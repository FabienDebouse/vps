#!/usr/bin/env bash
# Audit de sécurité d'un serveur Debian ou Ubuntu, en LECTURE SEULE : ne modifie rien.
# Lancé en root par « vps audit » et « vps adopt ».
#
# Sortie : une ligne par élément, champs séparés par « | » :
#   F|niveau|catégorie|titre|pourquoi|à faire     niveau : CRITIQUE, ELEVE, NORMAL ou OK
#   P|proto|port|exposition|origine|service|type|joignable|docker
#                                                  port écouté ailleurs que sur localhost
#   U|compte|méthode|dernière connexion|ip         connexions SSH réussies (30 derniers jours)
#   K|compte|nombre de clés                        comptes qui ont des clés SSH autorisées
set -uo pipefail
export LC_ALL=C

clean() { printf '%s' "$*" | tr '|\n' '/ '; }
finding() { printf 'F|%s|%s|%s|%s|%s\n' "$1" "$2" "$(clean "$3")" "$(clean "${4:-}")" "$(clean "${5:-}")"; }

if [[ $EUID -ne 0 ]]; then
  finding CRITIQUE audit "Audit lancé sans les droits root" "" \
    "Connecte-toi en root, ou avec un compte qui a sudo sans mot de passe."
  exit 1
fi

# --- Système ----------------------------------------------------------------
# shellcheck source=/dev/null
. /etc/os-release
case "${ID:-}:${VERSION_ID:-}" in
  debian:12|debian:13|ubuntu:22.04|ubuntu:24.04|ubuntu:26.04)
    finding OK systeme "${PRETTY_NAME:-?} : version qui reçoit encore les correctifs de sécurité" ;;
  debian:[0-9]|debian:1[01]|ubuntu:1[0-9].*|ubuntu:20.04)
    finding CRITIQUE systeme "${PRETTY_NAME:-?} ne reçoit plus de correctifs de sécurité" \
      "Toutes les failles découvertes depuis la fin du support restent ouvertes, pour toujours." \
      "Migrer vers Debian 12 (le plus simple : un VPS neuf, puis y redéployer les services)." ;;
  *)
    finding NORMAL systeme "Système non reconnu par l'audit : ${PRETTY_NAME:-?}" \
      "Les vérifications sont prévues pour Debian et Ubuntu." "" ;;
esac

if command -v apt >/dev/null; then
  lists_date=$(find /var/lib/apt/lists -maxdepth 1 -name '*Release' -printf '%TY-%Tm-%Td\n' 2>/dev/null | sort | tail -n1)
  upgradable=$(apt list --upgradable 2>/dev/null)
  sec=$(grep -c -- '-security' <<<"$upgradable" || true)
  all=$(grep -c 'upgradable from' <<<"$upgradable" || true)
  if [[ -z "$lists_date" ]]; then
    finding NORMAL mises-a-jour "Impossible de savoir s'il manque des mises à jour" \
      "La liste des paquets n'a jamais été téléchargée sur ce serveur." "sudo apt update, puis relancer l'audit."
  elif ((sec > 0)); then
    finding ELEVE mises-a-jour "$sec mise(s) à jour de sécurité en attente (liste apt du ${lists_date:-?})" \
      "Ces failles sont connues et déjà corrigées par Debian, mais pas encore sur ce serveur." \
      "sudo apt update && sudo apt upgrade, ou activer les mises à jour automatiques (vps adopt)."
  elif ((all > 0)); then
    finding NORMAL mises-a-jour "$all mise(s) à jour disponible(s), aucune de sécurité (liste apt du ${lists_date:-?})" "" \
      "sudo apt update && sudo apt upgrade quand ça t'arrange."
  else
    finding OK mises-a-jour "Paquets à jour (d'après la liste apt du ${lists_date:-?})"
  fi
  if [[ "$(apt-config dump 2>/dev/null | sed -n 's/^APT::Periodic::Unattended-Upgrade "\(.*\)";/\1/p')" == 1 ]] \
     && dpkg -s unattended-upgrades >/dev/null 2>&1; then
    finding OK mises-a-jour "Mises à jour de sécurité automatiques activées"
  else
    finding NORMAL mises-a-jour "Mises à jour de sécurité automatiques désactivées" \
      "Chaque faille corrigée par Debian reste ouverte tant que personne ne met à jour à la main." \
      "vps adopt les active (sans redémarrage automatique)."
  fi
fi

latest_kernel=$(find /boot -maxdepth 1 -name 'vmlinuz-*' 2>/dev/null | sort -V | tail -n1 || true)
if [[ -n "$latest_kernel" && "$latest_kernel" != "/boot/vmlinuz-$(uname -r)" ]]; then
  finding NORMAL systeme "Redémarrage nécessaire : un noyau plus récent est installé" \
    "Les correctifs du noyau ne s'appliquent qu'après un redémarrage." "sudo reboot, à un moment calme."
fi

# --- Comptes ----------------------------------------------------------------
uid0=$(awk -F: '$3 == 0 && $1 != "root" {print $1}' /etc/passwd | paste -sd, -)
[[ -n "$uid0" ]] && finding CRITIQUE comptes "Comptes avec les droits root cachés : $uid0" \
  "Un UID 0 donne exactement les droits de root. C'est une technique classique de porte dérobée." \
  "Vérifier qui a créé ce compte et pourquoi, puis le supprimer."
nopass=$(awk -F: '$2 == "" {print $1}' /etc/shadow 2>/dev/null | paste -sd, -)
[[ -n "$nopass" ]] && finding CRITIQUE comptes "Comptes sans mot de passe : $nopass" \
  "Ces comptes s'ouvrent sans rien taper si un service les accepte." "sudo passwd -l <compte>"
docker_members=$(getent group docker 2>/dev/null | cut -d: -f4)
[[ -n "$docker_members" ]] && finding ELEVE comptes "Comptes dans le groupe docker : $docker_members" \
  "Être dans le groupe docker revient à être root, sans mot de passe." \
  "sudo gpasswd -d <compte> docker, puis utiliser « sudo docker »."

while IFS=: read -r user _ _ _ _ home _; do
  [[ -f "$home/.ssh/authorized_keys" ]] || continue
  n=$(grep -cE '^[^#]*(ssh-|ecdsa-|sk-)' "$home/.ssh/authorized_keys" 2>/dev/null || true)
  ((n > 0)) && echo "K|$user|$n"
done < /etc/passwd

# --- SSH --------------------------------------------------------------------
sshd_journal() { journalctl _COMM=sshd --since "$1" --no-pager -o short-iso 2>/dev/null; cat /var/log/auth.log 2>/dev/null; }

pw_on=no
if command -v sshd >/dev/null; then
  sshd_conf=$(sshd -T 2>/dev/null)
  sget() { awk -v k="$1" '$1 == k {print $2; exit}' <<<"$sshd_conf"; }
  root_login=$(sget permitrootlogin)
  [[ "$(sget passwordauthentication)" == yes || "$(sget kbdinteractiveauthentication)" == yes ]] && pw_on=yes
  fails=$(sshd_journal "24 hours ago" | grep -cE 'Failed password|Invalid user|authentication failure' || true)
  attack=""
  ((fails > 0)) && attack=" $fails tentatives ratées ces dernières 24 h : des robots essaient en ce moment."

  [[ "$(sget permitemptypasswords)" == yes ]] && finding CRITIQUE ssh "SSH accepte les mots de passe vides" \
    "Un compte sans mot de passe s'ouvre à distance sans rien taper." "vps adopt : connexion par clé uniquement."
  if [[ "$root_login" == yes && $pw_on == yes ]]; then
    finding CRITIQUE ssh "Root peut se connecter avec un mot de passe" \
      "Les robots essaient des mots de passe root en permanence.$attack Un seul mot de passe deviné et le serveur est perdu." \
      "vps adopt : connexion par clé uniquement, root interdit."
  elif [[ $pw_on == yes ]]; then
    finding ELEVE ssh "Connexion SSH par mot de passe autorisée" \
      "Un mot de passe se devine ou se vole, une clé non.$attack" "vps adopt : connexion par clé uniquement."
  else
    finding OK ssh "SSH : connexion par clé uniquement"
  fi
  case "$root_login" in
    no) finding OK ssh "Connexion root interdite" ;;
    forced-commands-only) finding OK ssh "Root limité à des commandes précises" ;;
    *) [[ $pw_on == no ]] && finding NORMAL ssh "Root peut se connecter par clé" \
         "Une clé root volée donne tout le serveur d'un coup, sans passer par un compte normal." \
         "Se connecter avec un compte normal + sudo (vps adopt)." ;;
  esac

  # ADMIN_IP (passé par vps) : ta propre adresse, pour ne pas compter tes connexions.
  logins=$(sshd_journal "30 days ago" \
    | sed -nE 's/^([0-9]{4}-[0-9]{2}-[0-9]{2})T[^ ]* .* Accepted ([a-z-]+) for ([^ ]+) from ([^ ]+) .*/\3|\2|\1|\4/p' \
    | awk -F'|' -v me="${ADMIN_IP:-}" '$4 != me { last[$1 "|" $2] = $3 "|" $4 } END { for (k in last) print "U|" k "|" last[k] }')
  if [[ -n "$logins" ]]; then
    echo "$logins"
    finding NORMAL ssh "Connexions SSH réussies ces 30 derniers jours (hors les tiennes)" \
      "$(awk -F'|' '{ printf "%s%s par %s le %s depuis %s", (NR > 1 ? " ; " : ""), $2, ($3 == "publickey" ? "clé" : "mot de passe"), $4, $5 }' <<<"$logins")." \
      "Vérifie que tu reconnais chaque compte et chaque adresse."
  fi
fi

protection=""
for svc in fail2ban crowdsec; do
  systemctl is-active --quiet "$svc" 2>/dev/null && protection=$svc
done
if [[ -n "$protection" ]]; then
  finding OK ssh "Protection contre les attaques par force brute : $protection"
elif [[ $pw_on == yes ]]; then
  finding ELEVE ssh "Aucune protection contre les attaques par force brute" \
    "Un robot peut essayer des mots de passe sans limite." "vps adopt installe Fail2ban (5 échecs = 1 h de ban)."
else
  finding NORMAL ssh "Aucune protection contre les attaques par force brute" \
    "Moins grave avec des clés, mais les tentatives remplissent les journaux et occupent le serveur." \
    "vps adopt installe Fail2ban (5 échecs = 1 h de ban)."
fi

# --- Pare-feu ---------------------------------------------------------------
fw=none
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
  fw=ufw
  ufw status verbose 2>/dev/null | grep -q 'allow (incoming)' && fw=ufw-open
elif iptables -S INPUT 2>/dev/null | grep -qE '^-P INPUT (DROP|REJECT)'; then
  fw=iptables
elif nft list ruleset 2>/dev/null | grep -qE 'hook input .*policy drop'; then
  fw=nftables
fi
case $fw in
  ufw) finding OK pare-feu "Pare-feu UFW actif (entrées refusées par défaut)" ;;
  ufw-open) finding ELEVE pare-feu "UFW est actif mais laisse tout entrer par défaut" \
    "Tout programme qui écoute sur le réseau est joignable depuis Internet." "sudo ufw default deny incoming (vps adopt le fait)." ;;
  iptables|nftables) finding OK pare-feu "Pare-feu $fw actif (hors UFW)" ;;
  none) finding ELEVE pare-feu "Aucun pare-feu actif" \
    "Tout programme qui écoute sur le réseau est joignable depuis Internet, même par erreur." \
    "vps adopt active UFW en gardant les ports que tu choisis." ;;
esac

# Vrai si le pare-feu laisse passer ce port ($1) / protocole ($2) depuis Internet.
reachable() {
  case $fw in
    none|ufw-open|nftables) return 0 ;;
    iptables) iptables -S INPUT 2>/dev/null | grep -qE -- "--dport $1( |$).*-j ACCEPT" ;;
    ufw) ufw status 2>/dev/null | sed 's/ (v6)//g' | awk -v p="$1" -v pr="$2" '
           $2 == "ALLOW" && $3 == "Anywhere" {
             split($1, a, "/"); if (a[2] != "" && a[2] != pr) next
             n = split(a[1], list, ",")
             for (i = 1; i <= n; i++) {
               if (split(list[i], r, ":") == 2) { if (p >= r[1] && p <= r[2]) ok = 1 }
               else if (list[i] == p) ok = 1
             }
           }
           END { exit !ok }' ;;
  esac
}

fw_reason() {
  case $fw in
    none) echo "aucun pare-feu ne le bloque" ;;
    ufw|ufw-open) echo "UFW laisse passer ce port" ;;
    *) echo "le pare-feu ne le bloque pas" ;;
  esac
}

# --- Ports ouverts ----------------------------------------------------------
# « Libellé|type » d'un service, d'après le nom du programme ou de l'image ($2), sinon le port ($1).
service_of() {
  local hint
  hint=$(tr '[:upper:]' '[:lower:]' <<<"${2:-}")
  case $hint in
    *postgres*|*postgis*|*timescale*) echo "PostgreSQL|db" ;;
    *mysql*|*mariadb*) echo "MySQL/MariaDB|db" ;;
    *mongo*) echo "MongoDB|db" ;;
    *redis*|*valkey*|*keydb*) echo "Redis|db" ;;
    *elasticsearch*|*opensearch*) echo "Elasticsearch|db" ;;
    *memcached*) echo "Memcached|db" ;;
    *clickhouse*) echo "ClickHouse|db" ;;
    *influx*) echo "InfluxDB|db" ;;
    *couchdb*) echo "CouchDB|db" ;;
    *phpmyadmin*|*adminer*|*pgadmin*) echo "Interface d'admin de base de données|admin" ;;
    *portainer*) echo "Portainer|admin" ;;
    *grafana*) echo "Grafana|admin" ;;
    *kibana*) echo "Kibana|admin" ;;
    *prometheus*) echo "Prometheus|admin" ;;
    *rabbitmq*) echo "RabbitMQ|admin" ;;
    *cockpit*) echo "Cockpit|admin" ;;
    *dockerd*) echo "API Docker|dockerapi" ;;
    *sshd*) echo "SSH|ssh" ;;
    *)
      case $1 in
        5432) echo "PostgreSQL|db" ;;
        3306) echo "MySQL/MariaDB|db" ;;
        27017) echo "MongoDB|db" ;;
        6379) echo "Redis|db" ;;
        9200|9300) echo "Elasticsearch|db" ;;
        11211) echo "Memcached|db" ;;
        5984) echo "CouchDB|db" ;;
        8086) echo "InfluxDB|db" ;;
        1433) echo "SQL Server|db" ;;
        2375|2376) echo "API Docker|dockerapi" ;;
        22) echo "SSH|ssh" ;;
        80|443) echo "Web|web" ;;
        *) echo "Service|other" ;;
      esac ;;
  esac
}

# Les bases qui n'ont souvent aucun mot de passe par défaut.
nopass_note() {
  case $1 in
    Redis|MongoDB|Memcached|Elasticsearch) echo " $1 n'a souvent aucun mot de passe par défaut : n'importe qui peut lire et effacer les données." ;;
  esac
}

native_hint() {
  case $1 in
    PostgreSQL) echo "listen_addresses = 'localhost' dans /etc/postgresql/*/main/postgresql.conf" ;;
    MySQL/MariaDB) echo "bind-address = 127.0.0.1 dans /etc/mysql/mariadb.conf.d/50-server.cnf (ou mysqld.cnf)" ;;
    MongoDB) echo "net.bindIp: 127.0.0.1 dans /etc/mongod.conf" ;;
    Redis) echo "bind 127.0.0.1 dans /etc/redis/redis.conf" ;;
    Memcached) echo "-l 127.0.0.1 dans /etc/memcached.conf" ;;
    Elasticsearch) echo "network.host: 127.0.0.1 dans /etc/elasticsearch/elasticsearch.yml" ;;
    *) echo "l'adresse d'écoute 127.0.0.1 dans la configuration du service" ;;
  esac
}

# Adresses du serveur lui-même et de ses réseaux Docker : une connexion qui en vient n'est
# pas « extérieure » (ex. ton app qui parle à sa base).
local_ips=$(
  ip -o addr show 2>/dev/null | awk '{print $4}'
  if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
    # shellcheck disable=SC2046
    docker network inspect $(docker network ls -q) \
      --format '{{range .IPAM.Config}}{{.Gateway}} {{end}}{{range .Containers}}{{.IPv4Address}} {{end}}' 2>/dev/null | tr ' ' '\n'
  fi
)
local_ips=$(sed 's#/.*##' <<<"$local_ips" | grep -v '^$' | sort -u)

# Connexions établies en ce moment sur le port $1, hors localhost, serveur et Docker.
# $2 (facultatif) : PID d'un conteneur, pour regarder dans son réseau.
# Affiche « nombre|ip1, ip2 ».
ext_peers() {
  local cmd=(ss -Htn state established "( sport = :$1 )")
  [[ -n "${2:-}" && "${2:-0}" != 0 ]] && cmd=(nsenter -t "$2" -n "${cmd[@]}")
  "${cmd[@]}" 2>/dev/null | awk '{print $4}' \
    | sed -E 's/:[0-9]+$//; s/^\[//; s/\]$//; s/^::ffff://' \
    | grep -vE '^(127\.|::1$)' | grep -vxF -f <(printf '%s\n' "$local_ips") \
    | sort | uniq -c | sort -rn \
    | awk '{ n += $1; ips = ips (ips ? ", " : "") $2 } END { printf "%d|%s", n, ips }'
}

conn_text() {
  local n=${1%%|*} ips=${1#*|}
  if ((n > 0)); then
    echo " Connexions en ce moment : $n, depuis $ips. Si tu ne reconnais pas ces adresses, quelqu'un d'autre utilise ta base."
  else
    echo " Aucune connexion extérieure en ce moment."
  fi
}

normal_ports=""
declare -A seen=()

# Ports publiés par Docker (ils passent avant UFW).
docker_tpl='{{.Name}}|{{.Config.Image}}|{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.service"}}|{{index .Config.Labels "com.docker.compose.project.working_dir"}}|{{index .Config.Labels "com.docker.compose.project.config_files"}}|{{.HostConfig.Privileged}}|{{.HostConfig.NetworkMode}}|{{.State.Pid}}|{{range .Mounts}}{{.Source}},{{end}}|{{range $p, $b := .NetworkSettings.Ports}}{{range $b}}{{$p}}={{.HostIp}}:{{.HostPort}} {{end}}{{end}}'
compose_dirs=""
if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
  for id in $(docker ps -q); do
    IFS='|' read -r cname image project service wdir cfiles priv netmode cpid mounts bindings \
      <<<"$(docker inspect --format "$docker_tpl" "$id" 2>/dev/null)"
    cname=${cname#/}
    if [[ -n "$project" ]]; then
      cfile=${cfiles%%,*}
      where="projet Compose « $project », service « $service », fichier ${cfile:-?}"
      [[ -n "$wdir" ]] && compose_dirs="$compose_dirs"$'\n'"$wdir"
    else
      cfile=""
      where="lancé avec docker run"
    fi

    [[ "$priv" == true ]] && finding ELEVE docker "Conteneur « $cname » en mode privilégié" \
      "Il a tous les droits sur le serveur : une faille dans ce conteneur et le serveur est compromis ($where)." \
      "Retirer « privileged: true » et ne donner que les capacités nécessaires (cap_add)."
    [[ "$mounts" == *docker.sock* ]] && finding ELEVE docker "Le conteneur « $cname » contrôle Docker (docker.sock monté)" \
      "Il peut lancer n'importe quel conteneur avec les droits root du serveur. Courant pour Traefik ou Portainer, mais c'est un point sensible ($where)." \
      "Passer par un proxy de socket en lecture seule (ex. tecnativa/docker-socket-proxy), ou s'en passer."
    [[ "$netmode" == host ]] && finding NORMAL docker "Conteneur « $cname » sur le réseau de l'hôte" \
      "Ses ports ne passent pas par Docker : ils apparaissent comme des programmes normaux dans la liste des ports." ""

    for b in $bindings; do
      cport=${b%%=*}; cproto=${cport#*/}; cport=${cport%/*}
      hostpart=${b#*=}; hport=${hostpart##*:}; hip=${hostpart%:*}
      [[ "$hip" == 127.* || "$hip" == "::1" ]] && continue
      [[ -n "${seen[$cproto/$hport]:-}" ]] && continue
      seen[$cproto/$hport]=1
      IFS='|' read -r label kind <<<"$(service_of "$cport" "$image")"
      echo "P|$cproto|$hport|public|docker:$cname|$label|$kind|1|1"
      peers=$(ext_peers "$cport" "$cpid")
      [[ "${peers%%|*}" == 0 ]] && peers=$(ext_peers "$hport")
      if [[ -n "$cfile" ]]; then
        fix="Dans $cfile, service « $service » : remplace « $hport:$cport » par « 127.0.0.1:$hport:$cport », ou supprime « ports: » si seule ton app (même réseau Docker) s'y connecte. Puis : cd $wdir && docker compose up -d"
      else
        fix="Recrée le conteneur avec -p 127.0.0.1:$hport:$cport au lieu de -p $hport:$cport."
      fi
      bypass="Le conteneur « $cname » ($where) publie le port sur toutes les interfaces. Docker ouvre lui-même ce port dans le pare-feu : UFW ne le bloque pas."
      case $kind in
        db) finding CRITIQUE base-de-donnees "$label joignable depuis Internet (port $hport)" \
              "$bypass$(nopass_note "$label")$(conn_text "$peers")" "$fix" ;;
        dockerapi) finding CRITIQUE docker "API Docker ouverte sur le réseau (port $hport)" \
              "Quiconque y accède contrôle tout le serveur. $bypass" "$fix" ;;
        admin) finding ELEVE admin "$label accessible depuis Internet (port $hport)" \
              "Une interface d'administration exposée est une cible prioritaire pour les attaquants. $bypass" \
              "La mettre derrière ton reverse proxy avec authentification, ou : $fix" ;;
        web|ssh) normal_ports="$normal_ports $hport" ;;
        *) finding NORMAL ports "Port $hport ouvert à Internet par le conteneur « $cname »" \
              "Docker contourne UFW : ce port est public même avec le pare-feu actif ($where)." \
              "Si c'est voulu (site, API), rien à faire. Sinon : $fix" ;;
      esac
    done
  done

  if ! grep -qE '"ip"[[:space:]]*:[[:space:]]*"127\.0\.0\.1"' /etc/docker/daemon.json 2>/dev/null; then
    finding NORMAL docker "Docker publie les ports sur Internet par défaut" \
      "Un futur « -p 5432:5432 » serait public, même avec UFW actif." \
      "Ajouter \"ip\": \"127.0.0.1\" dans /etc/docker/daemon.json, et écrire alors 0.0.0.0:443:443 pour les ports vraiment publics."
  else
    finding OK docker "Docker publie les ports sur 127.0.0.1 par défaut"
  fi

  for d in $(sort -u <<<"$compose_dirs"); do
    while IFS= read -r envf; do
      finding ELEVE secrets "Fichier de secrets lisible par tous les comptes : $envf" \
        "N'importe quel compte ou service du serveur peut lire les mots de passe qu'il contient." "chmod 600 $envf"
    done < <(find "$d" -maxdepth 2 -name '.env*' -type f -perm -o=r 2>/dev/null)
  done
fi

# Programmes qui écoutent directement sur le serveur.
while read -r proto local procinfo; do
  port=${local##*:}
  addr=${local%:*}; addr=${addr#[}; addr=${addr%]}; addr=${addr%%%*}
  [[ "$addr" == 127.* || "$addr" == "::1" ]] && continue
  pname=$(sed -nE 's/.*\(\("([^"]+)",pid=([0-9]+).*/\1/p' <<<"$procinfo")
  pname=${pname:-inconnu}
  [[ "$pname" == docker-proxy ]] && continue
  [[ -n "${seen[$proto/$port]:-}" ]] && continue
  seen[$proto/$port]=1
  case $addr in
    0.0.0.0|::|'*') expo=public ;;
    10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|fd*|fe80*) expo=prive ;;
    *) expo=public ;;
  esac
  IFS='|' read -r label kind <<<"$(service_of "$port" "$pname")"
  reach=0
  reachable "$port" "$proto" && reach=1
  echo "P|$proto|$port|$expo|$pname|$label|$kind|$reach|0"

  listen="Le programme « $pname » écoute sur $( [[ $expo == public ]] && echo "toutes les interfaces ($addr)" || echo "le réseau privé ($addr)")"
  if [[ $kind == ssh || $kind == web ]]; then
    normal_ports="$normal_ports $port"
  elif [[ $expo == prive ]]; then
    [[ $kind == db || $kind == admin || $kind == dockerapi ]] && finding NORMAL reseau-prive "$label joignable depuis le réseau privé (port $port)" \
      "$listen. Les autres machines de ce réseau privé peuvent s'y connecter." \
      "Normal si un autre de tes serveurs s'y connecte. Sinon : $(native_hint "$label")."
  elif ((reach)); then
    case $kind in
      db) finding CRITIQUE base-de-donnees "$label joignable depuis Internet (port $port)" \
            "$listen et $(fw_reason).$(nopass_note "$label")$(conn_text "$(ext_peers "$port")")" \
            "Mettre $(native_hint "$label"), puis redémarrer le service. Pour y accéder depuis ton Mac : ssh -L $port:127.0.0.1:$port <ton-vps>." ;;
      dockerapi) finding CRITIQUE docker "API Docker ouverte sur le réseau (port $port)" \
            "Quiconque y accède contrôle tout le serveur, sans mot de passe. $listen et $(fw_reason)." \
            "Retirer l'option -H tcp://... du service Docker, ou la protéger par TLS." ;;
      admin) finding ELEVE admin "$label accessible depuis Internet (port $port)" \
            "Une interface d'administration exposée est une cible prioritaire. $listen et $(fw_reason)." \
            "La mettre derrière ton reverse proxy avec authentification, ou la faire écouter sur 127.0.0.1." ;;
      *) finding NORMAL ports "Port $port/$proto ouvert à Internet ($pname)" \
            "Chaque port ouvert est une porte d'entrée possible. $listen et $(fw_reason)." \
            "Si c'est voulu, rien à faire. Sinon : ferme-le dans le pare-feu ou fais écouter $pname sur 127.0.0.1." ;;
    esac
  elif [[ $kind == db || $kind == dockerapi ]]; then
    finding NORMAL base-de-donnees "$label écoute sur toutes les interfaces, mais le pare-feu le bloque (port $port)" \
      "Aujourd'hui c'est protégé. Si le pare-feu est désactivé un jour, la base sera exposée." \
      "Par sécurité, mettre $(native_hint "$label")."
  fi
done < <(ss -Htulnp 2>/dev/null | awk '{print $1, $5, $7}')

if [[ -n "$normal_ports" ]]; then
  finding OK ports "Ports publics attendus (SSH et web) : $(tr ' ' '\n' <<<"$normal_ports" | grep -v '^$' | sort -un | paste -sd' ' -)"
fi
exit 0
