#!/usr/bin/env python3
"""Point the UI test plan at the app bundle Xcode actually built.

`xcodebuild build-for-testing` writes the UI test's target application into the
`.xctestrun` as

    UITargetAppPath = __TESTROOT__/Debug/Sift

— a path without the `.app` extension. The bundle on disk is `Debug/Sift.app`, so
the runner reports

    The bundle identifier for Sift couldn't be read.
    No such file or directory: "…/Debug/Sift"

and exits before a single test case runs. It is not the app, the scheme or this
repository: the plist simply names the wrong path, and the UI stage then fails
with "no test ran" on every attempt instead of intermittently.

The earlier workaround (`build-for-testing` without `-destination`) no longer
holds for the Xcode on this machine — a fresh run still writes the bare path. So
the plist is corrected here, after the build and before the run: every
`UITargetAppPath` that names an existing sibling with `.app` appended is
rewritten to that neighbour. Nothing else in the file is touched, and a run that
needs no correction prints nothing.

Usage:
    python3 Scripts/fix-ui-testrun.py            # patch .build/xcode
    python3 Scripts/fix-ui-testrun.py --check    # exit 1 if any path is wrong
"""

from __future__ import annotations

import plistlib
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_PRODUCTS = REPO_ROOT / ".build" / "xcode" / "Build" / "Products"

#: The placeholder Xcode writes for the products directory of a run.
TESTROOT = "__TESTROOT__"


def expand(value: str, testroot: Path) -> Path:
    if value.startswith(TESTROOT):
        return testroot / value[len(TESTROOT) :].lstrip("/")
    return Path(value)


def corrected(value: str, testroot: Path) -> str | None:
    """The value with `.app` appended, or `None` when it needs no change.

    A path is only rewritten when the bare path it names does not exist and the
    `.app` neighbour does: guessing from the name alone would rewrite a value that
    was already right.
    """
    resolved = expand(value, testroot)
    if resolved.exists():
        return None
    app = resolved.with_name(resolved.name + ".app")
    if not app.exists():
        return None
    suffix = value[len(TESTROOT) :] if value.startswith(TESTROOT) else None
    return f"{TESTROOT}{suffix}.app" if suffix is not None else str(app)


def patch(products: Path, check_only: bool) -> int:
    plans = sorted(products.glob("*.xctestrun"))
    if not plans:
        # No build has produced a plan: the UI stage will build one first, so
        # there is nothing to correct and nothing to complain about.
        return 0

    stale = 0
    for plan in plans:
        with plan.open("rb") as handle:
            document = plistlib.load(handle)
        testroot = products
        changed: list[tuple[str, str]] = []

        for configuration in document.get("TestConfigurations", []):
            for target in configuration.get("TestTargets", []):
                value = target.get("UITargetAppPath")
                if not isinstance(value, str):
                    continue
                fixed = corrected(value, testroot)
                if fixed is None:
                    continue
                target["UITargetAppPath"] = fixed
                changed.append((value, fixed))

        if not changed:
            continue

        stale += len(changed)
        for before, after in changed:
            print(f"{plan.name}: {before} → {after}")
        if not check_only:
            with plan.open("wb") as handle:
                plistlib.dump(document, handle)

    if check_only and stale:
        print("run Scripts/fix-ui-testrun.py: the UI test plan names a path that does not exist")
        return 1
    return 0


def main() -> int:
    products = DEFAULT_PRODUCTS
    arguments = sys.argv[1:]
    if "--check" in arguments:
        return patch(products, check_only=True)
    return patch(products, check_only=False)


if __name__ == "__main__":
    raise SystemExit(main())
