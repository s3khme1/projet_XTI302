#!/bin/bash
# Reconstruit toute la configuration sur une Debian 13 vierge.
# Peut être relancé sans risque : rien n'est recréé ou reformaté inutilement.
# Usage : sudo ./installer.sh   (ou en root depuis la console)

set -euo pipefail

DOSSIER="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$DOSSIER/config"
# shellcheck source=config/projet.conf
source "$CONFIG/projet.conf"

PAQUETS=(sudo acl openssh-server nftables fail2ban python3-systemd rsync
         unattended-upgrades apt-listchanges e2fsprogs util-linux logrotate)

ATTENTION=0

# membres d'un groupe, y compris ceux dont c'est le groupe principal
membres() {
    local gid
    gid="$(getent group "$1" | cut -d: -f3)"
    [ -n "$gid" ] || return 0
    { getent group "$1" | cut -d: -f4 | tr ',' '\n'
      awk -F: -v g="$gid" '$4==g {print $1}' /etc/passwd; } | grep -v '^$' | sort -u
}

etape()     { echo; echo "==> $*"; }
info()      { echo "    $*"; }
attention() { echo "    [ATTENTION] $*" >&2; ATTENTION=1; }
erreur()    { echo "[ERREUR] $*" >&2; exit "${2:-1}"; }

verifier_prerequis() {
    [ "$(id -u)" -eq 0 ] || erreur "ce script doit être lancé en root" 2
    [ $# -eq 0 ] || erreur "usage : $0 (sans argument)" 2
    grep -q '^VERSION_ID="13"' /etc/os-release || attention "système autre que Debian 13"
}

installer_paquets() {
    etape "Paquets"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q
    apt-get install -y -q "${PAQUETS[@]}"
}

installer_scripts() {
    etape "Scripts dans /usr/local/sbin"
    # appartiennent à root et ne sont modifiables que par lui (lancés via sudo / timer)
    install -m 0755 -o root -g root "$DOSSIER/analyse_logs.sh" /usr/local/sbin/analyse_logs.sh
    install -m 0700 -o root -g root "$DOSSIER/sauvegarde.sh" /usr/local/sbin/sauvegarde.sh
}

configurer_comptes() {
    etape "Comptes, groupes et /srv (C1, C2)"
    sed -i -E 's/^#?HOME_MODE[[:space:]].*/HOME_MODE\t0700/' /etc/login.defs
    grep -q '^HOME_MODE' /etc/login.defs || echo -e "HOME_MODE\t0700" >> /etc/login.defs
    sed -i -E 's/^UMASK.*/UMASK\t\t027/' /etc/login.defs
    bash "$DOSSIER/creer_comptes.sh" "$DOSSIER/comptes.csv"
}

configurer_sudo() {
    etape "sudo (C3)"
    local f u
    for f in "$CONFIG"/sudoers.d/*; do
        visudo -cqf "$f" || erreur "syntaxe sudoers invalide : $f"
        install -m 0440 -o root -g root "$f" "/etc/sudoers.d/$(basename "$f")"
    done

    # le compte créé pendant l'installation de Debian est souvent dans "sudo"
    for u in $(membres sudo); do
        gpasswd -d "$u" sudo >/dev/null
        info "$u retiré du groupe sudo"
    done
    visudo -cq || erreur "configuration sudo invalide"
}

mots_de_passe_admins() {
    local u
    for u in $(membres admins); do
        [ "$(passwd -S "$u" | awk '{print $2}')" = "P" ] && continue
        if [ -t 0 ]; then
            echo "    Mot de passe de $u (sert uniquement pour sudo) :"
            until passwd "$u"; do :; done
        else
            attention "$u n'a pas de mot de passe : sudo impossible pour lui"
        fi
    done
}

configurer_root_homes() {
    etape "root et répertoires personnels (C4)"
    local u ok=0
    mots_de_passe_admins
    for u in $(membres admins); do
        if [ "$(passwd -S "$u" | awk '{print $2}')" = "P" ]; then
            ok=1
        fi
    done
    # verrouiller root sans admin utilisable = machine perdue
    if [ "$ok" -eq 1 ]; then
        passwd -l root >/dev/null
        info "root verrouillé"
    else
        attention "aucun admin avec mot de passe : root n'est PAS verrouillé"
    fi

    while IFS=: read -r u _ uid _ _ home _; do
        if [ "$uid" -ge 1000 ] && [ "$uid" -lt 60000 ] && [ -d "$home" ]; then
            chmod 0700 "$home"
        fi
    done < /etc/passwd
    chmod 0700 /root
}

configurer_ssh() {
    etape "SSH (S1 à S5)"
    local f
    install -d -m 0755 /etc/ssh/sshd_config.d
    for f in "$CONFIG"/ssh/sshd_config.d/*.conf; do
        install -m 0644 -o root -g root "$f" /etc/ssh/sshd_config.d/
    done
    install -m 0644 "$CONFIG/profile.d/tmout.sh" /etc/profile.d/tmout.sh

    if ! sshd -t; then
        for f in "$CONFIG"/ssh/sshd_config.d/*.conf; do
            rm -f "/etc/ssh/sshd_config.d/$(basename "$f")"
        done
        erreur "sshd -t a échoué : configuration SSH retirée, service non redémarré"
    fi
    systemctl enable ssh >/dev/null 2>&1
    systemctl reload-or-restart ssh
    info "sshd -t OK, ssh rechargé"
}

configurer_parefeu() {
    etape "Pare-feu nftables (J2)"
    nft -c -f "$CONFIG/nftables.conf" || erreur "nftables.conf invalide"
    install -m 0644 -o root -g root "$CONFIG/nftables.conf" /etc/nftables.conf
    systemctl enable nftables >/dev/null 2>&1
    # restart ferait un "flush ruleset" (ExecStop) et effacerait fail2ban
    if systemctl is-active -q nftables; then
        systemctl reload nftables
    else
        systemctl start nftables
    fi
}

configurer_fail2ban() {
    etape "fail2ban (J1)"
    local f
    for f in "$CONFIG"/fail2ban/jail.d/*.conf; do
        install -m 0644 -o root -g root "$f" /etc/fail2ban/jail.d/
    done
    install -d -m 0755 /etc/systemd/system/fail2ban.service.d
    install -m 0644 "$CONFIG/systemd/fail2ban-nftables.conf" /etc/systemd/system/fail2ban.service.d/nftables.conf
    systemctl daemon-reload
    fail2ban-client -t >/dev/null || erreur "configuration fail2ban invalide"
    systemctl enable fail2ban >/dev/null 2>&1
    systemctl restart fail2ban
}

configurer_journal() {
    etape "Journal persistant (J3)"
    install -d -m 0755 /etc/systemd/journald.conf.d
    install -m 0644 "$CONFIG/journald.conf.d/persistant.conf" /etc/systemd/journald.conf.d/
    install -d -m 2755 -g systemd-journal /var/log/journal
    systemd-tmpfiles --create --prefix /var/log/journal
    systemctl restart systemd-journald
    journalctl --flush
}

configurer_maj() {
    etape "Mises à jour automatiques (D1)"
    install -m 0644 "$CONFIG/apt/apt.conf.d/20auto-upgrades" /etc/apt/apt.conf.d/20auto-upgrades
    systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1
}

preparer_disque() {
    etape "Disque de sauvegarde (B1, B3)"
    local disque="$DISQUE_SAUVEGARDE" type label uuid

    [ -b "$disque" ] || erreur "disque $disque introuvable (voir DISQUE_SAUVEGARDE dans config/projet.conf)"
    if lsblk -no MOUNTPOINTS "$disque" | grep -q '^/$\|^/boot\|\[SWAP\]'; then
        erreur "$disque est un disque système, refus"
    fi

    type="$(blkid -s TYPE -o value "$disque" || true)"
    label="$(blkid -s LABEL -o value "$disque" || true)"

    if [ -z "$type" ]; then
        if [ -n "$(lsblk -no NAME "$disque" | tail -n +2)" ]; then
            erreur "$disque contient des partitions, formatage refusé"
        fi
        mkfs.ext4 -q -L "$LABEL_SAUVEGARDE" "$disque"
        info "$disque formaté en ext4"
    elif [ "$label" != "$LABEL_SAUVEGARDE" ]; then
        erreur "$disque contient déjà un système de fichiers ($type, label '$label') : formatage refusé"
    else
        info "$disque déjà prêt, pas de formatage"
    fi

    uuid="$(blkid -s UUID -o value "$disque")"
    install -d -m 0700 "$POINT_MONTAGE"
    if ! grep -q "[[:space:]]${POINT_MONTAGE}[[:space:]]" /etc/fstab; then
        echo "UUID=$uuid  $POINT_MONTAGE  ext4  defaults,nofail,nodev,nosuid,noexec  0  2" >> /etc/fstab
        systemctl daemon-reload
    fi
    mountpoint -q "$POINT_MONTAGE" || mount "$POINT_MONTAGE"

    chown root:admins "$POINT_MONTAGE"
    chmod 0750 "$POINT_MONTAGE"
}

configurer_sauvegarde() {
    etape "Planification de la sauvegarde (B2)"
    install -m 0644 "$CONFIG/systemd/sauvegarde.service" /etc/systemd/system/
    install -m 0644 "$CONFIG/systemd/sauvegarde.timer" /etc/systemd/system/
    install -m 0644 "$CONFIG/logrotate-sauvegarde" /etc/logrotate.d/sauvegarde
    touch /var/log/sauvegarde.log
    chown root:adm /var/log/sauvegarde.log
    chmod 0640 /var/log/sauvegarde.log
    systemctl daemon-reload
    systemctl enable --now sauvegarde.timer >/dev/null 2>&1

    if [ ! -e "$POINT_MONTAGE/derniere" ]; then
        info "première sauvegarde..."
        systemctl start sauvegarde.service
    fi
}

corriger_fichiers() {
    etape "Fichiers modifiables par tous (D3)"
    local f
    while IFS= read -r -d '' f; do
        chmod o-w "$f"
        info "o-w retiré : $f"
    done < <(find / \( -path /proc -o -path /sys -o -path /dev -o -path /run \
                     -o -path /tmp -o -path /var/tmp -o -path "$POINT_MONTAGE" \) -prune \
                  -o -type f -perm -0002 -print0 2>/dev/null)
}

main() {
    verifier_prerequis "$@"
    installer_paquets
    installer_scripts
    configurer_comptes
    configurer_sudo
    configurer_root_homes
    configurer_ssh
    configurer_parefeu
    configurer_fail2ban
    configurer_journal
    configurer_maj
    preparer_disque
    configurer_sauvegarde
    corriger_fichiers

    echo
    if [ "$ATTENTION" -eq 1 ]; then
        echo "Installation terminée avec des avertissements (voir ci-dessus)."
        exit 1
    fi
    echo "Installation terminée. Lancer : sudo ./verifier.sh"
}

main "$@"
