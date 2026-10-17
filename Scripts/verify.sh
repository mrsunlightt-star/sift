#!/usr/bin/env bash
#
# Runs every check this repository has, in dependency order.
#
# The last line of output is the verdict. A non-zero exit means something broke.
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

step "1/8  Generated sources are current"
# The Swift side of two shared tables is generated. A stale copy is a silent
# divergence — localisable text, or the set of paths the two engines protect —
# so it is checked before anything is built from it.
run bash -c "python3 Scripts/generate-strings.py --check"
run bash -c "python3 Scripts/generate-protection.py --check"

step "2/8  Rust: formatting and lints"
run bash -c "cd RustCore && cargo fmt --all -- --check"
run bash -c "cd RustCore && cargo clippy --all-targets -- -D warnings"

step "3/8  Rust: unit and contract tests"
run bash -c "cd RustCore && cargo test --workspace"

step "4/8  Rust: benchmarks compile"
run bash -c "cd RustCore && cargo bench -p sift-scanner-core --no-run"

if [[ "${QUICK}" == "0" ]]; then
  step "5/8  Rust: benchmark smoke run"
  run bash -c "cd RustCore && cargo bench -p sift-scanner-core --bench scan_stages -- --warm-up-time 0.3 --measurement-time 1 index_insert"
else
  step "5/8  Rust: benchmark smoke run (skipped)"
fi

step "6/8  Swift: build (Rust core linked)"
"${REPO_ROOT}/Scripts/build-rust-core.sh" >/dev/null
run swift build

step "7/8  Swift: self-test and XCTest suites"
run bash -c "cd '${REPO_ROOT}' && swift run SiftSelfTest"
run bash -c "cd '${REPO_ROOT}' && ./Scripts/run-tests.sh"

step "8/8  App bundle"
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
