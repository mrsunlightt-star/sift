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
            .buttonStyle(SiftLinkButtonStyle())
            .accessibilityLabel(
                Text(LocalizationKey.scanSelectAllShown.localized(cleanup.items.count))
            )

            Button {
                cleanup.deselectAll()
            } label: {
                Text(LocalizationKey.scanDeselectAll.localized)
            }
            .buttonStyle(SiftLinkButtonStyle())

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
        .padding(SiftMetrics.spacingL)
        .background(SiftColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusL, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusL, style: .continuous)
                .stroke(SiftColor.border, lineWidth: 1)
        }
    }

    private func beginCleanup() async {
        // `AppEnvironment` owns the entitlement gate and the execution boundary.
        // The preference only decides whether the panel appears; a later
        // confirmation is gated again inside `confirmCleanup`.
        let result = await environment.beginCleanup(
            operation: operation,
            requiresConfirmation: environment.preferences.showsConfirmationPanel,
            scanReport: environment.scan.report
        )
        if case .purchaseRequired = result {
            onRequestPurchase()
        }
    }
}


