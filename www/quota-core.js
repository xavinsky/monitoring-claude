// Logique et dessin communs au dashboard (www/template.html, dans lequel
// bin/generate-page.py embarque ce fichier) et au widget Plasma (plasmoid/,
// qui l'importe par un lien symbolique). Aucun acces au DOM : le dessin
// passe par un contexte 2D de canvas, que fournissent aussi bien le
// navigateur que le Canvas QML. Les declarations de haut niveau sont en
// `var`/`function`, les seules exposees par un import JS en QML.
//
// Le calcul de pacing est aussi implemente en Python dans bin/claude_wait.sh
// (meme formule).

var HOUR_MS = 3600 * 1000;
var DAY_MS = 24 * HOUR_MS;
var SESSION_PERIOD_MS = 5 * HOUR_MS;
var WEEKLY_PERIOD_MS = 7 * DAY_MS;

// Au-dela de ce delai, la derniere mesure est probablement perimee (timer
// arrete, machine en veille...).
var STALE_THRESHOLD_MS = 15 * 60 * 1000;

// Lignes de donnees de usage.csv. L'en-tete est ignore, ce qui permet aussi
// de ne lire que la fin du fichier.
function parseUsageCsv(text) {
  return text.split('\n')
    .filter(l => /^\d/.test(l))
    .map(l => l.split(','))
    .filter(c => c.length >= 5 && c[1] !== '' && c[3] !== '')
    .map(c => ({
      ts: new Date(c[0]),
      session: parseFloat(c[1]),
      sessionReset: c[2],
      weekly: parseFloat(c[3]),
      weeklyReset: c[4],
      tier: (c[5] || '').trim(),
      // Limite hebdo propre a Fable, relative a son propre plafond (pas au
      // quota 7j global) ; NaN quand non mesuree ou absente du plan.
      fable: parseFloat(c[6]),
      fableReset: (c[7] || '').trim(),
    }));
}

// Palier d'abonnement (colonne rate_limit_tier du CSV). Les % renvoyes par
// l'API sont relatifs au quota du plan : un 60% en Pro et un 60% en Max 5x
// ne representent pas la meme consommation absolue. Les lignes anterieures
// au suivi du plan ont un palier vide.
var TIER_LABELS = {
  default_claude_ai: 'Pro',
  default_claude_max_5x: 'Max 5x',
  default_claude_max_20x: 'Max 20x',
};

// Libelle lisible d'un palier ; un palier absent du mapping est rendu brut.
function tierName(tier) {
  return tier ? (TIER_LABELS[tier] || tier) : 'inconnu';
}

// Frontieres de changement d'abonnement dans la serie : entre deux points
// consecutifs dont le palier connu differe. Les points au palier vide sont
// ignores - on ne sait pas s'ils encadrent un changement.
function findTierChanges(points) {
  const changes = [];
  let prev = null;
  points.forEach(p => {
    if (!p.tier) return;
    if (prev && prev.tier !== p.tier) {
      changes.push({ ts: p.ts.getTime(), from: prev.tier, to: p.tier });
    }
    prev = p;
  });
  return changes;
}

function pad2(n) {
  return String(n).padStart(2, '0');
}

// "14:37"
function fmtHM(d) {
  return `${pad2(d.getHours())}:${pad2(d.getMinutes())}`;
}

// "22/09"
function fmtDM(d) {
  return `${pad2(d.getDate())}/${pad2(d.getMonth() + 1)}`;
}

// Duree avant ou depuis un reset, telle qu'affichee sur les cartes : "3h05",
// ou "4j 20h" au-dela de 24h.
function fmtResetDuration(ms) {
  ms = Math.abs(ms);
  const h = Math.floor(ms / HOUR_MS);
  const m = Math.floor((ms % HOUR_MS) / 60000);
  if (h >= 24) return `${Math.floor(h / 24)}j ${h % 24}h`;
  return `${h}h${pad2(m)}`;
}

// Age d'une mesure : "7 min", ou "2h05" au-dela d'une heure.
function fmtAge(ms) {
  const h = Math.floor(ms / HOUR_MS);
  const m = Math.floor((ms % HOUR_MS) / 60000);
  if (h > 0) return `${h}h${pad2(m)}`;
  return `${m} min`;
}

// Seuil de pacing pour la periode en cours (du dernier reset moins sa duree,
// jusqu'au prochain reset) : droite lineaire de 30% en debut de periode a
// 90% en fin de periode, proportionnel au temps ecoule. En dessous = zone
// standard, au-dessus = zone alerte.
var PACING_START = 30;
var PACING_END = 90;

function pacingThreshold(t, periodStart, periodEnd) {
  let frac = (t - periodStart) / (periodEnd - periodStart);
  frac = Math.min(Math.max(frac, 0), 1);
  return PACING_START + frac * (PACING_END - PACING_START);
}

// Temps avant que la ligne de pacing ne depasse l'usage actuel, a
// consommation nulle d'ici la. Retourne null si deja en zone standard,
// sinon {waitMs, atReset} (atReset=true si l'usage depasse 90%, auquel cas
// le retour n'arrive qu'au reset).
function waitForStandard(usage, resetIso, periodMs, now) {
  if (!resetIso) return null;
  const periodEnd = new Date(resetIso).getTime();
  const periodStart = periodEnd - periodMs;
  if (usage <= pacingThreshold(now, periodStart, periodEnd)) return null;
  if (usage > PACING_END) return { waitMs: periodEnd - now, atReset: true };
  const frac = (usage - PACING_START) / (PACING_END - PACING_START);
  const crossing = periodStart + frac * periodMs;
  return { waitMs: crossing - now, atReset: false };
}

// 'standard' ou 'alert' selon la ligne de pacing.
function zoneClass(usage, resetIso, periodMs, now) {
  return waitForStandard(usage, resetIso, periodMs, now) ? 'alert' : 'standard';
}

// Etat courant de chaque quota d'apres la derniere mesure : usage, reset,
// zone et, en zone alerte, heure de sortie (ms epoch). fable est null quand
// le plan n'a pas de plafond Fable.
function quotaSummary(points, now) {
  if (!points.length) return null;
  const last = points[points.length - 1];
  const gauge = (usage, reset, periodMs) => {
    const wait = waitForStandard(usage, reset, periodMs, now);
    return {
      usage: usage,
      reset: reset,
      zone: wait ? 'alert' : 'standard',
      exitAt: wait ? now + wait.waitMs : null,
    };
  };
  return {
    last: last,
    ageMs: now - last.ts.getTime(),
    stale: now - last.ts.getTime() > STALE_THRESHOLD_MS,
    tier: last.tier,
    session: gauge(last.session, last.sessionReset, SESSION_PERIOD_MS),
    weekly: gauge(last.weekly, last.weeklyReset, WEEKLY_PERIOD_MS),
    fable: isNaN(last.fable) ? null : gauge(last.fable, last.fableReset, WEEKLY_PERIOD_MS),
  };
}

// Heures de pointe Anthropic (voir promoclock.co) : jours ouvrables,
// 13h-19h UTC (= 15h-21h a Paris en ete). Fixe en UTC dans la definition
// officielle, donc pas de souci de changement d'heure ete/hiver a gerer
// ici. Retourne les intervalles [debut,fin] (ms epoch) qui chevauchent la
// fenetre visible.
function getPeakIntervalsUTC(windowStart, windowEnd) {
  const intervals = [];
  const dayStart = new Date(windowStart);
  dayStart.setUTCHours(0, 0, 0, 0);
  for (let d = dayStart.getTime(); d < windowEnd; d += DAY_MS) {
    const utcDay = new Date(d).getUTCDay(); // 0=dimanche ... 6=samedi
    if (utcDay >= 1 && utcDay <= 5) {
      const peakStart = d + 13 * HOUR_MS;
      const peakEnd = d + 19 * HOUR_MS;
      if (peakEnd > windowStart && peakStart < windowEnd) {
        intervals.push([Math.max(peakStart, windowStart), Math.min(peakEnd, windowEnd)]);
      }
    }
  }
  return intervals;
}

function drawHatchedRect(ctx, x1, y1, x2, y2, color, spacing) {
  if (x2 <= x1) return;
  ctx.save();
  ctx.beginPath();
  ctx.rect(x1, y1, x2 - x1, y2 - y1);
  ctx.clip();
  ctx.strokeStyle = color;
  ctx.lineWidth = 1;
  const h = y2 - y1;
  const w = x2 - x1;
  for (let off = -h; off < w + h; off += spacing) {
    ctx.beginPath();
    ctx.moveTo(x1 + off, y1);
    ctx.lineTo(x1 + off + h, y2);
    ctx.stroke();
  }
  ctx.restore();
}

// Bornes horaires (une par heure pleine) dans [windowStart, windowEnd].
function hourBoundaries(windowStart, windowEnd) {
  const start = Math.ceil(windowStart / HOUR_MS) * HOUR_MS;
  const out = [];
  for (let t = start; t <= windowEnd; t += HOUR_MS) out.push(t);
  return out;
}

// Minuits locaux (un par jour) dans [windowStart, windowEnd].
function localMidnights(windowStart, windowEnd) {
  const out = [];
  let d = new Date(windowStart);
  d.setHours(0, 0, 0, 0);
  if (d.getTime() < windowStart) d = new Date(d.getTime() + DAY_MS);
  for (let t = d.getTime(); t <= windowEnd; t += DAY_MS) out.push(t);
  return out;
}

// Abreviations 3 lettres, alignees sur Date#getDay() (0=dimanche ... 6=samedi).
var DAY_ABBREV_FR = ['Dim', 'Lun', 'Mar', 'Mer', 'Jeu', 'Ven', 'Sam'];
// Mode compact : une seule lettre (D/L/M/M/J/V/S), le double "M" (mardi/
// mercredi) etant leve par la date affichee dessous.
var DAY_ABBREV_FR_COMPACT = ['D', 'L', 'M', 'M', 'J', 'V', 'S'];

// Segment de sortie de zone alerte : a partir de la derniere mesure,
// horizontal au niveau de l'usage actuel jusqu'a ce que la ligne de pacing
// le rattrape (meme calcul que claude_wait.sh, sans sa marge de reprise).
// Retourne l'heure de sortie (ms epoch), ou null hors zone alerte.
function drawExitSegment(ctx, last, key, resetKey, periodMs, now, x, y, xMin, xMax, color) {
  if (!last || isNaN(last[key])) return null;
  const wait = waitForStandard(last[key], last[resetKey], periodMs, now);
  if (!wait) return null;
  const exitT = now + wait.waitMs;
  const x1 = Math.max(x(last.ts.getTime()), xMin);
  const x2 = Math.min(x(exitT), xMax);
  const yy = y(last[key]);
  ctx.strokeStyle = color;
  ctx.lineWidth = 2;
  ctx.setLineDash([6, 4]);
  ctx.beginPath();
  ctx.moveTo(x1, yy);
  ctx.lineTo(x2, yy);
  ctx.stroke();
  ctx.setLineDash([]);
  return exitT;
}

// Reglages des deux graphes (voir drawChart) : quota 5h sur 24h (10h en
// vue compacte), quota 7j sur 3 semaines (2 en vue compacte) avec le
// plafond Fable en serie secondaire.
var SESSION_CHART_OPTS = {
  valueKey: 'session',
  resetKey: 'sessionReset',
  windowMs: 24 * HOUR_MS,
  compactWindowMs: 10 * HOUR_MS,
  periodMs: SESSION_PERIOD_MS,
  lineColorVar: '--standard-text',
  tickHourStep: 4,
  compactTickHourStep: 2,
  tooltipShowDate: false,
  showPeakHatch: true,
  verticalGrid: 'hourly',
};
var WEEKLY_CHART_OPTS = {
  valueKey: 'weekly',
  resetKey: 'weeklyReset',
  windowMs: 21 * DAY_MS,
  compactWindowMs: 14 * DAY_MS,
  periodMs: WEEKLY_PERIOD_MS,
  lineColorVar: '--weekly',
  secondaryKey: 'fable',
  secondaryResetKey: 'fableReset',
  secondaryLabel: 'Fable',
  secondaryColorVar: '--fable',
  tooltipShowDate: true,
  verticalGrid: 'daily',
};

// Graphe complet d'un quota (dashboard, popup du widget). env :
//   col(nomDeVariable) -> couleur, compact, now (ms epoch),
//   fontAxis / fontDayLabel / fontEmpty (px, 20/20/42 par defaut).
// Retourne {x, visible} (projection temps -> abscisse et points affiches)
// pour le survol.
function drawChart(ctx, cssWidth, cssHeight, points, opts, env) {
  const { valueKey, resetKey, secondaryKey, secondaryResetKey, secondaryLabel, secondaryColorVar, windowMs, compactWindowMs, periodMs, lineColorVar, tickHourStep, compactTickHourStep, verticalGrid } = opts;
  const col = env.col;
  const compact = !!env.compact;
  const now = env.now;
  const fontAxis = env.fontAxis || 20;
  const fontDayLabel = env.fontDayLabel || 20;
  const fontEmpty = env.fontEmpty || 42;

  ctx.clearRect(0, 0, cssWidth, cssHeight);

  const dayLabelLineH = Math.ceil(fontDayLabel * 1.25);
  const padL = compact ? 16 : Math.round(fontAxis * 3.9);
  const padR = 16;
  const padT = 16;
  const padB = (verticalGrid === 'daily')
    ? dayLabelLineH * 2 + 16
    : Math.ceil(fontAxis * 1.3) + 12;
  const plotW = cssWidth - padL - padR;
  const plotH = cssHeight - padT - padB;
  const maxY = 105;

  const last = points.length ? points[points.length - 1] : null;
  // La periode en cours va du dernier reset connu (periodEnd, dans le futur
  // le plus souvent) moins sa duree nominale, jusqu'a ce reset.
  const periodEnd = last && last[resetKey] ? new Date(last[resetKey]).getTime() : now;
  const periodStart = periodEnd - periodMs;
  // Fenetre d'affichage : se termine au reset a venir si la periode en
  // cours n'est pas finie (pour voir toute la zone), sinon a "maintenant".
  let windowEnd = Math.max(now, periodEnd);
  const effectiveWindowMs = (compact && compactWindowMs) ? compactWindowMs : windowMs;
  let windowStart = windowEnd - effectiveWindowMs;
  // Sur le graphe horaire (session), on cale le debut et la fin de la
  // fenetre affichee pile sur des heures rondes, pour que la 1ere et la
  // derniere colonne du quadrillage ne soient jamais des demi-colonnes -
  // sinon les labels d'heure paraissent mal repartis.
  if (verticalGrid === 'hourly') {
    windowEnd = Math.ceil(windowEnd / HOUR_MS) * HOUR_MS;
    windowStart = Math.floor(windowStart / HOUR_MS) * HOUR_MS;
  } else if (verticalGrid === 'daily') {
    // Meme principe que ci-dessus mais cale sur des minuits locaux (une
    // colonne = un jour complet).
    const startDay = new Date(windowStart);
    startDay.setHours(0, 0, 0, 0);
    windowStart = startDay.getTime();
    const endDay = new Date(windowEnd);
    endDay.setHours(0, 0, 0, 0);
    if (endDay.getTime() < windowEnd) endDay.setDate(endDay.getDate() + 1);
    windowEnd = endDay.getTime();
  }

  const visible = points.filter(p => p.ts.getTime() >= windowStart && p.ts.getTime() <= now);

  const x = (t) => padL + ((t - windowStart) / (windowEnd - windowStart)) * plotW;
  const y = (v) => padT + plotH - (v / maxY) * plotH;

  // Grid + y axis labels
  ctx.strokeStyle = col('--grid');
  ctx.fillStyle = col('--muted');
  ctx.font = `${fontAxis}px sans-serif`;
  ctx.lineWidth = 1;
  [0, 20, 40, 60, 80, 100].forEach(v => {
    const yy = y(v);
    ctx.beginPath();
    ctx.moveTo(padL, yy);
    ctx.lineTo(padL + plotW, yy);
    ctx.stroke();
    if (!compact) ctx.fillText(v + '%', 6, yy + fontAxis * 0.2);
  });

  // Quadrillage vertical : une ligne par heure (session) ou par minuit local
  // (semaine), avec dans ce dernier cas le nom du jour + la date entre les
  // lignes.
  if (verticalGrid === 'hourly') {
    ctx.strokeStyle = col('--grid');
    ctx.lineWidth = 1;
    hourBoundaries(windowStart, windowEnd).forEach(t => {
      const xx = x(t);
      ctx.beginPath();
      ctx.moveTo(xx, padT);
      ctx.lineTo(xx, padT + plotH);
      ctx.stroke();
    });
  } else if (verticalGrid === 'daily') {
    const midnights = localMidnights(windowStart, windowEnd);
    ctx.strokeStyle = col('--grid');
    ctx.lineWidth = 1;
    midnights.forEach(t => {
      const xx = x(t);
      ctx.beginPath();
      ctx.moveTo(xx, padT);
      ctx.lineTo(xx, padT + plotH);
      ctx.stroke();
    });

    // Jour (3 lettres) + date JJ/MM, horizontaux sur deux lignes, centres
    // entre chaque paire de minuits (l'annee n'est pas repetee ici, elle
    // est deja donnee une fois dans "derniere mesure").
    // windowStart/windowEnd sont deja cales sur des minuits (voir plus
    // haut), donc deja presents dans "midnights" - on evite de les
    // dupliquer (ca creerait un segment de largeur nulle a chaque bord).
    const bounds = [...new Set([windowStart, ...midnights, windowEnd])].sort((a, b) => a - b);
    ctx.fillStyle = col('--muted');
    ctx.font = `${fontDayLabel}px sans-serif`;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'top';
    for (let i = 0; i < bounds.length - 1; i++) {
      const segMid = (bounds[i] + bounds[i + 1]) / 2;
      const xx = x(segMid);
      const dayDate = new Date(segMid);
      const dayLine = compact ? DAY_ABBREV_FR_COMPACT[dayDate.getDay()] : DAY_ABBREV_FR[dayDate.getDay()];
      const dateLine = compact ? pad2(dayDate.getDate()) : fmtDM(dayDate);
      const yBase = cssHeight - dayLabelLineH * 2 - 4;
      ctx.fillText(dayLine, xx, yBase);
      ctx.fillText(dateLine, xx, yBase + dayLabelLineH);
    }
    ctx.textAlign = 'left';
    ctx.textBaseline = 'alphabetic';
  }

  // Zones alerte/standard + ligne de pacing, uniquement sur la periode en
  // cours (clippee a la fenetre visible - toujours incluse par construction
  // puisque windowEnd >= periodEnd et windowMs > periodMs).
  const clipStart = Math.max(periodStart, windowStart);
  const clipEnd = Math.min(periodEnd, windowEnd);
  if (clipEnd > clipStart) {
    const xStart = x(clipStart), xEnd = x(clipEnd);
    const yStart = y(pacingThreshold(clipStart, periodStart, periodEnd));
    const yEnd = y(pacingThreshold(clipEnd, periodStart, periodEnd));

    // Zone alerte (au-dessus de la ligne)
    ctx.fillStyle = col('--alert-zone');
    ctx.beginPath();
    ctx.moveTo(xStart, yStart);
    ctx.lineTo(xEnd, yEnd);
    ctx.lineTo(xEnd, y(100));
    ctx.lineTo(xStart, y(100));
    ctx.closePath();
    ctx.fill();

    // Zone standard (en dessous de la ligne)
    ctx.fillStyle = col('--standard-zone');
    ctx.beginPath();
    ctx.moveTo(xStart, yStart);
    ctx.lineTo(xEnd, yEnd);
    ctx.lineTo(xEnd, y(0));
    ctx.lineTo(xStart, y(0));
    ctx.closePath();
    ctx.fill();

    // Ligne de separation
    ctx.strokeStyle = col('--pacing-line');
    ctx.setLineDash([5, 3]);
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    ctx.moveTo(xStart, yStart);
    ctx.lineTo(xEnd, yEnd);
    ctx.stroke();
    ctx.setLineDash([]);
  }

  // Heures de pointe Anthropic (hachures), uniquement si demande pour ce
  // graphe (active sur la session/24h, pas sur la semaine/3 semaines pour
  // eviter des dizaines de bandes fines).
  if (opts.showPeakHatch) {
    getPeakIntervalsUTC(windowStart, windowEnd).forEach(([s, e]) => {
      drawHatchedRect(ctx, x(s), padT, x(e), padT + plotH, col('--peak-hatch'), 7);
    });
  }

  if (!visible.length) {
    ctx.fillStyle = col('--muted');
    ctx.font = `${fontEmpty}px sans-serif`;
    const msg = points.length
      ? 'Aucune donnee dans cette fenetre.'
      : 'Pas encore de donnees - laisse le timer tourner quelques cycles.';
    ctx.fillText(msg, padL + 10, padT + plotH / 2);
  }

  // 100% reference line
  ctx.strokeStyle = col('--muted');
  ctx.lineWidth = 1;
  ctx.setLineDash([4, 4]);
  ctx.beginPath();
  ctx.moveTo(padL, y(100));
  ctx.lineTo(padL + plotW, y(100));
  ctx.stroke();
  ctx.setLineDash([]);

  // x axis labels (remplaces par les labels jour/date en mode "daily",
  // deja dessines plus haut avec le quadrillage vertical) - heures rondes
  // uniquement (compact ou non), a pas fixe en heures ; windowStart est
  // deja cale sur une heure ronde donc chaque pas retombe pile dessus.
  if (verticalGrid !== 'daily') {
    ctx.fillStyle = col('--muted');
    ctx.font = `${fontAxis}px sans-serif`;
    const fullW = fontAxis * 3.6;
    const hourStep = (compact && compactTickHourStep) ? compactTickHourStep : (tickHourStep || 4);
    // Chaque label demarre juste apres son trait vertical (pas centre
    // dessus), y compris le tout premier a windowStart. Le dernier est
    // ramene dans le cadre ; un label qui chevaucherait alors le precedent
    // est omis.
    let prevRight = -Infinity;
    for (let t = windowStart; t <= windowEnd; t += hourStep * HOUR_MS) {
      const label = pad2(new Date(t).getHours()) + 'h';
      const lx = Math.min(x(t) + 4, padL + plotW - fullW);
      if (lx < prevRight) continue;
      ctx.fillText(label, lx, cssHeight - 8);
      prevRight = lx + ctx.measureText(label).width + fontAxis * 0.5;
    }
  }

  // Ligne verticale "maintenant" - dessinee par-dessus le reste (zones,
  // quadrillage) mais sous la courbe de donnees, pour reperer d'un coup
  // d'oeil ou on en est dans la fenetre affichee.
  if (now >= windowStart && now <= windowEnd) {
    const xNow = x(now);
    ctx.strokeStyle = col('--now-line');
    ctx.lineWidth = 2;
    ctx.setLineDash([]);
    ctx.beginPath();
    ctx.moveTo(xNow, padT);
    ctx.lineTo(xNow, padT + plotH);
    ctx.stroke();
  }

  // Changements d'abonnement : les % de part et d'autre sont relatifs a
  // des quotas differents. On marque la frontiere (et on coupe la courbe
  // plus bas) pour que la rupture ne se lise pas comme un reset.
  findTierChanges(points).forEach(c => {
    if (c.ts < windowStart || c.ts > windowEnd) return;
    const xc = x(c.ts);
    ctx.strokeStyle = col('--plan-line');
    ctx.lineWidth = 2;
    ctx.setLineDash([3, 3]);
    ctx.beginPath();
    ctx.moveTo(xc, padT);
    ctx.lineTo(xc, padT + plotH);
    ctx.stroke();
    ctx.setLineDash([]);
    if (!compact) {
      const label = `${tierName(c.from)} -> ${tierName(c.to)}`;
      ctx.fillStyle = col('--plan-line');
      ctx.font = `${fontAxis}px sans-serif`;
      const w = ctx.measureText(label).width;
      ctx.fillText(label, Math.min(xc + 6, padL + plotW - w), padT + fontAxis * 2.4);
    }
  });

  // Data lines : serie principale, puis serie secondaire eventuelle
  // (dessinee par-dessus). Les points sans valeur coupent la courbe.
  const drawSeries = (key, color) => {
    const pts = visible.filter(p => !isNaN(p[key]));
    if (!pts.length) return;
    ctx.strokeStyle = color;
    ctx.lineWidth = 2;
    ctx.beginPath();
    let prevTier = null;
    let penDown = false;
    visible.forEach(p => {
      if (isNaN(p[key])) { penDown = false; return; }
      const xx = x(p.ts.getTime());
      const yy = y(p[key]);
      const rebased = p.tier && prevTier && p.tier !== prevTier;
      if (!penDown || rebased) ctx.moveTo(xx, yy); else ctx.lineTo(xx, yy);
      if (p.tier) prevTier = p.tier;
      penDown = true;
    });
    ctx.stroke();
    ctx.fillStyle = color;
    pts.forEach(p => {
      ctx.beginPath();
      ctx.arc(x(p.ts.getTime()), y(p[key]), 2.5, 0, Math.PI * 2);
      ctx.fill();
    });
  };
  drawSeries(valueKey, col(lineColorVar));
  if (secondaryKey) drawSeries(secondaryKey, col(secondaryColorVar));

  // Sortie de zone alerte, avec l'heure de sortie - et le jour sur le
  // graphe semaine - au-dessus du segment.
  const drawAlertExit = (key, resetK, prefix) => {
    const alertColor = col('--alert-text');
    const exitT = drawExitSegment(ctx, last, key, resetK, periodMs, now, x, y, x(windowStart), x(windowEnd), alertColor);
    if (exitT === null) return;
    const x2 = Math.min(x(exitT), x(windowEnd));
    const yy = y(last[key]);
    ctx.beginPath();
    ctx.moveTo(x2, yy - 8);
    ctx.lineTo(x2, yy + 8);
    ctx.stroke();

    const exitDate = new Date(exitT);
    const when = verticalGrid === 'daily'
      ? `${DAY_ABBREV_FR[exitDate.getDay()]} ${fmtDM(exitDate)} ${fmtHM(exitDate)}`
      : fmtHM(exitDate);
    const label = `${prefix}${compact ? '' : 'sortie '}${when}`;
    ctx.fillStyle = alertColor;
    ctx.font = `${fontAxis}px sans-serif`;
    const w = ctx.measureText(label).width;
    const lx = Math.max(padL + 4, Math.min(x2 - w / 2, padL + plotW - w));
    // Au-dessus du segment, ou en dessous s'il est colle au haut du graphe.
    const ly = yy - 10 - fontAxis < padT ? yy + 10 + fontAxis : yy - 10;
    ctx.fillText(label, lx, ly);
  };
  drawAlertExit(valueKey, resetKey, '');
  if (secondaryKey) drawAlertExit(secondaryKey, secondaryResetKey, secondaryLabel + ' ');

  return { x: x, visible: visible };
}

// Mini-graphe d'un quota pour la barre du widget : la periode en cours
// seulement (du debut de la fenetre au prochain reset), avec zones, ligne
// de pacing, courbe et segment de sortie de zone alerte, sans texte.
// opts : valueKey, resetKey, periodMs, lineColorVar ; env : col, now.
function drawSparkline(ctx, w, h, points, opts, env) {
  const col = env.col;
  const now = env.now;
  ctx.clearRect(0, 0, w, h);
  const last = points.length ? points[points.length - 1] : null;
  if (!last || isNaN(last[opts.valueKey])) return;

  const periodEnd = last[opts.resetKey] ? new Date(last[opts.resetKey]).getTime() : now;
  const periodStart = periodEnd - opts.periodMs;
  const x = (t) => ((t - periodStart) / opts.periodMs) * w;
  const y = (v) => h - 1 - (Math.min(Math.max(v, 0), 100) / 100) * (h - 2);

  ctx.fillStyle = col('--alert-zone');
  ctx.beginPath();
  ctx.moveTo(0, y(PACING_START));
  ctx.lineTo(w, y(PACING_END));
  ctx.lineTo(w, y(100));
  ctx.lineTo(0, y(100));
  ctx.closePath();
  ctx.fill();
  ctx.fillStyle = col('--standard-zone');
  ctx.beginPath();
  ctx.moveTo(0, y(PACING_START));
  ctx.lineTo(w, y(PACING_END));
  ctx.lineTo(w, y(0));
  ctx.lineTo(0, y(0));
  ctx.closePath();
  ctx.fill();
  ctx.strokeStyle = col('--pacing-line');
  ctx.lineWidth = 1;
  ctx.setLineDash([3, 2]);
  ctx.beginPath();
  ctx.moveTo(0, y(PACING_START));
  ctx.lineTo(w, y(PACING_END));
  ctx.stroke();
  ctx.setLineDash([]);

  if (now >= periodStart && now <= periodEnd) {
    ctx.strokeStyle = col('--now-line');
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(x(now), 0);
    ctx.lineTo(x(now), h);
    ctx.stroke();
  }

  // Courbe de la periode en cours, au palier actuel (un changement de plan
  // rend les % anterieurs incomparables).
  ctx.strokeStyle = col(opts.lineColorVar);
  ctx.lineWidth = 1.5;
  ctx.beginPath();
  let penDown = false;
  points.forEach(p => {
    const t = p.ts.getTime();
    if (t < periodStart || t > now || isNaN(p[opts.valueKey]) || (p.tier && last.tier && p.tier !== last.tier)) {
      penDown = false;
      return;
    }
    if (penDown) ctx.lineTo(x(t), y(p[opts.valueKey])); else ctx.moveTo(x(t), y(p[opts.valueKey]));
    penDown = true;
  });
  ctx.stroke();

  drawExitSegment(ctx, last, opts.valueKey, opts.resetKey, opts.periodMs, now, x, y, 0, w, col('--alert-text'));
}
