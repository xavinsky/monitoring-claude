#!/usr/bin/env bash
# Ajoute a peak-status.csv un releve du statut heures de pointe / heures
# creuses d'Anthropic, via l'API publique de promoclock.co
# (https://promoclock.co/fr), puis regenere le dashboard. Lance 1x/jour par
# le timer systemd claude-peak-status.
#
# C'est le seul appelant de promoclock.co dans le projet : ce service est
# maintenu benevolement par un tiers, on se limite donc a une requete par
# jour. Le planning etant fixe, bin/claude_wait.sh le recalcule localement
# et ne lit dans ce CSV que le libelle de vitesse.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
DATA_DIR="$HOME/.config/monitoring-claude"
LOG_FILE="$DATA_DIR/peak-status.csv"
USER_AGENT="monitoring-claude (https://github.com/xavinsky/monitoring-claude)"

mkdir -p "$DATA_DIR"

if [ ! -f "$LOG_FILE" ]; then
  echo "timestamp,status,is_peak,is_off_peak,is_weekend,session_limit_speed,next_change,minutes_until_change" > "$LOG_FILE"
fi

response=$(curl -s --max-time 10 -w $'\n%{http_code}' -A "$USER_AGENT" \
  "https://promoclock.co/api/status") || exit 0

http_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | sed '$d')

[ "$http_code" = "200" ] || exit 0

status=$(echo "$body" | jq -r '.status // empty')
# `// empty` traite `false` comme une absence de valeur (comme null) : les
# booleens sont donc convertis explicitement en chaine.
is_peak=$(echo "$body" | jq -r '.isPeak | if . == null then "" else tostring end')
is_off_peak=$(echo "$body" | jq -r '.isOffPeak | if . == null then "" else tostring end')
is_weekend=$(echo "$body" | jq -r '.isWeekend | if . == null then "" else tostring end')
speed=$(echo "$body" | jq -r '.sessionLimitSpeed // empty')
next_change=$(echo "$body" | jq -r '.nextChange // empty')
minutes_until=$(echo "$body" | jq -r '.minutesUntilChange // empty')

[ -n "$status" ] || exit 0

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "${ts},${status},${is_peak},${is_off_peak},${is_weekend},${speed},${next_change},${minutes_until}" >> "$LOG_FILE"

python3 "$REPO_DIR/bin/generate-page.py"
