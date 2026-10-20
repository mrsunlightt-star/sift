import Core
import Shared
import SwiftUI

/// The confirmation panel (§5.2).
///
/// Four things this panel must do, all of them from the specification:
///
///  * name the action and the size in the button ("Move 24 items to Trash, 10.2 GB"),
///  * group the selection by type,
///  * state that everything is recoverable from the Trash,
///  * warn when the selection includes items marked for review.
///
/// The "skip confirmation" switch is here rather than in settings alone, because
/// this is where the user can judge the risk (§5.6).
public struct CleanupConfirmationView: View {
    @ObservedObject var cleanup: CleanupModel
    @ObservedObject var preferences: PreferencesSnapshot
    let onConfirm: () -> Void
    let onCancel: () -> Void
    let onToggleSkipConfirmation: (Bool) -> Void

    /// The confirmation is presented as a sheet, so the main flow is unchanged.
    public init(
        cleanup: CleanupModel,
        preferences: PreferencesSnapshot,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onToggleSkipConfirmation: @escaping (Bool) -> Void
    ) {
        self.cleanup = cleanup
        self.preferences = preferences
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        self.onToggleSkipConfirmation = onToggleSkipConfirmation
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingL) {
            header
            Divider()
            if let preflight = cleanup.preflight {
                preflightSummary(preflight)
            }
            categoryBreakdown
            if cleanup.approvedIncludesItemsNeedingReview {
                NoticeBanner(level: .warning, titleKey: .cleanupConfirmRiskWarning)
            }
            Divider()
            footer
        }
        .padding(SiftMetrics.spacingXL)
        .frame(width: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
            Text(LocalizationKey.cleanupConfirmTitle.localized)
                .font(SiftFont.title)
            Text(cleanup.approvedConfirmActionTitle)
                .font(SiftFont.bodyEmphasis)
                .foregroundStyle(SiftColor.accent)
            Text(LocalizationKey.cleanupConfirmUndoNotice.localized)
                .font(SiftFont.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What pre-flight found: what will move, and what will not.
    private func preflightSummary(_ preflight: PreflightReport) -> some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
            HStack {
                Text(LocalizationKey.cleanupConfirmMethod.localized)
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)
                Text(LocalizationKey.cleanupConfirmMethodValue.localized)
                    .font(SiftFont.caption)
            }
            HStack {
                Text(LocalizationKey.cleanupConfirmRelease.localized)
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)
                Text(preflight.formattedReadyBytes)
                    .font(SiftFont.bodyEmphasis)
            }
            if !preflight.protected.isEmpty {
                Text(LocalizationKey.cleanupFailureProtectedLocation.localized)
                    .font(SiftFont.caption)
                    .foregroundStyle(SiftColor.danger)
            }
            if !preflight.skipped.isEmpty {
                Text(
                    LocalizationKey.cleanupFailureFileNotFound.localized + ": \(preflight.skipped.count)"
                )
                .font(SiftFont.caption)
                .foregroundStyle(SiftColor.review)
            }
            if !preflight.subsumed.isEmpty {
                Text(LocalizationKey.cleanupConfirmSelectedItems.localized(preflight.subsumed.count))
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var categoryBreakdown: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
            Text(LocalizationKey.cleanupConfirmByCategory.localized)
                .font(SiftFont.sectionTitle)
            ForEach(cleanup.approvedByCategory) { total in
                HStack(spacing: SiftMetrics.spacingM) {
                    Circle()
                        .fill(SiftColor.categoryPalette[total.category.paletteIndex])
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(total.category.titleKey.localized)
                        .font(SiftFont.body)
                    Spacer()
                    Text(LocalizationKey.commonItemCount.localized(total.itemCount))
                        .font(SiftFont.caption)
                        .foregroundStyle(.secondary)
                    Text(total.formattedSize)
                        .font(SiftFont.monospacedNumber)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
            Toggle(isOn: Binding(
                get: { preferences.skipConfirmation },
                set: { onToggleSkipConfirmation($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizationKey.cleanupConfirmSkipConfirmation.localized)
                        .font(SiftFont.body)
                    Text(LocalizationKey.settingsSkipConfirmationWarning.localized)
                        .font(SiftFont.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)

            HStack {
                Spacer()

                Button {
                    onCancel()
                } label: {
                    Text(LocalizationKey.cleanupConfirmCancel.localized)
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    onConfirm()
                } label: {
                    Text(cleanup.approvedConfirmActionTitle)
                        .font(SiftFont.bodyEmphasis)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}
