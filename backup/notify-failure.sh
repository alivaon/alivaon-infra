#!/usr/bin/env bash
#
# Notification d'échec, déclenchée par alivaon-backup-failure.service via la
# directive OnFailure= de alivaon-backup.service ET de
# alivaon-backup-verify.service (contrôle hebdomadaire).
#
# Unité en échec, par ordre de préférence :
#   1. argument explicite ;
#   2. $MONITOR_UNIT, transmis par systemd >= 251 aux unités OnFailure=
#      (Ubuntu 24.04) ;
#   3. à défaut (Ubuntu 22.04, systemd 249), toute unité du dispositif en état
#      « failed » ; si aucune ne l'est (déclenchement manuel, pour test),
#      alivaon-backup.service.
#
#   - journalise l'échec en priorité « err », avec les dernières lignes de
#     l'exécution fautive : `journalctl -p err` suffit à le retrouver ;
#   - si HC_PING_URL est renseigné, signale l'échec à healthchecks.io (ou
#     instance compatible), avec ces mêmes lignes en corps de requête.
#
# Doit fonctionner même quand la cause de l'échec est une configuration
# absente ou invalide : dans ce cas, seul le journal est alimenté.
#
# Le cas « la sauvegarde n'a jamais démarré » (timer désactivé, serveur
# éteint) ne passe PAS par ici : aucune unité n'échoue. Seul le dead man's
# switch le détecte, par l'absence de ping dans le délai attendu.
#
# Pas de `set -e`, délibérément : chaque étape est tentée, quoi qu'il arrive à
# la précédente. Un notificateur qui s'interrompt à la première erreur ne
# notifie rien.
#
# shellcheck source-path=SCRIPTDIR
set -Euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

readonly WATCHED_UNITS=(alivaon-backup.service alivaon-backup-verify.service)

failed_units() {
  local u
  if [[ -n ${1:-} ]]; then
    printf '%s\n' "$1"
    return
  fi
  if [[ -n ${MONITOR_UNIT:-} ]]; then
    printf '%s\n' "$MONITOR_UNIT"
    return
  fi
  local found=0
  for u in "${WATCHED_UNITS[@]}"; do
    if systemctl is-failed --quiet "$u" 2>/dev/null; then
      printf '%s\n' "$u"
      found=1
    fi
  done
  ((found)) || printf '%s\n' "${WATCHED_UNITS[0]}"
}

# unit_excerpt UNITÉ — dernières lignes de la dernière exécution de l'unité.
unit_excerpt() {
  local invocation out
  invocation=$(systemctl show -p InvocationID --value "$1" 2>/dev/null || true)
  if [[ -n $invocation ]]; then
    out=$(journalctl --no-pager -o short-iso "_SYSTEMD_INVOCATION_ID=$invocation" 2>/dev/null | tail -n 40 || true)
  fi
  if [[ -z ${out:-} ]]; then
    out=$(journalctl --no-pager -o short-iso -u "$1" -n 40 2>/dev/null || true)
  fi
  printf '%s\n' "${out:-(journal indisponible)}"
}

main() {
  local unit line text excerpt
  local -a units
  excerpt=$(mktemp)
  trap 'rm -f -- "$excerpt"' EXIT

  mapfile -t units < <(failed_units "${1:-}")
  for unit in "${units[@]}"; do
    text=$(unit_excerpt "$unit")
    printf '=== ÉCHEC de %s ===\n%s\n' "$unit" "$text" >>"$excerpt"
    error "ÉCHEC de $unit — dernières lignes :"
    while IFS= read -r line; do
      error "  | $line"
    done <<<"$text"
  done

  # Chargement dans un sous-shell d'abord : si la configuration est la cause
  # de l'échec, load_config quitterait ce script avant toute notification.
  if (load_config) >/dev/null 2>&1; then
    load_config
    hc_ping fail "$excerpt"
  else
    warn "configuration illisible : notification healthchecks impossible, seul le journal est alimenté"
  fi
}

main "$@"
