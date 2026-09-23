# Journal — installation du dispositif de sauvegarde

Mise en service de `backup/` sur le VPS, en suivant dans l'ordre
[RUNBOOK-BACKUP.md](../backup/RUNBOOK-BACKUP.md), le correctif du healthcheck
([runbook-healthcheck-mysql.md](runbook-healthcheck-mysql.md)) placé entre
les étapes 2 et 3, puis [RUNBOOK-RESTORE-TEST.md](../backup/RUNBOOK-RESTORE-TEST.md).

Tenu au fil de l'eau. Horodatage : heure de Paris. Aucun secret n'y figure :
les commandes qui en manipulent sont exécutées par l'opérateur, et seule leur
issue est consignée.

Règles de conduite de la session : une commande à la fois ; aucune écriture
sans GO ; staging avant production ; tout écart observé = arrêt.

## Décisions de départ

| Sujet | Décision | Horodatage |
|---|---|---|
| Plan de mise en service | Validé (« vas y ») | 2026-09-23 13:55 |
| Ordre staging → production pour chaque paire de commandes | Validé | 2026-09-23 13:55 |
| Correctif du healthcheck entre les étapes 2 et 3 | Validé | 2026-09-23 13:55 |
| Accès : alias `ssh alivaon` (alivaondev@178.104.185.156, clé ed25519) | Constaté localement (`ssh -G`) | 2026-09-23 13:55 |
| `restic forget --prune` lancé par `backup.sh` dès la première sauvegarde | **En suspens**, à trancher au jalon P3 | — |
| `DROP DATABASE` sur le staging (test 1, étape 1.5, et dump restauré) | **En suspens**, à trancher au jalon P5 | — |
| `sudo` sans mot de passe pour `alivaondev` | **Non** : `sudo` exige un mot de passe. Toute commande `sudo` est lancée par l'opérateur, qui transmet la sortie | 2026-09-23 13:58 |
| Hôte et identifiant de la Storage Box traités comme secrets (étape 6) | **À confirmer** avant l'étape 6 | — |

## Déroulé

| Horodatage | Étape | Commande | Sortie significative | Verdict / écart |
|---|---|---|---|---|
| 2026-09-23 13:55 | Préparation (Mac) | `git status --short` ; `git log --oneline -1` | Arbre propre ; `3f820c0 infra ok` | Conforme |
| 2026-09-23 13:55 | Préparation (Mac) | `ssh -G alivaon` | `user alivaondev`, `hostname 178.104.185.156`, `port 22`, clé `~/.ssh/id_ed25519` | Conforme |
| 2026-09-23 13:58 | Préalable (VPS, lecture) | `ssh alivaon 'sudo -n true; echo "sudo=$?"'` | `sudo=1` ; `sudo: interactive authentication is required` | Constat : commandes `sudo` à la charge de l'opérateur |
| 2026-09-23 13:58 | P0 | — | En attente : étapes 0 et 1 et test 0 confirmés par l'opérateur | Arrêt |

### Phase A — vérification, lecture seule (nouvel ordre de marche de l'opérateur)

Deux écarts de méthode de l'agent : trois puis deux lectures lancées en
parallèle au lieu d'une à la fois. Sans effet (lectures seules), corrigé.

| Horodatage | Étape | Commande | Sortie significative | Verdict / écart |
|---|---|---|---|---|
| 2026-09-23 14:05 | 2 — H5/H6 | `docker ps --format '{{.Names}}'` | `production-app-1`, `production-db-1`, `staging-app-1`, `staging-db-1` ; aussi `liens-canins` | Conforme. **Écart hors périmètre** : `liens-canins` absent de la topologie du dépôt |
| 2026-09-23 14:05 | 2 — H2/H3 | `docker volume ls` filtré | les 4 volumes attendus | Conforme |
| 2026-09-23 14:06 | 2 — H9 | `docker volume inspect -f '{{.Name}} {{.Driver}} {{.Mountpoint}}'` | 4 × `local`, `/var/lib/docker/volumes/<nom>/_data` | Conforme |
| 2026-09-23 14:06 | 2 — tailles | `docker exec <app> du -sh …/public/uploads …/var/private` (substitut sans sudo) | staging 9,5 Mo + 3,7 Mo ; production 11,0 Mo + 59,1 Mo | Relevé |
| 2026-09-23 14:07 | 2 — H4 | grep config Vich/Liip, puis `cat liip_imagine.yaml` | Vich → `public/uploads/*` ; Liip `web_root %kernel.project_dir%/public`, `cache_prefix media/cache` ; identique en production | Conforme : cache hors volume, pas de `RESTIC_EXCLUDE_FILE` |
| 2026-09-23 14:09 | 2 — H10 staging | `docker top staging-app-1 -o pid,uid,gid,args` | workers `php-fpm: pool www` en 82:82 ; nginx workers 100:101 | Conforme |
| 2026-09-23 14:09 | 2 — H10 staging | `stat` racines volumes | `82:82 755` × 2 | Conforme (H10 confirmée pour `cv_private`) |
| 2026-09-23 14:10 | 2 — H10 staging | `find … ! -user 82` | aucune sortie | Conforme |
| 2026-09-23 14:10 | 2 — H10 production | `docker top`, `stat`, `find ! -user 82` | workers 82:82 ; racines `82:82 755` ; aucune exception | Conforme |
| 2026-09-23 14:11 | Espace | `df -hP / /var/lib /var/lib/docker` | un seul FS `/dev/sda1` 75 Go, 64 Go libres | Relevé : dossier de travail, volumes et MySQL sur le même FS |
| 2026-09-23 14:11 | Taille des bases | `docker exec <db> du -sh /var/lib/mysql/alivaon_db /var/lib/mysql` | staging 4,7 Mo (datadir 202 Mo) ; production 4,9 Mo (datadir 220 Mo) | Relevé |
| 2026-09-23 14:12 | H8 (indice) | extensions des fichiers de `alivaon_db` | 29 `.ibd` dans chaque environnement | InnoDB seul (indice) ; routines/événements à constater par SQL |
| 2026-09-23 14:13 | rsync | `rsync --version` | 3.4.1, capacités `ACLs`, `xattrs` | Conforme |
| 2026-09-23 14:13 | rsync | `rsync -aHAX --numeric-ids --dry-run …` | `code=0`, aucune écriture | Conforme |
| 2026-09-23 14:14 | Versions | `apt-cache policy restic` | non installé ; candidat 0.18.1 | Voie `apt` (≥ 0.16) |
| 2026-09-23 14:14 | Versions | `docker version`, `systemctl --version`, `lsb_release` | Docker 29.6.1 ; systemd 259 ; Ubuntu 26.04 LTS | Conforme ; 26.04 non cité par le runbook, sans incidence |
| 2026-09-23 14:15 | ACL/xattr | `command -v getfacl getfattr` | `getfacl` présent, `getfattr` absent | Paquet `attr` à installer (sudo : opérateur) |
| 2026-09-23 14:15 | SFTP Storage Box | — | Non testable sans secret : clé VPS et alias créés à l'étape 6 | Commande préparée |
| 2026-09-23 14:15 | STOP 1 | — | Compte rendu à l'opérateur | Arrêt |
