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
> disparaît avec le VPS. **Une copie doit exister dans le gestionnaire de mots
> de passe**, faute de quoi, après une perte totale du VPS, les sauvegardes
> existent mais sont illisibles à jamais.
>
> Le Test 0 de [RUNBOOK-RESTORE-TEST.md](RUNBOOK-RESTORE-TEST.md) prouve que
> cette copie fonctionne. Il est obligatoire à l'installation et après chaque
> rotation.

---

## Fonctionnement

```
  03:15 Europe/Paris ─ alivaon-backup.timer
                              │
                    alivaon-backup.service ── échec ──► alivaon-backup-failure.service
                              │                          journal (err) + healthchecks /fail
                         backup.sh
                              │
      ┌───────────────────────┴───────────────────────┐
      │ pour production, puis staging :               │
      │  1. mysqldump --single-transaction            │
      │     (dans le conteneur MySQL)                 │
      │  2. restic backup : dump + volumes            │──► dépôt restic chiffré
      │     étiquettes env:<env>, kind:scheduled      │    (Storage Box SFTP ou S3)
      └───────────────────────┬───────────────────────┘
                              │
             3. restic forget --prune (7 j / 4 sem / 6 mois)
                              │
                     healthchecks /0 (succès) ou /<code>
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
environ 17 instantanés et six mois d'historique.

### Ce qui est sauvegardé

| Élément | Comment |
|---|---|
| Base `alivaon_db` (production, staging) | `mysqldump --single-transaction` dans le conteneur, dump SQL non compressé : restic compresse et déduplique mieux que gzip, qui casserait la déduplication d'un jour à l'autre |
| Uploads VichUploader (`public/uploads`) | Volume Docker, chemin demandé à Docker à chaque exécution |
| CV des candidats (`var/private`) | Idem. Données personnelles : voir « Limites » |

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
| `backup.sh` | `/usr/local/lib/alivaon-backup/` | Dump, sauvegarde, rétention. Lancé par le timer |
| `restore.sh` | idem | Restauration paramétrée, confirmée, avec garde-fous |
| `verify.sh` | idem | `restic check`, inventaire, fraîcheur < 48 h |
| `restic.sh` | idem | restic avec la configuration chargée, pour les opérations manuelles |
| `notify-failure.sh` | idem | Appelé par le service d'échec |
| `lib.sh` | idem | Fonctions communes (sourcé) |
| `alivaon-backup.service` | `/etc/systemd/system/` | Exécution de `backup.sh` |
| `alivaon-backup.timer` | idem | Chaque nuit à 03:15, heure de Paris |
| `alivaon-backup-failure.service` | idem | Notification d'échec (`OnFailure=`) |
| `.env.example` | → `/etc/alivaon-backup/backup.env` | Gabarit documenté de la configuration |
| `RUNBOOK-BACKUP.md` | — | Mise en place pas à pas |
| `RUNBOOK-RESTORE-TEST.md` | — | Tests de restauration et critères de réussite |

Sur le VPS, en dehors des scripts :

| Chemin | Contenu | Droits |
|---|---|---|
| `/etc/alivaon-backup/backup.env` | Configuration, mots de passe MySQL | `root:root 600` |
| `/etc/alivaon-backup/restic-password` | Mot de passe du dépôt | `root:root 400` |
| `/etc/alivaon-backup/ssh/` | Clé SSH et `known_hosts` de la Storage Box | `root:root 700` |
| `/etc/ssh/ssh_config.d/alivaon-backup.conf` | Alias `alivaon-storagebox` | `644`, sans secret |
| `/var/lib/alivaon-backup/` | Dumps pendant la sauvegarde, extraction pendant la restauration. **Vide au repos** | `700` |
| `/var/cache/alivaon-backup/` | Cache restic (métadonnées chiffrées) | `700` |

Les scripts refusent de démarrer si la configuration ou le mot de passe sont
lisibles par un autre utilisateur que root.

---

## Installation

Suivre [RUNBOOK-BACKUP.md](RUNBOOK-BACKUP.md) de bout en bout. Il commence par
la liste des **hypothèses** déduites des fichiers compose, et leur contrôle sur
le serveur.

---

## Exploitation courante

Toutes les commandes se lancent **sur le VPS**.

| Besoin | Commande |
|---|---|
| Prochaine exécution | `systemctl list-timers alivaon-backup.timer` |
| Journal de la dernière sauvegarde | `sudo journalctl -u alivaon-backup.service -n 80 --no-pager` |
| Uniquement les erreurs | `sudo journalctl -u alivaon-backup.service -p err --since -7d` |
| Sauvegarder maintenant | `sudo systemctl start alivaon-backup.service` |
| Contrôle de santé | `sudo /usr/local/lib/alivaon-backup/verify.sh` |
| Contrôle approfondi (relit 5 % des données) | `sudo /usr/local/lib/alivaon-backup/verify.sh --read-data-subset 5%` |
| Inventaire | `sudo /usr/local/lib/alivaon-backup/restore.sh --list` |
| Occupation du dépôt | `sudo /usr/local/lib/alivaon-backup/restic.sh stats --mode raw-data` |

**Rythme conseillé** : `verify.sh` chaque semaine, `--read-data-subset 5%`
chaque mois, Test 1 du runbook de restauration chaque mois, Test 2 chaque
trimestre.

### Alertes

- **healthchecks.io** (si `HC_PING_URL` est renseigné) : alerte sur échec
  **et** sur absence d'exécution. Le second cas n'est détectable que par ce
  moyen.
- **Journal** : tout échec est journalisé en priorité `err` par
  `alivaon-backup-failure.service`.

### Restaurer

```bash
# Inventaire
sudo /usr/local/lib/alivaon-backup/restore.sh --list --target production

# Restauration complète (base + fichiers) d'un instantané donné
sudo /usr/local/lib/alivaon-backup/restore.sh --target production --snapshot <ID>

# Fichiers seulement, dernier instantané planifié
sudo /usr/local/lib/alivaon-backup/restore.sh --target production --snapshot latest --only uploads
```

Avant d'écraser, `restore.sh` archive l'état courant de la cible
(`kind:pre-restore`) et affiche son identifiant : c'est le retour arrière.
Le conteneur applicatif est arrêté pendant l'écriture, puis redémarré par
`docker start`, sans passer par `docker compose up`.

| Règle | Comportement |
|---|---|
| staging → production | **Refus**, code 3, aucune option ne le lève |
| production → staging | Refus, sauf `--allow-production-to-staging` (copie de données personnelles en préprod) |
| Étiquette et manifeste discordants | Refus, code 3 |
| Pas de terminal | Refus : la confirmation est toujours interactive |

### Perte totale du VPS

1. Reconstruire le serveur selon le README racine (« Reconstruire le VPS depuis
   zéro »), jusqu'au `docker compose up -d` des deux stacks. Les volumes et les
   bases vides sont alors créés.
2. [RUNBOOK-BACKUP.md](RUNBOOK-BACKUP.md), étapes 3 à 8, avec le mot de passe
   **du gestionnaire** et le **même** `RESTIC_HOST`. À l'étape 9,
   `cat config` doit afficher le dépôt existant : **ne jamais lancer `init`**.
3. **Ne pas activer le timer** (étape 13) avant la restauration. Une sauvegarde
   d'un serveur vide prendrait place dans la rétention.
4. `sudo /usr/local/lib/alivaon-backup/restore.sh --target production --snapshot latest --no-safety-snapshot`
5. Vérifier le site, puis faire de même avec `--target staging`.
6. Activer le timer, puis lancer `verify.sh`.

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
   `sudo systemctl stop alivaon-backup.timer`
3. **[VPS]** Déposer le nouveau mot de passe (coller, Entrée, Ctrl-D) :
   `sudo sh -c 'umask 077; cat > /etc/alivaon-backup/restic-password.new'`
4. **[VPS]** Ajouter la clé :
   `sudo /usr/local/lib/alivaon-backup/restic.sh key add --new-password-file /etc/alivaon-backup/restic-password.new`
5. **[VPS]** Noter l'ID de l'**ancienne** clé, marquée `*` (celle qui a ouvert
   le dépôt) : `sudo /usr/local/lib/alivaon-backup/restic.sh key list`
6. **[VPS]** Basculer :
   `sudo install -o root -g root -m 0400 /etc/alivaon-backup/restic-password.new /etc/alivaon-backup/restic-password`
   puis `sudo rm /etc/alivaon-backup/restic-password.new`
7. **[VPS]** Contrôler : `sudo /usr/local/lib/alivaon-backup/restic.sh key list`
   (la clé `*` est maintenant la nouvelle), puis `verify.sh`.
8. **[MAC]** Test 0 de [RUNBOOK-RESTORE-TEST.md](RUNBOOK-RESTORE-TEST.md) avec
   le **nouveau** mot de passe. S'arrêter en cas d'échec : l'ancienne clé est
   toujours valide.
9. **[VPS]** Retirer l'ancienne clé :
   `sudo /usr/local/lib/alivaon-backup/restic.sh key remove <ID_ANCIENNE_CLÉ>`
10. **[VPS]** Reprendre : `sudo systemctl start alivaon-backup.timer`
11. **[MAC]** Supprimer l'ancien mot de passe du gestionnaire.

**Limite.** La clé maîtresse ne change pas. Si l'ancien mot de passe **et** une
copie du dépôt ont fuité ensemble, la rotation ne protège pas cette copie. Une
rotation qui rechiffre réellement impose un nouveau dépôt (`restic init`) et
la recopie des instantanés (`restic copy`).

### Autres secrets

| Secret | Rotation |
|---|---|
| Mot de passe MySQL applicatif | Le changer dans MySQL, dans le `.env` de la stack **et** dans `*_DB_PASSWORD` de `backup.env`. Sinon, la sauvegarde échoue dès la nuit suivante |
| Clé SSH de la Storage Box | Nouvelle clé (étape 5 du runbook), dépôt, test `sftp -b -`, retrait de l'ancienne dans `.ssh/authorized_keys` du sous-compte |
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
consomment aussi de l'espace sur le quota.

---

## Limites connues

- **Un VPS compromis peut effacer le dépôt.** Il détient la clé SSH ou les clés
  S3 en écriture. Parade : les instantanés automatiques de la Storage Box
  (étape 0 du runbook), inaccessibles au sous-compte. Sur S3, activer le
  versioning ou l'Object Lock du bucket.
- **Cohérence base / fichiers.** Le dump précède les fichiers de quelques
  secondes à quelques minutes. Un fichier téléversé entre les deux figure dans
  la sauvegarde sans ligne en base : orphelin inoffensif. L'ordre inverse
  aurait produit des lignes pointant vers des fichiers absents.
- **RGPD.** Un CV supprimé de l'application reste jusqu'à six mois dans les
  sauvegardes (rétention mensuelle). À déclarer dans le registre des
  traitements et la politique de confidentialité, ou à exclure (retirer
  `cv_private=...` des `*_VOLUMES`).
- **Mot de passe MySQL en double.** `backup.env` recopie `MYSQL_PASSWORD` des
  stacks. Une divergence fait échouer la sauvegarde bruyamment, jamais en
  silence.
- **restic ≥ 0.16 requis** (`--retry-lock`, dépôt compressé). Vérifié au
  démarrage de chaque script.
- **Pas de comparaison automatique** avec le dépôt Git : `scripts/diff-vps.sh`
  ne couvre que `/opt/alivaon`. Contrôle manuel : étape 16 du runbook.

---

## Codes de sortie

| Script | 0 | 1 | 2 | 3 |
|---|---|---|---|---|
| `backup.sh` | succès complet | une étape a échoué | — | — |
| `restore.sh` | restauration terminée | échec (le journal dit si la cible a été modifiée) | — | refus de sécurité |
| `verify.sh` | dépôt sain et à jour | `restic check` en échec | sauvegarde trop ancienne ou absente | — |
