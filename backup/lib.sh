# shellcheck shell=bash
#
# Bibliothèque commune de backup.sh, restore.sh, verify.sh, restic.sh et
# notify-failure.sh. Elle est SOURCÉE, jamais exécutée : son chargement ne fait
# que définir des constantes et des fonctions, sans aucun effet de bord.
#
# Prérequis : bash >= 4.3 (tableaux associatifs, ${var^^}). Ubuntu : bash 5.
#

# ── Constantes ───────────────────────────────────────────────────────────────
#
# ALIVAON_STATE_DIR est FIGÉ, volontairement non configurable : les dumps y
# sont écrits avant `restic backup`, donc leur chemin absolu est inscrit dans
# chaque instantané. restore.sh retrouve le manifeste d'un instantané par ce
# chemin. Le changer rendrait les instantanés existants illisibles par
# restore.sh (restic, lui, les lirait toujours).
# shellcheck disable=SC2034  # constantes partagées, utilisées par les scripts appelants
readonly ALIVAON_STATE_DIR=/var/lib/alivaon-backup
readonly ALIVAON_DUMP_ROOT=$ALIVAON_STATE_DIR/dumps
readonly ALIVAON_RESTORE_ROOT=$ALIVAON_STATE_DIR/restore
readonly ALIVAON_LOCK_FILE=/run/alivaon-backup.lock
readonly ALIVAON_DEFAULT_CONFIG=/etc/alivaon-backup/backup.env
readonly ALIVAON_DEFAULT_CACHE=/var/cache/alivaon-backup
readonly ALIVAON_MANIFEST_FORMAT=1
# 0.16 : --retry-lock, et dépôt au format v2 (compression) par défaut.
readonly ALIVAON_RESTIC_MIN_VERSION=0.16.0
# Seuls noms d'environnement admis. restore.sh fonde son refus de restaurer un
# environnement dans un autre sur ces noms : ne pas en inventer d'autres.
readonly ALIVAON_KNOWN_ENVS=(production staging)

# ── Journalisation ───────────────────────────────────────────────────────────
#
# Tout va sur stdout, horodaté. Sous systemd (JOURNAL_STREAM défini), chaque
# ligne est préfixée de sa priorité syslog au format <N> : journald la retire
# et classe la ligne (journalctl -p err n'affiche alors que les erreurs).

log() {
  local level=$1 prefix=''
  shift
  if [[ -n ${JOURNAL_STREAM:-} ]]; then
    case $level in
      ERREUR) prefix='<3>' ;;
      ALERTE) prefix='<4>' ;;
      *) prefix='<6>' ;;
    esac
  fi
  printf '%s%s [%s] %s\n' "$prefix" "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$level" "$*"
}

info() { log INFO "$@"; }
warn() { log ALERTE "$@"; }
error() { log ERREUR "$@"; }

# die MESSAGE [CODE] — journalise et quitte (code 1 par défaut).
die() {
  error "$1"
  exit "${2:-1}"
}

# Trace la commande fautive. À installer avec :
#   trap 'on_err $? $LINENO "$BASH_COMMAND"' ERR
on_err() {
  error "échec (code $1) ligne $2 : $3"
}

# ── Prérequis ────────────────────────────────────────────────────────────────

require_root() {
  [[ $EUID -eq 0 ]] || die "à lancer en root (sudo) : volumes Docker et configuration ne sont lisibles que par root."
}

require_cmds() {
  local c
  local -a missing=()
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if ((${#missing[@]} > 0)); then
    die "commande(s) introuvable(s) : $(join_by ' ' "${missing[@]}")"
  fi
}

# join_by SÉPARATEUR ÉLÉMENT... — indépendant de la valeur courante d'IFS.
join_by() {
  local sep=$1 out=''
  shift
  local item
  for item in "$@"; do
    out+=${out:+$sep}$item
  done
  printf '%s' "$out"
}

# version_ge A B — vrai si la version A >= B.
version_ge() {
  [[ $(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n 1) == "$2" ]]
}

check_restic_version() {
  local out ver
  out=$(restic version) || die "restic ne répond pas"
  IFS=' ' read -r _ ver _ <<<"$out"
  version_ge "$ver" "$ALIVAON_RESTIC_MIN_VERSION" ||
    die "restic $ver trop ancien (minimum $ALIVAON_RESTIC_MIN_VERSION) : voir RUNBOOK-BACKUP.md, étape 4."
}

# ── Configuration ────────────────────────────────────────────────────────────

# secure_file FICHIER DESCRIPTION — le fichier doit exister, appartenir à root
# et n'être accessible à personne d'autre.
secure_file() {
  local file=$1 what=$2 owner mode
  [[ -f $file ]] || die "$what absent : $file"
  owner=$(stat -c '%u' -- "$file")
  mode=$(stat -c '%a' -- "$file")
  [[ $owner == 0 ]] || die "$what doit appartenir à root : $file (uid $owner)"
  ((8#$mode & 8#077)) && die "$what accessible à d'autres que root : $file (mode $mode, attendu 600 ou 400)"
  return 0
}

# Charge le fichier de configuration puis le valide. Le fichier est sourcé :
# c'est pourquoi il doit appartenir à root et n'être modifiable par personne
# d'autre (vérifié avant lecture).
load_config() {
  local file=${ALIVAON_BACKUP_CONFIG:-$ALIVAON_DEFAULT_CONFIG}
  secure_file "$file" "fichier de configuration"
  set -a
  # shellcheck source=/dev/null
  . "$file"
  set +a
  validate_config
}

is_known_env() {
  local e
  for e in "${ALIVAON_KNOWN_ENVS[@]}"; do
    [[ $1 == "$e" ]] && return 0
  done
  return 1
}

# env_get ENV CLÉ — valeur de la variable <ENV>_<CLÉ> (ex. PRODUCTION_DB_NAME).
# Ne meurt jamais : la présence de chaque variable est garantie par
# validate_config, appelé avant tout usage.
env_get() {
  local var="${1^^}_$2"
  printf '%s' "${!var:-}"
}

# shellcheck disable=SC2154  # RESTIC_* proviennent du fichier de configuration sourcé
validate_config() {
  local v env spec
  local -a envs specs

  for v in RESTIC_REPOSITORY RESTIC_PASSWORD_FILE; do
    [[ -n ${!v:-} ]] || die "variable $v manquante ou vide dans la configuration"
  done
  secure_file "$RESTIC_PASSWORD_FILE" "fichier de mot de passe restic"

  : "${RESTIC_HOST:=alivaon-vps}"
  : "${BACKUP_ENVIRONMENTS:=production staging}"
  : "${KEEP_DAILY:=7}"
  : "${KEEP_WEEKLY:=4}"
  : "${KEEP_MONTHLY:=6}"
  : "${MAX_AGE_HOURS:=48}"
  : "${HC_PING_URL:=}"
  : "${RESTIC_EXCLUDE_FILE:=}"
  : "${RESTIC_CACHE_DIR:=$ALIVAON_DEFAULT_CACHE}"
  : "${RESTORE_SPACE_MARGIN_PERCENT:=20}"
  export RESTIC_CACHE_DIR

  for v in KEEP_DAILY KEEP_WEEKLY KEEP_MONTHLY MAX_AGE_HOURS; do
    [[ ${!v} =~ ^[1-9][0-9]*$ ]] || die "$v doit être un entier positif (valeur : '${!v}')"
  done
  [[ $RESTORE_SPACE_MARGIN_PERCENT =~ ^[0-9]+$ ]] ||
    die "RESTORE_SPACE_MARGIN_PERCENT doit être un entier positif ou nul (valeur : '$RESTORE_SPACE_MARGIN_PERCENT')"
  [[ -z $HC_PING_URL || $HC_PING_URL == https://* ]] ||
    die "HC_PING_URL doit commencer par https:// (ou rester vide pour désactiver)"
  [[ -z $RESTIC_EXCLUDE_FILE || -f $RESTIC_EXCLUDE_FILE ]] ||
    die "RESTIC_EXCLUDE_FILE pointe vers un fichier absent : $RESTIC_EXCLUDE_FILE"

  IFS=' ' read -r -a envs <<<"$BACKUP_ENVIRONMENTS"
  ((${#envs[@]} > 0)) || die "BACKUP_ENVIRONMENTS est vide"
  for env in "${envs[@]}"; do
    is_known_env "$env" || die "environnement inconnu dans BACKUP_ENVIRONMENTS : '$env' (admis : $(join_by ' ' "${ALIVAON_KNOWN_ENVS[@]}"))"
    for v in DB_CONTAINER DB_NAME DB_USER DB_PASSWORD BACKUP_DB_USER BACKUP_DB_PASSWORD APP_CONTAINER APP_OWNER VOLUMES; do
      [[ -n $(env_get "$env" "$v") ]] || die "variable ${env^^}_$v manquante ou vide dans la configuration"
    done
    [[ $(env_get "$env" APP_OWNER) =~ ^[0-9]+:[0-9]+$ ]] ||
      die "${env^^}_APP_OWNER : format attendu uid:gid numériques (ex. 82:82), constaté à l'étape 2 du runbook"
    [[ $(env_get "$env" DB_NAME) =~ ^[A-Za-z0-9_]+$ ]] ||
      die "${env^^}_DB_NAME : caractères admis A-Z a-z 0-9 _"
    IFS=' ' read -r -a specs <<<"$(env_get "$env" VOLUMES)"
    for spec in "${specs[@]}"; do
      [[ $spec =~ ^[a-z][a-z0-9_]*=[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] ||
        die "${env^^}_VOLUMES : entrée invalide '$spec' (format attendu : role=nom_du_volume)"
      [[ ${spec%%=*} != db ]] || die "${env^^}_VOLUMES : le rôle 'db' est réservé à la base"
    done
  done
}

# configured_envs — un environnement par ligne.
configured_envs() {
  local -a envs
  IFS=' ' read -r -a envs <<<"$BACKUP_ENVIRONMENTS"
  printf '%s\n' "${envs[@]}"
}

# ── Verrou ───────────────────────────────────────────────────────────────────
#
# Sauvegarde et restauration s'excluent mutuellement : une sauvegarde qui
# démarrerait au milieu d'une restauration archiverait un état à moitié écrit.

# acquire_lock [ATTENTE_EN_SECONDES]
acquire_lock() {
  local wait=${1:-0}
  exec 9>"$ALIVAON_LOCK_FILE"
  if ((wait > 0)); then
    flock -w "$wait" 9 || die "verrou $ALIVAON_LOCK_FILE toujours tenu après ${wait}s : une restauration ou une sauvegarde est en cours"
  else
    flock -n 9 || die "une sauvegarde ou une restauration est déjà en cours (verrou $ALIVAON_LOCK_FILE)"
  fi
}

# ── restic ───────────────────────────────────────────────────────────────────

# --retry-lock : attend qu'un verrou restic se libère (un `check` en cours, par
# exemple) plutôt que d'échouer immédiatement.
rstc() {
  restic --retry-lock 10m "$@"
}

# shellcheck disable=SC2154  # RESTIC_REPOSITORY provient de la configuration
check_repository() {
  rstc cat config >/dev/null ||
    die "dépôt restic inaccessible, non initialisé, ou mot de passe incorrect : $RESTIC_REPOSITORY. Ne JAMAIS lancer 'restic init' sur un dépôt qui existe déjà (voir RUNBOOK-BACKUP.md)."
}

# ── Healthchecks (dead man's switch, facultatif) ─────────────────────────────
#
# hc_ping SUFFIXE [FICHIER_CORPS]
#   SUFFIXE : start | fail | code de sortie (0 = succès, autre = échec).
# Désactivé si HC_PING_URL est vide. Un ping raté n'échoue jamais la sauvegarde.
hc_ping() {
  [[ -n ${HC_PING_URL:-} ]] || return 0
  local url="${HC_PING_URL%/}/$1"
  local -a args=(-fsS -m 10 --retry 3 -o /dev/null)
  if [[ -n ${2:-} ]]; then
    args+=(--data-binary "@$2")
  fi
  curl "${args[@]}" "$url" || warn "ping healthchecks '$1' non délivré (sans effet sur la sauvegarde)"
}

# ── Docker ───────────────────────────────────────────────────────────────────

container_running() {
  [[ $(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null) == true ]]
}

# resolve_volume VOLUME [INDICATION] — point de montage du volume sur l'hôte,
# DEMANDÉ À DOCKER (docker volume inspect), jamais déduit d'une disposition de
# répertoires. Résultat dans la variable globale VOLUME_MOUNTPOINT : pas de
# sous-shell, pour que `die` interrompe bien le script appelant.
#
# Échec explicite si le volume est absent, ou si son pilote n'est pas `local`
# (constaté pour les quatre volumes le 2026-09-23) : seul ce pilote garantit
# que le point de montage est un
# dossier de l'hôte que restic peut lire et que rsync peut écrire. Un volume
# d'un autre pilote (NFS, plugin tiers) serait sauvegardé vide ou pas du tout.
VOLUME_MOUNTPOINT=''
resolve_volume() {
  local vol=$1 hint=${2:-} out driver mp
  VOLUME_MOUNTPOINT=''
  out=$(docker volume inspect -f '{{.Driver}} {{.Mountpoint}}' "$vol" 2>/dev/null) ||
    die "volume Docker '$vol' introuvable${hint:+ : $hint}"
  IFS=' ' read -r driver mp <<<"$out"
  [[ $driver == local ]] ||
    # « H9 » désigne, dans la documentation, l'exigence du pilote « local »
    # (RUNBOOK-BACKUP.md, « Topologie constatée »). Chaîne conservée telle
    # quelle : tests/run.sh la compare.
    die "volume Docker '$vol' : pilote '$driver' non pris en charge, seul le pilote 'local' l'est (hypothèse H9)"
  [[ -n $mp && -d $mp ]] ||
    die "volume Docker '$vol' : point de montage '$mp' absent de l'hôte"
  VOLUME_MOUNTPOINT=$mp
}

# wait_healthy CONTENEUR [DÉLAI_S] — attend « healthy », ou « running » pour un
# conteneur sans healthcheck.
wait_healthy() {
  local c=$1 timeout=${2:-180} waited=0 status
  while ((waited < timeout)); do
    status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$c" 2>/dev/null || true)
    case $status in
      healthy | running) return 0 ;;
      *) ;; # starting, restarting, unhealthy : on attend
    esac
    sleep 5
    waited=$((waited + 5))
  done
  return 1
}

# ── MySQL dans le conteneur, sans mot de passe dans `ps` ─────────────────────
#
# Le mot de passe ne figure JAMAIS dans une ligne de commande, ni sur l'hôte ni
# dans le conteneur (dont les processus sont visibles depuis l'hôte) :
#
#   1. l'hôte construit un fichier d'options [client] avec `printf`, intégré à
#      bash donc absent de `ps`, et l'encode en base64 sur une seule ligne ;
#   2. cette ligne est envoyée en TÊTE de l'entrée standard de `docker exec -i` ;
#   3. dans le conteneur, `read` consomme exactement cette ligne (sur un tube,
#      read lit octet par octet et s'arrête au saut de ligne), la décode dans un
#      fichier 0600 créé par mktemp, supprimé à la sortie par trap ;
#   4. le client MySQL lit ce fichier via --defaults-extra-file, puis hérite du
#      reste de l'entrée standard (le dump, pour une restauration).

# Échappement d'une valeur pour un fichier d'options MySQL entre guillemets.
mysql_opt_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '%s' "$s"
}

# Deux profils d'identifiants, jamais interchangés :
#   dump     utilisateur MySQL `backup` (<ENV>_BACKUP_DB_*), lecture seule :
#            SELECT, SHOW VIEW, TRIGGER sur la base, et rien d'autre (jeu
#            minimal ; l'escalade éventuelle est documentée à l'étape 3 du
#            runbook). La sauvegarde ne dépend donc pas des privilèges de
#            l'application, qui restent minimaux ;
#   restore  utilisateur applicatif (<ENV>_DB_*), seul à pouvoir supprimer et
#            recréer la base lors d'une restauration.
#
# MODE DE CONNEXION : socket Unix, imposé par `protocol=socket`. Le client
# tourne DANS le conteneur MySQL (docker exec), sans -h. MySQL évalue alors la
# connexion comme venant de 'localhost' : le compte doit être créé en
# 'backup'@'localhost', et c'est ce que fait le runbook. Une connexion TCP, même
# vers 127.0.0.1, serait évaluée comme 'backup'@'127.0.0.1' et refusée
# (ERROR 1045, Access denied). `protocol=socket` est explicite pour qu'aucun
# `host=` d'un fichier d'options global du conteneur ne bascule en TCP à notre
# insu. tests/run.sh vérifie l'accord entre ce mode et l'hôte du runbook.

# db_cnf_line ENV PROFIL — le fichier d'options encodé, sur une ligne.
db_cnf_line() {
  local user pass enc prefix
  case $2 in
    dump) prefix=BACKUP_DB ;;
    restore) prefix=DB ;;
    *) die "profil d'identifiants inconnu : '$2'" ;;
  esac
  user=$(mysql_opt_escape "$(env_get "$1" "${prefix}_USER")")
  pass=$(mysql_opt_escape "$(env_get "$1" "${prefix}_PASSWORD")")
  # La substitution retire tout saut de ligne final, quelle que soit
  # l'implémentation de base64 : exactement une ligne est émise, sans quoi le
  # client MySQL recevrait une ligne vide parasite en tête du dump.
  enc=$(printf '[client]\nprotocol=socket\nuser="%s"\npassword="%s"\n' "$user" "$pass" | base64 -w 0)
  printf '%s\n' "$enc"
}

# Scripts exécutés DANS le conteneur MySQL par `sh -c`. $1 = nom de la base.
# Prologue commun : récupère le fichier d'options depuis la première ligne de
# l'entrée standard.
_DB_PROLOGUE=$(
  cat <<'EOF'
set -eu
umask 077
cnf=$(mktemp)
trap 'rm -f "$cnf"' EXIT
IFS= read -r line
printf '%s' "$line" | base64 -d > "$cnf"
EOF
)

# --single-transaction : instantané cohérent des tables InnoDB, sans LOCK TABLES
#                        (d'où l'absence de ce privilège).
# --quick              : lignes écrites au fil de l'eau, sans tout charger en
#                        mémoire.
# --routines           : procédures et fonctions stockées (aucune attendue,
#                        aucune constatée le 2026-09-23 ; l'option garantit qu'une routine ajoutée
#                        plus tard ne serait pas perdue en silence).
# --triggers           : déclencheurs (défaut de mysqldump, rendu explicite).
# --no-tablespaces     : n'interroge pas INFORMATION_SCHEMA.FILES, qui exige le
#                        privilège global PROCESS depuis 8.0.21. C'est ce qui
#                        permet de NE PAS accorder PROCESS à l'utilisateur
#                        backup. Les CREATE TABLESPACE sont inutiles ici
#                        (InnoDB, un fichier par table).
# --default-character-set=utf8mb4 : PAS cosmétique. Un dump dans un autre
#                        encodage altère le contenu accentué, et le défaut ne
#                        se voit qu'à la restauration.
# --hex-blob           : colonnes binaires en hexadécimal, insensibles à
#                        l'encodage.
# --set-gtid-purged=OFF: dump rejouable sans privilège SUPER.
# --databases + --add-drop-database : le dump recrée la base à l'identique
#   (jeu de caractères et collation compris). La restauration est donc
#   complète : une table apparue après l'instantané ne survit pas.
readonly DB_DUMP_SCRIPT="$_DB_PROLOGUE
mysqldump --defaults-extra-file=\"\$cnf\" \\
  --single-transaction --quick --routines --triggers --no-tablespaces \\
  --default-character-set=utf8mb4 --hex-blob --set-gtid-purged=OFF \\
  --add-drop-database --databases \"\$1\""

# shellcheck disable=SC2034  # utilisé par restore.sh
readonly DB_IMPORT_SCRIPT="$_DB_PROLOGUE
mysql --defaults-extra-file=\"\$cnf\" --default-character-set=utf8mb4"

# shellcheck disable=SC2034  # utilisé par restore.sh
# Sans base sélectionnée : doit réussir même si la base cible a disparu.
readonly DB_PING_SCRIPT="$_DB_PROLOGUE
mysql --defaults-extra-file=\"\$cnf\" -N -B -e 'SELECT 1' > /dev/null"

# db_run ENV PROFIL SCRIPT [ARG...] — exécute SCRIPT dans le conteneur MySQL de
# ENV avec les identifiants du PROFIL (dump ou restore). L'entrée standard de
# l'appelant est transmise après la ligne d'options.
db_run() {
  local env=$1 profile=$2 script=$3 container
  shift 3
  container=$(env_get "$env" DB_CONTAINER)
  { db_cnf_line "$env" "$profile"; cat; } | docker exec -i "$container" sh -c "$script" alivaon-backup "$@"
}

# check_dump FICHIER — refuse un dump vide ou tronqué. mysqldump n'écrit sa
# ligne finale « -- Dump completed » qu'après la dernière table.
check_dump() {
  local f=$1 last
  [[ -s $f ]] || die "dump vide : $f"
  last=$(tail -n 1 -- "$f")
  [[ $last == '-- Dump completed'* ]] ||
    die "dump tronqué, marqueur de fin mysqldump absent : $f"
  info "dump valide : $(numfmt --to=iec --suffix=o "$(stat -c %s -- "$f")")"
}

# ── Sauvegarde d'un environnement ────────────────────────────────────────────
#
# Utilisée par backup.sh (KIND=scheduled) et par restore.sh, qui archive l'état
# de la cible juste avant de l'écraser (KIND=pre-restore).
#
# Chaque environnement produit SON PROPRE instantané, étiqueté env:<nom>, dont
# les chemins sont disjoints de ceux de l'autre environnement :
#   /var/lib/alivaon-backup/dumps/<env>/       dump SQL + manifeste
#   <point de montage de chaque volume de l'env>
# restore.sh s'appuie sur l'étiquette ET sur le manifeste pour refuser toute
# restauration croisée non autorisée.
#
# Le tableau global CLEANUP_DIRS doit être déclaré par l'appelant : les dossiers
# de dumps y sont ajoutés pour être purgés par son trap EXIT.

prepare_dump_dir() {
  local dir=$ALIVAON_DUMP_ROOT/${1:?}
  # Idempotence : un dump laissé par une exécution interrompue est écarté.
  rm -rf -- "${dir:?}"
  install -d -m 0700 -- "$ALIVAON_DUMP_ROOT" "$dir"
  CLEANUP_DIRS+=("$dir")
}

backup_env() {
  local env=$1 kind=$2
  local db_container db_name dump_dir dump_file err_file line spec role vol mp rc=0
  local -a specs paths manifest args

  db_container=$(env_get "$env" DB_CONTAINER)
  db_name=$(env_get "$env" DB_NAME)
  dump_dir=$ALIVAON_DUMP_ROOT/$env
  dump_file=$dump_dir/$db_name.sql

  info "[$env] début de la sauvegarde ($kind)"
  container_running "$db_container" || die "[$env] conteneur MySQL $db_container arrêté ou absent"
  prepare_dump_dir "$env"

  # 1. Base : dump d'abord, fichiers ensuite. Un fichier téléversé entre les
  #    deux figure dans l'instantané sans ligne en base (orphelin inoffensif).
  #    Dans l'ordre inverse, la base pourrait référencer un fichier absent.
  #    La sortie d'erreur est recueillie HORS du dossier archivé, puis
  #    journalisée ligne à ligne, horodatée : un avertissement de mysqldump
  #    (privilège manquant sur une routine, par exemple) reste visible.
  err_file=$ALIVAON_DUMP_ROOT/$env.stderr
  CLEANUP_DIRS+=("$err_file")
  info "[$env] mysqldump --single-transaction de '$db_name' dans $db_container (utilisateur $(env_get "$env" BACKUP_DB_USER))"
  db_run "$env" dump "$DB_DUMP_SCRIPT" "$db_name" </dev/null >"$dump_file.partial" 2>"$err_file" || rc=$?
  while IFS= read -r line; do
    warn "[$env] mysqldump : $line"
  done <"$err_file"
  rm -f -- "$err_file"
  ((rc == 0)) || die "[$env] mysqldump a échoué (code $rc) : voir les lignes « mysqldump : » ci-dessus"
  check_dump "$dump_file.partial"
  mv -f -- "$dump_file.partial" "$dump_file"

  manifest=(
    "format $ALIVAON_MANIFEST_FORMAT"
    "env $env"
    "kind $kind"
    "created $(date '+%Y-%m-%dT%H:%M:%S%z')"
    "database $db_name $db_name.sql $db_container"
  )
  paths=("$dump_dir")

  # 2. Volumes : chemin résolu par Docker à chaque exécution, jamais supposé.
  IFS=' ' read -r -a specs <<<"$(env_get "$env" VOLUMES)"
  for spec in "${specs[@]}"; do
    role=${spec%%=*}
    vol=${spec#*=}
    resolve_volume "$vol" "rôle $role de l'environnement $env"
    mp=$VOLUME_MOUNTPOINT
    if [[ -z $(find "$mp" -mindepth 1 -print -quit) ]]; then
      warn "[$env] volume '$vol' VIDE : sauvegardé tel quel, à vérifier"
    fi
    info "[$env] volume $role : $vol -> $mp"
    manifest+=("volume $role $vol $mp")
    paths+=("$mp")
  done
  printf '%s\n' "${manifest[@]}" >"$dump_dir/manifest"

  # 3. Instantané.
  args=(backup --host "$RESTIC_HOST" --tag alivaon --tag "env:$env" --tag "kind:$kind")
  if [[ -n $RESTIC_EXCLUDE_FILE ]]; then
    args+=(--exclude-file "$RESTIC_EXCLUDE_FILE")
  fi
  info "[$env] restic backup vers $RESTIC_REPOSITORY"
  rstc "${args[@]}" -- "${paths[@]}" || rc=$?
  case $rc in
    0) ;;
    3) die "[$env] instantané INCOMPLET : des fichiers n'ont pas pu être lus (détail ci-dessus)" ;;
    *) die "[$env] restic backup a échoué (code $rc)" ;;
  esac

  # Le dump n'a plus de raison de rester sur le serveur.
  rm -rf -- "${dump_dir:?}"
  info "[$env] sauvegarde terminée"
}

# latest_snapshot_json TAGS — l'instantané le plus récent portant TOUTES les
# étiquettes TAGS (séparées par des virgules), ou `null`. `--latest 1` renvoie
# le dernier de CHAQUE groupe hôte+chemins : on garde le plus récent de tous.
latest_snapshot_json() {
  rstc snapshots --json --latest 1 --tag "$1" | jq -c 'sort_by(.time) | last'
}
