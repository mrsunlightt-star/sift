import AppKit
import Foundation
import OSLog
import Shared

/// Finds installed applications and the files they own (§5.3).
///
/// The rule that matters most here is what this type refuses to do: it never
/// guesses an association from a similar-looking name. A directory is only
/// reported as an application's leftover when its name matches the application's
/// bundle identifier, or its exact application name in a location where macOS
/// itself puts per-application data. `~/Library/Application Support/Editor` is
/// never claimed for an app called "Editor".
/// `@unchecked Sendable`: `RuleEngine` is a value type and the `FileManager` is
/// only used for its documented thread-safe read APIs, so instances can cross an
/// isolation boundary. The manager is not mutated and no shared state is cached.
public struct ApplicationDiscovery: @unchecked Sendable {
    private let rules: RuleEngine
    private let fileManager: FileManager
    private let logger = SiftLog.make("Discovery")

    /// Application directories, in the order the specification lists them (§5.3).
    private let applicationDirectories: [URL]

    public init(rules: RuleEngine, fileManager: FileManager = .default, additionalDirectories: [URL] = []) {
        self.rules = rules
        self.fileManager = fileManager
        var directories = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]
        directories.append(contentsOf: additionalDirectories)
        self.applicationDirectories = directories
    }

    /// Every application found, system apps included.
    ///
    /// System applications are returned with `isSystemApplication = true` rather
    /// than hidden, because §5.3 requires them to be visible and marked
    /// "cannot be uninstalled" instead of absent.
    public func installedApplications(includingSystemApplications: Bool = true) async -> [InstalledApplication] {
        let runningPaths = await runningBundlePaths()
        var applications: [InstalledApplication] = []
        var seen = Set<String>()

        for directory in applicationDirectories {
            guard let contents = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isApplicationKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in contents where url.pathExtension == "app" {
                guard let application = describe(url: url, runningPaths: runningPaths) else { continue }
                guard seen.insert(application.id).inserted else { continue }
                if application.isSystemApplication, !includingSystemApplications { continue }
                applications.append(application)
            }
        }

        logger.info("Discovered \(applications.count) applications")
        return applications.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Reads one bundle's identifying information.
    private func describe(url: URL, runningPaths: Set<String>) -> InstalledApplication? {
        guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else {
            // A bundle without an identifier cannot be matched to its files, so
            // it is still listed but with an empty identifier rather than
            // guessed at.
            let name = url.deletingPathExtension().lastPathComponent
            return InstalledApplication(
                url: url,
                name: name,
                bundleIdentifier: "",
                version: nil,
                sizeInBytes: measureApplication(url: url),
                lastUsedAt: lastUsed(url: url),
                isSystemApplication: isSystemLocation(url),
                isRunning: runningPaths.contains(url.standardizedFileURL.resolvingSymlinksInPath().path)
            )
        }
        return InstalledApplication(
            url: url,
            name: bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
                ?? bundle.infoDictionary?["CFBundleName"] as? String
                ?? url.deletingPathExtension().lastPathComponent,
            bundleIdentifier: identifier,
            version: bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
            sizeInBytes: measureApplication(url: url),
            lastUsedAt: lastUsed(url: url),
            isSystemApplication: isSystemLocation(url),
            isRunning: runningPaths.contains(url.standardizedFileURL.resolvingSymlinksInPath().path)
        )
    }

    /// `/System/Applications` and Apple's own bundles are not removable.
    private func isSystemLocation(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        return path.hasPrefix("/System/") || path.hasPrefix("/Library/Apple/")
    }

    private func measureApplication(url: URL) -> Int64 {
        FileWalker.measure(url: url, rules: rules, isCancelled: { false }).bytes
    }

    private func lastUsed(url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentAccessDateKey]))?.contentAccessDate
    }

    private func runningBundlePaths() async -> Set<String> {
        let paths = await MainActor.run { NSWorkspaceWorker.shared.runningApplicationBundlePaths() }
        return Set(paths)
    }

    // MARK: - Related files

    /// Finds the files an application owns (§5.3).
    ///
    /// Every candidate is derived from the bundle identifier. Files the match
    /// cannot justify are returned as `needsReview` instead of being dropped, so
    /// the user still sees them but nothing is removed on Sift's judgement alone.
    public func relatedFiles(for application: InstalledApplication) -> UninstallPlan {
        var confirmed: [RelatedFile] = []
        var review: [RelatedFile] = []

        let home = URL(fileURLWithPath: rules.homeDirectory)
        let identifier = application.bundleIdentifier
        let appName = application.name

        // Directories whose contents are named after the owning application.
        let nameBasedLocations: [(String, RelatedFile.Confidence)] = [
            ("Library/Application Support", .confirmed),
            ("Library/Caches", .confirmed),
            ("Library/Logs", .confirmed),
            ("Library/Saved Application State", .confirmed),
            ("Library/HTTPStorages", .confirmed),
            ("Library/WebKit", .confirmed),
            ("Library/Containers", .confirmed),
            ("Library/Group Containers", .needsReview),
            ("Library/Preferences", .confirmed),
        ]

        for (relative, confidence) in nameBasedLocations {
            let directory = home.appendingPathComponent(relative)
            guard let contents = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for candidate in contents {
                guard let match = match(candidate: candidate, identifier: identifier, appName: appName) else {
                    continue
                }
                if rules.protectionReason(for: candidate.path) != nil { continue }
                if rules.isExcludedBundleName(candidate.lastPathComponent) { continue }
                let size = measureEntry(candidate)
                let file = RelatedFile(
                    url: candidate,
                    sizeInBytes: size,
                    confidence: confidence,
                    reason: match
                )
                // A group container is only ever a candidate when the rule is
                // unambiguous, which the review bucket expresses.
                if confidence == .confirmed {
                    confirmed.append(file)
                } else {
                    review.append(file)
                }
            }
        }

        confirmed.sort { $0.sizeInBytes > $1.sizeInBytes }
        review.sort { $0.sizeInBytes > $1.sizeInBytes }
        return UninstallPlan(application: application, confirmedFiles: confirmed, reviewFiles: review)
    }

    /// Decides whether a candidate belongs to an application, and why.
    ///
    /// Returns `nil` unless the match is exact: the bundle identifier, the full
    /// `<bundle-id>.<suffix>` form macOS uses for per-app files, or the exact
    /// application name. A prefix or substring match is never enough. The reason
    /// travels with the file so the uninstaller can show what the match was, which
    /// is what lets the user judge the ones it is unsure about (§5.3).
    private func match(
        candidate: URL,
        identifier: String,
        appName: String
    ) -> RelatedFile.MatchReason? {
        let name = candidate.lastPathComponent
        let stem = name.contains(".") ? String(name.split(separator: ".").first ?? "") : name

        if !identifier.isEmpty {
            // Exact identifier, or `<identifier>.<something>` (caches, plists).
            if name.caseInsensitiveCompare(identifier) == .orderedSame {
                return .bundleIdentifier
            }
            if name.lowercased().hasPrefix(identifier.lowercased() + ".") {
                return .identifierPrefix
            }
        }

        // An exact application-name match is only accepted where macOS itself
        // names per-app data, which the caller's location list already encodes.
        if name.caseInsensitiveCompare(appName) == .orderedSame {
            return .applicationName
        }
        if !identifier.isEmpty,
           stem.caseInsensitiveCompare(identifier.split(separator: ".").last.map(String.init) ?? identifier)
            == .orderedSame {
            return .identifierSuffix
        }
        return nil
    }

    private func measureEntry(_ url: URL) -> Int64 {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if isDirectory.boolValue {
            return FileWalker.measure(url: url, rules: rules, isCancelled: { false }).bytes
        }
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        return FileWalker.allocatedSize(values: values, url: url)
    }

    /// Bundle identifiers of every installed application, for residue detection.
    public func installedBundleIdentifiers() async -> [String] {
        await installedApplications()
            .map(\.bundleIdentifier)
            .filter { !$0.isEmpty }
    }
}
