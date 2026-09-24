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

`web` et `admin` rejoignent `traefik_proxy` et le réseau interne (appels à
Symfony par `http://app`). Ils ne reçoivent **aucun** secret Symfony
(variables `environment:` explicites, pas d'`env_file`).

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
NEXT_REVALIDATE_URL=http://web:3000/api/revalidate
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

## Journal des actions sur le serveur

Actions exécutées directement sur le VPS (accès SSH accordé par le
propriétaire le 24/09/2026). Chaque fichier modifié est sauvegardé à côté
(`*.bak-AAAAMMJJ-HHMMSS`).

| Date | Action | Sauvegarde |
|---|---|---|
| 24/09/2026 10:19 | `diff-vps.sh` depuis `main` : serveur identique au dépôt | — |
| 24/09/2026 10:19 | Clé SSH dédiée au déploiement d'alivaon-next (ED25519, `SHA256:AOqe0EdM7bnKoHIy8zidQb4O/qZA504oyMwm27Jwovk`) ajoutée à `~alivaondev/.ssh/authorized_keys` ; clé privée uniquement dans le secret `VPS_SSH_KEY` du dépôt (supprimée du poste). Révocation : retirer la ligne « github-actions alivaon-next » | `authorized_keys.bak-20260924-101919` |
| 24/09/2026 10:20 | `NEXT_REVALIDATE_URL` et `NEXT_REVALIDATE_SECRET` (64 caractères) ajoutés à `/opt/alivaon/staging/.env` | `.env.bak-20260924-102008` |

