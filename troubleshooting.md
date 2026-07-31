# Depannage

Pour l'installation et l'usage courant, voir [README.md](README.md). Pour
le detail de l'implementation (composants, diagramme du flux de donnees),
voir [README.infra.md](README.infra.md).

## Verifier que les timers tournent

```bash
systemctl --user list-timers claude-usage-log.timer claude-peak-status.timer
journalctl --user -u claude-usage-log.service -n 20
journalctl --user -u claude-peak-status.service -n 20
```

`claude-usage-log.timer` doit se declencher toutes les 10 min,
`claude-peak-status.timer` une fois par jour a 06:00. Si un timer
n'apparait pas ou est `inactive`, relance `./install.sh` (idempotent,
sans danger).

## "WARNING" s'affiche devant "Last data" sur le dashboard

Le dashboard compare l'age de la derniere mesure a l'heure actuelle : au-dela
de 15 min sans nouvelle donnee, il affiche "WARNING" devant "Last data" et
l'age de la mesure en orange (vue standard seulement) :

- **Ecart de quelques dizaines de minutes** : probablement un vrai
  probleme du logger - token OAuth expire, pas de reseau, timer arrete.
  Verifie les logs ci-dessus.
- **Ecart de plusieurs heures** : le plus souvent la machine etait
  eteinte ou en veille sur cette periode (les timers `systemd --user` ne
  tournent pas dans ce cas) - pas la peine d'accuser le logger, ca
  devrait se resorber tout seul au prochain tick.

## Les timers ne se declenchent jamais / desactives au demarrage

Les timers sont des services **user** systemd : ils ne tournent que
pendant une session utilisateur active, sauf si le lingering est active :

```bash
loginctl enable-linger $USER
```

(necessite les droits admin).

## Le % affiche parait faux ou ne bouge plus

- Verifie que Claude Code a bien un token valide : `cat
  ~/.claude/.credentials.json` doit exister et contenir un
  `accessToken`. Le logger l'utilise tel quel (il ne gere pas le refresh
  OAuth lui-meme) - si Claude Code n'a pas tourne depuis longtemps, le
  token peut etre expire ; il se remettra a jour au prochain usage normal
  de Claude Code.
- Regenere la page manuellement pour ecarter un souci de rendu plutot que
  de donnees :

  ```bash
  ./bin/generate-page.py
  ```

## Le skill ne trouve pas `claude_wait.sh`

Le skill appelle `~/.local/bin/claude_wait.sh`, un lien symbolique vers
le depot pose par `install.sh`. S'il manque ou pointe dans le vide (depot
deplace ou supprime), relance `./install.sh` depuis le depot :

```bash
ls -l ~/.local/bin/claude_wait.sh ~/.claude/skills/quota-zone-gate
```

## `install.sh` refuse de creer un lien

Un fichier ou dossier reel (pas un lien) existe deja a
`~/.claude/skills/quota-zone-gate` ou `~/.local/bin/claude_wait.sh`.
`install.sh` ne l'ecrase jamais : deplace-le ou supprime-le a la main
apres avoir verifie son contenu, puis relance l'installation.

## Repartir d'un historique propre

Sans desinstaller : les loggers recreent les fichiers automatiquement,
donc un simple

```bash
rm -f ~/.config/monitoring-claude/usage.csv ~/.config/monitoring-claude/peak-status.csv
```

suffit. En desinstallant, `./uninstall.sh --purge` fait la meme chose
(voir [README.md](README.md#desinstallation)).
