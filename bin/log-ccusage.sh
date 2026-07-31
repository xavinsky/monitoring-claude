#!/usr/bin/env bash
# Ajoute a usage.csv une mesure du quota Claude Code (session 5h, semaine
# 7j, plafond Fable 7j) puis regenere le dashboard. Lance toutes les 10 min
# par le timer systemd claude-usage-log.
#
# Chaque ligne embarque aussi le palier d'abonnement (`rate_limit_tier`)
# en vigueur au moment de la mesure. Les pourcentages renvoyes par l'API
# sont relatifs au quota du plan : un 60% en Pro et un 60% en Max 5x ne
# representent pas la meme consommation absolue, donc sans cette colonne
# l'historique devient illisible des qu'on change d'abonnement.
#
# Les colonnes fable_* suivent la limite hebdomadaire propre aux modeles
# Fable (entree `weekly_scoped` de `limits[]`) : sur Max, Fable a son propre
# plafond a l'interieur du quota 7j, qui peut etre atteint alors que le
# quota 7j global ne l'est pas. Le % est relatif a ce plafond Fable.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=bin/lib-anthropic.sh
. "$REPO_DIR/bin/lib-anthropic.sh"

DATA_DIR="$HOME/.config/monitoring-claude"
LOG_FILE="$DATA_DIR/usage.csv"

CSV_HEADER="timestamp,session_usage,session_reset_at,weekly_usage,weekly_reset_at,rate_limit_tier,fable_usage,fable_reset_at"

mkdir -p "$DATA_DIR"

# Mise a niveau des CSV crees avant l'ajout des colonnes palier et Fable :
# les colonnes manquantes sont laissees vides sur l'historique plutot que
# de supposer des valeurs jamais mesurees.
if [ ! -f "$LOG_FILE" ]; then
  echo "$CSV_HEADER" > "$LOG_FILE"
elif ! head -n1 "$LOG_FILE" | grep -q 'rate_limit_tier'; then
  tmp=$(mktemp)
  { echo "$CSV_HEADER"; tail -n +2 "$LOG_FILE" | sed 's/$/,,,/'; } > "$tmp"
  mv "$tmp" "$LOG_FILE"
elif ! head -n1 "$LOG_FILE" | grep -q 'fable_usage'; then
  tmp=$(mktemp)
  { echo "$CSV_HEADER"; tail -n +2 "$LOG_FILE" | sed 's/$/,,/'; } > "$tmp"
  mv "$tmp" "$LOG_FILE"
fi

# Sans token (Claude Code jamais connecte), ou si l'appel echoue (token
# expire, rate limit, reseau), on saute ce tick : le suivant reessaiera.
token=$(oauth_token)
[ -n "$token" ] || exit 0
body=$(anthropic_get "$token" /api/oauth/usage) || exit 0

session_usage=$(echo "$body" | jq -r '.five_hour.utilization // empty')
session_reset=$(echo "$body" | jq -r '.five_hour.resets_at // empty')
weekly_usage=$(echo "$body" | jq -r '.seven_day.utilization // empty')
weekly_reset=$(echo "$body" | jq -r '.seven_day.resets_at // empty')

[ -n "$session_usage" ] && [ -n "$weekly_usage" ] || exit 0

# Colonnes vides si le plan n'a pas de plafond Fable.
fable_usage=$(echo "$body" | jq -r "${FABLE_LIMIT_FILTER}.percent // empty")
fable_reset=$(echo "$body" | jq -r "${FABLE_LIMIT_FILTER}.resets_at // empty")

# Un echec sur le profil n'est pas bloquant : la mesure est gardee avec un
# palier vide.
tier=$(rate_limit_tier "$token")

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "${ts},${session_usage},${session_reset},${weekly_usage},${weekly_reset},${tier},${fable_usage},${fable_reset}" >> "$LOG_FILE"

python3 "$REPO_DIR/bin/generate-page.py"
