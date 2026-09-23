# Chantiers suivants

Travaux identifiés mais volontairement laissés hors des chantiers en cours,
pour que ceux-ci se ferment sur leur périmètre. Chaque entrée dit ce qui a
été constaté, ce qui reste à déterminer, les actions et leur estimation.

---

## 1. Le site client `liens-canins` : hors dépôt, hors sauvegarde

**Priorité : haute parmi les chantiers suivants.** Perdre les données d'un
site client est plus grave que perdre les siennes : l'engagement porte sur
le bien d'un tiers, qui n'a aucune autre copie.

### Constat

Lors de la phase A de l'installation du dispositif de sauvegarde (lecture
seule, **2026-09-23**, voir
[journal-installation-sauvegarde.md](journal-installation-sauvegarde.md)),
`docker ps` sur le VPS a montré un conteneur **`liens-canins`** en marche.
C'est un site client. Il ne figure nulle part dans la topologie versionnée
d'`alivaon-infra`, ni stack, ni `docker-compose.yml`, ni documentation.

Conséquences :

- **sa stack n'est pas reproductible depuis le dépôt** : après une perte du
  VPS, rien ne permet de la reconstruire ;
- **s'il possède une base ou des fichiers téléversés, rien ne les
  sauvegarde** : le dispositif de `backup/` ne couvre que les environnements
  `production` et `staging` d'Alivaon.

### À déterminer

Rien de ce qui suit n'a été examiné : le chantier de sauvegarde s'est tenu à
son périmètre.

- Emplacement de sa définition sur le serveur : un dossier sous
  `/opt/alivaon/` ou ailleurs, un `docker-compose.yml` ou un `docker run` ?
- Possède-t-il une **base de données**, dans son propre conteneur ou
  partagée ?
- Possède-t-il des **volumes**, et avec quel pilote ?
- Des **fichiers téléversés** par ses utilisateurs, ou un contenu purement
  statique, reconstructible depuis son dépôt de code ?
- Son image : d'où vient-elle, et est-elle reconstructible ?

### Actions

1. **Versionner sa stack dans `alivaon-infra`**, dans son propre dossier et
   selon la convention du dépôt (un dossier par stack, `.env` exclu,
   `.env.example` fourni). `scripts/diff-vps.sh` la couvrira alors
   automatiquement, puisqu'il découvre tous les `*/docker-compose.yml`.
2. **S'il a de l'état à sauvegarder, l'ajouter à `backup.env`**, comme un
   environnement de plus : conteneur MySQL, compte `backup` dédié, volumes et
   propriétaire. À vérifier au passage : le dispositif n'admet aujourd'hui que
   les noms d'environnement `production` et `staging`.

### Estimation

**Une à deux heures**, constat compris, si la stack est simple (un conteneur,
éventuellement une base). Plus, si l'examen révèle une base partagée ou une
image non reconstructible.

### Ce que ce chantier n'est pas

Il n'a pas été intégré au dispositif de sauvegarde lors de sa mise en place,
délibérément : ce dispositif se ferme sur son périmètre, Alivaon production
et staging, testé et documenté. `liens-canins` y entrera par un chantier
propre, avec ses propres constats et son propre test de restauration.
