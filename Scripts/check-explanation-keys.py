#!/usr/bin/env python3
"""Check that every explanation key the code hands to the UI is a shipped string.

An item reaches the user with a localisation key, not a sentence: the scanner
decides *what* the sentence is and the catalog carries the text. Nothing used to
connect the two, and the two had come apart — the Rust core emitted
`cleanup.<rule-id>.explanation` for every rule while the catalog held
`cleanup.explanation.<something>`, so on the shipped engine each item fell back to
its category's generic sentence and the rule's own explanation was never shown.

The same shape of mistake has a second half: a key that *is* shipped but carries a
`%d` reaches the user with the placeholder in it, because an item-level
explanation is rendered with no arguments. The sentences that take a number stay on
the category keys the pages format for themselves.

So both halves are checked here, over the literals in the code rather than over the
generated enum (which by construction contains every key and would pass whatever
the code did):

  * every `cleanup.*` key used in Rust or Swift is in `Localizable.xcstrings`;
  * no key the Rust core attaches to an item carries a format placeholder.

Usage:
    python3 Scripts/check-explanation-keys.py
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CATALOG = REPO_ROOT / "Shared" / "Localization" / "Localizable.xcstrings"

# Directories that hold source rather than build output, and the generated files
# that restate the catalog or the rule table.
SOURCE_DIRS = ("RustCore/crates", "Core", "Features", "App", "Shared")
GENERATED = {
    "Shared/Localization/LocalizationKey.swift",
    "Core/Rules/ProtectedPaths.swift",
    "Core/Rules/BuiltInRules.swift",
}
SUFFIXES = (".rs", ".swift")

# Two shapes, because they answer two questions.
#
# A key that *reaches the scanner* is an assignment — `explanation_key: "..."` in
# Rust, `explanationKey: "..."` in Swift — and an item is rendered with no
# arguments, so such a key may not carry a placeholder.
#
# Any other literal spelling a `cleanup.*` key is still a key someone expects the
# catalog to carry (the rule table passes its key as a call argument), so every
# literal has to exist; matching only assignments would have let the table's keys
# through unnoticed.
KEY_ASSIGNMENT = re.compile(r'(?:explanation_key|explanationKey):\s*"(cleanup\.[A-Za-z0-9._-]+)"')
KEY_LITERAL = re.compile(r'"(cleanup\.[A-Za-z0-9._-]+)"')
# `%@`, `%d`, `%.2f` and the positional forms `%1$@` / `%2$d`: a positional
# placeholder still takes an argument, so an attached key carrying one is as
# wrong as a plain `%@` and must not pass the check.
PLACEHOLDER_HOLDERS = re.compile(r"%(?:\d+\$)?\.?\d*[a-zA-Z@]")

# Test code builds rules and candidates with made-up keys on purpose, so only the
# shipped half of each file is scanned: a `#[cfg(test)]` module is the last thing
# in a Rust file here, the Swift suites are their own targets, and a benchmark is
# not shipped either.
TEST_MODULE = re.compile(r"\n#\[cfg\(test\)\]")
TEST_PATHS = ("benches", "tests")


def source_files() -> list[Path]:
    files: list[Path] = []
    for directory in SOURCE_DIRS:
        root = REPO_ROOT / directory
        if not root.is_dir():
            continue
        for path in sorted(root.rglob("*")):
            if path.suffix not in SUFFIXES or not path.is_file():
                continue
            if "target" in path.parts or ".build" in path.parts:
                continue
            if any(part in TEST_PATHS for part in path.parts):
                continue
            if str(path.relative_to(REPO_ROOT)) in GENERATED:
                continue
            files.append(path)
    return files


def shipped_text(path: Path) -> str:
    text = path.read_text(encoding="utf-8", errors="replace")
    if path.suffix == ".rs":
        cut = TEST_MODULE.search(text)
        if cut:
            text = text[: cut.start()]
    return text


def source_text(entry: dict) -> str:
    """The source-language string of a catalog entry."""
    unit = entry.get("localizations", {}).get("en", {}).get("stringUnit", {})
    value = unit.get("value")
    return value if isinstance(value, str) else ""


def main() -> int:
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))["strings"]
    used: dict[str, list[str]] = {}
    attached: dict[str, list[str]] = {}
    for path in source_files():
        text = shipped_text(path)
        where = str(path.relative_to(REPO_ROOT))
        for key in KEY_LITERAL.findall(text):
            used.setdefault(key, []).append(where)
        for key in KEY_ASSIGNMENT.findall(text):
            attached.setdefault(key, []).append(where)

    if not used or not attached:
        raise SystemExit("no explanation keys found; this script reads them from source")

    missing = {key: where for key, where in used.items() if key not in catalog}
    placeholders = {
        key: where
        for key, where in attached.items()
        if PLACEHOLDER_HOLDERS.search(source_text(catalog.get(key, {})))
    }

    if missing or placeholders:
        for key, where in sorted(missing.items()):
            print(f"missing from the catalog: {key}\n    used in {', '.join(sorted(set(where)))}")
        for key, where in sorted(placeholders.items()):
            print(
                f"carries a format placeholder and is used as an item explanation: {key}\n"
                f"    used in {', '.join(sorted(set(where)))}"
            )
        return 1

    print(f"all {len(used)} explanation keys used in the code are shipped and render without arguments")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
