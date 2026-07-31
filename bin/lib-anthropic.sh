# shellcheck shell=bash
# Fonctions communes d'acces aux API de compte Anthropic, a sourcer depuis
# les scripts de bin/ (pas executable seul).
#
# Utilise le token OAuth deja stocke localement par Claude Code. Ce sont
# des lectures de compte (quota, profil), pas des appels au modele : aucun
# token de modele consomme. Claude Code rafraichit lui-meme ce token pendant
# son utilisation normale, on lit simplement la valeur presente sur disque.

CREDS_FILE="$HOME/.claude/.credentials.json"

# Plafond hebdomadaire propre aux modeles Fable dans la reponse de
# /api/oauth/usage (absent si le plan n'en a pas).
# shellcheck disable=SC2034  # utilise par les scripts qui sourcent ce fichier
FABLE_LIMIT_FILTER='[.limits[]? | select(.kind == "weekly_scoped" and .scope.model.display_name == "Fable")][0]'

# Affiche le token OAuth de Claude Code, ou rien s'il est absent.
oauth_token() {
  [ -f "$CREDS_FILE" ] || return 0
  jq -r '.claudeAiOauth.accessToken // empty' "$CREDS_FILE" 2>/dev/null || true
}

# anthropic_get TOKEN CHEMIN : affiche le corps de la reponse et retourne 0
# si HTTP 200, retourne 1 sinon (reseau, token expire, rate limit...).
# Les en-tetes passent par l'entree standard (printf est un builtin) : le
# token n'apparait jamais dans la ligne de commande de curl, donc pas dans
# `ps` pour les autres utilisateurs de la machine.
anthropic_get() {
  local token="$1" path="$2" response
  response=$(printf 'Authorization: Bearer %s\nanthropic-beta: oauth-2025-04-20\n' "$token" \
    | curl -s --max-time 10 -w $'\n%{http_code}' -H @- "https://api.anthropic.com${path}") || return 1
  [ "$(printf '%s\n' "$response" | tail -n1)" = "200" ] || return 1
  printf '%s\n' "$response" | sed '$d'
}

# Palier d'abonnement (ex. default_claude_max_5x), ou rien en cas d'echec.
# Lu sur le profil et non dans `.credentials.json`, dont le `rateLimitTier`
# reste fige sur l'ancienne valeur apres un changement d'abonnement.
rate_limit_tier() {
  local profile
  profile=$(anthropic_get "$1" /api/oauth/profile) || return 0
  printf '%s\n' "$profile" | jq -r '.organization.rate_limit_tier // empty' 2>/dev/null | tr -d ',\n' || true
}
