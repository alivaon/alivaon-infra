# Portainer — installation et exploitation

Interface d'administration Docker, installée le **4 septembre 2026** en
cohabitation stricte avec les stacks existantes. Aucune interruption de service,
aucun conteneur préexistant redémarré.

**Portainer n'est pas exposé publiquement.** Il n'est pas routé par Traefik,
ne rejoint aucun réseau existant, et n'ouvre aucun port dans le pare-feu.

---

## Configuration

Voir [`portainer/docker-compose.yml`](../portainer/docker-compose.yml).

| | |
|---|---|
| Image | `portainer/portainer-ce:2.45.0` — **version figée** |
| Publication | `127.0.0.1:9443:9443` |
| Volumes | socket Docker en RW, volume nommé `portainer_data` sur `/data` |
| Sécurité | `security_opt: no-new-privileges:true` |
| Réseau | `portainer_default` seul — créé par la stack, ne rejoint rien d'existant |

### Pourquoi une version figée plutôt que `:lts`

Une montée de version doit rester une décision explicite, jamais l'effet de bord
d'un `docker compose pull`. La 2.45.0 est l'ouverture de la ligne LTS courante
(27 août 2026).

### ⚠️ Le préfixe `127.0.0.1:` est impératif

Docker inscrit ses règles DNAT directement dans la chaîne iptables `DOCKER`,
**évaluée avant les règles d'UFW**. Sans ce préfixe, le port 9443 serait
joignable depuis Internet bien qu'UFW soit actif et n'autorise que 22, 80 et 443.

Ce n'est pas une précaution théorique : c'est le mode d'échec classique d'un
service qu'on croit protégé par le pare-feu. Ne jamais retirer ce préfixe.

### Socket Docker monté en RW

Se connecter à un socket unix exige le droit d'écriture : un montage `:ro` ferait
échouer le `connect()`. C'est ce socket seul qui permet à Portainer de voir tous
les conteneurs — aucun réseau partagé n'est nécessaire.

Rattacher Portainer à `traefik_proxy` serait inutile et l'exposerait au routage.

### Pas de healthcheck

L'image `portainer/portainer-ce` n'embarque pas de `HEALTHCHECK` et repose sur
une base minimale sans shell ni `curl`. Le conteneur affiche `Up`, jamais
`healthy`. La santé se contrôle depuis l'hôte :

```bash
ssh alivaon "curl -k -s -o /dev/null -w '%{http_code}\n' https://127.0.0.1:9443"
```

---

## Accès

```bash
ssh -N -L 9443:127.0.0.1:9443 alivaon
```

Puis dans le navigateur : **`https://localhost:9443`**

> **Le `https://` doit être saisi explicitement.** En tapant `localhost:9443`
> seul, le navigateur complète en `http://` et Portainer, qui n'écoute qu'en TLS
> sur ce port, répond `HTTP 400`. C'est la cause d'échec la plus fréquente.

Certificat auto-signé généré par Portainer (valable jusqu'en 2031) :
l'avertissement du navigateur est attendu. `-N` n'ouvre pas de shell, le terminal
doit rester ouvert ; ajouter `-f` pour passer le tunnel en arrière-plan.

---

## Création du compte administrateur

⚠️ **Deux mécanismes se cumulent, il faut satisfaire les deux :**

1. un **jeton d'installation** imprimé dans les journaux, à coller dans l'écran
   de setup ;
2. un **minuteur d'initialisation** qui se referme quelques minutes après le
   démarrage du conteneur.

Le jeton **ne dispense pas** du minuteur. C'est l'erreur commise lors de
l'installation : le compte a semblé créé, puis l'écran est devenu inaccessible.

Procédure correcte, dans cet ordre :

```bash
# 1. Ouvrir le tunnel
ssh -N -L 9443:127.0.0.1:9443 alivaon

# 2. Redémarrer Portainer pour rouvrir la fenêtre d'initialisation
ssh alivaon 'cd /opt/alivaon/portainer && docker compose restart portainer'

# 3. Récupérer le jeton du DERNIER démarrage
ssh alivaon 'docker logs portainer 2>&1 | grep "setup_token=" | tail -1'

# 4. Ouvrir https://localhost:9443, coller le jeton, créer le compte SANS ATTENDRE
```

Le `tail -1` est essentiel : les journaux cumulent les jetons de tous les
démarrages successifs et **seul le dernier est valide**.

Symptôme d'une fenêtre expirée, renvoyé par
`curl -k https://localhost:9443/api/system/status` :

```json
{"message":"Administrator initialization timeout"}
```

Le jeton autorise la création du compte administrateur, lequel contrôle le démon
Docker de production : **à traiter comme un mot de passe**.

### Vérifier l'état du compte

```bash
curl -k -s -o /dev/null -w '%{http_code}\n' https://localhost:9443/api/users/admin/check
# 204 = un compte administrateur existe
# 404 = aucun compte administrateur
# 303 = fenêtre d'initialisation expirée
```

---

## Mise à jour

La version étant figée, un `pull` seul ne produit aucun effet — c'est voulu.
Éditer la ligne `image:` vers la version cible, puis :

```bash
ssh alivaon
cd /opt/alivaon/portainer
cp docker-compose.yml docker-compose.yml.bak-$(date +%Y%m%d-%H%M%S)
# éditer image: portainer/portainer-ce:<nouvelle version>
docker compose pull
docker compose up -d
docker logs --tail 30 portainer
```

Seul le conteneur `portainer` est recréé ; `portainer_data` est conservé, comptes
et réglages survivent.

Contrairement à `traefik.yml`, il n'y a pas de piège de no-op ici : c'est bien la
ligne `image:`, donc la définition du service, qui change.

---

## Désinstallation

```bash
ssh alivaon
cd /opt/alivaon/portainer
docker compose down                    # conteneur + réseau portainer_default
docker volume rm portainer_data        # OPTIONNEL : efface comptes et réglages
docker rmi portainer/portainer-ce:2.45.0
cd .. && rm -rf portainer
```

`docker compose down` est circonscrit au projet `portainer` : il ne peut pas
atteindre `production`, `staging` ni `traefik`. Omettre la ligne `volume rm` pour
pouvoir réinstaller sans reconfigurer.

---

## Ports internes au conteneur

Portainer écoute sur `0.0.0.0:8000` (tunnel Chisel) et `9000` (HTTP legacy)
**à l'intérieur** du conteneur. Ces ports **ne sont pas publiés** sur l'hôte —
`ss -tlnp` ne montre que `127.0.0.1:9443` — et restent inatteignables. Ils
apparaissent néanmoins dans `docker ps`, ce qui peut inquiéter à tort.

---

## Chantiers ouverts

Ces points concernent l'infrastructure dans son ensemble et sont détaillés dans
[traefik.md](traefik.md). Ils sont rappelés ici pour qu'une lecture de ce seul
document ne les manque pas.

- **Journaux d'accès en JSON** — le format CLF de Traefik ne journalise aucun nom
  d'en-tête, ce qui prive de toute visibilité sur ce que
  `aliasHeadersStrategy: delete` supprime.
- **Fragilité du httpChallenge** — quatre échecs de challenge ACME le
  3 septembre 2026 sur le domaine de production, renouvellement finalement abouti.
- **Entrée fantôme dans `acme.json`** — `staging.alivaon.com` stockée mais jamais
  servie, masquée par l'entrée `www.staging.alivaon.com`.
- **Traefik 3.7.13** — à réexaminer avant toute montée : `Upgrade: h2c` non
  transmis aux backends, cibles « rootless » rejetées en 400.

Propre à Portainer :

- **Aucune supervision** — ni sauvegarde de `portainer_data`, ni alerte si le
  conteneur tombe. La perte du volume n'entraîne que la reconfiguration des
  comptes, sans impact sur les stacks administrées.
