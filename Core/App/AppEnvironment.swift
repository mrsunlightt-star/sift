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
    //
    // The rule-dependent services are replaceable because the user-rule switch
    // is a runtime setting: the engines read the rule table when they are
    // created, so changing the table without rebuilding them left the old rules
    // running until the next launch.
    public private(set) var rules: RuleEngine
    public private(set) var scanner: any ScannerEngine
    public private(set) var operations: FileOperationService
    public let reports: ReportService
    public let permissions: PermissionsService
    public let entitlements: EntitlementService
    /// The locations the user authorised, shared with the rule engine.
    public let authorizedScope: AuthorizedScope
    public let authorization: AuthorizationService
    public private(set) var applications: ApplicationDiscovery
    public private(set) var volumes: VolumeEnumerator
    public private(set) var storageAnalyzer: StorageAnalyzer
    /// The read-only diagnostics. It shares the rule engine, so a location that is
    /// protected for a scan is protected here too.
    public let diagnostics: StorageDiagnosticEngine

    // Observable state shared by the features.
    @Published public private(set) var scan: ScanModel
    @Published public private(set) var cleanup: CleanupModel
    /// The storage page's last result and its running state. Owned here so
    /// leaving the page neither loses the result nor starts another analysis.
    public let storageAnalysis: StorageAnalysisModel

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
    /// True while the scan request is being assembled, before the engine has a
    /// session.
    ///
    /// Building the request reads the installed applications, which is slower
    /// than starting the engine. Without this the page looked idle after the
    /// user pressed Start, and a second press could start a second run.
    @Published public private(set) var isPreparingScan = false

    /// A user-rule change that arrived while a scan or cleanup was in flight.
    /// The next scan rebuilds the engines before it starts.
    private var pendingRuleReload = false

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
        self.diagnostics = StorageDiagnosticEngine()
        self.scan = ScanModel(engine: scanner, rules: rules)
        self.cleanup = CleanupModel(rules: rules, operations: operations, reports: reports)
        self.storageAnalysis = StorageAnalysisModel()
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
        let previous = await settings.current()
        await settings.update(mutate)
        preferences = await settings.current()

        // The engines read the rule table when they are created, so a change to
        // the user-rule switch has to rebuild them. Deferred while a scan or a
        // cleanup owns the old services; `runScan` applies it before it starts.
        if preferences.userRulesEnabled != previous.userRulesEnabled {
            await reloadUserRulesWhenIdle()
        }
    }

    /// Rebuilds every service that holds a `RuleEngine`.
    ///
    /// The scanner and the file-operation service do not share one mutable rule
    /// object: each owns a value copy. Replacing them together is what keeps the
    /// discovery rules and the pre-flight checks describing the same table.
    private func rebuildRuleDependentServices() async {
        let userRuleURL = preferences.userRulesEnabled ? await settings.userRuleURL() : nil
        let rules = RuleEngine(userRuleURL: userRuleURL, authorized: authorizedScope)
        let scanner = ScannerEngineFactory.makeDefault(rules: rules)
        let operations = FileOperationService(rules: rules)

        self.rules = rules
        self.scanner = scanner
        self.operations = operations
        self.applications = ApplicationDiscovery(rules: rules)
        self.volumes = VolumeEnumerator(rules: rules)
        self.storageAnalyzer = StorageAnalyzer(rules: rules)
        // The models are replaced as well: a result produced by the old table
        // must not stay selectable under the new one.
        self.scan = ScanModel(engine: scanner, rules: rules)
        self.cleanup = CleanupModel(rules: rules, operations: operations, reports: reports)
        self.engineKind = scanner.kind
    }

    private func reloadUserRulesWhenIdle() async {
        guard !isPreparingScan, !scan.isRunning, !cleanup.isWorking else {
            pendingRuleReload = true
            return
        }
        pendingRuleReload = false
        await rebuildRuleDependentServices()
    }

    /// The one way the interface changes language.
    ///
    /// The synchronous write is what lets `LocalizationKey.localized` return the
    /// new language in the same render pass; the settings update is what makes
    /// the choice survive a relaunch. Every control calls this, so there is no
    /// second place that could store the preference differently.
    public func selectLanguage(_ language: SiftLanguage) {
        SiftLanguage.persistSelection(language)
        Task {
            await updateSettings { $0.language = language }
        }
    }

    /// Runs the storage page's analysis on request.
    ///
    /// Nothing calls this when the page appears: the page shows the scope and
    /// waits for the user's button. The result stays on `storageAnalysis`, so
    /// returning to the page shows it again instead of starting another run.
    public func analyzeStorage() async {
        guard let flag = storageAnalysis.begin() else { return }
        defer { storageAnalysis.abortIfStillRunning() }

        let analyzer = storageAnalyzer
        let diagnostics = diagnostics
        let rules = rules
        let home = URL(fileURLWithPath: rules.homeDirectory)
        let request = await makeScanRequest(includeDuplicates: false)
        let roots = Self.storageAnalysisRoots(home: home, roots: request.roots)
        let ignoredPaths = request.ignoredPaths
        let diagnosticRoots = diagnosticRoots(includeVolumeRoot: storageAnalysis.includeVolumeRoot)

        let task = Task(priority: .userInitiated) { () -> Void in
            let measured: StorageAnalysis
            do {
                measured = try await analyzer.analyze(
                    roots: roots,
                    ignoredPaths: ignoredPaths,
                    cancelled: { flag.isCancelled }
                )
            } catch {
                guard !flag.isCancelled else {
                    await MainActor.run { self.storageAnalysis.recordCancellation() }
                    return
                }
                // A failed measurement is not an empty disk. The page keeps the
                // last good result and reports this run's failure instead of
                // presenting `.empty` as a finished analysis.
                let failure = Self.storageFailure(for: error)
                await MainActor.run { self.storageAnalysis.recordFailure(failure) }
                return
            }
            guard !flag.isCancelled else {
                await MainActor.run { self.storageAnalysis.recordCancellation() }
                return
            }
            let diagnosed = await diagnostics.analyze(
                roots: diagnosticRoots,
                homeDirectory: home,
                rules: rules,
                isCancelled: { flag.isCancelled }
            )
            guard !flag.isCancelled else {
                await MainActor.run { self.storageAnalysis.recordCancellation() }
                return
            }
            await MainActor.run {
                self.storageAnalysis.finish(analysis: measured, report: diagnosed)
            }
        }
        await task.value
    }

    /// Maps a measurement error onto the sentence the page shows.
    ///
    /// The storage walk only throws when it cannot read the volume's metadata,
    /// so the useful distinctions are access, a missing volume and everything
    /// else. The previous code discarded the error entirely.
    private static func storageFailure(for error: Error) -> StorageAnalysisFailure {
        let code = FileOperationService.classify(error)
        let message: LocalizationKey
        switch code {
        case .permissionDenied:
            message = .storageNoAccess
        case .volumeUnavailable, .fileNotFound:
            message = .storageDiskDisconnected
        default:
            message = .commonUnknownError
        }
        return StorageAnalysisFailure(code: code, message: message.localized)
    }

    /// Stops a storage analysis that is in flight. The last completed result, if
    /// any, stays on screen.
    public func cancelStorageAnalysis() {
        storageAnalysis.cancel()
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
            // A grant inside the home folder is already covered by the home
            // root. Adding it again would walk the same tree twice — and, for
            // the threshold scans, offer every file in it twice.
            if RuleEngine.isPrefix(home.path, url.path) { continue }
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
            // The preference is a scan scope, so it is applied by the engines
            // rather than filtered out of the list afterwards.
            includeHiddenFiles: current.showHiddenFiles,
            includeDuplicates: includeDuplicates,
            // Sorted and deduplicated, including nested roots: a granted folder
            // inside `~/Downloads` is already covered by `~/Downloads`, and
            // walking both would report one file twice.
            duplicateRoots: Self.nonOverlappingDuplicateRoots(defaultDuplicateRoots()),
            // The Rust core only reads rule JSON; it has no access to this
            // engine's rule list. Without this the two engines ran different
            // rule sets and a user's own rule was honoured by the Swift
            // fallback but ignored by the shipped scanner.
            extraRulesJSON: rules.userRulesJSON
        )
    }

    /// The one way a scan is started (§5.1-§5.5).
    ///
    /// The pages differ in what they ask for and in what they load afterwards,
    /// not in how a scan runs. Keeping that here is what makes the gates agree:
    /// `scan.hasResults` means the same thing whichever page started the run.
    public func runScan(_ intent: ScanIntent) async {
        // One run at a time. A second request while the first is assembling its
        // request (or scanning) would put two runs' phases on one page, and a
        // cleanup in flight owns the current selection the scan would reset.
        guard !isPreparingScan, !scan.isRunning, !cleanup.isWorking else { return }

        if pendingRuleReload {
            pendingRuleReload = false
            await rebuildRuleDependentServices()
        }

        // Capture the pair: rebuilding the services replaces both, and the run
        // that is already under way must finish against the objects it started
        // with rather than writing its result into the new ones.
        let scan = self.scan
        let cleanup = self.cleanup
        cleanup.resetForNewScan()
        isPreparingScan = true
        let request = await makeScanRequest(includeDuplicates: intent.includesDuplicates)
        await scan.start(request)
        // The engine has a session now; the phase it reports is the truth.
        isPreparingScan = false
        // `start` only means the engine accepted the request. Paging and the
        // duplicate index are ready when the run reaches a terminal phase; asked
        // earlier they answer with an empty or partial result, and the first
        // screenful — including which items are pre-selected — would describe a
        // scan that had not finished.
        await scan.waitUntilSettled()
        if intent.includesDuplicates {
            await scan.loadDuplicateGroups()
        }
        let page = await scan.page(
            offset: 0,
            limit: 200,
            sort: .size,
            category: intent.category
        )
        cleanup.setItems(page.items.map { $0.asCleanupItem() }, preselect: intent.preselectsItems)
        // After the page is usable: reading the whole index for the risk split
        // must not delay the result page. The overview states the split when it
        // arrives.
        await scan.loadRiskTotals()
        // A cancelled or failed run is not a scan history entry: the page never
        // showed it as a result, and recording it would claim a completed scan
        // that the user stopped.
        if scan.phase == .ready || scan.phase == .partial {
            RecentHistory.recordScan()
        }
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
        return Self.nonOverlappingDuplicateRoots(roots)
    }

    /// The roots a storage analysis may measure.
    ///
    /// The page reports one volume's used/free figures. Measuring a folder on a
    /// different volume at the same time put another disk's bytes into those
    /// figures, so the analysis is limited to the home folder's volume. Nested
    /// roots are collapsed: walking both `~` and `~/Downloads` counted the same
    /// file twice.
    static func storageAnalysisRoots(home: URL, roots: [ScanRoot]) -> [ScanRoot] {
        let volume = home.resolvingSymlinksInPath().volumeRoot.path
        let eligible = roots.filter {
            $0.url.resolvingSymlinksInPath().volumeRoot.path == volume
        }
        guard !eligible.isEmpty else {
            return [ScanRoot(url: home, anchor: .home)]
        }
        let paths = nonOverlappingDuplicateRoots(eligible.map(\.url.path))
        return paths.map { path in
            eligible.first { RuleEngine.normalize($0.url.path) == path }
                ?? ScanRoot(url: URL(fileURLWithPath: path), anchor: .home)
        }
    }

    /// Drops duplicate and nested roots, keeping the outermost one.
    ///
    /// The duplicate scan walks every root it is given, so a granted folder
    /// inside `~/Downloads` must not be searched a second time: the same file
    /// would enter the size index twice and could be reported as a duplicate of
    /// itself, with reclaimable space counted twice.
    static func nonOverlappingDuplicateRoots(_ roots: [String]) -> [String] {
        let normalised = Set(roots.map(RuleEngine.normalize))
        let ordered = normalised.sorted { first, second in
            let firstDepth = first.split(separator: "/").count
            let secondDepth = second.split(separator: "/").count
            return firstDepth == secondDepth ? first < second : firstDepth < secondDepth
        }
        var kept: [String] = []
        for path in ordered {
            if kept.contains(where: { RuleEngine.isPrefix($0, path) }) { continue }
            kept.append(path)
        }
        return kept.sorted()
    }

    /// Where the diagnostics look.
    ///
    /// The home folder and the locations the user granted, plus — only when the
    /// user asks for it — the root of the volume they are on. Nothing else: the
    /// analysis widens what the product can see, so its scope has to be as
    /// explicit as the scan scope is (§7).
    public func diagnosticRoots(includeVolumeRoot: Bool) -> [DiagnosticRoot] {
        var roots = [DiagnosticRoot(url: URL(fileURLWithPath: rules.homeDirectory), kind: .home)]
        for location in authorizedLocations {
            guard let url = grants.url(for: location.id) else { continue }
            // A grant for a whole disk is a volume the diagnostics may look at;
            // a granted folder is just a folder.
            roots.append(DiagnosticRoot(url: url, kind: location.isVolume ? .volume : .authorized))
        }
        if includeVolumeRoot, !roots.contains(where: { $0.kind == .volume }) {
            roots.append(DiagnosticRoot(url: URL(fileURLWithPath: "/"), kind: .volume))
        }
        return roots
    }

    /// Restores every setting to its default.
    ///
    /// Authorisation is part of the settings: releasing the stored grants only
    /// in the settings store left the scan scope and the settings rows using the
    /// old grants until the next launch.
    public func resetSettings() async {
        // A cleanup owns a pre-flighted batch; resetting underneath it would
        // lose the result while the move is still running. A request being
        // assembled owns the old models in the same way.
        guard !cleanup.isWorking, !isPreparingScan else { return }
        if scan.isRunning {
            await scan.cancel()
        }

        await settings.resetToDefaults()
        preferences = await settings.current()

        await authorization.releaseAll()
        grants = GrantRegistry()
        authorizedLocations = []
        pendingRuleReload = false
        await rebuildRuleDependentServices()
    }

    /// True when a licence key is stored on this machine.
    public func hasStoredLicense() async -> Bool {
        await entitlements.hasStoredLicense()
    }

    /// Removes the stored licence key and returns to the free tier.
    public func removeStoredLicense() async {
        entitlement = await entitlements.removeStoredLicense()
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
            guard let index = locations.firstIndex(where: { $0.id == entry.id }) else { continue }
            let existing = locations[index]
            // A bookmark written by an older build carries that build's idea of
            // whether the location was a whole volume. The resolved path decides
            // now, so a folder inside an external disk stops being reported as
            // the disk itself.
            let isVolume = AuthorizationService.describesVolume(entry.url)
            let bookmark = entry.refreshedBookmark ?? existing.bookmark
            if entry.refreshedBookmark != nil || existing.isVolume != isVolume {
                locations[index] = AuthorizedLocation(
                    id: existing.id,
                    bookmark: bookmark,
                    displayName: existing.displayName,
                    isVolume: isVolume,
                    addedAt: existing.addedAt
                )
                changed = true
            }
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

    /// Asks the running application at `url` to quit.
    ///
    /// Returns `false` when it is not running or the request could not be sent.
    /// The caller shows that, because a button labelled "Quit" must not silently
    /// do something else.
    @discardableResult
    public func quitApplication(_ url: URL) async -> Bool {
        await WorkspaceActions.quitApplication(bundlePath: url)
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
