import AppKit
import Core
import Shared
import SwiftUI

/// Settings (03 §4).
///
/// Every group is a title, a hairline and a list of rows on the canvas. There is
/// no panel around any of it: a card per group, and then a card per row inside
/// the group, is how one page ends up looking like a dashboard of unrelated
/// widgets. The section title answers "which part of the product is this", the
/// row answers "what does it do", and the hairline between rows is the only
/// boundary the page needs.
///
/// Two behaviours here are product, not decoration, and the page keeps them
/// where the decision is made: the confirmation switch warns what turning it off
/// takes away, and the permission copy says that macOS applies a Full Disk
/// Access grant at launch (invariant 43).
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
                    tone: environment.entitlement.isUnlocked ? .safe : .neutral
                )
            }

            // A form's measure, not the wide page measure: a 1180 pt row puts the
            // label and its control a hand's width apart.
            SiftPage(maxWidth: SiftMetrics.contentWidthForm) {
                appearanceSection
                scanScopeSection
                thresholdsSection
                ignoresSection
                authorizedSection
                confirmationSection
                privacySection
                purchaseSection
                coverageSection
                diagnosticsSection
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

    // MARK: - Appearance

    private var appearanceSection: some View {
        SettingsGroup(titleKey: .settingsGroupAppearance) {
            // The light/dark/system switcher lives in the rail's footer, beside
            // the language and account entries; this group keeps the rest of the
            // appearance settings.
            LanguageMenu(
                selection: environment.preferences.language,
                style: .settings(title: .settingsGroupLanguage),
                identifier: "settings.language"
            ) { language in
                environment.selectLanguage(language)
            }

            SiftHairline()

            // The interface's own type scale. macOS has no system setting for it,
            // so a fixed ladder was the whole answer to a user who cannot read it.
            SettingsControlRow(titleKey: .settingsTextSize) {
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
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)
                .accessibilityIdentifier("settings.textSize")
            }

            SiftHairline()

            Toggle(isOn: Binding(
                get: { environment.preferences.reduceMotion },
                set: { value in Task { await environment.updateSettings { $0.reduceMotion = value } } }
            )) {
                // No second sentence: there is no keyed copy for one, and the
                // switch says what it does. A hard-coded English line under it
                // would be the one string on this page that never gets translated.
                Text(LocalizationKey.settingsReduceMotion.localized)
                    .font(SiftFont.body)
                    .foregroundStyle(SiftColor.mainText)
            }
            .toggleStyle(.checkbox)
            .padding(.vertical, SiftMetrics.spacingS)

            SiftHairline()

            if LoginItem.isSupported {
                // Opening at login is a launch behaviour, and macOS files it under
                // "General". This page has no General group and no key for one, so
                // it sits with the other switch that decides how the app starts up
                // and stays out of the scan groups, which are about what a run
                // produces.
                Toggle(isOn: Binding(
                    get: { loginItemEnabled },
                    set: { value in loginItemEnabled = LoginItem.set(enabled: value) }
                )) {
                    // No detail line: the permission hint belongs to the
                    // permission section, and there is no keyed sentence that
                    // describes a login item. Borrowing one put "macOS applies the
                    // grant when an app starts" under a launch-at-login switch.
                    Text(LocalizationKey.settingsLaunchAtLogin.localized)
                        .font(SiftFont.body)
                        .foregroundStyle(SiftColor.mainText)
                }
                .toggleStyle(.checkbox)
                .padding(.vertical, SiftMetrics.spacingS)
                .accessibilityIdentifier("settings.launchAtLogin")
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

    // MARK: - Scan scope

    /// The volumes a scan can see, and the two switches that decide what a run
    /// produces. Both of these scope decisions change the rows themselves, so they
    /// belong above the thresholds that filter them, not with the preferences that
    /// only change how the page looks.
    private var scanScopeSection: some View {
        SettingsGroup(titleKey: .settingsGroupScanScope) {
            ForEach(Array(environment.availableVolumes.enumerated()), id: \.element.id) { index, volume in
                if index > 0 {
                    SiftHairline()
                }
                HStack(spacing: SiftMetrics.spacingM) {
                    Image(systemName: volume.isExternal ? "externaldrive" : "internaldrive")
                        .font(.system(size: 12))
                        .foregroundStyle(volume.isExternal ? SiftColor.reviewTextColor : SiftColor.quietText)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(volume.name)
                            .font(SiftFont.body)
                            .foregroundStyle(SiftColor.mainText)
                        Text(LocalizationKey.dashboardDiskFree.localized(volume.formattedFree))
                            .font(SiftFont.supporting)
                            .foregroundStyle(SiftColor.secondaryText)
                    }
                    Spacer(minLength: SiftMetrics.spacingS)
                    if volume.isReadOnly {
                        Text(LocalizationKey.commonNotAvailable.localized)
                            .font(SiftFont.supporting)
                            .foregroundStyle(SiftColor.secondaryText)
                    }
                }
                .padding(.vertical, SiftMetrics.spacingS)
                .accessibilityElement(children: .combine)
            }

            SiftHairline()

            Toggle(isOn: Binding(
                get: { environment.preferences.showHiddenFiles },
                set: { value in Task { await environment.updateSettings { $0.showHiddenFiles = value } } }
            )) {
                Text(LocalizationKey.settingsIncludeHidden.localized)
                    .font(SiftFont.body)
                    .foregroundStyle(SiftColor.mainText)
            }
            .toggleStyle(.checkbox)
            .padding(.vertical, SiftMetrics.spacingS)

            SiftHairline()

            Toggle(isOn: Binding(
                get: { environment.preferences.userRulesEnabled },
                set: { value in Task { await environment.updateSettings { $0.userRulesEnabled = value } } }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizationKey.settingsUserRules.localized)
                        .font(SiftFont.body)
                        .foregroundStyle(SiftColor.mainText)
                    Text(LocalizationKey.settingsUserRulesDetail.localized)
                        .font(SiftFont.supporting)
                        .foregroundStyle(SiftColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            .padding(.vertical, SiftMetrics.spacingS)
        }
    }

    // MARK: - Thresholds

    private var thresholdsSection: some View {
        SettingsGroup(titleKey: .settingsGroupThresholds) {
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

            SiftHairline()

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

            SiftHairline()

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

    // MARK: - Ignored items

    /// Folders a scan leaves alone.
    ///
    /// The list existed only as a place entries could be removed from: nothing
    /// ever put one in, so the rule it feeds never had anything to apply to. It is
    /// its own group because it is a list, and a list inside another section reads
    /// as that section's footnote.
    private var ignoresSection: some View {
        SettingsGroup(titleKey: .settingsGroupIgnores) {
            if environment.preferences.ignoredPaths.isEmpty {
                Text(LocalizationKey.settingsIgnoreEmpty.localized)
                    .font(SiftFont.supporting)
                    .foregroundStyle(SiftColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, SiftMetrics.spacingS)
            } else {
                ForEach(Array(environment.preferences.ignoredPaths.enumerated()), id: \.element) { index, path in
                    if index > 0 {
                        SiftHairline()
                    }
                    HStack(spacing: SiftMetrics.spacingM) {
                        Text(CleanupItem.abbreviate(path))
                            .font(SiftFont.supporting)
                            .foregroundStyle(SiftColor.mainText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: SiftMetrics.spacingS)
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
                    .padding(.vertical, SiftMetrics.spacingXS)
                    .frame(minHeight: SiftMetrics.rowHeight)
                }
            }

            SiftHairline()

            Button {
                addIgnoredFolder()
            } label: {
                Text(LocalizationKey.settingsAddFolder.localized)
                    .font(SiftFont.supporting)
            }
            .buttonStyle(SiftLinkButtonStyle())
            .padding(.vertical, SiftMetrics.spacingS)
            .accessibilityIdentifier("settings.addIgnoredFolder")
        }
    }

    /// Adds one folder to the ignore list.
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

    // MARK: - Authorised folders

    /// The one place a folder or volume is granted (invariant 17).
    ///
    /// It used to live on the duplicate page as well, which meant two different
    /// lists of the same grants and two ways to change them. Every page that
    /// depends on a grant links here instead, and one location is one row: the
    /// grant is keyed by its resolved path, so a location added twice is the same
    /// row twice, which the list cannot represent.
    private var authorizedSection: some View {
        SettingsGroup(titleKey: .settingsGroupAuthorized) {
            if environment.authorizedLocations.isEmpty {
                Text(LocalizationKey.settingsAuthorizedEmpty.localized)
                    .font(SiftFont.supporting)
                    .foregroundStyle(SiftColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, SiftMetrics.spacingS)
            } else {
                ForEach(Array(environment.authorizedLocations.enumerated()), id: \.element.id) { index, location in
                    if index > 0 {
                        SiftHairline()
                    }
                    HStack(spacing: SiftMetrics.spacingM) {
                        Image(systemName: location.isVolume ? "externaldrive" : "folder")
                            .font(.system(size: 12))
                            .foregroundStyle(SiftColor.quietText)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(location.displayName)
                                .font(SiftFont.body)
                                .foregroundStyle(SiftColor.mainText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if !environment.isAvailable(location) {
                                // A grant is in force only while the location can
                                // be read (invariant 11), so an unplugged volume
                                // says so instead of looking authorised.
                                Text(LocalizationKey.settingsAuthorizedUnavailable.localized)
                                    .font(SiftFont.supporting)
                                    .foregroundStyle(SiftColor.reviewTextColor)
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
                    .padding(.vertical, SiftMetrics.spacingS)
                    .accessibilityElement(children: .combine)
                }
            }

            SiftHairline()

            Button {
                addAuthorizedLocations()
            } label: {
                Label(LocalizationKey.filesAddFolder.localized, systemImage: "folder.badge.plus")
                    .font(SiftFont.supporting)
            }
            .buttonStyle(SiftLinkButtonStyle())
            .padding(.vertical, SiftMetrics.spacingS)
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

    // MARK: - Confirmation

    private var confirmationSection: some View {
        SettingsGroup(titleKey: .settingsGroupConfirmation) {
            // One switch for one decision. There used to be two —
            // `requireConfirmation` and `skipConfirmation` — and clearing either
            // removed the last checkpoint, but only the second showed the warning.
            // Two names for one switch is how a page warns about one way to do the
            // unsafe thing and stays silent about the other.
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
                        .foregroundStyle(SiftColor.mainText)
                    Text(LocalizationKey.settingsRequireConfirmation.localized)
                        .font(SiftFont.supporting)
                        .foregroundStyle(SiftColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            .padding(.vertical, SiftMetrics.spacingS)
            .accessibilityIdentifier("settings.confirmList")

            if !environment.preferences.showsConfirmationPanel {
                NoticeBanner(level: .warning, titleKey: .settingsShowConfirmListWarning)
                    .padding(.bottom, SiftMetrics.spacingS)
            }

            SiftHairline()

            Text(LocalizationKey.cleanupConfirmUndoNotice.localized)
                .font(SiftFont.supporting)
                .foregroundStyle(SiftColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, SiftMetrics.spacingS)
        }
    }

    // MARK: - Privacy and permissions

    /// Two permissions and what the product keeps.
    ///
    /// Full Disk Access and App Management are different switches, and the two are
    /// confused easily — the uninstaller's failed row offered Full Disk Access for
    /// a refusal that App Management was the answer to. They are stated together
    /// here, each with its own state, so "I already granted everything" has an
    /// answer: the state says which one is missing.
    private var privacySection: some View {
        SettingsGroup(titleKey: .settingsGroupPrivacy) {
            Text(LocalizationKey.permissionFullDiskAccess.localized)
                .font(SiftFont.secondaryHeading)
                .foregroundStyle(SiftColor.mainText)
                .padding(.top, SiftMetrics.spacingXS)

            Text(LocalizationKey.permissionFullDiskAccessDetail.localized)
                .font(SiftFont.supporting)
                .foregroundStyle(SiftColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)

            ForEach(permissionReport) { location in
                HStack(spacing: SiftMetrics.spacingS) {
                    Image(systemName: location.isReadable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(location.isReadable ? SiftColor.safeTextColor : SiftColor.reviewTextColor)
                        .accessibilityHidden(true)
                    Text(location.title)
                        .font(SiftFont.supporting)
                        .foregroundStyle(SiftColor.secondaryText)
                    Spacer(minLength: SiftMetrics.spacingS)
                    Text(
                        location.isReadable
                            ? LocalizationKey.commonDone.localized
                            : LocalizationKey.permissionPartialAccess.localized
                    )
                    .font(SiftFont.supporting)
                    .foregroundStyle(location.isReadable ? SiftColor.secondaryText : SiftColor.reviewTextColor)
                }
                .padding(.top, SiftMetrics.spacingXS)
                .accessibilityElement(children: .combine)
            }

            if permissionReport.contains(where: { !$0.isReadable }) {
                // Invariant 43: a grant is read when the app starts, and a rebuilt
                // copy is a different code identity. The hint is the answer to "I
                // already granted Full Disk Access", so it is stated beside the
                // state rather than in a help page.
                Text(LocalizationKey.permissionRestartHint.localized)
                    .font(SiftFont.supporting)
                    .foregroundStyle(SiftColor.quietText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, SiftMetrics.spacingXS)
            }

            HStack(spacing: SiftMetrics.spacingM) {
                Button {
                    isExplainingPermission = true
                } label: {
                    Text(LocalizationKey.permissionOpenSettings.localized)
                        .font(SiftFont.supporting)
                }
                .buttonStyle(SiftLinkButtonStyle())
                .accessibilityIdentifier("settings.permissionExplain")
            }
            .padding(.top, SiftMetrics.spacingS)

            if permissionHint {
                Text(LocalizationKey.permissionOpenedSettings.localized)
                    .font(SiftFont.supporting)
                    .foregroundStyle(SiftColor.quietText)
            }

            SiftHairline()
                .padding(.vertical, SiftMetrics.spacingM)

            // Moving another developer's application bundle is App Management,
            // and granting it takes effect immediately — unlike Full Disk Access.
            // Re-checking is therefore honest here, which is why the row offers it.
            Text(LocalizationKey.appManagementTitle.localized)
                .font(SiftFont.secondaryHeading)
                .foregroundStyle(SiftColor.mainText)

            Text(LocalizationKey.appManagementRequired.localized)
                .font(SiftFont.supporting)
                .foregroundStyle(SiftColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)

            HStack(spacing: SiftMetrics.spacingS) {
                Image(systemName: environment.appManagement == .denied
                    ? "exclamationmark.triangle.fill"
                    : "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(
                        environment.appManagement == .denied
                            ? SiftColor.reviewTextColor
                            : SiftColor.safeTextColor
                    )
                    .accessibilityHidden(true)
                Text(
                    environment.appManagement == .granted
                        ? LocalizationKey.commonDone.localized
                        : LocalizationKey.commonNotAvailable.localized
                )
                .font(SiftFont.supporting)
                .foregroundStyle(SiftColor.secondaryText)
                Spacer(minLength: SiftMetrics.spacingS)
            }
            .padding(.top, SiftMetrics.spacingXS)
            .accessibilityElement(children: .combine)

            HStack(spacing: SiftMetrics.spacingM) {
                Button {
                    Task { await environment.openAppManagementSettings() }
                } label: {
                    Text(LocalizationKey.permissionOpenSettings.localized)
                        .font(SiftFont.supporting)
                }
                .buttonStyle(SiftLinkButtonStyle())
                .accessibilityIdentifier("settings.appManagementOpen")

                Button {
                    Task { await environment.recheckAppManagement() }
                } label: {
                    Text(LocalizationKey.appManagementRecheck.localized)
                        .font(SiftFont.supporting)
                }
                .buttonStyle(SiftLinkButtonStyle())
                .accessibilityIdentifier("settings.appManagementRecheck")
            }
            .padding(.top, SiftMetrics.spacingS)

            SiftHairline()
                .padding(.vertical, SiftMetrics.spacingM)

            Text(LocalizationKey.settingsPrivacyStatement.localized)
                .font(SiftFont.body)
                .foregroundStyle(SiftColor.mainText)
                .fixedSize(horizontal: false, vertical: true)

            Text(LocalizationKey.reportPrivacyNote.localized)
                .font(SiftFont.supporting)
                .foregroundStyle(SiftColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, SiftMetrics.spacingXS)

            // How much history is kept sits next to the control that clears it:
            // both are about the same retained data, and a retention setting filed
            // under "diagnostics" is one nobody finds.
            SettingsControlRow(titleKey: .settingsKeepHistory) {
                HStack(spacing: SiftMetrics.spacingS) {
                    Text("\(environment.preferences.keepScanHistory)")
                        .font(SiftFont.monospacedNumber)
                        .foregroundStyle(SiftColor.mainText)
                    Stepper(
                        "",
                        value: Binding(
                            get: { environment.preferences.keepScanHistory },
                            set: { value in
                                Task { await environment.updateSettings { $0.keepScanHistory = value } }
                            }
                        ),
                        in: 5...50,
                        step: 5
                    )
                    .labelsHidden()
                }
            }
            .padding(.bottom, SiftMetrics.spacingS)

            HStack(spacing: SiftMetrics.spacingM) {
                Button {
                    Task { await environment.clearHistory() }
                } label: {
                    Text(LocalizationKey.settingsClearHistory.localized)
                        .font(SiftFont.supporting)
                }
                .buttonStyle(SiftLinkButtonStyle())

                // Destructive, and worded as what it removes rather than as
                // "delete". Separated from the row above and confirmed once.
                Button(role: .destructive) {
                    isConfirmingReportDeletion = true
                } label: {
                    Text(LocalizationKey.settingsDeleteReports.localized)
                        .font(SiftFont.supporting)
                        .foregroundStyle(SiftColor.dangerTextColor)
                }
                .buttonStyle(SiftLinkButtonStyle())
            }
            .padding(.top, SiftMetrics.spacingS)
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

    // MARK: - Account

    /// The account entry: what this copy is licensed to do, and the one way to
    /// change it. The purchase page itself is where a licence is activated, so
    /// this row states the state and offers the only action that belongs to a
    /// settings page — removing a stored key.
    private var purchaseSection: some View {
        SettingsGroup(titleKey: .settingsGroupPurchase) {
            HStack(alignment: .firstTextBaseline) {
                Text(
                    environment.entitlement.isUnlocked
                        ? LocalizationKey.purchaseStatusPurchased.localized
                        : LocalizationKey.purchaseStatusFree.localized
                )
                .font(SiftFont.body)
                .foregroundStyle(SiftColor.mainText)

                Spacer(minLength: SiftMetrics.spacingS)

                if let days = environment.entitlement.status.graceDaysRemaining {
                    Text(LocalizationKey.purchaseOfflineGrace.localized(days))
                        .font(SiftFont.supporting)
                        .foregroundStyle(SiftColor.reviewTextColor)
                }
            }
            .padding(.vertical, SiftMetrics.spacingS)

            SiftHairline()

            Text(LocalizationKey.purchasePriceLine.localized)
                .font(SiftFont.supporting)
                .foregroundStyle(SiftColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, SiftMetrics.spacingS)

            if hasStoredLicense {
                SiftHairline()

                // The only way to remove a stored key. macOS binds the keychain
                // item to the app's code signature, so an ad-hoc build asks for
                // permission again after every rebuild; a user who no longer wants
                // the key stored needs a way to say so without the terminal.
                Button {
                    Task {
                        await environment.removeStoredLicense()
                        hasStoredLicense = await environment.hasStoredLicense()
                    }
                } label: {
                    Text(LocalizationKey.settingsRemoveLicense.localized)
                        .font(SiftFont.supporting)
                }
                .buttonStyle(SiftLinkButtonStyle())
                .padding(.vertical, SiftMetrics.spacingS)
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
            Text(LocalizationKey.diagnosticsCoverageDetail.localized)
                .font(SiftFont.supporting)
                .foregroundStyle(SiftColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, SiftMetrics.spacingS)

            SiftHairline()

            Button {
                isShowingCoverage = true
            } label: {
                Text(LocalizationKey.diagnosticsCoverageRun.localized)
                    .font(SiftFont.supporting)
            }
            .buttonStyle(SiftLinkButtonStyle())
            .disabled(environment.isScanInFlight || environment.cleanup.isWorking)
            .padding(.vertical, SiftMetrics.spacingS)
        }
        .sheet(isPresented: $isShowingCoverage) {
            RuleCoverageSheet()
                .environmentObject(environment)
        }
    }

    private var diagnosticsSection: some View {
        SettingsGroup(titleKey: .settingsGroupLogs) {
            // One action, one label. The row used to print "Export diagnostics"
            // twice — once as the label and once as the link beside it — so the
            // detail line sits under the link it belongs to.
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    exportDiagnostics()
                } label: {
                    Text(LocalizationKey.settingsExportLogs.localized)
                        .font(SiftFont.body)
                }
                .buttonStyle(SiftLinkButtonStyle())
                Text(LocalizationKey.settingsExportLogsDetail.localized)
                    .font(SiftFont.supporting)
                    .foregroundStyle(SiftColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, SiftMetrics.spacingS)

            if let exportMessage {
                NoticeBanner(level: .information, message: exportMessage)
                    .padding(.bottom, SiftMetrics.spacingS)
            }

            SiftHairline()

            // Which engine is running is a support question, so it is stated here
            // rather than hidden.
            SettingsValueRow(
                title: LocalizationKey.settingsDiagnosticsScannerCore.localized,
                value: environment.engineKind.displayName
            )

            SiftHairline()

            SettingsValueRow(
                title: LocalizationKey.settingsDiagnosticsVersion.localized,
                value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
            )

            SiftHairline()

            SettingsValueRow(
                title: LocalizationKey.settingsDiagnosticsMacOS.localized,
                value: ProcessInfo.processInfo.operatingSystemVersionString
            )

            SiftHairline()

            // One click used to clear every setting *and* every authorised folder,
            // and cancel a scan in flight. That is a destructive action on data the
            // user granted deliberately, so it asks first, says what it will take
            // away, and sits last in its group where nothing follows it.
            Button(role: .destructive) {
                isConfirmingReset = true
            } label: {
                Text(LocalizationKey.settingsResetDefaults.localized)
                    .font(SiftFont.supporting)
                    .foregroundStyle(SiftColor.dangerTextColor)
            }
            .buttonStyle(SiftLinkButtonStyle())
            .padding(.vertical, SiftMetrics.spacingS)
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

// MARK: - Grouping

/// A settings group: one title, a hairline, and rows on the canvas.
///
/// The rows are separated by hairlines rather than by cards. `.plain` is the
/// point — a group is a boundary the eye draws from the title and the spacing, and
/// a fill behind it would make every group look like a task with a result.
struct SettingsGroup<Content: View>: View {
    let titleKey: LocalizationKey
    @ViewBuilder let content: Content

    var body: some View {
        SiftSection {
            VStack(alignment: .leading, spacing: 0) {
                Text(titleKey.localized)
                    .font(SiftFont.sectionHeading)
                    .foregroundStyle(SiftColor.mainText)
                    .padding(.bottom, SiftMetrics.spacingS)

                SiftHairline()

                content
            }
        }
    }
}

/// A labelled control on one row: the label stays a text role, and the control
/// keeps its standard size and its 44 pt target.
struct SettingsControlRow<Control: View>: View {
    let titleKey: LocalizationKey
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: SiftMetrics.spacingL) {
            Text(titleKey.localized)
                .font(SiftFont.body)
                .foregroundStyle(SiftColor.mainText)
            Spacer(minLength: SiftMetrics.spacingS)
            control
        }
        .frame(minHeight: SiftMetrics.rowHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(titleKey.localized))
    }
}

/// A read-only row: label on the left, value right-aligned on the right.
///
/// One shape for every fact on this page, so a column of them can be scanned down
/// the right edge without reading the labels again.
struct SettingsValueRow: View {
    let title: String
    let value: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SiftMetrics.spacingL) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SiftFont.body)
                    .foregroundStyle(SiftColor.mainText)
                if let detail {
                    Text(detail)
                        .font(SiftFont.supporting)
                        .foregroundStyle(SiftColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: SiftMetrics.spacingS)
            Text(value)
                .font(SiftFont.supporting)
                .foregroundStyle(SiftColor.secondaryText)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, SiftMetrics.spacingS)
        .frame(minHeight: SiftMetrics.rowHeight)
        .accessibilityElement(children: .combine)
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
        HStack(alignment: .center) {
            Text(titleKey.localized)
                .font(SiftFont.body)
                .foregroundStyle(SiftColor.mainText)
            Spacer(minLength: SiftMetrics.spacingS)
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
        .frame(minHeight: SiftMetrics.rowHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(titleKey.localized))
        .accessibilityValue(Text(value))
    }
}
