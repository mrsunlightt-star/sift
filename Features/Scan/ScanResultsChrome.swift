import Core
import Shared
import SwiftUI

/// The chrome around a settled scan.
///
/// The result page is one focused object: a completion summary, the filters that
/// change what the list shows, the result groups, and the one action that moves
/// files. These views own that presentation only; ScanView still owns paging,
/// selection and cleanup.
struct ScanResultsToolbar: View {
    let isBusy: Bool
    let onRescan: () -> Void

    var body: some View {
        HStack(spacing: SiftMetrics.spacingM) {
            Text(LocalizationKey.navScan.localized)
                .font(SiftFont.sectionHeading)
                .foregroundStyle(SiftColor.mainText)

            Spacer(minLength: SiftMetrics.spacingM)

            if isBusy {
                HStack(spacing: SiftMetrics.spacingS) {
                    ProgressView()
                        .controlSize(.small)
                    Text(LocalizationKey.scanPhaseReady.localized)
                        .font(SiftFont.caption)
                        .foregroundStyle(SiftColor.secondaryText)
                }
            } else {
                SiftSecondaryButton(
                    titleKey: .scanRescan,
                    symbolName: "arrow.clockwise",
                    action: onRescan
                )
                .accessibilityIdentifier("scan.rescan")
            }
        }
        .padding(.horizontal, SiftMetrics.pagePadding)
        .frame(height: 54)
        .background(SiftColor.scanResultsCanvas)
    }
}
/// The completion headline and its two totals.
///
/// The totals are one block because they answer one question: how much was
/// found, and how much of that can be released. A narrow window moves them below
/// the headline instead of squeezing either side into a truncated sentence.
struct ScanCompletionHero: View {
    let phase: ScanPhase
    let itemCount: Int
    let reclaimableBytes: Int64

    private var statusTitleKey: LocalizationKey {
        switch phase {
        case .cancelled: .scanPhaseCancelled
        case .failed: .scanPhaseFailed
        default: .scanPhaseReady
        }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: SiftMetrics.spacingL) {
                summary
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: SiftMetrics.spacingL)
                metrics
                    .fixedSize(horizontal: true, vertical: false)
            }

            VStack(alignment: .leading, spacing: SiftMetrics.spacingL) {
                summary
                    .fixedSize(horizontal: false, vertical: true)
                metrics
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
            Text(statusTitleKey.localized)
                .font(.system(size: 30 * SiftTypeScale.current.multiplier, weight: .bold))
                .foregroundStyle(SiftColor.mainText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            Text(LocalizationKey.scanResultsTrashHint.localized)
                .font(SiftFont.secondaryHeading)
                .foregroundStyle(SiftColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var metrics: some View {
        HStack(spacing: 0) {
            metric(
                value: SiftFormat.bytes(reclaimableBytes),
                label: LocalizationKey.appsReclaimable.localized,
                valueColor: SiftColor.safeTextColor
            )
            .frame(minWidth: 176, alignment: .leading)

            Rectangle()
                .fill(SiftColor.scanResultCardBorder)
                .frame(width: SiftMetrics.panelBorderWidth, height: 58)
                .padding(.horizontal, SiftMetrics.spacingXL)

            metric(
                value: SiftFormat.count(itemCount),
                label: LocalizationKey.scanResults.localized,
                valueColor: SiftColor.mainText
            )
            .frame(minWidth: 90, alignment: .leading)
        }
        .padding(.horizontal, SiftMetrics.spacingXL)
        .padding(.vertical, SiftMetrics.spacingM)
        .background {
            RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusL, style: .continuous)
                .fill(SiftColor.scanHeroSummaryFill)
        }
        .accessibilityElement(children: .combine)
    }

    private func metric(value: String, label: String, valueColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(SiftFont.heroMetric)
                .monospacedDigit()
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
            Text(label)
                .font(SiftFont.metadata)
                .foregroundStyle(SiftColor.secondaryText)
                .lineLimit(1)
        }
    }
}
/// A result group.
///
/// The page has one surface. Risk is carried by the leading glyph and the words,
/// never by giving each group a different block of background colour.
struct ScanResultRiskCard<Content: View>: View {
    let risk: CleanupRisk
    let itemCount: Int
    let sizeInBytes: Int64
    let isExpanded: Bool
    let onToggle: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: SiftMetrics.spacingM) {
                    riskGlyph

                    VStack(alignment: .leading, spacing: 2) {
                        Text(risk.groupTitleKey.localized)
                            .font(SiftFont.secondaryHeading)
                            .foregroundStyle(SiftColor.mainText)
                        Text(risk.detailKey.localized)
                            .font(SiftFont.supporting)
                            .foregroundStyle(SiftColor.secondaryText)
                            .lineLimit(2)
                    }

                    Spacer(minLength: SiftMetrics.spacingM)

                    Text(LocalizationKey.commonItemCount.counted(itemCount))
                        .font(SiftFont.bodyEmphasis)
                        .foregroundStyle(SiftColor.mainText)
                        .monospacedDigit()

                    Text(SiftFormat.bytes(sizeInBytes))
                        .font(SiftFont.monospacedEmphasis)
                        .foregroundStyle(SiftColor.mainText)
                        .monospacedDigit()

                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(SiftColor.secondaryText)
                        .rotationEffect(.degrees(isExpanded ? 0 : 180))
                        .frame(width: 18)
                }
                .padding(.horizontal, SiftMetrics.spacingM)
                .padding(.vertical, SiftMetrics.spacingS)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(SiftRowButtonStyle())
            .accessibilityLabel(Text(risk.groupTitleKey.localized))
            .accessibilityValue(
                Text(
                    "\(LocalizationKey.commonItemCount.counted(itemCount)), "
                        + SiftFormat.bytes(sizeInBytes)
                )
            )
            .accessibilityHint(Text(risk.detailKey.localized))

            if isExpanded {
                content()
            }
        }
    }

    @ViewBuilder
    private var riskGlyph: some View {
        switch risk {
        case .safe:
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(SiftColor.safeTextColor)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
        case .review:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(SiftColor.reviewTextColor)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
        case .protected:
            Image(systemName: "lock.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SiftColor.protectedTextColor)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
        }
    }
}

struct ScanPermissionResultCard: View {
    let locations: [SkippedLocation]
    let onOpenSettings: () -> Void

    @State private var isExpanded = false

    private var actionableCount: Int {
        locations.count(where: \.isActionable)
    }

    private var actionableLocations: [SkippedLocation] {
        locations.filter(\.isActionable)
    }

    var body: some View {
        if actionableCount > 0 {
            VStack(spacing: 0) {
                HStack(spacing: SiftMetrics.spacingS) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SiftColor.reviewTextColor)
                        .frame(width: 18, height: 18)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalizationKey.scanSkippedActionable.localized(actionableCount))
                            .font(SiftFont.bodyEmphasis)
                            .foregroundStyle(SiftColor.mainText)
                        Text(LocalizationKey.permissionFullDiskAccessDetail.localized)
                            .font(SiftFont.caption)
                            .foregroundStyle(SiftColor.secondaryText)
                            .lineLimit(1)
                    }

                    Spacer(minLength: SiftMetrics.spacingM)

                    Button(action: onOpenSettings) {
                        Text(LocalizationKey.permissionOpenSettings.localized)
                            .font(SiftFont.bodyEmphasis)
                    }
                    .buttonStyle(SiftLinkButtonStyle())

                    Button {
                        isExpanded.toggle()
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(SiftColor.secondaryText)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(
                                width: SiftMetrics.minimumHitTarget,
                                height: SiftMetrics.minimumHitTarget
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(SiftRowButtonStyle())
                    .accessibilityLabel(Text(LocalizationKey.scanSkippedExpandHint.localized))
                }
                .padding(.horizontal, SiftMetrics.spacingM)
                .padding(.vertical, SiftMetrics.spacingS)
                .background {
                    RoundedRectangle(
                        cornerRadius: SiftMetrics.cornerRadiusS,
                        style: .continuous
                    )
                    .fill(SiftColor.controlFill)
                }

                if isExpanded {
                    SkippedLocationsCard(locations: actionableLocations)
                        .padding(.horizontal, SiftMetrics.spacingM)
                        .padding(.top, SiftMetrics.spacingS)
                }
            }
        }
    }
}

struct ScanDuplicateSummaryCard: View {
    let groups: [DuplicateGroup]
    let totalGroupCount: Int
    let reclaimableBytes: Int64
    let onOpen: () -> Void

    @State private var isHovering = false
    @Environment(\.siftReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: SiftMetrics.spacingS) {
                Image(systemName: CleanupCategory.duplicateFiles.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SiftColor.quietText)
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizationKey.filesModeDuplicates.localized)
                        .font(SiftFont.secondaryHeading)
                        .foregroundStyle(SiftColor.mainText)
                    Text(
                        LocalizationKey.filesDuplicateGroups.localized(
                            totalGroupCount,
                            SiftFormat.bytes(reclaimableBytes)
                        )
                    )
                        .font(SiftFont.caption)
                        .foregroundStyle(SiftColor.secondaryText)
                }

                Spacer(minLength: SiftMetrics.spacingM)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SiftColor.secondaryText)
            }
            .padding(.horizontal, SiftMetrics.spacingM)
            .padding(.vertical, SiftMetrics.spacingS)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusS, style: .continuous)
                    .fill(isHovering ? SiftColor.rowHoverFill : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SiftRowButtonStyle())
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : SiftMotion.hover, value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(LocalizationKey.filesKeepHint.localized))
    }
}

struct ScanResultActionBar: View {
    let amount: String
    let selectedCount: Int
    let reviewCount: Int
    let hiddenSelectedCount: Int
    let isWorking: Bool
    let showsSelectionLinks: Bool
    let onSelectAll: () -> Void
    let onDeselectAll: () -> Void
    let onClean: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(SiftColor.scanResultCardBorder)
                .frame(height: SiftMetrics.panelBorderWidth)

            ViewThatFits(in: .horizontal) {
                fullBar
                compactBar
            }
            .padding(.horizontal, SiftMetrics.pagePadding)
            .padding(.vertical, SiftMetrics.spacingM)
        }
        .background(SiftColor.surfaceColor)
    }

    private var fullBar: some View {
        HStack(spacing: SiftMetrics.spacingL) {
            amountBlock
            selectionBlock

            Rectangle()
                .fill(SiftColor.scanResultCardBorder)
                .frame(width: SiftMetrics.panelBorderWidth, height: 36)

            trashHint
                .frame(maxWidth: 250, alignment: .leading)

            Spacer(minLength: SiftMetrics.spacingM)
            actionControls
        }
    }

    private var compactBar: some View {
        VStack(spacing: SiftMetrics.spacingM) {
            HStack(spacing: SiftMetrics.spacingL) {
                amountBlock
                selectionBlock
                Spacer(minLength: SiftMetrics.spacingM)
                cleanButton
            }
            HStack(spacing: SiftMetrics.spacingL) {
                trashHint
                Spacer(minLength: SiftMetrics.spacingM)
                if showsSelectionLinks {
                    selectionLinks
                }
            }
        }
    }

    private var amountBlock: some View {
        Text(amount)
            .font(SiftFont.pageTitle)
            .monospacedDigit()
            .foregroundStyle(selectedCount == 0 ? SiftColor.quietText : SiftColor.safeTextColor)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
    }

    private var selectionBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizationKey.cleanupConfirmSelectedItems.localized(selectedCount))
                .font(SiftFont.bodyEmphasis)
                .foregroundStyle(SiftColor.mainText)
                .lineLimit(1)

            if selectedCount == 0 {
                Text(LocalizationKey.scanResultsReportHint.localized)
                    .font(SiftFont.metadata)
                    .foregroundStyle(SiftColor.quietText)
                    .lineLimit(1)
            } else if reviewCount > 0 || hiddenSelectedCount > 0 {
                HStack(spacing: SiftMetrics.spacingS) {
                    if reviewCount > 0 {
                        Text(LocalizationKey.riskReviewShort.localized)
                            .foregroundStyle(SiftColor.reviewTextColor)
                        Text(SiftFormat.count(reviewCount))
                            .foregroundStyle(SiftColor.secondaryText)
                    }
                    if hiddenSelectedCount > 0 {
                        Text(LocalizationKey.scanHiddenSelected.localized(hiddenSelectedCount))
                            .foregroundStyle(SiftColor.secondaryText)
                    }
                }
                .font(SiftFont.metadata)
                .monospacedDigit()
                .lineLimit(1)
            }
        }
    }

    private var trashHint: some View {
        HStack(spacing: SiftMetrics.spacingS) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(SiftColor.safeTextColor)
            Text(LocalizationKey.scanResultsTrashHint.localized)
                .font(SiftFont.supporting)
                .foregroundStyle(SiftColor.secondaryText)
                .lineLimit(2)
        }
    }

    private var actionControls: some View {
        HStack(spacing: SiftMetrics.spacingL) {
            if showsSelectionLinks {
                selectionLinks
            }
            cleanButton
        }
    }

    private var selectionLinks: some View {
        HStack(spacing: SiftMetrics.spacingL) {
            Button(action: onSelectAll) {
                Text(LocalizationKey.scanSelectAll.localized)
                    .font(SiftFont.bodyEmphasis)
                    .frame(
                        minWidth: SiftMetrics.minimumHitTarget,
                        minHeight: SiftMetrics.minimumHitTarget
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(SiftLinkButtonStyle())
            .keyboardShortcut("a", modifiers: .command)

            Button(action: onDeselectAll) {
                Text(LocalizationKey.scanDeselectAll.localized)
                    .font(SiftFont.bodyEmphasis)
                    .frame(
                        minWidth: SiftMetrics.minimumHitTarget,
                        minHeight: SiftMetrics.minimumHitTarget
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(SiftLinkButtonStyle())
            .keyboardShortcut("a", modifiers: [.command, .shift])
        }
        .fixedSize()
    }

    private var cleanButton: some View {
        SiftPrimaryButton(
            title: LocalizationKey.cleanupConfirmMoveAction.localized,
            symbolName: "trash",
            isEnabled: selectedCount > 0 && !isWorking,
            action: onClean
        )
        .accessibilityIdentifier("scan.clean")
        .fixedSize()
    }
}
