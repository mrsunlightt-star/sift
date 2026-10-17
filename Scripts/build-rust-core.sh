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

echo "==> ${OUTPUT}" >&2
lipo -info "${OUTPUT}"
