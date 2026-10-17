import Foundation

/// A cancellation flag a running walk can poll.
///
/// Shared by the scans, the storage analysis and the diagnostics: a long read
/// has to stop when the user leaves the page, and a Swift `Task`'s cancellation
/// cannot be seen from inside a synchronous loop. `NSLock` would be enough, but
/// the walker polls this once per directory entry, so an atomic keeps that cost
/// invisible.
public final class CancellationFlag: @unchecked Sendable {
    private let storage = ManagedAtomicFlag()

    public init() {}

    public var isCancelled: Bool {
        get { storage.value }
        set { storage.value = newValue }
    }
}

/// Wrapper so the atomic is created once and read without allocation.
private final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return flag
        }
        set {
            lock.lock()
            flag = newValue
            lock.unlock()
        }
    }
}
