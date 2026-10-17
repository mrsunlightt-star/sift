import Foundation
import OSLog

/// Logging (§6.1, §13.2).
///
/// Every log statement in the app goes through this type so the redaction rules
/// hold in one place:
///
/// * **never** logged: full paths, user names, file names, document titles,
///   purchase credentials,
/// * **always** logged with an explicit privacy annotation so a mistake is a
///   visible `private` marker rather than a leak.
///
/// Fields that are safe to record — rule ids, error codes, categories, size
/// bands, durations, the macOS version — are passed as plain interpolations.
public enum SiftLog {
    /// Subsystem shared by every category, matching the bundle identifier.
    public static let subsystem = "com.siftmac.cleaner"

    /// Creates a category logger.
    public static func make(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }

    public static let scan = make("Scan")
    public static let cleanup = make("Cleanup")
    public static let rules = make("Rules")
    public static let permissions = make("Permissions")
    public static let operations = make("FileOperations")
    public static let storage = make("Storage")
    public static let purchase = make("Purchase")
    public static let report = make("Report")
    public static let ui = make("UI")
}

/// A redacted description of a path.
///
/// Use this whenever a path has to appear in a log or an exported diagnostic:
/// the leaf name becomes `<file>` and the parent directories become `<dir>`
/// segments, so the shape of a path is visible without identifying anything.
public struct RedactedPath: CustomStringConvertible, Sendable {
    public let components: [String]

    public init(_ path: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var trimmed = path
        if trimmed.hasPrefix(home) {
            trimmed = "~" + trimmed.dropFirst(home.count)
        }
        components = trimmed.split(separator: "/").map { component in
            let text = String(component)
            // Keep `~` and known-safe directory names out of the redaction: the
            // point of the log line is to show which area failed, not which file.
            if text == "~" { return text }
            return "<dir>"
        }
        lastComponentName = (path as NSString).lastPathComponent
    }

    private let lastComponentName: String

    public var description: String {
        components.joined(separator: "/")
    }

    /// The number of path components, safe to log: it distinguishes a top-level
    /// problem from a deeply nested one without naming either.
    public var depth: Int { components.count }
}

/// A size band, so a log line can carry magnitude without carrying a size.
public enum SizeBand: String, Sendable {
    case empty
    case bytes
    case kilobytes
    case megabytes
    case gigabytes
    case terabytes

    public init(bytes: Int64) {
        switch bytes {
        case ..<1: self = .empty
        case ..<1_000: self = .bytes
        case ..<1_000_000: self = .kilobytes
        case ..<1_000_000_000: self = .megabytes
        case ..<1_000_000_000_000: self = .gigabytes
        default: self = .terabytes
        }
    }
}
