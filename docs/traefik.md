# Traefik — configuration et historique

État courant : **`traefik:v3.7.12`**, accès direct au socket Docker,
`aliasHeadersStrategy: delete` sur les deux entryPoints.

Trois interventions se sont enchaînées sur le reverse proxy de production dans
la nuit du **4 septembre 2026**. Ce document retrace chacune, avec son motif —
la conclusion générale étant qu'aucune ne doit être défaite sans comprendre
pourquoi elle a été faite.

Cumul d'indisponibilité des trois : **moins de 4 secondes**.

---

## Configuration actuelle

| | |
|---|---|
| Image | `traefik:v3.7.12` (digest amd64 `sha256:7523e37d…eecc6`) |
| Ports publiés | `80`, `443` — seul conteneur à publier sur l'hôte |
| Socket Docker | monté en **RW** (un montage `:ro` fait échouer le `connect()` sur un socket unix) |
| Réseaux | `traefik_proxy` uniquement, déclaré `external: true` |
| Résolveur ACME | `letsencrypt`, httpChallenge sur l'entryPoint `web` |
| Dashboard | désactivé (`api.dashboard: false`) — aucun port d'API exposé |
| Découverte | `exposedByDefault: false` — rien n'est routé sans `traefik.enable=true` |

L'image officielle tourne en **root** (`Config.User` vide) : aucun `group_add`
n'est nécessaire pour lire le socket, contrairement au sidecar HAProxy d'autrefois.

---

## Intervention 1 — v3.5 → v3.6.25, retrait du sidecar HAProxy

### Ce qui existait

La stack comportait un second conteneur, `traefik-dockerproxy` (HAProxy), qui
détenait le socket Docker et réécrivait le préfixe de version des requêtes de
l'API Docker (`/v1.24/…` → `/v1.44/…`) avant de les transmettre. Traefik
l'interrogeait en `tcp://dockerproxy:2375`, sur un réseau dédié `docker_api`
déclaré `internal`.

### Pourquoi il a été supprimé

Le sidecar contournait le fait que Docker Engine 29 a supprimé le support des
versions d'API antérieures à 1.44, alors que le provider docker de Traefik v3.5
parlait l'API 1.24 sans négociation.

**Ce contournement visait une version obsolète de Traefik, pas une contrainte de
Docker 29.** Traefik a corrigé sa négociation d'API en **v3.6.1**. À partir de
là, le sidecar ne servait plus à rien.

Une analyse préalable a confirmé qu'il **ne filtrait pas** la surface de l'API :
une seule directive `http-request replace-path`, un `default_backend` en
catch-all, aucune ACL, aucune restriction de méthode ni d'endpoint. Traefik
disposait donc déjà d'un accès complet et non filtré au démon. Son retrait est
neutre côté sécurité — et même marginalement favorable, puisque le point d'accès
TCP non authentifié sur `docker_api` disparaît avec lui.

### Résultat

Conteneur `traefik-dockerproxy` supprimé (via `up -d --remove-orphans` —
sans cette option, Compose laisse en vie le conteneur d'un service retiré du
fichier, et il garde le réseau attaché), réseau `traefik_docker_api` supprimé,
fichier `docker-proxy.cfg` laissé sur le serveur mais plus référencé.

**43 Mio de mémoire libérés** (Traefik 22,7 + HAProxy 41,1 → Traefik 20,6 Mio).

### 🚫 Ne pas réintroduire ce sidecar

Le contenu de `docker-proxy.cfg` est reproduit ci-dessous **à titre d'archive
documentaire uniquement**. Il n'est volontairement pas versionné comme fichier :
un `docker-proxy.cfg` posé à côté des configurations vivantes invite à être
remis en service, ce qui réintroduirait un composant inutile détenant le socket
Docker.

```haproxy
# ARCHIVE — NE PAS REMETTRE EN SERVICE (retiré le 2026-09-04)
#
# HAProxy — sidecar de compatibilité API Docker.
#
# Pourquoi : le provider docker de Traefik parle l'API Docker 1.24 (pinned, sans
# négociation, et ignore DOCKER_API_VERSION). Or Docker Engine 29+ refuse toute
# API < 1.40. On intercale ce proxy qui réécrit le préfixe de version des
# requêtes (1.24 -> 1.44) avant de les transmettre au socket Docker.
#
# HAProxy tourne en root DANS le conteneur (aucune directive user/group), il peut
# donc lire /var/run/docker.sock (root:docker) — sans sudo côté hôte.

global
    log stdout format raw local0

defaults
    mode http
    log global
    option httplog
    timeout connect 5s
    timeout client  3600s   # /events est un flux long -> timeouts larges
    timeout server  3600s

frontend docker_api_in
    bind :2375
    # Réécrit /v1.24/<x> en /v1.44/<x> (toutes les routes de l'API).
    http-request replace-path ^/v1\.24/(.*)$ /v1.44/\1
    default_backend docker_sock

backend docker_sock
    # Backend socket unix -> syntaxe HAProxy `unix@/chemin`.
    server dockersock unix@/var/run/docker.sock
```

**Motif de l'interdiction, en une phrase :** depuis Traefik v3.6, le provider
docker négocie la version d'API avec le démon, ce sidecar n'a plus d'objet.

---

## Intervention 2 — v3.6.25 → v3.7.12

Une seule ligne modifiée : la directive `image:`. Digest `linux/amd64` vérifié
avant bascule.

Analyse préalable du guide de migration sur les deux branches mineures
franchies. Aucune rupture ne concernait cette configuration :

| Rupture 3.7 | Concernée ? |
|---|---|
| v3.7.3 — BasicAuth exige `users` non vide | Non, `staging-auth` est renseigné |
| v3.7.3 — StripPrefix rejette les chemins non normalisés | Non, middleware inutilisé |
| v3.7.7 — `Host(*)` devient catch-all | Non, règles explicites |
| v3.7.9 — `CONNECT` HTTP/1 rejeté en 501 | Non, déjà actif depuis 3.6.24 |
| v3.7.12 — poids négatifs TCP/UDP rejetés | Non, aucun service TCP/UDP |
| v3.6.x, v3.7.x — entrées Kubernetes | Non, pas de Kubernetes |

Point de vigilance relevé au passage : la branche 3.6 a connu un aller-retour sur
les **caractères encodés** dans les chemins — rejet par défaut en v3.6.4, retour
au comportement permissif en v3.6.7. Viser une version entre les deux aurait
cassé les URL contenant des caractères encodés. La 3.7 conserve les défauts
permissifs de la 3.6.7.

---

## Intervention 3 — `aliasHeadersStrategy: delete`

Référence : avis de sécurité Traefik **GHSA-rf44-j88r-hh8c**.

### Le problème

Go traite `X-Auth-User`, `X_Auth_User` et `X.Auth.User` comme trois en-têtes
distincts. PHP-FPM, CGI et WSGI les lisent tous comme la **même** variable
`HTTP_X_AUTH_USER`. Un client peut donc usurper un en-tête que le reverse proxy
croit maîtriser.

### Pourquoi cela comptait ici précisément

Dans le dépôt applicatif, `docker/nginx/default.conf:38` :

```nginx
fastcgi_param HTTPS $http_x_forwarded_proto;
```

**La notion de connexion sécurisée vue par Symfony dérive d'un en-tête client.**
Tout ce qui en dépend — génération d'URL absolues, cookies `secure`,
redirections — devient contrôlable par l'appelant s'il parvient à usurper
`X-Forwarded-Proto`.

Ce qui protégeait cela était `underscores_in_headers`, **une valeur par défaut de
nginx, jamais décidée ni écrite nulle part**. Elle tombe dès qu'on ajoute un
`underscores_in_headers on;` pour une raison sans rapport, ou qu'on change
d'image de base. Et elle ne couvre pas les points ni les onze autres caractères
aliasants.

### `delete` plutôt que `reject`

`reject` renvoie **400 sur la requête entière** dès qu'un en-tête aliasant est
présent — y compris légitime. Or les journaux d'accès sont au format CLF, qui
n'enregistre **aucun nom d'en-tête** : il était impossible d'inventorier ce que
les clients réels envoient. Transformer cette inconnue en refus de service était
un risque non borné.

`delete` traite la même faille — l'en-tête n'atteint jamais le backend — mais
échoue en douceur : la requête aboutit, seul l'en-tête disparaît.

### Vérification

Un code 200 ne prouve rien : il ne distingue pas « en-tête supprimé » de « option
inopérante ». La preuve a été obtenue par un test différentiel sur la **taille**.

nginx refuse tout en-tête dépassant 8 Ko (`large_client_header_buffers`) et le
bufférise *avant* de décider de l'ignorer. Un en-tête aliasant de 16 Ko qui
l'atteint produit donc un 400 — sauf si Traefik l'a supprimé en amont.

| En-tête de 16 Ko | À travers Traefik | En accès direct à nginx |
|---|---|---|
| `X-Big` (tiret, non aliasant) | **400** | **400** |
| `X_Big` (underscore, aliasant) | **200** | **400** |
| `X.Big` (point, aliasant) | **200** | **400** |
| témoin sans en-tête | 200 | 200 |

nginx rejette les trois quand il les reçoit ; à travers Traefik, seules les
variantes aliasantes passent. Elles n'atteignent donc jamais nginx : la
suppression est démontrée, pas inférée.

### Effet secondaire attendu

Traefik v3.7.12 émet un avertissement au démarrage pour chaque entryPoint sans
cette option. Après configuration, ces deux WRN disparaissent — c'est le
contrôle de cohérence le plus simple.

⚠️ `docker compose restart` conserve les journaux du démarrage précédent : un
`docker logs` non filtré affichera encore les anciens avertissements. Filtrer sur
le nouveau démarrage avant de conclure.

---

## Chantiers ouverts

### Journaux d'accès en JSON

`accessLog: {}` produit du CLF, qui ne journalise **aucun nom d'en-tête**. Double
conséquence : impossible d'inventorier le trafic réel, et **aucune visibilité sur
ce que `aliasHeadersStrategy: delete` supprime effectivement**. Si un client
légitime envoie un `X_Request_Id`, il disparaît sans trace.

Passage souhaitable en `accessLog.format: json` avec quelques champs d'en-têtes
retenus.

### Fragilité du httpChallenge

Le 3 septembre 2026 à 08:16, quatre erreurs `Cannot retrieve the ACME challenge`
sur `alivaon.com` et `www.alivaon.com`. Le renouvellement a finalement abouti le
soir même à 23:23, et un renouvellement ultérieur sur le staging a réussi du
premier coup : la fragilité n'est donc pas systématique.

Piste à explorer : concurrence entre le challenge HTTP et la redirection
`web → websecure`, susceptible d'intercepter `/.well-known/acme-challenge/`
selon le timing.

### Entrée fantôme dans `acme.json`

Trois entrées de certificat pour deux couples de domaines :

| Entrée | SAN réels | Servie ? |
|---|---|---|
| `alivaon.com` | alivaon.com, www.alivaon.com | oui |
| `staging.alivaon.com` | staging.alivaon.com | **non** |
| `www.staging.alivaon.com` | staging.alivaon.com, www.staging.alivaon.com | oui, pour les deux noms |

L'entrée `staging.alivaon.com` est stockée mais jamais servie : celle de
`www.staging.alivaon.com` couvre les deux noms et l'emporte dans la sélection
SNI. Sans gravité, mais c'est un certificat renouvelé pour rien à chaque cycle.

### Traefik 3.7.13 — à réexaminer avant toute montée

Documentée mais non publiée sur Docker Hub au 4 septembre 2026. Deux ruptures
concerneraient cette configuration :

- les en-têtes `Upgrade: h2c` et `HTTP2-Settings` ne sont plus transmis aux
  backends — déclarer le backend en `h2c://` si nécessaire ;
- les cibles « rootless » du type `http:example.com/admin` sont rejetées en
  **400**.

---

## Rappels d'exploitation

**Modifier `traefik.yml` :** `docker compose up -d` est un **no-op** — fichier
monté, définition de service inchangée, et Traefik ne recharge pas sa
configuration statique à chaud. Utiliser `docker compose restart traefik`.
Un changement de la ligne `image:`, lui, est bien pris par `up -d`.

**Critère de non-régression après toute intervention :** le numéro de série du
certificat de production doit rester **rigoureusement inchangé**. Un changement
sur `alivaon.com` signale une perte d'`acme.json`. Un renouvellement sur les
domaines staging est acceptable s'il est tracé par une ligne `Renewing` dans les
journaux.

```bash
echo | openssl s_client -connect www.alivaon.com:443 -servername www.alivaon.com 2>/dev/null \
  | openssl x509 -noout -serial -enddate
```
