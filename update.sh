#!/usr/bin/env bash
# Met a jour monitoring-claude : recupere la derniere version du depot
# (fast-forward uniquement) puis relance install.sh, qui regenere les
# unites systemd, les liens et le dashboard. Les scripts etant lances depuis
# le depot, le nouveau code est actif des le pull ; les CSV existants sont
# mis a niveau au prochain releve.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

if git -C "$REPO_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
  echo "==> git pull --ff-only"
  git -C "$REPO_DIR" pull --ff-only
else
  echo "==> Pas de branche distante suivie : pas de pull, reinstallation seule."
fi

exec "$REPO_DIR/install.sh"
