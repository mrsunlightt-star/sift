import Core
import Shared
import SwiftUI

/// File cleanup: large files, old files and duplicates (§5.5).
///
/// The three modes are filters over one scan, so the selection and confirmation
/// flow is identical to junk cleanup, and the page shows only the category it
/// owns. The duplicate mode is the one with its own scope: only the folders the
/// user granted, which are managed in Settings rather than here.
public struct FileCleanupView: View {
    @EnvironmentObject private var environment: AppEnvironment
    private let onRequestPurchase: () -> Void
    /// Set by the shell: authorisation is managed in one place, and this page
    /// links there instead of offering a second copy of it.
    private let onManageScope: () -> Void
    @State private var mode: FileCleanupMode = .large

    public init(
        onRequestPurchase: @escaping () -> Void = {},
        onManageScope: @escaping () -> Void = {}
    ) {
        self.onRequestPurchase = onRequestPurchase
        self.onManageScope = onManageScope
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingXL) {
                PageHeader(titleKey: .filesTitle) {
                    Picker(String(), selection: $mode) {
                        ForEach(FileCleanupMode.allCases, id: \.self) { mode in
                            Text(mode.titleKey.localized).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 320)
                }

                thresholdNote

                if mode == .duplicates {
                    duplicateScopeCard
                }

                if environment.scan.hasResults {
                    SelectionBar(
                        cleanup: environment.cleanup,
                        environment: environment,
                        operation: mode.operationName,
                        onRequestPurchase: onRequestPurchase
                    )
                    ScanResultsView(
                        scan: environment.scan,
                        cleanup: environment.cleanup,
                        categories: mode.categories
                    )
                } else {
                    ScanGateCard(
                        titleKey: mode.titleKey,
                        detailKey: mode == .duplicates
                            ? .filesRequiresAuthorization
                            : .cleanupExplanationLargeFilesItem,
                        onStart: { Task { await environment.runScan(.files(mode)) } }
                    )
                }
            }
            .padding(SiftMetrics.spacingXL)
            .frame(maxWidth: 900, alignment: .leading)
            // Keep a readable column, centred in the available detail area.
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var thresholdNote: some View {
        SiftPanel(padding: SiftMetrics.spacingM) {
            HStack(spacing: SiftMetrics.spacingM) {
                Image(systemName: "info.circle")
                    .foregroundStyle(SiftColor.accent)
                    .accessibilityHidden(true)
                switch mode {
                case .large:
                    Text(
                        LocalizationKey.filesThresholdLarge.localized(
                            SiftFormat.bytes(environment.preferences.largeFileThresholdBytes)
                        )
                    )
                    .font(SiftFont.body)
                case .old:
                    Text(
                        LocalizationKey.filesThresholdOld.localized(environment.preferences.oldFileThresholdDays)
                    )
                    .font(SiftFont.body)
                case .duplicates:
                    Text(LocalizationKey.cleanupExplanationDuplicates.localized)
                        .font(SiftFont.body)
                }
                Spacer()
            }
        }
    }

    /// The folders a duplicate scan may look in, and the one way to change them.
    ///
    /// Read-only on purpose: adding or removing a grant is authorisation, and
    /// authorisation lives in Settings so there is one place that owns it.
    private var duplicateScopeCard: some View {
        SiftPanel {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                HStack {
                    Text(LocalizationKey.filesScopeTitle.localized)
                        .font(SiftFont.sectionTitle)
                    Spacer()
                    Button(action: onManageScope) {
                        Text(LocalizationKey.filesManageScope.localized)
                            .font(SiftFont.caption)
                    }
                    .buttonStyle(.link)
                }
                Text(LocalizationKey.filesRequiresAuthorization.localized)
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(environment.authorizedLocations) { location in
                    HStack(spacing: SiftMetrics.spacingM) {
                        Image(systemName: "folder")
                            .foregroundStyle(SiftColor.accent)
                            .accessibilityHidden(true)
                        Text(location.displayName)
                            .font(SiftFont.body)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                    }
                }
                if environment.authorizedLocations.isEmpty {
                    Text(LocalizationKey.filesScopeEmpty.localized)
                        .font(SiftFont.body)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
