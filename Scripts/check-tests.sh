#!/usr/bin/env bash
#
# Type-checks the XCTest suite without running it.
#
# XCTest ships with Xcode, not with the Command Line Tools, so on a
# tools-only machine `swift test` cannot run. This script compiles `Tests/`
# against the real modules and a declaration-only XCTest shim, which catches
# every kind of error except a wrong expectation. `swift test` remains the way to
# actually run the suite; see README.
#
# Usage: Scripts/check-tests.sh

set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
REPO_ROOT="$(cd "$(dirname "${SCRIPT_PATH}")/.." && pwd)"
cd "${REPO_ROOT}"

SHIM_DIR="${REPO_ROOT}/Scripts/shims"
MODULE_DIR="${REPO_ROOT}/.build/check-tests"
mkdir -p "${MODULE_DIR}"

echo "==> Building the package so the module interfaces exist"
swift build >/dev/null

BIN_PATH="$(swift build --show-bin-path)"
SDK_PATH="$(xcrun --show-sdk-path)"
TARGET_TRIPLE="$(uname -m)-apple-macosx13.0"

# Emit the XCTest shim as a Swift module, so `import XCTest` resolves in the
# suite the way it does with the real framework.
echo "==> Preparing the XCTest shim"
SHIM_MODULE_DIR="${MODULE_DIR}/shim-modules"
rm -rf "${SHIM_MODULE_DIR}"
mkdir -p "${SHIM_MODULE_DIR}"
swiftc -emit-module \
  -module-name XCTest \
  -emit-module-path "${SHIM_MODULE_DIR}/XCTest.swiftmodule" \
  -swift-version 6 \
  -target "${TARGET_TRIPLE}" \
  -sdk "${SDK_PATH}" \
  "${SHIM_DIR}/XCTest/XCTest.swift"

# The Swift module interfaces plus the Clang module map, so `@testable import Core`
# resolves without recompiling the library.
# SwiftPM writes each target's Clang module map under
# `<target>.build/include`, and the Swift module interfaces under `Modules`.
INCLUDE_FLAGS=(
  -I "${BIN_PATH}/Modules"
  -I "${BIN_PATH}"
)
for target in Core Shared; do
  map="${BIN_PATH}/${target}.build/include/module.modulemap"
  if [[ -f "${map}" ]]; then
    INCLUDE_FLAGS+=( -Xcc -fmodule-map-file="${map}" )
  fi
done

# The Rust C ABI is a system-library target, so its map lives with the sources.
INCLUDE_FLAGS+=(
  -Xcc -fmodule-map-file="${REPO_ROOT}/Bridge/module.modulemap"
  -I "${REPO_ROOT}/Bridge/include"
)

# The whole suite is checked at once: `swift test` compiles it as one module, so
# a helper declared in one file must be visible from the others.
LOG="${MODULE_DIR}/typecheck.log"
if swiftc -typecheck \
    -swift-version 6 \
    -target "${TARGET_TRIPLE}" \
    -sdk "${SDK_PATH}" \
    -I "${SHIM_MODULE_DIR}" \
    "${INCLUDE_FLAGS[@]}" \
    "${REPO_ROOT}"/Tests/*.swift 2>"${LOG}"; then
  test_count=$(grep -c "func test" "${REPO_ROOT}"/Tests/*.swift | awk -F: '{sum += $2} END {print sum}')
  echo "  ✓ ${test_count} test methods type-check"
  echo
  echo "Run the suite with 'swift test' where XCTest is available."
else
  sed -n '1,40p' "${LOG}"
  echo
  echo "The XCTest suite does not type-check. This is a compile error, not a test failure."
  exit 1
fi
