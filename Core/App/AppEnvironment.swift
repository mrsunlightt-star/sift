import AppKit
import Foundation
import OSLog
import Shared

/// The app's composition root (§6.3).
///
/// One object owns every service so the wiring is visible in one place, and the
/// UI never constructs a scanner, a file operation or a purchase channel itself.
/// That is what makes the layering real rather than decorative: a view that wants
/// to delete something has to go through this graph, and this graph is where the
/// safety checks live.
@MainActor
public final class AppEnvironment: ObservableObject {
    // Settings and preferences.
    public let settings: SettingsStore
    @Published public private(set) var preferences: AppSettings = .default

    // Domain services.
    public let rules: RuleEngine
    public let scanner: any ScannerEngine
    public let operations: FileOperationService
    public let reports: ReportService
    public let permissions: PermissionsService
    public let entitlements: EntitlementService
    /// The locations the user authorised, shared with the rule engine.
    public let authorizedScope: AuthorizedScope
    public let authorization: AuthorizationService
    public let applications: ApplicationDiscovery
    public let volumes: VolumeEnumerator
    public let storageAnalyzer: StorageAnalyzer

    // Observable state shared by the features.
    public let scan: ScanModel
    public let cleanup: CleanupModel

    /// The diagnostics shown in settings.
    @Published public private(set) var engineKind: ScannerEngineKind
    /// Cached volume list, refreshed when the storage page appears.
    @Published public private(set) var availableVolumes: [VolumeInfo] = []
    /// Cached application list for the uninstaller.
    @Published public private(set) var installedApplications: [InstalledApplication] = []
    @Published public private(set) var isLoadingApplications = false
    /// The entitlement snapshot.
    @Published public private(set) var entitlement = EntitlementState(channel: .direct, status: .free)
    /// Authorised locations, as settings shows them.
    @Published public private(set) var authorizedLocations: [AuthorizedLocation] = []
    /// The grants in force this launch.
    ///
    /// Keyed by identifier, with the resolved URL as the value: availability and
    /// the scan root are two facts about the same grant, and keeping them in step
    /// by hand is what let a re-authorised location appear in settings while this
    /// session had already decided it was unavailable.
    private var grants = GrantRegistry()
    /// The resolved URLs, ordered so a scan request is reproducible.
    private var restoredAuthorizedURLs: [URL] { grants.urls }
    /// Message shown above the result page after an export attempt.
    @Published public private(set) var reportExportMessage: String?

    private let logger = SiftLog.make("App")

    public init(settings: SettingsStore = SettingsStore()) {
        // The rule engine reads the user's rule file only when they enabled it,
        // so a stray file in the data directory cannot change behaviour silently.
        let ruleURL = UserDefaults.standard.bool(forKey: "settings.userRulesEnabled")
            ? SettingsStore.defaultSupportDirectory().appendingPathComponent("CleaningRules.json")
            : nil
        let authorizedScope = AuthorizedScope()
        let rules = RuleEngine(userRuleURL: ruleURL, authorized: authorizedScope)
        let scanner = ScannerEngineFactory.makeDefault(rules: rules)
        let operations = FileOperationService(rules: rules)
        let reports = ReportService()

        self.settings = settings
        self.rules = rules
        self.scanner = scanner
        self.operations = operations
        self.reports = reports
        self.permissions = PermissionsService()
        self.authorizedScope = authorizedScope
        self.authorization = AuthorizationService(scope: authorizedScope) { url in
            // The allowlist lives in the rule engine, so the settings page and
            // the service that stores bookmarks give the same answer.
            rules.canAuthorize(url: url)
        }
        self.entitlements = EntitlementService(channel: DirectLicenseService { _ in
            // No license vendor is wired yet; the specification leaves the choice
            // open (§19). Until then every activation reports that the service is
            // unreachable, which is the honest answer, and the free tier keeps
            // working because a failed check never locks a user out.
            throw PurchaseError.licenseServiceUnavailable
        })
        self.applications = ApplicationDiscovery(rules: rules)
        self.volumes = VolumeEnumerator(rules: rules)
        self.storageAnalyzer = StorageAnalyzer(rules: rules)
        self.scan = ScanModel(engine: scanner, rules: rules)
        self.cleanup = CleanupModel(rules: rules, operations: operations, reports: reports)
        self.engineKind = scanner.kind

        logger.info("Environment ready (engine=\(scanner.kind.rawValue, privacy: .public))")
    }

    /// Re-reads the entitlement from the purchase channel.
    public func refreshEntitlement() async {
        await entitlements.refresh()
        entitlement = await entitlements.current()
    }

    /// Loads preferences and the initial data the shell needs.
    public func bootstrap() async {
        preferences = await settings.current()
        availableVolumes = volumes.mountedVolumes()

        // Reopen the user's grants before anything can scan. A bookmark that no
        // longer resolves is dropped, and the settings page shows the remainder.
        authorizedLocations = preferences.authorizedLocations
        await applyRestored(await authorization.restore(preferences.authorizedLocations))

        entitlement = await entitlements.current()
        await entitlements.refresh()
        entitlement = await entitlements.current()
        await settings.removeObsoleteRuleFlagIfNeeded()
    }

    /// Republishes settings after the user changes something.
    public func updateSettings(_ mutate: @Sendable (inout AppSettings) -> Void) async {
        await settings.update(mutate)
        preferences = await settings.current()
    }

    /// Refreshes the volume list.
    public func refreshVolumes() {
        availableVolumes = volumes.mountedVolumes()
    }

    /// Loads the installed applications, once per session unless forced.
    public func loadApplications(force: Bool = false) async {
        guard !isLoadingApplications else { return }
        if !force, !installedApplications.isEmpty { return }
        isLoadingApplications = true
        installedApplications = await applications.installedApplications()
        isLoadingApplications = false
    }

    /// Clears the application cache so a new uninstall scan sees the change.
    public func invalidateApplications() {
        installedApplications = []
    }

    /// Builds the scan request the engine will run.
    ///
    /// This is where preferences become a request: thresholds, ignore list,
    /// duplicate scope and the installed bundle identifiers the residue scan
    /// needs.
    ///
    /// The scope is deliberately narrow. The home directory is the only implicit
    /// root; a second volume is included only when the user added it in settings,
    /// and then only through the bookmark that records that grant (§10.1). Sift
    /// never enumerates mount points and decides for itself that they look
    /// interesting.
    public func makeScanRequest(includeDuplicates: Bool = true) async -> ScanRequest {
        let current = await settings.current()
        let home = FileManager.default.homeDirectoryForCurrentUser

        var roots: [ScanRoot] = [
            ScanRoot(url: home, anchor: .home),
        ]
        for url in restoredAuthorizedURLs {
            roots.append(
                ScanRoot(
                    url: url,
                    anchor: .externalVolume,
                    isCleanable: true,
                    volumeIdentifier: url.path
                )
            )
        }

        let bundleIdentifiers = await applications.installedBundleIdentifiers()
        return ScanRequest(
            homeDirectory: home,
            roots: roots,
            largeFileThresholdBytes: current.largeFileThresholdBytes,
            oldFileThresholdDays: current.oldFileThresholdDays,
            staleThresholdDays: current.staleThresholdDays,
            ignoredPaths: current.ignoredPaths,
            authorizedRoots: restoredAuthorizedURLs.map(\.path),
            installedBundleIdentifiers: bundleIdentifiers,
            includeDuplicates: includeDuplicates,
            duplicateRoots: defaultDuplicateRoots()
        )
    }

    /// Adds a folder or volume the user picked in a file panel.
    @discardableResult
    public func authorizeLocation(_ url: URL) async -> AuthorizedLocation? {
        // A grant must not turn user content into a cleanup target. Volumes and
        // system cache trees are exactly what authorisation exists for; Documents,
        // keychains and a photo library are refused even when picked by hand.
        guard rules.canAuthorize(url: url) else {
            SiftLog.permissions.notice("Refused to authorise a protected location")
            return nil
        }
        guard let grant = await authorization.authorize(url) else { return nil }
        // The service resolves symlinks; the panel's URL is what the user clicked,
        // not what the grant covers. Everything downstream — the scan roots, the
        // duplicate roots, the deduplication below — has to use the resolved one.
        let resolved = grant.url

        // One row per location. A second grant for a folder that is already
        // authorised replaces the stored bookmark under the existing identifier
        // rather than adding a row that would report itself unavailable.
        let replacing = grants.identifier(forResolvedPath: resolved.path)
        let stored = replacing.map { id in
            AuthorizedLocation(
                id: id,
                bookmark: grant.location.bookmark,
                displayName: grant.location.displayName,
                isVolume: grant.location.isVolume,
                addedAt: authorizedLocations.first { $0.id == id }?.addedAt ?? Date()
            )
        } ?? grant.location

        await settings.update { settings in
            if let index = settings.authorizedLocations.firstIndex(where: { $0.id == stored.id }) {
                settings.authorizedLocations[index] = stored
            } else {
                settings.authorizedLocations.append(stored)
            }
        }
        preferences = await settings.current()
        authorizedLocations = preferences.authorizedLocations
        grants.remember(stored.id, url: resolved)
        return stored
    }

    /// Removes an authorised location and releases its access.
    public func removeAuthorizedLocation(_ location: AuthorizedLocation) async {
        await settings.update { settings in
            settings.authorizedLocations.removeAll { $0.id == location.id }
        }
        preferences = await settings.current()
        authorizedLocations = preferences.authorizedLocations
        // Release every open access before reopening the remainder: otherwise the
        // removed location's security scope stays open for the process lifetime.
        await authorization.releaseAll()
        await applyRestored(await authorization.restore(preferences.authorizedLocations))
    }

    /// Where the duplicate scan looks by default (§5.5).
    ///
    /// Downloads, Desktop and any authorised folder: never the system
    /// directories, and never a path the user did not add.
    public func defaultDuplicateRoots() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots = ["Downloads", "Desktop"]
            .map { home.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map(\.path)
        roots.append(contentsOf: restoredAuthorizedURLs.map(\.path))
        return roots
    }

    /// True when this stored bookmark resolved at launch and could be opened.
    public func isAvailable(_ location: AuthorizedLocation) -> Bool {
        grants.isAvailable(location.id)
    }

    /// Records which bookmarks resolved and persists any that were refreshed.
    private func applyRestored(_ restored: RestoredGrants) async {
        grants = GrantRegistry(restored.locations)

        var locations = await settings.current().authorizedLocations
        var changed = false
        for entry in restored.locations {
            guard let refreshed = entry.refreshedBookmark,
                  let index = locations.firstIndex(where: { $0.id == entry.id }) else { continue }
            let existing = locations[index]
            locations[index] = AuthorizedLocation(
                id: existing.id,
                bookmark: refreshed,
                displayName: existing.displayName,
                isVolume: existing.isVolume,
                addedAt: existing.addedAt
            )
            changed = true
        }
        if !restored.refused.isEmpty {
            // A stored grant the allowlist no longer accepts is removed rather
            // than kept as an unavailable row: it can never be honoured again, and
            // leaving it stored is what would let a future build restore it.
            locations.removeAll { restored.refused.contains($0.id) }
            changed = true
        }
        if changed {
            let updated = locations
            await settings.update { $0.authorizedLocations = updated }
            preferences = await settings.current()
            authorizedLocations = preferences.authorizedLocations
        }
    }

    /// True when the user may perform a destructive action.
    public func canClean() async -> Bool {
        await entitlements.allows(.cleanJunk)
    }

    /// True when the user may export a report (§12.2).
    public func canExportReports() async -> Bool {
        await entitlements.allows(.exportReports)
    }

    /// Writes the report as a PDF at the location the user picks.
    ///
    /// The local copy already exists, so a failed export leaves a report behind
    /// and the message says so (§5.7).
    public func exportReport(_ report: CleanupReport) async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Sift-Report.pdf"
        panel.allowedContentTypes = [.pdf]
        panel.message = LocalizationKey.reportPrivacyNote.localized
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try await reports.exportPDF(
                report,
                to: url,
                title: LocalizationKey.reportTitle.localized
            )
            reportExportMessage = nil
        } catch {
            reportExportMessage = LocalizationKey.reportExportFailed.localized
        }
    }

    /// Clears the export message when the result page closes.
    public func clearReportExportMessage() {
        reportExportMessage = nil
    }

    /// Reveals a file or folder in the Finder.
    public func reveal(_ url: URL) async {
        await WorkspaceActions.reveal(url)
    }

    /// Opens the Trash.
    public func openTrash() async {
        await WorkspaceActions.openTrash()
    }

    /// Opens the Full Disk Access pane.
    public func openPermissionSettings() async {
        await permissions.openFullDiskAccessSettings()
    }
}

extension SettingsStore {
    /// Reserved for preference keys that move between versions.
    func removeObsoleteRuleFlagIfNeeded() async {
        // `settings.userRulesEnabled` predates the settings migration; the value
        // is read once at launch and now lives in `AppSettings`.
    }
}
