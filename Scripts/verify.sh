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

step "1/7  Rust: formatting and lints"
run bash -c "cd RustCore && cargo fmt --all -- --check"
run bash -c "cd RustCore && cargo clippy --all-targets -- -D warnings"

step "2/7  Rust: unit and contract tests"
run bash -c "cd RustCore && cargo test --workspace"

step "3/7  Rust: benchmarks compile"
run bash -c "cd RustCore && cargo bench -p sift-scanner-core --no-run"

if [[ "${QUICK}" == "0" ]]; then
  step "4/7  Rust: benchmark smoke run"
  run bash -c "cd RustCore && cargo bench -p sift-scanner-core --bench scan_stages -- --warm-up-time 0.3 --measurement-time 1 index_insert"
else
  step "4/7  Rust: benchmark smoke run (skipped)"
fi

step "5/7  Swift: build (Rust core linked)"
"${REPO_ROOT}/Scripts/build-rust-core.sh" >/dev/null
run swift build

step "6/7  Swift: self-test and XCTest suites"
run bash -c "cd '${REPO_ROOT}' && swift run SiftSelfTest"
run bash -c "cd '${REPO_ROOT}' && ./Scripts/run-tests.sh"

step "7/7  App bundle"
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
