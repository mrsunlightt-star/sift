#!/usr/bin/env python3
"""Prepares the test sources for the minimal XCTest runner.

Two things happen, both mechanical:

  * every `func test…()` gains `throws`, because the assertions and `XCTUnwrap`
    throw;
  * a registry of test classes and methods is generated, so the runner can await
    each test on the main actor without reaching it through the Objective-C
    runtime.

No test body is changed. The same files run under XCTest and under
`Scripts/run-tests.sh`.

Usage: rewrite-async-tests.py <tests-dir> <out-dir>
"""

from __future__ import annotations

import pathlib
import re
import sys

CLASS_PATTERN = re.compile(r"^(?:final )?class (\w+Tests)\s*:\s*XCTestCase", re.MULTILINE)
# A test method with or without parameters. Parameters are matched so the
# registry can refuse them loudly: the shim runner calls each test with no
# argument, so a parameterised test would be silently dropped from the suite
# here while `swift test` still runs it — the two runners would disagree
# without anything noticing.
TEST_PATTERN = re.compile(r"^\s*func (test\w+)\(([^)]*)\)", re.MULTILINE)


def add_throws(text: str) -> str:
    """Marks every test method `throws`, because the assertions throw."""
    return re.sub(
        r"^(\s*)func (test\w+)\(\) \{",
        r"\1func \2() throws {",
        text,
        flags=re.MULTILINE,
    )


def rewrite(text: str) -> str:
    """Marks every test method `throws`.

    The async signature is kept: the generated runner awaits the method inside a
    main-actor closure, which is how XCTest runs it too. Nothing inside a test
    body is rewritten.
    """
    return add_throws(text)


def registry_entry(name: str, text: str) -> str:
    """Builds the registry entries for one test class.

    Each entry constructs the suite, runs its fixture hooks and awaits the method
    on the main actor. Calling through a closure rather than a selector keeps the
    tests out of the Objective-C runtime entirely.
    """
    lines = []
    for method, parameters in TEST_PATTERN.findall(text):
        if parameters.strip():
            # Detected in `main` before this point; guarded again so a caller
            # cannot skip that path and generate a broken registry silently.
            raise SystemExit(f"test {name}.{method} takes parameters; the shim runner cannot call it — split it into concrete test functions")
        lines.append(
            f'        ("{name}", "{method}", {{\n'
            f'            let instance = {name}()\n'
            f'            instance.setUp()\n'
            f'            defer {{ instance.tearDown() }}\n'
            f'            try instance.setUpWithError()\n'
            f'            var thrown: Error?\n'
            f'            do {{ try await instance.{method}() }} catch {{ thrown = error }}\n'
            f'            do {{ try instance.tearDownWithError() }} catch {{ if thrown == nil {{ thrown = error }} }}\n'
            f'            if let thrown {{ throw thrown }}\n'
            f'        }}),'
        )
    return "\n".join(lines)


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    source_dir = pathlib.Path(sys.argv[1])
    target_dir = pathlib.Path(sys.argv[2])
    target_dir.mkdir(parents=True, exist_ok=True)

    rewritten = 0
    entries: list[str] = []
    registered = 0
    declared = 0
    # `rglob` rather than `glob`: a test file in a subdirectory exists — or will
    # exist one day — and the registry silently missing it would let the shim
    # runner run fewer tests than `swift test` does. The registry count below
    # turns that into an error, so the two lists are refused together.
    sources = sorted(source_dir.rglob("*.swift"))
    for source in sources:
        text = source.read_text(encoding="utf-8")
        for method, parameters in TEST_PATTERN.findall(text):
            if parameters.strip():
                print(
                    "  ERROR: %s: test %s(%s) takes parameters; the shim runner cannot call it. "
                    "Give it concrete test functions instead of a data-driven set."
                    % (source, method, parameters.strip())
                )
                return 1
        result = rewrite(text)
        declared += len(TEST_PATTERN.findall(result))
        if result != text:
            rewritten += 1
        # The output directory is flat, so a subdirectory's name is folded into
        # the filename to keep two files with the same basename distinct.
        relative = source.relative_to(source_dir)
        (target_dir / str(relative).replace("/", "-")).write_text(result, encoding="utf-8")
        # Slice each class's body up to the next class, so a registry entry only
        # names the methods that class declares.
        matches = list(CLASS_PATTERN.finditer(result))
        for index, match in enumerate(matches):
            start = match.end()
            end = matches[index + 1].start() if index + 1 < len(matches) else len(result)
            body = result[start:end]
            registered += len(TEST_PATTERN.findall(body))
            entries.append(registry_entry(match.group(1), body))

    # An explicit registry, rather than runtime discovery: walking every class in
    # the process sends messages to AppKit internals that abort when asked.
    registry = [
        "import Foundation",
        "import XCTest",
        "",
        "/// Generated by Scripts/rewrite-async-tests.py.",
        "struct TestRegistry {",
        "    nonisolated(unsafe) static let all: [(suite: String, method: String, body: () async throws -> Void)] = [",
        *entries,
        "    ]",
        "}",
        "",
    ]
    (target_dir / "TestRegistry.swift").write_text("\n".join(registry), encoding="utf-8")
    if registered != declared:
        print(
            f"  ERROR: {declared} test methods declared but {registered} registered; "
            "a test would not run"
        )
        return 1
    print(f"  rewrote {rewritten} of {len(sources)} files, registered {registered} test methods")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
