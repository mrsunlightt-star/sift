import Shared
import SwiftUI

/// The selection bar: how many items are selected, their size, and the action.
///
/// The action label names the real operation and the real size (§5.2), and the
/// paywall appears here rather than at launch (§12.2).
public struct SelectionBar: View {
    @ObservedObject var cleanup: CleanupModel
    let environment: AppEnvironment
    /// Which operation this entry point performs, so its report and history say
    /// "smart scan" or "duplicate files" instead of always "junk cleanup".
    let operation: CleanupOperationName
    let onRequestPurchase: () -> Void

    public init(
        cleanup: CleanupModel,
        environment: AppEnvironment,
        operation: CleanupOperationName,
        onRequestPurchase: @escaping () -> Void
    ) {
        self.cleanup = cleanup
        self.environment = environment
        self.operation = operation
        self.onRequestPurchase = onRequestPurchase
    }

    public var body: some View {
        HStack(spacing: SiftMetrics.spacingM) {
            // The results are paged, and the model holds the pages that have been
            // loaded, so this can only select those. The count is in the label
            // because the label is what sets the expectation: "Select all" over a
            // list that is showing part of the result reads as the whole thing.
            Button {
                cleanup.selectAll(in: cleanup.items)
            } label: {
                Text(LocalizationKey.scanSelectAllShown.localized(cleanup.items.count))
            }
            .buttonStyle(.link)
            .accessibilityLabel(
                Text(LocalizationKey.scanSelectAllShown.localized(cleanup.items.count))
            )

            Button {
                cleanup.deselectAll()
            } label: {
                Text(LocalizationKey.scanDeselectAll.localized)
            }
            .buttonStyle(.link)

            Spacer()

            Text(
                "\(LocalizationKey.commonSelected.localized(cleanup.selectedCount)) · \(cleanup.formattedSelectedBytes)"
            )
            .font(SiftFont.bodyEmphasis)
            .foregroundStyle(.secondary)
            .accessibilityLabel(
                Text(LocalizationKey.commonSelected.localized(cleanup.selectedCount))
            )

            Button {
                Task { await beginCleanup() }
            } label: {
                Text(cleanup.confirmActionTitle)
                    .font(SiftFont.bodyEmphasis)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(cleanup.selectedCount == 0 || cleanup.isWorking)
        }
        .padding(SiftMetrics.spacingM)
        .background(SiftColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusM, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusM, style: .continuous)
                .stroke(SiftColor.border, lineWidth: 1)
        }
    }

    private func beginCleanup() async {
        // The gate is checked here, not on entry to the app.
        guard await environment.canClean() else {
            onRequestPurchase()
            return
        }
        // The preference decides whether the confirmation panel appears. It can
        // only be off because the user turned it off, and everything still goes
        // to the Trash either way.
        await cleanup.prepareCleanup(
            requiresConfirmation: environment.preferences.showsConfirmationPanel,
            operation: operation
        )
    }
}


