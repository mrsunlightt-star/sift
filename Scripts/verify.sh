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

# The test suites write what they ran to a log, so the counts printed at the end
# come from the runs themselves. A number copied into a document drifts; these
# are the counts a document should quote.
LOG_DIR="${REPO_ROOT}/.build/verify"
mkdir -p "${LOG_DIR}"

run_logged() {
  local log="$1"
  shift
  if "$@" >"${log}.log" 2>&1; then
    echo "  → ok"
  else
    echo "  → FAILED"
    FAILED=1
  fi
}

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
if (cd RustCore && cargo test --workspace) >"${LOG_DIR}/rust-tests.log" 2>&1; then
  echo "  → ok"
else
  echo "  → FAILED"
  FAILED=1
fi

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
run_logged "${LOG_DIR}/self-test" bash -c "cd '${REPO_ROOT}' && swift run SiftSelfTest"
run_logged "${LOG_DIR}/swift-tests" bash -c "cd '${REPO_ROOT}' && ./Scripts/run-tests.sh"

step "8/9  Xcode: test plan (skipped without Xcode)"
# XCTest ships with Xcode, not the Command Line Tools, so this stage is the one
# that needs it. The suite above runs either way; this runs the same files under
# the real framework and then the UI tests, which nothing else can execute.
if xcode_available; then
  run xcode_run swift test --package-path "${REPO_ROOT}"

  # No `-destination` on the build. Given one, xcodebuild writes the UI test's
  # target application into the generated xctestrun as `<products>/Debug/Sift`,
  # without the `.app` suffix, so it names a path that does not exist. Without
  # one it writes `Debug/Sift.app`. The run below does need a destination,
  # because it has to choose a runner.
  run xcode_run xcodebuild build-for-testing -scheme Sift -testPlan Sift -derivedDataPath "${REPO_ROOT}/.build/xcode" -quiet

  # The architecture is named because bare `platform=macOS` matches both on an
  # Apple Silicon Mac and xcodebuild then picks one with "using the first of
  # multiple matching destinations".
  DESTINATION="platform=macOS,arch=$(uname -m)"
  TEST_PLAN_ARGS=(-scheme Sift -testPlan Sift -destination "${DESTINATION}" -derivedDataPath "${REPO_ROOT}/.build/xcode" -quiet)

  # The unit tests run on their own, with no retry: a failure here is a failure.
  run_logged "${LOG_DIR}/xcode-unit" \
    xcode_run xcodebuild test-without-building "${TEST_PLAN_ARGS[@]}" -only-testing:SiftTests

  # The UI target is separate, and retried once, because Xcode 16.4's UI-test
  # runner often fails to *start*: it looks for the target application at
  # `<products>/Debug/Sift`, a path with no `.app` on it, and the bundle is at
  # `<products>/Debug/Sift.app`. The run then fails before a single test case
  # executes. It is not caused by anything in this repository — the generated
  # xctestrun holds the right path on the failing runs, and the app bundle is
  # valid and correctly signed — and it happens locally and on GitHub's macOS 15
  # runners alike.
  #
  # So the two outcomes are told apart rather than lumped together: a *test* that
  # fails fails this stage, and a runner that never started is reported as such
  # and does not. Saying "passed" for a run that never executed would be the
  # dishonest half of this, and so would failing a build because Xcode did not
  # start a process.
  UI_STATE="did not run"
  for attempt in 1 2; do
    UI_ATTEMPT_LOG="${LOG_DIR}/xcode-ui-attempt-${attempt}.log"
    if xcode_run xcodebuild test-without-building "${TEST_PLAN_ARGS[@]}" -only-testing:SiftUITests \
      >"${UI_ATTEMPT_LOG}" 2>&1; then
      UI_STATE="ran"
      echo "  → ok (UI target, attempt ${attempt})"
      break
    fi
    if grep -q "failed on '" "${UI_ATTEMPT_LOG}"; then
      UI_STATE="failed"
      echo "  → FAILED (UI target: a test failed; see ${UI_ATTEMPT_LOG})"
      FAILED=1
      break
    fi
    if grep -q "SiftUITests encountered an error" "${UI_ATTEMPT_LOG}"; then
      echo "  … UI target attempt ${attempt}: the runner did not start, no test ran"
    else
      UI_STATE="failed"
      echo "  → FAILED (UI target: unrecognised failure; see ${UI_ATTEMPT_LOG})"
      FAILED=1
      break
    fi
  done
  if [[ "${UI_STATE}" == "did not run" ]]; then
    echo "  → note: Xcode's UI-test runner did not start on either attempt, so no UI"
    echo "    test ran. It fails the same way on the runner this project builds on,"
    echo "    before any test case executes; logs in ${LOG_DIR}."
  fi
else
  echo "  → skipped (no Xcode; Scripts/run-tests.sh covered the suite)"
fi

step "9/9  App bundle"
run bash -c "cd '${REPO_ROOT}' && ./Scripts/build-app.sh"

echo
echo "=============================================================="
echo "Test counts from this run"
echo "=============================================================="
RUST_TESTS="$(awk -F'[ ;]' '/^test result: ok/ { total += $4 } END { print total + 0 }' "${LOG_DIR}/rust-tests.log" 2>/dev/null || echo 0)"
SWIFT_TESTS="$(grep -E '^  passed: [0-9]+' "${LOG_DIR}/swift-tests.log" 2>/dev/null | tail -1 | awk '{ print $2 }' || echo 0)"
SELF_TESTS="$(grep -E '^  passed: [0-9]+' "${LOG_DIR}/self-test.log" 2>/dev/null | tail -1 | awk '{ print $2 }' || echo 0)"
echo "  Rust                    ${RUST_TESTS:-unknown}"
echo "  Swift XCTest methods    ${SWIFT_TESTS:-unknown}"
echo "  Self-test checks        ${SELF_TESTS:-unknown}"
echo "  XCUITest methods        $(grep -c '^    func test_' "${REPO_ROOT}/UITests/SiftUITests.swift" 2>/dev/null || echo unknown) (${UI_STATE:-not run})"

echo
echo "=============================================================="
if [[ "${FAILED}" == "0" ]]; then
  # The verdict says what did not run, not only what passed: "every check passed"
  # next to a UI target that never executed reads as "the UI tests passed", which
  # is the one thing this stage cannot claim on a run like that.
  if [[ "${UI_STATE:-did not run}" == "ran" ]]; then
    echo "VERDICT: every check passed"
  else
    echo "VERDICT: every check passed, but the XCUITest target did not run"
  fi
  echo "=============================================================="
else
  echo "VERDICT: at least one check failed"
  echo "=============================================================="
fi
exit "${FAILED}"
