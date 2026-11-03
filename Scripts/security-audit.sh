#!/usr/bin/env bash
#
# Runs the two security checks RELEASE.md promises: a dependency audit of the
# Rust workspace, and an AddressSanitizer run of the FFI crate's tests.
#
# Usage:
#
#     Scripts/security-audit.sh              # both checks
#     Scripts/security-audit.sh audit        # cargo audit inside RustCore/
#     Scripts/security-audit.sh sanitize     # cargo test -p sift-ffi under ASan
#     Scripts/security-audit.sh --offline    # both, without touching the network
#
# `sift-ffi` is the only crate with `unsafe`, and the app ships without a
# sandbox, so a memory error there is user-level read/write over the whole
# disk rather than an escape from a container. That is why these two checks are
# a release condition (RELEASE.md §5.1) and why CI runs them on every push.
#
# Neither check may pass by not happening: a missing `cargo-audit`, an advisory
# database that cannot be fetched, and a test binary that was built without the
# sanitizer runtime are each reported as failures. A check that could not run is
# not a pass.
#
# The sanitizer build uses its own target directory (`RustCore/target/asan`).
# `Bridge/macos-universal/libsift_ffi.a` — the archive both SwiftPM and Xcode
# force-load — is produced from `RustCore/target/<triple>/release` by
# `Scripts/build-rust-core.sh`, so a sanitized build must never land there.

set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
REPO_ROOT="$(cd "$(dirname "${SCRIPT_PATH}")/.." && pwd)"
cd "${REPO_ROOT}"

usage() {
  cat <<'EOF'
Usage: Scripts/security-audit.sh [audit|sanitize] [--offline]

  audit      cargo audit inside RustCore/ (dependency CVEs)
  sanitize   cargo test -p sift-ffi under AddressSanitizer
  --offline  do not fetch the advisory database or install cargo-audit

With neither subcommand, both checks run.
EOF
}

OFFLINE=0
COMMAND=""
for argument in "$@"; do
  case "${argument}" in
    audit|sanitize) COMMAND="${argument}" ;;
    --offline) OFFLINE=1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "error: unknown argument '${argument}'" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# `cargo audit` reads the advisory database from a git clone under
# `~/.cargo/advisory-db`; `--no-fetch` asks it to use that clone as it stands.
# When the clone is missing or stale the audit fails, which is the honest
# answer: an audit against no database has examined nothing.
run_audit() {
  local audit_args=()

  echo "==> cargo audit (RustCore/)"
  if ! command -v cargo-audit >/dev/null 2>&1; then
    if [[ "${OFFLINE}" == "1" ]]; then
      echo "error: cargo-audit is not installed, and --offline forbids installing it." >&2
      echo "       Install it with: cargo install cargo-audit --locked" >&2
      return 1
    fi
    echo "==> cargo-audit is not installed; installing it"
    if ! cargo install cargo-audit --locked; then
      echo "error: cargo install cargo-audit --locked failed, so no audit ran." >&2
      return 1
    fi
    if ! command -v cargo-audit >/dev/null 2>&1; then
      echo "error: cargo-audit is still not on PATH after installing it." >&2
      echo "       Its default location is \${CARGO_HOME:-~/.cargo}/bin." >&2
      return 1
    fi
  fi

  if [[ "${OFFLINE}" == "1" ]]; then
    audit_args+=(--no-fetch)
  fi

  if ! (cd RustCore && cargo audit ${audit_args[@]+"${audit_args[@]}"}); then
    echo "error: cargo audit failed; a failing audit fails the release and the run." >&2
    return 1
  fi
}

# The sanitizer is switched on with `-Zsanitizer=address`, which is the only
# switch that instruments the generated code. `-C link-arg=-fsanitize=address`
# links nothing on this toolchain — the test binaries come out without the
# runtime, so tests pass while nothing is checked — which is why the script
# verifies the linkage afterwards instead of trusting the flag.
#
# `RustCore/.cargo/config.toml` sets `target.<triple>.rustflags`, and cargo
# prefers that list over the RUSTFLAGS environment variable, so the flags are
# passed through `--config` instead. The config's own two deployment-target
# flags are repeated here because the value replaces them: dropping either
# would link the sanitized test binaries against the SDK's default minimum
# instead of the app's macOS 13.
#
# `-Z` is nightly-only on stable, so RUSTC_BOOTSTRAP opts the pinned 1.99.1
# toolchain into it. That keeps `rust-toolchain.toml` — and the "do not upgrade
# tools" rule in AGENTS.md — intact: no second toolchain is installed for this.
run_sanitize() {
  local host
  host="$(rustc -vV | sed -n 's/^host: //p')"
  if [[ -z "${host}" ]]; then
    echo "error: rustc did not report a host triple." >&2
    return 1
  fi

  local target_dir="${REPO_ROOT}/RustCore/target/asan"
  local rustflags='["-C","link-arg=-mmacosx-version-min=13.0","-C","link-args=-mmacosx-version-min=13.0","-Zsanitizer=address"]'

  local cargo_args=(test -p sift-ffi --target "${host}" --config "target.${host}.rustflags=${rustflags}")
  if [[ "${OFFLINE}" == "1" ]]; then
    cargo_args+=(--offline)
  fi

  # `--target` is not decoration: without it, cargo also applies the target's
  # rustflags to host units such as proc macros, and rustc then aborts while
  # loading an instrumented proc macro into a rustc that is not instrumented
  # ("Interceptors are not working ... loaded too late"). Naming the host triple
  # as the target keeps build scripts and proc macros out of the sanitizer.
  echo "==> cargo test -p sift-ffi with AddressSanitizer (${host})"
  echo "    target directory: RustCore/target/asan"
  if ! (
    cd RustCore
    RUSTC_BOOTSTRAP=1 \
      CARGO_TARGET_DIR="${target_dir}" \
      ASAN_OPTIONS="detect_leaks=0" \
      cargo "${cargo_args[@]}"
  ); then
    echo "error: the AddressSanitizer run failed; see the output above." >&2
    return 1
  fi

  verify_sanitizer_linked "${target_dir}/${host}/debug/deps"
}

# The proof that the run above meant something: at least one test executable
# carries the sanitizer runtime. Without this check a flag that silently failed
# to apply would leave a green run over uninstrumented code.
verify_sanitizer_linked() {
  local deps_dir="$1"
  local binary

  for binary in "${deps_dir}"/sift_ffi-*; do
    [[ -f "${binary}" && -x "${binary}" ]] || continue
    if otool -L "${binary}" 2>/dev/null | grep -qi 'asan.*\.dylib'; then
      echo "  ✓ the test binary links the AddressSanitizer runtime"
      return 0
    fi
  done

  echo "error: no sift-ffi test binary in ${deps_dir} links the AddressSanitizer runtime." >&2
  echo "       The tests ran without instrumentation, so the run proves nothing." >&2
  return 1
}

FAILED=0

if [[ -z "${COMMAND}" || "${COMMAND}" == "audit" ]]; then
  run_audit || FAILED=1
fi

if [[ -z "${COMMAND}" || "${COMMAND}" == "sanitize" ]]; then
  run_sanitize || FAILED=1
fi

if [[ "${FAILED}" != "0" ]]; then
  echo "security-audit: at least one check failed" >&2
  exit 1
fi

echo "security-audit: every check passed"
