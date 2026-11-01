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

    /// Resolves a bundle identifier to the installed application's name.
    ///
    /// Injected so a test can answer it without installing anything, and so the
    /// LaunchServices call is in one place: a shared container is reported as
    /// shared only when a *registered* application answers for the identifier.
    private let appNameForBundleIdentifier: @Sendable (String) -> String?

    /// Which installed applications declare which app groups.
    ///
    /// A group container is named after its group, so the name it carries belongs
    /// to no application in particular. This is the entitlement-level answer to
    /// "who else uses this container", and it is built at most once per instance.
    private let appGroups: AppGroupRegistry

    public init(
        rules: RuleEngine,
        fileManager: FileManager = .default,
        additionalDirectories: [URL] = [],
        includeDefaultDirectories: Bool = true,
        appNameForBundleIdentifier: @escaping @Sendable (String) -> String? = {
            ApplicationDiscovery.installedApplicationName(forBundleIdentifier: $0)
        },
        readAppGroups: @escaping AppGroupEntitlements.Reader = AppGroupEntitlements.read
    ) {
        self.rules = rules
        self.fileManager = fileManager
        self.appNameForBundleIdentifier = appNameForBundleIdentifier
        var directories: [URL] = []
        if includeDefaultDirectories {
            directories = [
                URL(fileURLWithPath: "/Applications", isDirectory: true),
                URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
                // System applications are listed and marked uninstallable-protected,
                // not hidden (§5.3). A directory only reachable through here would
                // otherwise be absent from the list entirely.
                URL(fileURLWithPath: "/System/Applications", isDirectory: true),
                URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
                fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
            ]
        }
        directories.append(contentsOf: additionalDirectories)
        self.applicationDirectories = directories
        self.appGroups = AppGroupRegistry(
            applicationDirectories: directories,
            fileManager: fileManager,
            read: readAppGroups
        )
    }

    /// The directories this discovery searches, in order. Test-visible.
    var searchDirectories: [URL] { applicationDirectories }

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
            for url in applicationBundleURLs(in: directory) {
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
        // An application bundle is one object, and its size is what removing it
        // would free. It must not be measured through the cleanup walker: that
        // walker refuses `/System`, so every system application — now that
        // `/System/Applications` is searched — reported zero bytes.
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey,
        ]
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }

        var bytes: Int64 = 0
        for case let child as URL in enumerator {
            guard let values = try? child.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true { continue }
            guard values.isRegularFile == true else { continue }
            bytes += FileWalker.allocatedSize(values: values, url: child)
        }
        return bytes
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

        // A group container is named after its group, so the entries in this one
        // directory can belong to the application for a reason no name can show.
        // Read the application's own declarations once, and only when there is a
        // group container to ask about.
        let groupContainers = "Library/Group Containers"
        var declaredGroups: Set<String> = []
        if fileManager.fileExists(atPath: home.appendingPathComponent(groupContainers).path) {
            declaredGroups = appGroups.groups(ofApplicationAt: application.url)
        }

        for (relative, confidence) in nameBasedLocations {
            let directory = home.appendingPathComponent(relative)
            guard let contents = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            let declaresGroups = relative == groupContainers ? declaredGroups : []

            for candidate in contents {
                guard let match = match(
                    candidate: candidate,
                    identifier: identifier,
                    appName: appName,
                    declaredGroups: declaresGroups
                ) else {
                    continue
                }
                if rules.protectionReason(for: candidate.path) != nil { continue }
                if rules.isInExcludedLocation(candidate.path) { continue }
                let size = measureEntry(candidate)
                let file = RelatedFile(
                    url: candidate,
                    sizeInBytes: size,
                    confidence: Self.combine(confidence, match.confidence),
                    reason: match.reason,
                    // A group container is shared by an app group: name the other
                    // installed applications that answer for it, so the row itself
                    // says that removing it may affect them.
                    sharedWith: relative == groupContainers
                        ? sharedApplications(for: candidate, besides: appName)
                        : [],
                    // The group is the container's name, kept as it is spelled on
                    // disk: it is what the entitlement says, and what the row can
                    // show when its own name is truncated.
                    groupIdentifier: match.reason == .appGroup ? candidate.lastPathComponent : nil
                )
                // Only a precise match in a location macOS itself names after an
                // application enters the removal batch on Sift's judgement. A
                // name or identifier-suffix match is a plausible association, and
                // two applications can share either, so it is shown for review.
                if file.confidence == .confirmed {
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

    /// The other installed applications that share the same container.
    ///
    /// Two facts, and the row states whichever it finds:
    ///
    /// - an installed application answers for one of the container's name
    ///   readings (LaunchServices), which is how a helper's container is claimed
    ///   for the parent that named it;
    /// - an installed application declares the container's group in its
    ///   entitlements, which is the only way a container shared by two unrelated
    ///   applications can be found at all — the name belongs to the group, not to
    ///   either of them.
    ///
    /// Both are facts read from the system. A container nothing installed answers
    /// for produces no names, and the row then says only what it knows.
    private func sharedApplications(for candidate: URL, besides appName: String) -> [String] {
        var names: [String] = []
        func add(_ name: String) {
            if name.caseInsensitiveCompare(appName) == .orderedSame { return }
            if names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return }
            names.append(name)
        }

        for reading in BundleNameReadings.identifiers(candidate.lastPathComponent) {
            if let name = appNameForBundleIdentifier(reading) { add(name) }
        }
        for name in appGroups.applications(declaring: candidate.lastPathComponent, excluding: appName) {
            add(name)
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The application LaunchServices has registered for an identifier.
    ///
    /// The residue scanner uses this to decide whether a container still belongs
    /// to something installed, and the uninstaller uses it to name the other
    /// applications a shared container belongs to. Both want the same answer, so
    /// there is one lookup.
    public static func applicationURL(forBundleIdentifier identifier: String) -> URL? {
        guard !identifier.isEmpty else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
    }

    /// The name of the installed application that answers for an identifier.
    ///
    /// `nil` when nothing is registered: a container whose application is gone
    /// has no name to show, and inventing one from the identifier is the guess
    /// this type exists to refuse.
    public static func installedApplicationName(forBundleIdentifier identifier: String) -> String? {
        guard let url = applicationURL(forBundleIdentifier: identifier) else { return nil }
        return url.deletingPathExtension().lastPathComponent
    }

    /// Decides whether a candidate belongs to an application, and why.
    ///
    /// Returns `nil` unless the match is exact: the bundle identifier, the full
    /// `<bundle-id>.<suffix>` form macOS uses for per-app files, or the exact
    /// application name. A prefix or substring match is never enough. The reason
    /// travels with the file so the uninstaller can show what the match was, which
    /// is what lets the user judge the ones it is unsure about (§5.3).
    ///
    /// The confidence is part of the answer. An identifier match names the
    /// application unambiguously; an exact name and the last identifier component
    /// do not — `com.vendor.notes` and an unrelated `notes` folder can coexist —
    /// so those are only ever suggestions.
    private func match(
        candidate: URL,
        identifier: String,
        appName: String,
        declaredGroups: Set<String> = []
    ) -> (reason: RelatedFile.MatchReason, confidence: RelatedFile.Confidence)? {
        let name = candidate.lastPathComponent
        let stem = name.contains(".") ? String(name.split(separator: ".").first ?? "") : name

        // The strongest evidence there is for a group container, and the only one
        // that exists when two applications share it: the container is named after
        // the group, and this application's signature declares that group. It is
        // checked first because it is a statement about this application rather
        // than about a name that could belong to anyone.
        if declaredGroups.contains(name.lowercased()) {
            return (.appGroup, .confirmed)
        }

        if !identifier.isEmpty {
            // Exact identifier, or `<identifier>.<something>` (caches, plists).
            if name.caseInsensitiveCompare(identifier) == .orderedSame {
                return (.bundleIdentifier, .confirmed)
            }
            if name.lowercased().hasPrefix(identifier.lowercased() + ".") {
                return (.identifierPrefix, .confirmed)
            }
            // A group container is `<team-id>.<identifier>`: the identifier is not
            // a prefix of the name, it is what follows the team id. Comparing the
            // whole name missed every one of them, so an installed application's
            // shared container was never associated with it.
            if BundleNameReadings.names(name, identifier: identifier) {
                return (.bundleIdentifier, .confirmed)
            }
        }

        // An exact application-name match is only accepted where macOS itself
        // names per-app data, which the caller's location list already encodes.
        if name.caseInsensitiveCompare(appName) == .orderedSame {
            return (.applicationName, .needsReview)
        }
        if !identifier.isEmpty,
           stem.caseInsensitiveCompare(identifier.split(separator: ".").last.map(String.init) ?? identifier)
            == .orderedSame {
            return (.identifierSuffix, .needsReview)
        }
        return nil
    }

    /// The weaker of two confidences.
    ///
    /// A location that is itself ambiguous (`Group Containers`) cannot become
    /// confirmed because the name happened to match exactly, and a precise match
    /// is the only thing that can confirm a candidate at all.
    private static func combine(
        _ location: RelatedFile.Confidence,
        _ match: RelatedFile.Confidence
    ) -> RelatedFile.Confidence {
        location == .confirmed && match == .confirmed ? .confirmed : .needsReview
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

    /// The app groups installed applications declare, for the scan request.
    ///
    /// A group container is named after its group, so a container two installed
    /// applications share resolves to no identifier. The scan needs this set to
    /// keep such a container out of the residue list, and it reads no signature
    /// when there is no group container to decide about.
    ///
    /// The answer carries whether it is the whole set: a read that runs out of
    /// time returns `isComplete == false`, and the request then tells both engines
    /// not to report group-container residue at all for that run. Half a set is
    /// worse than none — every container whose owner went unread would be offered
    /// as a leftover.
    public func declaredAppGroupIdentifiers(
        deadline: Date? = Date().addingTimeInterval(AppGroupRegistry.defaultDeadline)
    ) async -> DeclaredAppGroups {
        let containers = URL(fileURLWithPath: rules.homeDirectory)
            .appendingPathComponent("Library/Group Containers", isDirectory: true)
        let names = (try? fileManager.contentsOfDirectory(atPath: containers.path)) ?? []
        guard !names.isEmpty else { return .empty }
        return appGroups.declaredGroups(deadline: deadline)
    }

    /// Bundle identifiers of every installed application, for residue detection.
    public func installedBundleIdentifiers() async -> [String] {
        // Identifiers only: `installedApplications` measures every bundle, which
        // is the right work for the Apps page and the wrong work before a scan.
        // Measuring 100 applications delayed the scan's first event by tens of
        // seconds while the page still looked idle. The residue check needs the
        // identifier, not the size.
        var identifiers: [String] = []
        var seen = Set<String>()
        for directory in applicationDirectories {
            for url in applicationBundleURLs(in: directory) {
                guard let identifier = Bundle(url: url)?.bundleIdentifier,
                      !identifier.isEmpty,
                      seen.insert(identifier).inserted else { continue }
                identifiers.append(identifier)
            }
        }
        return identifiers
    }

    /// Bundle identifiers LaunchServices can resolve for names that appear in
    /// the residue locations.
    ///
    /// `installedBundleIdentifiers` only searches the fixed application
    /// directories. An application run from `~/Downloads`, an external disk or
    /// `/opt` is not there, so its live container, cache and Application
    /// Support directory would be reported as residue. LaunchServices knows
    /// where every registered application lives; the names found under the
    /// residue roots are resolved through it before the scan starts and added
    /// to the installed set.
    public func residueBundleIdentifiersStillInstalled() -> [String] {
        let home = URL(fileURLWithPath: rules.homeDirectory)
        let locations = [
            "Library/Application Support",
            "Library/Caches",
            "Library/Containers",
            "Library/Logs",
            "Library/Saved Application State",
            "Library/Preferences",
            "Library/HTTPStorages",
            "Library/Group Containers",
        ]
        var installed = Set<String>()
        for relative in locations {
            let directory = home.appendingPathComponent(relative)
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
                continue
            }
            for name in names {
                for reading in BundleNameReadings.identifiers(BundleNameReadings.stem(name))
                where rules.looksLikeBundleIdentifier(reading)
                    && NSWorkspace.shared.urlForApplication(withBundleIdentifier: reading) != nil {
                    installed.insert(reading)
                }
            }
        }
        return Array(installed)
    }

    /// Every `.app` bundle below an application directory.
    ///
    /// Some vendors install one level deeper (`/Applications/Adobe Photoshop
    /// 2024/Adobe Photoshop 2024.app`). Looking only at immediate children left
    /// those applications out of the installed set, so residue detection then
    /// treated their live containers as belonging to an uninstalled app.
    ///
    /// The enumerator does not descend into a bundle, and the depth cap keeps a
    /// stray package tree from turning discovery into a full-disk walk.
    private func applicationBundleURLs(in directory: URL) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isApplicationKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            let depth = url.pathComponents.count - directory.pathComponents.count
            if depth > 3 {
                enumerator.skipDescendants()
                continue
            }
            if url.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                urls.append(url)
                enumerator.skipDescendants()
            }
        }
        return urls
    }
}
