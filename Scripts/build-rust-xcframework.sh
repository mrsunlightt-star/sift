#!/usr/bin/env bash
#
# Builds the Sift scanner core for both macOS architectures and packages it as an
# XCFramework that Xcode can embed.
#
# The specification requires the released binary to be universal (Apple Silicon
# plus Intel), so this script refuses to produce a "universal" framework that is
# missing an architecture: it fails loudly instead of shipping a silent
# regression.
#
# Usage:
#   ./Scripts/build-rust-xcframework.sh [--debug] [--no-tests] [--skip-xcframework]
#
# Environment:
#   SIFT_SKIP_X86=1   skip the Intel slice (development on Apple Silicon only)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUST_CORE="${REPO_ROOT}/RustCore"
BRIDGE_DIR="${REPO_ROOT}/Bridge"
INCLUDE_DIR="${BRIDGE_DIR}/include"
HEADER="${INCLUDE_DIR}/sift_scanner.h"
XCFRAMEWORK="${BRIDGE_DIR}/SiftScanner.xcframework"
LIB_NAME="libsift_ffi.a"

PROFILE="release"
RUN_TESTS=1
BUILD_XCFRAMEWORK=1

while [[ $# -gt 0 ]]; do
  case "$1" in
  --debug) PROFILE="debug" ;;
  --no-tests) RUN_TESTS=0 ;;
  --skip-xcframework) BUILD_XCFRAMEWORK=0 ;;
  -h | --help)
    sed -n '2,20p' "${BASH_SOURCE[0]}"
    exit 0
    ;;
  *)
    echo "unknown argument: $1" >&2
    exit 2
    ;;
  esac
  shift
done

if [[ "${PROFILE}" == "release" ]]; then
  CARGO_FLAGS=(--release)
else
  CARGO_FLAGS=()
fi

echo "==> Checking the toolchain pinned by rust-toolchain.toml"
(cd "${RUST_CORE}" && rustc --version && cargo --version)

# The toolchain file pins the architectures this project ships.
REQUIRED_TARGETS=("aarch64-apple-darwin")
if [[ "${SIFT_SKIP_X86:-0}" != "1" ]]; then
  REQUIRED_TARGETS+=("x86_64-apple-darwin")
fi

INSTALLED_TARGETS="$(rustup target list --installed)"
for target in "${REQUIRED_TARGETS[@]}"; do
  if ! grep -qx "${target}" <<<"${INSTALLED_TARGETS}"; then
    echo "==> Installing missing Rust target ${target}"
    rustup target add "${target}"
  fi
done

if [[ "${RUN_TESTS}" == "1" ]]; then
  echo "==> Running the Rust test suite (including the FFI contract tests)"
  (cd "${RUST_CORE}" && cargo test --workspace)
fi

if [[ ! -f "${HEADER}" ]]; then
  echo "error: the C header is missing at ${HEADER}" >&2
  echo "       the FFI contract tests verify the header against the Rust structs," >&2
  echo "       so the header is a checked-in source file, not a build artifact" >&2
  exit 1
fi

echo "==> Building ${LIB_NAME} for: ${REQUIRED_TARGETS[*]} (${PROFILE})"
for target in "${REQUIRED_TARGETS[@]}"; do
  (cd "${RUST_CORE}" && cargo build --package sift-ffi --target "${target}" "${CARGO_FLAGS[@]}")
done

if [[ "${BUILD_XCFRAMEWORK}" != "1" ]]; then
  echo "==> Skipping the XCFramework step as requested"
  exit 0
fi

echo "==> Creating a universal static library"
UNIVERSAL_DIR="${BRIDGE_DIR}/macos-universal"
rm -rf "${UNIVERSAL_DIR}"
mkdir -p "${UNIVERSAL_DIR}"

SLICES=()
for target in "${REQUIRED_TARGETS[@]}"; do
  SLICES+=("${RUST_CORE}/target/${target}/${PROFILE}/${LIB_NAME}")
done
for slice in "${SLICES[@]}"; do
  if [[ ! -f "${slice}" ]]; then
    echo "error: expected library is missing: ${slice}" >&2
    exit 1
  fi
done

if [[ ${#SLICES[@]} -gt 1 ]]; then
  lipo -create "${SLICES[@]}" -output "${UNIVERSAL_DIR}/${LIB_NAME}"
else
  cp "${SLICES[0]}" "${UNIVERSAL_DIR}/${LIB_NAME}"
fi

echo "==> Verifying the slices inside the universal library"
lipo -info "${UNIVERSAL_DIR}/${LIB_NAME}"

# A universal build must actually contain both architectures. Without this check
# a failed cross-build would still produce a working (single-architecture)
# framework, and the omission would only surface on a user's Intel Mac.
if [[ ${#SLICES[@]} -gt 1 ]]; then
  ARCH_INFO="$(lipo -info "${UNIVERSAL_DIR}/${LIB_NAME}")"
  for arch in arm64 x86_64; do
    if [[ "${ARCH_INFO}" != *"${arch}"* ]]; then
      echo "error: the universal library is missing the ${arch} slice" >&2
      echo "       ${ARCH_INFO}" >&2
      exit 1
    fi
  done
fi

echo "==> Assembling ${XCFRAMEWORK}"
rm -rf "${XCFRAMEWORK}"
xcodebuild -create-xcframework \
  -library "${UNIVERSAL_DIR}/${LIB_NAME}" \
  -headers "${INCLUDE_DIR}" \
  -output "${XCFRAMEWORK}"

echo "==> Done"
echo "    header:      ${HEADER}"
echo "    library:     ${UNIVERSAL_DIR}/${LIB_NAME}"
echo "    xcframework: ${XCFRAMEWORK}"
