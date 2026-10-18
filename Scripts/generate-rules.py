#!/usr/bin/env python3
"""Generate both copies of the cleaning rule table from the Rust one.

Three things hold cleaning rules: `default_rules()` in
`RustCore/crates/sift-rules/src/lib.rs`, which the Rust scanner applies;
`Core/Resources/CleaningRules.json`, which ships inside the app and is the file a
user copies to write rules of their own; and `RuleEngine.builtInRules`, the Swift
fallback for a build whose resource is missing.

They were three hand-written tables and they had drifted apart: the Rust one held
twelve rules, the shipped file seven, so the two engines recognised different sets
of files while sharing one protection list. A rule that only one engine knew about
was invisible in the file a reviewer reads, which is how a rule offering the live
data of installed applications went unnoticed.

The Rust table is the source. This script renders the other two from it — by
asking the Rust core for the document rather than by parsing its source, so a rule
the table gains cannot be missing from the copies — and `--check` fails when either
is stale, so `Scripts/verify.sh` catches a forgotten regeneration before a commit.

Usage:
    python3 Scripts/generate-rules.py            # writes both files
    python3 Scripts/generate-rules.py --check    # verifies both are current
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
RUST_MANIFEST = REPO_ROOT / "RustCore" / "Cargo.toml"
JSON_OUTPUT = REPO_ROOT / "Core" / "Resources" / "CleaningRules.json"
SWIFT_OUTPUT = REPO_ROOT / "Core" / "Rules" / "BuiltInRules.swift"

# The Swift cases carry the same names as the JSON values (`applicationCache`,
# `homeLibrary`, ...), so a value this script does not know is an error rather
# than something to guess at: a category quietly rendered as the wrong case would
# put an item in front of the user under the wrong heading.
SWIFT_ENUM_FIELDS = ("category", "risk", "root")

MATCH_SPECS = {
    "directory": ".directory",
    "childDirectories": ".childDirectories",
    "anyFile": ".anyFile",
}


def rule_table() -> dict:
    """The built-in table, as the Rust core serialises it."""
    try:
        result = subprocess.run(
            [
                "cargo",
                "run",
                "--quiet",
                "--manifest-path",
                str(RUST_MANIFEST),
                "-p",
                "sift-rules",
                "--bin",
                "print-rules",
            ],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError:
        raise SystemExit(
            "cargo is not on PATH; the rule table is read from the Rust core, "
            "so Scripts/bootstrap.sh has to have run at least once"
        )
    if result.returncode != 0:
        raise SystemExit(
            "the rule table could not be read from the Rust core:\n"
            f"{result.stderr.strip()}"
        )
    document = json.loads(result.stdout)
    if not document.get("rules"):
        raise SystemExit("the built-in rule table is empty")
    return document


def swift_string_literal(value: str) -> str:
    # A rule id or a path is plain ASCII, but escaping through JSON keeps a quote
    # or a backslash in a future rule from producing Swift that does not compile.
    return json.dumps(value, ensure_ascii=False)


def swift_rule(rule: dict) -> str:
    for field in SWIFT_ENUM_FIELDS:
        value = rule[field]
        if not value.isascii() or not value[:1].islower():
            raise SystemExit(f"rule `{rule['id']}` has an unexpected {field}: {value!r}")

    spec = rule.get("matchSpec")
    if spec == "filesByExtension":
        extensions = ", ".join(swift_string_literal(e) for e in rule.get("extensions", []))
        match_spec = f".filesByExtension([{extensions}])"
    elif spec in MATCH_SPECS:
        match_spec = MATCH_SPECS[spec]
    else:
        raise SystemExit(f"rule `{rule['id']}` has an unknown matchSpec: {spec!r}")

    excludes = ", ".join(swift_string_literal(e) for e in rule.get("excludes", []))
    min_age = rule.get("minAgeDays")
    # `Rule` is nested in `RuleEngine`, so the generated literal names it in full:
    # an unqualified `Rule` is not in scope here, and without it the leading-dot
    # members have no contextual type to resolve against.
    return (
        "        RuleEngine.Rule(\n"
        f"            id: {swift_string_literal(rule['id'])},\n"
        f"            category: .{rule['category']},\n"
        f"            risk: .{rule['risk']},\n"
        f"            root: .{rule['root']},\n"
        f"            relativePath: {swift_string_literal(rule.get('relativePath', ''))},\n"
        f"            matchSpec: {match_spec},\n"
        f"            excludes: [{excludes}],\n"
        f"            minAgeDays: {min_age if min_age is not None else 'nil'},\n"
        f"            usesStaleThreshold: {str(rule.get('usesStaleThreshold', False)).lower()},\n"
        f"            requiresFullDiskAccess: {str(rule.get('requiresFullDiskAccess', False)).lower()},\n"
        f"            explanationKey: {swift_string_literal(rule['explanationKey'])},\n"
        f"            isEnabled: {str(rule.get('enabled', True)).lower()}\n"
        "        ),\n"
    )


def swift_source(document: dict) -> str:
    rules = "".join(swift_rule(rule) for rule in document["rules"])
    return (
        "/// The built-in rule table.\n"
        "///\n"
        "/// Generated by `Scripts/generate-rules.py` from `default_rules()` in\n"
        "/// `RustCore/crates/sift-rules/src/lib.rs`. Do not edit by hand: this table,\n"
        "/// the shipped `CleaningRules.json` and the Rust table were three hand-written\n"
        "/// copies, and they disagreed — so the two engines recognised different sets of\n"
        "/// files, while sharing one protection list.\n"
        "///\n"
        "/// The table is what `RuleEngine` falls back to when the bundled rule file\n"
        "/// cannot be read, so a packaging mistake cannot leave the app with no rules at\n"
        "/// all — which would silently make every scan return nothing.\n"
        "public enum BuiltInRules {\n"
        "    /// The rules the app ships.\n"
        f"    public static let table: [RuleEngine.Rule] = [\n"
        f"{rules}"
        "    ]\n"
        "}\n"
    )


def json_source(document: dict) -> str:
    return json.dumps(document, indent=2, ensure_ascii=False) + "\n"


def write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(content)


def main() -> int:
    document = rule_table()
    rendered = {
        JSON_OUTPUT: json_source(document),
        SWIFT_OUTPUT: swift_source(document),
    }

    if "--check" in sys.argv:
        stale = [
            path.relative_to(REPO_ROOT)
            for path, content in rendered.items()
            if not path.exists() or path.read_text(encoding="utf-8") != content
        ]
        if stale:
            for path in stale:
                print(f"{path} is out of date")
            print("run Scripts/generate-rules.py")
            return 1
        ids = ", ".join(rule["id"] for rule in document["rules"])
        print(
            f"the shipped rule file and the Swift fallback match the Rust table "
            f"({len(document['rules'])} rules: {ids})"
        )
        return 0

    for path, content in rendered.items():
        write(path, content)
        print(f"wrote {path.relative_to(REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
