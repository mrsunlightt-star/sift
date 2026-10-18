#!/usr/bin/env bash
#
# Runs every check this repository has, in dependency order.
#
# The last line of output is the verdict. A non-zero exit means something broke.
# The Xcode stage is skipped when only the Command Line Tools are installed; see
# AGENTS.md for the macOS version this machine stays on.
#
# Usage: Scripts/verify.sh [--quick]
#   --quick  skip the Rust benchmark smoke run

set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
REPO_ROOT="$(cd "$(dirname "${SCRIPT_PATH}")/.." && pwd)"
cd "${REPO_ROOT}"

QUICK=0
[[ "${1:-}" == "--quick" ]] && QUICK=1

FAILED=0

# A full Xcode can be installed without `xcode-select` having been switched to it
# (that step needs the admin password). If /Applications has one, use it for the
# Xcode stage rather than reporting "skipped" next to a working installation.
XCODE_DEVELOPER=""
if ! /usr/bin/xcodebuild -version >/dev/null 2>&1 && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  XCODE_DEVELOPER="/Applications/Xcode.app/Contents/Developer"
fi

xcode_available() {
  if [ -n "${XCODE_DEVELOPER}" ]; then
    DEVELOPER_DIR="${XCODE_DEVELOPER}" /usr/bin/xcodebuild -version >/dev/null 2>&1
  else
    /usr/bin/xcodebuild -version >/dev/null 2>&1
  fi
}

xcode_run() {
  if [ -n "${XCODE_DEVELOPER}" ]; then
    DEVELOPER_DIR="${XCODE_DEVELOPER}" "$@"
  else
    "$@"
  fi
}

step() {
  echo
  echo "=============================================================="
  echo "$1"
  echo "=============================================================="
}

run() {
  if "$@"; then
    echo "  → ok"
  else
    echo "  → FAILED"
    FAILED=1
  fi
}

step "1/9  Generated sources are current"
# The Swift side of two shared tables is generated. A stale copy is a silent
# divergence — localisable text, or the set of paths the two engines protect —
# so it is checked before anything is built from it.
run bash -c "python3 Scripts/generate-strings.py --check"
run bash -c "python3 Scripts/generate-protection.py --check"

step "2/9  Rust: formatting and lints"
run bash -c "cd RustCore && cargo fmt --all -- --check"
run bash -c "cd RustCore && cargo clippy --all-targets -- -D warnings"

step "3/9  Rust: unit and contract tests"
run bash -c "cd RustCore && cargo test --workspace"

step "4/9  Rust: benchmarks compile"
run bash -c "cd RustCore && cargo bench -p sift-scanner-core --no-run"

if [[ "${QUICK}" == "0" ]]; then
  step "5/9  Rust: benchmark smoke run"
  run bash -c "cd RustCore && cargo bench -p sift-scanner-core --bench scan_stages -- --warm-up-time 0.3 --measurement-time 1 index_insert"
else
  step "5/9  Rust: benchmark smoke run (skipped)"
fi

step "6/9  Swift: build (Rust core linked)"
"${REPO_ROOT}/Scripts/build-rust-core.sh" >/dev/null
run swift build

step "7/9  Swift: self-test and XCTest suites"
run bash -c "cd '${REPO_ROOT}' && swift run SiftSelfTest"
run bash -c "cd '${REPO_ROOT}' && ./Scripts/run-tests.sh"

step "8/9  Xcode: XCTest and test-plan build (skipped without Xcode)"
# XCTest ships with Xcode, not the Command Line Tools, so this stage is the one
# that needs it. The suite above runs either way; this runs the same files under
# the real framework and then the UI tests and the test plan, which nothing else
# can execute.
if xcode_available; then
  run xcode_run swift test --package-path "${REPO_ROOT}"
  # The UI target is compiled and signed here, which is what catches a broken
  # UI test. Running it is left to the operator: the UI-test runner on
  # Xcode 16.4 / macOS 15.7 fails intermittently to resolve the app bundle
  # ("The bundle identifier for Sift couldn't be read"), and a verification stage
  # that fails half the time decides nothing. The command is in AGENTS.md, and
  # the suite passes when the runner starts.
  run xcode_run xcodebuild build-for-testing -scheme Sift -testPlan Sift -derivedDataPath "${REPO_ROOT}/.build/xcode" -quiet
else
  echo "  → skipped (no Xcode; Scripts/run-tests.sh covered the suite)"
fi

step "9/9  App bundle"
run bash -c "cd '${REPO_ROOT}' && ./Scripts/build-app.sh"

echo
echo "=============================================================="
if [[ "${FAILED}" == "0" ]]; then
  echo "VERDICT: every check passed"
  echo "=============================================================="
else
  echo "VERDICT: at least one check failed"
  echo "=============================================================="
fi
exit "${FAILED}"
