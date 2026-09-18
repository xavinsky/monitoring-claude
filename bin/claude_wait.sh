#!/usr/bin/env bash
# Verification combinee, en un seul appel, de tout ce qui doit etre au vert
# avant de lancer une tache non urgente/lourde :
#   1. Quota Claude Code (session 5h + semaine 7j + plafond Fable 7j) vs
#      la ligne de pacing (voir www/template.html : droite lineaire de 30%
#      en debut de periode a 90% en fin de periode). Interroge l'API
#      Anthropic en direct a chaque appel (aucun token de modele consomme).
#   2. Heures de pointe Anthropic (jours ouvrables 13h-19h UTC). N'appelle
#      pas promoclock.co, service maintenu benevolement par un tiers : le
#      planning etant fixe et public, il est recalcule localement (meme
#      regle que www/template.html). Le libelle de vitesse
#      ("normal"/"reduced") vient du dernier releve de log-peak-status.sh
#      dans peak-status.csv, pour l'affichage seulement.
#
# Installe par install.sh en lien symbolique ~/.local/bin/claude_wait.sh,
# le chemin qu'utilise le skill quota-zone-gate.
#
# Usage : claude_wait.sh [--fable]
#   --fable : la tache tournera sur un modele Fable. Sans cette option, le
#             plafond Fable est affiche mais ne bloque pas : une tache sur
#             Opus/Sonnet ne consomme pas ce plafond.
set -euo pipefail

fable_task=false
for arg in "$@"; do
  case "$arg" in
    --fable) fable_task=true ;;
    *) echo "Usage : $0 [--fable]" >&2; exit 2 ;;
  esac
done

REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=bin/lib-anthropic.sh
. "$REPO_DIR/bin/lib-anthropic.sh"

PEAK_CSV="$HOME/.config/monitoring-claude/peak-status.csv"

# --- 1. Quota usage (session 5h / semaine 7j / Fable 7j) ---

session_usage="" session_reset="" weekly_usage="" weekly_reset="" tier=""
fable_usage="" fable_reset=""
token=$(oauth_token)
if [ -n "$token" ]; then
  if usage_body=$(anthropic_get "$token" /api/oauth/usage); then
    session_usage=$(echo "$usage_body" | jq -r '.five_hour.utilization // empty')
    session_reset=$(echo "$usage_body" | jq -r '.five_hour.resets_at // empty')
    weekly_usage=$(echo "$usage_body" | jq -r '.seven_day.utilization // empty')
    weekly_reset=$(echo "$usage_body" | jq -r '.seven_day.resets_at // empty')
    # Plafond hebdo propre a Fable (absent si le plan n'en a pas) : meme
    # periode de 7j que la semaine, mais son % est relatif au plafond Fable.
    fable_usage=$(echo "$usage_body" | jq -r "${FABLE_LIMIT_FILTER}.percent // empty")
    fable_reset=$(echo "$usage_body" | jq -r "${FABLE_LIMIT_FILTER}.resets_at // empty")
  fi
  # Les % ci-dessus sont relatifs au quota du plan : on rappelle lequel.
  tier=$(rate_limit_tier "$token")
fi

# --- 2. Heures de pointe (calcul local + vitesse depuis le CSV) ---

peak_speed=""
if [ -f "$PEAK_CSV" ]; then
  last_peak_line=$(tail -n1 "$PEAK_CSV")
  if [ "$last_peak_line" != "timestamp,status,is_peak,is_off_peak,is_weekend,session_limit_speed,next_change,minutes_until_change" ] && [ -n "$last_peak_line" ]; then
    IFS=',' read -r _ts _status _is_peak _is_off_peak _is_weekend peak_speed _next_change _minutes <<< "$last_peak_line"
  fi
fi

if [ -z "$session_usage" ]; then
  echo "Erreur : la verification du quota usage a echoue (API Anthropic inaccessible ou token absent/expire)." >&2
  exit 1
fi

python3 - "$session_usage" "$session_reset" "$weekly_usage" "$weekly_reset" "$peak_speed" "$tier" "$fable_usage" "$fable_reset" "$fable_task" <<'PYEOF'
import sys
from datetime import datetime, timedelta, timezone

session_usage, session_reset, weekly_usage, weekly_reset, peak_speed, tier, fable_usage, fable_reset, fable_task = sys.argv[1:10]
fable_task = fable_task == "true"

# Les pourcentages de quota sont relatifs au quota du plan : un 60% en Pro
# et un 60% en Max 5x ne representent pas la meme consommation absolue.
TIER_LABELS = {
    "default_claude_ai": "Pro",
    "default_claude_max_5x": "Max 5x",
    "default_claude_max_20x": "Max 20x",
}
print(f"{'Abonnement':14s}: {TIER_LABELS.get(tier, tier) if tier else 'inconnu'} (les % ci-dessous sont relatifs au quota de ce plan)")

SESSION_PERIOD = 5 * 3600
WEEKLY_PERIOD = 7 * 24 * 3600
now_dt = datetime.now(timezone.utc)
now = now_dt.timestamp()


def fmt_duration(seconds):
    seconds = max(0, int(round(seconds)))
    h, m = divmod(seconds // 60, 60)
    return f"{m}min" if h == 0 else f"{h}h{m:02d}"


PACING_START = 30.0
PACING_END = 90.0


def pacing_threshold(t, period_start, period_end):
    frac = (t - period_start) / (period_end - period_start)
    frac = min(max(frac, 0.0), 1.0)
    return PACING_START + frac * (PACING_END - PACING_START)


# Marge ajoutee a l'heure de sortie de zone alerte pour fixer l'heure de
# reprise : l'API renvoie des % entiers, donc l'heure de croisement calculee
# est approximative (1 point = 5 min sur la session, 2h48 sur la semaine).
REPRISE_MARGIN = {SESSION_PERIOD: 2 * 60, WEEKLY_PERIOD: 10 * 60}


# Heure de reprise (datetime locale) pour un instant donne : arrondie a la
# minute superieure, et jamais pile sur :00 ou :30, car un reveil programme
# par cron a ces minutes peut partir jusqu'a 90 s en avance.
def reprise_at(ts):
    dt = datetime.fromtimestamp(ts, tz=timezone.utc).astimezone()
    if dt.second or dt.microsecond:
        dt = dt.replace(second=0, microsecond=0) + timedelta(minutes=1)
    if dt.minute in (0, 30):
        dt += timedelta(minutes=1)
    return dt


def wait_for_standard(usage, reset_iso, period_seconds):
    if not reset_iso:
        return None, None
    period_end = datetime.fromisoformat(reset_iso).timestamp()
    period_start = period_end - period_seconds
    if usage <= pacing_threshold(now, period_start, period_end):
        return 0.0, None
    if usage > PACING_END:
        return period_end - now, "reset"
    frac = (usage - PACING_START) / (PACING_END - PACING_START)
    crossing = period_start + frac * period_seconds
    return crossing - now, None


# Retourne le delai avant l'heure de reprise conseillee (sortie de zone
# alerte + marge), 0 si rien ne bloque.
def report_usage(label, usage_str, reset_iso, period_seconds):
    if not usage_str:
        print(f"{label:14s}: verification indisponible (API usage inaccessible).")
        return 0.0
    usage = float(usage_str)
    wait_s, note = wait_for_standard(usage, reset_iso, period_seconds)
    if wait_s is None:
        # Pas de date de reset : aucune fenetre ouverte (typiquement la
        # session 5h quand rien n'a tourne depuis plus de 5h).
        print(f"{label:14s}: {usage:.0f}% - aucune fenetre en cours.")
        return 0.0
    if wait_s <= 0:
        print(f"{label:14s}: {usage:.0f}% - deja en zone STANDARD.")
        return 0.0
    fmt = '%H:%M' if period_seconds == SESSION_PERIOD else '%d/%m %H:%M'
    margin = REPRISE_MARGIN[period_seconds]
    when = datetime.fromtimestamp(now + wait_s, tz=timezone.utc).astimezone().strftime(fmt)
    when_reprise = reprise_at(now + wait_s + margin).strftime(fmt)
    suffix = f" (au reset, le seuil plafonne a {PACING_END:.0f}%)" if note == "reset" else ""
    print(f"{label:14s}: {usage:.0f}% - zone ALERTE - retour en zone standard dans {fmt_duration(wait_s)} (vers {when}){suffix}"
          f" - reprise a {when_reprise} (+{margin // 60}min)")
    return wait_s + margin


session_wait = report_usage("Session (5h)", session_usage, session_reset, SESSION_PERIOD)
weekly_wait = report_usage("Semaine (7j)", weekly_usage, weekly_reset, WEEKLY_PERIOD)
# Plafond Fable : meme regle de pacing que la semaine, mais ne bloque que
# les taches Fable (--fable). Pas de ligne du tout si le plan n'a pas de
# plafond Fable.
fable_wait = report_usage("Fable (7j)", fable_usage, fable_reset, WEEKLY_PERIOD) if fable_usage else 0.0
if fable_wait > 0 and not fable_task:
    print(f"{'':14s}  (ignore : tache non Fable - relancer avec --fable si elle tourne sur Fable)")
    fable_wait = 0.0


# Heures de pointe : jours ouvrables (lundi-vendredi) 13h-19h UTC, jamais
# le week-end - meme regle fixe que le hachurage du graphe Quota 5h dans
# www/template.html, recalculee ici plutot que de dependre d'un appel
# reseau ou d'un CSV loggue une fois par jour (qui serait systematiquement
# perime des qu'on passe la frontiere peak/off-peak dans la journee).
def is_peak_at(dt):
    return dt.weekday() <= 4 and 13 <= dt.hour < 19


is_peak_now = is_peak_at(now_dt)
if is_peak_now:
    next_change_dt = now_dt.replace(hour=19, minute=0, second=0, microsecond=0)
else:
    candidate = now_dt.replace(hour=13, minute=0, second=0, microsecond=0)
    if candidate <= now_dt:
        candidate += timedelta(days=1)
    while candidate.weekday() > 4:
        candidate += timedelta(days=1)
    next_change_dt = candidate

peak_wait = max(0.0, (next_change_dt - now_dt).total_seconds())
speed_txt = f" - vitesse '{peak_speed}'" if peak_speed and not is_peak_now else ""
when = next_change_dt.astimezone().strftime(" (vers %H:%M)")
if is_peak_now:
    print(f"Heures creuses : NON (heures de pointe en cours) - retour en heures creuses dans {fmt_duration(peak_wait)}{when}.")
else:
    print(f"Heures creuses : OUI (hors heures de pointe){speed_txt} - prochaine periode de pointe dans {fmt_duration(peak_wait)}{when}.")

# --- Recommandation combinee, pour une tache NON URGENTE uniquement ---
# Toutes les dimensions bloquent symetriquement (session 5h, semaine 7j,
# Fable 7j pour une tache Fable, heures de pointe) : le blocage global est
# le plus long des delais encore actifs.
# La semaine peut representer une trentaine d'heures d'attente - assume,
# c'est voulu (voir skill quota-zone-gate) : on prefere attendre plutot que
# de continuer a consommer alors qu'on est deja au-dessus du pacing.
overall_wait = max(session_wait, weekly_wait, fable_wait, peak_wait if is_peak_now else 0.0)
print()
if overall_wait <= 0:
    print(f"=> Tache non urgente : OK, rien ne bloque actuellement (session standard + semaine standard{' + Fable standard' if fable_usage and fable_task else ''} + heures creuses).")
else:
    reprise = reprise_at(now + overall_wait)
    overall_wait = (reprise - now_dt).total_seconds()
    # Format avec date si l'attente depasse ~20h (sinon HH:MM seul serait ambigu)
    fmt = '%d/%m %H:%M' if overall_wait > 20 * 3600 else '%H:%M'
    when_overall = reprise.strftime(fmt)
    blockers = []
    if session_wait > 0:
        blockers.append("session en zone alerte")
    if weekly_wait > 0:
        blockers.append("semaine en zone alerte")
    if fable_wait > 0:
        blockers.append("Fable en zone alerte")
    if is_peak_now:
        blockers.append("heures de pointe")
    print(f"=> Tache non urgente : ATTENDRE {fmt_duration(overall_wait)} (jusqu'a {when_overall}) - {' + '.join(blockers)}.")
    # Heure de reprise sous forme exploitable pour programmer le reveil
    # (cron one-shot en heure locale, ou delai en secondes).
    print(f"=> Reprise : {reprise.isoformat(timespec='minutes')} - cron \"{reprise.minute} {reprise.hour} {reprise.day} {reprise.month} *\" - delai {int(overall_wait)} s")
PYEOF
