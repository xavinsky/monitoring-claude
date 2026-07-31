---
name: quota-zone-gate
description: "Verifie via ~/.local/bin/claude_wait.sh (un seul script, aucun token de modele consomme) si le quota Claude Code (session 5h ET semaine 7j, plus le plafond Fable 7j pour une tache Fable via --fable) est en zone standard ET si on est en heures creuses Anthropic (planning calcule localement). Ne se declenche que sur demande EXPLICITE de l'utilisateur (ex: 'check le quota', 'est-ce qu'on peut lancer X maintenant', 'attends la zone verte', 'attends les heures creuses', 'active le garde-fou quota avant cette tache') - jamais de sa propre initiative avant une tache non urgente/lourde sans que l'utilisateur l'ait demande. Une fois invoque pour une tache a venir, toutes les dimensions bloquent symetriquement : si l'une n'est pas favorable, attend automatiquement (ScheduleWakeup) via la recommandation combinee du script - sauf si la tache est urgente, auquel cas on procede quand meme immediatement."
---

# Quota zone gate

Ce skill ne se declenche que sur **demande explicite de l'utilisateur**
(ex: "check le quota", "est-ce qu'on peut lancer X maintenant", "attends
la zone verte", "active le garde-fou quota avant cette tache") - jamais
de ta propre initiative avant une tache non urgente/lourde sans que
l'utilisateur l'ait demande, meme si elle ressemble a un gros lot de
forks paralleles ou une boucle longue. C'est volontairement a
l'utilisateur de decider quand l'activer.

Une fois invoque, il sert de garde-fou avant de demarrer la tache visee
(typiquement un gros lot de forks paralleles, une boucle de recherche
longue, un refactor etendu...) : il verifie a la fois le quota Claude Code
(zone standard/alerte) et les heures de pointe Anthropic (heures creuses
ou non), et si la tache n'est pas urgente, attend que les deux soient
favorables avant de commencer plutot que de risquer d'epuiser le quota ou
de tourner en pleine heure de pointe.

Repose sur le script `claude_wait.sh` du projet monitoring-claude
(installe en lien symbolique dans `~/.local/bin/` par son `install.sh`),
qui interroge en direct l'API usage d'Anthropic (aucun token de modele
consomme - lecture de compte en lecture seule), calcule les heures de
pointe localement, puis affiche une recommandation combinee prete a
l'emploi.

## Etape 1 : determiner si la tache est urgente

Une tache est **urgente** si, par exemple :
- l'utilisateur le demande explicitement ou emploie des mots comme
  "urgent", "maintenant", "vite", "tout de suite",
- c'est une reponse courte / un seul appel d'outil (pas un gros lot de
  forks ni une boucle longue),
- ca corrige un blocage immediat de l'utilisateur (bug qui l'empeche de
  continuer, question a laquelle il attend une reponse pour avancer).

Une tache est **non urgente** si, par exemple :
- c'est un lot de plusieurs forks paralleles (traitement en masse de
  dizaines de fichiers, par exemple),
- l'utilisateur a lui-meme mentionne qu'il n'y a pas de delai serre, ou
  qu'on peut "avancer jusqu'a epuisement du quota" / "continuer plus
  tard" / etc.,
- c'est une tache de fond que l'utilisateur ne surveille pas activement.

Dans le doute, pose la question a l'utilisateur plutot que de deviner
(`AskUserQuestion`) - sauf si le contexte de la conversation le rend deja
evident.

Si la tache est **urgente** : procede immediatement, sans consulter le
quota. Ne bloque jamais une demande urgente pour une histoire de pacing.

## Etape 2 : verifier (taches non urgentes uniquement)

Execute :

```bash
~/.local/bin/claude_wait.sh
```

Ajoute `--fable` si la tache tournera sur un modele Fable (la session en
cours est sur Fable, ou les forks/sous-agents seront lances avec
`model: "fable"`). Sans cette option, la ligne `Fable (7j)` reste
affichee mais le plafond Fable ne bloque pas : une tache sur Opus/Sonnet
ne le consomme pas.

Sortie type (cas bloquant, ici sur la semaine - c'est le cas le plus
long, jusqu'a une trentaine d'heures) :

```
Abonnement    : Max 5x (les % ci-dessous sont relatifs au quota de ce plan)
Session (5h)  : 61% - zone ALERTE - retour en zone standard dans 1h11 (vers 10:15)
Semaine (7j)  : 60% - zone ALERTE - retour en zone standard dans 36h56 (vers 01/08 22:00)
Fable (7j)    : 20% - deja en zone STANDARD.
Heures creuses : OUI (hors heures de pointe) - vitesse 'normal' - prochaine periode de pointe dans 4h12 (vers 15:00).

=> Tache non urgente : ATTENDRE 36h56 (jusqu'a 01/08 22:00) - session en zone alerte + semaine en zone alerte.
```

Sortie type (cas favorable, lance avec `--fable` ; sans l'option,
`+ Fable standard` n'apparait pas dans la derniere ligne) :

```
Abonnement    : Max 5x (les % ci-dessous sont relatifs au quota de ce plan)
Session (5h)  : 32% - deja en zone STANDARD.
Semaine (7j)  : 27% - deja en zone STANDARD.
Fable (7j)    : 15% - deja en zone STANDARD.
Heures creuses : OUI (hors heures de pointe) - vitesse 'normal' - prochaine periode de pointe dans 4h12 (vers 15:00).

=> Tache non urgente : OK, rien ne bloque actuellement (session standard + semaine standard + Fable standard + heures creuses).
```

La derniere ligne (`=> Tache non urgente : ...`) donne deja la decision
et, si besoin d'attendre, la duree/heure cible combinee (le script prend
lui-meme le plus long des delais bloquants) - pas besoin de recalculer
quoi que ce soit, juste relayer/utiliser cette ligne.

**Toutes les dimensions (session 5h, semaine 7j, plafond Fable 7j pour une
tache Fable, heures de pointe) bloquent symetriquement** - le plafond Fable
suit la meme regle de pacing que la semaine, sur son propre % (relatif au
plafond Fable, pas au quota 7j global) ; la ligne `Fable (7j)` n'apparait
pas si le plan n'a pas de plafond Fable. La semaine peut representer une
trentaine d'heures d'attente, c'est assume (taches non urgentes
uniquement) : on prefere attendre plutot que de continuer a consommer
alors qu'on est deja au-dessus du pacing.

- Si le script echoue (`Erreur : la verification du quota usage a
  echoue...` sur stderr, code de sortie non nul - API usage Anthropic
  inaccessible, ou token absent/expire ; les heures de pointe etant
  calculees localement, elles ne peuvent pas le faire echouer) : ne
  bloque pas indefiniment pour autant - previens l'utilisateur que la
  verification a echoue, puis procede quand meme (fail-open : le pire cas
  est de retomber sur une erreur de limite de session deja connue et
  recuperable, pas un blocage silencieux). Si seule la semaine n'a pas pu
  etre lue, le script le signale sur sa ligne ("verification
  indisponible") et calcule quand meme la recommandation sur la base du
  reste.
- Si `~/.local/bin/claude_wait.sh` est introuvable, monitoring-claude
  n'est pas installe (ou son `install.sh` n'a pas ete relance) : previens
  l'utilisateur et procede sans verification.

## Etape 3 : decision

- **`=> Tache non urgente : OK...`** : procede immediatement avec la
  tache.

- **`=> Tache non urgente : ATTENDRE ...`** : ne demarre PAS la tache
  maintenant. Informe clairement l'utilisateur (reprends la ligne de
  recommandation, plus le detail session/heures de pointe), puis
  programme une reprise automatique avec `ScheduleWakeup` plutot que
  d'attendre en synchrone :
  - `delaySeconds` = la duree d'attente indiquee par le script,
    plafonnee a 3600 (le maximum accepte par l'outil) - si l'attente
    reelle depasse 1h, le reveil suivant relance `claude_wait.sh` et
    re-programme un nouveau reveil si necessaire.
  - `prompt` : redemarre ce skill (`quota-zone-gate`) puis, si le script
    indique maintenant "OK", lance effectivement la tache prevue ; sinon
    reprogramme un nouveau reveil. Le prompt doit rappeler explicitement
    quelle tache est en attente (nom/contexte), puisque le reveil arrive
    dans un tour separe sans memoire immediate du raisonnement precedent.
  - `reason` : une phrase courte, ex. "attente zone standard/heures
    creuses avant de lancer <tache>".

Ne relance jamais le script en boucle serree avec des `sleep` - toujours
passer par `ScheduleWakeup` pour rendre la main entre deux verifications.

## Exemple

> Utilisateur : "lance le traitement des 12 fichiers restants, pas
> d'urgence particuliere"
>
> 1. Tache identifiee comme non urgente (lot de forks, pas de delai
>    mentionne).
> 2. `claude_wait.sh` renvoie `=> Tache non urgente : ATTENDRE 36h56
>    (jusqu'a 01/08 22:00) - session en zone alerte + semaine en zone
>    alerte.`
> 3. Reponse a l'utilisateur : "On est en zone alerte sur la session 5h
>    et la semaine 7j - je programme une reprise automatique vers le
>    01/08 22:00 plutot que de lancer les 12 forks tout de suite."
> 4. `ScheduleWakeup(delaySeconds=3600, prompt="Relancer quota-zone-gate
>    puis, si claude_wait.sh indique OK, lancer le traitement des 12
>    fichiers restants de <chemin> ; sinon reprogrammer un nouveau
>    reveil", reason="attente zone standard (session+semaine) avant lot
>    de 12 forks")` - l'attente reelle (36h56) depasse largement le
>    plafond de 3600s d'un seul appel : chaque reveil relance le script
>    et re-programme le suivant jusqu'a ce que la zone soit standard.
