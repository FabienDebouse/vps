#!/usr/bin/env bash
# Télécharge vps.sh dans le dossier courant, puis le lance :
#   curl -fsSL https://raw.githubusercontent.com/FabienDebouse/vps/main/install.sh | bash
#
# Équivalent sans « | bash » :
#   curl -fsSL https://raw.githubusercontent.com/FabienDebouse/vps/main/vps.sh -o vps.sh && chmod +x vps.sh && ./vps.sh
set -euo pipefail

# Tout est dans une fonction appelée à la dernière ligne : avec « curl | bash »,
# le script est ainsi lu en entier avant de s'exécuter.
main() {
  local repo="${VPS_REPO:-FabienDebouse/vps}" branch="${VPS_BRANCH:-main}" base
  base="${VPS_BASE_URL:-https://raw.githubusercontent.com/$repo/$branch}"

  command -v curl >/dev/null || { echo "curl est nécessaire." >&2; exit 1; }
  curl -fsSL "$base/vps.sh" -o vps.sh
  chmod +x vps.sh
  echo "vps.sh téléchargé dans $(pwd)"

  # Avec « curl | bash », l'entrée standard est le script : on répond aux questions
  # depuis le terminal.
  if (exec </dev/tty) 2>/dev/null; then
    exec </dev/tty
  fi
  VPS_NO_UPDATE_CHECK=1 ./vps.sh
}

main "$@"
