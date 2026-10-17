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

    private let logger = SiftLog.make("App")

    public init(settings: SettingsStore = SettingsStore()) {
        // The rule engine reads the user's rule file only when they enabled it,
        // so a stray file in the data directory cannot change behaviour silently.
        let ruleURL = UserDefaults.standard.bool(forKey: "settings.userRulesEnabled")
            ? SettingsStore.defaultSupportDirectory().appendingPathComponent("CleaningRules.json")
            : nil
        let rules = RuleEngine(userRuleURL: ruleURL)
        let scanner = ScannerEngineFactory.makeDefault(rules: rules)
        let operations = FileOperationService(rules: rules)
        let reports = ReportService()

        self.settings = settings
        self.rules = rules
        self.scanner = scanner
        self.operations = operations
        self.reports = reports
        self.permissions = PermissionsService()
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
    /// needs. Nothing here widens the scope beyond what the user allowed.
    public func makeScanRequest(includeDuplicates: Bool = true) async -> ScanRequest {
        let current = await settings.current()
        let home = FileManager.default.homeDirectoryForCurrentUser

        var roots: [ScanRoot] = [
            ScanRoot(url: home, anchor: .home),
        ]
        for volume in availableVolumes where volume.isExternal && !volume.isReadOnly {
            roots.append(
                ScanRoot(
                    url: volume.mountPoint,
                    anchor: .externalVolume,
                    // An external volume is only scanned because the user added
                    // it to the scope, which is the authorisation §10.1 requires.
                    isCleanable: true,
                    volumeIdentifier: volume.mountPoint.path
                )
            )
        }

        let bundleIdentifiers = await applications.installedBundleIdentifiers()
        return ScanRequest(
            roots: roots,
            largeFileThresholdBytes: current.largeFileThresholdBytes,
            oldFileThresholdDays: current.oldFileThresholdDays,
            staleThresholdDays: current.staleThresholdDays,
            ignoredPaths: current.ignoredPaths,
            installedBundleIdentifiers: bundleIdentifiers,
            includeDuplicates: includeDuplicates,
            duplicateRoots: defaultDuplicateRoots()
        )
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
        roots.append(contentsOf: preferences.authorizedLocations.compactMap(resolveAuthorized))
        return roots
    }

    /// Resolves a security-scoped bookmark into a path.
    ///
    /// A bookmark that no longer resolves is reported by the settings page and
    /// simply left out here, so a moved folder cannot silently expand the scope.
    public func resolveAuthorized(_ location: AuthorizedLocation) -> String? {
        var isStale = false
        let url = try? URL(
            resolvingBookmarkData: location.bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        guard let url, !isStale else { return nil }
        return url.path
    }

    /// True when the user may perform a destructive action.
    public func canClean() async -> Bool {
        await entitlements.allows(.cleanJunk)
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
