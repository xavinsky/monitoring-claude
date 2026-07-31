#!/usr/bin/env bash
# Installe monitoring-claude pour l'utilisateur courant. Le depot est
# l'installation : rien n'est copie, tout ce qui est pose hors du depot
# pointe vers lui.
#   - ~/.config/systemd/user/claude-{usage-log,peak-status}.{service,timer}
#     (unites generees depuis systemd/, avec le chemin de ce depot)
#   - ~/.claude/skills/quota-zone-gate -> skills/quota-zone-gate (lien)
#   - ~/.local/bin/claude_wait.sh      -> bin/claude_wait.sh (lien, chemin
#     stable utilise par le skill)
# Relancable sans risque (idempotent) ; a relancer si le depot est deplace.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
DATA_DIR="$HOME/.config/monitoring-claude"
UNIT_DIR="$HOME/.config/systemd/user"
SKILLS_DIR="$HOME/.claude/skills"
BIN_DIR="$HOME/.local/bin"

# --- Prerequis ---

missing=()
for cmd in curl jq python3 systemctl readlink; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "Erreur : commandes manquantes : ${missing[*]}" >&2
  exit 1
fi
if ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 7))'; then
  echo "Erreur : python3 >= 3.7 requis." >&2
  exit 1
fi

# install_link CIBLE LIEN : cree ou met a jour un lien symbolique, sans
# jamais ecraser un fichier ou dossier reel qui porterait deja ce nom.
install_link() {
  local target="$1" link="$2"
  if [ -e "$link" ] && [ ! -L "$link" ]; then
    echo "Erreur : $link existe deja et n'est pas un lien symbolique - a deplacer ou supprimer a la main." >&2
    exit 1
  fi
  mkdir -p "$(dirname "$link")"
  ln -sfn "$target" "$link"
  echo "    $link -> $target"
}

chmod +x "$REPO_DIR"/bin/claude_wait.sh "$REPO_DIR"/bin/log-*.sh "$REPO_DIR"/bin/generate-page.py \
  "$REPO_DIR"/install.sh "$REPO_DIR"/uninstall.sh "$REPO_DIR"/update.sh

echo "==> Dossier de donnees : $DATA_DIR"
mkdir -p "$DATA_DIR"

# --- Timers systemd ---

# Chemin echappe pour ExecStart entre guillemets (\, " et %), puis pour
# la partie remplacement de sed (\, & et le separateur |).
unit_path() {
  printf '%s' "$1" | sed -e 's/[\\"]/\\&/g' -e 's/%/%%/g' -e 's/[\\&|]/\\&/g'
}

write_unit() {
  local name="$1" script="$2"
  echo "==> Unites systemd : $name"
  sed "s|@EXEC_PATH@|$(unit_path "$REPO_DIR/bin/$script")|" \
    "$REPO_DIR/systemd/$name.service.template" > "$UNIT_DIR/$name.service"
  cp "$REPO_DIR/systemd/$name.timer" "$UNIT_DIR/$name.timer"
}

mkdir -p "$UNIT_DIR"
write_unit claude-usage-log log-ccusage.sh
write_unit claude-peak-status log-peak-status.sh

systemctl --user daemon-reload
systemctl --user enable --now claude-usage-log.timer claude-peak-status.timer

# --- Liens : skill et script de verification ---

echo "==> Liens symboliques"
install_link "$REPO_DIR/skills/quota-zone-gate" "$SKILLS_DIR/quota-zone-gate"
install_link "$REPO_DIR/bin/claude_wait.sh" "$BIN_DIR/claude_wait.sh"

# --- Page ---

echo "==> Generation du dashboard"
python3 "$REPO_DIR/bin/generate-page.py"

echo
echo "==> Installe. Timers :"
systemctl --user list-timers claude-usage-log.timer claude-peak-status.timer --no-pager

echo
echo "Donnees collectees dans : $DATA_DIR/"
echo "Dashboard a ouvrir      : $REPO_DIR/www/index.html"
