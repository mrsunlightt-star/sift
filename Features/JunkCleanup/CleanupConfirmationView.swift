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
public struct CleanupConfirmationView: View {
    @ObservedObject var cleanup: CleanupModel
    @ObservedObject var preferences: PreferencesSnapshot
    let onConfirm: () -> Void
    let onCancel: () -> Void
    let onToggleSkipConfirmation: (Bool) -> Void

    /// Which disclosure is open. Both start closed: the panel answers the
    /// common question ("how much, where, can I undo it") without scrolling.
    private enum Detail: Hashable { case items, recoverability }
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
        VStack(alignment: .leading, spacing: SiftMetrics.spacingL) {
            header
            locations
            itemList
            recoverability
            counts
            if !preferences.hasCompletedCleanup {
                NoticeBanner(level: .information, titleKey: .scanFirstRunReview)
            }
            if cleanup.approvedIncludesItemsNeedingReview {
                NoticeBanner(
                    level: .warning,
                    message: LocalizationKey.cleanupConfirmReviewCount.localized(reviewCount)
                )
            }
            Divider()
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

    private var header: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
            Text(LocalizationKey.cleanupConfirmTitleCount.localized(cleanup.approvedCount))
                .font(SiftFont.title)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: SiftMetrics.spacingS) {
                fact(SiftFormat.count(cleanup.approvedCount), .commonItemCount)
                fact(SiftFormat.bytes(cleanup.approvedBytes), nil)
            }
            if !cleanup.approvedByCategory.isEmpty {
                Text(
                    LocalizationKey.scanResultsCategoryTotals.localized(
                        cleanup.approvedByCategory
                            .map { "\($0.category.titleKey.localized) \($0.formattedSize)" }
                            .joined(separator: ", ")
                    )
                )
                .font(SiftFont.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One fact chip. `countKey` names the unit, so a chip never reads as a bare
    /// number.
    private func fact(_ value: String, _ countKey: LocalizationKey?) -> some View {
        HStack(spacing: 5) {
            Text(value)
                .font(SiftFont.badge)
                .monospacedDigit()
            if let countKey {
                Text(countKey.localized.replacingOccurrences(of: "%d ", with: ""))
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, SiftMetrics.spacingS)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusS, style: .continuous)
                .fill(SiftColor.subtleFill)
        )
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

    private var locations: some View {
        let all = approvedLocations
        let shown = all.prefix(3)
        let extra = all.count - shown.count
        return VStack(alignment: .leading, spacing: SiftMetrics.spacingXS) {
            Text(LocalizationKey.cleanupConfirmLocations.localized)
                .font(SiftFont.caption)
                .foregroundStyle(.secondary)
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
                                .fill(SiftColor.subtleFill)
                        )
                }
                if extra > 0 {
                    Text("+\(extra)")
                        .font(SiftFont.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - The list

    private var itemList: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
            disclosureButton(
                .items,
                title: expanded.contains(.items)
                    ? LocalizationKey.cleanupConfirmHideItems.localized
                    : LocalizationKey.cleanupConfirmShowItems.localized(cleanup.approvedCount)
            )

            if expanded.contains(.items) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(cleanup.approvedItems) { item in
                            approvedRow(item)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 220)
                .background(
                    RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusM, style: .continuous)
                        .fill(SiftColor.subtleFill)
                )
                .clipShape(RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusM, style: .continuous))
                .transition(.opacity)
            }
        }
    }

    private func approvedRow(_ item: CleanupItem) -> some View {
        HStack(spacing: SiftMetrics.spacingM) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(SiftFont.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.displayPath)
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: SiftMetrics.spacingS)
            Text(SiftFormat.bytes(item.sizeInBytes))
                .font(SiftFont.monospacedNumber)
            RiskBadge(risk: item.risk.level)
        }
        .padding(.horizontal, SiftMetrics.spacingM)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var recoverability: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
            disclosureButton(.recoverability, title: LocalizationKey.cleanupConfirmWhyRecoverable.localized)
            if expanded.contains(.recoverability) {
                VStack(alignment: .leading, spacing: SiftMetrics.spacingXS) {
                    Text(LocalizationKey.cleanupConfirmUndoNotice.localized)
                    Text(LocalizationKey.scanResultsProtectedHint.localized)
                }
                .font(SiftFont.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, SiftMetrics.spacingM)
                .transition(.opacity)
            }
        }
    }

    private func disclosureButton(_ detail: Detail, title: String) -> some View {
        Button {
            withAnimation(SiftMotion.expand) {
                if expanded.contains(detail) {
                    expanded.remove(detail)
                } else {
                    expanded.insert(detail)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(expanded.contains(detail) ? 0 : -90))
                Text(title)
                    .font(SiftFont.caption)
            }
        }
        .buttonStyle(SiftLinkButtonStyle())
        .accessibilityAddTraits(expanded.contains(detail) ? [.isSelected] : [])
    }

    // MARK: - Counts

    /// What pre-flight found that is *not* moving. Two counts, because "eleven
    /// items are protected" and "three files were already gone" are different
    /// facts and the old panel showed one of them without a number.
    @ViewBuilder
    private var counts: some View {
        if let preflight = cleanup.preflight {
            VStack(alignment: .leading, spacing: 2) {
                if !preflight.protected.isEmpty {
                    Text(LocalizationKey.cleanupConfirmProtectedCount.localized(preflight.protected.count))
                        .foregroundStyle(SiftColor.textColor(for: .protected))
                }
                if !preflight.skipped.isEmpty {
                    Text(LocalizationKey.cleanupConfirmMissingCount.localized(preflight.skipped.count))
                        .foregroundStyle(SiftColor.textColor(for: .review))
                }
                if !preflight.subsumed.isEmpty {
                    Text(LocalizationKey.cleanupConfirmSelectedItems.localized(preflight.subsumed.count))
                        .foregroundStyle(.secondary)
                }
            }
            .font(SiftFont.caption)
            .fixedSize(horizontal: false, vertical: true)
        }
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
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)

            Spacer(minLength: SiftMetrics.spacingM)

            VStack(alignment: .trailing, spacing: SiftMetrics.spacingS) {
                Text(
                    "\(LocalizationKey.commonItemCount.counted(cleanup.approvedCount)) · \(SiftFormat.bytes(cleanup.approvedBytes))"
                )
                .font(SiftFont.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)

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
