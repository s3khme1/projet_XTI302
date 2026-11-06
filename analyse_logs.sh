#!/bin/bash
# J4 - Rapport sur les connexions SSH
# Lancé en root via sudo par le compte support : il n'accepte que des
# options contrôlées et n'ouvre jamais de pager.
#
# Codes de sortie : 0 rien à signaler, 1 seuil dépassé, 2 erreur d'utilisation

set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
umask 077

SEUIL=10
HEURES=24
STDIN=0

usage() {
    cat <<EOF
Usage : $(basename "$0") [-s seuil] [-H heures] [-i]
  -s seuil   nombre d'échecs par IP déclenchant une alerte (défaut : $SEUIL)
  -H heures  période analysée en heures (défaut : $HEURES)
  -i         lire les lignes de journal sur l'entrée standard
EOF
}

erreur() { echo "erreur : $*" >&2; usage >&2; exit 2; }

lire_options() {
    while getopts ":s:H:ih" opt; do
        case "$opt" in
            s) SEUIL="$OPTARG" ;;
            H) HEURES="$OPTARG" ;;
            i) STDIN=1 ;;
            h) usage; exit 0 ;;
            :) erreur "l'option -$OPTARG attend une valeur" ;;
            *) erreur "option inconnue : -$OPTARG" ;;
        esac
    done
    shift $((OPTIND - 1))
    [ $# -eq 0 ] || erreur "argument inattendu : $1"
    [[ "$SEUIL" =~ ^[1-9][0-9]{0,5}$ ]] || erreur "seuil invalide : $SEUIL"
    [[ "$HEURES" =~ ^[1-9][0-9]{0,4}$ ]] || erreur "durée invalide : $HEURES"
}

# Sur Debian 13 il n'y a pas de /var/log/auth.log : tout est dans journald
lire_journal() {
    if [ "$STDIN" -eq 1 ]; then
        cat
    else
        [ "$(id -u)" -eq 0 ] || { echo "erreur : lancer en root (sudo)" >&2; exit 2; }
        journalctl --no-pager -q -o cat --since "-${HEURES}h" \
            _SYSTEMD_UNIT=ssh.service + SYSLOG_IDENTIFIER=sshd + SYSLOG_IDENTIFIER=sshd-session
    fi
}

# Une ligne par événement : TYPE IP COMPTE
extraire() {
    sed -nE \
        -e 's/.*Failed [a-z-]+ for invalid user ([^ ]+) from ([0-9a-fA-F:.]+) port.*/ECHEC \2 \1/p' \
        -e 's/.*Failed [a-z-]+ for ([^ ]+) from ([0-9a-fA-F:.]+) port.*/ECHEC \2 \1/p' \
        -e 's/.*Invalid user ([^ ]*) from ([0-9a-fA-F:.]+) port.*/ECHEC \2 \1/p' \
        -e 's/.*User ([^ ]+) from ([0-9a-fA-F:.]+) not allowed because.*/ECHEC \2 \1/p' \
        -e 's/.*Connection (closed|reset) by authenticating user ([^ ]+) ([0-9a-fA-F:.]+) port.*\[preauth\].*/ECHEC \3 \2/p' \
        -e 's/.*Accepted [a-z-]+ for ([^ ]+) from ([0-9a-fA-F:.]+) port.*/SUCCES \2 \1/p'
}

rapport() {
    local evenements="$1" alertes

    echo "=== Rapport SSH - $(hostname) - $(date '+%F %T') ==="
    if [ "$STDIN" -eq 1 ]; then
        echo "Source : entrée standard"
    else
        echo "Période : $HEURES dernières heures"
    fi
    echo "Seuil d'alerte : $SEUIL échecs par IP"
    echo

    echo "--- Échecs par adresse IP ---"
    awk '$1=="ECHEC" {n[$2]++} END {for (ip in n) printf "%6d  %s\n", n[ip], ip}' "$evenements" | sort -rn
    echo

    echo "--- Comptes visés ---"
    awk '$1=="ECHEC" {n[$3]++} END {for (u in n) printf "%6d  %s\n", n[u], u}' "$evenements" | sort -rn
    echo

    echo "--- Connexions réussies ---"
    awk '$1=="SUCCES" {n[$3" depuis "$2]++} END {for (k in n) printf "%6d  %s\n", n[k], k}' "$evenements" | sort -rn
    echo

    alertes="$(awk -v s="$SEUIL" '$1=="ECHEC" {n[$2]++} END {for (ip in n) if (n[ip] >= s) print ip}' "$evenements")"
    if [ -n "$alertes" ]; then
        echo "ALERTE : seuil atteint pour : $(echo "$alertes" | tr '\n' ' ')"
        return 1
    fi
    echo "Aucune alerte."
    return 0
}

main() {
    local tmp code=0
    lire_options "$@"
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' EXIT

    lire_journal | extraire > "$tmp"
    rapport "$tmp" || code=1
    exit "$code"
}

main "$@"
