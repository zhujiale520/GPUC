#!/usr/bin/env python3
"""Fail when a relative Markdown link/image points to a missing local file."""
from pathlib import Path
import re
import sys
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[1]
LINK = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
errors = []

for doc in ROOT.rglob("*.md"):
    # Vendored packages keep their upstream documentation verbatim and may
    # intentionally omit website/build-only assets. Validate project-owned
    # documentation, not third-party distribution internals.
    if any(part in {".git", "node_modules", "third_party"} for part in doc.parts):
        continue
    text = doc.read_text(encoding="utf-8", errors="replace")
    for line_no, line in enumerate(text.splitlines(), 1):
        for raw in LINK.findall(line):
            raw = raw.strip()
            if raw.startswith("<") and ">" in raw:
                target = raw[1:raw.index(">")]
            else:
                target = raw.split(maxsplit=1)[0]
            if not target or target.startswith(("#", "http://", "https://", "mailto:")):
                continue
            path_part = unquote(target.split("#", 1)[0])
            if not path_part:
                continue
            candidate = (doc.parent / path_part).resolve()
            try:
                candidate.relative_to(ROOT)
            except ValueError:
                errors.append(f"{doc.relative_to(ROOT)}:{line_no}: link escapes repository: {target}")
                continue
            if not candidate.exists():
                errors.append(f"{doc.relative_to(ROOT)}:{line_no}: missing: {target}")

if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
print("PASS: local Markdown links resolve")
