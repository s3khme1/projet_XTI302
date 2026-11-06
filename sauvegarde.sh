#!/bin/bash
# B1/B2 - Sauvegarde incrémentale de /srv et /etc avec versions datées
# Chaque version est un dossier complet, mais les fichiers inchangés sont
# des liens physiques vers la version précédente (rsync --link-dest).

set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 027

DESTINATION="${DESTINATION:-/sauvegardes}"
SOURCES=(/srv /etc)
GARDER="${GARDER:-14}"
JOURNAL=/var/log/sauvegarde.log

VERSIONS="$DESTINATION/versions"
DERNIERE="$DESTINATION/derniere"

log() {
    local msg
    msg="$(date '+%F %T') $*"
    echo "$msg" | tee -a "$JOURNAL"
    logger -t sauvegarde -- "$*" || true
}

echec() {
    log "ECHEC : $*"
    exit 1
}

verifier() {
    [ "$(id -u)" -eq 0 ] || { echo "ce script doit être lancé en root" >&2; exit 2; }
    [ $# -eq 0 ] || { echo "usage : $(basename "$0")  (sans argument)" >&2; exit 2; }
    [[ "$GARDER" =~ ^[0-9]+$ ]] && [ "$GARDER" -ge 7 ] || { echo "GARDER doit être >= 7" >&2; exit 2; }
    command -v rsync >/dev/null || echec "rsync absent"
    # sans disque monté, on écrirait sur le disque système
    mountpoint -q "$DESTINATION" || echec "$DESTINATION n'est pas monté"
}

sauvegarder() {
    local nom cible encours precedente=()

    nom="$(date '+%Y-%m-%d_%H%M%S')"
    cible="$VERSIONS/$nom"
    encours="$VERSIONS/.encours"

    mkdir -p "$VERSIONS"
    rm -rf "$encours"

    if [ -d "$DERNIERE" ]; then
        precedente=(--link-dest="$(readlink -f "$DERNIERE")")
    fi

    log "début de la sauvegarde $nom (${SOURCES[*]})"
    rsync -aAXH --numeric-ids --delete "${precedente[@]}" "${SOURCES[@]}" "$encours/" \
        >>"$JOURNAL" 2>&1 || echec "rsync a échoué (code $?)"

    mv "$encours" "$cible"
    ln -sfn "versions/$nom" "$DERNIERE"
    log "version $nom terminée ($(du -sh "$cible" | cut -f1) apparents)"
}

nettoyer() {
    local liste=() n i
    shopt -s nullglob
    liste=("$VERSIONS"/20*)
    shopt -u nullglob
    n=${#liste[@]}

    for ((i = 0; i < n - GARDER; i++)); do
        rm -rf "${liste[$i]}"
        log "ancienne version supprimée : $(basename "${liste[$i]}")"
    done
}

main() {
    verifier "$@"
    exec 9>/run/sauvegarde.lock
    flock -n 9 || { echo "une sauvegarde est déjà en cours" >&2; exit 1; }
    sauvegarder
    nettoyer
    log "sauvegarde terminée"
}

main "$@"
