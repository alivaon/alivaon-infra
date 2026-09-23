#!/usr/bin/env bash
#
# Installation et mise à jour du dispositif de sauvegarde sur le VPS —
# IDEMPOTENT. À lancer depuis la copie du dossier backup/ déposée sur le VPS
# (RUNBOOK-BACKUP.md, étape 5).
#
# CE QUE FAIT LE SCRIPT
#   - scripts      -> /usr/local/lib/alivaon-backup/   root:root, 0755 (lib.sh 0644)
#   - unités       -> /etc/systemd/system/              root:root, 0644
#   - /etc/alivaon-backup/ et ssh/                      root:root, 0700
#   - /etc/alivaon-backup/restic-password               droits ramenés à 0600,
#                                                       JAMAIS créé ni modifié
#   - /etc/alivaon-backup/backup.env                    créé depuis .env.example
#                                                       s'il est absent, JAMAIS
#                                                       écrasé ; droits 0600
#   - systemctl daemon-reload
#
# Un fichier n'est copié que si son contenu diffère : le diff (version
# installée -> version du dépôt) est alors affiché. Des droits incorrects sont
# corrigés et signalés. Une seconde exécution n'affiche ni diff ni correction.
#
# Le script n'active AUCUN timer : c'est une étape distincte du runbook, qui
# suit la première sauvegarde manuelle.
#
# UTILISATION (sur le VPS)
#   sudo ~/alivaon-backup-src/install.sh           installe ou met à jour
#   sudo ~/alivaon-backup-src/install.sh --check   compare seulement, ne modifie rien
#
# CODES DE SORTIE
#   0  installation conforme (après mise à jour éventuelle) ; en --check,
#      serveur identique au dépôt
#   1  erreur ; en --check, au moins un écart (contenu ou droits)
#
# DESTDIR : préfixe de toutes les destinations, pour les tests (tests/run.sh).
# Vide en exploitation. Avec DESTDIR, ni systemctl ni changement de
# propriétaire (possible sans root).
#
# shellcheck source-path=SCRIPTDIR
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

SRC=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
# shellcheck source=lib.sh
. "$SRC/lib.sh"

DESTDIR=${DESTDIR:-}
LIB_DIR=$DESTDIR/usr/local/lib/alivaon-backup
UNIT_DIR=$DESTDIR/etc/systemd/system
CONF_DIR=$DESTDIR/etc/alivaon-backup

readonly SCRIPTS=(backup.sh restore.sh verify.sh restic.sh notify-failure.sh)
readonly LIBS=(lib.sh)
readonly UNITS=(
  alivaon-backup.service
  alivaon-backup.timer
  alivaon-backup-failure.service
  alivaon-backup-verify.service
  alivaon-backup-verify.timer
)

CHECK=0
CHANGES=0
AS_ROOT=0

usage() {
  cat <<'EOF'
Usage : install.sh [--check]

  (sans option)  installe ou met à jour scripts et unités, pose les droits,
                 recharge systemd. N'écrase jamais backup.env ni le mot de passe.
  --check        compare le serveur au dépôt sans rien modifier ; code 1 si écart.
  -h, --help     cette aide.
EOF
}

# note CATÉGORIE MESSAGE — un écart constaté (et corrigé hors --check).
note() {
  CHANGES=$((CHANGES + 1))
  if ((CHECK)); then
    warn "ÉCART $1 : $2"
  else
    info "$1 : $2"
  fi
}

# ensure_attrs CHEMIN MODE — droits et propriétaire attendus.
ensure_attrs() {
  local path=$1 mode=$2 cur owner
  cur=$(stat -c '%a' -- "$path")
  if [[ $cur != "${mode#0}" ]]; then
    note droits "$path : $cur -> ${mode#0}"
    ((CHECK)) || chmod "$mode" -- "$path"
  fi
  if ((AS_ROOT)); then
    owner=$(stat -c '%u:%g' -- "$path")
    if [[ $owner != 0:0 ]]; then
      note propriétaire "$path : $owner -> 0:0"
      ((CHECK)) || chown 0:0 -- "$path"
    fi
  fi
  return 0
}

ensure_dir() {
  local dir=$1 mode=$2
  if [[ ! -d $dir ]]; then
    note création "dossier $dir ($mode)"
    ((CHECK)) && return 0
    install -d -m "$mode" -- "$dir"
  fi
  ensure_attrs "$dir" "$mode"
}

# ensure_file SOURCE DESTINATION MODE — copie si le contenu diffère.
ensure_file() {
  local src=$1 dst=$2 mode=$3
  [[ -f $src ]] || die "fichier absent de la source : $src (copie incomplète du dépôt ?)"
  if [[ ! -e $dst ]]; then
    note installation "$dst"
    ((CHECK)) && return 0
    install -m "$mode" -- "$src" "$dst"
  elif ! cmp -s -- "$src" "$dst"; then
    note "mise à jour" "$dst (diff : version installée -> version du dépôt)"
    diff -u --label "installé  $dst" --label "dépôt     $src" -- "$dst" "$src" || true
    ((CHECK)) && return 0
    install -m "$mode" -- "$src" "$dst"
  fi
  ensure_attrs "$dst" "$mode"
}

# Noms de variables présents dans le gabarit mais absents de la configuration
# réelle : typiquement après une mise à jour qui en ajoute.
report_missing_variables() {
  local conf=$1 name
  local -a missing=()
  while IFS= read -r name; do
    grep -Eq "^[[:space:]]*(export[[:space:]]+)?${name}=" -- "$conf" || missing+=("$name")
  done < <(grep -oE '^[A-Z][A-Z0-9_]*=' -- "$SRC/.env.example" | tr -d '=' | sort -u)
  if ((${#missing[@]} > 0)); then
    warn "variables absentes de $conf, à ajouter depuis .env.example : $(join_by ' ' "${missing[@]}")"
  fi
}

install_config() {
  local conf=$CONF_DIR/backup.env pw=$CONF_DIR/restic-password

  ensure_dir "$CONF_DIR" 0700
  ensure_dir "$CONF_DIR/ssh" 0700

  if [[ -e $conf ]]; then
    ((CHECK)) || [[ -r $conf ]] || die "$conf illisible"
    ensure_attrs "$conf" 0600
    report_missing_variables "$conf"
  else
    note création "$conf depuis .env.example, À RENSEIGNER"
    if ((!CHECK)); then
      install -m 0600 -- "$SRC/.env.example" "$conf"
      ensure_attrs "$conf" 0600
    fi
  fi

  if [[ -e $pw ]]; then
    ensure_attrs "$pw" 0600
  else
    warn "$pw absent : à créer depuis le gestionnaire de mots de passe (RUNBOOK-BACKUP.md, étape 7)"
  fi
}

report_unknown_files() {
  local f known name
  known=" $(join_by ' ' "${SCRIPTS[@]}" "${LIBS[@]}") "
  for f in "$LIB_DIR"/*; do
    [[ -e $f ]] || continue
    name=${f##*/}
    [[ $known == *" $name "* ]] || warn "fichier inconnu du dépôt dans $LIB_DIR : $name (laissé en place)"
  done
}

main() {
  local f
  while (($# > 0)); do
    case $1 in
      --check) CHECK=1; shift ;;
      -h | --help) usage; exit 0 ;;
      *) usage; exit 1 ;;
    esac
  done

  if [[ $EUID -eq 0 ]]; then
    AS_ROOT=1
  elif [[ -z $DESTDIR ]]; then
    require_root
  fi
  require_cmds install cmp diff stat
  trap 'on_err $? $LINENO "$BASH_COMMAND"' ERR

  if ((CHECK)); then
    info "comparaison du serveur au dépôt ($SRC), sans modification"
  else
    info "installation depuis $SRC"
  fi

  ensure_dir "$LIB_DIR" 0755
  for f in "${SCRIPTS[@]}"; do
    ensure_file "$SRC/$f" "$LIB_DIR/$f" 0755
  done
  for f in "${LIBS[@]}"; do
    ensure_file "$SRC/$f" "$LIB_DIR/$f" 0644
  done
  report_unknown_files

  ensure_dir "$UNIT_DIR" 0755
  for f in "${UNITS[@]}"; do
    ensure_file "$SRC/$f" "$UNIT_DIR/$f" 0644
  done

  install_config

  if ((!CHECK)) && [[ -z $DESTDIR ]]; then
    # Toujours, même sans changement : sans effet de bord, et rattrape une
    # exécution précédente interrompue entre la copie et le rechargement.
    systemctl daemon-reload
    info "systemd rechargé"
  fi

  if ((CHECK)); then
    if ((CHANGES > 0)); then
      error "BILAN : $CHANGES écart(s) entre le serveur et le dépôt"
      exit 1
    fi
    info "BILAN : serveur identique au dépôt"
  else
    info "BILAN : $CHANGES modification(s) appliquée(s)"
  fi
}

main "$@"
