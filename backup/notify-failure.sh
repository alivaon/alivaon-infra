#!/usr/bin/env bash
#
# Notification d'échec, déclenchée par alivaon-backup-failure.service via la
# directive OnFailure= de alivaon-backup.service.
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

UNIT=${1:-alivaon-backup.service}

main() {
  local invocation excerpt
  excerpt=$(mktemp)
  trap 'rm -f -- "$excerpt"' EXIT

  # Dernière exécution de l'unité uniquement, pas l'historique complet.
  invocation=$(systemctl show -p InvocationID --value "$UNIT" 2>/dev/null || true)
  if [[ -n $invocation ]]; then
    journalctl --no-pager -o short-iso "_SYSTEMD_INVOCATION_ID=$invocation" | tail -n 40 >"$excerpt" || true
  fi
  if [[ ! -s $excerpt ]]; then
    journalctl --no-pager -o short-iso -u "$UNIT" -n 40 >"$excerpt" || true
  fi

  error "ÉCHEC de $UNIT — dernières lignes :"
  while IFS= read -r line; do
    error "  | $line"
  done <"$excerpt"

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
