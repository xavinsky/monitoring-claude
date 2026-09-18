#!/usr/bin/env python3
"""Regenere www/index.html a partir de www/template.html, www/quota-core.js
et de usage.csv.

Le contenu du CSV est embarque directement comme chaine JS : la page
generee fonctionne ouverte telle quelle (file://), sans serveur.
"""
import os
from pathlib import Path

REPO_DIR = Path(__file__).resolve().parent.parent
DATA_FILE = Path.home() / ".config/monitoring-claude/usage.csv"
TEMPLATE_FILE = REPO_DIR / "www" / "template.html"
# Logique et dessin partages avec le widget Plasma.
CORE_FILE = REPO_DIR / "www" / "quota-core.js"
OUTPUT_FILE = REPO_DIR / "www" / "index.html"

DEFAULT_CSV = "timestamp,session_usage,session_reset_at,weekly_usage,weekly_reset_at,rate_limit_tier,fable_usage,fable_reset_at\n"


def escape_for_template_literal(text: str) -> str:
    text = text.replace("\\", "\\\\").replace("`", "\\`").replace("${", "\\${")
    # Une sequence </script> dans les donnees fermerait la balise script.
    return text.replace("</", "<\\/")


def render(csv_text: str) -> str:
    """Page complete : gabarit + logique partagee + donnees embarquees."""
    template = TEMPLATE_FILE.read_text()
    core = CORE_FILE.read_text()
    return (template
            .replace("/*__QUOTA_CORE_JS__*/", core)
            .replace("__CCUSAGE_CSV__", escape_for_template_literal(csv_text)))


def main() -> None:
    csv_text = DATA_FILE.read_text() if DATA_FILE.exists() else DEFAULT_CSV
    output = render(csv_text)

    # Ecriture atomique : la page se recharge seule toutes les 2 min et ne
    # doit jamais tomber sur un fichier a moitie ecrit.
    tmp_file = OUTPUT_FILE.with_name(OUTPUT_FILE.name + ".tmp")
    tmp_file.write_text(output)
    os.replace(tmp_file, OUTPUT_FILE)


if __name__ == "__main__":
    main()
