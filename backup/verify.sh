#!/usr/bin/env bash
#
# Contrôle de santé du dépôt restic — lecture seule, relançable à volonté.
#
#   1. restic check : intégrité de la structure du dépôt (index, arbres).
#      Seul, il ne lit AUCUNE donnée : un bloc corrompu sur le stockage passe
#      inaperçu. D'où deux modes de relecture des données :
#        --read-data-rotation   relit 1/8 du dépôt, une fraction différente
#                               chaque semaine ISO : le dépôt entier est relu
#                               en huit semaines. Mode du timer hebdomadaire
#                               alivaon-backup-verify.timer ;
#        --read-data-subset N%  relit un échantillon aléatoire, à la main.
#   2. restic snapshots : inventaire affiché.
#   3. Fraîcheur : pour chaque environnement de BACKUP_ENVIRONMENTS, le dernier
#      instantané planifié doit dater de moins de MAX_AGE_HOURS (48 h).
#
# Toutes les étapes s'exécutent même si l'une échoue : le bilan final les
# résume toutes.
#
# UTILISATION (sur le VPS, en root)
#   /usr/local/lib/alivaon-backup/verify.sh                        contrôle rapide
#   /usr/local/lib/alivaon-backup/verify.sh --read-data-rotation   hebdomadaire
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
READ_ROTATION=0

usage() {
  cat <<'EOF'
Usage : verify.sh [--read-data-rotation | --read-data-subset N%]

  (sans option)           contrôle rapide : structure, inventaire, fraîcheur.
  --read-data-rotation    relit en plus la fraction k/8 du dépôt, k dépendant
                          de la semaine ISO : tout le dépôt en huit semaines.
                          C'est le mode du timer hebdomadaire.
  --read-data-subset N%   relit en plus N % des données, tirés au hasard.
  -h, --help              cette aide.

La relecture télécharge réellement les données : compter trafic et durée.
EOF
}

# read_data_slice EPOCH — fraction « k/8 » à relire la semaine contenant EPOCH.
#
# k suit un compteur de semaines ISO CONTINU : semaines écoulées depuis le
# lundi 29 décembre 1969 (le 1er janvier 1970 était un jeudi, d'où le +3 en
# jours). `date +%V` ne convient pas : il repasse à 1 au changement d'année
# après 52 ou 53 semaines, et la rotation sauterait ou répéterait des
# fractions fin décembre. Ici, deux semaines consécutives donnent toujours deux
# fractions consécutives (modulo 8), et huit semaines consécutives les
# couvrent toutes. Calcul en jours UTC : le timer s'exécute le dimanche en
# fin de matinée, loin de minuit dans les deux fuseaux.
read_data_slice() {
  local days=$(($1 / 86400))
  printf '%s/8' "$((((days + 3) / 7) % 8 + 1))"
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
      --read-data-rotation)
        READ_ROTATION=1
        shift
        ;;
      -h | --help) usage; exit 0 ;;
      *) usage; exit 1 ;;
    esac
  done

  if ((READ_ROTATION)) && [[ -n $READ_SUBSET ]]; then
    die "--read-data-rotation et --read-data-subset s'excluent"
  fi
  if ((READ_ROTATION)); then
    READ_SUBSET=$(read_data_slice "$(date +%s)")
  fi

  require_root
  require_cmds restic jq
  load_config
  check_restic_version
  install -d -m 0700 -- "$RESTIC_CACHE_DIR"
  trap 'on_err $? $LINENO "$BASH_COMMAND"' ERR

  info "dépôt : $RESTIC_REPOSITORY"
  if ((READ_ROTATION)); then
    info "relecture tournante : fraction $READ_SUBSET (semaine ISO $(date +%G-W%V))"
  fi

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
