#!/usr/bin/env bash
#
# Builds the Rust scanner core for this machine and places the archive where both
# build systems expect it:
#
#     Bridge/macos-universal/libsift_ffi.a
#
# Run once after cloning, and again after changing anything under `RustCore/`.
# `Scripts/bootstrap.sh` calls it and adds the rest of the setup.
#
# Pass `--universal` to build both architectures (needs the x86_64 Rust target);
# the result is the same path but contains both slices.

set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
REPO_ROOT="$(cd "$(dirname "${SCRIPT_PATH}")/.." && pwd)"
cd "${REPO_ROOT}"

UNIVERSAL=0
[[ "${1:-}" == "--universal" ]] && UNIVERSAL=1

OUTPUT_DIR="${REPO_ROOT}/Bridge/macos-universal"
OUTPUT="${OUTPUT_DIR}/libsift_ffi.a"
mkdir -p "${OUTPUT_DIR}"

build_for() {
  local target="$1"
  echo "==> cargo build --release (${target})" >&2
  (cd RustCore && cargo build --release -p sift-ffi --target "${target}" >&2)
  echo "RustCore/target/${target}/release/libsift_ffi.a"
}

ARCH="$(uname -m)"
case "${ARCH}" in
arm64) HOST_TARGET="aarch64-apple-darwin" ;;
x86_64) HOST_TARGET="x86_64-apple-darwin" ;;
*)
  echo "error: unsupported architecture ${ARCH}" >&2
  exit 1
  ;;
esac

HOST_LIB="$(build_for "${HOST_TARGET}")"

# What the archive was before this run, so a change can be announced to SwiftPM.
BEFORE=""
[[ -f "${OUTPUT}" ]] && BEFORE="$(shasum -a 256 "${OUTPUT}" | awk '{ print $1 }')"

if [[ "${UNIVERSAL}" == "1" ]]; then
  OTHER_TARGET="x86_64-apple-darwin"
  [[ "${HOST_TARGET}" == "x86_64-apple-darwin" ]] && OTHER_TARGET="aarch64-apple-darwin"
  if ! rustup target list --installed | grep -qx "${OTHER_TARGET}"; then
    echo "==> Installing ${OTHER_TARGET}" >&2
    rustup target add "${OTHER_TARGET}" >&2
  fi
  OTHER_LIB="$(build_for "${OTHER_TARGET}")"
  lipo -create "${HOST_LIB}" "${OTHER_LIB}" -output "${OUTPUT}"
else
  cp "${HOST_LIB}" "${OUTPUT}"
fi

# SwiftPM cannot see this archive as a build input: it reaches the linker through
# `-force_load` in the manifest's unsafe flags, which the build graph does not
# track. A rebuilt archive therefore left every already-linked product alone and
# the suite kept running the previous core without saying so — which is a silent
# wrong answer in exactly the place it matters most, because `Scripts/verify.sh`
# builds this archive and then runs the tests. Touching the bridge source makes
# the modules that import it recompile. Xcode's build system has the same blind
# spot and is cured by the same touch.
#
# The touch alone is not enough, and this is measured rather than assumed: with
# the archive changed and the source merely touched, `swift build --build-tests`
# reported "Compiling Core RustScannerEngine.swift … Build complete" and never
# ran its link step, because the recompiled object files came out byte-identical
# and the linker output therefore looked up to date. The test bundle kept the
# previous core, and a regression in the Rust half passed the suite. Removing the
# linked products makes the link mandatory. DerivedData from an Xcode build is a
# separate build directory and gets the touch above, not this sweep.
AFTER="$(shasum -a 256 "${OUTPUT}" | awk '{ print $1 }')"
if [[ "${BEFORE}" != "${AFTER}" ]]; then
  touch "${REPO_ROOT}/Core/RustBridge/RustScannerEngine.swift"
  if [[ -d "${REPO_ROOT}/.build" ]]; then
    find "${REPO_ROOT}/.build" -maxdepth 5 \
      \( -name "Sift" -o -name "SiftSelfTest" -o -name "SiftPackageTests.xctest" \) \
      -exec rm -rf {} + 2>/dev/null || true
  fi
fi

echo "==> ${OUTPUT}" >&2
lipo -info "${OUTPUT}"
