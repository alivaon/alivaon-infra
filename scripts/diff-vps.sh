#!/usr/bin/env bash
#
# Compare, fichier par fichier, la version du dépôt et celle du VPS, puis
# contrôle quelques invariants qui ne se lisent pas dans un fichier.
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
# CE QUI EST COMPARÉ
#   Tous les */docker-compose.yml du dépôt, découverts automatiquement, plus
#   first-deploy.sh et traefik/traefik.yml. La liste n'est plus écrite en dur :
#   un nouveau service déposé dans son propre dossier est couvert sans toucher
#   à ce script. Le sens inverse est vérifié aussi — une stack présente sur le
#   VPS mais absente du dépôt est signalée.
#
# CE QUI EST CONTRÔLÉ EN PLUS DES FICHIERS
#   Les « réseaux porteurs » (tout réseau Docker dont le nom contient
#   « porteur ») doivent avoir enable_ip_masquerade=false.
#
#   Ces réseaux existent parce que, depuis Docker 28, un conteneur rattaché
#   uniquement à des réseaux `internal` ne publie plus aucun port. Ils rendent
#   la publication possible ; l'option enable_ip_masquerade=false leur retire
#   le NAT sortant, donc tout accès Internet.
#
#   Cette option ne vit PAS dans le docker-compose.yml une fois le réseau créé :
#   Compose ne recrée pas un réseau existant. Un réseau recréé à la main sans
#   l'option serait donc d'apparence identique, les conteneurs démarreraient
#   normalement, et Adminer comme File Browser retrouveraient un accès Internet
#   — sans le moindre message. D'où cette assertion.
#
# CODES DE SORTIE
#   0  dépôt et serveur identiques, invariants respectés
#   1  au moins un écart entre un fichier du dépôt et celui du serveur
#   2  fichier absent du serveur, stack inconnue du dépôt, ou serveur injoignable
#   3  régression sur un réseau porteur (NAT sortant réactivé)
#
set -uo pipefail

HOTE="${VPS_HOST:-alivaon}"
BASE="${VPS_BASE:-/opt/alivaon}"
VERBEUX=0
[ "${1:-}" = "-v" ] && VERBEUX=1

cd "$(dirname "$0")/.." || exit 2

# ── Liste des fichiers : découverte, plus les deux fichiers hors convention ──
FICHIERS=("first-deploy.sh" "traefik/traefik.yml")
while IFS= read -r f; do
  FICHIERS+=("$f")
done < <(find . -mindepth 2 -maxdepth 2 -name docker-compose.yml | sed 's|^\./||' | sort)

# sha256sum côté Linux, shasum côté macOS.
if command -v sha256sum >/dev/null 2>&1; then
  LOCAL_HASH() { sha256sum "$1" | cut -d' ' -f1; }
else
  LOCAL_HASH() { shasum -a 256 "$1" | cut -d' ' -f1; }
fi

ECARTS=0
ERREURS=0
REGRESSIONS=0

echo "Comparaison  dépôt  <->  ${HOTE}:${BASE}"
echo

for f in "${FICHIERS[@]}"; do
  distant="${BASE}/${f}"
  if [ ! -f "$f" ]; then
    printf '  ABSENT DU DÉPÔT  %s\n' "$f"
    ERREURS=$((ERREURS + 1))
    continue
  fi
  hl=$(LOCAL_HASH "$f")
  hr=$(ssh -n -o BatchMode=yes "$HOTE" "sha256sum '$distant' 2>/dev/null | cut -d' ' -f1")

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
      ssh -n -o BatchMode=yes "$HOTE" "cat '$distant'" | diff "$f" - | sed 's/^/                 /'
    fi
  fi
done

# ── Sens inverse : une stack sur le VPS que le dépôt ignore ─────────────────
echo
DISTANTS=$(ssh -n -o BatchMode=yes "$HOTE" "ls -1 ${BASE}/*/docker-compose.yml 2>/dev/null" | sed "s|^${BASE}/||")
if [ -z "$DISTANTS" ]; then
  echo "  Serveur injoignable, ou aucune stack trouvée dans ${BASE}."
  exit 2
fi
while IFS= read -r d; do
  [ -z "$d" ] && continue
  if [ ! -f "$d" ]; then
    printf '  INCONNU DU DÉPÔT  %s (présent sur le VPS)\n' "$d"
    ERREURS=$((ERREURS + 1))
  fi
done <<< "$DISTANTS"

# ── Invariant : pas de NAT sortant sur les réseaux porteurs ─────────────────
echo
echo "Réseaux porteurs — contrôle de enable_ip_masquerade"
PORTEURS=$(ssh -n -o BatchMode=yes "$HOTE" "docker network ls --format '{{.Name}}' | grep porteur" 2>/dev/null)
if [ -z "$PORTEURS" ]; then
  echo "  AUCUN réseau porteur trouvé sur le VPS."
  echo "  Les stacks adminer et filebrowser en déclarent ; leur absence signifie"
  echo "  qu'elles ne tournent pas, ou que la convention de nommage a changé."
  ERREURS=$((ERREURS + 1))
else
  while IFS= read -r n; do
    [ -z "$n" ] && continue
    # `ssh -n` est IMPÉRATIF dans une boucle `while read` : sans lui, ssh lit
    # l'entrée standard et consomme les lignes restantes de la liste. Le
    # contrôle passerait alors sur le premier réseau seulement, en silence.
    v=$(ssh -n -o BatchMode=yes "$HOTE" \
        "docker network inspect '$n' --format '{{index .Options \"com.docker.network.bridge.enable_ip_masquerade\"}}'" 2>/dev/null)
    if [ "$v" = "false" ]; then
      printf '  conforme       %s\n' "$n"
    else
      printf '  RÉGRESSION     %s : enable_ip_masquerade=%s (attendu : false)\n' "$n" "${v:-<absent>}"
      printf '                 Ce réseau donne un accès Internet aux conteneurs qui y sont\n'
      printf '                 rattachés. Le corriger impose de SUPPRIMER le réseau puis de\n'
      printf '                 relancer la stack : Compose ne recrée pas un réseau existant.\n'
      REGRESSIONS=$((REGRESSIONS + 1))
    fi
  done <<< "$PORTEURS"
fi

echo
if [ "$REGRESSIONS" -gt 0 ]; then
  echo "$REGRESSIONS réseau(x) porteur(s) en régression : le NAT sortant est réactivé."
  exit 3
elif [ "$ERREURS" -gt 0 ]; then
  echo "$ERREURS anomalie(s) de présence — le VPS n'est pas dans l'état décrit par ce dépôt."
  exit 2
elif [ "$ECARTS" -gt 0 ]; then
  echo "$ECARTS écart(s). Le dépôt n'est plus une photographie fidèle du serveur."
  echo "Relancer avec -v pour voir les différences, puis décider quel côté fait autorité."
  exit 1
else
  echo "Aucun écart, aucun invariant rompu : le dépôt et le serveur sont identiques."
  exit 0
fi
