import Foundation

/// A cancellation flag a running walk can poll.
///
/// Shared by the scans, the storage analysis and the diagnostics: a long read
/// has to stop when the user leaves the page, and a Swift `Task`'s cancellation
/// cannot be seen from inside a synchronous loop.
///
/// The flag is a `Bool` behind an `NSLock`, and this comment used to call it an
/// atomic. It is not one, and the difference is worth stating rather than
/// hiding: `Synchronization.Atomic` is macOS 15+, this package targets macOS 13,
/// and a wrapper whose type name said "atomic" while its body took a lock is
/// exactly the kind of comment that gets trusted instead of read. The cost the
/// lock actually has is an uncontended `pthread_mutex_lock` — no allocation, no
/// system call on the fast path — which is what makes a poll per directory entry
/// affordable. A second implementation for newer systems would only give the
/// two halves somewhere to disagree; `Synchronization` becomes the right answer
/// when the deployment target reaches macOS 15.
public final class CancellationFlag: @unchecked Sendable {
    private let storage = LockedFlag()

    public init() {}

    public var isCancelled: Bool {
        get { storage.value }
        set { storage.value = newValue }
    }
}

/// The lock the flag lives behind; created once and read without allocation.
private final class LockedFlag: @unchecked Sendable {
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
