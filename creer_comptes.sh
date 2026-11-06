#!/bin/bash
# Création des groupes, comptes, répertoires /srv et ACL (C1, C2)
# Installe aussi les clés publiques des membres de acces_ssh.
# Usage : creer_comptes.sh [fichier.csv]

set -euo pipefail

DOSSIER="$(cd "$(dirname "$0")" && pwd)"
CSV="${1:-$DOSSIER/comptes.csv}"
DROITS="$DOSSIER/config/droits.csv"
CLES="$DOSSIER/config/cles"

# shellcheck source=config/projet.conf
source "$DOSSIER/config/projet.conf"

# membres d'un groupe, y compris ceux dont c'est le groupe principal
membres() {
    local gid
    gid="$(getent group "$1" | cut -d: -f3)"
    [ -n "$gid" ] || return 0
    { getent group "$1" | cut -d: -f4 | tr ',' '\n'
      awk -F: -v g="$gid" '$4==g {print $1}' /etc/passwd; } | grep -v '^$' | sort -u
}

info()   { echo "[*] $*"; }
erreur() { echo "[ERREUR] $*" >&2; exit "${2:-1}"; }

verifier_prerequis() {
    [ "$(id -u)" -eq 0 ] || erreur "ce script doit être lancé en root" 2
    [ -r "$CSV" ] || erreur "fichier introuvable : $CSV" 2
    [ -r "$DROITS" ] || erreur "fichier introuvable : $DROITS" 2
    command -v setfacl >/dev/null || erreur "paquet acl manquant (apt install acl)" 3

    local entete
    entete="$(head -n1 "$CSV" | tr -d '\r')"
    [ "$entete" = "login;nom;groupe_principal;groupes_secondaires" ] \
        || erreur "en-tête de $CSV incorrect : $entete" 2
}

creer_groupe() {
    if ! getent group "$1" >/dev/null; then
        groupadd "$1"
        info "groupe $1 créé"
    fi
}

creer_groupes() {
    local g
    for g in $GROUPES_FIXES $GROUPES_METIER; do
        creer_groupe "$g"
    done

    # groupes cités dans le CSV mais pas dans la config
    tail -n +2 "$CSV" | tr -d '\r' | cut -d';' -f3,4 | tr ';,' '\n\n' | sort -u |
    while read -r g; do
        if [ -n "$g" ]; then
            creer_groupe "$g"
        fi
    done
}

creer_compte() {
    local login="$1" nom="$2" principal="$3" secondaires="$4"

    if id "$login" >/dev/null 2>&1; then
        usermod -g "$principal" -c "$nom" "$login"
        if [ -n "$secondaires" ]; then
            usermod -aG "$secondaires" "$login"
        fi
        info "compte $login mis à jour"
    else
        if [ -n "$secondaires" ]; then
            useradd -m -s /bin/bash -c "$nom" -g "$principal" -G "$secondaires" "$login"
        else
            useradd -m -s /bin/bash -c "$nom" -g "$principal" "$login"
        fi
        info "compte $login créé"
    fi

    chmod 0700 "$(getent passwd "$login" | cut -d: -f6)"

    if [ "$principal" = "freelance" ]; then
        chage -E "$EXPIRATION_FREELANCE" "$login"
    fi
}

creer_comptes() {
    local login nom principal secondaires
    while IFS=';' read -r login nom principal secondaires; do
        secondaires="${secondaires%$'\r'}"
        [ -z "$login" ] && continue
        [[ "$login" =~ ^[a-z_][a-z0-9_-]*$ ]] || erreur "login invalide : $login" 2
        creer_compte "$login" "$nom" "$principal" "$secondaires"
    done < <(tail -n +2 "$CSV")
}

installer_cles() {
    local login home cle
    for login in $(membres acces_ssh); do
        cle="$CLES/$login.pub"
        if [ ! -s "$cle" ]; then
            echo "[ATTENTION] pas de clé publique pour $login ($cle)" >&2
            continue
        fi
        ssh-keygen -l -f "$cle" >/dev/null 2>&1 || { echo "[ATTENTION] clé invalide : $cle" >&2; continue; }

        home="$(getent passwd "$login" | cut -d: -f6)"
        install -d -m 0700 -o "$login" -g "$(id -gn "$login")" "$home/.ssh"
        install -m 0600 -o "$login" -g "$(id -gn "$login")" "$cle" "$home/.ssh/authorized_keys"
        info "clé installée pour $login"
    done
}

# Conversion rw / r / x vers les droits setfacl
droits_acl() {
    case "$1" in
        rw) echo "rwx" ;;
        r)  echo "r-x" ;;
        x)  echo "--x" ;;
        *)  erreur "droit inconnu dans $DROITS : $1" ;;
    esac
}

creer_repertoires() {
    local rep groupe droits acl

    install -d -m 0755 -o root -g root /srv

    # d'abord tous les répertoires, puis les ACL (externe est dans projets)
    tail -n +2 "$DROITS" | cut -d';' -f1 | sort -u | while read -r rep; do
        mkdir -p "$rep"
        chown root:root "$rep"
        chmod 0770 "$rep"
        setfacl -b "$rep"
        setfacl -m u::rwx,g::---,o::--- "$rep"
        setfacl -d -m u::rwx,g::---,o::--- "$rep"
    done

    while IFS=';' read -r rep groupe droits; do
        acl="$(droits_acl "$droits")"
        setfacl -m "g:$groupe:$acl" "$rep"
        # la traversée seule ne doit pas être héritée
        if [ "$droits" != "x" ]; then
            setfacl -d -m "g:$groupe:$acl" "$rep"
        fi
    done < <(tail -n +2 "$DROITS")

    tail -n +2 "$DROITS" | cut -d';' -f1 | sort -u | while read -r rep; do
        setfacl -m m::rwx "$rep"
        setfacl -d -m m::rwx "$rep"
    done
    info "répertoires de /srv et ACL en place"
}

main() {
    verifier_prerequis
    creer_groupes
    creer_comptes
    installer_cles
    creer_repertoires
    info "terminé"
}

main "$@"
