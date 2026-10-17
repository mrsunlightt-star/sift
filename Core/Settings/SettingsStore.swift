import Foundation
import OSLog
import Shared

/// User preferences (§5.6).
///
/// Stored in `UserDefaults` because every value is a simple preference that must
/// be readable before any window appears. Nothing here is an authorization
/// decision: purchase state lives in `EntitlementService`, and the scan scope
/// only ever *narrows* what Sift looks at.
public struct AppSettings: Sendable, Equatable {
    /// Directories the user added for scanning, plus their security-scoped
    /// bookmarks so the grant survives a relaunch (§10.3).
    public var authorizedLocations: [AuthorizedLocation]
    /// Paths the user asked Sift never to visit.
    public var ignoredPaths: [String]
    /// Extra rule file the user placed in the app's data directory.
    public var userRulesEnabled: Bool
    public var largeFileThresholdBytes: Int64
    public var oldFileThresholdDays: Int
    public var staleThresholdDays: Int
    public var showHiddenFiles: Bool
    public var requireConfirmation: Bool
    public var skipConfirmation: Bool
    public var appearance: Appearance
    public var reduceMotion: Bool
    public var keepScanHistory: Int
    public var launchAtLogin: Bool

    public enum Appearance: String, Sendable, CaseIterable, Codable {
        case system
        case light
        case dark

        public var titleKey: LocalizationKey {
            switch self {
            case .system: .settingsAppearanceSystem
            case .light: .settingsAppearanceLight
            case .dark: .settingsAppearanceDark
            }
        }
    }

    /// Defaults, matching §5.4 and §5.6.
    public static let `default` = AppSettings(
        authorizedLocations: [],
        ignoredPaths: [],
        userRulesEnabled: false,
        largeFileThresholdBytes: ScanDefaults.largeFileThresholdBytes,
        oldFileThresholdDays: ScanDefaults.oldFileThresholdDays,
        staleThresholdDays: ScanDefaults.staleThresholdDays,
        showHiddenFiles: false,
        // "Skip confirmation" is off by default and the user has to opt in with
        // an explicit warning (§5.6).
        requireConfirmation: true,
        skipConfirmation: false,
        appearance: .system,
        reduceMotion: false,
        keepScanHistory: 10,
        launchAtLogin: false
    )

    /// Whether the confirmation panel is shown for a destructive action.
    public var showsConfirmationPanel: Bool {
        requireConfirmation && !skipConfirmation
    }
}

/// Persists and publishes `AppSettings`.
///
/// The store is an `actor` so two features cannot interleave a read-modify-write
/// on the same key, and it publishes changes through an `AsyncStream` so the UI
/// reloads without polling.
/// A `UserDefaults` suite behind a `Sendable` façade.
///
/// `UserDefaults` is documented as thread-safe but is not annotated `Sendable`,
/// and the settings store is an actor. Wrapping it here is what lets the store
/// hold it without an unchecked escape hatch on every access.
public struct StringPreferences: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func bool(forKey key: String, default fallback: Bool = false) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    public func integer(forKey key: String) -> Int { defaults.integer(forKey: key) }
    public func int64(forKey key: String) -> Int64? { (defaults.object(forKey: key) as? NSNumber)?.int64Value }
    public func string(forKey key: String) -> String? { defaults.string(forKey: key) }
    public func stringArray(forKey key: String) -> [String]? { defaults.stringArray(forKey: key) }
    public func data(forKey key: String) -> Data? { defaults.data(forKey: key) }
    public func date(forKey key: String) -> Date? { defaults.object(forKey: key) as? Date }
    public func hasValue(forKey key: String) -> Bool { defaults.object(forKey: key) != nil }

    public func set(_ value: Bool, forKey key: String) { defaults.set(value, forKey: key) }
    public func set(_ value: Int, forKey key: String) { defaults.set(value, forKey: key) }
    public func set(_ value: Int64, forKey key: String) { defaults.set(value, forKey: key) }
    public func set(_ value: String, forKey key: String) { defaults.set(value, forKey: key) }
    public func set(_ value: [String], forKey key: String) { defaults.set(value, forKey: key) }
    public func set(_ value: Data, forKey key: String) { defaults.set(value, forKey: key) }
    public func set(_ value: Date, forKey key: String) { defaults.set(value, forKey: key) }
    public func remove(forKey key: String) { defaults.removeObject(forKey: key) }
    public func removeDomain(_ name: String) { defaults.removePersistentDomain(forName: name) }
}

public actor SettingsStore {
    private let defaults: StringPreferences
    private let logger = SiftLog.make("Settings")
    private var settings: AppSettings
    private var continuations: [UUID: AsyncStream<AppSettings>.Continuation] = [:]
    /// Where a user rule file would live, if the user drops one in.
    private let supportDirectory: URL

    private enum Key {
        static let authorizedLocations = "settings.authorizedLocations"
        static let ignoredPaths = "settings.ignoredPaths"
        static let userRulesEnabled = "settings.userRulesEnabled"
        static let largeFileThresholdBytes = "settings.largeFileThresholdBytes"
        static let oldFileThresholdDays = "settings.oldFileThresholdDays"
        static let staleThresholdDays = "settings.staleThresholdDays"
        static let showHiddenFiles = "settings.showHiddenFiles"
        static let requireConfirmation = "settings.requireConfirmation"
        static let skipConfirmation = "settings.skipConfirmation"
        static let appearance = "settings.appearance"
        static let reduceMotion = "settings.reduceMotion"
        static let keepScanHistory = "settings.keepScanHistory"
        static let launchAtLogin = "settings.launchAtLogin"
    }

    /// Creates a store over a preferences suite.
    ///
    /// `preferences` is the `Sendable` façade rather than `UserDefaults` itself,
    /// so a store can be created from any context.
    public init(preferences: StringPreferences = StringPreferences(), supportDirectory: URL? = nil) {
        self.defaults = preferences
        self.supportDirectory = supportDirectory ?? Self.defaultSupportDirectory()
        self.settings = Self.load(from: preferences)
    }

    /// The app's own data directory, used for scan history and reports.
    public static func defaultSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Sift", isDirectory: true)
    }

    /// The user's rule file, when one exists.
    public func userRuleURL() -> URL? {
        let url = supportDirectory.appendingPathComponent("CleaningRules.json")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Resolved ignore list, used by the scan request.
    public func ignoredPathsForScan() -> [String] {
        // Hidden files that the user does not want to see are excluded at the
        // scan level rather than filtered in the UI, so they never affect totals.
        var paths = settings.ignoredPaths
        if !settings.showHiddenFiles {
            // No implicit path is added: hidden items are filtered when shown,
            // which keeps the totals honest. Listed here for clarity.
            paths = settings.ignoredPaths
        }
        return paths
    }

    public func current() -> AppSettings { settings }

    /// Applies a change and notifies observers.
    public func update(_ mutate: @Sendable (inout AppSettings) -> Void) {
        mutate(&settings)
        persist()
        for continuation in continuations.values {
            continuation.yield(settings)
        }
    }

    /// A stream of settings changes for the UI.
    public func changes() -> AsyncStream<AppSettings> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<AppSettings>.makeStream()
        continuation.yield(settings)
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    /// Restores every value to its default.
    public func resetToDefaults() {
        settings = .default
        persist()
        for continuation in continuations.values {
            continuation.yield(settings)
        }
        logger.notice("Settings restored to defaults")
    }

    /// Clears the scan history directory.
    public func clearHistory() {
        let historyDirectory = supportDirectory.appendingPathComponent("History", isDirectory: true)
        try? FileManager.default.removeItem(at: historyDirectory)
        logger.notice("Scan history cleared")
    }

    // MARK: - Persistence

    private func persist() {
        defaults.set(settings.largeFileThresholdBytes, forKey: Key.largeFileThresholdBytes)
        defaults.set(settings.oldFileThresholdDays, forKey: Key.oldFileThresholdDays)
        defaults.set(settings.staleThresholdDays, forKey: Key.staleThresholdDays)
        defaults.set(settings.showHiddenFiles, forKey: Key.showHiddenFiles)
        defaults.set(settings.requireConfirmation, forKey: Key.requireConfirmation)
        defaults.set(settings.skipConfirmation, forKey: Key.skipConfirmation)
        defaults.set(settings.appearance.rawValue, forKey: Key.appearance)
        defaults.set(settings.reduceMotion, forKey: Key.reduceMotion)
        defaults.set(settings.keepScanHistory, forKey: Key.keepScanHistory)
        defaults.set(settings.launchAtLogin, forKey: Key.launchAtLogin)
        defaults.set(settings.userRulesEnabled, forKey: Key.userRulesEnabled)
        defaults.set(settings.ignoredPaths, forKey: Key.ignoredPaths)
        if let encoded = try? JSONEncoder().encode(settings.authorizedLocations) {
            defaults.set(encoded, forKey: Key.authorizedLocations)
        }
    }

    private static func load(from defaults: StringPreferences) -> AppSettings {
        var settings = AppSettings.default
        if let bytes = defaults.int64(forKey: Key.largeFileThresholdBytes) {
            settings.largeFileThresholdBytes = bytes
        }
        if defaults.hasValue(forKey: Key.oldFileThresholdDays) {
            settings.oldFileThresholdDays = defaults.integer(forKey: Key.oldFileThresholdDays)
        }
        if defaults.hasValue(forKey: Key.staleThresholdDays) {
            settings.staleThresholdDays = defaults.integer(forKey: Key.staleThresholdDays)
        }
        settings.showHiddenFiles = defaults.bool(forKey: Key.showHiddenFiles)
        // Confirmation defaults to on: an absent key must not silently disable it.
        settings.requireConfirmation = defaults.bool(forKey: Key.requireConfirmation, default: true)
        settings.skipConfirmation = defaults.bool(forKey: Key.skipConfirmation)
        settings.reduceMotion = defaults.bool(forKey: Key.reduceMotion)
        settings.userRulesEnabled = defaults.bool(forKey: Key.userRulesEnabled)
        settings.launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
        if let raw = defaults.string(forKey: Key.appearance),
           let appearance = AppSettings.Appearance(rawValue: raw) {
            settings.appearance = appearance
        }
        if defaults.hasValue(forKey: Key.keepScanHistory),
           defaults.integer(forKey: Key.keepScanHistory) > 0 {
            settings.keepScanHistory = defaults.integer(forKey: Key.keepScanHistory)
        }
        if let ignored = defaults.stringArray(forKey: Key.ignoredPaths) {
            settings.ignoredPaths = ignored
        }
        if let data = defaults.data(forKey: Key.authorizedLocations),
           let locations = try? JSONDecoder().decode([AuthorizedLocation].self, from: data) {
            settings.authorizedLocations = locations
        }
        return settings
    }
}
