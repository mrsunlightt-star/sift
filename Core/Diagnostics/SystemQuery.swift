import Darwin
import Foundation

/// What macOS reports about its own indexes and snapshots.
///
/// This is the only place in the product that runs another program, and both
/// queries are status reads. `mdutil -s` says whether a volume is indexed;
/// `tmutil listlocalsnapshots` lists snapshot names. Neither changes anything,
/// neither takes input, and the arguments are fixed here rather than built from
/// anything a user, a rule file or a scanned path can influence.
///
/// A query that fails, times out or is missing is reported as unknown. It is
/// never turned into a result: guessing that a volume is indexed because the
/// question could not be asked would put a fabricated statement in front of the
/// user.
enum SystemQuery {
    /// How long a single query may take before it is terminated.
    static let timeout: TimeInterval = 5

    struct Outcome: Sendable {
        let output: String
        let succeeded: Bool
    }

    /// Runs `executable` with `arguments` and returns its standard output.
    ///
    /// No shell is involved: the executable path and the argument list are passed
    /// to the system directly, so a path containing a space or a quote cannot
    /// change what runs.
    static func run(_ executable: String, _ arguments: [String]) -> Outcome {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return Outcome(output: "", succeeded: false)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        // Both halves of the query are bounded: reading the output *and*
        // waiting for the process to exit. Waiting only on the read left
        // `waitUntilExit()` blocking forever when the tool closed its output
        // and kept running, so the caller never got a verdict.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return Outcome(output: "", succeeded: false)
        }

        let box = OutputBox()
        let readFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            box.set(pipe.fileHandleForReading.readDataToEndOfFile())
            readFinished.signal()
        }

        guard readFinished.wait(timeout: .now() + timeout) == .success else {
            // The tool is holding its output open. Ask it to stop, then insist;
            // the read thread is given a bounded chance to observe the closed
            // pipe, but its result no longer decides when this call returns.
            stop(process, exited: exited)
            _ = readFinished.wait(timeout: .now() + 1)
            return Outcome(output: "", succeeded: false)
        }

        // The output is complete. The process is allowed a short exit window;
        // one that stays alive after closing its output is not a successful
        // query, even if it would eventually exit.
        guard exited.wait(timeout: .now() + 1) == .success else {
            stop(process, exited: exited)
            return Outcome(output: "", succeeded: false)
        }

        return Outcome(
            output: String(data: box.value, encoding: .utf8) ?? "",
            succeeded: process.terminationStatus == 0
        )
    }

    /// Terminates a query and waits a bounded time for it to go away.
    private static func stop(_ process: Process, exited: DispatchSemaphore) {
        process.terminate()
        if exited.wait(timeout: .now() + 1) == .success { return }
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
        _ = exited.wait(timeout: .now() + 1)
    }

    /// A small locked box for the bytes read on the background queue.
    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func set(_ next: Data) {
            lock.lock()
            data = next
            lock.unlock()
        }

        var value: Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    // MARK: - Spotlight

    /// What Spotlight says about a volume.
    ///
    /// Only whether indexing is on. `mdutil -s` does not report a rebuild that is
    /// currently running, so no state here claims that one is.
    enum SpotlightState: Sendable, Hashable {
        case indexed
        case notIndexed
        case unknown
    }

    static func spotlightState(ofVolumeAt path: String) -> SpotlightState {
        guard path.hasPrefix("/") else { return .unknown }
        let outcome = run("/usr/bin/mdutil", ["-s", path])
        guard outcome.succeeded else { return .unknown }
        let text = outcome.output.lowercased()
        // `mdutil` answers with "Indexing enabled." or "Indexing disabled." /
        // "Indexing and searching disabled."; anything else is not an answer.
        if text.contains("indexing and searching disabled") || text.contains("indexing disabled") {
            return .notIndexed
        }
        if text.contains("indexing enabled") { return .indexed }
        return .unknown
    }

    // MARK: - APFS snapshots

    struct LocalSnapshot: Sendable, Hashable {
        let name: String
        let createdAt: Date?
    }

    /// The APFS local snapshots a volume currently holds.
    ///
    /// An empty list means either "none" or "the question could not be asked";
    /// `asked` is what tells them apart, because reporting a volume as
    /// snapshot-free when the query failed would hide space the user is looking
    /// for. The exit status cannot be that signal: `tmutil` exits zero while
    /// printing "… is not a valid disk", so the listing header is used instead.
    static func localSnapshots(ofVolumeAt path: String) -> (snapshots: [LocalSnapshot], asked: Bool) {
        guard path.hasPrefix("/") else { return ([], false) }
        let outcome = run("/usr/bin/tmutil", ["listlocalsnapshots", path])
        guard outcome.succeeded, outcome.output.contains("Snapshots for disk") else {
            return ([], false)
        }
        return (parseSnapshots(outcome.output), true)
    }

    /// Extracts snapshot names and dates from `tmutil`'s listing.
    static func parseSnapshots(_ output: String) -> [LocalSnapshot] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.timeZone = .current

        return output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("com.apple.TimeMachine.") && $0.hasSuffix(".local") }
            .map { name in
                let stamp = name
                    .replacingOccurrences(of: "com.apple.TimeMachine.", with: "")
                    .replacingOccurrences(of: ".local", with: "")
                return LocalSnapshot(name: name, createdAt: formatter.date(from: stamp))
            }
    }
}
