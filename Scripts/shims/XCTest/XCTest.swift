/*
 * A small XCTest-compatible test runner.
 *
 * XCTest ships with Xcode, not with the Command Line Tools, so on a tools-only
 * machine the suite in `Tests/` cannot run. This module gives the suite the same
 * API surface — `XCTestCase`, the assertion functions, `setUp`/`tearDown` — and a
 * runner that discovers subclasses through the Objective-C runtime, so the suite
 * that ships for Xcode also runs here, unmodified.
 *
 * It is deliberately minimal: the semantics that matter are that an assertion
 * failure fails the test, `setUp`/`tearDown` run around it, and async test
 * methods are awaited. `swift test` and the Xcode test plan remain the real
 * runners; this one is for verification on a machine without Xcode.
 */
import Foundation

// MARK: - Failure reporting

/// A failed assertion. Thrown so the runner can attribute it to a test.
public struct XCTestFailure: Error, CustomStringConvertible {
    public let message: String
    public let file: StaticString
    public let line: UInt

    public init(message: String, file: StaticString, line: UInt) {
        self.message = message
        self.file = file
        self.line = line
    }

    public var description: String {
        "\(file):\(line): \(message)"
    }
}

/// Collects results for the runner.
///
/// The runner is single-threaded, so the state is guarded by a lock rather than a
/// global actor: the assertions are called from synchronous test bodies.
public final class XCTestObserver: @unchecked Sendable {
    public struct Result {
        public let name: String
        public var failure: String?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var storage: [Result] = []

    /// The tests that have run, in order.
    public static var results: [Result] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    /// Starts a test.
    public static func begin(_ name: String) {
        lock.lock()
        storage.append(Result(name: name, failure: nil))
        lock.unlock()
    }

    /// The failure recorded for the most recent test, if any.
    public static func lastFailure() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage.last?.failure
    }

    /// Records a failure against the running test.
    public static func record(_ failure: XCTestFailure) {
        lock.lock()
        defer { lock.unlock() }
        guard !storage.isEmpty else { return }
        let index = storage.count - 1
        if storage[index].failure == nil {
            storage[index].failure = failure.description
        }
    }
}

// MARK: - Test case

open class XCTestCase: NSObject, @unchecked Sendable {
    public override required init() { super.init() }

    open func setUp() {}
    open func tearDown() {}
    open func setUpWithError() throws {}
    open func tearDownWithError() throws {}


}

public struct XCTestError: Error {
    public init() {}
}

// MARK: - Assertions

/// Records a failure against the running test.
///
/// XCTest's assertions do not throw, and neither do these: a failure is recorded
/// and the test continues to its next statement, which is what makes a test report
/// every failure rather than only the first.
private func fail(
    _ message: @autoclosure () -> String,
    file: StaticString,
    line: UInt
) {
    XCTestObserver.record(XCTestFailure(message: message(), file: file, line: line))
}

@discardableResult
public func XCTAssertTrue(
    _ expression: @autoclosure () throws -> Bool,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) rethrows -> Bool {
    let value = try expression()
    if !value { fail(message().isEmpty ? "expression was false" : message(), file: file, line: line) }
    return value
}

@discardableResult
public func XCTAssertFalse(
    _ expression: @autoclosure () throws -> Bool,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) rethrows -> Bool {
    let value = try expression()
    if value { fail(message().isEmpty ? "expression was true" : message(), file: file, line: line) }
    return !value
}

public func XCTAssertEqual<T: Equatable>(
    _ expression1: @autoclosure () throws -> T,
    _ expression2: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) rethrows {
    let (left, right) = (try expression1(), try expression2())
    if left != right {
        fail(
            "\(message().isEmpty ? "values differ" : message()): expected \(right), got \(left)",
            file: file,
            line: line
        )
    }
}

public func XCTAssertNotEqual<T: Equatable>(
    _ expression1: @autoclosure () throws -> T,
    _ expression2: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) rethrows {
    if try expression1() == expression2() {
        fail(message().isEmpty ? "values are equal" : message(), file: file, line: line)
    }
}

public func XCTAssertNil<T>(
    _ expression: @autoclosure () throws -> T?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) rethrows {
    if try expression() != nil {
        fail(message().isEmpty ? "value was not nil" : message(), file: file, line: line)
    }
}

public func XCTAssertNotNil<T>(
    _ expression: @autoclosure () throws -> T?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) rethrows {
    if try expression() == nil {
        fail(message().isEmpty ? "value was nil" : message(), file: file, line: line)
    }
}

public func XCTAssertLessThan<T: Comparable>(
    _ expression1: @autoclosure () throws -> T,
    _ expression2: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) rethrows {
    let (left, right) = (try expression1(), try expression2())
    if !(left < right) {
        fail(
            "\(message().isEmpty ? "not less than" : message()): \(left) is not < \(right)",
            file: file,
            line: line
        )
    }
}

public func XCTAssertLessThanOrEqual<T: Comparable>(
    _ expression1: @autoclosure () throws -> T,
    _ expression2: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) rethrows {
    let (left, right) = (try expression1(), try expression2())
    if !(left <= right) {
        fail(
            "\(message().isEmpty ? "not less than or equal" : message()): \(left) is not <= \(right)",
            file: file,
            line: line
        )
    }
}

public func XCTAssertGreaterThan<T: Comparable>(
    _ expression1: @autoclosure () throws -> T,
    _ expression2: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) rethrows {
    let (left, right) = (try expression1(), try expression2())
    if !(left > right) {
        fail(
            "\(message().isEmpty ? "not greater than" : message()): \(left) is not > \(right)",
            file: file,
            line: line
        )
    }
}

public func XCTAssertGreaterThanOrEqual<T: Comparable>(
    _ expression1: @autoclosure () throws -> T,
    _ expression2: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) rethrows {
    let (left, right) = (try expression1(), try expression2())
    if !(left >= right) {
        fail(
            "\(message().isEmpty ? "not greater than or equal" : message()): \(left) is not >= \(right)",
            file: file,
            line: line
        )
    }
}

public func XCTFail(
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    fail(message.isEmpty ? "explicit failure" : message, file: file, line: line)
}

/// Asserts that an expression throws.
///
/// The handler receives the error so a test can pin *which* failure it expects,
/// which is how a rule file is checked for the specific reason it was refused
/// rather than for "something went wrong".
public func XCTAssertThrowsError<T>(
    _ expression: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) {
    do {
        _ = try expression()
        fail(
            "\(message().isEmpty ? "expression did not throw" : message()): no error was thrown",
            file: file,
            line: line
        )
    } catch {
        errorHandler(error)
    }
}

/// Asserts that an expression does not throw.
public func XCTAssertNoThrow<T>(
    _ expression: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    do {
        _ = try expression()
    } catch {
        fail(
            "\(message().isEmpty ? "expression threw" : message()): \(error)",
            file: file,
            line: line
        )
    }
}

public func XCTUnwrap<T>(
    _ expression: @autoclosure () throws -> T?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> T {
    guard let value = try expression() else {
        throw XCTestFailure(
            message: message().isEmpty ? "value was nil" : message(),
            file: file,
            line: line
        )
    }
    return value
}

// MARK: - Runner

/// Runs every subclass of `XCTestCase` it can find.
///
/// Discovery uses the Objective-C runtime because Swift has no reflection over
/// subclasses; the test classes are `NSObject` subclasses, so they are visible.
public enum XCTestRunner {
    /// Runs the suite and returns the number of failures.
    ///
    /// The runner is main-actor isolated: each generated body hops there to
    /// construct the suite, which matches how XCTest presents tests and keeps a
    /// view-model test on the same thread as the real app.
    @MainActor
    public static func run(
        _ tests: [(suite: String, method: String, body: () async throws -> Void)]
    ) async -> Int {
        var failures = 0
        var passed = 0

        for entry in tests {
            let displayName = "\(entry.suite).\(entry.method)"
            XCTestObserver.begin(displayName)

            do {
                try await entry.body()
            } catch let failure as XCTestFailure {
                XCTestObserver.record(failure)
            } catch {
                XCTestObserver.record(
                    XCTestFailure(message: "threw: \(error)", file: #filePath, line: 0)
                )
            }

            if let failure = XCTestObserver.lastFailure() {
                failures += 1
                print("  \u{001B}[31m✗\u{001B}[0m \(displayName)")
                print("      \(failure)")
            } else {
                passed += 1
                print("  \u{001B}[32m✓\u{001B}[0m \(displayName)")
            }
        }

        print("")
        print("  passed: \(passed)")
        print("  failed: \(failures)")
        return failures
    }

}
