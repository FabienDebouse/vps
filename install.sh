#!/usr/bin/env bash
# Installe l'outil vps sur ton Mac :
#   curl -fsSL https://raw.githubusercontent.com/FabienDebouse/vps/main/install.sh | bash
#
# Tout est installé dans ~/.vps. Relancer la commande met l'outil à jour sans rien perdre.
set -euo pipefail

# Tout est dans une fonction appelée à la dernière ligne : avec « curl | bash »,
# le script est ainsi lu en entier avant de s'exécuter.
main() {
  local repo="${VPS_REPO:-FabienDebouse/vps}" branch="${VPS_BRANCH:-main}" base tmp f
  base="${VPS_BASE_URL:-https://raw.githubusercontent.com/$repo/$branch}"

  command -v curl >/dev/null || { echo "curl est nécessaire." >&2; exit 1; }
  command -v ssh >/dev/null || { echo "ssh est nécessaire." >&2; exit 1; }

  tmp=$(mktemp -d)
  # shellcheck disable=SC2064  # $tmp est développé maintenant : la variable locale n'existe plus à la sortie.
  trap "rm -rf '$tmp'" EXIT
  echo "Téléchargement de vps depuis $repo..."
  for f in vps harden-debian12.sh; do
    curl -fsSL "$base/$f" -o "$tmp/$f"
  done
  chmod +x "$tmp/vps"

  # Avec « curl | bash », l'entrée standard est le script : on répond aux questions
  # depuis le terminal.
  if (exec </dev/tty) 2>/dev/null; then
    exec </dev/tty
  fi
  VPS_REPO="$repo" VPS_BRANCH="$branch" bash "$tmp/vps" init
}

main "$@"
