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
#   6. Le conteneur applicatif ne doit pas tourner pendant l'écriture : refus
#      s'il tourne, sauf --stop-app (voir ci-dessous).
#   7. Mode de restauration des fichiers OBLIGATOIRE dès qu'un volume est
#      restauré, sans valeur par défaut : --merge ou --mirror. En --mirror, le
#      nombre de fichiers qui seront supprimés est annoncé et doit être
#      confirmé par une seconde phrase tapée.
#   8. Espace disque : estimé depuis l'instantané, avec une marge
#      (RESTORE_SPACE_MARGIN_PERCENT), sur le système de fichiers du dossier de
#      travail et sur celui des volumes ; vérifié avant l'extraction, puis de
#      nouveau pour les volumes juste avant d'écrire.
#   9. Propriété et droits : le propriétaire des volumes dans l'instantané doit
#      être celui sous lequel l'application écrit (<ENV>_APP_OWNER), vérifié
#      AVANT l'écriture ; après l'écriture, propriétaire et droits de chaque
#      fichier restauré sont comparés à ceux de l'instantané.
#
# CE QUI EST ÉCRASÉ
#   db      la base est SUPPRIMÉE puis recréée depuis le dump (DROP DATABASE).
#   <rôle>  chaque volume (uploads, cv_private...) est synchronisé par rsync,
#           UID/GID numériques, droits, ACL et attributs étendus préservés
#           (-aHAX --numeric-ids, en root) :
#           --merge   les fichiers absents de l'instantané sont CONSERVÉS ;
#           --mirror  ils sont SUPPRIMÉS (état exact de l'instantané).
#
# CONTENEUR APPLICATIF
#   Aucune écriture n'a lieu pendant qu'il tourne : un téléversement concurrent
#   serait écrasé, ou produirait un état mêlant deux moments. S'il tourne,
#   restore.sh refuse, sauf --stop-app : il est alors arrêté juste avant
#   l'écriture, puis redémarré à la fin. Arrêté au départ, il reste arrêté dans
#   tous les cas. Le redémarrage passe par `docker start`, jamais `docker
#   compose up`, qui réinterpolerait les labels (piège STAGING_BASICAUTH,
#   README racine). Le conteneur MySQL, lui, n'est jamais arrêté : la base est
#   restaurée par import, à travers lui.
#
# EN CAS D'ÉCHEC : LE POINT DE BASCULE EST WRITE_STARTED
#   L'indicateur WRITE_STARTED est posé par begin_write, JUSTE AVANT la
#   première opération destructive de chaque cible (import de la base, rsync
#   d'un volume). Il n'est jamais déduit d'un code de sortie.
#   - Échec avant (validation, volume, espace disque, propriété, mode,
#     confirmation) : rien n'est écrit, le trap rend au conteneur applicatif
#     son état initial ; arrêté par --stop-app, il est redémarré.
#   - Échec après : la cible est dans un état intermédiaire, le conteneur
#     applicatif reste ARRÊTÉ, pour ne servir ni écrire aucune donnée
#     incohérente. Le journal donne la commande de retour arrière.
#
# UTILISATION (sur le VPS, en root, dans un terminal)
#   restore.sh --list [--target ENV]
#   restore.sh --target ENV --snapshot ID|latest --merge|--mirror [--stop-app]
#              [--only db,uploads,...] [--allow-production-to-staging]
#              [--no-safety-snapshot]
#
# CODES DE SORTIE
#   0  restauration terminée, conteneur applicatif dans son état initial
#   1  échec ou refus ; le journal dit si la cible a été modifiée ou non
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
STOP_APP=0
VOLUME_MODE='' # merge | mirror : jamais de valeur par défaut

CLEANUP_DIRS=()
WORK_DIR=''
PHASE='prepare' # prepare -> safety -> prepare -> write -> done
APP_CONTAINER=''
APP_OWNER=''
APP_STOPPED_BY_US=0
WRITE_STARTED=0 # posé par begin_write, juste avant la 1re opération destructive
DUMP_SIZE=0
FS_AVAIL=0 FS_MOUNT=''
SAFETY_ID=''
DEL_TOTAL=0

SNAP_ID='' SNAP_SHORT='' SNAP_TIME='' SNAP_HOST='' SNAP_ENV=''
SNAP_PATHS=()
M_FORMAT='' M_ENV='' M_DB_NAME='' M_DB_FILE=''
M_ROLES=()
declare -A M_VOL=() M_MP=() T_VOL=() T_MP=() DEL_FILES=() DEL_DIRS=() DATA_SIZE=()
T_DB_NAME='' T_DB_CONTAINER=''
COMPONENTS=()

usage() {
  cat <<'EOF'
Usage :
  restore.sh --list [--target production|staging]
  restore.sh --target production|staging --snapshot ID|latest
             --merge|--mirror [--stop-app] [options]

Mode de restauration des fichiers, OBLIGATOIRE dès qu'un volume est restauré :
  --merge                         conserve les fichiers de la cible absents de
                                  l'instantané (ceux présents des deux côtés
                                  sont remplacés par la version archivée).
  --mirror                        état exact de l'instantané : les fichiers
                                  absents de l'instantané sont SUPPRIMÉS. Leur
                                  nombre est annoncé et doit être confirmé.

Conteneur applicatif :
  --stop-app                      l'arrête juste avant l'écriture et le
                                  redémarre à la fin, ou après un échec
                                  survenu AVANT toute écriture. Après un échec
                                  en cours d'écriture, il reste arrêté. Sans
                                  cette option, restore.sh refuse de s'exécuter
                                  s'il tourne.

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
  # En premier : le conteneur applicatif. Aucune écriture entamée : il
  # retrouve son état initial (seul un conteneur arrêté PAR restore.sh est
  # redémarré). Écriture entamée : il reste arrêté, voir plus bas.
  if ((!WRITE_STARTED)); then
    restart_app || true
  fi
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
        error "restauration abandonnée AVANT toute écriture : la cible '$TARGET' n'a pas été modifiée ; le conteneur applicatif est dans son état initial."
        ;;
      safety)
        error "instantané de sécurité impossible : la cible '$TARGET' n'a pas été modifiée."
        error "si la base cible est absente ou vide (serveur reconstruit), relancer avec --no-safety-snapshot."
        ;;
      write)
        error "restauration interrompue PENDANT l'écriture : '$TARGET' est dans un état intermédiaire."
        error "le conteneur $APP_CONTAINER est laissé ARRÊTÉ à dessein : il servirait des pages cassées et pourrait écrire dans une base ou des volumes à moitié restaurés. NE PAS le démarrer avant d'avoir terminé ou annulé la restauration."
        error "terminer : corriger la cause, puis relancer la même commande restore.sh (la restauration est complète et rejouable)."
        if [[ -n $SAFETY_ID ]]; then
          error "ou annuler, retour à l'état précédent : restore.sh --target $TARGET --snapshot $SAFETY_ID --no-safety-snapshot --mirror"
        fi
        error "ensuite seulement : docker start $APP_CONTAINER"
        ;;
      *) ;;
    esac
  fi
  exit "$rc"
}

set_volume_mode() {
  [[ -z $VOLUME_MODE || $VOLUME_MODE == "$1" ]] ||
    die "--merge et --mirror s'excluent : choisir l'un des deux"
  VOLUME_MODE=$1
}

parse_args() {
  while (($# > 0)); do
    case $1 in
      --target) TARGET=${2:-}; shift 2 || { usage; exit 1; } ;;
      --snapshot) SNAPSHOT=${2:-}; shift 2 || { usage; exit 1; } ;;
      --only) ONLY=${2:-}; shift 2 || { usage; exit 1; } ;;
      --allow-production-to-staging) ALLOW_P2S=1; shift ;;
      --no-safety-snapshot) SAFETY=0; shift ;;
      --stop-app) STOP_APP=1; shift ;;
      --merge) set_volume_mode merge; shift ;;
      --mirror) set_volume_mode mirror; shift ;;
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
  APP_OWNER=$(env_get "$TARGET" APP_OWNER)
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

# ── Mode de restauration des fichiers ────────────────────────────────────────

check_volume_mode() {
  if has_volumes; then
    [[ -n $VOLUME_MODE ]] ||
      die "mode de restauration des fichiers non précisé. Choisir explicitement : --merge (conserve les fichiers de la cible absents de l'instantané) ou --mirror (état exact de l'instantané : ces fichiers sont SUPPRIMÉS). Aucun mode par défaut ; voir README, « Choisir le mode de restauration des fichiers »."
    info "mode de restauration des fichiers : --$VOLUME_MODE"
  elif [[ -n $VOLUME_MODE ]]; then
    warn "--$VOLUME_MODE sans effet : aucun volume à restaurer"
  fi
  return 0
}

# ── Conteneur applicatif ─────────────────────────────────────────────────────

# Avant la confirmation : refus s'il tourne sans --stop-app.
check_app_state() {
  if container_running "$APP_CONTAINER"; then
    ((STOP_APP)) ||
      die "le conteneur applicatif $APP_CONTAINER tourne. Écrire pendant qu'il fonctionne produirait un état mêlant deux moments, et pourrait écraser un téléversement en cours. Au choix : l'arrêter soi-même (docker stop $APP_CONTAINER), ou relancer avec --stop-app, qui l'arrête juste avant l'écriture et le redémarre à la fin (ou après un échec survenu avant toute écriture). Le conteneur MySQL $T_DB_CONTAINER, lui, doit rester démarré."
    info "$APP_CONTAINER tourne : il sera arrêté juste avant l'écriture, puis redémarré (--stop-app)"
  else
    info "$APP_CONTAINER est arrêté : il le restera après la restauration"
  fi
}

# Juste avant l'écriture. Le conteneur a pu démarrer depuis check_app_state.
stop_app_for_write() {
  container_running "$APP_CONTAINER" || return 0
  ((STOP_APP)) ||
    die "$APP_CONTAINER a démarré depuis la vérification : refus, aucune donnée n'a été modifiée"
  info "arrêt de $APP_CONTAINER (--stop-app)"
  docker stop "$APP_CONTAINER" >/dev/null
  APP_STOPPED_BY_US=1
}

# Ne redémarre QUE ce que restore.sh a arrêté. Appelé en fin de restauration, et
# par on_exit tant qu'aucune écriture n'a été entamée.
restart_app() {
  ((APP_STOPPED_BY_US)) || return 0
  info "redémarrage de $APP_CONTAINER (retour à l'état initial)"
  if docker start "$APP_CONTAINER" >/dev/null; then
    APP_STOPPED_BY_US=0
    return 0
  fi
  error "redémarrage de $APP_CONTAINER impossible : le démarrer à la main (docker start $APP_CONTAINER)"
  return 1
}

# begin_write DESCRIPTION — point de bascule, à appeler JUSTE AVANT chaque
# opération destructive (import de la base, rsync d'un volume). À partir de
# là, un échec laisse le conteneur applicatif arrêté (voir on_exit).
begin_write() {
  WRITE_STARTED=1
  PHASE='write'
  info "écriture entamée : $1"
}

# ── Contenu et métadonnées des volumes dans l'instantané ─────────────────────
#
# Pour chaque volume restauré, WORK_DIR/listing.<rôle> contient une ligne par
# entrée de l'instantané : « uid gid mode chemin_relatif », le chemin relatif
# de la racine du volume étant « . ». uid, gid et mode sont ceux enregistrés
# par restic au moment de la sauvegarde : c'est la référence de propriété et
# de droits.

# Filtre jq commun : les entrées de l'instantané sous le point de montage $mp.
# shellcheck disable=SC2016  # $mp est une variable jq (--arg), pas bash
readonly JQ_UNDER_MP='select((.struct_type // .message_type) == "node")
  | select(.path == $mp or (.path | startswith($mp + "/")))'

# Pour chaque volume : le listing, et DATA_SIZE[rôle], somme des tailles des
# fichiers du volume dans l'instantané (octets), base du contrôle d'espace.
load_listings() {
  local c json
  for c in "${COMPONENTS[@]}"; do
    [[ $c == db ]] && continue
    json=$WORK_DIR/ls.$c.json
    rstc ls --json "$SNAP_ID" "${M_MP[$c]}" >"$json"
    jq -r --arg mp "${M_MP[$c]}" "$JQ_UNDER_MP"'
      | "\(.uid) \(.gid) \(.mode) \(if .path == $mp then "." else .path[($mp | length) + 1:] end)"' \
      "$json" >"$WORK_DIR/listing.$c"
    [[ -s $WORK_DIR/listing.$c ]] || die "volume '$c' vide ou illisible dans l'instantané $SNAP_SHORT"
    DATA_SIZE[$c]=$(jq -s --arg mp "${M_MP[$c]}" \
      "[.[] | $JQ_UNDER_MP | select(.type == \"file\") | (.size // 0)] | add // 0" "$json")
  done
  return 0
}

# DUMP_SIZE : taille du dump SQL dans l'instantané (octets).
load_dump_size() {
  local path=$ALIVAON_DUMP_ROOT/$SNAP_ENV/$M_DB_FILE
  DUMP_SIZE=$(rstc ls --json "$SNAP_ID" "$path" |
    jq -s --arg p "$path" '[.[] | select((.struct_type // .message_type) == "node")
      | select(.path == $p and .type == "file") | (.size // 0)] | add // 0')
}

# perm_of MODE_RESTIC — droits Unix (octal, sans zéro initial, comme stat %a)
# d'un mode Go enregistré par restic. Les bits spéciaux y sont hors des 12 bits
# bas : setuid 1<<23, setgid 1<<22, sticky 1<<20.
perm_of() {
  local mode=$1 perm
  perm=$((mode & 8#777))
  if (((mode >> 23) & 1)); then perm=$((perm | 8#4000)); fi
  if (((mode >> 22) & 1)); then perm=$((perm | 8#2000)); fi
  if (((mode >> 20) & 1)); then perm=$((perm | 8#1000)); fi
  printf '%o' "$perm"
}

# AVANT l'écriture : la racine de chaque volume, dans l'instantané, doit
# appartenir à l'utilisateur sous lequel l'application écrit. Sinon la
# restauration paraîtrait réussie et le premier téléversement échouerait
# plus tard (typiquement : image applicative reconstruite avec un autre UID).
check_snapshot_owner() {
  local c uid gid mode rel
  for c in "${COMPONENTS[@]}"; do
    [[ $c == db ]] && continue
    while IFS=' ' read -r uid gid mode rel; do
      [[ $rel == . ]] || continue
      [[ $uid:$gid == "$APP_OWNER" ]] ||
        die "propriété incompatible : dans l'instantané, la racine du volume '$c' appartient à $uid:$gid, l'application écrit sous $APP_OWNER (${TARGET^^}_APP_OWNER). Restauré tel quel, le premier téléversement échouerait. Vérifier ${TARGET^^}_APP_OWNER (RUNBOOK-BACKUP.md, étape 2) ; aucune donnée n'a été modifiée."
    done <"$WORK_DIR/listing.$c"
  done
  return 0
}

# ── Fichiers qui seront supprimés en --mirror ────────────────────────────────

# deletion_plan RÔLE — chemins relatifs présents sur la cible et absents de
# l'instantané, c'est-à-dire exactement ce que rsync --delete supprimera.
deletion_plan() {
  local c=$1
  LC_ALL=C comm -13 \
    <(cut -d' ' -f4- "$WORK_DIR/listing.$c" | LC_ALL=C sort) \
    <(cd -- "${T_MP[$c]}" && find . -mindepth 1 | sed 's|^\./||' | LC_ALL=C sort)
}

count_deletions() {
  local c p files dirs
  DEL_TOTAL=0
  for c in "${COMPONENTS[@]}"; do
    [[ $c == db ]] && continue
    files=0
    dirs=0
    while IFS= read -r p; do
      if [[ -d ${T_MP[$c]}/$p && ! -L ${T_MP[$c]}/$p ]]; then
        dirs=$((dirs + 1))
      else
        files=$((files + 1))
      fi
    done < <(deletion_plan "$c")
    DEL_FILES[$c]=$files
    DEL_DIRS[$c]=$dirs
    DEL_TOTAL=$((DEL_TOTAL + files + dirs))
  done
  return 0
}

confirm_deletions() {
  local expected="SUPPRIMER $DEL_TOTAL" answer c
  printf '
'
  printf 'Mode --mirror : ce qui existe sur la cible et pas dans l'"'"'instantané sera SUPPRIMÉ.
'
  for c in "${COMPONENTS[@]}"; do
    [[ $c == db ]] && continue
    printf '  - %s : %s fichier(s) et %s dossier(s) à supprimer
' "$c" "${DEL_FILES[$c]}" "${DEL_DIRS[$c]}"
  done
  printf '  Total : %s entrée(s)

' "$DEL_TOTAL"
  printf 'Pour confirmer la suppression, tapez exactement :  %s
> ' "$expected"
  IFS= read -r answer || die "lecture de la confirmation de suppression impossible"
  [[ $answer == "$expected" ]] || die "confirmation de suppression incorrecte : aucune donnée n'a été modifiée"
  info "suppression de $DEL_TOTAL entrée(s) confirmée"
}

# ── Synchronisation et vérification d'un volume ──────────────────────────────

# Options rsync de restauration, en un seul endroit.
# -a : -rlptgoD, dont -o -g (propriétaire, groupe) et -p (droits) ;
# -H : liens physiques ; -A : ACL ; -X : attributs étendus, que restic capture
# et qu'un rsync sans ces options perdrait en silence ;
# --numeric-ids : UID/GID transmis tels quels, jamais traduits par nom (82 n'a
# pas de nom sur l'hôte). Exécuté en root, seul à pouvoir tout attribuer.
readonly RSYNC_OPTS=(-aHAX --numeric-ids)

# AVANT l'écriture : ce rsync sait-il traiter -A et -X ? Un rsync compilé sans
# ACL ni xattrs refuse l'option d'emblée : on le découvre ici, pas à mi-chemin.
check_rsync_capabilities() {
  local probe=$WORK_DIR/rsync-probe rc=0
  mkdir -p -- "$probe/src" "$probe/dst"
  rsync "${RSYNC_OPTS[@]}" --dry-run -- "$probe/src/" "$probe/dst/" 2>"$probe/err" || rc=$?
  if ((rc != 0)); then
    error "rsync : $(tr '\n' ' ' <"$probe/err")"
    die "le rsync de ce serveur ne prend pas en charge les ACL ou les attributs étendus (-A, -X) : les restaurer est impossible, et les perdre en silence est exclu. Aucune donnée n'a été modifiée."
  fi
  rm -rf -- "$probe"
}

sync_volume() {
  local c=$1 rc=0 err line
  local -a opts=("${RSYNC_OPTS[@]}")
  if [[ $VOLUME_MODE == mirror ]]; then
    opts+=(--delete)
  fi
  err=$WORK_DIR/rsync.$c.err
  info "synchronisation $c -> ${T_MP[$c]} (--$VOLUME_MODE)"
  begin_write "rsync du volume $c vers ${T_MP[$c]}"
  # Échec traité explicitement, sans compter sur set -e : la fonction reste
  # sûre quel que soit son contexte d'appel.
  rsync "${opts[@]}" -- "$WORK_DIR/files${M_MP[$c]}/" "${T_MP[$c]}/" 2>"$err" || rc=$?
  while IFS= read -r line; do
    warn "rsync : $line"
  done <"$err"
  ((rc == 0)) && return 0
  # Le système de fichiers cible refuse une ACL ou un attribut étendu présent
  # dans l'instantané : rsync signale « Operation not supported » sur
  # set_acl / lsetxattr. Diagnostic explicite plutôt qu'un code nu.
  if grep -Eiq 'acl|xattr|extended attribute' "$err" &&
    grep -Eiq 'not supported|does not support' "$err"; then
    die "le système de fichiers de ${T_MP[$c]} ne prend pas en charge les ACL ou attributs étendus présents dans l'instantané (rsync, code $rc) : restauration arrêtée plutôt que de les perdre en silence. Volume dans un état intermédiaire ; voir RUNBOOK-BACKUP.md, étape 2 (getfacl, getfattr)."
  fi
  die "rsync a échoué (code $rc) sur ${T_MP[$c]} : volume dans un état intermédiaire"
}

# APRÈS l'écriture : chaque entrée de l'instantané doit exister sur la cible
# avec le même propriétaire, le même groupe et les mêmes droits ; la racine du
# volume doit appartenir à l'utilisateur de l'application. En --merge, les
# fichiers propres à la cible ne sont pas examinés.
verify_volume() {
  local c=$1
  local dest=${T_MP[$c]} uid gid mode rel perm u g a name got want root line
  local -a errs=()
  local -A actual=()
  while IFS=' ' read -r u g a name; do
    name=${name#"$dest"}
    name=${name#/}
    actual[${name:-.}]="$u $g $a"
  done < <(find "$dest" -exec stat -c '%u %g %a %n' {} +)

  while IFS=' ' read -r uid gid mode rel; do
    perm=$(perm_of "$mode")
    want="$uid $gid $perm"
    got=${actual[$rel]:-absent}
    [[ $got == "$want" ]] || errs+=("$rel : attendu $uid:$gid $perm, obtenu ${got/ /:}")
  done <"$WORK_DIR/listing.$c"

  root=${actual[.]:-absente}
  if [[ ${root% *} != "${APP_OWNER/:/ }" ]]; then
    errs+=("racine du volume : ${root% *} au lieu de $APP_OWNER, l'utilisateur sous lequel l'application écrit")
  fi

  if ((${#errs[@]} > 0)); then
    error "volume '$c' : ${#errs[@]} écart(s) de propriété ou de droits après restauration :"
    printf '%s\n' "${errs[@]}" | head -n 10 | while IFS= read -r line; do error "  | $line"; done
    die "propriété ou droits incorrects sur ${T_MP[$c]} : les fichiers sont restaurés mais le premier téléversement risque d'échouer"
  fi
  info "volume '$c' : propriétaire, groupe et droits conformes à l'instantané ($(wc -l <"$WORK_DIR/listing.$c" | tr -d ' ') entrées)"
}

# ── Espace disque ────────────────────────────────────────────────────────────

# fs_measure CHEMIN — FS_AVAIL (octets libres) et FS_MOUNT (point de montage)
# du système de fichiers qui porte CHEMIN. Variables globales, pas de
# sous-shell : `die` doit interrompre le script.
fs_measure() {
  local line kb
  line=$(df -Pk -- "$1" | tail -n 1)
  IFS=' ' read -r _ _ _ kb _ FS_MOUNT <<<"$line"
  [[ $kb =~ ^[0-9]+$ && -n $FS_MOUNT ]] || die "espace libre illisible pour $1 (df : $line)"
  FS_AVAIL=$((kb * 1024))
}

human() { numfmt --to=iec --suffix=o "$1"; }

# check_space full|write
#   full   avant l'extraction : le dossier de travail reçoit le dump et les
#          fichiers des volumes (restic restore), puis chaque volume reçoit ses
#          fichiers (rsync). Deux besoins distincts ; sur un même système de
#          fichiers, ils s'additionnent : environ deux fois les données.
#   write  juste avant d'écrire, application arrêtée, extraction faite : seul
#          reste le besoin des volumes.
# Chaque besoin est majoré de RESTORE_SPACE_MARGIN_PERCENT. Refus chiffré au
# premier système de fichiers insuffisant.
check_space() {
  local mode=$1 c need fs req avail
  local -A fs_need=() fs_what=() fs_avail=()
  if [[ $mode == full ]]; then
    need=$DUMP_SIZE
    for c in "${COMPONENTS[@]}"; do
      [[ $c == db ]] || need=$((need + DATA_SIZE[$c]))
    done
    fs_measure "$WORK_DIR"
    fs_need[$FS_MOUNT]=$((${fs_need[$FS_MOUNT]:-0} + need))
    fs_what[$FS_MOUNT]+="dossier-de-travail "
    fs_avail[$FS_MOUNT]=$FS_AVAIL
  fi
  for c in "${COMPONENTS[@]}"; do
    [[ $c == db ]] && continue
    fs_measure "${T_MP[$c]}"
    fs_need[$FS_MOUNT]=$((${fs_need[$FS_MOUNT]:-0} + DATA_SIZE[$c]))
    fs_what[$FS_MOUNT]+="volume:$c "
    fs_avail[$FS_MOUNT]=$FS_AVAIL
  done
  for fs in "${!fs_need[@]}"; do
    need=${fs_need[$fs]}
    req=$(((need * (100 + RESTORE_SPACE_MARGIN_PERCENT) + 99) / 100))
    avail=${fs_avail[$fs]}
    if ((avail < req)); then
      die "espace disque insuffisant sur $fs (${fs_what[$fs]% }) : requis $req octets ($(human "$req"), dont marge de $RESTORE_SPACE_MARGIN_PERCENT %), disponible $avail octets ($(human "$avail")), manque $((req - avail)) octets ($(human $((req - avail))))"
    fi
    info "espace disque sur $fs (${fs_what[$fs]% }) : requis $(human "$req") marge comprise, disponible $(human "$avail")"
  done
  return 0
}

# ── Confirmation ─────────────────────────────────────────────────────────────

require_tty() {
  [[ -t 0 ]] || die "pas de terminal : restore.sh exige un opérateur pour confirmer l'écrasement"
}

confirm() {
  local expected="RESTAURER $TARGET $SNAP_SHORT" answer c
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
      if [[ $VOLUME_MODE == mirror ]]; then
        printf "    --mirror : %s fichier(s) et %s dossier(s) absents de l'instantané SUPPRIMÉS\n" "${DEL_FILES[$c]}" "${DEL_DIRS[$c]}"
      else
        printf "    --merge : fichiers absents de l'instantané CONSERVÉS\n"
      fi
    fi
  done
  if container_running "$APP_CONTAINER"; then
    printf "  Application: %s arrêtée pendant l'écriture, puis redémarrée\n" "$APP_CONTAINER"
  else
    printf '  Application: %s déjà arrêtée, le restera\n' "$APP_CONTAINER"
  fi
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
  local c confirmed=$DEL_TOTAL rc=0
  stop_app_for_write

  # Le décompte confirmé est celui qui sera supprimé. Recalculé une fois
  # l'application arrêtée : s'il a changé entre-temps (téléversement pendant
  # la confirmation), refus, sans rien écrire.
  if has_volumes && [[ $VOLUME_MODE == mirror ]]; then
    count_deletions
    ((DEL_TOTAL == confirmed)) ||
      die "le nombre de fichiers à supprimer est passé de $confirmed à $DEL_TOTAL depuis la confirmation : refus, aucune donnée n'a été modifiée"
  fi
  # Dernier contrôle d'espace, application arrêtée et extraction faite : son
  # échec est encore « avant écriture », l'application est donc redémarrée.
  check_space write

  for c in "${COMPONENTS[@]}"; do
    if [[ $c == db ]]; then
      info "import du dump dans $T_DB_CONTAINER (DROP puis CREATE DATABASE $T_DB_NAME)"
      begin_write "import de la base $T_DB_NAME dans $T_DB_CONTAINER"
      # Échec explicite, sans compter sur set -e (voir sync_volume).
      db_run "$TARGET" restore "$DB_IMPORT_SCRIPT" <"$WORK_DIR/db.sql" || rc=$?
      ((rc == 0)) || die "import de la base $T_DB_NAME a échoué (code $rc) : base dans un état intermédiaire"
    else
      sync_volume "$c"
      verify_volume "$c"
    fi
  done

  if ((APP_STOPPED_BY_US)); then
    restart_app
    wait_healthy "$APP_CONTAINER" 180 ||
      die "$APP_CONTAINER n'est pas « healthy » après 180 s : données restaurées, application à diagnostiquer (docker logs $APP_CONTAINER)"
  else
    info "$APP_CONTAINER était arrêté au départ : laissé arrêté (docker start $APP_CONTAINER pour le démarrer)"
  fi
  PHASE='done'
}

main() {
  parse_args "$@"
  require_root
  require_cmds docker restic jq rsync flock base64 numfmt df find comm stat
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
  check_volume_mode
  check_app_state
  load_listings
  if [[ " $(join_by ' ' "${COMPONENTS[@]}") " == *' db '* ]]; then
    load_dump_size
  fi
  check_snapshot_owner
  if has_volumes && [[ $VOLUME_MODE == mirror ]]; then
    count_deletions
  fi
  check_space full
  if has_volumes; then
    check_rsync_capabilities
  fi
  require_tty
  confirm
  if has_volumes && [[ $VOLUME_MODE == mirror ]]; then
    confirm_deletions
  fi

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
