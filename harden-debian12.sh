#!/usr/bin/env bash
# Durcissement d'un VPS Debian 12 qui fait tourner des apps sous Docker.
#
# Normalement lancé par l'outil `vps` depuis le Mac (vps add / vps adopt / vps apply).
# Usage manuel, en root :
#   NEW_USER=fabien AUTHORIZED_KEYS_B64="$(base64 < keys.txt)" bash harden-debian12.sh
#
# Si AUTHORIZED_KEYS_B64 est vide, les clés de /root/.ssh/authorized_keys sont reprises.
# Le script est rejouable : le relancer réécrit les mêmes fichiers.
# Il ne supprime jamais de conteneur, d'image, de volume ni de données.
set -euo pipefail

NEW_USER="${NEW_USER:-}"
AUTHORIZED_KEYS_B64="${AUTHORIZED_KEYS_B64:-}"
SSH_PORT="${SSH_PORT:-22}"
SUDO_NOPASSWD="${SUDO_NOPASSWD:-1}"          # 1 = sudo sans mot de passe (l'accès est déjà protégé par la clé)
INSTALL_DOCKER="${INSTALL_DOCKER:-1}"
DOCKER_DAEMON_CONFIG="${DOCKER_DAEMON_CONFIG:-1}"  # 0 = ne pas toucher à la config Docker (serveur existant)
APT_UPGRADE="${APT_UPGRADE:-1}"              # 0 = installer seulement le nécessaire, sans tout mettre à jour
EXTRA_PORTS="${EXTRA_PORTS:-}"               # ports à garder ouverts en plus, ex. "3000/tcp 8080/tcp"
EXTRA_SSH_USERS="${EXTRA_SSH_USERS:-}"       # autres comptes qui gardent l'accès SSH (par clé), ex. "deploy"
ROOT_LOGIN="${ROOT_LOGIN:-no}"               # no = root interdit, key = root par clé seulement
BAN_MAXRETRY="${BAN_MAXRETRY:-5}"            # échecs autorisés...
BAN_FINDTIME="${BAN_FINDTIME:-10m}"          # ...dans cette fenêtre...
BAN_TIME="${BAN_TIME:-1h}"                   # ...avant un bannissement de cette durée
AUTO_REBOOT="${AUTO_REBOOT:-false}"          # true = redémarre seul si une MAJ noyau l'exige
AUTO_REBOOT_TIME="${AUTO_REBOOT_TIME:-04:00}"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "À lancer en root (ou avec sudo)."
# shellcheck source=/dev/null
. /etc/os-release
[[ "${ID:-}" == debian && "${VERSION_ID:-}" == 12 ]] \
  || die "Script prévu pour Debian 12 (détecté : ${PRETTY_NAME:-inconnu})."
[[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "NEW_USER manquant ou invalide : '$NEW_USER'."
[[ "$NEW_USER" != root ]] || die "NEW_USER ne peut pas être root."
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] || die "SSH_PORT invalide : $SSH_PORT"
for p in $EXTRA_PORTS; do
  [[ "$p" =~ ^[0-9]+(/(tcp|udp))?$ ]] || die "Port invalide dans EXTRA_PORTS : $p"
done
for u in $EXTRA_SSH_USERS; do
  [[ "$u" =~ ^[a-z_][a-z0-9_.-]*$ && "$u" != root ]] || die "Compte invalide dans EXTRA_SSH_USERS : $u"
done
[[ "$ROOT_LOGIN" == no || "$ROOT_LOGIN" == key ]] || die "ROOT_LOGIN doit valoir no ou key."

# --- 1. Paquets -------------------------------------------------------------
log "Paquets de base"
export DEBIAN_FRONTEND=noninteractive
apt_opts=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
apt-get update
if [[ "$APT_UPGRADE" == 1 ]]; then
  apt-get "${apt_opts[@]}" upgrade
else
  echo "Mise à jour complète ignorée : les mises à jour de sécurité se feront automatiquement chaque nuit."
fi
apt-get "${apt_opts[@]}" install sudo ufw fail2ban python3-systemd unattended-upgrades \
  ca-certificates curl

# --- 2. Utilisateur d'administration ----------------------------------------
log "Utilisateur $NEW_USER"
if ! id "$NEW_USER" &>/dev/null; then
  adduser --disabled-password --gecos "" "$NEW_USER"
fi
usermod -aG sudo "$NEW_USER"
group=$(id -gn "$NEW_USER")
home=$(getent passwd "$NEW_USER" | cut -d: -f6)
auth="$home/.ssh/authorized_keys"
install -d -m 700 -o "$NEW_USER" -g "$group" "$home/.ssh"
if [[ -n "$AUTHORIZED_KEYS_B64" ]]; then
  # La liste envoyée remplace entièrement l'ancienne : c'est le Mac qui fait foi.
  printf '%s' "$AUTHORIZED_KEYS_B64" | base64 -d > "$auth.new"
  mv "$auth.new" "$auth"
elif [[ ! -s "$auth" && -s /root/.ssh/authorized_keys ]]; then
  # On ne garde que les lignes sans options (évite les command="..." qui bloquent root).
  grep -E '^(ssh-|ecdsa-|sk-)' /root/.ssh/authorized_keys > "$auth" || true
  echo "Clés reprises depuis /root/.ssh/authorized_keys"
fi
touch "$auth"
chown "$NEW_USER:$group" "$auth"
chmod 600 "$auth"
grep -qE '^(ssh-|ecdsa-|sk-)' "$auth" \
  || die "Aucune clé SSH dans $auth : j'arrête avant de couper l'accès par mot de passe."
echo "$(grep -cE '^(ssh-|ecdsa-|sk-)' "$auth") clé(s) autorisée(s) pour $NEW_USER"

sudoers="/etc/sudoers.d/90-$NEW_USER"
if [[ "$SUDO_NOPASSWD" == 1 ]]; then
  echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" > "$sudoers"
  chmod 440 "$sudoers"
  visudo -cf "$sudoers" >/dev/null || { rm -f "$sudoers"; die "Règle sudo invalide, retirée."; }
else
  rm -f "$sudoers"
  if passwd -S "$NEW_USER" | awk '{exit !($2=="L" || $2=="NP")}'; then
    warn "$NEW_USER n'a pas de mot de passe : sudo ne marchera pas. Lance 'passwd $NEW_USER'."
  fi
fi

# --- 3. SSH -----------------------------------------------------------------
allow_users="$NEW_USER $EXTRA_SSH_USERS"
root_rule=no
if [[ "$ROOT_LOGIN" == key ]]; then
  allow_users="$allow_users root"
  root_rule=prohibit-password
fi
allow_users=$(echo $allow_users)  # espaces superflus
log "SSH : clé uniquement, port $SSH_PORT, comptes autorisés : $allow_users"
grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config \
  || die "sshd_config n'inclut pas sshd_config.d/*.conf : à vérifier à la main."
sshd_dropin=/etc/ssh/sshd_config.d/00-hardening.conf
cat > "$sshd_dropin" <<EOF
# Généré par harden-debian12.sh.
# Pour sshd, la première valeur lue gagne : ce fichier (00-) prime donc sur
# 50-cloud-init.conf et sur le reste de sshd_config.
Port $SSH_PORT
PermitRootLogin $root_rule
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PubkeyAuthentication yes
AuthenticationMethods publickey
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
AllowAgentForwarding no
# "local" garde les tunnels ssh -L (pratique pour atteindre une base en 127.0.0.1).
AllowTcpForwarding local
ClientAliveInterval 300
ClientAliveCountMax 2
AllowUsers $allow_users
EOF
sshd -t || { rm -f "$sshd_dropin"; die "Config SSH invalide : fichier retiré, SSH inchangé."; }

# --- 4. Pare-feu ------------------------------------------------------------
log "Pare-feu UFW : tout fermé sauf SSH, 80, 443${EXTRA_PORTS:+ et $EXTRA_PORTS}"
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT/tcp" comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw allow 443/udp comment 'HTTP/3'
for p in $EXTRA_PORTS; do
  ufw allow "$p" comment 'vps: port garde'
done
if [[ "$SSH_PORT" != 22 ]]; then
  ufw delete allow 22/tcp >/dev/null 2>&1 || true
fi
ufw --force enable

# Le port est ouvert dans UFW, on peut appliquer la config SSH.
# Les sessions déjà ouvertes survivent au redémarrage.
systemctl restart ssh

# --- 5. Fail2ban ------------------------------------------------------------
log "Fail2ban : $BAN_MAXRETRY échecs en $BAN_FINDTIME = banni $BAN_TIME"
# Fichier à part, chargé en dernier : les autres prisons (nginx...) d'un serveur
# existant et leurs réglages par défaut restent intacts.
if grep -q "Debian 12 n'a pas de /var/log/auth.log" /etc/fail2ban/jail.local 2>/dev/null; then
  rm -f /etc/fail2ban/jail.local  # écrit par une ancienne version de ce script
fi
cat > /etc/fail2ban/jail.d/zz-vps.local <<EOF
[sshd]
enabled = true
port = $SSH_PORT
# Debian 12 n'a pas de /var/log/auth.log par défaut : on lit le journal systemd.
backend = systemd
bantime = $BAN_TIME
findtime = $BAN_FINDTIME
maxretry = $BAN_MAXRETRY
# Les mots de passe sont désactivés : "aggressive" compte aussi les mauvaises clés.
# Mesuré sur Debian 12 : bon utilisateur + mauvaise clé = banni à la 5e erreur ;
# root ou utilisateur inexistant = 2 lignes par tentative, donc banni dès la 3e.
# (En mode "normal", les mauvaises clés sur un vrai utilisateur ne sont jamais comptées.)
mode = aggressive
EOF
systemctl enable fail2ban
systemctl restart fail2ban

# --- 6. Mises à jour de sécurité automatiques -------------------------------
log "Mises à jour automatiques"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
cat > /etc/apt/apt.conf.d/52unattended-upgrades-local <<EOF
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "$AUTO_REBOOT";
Unattended-Upgrade::Automatic-Reboot-Time "$AUTO_REBOOT_TIME";
EOF
systemctl enable --now unattended-upgrades

# --- 7. Noyau (sysctl) ------------------------------------------------------
log "Paramètres noyau"
# Ne pas toucher à net.ipv4.ip_forward : Docker en a besoin.
cat > /etc/sysctl.d/99-hardening.conf <<EOF
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.suid_dumpable = 0
EOF
sysctl --system >/dev/null || warn "Certains paramètres sysctl n'ont pas été appliqués."

# --- 8. Docker --------------------------------------------------------------
if [[ "$INSTALL_DOCKER" == 1 ]] && ! command -v docker &>/dev/null; then
  log "Installation de Docker (dépôt officiel)"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $VERSION_CODENAME stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get "${apt_opts[@]}" install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

if [[ "$DOCKER_DAEMON_CONFIG" != 1 ]] && command -v docker &>/dev/null; then
  log "Docker : configuration laissée telle quelle (serveur existant)"
elif command -v docker &>/dev/null; then
  log "Configuration du démon Docker"
  # "ip": les ports publiés avec -p 8080:80 écoutent sur 127.0.0.1 par défaut.
  # Pour exposer un port à Internet, il faut l'écrire explicitement : "0.0.0.0:443:443".
  daemon_json='{
  "ip": "127.0.0.1",
  "icc": false,
  "no-new-privileges": true,
  "live-restore": true,
  "userland-proxy": false,
  "log-driver": "local",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}'
  install -d /etc/docker
  if [[ -s /etc/docker/daemon.json ]]; then
    if [[ "$(cat /etc/docker/daemon.json)" != "$daemon_json" ]]; then
      echo "$daemon_json" > /etc/docker/daemon.json.recommended
      warn "/etc/docker/daemon.json existe déjà, je n'y touche pas. Config recommandée : /etc/docker/daemon.json.recommended (à fusionner à la main)."
    fi
  else
    echo "$daemon_json" > /etc/docker/daemon.json
    if [[ -z "$(docker ps -q 2>/dev/null)" ]]; then
      systemctl restart docker
    else
      warn "Des conteneurs tournent : redémarre Docker pendant une fenêtre de maintenance (systemctl restart docker), puis recrée-les (docker compose up -d --force-recreate)."
    fi
  fi
  if id -nG "$NEW_USER" | grep -qw docker; then
    warn "$NEW_USER est dans le groupe docker : ça équivaut à un accès root. Préfère 'sudo docker'."
  fi
fi

# --- 9. Bilan ---------------------------------------------------------------
log "Terminé"
echo "Ports qui écoutent ailleurs que sur localhost :"
ss -tulnH | awk '$5 !~ /^(127\.|\[::1\])/ {print "  " $1 "  " $5}'
if command -v docker &>/dev/null; then
  echo "Ports publiés par Docker (ATTENTION : ils contournent UFW s'ils ne sont pas sur 127.0.0.1) :"
  docker ps --format '  {{.Names}}  {{.Ports}}' | grep -v '^  [^ ]*  $' || echo "  aucun"
fi
latest_kernel=$(find /boot -maxdepth 1 -name 'vmlinuz-*' 2>/dev/null | sort -V | tail -n1 || true)
if [[ -n "$latest_kernel" && "$latest_kernel" != "/boot/vmlinuz-$(uname -r)" ]]; then
  warn "Le noyau a été mis à jour : redémarre le VPS (sudo reboot)."
fi
