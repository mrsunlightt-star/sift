import Shared
import SwiftUI

/// The scan progress panel.
///
/// Every phase is named, the item being examined is shown by leaf name only, and
/// cancelling is always available (§5.1). No infinite spinner without a label.
public struct ScanProgressPanel: View {
    private let model: ScanModel
    @State private var pulse = false

    public init(model: ScanModel) {
        self.model = model
    }

    public var body: some View {
        SiftPanel {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                HStack(spacing: SiftMetrics.spacingM) {
                    phaseIcon
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.phase.labelKey.localized)
                            .font(SiftFont.sectionTitle)
                        Text(progressSummary)
                            .font(SiftFont.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: SiftMetrics.spacingM)
                    if model.isRunning {
                        Button {
                            Task { await model.cancel() }
                        } label: {
                            Text(LocalizationKey.scanCancel.localized)
                        }
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityLabel(Text(LocalizationKey.scanCancel.localized))
                    }
                }

                if model.isRunning {
                    // An indeterminate bar would be invisible here, so the phases
                    // are listed and the current one is marked instead (§5.1:
                    // show the stage, not just a spinner).
                    PhaseTrail(phase: model.phase)
                }

                if !model.skippedLocations.isEmpty {
                    NoticeBanner(
                        level: .warning,
                        message: LocalizationKey.scanPartialNotice
                            .localized(model.skippedLocations.count),
                        actionTitle: needsFullDiskAccess
                            ? LocalizationKey.scanOpenSystemSettings
                            : nil
                    ) {
                        Task { await WorkspaceActions.openFullDiskAccessSettings() }
                    }
                }
            }
        }
        .onAppear { pulse = true }
    }

    private var needsFullDiskAccess: Bool {
        model.skippedLocations.contains { $0.needsFullDiskAccess }
    }

    private var phaseIcon: some View {
        ZStack {
            Circle()
                .fill(SiftColor.color(for: model.phase).opacity(0.14))
                .frame(width: 40, height: 40)
            Image(systemName: model.phase.symbolName)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(SiftColor.color(for: model.phase))
                .scaleEffect(model.isRunning && pulse ? 1.08 : 1.0)
                .animation(
                    model.isRunning
                        ? SiftMotion.scanning
                        : nil,
                    value: pulse
                )
        }
        .accessibilityHidden(true)
    }

    private var progressSummary: String {
        let files = SiftFormat.count(model.progress.filesSeen)
        let items = SiftFormat.count(model.progress.itemsFound)
        if model.isRunning, !model.progress.currentItemName.isEmpty {
            return LocalizationKey.scanCurrentItem.localized(model.progress.currentItemName)
        }
        return "\(LocalizationKey.scanCheckedFiles.localized(files)) · \(LocalizationKey.scanItemsFound.localized(items))"
    }
}

/// The phase list with the active phase marked.
struct PhaseTrail: View {
    let phase: ScanPhase

    private var phases: [ScanPhase] { [.preparing, .scanning, .indexing, .ready] }

    var body: some View {
        HStack(spacing: SiftMetrics.spacingS) {
            ForEach(Array(phases.enumerated()), id: \.offset) { index, candidate in
                let isDone = index < activeIndex
                let isActive = candidate == phase
                HStack(spacing: 5) {
                    Image(systemName: isDone ? "checkmark.circle.fill" : (isActive ? "circle.inset.filled" : "circle"))
                        .font(.system(size: 10))
                    Text(candidate.labelKey.localized)
                        .font(SiftFont.caption)
                }
                .foregroundStyle(isActive ? SiftColor.accent : (isDone ? SiftColor.safe : SiftColor.neutral))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(candidate.labelKey.localized))
                if index < phases.count - 1 {
                    Rectangle()
                        .fill(SiftColor.border)
                        .frame(width: 12, height: 1)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private var activeIndex: Int {
        phases.firstIndex(of: phase == .partial ? .ready : phase) ?? 0
    }
}
