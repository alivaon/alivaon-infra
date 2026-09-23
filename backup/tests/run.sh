#!/usr/bin/env bash
#
# Suite de tests du dispositif de sauvegarde, SANS serveur : docker, restic,
# mysqldump et mysql sont remplacés par les simulacres de tests/mocks/.
# Aucun réseau, aucun privilège, aucun fichier écrit hors d'un dossier
# temporaire supprimé à la fin.
#
# UTILISATION (sur le Mac ou sur Linux, depuis n'importe quel dossier)
#   backup/tests/run.sh
#
# Exige bash >= 4.3. Sur macOS, /bin/bash est en 3.2 : le script se relance
# de lui-même avec le bash de Homebrew (brew install bash). Les outils GNU
# absents de macOS (stat -c, base64 -w, numfmt) sont traduits par tests/shims/.
#
# CE QUI EST COUVERT
#   A. transport des identifiants MySQL, options et journalisation du dump
#   B. les 15 garde-fous de restore.sh (politique d'environnement, manifeste,
#      arguments), inchangés
#   C. rotation hebdomadaire de la fraction relue par verify.sh
#   D. idempotence d'install.sh
#   E. validation de la configuration
#   F. mode de connexion MySQL (socket) et hôte du compte documenté dans le
#      runbook ('backup'@'localhost'), qui doivent s'accorder
#   G. résolution des volumes par docker volume inspect (pilote local requis)
#
# CODE DE SORTIE : 0 si tous les cas passent, 1 sinon.
#
# Pas de `set -e`, délibérément : chaque cas est évalué et compté, un échec
# n'interrompt pas la suite.
#
# Règles shellcheck écartées pour CE fichier, et pourquoi :
#   SC2034, SC2154 — les fonctions testées sont sourcées depuis des copies
#     générées à l'exécution (lib.sh, restore_fn.sh, verify_fn.sh), que
#     l'analyseur ne peut pas suivre : il ne voit ni l'usage des variables
#     posées ici (TARGET, M_MP, PRODUCTION_*...), ni leur définition
#     (DB_IMPORT_SCRIPT...).
#   SC2329 — les fonctions d'un cas (pol, lm, v_ok...) sont appelées
#     indirectement, en argument de expect_code.
#   SC2016 — mots de passe de test volontairement littéraux ($HOME ne doit PAS
#     être développé : c'est précisément ce qu'on vérifie).
#   SC2030, SC2031 — chaque section tourne dans un sous-shell, précisément pour
#     que ses variables ne fuient pas vers la suivante.
# shellcheck disable=SC2034,SC2154,SC2329,SC2016,SC2030,SC2031
set -uo pipefail
IFS=$'\n\t'

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3))); then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [[ -x $b ]] && exec "$b" "$0" "$@"
  done
  echo "bash >= 4.3 requis (macOS : brew install bash)" >&2
  exit 1
fi

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
BACKUP_DIR=$(dirname -- "$HERE")
TEST_ROOT=$(cd -- "$(mktemp -d)" && pwd -P)
RESULTS=$TEST_ROOT/results
trap 'rm -rf -- "$TEST_ROOT"' EXIT
export TEST_ROOT TEST_MOCKS=$HERE/mocks

PATH=$HERE/mocks/bin:$PATH
if ! stat -c %a / >/dev/null 2>&1; then
  PATH=$HERE/shims:$PATH
fi
export PATH

mkdir -p "$TEST_ROOT"/{log,restic,volumes,state}
# Copies de travail : dossier d'état redirigé, appel final à main retiré pour
# pouvoir sourcer les fonctions de restore.sh et verify.sh.
sed "s|/var/lib/alivaon-backup|$TEST_ROOT/state|" "$BACKUP_DIR/lib.sh" >"$TEST_ROOT/lib.sh"
sed '$d' "$BACKUP_DIR/restore.sh" >"$TEST_ROOT/restore_fn.sh"
sed '$d' "$BACKUP_DIR/verify.sh" >"$TEST_ROOT/verify_fn.sh"

# ── Outils de test ───────────────────────────────────────────────────────────

ok() { printf 'OK     %s\n' "$*"; }
ko() { printf 'ÉCHEC  %s\n' "$*"; }

# check DESCRIPTION COMMANDE...
check() {
  local what=$1
  shift
  if "$@"; then ok "$what"; else ko "$what"; fi
}

# expect_code CODE DESCRIPTION COMMANDE... — exécutée dans un sous-shell.
expect_code() {
  local want=$1 what=$2 got
  shift 2
  ("$@") >"$TEST_ROOT/log/out" 2>&1
  got=$?
  if [[ $got == "$want" ]]; then
    ok "[$got] $what"
  else
    ko "[$got≠$want] $what"
    sed 's/^/         | /' "$TEST_ROOT/log/out"
  fi
}

contains() { [[ $1 == *"$2"* ]]; }
lacks() { [[ $1 != *"$2"* ]]; }

section() { printf '\n== %s\n' "$*"; }

# ── A. Transport des identifiants et dump ────────────────────────────────────

section_a() (
  # shellcheck source=/dev/null
  . "$TEST_ROOT/lib.sh"
  CLEANUP_DIRS=()
  TRICKY='p@ss"wo\rd #x $HOME '"'"'q'"'"' ;ls'
  PRODUCTION_DB_CONTAINER=production-db-1
  PRODUCTION_DB_NAME=alivaon_db
  PRODUCTION_DB_USER=alivaon_app
  PRODUCTION_DB_PASSWORD=app-secret-42
  PRODUCTION_BACKUP_DB_USER=backup
  PRODUCTION_BACKUP_DB_PASSWORD=$TRICKY
  PRODUCTION_VOLUMES='uploads=production_uploads cv_private=production_cv_private'
  RESTIC_HOST=alivaon-vps RESTIC_EXCLUDE_FILE='' RESTIC_REPOSITORY=sftp:x:y
  mkdir -p "$TEST_ROOT/volumes/production_uploads" "$TEST_ROOT/volumes/production_cv_private"
  echo img >"$TEST_ROOT/volumes/production_uploads/a.jpg"
  echo cv >"$TEST_ROOT/volumes/production_cv_private/cv.pdf"

  section "A. transport des identifiants, options et journalisation du dump"
  expect_code 0 "backup_env production scheduled" backup_env production scheduled
  local args cnf out opt
  args=$(grep '^ARGS' "$TEST_ROOT/log/mysqldump")
  for opt in --single-transaction --quick --routines --triggers --no-tablespaces \
    --default-character-set=utf8mb4 --add-drop-database --set-gtid-purged=OFF; do
    check "option de dump présente : $opt" contains "$args " " $opt "
  done
  check "mot de passe backup absent des arguments" lacks "$args" 'p@ss'
  check "mot de passe applicatif absent des arguments" lacks "$args" 'app-secret'
  check "fichier d'options en 0600" grep -q '^MODE: 600$' "$TEST_ROOT/log/mysqldump"
  cnf=$(sed -n 's/^CNF_PATH: //p' "$TEST_ROOT/log/mysqldump")
  check "fichier d'options supprimé après usage" test ! -e "$cnf"
  out=$(sed -n '/^CNF<</,/^>>CNF/p' "$TEST_ROOT/log/mysqldump")
  check "dump réalisé avec l'utilisateur backup, pas l'applicatif" contains "$out" 'user="backup"'
  check "mot de passe échappé pour le fichier d'options" \
    contains "$out" 'password="p@ss\"wo\\rd #x $HOME '"'"'q'"'"' ;ls"'
  check "instantané étiqueté env:production kind:scheduled" \
    grep -q -- '--tag alivaon --tag env:production --tag kind:scheduled' "$TEST_ROOT/log/restic"
  check "manifeste archivé avec les deux volumes" \
    test "$(grep -c '^volume ' "$TEST_ROOT/log/manifest")" -eq 2
  check "dossier de dump supprimé après sauvegarde" test ! -e "$TEST_ROOT/state/dumps/production"

  out=$(
    export MOCK_MYSQLDUMP_STDERR='Warning: insufficient privileges to SHOW CREATE PROCEDURE'
    backup_env production scheduled 2>&1
  )
  check "avertissement mysqldump journalisé, horodaté, en ALERTE" \
    grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}[+-][0-9]{4} \[ALERTE\] \[production\] mysqldump : Warning: insufficient' <<<"$out"
  check "fichier stderr du dump supprimé" test ! -e "$TEST_ROOT/state/dumps/production.stderr"

  export MOCK_MYSQLDUMP_EXIT=2
  expect_code 1 "échec de mysqldump -> échec de la sauvegarde" backup_env production scheduled
  check "message d'échec explicite" grep -q 'mysqldump a échoué (code 2)' "$TEST_ROOT/log/out"
  unset MOCK_MYSQLDUMP_EXIT

  printf 'DROP DATABASE IF EXISTS x;\nligne 2 avec "guillemets"\n-- Dump completed\n' >"$TEST_ROOT/dump.sql"
  db_run production restore "$DB_IMPORT_SCRIPT" <"$TEST_ROOT/dump.sql"
  check "import : pas de ligne parasite, dump reçu octet pour octet" \
    cmp -s "$TEST_ROOT/dump.sql" "$TEST_ROOT/log/mysql.stdin"
  check "import réalisé avec l'utilisateur applicatif (profil restore)" \
    grep -q 'user="alivaon_app"' "$TEST_ROOT/log/mysql"
  expect_code 1 "profil d'identifiants inconnu refusé" db_cnf_line production root
  printf 'CREATE TABLE t;\n' >"$TEST_ROOT/trunc.sql"
  expect_code 1 "dump tronqué refusé" check_dump "$TEST_ROOT/trunc.sql"
)

# ── B. Garde-fous de restore.sh (15 cas, inchangés) ──────────────────────────

section_b() (
  # shellcheck source=/dev/null
  . "$TEST_ROOT/restore_fn.sh"
  set +e
  pol() { SNAP_SHORT=abcd1234 SNAP_ENV=$1 TARGET=$2 ALLOW_P2S=$3; check_env_policy; }
  mf() { printf '%s\n' "$@" >"$TEST_ROOT/restic/dump"; }
  lm() { SNAP_ID=x SNAP_SHORT=x SNAP_ENV=$1; SNAP_PATHS=(/v/up); load_manifest; }
  WORK_DIR=$TEST_ROOT/work
  mkdir -p "$WORK_DIR"

  section "B. garde-fous de restore.sh"
  expect_code 0 "production -> production" pol production production 0
  expect_code 0 "staging -> staging" pol staging staging 0
  expect_code 3 "staging -> production refusé" pol staging production 0
  expect_code 3 "staging -> production refusé MÊME avec l'option" pol staging production 1
  expect_code 3 "production -> staging refusé sans option" pol production staging 0
  expect_code 0 "production -> staging accepté avec option" pol production staging 1

  mf 'format 1' 'env staging' 'database alivaon_db alivaon_db.sql staging-db-1' 'volume uploads staging_uploads_staging /v/up'
  expect_code 3 "étiquette env:production mais manifeste staging -> refus" lm production
  expect_code 0 "étiquette et manifeste concordants" lm staging
  mf 'format 1' 'env staging' 'database alivaon_db ../../etc/passwd staging-db-1'
  expect_code 1 "nom de dump avec chemin -> refus" lm staging
  mf 'format 1' 'env staging' 'database alivaon_db alivaon_db.sql staging-db-1' 'volume uploads x /ailleurs'
  expect_code 1 "volume du manifeste absent des chemins de l'instantané" lm staging
  mf 'format 2' 'env staging'
  expect_code 1 "format de manifeste inconnu" lm staging

  expect_code 1 "identifiant d'instantané invalide" parse_args --target production --snapshot 'latest;rm'
  expect_code 1 "cible inconnue" parse_args --target prod --snapshot latest
  expect_code 1 "cible manquante" parse_args --snapshot latest
  expect_code 0 "arguments valides" parse_args --target staging --snapshot 1a2b3c4d
)

# ── C. Rotation de la fraction relue par verify.sh ───────────────────────────

section_c() (
  # shellcheck source=/dev/null
  . "$TEST_ROOT/verify_fn.sh"
  local day=86400 w d ref seen=' ' s cur prev
  # Lundi 28 décembre 2026 : semaine ISO 2026-W53 (jour 20815 depuis 1970).
  local mon=$((20815 * day))

  section "C. rotation hebdomadaire de --read-data-subset"
  check "semaine du 1er janvier 1970 (lundi 29/12/1969) -> 1/8" test "$(read_data_slice 0)" = 1/8
  check "lundi 5 janvier 1970 -> 2/8" test "$(read_data_slice $((4 * day)))" = 2/8

  ref=$(read_data_slice "$mon")
  local same=1
  for d in 0 1 2 3 4 5 6; do
    [[ $(read_data_slice $((mon + d * day + 43200))) == "$ref" ]] || same=0
  done
  check "même fraction du lundi au dimanche d'une semaine ISO" test "$same" = 1

  for w in -4 -3 -2 -1 0 1 2 3; do
    s=$(read_data_slice $((mon + w * 7 * day + 43200)))
    seen+="$s "
  done
  local all=1
  for s in 1/8 2/8 3/8 4/8 5/8 6/8 7/8 8/8; do
    [[ $seen == *" $s "* ]] || all=0
  done
  check "huit semaines consécutives couvrent les huit fractions, une fois chacune (${seen# })" test "$all" = 1

  prev=$(read_data_slice $((20814 * day + 43200))) # dimanche 27/12/2026, 2026-W52
  cur=$(read_data_slice $((20822 * day + 43200)))  # lundi 04/01/2027, 2027-W01
  check "2026-W52 -> 2026-W53 : fraction suivante" test "$(((${prev%/8} % 8) + 1))/8" = "$ref"
  check "2026-W53 -> 2027-W01 : fraction suivante, sans saut au changement d'année" \
    test "$(((${ref%/8} % 8) + 1))/8" = "$cur"
)

# ── D. Idempotence d'install.sh ──────────────────────────────────────────────

section_d() (
  local dest=$TEST_ROOT/dest out rc lib=$TEST_ROOT/dest/usr/local/lib/alivaon-backup
  local conf=$TEST_ROOT/dest/etc/alivaon-backup
  run_install() { DESTDIR=$dest "$BASH" "$BACKUP_DIR/install.sh" "$@" 2>&1; }

  section "D. idempotence d'install.sh"
  out=$(run_install); rc=$?
  check "1re exécution : succès" test "$rc" = 0
  check "1re exécution : fichiers installés" contains "$out" "installation : $lib/backup.sh"
  check "scripts en 0755, lib.sh en 0644" \
    test "$(stat -c %a "$lib/restore.sh")/$(stat -c %a "$lib/lib.sh")" = 755/644
  check "/etc/alivaon-backup en 0700, backup.env créé en 0600" \
    test "$(stat -c %a "$conf")/$(stat -c %a "$conf/backup.env")" = 700/600
  check "unités de vérification installées" test -f "$dest/etc/systemd/system/alivaon-backup-verify.timer"

  out=$(run_install); rc=$?
  check "2e exécution : succès" test "$rc" = 0
  check "2e exécution : aucune modification" contains "$out" 'BILAN : 0 modification(s)'
  check "2e exécution : aucun diff affiché" lacks "$out" '+++ dépôt'
  out=$(run_install --check); rc=$?
  check "--check après installation : identique, code 0" test "$rc" = 0

  echo '# modification faite à la main sur le serveur' >>"$lib/backup.sh"
  out=$(run_install --check); rc=$?
  check "--check : écart détecté, code 1" test "$rc" = 1
  check "--check : diff affiché" contains "$out" '-# modification faite à la main sur le serveur'
  check "--check : rien modifié" grep -q 'modification faite à la main' "$lib/backup.sh"
  out=$(run_install); rc=$?
  check "réinstallation : version du dépôt rétablie" cmp -s "$BACKUP_DIR/backup.sh" "$lib/backup.sh"

  chmod 0777 "$lib/lib.sh"
  out=$(run_install)
  check "droits dérivés corrigés (0777 -> 0644)" test "$(stat -c %a "$lib/lib.sh")" = 644

  printf 'RESTIC_REPOSITORY=valeur-locale\n' >"$conf/backup.env"
  printf 'secret\n' >"$conf/restic-password"
  chmod 0644 "$conf/restic-password"
  out=$(run_install)
  check "backup.env existant jamais écrasé" grep -qx 'RESTIC_REPOSITORY=valeur-locale' "$conf/backup.env"
  check "variables manquantes de backup.env signalées" contains "$out" 'PRODUCTION_BACKUP_DB_PASSWORD'
  check "restic-password ramené à 0600, contenu intact" \
    test "$(stat -c %a "$conf/restic-password")/$(cat "$conf/restic-password")" = 600/secret
  out=$(run_install); rc=$?
  check "exécution suivante : aucune modification" contains "$out" 'BILAN : 0 modification(s)'
)

# ── E. Validation de la configuration ────────────────────────────────────────

section_e() (
  # shellcheck source=/dev/null
  . "$TEST_ROOT/lib.sh"
  set +e
  secure_file() { :; } # propriétaire root impossible à reproduire hors serveur
  base_config() {
    RESTIC_REPOSITORY=sftp:x:y RESTIC_PASSWORD_FILE=/dev/null BACKUP_ENVIRONMENTS=production
    PRODUCTION_DB_CONTAINER=production-db-1 PRODUCTION_DB_NAME=alivaon_db
    PRODUCTION_DB_USER=alivaon_app PRODUCTION_DB_PASSWORD=x
    PRODUCTION_BACKUP_DB_USER=backup PRODUCTION_BACKUP_DB_PASSWORD=y
    PRODUCTION_APP_CONTAINER=production-app-1
    PRODUCTION_VOLUMES='uploads=production_uploads cv_private=production_cv_private'
  }
  v_ok() { base_config; validate_config; }
  v_no_backup_pw() { base_config; unset PRODUCTION_BACKUP_DB_PASSWORD; validate_config; }

  section "E. validation de la configuration"
  expect_code 0 "configuration complète acceptée" v_ok
  expect_code 1 "PRODUCTION_BACKUP_DB_PASSWORD manquant -> refus" v_no_backup_pw
  check "message désignant la variable manquante" grep -q 'PRODUCTION_BACKUP_DB_PASSWORD' "$TEST_ROOT/log/out"
)

# ── F. Mode de connexion MySQL et hôte du compte ─────────────────────────────
#
# L'hôte du compte 'backup'@'<hôte>' créé par le runbook doit correspondre au
# mode de connexion RÉEL du script : socket Unix -> 'localhost' ; TCP (-h,
# --host, protocol=tcp) -> hôte réseau ('%', '127.0.0.1'...). Un désaccord ne
# se voit qu'à la première sauvegarde, sous la forme d'un « Access denied »
# difficile à relier à sa cause.
#
# Seules les DÉFINITIONS de compte du runbook sont lues (CREATE USER, ALTER
# USER, GRANT ... TO, SHOW GRANTS FOR) : le runbook cite aussi, volontairement,
# le message d'erreur d'un mauvais appariement ('backup'@'127.0.0.1').

no_tcp_option() {
  [[ $1 != *" -h "* && $1 != *" --host"* && $1 != *" --port"* && $1 != *" -P "* &&
    $1 != *"--protocol=tcp"* && $1 != *"--protocol=TCP"* ]]
}

section_f() (
  # shellcheck source=/dev/null
  . "$TEST_ROOT/lib.sh"
  set +e
  local runbook=$BACKUP_DIR/RUNBOOK-BACKUP.md cnf_dump cnf_restore args mode expected line n
  local -a hosts env_hosts cmds
  PRODUCTION_DB_CONTAINER=production-db-1
  PRODUCTION_DB_USER=alivaon_app PRODUCTION_DB_PASSWORD=x
  PRODUCTION_BACKUP_DB_USER=backup PRODUCTION_BACKUP_DB_PASSWORD=y

  section "F. mode de connexion MySQL et hôte du compte 'backup'"
  cnf_dump=$(db_cnf_line production dump | base64 -d)
  cnf_restore=$(db_cnf_line production restore | base64 -d)
  check "profil dump : protocol=socket imposé" grep -qx 'protocol=socket' <<<"$cnf_dump"
  check "profil restore : protocol=socket imposé" grep -qx 'protocol=socket' <<<"$cnf_restore"
  check "aucun host= dans les fichiers d'options" lacks "$cnf_dump$cnf_restore" 'host='
  db_run production dump "$DB_DUMP_SCRIPT" alivaon_db </dev/null >/dev/null 2>&1
  args=" $(sed -n 's/^ARGS: //p' "$TEST_ROOT/log/mysqldump") "
  check "mysqldump lancé sans -h, --host, --port ni --protocol=tcp" no_tcp_option "$args"

  # Mode effectif du script, et hôte de compte qu'il impose.
  mode=tcp
  if grep -qx 'protocol=socket' <<<"$cnf_dump" && no_tcp_option "$args"; then
    mode=socket
  fi
  case $mode in
    socket) expected=localhost ;;
    *) expected='%' ;;
  esac
  mapfile -t hosts < <(grep -oE "(USER( IF NOT EXISTS)?|TO|FOR) 'backup'@'[^']*'" "$runbook" |
    sed -E "s/.*'backup'@'([^']*)'/\1/")
  check "le runbook définit le compte 'backup' (${#hosts[@]} définitions, 12 attendues au minimum)" \
    test "${#hosts[@]}" -ge 12
  check "mode du script : $mode -> hôte attendu '$expected' ; hôtes du runbook : $(printf '%s\n' "${hosts[@]}" | sort -u | tr '\n' ' ')" \
    test "$(printf '%s\n' "${hosts[@]}" | sort -u)" = "$expected"
  mapfile -t env_hosts < <(grep -oE "'backup'@'[^']*'" "$BACKUP_DIR/.env.example" |
    sed -E "s/.*'backup'@'([^']*)'/\1/" | sort -u)
  check ".env.example documente le même hôte" test "$(join_by ' ' "${env_hosts[@]}")" = "$expected"

  mapfile -t cmds < <(grep -E 'mysqldump .*-u backup' "$runbook")
  n=0
  for line in "${cmds[@]}"; do
    if [[ $line == *--protocol=socket* ]] && no_tcp_option " $line "; then n=$((n + 1)); fi
  done
  check "dumps d'essai du runbook en --protocol=socket, sans -h (${#cmds[@]} commandes, 2 attendues)" \
    test "${#cmds[@]}" -eq 2 -a "$n" -eq 2
  check "le symptôme d'un mauvais appariement est documenté" \
    grep -q "Access denied for user 'backup'@'127.0.0.1'" "$runbook"
)

# ── G. Résolution des volumes ────────────────────────────────────────────────

section_g() (
  # shellcheck source=/dev/null
  . "$TEST_ROOT/lib.sh"
  set +e
  mkdir -p "$TEST_ROOT/volumes/vol_local" "$TEST_ROOT/volumes/vol_nfs"
  echo marqueur >"$TEST_ROOT/volumes/vol_local/f"
  echo nfs >"$TEST_ROOT/volumes/vol_nfs.driver"

  section "G. résolution des volumes (docker volume inspect, pilote local requis)"
  resolve_volume vol_local
  check "pilote local : point de montage récupéré auprès de Docker" \
    test "$VOLUME_MOUNTPOINT" = "$TEST_ROOT/volumes/vol_local"
  expect_code 1 "volume absent -> échec explicite" resolve_volume vol_absent "démarrer la stack"
  check "message : volume introuvable, avec l'indication" \
    grep -q "volume Docker 'vol_absent' introuvable : démarrer la stack" "$TEST_ROOT/log/out"
  expect_code 1 "pilote non local -> échec explicite" resolve_volume vol_nfs
  check "message : pilote nommé et hypothèse H9 citée" \
    grep -q "pilote 'nfs' non pris en charge.*(hypothèse H9)" "$TEST_ROOT/log/out"

  CLEANUP_DIRS=()
  PRODUCTION_DB_CONTAINER=production-db-1 PRODUCTION_DB_NAME=alivaon_db
  PRODUCTION_BACKUP_DB_USER=backup PRODUCTION_BACKUP_DB_PASSWORD=y
  PRODUCTION_VOLUMES='uploads=vol_nfs'
  RESTIC_HOST=alivaon-vps RESTIC_EXCLUDE_FILE='' RESTIC_REPOSITORY=sftp:x:y
  : >"$TEST_ROOT/log/restic"
  expect_code 1 "sauvegarde refusée pour un volume au pilote non local" backup_env production scheduled
  check "aucun instantané tenté dans ce cas" test "$(grep -c '^backup' "$TEST_ROOT/log/restic")" -eq 0
)

{
  section_a
  section_b
  section_c
  section_d
  section_e
  section_f
  section_g
} | tee "$RESULTS"

pass=$(grep -c '^OK ' "$RESULTS")
fail=$(grep -c '^ÉCHEC ' "$RESULTS")
printf '\nBILAN : %s cas réussis, %s en échec\n' "$pass" "$fail"
((fail == 0))
