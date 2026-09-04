# Accès aux interfaces d'administration

| Port local | Service | Environnement | Conteneur |
|---|---|---|---|
| `8081` | Adminer | **production** | `adminer-production` |
| `8082` | File Browser | production *(lecture seule)* + préprod | `filebrowser` |
| `8083` | Adminer | **préprod** | `adminer-staging` |

*(Portainer occupe `9443`, en HTTPS, et fait l'objet de [sa propre note](portainer.md).)*

## 1. Pourquoi un tunnel

Ces trois services écoutent exclusivement sur `127.0.0.1` du VPS et ne sont
routés par aucun sous-domaine : UFW n'autorise que 22, 80 et 443, et rien
d'autre n'est ouvert. La clé SSH est donc la seule porte d'entrée — il n'existe
aucune URL publique à deviner, aucun formulaire à forcer depuis Internet.

## 2. Ouvrir le tunnel

En copier-coller, les trois ports d'un coup :

```bash
ssh -N \
  -o ExitOnForwardFailure=yes \
  -L 8081:127.0.0.1:8081 \
  -L 8082:127.0.0.1:8082 \
  -L 8083:127.0.0.1:8083 \
  alivaon
```

`-N` n'ouvre aucun shell distant : la session ne sert qu'au transport.
`ExitOnForwardFailure=yes` fait échouer la commande bruyamment si un port local
est déjà pris, au lieu de laisser un tunnel partiellement ouvert dans lequel une
seule interface répondrait.

Le terminal reste occupé tant que le tunnel vit. C'est voulu : il est visible, et
`Ctrl+C` le ferme.

### Variante `~/.ssh/config`

Pour réduire l'ouverture à une commande courte, ajouter ce bloc à
`~/.ssh/config` sur le poste macOS, **à côté** du bloc `Host alivaon` existant
sans le remplacer :

```sshconfig
Host alivaon-admin
    HostName 178.104.185.156
    User alivaondev
    IdentityFile ~/.ssh/id_ed25519
    # Aucun shell distant : ce bloc ne sert qu'aux redirections.
    RequestTTY no
    SessionType none
    ExitOnForwardFailure yes
    LocalForward 8081 127.0.0.1:8081
    LocalForward 8082 127.0.0.1:8082
    LocalForward 8083 127.0.0.1:8083
```

L'ouverture devient :

```bash
ssh alivaon-admin
```

`SessionType none` est l'équivalent de `-N` en fichier de configuration ; sur les
versions d'OpenSSH antérieures à 8.7 qui ne le connaissent pas, le retirer et
lancer `ssh -N alivaon-admin`.

## 3. Les trois interfaces

Une fois le tunnel ouvert :

| URL | Donne accès à | Environnement |
|---|---|---|
| <http://localhost:8081> | base MySQL `alivaon_db` de production | **production** |
| <http://localhost:8082> | fichiers téléversés des deux environnements | mixte |
| <http://localhost:8083> | base MySQL `alivaon_db` de préprod | **préprod** |

En clair et non en HTTPS : le chiffrement est assuré par le tunnel SSH, le
trafic ne circule jamais en dehors.

> **Le port détermine l'environnement, rien d'autre.**
> `8081` = production. `8083` = préprod.
>
> Ce n'est pas une convention mais une contrainte de câblage :
> `adminer-production` n'est rattaché qu'au réseau `production_internal`, et
> `adminer-staging` qu'à `staging_internal`. Chaque instance est **incapable**
> de joindre la base de l'autre environnement, quoi qu'on saisisse dans le
> formulaire. Les deux bases portant le même nom et le même utilisateur, c'est
> cette séparation réseau — et non la vigilance — qui empêche de modifier la
> production en croyant toucher au préprod.

## 4. Connexion à Adminer

Le champ **Serveur** est pré-rempli et diffère d'une instance à l'autre : c'est
le repère visuel qui distingue les deux écrans, par ailleurs identiques.

| Champ | `:8081` production | `:8083` préprod |
|---|---|---|
| Système | MySQL | MySQL |
| Serveur | `production-db-1` *(pré-rempli)* | `staging-db-1` *(pré-rempli)* |
| Utilisateur | `alivaon_app` ou `root` | `alivaon_app` ou `root` |
| Mot de passe | voir §6 | voir §6 |
| Base | `alivaon_db` | `alivaon_db` |

Si le champ Serveur est vide ou affiche autre chose, ne pas le corriger à la
main : c'est le signe que la stack ne tourne pas dans l'état décrit ici (voir §8).

### Quel compte utiliser

**`alivaon_app` par défaut, pour tout le travail courant.** Ce compte détient
`ALL PRIVILEGES` sur la base `alivaon_db` : consultation, modification des
données, et modification du schéma de cette base. Il couvre l'intégralité des
opérations applicatives.

**`root` uniquement pour ce que le compte applicatif ne peut pas faire**, car il
n'a que `USAGE` en dehors de sa base :

- lister ou consulter une autre base que `alivaon_db` ;
- créer, modifier ou supprimer un compte MySQL, ajuster des `GRANT` ;
- lire ou changer une variable serveur, consulter `mysql.*` ou
  `performance_schema` ;
- restaurer un dump qui contient des instructions au niveau serveur.

Ouvrir une session `root` pour une simple consultation de données revient à
travailler sans filet là où `alivaon_app` aurait refusé une erreur de portée.

## 5. Connexion à File Browser

Utilisateur **`admin`**. Mot de passe : voir §6.

Deux dossiers seulement sont visibles à la racine :

```
/srv
├── production-uploads   ← LECTURE SEULE
└── staging-uploads      ← lecture / écriture
```

Rien d'autre n'est monté. Ni les fichiers de configuration du serveur, ni les
certificats TLS, ni les volumes `cv_private` — qui contiennent les CV déposés
par les candidats et sont délibérément hors de portée, y compris en lecture.

### La production est en lecture seule, et c'est voulu

Sur `production-uploads`, ces opérations **échoueront** :

- téléverser un fichier ;
- renommer, déplacer ou supprimer ;
- créer un dossier ;
- éditer un fichier en place.

La consultation, la prévisualisation et le téléchargement fonctionnent
normalement.

La cause n'est pas un problème de droits à corriger : File Browser est un projet
**archivé depuis le 1ᵉʳ septembre 2026**, et la version déployée est atteinte par
`GHSA-c4fr-5f24-4wrj`, qui provoque une suppression récursive de dossiers lors du
nettoyage d'un téléversement échoué — sans correctif possible. Le volume est donc
monté `:ro`, ce qui confie le refus au noyau plutôt qu'au contrôle de permissions
que la faille contourne. Le message d'erreur attendu est `Read-only file system`.

**Ne pas repasser ce montage en `:rw`** pour débloquer une manipulation ponctuelle.
Pour agir sur un fichier de production, passer par l'application ou par le shell
du VPS. Contexte complet dans la section « Dette connue » du
[README](../README.md#dette-connue).

## 6. Où sont les mots de passe

Aucun mot de passe ne figure dans ce dépôt, et aucun ne doit y être ajouté :
tous les fichiers ci-dessous sont exclus par `.gitignore` (`.env`, `.env.*`).
Ils n'existent que sur le VPS, en `0600`.

| Pour | Fichier sur le VPS | Variable à lire |
|---|---|---|
| Adminer production, compte `alivaon_app` | `/opt/alivaon/production/.env` | `MYSQL_PASSWORD` |
| Adminer production, compte `root` | `/opt/alivaon/production/.env` | `MYSQL_ROOT_PASSWORD` |
| Adminer préprod, compte `alivaon_app` | `/opt/alivaon/staging/.env` | `MYSQL_PASSWORD` |
| Adminer préprod, compte `root` | `/opt/alivaon/staging/.env` | `MYSQL_ROOT_PASSWORD` |
| File Browser, compte `admin` | `/opt/alivaon/filebrowser/.env` | `FB_ADMIN_PASSWORD` |

Lecture d'une seule variable, sans afficher le reste du fichier :

```bash
ssh alivaon 'grep "^MYSQL_PASSWORD=" /opt/alivaon/production/.env'
ssh alivaon 'grep "^FB_ADMIN_PASSWORD=" /opt/alivaon/filebrowser/.env'
```

`MYSQL_DATABASE` et `MYSQL_USER` vivent au même endroit. Ils ne figurent pas
dans les `docker-compose.yml`, qui se contentent d'un `env_file: .env`, ni dans
les `.env.example`, où ils sont laissés vides. Les valeurs en service sont
`alivaon_db` et `alivaon_app`, identiques sur les deux environnements.

## 7. Fermer la session

Le tunnel lancé au premier plan se ferme par **`Ctrl+C`** dans son terminal.

S'il a été lancé en arrière-plan avec `-f`, le retrouver et le fermer :

```bash
# Quel processus tient les ports ?
lsof -nP -iTCP:8081 -iTCP:8082 -iTCP:8083 -sTCP:LISTEN

# Fermer le tunnel correspondant
pkill -f 'ssh -N.*8081:127.0.0.1:8081'
```

Vérifier qu'il ne reste rien :

```bash
lsof -nP -iTCP:8081 -sTCP:LISTEN   # aucune sortie = tunnel fermé
```

> **Ne jamais laisser un tunnel ouvert sans surveillance sur un poste partagé.**
> Tant qu'il vit, `http://localhost:8081` donne accès à la base de production
> depuis ce poste — sans mot de passe SSH, sans nouvelle authentification, à
> quiconque s'assoit devant l'écran. Une session Adminer laissée connectée
> ajoute même la base déjà ouverte. Fermer le tunnel fait partie de la fin de
> l'intervention, au même titre que la déconnexion.

## 8. Dépannage

### « Connection refused » sur `localhost:8081`

Rien n'écoute côté poste : le tunnel n'est pas ouvert, ou il s'est fermé.

```bash
# Côté poste — le tunnel est-il vivant ?
lsof -nP -iTCP:8081 -sTCP:LISTEN
```

Aucune sortie : rouvrir le tunnel (§2). Si l'ouverture échoue avec
`bind: Address already in use`, un autre programme occupe le port localement —
l'identifier avec la même commande `lsof` avant de le libérer.

Si le tunnel est bien vivant, le problème est côté serveur :

```bash
ssh alivaon "ss -tln | grep -E ':808[123] '"
```

Les trois lignes attendues portent `127.0.0.1`. Une ligne manquante signifie que
le conteneur correspondant ne tourne pas ; une ligne en `0.0.0.0` serait une
anomalie grave à corriger immédiatement (le service serait exposé publiquement).

### Le tunnel s'ouvre mais la page ne charge pas

Le transport fonctionne, le service derrière ne répond pas.

```bash
ssh alivaon 'docker ps --filter name=adminer --filter name=filebrowser \
  --format "{{.Names}}\t{{.Status}}\t{{.Ports}}"'
```

Les trois doivent être `Up ... (healthy)`. Puis, en court-circuitant le tunnel
pour savoir de quel côté est la panne :

```bash
ssh alivaon 'for p in 8081 8082 8083; do
  printf "%s -> %s\n" "$p" "$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://127.0.0.1:$p/)"
done'
```

- **200 côté VPS mais rien côté poste** : la redirection est en cause. Fermer et
  rouvrir le tunnel, vérifier qu'aucun port n'a été remplacé dans la commande.
- **Pas de réponse côté VPS** : le conteneur est en cause.

```bash
ssh alivaon 'docker logs --tail 40 adminer-production'
ssh alivaon 'docker logs --tail 40 filebrowser'
```

Un conteneur `unhealthy` ou en redémarrage permanent se relance avec
`docker compose up -d` depuis `/opt/alivaon/adminer` ou `/opt/alivaon/filebrowser`.

### Adminer refuse la connexion MySQL

La page s'affiche, le formulaire est rejeté. Trois causes, dans cet ordre.

**1. Le mot de passe.** Le plus fréquent. Le relire à la source (§6) plutôt que
de le retaper de mémoire, et vérifier qu'il correspond au bon environnement :
les deux `.env` ont les mêmes noms de variables et des valeurs différentes.

**2. La base de données ne répond pas.**

```bash
ssh alivaon 'docker ps --filter name=db --format "{{.Names}}\t{{.Status}}"'
```

`production-db-1` et `staging-db-1` doivent être `Up ... (healthy)`. Sinon :

```bash
ssh alivaon 'docker logs --tail 40 production-db-1'
```

**3. Le nom de serveur saisi.** Vérifier qu'Adminer voit bien sa base, depuis le
conteneur lui-même :

```bash
ssh alivaon 'for c in adminer-production adminer-staging; do
  s=$(docker exec $c printenv ADMINER_DEFAULT_SERVER)
  printf "%-20s serveur=%-18s ip=%s\n" "$c" "$s" "$(docker exec $c getent hosts $s | awk "{print \$1}")"
done'
```

Une adresse en `172.19.x` correspond à la production, `172.20.x` au préprod.
**Aucune adresse retournée** signifie que le conteneur n'est plus rattaché au
réseau de sa base — relancer la stack depuis `/opt/alivaon/adminer`.

Tester la couche TCP jusqu'au serveur MySQL, ce qui écarte définitivement le
réseau :

```bash
ssh alivaon 'docker exec adminer-production sh -c \
  "nc -w 3 production-db-1 3306 | head -c 60 | tr -d \"\\000\" | strings | head -1"'
```

La sortie commence par la version du serveur, par exemple `8.0.46`, souvent
suivie de quelques caractères parasites issus du reste de la trame — c'est
normal. Voir cette version prouve que la connexion TCP aboutit et que seule
l'authentification est en cause.

### File Browser refuse une opération sur `production-uploads`

Ce n'est pas une panne. Voir §5 : le montage est en lecture seule, délibérément.
Confirmation :

```bash
ssh alivaon 'docker exec filebrowser grep "srv/production-uploads" /proc/mounts'
# ... ext4 ro,relatime ...   -> "ro" attendu
```

### Le formulaire Adminer n'affiche aucun serveur pré-rempli

La variable d'environnement n'est pas passée : la stack tourne dans une version
antérieure à celle décrite ici, ou a été démarrée hors de son
`docker-compose.yml`.

```bash
cd ~/Desktop/Alivaon/alivaon-infra && ./scripts/diff-vps.sh
```

Un écart signalé sur `adminer/docker-compose.yml` confirme le diagnostic :
redéployer le fichier du dépôt, puis `docker compose up -d`.
