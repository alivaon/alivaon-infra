#!/usr/bin/env bash
#
# Sauvegarde chiffrée hors machine d'Alivaon — IDEMPOTENT.
#
# Pour chaque environnement de BACKUP_ENVIRONMENTS (production puis staging) :
#   1. mysqldump --single-transaction, exécuté DANS le conteneur MySQL ;
#   2. `restic backup` du dump et des volumes d'uploads, en un instantané
#      étiqueté env:<environnement> ;
# puis, une fois tous les environnements sauvegardés :
#   3. `restic forget --prune` selon la rétention (7 j / 4 sem / 6 mois).
#
# Échec rapide : le script s'arrête avec un code non nul dès qu'une étape
# échoue, et ne purge alors rien. Les dumps temporaires sont supprimés dans
# tous les cas, succès, erreur ou interruption.
#
# Relançable à volonté : chaque exécution ajoute un instantané (dédupliqué par
# restic), la rétention s'applique à l'ensemble, rien d'autre ne s'accumule.
#
# UTILISATION (sur le VPS, en root)
#   Normalement via systemd :  systemctl start alivaon-backup.service
#   À la main :                /usr/local/lib/alivaon-backup/backup.sh [--env production]
#
# CODES DE SORTIE
#   0  toutes les sauvegardes et la purge ont réussi
#   1  une étape a échoué (détail dans le journal)
#
# shellcheck source-path=SCRIPTDIR
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

CLEANUP_DIRS=()
ONLY_ENVS=()

usage() {
  cat <<'EOF'
Usage : backup.sh [--env production|staging]...

  --env ENV   ne sauvegarder que cet environnement (répétable).
              Par défaut : tous ceux de BACKUP_ENVIRONMENTS.
  -h, --help  cette aide.

La purge (forget --prune) s'exécute dans tous les cas, sur l'ensemble du dépôt.
EOF
}

on_exit() {
  local rc=$?
  local d
  for d in "${CLEANUP_DIRS[@]}"; do
    rm -rf -- "$d"
  done
  if ((rc == 0)); then
    info "sauvegarde complète réussie"
  else
    error "sauvegarde en ÉCHEC (code $rc)"
  fi
  hc_ping "$rc"
  exit "$rc"
}

main() {
  local env
  local -a envs=()

  while (($# > 0)); do
    case $1 in
      --env)
        [[ -n ${2:-} ]] || { usage; exit 1; }
        ONLY_ENVS+=("$2")
        shift 2
        ;;
      -h | --help) usage; exit 0 ;;
      *) usage; exit 1 ;;
    esac
  done

  require_root
  require_cmds docker restic curl flock base64 numfmt
  load_config
  check_restic_version

  mapfile -t envs < <(configured_envs)
  if ((${#ONLY_ENVS[@]} > 0)); then
    for env in "${ONLY_ENVS[@]}"; do
      [[ " $(join_by ' ' "${envs[@]}") " == *" $env "* ]] || die "environnement '$env' absent de BACKUP_ENVIRONMENTS"
    done
    envs=("${ONLY_ENVS[@]}")
  fi

  # Une restauration en cours tient le verrou : on l'attend jusqu'à 30 min
  # plutôt que d'échouer aussitôt.
  acquire_lock 1800
  trap on_exit EXIT
  trap 'on_err $? $LINENO "$BASH_COMMAND"' ERR
  trap 'exit 130' INT
  trap 'exit 143' TERM

  install -d -m 0700 -- "$ALIVAON_STATE_DIR" "$RESTIC_CACHE_DIR"
  hc_ping start

  info "dépôt : $RESTIC_REPOSITORY — hôte restic : $RESTIC_HOST — environnements : $(join_by ' ' "${envs[@]}")"
  check_repository

  for env in "${envs[@]}"; do
    backup_env "$env" scheduled
  done

  info "rétention : $KEEP_DAILY quotidiennes, $KEEP_WEEKLY hebdomadaires, $KEEP_MONTHLY mensuelles, puis purge"
  # --group-by host,tags : chaque environnement (et chaque type, scheduled ou
  # pre-restore) a sa propre rétention. Sans cela, les instantanés staging
  # compteraient dans le quota de la production.
  rstc forget --tag alivaon --group-by host,tags \
    --keep-daily "$KEEP_DAILY" \
    --keep-weekly "$KEEP_WEEKLY" \
    --keep-monthly "$KEEP_MONTHLY" \
    --prune
}

main "$@"
