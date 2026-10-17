#!/usr/bin/env bash
#
# Runs the XCTest suite without Xcode.
#
# XCTest ships with Xcode, not the Command Line Tools, so `swift test` cannot run
# on a tools-only machine. This script compiles `Tests/` with a small
# XCTest-compatible runner and executes it, which is how the suite is verified
# here. `swift test` under Xcode remains the real runner and runs the same files
# unmodified.
#
# The one transformation: Swift `async` test methods cannot be reached through a
# selector, so the async bodies are rewritten into synchronous ones that wait on a
# task. The test logic, its assertions and its names are untouched.
#
# Usage: Scripts/run-tests.sh

set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
REPO_ROOT="$(cd "$(dirname "${SCRIPT_PATH}")/.." && pwd)"
cd "${REPO_ROOT}"

WORK="${REPO_ROOT}/.build/test-run"
rm -rf "${WORK}"
mkdir -p "${WORK}/transformed" "${WORK}/modules"

SDK_PATH="$(xcrun --show-sdk-path)"
RUST_LIB="${REPO_ROOT}/Bridge/macos-universal/libsift_ffi.a"
if [[ ! -f "${RUST_LIB}" ]]; then
  echo "error: the Rust scanner core is missing; run Scripts/bootstrap.sh first" >&2
  exit 1
fi
TRIPLE="$(uname -m)-apple-macosx13.0"
BIN_PATH="$(swift build --show-bin-path)"
MODULES="${BIN_PATH}/Modules"

echo "==> Building the package"
swift build --target Core --target Shared >/dev/null

echo "==> Compiling the XCTest-compatible runner"
swiftc -emit-module -emit-library -static \
  -module-name XCTest \
  -emit-module-path "${WORK}/modules/XCTest.swiftmodule" \
  -o "${WORK}/modules/libXCTest.a" \
  -swift-version 6 -target "${TRIPLE}" -sdk "${SDK_PATH}" \
  -I "${MODULES}" \
  "${REPO_ROOT}/Scripts/shims/XCTest/XCTest.swift"

# `async` test methods are rewritten to synchronous ones; each body is wrapped so
# its awaits still run, on a task the wrapper waits for.
echo "==> Preparing the test sources"
python3 "${REPO_ROOT}/Scripts/rewrite-async-tests.py" "${REPO_ROOT}/Tests" "${WORK}/transformed"

echo "==> Compiling the suite"
cat > "${WORK}/transformed/Main.swift" <<'MAIN'
import Foundation
import XCTest

/// Bridges an async test body into a synchronous one.
///
/// The runner discovers methods through selectors, and a Swift `async` method
/// cannot be reached that way. The rewritten bodies call this, which starts the
/// async work and waits for it. The runner is a single-threaded command-line
/// process, so blocking its only thread is safe.
///
/// The body is carried in an unchecked box rather than captured directly:
/// `Task` requires a `sending` closure under strict concurrency, and the box is
/// what states that the hand-off is safe here (one thread, one task at a time).
final class BodyBox<T>: @unchecked Sendable {
    let body: () async throws -> T
    var result: Result<T, Error>?

    init(_ body: @escaping () async throws -> T) {
        self.body = body
    }
}

func runAsync<T>(_ body: @escaping () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = BodyBox(body)
    Task {
        do {
            box.result = .success(try await box.body())
        } catch {
            box.result = .failure(error)
        }
        semaphore.signal()
    }
    semaphore.wait()
    switch box.result {
    case let .success(value): return value
    case let .failure(error): throw error
    case .none: fatalError("async test body never completed")
    }
}

@main
struct TestMain {
    static func main() async {
        print("Sift test suite")
        let failures = await XCTestRunner.run(TestRegistry.all)
        exit(failures == 0 ? 0 : 1)
    }
}
MAIN

INCLUDE_FLAGS=(-I "${MODULES}" -I "${WORK}/modules" -I "${REPO_ROOT}/Bridge/include")
for target in Core Shared; do
  map="${BIN_PATH}/${target}.build/include/module.modulemap"
  [[ -f "${map}" ]] && INCLUDE_FLAGS+=(-Xcc -fmodule-map-file="${map}")
done
INCLUDE_FLAGS+=(-Xcc -fmodule-map-file="${REPO_ROOT}/Bridge/module.modulemap")

swiftc \
  -swift-version 6 -target "${TRIPLE}" -sdk "${SDK_PATH}" \
  -o "${WORK}/SiftPackageTests" \
  "${INCLUDE_FLAGS[@]}" \
  -L "${WORK}/modules" -lXCTest \
  -Xlinker -force_load -Xlinker "${WORK}/modules/libXCTest.a" \
  -Xlinker -force_load -Xlinker "${RUST_LIB}" \
  -framework CoreFoundation -framework Security -lc++ -lm \
  "${BIN_PATH}"/Core.build/*.o \
  "${BIN_PATH}"/Shared.build/*.o \
  "${WORK}/transformed"/*.swift

echo "==> Running"
"${WORK}/SiftPackageTests"
