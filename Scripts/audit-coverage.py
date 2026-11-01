#!/usr/bin/env python3
"""Report what the shipped rule table actually finds on this Mac.

The rule table says what Sift recognises; nothing said how much of a real home
folder it reaches. Two questions this answers, neither of which a test can:

  1. **Which rules find nothing?** A rule that reports zero items on every Mac is
     either dead or aimed at a shape no application uses any more. The table is
     the product's definition of "cleanable", so a rule nobody exercises is a
     claim nobody checks.
  2. **Which large directories does no rule reach?** `~/Library/Application
     Support/<app>` is deliberately not an item — it is the application's live
     data — but the report says so instead of leaving the user to wonder why the
     biggest subtree on the disk is missing from the list.
  3. **Who answers for a group container?** `~/Library/Group Containers` is named
     after an app group, so two applications sharing one are invisible to any
     name-based test. The last section reads every installed bundle's
     `com.apple.security.application-groups` and reports the containers the
     name-based scan reports as residue while an application still declares them
     (`declaredWithoutAName`).

The numbers are produced the way the engines produce them: the shipped
`CleaningRules.json`, the same anchors, the same one-segment wildcard, the same
`matchSpec` semantics, the same age filter (a directory with a fresh file inside
it is not a candidate, because the move takes the fresh file too), the same
allocated-size accounting (`st_blocks`, which is what the Finder shows). It is
still a second implementation of that logic, which is why `--self-check` builds a
fixture of known size and asserts the counts: the audit is a measurement, never a
gate, and nothing in the product reads it.

Usage:
    python3 Scripts/audit-coverage.py                  # this Mac
    python3 Scripts/audit-coverage.py --home /some/dir  # a fixture or a backup
    python3 Scripts/audit-coverage.py --json            # machine readable
    python3 Scripts/audit-coverage.py --only-group-containers  # just the last section
    python3 Scripts/audit-coverage.py --self-check      # exit 1 on a wrong count
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
RULES_JSON = REPO_ROOT / "Core" / "Resources" / "CleaningRules.json"

# The same bound the engines apply (`MAX_RULE_ROOTS`). A wildcard that expands
# past it contributes nothing rather than a partial set.
MAX_RULE_ROOTS = 4096

# `ProtectedPaths.swift` is generated from the Rust constants and carries the
# whole list; the audit only needs the anchors it walks, so it reads the two
# numbers it cares about instead of parsing a Swift file.
DEFAULT_STALE_DAYS = 30

# Directory names the walkers never descend into. A subset of the engines'
# list is enough here: the audit measures, it does not decide.
SKIP_DIRECTORY_NAMES = {".git", "node_modules"}

# Directories a built-in scanner reads, relative to the home directory. A folder
# here is covered even when today's scan found nothing in it, which is the same
# rule `RuleCoverageAnalyzer.scannerCoveredDirectories` applies in the app: the
# threshold scans are deliberately absent, because they cover the whole tree and
# would empty the list this column exists to produce.
SCANNER_COVERED = {
    "Library/Application Support",
    "Library/Caches",
    "Library/Containers",
    "Library/Group Containers",
    "Library/HTTPStorages",
    "Library/Logs",
    "Library/Preferences",
    "Library/Saved Application State",
    "Library/WebKit",
}


class Measurement:
    """What one item occupies, and how old its oldest file is."""

    __slots__ = ("bytes", "files", "oldest", "matching_bytes", "matching_files", "oldest_matching")

    def __init__(self) -> None:
        self.bytes = 0
        self.files = 0
        self.oldest = 0.0
        self.matching_bytes = 0
        self.matching_files = 0
        self.oldest_matching = 0.0


def allocated_size(entry: os.DirEntry) -> int:
    """The size the Finder reports for this entry.

    `st_blocks * 512` rather than `st_size`: the engines report allocated size,
    and a report that disagreed with the row the user sees would be worse than no
    report.
    """
    try:
        info = entry.stat(follow_symlinks=False)
    except OSError:
        return 0
    if not stat.S_ISREG(info.st_mode):
        return 0
    return info.st_blocks * 512


def measure(path: Path, min_age_days: int | None, cutoff: float, include_hidden: bool) -> Measurement:
    """Measure one item, and separately the part of it that passes the age filter.

    The two are measured together because a threshold rule may only *decide*
    whether a directory qualifies: if any file inside is fresh, the whole
    directory is not a candidate, since the move would take the fresh file too.
    """
    result = Measurement()
    stack = [str(path)]
    while stack:
        current = stack.pop()
        try:
            entries = list(os.scandir(current))
        except OSError:
            continue
        for entry in entries:
            name = entry.name
            if not include_hidden and name.startswith("."):
                continue
            try:
                if entry.is_symlink():
                    continue
                if entry.is_dir(follow_symlinks=False):
                    if name not in SKIP_DIRECTORY_NAMES:
                        stack.append(entry.path)
                    continue
            except OSError:
                continue
            size = allocated_size(entry)
            try:
                modified = entry.stat(follow_symlinks=False).st_mtime
            except OSError:
                continue
            result.bytes += size
            result.files += 1
            result.oldest = modified if result.oldest == 0 else min(result.oldest, modified)
            if min_age_days is None or modified <= cutoff:
                result.matching_bytes += size
                result.matching_files += 1
                result.oldest_matching = (
                    modified
                    if result.oldest_matching == 0
                    else min(result.oldest_matching, modified)
                )
    return result


def measure_once(path: Path, include_hidden: bool) -> tuple[int, int, float]:
    """Bytes, files and the *oldest* modification time of one tree.

    One walk answers every age at once: a directory is eligible for an age
    threshold when its oldest file is older than the threshold, so the same
    measurement decides the answer for 7, 30, 90 and 180 days. That is what makes
    `--age-sweep` one walk per rule instead of one per age.
    """
    total = 0
    files = 0
    oldest = 0.0
    stack = [str(path)]
    while stack:
        current = stack.pop()
        try:
            entries = list(os.scandir(current))
        except OSError:
            continue
        for entry in entries:
            if not include_hidden and entry.name.startswith("."):
                continue
            try:
                if entry.is_symlink():
                    continue
                if entry.is_dir(follow_symlinks=False):
                    if entry.name not in SKIP_DIRECTORY_NAMES:
                        stack.append(entry.path)
                    continue
                modified = entry.stat(follow_symlinks=False).st_mtime
            except OSError:
                continue
            total += allocated_size(entry)
            files += 1
            oldest = modified if oldest == 0 else min(oldest, modified)
    return total, files, oldest


def child_directories(directory: Path) -> list[Path]:
    try:
        entries = list(os.scandir(directory))
    except OSError:
        return []
    found = []
    for entry in sorted(entries, key=lambda item: item.name):
        try:
            if entry.is_symlink() or not entry.is_dir(follow_symlinks=False):
                continue
        except OSError:
            continue
        found.append(Path(entry.path))
    return found


def walk_files(root: Path, include_hidden: bool):
    """Every file under `root`, never following a symlink."""
    stack = [str(root)]
    while stack:
        current = stack.pop()
        try:
            entries = list(os.scandir(current))
        except OSError:
            continue
        for entry in entries:
            if not include_hidden and entry.name.startswith("."):
                continue
            try:
                if entry.is_symlink():
                    continue
                if entry.is_dir(follow_symlinks=False):
                    if entry.name not in SKIP_DIRECTORY_NAMES:
                        stack.append(entry.path)
                    continue
            except OSError:
                continue
            yield Path(entry.path)


def session_root() -> Path | None:
    """`/var/folders/<xx>/<hash>` for this login session, from `TMPDIR`.

    The rule table anchors one rule there (`user-temp-caches`); the engines get
    the path in the scan request, resolved with `confstr`. The audit is a shell
    script away from that API, so it uses the environment, and `--session-root`
    exists for a run that wants the answer to be reproducible.
    """
    raw = os.environ.get("TMPDIR")
    if not raw:
        return None
    candidate = Path(raw).parent
    return candidate if candidate.is_dir() else None


def anchor_bases(
    rule: dict,
    home: Path,
    grants: list[Path],
    session: Path | None,
) -> list[Path]:
    anchor = rule.get("root")
    if anchor == "home":
        return [home]
    if anchor == "homeLibrary":
        return [home / "Library"]
    if anchor == "applications":
        return [Path("/Applications")]
    if anchor == "systemLibrary":
        return [Path("/Library")]
    if anchor == "userTemp":
        return [session] if session is not None else []
    if anchor == "authorized":
        return sorted(grants)
    if anchor == "externalVolume":
        return sorted(grants)
    return []


def rule_roots(
    rule: dict,
    home: Path,
    grants: list[Path],
    include_hidden: bool,
    session: Path | None = None,
) -> list[Path]:
    relative = [part for part in rule.get("relativePath", "").split("/") if part]
    roots: list[Path] = []
    for base in anchor_bases(rule, home, grants, session):
        current = [base]
        for component in relative:
            if component == "*":
                expanded: list[Path] = []
                for directory in current:
                    children = child_directories(directory)
                    if not include_hidden:
                        children = [c for c in children if not c.name.startswith(".")]
                    expanded.extend(children)
                    if len(expanded) >= MAX_RULE_ROOTS:
                        break
                current = expanded
            else:
                current = [directory / component for directory in current]
            if not current:
                break
        if len(current) >= MAX_RULE_ROOTS:
            # A rule that expands past the bound contributes nothing in the
            # engines, so it contributes nothing here either.
            return []
        roots.extend(current)
    return roots


def excluded_by_rule(rule: dict, path: Path, root: Path) -> bool:
    excludes = rule.get("excludes") or []
    if not excludes:
        return False
    try:
        relative = path.relative_to(root).parts
    except ValueError:
        return False
    for component in relative:
        for exclude in excludes:
            if component == exclude or component.startswith(exclude + "."):
                return True
    return False


class Item:
    __slots__ = ("path", "rule_id", "bytes", "files", "is_directory")

    def __init__(self, path: Path, rule_id: str, measured: Measurement, is_directory: bool):
        self.path = path
        self.rule_id = rule_id
        self.bytes = measured.bytes
        self.files = measured.files
        self.is_directory = is_directory


def items_for_rule(
    rule: dict,
    home: Path,
    grants: list[Path],
    stale_days: int,
    include_hidden: bool,
    now: float,
    session: Path | None = None,
) -> list[Item]:
    spec = rule.get("matchSpec")
    relative = [part for part in rule.get("relativePath", "").split("/") if part]
    if spec is None:
        spec = "directory" if relative else "childDirectories"

    minimum_age = rule.get("minAgeDays")
    if minimum_age is not None and rule.get("usesStaleThreshold") and stale_days > 0:
        minimum_age = stale_days
    cutoff = now - minimum_age * 86_400 if minimum_age is not None else 0.0

    names = {name.casefold() for name in (rule.get("names") or [])}
    extensions = {extension.lower().lstrip(".") for extension in (rule.get("extensions") or [])}

    items: list[Item] = []
    for root in rule_roots(rule, home, grants, include_hidden, session):
        try:
            if not root.exists():
                continue
        except OSError:
            continue

        if spec == "directory":
            candidates = [root]
        elif spec == "childDirectories" or spec == "directoriesNamed":
            candidates = child_directories(root)
            if spec == "directoriesNamed":
                candidates = [c for c in candidates if c.name.casefold() in names]
        else:
            candidates = []

        if spec in ("directory", "childDirectories", "directoriesNamed"):
            for candidate in candidates:
                if excluded_by_rule(rule, candidate, root):
                    continue
                measured = measure(candidate, minimum_age, cutoff, include_hidden)
                # A threshold may only decide eligibility: a directory holding a
                # fresh file is not an item, because the move would take it too.
                if minimum_age is not None and (
                    measured.matching_bytes != measured.bytes
                    or measured.matching_files != measured.files
                ):
                    continue
                if measured.bytes == 0:
                    continue
                items.append(Item(candidate, rule["id"], measured, True))
            continue

        # File-level specifications: the age filter selects files, and the item
        # is the file.
        for path in walk_files(root, include_hidden):
            if excluded_by_rule(rule, path, root):
                continue
            if spec == "filesByExtension":
                if path.suffix.lower().lstrip(".") not in extensions:
                    continue
            try:
                modified = os.lstat(path).st_mtime
            except OSError:
                continue
            if minimum_age is not None and modified > cutoff:
                continue
            measured = Measurement()
            entry = _entry_for(path)
            measured.bytes = allocated_size(entry) if entry is not None else 0
            measured.files = 1
            items.append(Item(path, rule["id"], measured, False))
    return items


def age_candidates(
    rule: dict,
    home: Path,
    grants: list[Path],
    include_hidden: bool,
    session: Path | None,
) -> list[tuple[int, int, float]]:
    """Every item a rule *could* find, with its size and its oldest file.

    The age is not applied here: the caller decides eligibility for each age it
    asks about. Files are items on their own (the age selects the file); a
    directory is one item whose oldest file decides whether the whole move is
    stale.
    """
    spec = rule.get("matchSpec")
    relative = [part for part in rule.get("relativePath", "").split("/") if part]
    if spec is None:
        spec = "directory" if relative else "childDirectories"

    names = {name.casefold() for name in (rule.get("names") or [])}
    extensions = {extension.lower().lstrip(".") for extension in (rule.get("extensions") or [])}

    measured: list[tuple[int, int, float]] = []
    for root in rule_roots(rule, home, grants, include_hidden, session):
        try:
            if not root.exists():
                continue
        except OSError:
            continue

        if spec in ("directory", "childDirectories", "directoriesNamed"):
            if spec == "directory":
                candidates = [root]
            else:
                candidates = child_directories(root)
                if spec == "directoriesNamed":
                    candidates = [c for c in candidates if c.name.casefold() in names]
            for candidate in candidates:
                if excluded_by_rule(rule, candidate, root):
                    continue
                measured.append(measure_once(candidate, include_hidden))
            continue

        for path in walk_files(root, include_hidden):
            if excluded_by_rule(rule, path, root):
                continue
            if spec == "filesByExtension" and path.suffix.lower().lstrip(".") not in extensions:
                continue
            try:
                modified = os.lstat(path).st_mtime
            except OSError:
                continue
            entry = _entry_for(path)
            measured.append((allocated_size(entry) if entry is not None else 0, 1, modified))
    return measured


def age_sweep(
    home: Path,
    grants: list[Path],
    ages: list[int],
    include_hidden: bool,
    session: Path | None,
) -> dict:
    """Would a different age threshold find more, or less?

    The shipped ages (7, 30, 180) were chosen on one machine's data. This prints
    the whole curve, so the next window can be argued about with numbers instead of
    a guess: each cell is what that rule would offer at that age, on this Mac.
    """
    document = json.loads(RULES_JSON.read_text(encoding="utf-8"))
    now = time.time()
    rows = []
    totals = {age: {"items": 0, "bytes": 0} for age in ages}

    for rule in document["rules"]:
        if not include_hidden and any(
            part.startswith(".") for part in rule.get("relativePath", "").split("/")
        ):
            candidates: list[tuple[int, int, float]] = []
        else:
            candidates = age_candidates(rule, home, grants, include_hidden, session)
        by_age: dict[int, dict[str, int]] = {}
        for age in ages:
            cutoff = now - age * 86_400
            eligible = [entry for entry in candidates if entry[0] > 0 and entry[2] <= cutoff]
            by_age[age] = {
                "items": len(eligible),
                "bytes": sum(entry[0] for entry in eligible),
            }
            totals[age]["items"] += by_age[age]["items"]
            totals[age]["bytes"] += by_age[age]["bytes"]
        if any(by_age[age]["items"] for age in ages):
            rows.append({"id": rule["id"], "byAge": by_age})

    return {"home": str(home), "ages": ages, "rules": rows, "totals": totals}


def print_sweep(result: dict) -> None:
    ages = result["ages"]
    header = f"{'规则':28s}" + "".join(f"{str(age) + ' 天':>18s}" for age in ages)
    print(f"阈值扫描  home={result['home']}\n")
    print(header)
    print("-" * len(header))
    for row in sorted(result["rules"], key=lambda r: r["byAge"][ages[0]]["bytes"], reverse=True):
        cells = "".join(
            f"{row['byAge'][age]['items']:5d} / {human(row['byAge'][age]['bytes']):>10s}"
            for age in ages
        )
        print(f"{row['id']:28s}{cells}")
    print("-" * len(header))
    total_cells = "".join(
        f"{result['totals'][age]['items']:5d} / {human(result['totals'][age]['bytes']):>10s}"
        for age in ages
    )
    print(f"{'合计':28s}{total_cells}")
    print("\n每条规则在更长的年龄下只会更少（目录以最旧的文件判定），所以新规则引入前可以用左侧一列对照右侧一列。")


def _entry_for(path: Path) -> os.DirEntry | None:
    try:
        scanner = os.scandir(path.parent)
    except OSError:
        return None
    try:
        for entry in scanner:
            if entry.name == path.name:
                return entry
    except OSError:
        return None
    finally:
        scanner.close()
    return None


def human(bytes_count: int) -> str:
    value = float(bytes_count)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if value < 1024 or unit == "TB":
            return f"{value:.0f} {unit}" if unit == "B" else f"{value:.1f} {unit}"
        value /= 1024
    return f"{value:.1f} TB"


def audit(
    home: Path,
    grants: list[Path],
    stale_days: int,
    include_hidden: bool,
    include_system: bool = False,
    session: Path | None = None,
) -> dict:
    document = json.loads(RULES_JSON.read_text(encoding="utf-8"))
    now = time.time()
    rules = document["rules"]

    per_rule = []
    items: list[Item] = []
    # Which rule *could* reach each root, independent of whether it found
    # anything today: "no rule exists for this folder" and "the rule exists and
    # this Mac has nothing for it" are different answers, and only the second is
    # normal.
    root_owners: dict[Path, set[str]] = {}
    for rule in rules:
        # A rule that lives inside a dot-directory is out of scope when hidden
        # entries are, exactly as both engines decide it.
        if not include_hidden and any(
            part.startswith(".") for part in rule.get("relativePath", "").split("/")
        ):
            found = []
        else:
            found = items_for_rule(rule, home, grants, stale_days, include_hidden, now, session)
        if include_hidden or not any(
            part.startswith(".") for part in rule.get("relativePath", "").split("/")
        ):
            for root in rule_roots(rule, home, grants, include_hidden, session):
                root_owners.setdefault(root, set()).add(rule["id"])
        items.extend(found)
        per_rule.append(
            {
                "id": rule["id"],
                "spec": rule.get("matchSpec") or "",
                "risk": rule.get("risk"),
                "relativePath": rule.get("relativePath", ""),
                "roots": len(rule_roots(rule, home, grants, include_hidden, session)),
                "items": len(found),
                "bytes": sum(item.bytes for item in found),
                "files": sum(item.files for item in found),
            }
        )

    # Which rules reach into each top-level directory, and how big that directory
    # is. A directory no rule reaches is the audit's headline: it is the part of
    # the disk the user is right to wonder about.
    anchors = [("homeLibrary", home / "Library"), ("home", home)]
    if include_system:
        # `/Library` is the system anchor. It is measured only on request: it is
        # large, it is mostly not cleanable, and an audit of a fixture home has
        # no business reading it.
        anchors.append(("systemLibrary", Path("/Library")))
    top_level = []
    for name, directory in anchors:
        if not directory.exists():
            continue
        for child in child_directories(directory):
            if name == "home" and child.name == "Library":
                continue
            covering = {item.rule_id for item in items if _inside(child, item.path)}
            for root, owner_ids in root_owners.items():
                if _inside(child, root):
                    covering |= owner_ids
            covering = sorted(covering)
            measured = measure(child, None, 0.0, include_hidden)
            try:
                relative = child.relative_to(home).as_posix()
            except ValueError:
                relative = ""
            top_level.append(
                {
                    "anchor": name,
                    "path": str(child),
                    "bytes": measured.bytes,
                    "items": sum(1 for item in items if _inside(child, item.path)),
                    "rules": covering,
                    # A scanner covering a folder is not a rule covering it: the
                    # column says which rule table entry reaches here, and this
                    # answers the different question the column implied.
                    "scanner": relative in SCANNER_COVERED,
                }
            )

    claimed = {item.path for item in items}
    return {
        "home": str(home),
        "staleDays": stale_days,
        "rules": per_rule,
        "topLevel": sorted(top_level, key=lambda row: row["bytes"], reverse=True),
        "totals": {
            "rules": len(per_rule),
            "items": len(items),
            "distinctItems": len(claimed),
            "bytes": sum(entry["bytes"] for entry in per_rule),
            "emptyRules": [entry["id"] for entry in per_rule if entry["items"] == 0],
        },
    }


def _inside(parent: Path, path: Path) -> bool:
    try:
        return parent == path or parent in path.parents
    except (OSError, ValueError):
        return False


# MARK: - Group containers

GROUP_CONTAINER_ROOT = "Library/Group Containers"
# The ages the group-container section reports, in days. The ladder is the same
# one `--age-sweep` prints for rules, so the two sections can be read together.
GROUP_AGE_LADDER = (7, 30, 90, 180)
APP_GROUP_ENTITLEMENT = "com.apple.security.application-groups"
APPLICATION_DIRECTORIES = (
    "/Applications",
    "/Applications/Utilities",
    "/System/Applications",
    "/System/Applications/Utilities",
)

# What a container's name means for who owns it.
DECLARED = "declared"
NAMED = "named"
RESIDUE = "residue"


def bundle_name_readings(name: str) -> list[str]:
    """The identifiers a directory name could stand for, lower-cased.

    The same three spellings `BundleNameReadings.identifiers` produces on the
    Swift side, re-implemented because this audit must run without building the
    product: the identifier itself, and — when the first dot-separated segment
    carries no dot, which is the shape of a team id and of the `group.` prefix —
    the name with that segment removed.
    """
    lowered = name.lower()
    readings: list[str] = []
    if "." in lowered:
        prefix, _, suffix = lowered.partition(".")
        if "." not in prefix and suffix:
            readings.append(suffix)
    readings.append(lowered)
    return readings


def installed_application_bundles(home: Path, include_system: bool = True) -> list[Path]:
    """Every `.app` below the application directories, depth-capped at three.

    Vendors nest one level deeper than `/Applications/<App>.app`; a bundle is
    never descended into, and the cap keeps a stray package tree from turning
    this into a full-disk walk.
    """
    directories = [Path(APPLICATION_DIRECTORIES[0]), Path(APPLICATION_DIRECTORIES[1]), home / "Applications"]
    if include_system:
        directories += [Path(APPLICATION_DIRECTORIES[2]), Path(APPLICATION_DIRECTORIES[3])]
    bundles: list[Path] = []
    seen: set[str] = set()
    for directory in directories:
        if not directory.is_dir():
            continue
        for pattern in ("*.app", "*/*.app", "*/*/*.app"):
            for candidate in sorted(directory.glob(pattern)):
                if not candidate.is_dir():
                    continue
                key = str(candidate.resolve())
                if key in seen:
                    continue
                seen.add(key)
                bundles.append(candidate)
    return bundles


def application_bundle_identifiers(bundles: list[Path]) -> set[str]:
    """The `CFBundleIdentifier` of every bundle, lower-cased.

    This is the same question the engines answer through LaunchServices, read
    from the bundle instead so the audit needs no registered application.
    """
    identifiers: set[str] = set()
    for bundle in bundles:
        plist = bundle / "Contents" / "Info.plist"
        try:
            document = plistlib.loads(plist.read_bytes())
        except (OSError, plistlib.InvalidFileException, ValueError):
            continue
        identifier = document.get("CFBundleIdentifier")
        if isinstance(identifier, str) and identifier:
            identifiers.add(identifier.lower())
    return identifiers


def declared_app_groups(bundle: Path, timeout: float = 10.0) -> set[str]:
    """The app groups an application's signature grants it.

    `codesign -d --entitlements` rather than a Security-framework call: this is a
    Python measurement, and the entitlement is the one fact a container's name
    cannot express. A bundle with no signature, or one whose entitlements cannot
    be read, declares nothing — which is the ordinary answer, not a failure.
    """
    if shutil.which("codesign") is None:
        return set()
    try:
        completed = subprocess.run(
            ["codesign", "-d", "--entitlements", ":-", "--xml", str(bundle)],
            capture_output=True,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return set()
    payload = completed.stdout
    start = payload.find(b"<?xml")
    if start < 0:
        return set()
    try:
        document = plistlib.loads(payload[start:])
    except (plistlib.InvalidFileException, ValueError):
        return set()
    groups = document.get(APP_GROUP_ENTITLEMENT) or []
    return {str(group).lower() for group in groups if group}


def app_group_index(bundles: list[Path]) -> dict[str, list[str]]:
    """Group identifier -> the applications declaring it.

    One signature read per installed bundle: 135 bundles take about half a
    second, which is why the audit does it once and caches nothing on disk.
    """
    index: dict[str, set[str]] = {}
    for bundle in bundles:
        for group in declared_app_groups(bundle):
            index.setdefault(group, set()).add(bundle.stem)
    return {group: sorted(names) for group, names in sorted(index.items())}


PRIVATE_CONTAINER_ROOT = "Library/Containers"


def private_container_report(
    home: Path,
    installed: set[str] | None = None,
    include_system: bool = True,
    stale_days: int = DEFAULT_STALE_DAYS,
) -> dict:
    """The same two questions for a private container: is it live, and how old.

    A private container is named exactly after its bundle identifier, so the
    residue test is one comparison rather than a reading list — which is also why
    this section exists separately: the shared-container section measures a
    directory whose name cannot answer the question at all, and the two should not
    be read as one number. The age ladder and the filter comparison are the same
    shape as the group section's, so the two can be compared line by line.
    """
    if installed is None:
        installed = application_bundle_identifiers(
            installed_application_bundles(home, include_system)
        )

    directory = home / PRIVATE_CONTAINER_ROOT
    now = time.time()
    rows: list[dict] = []
    for child in child_directories(directory):
        lowered = child.name.lower()
        live = lowered in installed or any(
            reading in installed for reading in bundle_name_readings(child.name)
        )
        measured_bytes, files, oldest = measure_once(child, True)
        rows.append(
            {
                "name": child.name,
                "path": str(child),
                "kind": NAMED if live else RESIDUE,
                "bytes": measured_bytes,
                "files": files,
                "ageDays": round((now - oldest) / 86_400) if oldest else None,
            }
        )

    residue = [row for row in rows if row["kind"] == RESIDUE]
    offered = [row for row in residue if row["bytes"] > 0]
    stale = [row for row in offered if (row["ageDays"] or 0) >= stale_days]
    fresh = [row for row in offered if row not in stale]
    return {
        "path": str(directory),
        "totals": {
            kind: {
                "containers": sum(1 for row in rows if row["kind"] == kind),
                "bytes": sum(row["bytes"] for row in rows if row["kind"] == kind),
            }
            for kind in (NAMED, RESIDUE)
        },
        "residue": sorted(residue, key=lambda row: row["bytes"], reverse=True),
        "residueAges": [
            {
                "days": days,
                "containers": sum(1 for row in residue if (row["ageDays"] or 0) >= days),
                "bytes": sum(row["bytes"] for row in residue if (row["ageDays"] or 0) >= days),
            }
            for days in GROUP_AGE_LADDER
        ],
        "staleFilter": {
            "days": stale_days,
            "kept": len(stale),
            "keptBytes": sum(row["bytes"] for row in stale),
            "dropped": len(fresh),
            "droppedBytes": sum(row["bytes"] for row in fresh),
            "droppedFreshWithinAWeek": sum(1 for row in fresh if (row["ageDays"] or 0) < 7),
        },
    }


def print_private_report(report: dict, limit: int) -> None:
    """The private-container section: how much of `~/Library/Containers` is dead."""
    totals = report["totals"]
    total = sum(entry["containers"] for entry in totals.values())
    print(f"\n私有容器归属（{report['path']}，{total} 个容器）")
    print(f"{'容器':>6s} {'体积':>10s}  判定")
    print("-" * 60)
    print(f"{totals[NAMED]['containers']:6d} {human(totals[NAMED]['bytes']):>10s}  应用仍安装")
    print(f"{totals[RESIDUE]['containers']:6d} {human(totals[RESIDUE]['bytes']):>10s}  残留：应用已卸载")
    print(
        "\n注意：这一节只按名字比对已安装的应用包，所以「残留」是一个上限——"
        "系统守护进程、扩展和从未作为应用安装过的组件（例如 com.apple.mediaanalysisd）"
        "也会落进这一栏。产品里的引擎另外用 LaunchServices 解析这些名字，"
        "本审计没有这一层，读数只能当上限用。"
    )

    stale = report["staleFilter"]
    if stale["kept"] or stale["dropped"]:
        print(
            f"\n按 {stale['days']} 天过滤会变成：保留 {stale['kept']} 个 / "
            f"{human(stale['keptBytes'])}，隐藏 {stale['dropped']} 个 / "
            f"{human(stale['droppedBytes'])}"
            f"（其中 {stale['droppedFreshWithinAWeek']} 个是 7 天内写入的）"
        )
    ages = report["residueAges"]
    if any(entry["containers"] for entry in ages):
        print("残留容器的年龄（最近一次写入早于该天数）")
        for entry in ages:
            print(
                f"  ≥ {entry['days']:3d} 天  {entry['containers']:4d} 个  "
                f"{human(entry['bytes']):>10s}"
            )
    residue = report["residue"][:limit]
    if residue:
        print(f"\n最大的残留容器（前 {len(residue)} 项）")
        for row in residue:
            age = "—" if row["ageDays"] is None else f"{row['ageDays']}天"
            print(f"{human(row['bytes']):>10s} {row['files']:8d} {age:>8s}  {row['name']}")


def name_claims_an_installed_application(name: str, installed: set[str]) -> bool:
    """Whether the name alone points at something installed.

    This is the whole of the name-based evidence the residue scan has, kept
    separate so the entitlement answer can be compared against it.
    """
    return any(reading in installed for reading in bundle_name_readings(name))


def classify_group_container(
    name: str,
    declarations: dict[str, list[str]],
    installed: set[str],
) -> str:
    """Who a container belongs to: `declared`, `named`, or `residue`.

    `declared` is an application whose entitlements name this exact group, so two
    applications that share a container are found however the container is
    spelled. `named` is the weaker reading both engines use — the container's name
    contains an installed application's identifier — and it misses every
    container shared by two applications, because the name belongs to the group
    rather than to either of them.
    """
    if name.lower() in declarations:
        return DECLARED
    if name_claims_an_installed_application(name, installed):
        return NAMED
    return RESIDUE


def group_container_report(
    home: Path,
    declarations: dict[str, list[str]] | None = None,
    installed: set[str] | None = None,
    include_system: bool = True,
    use_entitlements: bool = True,
    stale_days: int = DEFAULT_STALE_DAYS,
) -> dict:
    """How many group containers this Mac has, and who answers for each.

    The interesting number is the difference between `declared` and `named`: a
    container an application still declares but whose name resolves to nothing is
    reported as residue by the name-based scan. This section is the measurement
    that says how large that difference is on a real machine.
    """
    bundles: list[Path] = []
    if declarations is None or installed is None:
        bundles = installed_application_bundles(home, include_system)
    if declarations is None:
        declarations = app_group_index(bundles) if use_entitlements else {}
    if installed is None:
        installed = application_bundle_identifiers(bundles)

    directory = home / GROUP_CONTAINER_ROOT
    now = time.time()
    rows: list[dict] = []
    for child in child_directories(directory):
        kind = classify_group_container(child.name, declarations, installed)
        # `measure_once` answers the age question from the same walk: a container
        # is only worth offering when nothing has written to it for a while, and
        # asking for its size and its oldest file separately would walk it twice.
        measured_bytes, files, oldest = measure_once(child, True)
        rows.append(
            {
                "name": child.name,
                "path": str(child),
                "kind": kind,
                "bytes": measured_bytes,
                "files": files,
                # 0 when the container holds no file at all: it has no age, and
                # reporting "0 days" would read as "written just now".
                "ageDays": round((now - oldest) / 86_400) if oldest else None,
                "sharedWith": declarations.get(child.name.lower(), []),
            }
        )

    totals = {
        kind: {
            "containers": sum(1 for row in rows if row["kind"] == kind),
            "bytes": sum(row["bytes"] for row in rows if row["kind"] == kind),
        }
        for kind in (DECLARED, NAMED, RESIDUE)
    }
    declared = [row for row in rows if row["kind"] == DECLARED]
    missed = [row for row in declared if not name_claims_an_installed_application(row["name"], installed)]
    residue = [row for row in rows if row["kind"] == RESIDUE]
    # What an age threshold would do to the residue list, measured rather than
    # assumed. The engines already skip a container that measures zero bytes, so
    # the comparison is over the rows that would actually be offered: an age
    # filter can only hide containers that hold something.
    offered = [row for row in residue if row["bytes"] > 0]
    stale = [row for row in offered if (row["ageDays"] or 0) >= stale_days]
    fresh = [row for row in offered if row not in stale]
    stale_filter = {
        "days": stale_days,
        "kept": len(stale),
        "keptBytes": sum(row["bytes"] for row in stale),
        "dropped": len(fresh),
        "droppedBytes": sum(row["bytes"] for row in fresh),
        "droppedFreshWithinAWeek": sum(1 for row in fresh if (row["ageDays"] or 0) < 7),
    }
    # The same age ladder the rule audit prints, derived from one measurement per
    # container: how much of the residue is actually stale enough to be worth a
    # cleanup, and how much of it is a container something wrote to last week.
    ages = [
        {
            "days": days,
            "containers": sum(1 for row in residue if (row["ageDays"] or 0) >= days),
            "bytes": sum(row["bytes"] for row in residue if (row["ageDays"] or 0) >= days),
        }
        for days in GROUP_AGE_LADDER
    ]
    return {
        "path": str(directory),
        "entitlementsRead": use_entitlements,
        "applications": len(bundles),
        "groupDeclarations": len(declarations),
        "totals": totals,
        "residue": sorted(
            (row for row in rows if row["kind"] == RESIDUE),
            key=lambda row: row["bytes"],
            reverse=True,
        ),
        "shared": sorted(
            (row for row in rows if row["kind"] != RESIDUE),
            key=lambda row: row["bytes"],
            reverse=True,
        ),
        # The containers the name-based scan reports as residue while an installed
        # application still declares their group: the entitlement read is the only
        # evidence they are in use. `declaredWithAName` is the rest of the
        # `declared` bucket — the ones the name already resolves.
        "declaredWithoutAName": len(missed),
        "declaredWithoutANameBytes": sum(row["bytes"] for row in missed),
        "declaredWithAName": len(declared) - len(missed),
        "residueAges": ages,
        "staleFilter": stale_filter,
        "residueWithoutFiles": sum(1 for row in residue if row["ageDays"] is None),
    }



def print_report(result: dict, limit: int) -> None:
    print(f"规则覆盖审计  home={result['home']}  过期阈值={result['staleDays']} 天\n")

    header = f"{'规则':28s} {'级别':8s} {'根':>4s} {'条目':>6s} {'体积':>10s} {'文件':>8s}  relativePath"
    print(header)
    print("-" * len(header))
    for entry in sorted(result["rules"], key=lambda row: row["bytes"], reverse=True):
        print(
            f"{entry['id']:28s} {entry['risk'] or '':8s} {entry['roots']:4d} "
            f"{entry['items']:6d} {human(entry['bytes']):>10s} {entry['files']:8d}  "
            f"{entry['relativePath'] or '(锚点)'}"
        )

    totals = result["totals"]
    print(
        f"\n{ totals['rules']} 条规则共命中 {totals['items']} 条目标（去重 {totals['distinctItems']}），"
        f"{human(totals['bytes'])}"
    )
    if totals["emptyRules"]:
        print(f"没有命中任何条目的规则: {', '.join(totals['emptyRules'])}")

    print(f"\n各顶层目录的规则覆盖面（按体积，前 {limit} 项）")
    print(f"{'体积':>10s} {'条目':>6s}  目录 / 覆盖规则")
    print("-" * 60)
    rows = [row for row in result["topLevel"] if row["bytes"] > 0][:limit]
    for row in rows:
        covered = ", ".join(row["rules"]) if row["rules"] else "—— 无规则"
        if row["rules"] and row["items"] == 0:
            covered += " (规则存在，今天没有命中)"
        if row.get("scanner"):
            covered += " (内置残留扫描会看这里)"
        print(f"{human(row['bytes']):>10s} {row['items']:6d}  {row['path']}  [{covered}]")


def print_group_report(report: dict, limit: int) -> None:
    """The group-container section: who answers for each container today."""
    totals = report["totals"]
    print(
        f"\nGroup Containers 归属（{report['path']}，"
        f"{sum(entry['containers'] for entry in totals.values())} 个容器）"
    )
    print(f"{'容器':>6s} {'体积':>10s}  判定")
    print("-" * 60)
    declared = totals[DECLARED]
    if declared["containers"]:
        detail = (
            f"应用授权声明的组（{report['declaredWithAName']} 个名称也能归属，"
            f"{report['declaredWithoutAName']} 个只有授权说得清）"
        )
    else:
        detail = "应用授权声明的组"
    labels = {
        DECLARED: detail,
        NAMED: "仅名称可归属（授权里查不到）",
        RESIDUE: "残留：名称与授权都指不到应用",
    }
    for kind in (DECLARED, NAMED, RESIDUE):
        entry = totals[kind]
        print(f"{entry['containers']:6d} {human(entry['bytes']):>10s}  {labels[kind]}")
    if not report["entitlementsRead"]:
        print("（未读授权：本节的 declared 一项恒为 0）")
        return
    print(
        f"\n{report['applications']} 个已安装应用声明了 {report['groupDeclarations']} 个组；"
        f"其中 {report['declaredWithoutAName']} 个容器 "
        f"({human(report['declaredWithoutANameBytes'])}) 的组没有出现在名称里——"
        "只按名称判断会把它们报成残留。"
    )
    stale = report.get("staleFilter")
    if stale and (stale["kept"] or stale["dropped"]):
        print(
            f"\n按 {stale['days']} 天过滤会变成：保留 {stale['kept']} 个 / "
            f"{human(stale['keptBytes'])}，隐藏 {stale['dropped']} 个 / "
            f"{human(stale['droppedBytes'])}"
            f"（其中 {stale['droppedFreshWithinAWeek']} 个是 7 天内写入的）"
            "——产品里没有加这个过滤，见 AGENTS 不变量 40"
        )

    ages = report.get("residueAges") or []
    if ages:
        print("\n残留容器的年龄（最近一次写入早于该天数，按容器数/体积）")
        for entry in ages:
            print(
                f"  ≥ {entry['days']:3d} 天  {entry['containers']:4d} 个  "
                f"{human(entry['bytes']):>10s}"
            )
        if report["residueWithoutFiles"]:
            print(
                f"  另有 {report['residueWithoutFiles']} 个容器里没有任何文件，"
                "没有年龄可言（不按天数折算成「刚刚写入」）"
            )

    residue = report["residue"][:limit]
    if residue:
        print(f"\n最大的残留容器（前 {len(residue)} 项）")
        for row in residue:
            age = "—" if row["ageDays"] is None else f"{row['ageDays']}天"
            print(f"{human(row['bytes']):>10s} {row['files']:8d} {age:>8s}  {row['name']}")


def self_check() -> int:
    """Assert the audit's arithmetic on a fixture of known size.

    A report nobody checks is a report that drifts: the engines changed their
    size accounting once already, from `st_size` to `st_blocks`, and the audit
    would have gone on measuring the wrong one.
    """
    failures: list[str] = []
    with tempfile.TemporaryDirectory() as raw:
        home = Path(raw)
        (home / "Library" / "Caches" / "com.example.app").mkdir(parents=True)
        (home / "Library" / "Caches" / "com.example.app" / "blob.bin").write_bytes(b"x" * 8192)
        (home / "Library" / "Caches" / "CloudKit").mkdir(parents=True)
        (home / "Library" / "Caches" / "CloudKit" / "blob.bin").write_bytes(b"x" * 4096)
        (home / "Library" / "Logs" / "stale.app").mkdir(parents=True)
        old = home / "Library" / "Logs" / "stale.app" / "old.log"
        old.write_bytes(b"x" * 2048)
        _age(old, days=60)
        (home / "Library" / "Logs" / "fresh.app").mkdir(parents=True)
        (home / "Library" / "Logs" / "fresh.app" / "new.log").write_bytes(b"x" * 2048)
        (home / "Downloads").mkdir()
        installer = home / "Downloads" / "Old.dmg"
        installer.write_bytes(b"x" * 4096)
        _age(installer, days=60)
        (home / "Downloads" / "New.dmg").write_bytes(b"x" * 4096)
        (home / "Library" / "Application Support" / "com.example.app" / "Cache").mkdir(parents=True)
        (home / "Library" / "Application Support" / "com.example.app" / "Cache" / "a.bin").write_bytes(
            b"x" * 1024
        )
        (home / "Library" / "Application Support" / "com.example.app" / "State").mkdir(parents=True)
        (home / "Library" / "Application Support" / "com.example.app" / "State" / "b.bin").write_bytes(
            b"x" * 1024
        )

        result = audit(home, [], DEFAULT_STALE_DAYS, True, session=None)
        by_id = {entry["id"]: entry for entry in result["rules"]}

        def expect(condition: bool, message: str) -> None:
            if not condition:
                failures.append(message)

        expect(
            by_id["user-cache"]["items"] == 1,
            f"user-cache should find exactly `com.example.app` (found {by_id['user-cache']['items']}); "
            "`CloudKit` is excluded by the rule",
        )
        expect(
            by_id["user-cache"]["bytes"] == 8192,
            f"user-cache should report 8192 allocated bytes (got {by_id['user-cache']['bytes']})",
        )
        expect(
            by_id["user-logs"]["items"] == 1,
            "user-logs should offer only the directory whose every file is stale",
        )
        expect(
            by_id["download-installers"]["items"] == 1,
            "download-installers should offer only the installer past 30 days",
        )
        expect(
            by_id["app-support-caches"]["items"] == 1,
            "app-support-caches should offer `Cache` and not `State`",
        )
        support = next(
            (
                row
                for row in result["topLevel"]
                if row["path"] == str(home / "Library" / "Application Support")
            ),
            None,
        )
        expect(support is not None, "the report should include ~/Library/Application Support")
        if support is not None:
            expect(
                support["rules"] == ["app-support-caches"],
                f"Application Support is reached by app-support-caches only (got {support['rules']})",
            )
            expect(support["items"] == 1, "and by exactly one item")

        # The sweep is a second way of reading the same measurements, so it has to
        # agree with the audit at the default age and be monotone in the age.
        sweep = age_sweep(home, [], [0, 100_000], True, None)
        expect(
            sweep["totals"][0]["items"] >= sweep["totals"][100_000]["items"],
            "a longer age never offers more",
        )
        expect(
            sweep["totals"][0]["items"] > 0,
            "an age of zero offers everything the rules can see",
        )
        expect(
            sweep["totals"][0]["items"] >= result["totals"]["items"],
            "and at least as much as the audit's default threshold",
        )

        # Group containers: the name readings have to agree with the Swift side,
        # and the classifier has to put each container in exactly one bucket.
        expect(
            bundle_name_readings("6N38VWS5BX.ru.keepcoder.Telegram")
            == ["ru.keepcoder.telegram", "6n38vws5bx.ru.keepcoder.telegram"],
            "a team-prefixed container has two readings, most specific first",
        )
        expect(
            bundle_name_readings("group.com.vendor.notes")
            == ["com.vendor.notes", "group.com.vendor.notes"],
            "and so does an app group's `group.` spelling",
        )
        expect(
            bundle_name_readings("notes") == ["notes"],
            "a plain folder name has one reading, never a truncated one",
        )

        containers = home / GROUP_CONTAINER_ROOT
        (containers / "group.com.vendor.notes").mkdir(parents=True)
        (containers / "group.com.vendor.notes" / "store.db").write_bytes(b"x" * 4096)
        (containers / "6N38VWS5BX.ru.keepcoder.Telegram").mkdir(parents=True)
        (containers / "6N38VWS5BX.ru.keepcoder.Telegram" / "cache.bin").write_bytes(b"x" * 2048)
        (containers / "com.vendor.gone").mkdir(parents=True)
        (containers / "com.vendor.gone" / "old.bin").write_bytes(b"x" * 1024)

        labels = {
            "group.com.vendor.notes": DECLARED,
            "6N38VWS5BX.ru.keepcoder.Telegram": NAMED,
            "com.vendor.gone": RESIDUE,
        }
        for name, expected in labels.items():
            expect(
                classify_group_container(
                    name,
                    {"group.com.vendor.notes": ["Notes"]},
                    {"ru.keepcoder.telegram"},
                )
                == expected,
                f"{name} should be classified {expected}",
            )

        report = group_container_report(
            home,
            declarations={"group.com.vendor.notes": ["Notes"]},
            installed={"ru.keepcoder.telegram"},
            use_entitlements=False,
        )
        expect(
            report["totals"][DECLARED]["containers"] == 1,
            "one container is declared by an application group",
        )
        expect(
            report["totals"][DECLARED]["bytes"] == 4096,
            f"and it is measured whole (got {report['totals'][DECLARED]['bytes']})",
        )
        expect(
            report["totals"][NAMED]["containers"] == 1 and report["totals"][RESIDUE]["containers"] == 1,
            "the other two split between named and residue",
        )
        expect(
            report["declaredWithoutAName"] == 1,
            "a declared container no name points at is the one the entitlement read saves",
        )
        expect(
            report["declaredWithAName"] == 0,
            "the declared bucket splits into the names that do and do not resolve",
        )
        expect(
            report["residue"][0]["name"] == "com.vendor.gone",
            "the residue list is the containers neither answer claims",
        )

        # Age: the ladder reads one measurement per container, and a container
        # that holds no file at all has no age rather than an age of zero.
        _age(containers / "com.vendor.gone" / "old.bin", days=100)
        (containers / "com.vendor.empty").mkdir(parents=True)
        aged = group_container_report(
            home,
            declarations={"group.com.vendor.notes": ["Notes"]},
            installed={"ru.keepcoder.telegram"},
            use_entitlements=False,
        )
        gone = next(row for row in aged["residue"] if row["name"] == "com.vendor.gone")
        expect(gone["ageDays"] >= 100, f"the container's age is its oldest file ({gone['ageDays']})")
        empty = next(row for row in aged["residue"] if row["name"] == "com.vendor.empty")
        expect(empty["ageDays"] is None, "a container with no files has no age")
        ladder = {entry["days"]: entry["containers"] for entry in aged["residueAges"]}
        expect(ladder[90] == 1, f"one residue container is older than 90 days (got {ladder[90]})")
        expect(ladder[180] == 0, "and none is older than 180 days")
        expect(aged["residueWithoutFiles"] == 1, "the empty container is counted separately")

        # The private-container section answers the same two questions with one
        # name comparison, and its ladder has to agree with the fixture's ages.
        (home / "Library/Containers/com.installed.app/Data").mkdir(parents=True)
        (home / "Library/Containers/com.installed.app/Data/blob.bin").write_bytes(b"x" * 2048)
        (home / "Library/Containers/com.gone.app/Data").mkdir(parents=True)
        private_blob = home / "Library/Containers/com.gone.app/Data/blob.bin"
        private_blob.write_bytes(b"x" * 4096)
        _age(private_blob, days=45)

        private = private_container_report(
            home, installed={"com.installed.app"}, stale_days=30
        )
        expect(
            private["totals"][NAMED]["containers"] == 1,
            "the container of an installed application is not residue",
        )
        expect(
            private["totals"][RESIDUE]["containers"] == 1,
            "the container of a gone application is",
        )
        expect(
            private["staleFilter"]["kept"] == 1 and private["staleFilter"]["dropped"] == 0,
            "a 30-day filter keeps a container last written 45 days ago",
        )
        expect(
            private["staleFilter"]["droppedFreshWithinAWeek"] == 0,
            "nothing was hidden, so nothing recent was hidden either",
        )
        expect(
            aged["staleFilter"]["kept"] == 1 and aged["staleFilter"]["dropped"] == 0,
            "a 30-day filter keeps the only container that holds files",
        )
        strict = group_container_report(
            home,
            declarations={"group.com.vendor.notes": ["Notes"]},
            installed={"ru.keepcoder.telegram"},
            use_entitlements=False,
            stale_days=200,
        )
        expect(
            strict["staleFilter"]["kept"] == 0 and strict["staleFilter"]["dropped"] == 1,
            "and a 200-day filter would hide it, which is the cost being measured",
        )
        expect(
            strict["staleFilter"]["droppedFreshWithinAWeek"] == 0,
            "the hidden container is not one that was written to recently",
        )

    if failures:
        for failure in failures:
            print(f"coverage self-check failed: {failure}")
        return 1
    print("coverage self-check passed: the audit counts what the engines count")
    return 0


def _age(path: Path, days: int) -> None:
    when = time.time() - days * 86_400
    os.utime(path, (when, when))


def main() -> int:
    parser = argparse.ArgumentParser(description="Audit how much the rule table reaches.")
    parser.add_argument("--home", type=Path, default=Path.home())
    parser.add_argument(
        "--grant",
        type=Path,
        action="append",
        default=[],
        help="an authorised root, scanned by rules anchored at `authorized`/`externalVolume`",
    )
    parser.add_argument("--stale-days", type=int, default=DEFAULT_STALE_DAYS)
    parser.add_argument("--exclude-hidden", action="store_true")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--limit", type=int, default=25)
    parser.add_argument(
        "--session-root",
        type=Path,
        default=None,
        help="the per-user temporary root for `userTemp` rules (default: from $TMPDIR)",
    )
    parser.add_argument(
        "--include-system",
        action="store_true",
        help="also measure /Library; off by default because it is mostly not cleanable",
    )
    parser.add_argument(
        "--age-sweep",
        default="",
        help="comma-separated ages in days to compare, e.g. 7,30,90,180",
    )
    parser.add_argument(
        "--skip-group-containers",
        action="store_true",
        help="skip the group-container section (it reads every installed signature)",
    )
    parser.add_argument(
        "--no-entitlements",
        action="store_true",
        help="classify group containers by name only, as the engines do",
    )
    parser.add_argument(
        "--only-group-containers",
        action="store_true",
        help="print only the group-container section (skips measuring the rule table)",
    )
    parser.add_argument(
        "--only-containers",
        action="store_true",
        help="print both container sections: private and shared",
    )
    parser.add_argument("--self-check", action="store_true")
    arguments = parser.parse_args()

    if arguments.self_check:
        return self_check()

    if not RULES_JSON.exists() and not arguments.only_group_containers:
        print(f"{RULES_JSON} is missing; run Scripts/generate-rules.py", file=sys.stderr)
        return 1

    if arguments.only_containers:
        private = private_container_report(
            arguments.home.resolve(),
            include_system=True,
            stale_days=max(arguments.stale_days, 0),
        )
        shared = group_container_report(
            arguments.home.resolve(),
            include_system=True,
            use_entitlements=not arguments.no_entitlements,
            stale_days=max(arguments.stale_days, 0),
        )
        if arguments.json:
            print(
                json.dumps(
                    {"privateContainers": private, "groupContainers": shared},
                    indent=2,
                    ensure_ascii=False,
                )
            )
        else:
            print_private_report(private, max(arguments.limit, 1))
            print_group_report(shared, max(arguments.limit, 1))
        return 0

    if arguments.only_group_containers:
        containers = group_container_report(
            arguments.home.resolve(),
            include_system=True,
            use_entitlements=not arguments.no_entitlements,
            stale_days=max(arguments.stale_days, 0),
        )
        if arguments.json:
            print(json.dumps({"groupContainers": containers}, indent=2, ensure_ascii=False))
        else:
            print_group_report(containers, max(arguments.limit, 1))
        return 0

    if arguments.age_sweep:
        try:
            ages = sorted({int(part) for part in arguments.age_sweep.split(",") if part.strip()})
        except ValueError:
            print("--age-sweep wants whole numbers of days, e.g. 7,30,90,180", file=sys.stderr)
            return 1
        if not ages or ages[0] < 0:
            print("--age-sweep needs at least one non-negative age", file=sys.stderr)
            return 1
        sweep = age_sweep(
            arguments.home.resolve(),
            [grant.resolve() for grant in arguments.grant],
            ages,
            not arguments.exclude_hidden,
            arguments.session_root or session_root(),
        )
        if arguments.json:
            print(json.dumps(sweep, indent=2, ensure_ascii=False))
        else:
            print_sweep(sweep)
        return 0

    result = audit(
        arguments.home.resolve(),
        [grant.resolve() for grant in arguments.grant],
        max(arguments.stale_days, 0),
        not arguments.exclude_hidden,
        include_system=arguments.include_system,
        session=arguments.session_root or session_root(),
    )
    containers = None
    # The sweep is its own report; the last section belongs to the full audit.
    private_containers = None
    if not arguments.skip_group_containers:
        private_containers = private_container_report(
            arguments.home.resolve(),
            include_system=True,
            stale_days=max(arguments.stale_days, 0),
        )
        containers = group_container_report(
            arguments.home.resolve(),
            stale_days=max(arguments.stale_days, 0),
            # System applications are always included here, whatever
            # `--include-system` says: both engines resolve installed applications
            # over `/System/Applications` too, so an Apple group declared on the
            # system volume is a container the scan sees as live. Excluding them
            # would understate exactly the gap this section measures.
            include_system=True,
            use_entitlements=not arguments.no_entitlements,
        )
    if arguments.json:
        if containers is not None:
            result["groupContainers"] = containers
        if private_containers is not None:
            result["privateContainers"] = private_containers
        print(json.dumps(result, indent=2, ensure_ascii=False))
    else:
        print_report(result, max(arguments.limit, 1))
        if private_containers is not None:
            print_private_report(private_containers, max(arguments.limit, 1))
        if containers is not None:
            print_group_report(containers, max(arguments.limit, 1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
