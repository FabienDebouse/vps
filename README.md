# vps

Sécurise tes VPS **Debian 12** en une commande depuis ton Mac, puis connecte-toi avec un simple `ssh web1`.

- Connexion **par clé SSH uniquement** : root et mots de passe interdits
- **UFW** : tout est fermé sauf SSH, 80 et 443
- **Fail2ban** : 5 échecs en 10 minutes = banni 1 heure
- **Mises à jour de sécurité** automatiques
- **Docker** installé et durci (optionnel)
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

Un menu s'affiche et te pose les questions :

```
Que veux-tu faire ?
  1) Sécuriser un nouveau VPS
  2) Voir mes VPS
  3) Voir les clés autorisées
  4) Autoriser une nouvelle clé
  5) Retirer une clé
  6) Renvoyer les clés sur tous les VPS
  7) Rejouer la sécurisation sur tous les VPS
  8) Mettre à jour l'outil
```

Pour sécuriser un nouveau VPS, choisis **1** et réponds aux questions (nom, IP, compte fourni par l'hébergeur, port, Docker). Le mot de passe root de l'hébergeur est demandé **une seule fois**. Ensuite :

```bash
ssh web1
```

### Les mêmes actions en ligne de commande

| Commande | Effet |
|---|---|
| `vps add` | sécurise un nouveau VPS (questions) |
| `vps add web1 203.0.113.10` | pareil, sans questions |
| `vps add web2 203.0.113.11 --user debian --no-docker` | hébergeur qui fournit un compte `debian` (OVH), sans Docker |
| `vps list` | liste tes VPS |
| `vps keys` | liste les clés autorisées |
| `vps addkey ~/autre-mac.pub` | autorise une clé, puis propose de l'envoyer partout |
| `vps delkey autre-mac` | retire une clé, puis propose de mettre à jour partout |
| `vps sync` | renvoie la liste des clés sur tous les VPS |
| `vps apply` | rejoue la sécurisation sur tous les VPS |
| `vps rm web1` | supprime le raccourci (le serveur n'est pas modifié) |
| `vps update` | installe la dernière version de l'outil |

## Comment ça marche

```
~/.vps/
├── bin/          l'outil et le script envoyé aux serveurs
├── keys/         une clé publique par appareil autorisé (.pub)
├── hosts/        un raccourci SSH par VPS (inclus dans ~/.ssh/config)
└── config        ton nom d'utilisateur sur les VPS
```

- **Le dossier `keys/` fait foi.** `vps sync` remplace la liste des clés de chaque serveur par le contenu de ce dossier. Retirer un fichier et lancer `vps sync`, c'est révoquer cet appareil partout.
- **Tu ne peux pas te bloquer dehors :** `vps sync` refuse de tourner si la clé de ce Mac n'est pas dans la liste, et `vps delkey` refuse de la retirer.
- **Une seule connexion** pour sécuriser un serveur : le script [harden-debian12.sh](harden-debian12.sh) est envoyé et exécuté en root, puis vérifié.
- Ton utilisateur a `sudo` **sans mot de passe** : l'accès est déjà protégé par ta clé, et gérer un mot de passe sudo par serveur serait ingérable. Pour en exiger un, mets `SUDO_NOPASSWD=0` dans le script.

## Bon à savoir

- **Fail2ban** compte toutes les tentatives ratées, pas seulement les mots de passe (qui sont désactivés) :
  - ton vrai nom d'utilisateur avec une mauvaise clé : banni à la **5ᵉ** erreur ;
  - root ou un nom inexistant (les robots) : chaque essai compte double, banni dès la **3ᵉ**.
- **Docker contourne UFW** pour les ports publiés. Le script configure Docker pour que `-p 8080:80` n'écoute que sur `127.0.0.1`. Pour exposer un port à Internet, écris-le explicitement : `-p 0.0.0.0:443:443`. Voir [examples/](examples/) pour une stack Caddy + app + Postgres durcie.
- Active aussi le **pare-feu de ton hébergeur** (SSH, 80 et 443) : il filtre avant même que le trafic n'atteigne le VPS.
- Le script est **rejouable** : `vps apply` réécrit les mêmes réglages, sans rien casser.

## Testé

Testé de bout en bout sur Debian 12 (conteneur systemd) : ajout d'un VPS, connexion par le raccourci, refus de root et des mots de passe, UFW, bannissement Fail2ban mesuré, Docker (sortie Internet, ports sur `127.0.0.1` par défaut), `vps sync` et `vps apply`.

Prévu pour **macOS** côté client (trousseau, `~/.zshrc`) et **Debian 12** côté serveur.
