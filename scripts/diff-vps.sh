#!/usr/bin/env bash
#
# Compare, fichier par fichier, la version du dépôt et celle du VPS.
#
# POURQUOI
#   Ce dépôt est censé être une photographie fidèle de /opt/alivaon sur le
#   serveur. Rien ne garantit qu'il le reste : une modification faite en direct
#   sur le VPS, ou un commit non déployé, créent un écart silencieux. Ce script
#   le rend visible.
#
# À LANCER DEPUIS LE MAC, pas depuis le VPS : la comparaison suppose d'avoir les
# deux côtés sous la main. Le serveur ne connaît pas le contenu du dépôt, et y
# cloner un dépôt privé demanderait d'y déposer des identifiants GitHub — ce que
# cette infrastructure évite délibérément.
#
#   ./scripts/diff-vps.sh          compare par empreinte
#   ./scripts/diff-vps.sh -v       affiche le diff des fichiers qui divergent
#
# Seuls les 6 fichiers copiés du serveur sont comparés. Les autres (README,
# docs/, scripts/, .env.example) n'existent que dans le dépôt.
#
# CODES DE SORTIE
#   0  dépôt et serveur identiques
#   1  au moins un écart
#   2  fichier absent du serveur, ou serveur injoignable
#
set -uo pipefail

HOTE="${VPS_HOST:-alivaon}"
BASE="${VPS_BASE:-/opt/alivaon}"
VERBEUX=0
[ "${1:-}" = "-v" ] && VERBEUX=1

cd "$(dirname "$0")/.." || exit 2

FICHIERS=(
  "first-deploy.sh"
  "traefik/docker-compose.yml"
  "traefik/traefik.yml"
  "production/docker-compose.yml"
  "staging/docker-compose.yml"
  "portainer/docker-compose.yml"
)

# sha256sum côté Linux, shasum côté macOS.
if command -v sha256sum >/dev/null 2>&1; then
  LOCAL_HASH() { sha256sum "$1" | cut -d' ' -f1; }
else
  LOCAL_HASH() { shasum -a 256 "$1" | cut -d' ' -f1; }
fi

ECARTS=0
ERREURS=0

echo "Comparaison  dépôt  <->  ${HOTE}:${BASE}"
echo

for f in "${FICHIERS[@]}"; do
  distant="${BASE}/${f}"
  hl=$(LOCAL_HASH "$f")
  hr=$(ssh -o BatchMode=yes "$HOTE" "sha256sum '$distant' 2>/dev/null | cut -d' ' -f1")

  if [ -z "$hr" ]; then
    printf '  ABSENT DU VPS  %s\n' "$f"
    ERREURS=$((ERREURS + 1))
  elif [ "$hl" = "$hr" ]; then
    printf '  identique      %s\n' "$f"
  else
    printf '  ÉCART          %s\n' "$f"
    printf '                 dépôt : %s\n' "$hl"
    printf '                 VPS   : %s\n' "$hr"
    ECARTS=$((ECARTS + 1))
    if [ "$VERBEUX" = "1" ]; then
      echo "                 --- diff (< dépôt, > VPS) ---"
      ssh -o BatchMode=yes "$HOTE" "cat '$distant'" | diff "$f" - | sed 's/^/                 /'
    fi
  fi
done

echo
if [ "$ERREURS" -gt 0 ]; then
  echo "$ERREURS fichier(s) absent(s) du serveur — le VPS n'est pas dans l'état décrit par ce dépôt."
  exit 2
elif [ "$ECARTS" -gt 0 ]; then
  echo "$ECARTS écart(s). Le dépôt n'est plus une photographie fidèle du serveur."
  echo "Relancer avec -v pour voir les différences, puis décider quel côté fait autorité."
  exit 1
else
  echo "Aucun écart : le dépôt et le serveur sont identiques."
  exit 0
fi
