#!/usr/bin/env bash
# Desinstalle ce que install.sh a pose hors du depot (timers systemd, liens
# du skill et de claude_wait.sh), puis demande s'il faut aussi supprimer les
# donnees collectees. --purge les supprime sans demander ; sans terminal
# interactif et sans --purge, elles sont conservees.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
UNIT_DIR="$HOME/.config/systemd/user"
SKILLS_DIR="$HOME/.claude/skills"
BIN_DIR="$HOME/.local/bin"
DATA_DIR="$HOME/.config/monitoring-claude"

PURGE=0
for arg in "$@"; do
  case "$arg" in
    --purge) PURGE=1 ;;
    *) echo "Usage : $0 [--purge]" >&2; exit 2 ;;
  esac
done

for name in claude-usage-log claude-peak-status; do
  echo "==> Arret et desactivation de $name.timer"
  systemctl --user disable --now "$name.timer" 2>/dev/null || true
  rm -f "$UNIT_DIR/$name.service" "$UNIT_DIR/$name.timer"
done
systemctl --user daemon-reload

# remove_link LIEN CIBLE : supprime le lien seulement s'il pointe vers ce
# depot (un autre clone installe par-dessus n'est pas touche).
remove_link() {
  local link="$1" target="$2"
  if [ -L "$link" ] && [ "$(readlink -f "$link")" = "$(readlink -f "$target")" ]; then
    rm -f "$link"
    echo "==> Lien supprime : $link"
  elif [ -e "$link" ] || [ -L "$link" ]; then
    echo "==> Laisse en place (ne pointe pas vers ce depot) : $link"
  fi
}

remove_link "$SKILLS_DIR/quota-zone-gate" "$REPO_DIR/skills/quota-zone-gate"
remove_link "$BIN_DIR/claude_wait.sh" "$REPO_DIR/bin/claude_wait.sh"

echo
echo "==> Desinstalle."

# Donnees : les CSV et la page generee, qui les embarque.
purge_data() {
  rm -rf "$DATA_DIR"
  rm -f "$REPO_DIR/www/index.html"
  echo "==> Donnees supprimees : $DATA_DIR et www/index.html"
}

if [ ! -d "$DATA_DIR" ]; then
  echo "==> Pas de donnees collectees a supprimer ($DATA_DIR n'existe pas)."
elif [ "$PURGE" = "1" ]; then
  purge_data
elif [ -t 0 ]; then
  read -r -p "Supprimer aussi les donnees collectees dans $DATA_DIR ? [y/N] " reply
  case "$reply" in
    [yY]) purge_data ;;
    *) echo "==> Donnees conservees : $DATA_DIR" ;;
  esac
else
  echo "==> Donnees conservees : $DATA_DIR (relancer avec --purge pour les supprimer)"
fi
