#!/usr/bin/env bash
#
# Makes the Rust scanner core visible to SwiftPM and to the linker.
#
# SwiftPM resolves the `SiftScanner` system-library target (module map and C
# header) without help. Linking the Rust archive is a separate problem: SwiftPM
# cannot attach a static library to a system-library target unless pkg-config
# reports it, so this script exports the link flags instead.
#
# Usage:
#   source Scripts/swift-env.sh        # prepare this shell
#   sift_swift build                   # SwiftPM with the Rust archive linked
#   Scripts/swift-env.sh --build       # prepare and build in one step
#
# Without this, `swift build` still produces a complete app: `Core` guards every
# Rust call site with `#if canImport(SiftScanner)` and falls back to the Swift
# scanner core. Only the engine performing scans changes.

set -euo pipefail

# Resolve the repository root when sourced by bash or zsh: `BASH_SOURCE` is a
# bash array, zsh provides `%x`.
if [[ -n "${BASH_VERSION:-}" ]]; then
  SCRIPT_PATH="${BASH_SOURCE[0]}"
elif [[ -n "${ZSH_VERSION:-}" ]]; then
  SCRIPT_PATH="${(%):-%x}"
else
  SCRIPT_PATH="$0"
fi
REPO_ROOT="$(cd "$(dirname "${SCRIPT_PATH}")/.." && pwd)"

RUSTC_TARGET="$(rustc -vV | awk '/host:/{print $2}')"
RUST_LIB="${REPO_ROOT}/RustCore/target/${RUSTC_TARGET}/release/libsift_ffi.a"

# 1. Build the Rust library when it is missing.
if [[ ! -f "${RUST_LIB}" ]]; then
  echo "==> Building the Rust scanner core (release, ${RUSTC_TARGET})"
  (cd "${REPO_ROOT}/RustCore" && cargo build --release -p sift-ffi --target "${RUSTC_TARGET}")
fi

# 2. Export the archive path and the SwiftPM flags that pull it in.
#
#    `-force_load` rather than `-l`: every FFI symbol must be present even when
#    the app only references a few of them.
export SIFT_RUST_LIB="${RUST_LIB}"
export SIFT_RUST_TARGET="${RUSTC_TARGET}"
export SIFT_SWIFT_FLAGS=(-Xlinker -force_load -Xlinker "${RUST_LIB}")
export PKG_CONFIG_PATH="${REPO_ROOT}/Bridge:${PKG_CONFIG_PATH:-}"

# 3. A convenience wrapper so callers do not have to remember the flag shape.
sift_swift() {
  swift "$@" "${SIFT_SWIFT_FLAGS[@]}"
}

echo "==> SiftScanner is ready"
echo "    library: ${RUST_LIB}"
echo "    helper:  sift_swift <swift arguments>"

if [[ "${1:-}" == "--build" ]]; then
  cd "${REPO_ROOT}"
  swift build "${SIFT_SWIFT_FLAGS[@]}"
fi
