import AppKit
import Core
import Shared
import SwiftUI

/// Settings (§5.6).
///
/// Grouped exactly as the specification lists them, with one rule the spec calls
/// out explicitly: "skip confirmation" is off by default and turning it on shows
/// what the user is giving up.
public struct SettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var permissionReport: [PermissionsService.LocationAccess] = []
    @State private var exportMessage: String?
    @State private var permissionHint = false
    /// The explanation, before the system dialog: macOS's own prompt cannot say
    /// why an app wants the permission, so the app has to.
    @State private var isExplainingPermission = false
    /// Reset clears settings and every granted folder, so it asks once.
    @State private var isConfirmingReset = false
    /// Read from the system, never from `UserDefaults`: the login item is the
    /// system's registration, and a cached boolean drifts the moment the user
    /// removes it in System Settings.
    @State private var loginItemEnabled = LoginItem.isEnabled
    @State private var hasStoredLicense = false
    @State private var isConfirmingReportDeletion = false
    /// The coverage audit's page, opened from the diagnostics group.
    @State private var isShowingCoverage = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            SiftPageHeader(title: LocalizationKey.settingsTitle.localized, status: headerStatus) {
                SiftMetricPill(
                    symbolName: environment.entitlement.isUnlocked ? "checkmark.seal.fill" : "lock.open",
                    value: (environment.entitlement.isUnlocked
                        ? LocalizationKey.purchaseStatusPurchased
                        : LocalizationKey.purchaseStatusFree).localized,
                    tone: environment.entitlement.isUnlocked ? .safe : .accent
                )
            }

            ScrollView {
                VStack(alignment: .leading, spacing: SiftMetrics.pageSpacing) {
                    scanScopeSection
                    authorizedSection
                    thresholdsSection
                    confirmationSection
                    appearanceSection
                    privacySection
                    purchaseSection
                    diagnosticsSection
                    coverageSection
                }
                .padding(.horizontal, SiftMetrics.pagePadding)
                .padding(.vertical, SiftMetrics.pageSpacing)
                .frame(maxWidth: SiftMetrics.contentWidthForm, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .task {
            permissionReport = await environment.permissions.accessReport()
            hasStoredLicense = await environment.hasStoredLicense()
        }
    }

    private var headerStatus: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
        return LocalizationKey.settingsHeaderStatus.localized(version)
    }

    // MARK: - Scan scope

    private var scanScopeSection: some View {
        SettingsGroup(titleKey: .settingsGroupScanScope) {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                ForEach(environment.availableVolumes) { volume in
                    HStack(spacing: SiftMetrics.spacingM) {
                        Image(systemName: volume.isExternal ? "externaldrive" : "internaldrive")
                            .foregroundStyle(volume.isExternal ? SiftColor.review : SiftColor.neutral)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(volume.name)
                                .font(SiftFont.body)
                            Text(LocalizationKey.dashboardDiskFree.localized(volume.formattedFree))
                                .font(SiftFont.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if volume.isReadOnly {
                            Text(LocalizationKey.commonNotAvailable.localized)
                                .font(SiftFont.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }

                Divider()

                Toggle(isOn: Binding(
                    get: { environment.preferences.showHiddenFiles },
                    set: { value in Task { await environment.updateSettings { $0.showHiddenFiles = value } } }
                )) {
                    Text(LocalizationKey.settingsIncludeHidden.localized)
                        .font(SiftFont.body)
                }
                .toggleStyle(.checkbox)

                Toggle(isOn: Binding(
                    get: { environment.preferences.userRulesEnabled },
                    set: { value in Task { await environment.updateSettings { $0.userRulesEnabled = value } } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalizationKey.settingsUserRules.localized)
                            .font(SiftFont.body)
                        Text(LocalizationKey.settingsUserRulesDetail.localized)
                            .font(SiftFont.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.checkbox)

                // The interface's own type scale. macOS has no system setting for
                // it, so a fixed 13 pt ladder was the whole answer to a user who
                // cannot read it.
                Picker(
                    LocalizationKey.settingsTextSize.localized,
                    selection: Binding(
                        get: { environment.preferences.textScale },
                        set: { value in
                            SiftTypeScale.current = Self.step(for: value)
                            Task { await environment.updateSettings { $0.textScale = value } }
                        }
                    )
                ) {
                    ForEach(AppSettings.TextScale.allCases, id: \.self) { scale in
                        Text(scale.titleKey.localized).tag(scale)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
                .accessibilityIdentifier("settings.textSize")

                if LoginItem.isSupported {
                    Toggle(isOn: Binding(
                        get: { loginItemEnabled },
                        set: { value in loginItemEnabled = LoginItem.set(enabled: value) }
                    )) {
                        Text(LocalizationKey.settingsLaunchAtLogin.localized)
                            .font(SiftFont.body)
                    }
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("settings.launchAtLogin")
                }

                Stepper(
                    value: Binding(
                        get: { environment.preferences.keepScanHistory },
                        set: { value in
                            Task { await environment.updateSettings { $0.keepScanHistory = value } }
                        }
                    ),
                    in: 5...50,
                    step: 5
                ) {
                    HStack(spacing: SiftMetrics.spacingS) {
                        Text(LocalizationKey.settingsKeepHistory.localized)
                            .font(SiftFont.body)
                        Text("\(environment.preferences.keepScanHistory)")
                            .font(SiftFont.monospacedNumber)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                Text(LocalizationKey.settingsGroupIgnores.localized)
                    .font(SiftFont.bodyEmphasis)
                if environment.preferences.ignoredPaths.isEmpty {
                    Text(LocalizationKey.settingsIgnoreEmpty.localized)
                        .font(SiftFont.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: SiftMetrics.spacingXS) {
                        ForEach(environment.preferences.ignoredPaths, id: \.self) { path in
                            HStack {
                                Text(CleanupItem.abbreviate(path))
                                    .font(SiftFont.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                SiftIconButton(
                                    symbolName: "minus.circle",
                                    help: LocalizationKey.commonRemove.localized
                                ) {
                                    Task {
                                        await environment.updateSettings { settings in
                                            settings.ignoredPaths.removeAll { $0 == path }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                Button {
                    addIgnoredFolder()
                } label: {
                    Text(LocalizationKey.settingsAddFolder.localized)
                        .font(SiftFont.caption)
                }
                .buttonStyle(SiftLinkButtonStyle())
                .accessibilityIdentifier("settings.addIgnoredFolder")

                Divider()

                permissionRows
            }
        }
    }

    static func step(for scale: AppSettings.TextScale) -> SiftTypeScale.Step {
        switch scale {
        case .small: .small
        case .standard: .standard
        case .large: .large
        }
    }

    /// Adds one folder to the ignore list.
    ///
    /// The list existed only as a place entries could be removed from: nothing
    /// ever put one in, so the rule it feeds never had anything to apply to.
    private func addIgnoredFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = LocalizationKey.settingsAddFolder.localized
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Home-relative, the way every other path in the product is stored.
        let stored = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        Task {
            await environment.updateSettings { settings in
                guard !settings.ignoredPaths.contains(stored) else { return }
                settings.ignoredPaths.append(stored)
            }
        }
    }

    private var permissionRows: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
            Text(LocalizationKey.permissionFullDiskAccess.localized)
                .font(SiftFont.bodyEmphasis)
            Text(LocalizationKey.permissionFullDiskAccessDetail.localized)
                .font(SiftFont.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(permissionReport) { location in
                HStack(spacing: SiftMetrics.spacingS) {
                    Image(systemName: location.isReadable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(location.isReadable ? SiftColor.safe : SiftColor.review)
                        .accessibilityHidden(true)
                    Text(location.title)
                        .font(SiftFont.caption)
                    Spacer()
                    Text(
                        location.isReadable
                            ? LocalizationKey.commonDone.localized
                            : LocalizationKey.permissionPartialAccess.localized
                    )
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            Divider()
                .padding(.vertical, SiftMetrics.spacingXS)
            // Moving another developer's application bundle is a different
            // switch from reading a protected folder, and the two are confused
            // easily — the uninstaller's failed row offered Full Disk Access for
            // exactly this refusal. Stated here, next to the reading
            // permissions, so "I already granted everything" has an answer.
            HStack(spacing: SiftMetrics.spacingS) {
                Image(systemName: environment.appManagement == .denied
                    ? "exclamationmark.triangle.fill"
                    : "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(environment.appManagement == .denied ? SiftColor.review : SiftColor.safe)
                    .accessibilityHidden(true)
                Text(LocalizationKey.appManagementTitle.localized)
                    .font(SiftFont.caption)
                Spacer()
                Text(
                    environment.appManagement == .granted
                        ? LocalizationKey.commonDone.localized
                        : LocalizationKey.commonNotAvailable.localized
                )
                .font(SiftFont.caption)
                .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: SiftMetrics.spacingM) {
                Button {
                    Task { await environment.openAppManagementSettings() }
                } label: {
                    Text(LocalizationKey.permissionOpenSettings.localized)
                        .font(SiftFont.caption)
                }
                .buttonStyle(SiftLinkButtonStyle())
                .accessibilityIdentifier("settings.appManagementOpen")
                Button {
                    Task { await environment.recheckAppManagement() }
                } label: {
                    Text(LocalizationKey.appManagementRecheck.localized)
                        .font(SiftFont.caption)
                }
                .buttonStyle(SiftLinkButtonStyle())
                .accessibilityIdentifier("settings.appManagementRecheck")
            }

            Button {
                isExplainingPermission = true
            } label: {
                Text(LocalizationKey.permissionOpenSettings.localized)
                    .font(SiftFont.caption)
            }
            .buttonStyle(SiftLinkButtonStyle())
            .accessibilityIdentifier("settings.permissionExplain")
            if permissionHint {
                Text(LocalizationKey.permissionOpenedSettings.localized)
                    .font(SiftFont.caption)
                    .foregroundStyle(SiftColor.subtleText)
            }
        }
        .sheet(isPresented: $isExplainingPermission) {
            FullDiskAccessSheet(
                onOpenSettings: {
                    isExplainingPermission = false
                    Task {
                        await environment.openPermissionSettings()
                        permissionHint = true
                    }
                },
                onDismiss: { isExplainingPermission = false }
            )
        }
    }


    // MARK: - Authorised folders

    /// The one place a folder or volume is granted.
    ///
    /// It used to live on the duplicate page as well, which meant two different
    /// lists of the same grants and two ways to change them. Every page that
    /// depends on a grant links here instead.
    private var authorizedSection: some View {
        SettingsGroup(titleKey: .settingsGroupAuthorized) {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                if environment.authorizedLocations.isEmpty {
                    Text(LocalizationKey.settingsAuthorizedEmpty.localized)
                        .font(SiftFont.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(environment.authorizedLocations) { location in
                        HStack(spacing: SiftMetrics.spacingM) {
                            Image(systemName: location.isVolume ? "externaldrive" : "folder")
                                .foregroundStyle(SiftColor.accentText)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(location.displayName)
                                    .font(SiftFont.body)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if !environment.isAvailable(location) {
                                    Text(LocalizationKey.settingsAuthorizedUnavailable.localized)
                                        .font(SiftFont.caption)
                                        .foregroundStyle(SiftColor.review)
                                }
                            }
                            Spacer(minLength: SiftMetrics.spacingS)
                            SiftIconButton(
                                symbolName: "minus.circle",
                                help: LocalizationKey.commonRemove.localized
                            ) {
                                Task { await environment.removeAuthorizedLocation(location) }
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }

                Button {
                    addAuthorizedLocations()
                } label: {
                    Label(LocalizationKey.filesAddFolder.localized, systemImage: "folder.badge.plus")
                }
            }
        }
    }

    /// Opens the system panel. A volume can be reached by navigating to
    /// `/Volumes`, which is how macOS exposes disks to a folder picker.
    private func addAuthorizedLocations() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = LocalizationKey.filesAddFolder.localized
        panel.message = LocalizationKey.filesRequiresAuthorization.localized
        panel.directoryURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)

        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task {
            for url in urls {
                await environment.authorizeLocation(url)
            }
        }
    }

    // MARK: - Thresholds

    private var thresholdsSection: some View {
        SettingsGroup(titleKey: .settingsGroupThresholds) {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                ThresholdRow(
                    titleKey: .settingsLargeFileThreshold,
                    value: SiftFormat.bytes(environment.preferences.largeFileThresholdBytes),
                    options: [
                        (500 * 1024 * 1024, SiftFormat.bytes(500 * 1024 * 1024)),
                        (1024 * 1024 * 1024, SiftFormat.bytes(1024 * 1024 * 1024)),
                        (2048 * 1024 * 1024, SiftFormat.bytes(2048 * 1024 * 1024)),
                        (5120 * 1024 * 1024, SiftFormat.bytes(5120 * 1024 * 1024)),
                    ],
                    selected: environment.preferences.largeFileThresholdBytes
                ) { bytes in
                    Task { await environment.updateSettings { $0.largeFileThresholdBytes = bytes } }
                }

                ThresholdRow(
                    titleKey: .settingsOldFileThreshold,
                    value: LocalizationKey.settingsDays.localized(environment.preferences.oldFileThresholdDays),
                    options: [
                        (90, LocalizationKey.settingsDays.localized(90)),
                        (180, LocalizationKey.settingsDays.localized(180)),
                        (365, LocalizationKey.settingsDays.localized(365)),
                    ],
                    selected: Int64(environment.preferences.oldFileThresholdDays)
                ) { value in
                    let days = Int(value)
                    Task { await environment.updateSettings { $0.oldFileThresholdDays = days } }
                }

                ThresholdRow(
                    titleKey: .settingsStaleThreshold,
                    value: LocalizationKey.settingsDays.localized(environment.preferences.staleThresholdDays),
                    options: [
                        (14, LocalizationKey.settingsDays.localized(14)),
                        (30, LocalizationKey.settingsDays.localized(30)),
                        (90, LocalizationKey.settingsDays.localized(90)),
                    ],
                    selected: Int64(environment.preferences.staleThresholdDays)
                ) { value in
                    let days = Int(value)
                    Task { await environment.updateSettings { $0.staleThresholdDays = days } }
                }
            }
        }
    }

    // MARK: - Confirmation

    private var confirmationSection: some View {
        SettingsGroup(titleKey: .settingsGroupConfirmation) {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                // One switch for one decision. There used to be two —
                // `requireConfirmation` and `skipConfirmation` — and clearing
                // either removed the last checkpoint, but only the second showed
                // the warning. Two names for one switch is how a page warns about
                // one way to do the unsafe thing and stays silent about the other.
                Toggle(isOn: Binding(
                    get: { environment.preferences.showsConfirmationPanel },
                    set: { value in
                        Task {
                            await environment.updateSettings {
                                $0.requireConfirmation = value
                                $0.skipConfirmation = false
                            }
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalizationKey.settingsShowConfirmList.localized)
                            .font(SiftFont.body)
                        Text(LocalizationKey.settingsRequireConfirmation.localized)
                            .font(SiftFont.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("settings.confirmList")

                if !environment.preferences.showsConfirmationPanel {
                    NoticeBanner(level: .warning, titleKey: .settingsShowConfirmListWarning)
                }
                Text(LocalizationKey.cleanupConfirmUndoNotice.localized)
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Appearance and language

    private var appearanceSection: some View {
        SettingsGroup(titleKey: .settingsGroupAppearance) {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                // The light/dark/system switcher lives in the rail's footer,
                // beside the language and account entries; this group keeps the
                // rest of the appearance settings.
                LanguageMenu(
                    selection: environment.preferences.language,
                    style: .settings(title: .settingsGroupLanguage),
                    identifier: "settings.language"
                ) { language in
                    environment.selectLanguage(language)
                }

                Toggle(isOn: Binding(
                    get: { environment.preferences.reduceMotion },
                    set: { value in Task { await environment.updateSettings { $0.reduceMotion = value } } }
                )) {
                    Text(LocalizationKey.settingsReduceMotion.localized)
                        .font(SiftFont.body)
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    // MARK: - Privacy

    private var privacySection: some View {
        SettingsGroup(titleKey: .settingsGroupPrivacy) {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                Text(LocalizationKey.settingsPrivacyStatement.localized)
                    .font(SiftFont.body)
                    .fixedSize(horizontal: false, vertical: true)
                Text(LocalizationKey.reportPrivacyNote.localized)
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: SiftMetrics.spacingM) {
                    Button {
                        Task { await environment.clearHistory() }
                    } label: {
                        Text(LocalizationKey.settingsClearHistory.localized)
                            .font(SiftFont.caption)
                    }
                    .buttonStyle(SiftLinkButtonStyle())

                    Button(role: .destructive) {
                        isConfirmingReportDeletion = true
                    } label: {
                        Text(LocalizationKey.settingsDeleteReports.localized)
                            .font(SiftFont.caption)
                    }
                    .buttonStyle(SiftLinkButtonStyle())
                }
                .confirmationDialog(
                    LocalizationKey.settingsDeleteReportsConfirm.localized,
                    isPresented: $isConfirmingReportDeletion,
                    titleVisibility: .visible
                ) {
                    Button(LocalizationKey.commonRemove.localized, role: .destructive) {
                        Task { await environment.deleteSavedReports() }
                    }
                    Button(LocalizationKey.cleanupConfirmCancel.localized, role: .cancel) {}
                }
            }
        }
    }

    // MARK: - Purchase

    private var purchaseSection: some View {
        SettingsGroup(titleKey: .settingsGroupPurchase) {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                HStack {
                    Text(
                        environment.entitlement.isUnlocked
                            ? LocalizationKey.purchaseStatusPurchased.localized
                            : LocalizationKey.purchaseStatusFree.localized
                    )
                    .font(SiftFont.bodyEmphasis)
                    Spacer()
                    if let days = environment.entitlement.status.graceDaysRemaining {
                        Text(LocalizationKey.purchaseOfflineGrace.localized(days))
                            .font(SiftFont.caption)
                            .foregroundStyle(SiftColor.review)
                    }
                }
                Text(LocalizationKey.purchasePriceLine.localized)
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)
                if hasStoredLicense {
                    // The only way to remove a stored key. macOS binds the
                    // keychain item to the app's code signature, so an ad-hoc
                    // build asks for permission again after every rebuild; a
                    // user who no longer wants the key stored needs a way to say
                    // so without the terminal.
                    Button {
                        Task {
                            await environment.removeStoredLicense()
                            hasStoredLicense = await environment.hasStoredLicense()
                        }
                    } label: {
                        Text(LocalizationKey.settingsRemoveLicense.localized)
                            .font(SiftFont.caption)
                    }
                    .buttonStyle(SiftLinkButtonStyle())
                }
            }
        }
    }

    // MARK: - Diagnostics

    /// The coverage audit, opened from the diagnostics group.
    ///
    /// Its own page rather than a row here: it walks a whole home folder, and the
    /// numbers are the point — a submenu of counts would read as decoration.
    private var coverageSection: some View {
        SettingsGroup(titleKey: .diagnosticsCoverageTitle) {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
                Text(LocalizationKey.diagnosticsCoverageDetail.localized)
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    isShowingCoverage = true
                } label: {
                    Text(LocalizationKey.diagnosticsCoverageRun.localized)
                        .font(SiftFont.caption)
                }
                .buttonStyle(SiftLinkButtonStyle())
                .disabled(environment.isScanInFlight || environment.cleanup.isWorking)
            }
        }
        .sheet(isPresented: $isShowingCoverage) {
            RuleCoverageSheet()
                .environmentObject(environment)
        }
    }

    private var diagnosticsSection: some View {
        SettingsGroup(titleKey: .settingsGroupLogs) {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                HStack {
                    Text(LocalizationKey.settingsExportLogs.localized)
                        .font(SiftFont.body)
                    Spacer()
                    Button {
                        exportDiagnostics()
                    } label: {
                        Text(LocalizationKey.settingsExportLogs.localized)
                            .font(SiftFont.caption)
                    }
                    .buttonStyle(SiftLinkButtonStyle())
                }
                Text(LocalizationKey.settingsExportLogsDetail.localized)
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)

                if let exportMessage {
                    NoticeBanner(level: .information, message: exportMessage)
                }

                Divider()

                // Which engine is running is a support question, so it is stated
                // here rather than hidden.
                HStack {
                    Text(LocalizationKey.settingsDiagnosticsScannerCore.localized)
                        .font(SiftFont.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(environment.engineKind.displayName)
                        .font(SiftFont.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text(LocalizationKey.settingsDiagnosticsVersion.localized)
                        .font(SiftFont.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1")
                        .font(SiftFont.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text(LocalizationKey.settingsDiagnosticsMacOS.localized)
                        .font(SiftFont.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(ProcessInfo.processInfo.operatingSystemVersionString)
                        .font(SiftFont.caption)
                        .foregroundStyle(.secondary)
                }

                // One click used to clear every setting *and* every authorised
                // folder, and cancel a scan in flight. That is a destructive
                // action on data the user granted deliberately, so it asks first
                // and says what it will take away.
                Button {
                    isConfirmingReset = true
                } label: {
                    Text(LocalizationKey.settingsResetDefaults.localized)
                        .font(SiftFont.caption)
                }
                .buttonStyle(SiftLinkButtonStyle())
                .accessibilityIdentifier("settings.resetDefaults")
                .confirmationDialog(
                    LocalizationKey.settingsResetDefaults.localized,
                    isPresented: $isConfirmingReset,
                    titleVisibility: .visible
                ) {
                    Button(LocalizationKey.settingsResetDefaults.localized, role: .destructive) {
                        Task { await environment.resetSettings() }
                    }
                    Button(LocalizationKey.cleanupConfirmCancel.localized, role: .cancel) {}
                } message: {
                    Text(LocalizationKey.settingsAuthorizedEmpty.localized)
                }
                .disabled(
                    environment.cleanup.isWorking
                        || environment.cleanup.isPreparingCleanup
                        || environment.isScanInFlight
                )
            }
        }
    }

    /// Writes a redacted diagnostics file the user can attach to a report.
    ///
    /// §13.2 forbids file names and full paths, so this contains counts, the
    /// engine, versions and the preference values only.
    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Sift-Diagnostics.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let diagnostics: [String: Any] = [
            "engine": environment.engineKind.rawValue,
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1",
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "volumes": environment.availableVolumes.count,
            "applications": environment.installedApplications.count,
            "entitlement": environment.entitlement.isUnlocked ? "unlocked" : "free",
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: diagnostics, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            exportMessage = LocalizationKey.settingsExportLogsDetail.localized
        } catch {
            exportMessage = LocalizationKey.commonUnknownError.localized
        }
    }
}

/// A settings group: a title and a bordered panel.
struct SettingsGroup<Content: View>: View {
    let titleKey: LocalizationKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
            Text(titleKey.localized)
                .font(SiftFont.sectionTitle)
            SiftGlassCard(padding: SiftMetrics.spacingL) {
                content
            }
        }
    }
}

/// A labelled picker with a numeric value and a set of allowed choices.
struct ThresholdRow: View {
    let titleKey: LocalizationKey
    let value: String
    let options: [(Int64, String)]
    let selected: Int64
    let onSelect: (Int64) -> Void

    var body: some View {
        HStack {
            Text(titleKey.localized)
                .font(SiftFont.body)
            Spacer()
            Picker(String(), selection: Binding(
                get: { selected },
                set: { onSelect($0) }
            )) {
                ForEach(options, id: \.0) { option in
                    Text(option.1).tag(option.0)
                }
            }
            .labelsHidden()
            .frame(width: 140)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(titleKey.localized))
        .accessibilityValue(Text(value))
    }
}
