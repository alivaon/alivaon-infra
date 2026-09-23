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

# 5. Adminer et File Browser (optionnels) — APRÈS production et staging, dont
#    ils réutilisent les réseaux et les volumes.
scp -r adminer/ alivaon:/opt/alivaon/
ssh alivaon 'cd /opt/alivaon/adminer && docker compose up -d'

scp -r filebrowser/ alivaon:/opt/alivaon/
#    File Browser exige une initialisation avant son premier démarrage :
#    voir « Accès à Adminer et File Browser » plus bas. Ne PAS lancer
#    `docker compose up -d` avant, sous peine de laisser le serveur créer
#    lui-même un compte administrateur.
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

## Vérifier que le dépôt est toujours fidèle au serveur

Rien ne garantit que la photographie le reste : une modification faite en direct
sur le VPS, ou un commit non déployé, créent un écart silencieux.

```bash
./scripts/diff-vps.sh        # comparaison par empreinte sha256
./scripts/diff-vps.sh -v     # affiche le diff des fichiers qui divergent
```

À lancer **depuis le poste**, pas depuis le VPS : la comparaison suppose d'avoir
les deux côtés sous la main. Le serveur ne connaît pas le contenu du dépôt, et y
cloner un dépôt privé demanderait d'y déposer des identifiants GitHub — ce que
cette infrastructure évite délibérément.

La liste des fichiers n'est **plus écrite en dur** : le script découvre tous les
`*/docker-compose.yml` du dépôt, et y ajoute `first-deploy.sh` et
`traefik/traefik.yml`. Un nouveau service déposé dans son propre dossier est
donc couvert sans toucher au script. Le sens inverse est vérifié aussi : une
stack présente sur le VPS mais absente du dépôt est signalée. Les autres
fichiers (README, `docs/`, `scripts/`, `.env.example`) n'existent que dans le
dépôt et ne sont pas comparés.

Au-delà des fichiers, le script contrôle un invariant qui ne se lit dans aucun
d'entre eux : les réseaux porteurs doivent conserver
`enable_ip_masquerade=false`. Voir « Ce qu'il ne faut pas casser ».

Codes de sortie : `0` conforme, `1` écart de contenu, `2` fichier ou stack
manquant, `3` régression sur un réseau porteur.

Pour un contrôle manuel, la partie serveur se réduit à :

```bash
ssh alivaon 'sha256sum /opt/alivaon/first-deploy.sh \
  /opt/alivaon/traefik/traefik.yml /opt/alivaon/*/docker-compose.yml'
```

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
- **Sauvegarde hors serveur : prête, pas encore installée.** Le dispositif
  restic (bases MySQL et volumes d'uploads, production et staging) est dans
  [backup/](backup/README.md). Tant que [backup/RUNBOOK-BACKUP.md](backup/RUNBOOK-BACKUP.md)
  n'a pas été déroulé sur le VPS, une perte du serveur emporte tout. Restent
  hors périmètre : les `.env` des stacks et `acme.json`.

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

## Accès à Adminer et File Browser

Trois interfaces d'administration, toutes sur le modèle de Portainer :
**publication sur la loopback uniquement**, aucun label Traefik, aucun
sous-domaine, aucun port ouvert dans UFW. Elles sont injoignables depuis
Internet, et le resteront.

> Cette section décrit la **conception** et ce qu'il ne faut pas casser. Pour
> l'usage courant — ouvrir le tunnel, se connecter, retrouver un mot de passe,
> diagnostiquer une panne — voir **[docs/acces-admin.md](docs/acces-admin.md)**.

| Service | Port | Périmètre |
|---|---|---|
| Adminer — production | `127.0.0.1:8081` | base MySQL de production, et rien d'autre |
| File Browser | `127.0.0.1:8082` | uploads de production et de préprod |
| Adminer — préprod | `127.0.0.1:8083` | base MySQL de préprod, et rien d'autre |

### Tunnels SSH

```bash
# Adminer production
ssh -N -L 8081:127.0.0.1:8081 alivaon

# File Browser
ssh -N -L 8082:127.0.0.1:8082 alivaon

# Adminer préprod
ssh -N -L 8083:127.0.0.1:8083 alivaon

# Les trois d'un coup
ssh -N -L 8081:127.0.0.1:8081 -L 8082:127.0.0.1:8082 -L 8083:127.0.0.1:8083 alivaon
```

Puis `http://localhost:8081`, `http://localhost:8082`, `http://localhost:8083`.
En clair, contrairement à Portainer : le trafic ne quitte jamais le tunnel SSH,
qui assure lui-même le chiffrement.

### Connexion à Adminer

| Champ | Production (`:8081`) | Préprod (`:8083`) |
|---|---|---|
| Système | MySQL | MySQL |
| Serveur | `production-db-1` *(pré-rempli)* | `staging-db-1` *(pré-rempli)* |
| Utilisateur | `alivaon_app`, ou `root` | idem |
| Mot de passe | `MYSQL_PASSWORD` (ou `MYSQL_ROOT_PASSWORD`) du `.env` de la stack | idem |
| Base | `alivaon_db` | `alivaon_db` |

Les deux bases portent le **même nom**, `alivaon_db`, et le même utilisateur
applicatif. Rien à l'écran ne les distingue une fois connecté — d'où deux
instances séparées plutôt qu'une seule.

**Une instance par environnement, et c'est structurel.** `production-db-1` et
`staging-db-1` répondent tous deux à l'alias réseau `db` sur leur réseau. Une
instance unique branchée sur les deux aurait eu un `db` ambigu. Ici chaque
instance ne voit qu'un réseau : celle du port 8081 ne peut pas joindre le
préprod, celle du 8083 ne peut pas joindre la production. L'environnement est
déterminé par le port du tunnel, pas par un champ de formulaire. Le champ
« serveur » est pré-rempli avec le nom de conteneur complet, et non `db`, pour
que les deux écrans ne soient jamais indiscernables.

### Connexion à File Browser

Utilisateur `admin`. Le mot de passe a été généré aléatoirement et n'existe
qu'à un seul endroit, non versionné :

```bash
ssh alivaon 'cat /opt/alivaon/filebrowser/.env'
```

Seuls deux dossiers sont exposés : `production-uploads` et `staging-uploads`.
La racine n'est **pas** `/opt/alivaon` — l'y placer aurait mis les `.env`
applicatifs et `traefik/letsencrypt/acme.json`, qui contient les clés privées
TLS, derrière une interface web. Les volumes `cv_private` sont délibérément
exclus, même en lecture : ce sont des CV de candidats.

Le service tourne sous l'uid **82**, celui de `www-data` dans l'image de
l'application, propriétaire réel des fichiers téléversés. Sous l'uid 1000 —
celui de `/opt/alivaon` — File Browser aurait été lecture seule dans la plupart
des dossiers, et les fichiers qu'il aurait créés auraient été ingérables par
Symfony.

Initialisation, à faire **avant** le premier `docker compose up -d` :

```bash
cd /opt/alivaon/filebrowser
IMG=filebrowser/filebrowser:v2.63.23-s6
MNT="-v $PWD/data:/database -v $PWD/data:/config"

umask 077 && printf 'FB_ADMIN_PASSWORD=%s\n' "$(openssl rand -base64 24)" > .env
mkdir -p data && cat > data/settings.json <<'JSON'
{ "port": 80, "baseURL": "", "address": "", "log": "stdout",
  "database": "/database/database.db", "root": "/srv" }
JSON

# chown vers l'uid 82 sans sudo, via un conteneur jetable
docker run --rm -v $PWD/data:/d alpine:3.22 chown -R 82:82 /d

docker run --rm --user 82:82 $MNT --entrypoint filebrowser $IMG \
  config init -d /database/database.db \
  --address "" --port 80 --root /srv --disableExec --auth.method json

set -a; . ./.env; set +a; export ADMIN_PW="$FB_ADMIN_PASSWORD"
docker run --rm --user 82:82 -e ADMIN_PW $MNT --entrypoint sh $IMG -c \
  'filebrowser users add admin "$ADMIN_PW" -d /database/database.db \
   --perm.admin --perm.execute=false --perm.share=false'

docker compose up -d
```

Créer le compte **avant** le premier démarrage est ce qui empêche File Browser
de générer lui-même un administrateur par défaut. Le contrôle :

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:8082/api/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"admin","recaptcha":""}'
# 403 attendu. Un 200 signifierait que le compte par défaut existe.
```

Le passage par `-e ADMIN_PW` sans valeur, plutôt que par la ligne de commande,
évite que le mot de passe apparaisse dans `ps`.

### File Browser — projet archivé, production en lecture seule

Le dépôt amont est **archivé depuis le 1ᵉʳ septembre 2026** : `v2.63.23` est la
dernière version, et aucun correctif de sécurité ne viendra. Quatre avis la
concernent sans correctif, dont un *high* qui permet une suppression récursive
de dossiers.

**Le volume de production est monté en lecture seule** (`:ro`), ce qui place la
protection dans le noyau plutôt que dans le contrôle de permissions applicatif
que la faille contourne. Consultation et téléchargement restent possibles ;
toute écriture est refusée. Le préprod reste inscriptible.

Détail des avis, de la mitigation et de l'échéance de revue : **[Dette
connue](#dette-connue)**.

### Ce qu'il ne faut pas casser

**Les réseaux porteurs.** Depuis Docker 28, un conteneur rattaché uniquement à
des réseaux `internal` **ne publie plus aucun port**, et le refus est
silencieux : le conteneur démarre, passe `healthy`, et rien n'écoute. Vérifié
sur ce VPS en Docker 29.6.1. `EnableUserlandProxy` n'y change rien.

Les réseaux `production_internal` et `staging_internal` étant `internal`, chaque
stack déclare donc un second réseau, dit *porteur*, non `internal`, dont le seul
rôle est de porter la publication du port :

`adminer_porteur_production`, `adminer_porteur_staging`, `filebrowser_porteur`

Chacun est créé avec `enable_ip_masquerade=false`, ce qui lui retire le NAT
sortant : les trois conteneurs n'ont **aucun accès Internet**. C'est délibéré —
ni Adminer, qui parle à la base de production, ni File Browser, qui écrit dans
les uploads, ne doivent disposer d'un canal de sortie.

> **Ne jamais recréer ces réseaux à la main.** Compose ne recrée pas un réseau
> existant : un `docker network create adminer_porteur_production` sans l'option
> produirait un réseau d'apparence identique, les conteneurs démarreraient
> normalement, et l'accès Internet reviendrait sans le moindre message. Pour
> corriger, supprimer le réseau puis relancer la stack.

`scripts/diff-vps.sh` contrôle cet invariant sur tout réseau dont le nom
contient « porteur », et sort en code 3 si le NAT a été réactivé.

**Le `down` des stacks applicatives.** Un `docker compose down` dans
`/opt/alivaon/production` ou `/opt/alivaon/staging` échoue désormais à supprimer
son réseau (« network has active endpoints »), l'instance Adminer y étant
attachée. Les conteneurs de la stack s'arrêtent normalement ; seul le réseau
survit. Pour un `down` complet, arrêter d'abord l'instance Adminer.

**Le préfixe `127.0.0.1:`** dans chaque mapping de port, pour la même raison que
sur Portainer : Docker inscrit ses règles DNAT dans la chaîne iptables `DOCKER`,
évaluée **avant** UFW. Sans ce préfixe, les ports 8081, 8082 et 8083 seraient
joignables depuis Internet bien qu'UFW soit actif.

Contrôle, à tout moment :

```bash
ssh alivaon "ss -tln | grep -E ':808[123] '"
# Les trois lignes doivent porter 127.0.0.1, jamais 0.0.0.0 ni [::]
```

---

## Dette connue

### File Browser — dépendance à un projet abandonné

**Le fait.** Le dépôt amont `filebrowser/filebrowser` a été archivé le
**1ᵉʳ septembre 2026**, trois jours avant la mise en service de cette stack.
`v2.63.23` est la dernière version publiée. Il n'y aura **plus aucun correctif
de sécurité**, y compris pour les failles déjà connues et publiées.

**La faille qui compte ici.** `GHSA-c4fr-5f24-4wrj` *(high, sans correctif,
affecte >= 2.5.0)* : lorsqu'un téléversement échoue, la routine de nettoyage
supprime **récursivement** des dossiers, en contournant le contrôle
`Perm.Delete` et les règles de refus. Ce n'est pas une voie d'intrusion — c'est
un chemin de perte de données déclenchable par un simple envoi interrompu, sans
la moindre intention hostile.

Trois autres avis affectent la version, sans correctif : `GHSA-39cx-23x9-5c8p`
*(medium)*, `GHSA-448h-jr2h-3vhp` *(medium)*, `GHSA-7w29-q235-57m9` *(medium)*.
Ils sont couverts par la configuration en place — `disableExec`, `Execute:
false` sur le compte admin, `mem_limit: 512m`, aucune règle de refus de chemin.

**La mitigation en place.** Le volume `production_uploads` est monté
**en lecture seule** :

```yaml
- production_uploads:/srv/production-uploads:ro
```

Ce choix déplace la protection du niveau applicatif — celui-là même que la
faille contourne — vers le **noyau**, qui refuse l'appel `unlink` quel que soit
le chemin de code emprunté. Le chemin vulnérable devient donc **sans effet sur
la production**, y compris s'il est atteint. Vérifié en conditions réelles :

```
/dev/sda1 /srv/production-uploads ext4 ro,relatime 0 0
rm:    cannot remove '.../articles/....png': Read-only file system
touch: cannot touch '.../.essai':            Read-only file system
mkdir: cannot create directory '.../essai':  Read-only file system
```

La lecture et le téléchargement restent intacts : les neuf dossiers de
production sont listables et leurs fichiers consultables.

**Le risque résiduel, assumé.** Le préprod reste monté en écriture. Une
suppression récursive y demeure possible ; la perte y est sans conséquence, les
données de `staging` étant reproductibles. C'est un arbitrage délibéré, pas un
oubli : File Browser doit rester un outil de gestion quelque part, faute de quoi
il n'a plus d'objet.

**Échéance de revue : mars 2027.** À cette date, remplacer File Browser par un
outil maintenu. D'ici là, ne pas repasser `production_uploads` en `:rw`, et ne
pas monter les volumes `cv_private`. `scripts/diff-vps.sh` signalera toute
divergence du `docker-compose.yml` par rapport à ce dépôt.

### Sauvegarde des fichiers téléversés

Les dossiers `uploads` de production **ne sont couverts par aucune sauvegarde**.
Les seuls fichiers présents dans `*/backups/` sont des dumps MySQL
`pre-deploy-*.sql.gz` : ils contiennent la base, jamais les fichiers, et vivent
sur le serveur lui-même. Aucun outil de sauvegarde n'est installé, aucune tâche
planifiée ne les traite.

La lecture seule sur la production protège des suppressions accidentelles **par
File Browser**, mais ne remplace pas une sauvegarde : elle ne couvre ni la perte
du serveur, ni une suppression par l'application elle-même.

Le dispositif qui couvre ces volumes est prêt dans [backup/](backup/README.md),
**en attente d'installation** : voir « Sauvegarde hors serveur » dans les
chantiers ouverts.

---

## Documentation

- [docs/traefik.md](docs/traefik.md) — les trois migrations du 4 septembre 2026,
  la configuration actuelle et les chantiers ouverts
- [docs/portainer.md](docs/portainer.md) — installation, accès, mise à jour,
  désinstallation
- [docs/acces-admin.md](docs/acces-admin.md) — guide d'accès aux trois interfaces
  d'administration : tunnel SSH, connexion à Adminer et à File Browser,
  emplacement des mots de passe, dépannage
- [backup/README.md](backup/README.md) — sauvegarde chiffrée hors machine
  (restic) : fonctionnement, exploitation, restauration, rotation du mot de
  passe, coût. Mise en place : [backup/RUNBOOK-BACKUP.md](backup/RUNBOOK-BACKUP.md) ;
  tests : [backup/RUNBOOK-RESTORE-TEST.md](backup/RUNBOOK-RESTORE-TEST.md)

## Portée de ce dépôt

Il couvre l'**infrastructure** : orchestration, reverse proxy, TLS, administration.
Le code applicatif Symfony, son `Dockerfile` et sa configuration nginx vivent dans
le dépôt `alivaon-symfony`. Les deux se rejoignent au déploiement, via GitHub
Actions, qui pousse les images vers `ghcr.io/alivaon/alivaon-symfony`.
