# vps

Sécurise tes VPS **Debian 12** depuis ton Mac, neufs ou déjà en production, puis connecte-toi avec un simple `ssh web1`.

- Connexion **par clé SSH uniquement** : root et mots de passe interdits
- **UFW** : tout est fermé sauf SSH, 80, 443 et les ports que tu choisis
- **Fail2ban** : 5 échecs en 10 minutes = banni 1 heure
- **Mises à jour de sécurité** automatiques
- **Audit de sécurité** avec des niveaux CRITIQUE, ÉLEVÉ et NORMAL, et le *pourquoi* de chaque problème
- **Docker** installé et durci sur les VPS neufs, laissé intact sur les serveurs existants
- Clés gérées depuis un seul dossier sur ton Mac et envoyées sur tous tes VPS en une commande

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/FabienDebouse/vps/main/install.sh | bash
```

L'installateur te demande le nom d'utilisateur à créer sur tes serveurs, crée ta clé SSH si tu n'en as pas, et prépare `~/.ssh/config`. Ouvre ensuite un nouveau terminal.

> Tu préfères lire avant d'exécuter ? Télécharge [install.sh](install.sh), lis-le, puis lance `bash install.sh`.

## Utilisation

```bash
vps
```

```
Que veux-tu faire ?
  1) Sécuriser un nouveau VPS
  2) Sécuriser un VPS déjà en production
  3) Audit de sécurité
  4) Voir mes VPS
  5) Voir les clés autorisées
  6) Autoriser une nouvelle clé
  7) Retirer une clé
  8) Renvoyer les clés sur tous les VPS
  9) Rejouer la sécurisation sur tous les VPS
  u) Mettre à jour l'outil
```

Réponds aux questions. Le mot de passe du serveur est demandé **une seule fois**. Ensuite :

```bash
ssh web1
```

## VPS neuf ou VPS en production ?

| | **1) VPS neuf** (`vps add`) | **2) VPS en production** (`vps adopt`) |
|---|---|---|
| Audit avant de toucher à quoi que ce soit | non | **oui**, affiché en entier |
| SSH par clé, root interdit | oui | oui, avec la liste des **comptes à garder** (ex. `deploy`) |
| Pare-feu | SSH, 80, 443 | SSH, 80, 443 + **les ports que tu choisis**, un par un |
| Docker | installé et durci | **jamais touché** : aucun conteneur arrêté ni modifié |
| Mises à jour complètes | oui | seulement si tu le demandes |
| Confirmation finale | oui | oui, avec un **récapitulatif**, et *non* par défaut |

**Rien n'est jamais supprimé** : ni conteneur, ni image, ni volume, ni donnée.

Pour un serveur en production, `vps adopt` :
1. lance l'audit, en lecture seule ;
2. te montre chaque port ouvert (« Port 3000 (python3) : le garder joignable depuis Internet ? »). Pour une base de données, la réponse proposée par défaut est *non* ;
3. repère les comptes qui se connectent en SSH (« Le compte deploy, connecté par clé hier : lui garder l'accès ? »), et prévient si root ou un compte utilise encore un mot de passe ;
4. affiche le récapitulatif et attend ton *oui* ;
5. sécurise le serveur, vérifie l'accès, puis relance l'audit : `Avant : 3 critiques → Après : 1 critique`.

> Fais un **snapshot** chez ton hébergeur avant d'adopter un serveur en production.

## Audit de sécurité

```bash
vps audit              # tous tes VPS
vps audit web1         # un seul
vps audit root@1.2.3.4 # un serveur pas encore ajouté (lecture seule)
```

Chaque problème est classé et **expliqué** :

```
 CRITIQUE  PostgreSQL joignable depuis Internet (port 5432)
   Pourquoi : Le conteneur « app-db-1 » (projet Compose « app », service « db »,
              fichier /srv/app/docker-compose.yml) publie le port sur toutes les
              interfaces. Docker ouvre lui-même ce port dans le pare-feu : UFW ne le
              bloque pas. Connexions en ce moment : 1, depuis 203.0.113.5.
   À faire  : Dans /srv/app/docker-compose.yml, service « db » : remplace
              « 5432:5432 » par « 127.0.0.1:5432:5432 »...
```

| Niveau | Exemples |
|---|---|
| **CRITIQUE** | base de données (PostgreSQL, MySQL, Redis, MongoDB…) ou API Docker joignable depuis Internet, root avec mot de passe, système sans correctifs, compte root caché |
| **ÉLEVÉ** | pas de pare-feu, mots de passe SSH autorisés, mises à jour de sécurité en attente, interface d'admin exposée, conteneur privilégié, `.env` lisible par tous, compte dans le groupe docker |
| **NORMAL** | port inconnu ouvert, root par clé, mises à jour automatiques désactivées, redémarrage nécessaire, connexions SSH récentes à vérifier |

Pour chaque base de données exposée, l'audit dit **qui l'expose** (quel conteneur et quel fichier Compose, ou quel programme et quelle ligne de configuration) et **qui y est connecté en ce moment**.

Les rapports sont enregistrés dans `~/.vps/audits/`. `vps audit` renvoie le code 2 s'il trouve un problème critique, ce qui permet de l'utiliser dans un script.

## Toutes les commandes

| Commande | Effet |
|---|---|
| `vps add` | sécurise un VPS neuf (questions) |
| `vps add web1 203.0.113.10 [--user debian] [--port 22] [--no-docker]` | pareil, sans questions |
| `vps adopt` | sécurise un VPS déjà en production (questions) |
| `vps audit [nom…\|compte@ip]` | audit de sécurité, sans rien modifier |
| `vps list` | liste tes VPS (neuf / existant) |
| `vps keys` | liste les clés autorisées |
| `vps addkey ~/autre-mac.pub` | autorise une clé, puis propose de l'envoyer partout |
| `vps delkey autre-mac` | retire une clé, puis propose de mettre à jour partout |
| `vps sync` | renvoie la liste des clés sur tous les VPS |
| `vps apply` | rejoue la sécurisation partout (en gardant les choix faits à l'adoption) |
| `vps rm web1` | supprime le raccourci (le serveur n'est pas modifié) |
| `vps update` | installe la dernière version de l'outil |

## Comment ça marche

```
~/.vps/
├── bin/          l'outil, le script de sécurisation et le script d'audit
├── keys/         une clé publique par appareil autorisé (.pub)
├── hosts/        un raccourci SSH par VPS (inclus dans ~/.ssh/config)
├── audits/       les rapports d'audit
└── config        ton nom d'utilisateur sur les VPS
```

- **Le dossier `keys/` fait foi.** `vps sync` remplace la liste des clés de ton compte sur chaque serveur par le contenu de ce dossier. Retirer un fichier puis lancer `vps sync`, c'est révoquer cet appareil partout.
- **Tu ne peux pas te bloquer dehors :** `vps sync` refuse de tourner si la clé de ce Mac n'est pas dans la liste, et `vps delkey` refuse de la retirer.
- Les scripts sont envoyés et exécutés en root à travers une seule connexion SSH, puis l'accès est vérifié.
- Ton utilisateur a `sudo` **sans mot de passe** : l'accès est déjà protégé par ta clé. Pour en exiger un, mets `SUDO_NOPASSWD=0` dans le script.

## Bon à savoir

- **Fail2ban** compte toutes les tentatives ratées, pas seulement les mots de passe (qui sont désactivés) :
  - ton vrai nom d'utilisateur avec une mauvaise clé : banni à la **5ᵉ** erreur ;
  - root ou un nom inexistant (les robots) : chaque essai compte double, banni dès la **3ᵉ**.

  À l'installation, il relit les 10 dernières minutes : une adresse qui vient d'échouer plusieurs fois est bannie tout de suite.
- **Docker contourne UFW** pour les ports publiés. Sur un VPS neuf, Docker est configuré pour que `-p 8080:80` n'écoute que sur `127.0.0.1`. Sur un serveur existant, l'audit liste les ports Docker publics et la ligne à changer. Voir [examples/](examples/) pour une stack Caddy + app + Postgres durcie.
- Active aussi le **pare-feu de ton hébergeur** (SSH, 80 et 443) : il filtre avant même que le trafic n'atteigne le VPS.
- Les scripts sont **rejouables** : `vps apply` réécrit les mêmes réglages, sans rien casser.

## Testé

Testé de bout en bout sur Debian 12 (conteneurs systemd) :
- **VPS neuf** : ajout, raccourci SSH, refus de root et des mots de passe, UFW, bannissement Fail2ban mesuré, Docker (sortie Internet, ports sur `127.0.0.1` par défaut), `vps sync` et `vps apply`.
- **VPS en production**, volontairement mal configuré (root avec mot de passe, PostgreSQL publié par Docker, Redis ouvert, app sur le port 3000, compte `deploy`) :
  - l'audit trouve les 3 problèmes critiques et la connexion en cours à la base ;
  - `vps adopt` garde l'app et `deploy`, ferme Redis, refuse root, ne redémarre aucun conteneur, et `vps apply` rejoue les mêmes choix.

Prévu pour **macOS** côté client (trousseau, `~/.zshrc`) et **Debian 12** côté serveur. L'audit fonctionne aussi sur Debian 11/13 et Ubuntu.
