import Core
import Shared
import SwiftUI

/// The confirmation panel (§5.2).
///
/// Four things this panel must do, all of them from the specification:
///
///  * name the action and the size ("Move to Trash" above "24 items · 10.2 GB"),
///  * group the selection by type,
///  * state that everything is recoverable from the Trash,
///  * warn when the selection includes items marked for review.
///
/// The panel is the last checkpoint, so it has to be *checkable*: the result
/// list showed paths and the confirmation used to show only three category
/// totals, which meant the user knew less at the moment of acting than a second
/// earlier. The item list below is read-only on purpose — the selection was made
/// on the page behind this sheet, and a second place to change it is how a
/// summary and a move come to describe two batches.
///
/// The button no longer carries the count. In German and Russian that label ran
/// past 60 characters inside a one-line button, so the action and the quantity
/// are separate lines: the button says what happens, the line above says how
/// much.
///
/// Everything here comes from `cleanup.approvedItems` — the pre-flight snapshot,
/// not the live selection (invariant 27), so a checkbox clicked behind the sheet
/// cannot make the sentence and the move describe two batches. Only one item
/// shape is *not* from that snapshot: the counts of what pre-flight refused,
/// which the report states on its own.
///
/// The hierarchy is plain: a title, the facts, hairlines, and one filled surface
/// at the very bottom for the two buttons. A dialog that is a stack of cards
/// reads as a page; this is the last thing between a click and the Trash, so it
/// is one column that can be read top to bottom.
public struct CleanupConfirmationView: View {
    @ObservedObject var cleanup: CleanupModel
    @ObservedObject var preferences: PreferencesSnapshot
    let onConfirm: () -> Void
    let onCancel: () -> Void
    let onToggleSkipConfirmation: (Bool) -> Void

    /// Which disclosure is open. Both start closed: the panel answers the
    /// common question ("how much, where, can I undo it") without scrolling.
    private enum Detail: Hashable { case items, recoverable }
    @State private var expanded: Set<Detail> = []

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
        VStack(alignment: .leading, spacing: 0) {
            // One column, read top to bottom, sized by its content: the two
            // disclosures start closed, so the common question ("how much, where,
            // can I undo it") is answered without a scroll, and the only part that
            // can grow — the item list — scrolls inside its own 220 pt frame.
            VStack(alignment: .leading, spacing: SiftMetrics.spacingL) {
                titleBlock
                SiftHairline()
                destination
                itemList
                counts
                whyRecoverable
                if !preferences.hasCompletedCleanup {
                    NoticeBanner(level: .information, titleKey: .scanFirstRunReview)
                }
                if cleanup.approvedIncludesItemsNeedingReview {
                    NoticeBanner(
                        level: .warning,
                        message: LocalizationKey.cleanupConfirmReviewCount.localized(reviewCount)
                    )
                }
            }

            SiftHairline()
                .padding(.top, SiftMetrics.spacingL)
            safety
            footer
        }
        .padding(SiftMetrics.spacingXL)
        // 640 pt: the widest sheet in the product, because this is the one that
        // shows paths. The host no longer adds its own padding on top (the two
        // used to disagree by 8 pt and clip the trailing edge).
        .frame(width: 640)
    }

    private var reviewCount: Int {
        cleanup.approvedItems.filter { $0.risk == .review }.count
    }

    // MARK: - Header

    /// The title states the action and the number of items it acts on — the
    /// sheet's own frame has no title bar to state either.
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
            Text(LocalizationKey.cleanupConfirmTitleCount.localized(cleanup.approvedCount))
                .font(SiftFont.title)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .firstTextBaseline, spacing: SiftMetrics.spacingS) {
                Text(SiftFormat.bytes(cleanup.approvedBytes))
                    .font(SiftFont.metricLarge)
                    .monospacedDigit()
                    .foregroundStyle(SiftColor.mainText)
                Text(LocalizationKey.commonItemCount.counted(cleanup.approvedCount))
                    .font(SiftFont.caption)
                    .foregroundStyle(SiftColor.secondaryText)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)

            if !cleanup.approvedByCategory.isEmpty {
                Text(
                    LocalizationKey.scanResultsCategoryTotals.localized(
                        cleanup.approvedByCategory
                            .map { "\($0.category.titleKey.localized) \($0.formattedSize)" }
                            .joined(separator: ", ")
                    )
                )
                .font(SiftFont.caption)
                .foregroundStyle(SiftColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Where

    /// The containers the approved items live in, home-relative.
    ///
    /// Two components deep: `~/Library/Caches` is a place the user recognises,
    /// `~/Library/Caches/Google/Chrome/Default/Cache` is a path they have to
    /// trust. Grouping keeps twenty rows from producing twenty locations.
    private var approvedLocations: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var seen = Set<String>()
        var out: [String] = []
        for item in cleanup.approvedItems {
            let path = item.url.path
            let components: [Substring]
            let prefix: String
            if path == home || path.hasPrefix(home + "/") {
                prefix = "~"
                components = Array(path.dropFirst(home.count).split(separator: "/"))
            } else {
                prefix = ""
                components = Array(path.split(separator: "/"))
            }
            let shown = components.prefix(2).joined(separator: "/")
            let location = shown.isEmpty ? (prefix.isEmpty ? "/" : prefix) : "\(prefix)/\(shown)"
            if seen.insert(location).inserted {
                out.append(location)
            }
        }
        return out.sorted()
    }

    /// Where the items are, as a summary rather than a path list.
    private var destination: some View {
        let all = approvedLocations
        let shown = all.prefix(3)
        let extra = all.count - shown.count
        return VStack(alignment: .leading, spacing: SiftMetrics.spacingXS) {
            Text(LocalizationKey.cleanupConfirmLocations.localized)
                .font(SiftFont.caption)
                .foregroundStyle(SiftColor.secondaryText)
            HStack(spacing: SiftMetrics.spacingS) {
                ForEach(Array(shown), id: \.self) { location in
                    Text(location)
                        .font(SiftFont.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, SiftMetrics.spacingS)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusS, style: .continuous)
                                .fill(SiftColor.controlFill)
                        )
                }
                if extra > 0 {
                    Text("+\(extra)")
                        .font(SiftFont.caption)
                        .foregroundStyle(SiftColor.secondaryText)
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - The list

    private var itemList: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
            Button {
                // Immediate: a disclosure states what is on screen, and the
                // animation only ever inserted a wait between the click and the
                // rows (invariant 45).
                toggle(.items)
            } label: {
                HStack(spacing: SiftMetrics.spacingS) {
                    Image(systemName: expanded.contains(.items) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(SiftColor.quietText)
                        .frame(width: 10)
                    Text(
                        expanded.contains(.items)
                            ? LocalizationKey.cleanupConfirmHideItems.localized
                            : LocalizationKey.cleanupConfirmShowItems.localized(cleanup.approvedCount)
                    )
                    .font(SiftFont.caption)
                    .foregroundStyle(SiftColor.actionGreen)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(expanded.contains(.items) ? [.isSelected] : [])

            if expanded.contains(.items) {
                SiftSection(style: .plain) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(cleanup.approvedItems.enumerated()), id: \.element.id) { index, item in
                            if index > 0 {
                                SiftHairline()
                            }
                            approvedRow(item)
                        }
                    }
                }
                .frame(maxHeight: 220)
                .clipped()
            }
        }
    }

    /// One approved item, as the move will act on it: name, path, size, risk.
    private func approvedRow(_ item: CleanupItem) -> some View {
        HStack(spacing: SiftMetrics.spacingM) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(SiftFont.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.displayPath)
                    .font(SiftFont.caption)
                    .foregroundStyle(SiftColor.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: SiftMetrics.spacingS)
            Text(SiftFormat.bytes(item.sizeInBytes))
                .font(SiftFont.monospacedNumber)
                .monospacedDigit()
                .foregroundStyle(SiftColor.mainText)
            RiskBadge(risk: item.risk.level)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private func toggle(_ detail: Detail) {
        if expanded.contains(detail) {
            expanded.remove(detail)
        } else {
            expanded.insert(detail)
        }
    }

    // MARK: - Counts

    /// What pre-flight found that is *not* moving. Two counts, because "eleven
    /// items are protected" and "three files were already gone" are different
    /// facts and the old panel showed one of them without a number.
    @ViewBuilder
    private var counts: some View {
        if let preflight = cleanup.preflight {
            VStack(alignment: .leading, spacing: 4) {
                if !preflight.protected.isEmpty {
                    countLine(
                        LocalizationKey.cleanupConfirmProtectedCount.localized(preflight.protected.count),
                        tint: SiftColor.protectedTextColor,
                        symbolName: "lock.fill"
                    )
                }
                if !preflight.skipped.isEmpty {
                    countLine(
                        LocalizationKey.cleanupConfirmMissingCount.localized(preflight.skipped.count),
                        tint: SiftColor.reviewTextColor,
                        symbolName: "questionmark.circle.fill"
                    )
                }
                if !preflight.subsumed.isEmpty {
                    countLine(
                        LocalizationKey.cleanupConfirmSelectedItems.localized(preflight.subsumed.count),
                        tint: SiftColor.secondaryText,
                        symbolName: "square.stack.3d.up"
                    )
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A fact with a glyph, so the line is not read by its colour.
    private func countLine(_ text: String, tint: Color, symbolName: String) -> some View {
        HStack(spacing: SiftMetrics.spacingXS) {
            Image(systemName: symbolName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(SiftFont.caption)
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Recoverability

    /// Why this is recoverable, and what is not moving.
    ///
    /// The sentence is in the footer, beside the button, because that is where it
    /// is read. This disclosure holds the second half of the answer: what the
    /// product refuses to move, and where the items go.
    private var whyRecoverable: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingXS) {
            Button {
                toggle(.recoverable)
            } label: {
                HStack(spacing: SiftMetrics.spacingS) {
                    Image(systemName: expanded.contains(.recoverable) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(SiftColor.quietText)
                        .frame(width: 10)
                    Text(LocalizationKey.cleanupConfirmWhyRecoverable.localized)
                        .font(SiftFont.caption)
                        .foregroundStyle(SiftColor.actionGreen)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(expanded.contains(.recoverable) ? [.isSelected] : [])

            if expanded.contains(.recoverable) {
                VStack(alignment: .leading, spacing: SiftMetrics.spacingXS) {
                    Text(LocalizationKey.scanResultsProtectedHint.localized)
                    Text(LocalizationKey.scanResultsReportHint.localized)
                }
                .font(SiftFont.caption)
                .foregroundStyle(SiftColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 18)
            }
        }
    }

    /// The promise, stated once, next to the control that keeps it.
    private var safety: some View {
        HStack(alignment: .top, spacing: SiftMetrics.spacingS) {
            Image(systemName: "arrow.uturn.backward.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SiftColor.quietText)
                .padding(.top, 2)
            Text(LocalizationKey.cleanupConfirmUndoNotice.localized)
                .font(SiftFont.caption)
                .foregroundStyle(SiftColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, SiftMetrics.spacingM)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(alignment: .bottom, spacing: SiftMetrics.spacingM) {
            Toggle(isOn: Binding(
                get: { preferences.skipConfirmation },
                set: { onToggleSkipConfirmation($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizationKey.cleanupConfirmSkipConfirmation.localized)
                        .font(SiftFont.body)
                    Text(LocalizationKey.settingsSkipConfirmationWarning.localized)
                        .font(SiftFont.caption)
                        .foregroundStyle(SiftColor.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)

            Spacer(minLength: SiftMetrics.spacingM)

            VStack(alignment: .trailing, spacing: SiftMetrics.spacingS) {
                // The quantity, beside the button rather than inside it: the
                // label states the action, the line states how much it acts on.
                Text(
                    "\(LocalizationKey.commonItemCount.counted(cleanup.approvedCount)) · \(SiftFormat.bytes(cleanup.approvedBytes))"
                )
                .font(SiftFont.caption)
                .monospacedDigit()
                .foregroundStyle(SiftColor.secondaryText)

                HStack(spacing: SiftMetrics.spacingM) {
                    SiftSecondaryButton(titleKey: .cleanupConfirmCancel) {
                        onCancel()
                    }
                    .keyboardShortcut(.cancelAction)

                    SiftPrimaryButton(titleKey: .cleanupConfirmMoveAction) {
                        onConfirm()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}
