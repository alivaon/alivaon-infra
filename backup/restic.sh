#!/usr/bin/env bash
#
# Lance restic avec la configuration d'Alivaon déjà chargée : dépôt, fichier de
# mot de passe, identifiants S3 éventuels, cache. Pour les opérations
# manuelles (inventaire, rotation de clé, extraction ponctuelle) sans jamais
# recopier un secret dans le shell ou l'historique.
#
# UTILISATION (sur le VPS, en root)
#   /usr/local/lib/alivaon-backup/restic.sh snapshots
#   /usr/local/lib/alivaon-backup/restic.sh key list
#   /usr/local/lib/alivaon-backup/restic.sh stats --mode raw-data
#
# shellcheck source-path=SCRIPTDIR
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

require_root
require_cmds restic
load_config
install -d -m 0700 -- "$RESTIC_CACHE_DIR"
exec restic "$@"
