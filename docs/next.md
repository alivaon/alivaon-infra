# Front Next.js — intégration au VPS

Le site public et le back-office passent de Symfony/Twig/EasyAdmin à Next.js
(dépôt `alivaon-next`). Symfony reste le backend (API). Ce document décrit le
routage Traefik et la mise en service, **staging d'abord**.

Règle absolue : le site public ne remplace Symfony sur `www` qu'après un
contrôle de parité SEO sans écart (`alivaon-next/docs/seo-parity.md`).

## Services

| Service | Image | Rôle |
|---|---|---|
| `app` | `ghcr.io/alivaon/alivaon-symfony:<env>` | Symfony : API, fichiers (`/uploads`), sitemap, robots, site Twig tant qu'il n'est pas remplacé |
| `web` | `ghcr.io/alivaon/alivaon-next-site:<env>` | Site public Next.js |
| `admin` | `ghcr.io/alivaon/alivaon-next-admin:<env>` | Back-office Next.js |

`web` rejoint `traefik_proxy` et le réseau interne ; `admin` seulement
`traefik_proxy` (ses appels passent par son propre hôte). Ils ne reçoivent
**aucun** secret Symfony (variables `environment:` explicites, pas
d'`env_file`).

**Noms internes : toujours un alias propre à la pile**, jamais `app` ni
`web`. Les piles staging et production partagent `traefik_proxy`, et le DNS
Docker y résout `app` vers les deux Symfony à la fois (constaté le
24/09/2026 : le front du staging lisait au hasard l'API de production).
Staging : `staging-api` (Symfony) et `staging-site` (Next), déclarés sur le
réseau interne ; production à la bascule : `production-api` et
`production-site`.

Chaque dépôt ne tire et ne relance **que ses services** :
- `alivaon-symfony` → `docker compose pull app` / `up -d app` (branche
  `ci/deploy-scoped-services`, prérequis) ;
- `alivaon-next` → `docker compose pull web admin` / `up -d --no-deps web admin`.

Un `pull` global échouerait : le `GITHUB_TOKEN` d'un dépôt ne lit pas les images
de l'autre.

## Hôtes : la forme `www` est canonique

Comme `alivaon.com` → `www.alivaon.com`, chaque hôte n'est servi que sous sa
forme `www` ; la forme sans `www` redirige en **301** (routeur dédié, service
`noop@internal`, déclaré sur le conteneur de l'hôte : un redémarrage de
Symfony ne coupe pas la redirection).

| Forme sans www (301) | Hôte canonique |
|---|---|
| `admin.alivaon.com` | `www.admin.alivaon.com` |
| `admin.staging.alivaon.com` | `www.admin.staging.alivaon.com` |
| `preview.staging.alivaon.com` | `www.preview.staging.alivaon.com` |

## Routage staging

Tous les hôtes sont derrière la BasicAuth du staging.

| Hôte | Chemins | Service | Priorité |
|---|---|---|---|
| `www.staging.alivaon.com` | tout | `app` (Symfony, inchangé) | — |
| `www.admin.staging.alivaon.com` | `/api/admin`, `/api/auth`, `/uploads/` | `app` | 100 |
| `www.admin.staging.alivaon.com` | tout le reste | `admin` | 10 |
| `www.preview.staging.alivaon.com` | `/api/public`, `/uploads/`, `/sitemap.xml`, `/robots.txt`, `/llms.txt` | `app` | 100 |
| `www.preview.staging.alivaon.com` | tout le reste | `web` | 10 |

Les hôtes admin et preview renvoient aussi `X-Robots-Tag: noindex, nofollow`.
`/api/admin` n'est jamais routé sur `preview` ni sur `www.staging`.

## Routage de production

### En service (back-office, depuis le 24/09/2026)

| Hôte | Chemins | Service | Priorité |
|---|---|---|---|
| `www.alivaon.com` (et apex → 301) | `/api`, `/api/…` | `app`, chemin remplacé : même 404 Symfony qu'avant l'API | 100 |
| `www.alivaon.com` (et apex → 301) | tout le reste | `app` (site Twig et EasyAdmin, inchangés) | — |
| `www.admin.alivaon.com` | `/api/admin`, `/api/auth`, `/uploads/` | `app` | 100 |
| `www.admin.alivaon.com` | tout le reste | `admin` (+ `X-Robots-Tag: noindex, nofollow`) | 10 |

EasyAdmin reste disponible sur `www.alivaon.com/admin` pendant la prise en
main du nouveau back-office.

### Cible à la bascule du site (phase 5, non appliquée)

| Hôte | Chemins | Service |
|---|---|---|
| `www.alivaon.com` | `/api/public`, `/uploads/`, `/sitemap.xml`, `/robots.txt`, `/llms.txt`, `/invitation` | `app` |
| `www.alivaon.com` | `/admin*`, `/login` | redirection 301 vers `www.admin.alivaon.com` |
| `www.alivaon.com` | tout le reste | `web` |

Retour arrière de la bascule : remettre le routeur `www` → `app` (quelques
minutes, la base ne change pas).

## Mise en service du staging — runbook

Ordre impératif : le pipeline Symfony limité à `app` doit être en production
**avant** que le compose du staging contienne `web` et `admin`.

### 1. Pipeline Symfony limité à `app`

Fusion de la branche `ci/deploy-scoped-services` d'alivaon-symfony (PR, puis
déploiement habituel).

### 2. DNS

Chez le registrar, deux enregistrements A vers l'IP du VPS (la même que
`www.staging.alivaon.com`) :

- `admin.staging.alivaon.com` et `www.admin.staging.alivaon.com`
- `preview.staging.alivaon.com` et `www.preview.staging.alivaon.com`

Vérifier la propagation.

Mac :
```bash
dig +short www.admin.staging.alivaon.com
```

Mac :
```bash
dig +short www.preview.staging.alivaon.com
```

Les deux doivent renvoyer l'IP du VPS. Le certificat Let's Encrypt est obtenu
automatiquement au premier accès (défi HTTP).

### 3. Dépôt GitHub `alivaon/alivaon-next`

Mac (dans `alivaon-next`) :
```bash
gh repo create alivaon/alivaon-next --private --source . --push
```

Secrets de déploiement (mêmes valeurs que ceux d'alivaon-symfony).

Mac :
```bash
gh secret set VPS_HOST --repo alivaon/alivaon-next
```

Mac :
```bash
gh secret set VPS_USER --repo alivaon/alivaon-next
```

Mac :
```bash
gh secret set VPS_SSH_KEY --repo alivaon/alivaon-next < ~/.ssh/CLE_DE_DEPLOIEMENT
```

### 4. Secret de régénération

Mac :
```bash
php -r 'echo bin2hex(random_bytes(32)), PHP_EOL;'
```

Ajouter à `/opt/alivaon/staging/.env`, avec la valeur générée :

```dotenv
NEXT_REVALIDATE_URL=http://staging-site:3000/api/revalidate
NEXT_REVALIDATE_SECRET=<valeur générée>
```

Mac :
```bash
ssh alivaon
```

VPS :
```bash
nano /opt/alivaon/staging/.env
```

VPS :
```bash
exit
```

### 5. Nouveau compose du staging

Mac (dans `alivaon-infra`, branche `feat/next-staging` fusionnée) :
```bash
scp staging/docker-compose.yml alivaon:/opt/alivaon/staging/docker-compose.yml
```

### 6. Premier déploiement du front

Un push sur une branche d'alivaon-next (autre que `main`) publie les images et
démarre `web` et `admin` sur le staging (workflow `Deploy`).

### 7. Contrôles

Mac :
```bash
curl -s -o /dev/null -w '%{http_code}\n' https://www.admin.staging.alivaon.com
```

Mac :
```bash
curl -s -o /dev/null -w '%{http_code}\n' https://www.preview.staging.alivaon.com
```

Mac :
```bash
curl -s -o /dev/null -w '%{http_code}\n' https://www.staging.alivaon.com
```

Les trois doivent renvoyer **401** (BasicAuth). Un 200 signifie que la
protection est tombée (`STAGING_BASICAUTH` vide, voir « Pièges connus » du
README).

## Mise en production du back-office — runbook

Appliqué le 24/09/2026 (voir le journal). Ordre retenu pour ne redémarrer
Symfony qu'une fois :

1. Compose de production (service `admin`, routeurs) copié sur le serveur,
   **sans redémarrage** (sauvegarde + `diff-vps.sh` avant/après).
2. Fusion de l'API dans `main` d'alivaon-symfony : le pipeline recrée `app`
   (nouvelle image et nouveaux routeurs d'un coup). Base non recréée : le
   `.env` de production n'est pas modifié.
3. Push sur `main` d'alivaon-next : image `alivaon-next-admin:production`,
   déploiement du seul service `admin`.
4. Contrôles : parité SEO de `www` contre la référence de production
   (`pnpm seo:snapshot --origin https://www.alivaon.com --seeds-from
   prod-2026-09-24 --label _work/…` puis `pnpm seo:compare`), `/api` en 404 sur
   `www`, `admin.alivaon.com` → 301, TLS, `noindex`, connexion.

### Retour arrière

Back-office seul (le site n'en dépend pas) :

VPS :
```bash
cd /opt/alivaon/production && docker compose stop admin
```

Symfony : revenir à la version d'avant l'API (commit `c15eab7`). Le serveur
ne garde pas les anciennes images et le registre est privé : relancer le
déploiement GitHub de ce commit, qui reconstruit et redéploie cette version
(`app` seul) :

Mac :
```bash
gh run rerun 35972439677 --repo alivaon/alivaon-symfony
```

Ou, pour un retour durable, `git revert -m 1 <merge de la PR #140>` sur `main`.

Routage : restaurer `docker-compose.yml.bak-20260924-143902` (production)
puis `docker compose up -d --no-deps app`, et remettre le dépôt en accord
(revert des PR #3 et #4).

## Copie de la production vers le staging (anonymisée)

Pour le dernier contrôle de parité avant la bascule : le staging reçoit le
contenu de la production (base + fichiers publics), données personnelles
anonymisées. Autorisée par le propriétaire le 24/09/2026.

Mac :
```bash
./scripts/diff-vps.sh
ssh alivaon 'bash -s' < scripts/staging-copie-prod.sh
./scripts/diff-vps.sh
```

Ce que fait `scripts/staging-copie-prod.sh` (sur le VPS) :

1. sauvegarde la base et les uploads du staging dans
   `/opt/alivaon/backups/staging-<horodatage>/` ;
2. arrête `app` et `web` du staging (pas `db`) ;
3. copie la base de production **sans** `user` (le staging garde ses comptes)
   ni `messenger_messages` ; production en lecture seule
   (`mysqldump --single-transaction`) ;
4. anonymise `candidate_application`, `contact_message` et `comment`
   (adresses `@staging.invalid`, téléphones, IP, CV et textes libres) et
   vérifie qu'il ne reste aucune ligne en clair — sinon vide ces tables et
   s'arrête ;
5. remplace les uploads du staging par ceux de la production (volume monté en
   lecture seule) ; `cv_private` n'est jamais copié ;
6. redémarre `app`, recrée `web` (cache de Next vidé) et affiche un bilan.

Restauration du staging d'avant la copie (VPS) :
```bash
cd /opt/alivaon/staging && docker compose stop web app
B=/opt/alivaon/backups/staging-<horodatage>
gunzip -c $B/staging-db.sql.gz | docker exec -i staging-db-1 sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -u root "$MYSQL_DATABASE"'
docker run --rm --user 0:0 -v staging_uploads_staging:/dst -v $B:/src:ro --entrypoint sh ghcr.io/alivaon/alivaon-symfony:staging -c 'find /dst -mindepth 1 -delete && tar -C /dst -xzf /src/staging-uploads.tar.gz'
docker compose start app && docker compose up -d --force-recreate --no-deps web
```

## Journal des actions sur le serveur

Actions exécutées directement sur le VPS (accès SSH accordé par le
propriétaire le 24/09/2026). Chaque fichier modifié est sauvegardé à côté
(`*.bak-AAAAMMJJ-HHMMSS`).

| Date | Action | Sauvegarde |
|---|---|---|
| 24/09/2026 10:19 | `diff-vps.sh` depuis `main` : serveur identique au dépôt | — |
| 24/09/2026 10:19 | Clé SSH dédiée au déploiement d'alivaon-next (ED25519, `SHA256:AOqe0EdM7bnKoHIy8zidQb4O/qZA504oyMwm27Jwovk`) ajoutée à `~alivaondev/.ssh/authorized_keys` ; clé privée uniquement dans le secret `VPS_SSH_KEY` du dépôt (supprimée du poste). Révocation : retirer la ligne « github-actions alivaon-next » | `authorized_keys.bak-20260924-101919` |
| 24/09/2026 10:20 | `NEXT_REVALIDATE_URL` et `NEXT_REVALIDATE_SECRET` (64 caractères) ajoutés à `/opt/alivaon/staging/.env` | `.env.bak-20260924-102008` |
| 24/09/2026 10:51 | DNS `admin.staging` et `preview.staging` → 178.104.185.156 vérifié sur ns1 et ns2 d'o2switch | — |
| 24/09/2026 10:51 | `diff-vps.sh` : identique ; PR #1 fusionnée ; `staging/docker-compose.yml` copié ; `diff-vps.sh` après : identique | `docker-compose.yml.bak-20260924-105146` |
| 24/09/2026 10:52 | Premier déploiement du front (branche `deploy/staging` d'alivaon-next) : `web` et `admin` créés, healthy | — |
| 24/09/2026 10:54 | `docker compose up -d app` : app recréé (nouveaux routeurs, variables de régénération). **db recréée aussi** (son `.env` a changé) : coupure de quelques secondes, données intactes (volume) | — |
| 24/09/2026 10:54 | Certificats Let's Encrypt obtenus pour `admin.staging` et `preview.staging` (1re tentative sur `preview` refusée : un validateur voyait encore l'ancienne IP ; 2e réussie) | — |
| 24/09/2026 10:55 | Contrôles : 401 + TLS valide sur les 3 hôtes ; web → API interne avec hôte public ; app → régénération 200, sans secret 401 ; production inchangée | — |
| 24/09/2026 14:25 | `diff-vps.sh` depuis `main` : identique | — |
| 24/09/2026 14:39 | PR #3 (admin en production) et #4 (hôtes canoniques en www) fusionnées ; `diff-vps.sh` : exactement 2 écarts attendus (les deux composes) ; composes production et staging copiés, `docker compose config` valide ; `diff-vps.sh` après : identique. **Aucun redémarrage en production à cette étape** | `production/docker-compose.yml.bak-20260924-143902`, `staging/docker-compose.yml.bak-20260924-143902` |
| 24/09/2026 14:39 | Staging : `docker compose up -d --no-deps app web admin` (hôtes en www, admin sans réseau interne ni variable) ; base non recréée. Erreurs Traefik `staging-noindex` pendant les 10 s du redémarrage d'`app` (connu, voir Enseignements), aucune ensuite | — |
| 24/09/2026 14:40 | Contrôles staging : `admin.staging` et `preview.staging` → 301 vers `www.…` (chemin et paramètres conservés), 401 sur les hôtes www, certificats `www.admin.staging` et `www.preview.staging` obtenus | — |
| 24/09/2026 14:49 | alivaon-symfony PR #140 (API) fusionnée → pipeline : `app` recréé en production (image `13cd368`). Retour arrière : relancer le déploiement de `c15eab7` (run 35972439677, voir « Retour arrière »). Base non recréée | — |
| 24/09/2026 14:50 | Contrôles production : `www` 200, apex → 301, `/api…` sur www et apex → 404 (comme avant), EasyAdmin inchangé, `www.admin.alivaon.com/api/…` → 401 sans session. **Parité SEO contre `prod-2026-09-24` : 0 écart** (74 pages, 117 sondes, 47 entrées de sitemap) | — |
| 24/09/2026 14:53 | alivaon-next `main` → image `alivaon-next-admin:production`, service `admin` créé en production, healthy | — |
| 24/09/2026 14:55 | Contrôles admin : `admin.alivaon.com` → 301 `www.admin.alivaon.com`, TLS valide, `X-Robots-Tag: noindex, nofollow`, `robots.txt` Disallow, `/uploads/` servi par Symfony, connexion refusée proprement (401) ; `diff-vps.sh` : identique | — |
| 24/09/2026 18:47 | PR #5 (routage du site Next.js sur `www.preview.staging`) fusionnée ; `diff-vps.sh` : 1 écart attendu (compose staging) ; compose staging copié, `docker compose config` valide, `docker compose up -d --no-deps app web` ; `diff-vps.sh` après : identique. Production non touchée | `staging/docker-compose.yml.bak-20260924-184757` |
| 24/09/2026 19:20 | Déploiement staging d'alivaon-next `feat/site-pages` (run 36031234229) : `web` et `admin` recréés, healthy. Contrôles : pages FR/EN en 200 depuis `web` (titre et canonique attendus), 404 sur article inconnu, `/sitemap.xml` servi par Symfony, `www.preview.staging` → 401, `preview.staging` → 301 `www` (chemin conservé) ; `diff-vps.sh` : identique | — |
| 24/09/2026 19:35 | Constat pendant la parité staging : sur `traefik_proxy`, le DNS Docker résout `app` vers `staging-app-1` **et** `production-app-1` ; le front du staging (`http://app`) lisait au hasard l'API publique de production (GET en lecture seule ; admins et production non concernés : appels par hôte, routés par Traefik) | — |
| 24/09/2026 19:48 | PR #6 et #7 fusionnées ; `diff-vps.sh` : 1 écart attendu (compose staging) ; compose copié, `docker compose config` valide, `docker compose up -d --no-deps app web` (base non recréée) ; `diff-vps.sh` après : identique. Contrôles : `staging-api` et `staging-site` résolus vers une seule adresse (réseau interne du staging), API vue de `web` = données du staging (5/5), régénération joignable (401 sans secret), cache de Next vidé par la recréation | `staging/docker-compose.yml.bak-20260924-194856` |
| 24/09/2026 19:48 | Production, par les pipelines après fusion par le propriétaire : alivaon-symfony PR #141 (commentaire vide → 422) → `app` recréé ; alivaon-next PR #1 → `admin` redéployé. Contrôles : `www` 200, apex → 301, `/api…` sur www → 404, `admin.alivaon.com` → 301 `www`, `/api/auth/me` et `/api/admin/…` → 401 sans session | — |
| 24/09/2026 20:05 | Parité SEO du staging (Next `www.preview.staging` contre Symfony `www.staging`, mêmes données) : plus aucun écart de contenu ; restent `/admin*`, `/login`, `/logout` (routage de la bascule), `x-robots-tag` du middleware noindex du staging sur `/index.php` et `/adminer.php` (404 des deux côtés) et `?page=0` (exception validée). Production contre `prod-2026-09-24` : seuls écarts = blancs du texte extrait (« 30 + » → « 30+ »), dus à l'extracteur modifié après la capture de la référence ; titres, metas, canonicals, liens, images, JSON-LD, statuts et sitemap identiques | — |

### Enseignements pour la production

- **Modifier le `.env` d'une stack recrée aussi `db`** au prochain `docker compose up -d app` (y compris par le pipeline Symfony) : prévoir l'ajout des variables Next en production à un moment calme, ou ajouter le service `db` à `env_file` séparé.
- Les middlewares `staging-auth` et `staging-noindex` sont déclarés dans les labels du conteneur `app` : pendant un redémarrage d'`app`, les routeurs de `web` et `admin` qui les référencent sont désactivés (404, jamais d'exposition). **Appliqué en production** : chaque middleware est déclaré sur le conteneur du routeur qui l'utilise (noindex et redirection de l'admin sur `admin`), un redémarrage de Symfony ne coupe pas l'admin.
- Côté DNS o2switch : créer les enregistrements dans l'**Éditeur de zone**, jamais via « Sous-domaines » (qui pointe vers l'hébergement o2switch).

