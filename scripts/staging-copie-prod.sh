#!/usr/bin/env bash
# Copie ANONYMISÉE de la production vers le staging : base + fichiers publics
# (uploads). Sert au dernier contrôle de parité SEO avant la bascule du site.
#
# À lancer depuis le Mac (le script s'exécute sur le VPS) :
#   ssh alivaon 'bash -s' < scripts/staging-copie-prod.sh
#
# Production : LECTURE SEULE (mysqldump --single-transaction, volume des
# uploads monté en :ro). Rien n'y est arrêté ni modifié.
# Ne quittent jamais la production :
#   - la table `user` (comptes et mots de passe) : le staging garde les siens ;
#   - `messenger_messages` (emails en attente) ;
#   - le volume `cv_private` (CV des candidats).
# Données personnelles importées puis anonymisées aussitôt, application du
# staging arrêtée pendant toute l'opération ; en cas d'échec, les tables
# personnelles du staging sont vidées (trap).
# Retour arrière : sauvegardes dans /opt/alivaon/backups/staging-<horodatage>/.
set -Eeuo pipefail

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP="/opt/alivaon/backups/staging-$TS"
STAGING_DIR=/opt/alivaon/staging
PERSONAL_TABLES="candidate_application contact_message comment"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

# Client MySQL dans un conteneur de base, identifiants lus DANS le conteneur
# (jamais affichés ni passés en argument sur l'hôte).
mysql_in()     { docker exec -i "$1" sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -u root "$MYSQL_DATABASE"'; }
# Valeur seule, sans en-tête (-N) : MySQL prend sinon l'expression pour titre.
mysql_value()  { docker exec -i "$1" sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -N -B -u root "$MYSQL_DATABASE"'; }
mysqldump_in() { docker exec "$1" sh -c "MYSQL_PWD=\"\$MYSQL_ROOT_PASSWORD\" exec mysqldump -u root --single-transaction --no-tablespaces --routines --triggers $2 \"\$MYSQL_DATABASE\""; }

for c in production-db-1 staging-db-1; do
  docker inspect -f '{{.State.Running}}' "$c" | grep -q true || { echo "ERREUR : $c ne tourne pas"; exit 1; }
done
# app peut être arrêté (reprise après un échec) : il doit seulement exister.
docker inspect staging-app-1 >/dev/null || { echo "ERREUR : staging-app-1 introuvable"; exit 1; }
for c in production-db-1 staging-db-1; do
  docker exec "$c" sh -c 'test -n "$MYSQL_DATABASE" && test -n "$MYSQL_ROOT_PASSWORD"' || { echo "ERREUR : variables MySQL absentes dans $c"; exit 1; }
done

log "1. Sauvegardes du staging → $BACKUP"
mkdir -p "$BACKUP" && chmod 700 "$BACKUP"
mysqldump_in staging-db-1 "" | gzip > "$BACKUP/staging-db.sql.gz"
test -s "$BACKUP/staging-db.sql.gz"
docker run --rm --user 0:0 -v staging_uploads_staging:/src:ro -v "$BACKUP":/dst --entrypoint sh \
  ghcr.io/alivaon/alivaon-symfony:staging -c 'tar -C /src -czf /dst/staging-uploads.tar.gz .'

log "2. Arrêt de l'application et du front du staging"
cd "$STAGING_DIR"
docker compose stop web app

cleanup_on_error() {
  log "ÉCHEC : vidage des tables personnelles du staging par précaution"
  for t in $PERSONAL_TABLES; do echo "SET FOREIGN_KEY_CHECKS=0; TRUNCATE TABLE \`$t\`;" | mysql_in staging-db-1 || true; done
  log "Staging laissé arrêté (app, web). Restauration : voir docs/next.md, « Copie de la production »."
}
trap cleanup_on_error ERR

log "3. Base : production → staging (sans user ni messenger_messages)"
DB="$(docker exec production-db-1 sh -c 'printf %s "$MYSQL_DATABASE"')"
mysqldump_in production-db-1 "--ignore-table=$DB.user --ignore-table=$DB.messenger_messages" | mysql_in staging-db-1

log "4. Anonymisation"
mysql_in staging-db-1 <<'SQL'
UPDATE candidate_application SET
  first_name    = 'Candidat',
  last_name     = CONCAT('n°', id),
  email         = CONCAT('candidat-', id, '@staging.invalid'),
  phone         = NULL,
  linkedin_url  = NULL,
  portfolio_url = NULL,
  motivation    = 'Lettre de motivation anonymisée (copie de la production pour le staging).',
  cv_file_name  = NULL;
UPDATE contact_message SET
  name       = CONCAT('Contact n°', id),
  email      = CONCAT('contact-', id, '@staging.invalid'),
  phone      = NULL,
  message    = 'Message anonymisé (copie de la production pour le staging).',
  ip_address = NULL;
UPDATE comment SET
  author_name  = CONCAT('Lecteur n°', id),
  author_email = CONCAT('lecteur-', id, '@staging.invalid'),
  ip_address   = NULL;
SQL

log "5. Contrôle de l'anonymisation"
LEFT="$(mysql_value staging-db-1 <<'SQL'
SELECT (SELECT COUNT(*) FROM candidate_application WHERE email NOT LIKE '%@staging.invalid' OR phone IS NOT NULL OR cv_file_name IS NOT NULL)
     + (SELECT COUNT(*) FROM contact_message WHERE email NOT LIKE '%@staging.invalid' OR phone IS NOT NULL OR ip_address IS NOT NULL)
     + (SELECT COUNT(*) FROM comment WHERE author_email NOT LIKE '%@staging.invalid' OR ip_address IS NOT NULL);
SQL
)"
[ "$LEFT" = "0" ] || { echo "ERREUR : $LEFT ligne(s) non anonymisée(s)"; false; }
trap - ERR

log "6. Fichiers publics : production_uploads (lecture seule) → staging_uploads_staging"
docker run --rm --user 0:0 -v production_uploads:/src:ro -v staging_uploads_staging:/dst --entrypoint sh \
  ghcr.io/alivaon/alivaon-symfony:staging -c 'find /dst -mindepth 1 -delete && cp -a /src/. /dst/'

log "7. Redémarrage (web recréé : cache de Next vidé)"
docker compose start app
docker compose up -d --force-recreate --no-deps web
for svc in app web; do
  for _ in $(seq 1 45); do
    status="$(docker inspect -f '{{.State.Health.Status}}' "$(docker compose ps -q "$svc")")"
    [ "$status" = "healthy" ] && break
    sleep 2
  done
  [ "$status" = "healthy" ] || { echo "ERREUR : $svc n'est pas healthy"; docker compose logs --tail=40 "$svc"; exit 1; }
done

log "8. Bilan"
mysql_in staging-db-1 <<'SQL'
SELECT 'articles' t, COUNT(*) n FROM article UNION ALL SELECT 'projets', COUNT(*) FROM project
UNION ALL SELECT 'offres', COUNT(*) FROM job_offer UNION ALL SELECT 'candidatures (anonymisées)', COUNT(*) FROM candidate_application
UNION ALL SELECT 'messages (anonymisés)', COUNT(*) FROM contact_message UNION ALL SELECT 'comptes du staging', COUNT(*) FROM user;
SQL
docker compose exec -T app php bin/console doctrine:migrations:status --no-interaction 2>/dev/null | grep -E "Executed|Available|New|Unavailable" || true
log "Terminé. Sauvegardes : $BACKUP"
