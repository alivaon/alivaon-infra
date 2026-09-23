# Sauvegarde hors machine — `backup/`

Sauvegarde chiffrée, quotidienne et vérifiable, des **bases MySQL** et des
**fichiers téléversés** d'Alivaon (production et staging), vers un stockage
distinct du VPS. Outil : [restic](https://restic.net), chiffrement côté client.

> ## ⚠️ Le mot de passe du dépôt est le point de défaillance unique
>
> Tout le dépôt est chiffré par un seul mot de passe, que **personne** ne peut
> retrouver : ni Hetzner, ni restic, ni un support quelconque.
>
> Sur le serveur, il vit dans `/etc/alivaon-backup/restic-password`, qui
> disparaît avec le VPS. **La référence est la copie du gestionnaire de mots
> de passe** : le dépôt est créé depuis le Mac avec elle, avant que le VPS n'en
> reçoive un exemplaire. Sans elle, après une perte totale du VPS, les
> sauvegardes existent mais sont illisibles à jamais.
>
> Le test 0 de [RUNBOOK-RESTORE-TEST.md](RUNBOOK-RESTORE-TEST.md) prouve que
> cette copie ouvre le dépôt. Il est obligatoire à l'installation et après
> chaque rotation.

> ## 🛡️ Un VPS compromis peut détruire les sauvegardes : instantanés Storage Box obligatoires
>
> Pour sauvegarder, le VPS détient une clé SSH qui **écrit** sur la Storage
> Box. Un attaquant devenu root sur le VPS dispose donc de cette clé : c'est le
> scénario du rançongiciel, qui chiffre les sites **puis efface le dépôt
> restic** pour empêcher toute reprise.
>
> La mitigation est l'**activation des instantanés automatiques de la Storage
> Box**, dans la console Hetzner. Ils sont pris et supprimés par Hetzner ; le
> sous-compte SFTP du VPS ne peut ni les lister ni les supprimer. Ils restent
> donc hors de portée d'une compromission du VPS, et le dépôt se restaure
> depuis celui de la veille.
>
> Ce n'est pas une option : c'est l'**étape 0** de
> [RUNBOOK-BACKUP.md](RUNBOOK-BACKUP.md), à faire **avant la première
> sauvegarde**. Elle ne tient qu'à deux conditions : les identifiants de la
> console Hetzner et de l'API Robot ne sont **jamais** sur le VPS, et le compte
> Hetzner est protégé par une double authentification.

---

## Fonctionnement

```
  CHAQUE NUIT, 03:15 Europe/Paris ── alivaon-backup.timer
  alivaon-backup.service ─► backup.sh
      pour production, puis staging :
        1. mysqldump --single-transaction, utilisateur MySQL `backup`,
           dans le conteneur, par socket
        2. restic backup : dump + volumes ──────────► dépôt restic chiffré
           étiquettes env:<env>, kind:scheduled        (Storage Box SFTP)
      3. restic forget --prune (7 j / 4 sem / 6 mois)        │ instantanés
      4. healthchecks /0, ou /<code> en cas d'échec          │ Storage Box
                                                             │ quotidiens,
  CHAQUE DIMANCHE, 11:15 ── alivaon-backup-verify.timer      │ pilotés par
  alivaon-backup-verify.service ─► verify.sh                 │ Hetzner, hors
      --read-data-rotation : restic check + relecture de     │ de portée
      1/8 des données (tournante), inventaire, fraîcheur     ▼ du VPS

  ÉCHEC de l'un ou l'autre service ─► alivaon-backup-failure.service
      journal (priorité err, unité fautive) + healthchecks /fail
```

**Un dépôt, deux environnements séparés.** Chaque exécution produit un
instantané par environnement, étiqueté `env:production` ou `env:staging`. Leurs
chemins ne se recouvrent jamais :

| Environnement | Chemins dans l'instantané |
|---|---|
| production | `/var/lib/alivaon-backup/dumps/production/`, points de montage de `production_uploads` et `production_cv_private` |
| staging | `/var/lib/alivaon-backup/dumps/staging/`, points de montage de `staging_uploads_staging` et `staging_cv_private_staging` |

Chaque instantané embarque un **manifeste** (environnement, base, volume de
chaque rôle). `restore.sh` exige que l'étiquette et le manifeste concordent,
et **refuse sans exception** de restaurer un instantané de staging en
production.

**Rétention**, appliquée à chaque environnement séparément
(`--group-by host,tags`) : 7 quotidiennes, 4 hebdomadaires, 6 mensuelles, soit
environ 17 instantanés et six mois d'historique, pour toutes les données, base
et fichiers.

**Contrôle hebdomadaire.** `restic check` seul vérifie la structure du dépôt
(index, arbres) mais ne lit **aucune** donnée : un bloc corrompu sur le
stockage passerait inaperçu jusqu'au jour de la restauration. Chaque dimanche,
`verify.sh --read-data-rotation` relit et déchiffre en plus 1/8 du dépôt, une
fraction différente chaque semaine ISO : l'intégralité est relue en huit
semaines, soit environ deux mois.

### Ce qui est sauvegardé

| Élément | Comment |
|---|---|
| Base `alivaon_db` (production, staging) | `mysqldump` dans le conteneur, par l'utilisateur dédié `backup` (voir ci-dessous). Dump SQL non compressé : restic compresse et déduplique mieux que gzip, qui casserait la déduplication d'un jour à l'autre |
| Uploads VichUploader (`public/uploads`) | Volume Docker, chemin demandé à Docker à chaque exécution |
| CV des candidats (`var/private`) | Idem |

**Le dump MySQL.** Il est exécuté par un utilisateur dédié
`'backup'@'localhost'`, un par environnement, qui ne détient que `SELECT, SHOW
VIEW, TRIGGER` sur `alivaon_db` : aucun privilège global. La sauvegarde ne
dépend donc pas des privilèges de l'application, qui restent minimaux ;
l'utilisateur applicatif ne sert plus qu'à la restauration. `LOCK TABLES` et
`PROCESS` ne sont pas accordés, les options ci-dessous les rendent inutiles ;
`RELOAD` non plus, il ne sert qu'à `--flush-logs` et `--source-data`, non
utilisés. Si un dump d'essai prouvait le contraire, l'étape 3.3 du runbook dit
lequel ajouter, un à la fois.

**Mode de connexion : socket.** mysqldump s'exécute dans le conteneur MySQL
(`docker exec`) et s'y connecte par socket Unix, imposé par `protocol=socket`.
MySQL évalue cette connexion comme venant de `localhost` : d'où le compte
`'backup'@'localhost'`. Une connexion TCP serait évaluée comme
`'backup'@'127.0.0.1'` et refusée. `tests/run.sh` vérifie que le mode du
script et l'hôte du compte documenté dans le runbook s'accordent.

Options :

| Option | Pourquoi |
|---|---|
| `--single-transaction` | Instantané cohérent des tables InnoDB, sans verrou : `LOCK TABLES` inutile |
| `--quick` | Lignes écrites au fil de l'eau, sans tout charger en mémoire |
| `--routines`, `--triggers` | Aucune routine attendue, mais une routine ajoutée plus tard ne serait pas perdue en silence |
| `--no-tablespaces` | N'interroge pas `INFORMATION_SCHEMA.FILES`, qui exige `PROCESS` depuis MySQL 8.0.21 : `PROCESS` inutile |
| `--default-character-set=utf8mb4` | **Pas cosmétique** : un dump dans un autre encodage altère le contenu français accentué, et le défaut ne se voit qu'à la restauration |
| `--hex-blob`, `--set-gtid-purged=OFF`, `--databases --add-drop-database` | Binaires insensibles à l'encodage, dump rejouable sans `SUPER`, base recréée à l'identique |

Tout message de mysqldump sur sa sortie d'erreur est journalisé, horodaté, en
priorité « alerte ».

### Ce qui ne l'est PAS

| Élément | Pourquoi |
|---|---|
| Variantes LiipImagine | Régénérées à la demande depuis les originaux (hypothèse H4 du runbook, à vérifier) |
| `production/.env`, `staging/.env` | Hors périmètre de ce chantier. Candidat naturel pour une extension, le dépôt étant chiffré |
| `traefik/letsencrypt/acme.json` | Régénéré par Traefik. Le restaurer à tort consomme le quota Let's Encrypt (README racine) |
| Dumps `pre-deploy-*.sql.gz` des stacks | Redondants avec les dumps quotidiens |
| Images Docker, configuration | Dans `ghcr.io` et dans ce dépôt Git |

---

## Fichiers

| Fichier du dépôt | Installé sur le VPS | Rôle |
|---|---|---|
| `install.sh` | — (exécuté depuis la copie du dépôt) | Installation et mise à jour idempotentes, `--check` pour comparer serveur et dépôt |
| `backup.sh` | `/usr/local/lib/alivaon-backup/` | Dump, sauvegarde, rétention. Lancé par le timer |
| `restore.sh` | idem | Restauration paramétrée, confirmée, avec garde-fous |
| `verify.sh` | idem | `restic check` (avec relecture tournante), inventaire, fraîcheur < 48 h |
| `restic.sh` | idem | restic avec la configuration chargée, pour les opérations manuelles |
| `notify-failure.sh` | idem | Appelé par le service d'échec, identifie l'unité fautive |
| `lib.sh` | idem | Fonctions communes (sourcé) |
| `alivaon-backup.service` | `/etc/systemd/system/` | Exécution de `backup.sh` |
| `alivaon-backup.timer` | idem | Chaque nuit à 03:15, heure de Paris |
| `alivaon-backup-verify.service` | idem | Exécution de `verify.sh --read-data-rotation` |
| `alivaon-backup-verify.timer` | idem | Chaque dimanche à 11:15, heure de Paris |
| `alivaon-backup-failure.service` | idem | Notification d'échec des deux services (`OnFailure=`) |
| `.env.example` | → `/etc/alivaon-backup/backup.env` | Gabarit documenté de la configuration |
| `tests/` | — | Suite de tests hors serveur : `backup/tests/run.sh` sur le Mac |
| `.shellcheckrc` | — | Règles shellcheck optionnelles écartées, avec leur justification |
| `RUNBOOK-BACKUP.md` | — | Mise en place pas à pas |
| `RUNBOOK-RESTORE-TEST.md` | — | Tests de restauration et critères de réussite |

Sur le VPS, en dehors des scripts :

| Chemin | Contenu | Droits |
|---|---|---|
| `/etc/alivaon-backup/` | Configuration et secrets | `root:root 700` |
| `/etc/alivaon-backup/backup.env` | Configuration, mots de passe MySQL (`backup` et applicatif) | `root:root 600` |
| `/etc/alivaon-backup/restic-password` | Mot de passe du dépôt | `root:root 600` |
| `/etc/alivaon-backup/ssh/` | Clé SSH et `known_hosts` de la Storage Box | `root:root 700` |
| `/etc/ssh/ssh_config.d/alivaon-backup.conf` | Alias `alivaon-storagebox` | `644`, sans secret |
| `/var/lib/alivaon-backup/` | Dumps pendant la sauvegarde, extraction pendant la restauration. **Vide au repos** | `700` |
| `/var/cache/alivaon-backup/` | Cache restic (métadonnées chiffrées) | `700` |

Les scripts refusent de démarrer si la configuration ou le mot de passe sont
lisibles par un autre utilisateur que root. `install.sh` pose ces droits et les
rétablit s'ils ont dérivé.

---

## Installation

Suivre [RUNBOOK-BACKUP.md](RUNBOOK-BACKUP.md) de bout en bout, dans cet ordre :

1. instantanés automatiques de la Storage Box **activés** ;
2. mot de passe restic dans le gestionnaire, dépôt créé depuis le Mac ;
3. **test 0** : le dépôt s'ouvre depuis le Mac avec la seule copie du
   gestionnaire ;
4. étape 2 : vérification des noms (conteneurs, volumes) sur le VPS ;
5. utilisateurs MySQL `backup` créés, dump d'essai ;
6. `install.sh` ;
7. première sauvegarde manuelle ;
8. `systemd-analyze verify` ;
9. activation des timers ;
10. **test de restauration complet sur le staging.**

**La mise en place n'est terminée qu'au point 10**, quand les critères du test
de restauration sont tous verts. Des timers actifs ne prouvent rien.

---

## Exploitation courante

Toutes les commandes se lancent **sur le VPS**.

| Besoin | Commande |
|---|---|
| Prochaines exécutions | `systemctl list-timers 'alivaon-backup*'` |
| Journal de la dernière sauvegarde | `sudo journalctl -u alivaon-backup.service -n 80 --no-pager` |
| Journal du dernier contrôle hebdomadaire | `sudo journalctl -u alivaon-backup-verify.service -n 60 --no-pager` |
| Uniquement les erreurs | `sudo journalctl -u 'alivaon-backup*' -p err --since -7d` |
| Sauvegarder maintenant | `sudo systemctl start alivaon-backup.service` |
| Contrôle rapide (structure, inventaire, fraîcheur) | `sudo /usr/local/lib/alivaon-backup/verify.sh` |
| Contrôle hebdomadaire maintenant (relit 1/8 des données) | `sudo systemctl start alivaon-backup-verify.service` |
| Relecture d'un échantillon aléatoire | `sudo /usr/local/lib/alivaon-backup/verify.sh --read-data-subset 5%` |
| Inventaire | `sudo /usr/local/lib/alivaon-backup/restore.sh --list` |
| Occupation du dépôt | `sudo /usr/local/lib/alivaon-backup/restic.sh stats --mode raw-data` |
| Serveur conforme au dépôt ? | `sudo ~/alivaon-backup-src/install.sh --check` (après `rsync`, voir l'annexe du runbook) |

**Rythme** : la sauvegarde chaque nuit et le contrôle chaque dimanche sont
automatiques. À la main : test 1 du runbook de restauration chaque mois,
test 2 chaque trimestre, `install.sh --check` après toute intervention sur le
serveur.

Le contrôle de fraîcheur de `verify.sh` ne tourne qu'une fois par semaine ;
au jour le jour, c'est healthchecks.io qui détecte une sauvegarde manquante.

### Alertes

- **healthchecks.io** (si `HC_PING_URL` est renseigné) : alerte sur échec
  **et** sur absence d'exécution. Le second cas n'est détectable que par ce
  moyen. Un échec du contrôle hebdomadaire est signalé sur le même check.
- **Journal** : tout échec de la sauvegarde **ou** du contrôle hebdomadaire
  est journalisé en priorité `err` par `alivaon-backup-failure.service`, avec
  le nom de l'unité fautive et les dernières lignes de son exécution.

### Restaurer

```bash
# Inventaire
sudo /usr/local/lib/alivaon-backup/restore.sh --list --target production

# Retour complet (base + fichiers) à un instantané donné
sudo /usr/local/lib/alivaon-backup/restore.sh --target production --snapshot <ID> --stop-app --mirror

# Fichiers abîmés ou effacés, base saine : dernier instantané, récents conservés
sudo /usr/local/lib/alivaon-backup/restore.sh --target production --snapshot latest --only uploads --stop-app --merge
```

Avant d'écraser, `restore.sh` archive l'état courant de la cible
(`kind:pre-restore`) et affiche son identifiant : c'est le retour arrière.

**Conteneur applicatif.** Aucune écriture n'a lieu pendant qu'il tourne :
rsync réécrit les volumes depuis l'hôte, et un téléversement concurrent
pourrait être écrasé ou produire un état mêlant deux moments. S'il tourne,
`restore.sh` refuse et dit quoi arrêter, sauf **`--stop-app`** : il est alors
arrêté juste avant l'écriture et redémarré à la fin, par `docker start`,
jamais `docker compose up`. Arrêté au départ, il reste arrêté dans tous les
cas. Le conteneur MySQL n'est jamais arrêté : la base est restaurée par
import, à travers lui.

**Après un échec**, tout dépend du point de bascule `écriture entamée`, posé
juste avant l'import de la base ou le rsync d'un volume. Échec **avant** : la
cible est intacte, le conteneur applicatif retrouve son état initial (arrêté
par `--stop-app`, il est redémarré). Échec **après** : la cible est dans un
état intermédiaire et le conteneur reste **arrêté**, pour ne pas servir ni
écrire des données incohérentes ; le journal dit comment terminer ou annuler
(RUNBOOK-RESTORE-TEST.md, « Que faire dans le second cas »).

**Propriété et droits.** Les fichiers doivent appartenir à l'UID sous lequel
PHP-FPM écrit (`<ENV>_APP_OWNER`, `82:82`), sans quoi la restauration paraît
réussie et le premier téléversement échoue plus tard. La chaîne conserve les
UID/GID **numériques** de bout en bout : `restic backup` et `restic restore`
en root, puis `rsync -aHAX --numeric-ids` en root, qui restaure aussi ACL
(`-A`) et attributs étendus (`-X`). `restore.sh` le vérifie :

- **avant** l'écriture, la racine de chaque volume doit, dans l'instantané,
  appartenir à `<ENV>_APP_OWNER` ; sinon refus, rien n'est modifié ;
- **après** l'écriture, propriétaire, groupe et droits de **chaque** fichier
  restauré sont comparés à ceux enregistrés dans l'instantané ; au moindre
  écart, échec avec la liste des fichiers en cause.

**ACL et attributs étendus.** Avant d'écrire, `restore.sh` vérifie que le
rsync du serveur prend en charge `-A` et `-X`. Si le système de fichiers
cible refuse une ACL ou un attribut présent dans l'instantané, rsync le
signale et `restore.sh` s'arrête avec un message explicite, plutôt que de les
perdre en silence. L'état de départ des volumes est constaté à l'étape 2 du
runbook (`getfacl`, `getfattr`).

**Espace disque.** `restic restore` extrait d'abord l'instantané dans un
dossier de travail (`/var/lib/alivaon-backup/restore/`), puis rsync copie
vers les volumes : une restauration demande environ **deux fois** la taille
des données si les deux sont sur le même système de fichiers. Avant toute
écriture, `restore.sh` estime cette taille depuis l'instantané (fichiers des
volumes restaurés, et dump SQL), la majore de `RESTORE_SPACE_MARGIN_PERCENT`
(20 % par défaut), et la compare à l'espace libre de chaque système de
fichiers concerné : celui du dossier de travail, et celui des volumes s'il
est distinct ; sur un même système de fichiers, les besoins s'additionnent.
Le contrôle a lieu avant l'extraction, puis de nouveau pour les volumes juste
avant d'écrire, application arrêtée. En cas de manque, refus chiffré :

```
espace disque insuffisant sur / (dossier-de-travail volume:uploads) :
requis 12884901888 octets (12G, dont marge de 20 %), disponible 10737418240
octets (10G), manque 2147483648 octets (2.0G)
```

Ce refus survient avant toute écriture : le conteneur applicatif retrouve son
état initial. La croissance de la base MySQL pendant l'import n'est pas
comptée : elle se fait dans le volume de données MySQL, hors de ce contrôle.

| Règle | Comportement |
|---|---|
| staging → production | **Refus**, code 3, aucune option ne le lève |
| production → staging | Refus, sauf `--allow-production-to-staging` (copie de données personnelles en préprod) |
| Étiquette et manifeste discordants | Refus, code 3 |
| Pas de terminal | Refus : la confirmation est toujours interactive |
| Volume absent, ou pilote autre que `local` (H9) | Refus, avant toute écriture |
| Conteneur applicatif en marche, sans `--stop-app` | Refus, avant toute écriture, avec la commande d'arrêt à lancer |
| Volume à restaurer sans `--merge` ni `--mirror` | Refus : aucun mode par défaut |
| `--mirror` | Nombre de fichiers à supprimer annoncé, seconde phrase à taper (`SUPPRIMER <n>`) ; refus si ce nombre change avant l'écriture |
| Volumes de l'instantané à un autre UID que `<ENV>_APP_OWNER` | Refus, avant toute écriture |
| Propriétaire ou droits restaurés différents de l'instantané | Échec en fin de restauration, fichiers en cause listés |
| Espace libre inférieur au besoin estimé, marge comprise | Refus avant toute écriture, avec requis, disponible et manque |
| rsync sans prise en charge de `-A`/`-X` | Refus avant toute écriture |
| Système de fichiers cible refusant une ACL ou un attribut étendu | Échec explicite pendant le rsync, conteneur laissé arrêté |
| Échec après `écriture entamée` | Conteneur applicatif laissé **arrêté**, commandes pour terminer ou annuler |

### Choisir le mode de restauration des fichiers

Sans `--delete`, les fichiers créés après l'instantané survivent, et l'état
obtenu mêle deux moments. Avec `--delete`, les téléversements récents sont
perdus. Les deux se défendent selon le scénario : le choix est donc
**obligatoire** dès qu'un volume est restauré.

| Scénario | Mode | Commande | Pourquoi |
|---|---|---|---|
| **Perte totale du serveur** | `--mirror` | `--target production --snapshot latest --stop-app --mirror --no-safety-snapshot` | Les volumes sont neufs, il n'y a rien à conserver : l'objectif est l'état exact de l'instantané. Décompte attendu : 0, ou les quelques fichiers déposés par l'image au premier démarrage |
| **Corruption partielle** des fichiers, base saine | `--merge` | `--target production --snapshot <ID> --only uploads --stop-app --merge` | Remet ce qui manque ou a été abîmé, sans supprimer les téléversements récents, que la base actuelle référence. Un fichier présent des deux côtés reprend la version archivée : choisir un instantané antérieur à la corruption |
| Corruption de la base, retour complet à un instant donné | `--mirror` | `--target production --snapshot <ID> --stop-app --mirror` | La base revient à l'instant de l'instantané ; les fichiers postérieurs n'y seraient plus référencés. Le décompte annoncé dit combien de téléversements seront perdus |
| **Test de restauration sur le staging** | `--mirror` | voir RUNBOOK-RESTORE-TEST.md, test 1 | Un test doit être déterministe : rien d'hérité de la cible |

### Perte totale du VPS

1. Reconstruire le serveur selon le README racine (« Reconstruire le VPS depuis
   zéro »), jusqu'au `docker compose up -d` des deux stacks. Les volumes et les
   bases vides sont alors créés.
2. [RUNBOOK-BACKUP.md](RUNBOOK-BACKUP.md), étapes 3 à 7 : utilisateurs MySQL
   `backup` recréés avec les mots de passe **du gestionnaire** (les comptes
   MySQL ne sont pas dans le dump), outils, `install.sh`, accès SSH,
   configuration avec le mot de passe restic **du gestionnaire** et le
   **même** `RESTIC_HOST`. `cat config` doit afficher le dépôt existant :
   **ne jamais lancer `init`**.
3. **Ne pas activer les timers** (étape 10) avant la restauration. Une
   sauvegarde d'un serveur vide prendrait place dans la rétention.
4. `sudo /usr/local/lib/alivaon-backup/restore.sh --target production --snapshot latest --no-safety-snapshot --stop-app --mirror`
5. Vérifier le site, puis faire de même avec `--target staging`.
6. Étapes 8 à 10 du runbook : sauvegarde manuelle, contrôle des unités,
   timers.

Si le dépôt lui-même a été effacé (compromission du VPS), le restaurer d'abord
depuis un instantané de la Storage Box, dans la console Hetzner.

---

## Rotation du mot de passe du dépôt

restic chiffre les données avec une **clé maîtresse**, elle-même chiffrée par
un ou plusieurs mots de passe (les « clés » du dépôt). La rotation ajoute une
clé avec le nouveau mot de passe, puis retire l'ancienne. Rien n'est rechiffré,
l'opération est instantanée.

Ordre impératif : le nouveau mot de passe est dans le gestionnaire **avant**
d'exister sur le serveur, et l'ancienne clé n'est retirée **qu'après** la preuve
que la nouvelle ouvre le dépôt depuis le Mac.

1. **[MAC]** Générer le nouveau mot de passe et l'enregistrer dans le
   gestionnaire, **à côté** de l'ancien :
   `openssl rand -base64 48 | tr -d '\n' | pbcopy`
2. **[VPS]** Suspendre la planification :
   `sudo systemctl stop alivaon-backup.timer alivaon-backup-verify.timer`
3. **[VPS]** Déposer le nouveau mot de passe (coller, Entrée, Ctrl-D) :
   `sudo sh -c 'umask 077; cat > /etc/alivaon-backup/restic-password.new'`
4. **[VPS]** Ajouter la clé :
   `sudo /usr/local/lib/alivaon-backup/restic.sh key add --new-password-file /etc/alivaon-backup/restic-password.new`
5. **[VPS]** Noter l'ID de l'**ancienne** clé, marquée `*` (celle qui a ouvert
   le dépôt) : `sudo /usr/local/lib/alivaon-backup/restic.sh key list`
6. **[VPS]** Basculer :
   `sudo install -o root -g root -m 0600 /etc/alivaon-backup/restic-password.new /etc/alivaon-backup/restic-password`
   puis `sudo rm /etc/alivaon-backup/restic-password.new`
7. **[VPS]** Contrôler : `sudo /usr/local/lib/alivaon-backup/restic.sh key list`
   (la clé `*` est maintenant la nouvelle), puis `verify.sh`.
8. **[MAC]** Test 0 de [RUNBOOK-RESTORE-TEST.md](RUNBOOK-RESTORE-TEST.md) avec
   le **nouveau** mot de passe. S'arrêter en cas d'échec : l'ancienne clé est
   toujours valide.
9. **[VPS]** Retirer l'ancienne clé :
   `sudo /usr/local/lib/alivaon-backup/restic.sh key remove <ID_ANCIENNE_CLÉ>`
10. **[VPS]** Reprendre :
    `sudo systemctl start alivaon-backup.timer alivaon-backup-verify.timer`
11. **[MAC]** Supprimer l'ancien mot de passe du gestionnaire.

**Limite.** La clé maîtresse ne change pas. Si l'ancien mot de passe **et** une
copie du dépôt ont fuité ensemble, la rotation ne protège pas cette copie. Une
rotation qui rechiffre réellement impose un nouveau dépôt (`restic init`) et
la recopie des instantanés (`restic copy`).

### Autres secrets

| Secret | Rotation |
|---|---|
| Mot de passe MySQL `backup` | Nouveau mot de passe dans le gestionnaire, `ALTER USER 'backup'@'localhost' IDENTIFIED BY ...` (étape 3 du runbook), puis `*_BACKUP_DB_PASSWORD` dans `backup.env`. Sinon, la sauvegarde échoue dès la nuit suivante, bruyamment |
| Mot de passe MySQL applicatif | Le changer dans MySQL, dans le `.env` de la stack **et** dans `*_DB_PASSWORD` de `backup.env`. Sinon, c'est la **restauration** qui échouera, le jour où elle sera nécessaire : le test 1 mensuel le détecte |
| Clé SSH de la Storage Box | Nouvelle clé (étape 6 du runbook), dépôt, test `sftp -b -`, retrait de l'ancienne dans `.ssh/authorized_keys` du sous-compte |
| Clés S3 | Créer, remplacer dans `backup.env`, `verify.sh`, révoquer l'ancienne |

---

## Coût

Tarifs Hetzner indicatifs (HT), **à revérifier** à la commande :

| Stockage | Prix mensuel | Inclus |
|---|---|---|
| Storage Box BX11 (option A) | ≈ 3,20 € | 1 To, trafic inclus, instantanés côté Hetzner |
| Object Storage (option B) | ≈ 5 € | 1 To stocké et 1 To de trafic sortant, facturation au-delà |

Taille du dépôt, ordre de grandeur :

```
dépôt ≈ 1,2 × (uploads production + uploads staging)   ← images déjà compressées,
                                                          stockées une fois (déduplication)
      + 17 × (taille du dump ÷ 5) par environnement     ← majorant : restic compresse le SQL
                                                          (zstd) et ne stocke que les blocs modifiés
```

Exemple : 5 Go d'uploads en production, 1 Go en staging, dumps de 200 Mo →
environ 7 Go d'uploads + 1,4 Go de dumps ≈ **9 Go**, moins de 1 % d'une BX11. À
ce volume, **le coût est le forfait fixe**, soit environ 40 € HT par an. Les
tailles réelles se mesurent à l'étape 2 du runbook ; l'occupation effective
avec `restic.sh stats --mode raw-data`. Les instantanés de la Storage Box
consomment aussi de l'espace sur le quota : les données purgées par restic y
subsistent jusqu'à l'expiration de l'instantané qui les contient.

La relecture hebdomadaire télécharge 1/8 du dépôt, soit environ 1,1 Go dans
l'exemple ci-dessus : sans coût sur une Storage Box, et dans le trafic inclus
d'Object Storage.

---

## Données des candidats

Les données des candidats, base comme fichiers (`cv_private`), suivent la
**rétention générale** (7 quotidiennes, 4 hebdomadaires, 6 mensuelles), comme
le reste. C'est un choix d'exploitation lié à la reprise d'activité : une
sauvegarde sert à reprendre après un incident, pas à archiver. Aucune purge
sélective n'est en place. Une éventuelle anonymisation relèvera de
l'application, dans un chantier distinct.

Si la décision changeait et qu'il fallait conserver certains fichiers moins
longtemps que le reste, le moyen serait `restic rewrite --exclude <chemin du
volume> --forget`, appliqué chaque nuit aux instantanés plus anciens que la
durée voulue, avant la purge. restic applique sa rétention à des instantanés
entiers : c'est la seule manière de retirer un chemin d'un instantané existant.
`restore.sh` devrait alors savoir qu'un volume cité par le manifeste peut être
absent de l'instantané, et laisser intact le volume cible plutôt que de le
vider par `rsync --delete`. Rien de cela n'est codé.

---

## Limites connues

- **ACL et attributs étendus restaurés, non comparés.** rsync les restaure
  (`-A -X`) et s'arrête si le système de fichiers les refuse, mais la
  vérification de fin de restauration ne compare que propriétaire, groupe et
  droits Unix.
- **Vérification de propriété limitée à ce que l'instantané enregistre.** Si
  les fichiers archivés appartenaient déjà au mauvais UID, `restore.sh` le
  reproduit fidèlement ; seul le contrôle de la racine contre
  `<ENV>_APP_OWNER`, et le téléversement réel du test 1 (critère C8), le
  détectent.

- **Un VPS compromis détient la clé d'écriture sur le dépôt.** Mitigation :
  instantanés de la Storage Box, obligatoires (voir en tête). Sur S3, activer
  le versioning ou l'Object Lock du bucket.
- **Cohérence base / fichiers.** Le dump précède les fichiers de quelques
  secondes à quelques minutes. Un fichier téléversé entre les deux figure dans
  la sauvegarde sans ligne en base : orphelin inoffensif. L'ordre inverse
  aurait produit des lignes pointant vers des fichiers absents.
- **Mot de passe MySQL applicatif en double.** `backup.env` recopie
  `MYSQL_PASSWORD` des stacks pour `restore.sh`. Une divergence ne gêne pas
  la sauvegarde, mais fait échouer la restauration : le test 1 mensuel la
  détecte.
- **Pilote `local` requis** pour chaque volume sauvegardé (hypothèse H9),
  vérifié à chaque exécution : un volume d'un autre pilote est refusé, la
  sauvegarde échoue plutôt que d'archiver un dossier vide.
- **restic ≥ 0.16 requis** (`--retry-lock`, dépôt compressé). Vérifié au
  démarrage de chaque script.
- **Comparaison avec le dépôt Git à la demande** : `scripts/diff-vps.sh` ne
  couvre que `/opt/alivaon` ; pour le dispositif de sauvegarde, c'est
  `install.sh --check` (annexe du runbook), non planifié.

---

## Codes de sortie

| Script | 0 | 1 | 2 | 3 |
|---|---|---|---|---|
| `backup.sh` | succès complet | une étape a échoué | — | — |
| `restore.sh` | restauration terminée | échec (le journal dit si la cible a été modifiée) | — | refus de sécurité |
| `verify.sh` | dépôt sain et à jour | `restic check` en échec | sauvegarde trop ancienne ou absente | — |
| `install.sh` | installation conforme ; en `--check`, identique au dépôt | erreur ; en `--check`, au moins un écart | — | — |
| `tests/run.sh` | tous les cas réussis | au moins un échec | — | — |
