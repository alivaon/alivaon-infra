#!/usr/bin/env bash
#
# Restauration d'un instantané restic vers la production ou le staging.
#
# GARDE-FOUS, dans l'ordre où ils s'appliquent
#   1. L'environnement d'origine est lu dans l'étiquette env:* de l'instantané
#      ET dans son manifeste ; les deux doivent concorder.
#   2. staging -> production : REFUSÉ, sans option pour lever le refus.
#      production -> staging : refusé sauf --allow-production-to-staging.
#   3. Tout est vérifié puis extrait dans un dossier de travail AVANT la
#      moindre écriture : un instantané illisible ou un dump tronqué ne touche
#      jamais la cible.
#   4. Confirmation interactive : l'opérateur doit retaper une phrase qui
#      contient la cible et l'identifiant de l'instantané. Pas de mode forcé.
#   5. L'état courant de la cible est archivé (kind:pre-restore) juste avant
#      l'écrasement, sauf --no-safety-snapshot.
#
# CE QUI EST ÉCRASÉ
#   db      la base est SUPPRIMÉE puis recréée depuis le dump (DROP DATABASE).
#   <rôle>  chaque volume (uploads, cv_private...) est synchronisé avec
#           rsync --delete : les fichiers absents de l'instantané disparaissent.
#   Le conteneur applicatif est arrêté pendant l'écriture, puis redémarré par
#   `docker start` — jamais `docker compose up`, qui réinterpolerait les labels
#   (voir le piège STAGING_BASICAUTH dans le README racine).
#
# UTILISATION (sur le VPS, en root, dans un terminal)
#   restore.sh --list [--target ENV]
#   restore.sh --target ENV --snapshot ID|latest [--only db,uploads,...]
#              [--allow-production-to-staging] [--no-safety-snapshot]
#
# CODES DE SORTIE
#   0  restauration terminée, application redémarrée
#   1  échec ; le journal dit si la cible a été modifiée ou non
#   3  refus de sécurité (environnements incompatibles)
#
# shellcheck source-path=SCRIPTDIR
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

TARGET=''
SNAPSHOT=''
ONLY=''
ALLOW_P2S=0
SAFETY=1
LIST=0

CLEANUP_DIRS=()
WORK_DIR=''
PHASE='prepare' # prepare -> safety -> prepare -> write -> done
APP_CONTAINER=''
APP_STOPPED=0
SAFETY_ID=''

SNAP_ID='' SNAP_SHORT='' SNAP_TIME='' SNAP_HOST='' SNAP_ENV=''
SNAP_PATHS=()
M_FORMAT='' M_ENV='' M_DB_NAME='' M_DB_FILE=''
M_ROLES=()
declare -A M_VOL=() M_MP=() T_VOL=() T_MP=()
T_DB_NAME='' T_DB_CONTAINER=''
COMPONENTS=()

usage() {
  cat <<'EOF'
Usage :
  restore.sh --list [--target production|staging]
  restore.sh --target production|staging --snapshot ID|latest [options]

Options :
  --only LISTE                    composants à restaurer, séparés par des
                                  virgules : db, et les rôles de volumes
                                  (uploads, cv_private...). Défaut : tout.
  --allow-production-to-staging   autorise un instantané de PRODUCTION vers
                                  le staging. Copie des données personnelles
                                  en préprod : à réserver aux cas justifiés.
  --no-safety-snapshot            ne pas archiver l'état courant de la cible
                                  avant écrasement (cible vide ou base absente,
                                  typiquement après perte du serveur).
  -h, --help                      cette aide.

« latest » désigne le dernier instantané planifié (kind:scheduled) de
l'environnement cible, ou de la production avec --allow-production-to-staging.

Un instantané de staging n'est JAMAIS restauré en production.
EOF
}

on_exit() {
  local rc=$?
  local d
  for d in "${CLEANUP_DIRS[@]}"; do
    rm -rf -- "$d"
  done
  # Le dossier de travail contient le dump en clair (données personnelles).
  if [[ -n $WORK_DIR ]]; then
    rm -rf -- "$WORK_DIR"
  fi

  if ((rc != 0)); then
    case $PHASE in
      prepare)
        error "restauration abandonnée AVANT toute écriture : la cible '$TARGET' n'a pas été modifiée."
        ;;
      safety)
        error "instantané de sécurité impossible : la cible '$TARGET' n'a pas été modifiée."
        error "si la base cible est absente ou vide (serveur reconstruit), relancer avec --no-safety-snapshot."
        ;;
      write)
        error "restauration interrompue PENDANT l'écriture : '$TARGET' est dans un état intermédiaire."
        if ((APP_STOPPED)); then
          error "le conteneur $APP_CONTAINER est laissé ARRÊTÉ à dessein, pour qu'aucune écriture n'ait lieu sur une base incohérente."
        fi
        if [[ -n $SAFETY_ID ]]; then
          error "retour à l'état précédent : restore.sh --target $TARGET --snapshot $SAFETY_ID --no-safety-snapshot"
        fi
        ;;
      *) ;;
    esac
  fi
  exit "$rc"
}

parse_args() {
  while (($# > 0)); do
    case $1 in
      --target) TARGET=${2:-}; shift 2 || { usage; exit 1; } ;;
      --snapshot) SNAPSHOT=${2:-}; shift 2 || { usage; exit 1; } ;;
      --only) ONLY=${2:-}; shift 2 || { usage; exit 1; } ;;
      --allow-production-to-staging) ALLOW_P2S=1; shift ;;
      --no-safety-snapshot) SAFETY=0; shift ;;
      --list) LIST=1; shift ;;
      -h | --help) usage; exit 0 ;;
      *) usage; exit 1 ;;
    esac
  done
  if [[ -n $TARGET ]]; then
    is_known_env "$TARGET" || die "cible inconnue : '$TARGET' (production ou staging)"
  fi
  if ((!LIST)); then
    [[ -n $TARGET && -n $SNAPSHOT ]] || { usage; exit 1; }
    [[ $SNAPSHOT == latest || $SNAPSHOT =~ ^[0-9a-f]{8,64}$ ]] ||
      die "identifiant d'instantané invalide : '$SNAPSHOT'"
  fi
}

# ── Instantané et politique d'environnement ──────────────────────────────────

resolve_snapshot() {
  local json source_env
  local -a env_tags
  if [[ $SNAPSHOT == latest ]]; then
    source_env=$TARGET
    if ((ALLOW_P2S)) && [[ $TARGET == staging ]]; then
      source_env=production
    fi
    json=$(latest_snapshot_json "alivaon,env:$source_env,kind:scheduled")
  else
    json=$(rstc snapshots --json "$SNAPSHOT" | jq -c '.[0] // null')
  fi
  [[ -n $json && $json != null ]] || die "instantané introuvable : $SNAPSHOT"

  SNAP_ID=$(jq -r '.id' <<<"$json")
  SNAP_SHORT=$(jq -r '.short_id' <<<"$json")
  SNAP_TIME=$(jq -r '.time' <<<"$json")
  SNAP_HOST=$(jq -r '.hostname' <<<"$json")
  mapfile -t SNAP_PATHS < <(jq -r '.paths[]' <<<"$json")
  mapfile -t env_tags < <(jq -r '(.tags // [])[] | select(startswith("env:")) | ltrimstr("env:")' <<<"$json")
  ((${#env_tags[@]} == 1)) ||
    die "l'instantané $SNAP_SHORT ne porte pas exactement une étiquette env:* : restauration refusée" 3
  SNAP_ENV=${env_tags[0]}
}

check_env_policy() {
  if [[ $SNAP_ENV == "$TARGET" ]]; then
    return 0
  fi
  if [[ $SNAP_ENV == staging && $TARGET == production ]]; then
    die "REFUS : l'instantané $SNAP_SHORT provient du STAGING. Il ne sera jamais restauré en PRODUCTION, et aucune option ne lève ce refus." 3
  fi
  if [[ $SNAP_ENV == production && $TARGET == staging ]]; then
    ((ALLOW_P2S)) ||
      die "REFUS : l'instantané $SNAP_SHORT provient de la PRODUCTION, la cible est le staging. Si c'est délibéré, relancer avec --allow-production-to-staging." 3
    warn "restauration CROISÉE production -> staging, autorisée explicitement : des données personnelles de production vont être copiées en préprod"
    return 0
  fi
  die "REFUS : instantané de '$SNAP_ENV' incompatible avec la cible '$TARGET'" 3
}

load_manifest() {
  local file=$WORK_DIR/manifest key a b c role p found
  rstc dump "$SNAP_ID" "$ALIVAON_DUMP_ROOT/$SNAP_ENV/manifest" >"$file" ||
    die "manifeste absent de l'instantané $SNAP_SHORT : il n'a pas été produit par backup.sh"

  while IFS=' ' read -r key a b c; do
    case $key in
      format) M_FORMAT=$a ;;
      env) M_ENV=$a ;;
      database)
        M_DB_NAME=$a
        M_DB_FILE=$b
        ;;
      volume)
        M_ROLES+=("$a")
        M_VOL[$a]=$b
        M_MP[$a]=$c
        ;;
      *) ;; # clé inconnue (format futur, ligne vide) : ignorée
    esac
  done <"$file"

  [[ $M_FORMAT == "$ALIVAON_MANIFEST_FORMAT" ]] ||
    die "format de manifeste '$M_FORMAT' non pris en charge (attendu : $ALIVAON_MANIFEST_FORMAT)"
  [[ $M_ENV == "$SNAP_ENV" ]] ||
    die "INCOHÉRENCE : étiquette env:$SNAP_ENV mais manifeste '$M_ENV' — restauration refusée" 3
  [[ $M_DB_FILE =~ ^[A-Za-z0-9_.-]+$ ]] || die "nom de dump invalide dans le manifeste : '$M_DB_FILE'"

  # Chaque volume déclaré doit réellement figurer dans l'instantané.
  for role in "${M_ROLES[@]}"; do
    found=0
    for p in "${SNAP_PATHS[@]}"; do
      [[ $p == "${M_MP[$role]}" ]] && found=1
    done
    ((found)) || die "le manifeste cite ${M_MP[$role]}, absent des chemins de l'instantané"
  done
}

# ── Cible ────────────────────────────────────────────────────────────────────

load_target() {
  local spec
  local -a specs
  configured_envs | grep -qx -- "$TARGET" ||
    die "la cible '$TARGET' n'est pas dans BACKUP_ENVIRONMENTS : sa configuration est absente"
  T_DB_NAME=$(env_get "$TARGET" DB_NAME)
  T_DB_CONTAINER=$(env_get "$TARGET" DB_CONTAINER)
  APP_CONTAINER=$(env_get "$TARGET" APP_CONTAINER)
  IFS=' ' read -r -a specs <<<"$(env_get "$TARGET" VOLUMES)"
  for spec in "${specs[@]}"; do
    T_VOL[${spec%%=*}]=${spec#*=}
  done
  docker inspect "$APP_CONTAINER" >/dev/null 2>&1 ||
    die "conteneur applicatif $APP_CONTAINER absent : démarrer la stack '$TARGET' une première fois (docker compose up -d)"
}

select_components() {
  local c r
  if [[ -z $ONLY ]]; then
    COMPONENTS=(db "${M_ROLES[@]}")
  else
    IFS=',' read -r -a COMPONENTS <<<"$ONLY"
  fi
  ((${#COMPONENTS[@]} > 0)) || die "aucun composant à restaurer"

  for c in "${COMPONENTS[@]}"; do
    if [[ $c == db ]]; then
      # Le dump contient CREATE DATABASE <nom d'origine> : un nom différent
      # recréerait une base que l'application ne lit pas.
      [[ $M_DB_NAME == "$T_DB_NAME" ]] ||
        die "base '$M_DB_NAME' dans l'instantané, '$T_DB_NAME' sur la cible : refus"
      container_running "$T_DB_CONTAINER" || die "conteneur MySQL cible $T_DB_CONTAINER arrêté ou absent"
      db_run "$TARGET" restore "$DB_PING_SCRIPT" </dev/null ||
        die "connexion MySQL impossible dans $T_DB_CONTAINER avec ${TARGET^^}_DB_USER : vérifier les identifiants"
    else
      [[ -n ${M_MP[$c]:-} ]] ||
        die "composant '$c' absent de l'instantané (disponibles : db $(join_by ' ' "${M_ROLES[@]}"))"
      [[ -n ${T_VOL[$c]:-} ]] || die "rôle '$c' sans volume cible dans ${TARGET^^}_VOLUMES"
      resolve_volume "${T_VOL[$c]}" "démarrer la stack '$TARGET' une première fois pour le créer"
      T_MP[$c]=$VOLUME_MOUNTPOINT
    fi
  done

  for r in "${!T_VOL[@]}"; do
    [[ -n ${M_MP[$r]:-} ]] || warn "le volume '$r' de la cible n'est pas dans l'instantané : il reste inchangé"
  done
}

has_volumes() {
  local c
  for c in "${COMPONENTS[@]}"; do
    [[ $c == db ]] || return 0
  done
  return 1
}

check_space() {
  local need avail
  has_volumes || return 0
  need=$(rstc stats --json --mode restore-size "$SNAP_ID" | jq -r '.total_size')
  avail=$(df --output=avail -B1 -- "$ALIVAON_STATE_DIR" | tail -n 1 | tr -d ' ')
  info "espace requis (majorant) : $(numfmt --to=iec --suffix=o "$need") — disponible : $(numfmt --to=iec --suffix=o "$avail")"
  ((avail > need + need / 10)) ||
    die "espace disque insuffisant dans $ALIVAON_STATE_DIR pour extraire l'instantané"
}

# ── Confirmation ─────────────────────────────────────────────────────────────

confirm() {
  local expected="RESTAURER $TARGET $SNAP_SHORT" answer c
  [[ -t 0 ]] || die "pas de terminal : restore.sh exige un opérateur pour confirmer l'écrasement"

  printf '\n'
  printf '══════════════════════════════════════════════════════════════════\n'
  printf '  RESTAURATION — LES DONNÉES DE LA CIBLE VONT ÊTRE ÉCRASÉES\n'
  printf '══════════════════════════════════════════════════════════════════\n'
  printf '  Instantané : %s  (%s, %s, hôte %s)\n' "$SNAP_SHORT" "$SNAP_ENV" "$SNAP_TIME" "$SNAP_HOST"
  printf '  Cible      : %s\n' "${TARGET^^}"
  for c in "${COMPONENTS[@]}"; do
    if [[ $c == db ]]; then
      printf '  - base %s dans %s : SUPPRIMÉE puis recréée\n' "$T_DB_NAME" "$T_DB_CONTAINER"
    else
      printf '  - %s : %s (instantané) -> volume %s (%s)\n' "$c" "${M_VOL[$c]}" "${T_VOL[$c]}" "${T_MP[$c]}"
      printf "    synchronisé, fichiers absents de l'instantané SUPPRIMÉS\n"
    fi
  done
  printf "  Application: %s arrêtée pendant l'opération\n" "$APP_CONTAINER"
  if ((SAFETY)); then
    printf '  Filet      : état actuel archivé (kind:pre-restore) avant écrasement\n'
  else
    printf '  Filet      : AUCUN (--no-safety-snapshot)\n'
  fi
  printf '══════════════════════════════════════════════════════════════════\n\n'
  printf 'Pour confirmer, tapez exactement :  %s\n> ' "$expected"

  IFS= read -r answer || die "lecture de la confirmation impossible"
  [[ $answer == "$expected" ]] || die "confirmation incorrecte"
  info "confirmation reçue"
}

# ── Étapes ───────────────────────────────────────────────────────────────────

safety_snapshot() {
  if ((!SAFETY)); then
    warn "instantané de sécurité désactivé (--no-safety-snapshot)"
    return 0
  fi
  info "archivage de l'état actuel de '$TARGET' avant écrasement"
  # Appel direct, surtout pas `(backup_env ...) || die` : dans une liste ||,
  # bash désactive set -e pour toute la fonction appelée. Un échec est
  # expliqué par on_exit grâce à la phase « safety ».
  PHASE='safety'
  backup_env "$TARGET" pre-restore
  PHASE='prepare'
  SAFETY_ID=$(latest_snapshot_json "alivaon,env:$TARGET,kind:pre-restore" | jq -r '.short_id')
  info "instantané de sécurité : $SAFETY_ID"
}

extract() {
  local c
  local -a args
  if [[ " $(join_by ' ' "${COMPONENTS[@]}") " == *' db '* ]]; then
    info "extraction du dump $M_DB_FILE"
    rstc dump "$SNAP_ID" "$ALIVAON_DUMP_ROOT/$SNAP_ENV/$M_DB_FILE" >"$WORK_DIR/db.sql"
    check_dump "$WORK_DIR/db.sql"
  fi
  if has_volumes; then
    args=(restore "$SNAP_ID" --target "$WORK_DIR/files")
    for c in "${COMPONENTS[@]}"; do
      [[ $c == db ]] || args+=(--include "${M_MP[$c]}")
    done
    info "extraction des fichiers dans $WORK_DIR/files"
    rstc "${args[@]}"
    for c in "${COMPONENTS[@]}"; do
      [[ $c == db || -d $WORK_DIR/files${M_MP[$c]} ]] ||
        die "extraction incomplète : $WORK_DIR/files${M_MP[$c]} absent"
    done
  fi
}

write_target() {
  local c
  PHASE='write'

  if container_running "$APP_CONTAINER"; then
    info "arrêt de $APP_CONTAINER"
    docker stop "$APP_CONTAINER" >/dev/null
    APP_STOPPED=1
  fi

  for c in "${COMPONENTS[@]}"; do
    if [[ $c == db ]]; then
      info "import du dump dans $T_DB_CONTAINER (DROP puis CREATE DATABASE $T_DB_NAME)"
      db_run "$TARGET" restore "$DB_IMPORT_SCRIPT" <"$WORK_DIR/db.sql"
    else
      info "synchronisation $c -> ${T_MP[$c]}"
      rsync -aH --numeric-ids --delete -- "$WORK_DIR/files${M_MP[$c]}/" "${T_MP[$c]}/"
    fi
  done

  info "démarrage de $APP_CONTAINER"
  docker start "$APP_CONTAINER" >/dev/null
  APP_STOPPED=0
  wait_healthy "$APP_CONTAINER" 180 ||
    die "$APP_CONTAINER n'est pas « healthy » après 180 s : données restaurées, application à diagnostiquer (docker logs $APP_CONTAINER)"
  PHASE='done'
}

main() {
  parse_args "$@"
  require_root
  require_cmds docker restic jq rsync flock base64 numfmt df
  load_config
  check_restic_version

  if ((LIST)); then
    rstc snapshots --tag "alivaon${TARGET:+,env:$TARGET}"
    exit 0
  fi

  acquire_lock
  trap on_exit EXIT
  trap 'on_err $? $LINENO "$BASH_COMMAND"' ERR
  trap 'exit 130' INT
  trap 'exit 143' TERM

  install -d -m 0700 -- "$ALIVAON_STATE_DIR" "$ALIVAON_RESTORE_ROOT" "$RESTIC_CACHE_DIR"
  WORK_DIR=$(mktemp -d -p "$ALIVAON_RESTORE_ROOT" "$TARGET.XXXXXX")

  check_repository
  resolve_snapshot
  info "instantané $SNAP_SHORT : env $SNAP_ENV, $SNAP_TIME, hôte $SNAP_HOST"
  check_env_policy
  load_manifest
  load_target
  select_components
  check_space
  confirm

  safety_snapshot
  extract
  write_target

  info "restauration terminée : $TARGET <- $SNAP_SHORT ($SNAP_ENV, $SNAP_TIME)"
  if [[ -n $SAFETY_ID ]]; then
    info "état antérieur conservé dans l'instantané $SAFETY_ID"
  fi
  if [[ $TARGET == staging ]]; then
    info "contrôle à faire depuis le Mac : ./scripts/check-staging-auth.sh (401 attendu)"
  fi
  info "si l'image applicative est plus récente que l'instantané : docker exec $APP_CONTAINER php bin/console doctrine:migrations:status"
}

main "$@"
