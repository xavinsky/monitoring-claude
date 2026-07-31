#!/usr/bin/env python3
"""Genere les captures du README a partir de donnees de quota fictives.

Deux profils, Pro et Max 5x, en vue standard et compacte. Les donnees
simulent trois semaines d'usage : journees de travail et soirees, nuits
machine eteinte, taches non urgentes lancees derriere le skill
quota-zone-gate (plateaux quand il bloque), un pic urgent qui touche la
zone alerte dans la fenetre 5h en cours, et en Max 5x un jour Fable par
semaine. Aucune jauge ne depasse sa ligne de pacing de plus de 2 points. Chaque semaine complete finit
dans la plage de consommation du profil, et l'etat affiche est en zone
standard. Rien n'est lu ni ecrit dans les donnees reelles.

Usage : docs/screenshots/generer-captures.py   (necessite google-chrome)
"""
import random
import subprocess
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

OUT_DIR = Path(__file__).resolve().parent
REPO_DIR = OUT_DIR.parent.parent

TICK = timedelta(minutes=10)
DAY = timedelta(days=1)
SESSION = timedelta(hours=5)
WEEK = timedelta(days=7)
HEADER = "timestamp,session_usage,session_reset_at,weekly_usage,weekly_reset_at,rate_limit_tier,fable_usage,fable_reset_at"

SCENARIOS = {
    # weekly_range  : % du quota 7j consomme en fin de semaine
    # sess_per_week : % de session 5h consommes par % de quota 7j
    # fable         : un jour par semaine ou les taches tournent sur Fable
    "pro": dict(tier="default_claude_ai", weekly_range=(40, 75), sess_per_week=10.0, fable=False),
    "max5x": dict(tier="default_claude_max_5x", weekly_range=(20, 55), sess_per_week=16.0, fable=True),
}

PACING_START, PACING_END = 30.0, 90.0
BURST_TICKS, BURST_SESSION = 6, (8.0, 11.0)  # % de session par tick de rafale
TASK_TICKS = (2, 5)


def busy_fraction(p):
    """Part du temps passee en tache quand une tache demarre avec la probabilite
    p a chaque tick libre et dure TASK_TICKS en moyenne."""
    length = sum(TASK_TICKS) / 2
    return p * length / (1 + p * length)


def iso(dt):
    return dt.astimezone(timezone.utc).isoformat()


# Depassement maximal au-dessus de la ligne de pacing, en points de %. Marge
# de 0.5 pour que la valeur arrondie du CSV reste dans la limite.
MAX_OVERSHOOT = 2.0 - 0.5


def pacing_line(t, period_end, period):
    frac = min(max((t - (period_end - period)) / period, 0.0), 1.0)
    return PACING_START + frac * (PACING_END - PACING_START)


def under_pacing(value, t, period_end, period):
    """Vrai si value est sous la ligne de pacing a l'instant t (zone standard)."""
    return value <= pacing_line(t, period_end, period)


def headroom(value, t, period_end, period):
    """Marge avant de depasser la ligne de pacing de plus de MAX_OVERSHOOT."""
    return max(0.0, pacing_line(t, period_end, period) + MAX_OVERSHOOT - value)


def activity_probability(t):
    local = t.astimezone()
    wd, h = local.weekday(), local.hour + local.minute / 60
    if wd < 5:
        if 9 <= h < 12.5 or 14 <= h < 19:
            return 0.7
        if 20.5 <= h < 23.5:
            return 0.35
        return 0.0
    return 0.2 if 10 <= h < 18 else 0.0


def local_day_index(t, period_start):
    return (t.astimezone().date() - period_start.astimezone().date()).days


def plan_week(rng, period_start, weekly_range, sess_per_week, fable, forced_burst_day=None):
    """Budget hebdo reparti par jour calendaire local, jour Fable et jours a pic."""
    target = rng.uniform(*weekly_range)
    ticks_by_day = {}
    t = period_start
    while t < period_start + WEEK:
        ticks_by_day.setdefault(local_day_index(t, period_start), []).append(t)
        t += TICK
    days = []
    for i in range(len(ticks_by_day)):
        ticks = ticks_by_day[i]
        day_start = ticks[0]
        expected = sum(busy_fraction(activity_probability(t)) for t in ticks)
        weekday = day_start.astimezone().weekday() < 5
        weight = (rng.choice([0.5, 0.8, 1.0, 1.2, 1.5]) if weekday else 0.25) if expected else 0.0
        burst = weekday and (rng.random() < 0.3 or i == forced_burst_day)
        days.append(dict(expected=expected, weight=weight, weekday=weekday, burst=burst,
                         forced=i == forced_burst_day))
    # Le budget hebdo des rafales est deduit de celui des taches normales.
    burst_weekly = BURST_TICKS * sum(BURST_SESSION) / 2 / sess_per_week
    target = max(5.0, target - burst_weekly * sum(d["burst"] for d in days))
    total = sum(d["weight"] for d in days)
    for d in days:
        d["rate"] = target * d["weight"] / total / d["expected"] if d["expected"] else 0.0
    weekdays = [i for i, d in enumerate(days) if d["weight"] and d["weekday"]]
    # Semaine en cours : jour Fable deja passe, pour que la carte Fable ait une valeur.
    if forced_burst_day is not None:
        weekdays = [i for i in weekdays if i < forced_burst_day] or weekdays
    fable_day = rng.choice(weekdays) if fable and weekdays else None
    if fable_day is not None:
        days[fable_day]["rate"] *= 1.5
    return days, fable_day


def generate(tier, weekly_range, sess_per_week, fable, seed):
    rng = random.Random(seed)
    now = datetime.now(timezone.utc).replace(second=0, microsecond=0)
    now -= timedelta(minutes=now.minute % 10)
    start = now - timedelta(days=23)

    # Reset hebdo a 08:00 UTC, ~2.7 jours apres maintenant
    weekly_reset = (now + timedelta(days=2, hours=16)).replace(hour=8, minute=0)
    while weekly_reset - WEEK > start:
        weekly_reset -= WEEK

    current_reset = weekly_reset
    while current_reset <= now:
        current_reset += WEEK
    today = local_day_index(now, current_reset - WEEK)

    rows, week_ends = [], []
    state_at_now = None
    forced_burst_done = False
    t = start
    session_reset = None
    session = weekly = fable_part = 0.0
    task_left = burst_left = 0
    fable_task = False
    def plan_for(period_start):
        forced = today if period_start == current_reset - WEEK else None
        return plan_week(rng, period_start, weekly_range, sess_per_week, fable, forced)

    plan, fable_day = plan_for(weekly_reset - WEEK)
    nights = {}
    while t < current_reset:
        if t >= weekly_reset:
            week_ends.append(weekly)
            weekly = fable_part = 0.0
            plan, fable_day = plan_for(weekly_reset)
            weekly_reset += WEEK
        if session_reset and t >= session_reset:
            session_reset, session = None, 0.0
        day_index = local_day_index(t, weekly_reset - WEEK)
        day = plan[day_index]
        local = t.astimezone()

        # Pic : rafale de travail urgent a l'ouverture d'une fenetre 5h, lancee
        # sans passer par le skill, qui fait monter la session en zone rouge.
        # Le dashboard ne dessine les zones que pour la fenetre en cours : le
        # pic du jour est donc place dans la fenetre ouverte 2 a 4h avant
        # maintenant, les autres en journee.
        if day["burst"] and burst_left == 0 and session_reset is None:
            if day["forced"]:
                start_ok = now - timedelta(hours=4) <= t <= now - timedelta(hours=2) and activity_probability(t) > 0
            else:
                start_ok = 9 <= local.hour < 16 and rng.random() < activity_probability(t)
            if start_ok:
                burst_left = BURST_TICKS
                day["burst"] = False

        # Taches non urgentes lancees derriere le skill quota-zone-gate : il ne
        # verifie qu'au demarrage (session et semaine sous la ligne, plafond
        # Fable en plus pour une tache Fable) ; une tache lancee va au bout et
        # peut depasser un peu la ligne, sinon la courbe reste a plat.
        if burst_left == 0 and task_left == 0 and rng.random() < activity_probability(t):
            fable_task = day_index == fable_day
            if ((session_reset is None or under_pacing(session, t, session_reset, SESSION))
                    and under_pacing(weekly, t, weekly_reset, WEEK)
                    and (not fable_task or under_pacing(fable_part * 2, t, weekly_reset, WEEK))):
                task_left = rng.randint(*TASK_TICKS)

        wanted = 0.0
        if burst_left > 0:
            burst_left -= 1
            wanted = rng.uniform(*BURST_SESSION) / sess_per_week
            fable_task = day_index == fable_day
        elif task_left > 0:
            task_left -= 1
            wanted = day["rate"] * rng.uniform(0.6, 1.4)
        if wanted:
            if session_reset is None:
                session_reset = t + SESSION
            # Aucune jauge ne passe plus de MAX_OVERSHOOT au-dessus de sa ligne.
            wdelta = min(wanted, 100 - weekly, (100 - session) / sess_per_week,
                         headroom(session, t, session_reset, SESSION) / sess_per_week,
                         headroom(weekly, t, weekly_reset, WEEK))
            if fable_task:
                wdelta = min(wdelta, headroom(fable_part * 2, t, weekly_reset, WEEK) / 2)
            weekly += wdelta
            session += wdelta * sess_per_week
            if fable_task:
                fable_part += wdelta
            if day["forced"] and not under_pacing(session, t, session_reset, SESSION):
                forced_burst_done = True

        if t > now:
            t += TICK
            continue
        if t == now:
            state_at_now = (session, session_reset, weekly, fable_part, weekly_reset)
        date = local.date()
        if date not in nights:
            nights[date] = rng.random() < 0.7
        h = local.hour + local.minute / 60
        machine_on = not (nights[date] and (h >= 23.8 or h < 7.5))
        if now - t < timedelta(hours=3) or machine_on:
            fable_cols = ",,"
            if fable:
                fable_cols = f",{round(min(100.0, fable_part * 2))},{iso(weekly_reset - timedelta(seconds=1))}"
            rows.append(
                f"{t.strftime('%Y-%m-%dT%H:%M:%SZ')},{round(session)}.0,"
                f"{iso(session_reset) if session_reset else ''},{round(weekly)}.0,{iso(weekly_reset)},{tier}{fable_cols}"
            )
        t += TICK

    # Semaines completes dans la plage demandee (la 1re, partielle, exclue ;
    # la semaine en cours est simulee jusqu'a son reset), et etat a
    # maintenant (valeurs arrondies, comme dans le CSV) sous la ligne
    # partout, avec une session 5h ouverte contenant le pic du jour.
    week_ends.append(weekly)
    full_weeks_ok = all(weekly_range[0] <= w <= weekly_range[1] for w in week_ends[1:])
    session, session_reset, weekly, fable_part, weekly_reset = state_at_now
    final_ok = (forced_burst_done and session_reset is not None
                and under_pacing(round(session), now, session_reset, SESSION)
                and under_pacing(round(weekly), now, weekly_reset, WEEK)
                and under_pacing(round(min(100.0, fable_part * 2)), now, weekly_reset, WEEK))
    if not (full_weeks_ok and final_ok):
        return None
    return HEADER + "\n" + "\n".join(rows) + "\n"


def render(csv_text, compact):
    template = (REPO_DIR / "www" / "template.html").read_text()
    escaped = csv_text.replace("\\", "\\\\").replace("`", "\\`").replace("${", "\\${").replace("</", "<\\/")
    html = template.replace("__CCUSAGE_CSV__", escaped)
    html = html.replace("setTimeout(() => location.reload(), 2 * 60 * 1000);", "")
    if compact:
        html = html.replace("compact = localStorage.getItem(COMPACT_KEY) === '1';", "compact = true;")
    return html


def screenshot(html_path, png_path, width, height):
    subprocess.run(
        ["google-chrome", "--headless=new", "--disable-gpu", "--hide-scrollbars",
         "--force-device-scale-factor=2", f"--window-size={width},{height}",
         "--virtual-time-budget=3000", f"--screenshot={png_path}", f"file://{html_path}"],
        check=True, capture_output=True, timeout=60,
    )


# Taille de fenetre par vue
VIEWS = {name: (("normal", False, (1700, 1010)), ("compact", True, (1250, 550))) for name in SCENARIOS}

with tempfile.TemporaryDirectory() as tmp:
    for name, params in SCENARIOS.items():
        # Premiere graine dont les donnees respectent toutes les contraintes
        seed = 1
        while (csv_text := generate(seed=seed, **params)) is None:
            seed += 1
        for view, compact, size in VIEWS[name]:
            html_path = Path(tmp) / f"dashboard-{name}-{view}.html"
            html_path.write_text(render(csv_text, compact))
            png_path = OUT_DIR / f"dashboard-{name}-{view}.png"
            screenshot(html_path, png_path, *size)
            print(png_path)
