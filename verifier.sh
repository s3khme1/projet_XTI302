#!/bin/bash
# Vérifie chaque exigence du cahier des charges et affiche [OK] / [KO].
# Ne modifie pas le système (seuls des fichiers de test temporaires sont
# créés puis supprimés).
# Code de sortie : 0 si tout est conforme, 1 sinon, 2 si mauvais usage.
#
# Pas de "set -e" : les tests lancent volontairement des commandes qui échouent.
# Pas de "pipefail" : "cmd | grep -q" ferait échouer cmd (SIGPIPE) et donc le test.

set -u
export LC_ALL=C
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

DOSSIER="$(cd "$(dirname "$0")" && pwd)"
CSV="$DOSSIER/comptes.csv"
DROITS="$DOSSIER/config/droits.csv"
SUID_OK="$DOSSIER/config/suid_autorises.txt"
# shellcheck source=config/projet.conf
source "$DOSSIER/config/projet.conf"

SAUV="$POINT_MONTAGE"
TMPDIR_VERIF=""
FICHIERS_TEST=()
REUSSIS=0
TOTAL=0

if [ -t 1 ]; then VERT=$'\e[32m'; ROUGE=$'\e[31m'; NORMAL=$'\e[0m'; else VERT=""; ROUGE=""; NORMAL=""; fi

ok() { REUSSIS=$((REUSSIS + 1)); TOTAL=$((TOTAL + 1)); printf '%s[OK]%s %-4s %s\n' "$VERT" "$NORMAL" "$1" "$2"; }
ko() { TOTAL=$((TOTAL + 1)); printf '%s[KO]%s %-4s %s\n' "$ROUGE" "$NORMAL" "$1" "$2"; }

nettoyer() {
    local f
    for f in "${FICHIERS_TEST[@]}"; do rm -f "$f"; done
    [ -n "$TMPDIR_VERIF" ] && rm -rf "$TMPDIR_VERIF"
}
trap nettoyer EXIT

# --- outils -----------------------------------------------------------------

# membres d'un groupe, y compris ceux dont c'est le groupe principal
membres() {
    local gid
    gid="$(getent group "$1" | cut -d: -f3)"
    [ -n "$gid" ] || return 0
    { getent group "$1" | cut -d: -f4 | tr ',' '\n'
      awk -F: -v g="$gid" '$4==g {print $1}' /etc/passwd; } | grep -v '^$' | sort -u
}

csv_lignes() { tail -n +2 "$CSV" | tr -d '\r' | grep -v '^$'; }

# premier compte du CSV ayant ce groupe principal
membre() { csv_lignes | awk -F';' -v g="$1" '$3==g {print $1; exit}'; }

sshd_val() { sshd -T 2>/dev/null | awk -v k="$1" 'tolower($1)==k {$1=""; sub(/^ /,""); print; exit}'; }

peut_lire()   { sudo -n -u "$1" test -r "$2" -a -x "$2" 2>/dev/null; }
peut_entrer() { sudo -n -u "$1" test -x "$2" 2>/dev/null; }
peut_ecrire() {
    local f="$2/.verif_$$_$1"
    FICHIERS_TEST+=("$f")
    sudo -n -u "$1" touch "$f" 2>/dev/null
}

# droits attendus d'un groupe sur un répertoire : rw, r, x ou vide
droit_attendu() { awk -F';' -v r="$1" -v g="$2" 'NR>1 && $1==r && $2==g {print $3}' "$DROITS"; }

repertoires() { tail -n +2 "$DROITS" | cut -d';' -f1 | sort -u; }

a_sudo() {
    local sortie
    sortie="$(sudo -n -l -U "$1" 2>&1)"
    ! echo "$sortie" | grep -q "is not allowed to run sudo"
}

en_secondes() {
    case "$1" in
        *m) echo $(( ${1%m} * 60 )) ;;
        *h) echo $(( ${1%h} * 3600 )) ;;
        *s) echo "${1%s}" ;;
        *)  echo "$1" ;;
    esac
}

versions() { find "$SAUV/versions" -mindepth 1 -maxdepth 1 -type d -name '20*' 2>/dev/null | sort; }

# --- C : comptes et droits ----------------------------------------------------

test_C1_comptes() {
    local login principal secondaires g erreurs=""
    while IFS=";" read -r login _ principal secondaires; do
        if ! id "$login" >/dev/null 2>&1; then
            erreurs+=" $login(absent)"; continue
        fi
        [ "$(id -gn "$login")" = "$principal" ] || erreurs+=" $login(groupe principal)"
        for g in ${secondaires//,/ }; do
            id -nG "$login" | tr ' ' '\n' | grep -qx "$g" || erreurs+=" $login(pas dans $g)"
        done
    done < <(csv_lignes)
    if [ -z "$erreurs" ]; then
        ok "C1" "les $(csv_lignes | wc -l) comptes de comptes.csv existent avec les bons groupes"
    else
        ko "C1" "comptes non conformes :$erreurs"
    fi
}

test_C1_doublons() {
    local d
    d="$(cut -d: -f1 /etc/passwd | sort | uniq -d) $(cut -d: -f1 /etc/group | sort | uniq -d)"
    if [ -z "${d// /}" ]; then
        ok "C1" "aucun compte ni groupe en double (script idempotent)"
    else
        ko "C1" "doublons :$d"
    fi
}

test_C1_freelance() {
    local u exp erreurs=""
    for u in $(csv_lignes | awk -F';' '$3=="freelance" {print $1}'); do
        exp="$(chage -l "$u" 2>/dev/null | awk -F': ' '/^Account expires/ {print $2}')"
        if [ -z "$exp" ] || [ "$exp" = "never" ]; then
            erreurs+=" $u"
        fi
        a_sudo "$u" && erreurs+=" $u(sudo)"
    done
    if [ -z "$erreurs" ]; then
        ok "C1" "les comptes freelance expirent le $EXPIRATION_FREELANCE et n'ont pas sudo"
    else
        ko "C1" "freelance sans date d'expiration ou avec sudo :$erreurs"
    fi
}

test_C2_proprietes() {
    local rep mode erreurs=""
    for rep in $(repertoires); do
        if [ ! -d "$rep" ]; then erreurs+=" $rep(absent)"; continue; fi
        mode="$(stat -c '%U:%G %a' "$rep")"
        [ "$mode" = "root:root 770" ] || erreurs+=" $rep($mode)"
        getfacl -cp "$rep" 2>/dev/null | grep -q '^other::---' || erreurs+=" $rep(other)"
    done
    if [ -z "$erreurs" ]; then
        ok "C2" "répertoires de /srv présents, root:root 770, aucun droit pour les autres"
    else
        ko "C2" "répertoires incorrects :$erreurs"
    fi
}

test_C2_autorise() {
    local rep g u d erreurs=""
    for rep in $(repertoires); do
        for g in $GROUPES_METIER; do
            u="$(membre "$g")"
            [ -z "$u" ] && continue
            d="$(droit_attendu "$rep" "$g")"
            case "$d" in
                rw) peut_lire "$u" "$rep" && peut_ecrire "$u" "$rep" || erreurs+=" $g:rw:$rep" ;;
                r)  peut_lire "$u" "$rep" || erreurs+=" $g:r:$rep" ;;
                x)  peut_entrer "$u" "$rep" || erreurs+=" $g:x:$rep" ;;
            esac
        done
    done
    if [ -z "$erreurs" ]; then
        ok "C2" "les accès prévus fonctionnent (ex : un dev écrit dans /srv/projets)"
    else
        ko "C2" "accès prévus refusés :$erreurs"
    fi
}

test_C2_refuse() {
    local rep g u d erreurs=""
    for rep in $(repertoires); do
        for g in $GROUPES_METIER; do
            u="$(membre "$g")"
            [ -z "$u" ] && continue
            d="$(droit_attendu "$rep" "$g")"
            case "$d" in
                rw) ;;
                r)  peut_ecrire "$u" "$rep" && erreurs+=" $g:écriture:$rep" ;;
                x)  peut_lire "$u" "$rep" && erreurs+=" $g:lecture:$rep" ;;
                *)  peut_entrer "$u" "$rep" && erreurs+=" $g:accès:$rep" ;;
            esac
        done
    done
    if [ -z "$erreurs" ]; then
        ok "C2" "les accès interdits sont refusés (ex : un commercial ne lit pas /srv/projets)"
    else
        ko "C2" "accès qui devraient être refusés :$erreurs"
    fi
}

test_C2_acl_defaut() {
    local dev design com f
    dev="$(membre dev)"; design="$(membre design)"; com="$(membre commercial)"
    f="/srv/projets/.verif_heritage_$$"
    FICHIERS_TEST+=("$f")
    if ! sudo -n -u "$dev" sh -c "umask 077; echo test > '$f'" 2>/dev/null; then
        ko "C2" "impossible de créer un fichier de test dans /srv/projets"
    elif sudo -n -u "$design" test -r "$f" && ! sudo -n -u "$design" test -w "$f" \
         && ! sudo -n -u "$com" test -r "$f"; then
        ok "C2" "ACL par défaut : un nouveau fichier de /srv/projets hérite des droits"
    else
        ko "C2" "ACL par défaut : les droits ne s'appliquent pas aux nouveaux fichiers"
    fi
}

test_C3_admins() {
    local u erreurs=""
    [ -f /etc/sudoers.d/10-projet ] || erreurs+=" fichier /etc/sudoers.d/10-projet absent"
    for u in $(csv_lignes | awk -F';' '$3=="admins" {print $1}'); do
        sudo -n -l -U "$u" 2>/dev/null | grep -q '(ALL : ALL) ALL' || erreurs+=" $u"
    done
    if [ -z "$erreurs" ]; then
        ok "C3" "les membres de admins ont sudo via /etc/sudoers.d"
    else
        ko "C3" "admins sans sudo :$erreurs"
    fi
}

test_C3_support() {
    local regles
    regles="$(sudo -n -l -U support 2>/dev/null | sed -n '/may run the following/,$p' | tail -n +2 | sed 's/^ *//')"
    if [ "$regles" = "(root) NOPASSWD: /usr/local/sbin/analyse_logs.sh" ]; then
        ok "C3" "le compte support ne peut lancer que analyse_logs.sh"
    else
        ko "C3" "règles sudo de support : ${regles:-aucune}"
    fi
}

test_C3_autres() {
    local u autorises erreurs=""
    autorises=" support $(membres admins | tr '\n' ' ') "
    while IFS=: read -r u _; do
        [ "$u" = "root" ] && continue
        [[ "$autorises" == *" $u "* ]] && continue
        a_sudo "$u" && erreurs+=" $u"
    done < /etc/passwd
    if [ -z "$erreurs" ] && [ -z "$(membres sudo)" ]; then
        ok "C3" "aucun autre compte n'a sudo (groupe sudo vide)"
    else
        ko "C3" "comptes avec sudo non prévus :$erreurs $(membres sudo | tr '\n' ' ')"
    fi
}

test_C3_syntaxe() {
    if visudo -cq >/dev/null 2>&1 && [ "$(stat -c '%U %a' /etc/sudoers.d/10-projet 2>/dev/null)" = "root 440" ]; then
        ok "C3" "configuration sudo valide (visudo -c), fichier root 440"
    else
        ko "C3" "visudo -c échoue ou droits du fichier sudoers incorrects"
    fi
}

test_C4_root() {
    local etat
    etat="$(passwd -S root | awk '{print $2}')"
    if [ "$etat" = "L" ]; then
        ok "C4" "compte root verrouillé"
    else
        ko "C4" "compte root non verrouillé (état $etat, attendu L)"
    fi
}

test_C4_homes() {
    local u uid home erreurs=""
    while IFS=: read -r u _ uid _ _ home _; do
        [ "$uid" -ge 1000 ] && [ "$uid" -lt 60000 ] && [ -d "$home" ] || continue
        [ $(( 0$(stat -c '%a' "$home") & 077 )) -eq 0 ] || erreurs+=" $home($(stat -c '%a' "$home"))"
    done < /etc/passwd
    if [ -z "$erreurs" ]; then
        ok "C4" "répertoires personnels inaccessibles aux autres utilisateurs (700)"
    else
        ko "C4" "répertoires personnels trop ouverts :$erreurs"
    fi
}

test_C4_homes_reel() {
    local a b
    a="$(membre dev)"; b="$(csv_lignes | awk -F';' -v x="$a" '$3=="dev" && $1!=x {print $1; exit}')"
    if [ -n "$b" ] && ! peut_lire "$b" "$(getent passwd "$a" | cut -d: -f6)"; then
        ok "C4" "$b ne peut pas lire le répertoire personnel de $a (même groupe)"
    else
        ko "C4" "$b peut lire le répertoire personnel de $a"
    fi
}

# --- S : SSH -------------------------------------------------------------------

test_S1() {
    if [ "$(sshd_val passwordauthentication)" = "no" ] \
       && [ "$(sshd_val kbdinteractiveauthentication)" = "no" ] \
       && [ "$(sshd_val pubkeyauthentication)" = "yes" ]; then
        ok "S1" "connexion par clé uniquement, mot de passe refusé"
    else
        ko "S1" "authentification par mot de passe encore possible"
    fi
}

test_S1_cles() {
    local u home erreurs=""
    for u in $(membres acces_ssh); do
        home="$(getent passwd "$u" | cut -d: -f6)"
        if [ ! -s "$home/.ssh/authorized_keys" ]; then
            erreurs+=" $u(pas de clé)"
        elif [ "$(stat -c '%U %a' "$home/.ssh/authorized_keys")" != "$u 600" ]; then
            erreurs+=" $u(droits)"
        fi
    done
    if [ -z "$erreurs" ]; then
        ok "S1" "chaque membre de acces_ssh a sa clé publique installée (600)"
    else
        ko "S1" "clés manquantes ou mal installées :$erreurs"
    fi
}

test_S2() {
    if [ "$(sshd_val permitrootlogin)" = "no" ]; then
        ok "S2" "connexion root refusée"
    else
        ko "S2" "PermitRootLogin vaut '$(sshd_val permitrootlogin)' (attendu : no)"
    fi
}

test_S3() {
    if [ "$(sshd_val allowgroups)" = "acces_ssh" ]; then
        ok "S3" "seul le groupe acces_ssh peut se connecter"
    else
        ko "S3" "AllowGroups vaut '$(sshd_val allowgroups)' (attendu : acces_ssh)"
    fi
}

test_S3_metier() {
    local g u erreurs=""
    for g in $GROUPES_METIER; do
        for u in $(csv_lignes | awk -F';' -v g="$g" '$3==g {print $1}'); do
            id -nG "$u" | tr ' ' '\n' | grep -qx acces_ssh && erreurs+=" $u"
        done
    done
    if [ -z "$erreurs" ]; then
        ok "S3" "aucun utilisateur métier dans acces_ssh"
    else
        ko "S3" "utilisateurs métier avec accès SSH :$erreurs"
    fi
}

test_S4_essais() {
    local n
    n="$(sshd_val maxauthtries)"
    if [ -n "$n" ] && [ "$n" -le 4 ]; then
        ok "S4" "au plus $n essais d'authentification par connexion"
    else
        ko "S4" "MaxAuthTries vaut '$n' (attendu : 4 au plus)"
    fi
}

test_S4_inactivite() {
    local ct duree
    ct="$(sshd_val channeltimeout | tr ' ' '\n' | grep '^session' | head -n1 | cut -d= -f2)"
    duree="$(en_secondes "${ct:-0}")"
    if [ "$duree" -gt 0 ] && [ "$duree" -le 900 ]; then
        ok "S4" "session inactive fermée après ${duree}s (ChannelTimeout)"
    else
        ko "S4" "pas de fermeture des sessions inactives en 15 min (ChannelTimeout='$ct')"
    fi
}

test_S5() {
    if ls /etc/ssh/sshd_config.d/*.conf >/dev/null 2>&1 \
       && grep -qs '^AllowGroups' /etc/ssh/sshd_config.d/*.conf \
       && sshd -t 2>/dev/null; then
        ok "S5" "configuration dans /etc/ssh/sshd_config.d/, sshd -t valide"
    else
        ko "S5" "configuration absente de sshd_config.d ou sshd -t en erreur"
    fi
}

test_S5_service() {
    if systemctl is-active -q ssh && systemctl is-enabled -q ssh; then
        ok "S5" "service ssh actif et lancé au démarrage"
    else
        ko "S5" "service ssh inactif ou non activé"
    fi
}

# --- J : journaux et défense ---------------------------------------------------

test_J1_actif() {
    if systemctl is-active -q fail2ban && fail2ban-client status sshd >/dev/null 2>&1; then
        ok "J1" "fail2ban actif, prison sshd en place"
    else
        ko "J1" "fail2ban inactif ou prison sshd absente"
    fi
}

test_J1_reglages() {
    local mr bt act
    mr="$(fail2ban-client get sshd maxretry 2>/dev/null)"
    bt="$(fail2ban-client get sshd bantime 2>/dev/null)"
    act="$(fail2ban-client get sshd actions 2>/dev/null | tail -n1)"
    if [ -n "$mr" ] && [ "$mr" -le 10 ] && [ "${bt:-0}" -gt 0 ] && echo "$act" | grep -q nftables; then
        ok "J1" "bannissement après $mr échecs pendant ${bt}s, via nftables"
    else
        ko "J1" "réglages fail2ban incorrects (maxretry=$mr bantime=$bt actions=$act)"
    fi
}

test_J2_politique() {
    local pol
    pol="$(nft list chain inet filtrage entree 2>/dev/null | grep -o 'policy [a-z]*' | awk '{print $2}')"
    if [ "$pol" = "drop" ]; then
        ok "J2" "politique par défaut du pare-feu en entrée : drop"
    else
        ko "J2" "politique par défaut du pare-feu : ${pol:-absente} (attendu : drop)"
    fi
}

test_J2_regles() {
    local r
    r="$(nft list chain inet filtrage entree 2>/dev/null)"
    if echo "$r" | grep -q 'tcp dport 22' && echo "$r" | grep -q 'ct state established,related accept'; then
        ok "J2" "seuls SSH et les connexions établies sont acceptés"
    else
        ko "J2" "règles SSH ou connexions établies manquantes"
    fi
}

test_J2_persistant() {
    if systemctl is-enabled -q nftables && nft -c -f /etc/nftables.conf 2>/dev/null \
       && grep -q 'policy drop' /etc/nftables.conf; then
        ok "J2" "règles dans /etc/nftables.conf, chargées au démarrage"
    else
        ko "J2" "nftables non activé au démarrage ou /etc/nftables.conf incorrect"
    fi
}

test_J2_fail2ban() {
    if nft list tables 2>/dev/null | grep -q 'f2b-table' || [ "$(fail2ban-client status sshd 2>/dev/null | awk '/Currently banned/ {print $NF}')" = "0" ]; then
        ok "J2" "nftables et fail2ban cohabitent (table fail2ban présente ou aucun banni)"
    else
        ko "J2" "des IP sont bannies mais la table de fail2ban a disparu du pare-feu"
    fi
}

test_J3() {
    local s
    s="$(systemd-analyze cat-config systemd/journald.conf 2>/dev/null | grep -E '^Storage=' | tail -n1)"
    if [ "$s" = "Storage=persistent" ] && [ -d "/var/log/journal/$(cat /etc/machine-id)" ]; then
        ok "J3" "journal persistant ($(journalctl --list-boots 2>/dev/null | wc -l) démarrage(s) conservé(s))"
    else
        ko "J3" "journal non persistant (${s:-Storage non défini})"
    fi
}

test_J4_droits() {
    local f=/usr/local/sbin/analyse_logs.sh
    if [ -x "$f" ] && [ "$(stat -c '%U:%G' "$f")" = "root:root" ] && [ $(( 0$(stat -c '%a' "$f") & 022 )) -eq 0 ]; then
        ok "J4" "analyse_logs.sh appartient à root et n'est modifiable que par lui"
    else
        ko "J4" "analyse_logs.sh absent ou modifiable par un autre que root"
    fi
}

test_J4_alerte() {
    local f=/usr/local/sbin/analyse_logs.sh echantillon c1 c2
    echantillon="$(for i in 1 2 3 4 5; do
        echo "Invalid user test$i from 203.0.113.7 port 4000$i"
    done
    echo "Accepted publickey for support from 192.0.2.10 port 50000 ssh2: ED25519 SHA256:abc")"
    echo "$echantillon" | "$f" -i -s 5 >/dev/null 2>&1; c1=$?
    echo "$echantillon" | "$f" -i -s 50 >/dev/null 2>&1; c2=$?
    if [ "$c1" -ne 0 ] && [ "$c2" -eq 0 ]; then
        ok "J4" "analyse_logs.sh : code de sortie non nul quand le seuil est dépassé"
    else
        ko "J4" "codes de sortie incorrects (seuil dépassé : $c1, non dépassé : $c2)"
    fi
}

test_J4_rapport() {
    local sortie
    sortie="$(sudo -n -u support sudo -n /usr/local/sbin/analyse_logs.sh -s 99999 2>&1)"
    if echo "$sortie" | grep -q 'Échecs par adresse IP' && echo "$sortie" | grep -q 'Connexions réussies'; then
        ok "J4" "support produit le rapport SSH via sudo"
    else
        ko "J4" "le rapport ne peut pas être lancé par support"
    fi
}

# --- B : sauvegardes -------------------------------------------------------------

test_B1_versions() {
    local n
    n="$(versions | wc -l)"
    if mountpoint -q "$SAUV" && [ "$n" -ge 1 ] && [ "$n" -le 14 ] && [ -d "$SAUV/derniere/srv" ] && [ -d "$SAUV/derniere/etc" ]; then
        ok "B1" "$n version(s) datée(s) de /srv et /etc sur le second disque (14 max)"
    else
        ko "B1" "sauvegarde absente, disque non monté ou trop de versions ($n)"
    fi
}

test_B1_incremental() {
    local v a b f
    mapfile -t v < <(versions)
    if [ "${#v[@]}" -lt 2 ]; then
        ko "B1" "une seule version : impossible de vérifier l'incrémental (relancer sauvegarde.sh)"
        return
    fi
    a="${v[-2]}"; b="${v[-1]}"
    f="etc/os-release"
    [ -L "$a/$f" ] && f="etc/hostname"
    if [ "$(stat -c %i "$a/$f")" = "$(stat -c %i "$b/$f")" ]; then
        ok "B1" "incrémental : fichier inchangé partagé entre les deux dernières versions (même inode)"
    else
        ko "B1" "les fichiers inchangés sont recopiés à chaque version"
    fi
}

test_B1_acl() {
    local rep erreurs=""
    for rep in $(repertoires); do
        [ "$(getfacl -cp "$rep" 2>/dev/null)" = "$(getfacl -cp "$SAUV/derniere$rep" 2>/dev/null)" ] || erreurs+=" $rep"
    done
    if [ -z "$erreurs" ] && [ "$(stat -c '%U:%G %a' /etc/shadow)" = "$(stat -c '%U:%G %a' "$SAUV/derniere/etc/shadow" 2>/dev/null)" ]; then
        ok "B1" "droits et ACL conservés dans la sauvegarde"
    else
        ko "B1" "ACL ou droits différents dans la sauvegarde :$erreurs"
    fi
}

test_B2() {
    if systemctl is-enabled -q sauvegarde.timer && systemctl is-active -q sauvegarde.timer \
       && grep -q 'sauvegarde terminée' /var/log/sauvegarde.log 2>/dev/null; then
        ok "B2" "sauvegarde planifiée (timer systemd) et journalisée dans /var/log/sauvegarde.log"
    else
        ko "B2" "timer sauvegarde.timer inactif ou aucune exécution journalisée"
    fi
}

test_B3() {
    local dev
    dev="$(membre dev)"
    if [ "$(stat -c '%U:%G %a' "$SAUV" 2>/dev/null)" = "root:admins 750" ] && ! peut_entrer "$dev" "$SAUV"; then
        ok "B3" "sauvegardes accessibles aux seuls administrateurs ($dev refusé)"
    else
        ko "B3" "droits de $SAUV : $(stat -c '%U:%G %a' "$SAUV" 2>/dev/null) (attendu root:admins 750)"
    fi
}

test_B4() {
    local v ancienne
    mapfile -t v < <(versions)
    ancienne="${v[0]:-}"
    TMPDIR_VERIF="$(mktemp -d)"
    if [ -n "$ancienne" ] && rsync -aAX "$ancienne/srv/projets/" "$TMPDIR_VERIF/projets/" 2>/dev/null \
       && [ "$(getfacl -cp "$TMPDIR_VERIF/projets" 2>/dev/null | grep -c '^group:')" -ge 3 ]; then
        ok "B4" "restauration depuis la version $(basename "$ancienne") réussie (ACL comprises)"
    else
        ko "B4" "restauration impossible depuis la plus ancienne version"
    fi
}

# --- D : système -------------------------------------------------------------------

test_D1() {
    if dpkg -s unattended-upgrades >/dev/null 2>&1 \
       && apt-config dump | grep -q 'APT::Periodic::Unattended-Upgrade "1"' \
       && systemctl is-enabled -q apt-daily-upgrade.timer; then
        ok "D1" "mises à jour de sécurité automatiques (unattended-upgrades)"
    else
        ko "D1" "unattended-upgrades absent ou désactivé"
    fi
}

test_D2() {
    local proto adresse port hors=""
    while read -r proto _ _ _ adresse _; do
        port="${adresse##*:}"
        adresse="${adresse%:*}"
        case "$adresse" in
            127.*|"[::1]"|*%lo) continue ;;
        esac
        case "$proto:$port" in
            tcp:22|udp:68|udp:546) continue ;;
        esac
        hors+=" $proto/$adresse:$port"
    done < <(ss -tulnH)
    if [ -z "$hors" ]; then
        ok "D2" "seul SSH est joignable depuis le réseau (+ client DHCP)"
    else
        ko "D2" "services à l'écoute non prévus :$hors"
    fi
}

test_D3_ecriture() {
    local liste
    liste="$(find / \( -path /proc -o -path /sys -o -path /dev -o -path /run \
                    -o -path /tmp -o -path /var/tmp -o -path "$SAUV" \) -prune \
                 -o \( -type f -o -type d \) -perm -0002 ! -perm -1000 -print 2>/dev/null)"
    if [ -z "$liste" ]; then
        ok "D3" "aucun fichier modifiable par tous hors répertoires temporaires"
    else
        ko "D3" "fichiers modifiables par tous : $(echo "$liste" | head -n5 | tr '\n' ' ')"
    fi
}

test_D3_suid() {
    local inattendus
    inattendus="$(find / \( -path /proc -o -path /sys -o -path /dev -o -path /run -o -path "$SAUV" \) -prune \
                       -o -type f -perm -4000 -print 2>/dev/null | sort | comm -23 - <(sort "$SUID_OK"))"
    if [ -z "$inattendus" ]; then
        ok "D3" "fichiers SUID tous connus et justifiés ($(wc -l < "$SUID_OK") autorisés)"
    else
        ko "D3" "fichiers SUID non prévus : $(echo "$inattendus" | tr '\n' ' ')"
    fi
}

# ------------------------------------------------------------------------------------

main() {
    [ "$(id -u)" -eq 0 ] || { echo "ce script doit être lancé en root (sudo ./verifier.sh)" >&2; exit 2; }
    [ $# -eq 0 ] || { echo "usage : $0 (sans argument)" >&2; exit 2; }
    [ -r "$CSV" ] && [ -r "$DROITS" ] || { echo "comptes.csv ou config/droits.csv introuvable" >&2; exit 2; }

    test_C1_comptes; test_C1_doublons; test_C1_freelance
    test_C2_proprietes; test_C2_autorise; test_C2_refuse; test_C2_acl_defaut
    test_C3_admins; test_C3_support; test_C3_autres; test_C3_syntaxe
    test_C4_root; test_C4_homes; test_C4_homes_reel
    test_S1; test_S1_cles; test_S2; test_S3; test_S3_metier
    test_S4_essais; test_S4_inactivite; test_S5; test_S5_service
    test_J1_actif; test_J1_reglages
    test_J2_politique; test_J2_regles; test_J2_persistant; test_J2_fail2ban
    test_J3; test_J4_droits; test_J4_alerte; test_J4_rapport
    test_B1_versions; test_B1_incremental; test_B1_acl; test_B2; test_B3; test_B4
    test_D1; test_D2; test_D3_ecriture; test_D3_suid

    echo "--- $REUSSIS / $TOTAL tests réussis"
    [ "$REUSSIS" -eq "$TOTAL" ]
}

main "$@"
