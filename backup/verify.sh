#!/usr/bin/env bash
#
# Contrôle de santé du dépôt restic — lecture seule, relançable à volonté.
#
#   1. restic check : intégrité de la structure du dépôt (index, arbres).
#      Avec --read-data-subset, relit et déchiffre aussi une fraction des
#      données, ce qui détecte une corruption côté stockage.
#   2. restic snapshots : inventaire affiché.
#   3. Fraîcheur : pour chaque environnement de BACKUP_ENVIRONMENTS, le dernier
#      instantané planifié doit dater de moins de MAX_AGE_HOURS (48 h).
#
# Toutes les étapes s'exécutent même si l'une échoue : le bilan final les
# résume toutes.
#
# UTILISATION (sur le VPS, en root)
#   /usr/local/lib/alivaon-backup/verify.sh
#   /usr/local/lib/alivaon-backup/verify.sh --read-data-subset 5%
#
# CODES DE SORTIE
#   0  dépôt sain, sauvegardes à jour
#   1  restic check en échec (dépôt endommagé ou inaccessible)
#   2  dépôt sain mais au moins un environnement sans sauvegarde récente
#
# shellcheck source-path=SCRIPTDIR
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

READ_SUBSET=''

usage() {
  cat <<'EOF'
Usage : verify.sh [--read-data-subset N%]

  --read-data-subset N%   relit aussi N % des données (téléchargement réel :
                          compter le trafic et la durée). Ex. 5%.
  -h, --help              cette aide.
EOF
}

# snapshot_age_hours ENV — âge en heures du dernier instantané planifié, ou
# chaîne vide s'il n'y en a aucun.
snapshot_age_hours() {
  local t epoch
  t=$(latest_snapshot_json "alivaon,env:$1,kind:scheduled" | jq -r 'if . == null then "" else .time end')
  [[ -n $t ]] || return 0
  # restic écrit des nanosecondes (…:02.123456789+02:00) : on les retire
  # avant de confier la date à GNU date.
  t=$(sed -E 's/\.[0-9]+//' <<<"$t")
  epoch=$(date -d "$t" +%s) || return 1
  printf '%s' "$((($(date +%s) - epoch) / 3600))"
}

main() {
  local check_rc=0 stale=0 env age
  local -a check_args=(check)

  while (($# > 0)); do
    case $1 in
      --read-data-subset)
        [[ ${2:-} =~ ^[0-9]{1,3}(\.[0-9]+)?%$ ]] || { usage; exit 1; }
        READ_SUBSET=$2
        shift 2
        ;;
      -h | --help) usage; exit 0 ;;
      *) usage; exit 1 ;;
    esac
  done

  require_root
  require_cmds restic jq
  load_config
  check_restic_version
  install -d -m 0700 -- "$RESTIC_CACHE_DIR"
  trap 'on_err $? $LINENO "$BASH_COMMAND"' ERR

  info "dépôt : $RESTIC_REPOSITORY"

  # 1. Intégrité
  if [[ -n $READ_SUBSET ]]; then
    check_args+=("--read-data-subset=$READ_SUBSET")
  fi
  info "restic $(join_by ' ' "${check_args[@]}")"
  rstc "${check_args[@]}" || check_rc=$?
  if ((check_rc == 0)); then
    info "intégrité : OK"
  else
    error "intégrité : restic check en ÉCHEC (code $check_rc)"
  fi

  # 2. Inventaire
  rstc snapshots --tag alivaon --compact || warn "inventaire des instantanés indisponible"

  # 3. Fraîcheur
  while IFS= read -r env; do
    if ! age=$(snapshot_age_hours "$env"); then
      error "fraîcheur [$env] : date du dernier instantané illisible"
      stale=1
    elif [[ -z $age ]]; then
      error "fraîcheur [$env] : AUCUN instantané planifié"
      stale=1
    elif ((age >= MAX_AGE_HOURS)); then
      error "fraîcheur [$env] : dernier instantané il y a ${age} h (seuil ${MAX_AGE_HOURS} h)"
      stale=1
    else
      info "fraîcheur [$env] : dernier instantané il y a ${age} h — OK"
    fi
  done < <(configured_envs)

  if ((check_rc != 0)); then
    error "BILAN : dépôt en échec"
    exit 1
  fi
  if ((stale)); then
    error "BILAN : dépôt sain, mais sauvegarde en retard ou absente"
    exit 2
  fi
  info "BILAN : dépôt sain, sauvegardes à jour"
}

main "$@"
