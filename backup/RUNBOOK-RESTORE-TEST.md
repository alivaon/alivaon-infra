# Runbook — test de restauration

Une sauvegarde qui n'a jamais été restaurée n'est qu'une hypothèse. Ce runbook
la transforme en fait vérifié, sur le **staging**, sans jamais toucher la
production.

| Test | Prouve | Où | Fréquence | Durée |
|---|---|---|---|---|
| **0** | Le dépôt s'ouvre **sans le VPS**, avec le seul gestionnaire de mots de passe | Mac | À l'installation (étapes 1 et 8 de RUNBOOK-BACKUP), puis à chaque rotation du mot de passe | 10 min |
| **1** | Une restauration complète remet le staging en service | VPS + Mac | À l'installation (étape 11 de RUNBOOK-BACKUP : **clôt la mise en place**), puis mensuelle, et après toute modification de `backup/` | 30 min |
| **2** | La sauvegarde de **production** est restaurable, sans exposer ses données | VPS | Trimestrielle | 15 min |
| **3** | Le garde-fou staging → production tient en conditions réelles | VPS | À l'installation, puis après toute modification de `restore.sh` | 2 min |

Notation identique à [RUNBOOK-BACKUP.md](RUNBOOK-BACKUP.md) : **[MAC]** à la
racine du dépôt, **[VPS]** via `ssh alivaon`, une commande par bloc, avec
**Effet** et **Vérifier**. Consigner chaque exécution dans le
[journal des tests](#journal-des-tests).

Valeurs relevées au fil du test, à noter au brouillon :

| Placeholder | Relevé à |
|---|---|
| `<ID_INSTANTANE>` | Test 1, étape 1.2 |
| `<N_TABLES>` | Test 1, étape 1.3 |
| `<FICHIER>` | chemin relatif sous `public/uploads/`, Test 1, étape 1.3 |
| `<EMPREINTE>` | sha256 du fichier, Test 1, étape 1.3 |
| `<URL_ARTICLE>`, `<TITRE_ARTICLE>` | un article publié sur le staging, choisi à l'étape 1.3 |

---

## Avant toute restauration : conteneur applicatif et mode des fichiers

Deux choix que `restore.sh` n'accepte plus de faire implicitement.

**Le conteneur applicatif ne tourne pas pendant l'écriture.** `restore.sh`
réécrit les volumes depuis l'hôte, avec rsync. Si l'application tourne, un
téléversement concurrent peut être écrasé, ou l'état obtenu mêler deux
moments. S'il tourne, `restore.sh` **refuse** et dit quoi arrêter. Deux
façons de procéder :

- l'arrêter soi-même (`docker stop <conteneur>`) : `restore.sh` le laisse
  arrêté à la fin, le redémarrer à la main ;
- passer **`--stop-app`** : `restore.sh` l'arrête juste avant l'écriture et
  le **redémarre** ensuite, **y compris en cas d'échec** (trap) ; l'état
  initial est toujours rétabli.

Le conteneur MySQL, lui, n'est jamais arrêté : la base est restaurée par
import, à travers lui. La règle vaut pour toute écriture, base comprise : une
application qui tourne pendant l'import écrirait dans une base à moitié
recréée.

**Le mode de restauration des fichiers est obligatoire** dès qu'un volume est
restauré, sans valeur par défaut :

| Mode | Effet | Quand |
|---|---|---|
| `--merge` | Les fichiers de la cible absents de l'instantané sont **conservés** ; ceux présents des deux côtés sont remplacés par la version archivée | **Corruption partielle** des fichiers, base saine : on remet ce qui manque ou a été abîmé, sans perdre les téléversements récents que la base actuelle référence |
| `--mirror` | État **exact** de l'instantané : les fichiers absents de l'instantané sont **supprimés**. Leur nombre est annoncé et doit être confirmé (`SUPPRIMER <n>`) | **Perte totale du serveur** (volumes neufs : rien à conserver) ; retour complet base + fichiers à un instant donné ; **test de restauration sur le staging**, qui doit être déterministe |

Détail et commandes par scénario : README, « Choisir le mode de restauration
des fichiers ».

---

## Test 0 — Ouvrir le dépôt depuis le Mac

Le scénario couvert : le VPS a disparu, avec `/etc/alivaon-backup/`. Il ne
reste que le gestionnaire de mots de passe.

Le test se joue deux fois lors de la mise en place : à l'**étape 1** de
RUNBOOK-BACKUP, sur le dépôt tout juste créé et encore **vide**, avant que le
VPS ne reçoive le mot de passe ; puis à l'**étape 8**, après la première
sauvegarde. Les deux premiers blocs ne sont à refaire que sur un nouveau poste.

```bash
brew install restic
```

**Effet** : installe restic sur le Mac. Idempotent.

*Dépôt Storage Box (option A)* — autoriser une clé du Mac sur le sous-compte :

```bash
ssh-copy-id -p 23 -s <UTILISATEUR_SB>@<HOTE_SB>
```

**Effet** : dépose la clé SSH du Mac sur le sous-compte. Demande le mot de
passe du sous-compte, **pris dans le gestionnaire**, pas ailleurs.
**Vérifier** : `Number of key(s) added: 1` (ou « already exist »).

```bash
restic --no-cache -r 'sftp://<UTILISATEUR_SB>@<HOTE_SB>:23/restic-alivaon' snapshots --tag alivaon
```

**Effet** : lit l'inventaire du dépôt. restic **demande** le mot de passe :
le coller depuis le gestionnaire. `--no-cache` : rien n'est écrit sur le Mac.
*Option B, S3* : `export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...`
depuis le gestionnaire, puis même commande avec l'URL `s3:...`.
**Critère de réussite** :
- à l'étape 1 (dépôt vide) : restic ouvre le dépôt sans erreur et affiche une
  liste vide ;
- ensuite : la liste s'affiche, dont les instantanés de la dernière
  sauvegarde pour `env:production` et `env:staging`.
**Échec** (`wrong password`, dépôt introuvable) : **incident de priorité
maximale**. Tant qu'il n'est pas résolu, une perte du VPS entraîne la perte de
toutes les sauvegardes.

```bash
restic --no-cache -r 'sftp://<UTILISATEUR_SB>@<HOTE_SB>:23/restic-alivaon' cat config
```

**Vérifier** : le champ `"id"` est égal à l'identifiant du dépôt noté dans le
gestionnaire (RUNBOOK-BACKUP, étape 1).

---

## Test 1 — Restauration complète du staging

Principe : sauvegarder le staging, relever des témoins, **détruire** la base et
un fichier, restaurer, puis constater le retour des témoins.

La destruction est volontaire : restaurer par-dessus des données intactes ne
prouverait rien, puisque le site répondrait avant comme après.

### 1.1 — Sauvegarde fraîche [VPS]

```bash
sudo /usr/local/lib/alivaon-backup/verify.sh
```

**Vérifier** : `BILAN : dépôt sain`. Sinon, ne pas poursuivre : réparer d'abord.

```bash
sudo /usr/local/lib/alivaon-backup/backup.sh --env staging
```

**Effet** : sauvegarde le staging seul, puis applique la rétention.
**Vérifier** : dernière ligne `sauvegarde complète réussie`.

### 1.2 — Identifier l'instantané [VPS]

```bash
sudo /usr/local/lib/alivaon-backup/restore.sh --list --target staging
```

**Vérifier** : l'instantané le plus récent date de l'étape 1.1. Noter son ID
court (8 caractères) : `<ID_INSTANTANE>`.

### 1.3 — Relever les témoins [VPS]

```bash
docker exec -it staging-db-1 mysql -u alivaon_app -p -N -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='alivaon_db'"
```

**Effet** : compte les tables (mot de passe : `MYSQL_PASSWORD` du `.env` du
staging).
**Noter** : `<N_TABLES>`.

```bash
docker exec staging-app-1 find /var/www/html/public/uploads -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) -print -quit
```

**Effet** : désigne une image téléversée.
**Noter** : son chemin après `/var/www/html/public/uploads/` : `<FICHIER>`. Il
est accessible à l'URL `https://www.staging.alivaon.com/uploads/<FICHIER>`.

```bash
docker exec staging-app-1 sha256sum /var/www/html/public/uploads/<FICHIER>
```

**Noter** : `<EMPREINTE>`.

**[NAVIGATEUR]** Choisir un article publié sur le staging. Noter son URL
`<URL_ARTICLE>` et un fragment exact de son titre `<TITRE_ARTICLE>`.

### 1.4 — Contrôles de référence [MAC]

Les identifiants BasicAuth du staging sont lus depuis un fichier netrc
temporaire, pour qu'ils n'apparaissent ni dans l'historique du shell ni dans
`ps`.

```bash
touch ~/.alivaon-staging.netrc && chmod 600 ~/.alivaon-staging.netrc && open -e ~/.alivaon-staging.netrc
```

**Effet** : crée le fichier en `600` et l'ouvre dans TextEdit. Y écrire une
ligne, puis enregistrer :
`machine www.staging.alivaon.com login <UTILISATEUR> password <MOT_DE_PASSE>`

```bash
curl -s -o /dev/null -w '%{http_code}\n' --netrc-file ~/.alivaon-staging.netrc https://www.staging.alivaon.com/
```

**Vérifier** : `200`.

```bash
curl -s --netrc-file ~/.alivaon-staging.netrc '<URL_ARTICLE>' | grep -c '<TITRE_ARTICLE>'
```

**Vérifier** : `1` ou plus.

```bash
curl -s --netrc-file ~/.alivaon-staging.netrc 'https://www.staging.alivaon.com/uploads/<FICHIER>' | shasum -a 256
```

**Vérifier** : `<EMPREINTE>`. L'URL testée est celle du fichier **original**
servi depuis le volume, et non une variante LiipImagine
(`/media/cache/...`) : une variante déjà en cache répondrait même si l'original
avait disparu, et le test ne prouverait rien.

### 1.5 — Destruction contrôlée [VPS]

```bash
docker exec staging-app-1 rm /var/www/html/public/uploads/<FICHIER>
```

**Effet** : supprime l'image du volume.

```bash
docker exec -it staging-db-1 mysql -u alivaon_app -p -e 'DROP DATABASE alivaon_db'
```

**Effet** : **supprime la base du staging.** C'est l'objet du test.

### 1.6 — Constater la panne [MAC]

```bash
curl -s -o /dev/null -w '%{http_code}\n' --netrc-file ~/.alivaon-staging.netrc 'https://www.staging.alivaon.com/uploads/<FICHIER>'
```

**Vérifier** : `404`.

```bash
curl -s -o /dev/null -w '%{http_code}\n' --netrc-file ~/.alivaon-staging.netrc '<URL_ARTICLE>'
```

**Vérifier** : `500`, ou toute réponse autre que `200`.

### 1.7 — Restaurer [VPS]

```bash
time sudo /usr/local/lib/alivaon-backup/restore.sh --target staging --snapshot <ID_INSTANTANE> --no-safety-snapshot --stop-app --mirror
```

**Effet** : vérifie l'instantané, contrôle que les volumes y appartiennent à
`STAGING_APP_OWNER`, affiche le récapitulatif, puis demande deux phrases :
`RESTAURER staging <ID_INSTANTANE>`, puis `SUPPRIMER <n>`, où `<n>` est le
nombre annoncé de fichiers présents sur le staging et absents de
l'instantané. Ensuite : arrêt de `staging-app-1`, recréation de la base,
synchronisation des volumes, **vérification du propriétaire et des droits de
chaque fichier restauré**, redémarrage, attente de l'état `healthy`.

- `--stop-app` : `staging-app-1` tourne ; sans cette option, `restore.sh`
  refuse. C'est le changement par rapport aux versions précédentes, où
  l'arrêt était implicite.
- `--mirror` : un test doit reproduire exactement l'instantané. `<n>` vaut
  normalement **0** : l'étape 1.5 a *supprimé* un fichier, elle n'en a pas
  ajouté. Un `<n>` non nul signale des téléversements survenus sur le staging
  depuis l'étape 1.1 : les noter avant de confirmer.
- `--no-safety-snapshot` : la base ayant été supprimée, il n'y a rien à
  archiver, et l'instantané de référence est celui de l'étape 1.1. Hors test,
  ne pas utiliser cette option.

**Vérifier** : une ligne `volume 'uploads' : propriétaire, groupe et droits
conformes à l'instantané` (et de même pour `cv_private`), puis la dernière
ligne `restauration terminée : staging <- <ID_INSTANTANE>`. Noter la durée
`real` affichée par `time` : c'est le **temps de restauration** observé,
saisie des confirmations comprise.

### 1.8 — Contrôles serveur [VPS]

```bash
docker exec -it staging-db-1 mysql -u alivaon_app -p -N -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='alivaon_db'"
```

**Vérifier** : `<N_TABLES>`.

```bash
docker exec staging-app-1 sha256sum /var/www/html/public/uploads/<FICHIER>
```

**Vérifier** : `<EMPREINTE>`.

```bash
docker exec staging-app-1 stat -c '%u:%g' /var/www/html/public/uploads/<FICHIER>
```

**Vérifier** : `82:82`, soit `www-data` dans l'image. Les propriétaires ont été
restaurés tels quels.

### 1.9 — Critères de réussite [MAC]

```bash
curl -s -o /dev/null -w '%{http_code}\n' --netrc-file ~/.alivaon-staging.netrc https://www.staging.alivaon.com/
```

```bash
curl -s --netrc-file ~/.alivaon-staging.netrc '<URL_ARTICLE>' | grep -c '<TITRE_ARTICLE>'
```

```bash
curl -s -o /dev/null -w '%{http_code} %{content_type}\n' --netrc-file ~/.alivaon-staging.netrc 'https://www.staging.alivaon.com/uploads/<FICHIER>'
```

```bash
curl -s --netrc-file ~/.alivaon-staging.netrc 'https://www.staging.alivaon.com/uploads/<FICHIER>' | shasum -a 256
```

```bash
./scripts/check-staging-auth.sh
```

**Écriture réelle.** Afficher une image ne prouve que la lecture. Le défaut
typique d'une restauration (fichiers au mauvais propriétaire) ne se révèle
qu'à l'écriture, parfois des heures plus tard, sous une forme qui ne ressemble
pas à un problème de restauration. D'où ce critère :

**[NAVIGATEUR]** Sur `https://www.staging.alivaon.com`, téléverser une image
par un formulaire de l'application qui en accepte une (image d'article, par
exemple). **Vérifier** : l'enregistrement réussit, sans message d'erreur, et
l'image s'affiche.

**[VPS]**

```bash
docker exec staging-app-1 find /var/www/html/public/uploads -type f -mmin -15 -exec stat -c '%u:%g %a %n' {} +
```

**Effet** : liste les fichiers écrits dans le volume ces 15 dernières minutes.
**Vérifier** : au moins une ligne, celle de l'image téléversée, appartenant à
`82:82` (`STAGING_APP_OWNER`). Aucune ligne : l'application n'a pas pu écrire.

| # | Critère | Attendu | ✓ |
|---|---|---|---|
| C1 | `restore.sh` s'est terminé sans erreur | `restauration terminée` | ☐ |
| C2 | Le site staging répond | `200` | ☐ |
| C3 | Un article s'affiche | `grep -c` ≥ 1 | ☐ |
| C4 | L'image d'upload se charge | `200 image/...` | ☐ |
| C5 | L'image est identique à l'original | empreinte = `<EMPREINTE>` | ☐ |
| C6 | Le schéma est complet | `<N_TABLES>` tables | ☐ |
| C7 | La protection du staging est intacte | `check-staging-auth.sh` : `401`, code 0 | ☐ |
| C8 | L'application **écrit** dans le volume restauré | téléversement réussi, fichier présent, `82:82` | ☐ |

**Test réussi si et seulement si C1 à C8 sont tous cochés.**

```bash
rm ~/.alivaon-staging.netrc
```

**Effet** : supprime les identifiants BasicAuth du Mac.

### En cas d'échec

- `restore.sh` s'est arrêté **avant** l'écriture (`abandonnée AVANT toute
  écriture`) : la cause est dans le journal affiché. Le staging est resté dans
  son état saboté : corriger, puis relancer 1.7.
- `restore.sh` s'est arrêté **pendant** l'écriture : `staging-app-1` a été
  redémarré par le trap (retour à l'état initial), mais le staging est dans
  un état intermédiaire. Corriger, relancer 1.7 : la restauration est
  complète et rejouable.
- Écart de propriété ou de droits signalé en fin de restauration, ou C8 en
  échec : comparer avec la référence de l'étape 2 de RUNBOOK-BACKUP (UID/GID
  des processus PHP-FPM et des volumes). Ne pas corriger par un `chown` à la
  main sans avoir compris l'écart : il signale un défaut de la chaîne.
- C2 à C5 échouent alors que C1 est vert : `docker logs staging-app-1`. Si
  l'image applicative est plus récente que l'instantané :
  `docker exec staging-app-1 php bin/console doctrine:migrations:status`.
- Dans tous les cas : consigner l'échec au journal, et le traiter comme un
  incident sur la sauvegarde de **production**, qui repose sur le même code.

---

## Test 2 — Production restaurable, sans exposer ses données

Le dump de production est rejoué dans un conteneur MySQL **jetable, sans
réseau**, détruit juste après. Aucune donnée de production n'atteint le
staging, et aucune application ne tourne sur ces données : ni courriel envoyé,
ni page servie.

```bash
docker run -d --rm --name restore-test-mysql --network none -e MYSQL_ALLOW_EMPTY_PASSWORD=yes mysql:8.0
```

**Effet** : démarre un MySQL vierge, isolé (`--network none`). `--rm` : le
conteneur et son volume anonyme disparaissent à l'arrêt.

```bash
until docker logs restore-test-mysql 2>&1 | grep -q 'ready for connections.*port: 3306'; do sleep 2; done; echo prêt
```

**Effet** : attend le **vrai** démarrage. L'image lance d'abord un serveur
temporaire d'initialisation (`port: 0`), qui s'arrête ensuite : l'import doit
attendre le second.
**Vérifier** : `prêt`.

```bash
sudo /usr/local/lib/alivaon-backup/restic.sh dump --tag alivaon,env:production,kind:scheduled latest /var/lib/alivaon-backup/dumps/production/alivaon_db.sql | docker exec -i restore-test-mysql mysql -uroot
```

**Effet** : extrait le dernier dump de production du dépôt et le rejoue dans le
conteneur jetable. Le dump transite par un tube, jamais sur disque.
**Vérifier** : aucune erreur affichée.

```bash
docker exec restore-test-mysql mysql -uroot -N -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='alivaon_db'; SELECT MAX(version) FROM alivaon_db.doctrine_migration_versions;"
```

**Effet** : nombre de tables, dernière migration Doctrine rejouée.

```bash
docker exec -it production-db-1 mysql -u alivaon_app -p -N -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='alivaon_db'; SELECT MAX(version) FROM alivaon_db.doctrine_migration_versions;"
```

**Effet** : mêmes valeurs, lues sur la production réelle (en lecture seule).
**Critère** : nombre de tables **identique**, dernière migration **identique**,
sauf déploiement survenu depuis la sauvegarde. Si la table
`doctrine_migration_versions` porte un autre nom, comparer seulement le nombre
de tables.

```bash
docker stop restore-test-mysql
```

**Effet** : arrête et supprime le conteneur et ses données.
**Vérifier** : `docker ps -a --filter name=restore-test-mysql` n'affiche plus
que l'en-tête.

Fichiers de production : comparer un fichier archivé à l'original.

```bash
sudo find "$(docker volume inspect -f '{{.Mountpoint}}' production_uploads)" -type f -print -quit
```

**Noter** : le chemin complet affiché, `<CHEMIN_PROD>`.

```bash
sudo /usr/local/lib/alivaon-backup/restic.sh dump --tag alivaon,env:production,kind:scheduled latest '<CHEMIN_PROD>' | sha256sum
```

```bash
sudo sha256sum '<CHEMIN_PROD>'
```

**Critère** : les deux empreintes sont identiques.

---

## Test 3 — Le refus staging → production

Sans risque : le refus intervient avant toute confirmation et toute écriture.

```bash
sudo /usr/local/lib/alivaon-backup/restore.sh --target production --snapshot <ID_INSTANTANE>
```

`<ID_INSTANTANE>` : un instantané **staging** (Test 1, étape 1.2).
**Critère** : message `REFUS : l'instantané ... provient du STAGING`, suivi de
`abandonnée AVANT toute écriture`, et **aucune** demande de confirmation.

```bash
echo $?
```

**Critère** : `3`.

---

## Journal des tests

| Date | Opérateur | Test | Instantané | Durée de restauration | Résultat | Remarques |
|---|---|---|---|---|---|---|
| | | | | | | |
