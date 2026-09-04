# alivaon-infra

Configuration d'infrastructure du VPS Alivaon. **Dépôt privé.**

Ce dépôt est la seule copie versionnée de fichiers qui, jusqu'au 4 septembre
2026, n'existaient qu'à un seul endroit : le serveur lui-même.

---

## Le serveur

VPS Hetzner CX33 — 4 vCPU, 8 Go RAM, Ubuntu, datacenter Falkenstein.
Accès : `ssh alivaon` (utilisateur `alivaondev`, membre du groupe `docker`,
gid 983 — aucune opération Docker ne nécessite `sudo`).

Sur le serveur, tout vit sous `/opt/alivaon/`, un répertoire par stack.
L'arborescence de ce dépôt reproduit cette convention.

## Topologie

Quatre stacks Docker Compose indépendantes, sans `depends_on` entre elles.

```
                        Internet
                           │  :80  :443
                    ┌──────▼──────┐
                    │   traefik   │  seul conteneur publiant des ports
                    │  v3.7.12    │  socket Docker monté en direct
                    └──────┬──────┘
                           │ réseau traefik_proxy (external)
              ┌────────────┼────────────┐
              │            │            │
     ┌────────▼──────┐ ┌───▼────────────▼──┐
     │ production    │ │ staging           │
     │ app + db      │ │ app + db          │   + BasicAuth
     └───────────────┘ └───────────────────┘
        production_internal   staging_internal   (réseaux privés)

     ┌───────────────┐
     │  portainer    │  127.0.0.1:9443 — hors Traefik, tunnel SSH
     └───────────────┘
```

| Stack | Rôle |
|---|---|
| `traefik/` | Reverse proxy partagé, terminaison TLS, certificats Let's Encrypt |
| `production/` | `www.alivaon.com` — Symfony 7.4 (PHP-FPM + nginx) et MySQL 8.0 |
| `staging/` | `www.staging.alivaon.com` — même pile, base distincte, protégé par BasicAuth |
| `portainer/` | Administration Docker, jamais exposée publiquement |

### Le réseau `traefik_proxy`

C'est le point de couplage entre les stacks. Il est déclaré **`external: true`**
dans les quatre `docker-compose.yml` : aucune stack ne le crée ni ne le détruit.
Il est créé une seule fois par `first-deploy.sh`.

Conséquence : un `docker compose down` sur une stack applicative ne peut pas
emporter le réseau et couper les autres.

Les bases de données ne sont jointes qu'à leur réseau privé
(`production_internal`, `staging_internal`) et ne publient aucun port sur l'hôte.

---

## Ce qui n'est PAS dans ce dépôt

| Absent | Où le retrouver |
|---|---|
| `production/.env`, `staging/.env` | Uniquement sur le VPS. À reconstituer depuis les `.env.example` |
| `traefik/letsencrypt/acme.json` | Régénéré par Traefik — voir ci-dessous |
| `*/backups/*.sql.gz` | Dumps de production, sur le VPS. Données personnelles, jamais versionnées |
| Copies `*.bak-*` | Sur le VPS. L'historique Git remplit désormais cette fonction |

### Reconstituer les `.env`

Les gabarits `production/.env.example` et `staging/.env.example` listent tous les
noms de variables, sans aucune valeur. **Lire `staging/.env.example` en entier**
avant de le remplir : ce fichier a deux usages distincts et l'un d'eux échoue
silencieusement (voir « Pièges connus »).

### Régénérer `acme.json`

Il contient les **clés privées** des certificats. S'il est perdu, Traefik en
demande de nouveaux au premier démarrage, automatiquement, sans intervention.

⚠️ **Let's Encrypt limite à 5 certificats identiques par semaine.** Un
`acme.json` écrasé ou restauré à tort, plusieurs fois d'affilée, épuise ce quota
et laisse les sites sans certificat valide jusqu'à sa réinitialisation.

Règles de prudence :

- Ne jamais restaurer `acme.json` depuis une sauvegarde « par précaution ». Un
  renouvellement survenu entre-temps serait écrasé, et la réémission consommerait
  le quota. Ne le restaurer que sur corruption **avérée** : fichier illisible,
  entrées manquantes, compte ACME absent.
- Le fichier doit être en `600`, sinon Traefik refuse de démarrer.
- Inspection sans exposer les clés :

```bash
ssh alivaon "python3 -c \"
import json
r = json.load(open('/opt/alivaon/traefik/letsencrypt/acme.json'))['letsencrypt']
print('certificats :', len(r['Certificates']))
print('compte ACME :', r['Account']['Email'])
print('registration:', 'presente' if r['Account'].get('Registration') else 'ABSENTE')
\""
```

---

## Reconstruire le VPS depuis zéro

L'ordre compte : **Traefik d'abord**, car il crée et rejoint le réseau partagé
que les applications attendent. Une application démarrée avant lui échouerait
sur un `traefik_proxy` inexistant.

```bash
# 1. Arborescence, réseau partagé, acme.json vide, démarrage de Traefik
scp -r traefik/ alivaon:/opt/alivaon/
scp first-deploy.sh alivaon:/opt/alivaon/
ssh alivaon 'cd /opt/alivaon && ./first-deploy.sh'

# 2. Applications — .env à renseigner AVANT le démarrage
scp -r production/ staging/ alivaon:/opt/alivaon/
ssh alivaon 'cd /opt/alivaon/production && cp .env.example .env'   # puis renseigner
ssh alivaon 'cd /opt/alivaon/staging    && cp .env.example .env'   # puis renseigner
ssh alivaon 'cd /opt/alivaon/production && docker compose up -d'
ssh alivaon 'cd /opt/alivaon/staging    && docker compose up -d'

# 3. Importer les dumps MySQL et créer les utilisateurs applicatifs

# 4. Portainer (optionnel)
scp -r portainer/ alivaon:/opt/alivaon/
ssh alivaon 'cd /opt/alivaon/portainer && docker compose up -d'
```

`first-deploy.sh` est **idempotent** : il ne recrée rien d'existant et ne touche
à aucune permission. Il peut être relancé sans risque.

---

## Méthode — appliquer une modification

### Modifier `traefik.yml` : `up -d` ne suffit PAS

C'est le piège le plus coûteux de cette infrastructure, constaté en production
le 4 septembre 2026.

```bash
# ❌ NE FONCTIONNE PAS après modification de traefik.yml
cd /opt/alivaon/traefik && docker compose up -d
#    → « Container traefik Running » : aucun changement appliqué
```

Deux mécanismes se combinent :

1. `traefik.yml` est un fichier **monté** dans le conteneur. Le modifier ne
   change pas la définition du service, donc Compose considère le conteneur à
   jour et ne fait **rien**. La commande réussit et n'affiche aucune erreur.
2. Traefik ne recharge **pas** sa configuration statique à chaud. Même si
   Compose agissait, il faudrait redémarrer le processus.

```bash
# ✅ La bonne commande
cd /opt/alivaon/traefik && docker compose restart traefik
```

Un changement de la ligne `image:`, en revanche, modifie bien la définition du
service : `docker compose up -d` recrée alors le conteneur normalement.

### Corollaire — lire les journaux après un `restart`

`docker compose restart` **conserve les journaux du démarrage précédent**. Un
`docker logs traefik` non filtré affiche donc les avertissements de l'ancienne
configuration, y compris ceux que le changement était censé faire disparaître.

```bash
# Filtrer sur le nouveau démarrage avant toute conclusion
ssh alivaon 'docker inspect traefik --format "{{.State.StartedAt}}"'
ssh alivaon 'docker logs --since <cet-horodatage> traefik'
```

---

## Pièges connus

### 1. `STAGING_BASICAUTH` absent → le préprod devient public, sans erreur

**C'est le piège le plus dangereux de cette configuration.**

`staging/.env` a deux usages, contrairement à celui de la production :

- il alimente les conteneurs via `env_file:` — un manque y produit une erreur
  visible ;
- il est **interpolé côté hôte par Compose** pour construire le label
  `traefik.http.middlewares.staging-auth.basicauth.users=${STAGING_BASICAUTH}`.

Sur ce second usage, Compose remplace une variable absente par une **chaîne
vide**, sans avertissement. La stack démarre, les conteneurs passent `healthy`,
les journaux sont propres — et le préprod n'est plus protégé. Il devient public
et indexable par les moteurs de recherche.

**Contrôle après chaque redéploiement du staging :**

```bash
./scripts/check-staging-auth.sh
```

Ou directement :

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://www.staging.alivaon.com
# 401 = protection active
# 200 = PROTECTION TOMBÉE, le préprod est public
```

Ce script n'est **pas installé** : il n'est ni en cron, ni dans un pipeline.
Le brancher sur la supervision, ou en fin de job de déploiement du staging,
reste à faire.

### 2. Ne pas réintroduire le sidecar `dockerproxy`

Un sidecar HAProxy réécrivait autrefois la version de l'API Docker pour Traefik.
Il a été **supprimé le 4 septembre 2026** et ne doit pas revenir : depuis la
v3.6, le provider docker négocie la version d'API avec le démon. Motif détaillé
dans [docs/traefik.md](docs/traefik.md).

### 3. Les variables `MYSQL_*` n'agissent qu'au premier démarrage

`MYSQL_ROOT_PASSWORD`, `MYSQL_USER` et `MYSQL_PASSWORD` initialisent le conteneur
uniquement sur un volume **vide**. Les modifier dans `.env` sur une base déjà
peuplée ne change rien côté serveur MySQL : l'application ne se connectera plus,
sans que la cause soit visible dans les journaux Docker.

---

## Chantiers ouverts

### Écarts documentaires hérités du premier commit

Le commit initial est une **photographie fidèle du serveur** au 4 septembre 2026 :
les fichiers copiés n'ont pas été retouchés, même là où leurs commentaires sont
devenus faux. Corriger au passage aurait fait diverger le dépôt et le VPS dès la
première ligne d'historique.

Ces deux corrections sont donc à appliquer **simultanément au dépôt et au
serveur**, dans une même intervention, en vérifiant l'identité des fichiers après
coup (voir la commande de comparaison plus bas) :

1. **`portainer/docker-compose.yml`** — le commentaire de la section `networks`
   mentionne `traefik_docker_api` et « contrairement à ce qu'impose Traefik
   v3.5 ». Ce réseau a été supprimé le 4 septembre 2026 et Traefik est en
   v3.7.12. Reformuler sans référence à un réseau qui n'existe plus.

2. **`first-deploy.sh`** — la dernière ligne renvoie à `README-DEPLOY.md`, qui
   vit dans le dépôt `alivaon-symfony` et non ici. Faire pointer vers le présent
   README, section « Reconstruire le VPS depuis zéro ».

### Infrastructure

Détaillés dans [docs/traefik.md](docs/traefik.md) :

- **Journaux d'accès en JSON** — le format CLF ne journalise aucun nom d'en-tête,
  ce qui prive de toute visibilité sur ce que `aliasHeadersStrategy: delete`
  supprime réellement.
- **Fragilité du httpChallenge** — quatre échecs de challenge ACME le
  3 septembre 2026 sur le domaine de production, renouvellement finalement abouti.
- **Entrée fantôme dans `acme.json`** — `staging.alivaon.com` stockée mais jamais
  servie, renouvelée pour rien à chaque cycle.
- **Traefik 3.7.13** — à réexaminer avant toute montée : `Upgrade: h2c` non
  transmis aux backends, cibles « rootless » rejetées en 400.

### Exploitation

- **`scripts/check-staging-auth.sh` n'est branché nulle part** — ni cron, ni
  pipeline. À raccorder à la supervision ou en fin de job de déploiement du
  staging.
- **Aucune sauvegarde hors serveur** — les dumps `backups/` et `acme.json` ne
  vivent que sur le VPS. Une perte du serveur les emporte.

## Accès à Portainer

Portainer écoute **exclusivement sur `127.0.0.1:9443`**. Aucun port n'est ouvert
dans UFW (qui n'autorise que 22, 80 et 443), il n'est pas routé par Traefik, et
il est injoignable depuis Internet.

```bash
ssh -N -L 9443:127.0.0.1:9443 alivaon
```

Puis **`https://localhost:9443`** — le `https://` doit être saisi explicitement :
le navigateur complète `localhost:9443` en `http://`, et Traefik n'écoute qu'en
TLS sur ce port, ce qui produit un `HTTP 400`. Certificat auto-signé, avertissement
attendu.

⚠️ Le préfixe `127.0.0.1:` dans le mapping de port est **impératif**. Docker
inscrit ses règles DNAT dans la chaîne iptables `DOCKER`, évaluée **avant** UFW :
sans ce préfixe, le port 9443 serait joignable depuis Internet bien qu'UFW soit
actif. Détails dans [docs/portainer.md](docs/portainer.md).

---

## Documentation

- [docs/traefik.md](docs/traefik.md) — les trois migrations du 4 septembre 2026,
  la configuration actuelle et les chantiers ouverts
- [docs/portainer.md](docs/portainer.md) — installation, accès, mise à jour,
  désinstallation

## Portée de ce dépôt

Il couvre l'**infrastructure** : orchestration, reverse proxy, TLS, administration.
Le code applicatif Symfony, son `Dockerfile` et sa configuration nginx vivent dans
le dépôt `alivaon-symfony`. Les deux se rejoignent au déploiement, via GitHub
Actions, qui pousse les images vers `ghcr.io/alivaon/alivaon-symfony`.
