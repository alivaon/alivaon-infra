# Runbook — mise en place de la sauvegarde sur le VPS

Procédure pas à pas, à suivre **dans l'ordre**. Compter une demi-journée,
test de restauration compris.

Chaque commande est dans son propre bloc, précédée de l'endroit où elle
s'exécute :

| Marque | Où | Comment |
|---|---|---|
| **[MAC]** | Terminal du Mac, **à la racine du dépôt `alivaon-infra`** | tel quel |
| **[VPS]** | Session SSH sur le serveur : `ssh alivaon` | utilisateur `alivaondev`, `sudo` quand indiqué |
| **[VPS — mysql>]** | Invite du client MySQL ouverte par le bloc précédent | une instruction par bloc |
| **[NAVIGATEUR]** | Console Hetzner, healthchecks.io, gestionnaire de mots de passe | à la main |

Sous chaque commande : **Effet** (ce qu'elle fait) et **Vérifier** (ce qu'il faut
constater avant de passer à la suivante). Si la vérification échoue, s'arrêter.

Valeurs à substituer, notées entre chevrons :

| Placeholder | Exemple | Source |
|---|---|---|
| `<HOTE_SB>` | `u123456.your-storagebox.de` | Console Hetzner, Storage Box |
| `<UTILISATEUR_SB>` | `u123456-sub1` | Sous-compte créé à l'étape 0 |
| `<MDP_BACKUP_PRODUCTION>`, `<MDP_BACKUP_STAGING>` | 48 caractères hexadécimaux | Générés à l'étape 3, rangés dans le gestionnaire |

## Ordre d'exécution

| Étape | Quoi | Où |
|---|---|---|
| 0 | Storage Box, puis **instantanés automatiques activés** (obligatoire) | Navigateur |
| 1 | Mot de passe restic dans le gestionnaire, dépôt initialisé depuis le Mac, **test 0** | Mac |
| 2 | Contrôle des hypothèses (noms de conteneurs, volumes, privilèges) | VPS |
| — | Dans la même fenêtre : correctif du healthcheck MySQL, staging puis production ([runbook dédié](../docs/runbook-healthcheck-mysql.md)) | Mac, VPS |
| 3 | Utilisateurs MySQL `backup`, un par environnement, et dump d'essai | VPS |
| 4 | restic et outils | VPS |
| 5 | `install.sh` | Mac puis VPS |
| 6 | Accès SSH du VPS à la Storage Box | VPS |
| 7 | Configuration et mot de passe sur le VPS | VPS |
| 8 | Première sauvegarde manuelle | VPS |
| 9 | `systemd-analyze verify` | VPS |
| 10 | Activation des timers et du dead man's switch | VPS, navigateur |
| 11 | **Test de restauration complet sur le staging** | VPS, Mac |

> ### La mise en place n'est terminée qu'à l'issue de l'étape 11
>
> Timers actifs et sauvegardes qui tournent ne prouvent rien : seule une
> restauration réussie le prouve. Tant que les critères C1 à C7 du
> [test 1](RUNBOOK-RESTORE-TEST.md#test-1--restauration-complète-du-staging)
> ne sont pas tous verts, le dispositif est **en rodage**, pas en service.

---

## Hypothèses

Les fichiers compose de ce dépôt ne déclarent aucun `name:` de projet ni
`container_name:` pour les stacks `production` et `staging`. Les noms ci-dessous
en sont **déduits**, recoupés avec les autres fichiers du dépôt. Ils sont
contrôlés à l'**étape 2**, avant toute écriture sur le serveur.

| # | Hypothèse | Fondement dans le dépôt | Degré |
|---|---|---|---|
| H1 | Nom de projet Compose = nom du dossier (`production`, `staging`) | Aucun `name:` dans les compose ; volumes externes de `filebrowser/docker-compose.yml` nommés `production_uploads` et `staging_uploads_staging`, ce qui n'est vrai que sous cette hypothèse | **Confirmé** indirectement : File Browser tourne avec ces noms |
| H2 | Volumes d'uploads : `production_uploads`, `staging_uploads_staging` | `filebrowser/docker-compose.yml`, section `volumes:` | **Confirmé** (même source) |
| H3 | Volumes de CV : `production_cv_private`, `staging_cv_private_staging` | Commentaire d'en-tête de `filebrowser/docker-compose.yml` ; règle de nommage de H1 appliquée à `cv_private` et `cv_private_staging` | Déduit |
| H4 | Le cache LiipImagine n'est **pas** dans un volume (défaut Liip : `public/media/cache`, dans la couche du conteneur, régénéré à la demande) | Aucun volume sur `public/media` dans les compose | **Non vérifiable depuis le dépôt**, la configuration Liip vit dans `alivaon-symfony` |
| H5 | Conteneurs MySQL : `production-db-1`, `staging-db-1` | `ADMINER_DEFAULT_SERVER` dans `adminer/docker-compose.yml` | **Confirmé** |
| H6 | Conteneurs applicatifs : `production-app-1`, `staging-app-1` | Règle `<projet>-<service>-1` de Compose v2, appliquée au service `app` | Déduit, **jamais vu écrit** dans le dépôt |
| H7 | Base `alivaon_db`, utilisateur `alivaon_app`, avec `ALL PRIVILEGES ON alivaon_db.*` dans les deux environnements | README racine, « Connexion à Adminer » ; privilèges : comportement de l'image `mysql:8.0` pour `MYSQL_USER` | Noms confirmés, privilèges déduits |
| H8 | Tables toutes InnoDB, aucune routine stockée ni événement | Application Doctrine standard | Déduit. `--single-transaction` n'est cohérent **que** pour InnoDB |
| H9 | **Pilote `local` requis** pour chaque volume sauvegardé : seul ce pilote garantit que le point de montage donné par Docker est un dossier de l'hôte, lisible par restic et inscriptible par rsync | Aucun `driver:` dans les compose, donc pilote par défaut | Déduit. **Vérifié à chaque exécution** : les scripts refusent un volume absent ou d'un autre pilote (`resolve_volume`, `lib.sh`). Contrôlé aussi par la 3ᵉ commande de l'étape 2 |

**Les CV sont sauvegardés.** Le volume `cv_private` contient des fichiers
téléversés par les candidats, absents de la base : sans sauvegarde, une perte
du serveur les efface définitivement. Ils suivent la rétention générale, comme
tout le reste (README, « Données des candidats »).

**Chemins sur disque : aucun n'est supposé.** Les scripts demandent à Docker le
point de montage de chaque volume à chaque exécution (`docker volume inspect`).
Un `data-root` Docker non standard est donc pris en charge sans modification.

---

## Étape 0 — Storage Box et instantanés automatiques [NAVIGATEUR]

1. **Storage Box.** Console Hetzner → Storage Box → commander une BX11 (1 To),
   même région que le VPS de préférence mais **pas une obligation** : c'est
   justement une copie hors machine.
2. **Accès SSH.** Dans les réglages de la Storage Box : activer *SSH support*.
3. **Sous-compte dédié.** Créer un sous-compte (par exemple de répertoire de
   base `alivaon`) avec accès SSH, sans Samba ni WebDAV. Le VPS n'aura accès
   qu'à ce répertoire, jamais au reste de la boîte. Noter l'identifiant
   (`<UTILISATEUR_SB>`) et le mot de passe dans le gestionnaire.
4. **Instantanés automatiques — OBLIGATOIRE, avant toute sauvegarde.**
   Console Hetzner → Storage Box → *Snapshots* → planification automatique
   **quotidienne**, avec le nombre d'instantanés conservés le plus élevé que
   permet le forfait.

   > **Pourquoi c'est obligatoire : le scénario rançongiciel.** Le VPS détient
   > une clé SSH qui écrit sur la Storage Box ; il le faut pour sauvegarder.
   > Un attaquant devenu root sur le VPS dispose donc de cette clé, et peut
   > chiffrer les sites **puis effacer le dépôt restic** par SFTP. Les
   > sauvegardes disparaissent au moment exact où l'on en a besoin.
   >
   > Les instantanés de la Storage Box sont pris et supprimés **par Hetzner**,
   > pilotés depuis la console. Le sous-compte SFTP ne peut ni les lister ni
   > les supprimer : ils sont hors de portée d'une compromission du VPS. Après
   > une attaque, le dépôt se restaure depuis l'instantané de la veille.
   >
   > Deux conditions pour que la protection tienne : les identifiants de la
   > console Hetzner et de l'API Robot ne doivent **jamais** se trouver sur le
   > VPS, et le compte Hetzner doit être protégé par une double
   > authentification.

   **Vérifier** : la planification apparaît comme active dans la console. Le
   lendemain, un premier instantané figure dans la liste.
5. **Gestionnaire de mots de passe.** Créer une entrée « Alivaon — sauvegarde
   restic » avec les champs suivants, remplis au fil de la procédure :
   - mot de passe du dépôt restic (étape 1) ;
   - `RESTIC_REPOSITORY` et identifiant du dépôt (étape 1) ;
   - hôte de la Storage Box, identifiant et mot de passe du sous-compte ;
   - mots de passe MySQL `backup`, production et staging (étape 3) ;
   - URL de ping healthchecks (étape 10).

---

## Étape 1 — Mot de passe restic, dépôt et test 0 [MAC]

> ### ⚠️ Point de défaillance unique
>
> Le mot de passe du dépôt restic chiffre **toutes** les sauvegardes. Personne,
> ni Hetzner ni restic, ne peut le retrouver ni le contourner. Sur le serveur, il
> vivra dans `/etc/alivaon-backup/restic-password`, et ce fichier **disparaît
> avec le VPS**.
>
> D'où l'ordre de cette étape : le mot de passe naît dans le gestionnaire, le
> dépôt est créé **depuis le Mac** avec cette seule copie, et le test 0 prouve
> qu'elle l'ouvre, avant que le VPS n'en reçoive le moindre exemplaire. La
> copie du gestionnaire est ainsi la référence, pas une recopie faite après
> coup.

```bash
openssl rand -base64 48 | tr -d '\n' | pbcopy
```

**Effet** : génère 48 octets aléatoires (64 caractères base64) et les place
dans le presse-papiers, sans les afficher ni les écrire sur disque.
**Vérifier** : coller dans le champ « mot de passe du dépôt » de l'entrée du
gestionnaire, enregistrer. L'entrée doit être synchronisée (coffre partagé ou
sauvegardé) : un gestionnaire local au Mac déplacerait le point de défaillance
sans le supprimer.

```bash
ssh-copy-id -p 23 -s <UTILISATEUR_SB>@<HOTE_SB>
```

**Effet** : dépose la clé SSH du Mac sur le sous-compte. À la première
connexion, ssh affiche l'empreinte de l'hôte ; puis il demande le mot de passe
du sous-compte, pris dans le gestionnaire.
**Vérifier** : l'empreinte affichée est **identique** à celle que Hetzner
publie pour les Storage Box (documentation Hetzner, « Storage Box — SSH host
keys ») ; puis `Number of key(s) added: 1`.

```bash
brew install restic
```

**Effet** : installe restic sur le Mac. Idempotent.
**Vérifier** : `restic version` affiche une version ≥ 0.16.

```bash
restic --no-cache -r 'sftp://<UTILISATEUR_SB>@<HOTE_SB>:23/restic-alivaon' init
```

**Effet** : crée le dépôt chiffré sur la Storage Box. restic demande deux fois
le mot de passe : le coller depuis le gestionnaire. Sur un dépôt existant,
restic refuse (`config file already exists`) sans rien modifier.
**Vérifier** : `created restic repository <id> at ...`. Recopier `<id>` dans le
gestionnaire : il identifie ce dépôt sans ambiguïté.

**Test 0.** Suivre le [test 0](RUNBOOK-RESTORE-TEST.md#test-0--ouvrir-le-dépôt-depuis-le-mac)
de RUNBOOK-RESTORE-TEST.md : le dépôt, vide à ce stade, doit s'ouvrir avec la
seule copie du gestionnaire, et son identifiant correspondre. **Ne pas
continuer** tant que le test 0 n'a pas réussi.

---

## Étape 2 — Contrôler les hypothèses [VPS]

Rien n'est modifié à cette étape. Si un résultat diffère de l'attendu, corriger
la valeur correspondante à l'étape 7, pas le code.

```bash
docker ps --format '{{.Names}}' | sort
```

**Effet** : liste les conteneurs en cours d'exécution.
**Vérifier (H5, H6)** : présence de `production-app-1`, `production-db-1`,
`staging-app-1`, `staging-db-1`.

```bash
docker volume ls --format '{{.Name}}' | grep -E 'uploads|cv_private'
```

**Effet** : liste les volumes de fichiers.
**Vérifier (H2, H3)** : exactement `production_cv_private`, `production_uploads`,
`staging_cv_private_staging`, `staging_uploads_staging`.

```bash
docker volume inspect -f '{{.Name}} {{.Driver}} {{.Mountpoint}}' production_uploads production_cv_private staging_uploads_staging staging_cv_private_staging
```

**Effet** : affiche le pilote et le point de montage de chaque volume.
**Vérifier** : quatre lignes, sans erreur `no such volume`. **(H9)** Le pilote
est `local` sur chaque ligne. Un autre pilote : s'arrêter, les scripts
refuseraient ce volume.

```bash
sudo du -sh $(docker volume inspect -f '{{.Mountpoint}}' production_uploads production_cv_private staging_uploads_staging staging_cv_private_staging)
```

**Effet** : mesure le volume de fichiers à sauvegarder.
**Vérifier** : noter les tailles. Elles servent à l'estimation de coût du
README (section « Coût »).

```bash
docker exec production-app-1 sh -c 'grep -rnE "cache_prefix|web_path|upload_destination|uri_prefix" /var/www/html/config/packages/ 2>/dev/null'
```

**Effet** : affiche la configuration VichUploader et LiipImagine de
l'application.
**Vérifier (H4)** : les `upload_destination` pointent sous `public/uploads` ou
`var/private` (les volumes). Si `cache_prefix` place le cache Liip **sous
`uploads`**, le cache est dans le volume : créer un fichier d'exclusion
(`/etc/alivaon-backup/exclude.txt`, une ligne par motif, par exemple
`*/media/cache`) et le déclarer dans `RESTIC_EXCLUDE_FILE` à l'étape 7. Sinon,
rien à faire.

```bash
docker exec -it production-db-1 mysql -u alivaon_app -p -e 'SHOW GRANTS'
```

**Effet** : demande le mot de passe (celui de `MYSQL_PASSWORD` dans
`/opt/alivaon/production/.env`), puis affiche les privilèges. Le `-p` sans
valeur fait saisir le mot de passe de façon interactive : il n'apparaît pas
dans `ps`.
**Vérifier (H7)** : une ligne ``GRANT ALL PRIVILEGES ON `alivaon_db`.* TO
`alivaon_app`@`%` ``. Cet utilisateur ne sert qu'à la **restauration** (la
sauvegarde passe par l'utilisateur `backup`, étape 3) : sans `ALL`, il lui faut
au minimum `CREATE, DROP, INSERT, ALTER, INDEX, REFERENCES` sur `alivaon_db`,
pour supprimer puis recréer la base.

```bash
docker exec -it production-db-1 mysql -u alivaon_app -p -e "SELECT ENGINE, COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='alivaon_db' GROUP BY ENGINE; SELECT COUNT(*) AS routines FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='alivaon_db'; SELECT COUNT(*) AS evenements FROM information_schema.EVENTS WHERE EVENT_SCHEMA='alivaon_db';"
```

**Effet** : moteurs de stockage, nombre de routines et d'événements.
**Vérifier (H8)** : `InnoDB` seul (une ligne `NULL` pour les vues est normale),
`routines` = 0, `evenements` = 0. Une table MyISAM ne serait pas figée par
`--single-transaction` ; des routines ne seraient pas sauvegardées. Dans l'un
ou l'autre cas, s'arrêter et adapter `DB_DUMP_SCRIPT` dans `lib.sh`.

```bash
docker exec -it staging-db-1 mysql -u alivaon_app -p -e 'SHOW GRANTS'
```

**Effet / Vérifier** : identiques, pour le staging (mot de passe de
`/opt/alivaon/staging/.env`).

> **Fenêtre de maintenance commune.** Le correctif du healthcheck MySQL
> ([docs/runbook-healthcheck-mysql.md](../docs/runbook-healthcheck-mysql.md))
> recrée les conteneurs MySQL : coupure de la base de **20 à 40 s par
> environnement**. Le dérouler **ici**, entre l'étape 2 et l'étape 3, staging
> d'abord, puis production dans le même créneau creux que cette mise en place :
> la base n'est interrompue qu'une fois, et la première sauvegarde (étape 8)
> porte sur les conteneurs définitifs. Les noms de conteneurs ne changent pas :
> les constats de l'étape 2 restent valables.

---

## Étape 3 — Utilisateurs MySQL de sauvegarde [MAC, VPS]

Un utilisateur `backup` par environnement, chacun dans son propre serveur
MySQL, avec son propre mot de passe.

### Privilèges : le jeu minimal

| Privilège | Portée | Pourquoi mysqldump en a besoin |
|---|---|---|
| `SELECT` | `alivaon_db.*` | lire les tables |
| `SHOW VIEW` | `alivaon_db.*` | exporter la définition des vues |
| `TRIGGER` | `alivaon_db.*` | exporter les déclencheurs (`--triggers`) |

Et rien d'autre, parce que les options du dump rendent inutiles les privilèges
habituellement cités :

| Privilège **non** accordé | Pourquoi il n'est pas requis ici |
|---|---|
| `LOCK TABLES` | `--single-transaction` lit un instantané InnoDB cohérent **sans** verrouiller les tables |
| `PROCESS` | Exigé depuis MySQL 8.0.21 pour lire `INFORMATION_SCHEMA.FILES` (tablespaces) ; `--no-tablespaces` supprime cette lecture |
| `RELOAD` | Ne sert qu'à `FLUSH TABLES` / `FLUSH LOGS`, émis avec `--flush-logs` ou `--source-data`, non utilisés |

**Effet recherché** : le dump ne dépend plus des privilèges de l'application,
qui reste minimale. L'utilisateur applicatif n'est ni modifié ni élargi ; il
ne sert plus qu'à `restore.sh`, qui doit pouvoir supprimer et recréer la base.
`SELECT` porte sur `alivaon_db.*` et **non** sur `*.*`, qui ouvrirait la table
`mysql.user` et ses empreintes de mots de passe.

Si le dump d'essai échoue malgré tout sur un privilège, **l'escalade 3.3**
dit lequel ajouter, un à la fois.

### Mode de connexion : socket, donc 'backup'@'localhost'

`backup.sh` exécute mysqldump **dans le conteneur MySQL** (`docker exec`),
sans `-h`, et impose `protocol=socket` dans son fichier d'options. MySQL
évalue une connexion par socket Unix comme venant de `localhost` : le compte
est donc créé en `'backup'@'localhost'`. Il n'est joignable que de l'intérieur
du conteneur ; ni le conteneur applicatif ni Adminer ne peuvent l'utiliser.

L'hôte du compte et le mode de connexion doivent s'accorder. Une connexion
TCP, même vers `127.0.0.1`, est évaluée comme `'backup'@'127.0.0.1'`, qui
**n'existe pas** : refus d'accès. `tests/run.sh` vérifie cet accord à chaque
modification des scripts ou de ce runbook.

### 3.1 — Production (production-db-1)

**[MAC]**

```bash
openssl rand -hex 24 | pbcopy
```

**Effet** : génère le mot de passe de l'utilisateur `backup` de production
(48 caractères hexadécimaux : aucun caractère à échapper, ni en SQL ni dans un
fichier d'options).
**Vérifier** : le coller dans le gestionnaire, champ « MySQL backup — production ».
C'est `<MDP_BACKUP_PRODUCTION>`.

**[VPS]**

```bash
docker exec -it production-db-1 mysql -u root -p
```

**Effet** : ouvre le client MySQL en root dans le conteneur. Le mot de passe
(`MYSQL_ROOT_PASSWORD` de `/opt/alivaon/production/.env`) est saisi à l'invite, il
n'apparaît pas dans `ps`.
**Vérifier** : l'invite `mysql>` s'affiche.

**[VPS — mysql>]** Remplacer `<MDP_BACKUP_PRODUCTION>` avant de coller.

```sql
CREATE USER IF NOT EXISTS 'backup'@'localhost' IDENTIFIED BY '<MDP_BACKUP_PRODUCTION>';
```

**Effet** : crée l'utilisateur s'il n'existe pas, pour des connexions par
socket uniquement. Le client MySQL n'inscrit pas dans son historique les
instructions contenant `IDENTIFIED`.
**Vérifier** : `Query OK`.

```sql
ALTER USER 'backup'@'localhost' IDENTIFIED BY '<MDP_BACKUP_PRODUCTION>';
```

**Effet** : fixe le mot de passe, même si l'utilisateur existait déjà. Les deux
instructions ensemble rendent l'étape rejouable.
**Vérifier** : `Query OK`.

```sql
GRANT SELECT, SHOW VIEW, TRIGGER ON `alivaon_db`.* TO 'backup'@'localhost';
```

**Effet** : le jeu minimal, sur la seule base applicative. Idempotent.
**Vérifier** : `Query OK`.

```sql
SHOW GRANTS FOR 'backup'@'localhost';
```

**Vérifier** : exactement deux lignes, ``GRANT USAGE ON *.*`` (aucun privilège
global : c'est voulu) et ``GRANT SELECT, SHOW VIEW, TRIGGER ON `alivaon_db`.*``,
toutes deux à ``'backup'@'localhost'``. Si une ligne `PROCESS` ou `RELOAD`
apparaît, elle vient d'une version antérieure de ce runbook : la retirer par
`REVOKE PROCESS, RELOAD ON *.* FROM 'backup'@'localhost';`, sauf si
l'escalade (3.3) l'a rendue nécessaire.

```sql
exit
```

**[VPS] Vérification : dump d'essai avec le compte tout juste créé**

```bash
docker exec -it production-db-1 sh -c 'mysqldump --protocol=socket -u backup -p --single-transaction --quick --routines --triggers --no-tablespaces --default-character-set=utf8mb4 --hex-blob --set-gtid-purged=OFF --add-drop-database --databases alivaon_db > /tmp/essai.sql; echo "code=$?"; tail -n 1 /tmp/essai.sql; rm -f /tmp/essai.sql'
```

**Effet** : demande le mot de passe `<MDP_BACKUP_PRODUCTION>` (saisi à l'invite, absent
de `ps`), puis produit un dump complet avec **exactement** le mode de connexion
(socket) et les options du script (`DB_DUMP_SCRIPT`, `lib.sh`). Le dump est
écrit dans le `/tmp` du conteneur ; son code de sortie et sa dernière ligne
sont affichés, puis il est supprimé.
**Vérifier** :
- `code=0` ;
- dernière ligne `-- Dump completed on ...` : le dump est allé jusqu'au bout ;
- **aucune** ligne `Got error`, `Access denied` ni `Warning` entre les deux,
  en particulier aucune erreur d'authentification (`1045`). Toute ligne de
  ce type se lit dans le tableau « Reconnaître un échec » ci-dessous.

### 3.2 — Staging (staging-db-1)

**[MAC]**

```bash
openssl rand -hex 24 | pbcopy
```

**Effet** : génère le mot de passe de l'utilisateur `backup` de staging
(48 caractères hexadécimaux : aucun caractère à échapper, ni en SQL ni dans un
fichier d'options).
**Vérifier** : le coller dans le gestionnaire, champ « MySQL backup — staging ».
C'est `<MDP_BACKUP_STAGING>`.

**[VPS]**

```bash
docker exec -it staging-db-1 mysql -u root -p
```

**Effet** : ouvre le client MySQL en root dans le conteneur. Le mot de passe
(`MYSQL_ROOT_PASSWORD` de `/opt/alivaon/staging/.env`) est saisi à l'invite, il
n'apparaît pas dans `ps`.
**Vérifier** : l'invite `mysql>` s'affiche.

**[VPS — mysql>]** Remplacer `<MDP_BACKUP_STAGING>` avant de coller.

```sql
CREATE USER IF NOT EXISTS 'backup'@'localhost' IDENTIFIED BY '<MDP_BACKUP_STAGING>';
```

**Effet** : crée l'utilisateur s'il n'existe pas, pour des connexions par
socket uniquement. Le client MySQL n'inscrit pas dans son historique les
instructions contenant `IDENTIFIED`.
**Vérifier** : `Query OK`.

```sql
ALTER USER 'backup'@'localhost' IDENTIFIED BY '<MDP_BACKUP_STAGING>';
```

**Effet** : fixe le mot de passe, même si l'utilisateur existait déjà. Les deux
instructions ensemble rendent l'étape rejouable.
**Vérifier** : `Query OK`.

```sql
GRANT SELECT, SHOW VIEW, TRIGGER ON `alivaon_db`.* TO 'backup'@'localhost';
```

**Effet** : le jeu minimal, sur la seule base applicative. Idempotent.
**Vérifier** : `Query OK`.

```sql
SHOW GRANTS FOR 'backup'@'localhost';
```

**Vérifier** : exactement deux lignes, ``GRANT USAGE ON *.*`` (aucun privilège
global : c'est voulu) et ``GRANT SELECT, SHOW VIEW, TRIGGER ON `alivaon_db`.*``,
toutes deux à ``'backup'@'localhost'``. Si une ligne `PROCESS` ou `RELOAD`
apparaît, elle vient d'une version antérieure de ce runbook : la retirer par
`REVOKE PROCESS, RELOAD ON *.* FROM 'backup'@'localhost';`, sauf si
l'escalade (3.3) l'a rendue nécessaire.

```sql
exit
```

**[VPS] Vérification : dump d'essai avec le compte tout juste créé**

```bash
docker exec -it staging-db-1 sh -c 'mysqldump --protocol=socket -u backup -p --single-transaction --quick --routines --triggers --no-tablespaces --default-character-set=utf8mb4 --hex-blob --set-gtid-purged=OFF --add-drop-database --databases alivaon_db > /tmp/essai.sql; echo "code=$?"; tail -n 1 /tmp/essai.sql; rm -f /tmp/essai.sql'
```

**Effet** : demande le mot de passe `<MDP_BACKUP_STAGING>` (saisi à l'invite, absent
de `ps`), puis produit un dump complet avec **exactement** le mode de connexion
(socket) et les options du script (`DB_DUMP_SCRIPT`, `lib.sh`). Le dump est
écrit dans le `/tmp` du conteneur ; son code de sortie et sa dernière ligne
sont affichés, puis il est supprimé.
**Vérifier** :
- `code=0` ;
- dernière ligne `-- Dump completed on ...` : le dump est allé jusqu'au bout ;
- **aucune** ligne `Got error`, `Access denied` ni `Warning` entre les deux,
  en particulier aucune erreur d'authentification (`1045`). Toute ligne de
  ce type se lit dans le tableau « Reconnaître un échec » ci-dessous.

### Reconnaître un échec du dump d'essai

Le message d'accès refusé cite toujours le compte **tel que MySQL l'a
évalué**, `'utilisateur'@'hôte'`. C'est l'hôte qui distingue les causes.

| Message | Cause | Remède |
|---|---|---|
| `Got error: 1045: Access denied for user 'backup'@'127.0.0.1' (using password: YES)`, ou un hôte en `172.…` | **Mauvais appariement hôte / mode de connexion** : connexion en TCP alors que le compte est `'backup'@'localhost'`. Un `-h`, un `--protocol=tcp` ou un `host=` dans un fichier d'options du conteneur en est la cause | Retirer l'option fautive. Ne **pas** créer de compte `'backup'@'%'` pour contourner : le script se connecte par socket |
| `Got error: 1045: Access denied for user 'backup'@'localhost' (using password: YES)` | Hôte correct, mais mot de passe erroné, ou compte absent | Rejouer `ALTER USER` avec le mot de passe du gestionnaire ; vérifier `SHOW GRANTS` |
| `Access denied for user 'backup'@'localhost' (using password: NO)` | Aucun mot de passe transmis (`-p` oublié) | Relancer la commande telle quelle |
| `Got error: 1044: Access denied for user 'backup'@'localhost' to database 'alivaon_db' when using LOCK TABLES` | Privilège manquant | Escalade 3.3, `LOCK TABLES` |
| `Access denied; you need (at least one of) the PROCESS privilege(s)` | Privilège manquant | Escalade 3.3, `PROCESS` |
| `Access denied; you need (at least one of) the RELOAD or FLUSH_TABLES privilege(s)` | Privilège manquant | Escalade 3.3, `RELOAD` |
| `Warning: ... insufficient privileges to SHOW CREATE ...` | Routine stockée présente, contraire à H8 | `GRANT SHOW_ROUTINE ON *.* TO 'backup'@'localhost';`, puis rejouer le dump d'essai |

### 3.3 — Escalade, seulement si le dump d'essai échoue sur un privilège

Principe : ajouter **un seul** privilège, rejouer le dump d'essai de
l'environnement concerné, et s'arrêter dès qu'il réussit. Dans cet ordre, du
moins au plus large :

| Ordre | Privilège | Portée | Ce qu'il permet | Quand il devient nécessaire |
|---|---|---|---|---|
| 1 | `LOCK TABLES` | `alivaon_db.*` | Poser des verrous en lecture sur les tables de la base | Une table n'est pas InnoDB (contraire à H8) : mysqldump la verrouille faute de pouvoir l'inclure dans la transaction |
| 2 | `PROCESS` | global | Voir les requêtes de **tous** les utilisateurs du serveur et lire les métadonnées d'InnoDB | Une version de mysqldump lit malgré tout les tablespaces |
| 3 | `RELOAD` | global | `FLUSH` : vider les caches, fermer les tables, faire tourner les journaux, poser un verrou global en lecture | mysqldump émet un `FLUSH`, par exemple sous GTID |

`PROCESS` et `RELOAD` sont **globaux** par nature : ils portent sur tout le
serveur, pas sur une base. C'est la raison de l'ordre, et de ne les accorder
que sur preuve.

**[VPS]** Remplacer `<CONTENEUR_DB>` par `production-db-1` ou `staging-db-1`,
selon l'environnement en échec :

```bash
docker exec -it <CONTENEUR_DB> mysql -u root -p
```

**[VPS — mysql>]** Le **premier** bloc de la liste seulement, puis `exit` et
dump d'essai de l'environnement. Passer au bloc suivant uniquement si le dump
échoue encore, et sur un autre privilège.

```sql
GRANT LOCK TABLES ON `alivaon_db`.* TO 'backup'@'localhost';
```

```sql
GRANT PROCESS ON *.* TO 'backup'@'localhost';
```

```sql
GRANT RELOAD ON *.* TO 'backup'@'localhost';
```

```sql
exit
```

**Vérifier** : le dump d'essai de l'environnement réussit (3.1 ou 3.2, dernier
bloc).
**Consigner** : dans l'entrée « MySQL backup — <environnement> » du
gestionnaire, le ou les privilèges ajoutés **et** le message d'erreur qui les
a rendus nécessaires. Le choix reste ainsi éclairé et réversible (`REVOKE`).
Si le dump échoue encore après `RELOAD`, le problème n'est pas un privilège :
s'arrêter, et relire le tableau ci-dessus.

---

## Étape 4 — Installer restic et les outils [VPS]

```bash
apt-cache policy restic
```

**Effet** : affiche la version de restic proposée par Ubuntu.
**Vérifier** : la ligne `Candidate:`. Version **0.16 ou plus** (Ubuntu 24.04 :
0.16.x), passer au bloc suivant. Version inférieure (Ubuntu 22.04 : 0.12.x),
aller à « Variante : binaire officiel » plus bas.

```bash
sudo apt-get install -y restic jq rsync curl
```

**Effet** : installe restic, jq (lecture du JSON de restic), rsync
(restauration des fichiers) et curl (dead man's switch). Idempotent.
**Vérifier** : `restic version` affiche une version ≥ 0.16.

### Variante : binaire officiel (si la version Ubuntu est < 0.16)

Remplacer `<VERSION>` par la dernière version publiée sur
<https://github.com/restic/restic/releases> (sans le `v`).

```bash
sudo apt-get install -y jq rsync curl bzip2
```

```bash
cd "$(mktemp -d)"
```

```bash
curl -fLO https://github.com/restic/restic/releases/download/v<VERSION>/restic_<VERSION>_linux_amd64.bz2
```

```bash
curl -fLO https://github.com/restic/restic/releases/download/v<VERSION>/SHA256SUMS
```

```bash
sha256sum --ignore-missing -c SHA256SUMS
```

**Vérifier** : `restic_<VERSION>_linux_amd64.bz2: OK`. Tout autre résultat :
**ne pas installer**.

```bash
bunzip2 restic_<VERSION>_linux_amd64.bz2
```

```bash
sudo install -o root -g root -m 0755 restic_<VERSION>_linux_amd64 /usr/local/bin/restic
```

**Effet** : installe le binaire dans `/usr/local/bin`, prioritaire sur `/usr/bin`
dans le `PATH` de systemd comme dans celui du shell.
**Vérifier** : `restic version` affiche `<VERSION>`.

---

## Étape 5 — Installation par install.sh [MAC, VPS]

Les scripts s'installent dans `/usr/local/lib/alivaon-backup/`, en root, et
**pas** dans `/opt/alivaon/`. Ce dossier appartient à `alivaondev` : un script
qui s'y trouverait, exécuté chaque nuit en root, serait modifiable sans `sudo`.

`install.sh` copie scripts et unités systemd, pose les droits, crée
`/etc/alivaon-backup/` et `backup.env` s'ils manquent, recharge systemd. Il
**n'active aucun timer** (étape 10) et n'écrase jamais la configuration ni le
mot de passe.

**[MAC]**

```bash
rsync -av --delete backup/ alivaon:alivaon-backup-src/
```

**Effet** : copie le dossier `backup/` du dépôt dans `~/alivaon-backup-src/` sur
le VPS. `--delete` rend la copie exacte : relançable après chaque modification
du dépôt. La copie ne contient aucun secret ; la garder sert à `install.sh
--check`.
**Vérifier** : la liste transférée contient `install.sh`, les scripts et les
cinq unités systemd.

**[VPS]**

```bash
sudo ~/alivaon-backup-src/install.sh
```

**Effet** : installe tout ; à la première exécution, chaque fichier est signalé
`installation : ...`, et `backup.env` `création ..., À RENSEIGNER`.
L'avertissement `restic-password absent` est normal à ce stade (étape 7).
**Vérifier** : dernière ligne `BILAN : N modification(s) appliquée(s)`, aucune
ligne `[ERREUR]`.

```bash
sudo ~/alivaon-backup-src/install.sh
```

**Effet** : seconde exécution, pour constater l'idempotence.
**Vérifier** : `BILAN : 0 modification(s) appliquée(s)`, aucun diff affiché.

```bash
ls -l /usr/local/lib/alivaon-backup/ /etc/systemd/system/alivaon-backup*
```

**Vérifier** : six fichiers dans `/usr/local/lib/alivaon-backup/` appartenant à
`root` (`-rwxr-xr-x`, sauf `lib.sh` en `-rw-r--r--`), cinq unités `-rw-r--r--`
appartenant à `root`.

---

## Étape 6 — Accès SSH du VPS à la Storage Box [VPS]

*Dépôt S3 (option B) : sauter cette étape, voir l'étape 7.*

Le dossier `/etc/alivaon-backup/ssh/` a été créé en `0700` par `install.sh` à
l'étape 5.

```bash
sudo ssh-keygen -t ed25519 -N '' -C 'alivaon-backup@vps' -f /etc/alivaon-backup/ssh/id_ed25519
```

**Effet** : crée la clé dédiée à la sauvegarde. Sans phrase de passe, puisque
le timer s'exécute sans opérateur. Si la clé existe déjà, ssh-keygen demande
s'il faut l'écraser : répondre **n**.
**Vérifier** : `sudo ls /etc/alivaon-backup/ssh/` affiche `id_ed25519` et
`id_ed25519.pub`.

Remplacer `<HOTE_SB>` et `<UTILISATEUR_SB>` **avant** de coller ce bloc :

```bash
sudo tee /etc/ssh/ssh_config.d/alivaon-backup.conf >/dev/null <<'EOF'
# Accès restic à la Storage Box — voir alivaon-infra/backup/RUNBOOK-BACKUP.md
Host alivaon-storagebox
    HostName <HOTE_SB>
    Port 23
    User <UTILISATEUR_SB>
    IdentityFile /etc/alivaon-backup/ssh/id_ed25519
    IdentitiesOnly yes
    UserKnownHostsFile /etc/alivaon-backup/ssh/known_hosts
    StrictHostKeyChecking yes
    HostKeyAlgorithms ssh-ed25519
    ServerAliveInterval 60
    ServerAliveCountMax 240
EOF
```

**Effet** : déclare l'alias `alivaon-storagebox` utilisé par
`RESTIC_REPOSITORY`. Réécrit le fichier en entier : idempotent.
`StrictHostKeyChecking yes` refuse tout hôte dont la clé n'a pas été vérifiée à
la main (bloc suivant).
**Vérifier** : `ssh -G alivaon-storagebox | grep -E '^(hostname|port|user) '`
affiche les bonnes valeurs.

```bash
ssh-keyscan -p 23 -t ed25519 <HOTE_SB> 2>/dev/null | sudo tee /etc/alivaon-backup/ssh/known_hosts
```

**Effet** : récupère la clé d'hôte de la Storage Box.

```bash
sudo ssh-keygen -lf /etc/alivaon-backup/ssh/known_hosts
```

**Vérifier** : l'empreinte `SHA256:...` affichée est **identique** à celle que
Hetzner publie pour les Storage Box (documentation Hetzner, page « Storage Box —
SSH host keys »). En cas de différence : supprimer le fichier et s'arrêter.

```bash
sudo ssh-copy-id -s -i /etc/alivaon-backup/ssh/id_ed25519.pub alivaon-storagebox
```

**Effet** : dépose la clé publique sur le sous-compte. Demande **une fois** le
mot de passe du sous-compte. `-s` : mode SFTP, requis par la Storage Box.
Alternative : coller le contenu de `id_ed25519.pub` dans la console Hetzner.
**Vérifier** : le bloc suivant.

```bash
echo 'ls' | sudo sftp -b - alivaon-storagebox
```

**Effet** : ouvre une session SFTP non interactive. Le mode batch interdit toute
demande de mot de passe.
**Vérifier** : un listing, sans demande de mot de passe. `Permission denied` :
la clé n'est pas acceptée, recommencer le bloc précédent.

---

## Étape 7 — Configuration et mot de passe sur le VPS [VPS]

```bash
sudo sh -c 'umask 077; cat > /etc/alivaon-backup/restic-password'
```

**Effet** : attend une saisie. Coller le mot de passe du dépôt **depuis le
gestionnaire**, appuyer sur Entrée, puis **Ctrl-D**. Rien n'apparaît dans
l'historique du shell ni dans `ps`.

```bash
sudo stat -c '%U:%G %a %s octets' /etc/alivaon-backup/restic-password
```

**Vérifier** : `root:root 600 65 octets` (64 caractères et le saut de ligne,
que restic ignore).

```bash
sudo nano /etc/alivaon-backup/backup.env
```

**Effet** : ouvre la configuration créée par `install.sh`. Renseigner :

- `PRODUCTION_BACKUP_DB_PASSWORD`, `STAGING_BACKUP_DB_PASSWORD` : depuis le
  gestionnaire (étape 3) ;
- `PRODUCTION_DB_PASSWORD` : valeur de `MYSQL_PASSWORD` dans
  `/opt/alivaon/production/.env` ; `STAGING_DB_PASSWORD` : idem pour le
  staging. Utilisés par `restore.sh` seulement ;
- tout nom qui a différé de l'attendu à l'étape 2 ;
- `RESTIC_EXCLUDE_FILE`, seulement si l'étape 2 l'a rendu nécessaire (H4) ;
- laisser `HC_PING_URL` vide pour l'instant (étape 10).

`RESTIC_REPOSITORY` est déjà correct pour la Storage Box
(`sftp:alivaon-storagebox:restic-alivaon`) : même dépôt que celui créé depuis
le Mac, joint par l'alias SSH de l'étape 6.

*Option B, S3* : remplacer `RESTIC_REPOSITORY` par l'URL
`s3:https://<endpoint>/<bucket>/restic-alivaon`, décommenter et renseigner
`AWS_ACCESS_KEY_ID` et `AWS_SECRET_ACCESS_KEY`, les recopier dans le
gestionnaire.

```bash
sudo /usr/local/lib/alivaon-backup/restic.sh cat config
```

**Effet** : charge et valide la configuration (propriétaire, droits, variables
obligatoires, format des volumes), puis lit la configuration du dépôt distant.
**Vérifier** : un bloc JSON dont le champ `"id"` est **celui noté à l'étape 1**.
Toute ligne `[ERREUR]` désigne la variable à corriger. `wrong password` : le
fichier ne contient pas le mot de passe du gestionnaire, recommencer le
premier bloc de cette étape.
**Ne jamais lancer `restic init` depuis le VPS** : le dépôt existe déjà.

```bash
sudo ~/alivaon-backup-src/install.sh --check
```

**Vérifier** : `BILAN : serveur identique au dépôt`, et aucune ligne
`variables absentes de .../backup.env`.

---

## Étape 8 — Première sauvegarde manuelle [VPS]

La première sauvegarde se lance **directement**, hors systemd : le journal
s'affiche dans le terminal, et les unités ne sont contrôlées qu'à l'étape 9.

```bash
sudo /usr/local/lib/alivaon-backup/backup.sh
```

**Effet** : sauvegarde complète : dump de chaque base par l'utilisateur
`backup`, instantané de chaque environnement, rétention, purge. La
première exécution transfère tout ; les suivantes, seulement les différences.
**Vérifier** : pour chaque environnement, `dump valide`, `snapshot ... saved`,
`sauvegarde terminée` ; puis `sauvegarde complète réussie`. Aucune ligne
`[ERREUR]`. Une ligne `[ALERTE] ... mysqldump :` ou `[ALERTE] volume ... VIDE`
mérite examen avant de continuer.

```bash
sudo /usr/local/lib/alivaon-backup/restic.sh snapshots --tag alivaon
```

**Vérifier** : deux instantanés, étiquetés `env:production` et `env:staging`,
chacun avec `kind:scheduled`, et des chemins distincts.

```bash
sudo ls -la /var/lib/alivaon-backup/dumps/
```

**Vérifier** : dossier vide. Les dumps ne restent pas sur le serveur.

```bash
sudo /usr/local/lib/alivaon-backup/backup.sh
```

**Effet** : seconde exécution le même jour, pour constater l'idempotence.
**Vérifier** : toujours **deux** instantanés (commande `snapshots` ci-dessus),
avec de nouveaux identifiants. La rétention quotidienne ne garde que le plus
récent de chaque jour : rien ne s'accumule.

```bash
sudo /usr/local/lib/alivaon-backup/verify.sh
```

**Vérifier** : dernière ligne `BILAN : dépôt sain, sauvegardes à jour`.

**[MAC]** Rejouer le [test 0](RUNBOOK-RESTORE-TEST.md#test-0--ouvrir-le-dépôt-depuis-le-mac) :
il doit maintenant lister les deux instantanés. La sauvegarde écrite par le
VPS est donc lisible sans lui.

---

## Étape 9 — Contrôle des unités systemd [VPS]

```bash
sudo systemd-analyze verify /etc/systemd/system/alivaon-backup.service /etc/systemd/system/alivaon-backup.timer /etc/systemd/system/alivaon-backup-failure.service /etc/systemd/system/alivaon-backup-verify.service /etc/systemd/system/alivaon-backup-verify.timer
```

**Effet** : analyse les cinq unités, sans rien démarrer.
**Vérifier** : aucune sortie. Tout message doit être résolu avant l'étape 10.

---

## Étape 10 — Activation des timers et du dead man's switch [VPS, NAVIGATEUR]

```bash
sudo systemctl enable --now alivaon-backup.timer
```

**Effet** : sauvegarde quotidienne à 03:15, heure de Paris ; persistante au
redémarrage.

```bash
sudo systemctl enable --now alivaon-backup-verify.timer
```

**Effet** : contrôle hebdomadaire, le dimanche à 11:15 : `restic check` avec
relecture de 1/8 des données (fraction tournante, le dépôt entier en huit
semaines), inventaire, fraîcheur < 48 h.

```bash
systemctl list-timers 'alivaon-backup*'
```

**Vérifier** : deux lignes. `NEXT` à 03:15 pour `alivaon-backup.timer`, au
prochain dimanche 11:15 pour `alivaon-backup-verify.timer` (à 10–15 minutes
près, `RandomizedDelaySec`).

```bash
sudo systemctl start alivaon-backup.service
```

**Effet** : une sauvegarde **sous systemd**, avec son durcissement
(`ProtectSystem`, `ProtectHome`...), pour vérifier qu'il n'empêche rien. Rend
la main à la fin.

```bash
sudo journalctl -u alivaon-backup.service -n 60 --no-pager
```

**Vérifier** : `sauvegarde complète réussie`, aucune ligne `[ERREUR]`.

```bash
sudo systemctl start alivaon-backup-verify.service
```

**Effet** : le contrôle hebdomadaire, tout de suite. Télécharge et déchiffre
1/8 du dépôt.

```bash
sudo journalctl -u alivaon-backup-verify.service -n 40 --no-pager
```

**Vérifier** : `relecture tournante : fraction k/8 (semaine ISO ...)`, puis
`BILAN : dépôt sain, sauvegardes à jour`.

**[NAVIGATEUR]** Dead man's switch, sur healthchecks.io → *Add Check* :
- *Schedule* : Cron, `15 3 * * *`, fuseau `Europe/Paris` ;
- *Grace time* : 3 heures ;
- intégration : courriel (et autre canal au choix) ;
- copier l'URL de ping (`https://hc-ping.com/<uuid>`) dans le gestionnaire.

Sans lui, une sauvegarde qui **cesse de s'exécuter** (timer désactivé, serveur
éteint) ne produit aucun échec, donc aucune alerte.

```bash
sudo nano /etc/alivaon-backup/backup.env
```

**Effet** : renseigner `HC_PING_URL` avec l'URL de ping.

```bash
sudo systemctl start alivaon-backup.service
```

**Vérifier** : sur healthchecks.io, le check passe au vert (`start` puis `OK`).

```bash
sudo systemctl start alivaon-backup-failure.service
```

**Effet** : déclenche à blanc la notification d'échec.
**Vérifier** : le check passe au rouge, l'alerte arrive par courriel ;
`sudo journalctl -u alivaon-backup-failure.service -n 20 --no-pager` affiche
`ÉCHEC de alivaon-backup.service — dernières lignes :`.

```bash
sudo systemctl start alivaon-backup.service
```

**Effet** : remet le check au vert.

> **La mise en place n'est PAS terminée ici.** Les timers tournent, mais
> aucune restauration n'a encore été prouvée. Étape 11, sans délai.

---

## Étape 11 — Test de restauration complet sur le staging [VPS, MAC]

Dérouler [RUNBOOK-RESTORE-TEST.md](RUNBOOK-RESTORE-TEST.md) : **test 1**
(restauration complète du staging, critères C1 à C7), **test 2** (dump de
production rejoué dans un conteneur jetable), **test 3** (refus
staging → production). Consigner les résultats dans son journal des tests.

**Fin de la mise en place** : les critères C1 à C7 du test 1 sont tous verts,
et les tests 2 et 3 conformes. À partir de là seulement, le dispositif est en
service.

---

## Annexe — Mettre à jour les scripts plus tard

Après modification de `backup/` dans le dépôt :

**[MAC]**

```bash
rsync -av --delete backup/ alivaon:alivaon-backup-src/
```

**[VPS]**

```bash
sudo ~/alivaon-backup-src/install.sh
```

**Effet** : n'installe que les fichiers modifiés, et affiche pour chacun le diff
entre la version installée et celle du dépôt. Les timers actifs le restent ;
systemd est rechargé.
**Vérifier** : les diffs affichés correspondent à la modification voulue, et
rien d'autre.

## Annexe — Contrôle de fidélité serveur / dépôt

À tout moment, pour vérifier que personne n'a modifié les fichiers installés :

**[MAC]**

```bash
rsync -av --delete backup/ alivaon:alivaon-backup-src/
```

```bash
ssh -t alivaon 'sudo ~/alivaon-backup-src/install.sh --check'
```

**Effet** : compare, sans rien modifier, les fichiers installés à ceux du dépôt
(contenu et droits), et signale les variables de configuration manquantes.
**Vérifier** : `BILAN : serveur identique au dépôt`, code de sortie 0. Tout
écart est affiché avec son diff.
