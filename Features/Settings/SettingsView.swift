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

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingXL) {
                PageHeader(titleKey: .settingsTitle)

                scanScopeSection
                thresholdsSection
                confirmationSection
                appearanceSection
                privacySection
                purchaseSection
                diagnosticsSection
            }
            .padding(SiftMetrics.spacingXL)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .task {
            permissionReport = await environment.permissions.accessReport()
        }
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
                    Text(LocalizationKey.settingsShowHiddenFiles.localized)
                        .font(SiftFont.body)
                }
                .toggleStyle(.checkbox)

                Toggle(isOn: Binding(
                    get: { environment.preferences.userRulesEnabled },
                    set: { value in Task { await environment.updateSettings { $0.userRulesEnabled = value } } }
                )) {
                    Text(LocalizationKey.settingsGroupIgnores.localized)
                        .font(SiftFont.body)
                }
                .toggleStyle(.checkbox)

                if !environment.preferences.ignoredPaths.isEmpty {
                    VStack(alignment: .leading, spacing: SiftMetrics.spacingXS) {
                        ForEach(environment.preferences.ignoredPaths, id: \.self) { path in
                            HStack {
                                Text(CleanupItem.abbreviate(path))
                                    .font(SiftFont.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button {
                                    Task {
                                        await environment.updateSettings { settings in
                                            settings.ignoredPaths.removeAll { $0 == path }
                                        }
                                    }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(Text(LocalizationKey.commonRemove.localized))
                            }
                        }
                    }
                }

                Divider()

                permissionRows
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
            Button {
                Task {
                    await environment.openPermissionSettings()
                    permissionHint = true
                }
            } label: {
                Text(LocalizationKey.permissionOpenSettings.localized)
                    .font(SiftFont.caption)
            }
            .buttonStyle(.link)
            if permissionHint {
                Text(LocalizationKey.permissionFullDiskAccessDetail.localized)
                    .font(SiftFont.caption)
                    .foregroundStyle(.tertiary)
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
                    titleKey: .settingsScanHistory,
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
                Toggle(isOn: Binding(
                    get: { environment.preferences.requireConfirmation },
                    set: { value in Task { await environment.updateSettings { $0.requireConfirmation = value } } }
                )) {
                    Text(LocalizationKey.settingsRequireConfirmation.localized)
                        .font(SiftFont.body)
                }
                .toggleStyle(.checkbox)

                Toggle(isOn: Binding(
                    get: { environment.preferences.skipConfirmation },
                    set: { value in Task { await environment.updateSettings { $0.skipConfirmation = value } } }
                )) {
                    Text(LocalizationKey.settingsSkipConfirmation.localized)
                        .font(SiftFont.body)
                }
                .toggleStyle(.checkbox)
                .disabled(!environment.preferences.requireConfirmation)

                if environment.preferences.skipConfirmation {
                    NoticeBanner(level: .warning, titleKey: .settingsSkipConfirmationWarning)
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
                Picker(LocalizationKey.settingsGroupAppearance.localized, selection: Binding(
                    get: { environment.preferences.appearance },
                    set: { value in Task { await environment.updateSettings { $0.appearance = value } } }
                )) {
                    ForEach(AppSettings.Appearance.allCases, id: \.self) { appearance in
                        Text(appearance.titleKey.localized).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    Text(LocalizationKey.settingsGroupLanguage.localized)
                        .font(SiftFont.body)
                    Spacer()
                    Text(Locale.current.localizedString(forIdentifier: Locale.current.identifier) ?? "—")
                        .font(SiftFont.body)
                        .foregroundStyle(.secondary)
                }
                Text(LocalizationKey.settingsLanguageRestart.localized)
                    .font(SiftFont.caption)
                    .foregroundStyle(.tertiary)
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
                Button {
                    Task { await environment.updateSettings { _ in } }
                } label: {
                    Text(LocalizationKey.settingsClearHistory.localized)
                        .font(SiftFont.caption)
                }
                .buttonStyle(.link)
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
            }
        }
    }

    // MARK: - Diagnostics

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
                    .buttonStyle(.link)
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

                Button {
                    Task { await environment.updateSettings { _ in } }
                } label: {
                    Text(LocalizationKey.settingsResetDefaults.localized)
                        .font(SiftFont.caption)
                }
                .buttonStyle(.link)
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
            SiftPanel {
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
