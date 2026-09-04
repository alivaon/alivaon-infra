#!/usr/bin/env bash
#
# Détecte la chute silencieuse du BasicAuth protégeant le préprod.
#
# POURQUOI CE CONTRÔLE EXISTE
#   staging/docker-compose.yml construit le middleware BasicAuth à partir d'une
#   variable interpolée côté hôte :
#       traefik.http.middlewares.staging-auth.basicauth.users=${STAGING_BASICAUTH}
#   Si la variable manque dans staging/.env, Docker Compose la remplace par une
#   CHAÎNE VIDE, sans avertissement ni code d'erreur. La stack démarre, les
#   conteneurs passent « healthy », les journaux sont propres — et le préprod
#   devient public et indexable. Aucun symptôme ne remonte.
#
#   Ce script est la seule chose qui distingue les deux situations.
#
# CE SCRIPT N'EST PAS INSTALLÉ
#   Ni cron, ni pipeline. À lancer à la main après chaque redéploiement du
#   staging, ou à brancher sur la supervision / en fin de job de déploiement.
#
# UTILISATION
#   ./scripts/check-staging-auth.sh
#
# CODES DE SORTIE
#   0  protection active (401 attendu)
#   1  PROTECTION TOMBÉE (200) — le préprod est public
#   2  réponse inattendue ou site injoignable
#
set -uo pipefail

URL="${STAGING_URL:-https://www.staging.alivaon.com}"
ATTENDU=401

CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$URL" 2>/dev/null)

case "$CODE" in
  "$ATTENDU")
    echo "OK — $URL renvoie $CODE : le BasicAuth est actif."
    exit 0
    ;;
  200)
    echo "ALERTE — $URL renvoie 200 au lieu de $ATTENDU."
    echo
    echo "Le BasicAuth ne protège plus le préprod. Il est PUBLIC et INDEXABLE."
    echo
    echo "Cause la plus probable : STAGING_BASICAUTH absente ou vide dans"
    echo "/opt/alivaon/staging/.env, remplacée par une chaîne vide par Compose."
    echo
    echo "Vérifier (sans afficher la valeur) :"
    echo "  ssh alivaon 'grep -c \"^STAGING_BASICAUTH=.\\+\" /opt/alivaon/staging/.env'"
    echo "  → 1 = renseignée, 0 = absente ou vide"
    echo
    echo "Vérifier le label réellement appliqué au conteneur :"
    echo "  ssh alivaon 'docker inspect staging-app-1 --format \"{{index .Config.Labels \\\"traefik.http.middlewares.staging-auth.basicauth.users\\\"}}\"'"
    echo "  → une sortie vide confirme le diagnostic"
    echo
    echo "Corriger : renseigner STAGING_BASICAUTH puis"
    echo "  ssh alivaon 'cd /opt/alivaon/staging && docker compose up -d'"
    exit 1
    ;;
  000)
    echo "ERREUR — $URL injoignable (délai dépassé, DNS ou TLS)."
    echo "Ce script ne se prononce pas : vérifier que le site répond avant de conclure."
    exit 2
    ;;
  404)
    echo "ALERTE — $URL renvoie 404."
    echo
    echo "Depuis Traefik v3.6.19, un middleware BasicAuth construit avec une liste"
    echo "d'utilisateurs vide renvoie 404 et non 401. Ce code est donc, lui aussi,"
    echo "un signe probable de STAGING_BASICAUTH manquante — à distinguer d'un 404"
    echo "applicatif légitime. Vérifier le label du conteneur (commande ci-dessus)."
    exit 2
    ;;
  *)
    echo "INATTENDU — $URL renvoie $CODE (attendu $ATTENDU)."
    echo "Ni protection confirmée, ni panne confirmée. Investiguer avant de conclure."
    exit 2
    ;;
esac
