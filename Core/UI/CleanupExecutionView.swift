import Shared
import SwiftUI

/// What a running cleanup shows between the confirmation and the result.
///
/// There was nothing here before: the confirmation panel closed, the button
/// stayed disabled, and a batch of five thousand items looked like a click that
/// did nothing until the result appeared. The overlay reports two facts it can
/// stand behind — how many items have moved, and which one is being handled —
/// and offers the one control the situation allows: stop after the item in hand.
///
/// A stop is soft and says so. Rolling a move back automatically would need a
/// second, better-tested undo than the Trash already is, and the Trash is the
/// undo this product sells.
///
/// The layout is one column with no card around it: the ring, the one sentence
/// that states where the batch has got to, the bar, and the footer. An overlay
/// that is itself a card inside a sheet that is also a card read as two nested
/// surfaces for one fact. Nothing here invents a percentage the model does not
/// have: the bar is `done / total` and the sentence is the pair of numbers.
public struct CleanupExecutionView: View {
    @ObservedObject var cleanup: CleanupModel
    let onStop: () -> Void

    @Environment(\.siftReduceMotion) private var reduceMotion

    public init(cleanup: CleanupModel, onStop: @escaping () -> Void) {
        self.cleanup = cleanup
        self.onStop = onStop
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingL) {
            HStack(spacing: SiftMetrics.spacingM) {
                SiftProgressRing(
                    progress: cleanup.isPreparingCleanup ? nil : progressFraction,
                    lineWidth: 7,
                    label: cleanup.executionProgress.map { "\($0.done)" },
                    spokenLabel: title,
                    spokenValue: detail
                )
                .frame(width: 64, height: 64)

                VStack(alignment: .leading, spacing: SiftMetrics.spacingXS) {
                    Text(title)
                        .font(SiftFont.sectionTitle)
                        .foregroundStyle(SiftColor.mainText)
                    Text(detail)
                        .font(SiftFont.caption)
                        .foregroundStyle(SiftColor.secondaryText)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    if let name = cleanup.executionProgress?.currentName, !name.isEmpty {
                        Text(name)
                            .font(SiftFont.caption)
                            .foregroundStyle(SiftColor.quietText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: SiftMetrics.spacingM)
            }

            ProgressView(value: cleanup.executionProgress?.fraction ?? 0)
                .progressViewStyle(.linear)
                .tint(SiftColor.actionFill)
                .animation(reduceMotion ? nil : .linear(duration: 0.2), value: cleanup.executionProgress?.done)

            SiftHairline()

            HStack(spacing: SiftMetrics.spacingM) {
                Image(systemName: "arrow.uturn.backward.circle")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(SiftColor.quietText)
                Text(LocalizationKey.cleanupResultUndoHint.localized)
                    .font(SiftFont.caption)
                    .foregroundStyle(SiftColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: SiftMetrics.spacingS)
                SiftSecondaryButton(
                    title: cleanup.isStopping
                        ? LocalizationKey.scanStopping.localized
                        : LocalizationKey.commonStop.localized
                ) {
                    onStop()
                }
                .disabled(cleanup.isStopping)
                .accessibilityIdentifier("execution.stop")
            }
        }
        .padding(SiftMetrics.spacingXL)
        .frame(width: 460)
    }

    private var title: String {
        cleanup.isPreparingCleanup
            ? LocalizationKey.cleanupPreparingTitle.localized
            : LocalizationKey.cleanupExecutingTitle.localized
    }

    private var detail: String {
        guard let progress = cleanup.executionProgress, progress.total > 0 else {
            return LocalizationKey.commonLoading.localized
        }
        return LocalizationKey.cleanupExecutingProgress.localized(progress.done, progress.total)
    }

    private var progressFraction: Double? {
        guard let progress = cleanup.executionProgress, progress.total > 0 else { return nil }
        return progress.fraction
    }
}
