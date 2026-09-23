# Runbook — mise en place de la sauvegarde sur le VPS

Procédure pas à pas, à suivre dans l'ordre. Compter une heure, première
sauvegarde comprise.

Chaque commande est dans son propre bloc, précédée de l'endroit où elle
s'exécute :

| Marque | Où | Comment |
|---|---|---|
| **[MAC]** | Terminal du Mac, **à la racine du dépôt `alivaon-infra`** | tel quel |
| **[VPS]** | Session SSH sur le serveur : `ssh alivaon` | utilisateur `alivaondev`, `sudo` quand indiqué |
| **[NAVIGATEUR]** | Console Hetzner, healthchecks.io, gestionnaire de mots de passe | à la main |

Sous chaque commande : **Effet** (ce qu'elle fait) et **Vérifier** (ce qu'il faut
constater avant de passer à la suivante). Si la vérification échoue, s'arrêter.

Valeurs à substituer, notées entre chevrons :

| Placeholder | Exemple | Source |
|---|---|---|
| `<HOTE_SB>` | `u123456.your-storagebox.de` | Console Hetzner, Storage Box |
| `<UTILISATEUR_SB>` | `u123456-sub1` | Sous-compte créé à l'étape 0 |

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

**Choix à valider — les CV sont sauvegardés.** Le volume `cv_private` contient
des fichiers téléversés par les candidats, absents de la base : sans sauvegarde,
une perte du serveur les efface définitivement. Ils sont donc inclus. Deux
conséquences :

- la rétention garde un CV supprimé de l'application jusqu'à **six mois** dans
  les sauvegardes. À refléter dans le registre RGPD et la politique de
  confidentialité ;
- pour l'exclure : retirer `cv_private=...` des variables `*_VOLUMES` de la
  configuration (étape 8).

**Chemins sur disque : aucun n'est supposé.** Les scripts demandent à Docker le
point de montage de chaque volume à chaque exécution (`docker volume inspect`).
Un `data-root` Docker non standard est donc pris en charge sans modification.

---

## Étape 0 — Préparatifs hors terminal [NAVIGATEUR]

1. **Storage Box.** Console Hetzner → Storage Box → commander une BX11 (1 To),
   même région que le VPS de préférence mais **pas une obligation** : c'est
   justement une copie hors machine.
2. **Accès SSH.** Dans les réglages de la Storage Box : activer *SSH support*.
3. **Sous-compte dédié.** Créer un sous-compte (par exemple de répertoire de
   base `alivaon`) avec accès SSH, sans Samba ni WebDAV. Le VPS n'aura accès
   qu'à ce répertoire, jamais au reste de la boîte. Noter l'identifiant
   (`<UTILISATEUR_SB>`) et le mot de passe.
4. **Instantanés automatiques de la Storage Box.** Activer une planification
   quotidienne. Ces instantanés sont gérés depuis la console Hetzner et
   **inaccessibles au sous-compte** : un attaquant maître du VPS pourrait
   effacer le dépôt restic par SFTP, mais pas eux. C'est la seule protection
   contre ce scénario.
5. **Gestionnaire de mots de passe.** Créer une entrée « Alivaon — sauvegarde
   restic » avec les champs suivants, remplis au fil de la procédure :
   - mot de passe du dépôt restic (étape 1) ;
   - `RESTIC_REPOSITORY` (étape 8) et identifiant du dépôt (étape 9) ;
   - hôte de la Storage Box, identifiant et mot de passe du sous-compte ;
   - URL de ping healthchecks (étape 14).

> ### ⚠️ Point de défaillance unique
>
> Le mot de passe du dépôt restic chiffre **toutes** les sauvegardes. Personne,
> ni Hetzner ni restic, ne peut le retrouver ni le contourner. Sur le serveur, il
> vit dans `/etc/alivaon-backup/restic-password`, et ce fichier **disparaît avec
> le VPS**. Si la seule copie est sur le serveur, une perte totale du VPS rend
> toutes les sauvegardes illisibles, alors même qu'elles existent.
>
> Il est donc créé **d'abord** dans le gestionnaire de mots de passe (étape 1),
> et sa lisibilité depuis un autre poste que le VPS est prouvée à la fin (étape
> 17). Tant que cette preuve n'est pas faite, le dispositif n'est pas en service.

---

## Étape 1 — Générer le mot de passe du dépôt [MAC]

```bash
openssl rand -base64 48 | tr -d '\n' | pbcopy
```

**Effet** : génère 48 octets aléatoires (64 caractères base64) et les place
dans le presse-papiers, sans les afficher ni les écrire sur disque.
**Vérifier** : coller dans le champ « mot de passe du dépôt » de l'entrée du
gestionnaire, enregistrer. L'entrée doit être synchronisée (coffre partagé ou
sauvegardé) : un gestionnaire local au Mac déplacerait le point de défaillance
sans le supprimer.

---

## Étape 2 — Contrôler les hypothèses [VPS]

Rien n'est modifié à cette étape. Si un résultat diffère de l'attendu, corriger
la valeur correspondante à l'étape 8, pas le code.

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
docker volume inspect -f '{{.Name}} {{.Mountpoint}}' production_uploads production_cv_private staging_uploads_staging staging_cv_private_staging
```

**Effet** : affiche le point de montage de chaque volume.
**Vérifier** : quatre lignes, sans erreur `no such volume`.

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
`*/media/cache`) et le déclarer dans `RESTIC_EXCLUDE_FILE` à l'étape 8. Sinon,
rien à faire.

```bash
docker exec -it production-db-1 mysql -u alivaon_app -p -e 'SHOW GRANTS'
```

**Effet** : demande le mot de passe (celui de `MYSQL_PASSWORD` dans
`/opt/alivaon/production/.env`), puis affiche les privilèges. Le `-p` sans
valeur fait saisir le mot de passe de façon interactive : il n'apparaît pas
dans `ps`.
**Vérifier (H7)** : une ligne `GRANT ALL PRIVILEGES ON `alivaon_db`.* TO
`alivaon_app`@`%``. Sans `ALL`, il faut au minimum `SELECT, SHOW VIEW, TRIGGER,
LOCK TABLES` pour sauvegarder, et `CREATE, DROP, INSERT, ALTER, INDEX, REFERENCES`
en plus pour restaurer.

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

---

## Étape 3 — Installer restic et les outils [VPS]

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

## Étape 4 — Dossier de configuration et mot de passe [VPS]

```bash
sudo install -d -o root -g root -m 0700 /etc/alivaon-backup /etc/alivaon-backup/ssh
```

**Effet** : crée les dossiers réservés à root. Idempotent.
**Vérifier** : `sudo ls -ld /etc/alivaon-backup` affiche `drwx------ root root`.

```bash
sudo sh -c 'umask 077; cat > /etc/alivaon-backup/restic-password'
```

**Effet** : attend une saisie. Coller le mot de passe depuis le gestionnaire,
appuyer sur Entrée, puis **Ctrl-D**. Rien n'apparaît dans l'historique du shell
ni dans `ps`.
**Vérifier** : le bloc suivant.

```bash
sudo chmod 0400 /etc/alivaon-backup/restic-password
```

```bash
sudo stat -c '%U:%G %a %s octets' /etc/alivaon-backup/restic-password
```

**Vérifier** : `root:root 400 65 octets` (64 caractères et le saut de ligne,
que restic ignore).

---

## Étape 5 — Accès SSH à la Storage Box [VPS]

*Dépôt S3 (option B) : sauter cette étape, voir la fin de l'étape 8.*

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

## Étape 6 — Copier les fichiers sur le VPS [MAC]

```bash
rsync -av --delete backup/ alivaon:alivaon-backup-src/
```

**Effet** : copie le dossier `backup/` du dépôt dans `~/alivaon-backup-src/` sur
le VPS. `--delete` rend la copie exacte : relançable après chaque modification
du dépôt.
**Vérifier** : le bloc suivant.

```bash
ssh alivaon 'ls -la ~/alivaon-backup-src/'
```

**Vérifier** : `backup.sh`, `restore.sh`, `verify.sh`, `restic.sh`,
`notify-failure.sh`, `lib.sh`, les trois unités systemd, `.env.example`.

---

## Étape 7 — Installer scripts et unités systemd [VPS]

Les scripts sont installés dans `/usr/local/lib/alivaon-backup/`, en root, et
**pas** dans `/opt/alivaon/`. Ce dossier appartient à `alivaondev` : un script
qui s'y trouverait, exécuté chaque nuit en root, serait modifiable sans `sudo`.

```bash
sudo install -d -o root -g root -m 0755 /usr/local/lib/alivaon-backup
```

```bash
sudo install -o root -g root -m 0755 -t /usr/local/lib/alivaon-backup ~/alivaon-backup-src/backup.sh ~/alivaon-backup-src/restore.sh ~/alivaon-backup-src/verify.sh ~/alivaon-backup-src/restic.sh ~/alivaon-backup-src/notify-failure.sh
```

```bash
sudo install -o root -g root -m 0644 -t /usr/local/lib/alivaon-backup ~/alivaon-backup-src/lib.sh
```

**Effet** : installe les scripts (exécutables) et la bibliothèque (sourcée, non
exécutable). Écrase une version antérieure : idempotent.
**Vérifier** : `ls -l /usr/local/lib/alivaon-backup/` : six fichiers
appartenant à `root`.

```bash
sudo install -o root -g root -m 0644 -t /etc/systemd/system ~/alivaon-backup-src/alivaon-backup.service ~/alivaon-backup-src/alivaon-backup.timer ~/alivaon-backup-src/alivaon-backup-failure.service
```

```bash
sudo systemctl daemon-reload
```

```bash
sudo systemd-analyze verify /etc/systemd/system/alivaon-backup.service /etc/systemd/system/alivaon-backup.timer /etc/systemd/system/alivaon-backup-failure.service
```

**Effet** : charge et contrôle les trois unités.
**Vérifier** : aucune sortie. Un message d'erreur doit être résolu avant de
continuer.

---

## Étape 8 — Configuration [VPS]

```bash
sudo test -e /etc/alivaon-backup/backup.env || sudo install -o root -g root -m 0600 ~/alivaon-backup-src/.env.example /etc/alivaon-backup/backup.env
```

**Effet** : crée la configuration depuis le gabarit, **seulement si elle
n'existe pas**. Une configuration déjà renseignée n'est jamais écrasée.
**Vérifier** : `sudo stat -c '%U:%G %a' /etc/alivaon-backup/backup.env` affiche
`root:root 600`.

```bash
sudo nano /etc/alivaon-backup/backup.env
```

**Effet** : ouvre la configuration. Renseigner :

- `PRODUCTION_DB_PASSWORD` : valeur de `MYSQL_PASSWORD` dans
  `/opt/alivaon/production/.env` ;
- `STAGING_DB_PASSWORD` : valeur de `MYSQL_PASSWORD` dans
  `/opt/alivaon/staging/.env` ;
- tout nom qui a différé de l'attendu à l'étape 2 ;
- `RESTIC_EXCLUDE_FILE`, seulement si l'étape 2 l'a rendu nécessaire (H4) ;
- laisser `HC_PING_URL` vide pour l'instant (étape 14).

`RESTIC_REPOSITORY` est déjà correct pour la Storage Box
(`sftp:alivaon-storagebox:restic-alivaon`). Le recopier dans le gestionnaire de
mots de passe.

*Option B, S3* : remplacer `RESTIC_REPOSITORY` par l'URL
`s3:https://<endpoint>/<bucket>/restic-alivaon`, décommenter et renseigner
`AWS_ACCESS_KEY_ID` et `AWS_SECRET_ACCESS_KEY`, les recopier dans le
gestionnaire.

```bash
sudo /usr/local/lib/alivaon-backup/restic.sh version
```

**Effet** : charge et valide la configuration (propriétaire, droits, variables
obligatoires, format des volumes), puis affiche la version de restic.
**Vérifier** : une ligne `restic 0.x.y ...`. Toute ligne `[ERREUR]` désigne la
variable à corriger.

---

## Étape 9 — Initialiser le dépôt, une seule fois [VPS]

```bash
sudo /usr/local/lib/alivaon-backup/restic.sh cat config
```

**Effet** : tente de lire la configuration du dépôt distant.
**Vérifier** :
- un bloc JSON s'affiche : le dépôt **existe déjà**. **Ne pas** lancer le bloc
  suivant, passer à l'étape 10 ;
- `Is there a repository at the following location?` : le dépôt n'existe pas,
  continuer ;
- `wrong password` : le dépôt existe et le mot de passe diffère. Ne rien
  initialiser, retrouver le bon mot de passe.

```bash
sudo /usr/local/lib/alivaon-backup/restic.sh init
```

**Effet** : crée le dépôt chiffré sur la Storage Box. Sur un dépôt existant,
restic refuse (`config file already exists`) sans rien modifier.
**Vérifier** : `created restic repository <id> at ...`. Recopier `<id>` dans le
gestionnaire de mots de passe : il identifie ce dépôt sans ambiguïté.

---

## Étape 10 — Première sauvegarde [VPS]

```bash
sudo systemctl start alivaon-backup.service
```

**Effet** : lance une sauvegarde complète, exactement comme le fera le timer.
La commande rend la main à la fin (service `oneshot`). La première exécution
transfère tout ; les suivantes, seulement les différences.
**Vérifier** : la commande se termine sans message.

```bash
sudo journalctl -u alivaon-backup.service -n 60 --no-pager
```

**Vérifier** : pour chaque environnement, `dump valide`, `snapshot ... saved`,
`sauvegarde terminée` ; puis `sauvegarde complète réussie`. Aucune ligne
`[ERREUR]` ; une ligne `[ALERTE] volume ... VIDE` mérite examen.

```bash
sudo /usr/local/lib/alivaon-backup/restic.sh snapshots --tag alivaon
```

**Vérifier** : deux instantanés, étiquetés `env:production` et `env:staging`,
chacun avec `kind:scheduled`, et des chemins distincts.

```bash
sudo ls -la /var/lib/alivaon-backup/dumps/
```

**Vérifier** : dossier vide. Les dumps ne restent pas sur le serveur.

---

## Étape 11 — Contrôle de santé [VPS]

```bash
sudo /usr/local/lib/alivaon-backup/verify.sh
```

**Effet** : `restic check`, inventaire, fraîcheur de chaque environnement.
**Vérifier** : dernière ligne `BILAN : dépôt sain, sauvegardes à jour`.

```bash
echo $?
```

**Vérifier** : `0`.

---

## Étape 12 — Idempotence [VPS]

```bash
sudo systemctl start alivaon-backup.service
```

```bash
sudo /usr/local/lib/alivaon-backup/restic.sh snapshots --tag alivaon
```

**Effet** : seconde exécution le même jour.
**Vérifier** : toujours **deux** instantanés, avec de nouveaux identifiants. La
rétention quotidienne ne garde que le plus récent de chaque jour : la purge a
fonctionné et rien ne s'accumule.

---

## Étape 13 — Activer la planification [VPS]

```bash
sudo systemctl enable --now alivaon-backup.timer
```

**Effet** : active le timer et le rend persistant au redémarrage.

```bash
systemctl list-timers alivaon-backup.timer
```

**Vérifier** : colonne `NEXT` à 03:15 heure de Paris (à 10 minutes près,
`RandomizedDelaySec`), unité `alivaon-backup.service`.

---

## Étape 14 — Dead man's switch (facultatif, recommandé)

Sans lui, une sauvegarde qui **cesse de s'exécuter** (timer désactivé,
serveur éteint, systemd en panne) ne produit aucun échec, donc aucune alerte.

**[NAVIGATEUR]** healthchecks.io → *Add Check* :
- *Schedule* : Cron, `15 3 * * *`, fuseau `Europe/Paris` ;
- *Grace time* : 3 heures ;
- intégration : courriel (et autre canal au choix) ;
- copier l'URL de ping (`https://hc-ping.com/<uuid>`) dans le gestionnaire.

```bash
sudo nano /etc/alivaon-backup/backup.env
```

**Effet** : renseigner `HC_PING_URL` avec l'URL de ping.

```bash
sudo systemctl start alivaon-backup.service
```

**Vérifier** : sur healthchecks.io, le check passe au vert, avec un événement
`start` puis `OK`.

```bash
sudo systemctl start alivaon-backup-failure.service
```

**Effet** : déclenche à blanc la notification d'échec, sans échec réel.
**Vérifier** : le check passe au rouge sur healthchecks.io, et l'alerte arrive
par courriel.

```bash
sudo journalctl -u alivaon-backup-failure.service -n 20 --no-pager
```

**Vérifier** : `ÉCHEC de alivaon-backup.service — dernières lignes :` suivi
d'un extrait du journal.

```bash
sudo systemctl start alivaon-backup.service
```

**Effet** : remet le check au vert.

Désactiver plus tard : vider `HC_PING_URL`. Le journal systemd reste alimenté.

---

## Étape 15 — Nettoyage [VPS]

```bash
rm -rf ~/alivaon-backup-src
```

**Effet** : supprime la copie de travail. Les fichiers installés vivent dans
`/usr/local/lib/alivaon-backup` et `/etc/systemd/system`.

---

## Étape 16 — Contrôle de fidélité [MAC]

```bash
ssh alivaon 'sha256sum /usr/local/lib/alivaon-backup/* /etc/systemd/system/alivaon-backup*' | awk '{print $1}' | sort
```

```bash
shasum -a 256 backup/*.sh backup/*.service backup/*.timer | awk '{print $1}' | sort
```

**Vérifier** : les deux listes sont identiques. Toute différence signale une
installation qui ne correspond pas au dépôt.

---

## Étape 17 — Preuve que le mot de passe hors serveur fonctionne

**Obligatoire.** Suivre le **Test 0** de
[RUNBOOK-RESTORE-TEST.md](RUNBOOK-RESTORE-TEST.md) : ouvrir le dépôt depuis le
Mac avec le seul mot de passe du gestionnaire. Tant que ce test n'a pas réussi,
la sauvegarde n'est pas réputée en service.

Puis, dans la semaine : **Test 1** du même runbook (restauration complète du
staging).

---

## Mettre à jour les scripts plus tard

Après modification de `backup/` dans le dépôt : étape 6, puis étape 7 en
entier (dont `daemon-reload`), puis étape 16. La configuration
(`/etc/alivaon-backup/backup.env`) n'est pas touchée.
