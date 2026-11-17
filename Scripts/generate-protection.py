#!/usr/bin/env python3
"""Generate the Swift protection list from the Rust one.

Two engines decide whether a path may be scanned or cleaned: the Rust scanner
core (discovery and analysis) and the Swift rule engine (what the user may
select, what may reach the file operations service). Both lists are compiled in,
because a rule file can widen what is *recognised* but never what may be
*removed* — so neither may be relaxed by a file the user can edit.

Keeping the same list as two hand-written literals is how the two engines drift
apart, and the Swift side then protects less than the Rust side refuses to walk.
The Rust constants are the source; this script renders them as Swift, and
`--check` fails when the generated file no longer matches, so `Scripts/verify.sh`
catches a forgotten regeneration before a commit.

Usage:
    python3 Scripts/generate-protection.py            # writes the Swift file
    python3 Scripts/generate-protection.py --check    # verifies it is current
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
RUST_SOURCE = REPO_ROOT / "RustCore" / "crates" / "sift-rules" / "src" / "lib.rs"
SWIFT_OUTPUT = REPO_ROOT / "Core" / "Rules" / "ProtectedPaths.swift"

# The shape this script understands. Anything else is an error rather than a
# silently empty list: a protection list that fails to parse must not become a
# protection list with nothing in it.
#
# `\s*` after the `=`: rustfmt moves an array literal to the next line once the
# declaration no longer fits, and a generator that only read the single-line
# spelling would fail on a constant that is correct.
ARRAY_CONST = re.compile(
    r"pub const (?P<name>[A-Z_]+): &\[&str\] =\s*&\[(?P<body>.*?)\];",
    re.DOTALL,
)
STRING_CONST = re.compile(
    r'pub const (?P<name>[A-Z_]+): &str = "(?P<value>[^"]*)";',
)
INT_CONST = re.compile(
    r"pub const (?P<name>[A-Z_]+): (?:u32|usize|u64) = (?P<value>\d+);",
)
STRING_LITERAL = re.compile(r'"([^"]*)"')


def read_rust_constant(name: str) -> object:
    source = RUST_SOURCE.read_text(encoding="utf-8")

    for match in ARRAY_CONST.finditer(source):
        if match.group("name") == name:
            values = STRING_LITERAL.findall(match.group("body"))
            if not values:
                raise SystemExit(f"{name} parsed as an empty list in {RUST_SOURCE.name}")
            return values

    for match in STRING_CONST.finditer(source):
        if match.group("name") == name:
            return match.group("value")

    for match in INT_CONST.finditer(source):
        if match.group("name") == name:
            return int(match.group("value"))

    raise SystemExit(
        f"{name} is not declared in {RUST_SOURCE.relative_to(REPO_ROOT)} in the "
        "shape this script reads; update the script and the generated Swift file"
    )


def swift_string_list(values: list[str], indent: str) -> str:
    return "".join(f'{indent}"{value}",\n' for value in values)


def swift_source() -> str:
    home_children = read_rust_constant("PROTECTED_HOME_CHILDREN")
    prefixes = read_rust_constant("PROTECTED_PREFIXES")
    library_children = read_rust_constant("PROTECTED_LIBRARY_CHILDREN")
    user_content = read_rust_constant("PROTECTED_LIBRARY_USER_CONTENT")
    photos_suffix = read_rust_constant("PROTECTED_PHOTOS_LIBRARY_SUFFIX")
    recycle_bin_names = read_rust_constant("PROTECTED_RECYCLE_BIN_NAMES")
    max_min_age_days = read_rust_constant("MAX_RULE_MIN_AGE_DAYS")
    max_rule_roots = read_rust_constant("MAX_RULE_ROOTS")
    relative_path_wildcard = read_rust_constant("RELATIVE_PATH_WILDCARD")
    forbidden_rule_dirs = read_rust_constant("FORBIDDEN_RULE_DIRECTORIES")
    aliases = read_rust_constant("SYMLINK_ALIASES")
    alias_targets = read_rust_constant("SYMLINK_ALIAS_TARGETS")

    assert isinstance(home_children, list)
    assert isinstance(prefixes, list)
    assert isinstance(library_children, list)
    assert isinstance(user_content, list)
    assert isinstance(photos_suffix, str)
    assert isinstance(recycle_bin_names, list)
    assert isinstance(max_min_age_days, int)
    assert isinstance(max_rule_roots, int)
    assert isinstance(relative_path_wildcard, str)
    assert isinstance(forbidden_rule_dirs, list)
    assert isinstance(aliases, list)
    assert isinstance(alias_targets, list)
    if len(aliases) != len(alias_targets):
        raise SystemExit(
            "SYMLINK_ALIASES and SYMLINK_ALIAS_TARGETS are one table read index "
            "for index and must be the same length"
        )

    library_entries = []
    for path in library_children:
        kind = "userContent" if path in user_content else "secrets"
        library_entries.append(f'        ("{path}", .{kind}),\n')

    alias_entries = "".join(
        f'        SymlinkAlias(alias: "{alias}", target: "{target}"),\n'
        for alias, target in zip(aliases, alias_targets)
    )

    return (
        "/// The compiled-in protection list.\n"
        "///\n"
        "/// Generated by `Scripts/generate-protection.py` from the Rust constants in\n"
        "/// `RustCore/crates/sift-rules/src/lib.rs`. Do not edit by hand: one source\n"
        "/// is what stops this engine and the Rust scanner core from protecting\n"
        "/// different sets of paths.\n"
        "public enum ProtectedPaths {\n"
        "    /// Why a `~/Library` child is protected.\n"
        "    public enum LibraryKind: Sendable, Equatable {\n"
        "        /// Holds user data rather than application state.\n"
        "        case userContent\n"
        "        /// Holds credentials, accounts or private messages.\n"
        "        case secrets\n"
        "    }\n"
        "\n"
        "    /// One directory alias macOS ships as a symlink.\n"
        "    ///\n"
        "    /// A named struct rather than a tuple: a global `let` of tuples is not\n"
        "    /// `Sendable` under strict concurrency.\n"
        "    public struct SymlinkAlias: Sendable, Equatable {\n"
        "        public let alias: String\n"
        "        public let target: String\n"
        "\n"
        "        public init(alias: String, target: String) {\n"
        "            self.alias = alias\n"
        "            self.target = target\n"
        "        }\n"
        "    }\n"
        "\n"
        "    /// Paths that are never scanned or cleaned, as children of the home folder.\n"
        "    public static let homeChildren: Set<String> = [\n"
        f"{swift_string_list(home_children, '        ')}"
        "    ]\n"
        "\n"
        "    /// Absolute prefixes that are never scanned or cleaned. Only `/Volumes`\n"
        "    /// may be lifted, and only for a subtree the user granted.\n"
        "    public static let prefixes: [String] = [\n"
        f"{swift_string_list(prefixes, '        ')}"
        "    ]\n"
        "\n"
        "    /// `~/Library` children that hold secrets or user data, with the reason.\n"
        "    public static let libraryChildren: [(path: String, kind: LibraryKind)] = [\n"
        f"{''.join(library_entries)}"
        "    ]\n"
        "\n"
        "    /// Suffix of a photo library package, protected as one unit.\n"
        f'    public static let photosLibrarySuffix = "{photos_suffix}"\n'
        "\n"
        "    /// Directory names that mark a recycle bin, at any depth.\n"
        "    ///\n"
        "    /// Every removal this product performs moves an item *to* the Trash,\n"
        "    /// and the undo it promises is the user emptying that Trash later.\n"
        "    /// Offering the Trash itself inverts that promise, so the names are\n"
        "    /// refused as a whole component anywhere in a path. The Rust core\n"
        "    /// checks the same list.\n"
        "    public static let recycleBinNames: [String] = [\n"
        f"{swift_string_list(recycle_bin_names, '        ')}"
        "    ]\n"
        "\n"
        "    /// Rule-schema limits shared with the Rust rule loader.\n"
        "    ///\n"
        "    /// A rule file one engine accepts and the other refuses fails the whole\n"
        "    /// scan, so the domain of `minAgeDays` and the directories no rule may\n"
        "    /// name are read from the same Rust constants rather than restated here.\n"
        f"    public static let maximumMinAgeDays = {max_min_age_days}\n"
        "\n"
        "    /// The one wildcard a `relativePath` may use, and the bound on how\n"
        "    /// many directories it may expand to.\n"
        "    ///\n"
        "    /// A component is a literal name or exactly this, and it matches one\n"
        "    /// directory name. A wildcard enumerates a tree the rule author never\n"
        "    /// saw, so the expansion is bounded; a rule that exceeds the bound\n"
        "    /// contributes nothing rather than an unpredictable subset.\n"
        f'    public static let relativePathWildcard = "{relative_path_wildcard}"\n'
        f"    public static let maximumRuleRoots = {max_rule_roots}\n"
        "\n"
        "    /// Directory names no rule may target, whoever wrote the rule file.\n"
        "    public static let forbiddenRuleDirectories: [String] = [\n"
        f"{swift_string_list(forbidden_rule_dirs, '        ')}"
        "    ]\n"
        "\n"
        "    /// The directory aliases macOS ships as symlinks.\n"
        "    ///\n"
        "    /// `/var` is a symlink to `/private/var`, so a path arriving as\n"
        "    /// `/var/db/...` has to be compared in its `/private/var/db` spelling or\n"
        "    /// it would match none of the prefixes above. The Rust side normalises\n"
        "    /// with this same table.\n"
        "    public static let symlinkAliases: [SymlinkAlias] = [\n"
        f"{alias_entries}"
        "    ]\n"
        "}\n"
    )


def main() -> int:
    rendered = swift_source()

    if "--check" in sys.argv:
        current = SWIFT_OUTPUT.read_text(encoding="utf-8") if SWIFT_OUTPUT.exists() else ""
        if current != rendered:
            print(
                f"{SWIFT_OUTPUT.relative_to(REPO_ROOT)} is out of date; "
                "run Scripts/generate-protection.py"
            )
            return 1
        counts = (
            len(read_rust_constant("PROTECTED_HOME_CHILDREN")),
            len(read_rust_constant("PROTECTED_PREFIXES")),
            len(read_rust_constant("PROTECTED_LIBRARY_CHILDREN")),
            len(read_rust_constant("SYMLINK_ALIASES")),
        )
        print(
            "the Swift protection list matches the Rust one "
            f"({counts[0]} home children, {counts[1]} prefixes, {counts[2]} library children, "
            f"{counts[3]} symlink aliases)"
        )
        return 0

    SWIFT_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    with SWIFT_OUTPUT.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(rendered)
    print(f"wrote {SWIFT_OUTPUT.relative_to(REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
