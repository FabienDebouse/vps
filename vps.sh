#!/usr/bin/env bash
# vps.sh : sécuriser et gérer tes VPS Debian 12 depuis ton Mac.
#
# Télécharger dans le dossier courant, puis lancer :
#   curl -fsSL https://raw.githubusercontent.com/FabienDebouse/vps/main/vps.sh -o vps.sh && chmod +x vps.sh && ./vps.sh
#
#   ./vps.sh                          menu interactif
#   ./vps.sh add [<nom> <ip>] [opt.]  sécurise un VPS NEUF et crée le raccourci « ssh <nom> »
#   ./vps.sh adopt [<nom> <ip>] [opt.] sécurise un VPS DÉJÀ EN PRODUCTION, sans casser ses services
#       --user <u>                    compte pour s'y connecter aujourd'hui (défaut : root)
#       --port <p>                    port SSH (défaut : 22)
#       --no-docker                   (add) ne pas installer Docker
#   ./vps.sh audit [nom...|compte@ip] audit de sécurité (lecture seule), tous les VPS par défaut
#   ./vps.sh list                     liste tes VPS
#   ./vps.sh keys                     liste les clés autorisées
#   ./vps.sh addkey [fichier.pub]     autorise une nouvelle clé (autre Mac, PC...)
#   ./vps.sh delkey [nom]             retire une clé
#   ./vps.sh sync [nom...]            envoie les clés sur tous les VPS (ou ceux indiqués)
#   ./vps.sh apply [nom...]           rejoue la sécurisation sur tous les VPS (ou ceux indiqués)
#   ./vps.sh rm <nom>                 retire le raccourci (ne touche pas au serveur)
#   ./vps.sh update                   télécharge la dernière version à la place de celle-ci
#
# Au lancement, vps.sh vérifie d'abord qu'il est à jour (VPS_NO_UPDATE_CHECK=1 pour s'en passer).
# Tes clés, raccourcis et rapports d'audit sont dans ~/.vps : ce fichier peut être déplacé ou
# re-téléchargé sans rien perdre.
set -euo pipefail

# À augmenter à chaque publication : c'est ce numéro que compare la vérification au démarrage.
VPS_VERSION="2.0.0"

VPS_HOME="${VPS_HOME:-$HOME/.vps}"
KEYS_DIR="$VPS_HOME/keys"
HOSTS_DIR="$VPS_HOME/hosts"
AUDITS_DIR="$VPS_HOME/audits"
CONF="$VPS_HOME/config"

ADMIN_USER="$(id -un | tr '[:upper:]' '[:lower:]')"
IDENTITY="$HOME/.ssh/id_ed25519"
VPS_REPO="${VPS_REPO:-FabienDebouse/vps}"
VPS_BRANCH="${VPS_BRANCH:-main}"
if [[ -f "$CONF" ]]; then
  # shellcheck source=/dev/null
  . "$CONF"
fi

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SELF="$SELF_DIR/$(basename "${BASH_SOURCE[0]}")"
# Comment l'utilisateur appelle ce script, pour les messages (« ./vps.sh add »...).
if [[ "$SELF_DIR" == "$PWD" ]]; then CMDNAME="./$(basename "$SELF")"; else CMDNAME="$SELF"; fi
ARGS=("$@")

# Remplis par ask_target / parse_target, et par boot_open.
NAME="" IP="" BOOT_USER=root PORT=22 DOCKER=1
BOOT=()

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$SELF"; }

# ask "Question" [défaut] : affiche la question et renvoie la réponse (ou le défaut).
ask() {
  local q=$1 def=${2:-} ans=""
  if [[ -n "$def" ]]; then printf '%s [%s] : ' "$q" "$def" >&2; else printf '%s : ' "$q" >&2; fi
  if ! IFS= read -r ans; then
    echo >&2
    [[ -n "$def" ]] || die "Pas de réponse."
  fi
  echo "${ans:-$def}"
}

# ask_yn "Question" o|n : vrai si la réponse est oui.
ask_yn() {
  local ans
  ans=$(ask "$1 (o/n)" "$2")
  [[ "$ans" =~ ^[oOyY] ]]
}

# --- Version ----------------------------------------------------------------
script_url() { echo "${VPS_BASE_URL:-https://raw.githubusercontent.com/$VPS_REPO/$VPS_BRANCH}/vps.sh"; }

# Vrai si la version $1 est plus récente que $2 (numéros « 2.10.1 »).
newer() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    n = split(a, x, "."); m = split(b, y, ".")
    for (i = 1; i <= (n > m ? n : m); i++) {
      if (x[i] + 0 > y[i] + 0) exit 0
      if (x[i] + 0 < y[i] + 0) exit 1
    }
    exit 1 }'
}

# Télécharge la dernière version publiée dans un fichier temporaire, à côté de ce script
# (même disque : le remplacement sera instantané). Affiche son chemin.
fetch_latest() {
  local tmp
  tmp=$(mktemp "$SELF.XXXXXX")
  if curl -fsSL --max-time "${1:-10}" "$(script_url)" -o "$tmp" 2>/dev/null; then
    echo "$tmp"
  else
    rm -f "$tmp"
    return 1
  fi
}

remote_version() { sed -n 's/^VPS_VERSION="\([^"]*\)".*/\1/p' "$1" | head -n1; }

# Remplace ce script par le fichier $1, puis le relance avec les mêmes arguments.
install_latest() {
  if ! bash -n "$1" 2>/dev/null || [[ -z "$(remote_version "$1")" ]]; then
    rm -f "$1"
    die "Le fichier téléchargé est invalide : rien n'a été changé."
  fi
  chmod 755 "$1"
  # mv plutôt que cp : le script en cours garde son ancienne copie jusqu'au bout.
  mv "$1" "$SELF"
  ok "vps.sh mis à jour en version $(remote_version "$SELF")."
  echo
  VPS_NO_UPDATE_CHECK=1 exec "$SELF" ${ARGS[@]+"${ARGS[@]}"}
}

# Première chose au lancement : vérifier qu'on a la dernière version.
check_update() {
  local tmp remote
  [[ "${VPS_NO_UPDATE_CHECK:-0}" == 1 ]] && return 0
  if ! tmp=$(fetch_latest 4); then
    warn "Impossible de vérifier s'il existe une nouvelle version (pas de connexion ?). On continue avec la $VPS_VERSION."
    return 0
  fi
  remote=$(remote_version "$tmp")
  if [[ -z "$remote" ]] || ! newer "$remote" "$VPS_VERSION"; then
    rm -f "$tmp"
    return 0
  fi
  echo
  say "Nouvelle version disponible : $remote (tu as la $VPS_VERSION)."
  echo "    Pour la télécharger :"
  echo "    curl -fsSL $(script_url) -o \"$SELF\""
  echo
  if [[ -t 0 ]] && ask_yn "La télécharger maintenant à la place de celle-ci ?" o; then
    install_latest "$tmp"
  fi
  rm -f "$tmp"
  echo "On continue avec la $VPS_VERSION."
  echo
}

cmd_update() {
  local tmp remote
  tmp=$(fetch_latest) || die "Téléchargement impossible : $(script_url)"
  remote=$(remote_version "$tmp")
  if [[ -n "$remote" ]] && ! newer "$remote" "$VPS_VERSION"; then
    rm -f "$tmp"
    ok "Tu as déjà la dernière version ($VPS_VERSION)."
    return 0
  fi
  ARGS=(version)
  install_latest "$tmp"
}

# --- Outils -----------------------------------------------------------------
need_init() { [[ -f "$CONF" ]] || cmd_init; }

host_file() { echo "$HOSTS_DIR/$1.conf"; }

all_hosts() {
  local f
  shopt -s nullglob
  for f in "$HOSTS_DIR"/*.conf; do basename "$f" .conf; done
  shopt -u nullglob
}

# Les noms passés en argument (vérifiés), sinon tous les VPS.
targets() {
  local h
  if (($#)); then
    for h in "$@"; do
      [[ -f "$(host_file "$h")" ]] || die "VPS inconnu : $h"
      echo "$h"
    done
  else
    all_hosts
  fi
}

# Valeur d'un réglage noté dans la première ligne du raccourci (« # vps: mode=existing ports=... »).
meta_get() {
  awk -v k="$2" '/^# vps:/ { for (i = 3; i <= NF; i++) if (index($i, k "=") == 1) print substr($i, length(k) + 2) }' "$1"
}

write_host() {  # nom ip port réglages
  cat > "$(host_file "$1")" <<EOF
# vps: $4
Host $1
  HostName $2
  User $ADMIN_USER
  Port $3
  IdentityFile $IDENTITY
  IdentitiesOnly yes
  AddKeysToAgent yes
  IgnoreUnknown UseKeychain
  UseKeychain yes
EOF
}

# Toutes les clés publiques de ~/.vps/keys, une par ligne.
all_keys() {
  local files
  shopt -s nullglob
  files=("$KEYS_DIR"/*.pub)
  shopt -u nullglob
  ((${#files[@]})) || die "Aucune clé dans $KEYS_DIR"
  awk 1 "${files[@]}" | grep -E '^(ssh-|ecdsa-|sk-)' || die "Aucune clé valide dans $KEYS_DIR"
}

# Les clés encodées pour le serveur. Refuse si la clé de ce Mac n'en fait pas partie.
keys_b64() {
  local keys own
  keys=$(all_keys)
  [[ -f "$IDENTITY.pub" ]] || die "Clé introuvable : $IDENTITY.pub"
  own=$(awk '{print $1" "$2}' "$IDENTITY.pub")
  awk '{print $1" "$2}' <<<"$keys" | grep -qxF "$own" \
    || die "La clé de ce Mac ($IDENTITY.pub) n'est pas dans $KEYS_DIR : tu perdrais l'accès. Annulé."
  printf '%s\n' "$keys" | base64 | tr -d '\n'
}

# Variables du script de sécurisation : port docker config_docker apt ports comptes root.
harden_env() {
  printf "NEW_USER='%s' SSH_PORT='%s' INSTALL_DOCKER='%s' DOCKER_DAEMON_CONFIG='%s' APT_UPGRADE='%s' EXTRA_PORTS='%s' EXTRA_SSH_USERS='%s' ROOT_LOGIN='%s'" \
    "$ADMIN_USER" "$@"
}

# Envoie un script (intégré en bas de ce fichier) et l'exécute en root sur le serveur.
# $1 fonction qui affiche le script (harden_script ou audit_script), $2 variables
# (« A='x' B='y' »), $3 préfixe sudo, $4 1 = terminal interactif ; le reste : arguments ssh.
# ADMIN_IP permet à l'audit de reconnaître ta propre connexion.
run_root() {
  local script=$1 envs=$2 sudo=$3 tty=$4 b64 remote
  shift 4
  b64=$("$script" | base64 | tr -d '\n')
  remote="f=\$(mktemp) && echo '$b64' | base64 -d > \"\$f\" && ${sudo}env ADMIN_IP=\"\${SSH_CLIENT%% *}\" $envs bash \"\$f\"; rc=\$?; rm -f \"\$f\"; exit \$rc"
  # -n : sans terminal, ssh ne doit pas avaler les réponses destinées aux questions suivantes.
  if [[ $tty == 1 ]]; then ssh -t "$@" "$remote"; else ssh -n "$@" "$remote"; fi
}

# Connexion maître vers un serveur qui n'a pas encore de raccourci : on s'authentifie une
# seule fois (un seul mot de passe), les commandes suivantes passent par elle.
boot_open() {  # compte@ip port
  BOOT=(-p "$2" -i "$IDENTITY" -o StrictHostKeyChecking=accept-new -o "ControlPath=/tmp/vps-$(id -u)-%C" "$1")
  say "Connexion à $1 (le mot de passe du serveur peut être demandé une fois)"
  ssh -f -N -o ControlMaster=yes -o ConnectTimeout=15 "${BOOT[@]}" || die "Connexion impossible à $1 (port $2)."
}
boot_close() {
  if [[ -n "${BOOT[*]:-}" ]]; then ssh -O exit "${BOOT[@]}" 2>/dev/null || true; fi
  BOOT=()
}

# Questions communes à « add » et « adopt ».
ask_target() {
  while :; do
    NAME=$(ask "Nom du raccourci (ex : web1)")
    if [[ ! "$NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then warn "Lettres, chiffres, . _ - uniquement."
    elif [[ -f "$(host_file "$NAME")" ]]; then warn "$NAME existe déjà."
    else break; fi
  done
  while :; do
    IP=$(ask "Adresse IP du VPS")
    [[ "$IP" =~ ^[A-Za-z0-9.:-]+$ ]] && break
    warn "Adresse invalide."
  done
  BOOT_USER=$(ask "Compte pour s'y connecter aujourd'hui" root)
  while :; do
    PORT=$(ask "Port SSH" 22)
    [[ "$PORT" =~ ^[0-9]+$ ]] && break
    warn "Port invalide."
  done
}

parse_target() {
  (($# >= 2)) || die "Il faut un nom et une adresse IP : $CMDNAME $CMD <nom> <ip> [--user root] [--port 22]"
  NAME=$1 IP=$2
  shift 2
  while (($#)); do
    case $1 in
      --user) BOOT_USER=${2:?--user attend un nom}; shift 2 ;;
      --port) PORT=${2:?--port attend un numéro}; shift 2 ;;
      --no-docker) DOCKER=0; shift ;;
      *) die "Option inconnue : $1" ;;
    esac
  done
}

check_target() {
  [[ "$NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "Nom invalide : $NAME (lettres, chiffres, . _ -)"
  [[ "$IP" =~ ^[A-Za-z0-9.:-]+$ ]] || die "Adresse invalide : $IP"
  [[ "$PORT" =~ ^[0-9]+$ ]] || die "Port invalide : $PORT"
  [[ "$BOOT_USER" =~ ^[A-Za-z0-9._-]+$ ]] || die "Compte invalide : $BOOT_USER"
  [[ ! -f "$(host_file "$NAME")" ]] || die "$NAME existe déjà. Pour le refaire : $CMDNAME rm $NAME"
}

# Vérifie un VPS fraîchement sécurisé, via son raccourci. On lit la config effective de sshd
# plutôt que de tenter une connexion root : une tentative ratée compterait pour Fail2ban.
verify_host() {
  local conf
  say "Vérification"
  conf=$(ssh -o ConnectTimeout=10 "$1" 'sudo -n sshd -T' </dev/null) \
    || die "« ssh $1 » ne fonctionne pas. Le raccourci est dans $(host_file "$1")."
  ok "Connexion par clé et sudo : OK"
  if grep -qx 'passwordauthentication no' <<<"$conf"; then ok "Mots de passe refusés"
  else warn "sshd accepte encore les mots de passe : vérifie /etc/ssh/sshd_config.d/ sur le serveur."; fi
  if grep -qx 'permitrootlogin no' <<<"$conf"; then ok "Root refusé"
  elif grep -qE '^permitrootlogin (without-password|prohibit-password)$' <<<"$conf"; then ok "Root : par clé seulement"
  else warn "sshd accepte encore root : vérifie /etc/ssh/sshd_config.d/ sur le serveur."; fi
}

# Affiche un rapport d'audit et le garde dans ~/.vps/audits.
# $1 titre, $2 rapport brut, $3 « tout » ou « important » (critiques et élevés seulement),
# $4 nom du fichier enregistré. Remplit N_CRIT, N_HIGH et N_NORM.
show_report() {
  local title=$1 report=$2 mode=${3:-tout} save level lvl t why fix findings out
  save=$(printf '%s' "${4:-$title}" | tr -c 'A-Za-z0-9._-' '_')
  findings=$(grep '^F|' <<<"$report" || true)
  N_CRIT=$(grep -c '^F|CRITIQUE|' <<<"$findings" || true)
  N_HIGH=$(grep -c '^F|ELEVE|' <<<"$findings" || true)
  N_NORM=$(grep -c '^F|NORMAL|' <<<"$findings" || true)
  out=$(mktemp)
  {
    printf '\n\033[1m━━━ Audit de sécurité : %s ━━━\033[0m\n' "$title"
    for level in CRITIQUE ELEVE NORMAL OK; do
      if [[ $mode == important && ($level == NORMAL || $level == OK) ]]; then continue; fi
      if [[ $level == OK ]] && grep -q '^F|OK|' <<<"$findings"; then printf '\n\033[1mCe qui va bien\033[0m\n'; fi
      while IFS='|' read -r _ lvl _ t why fix; do
        [[ "$lvl" == "$level" ]] || continue
        case $level in
          CRITIQUE) printf '\n\033[1;97;41m CRITIQUE \033[0m \033[1m%s\033[0m\n' "$t" ;;
          ELEVE)    printf '\n\033[1;30;43m  ÉLEVÉ   \033[0m \033[1m%s\033[0m\n' "$t" ;;
          NORMAL)   printf '\n\033[1;97;44m  NORMAL  \033[0m %s\n' "$t" ;;
          OK)       printf ' \033[32m✓\033[0m %s\n' "$t" ;;
        esac
        if [[ $level != OK ]]; then
          if [[ -n "$why" ]]; then printf '   Pourquoi : %s\n' "$why"; fi
          if [[ -n "$fix" ]]; then printf '   À faire  : %s\n' "$fix"; fi
        fi
      done <<<"$findings"
    done
    printf '\n\033[1mBilan :\033[0m \033[31m%s critique(s)\033[0m, \033[33m%s élevé(s)\033[0m, \033[34m%s normal(aux)\033[0m\n' \
      "$N_CRIT" "$N_HIGH" "$N_NORM"
  } > "$out"
  cat "$out"
  mkdir -p "$AUDITS_DIR"
  sed $'s/\x1b\\[[0-9;]*m//g' "$out" > "$AUDITS_DIR/$save-$(date +%Y%m%d-%H%M).txt"
  rm -f "$out"
}

# --- Commandes --------------------------------------------------------------
cmd_init() {
  local inc tmp own_key def
  say "Première utilisation : configuration (une seule fois)"
  mkdir -p "$KEYS_DIR" "$HOSTS_DIR"
  chmod 700 "$VPS_HOME"

  def=$ADMIN_USER
  [[ "$def" =~ ^[a-z_][a-z0-9_-]*$ ]] || def=admin
  while :; do
    ADMIN_USER=$(ask "Nom d'utilisateur à créer sur tes VPS" "$def")
    [[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] && break
    warn "Minuscules, chiffres, _ et - uniquement."
  done
  cat > "$CONF" <<EOF
# Utilisateur créé sur chaque VPS (celui avec lequel tu te connectes).
ADMIN_USER=$ADMIN_USER
# Clé privée de ce Mac.
IDENTITY="\$HOME/.ssh/id_ed25519"
# Dépôt GitHub où vps.sh cherche les nouvelles versions.
VPS_REPO=$VPS_REPO
VPS_BRANCH=$VPS_BRANCH
EOF
  ok "Utilisateur des VPS : $ADMIN_USER (modifiable dans $CONF)"

  if [[ ! -f "$IDENTITY" ]]; then
    say "Création de ta clé SSH. Choisis une phrase de passe : le trousseau macOS la retiendra."
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -f "$IDENTITY" -C "$(id -un)@$(hostname -s)"
  fi
  ssh-add --apple-use-keychain "$IDENTITY" 2>/dev/null || true

  if ! awk '{print $2}' "$KEYS_DIR"/*.pub 2>/dev/null | grep -qxF "$(awk '{print $2}' "$IDENTITY.pub")"; then
    own_key="$KEYS_DIR/$(hostname -s).pub"
    cp "$IDENTITY.pub" "$own_key"
    ok "Clé de ce Mac ajoutée : $own_key"
  fi

  inc="Include $HOSTS_DIR/*.conf"
  if [[ "$VPS_HOME" == "$HOME/.vps" ]]; then
    inc="Include ~/.vps/hosts/*.conf"
  fi
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  touch "$HOME/.ssh/config"
  if ! grep -qxF "$inc" "$HOME/.ssh/config"; then
    # L'Include doit être en tête du fichier pour que ssh le prenne en compte partout.
    tmp=$(mktemp)
    { echo "$inc"; echo; cat "$HOME/.ssh/config"; } > "$tmp"
    cat "$tmp" > "$HOME/.ssh/config"
    rm -f "$tmp"
    ok "~/.ssh/config connaît maintenant tes VPS"
  fi
  chmod 600 "$HOME/.ssh/config"
  ok "Configuration terminée."
  echo
}

cmd_add() {
  need_init
  local sudo="" keys envs
  if (($# == 0)); then
    say "Nouveau VPS"
    ask_target
    if ask_yn "Installer Docker ?" o; then DOCKER=1; else DOCKER=0; fi
    echo
    echo "  $NAME : $BOOT_USER@$IP, port $PORT, Docker : $( ((DOCKER)) && echo oui || echo non)"
    echo "  Ensuite : connexion par clé uniquement, en tant que $ADMIN_USER, avec « ssh $NAME »."
    ask_yn "On y va ?" o || die "Annulé."
  else
    parse_target "$@"
  fi
  check_target
  [[ "$BOOT_USER" == root ]] || sudo="sudo "
  keys=$(keys_b64)

  boot_open "$BOOT_USER@$IP" "$PORT"
  trap boot_close EXIT
  say "Sécurisation de $NAME"
  envs=$(harden_env "$PORT" "$DOCKER" 1 1 "" "" no)
  run_root harden_script "$envs AUTHORIZED_KEYS_B64='$keys'" "$sudo" 1 "${BOOT[@]}" \
    || die "Échec. Si le serveur a déjà été sécurisé (root bloqué), relance avec : $CMDNAME add $NAME $IP --user $ADMIN_USER"
  boot_close
  trap - EXIT

  write_host "$NAME" "$IP" "$PORT" "mode=new docker=$DOCKER"
  verify_host "$NAME"
  echo
  ok "C'est prêt : ssh $NAME"
}

cmd_adopt() {
  need_init
  local sudo="" keys report before line u d ip m where def envs info
  local proto pport expo src label kind _reach dock
  local extra_ports="" extra_users="" root_login=no apt_upgrade=0 docker_public="" candidates
  local p_lines=()
  DOCKER=0
  if (($# == 0)); then
    say "VPS déjà en production : audit d'abord, puis sécurisation sans casser tes services."
    ask_target
  else
    parse_target "$@"
  fi
  check_target
  [[ "$BOOT_USER" == root ]] || sudo="sudo "
  keys=$(keys_b64)

  boot_open "$BOOT_USER@$IP" "$PORT"
  trap boot_close EXIT
  say "Audit de $NAME (lecture seule : rien n'est modifié)"
  report=$(run_root audit_script "" "${sudo:+sudo -n }" 0 "${BOOT[@]}") \
    || die "Audit impossible. Avec un compte autre que root, il faut sudo sans mot de passe."
  show_report "$NAME" "$report" tout "$NAME-avant"
  before="$N_CRIT critique(s), $N_HIGH élevé(s), $N_NORM normal(aux)"

  echo
  say "Préparation de la sécurisation. Rien n'est appliqué avant ta confirmation finale."

  # Ports : on lit tout d'abord, les questions viennent ensuite (elles lisent le clavier).
  while IFS= read -r line; do
    if [[ -n "$line" ]]; then p_lines+=("$line"); fi
  done <<<"$(grep '^P|' <<<"$report" || true)"
  for line in ${p_lines[@]+"${p_lines[@]}"}; do
    IFS='|' read -r _ proto pport expo src label kind _reach dock <<<"$line"
    if [[ $dock == 1 ]]; then
      docker_public="$docker_public    - $pport ($label, conteneur ${src#docker:})"$'\n'
      continue
    fi
    [[ $kind == ssh || $kind == web || $pport == "$PORT" ]] && continue
    def=o
    [[ $kind == db || $kind == dockerapi ]] && def=n
    if [[ $expo == prive ]]; then where="depuis ton réseau privé"; else where="depuis Internet"; fi
    if ask_yn "Port $pport/$proto ($label, programme « $src ») : le garder joignable $where ?" "$def"; then
      extra_ports="$extra_ports $pport/$proto"
    fi
  done

  # Comptes SSH : ceux qui ont des clés ou se sont connectés ces 30 derniers jours.
  candidates=$( { grep '^K|' <<<"$report"; grep '^U|' <<<"$report"; } | cut -d'|' -f2 \
    | grep -vxE "root|$ADMIN_USER" | sort -u || true)
  for u in $candidates; do
    [[ "$u" =~ ^[a-z_][a-z0-9_.-]*$ ]] || continue
    line=$(grep "^U|$u|" <<<"$report" | sort -t'|' -k4 | tail -n1 || true)
    if [[ -n "$line" ]]; then
      IFS='|' read -r _ _ m d ip <<<"$line"
      info="connecté par $( [[ $m == publickey ]] && echo clé || echo "mot de passe") le $d depuis $ip"
    else
      info="a des clés SSH, pas de connexion ces 30 derniers jours"
    fi
    if ask_yn "Le compte « $u » ($info) : lui garder l'accès SSH par clé ?" o; then
      extra_users="$extra_users $u"
      if grep -q "^U|$u|password|" <<<"$report"; then
        warn "« $u » se connecte par mot de passe : il lui faudra une clé SSH, les mots de passe seront refusés."
      fi
    fi
  done

  line=$(grep '^U|root|publickey|' <<<"$report" || true)
  if [[ -n "$line" ]]; then
    IFS='|' read -r _ _ _ d ip <<<"$line"
    if ask_yn "Root s'est connecté par clé le $d depuis $ip (souvent un déploiement automatique). Garder root par clé ? (déconseillé)" n; then
      root_login=key
    fi
  fi
  line=$(grep '^U|root|password|' <<<"$report" || true)
  if [[ -n "$line" ]]; then
    IFS='|' read -r _ _ _ d ip <<<"$line"
    warn "Root s'est connecté par mot de passe le $d depuis $ip : ce sera refusé. Si un outil l'utilise, donne-lui une clé SSH."
  fi

  if ask_yn "Installer aussi toutes les mises à jour maintenant ? (Docker et d'autres services peuvent redémarrer quelques secondes)" n; then
    apt_upgrade=1
  fi
  # shellcheck disable=SC2086  # on retire juste les espaces en trop
  extra_ports=$(echo $extra_ports)
  # shellcheck disable=SC2086
  extra_users=$(echo $extra_users)

  echo
  say "Récapitulatif pour $NAME"
  echo "  - SSH : clé uniquement ; toi : « ssh $NAME » (compte $ADMIN_USER)"
  [[ -n "$extra_users" ]] && echo "  - Comptes SSH gardés (par clé) : $extra_users"
  echo "  - Root : $( [[ $root_login == key ]] && echo "par clé seulement" || echo interdit)"
  echo "  - Pare-feu : ouverts = SSH ($PORT), 80, 443${extra_ports:+, $extra_ports} ; tout le reste fermé"
  if [[ -n "$docker_public" ]]; then
    echo "  - Ports Docker qui RESTENT publics (Docker passe avant le pare-feu, voir l'audit pour les fermer) :"
    printf '%s' "$docker_public"
  fi
  echo "  - Fail2ban : 5 échecs en 10 min = 1 h de ban"
  echo "  - Mises à jour de sécurité automatiques ; mises à jour complètes maintenant : $( ((apt_upgrade)) && echo oui || echo non)"
  echo "  - Docker : configuration inchangée, aucun conteneur arrêté ni modifié"
  echo
  warn "Fais un snapshot du VPS chez ton hébergeur avant de continuer."
  ask_yn "On y va ?" n || die "Annulé : rien n'a été modifié."

  envs=$(harden_env "$PORT" 0 0 "$apt_upgrade" "$extra_ports" "$extra_users" "$root_login")
  run_root harden_script "$envs AUTHORIZED_KEYS_B64='$keys'" "$sudo" 1 "${BOOT[@]}" \
    || die "La sécurisation s'est arrêtée en route (voir le message au-dessus). Aucun service n'a été arrêté ; tu peux relancer « $CMDNAME adopt »."
  boot_close
  trap - EXIT

  write_host "$NAME" "$IP" "$PORT" "mode=existing docker=0 ports=${extra_ports// /,} users=${extra_users// /,} root=$root_login"
  verify_host "$NAME"

  say "Nouvel audit"
  report=$(run_root audit_script "" "sudo -n " 0 -o ConnectTimeout=10 "$NAME") || die "Audit final impossible."
  show_report "$NAME" "$report" important "$NAME-apres"
  echo "  Avant : $before"
  echo "  Après : $N_CRIT critique(s), $N_HIGH élevé(s), $N_NORM normal(aux)"
  echo
  ok "C'est prêt : ssh $NAME"
}

cmd_audit() {
  need_init
  local port=22 t report name sudo rc=0 summary="" n=0
  local args=()
  while (($#)); do
    case $1 in
      --port) port=${2:?--port attend un numéro}; shift 2 ;;
      tous|all) shift ;;
      *) args+=("$1"); shift ;;
    esac
  done
  if ((${#args[@]} == 0)); then
    for t in $(all_hosts); do args+=("$t"); done
    ((${#args[@]})) || die "Aucun VPS enregistré. Pour un serveur pas encore ajouté : $CMDNAME audit root@<ip>"
  fi
  for t in "${args[@]}"; do
    if [[ "$t" == *@* ]]; then
      [[ "$t" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9.:-]+$ ]] || die "Cible invalide : $t"
      sudo=""
      [[ "${t%@*}" == root ]] || sudo="sudo -n "
      boot_open "$t" "$port"
      report=$(run_root audit_script "" "$sudo" 0 "${BOOT[@]}") || report=""
      boot_close
      name=${t#*@}
    else
      [[ -f "$(host_file "$t")" ]] || die "VPS inconnu : $t"
      report=$(run_root audit_script "" "sudo -n " 0 -o ConnectTimeout=10 "$t") || report=""
      name=$t
    fi
    if [[ -z "$report" ]]; then
      warn "$name : audit impossible (connexion, ou sudo qui demande un mot de passe)."
      rc=1
      continue
    fi
    show_report "$name" "$report" tout
    summary="$summary$(printf '  %-20s %3s critique(s)  %3s élevé(s)  %3s normal(aux)' "$name" "$N_CRIT" "$N_HIGH" "$N_NORM")"$'\n'
    n=$((n + 1))
    if ((N_CRIT > 0)); then rc=2; fi
  done
  if ((n > 1)); then
    echo
    say "Résumé"
    printf '%s' "$summary"
  fi
  echo
  echo "Rapports enregistrés dans $AUDITS_DIR"
  return $rc
}

cmd_list() {
  need_init
  local h n=0
  printf '%-20s %-24s %-6s %-12s %s\n' NOM ADRESSE PORT UTILISATEUR TYPE
  for h in $(all_hosts); do
    awk -v n="$h" -v mode="$( [[ "$(meta_get "$(host_file "$h")" mode)" == existing ]] && echo "existant" || echo "neuf")" \
      '$1=="HostName"{ip=$2} $1=="Port"{p=$2} $1=="User"{u=$2}
       END {printf "%-20s %-24s %-6s %-12s %s\n", n, ip, p, u, mode}' "$(host_file "$h")"
    n=$((n + 1))
  done
  ((n)) || echo "(aucun VPS : ajoute-en un avec « $CMDNAME add » ou « $CMDNAME adopt »)"
}

cmd_keys() {
  need_init
  local f
  shopt -s nullglob
  for f in "$KEYS_DIR"/*.pub; do
    printf '  %-28s %s\n' "$(basename "$f" .pub)" "$(ssh-keygen -lf "$f" | awk '{print $2, $NF}')"
  done
  shopt -u nullglob
}

# Demande d'envoyer les clés sur les VPS, s'il y en a.
offer_sync() {
  if [[ -z "$(all_hosts)" ]]; then return 0; fi
  if ask_yn "Mettre à jour tous tes VPS maintenant ?" o; then
    cmd_sync
  else
    echo "Pense à lancer « $CMDNAME sync »."
  fi
}

cmd_addkey() {
  need_init
  local src=${1:-} key def name dest tmp
  local re='^(ssh-[a-z0-9-]+|ecdsa-sha2-[a-z0-9-]+|sk-[a-z0-9@.-]+) [A-Za-z0-9+/=]+'
  if [[ -z "$src" ]]; then
    src=$(ask "Chemin du fichier .pub, ou colle la clé directement")
  fi
  src=${src/#\~/$HOME}
  if [[ -f "$src" ]]; then
    key=$(grep -m1 -E '^(ssh-|ecdsa-|sk-)' "$src" || true)
    def=$(basename "$src" .pub)
  else
    key=$src
    def=$(awk '{print $3}' <<<"$key")
  fi
  [[ "$key" =~ $re ]] || die "Ce n'est pas une clé publique SSH."
  tmp=$(mktemp)
  printf '%s\n' "$key" > "$tmp"
  ssh-keygen -lf "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; die "Clé illisible."; }
  rm -f "$tmp"
  if awk '{print $2}' "$KEYS_DIR"/*.pub 2>/dev/null | grep -qxF "$(awk '{print $2}' <<<"$key")"; then
    die "Cette clé est déjà autorisée."
  fi
  def=$(tr -c 'A-Za-z0-9._\n-' '-' <<<"${def:-cle}")
  while :; do
    name=$(ask "Nom de cette clé (ex : macbook-pro, pc-bureau)" "$def")
    dest="$KEYS_DIR/$name.pub"
    if [[ ! "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then warn "Lettres, chiffres, . _ - uniquement."
    elif [[ -f "$dest" ]]; then warn "Une clé s'appelle déjà $name."
    else break; fi
  done
  printf '%s\n' "$key" > "$dest"
  ok "Clé « $name » autorisée."
  offer_sync
}

cmd_delkey() {
  need_init
  local name=${1:-} f
  if [[ -z "$name" ]]; then
    cmd_keys
    name=$(ask "Nom de la clé à retirer")
  fi
  f="$KEYS_DIR/$name.pub"
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ && -f "$f" ]] || die "Clé inconnue : $name"
  if grep -qF "$(awk '{print $2}' "$IDENTITY.pub")" "$f"; then
    die "C'est la clé de ce Mac : tu perdrais l'accès à tes VPS."
  fi
  rm "$f"
  ok "Clé « $name » retirée."
  offer_sync
}

cmd_sync() {
  need_init
  local keys hosts h good=0 bad=0
  keys=$(keys_b64)
  hosts=$(targets "$@")
  [[ -n "$hosts" ]] || die "Aucun VPS enregistré."
  say "Envoi de $(all_keys | wc -l | tr -d ' ') clé(s)"
  for h in $hosts; do
    # Écriture puis renommage : le fichier n'est jamais à moitié écrit.
    # La seconde connexion vérifie qu'on a toujours accès avec la nouvelle liste.
    if ssh -n -o ConnectTimeout=10 "$h" "umask 077 && mkdir -p ~/.ssh && echo '$keys' | base64 -d > ~/.ssh/authorized_keys.new && mv ~/.ssh/authorized_keys.new ~/.ssh/authorized_keys" \
       && ssh -n -o ConnectTimeout=10 "$h" true; then
      ok "$h"
      good=$((good + 1))
    else
      warn "$h : échec"
      bad=$((bad + 1))
    fi
  done
  echo "$good OK, $bad en échec"
  ((bad == 0))
}

cmd_apply() {
  need_init
  local keys hosts h f port envs good=0 bad=0
  keys=$(keys_b64)
  hosts=$(targets "$@")
  [[ -n "$hosts" ]] || die "Aucun VPS enregistré."
  for h in $hosts; do
    say "$h"
    f=$(host_file "$h")
    port=$(awk '$1=="Port"{print $2}' "$f")
    if [[ "$(meta_get "$f" mode)" == existing ]]; then
      # Serveur existant : on rejoue avec les choix faits lors de « adopt ».
      envs=$(harden_env "${port:-22}" 0 0 0 "$(meta_get "$f" ports | tr , ' ')" \
        "$(meta_get "$f" users | tr , ' ')" "$(meta_get "$f" root)")
    else
      envs=$(harden_env "${port:-22}" "$(meta_get "$f" docker)" 1 1 "" "" no)
    fi
    if run_root harden_script "$envs AUTHORIZED_KEYS_B64='$keys'" "sudo " 1 "$h"; then
      ok "$h"
      good=$((good + 1))
    else
      warn "$h : échec"
      bad=$((bad + 1))
    fi
  done
  echo "$good OK, $bad en échec"
  ((bad == 0))
}

cmd_rm() {
  need_init
  local f
  f=$(host_file "${1:?Usage : $CMDNAME rm <nom>}")
  [[ -f "$f" ]] || die "VPS inconnu : $1"
  rm "$f"
  ok "Raccourci « $1 » retiré (le serveur n'a pas été modifié)."
}

cmd_menu() {
  need_init
  local c t
  if [[ -d "$VPS_HOME/bin" ]]; then
    warn "Ancienne installation trouvée dans $VPS_HOME/bin : elle n'est plus utilisée. Tu peux supprimer ce dossier et la ligne « export PATH=\"\$HOME/.vps/bin:\$PATH\" » de ~/.zshrc."
  fi
  while :; do
    echo
    echo "vps.sh $VPS_VERSION — que veux-tu faire ?"
    echo "  1) Sécuriser un nouveau VPS"
    echo "  2) Sécuriser un VPS déjà en production"
    echo "  3) Audit de sécurité"
    echo "  4) Voir mes VPS"
    echo "  5) Voir les clés autorisées"
    echo "  6) Autoriser une nouvelle clé"
    echo "  7) Retirer une clé"
    echo "  8) Renvoyer les clés sur tous les VPS"
    echo "  9) Rejouer la sécurisation sur tous les VPS"
    echo "  u) Mettre à jour vps.sh"
    echo "  q) Quitter"
    c=$(ask "Choix" q)
    echo
    # Chaque action tourne dans un sous-shell : une erreur ramène au menu.
    case $c in
      1) (cmd_add) || true ;;
      2) (cmd_adopt) || true ;;
      3) t=$(ask "Quel VPS ? (un nom, « tous », ou compte@ip pour un serveur pas encore ajouté)" tous)
         # shellcheck disable=SC2086
         (cmd_audit $t) || true ;;
      4) (cmd_list) || true ;;
      5) (cmd_keys) || true ;;
      6) (cmd_addkey) || true ;;
      7) (cmd_delkey) || true ;;
      8) (cmd_sync) || true ;;
      9) (cmd_apply) || true ;;
      u|U) ARGS=(menu); cmd_update ;;
      q|Q) exit 0 ;;
      *) warn "Choix inconnu : $c" ;;
    esac
  done
}

# --- Scripts envoyés aux serveurs -------------------------------------------
# Ils sont intégrés ici pour que vps.sh reste un seul fichier. run_root les envoie au
# serveur et les y exécute en root ; ils ne tournent jamais sur ton Mac.

harden_script() {
  cat <<'VPS_HARDEN_SCRIPT'
#!/usr/bin/env bash
# Durcissement d'un VPS Debian 12 qui fait tourner des apps sous Docker.
#
# Normalement lancé par l'outil vps.sh depuis le Mac (vps.sh add, adopt et apply).
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
VPS_HARDEN_SCRIPT
}

audit_script() {
  cat <<'VPS_AUDIT_SCRIPT'
#!/usr/bin/env bash
# Audit de sécurité d'un serveur Debian ou Ubuntu, en LECTURE SEULE : ne modifie rien.
# Lancé en root par « vps.sh audit » et « vps.sh adopt ».
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
      "sudo apt update && sudo apt upgrade, ou activer les mises à jour automatiques (vps.sh adopt)."
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
      "vps.sh adopt les active (sans redémarrage automatique)."
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
    "Un compte sans mot de passe s'ouvre à distance sans rien taper." "vps.sh adopt : connexion par clé uniquement."
  if [[ "$root_login" == yes && $pw_on == yes ]]; then
    finding CRITIQUE ssh "Root peut se connecter avec un mot de passe" \
      "Les robots essaient des mots de passe root en permanence.$attack Un seul mot de passe deviné et le serveur est perdu." \
      "vps.sh adopt : connexion par clé uniquement, root interdit."
  elif [[ $pw_on == yes ]]; then
    finding ELEVE ssh "Connexion SSH par mot de passe autorisée" \
      "Un mot de passe se devine ou se vole, une clé non.$attack" "vps.sh adopt : connexion par clé uniquement."
  else
    finding OK ssh "SSH : connexion par clé uniquement"
  fi
  case "$root_login" in
    no) finding OK ssh "Connexion root interdite" ;;
    forced-commands-only) finding OK ssh "Root limité à des commandes précises" ;;
    *) [[ $pw_on == no ]] && finding NORMAL ssh "Root peut se connecter par clé" \
         "Une clé root volée donne tout le serveur d'un coup, sans passer par un compte normal." \
         "Se connecter avec un compte normal + sudo (vps.sh adopt)." ;;
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
    "Un robot peut essayer des mots de passe sans limite." "vps.sh adopt installe Fail2ban (5 échecs = 1 h de ban)."
else
  finding NORMAL ssh "Aucune protection contre les attaques par force brute" \
    "Moins grave avec des clés, mais les tentatives remplissent les journaux et occupent le serveur." \
    "vps.sh adopt installe Fail2ban (5 échecs = 1 h de ban)."
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
    "Tout programme qui écoute sur le réseau est joignable depuis Internet." "sudo ufw default deny incoming (vps.sh adopt le fait)." ;;
  iptables|nftables) finding OK pare-feu "Pare-feu $fw actif (hors UFW)" ;;
  none) finding ELEVE pare-feu "Aucun pare-feu actif" \
    "Tout programme qui écoute sur le réseau est joignable depuis Internet, même par erreur." \
    "vps.sh adopt active UFW en gardant les ports que tu choisis." ;;
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
VPS_AUDIT_SCRIPT
}

# --- Lancement --------------------------------------------------------------
check_update

if (($# == 0)); then
  if [[ -t 0 ]]; then cmd_menu; else usage; fi
  exit 0
fi
CMD=$1
shift
case $CMD in
  init)   cmd_init ;;
  add)    cmd_add "$@" ;;
  adopt)  cmd_adopt "$@" ;;
  audit)  cmd_audit "$@" ;;
  list|ls) cmd_list ;;
  keys)   cmd_keys ;;
  addkey) cmd_addkey "$@" ;;
  delkey) cmd_delkey "$@" ;;
  sync)   cmd_sync "$@" ;;
  apply)  cmd_apply "$@" ;;
  rm)     cmd_rm "$@" ;;
  update) cmd_update ;;
  menu)   cmd_menu ;;
  version|--version) echo "vps.sh $VPS_VERSION" ;;
  help|-h|--help) usage ;;
  *) usage; exit 1 ;;
esac
