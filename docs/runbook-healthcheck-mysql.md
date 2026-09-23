# Runbook — healthcheck MySQL sans mot de passe root

Déploiement sur le VPS de la correction du healthcheck des services `db`,
dans `production/docker-compose.yml` et `staging/docker-compose.yml`.

## Le problème

L'ancien healthcheck était :

```yaml
test: ["CMD", "mysqladmin", "ping", "-h", "127.0.0.1", "-u", "root", "-p$$MYSQL_ROOT_PASSWORD"]
```

Toutes les 10 secondes, Docker lance cette commande **avec le mot de passe
root de MySQL en argument**. Les processus d'un conteneur sont visibles depuis
l'hôte : n'importe quel processus du VPS pouvait lire ce mot de passe par `ps`,
alors que Portainer, Adminer et File Browser tournent sur la même machine.

## La correction

```yaml
test: ["CMD", "mysqladmin", "ping", "-h", "127.0.0.1"]
```

Sans identifiants. `mysqladmin ping` renvoie 0 dès que le serveur **répond**,
y compris par un refus d'accès : c'est exactement ce qu'un healthcheck doit
tester. `-h 127.0.0.1` force une connexion TCP : pendant l'initialisation d'un
volume neuf, l'image lance un serveur temporaire qui n'écoute pas en TCP, et le
conteneur ne passe « healthy » qu'une fois le vrai serveur démarré.

Ce `-h 127.0.0.1` ne concerne que le healthcheck, qui ne s'authentifie pas. Il
est sans rapport avec le compte de sauvegarde `'backup'@'localhost'`, qui se
connecte, lui, par socket (backup/RUNBOOK-BACKUP.md, étape 3).

## Ce qu'il faut savoir avant de commencer

- **Durée de coupure : 20 à 40 secondes par environnement.** Le changement
  porte sur la **définition** du service : `docker compose up -d db` **recrée**
  le conteneur MySQL. Les données, dans le volume, ne bougent pas, mais la
  base est indisponible le temps du redémarrage, et le site renvoie des
  erreurs pendant ce temps.
- **Ordre imposé : staging d'abord, puis production.** Le staging sert de
  répétition. On ne passe à la production que si **toutes** les vérifications
  du staging (section 2) sont vertes.
- **Production dans un créneau creux**, hors de la fenêtre de sauvegarde
  (03:15–04:00) et hors du contrôle hebdomadaire (dimanche 11:15–11:30).
- **Grouper avec l'installation des sauvegardes.** Plutôt que d'interrompre la
  base deux fois, dérouler ce runbook dans la même fenêtre que
  [backup/RUNBOOK-BACKUP.md](../backup/RUNBOOK-BACKUP.md), entre son étape 2
  (contrôle des noms) et son étape 3 (comptes MySQL). La première sauvegarde
  porte ainsi sur les conteneurs définitifs, et une seule coupure est à
  annoncer.
- Le conteneur garde son nom (`production-db-1`, `staging-db-1`) et son
  réseau : Adminer, qui s'y réfère par ce nom, n'est pas affecté.
- Tant que ce runbook n'a pas été déroulé, `scripts/diff-vps.sh` signale un
  **ÉCART** sur les deux fichiers compose : c'est attendu.
- Notation : **[MAC]** à la racine du dépôt, **[VPS]** via `ssh alivaon`. Une
  commande par bloc.

---

## 1. Constater l'écart [MAC]

```bash
./scripts/diff-vps.sh -v
```

**Effet** : compare le dépôt au serveur.
**Vérifier** : `ÉCART` sur `production/docker-compose.yml` et
`staging/docker-compose.yml`, et le diff ne porte **que** sur la ligne `test:`
du healthcheck et son commentaire. Tout autre écart : s'arrêter et
l'expliquer d'abord.

## 2. Staging d'abord, avec vérification

**[VPS]**

```bash
cp -p /opt/alivaon/staging/docker-compose.yml /opt/alivaon/staging/docker-compose.yml.bak-$(date +%Y%m%d-%H%M%S)
```

**Effet** : copie horodatée de la version en place, selon la convention du
serveur.

**[MAC]**

```bash
scp staging/docker-compose.yml alivaon:/opt/alivaon/staging/docker-compose.yml
```

**Effet** : dépose la version corrigée.

**[VPS]**

```bash
cd /opt/alivaon/staging && docker compose config --quiet
```

**Vérifier** : aucune sortie. Une erreur de syntaxe s'afficherait ici, avant
tout effet.

```bash
cd /opt/alivaon/staging && docker compose up -d db
```

**Effet** : recrée le seul conteneur `staging-db-1` avec le nouveau
healthcheck.
**Vérifier** : `Container staging-db-1 Started` (ou `Recreated`).

```bash
docker inspect -f '{{json .Config.Healthcheck.Test}}' staging-db-1
```

**Vérifier** : `["CMD","mysqladmin","ping","-h","127.0.0.1"]`, sans `-p`.

```bash
docker inspect -f '{{.State.Health.Status}}' staging-db-1
```

**Vérifier** : `healthy`. `starting` : attendre 30 secondes et relancer.

**[MAC]**

```bash
./scripts/check-staging-auth.sh
```

**Vérifier** : code 0, `401`. Le `docker compose up` a réinterprété
`staging/.env` : c'est le contrôle du piège `STAGING_BASICAUTH` (README
racine, « Pièges connus »).

> **Barrière.** Passer à la production **uniquement** si les quatre
> vérifications du staging sont vertes : `config --quiet` muet, healthcheck
> sans `-p`, état `healthy`, `check-staging-auth.sh` à `401`. Sinon, retour
> arrière du staging (en fin de document) et analyse avant toute nouvelle
> tentative.

## 3. Production, dans un créneau creux

**[VPS]**

```bash
cp -p /opt/alivaon/production/docker-compose.yml /opt/alivaon/production/docker-compose.yml.bak-$(date +%Y%m%d-%H%M%S)
```

**[MAC]**

```bash
scp production/docker-compose.yml alivaon:/opt/alivaon/production/docker-compose.yml
```

**[VPS]**

```bash
cd /opt/alivaon/production && docker compose config --quiet
```

**Vérifier** : aucune sortie.

```bash
cd /opt/alivaon/production && docker compose up -d db
```

**Effet** : recrée `production-db-1`. **Coupure de la base de 20 à 40
secondes.**

```bash
docker inspect -f '{{json .Config.Healthcheck.Test}}' production-db-1
```

**Vérifier** : `["CMD","mysqladmin","ping","-h","127.0.0.1"]`.

```bash
docker inspect -f '{{.State.Health.Status}}' production-db-1
```

**Vérifier** : `healthy`.

**[MAC]**

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://www.alivaon.com/
```

**Vérifier** : `200`.

## 4. Plus aucun mot de passe dans `ps` [VPS]

```bash
sleep 25; ps -eo args | grep -c '[m]ysqladmin.*-p'
```

**Effet** : attend au moins deux cycles de healthcheck, puis cherche une
commande `mysqladmin` portant un `-p`.
**Vérifier** : `0`.

## 5. Fidélité dépôt / serveur [MAC]

```bash
./scripts/diff-vps.sh
```

**Vérifier** : `identique` pour les deux fichiers compose, code de sortie 0.

## Retour arrière

Recopier la copie `.bak-*` sur `docker-compose.yml`, puis
`docker compose up -d db` dans le dossier de la stack. Le mot de passe root
redevient visible dans `ps` : à ne faire que le temps de corriger.
