#!/usr/bin/env python3
"""Checks the skills against the rules in AGENTS.md.

Every skill folder has SKILL.md and agents/openai.yaml, and is listed in
plugin.json, the README table, and the bama router. Every relative link in
skills/, specs/, and README.md resolves. No em dashes in skill text.
AGENTS.md matches .claude/CLAUDE.md.

Usage: scripts/check-skills.py   (prints PASS or FAIL per check, exits 1 on any FAIL)
"""
import json, re, sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
failures = []

def fail(message):
    failures.append(message)
    print(f"FAIL {message}")

skills = sorted(p.parent for p in root.glob("skills/*/*/SKILL.md"))
folders = sorted(p for p in root.glob("skills/*/*") if p.is_dir())
for folder in folders:
    if not (folder / "SKILL.md").is_file():
        fail(f"{folder.relative_to(root)} has no SKILL.md")

plugin = json.loads((root / ".claude-plugin/plugin.json").read_text())
listed = {s.removeprefix("./") for s in plugin["skills"]}
readme = (root / "README.md").read_text()
router = (root / "skills/start/bama/SKILL.md").read_text()
for skill in skills:
    rel = str(skill.relative_to(root))
    name = skill.name
    if not (skill / "agents/openai.yaml").is_file():
        fail(f"{rel} has no agents/openai.yaml")
    front = (skill / "SKILL.md").read_text().split("---")[1]
    if not re.search(rf"^name: {re.escape(name)}$", front, re.M):
        fail(f"{rel}/SKILL.md name is not {name}")
    if rel not in listed:
        fail(f"{rel} is not in plugin.json skills")
    if f'href="{rel}/SKILL.md"' not in readme:
        fail(f"{rel} is not in the README skills table")
    if name != "bama" and f"`{name}`" not in router:
        fail(f"{name} is not in the bama router")
for entry in listed:
    if not (root / entry / "SKILL.md").is_file():
        fail(f"plugin.json lists {entry}, which has no SKILL.md")

link = re.compile(r"\]\(([^)\s]+)\)|href=\"([^\"]+)\"")
docs = [*root.glob("skills/**/*.md"), *root.glob("specs/*.md"), root / "README.md"]
for doc in docs:
    text = doc.read_text()
    # Links inside code fences are examples, not links.
    prose = re.sub(r"^(```|~~~).*?^\1", "", text, flags=re.M | re.S)
    for match in link.finditer(prose):
        target = (match.group(1) or match.group(2)).split("#")[0]
        if not target or re.match(r"^[a-z]+:", target) or "<" in target:
            continue
        if not (doc.parent / target).exists():
            fail(f"{doc.relative_to(root)} links to missing {target}")
    if "—" in text and doc.name != "README.md":
        fail(f"{doc.relative_to(root)} has an em dash")

if (root / "AGENTS.md").read_text() != (root / ".claude/CLAUDE.md").read_text():
    fail("AGENTS.md differs from .claude/CLAUDE.md")

if failures:
    sys.exit(1)
print(f"PASS {len(skills)} skills, {len(docs)} docs")
