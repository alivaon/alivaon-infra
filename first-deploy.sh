#!/usr/bin/env bash
#
# Bootstrap initial du VPS — IDEMPOTENT.
# Documente et automatise la mise en place minimale, sans rien casser de ce
# qui existe déjà (le serveur est en partie pré-configuré) :
#   - vérifie/crée le réseau Docker externe `traefik_proxy` ;
#   - vérifie/crée l'arborescence /opt/alivaon/{traefik,production,staging} ;
#   - lance (ou met à jour) la stack Traefik.
#
# Ce script NE modifie PAS les permissions existantes et NE recrée RIEN qui
# existe déjà. Il peut être relancé sans risque.
#
# Usage (sur le VPS, en tant qu'utilisateur alivaondev) :
#   ./first-deploy.sh
#
set -euo pipefail

BASE="/opt/alivaon"
NETWORK="traefik_proxy"

echo "==> Vérification du réseau Docker externe '${NETWORK}'"
if docker network inspect "$NETWORK" >/dev/null 2>&1; then
  echo "    déjà présent, on ne touche pas."
else
  echo "    absent, création."
  docker network create "$NETWORK"
fi

echo "==> Vérification de l'arborescence ${BASE}"
for d in traefik production staging; do
  target="${BASE}/${d}"
  if [ -d "$target" ]; then
    echo "    ${target} : déjà présent."
  else
    echo "    ${target} : création."
    # -p : ne renvoie pas d'erreur si un parent existe déjà.
    mkdir -p "$target"
  fi
done

# Dossier persistant des certificats Let's Encrypt (droits stricts requis).
LE_DIR="${BASE}/traefik/letsencrypt"
if [ ! -d "$LE_DIR" ]; then
  echo "==> Création du stockage Let's Encrypt (${LE_DIR})"
  mkdir -p "$LE_DIR"
fi
# acme.json doit être en 600 sinon Traefik refuse de démarrer.
if [ ! -f "${LE_DIR}/acme.json" ]; then
  echo "    initialisation acme.json (chmod 600)"
  touch "${LE_DIR}/acme.json"
  chmod 600 "${LE_DIR}/acme.json"
fi

echo "==> Démarrage / mise à jour de Traefik"
if [ -f "${BASE}/traefik/docker-compose.yml" ]; then
  ( cd "${BASE}/traefik" && docker compose up -d )
  echo "    Traefik lancé."
else
  echo "    ATTENTION : ${BASE}/traefik/docker-compose.yml manquant."
  echo "    Copiez d'abord traefik/traefik.yml et traefik/docker-compose.yml"
  echo "    (depuis le dépôt) dans ${BASE}/traefik/, puis relancez ce script."
  exit 1
fi

echo ""
echo "==> Bootstrap terminé."
echo "    Étapes suivantes (voir README-DEPLOY.md) :"
echo "      1. Déposer les docker-compose.yml + .env dans production/ et staging/"
echo "      2. Importer le dump MySQL initial et créer l'utilisateur applicatif"
echo "      3. Configurer les secrets GitHub et pousser sur develop/main"
