import Shared
import SwiftUI

/// Duplicate groups, largest reclaimable first.
///
/// Each group shows its keeper and the copies that would be removed, and the
/// removal set is per group: §5.5 forbids a single "delete duplicates" action
/// that hides which copy survives.
public struct DuplicateGroupsCard: View {
    let groups: [DuplicateGroup]
    @ObservedObject var scan: ScanModel
    @ObservedObject var cleanup: CleanupModel
    @State private var expanded: Set<Int64> = []
    @State private var loadedMembers: [Int64: [DuplicateMember]] = [:]
    @State private var loadingMembers: Set<Int64> = []

    @Environment(\.siftReduceMotion) private var reduceMotion

    public init(groups: [DuplicateGroup], scan: ScanModel, cleanup: CleanupModel) {
        self.groups = groups
        self.scan = scan
        self.cleanup = cleanup
    }

    public var body: some View {
        SiftPanel(padding: SiftMetrics.spacingL) {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
                HStack(spacing: SiftMetrics.spacingM) {
                    IconTile(symbolName: CleanupCategory.duplicateFiles.symbolName, tint: SiftColor.categoryPalette[7])
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalizationKey.filesModeDuplicates.localized)
                            .font(SiftFont.bodyEmphasis)
                        Text(
                            LocalizationKey.filesDuplicateGroups.localized(
                                groups.count,
                                SiftFormat.bytes(groups.reduce(0) { $0 + $1.reclaimableSizeInBytes })
                            )
                        )
                        .font(SiftFont.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        selectAllRemovable()
                    } label: {
                        Text(LocalizationKey.scanSelectAll.localized)
                            .font(SiftFont.caption)
                    }
                    .buttonStyle(SiftLinkButtonStyle())
                }

                Divider()

                // Lazy: a duplicate result is hundreds of groups, and an eager
                // VStack laid every one of them out on each frame of an
                // expansion animation. That re-layout — not the curve — is what
                // made opening a group feel slow.
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups) { group in
                        DuplicateGroupRow(
                            group: group,
                            members: loadedMembers[group.id] ?? group.members,
                            isExpanded: expanded.contains(group.id),
                            isLoading: loadingMembers.contains(group.id),
                            cleanup: cleanup,
                            onToggle: { toggle(group) }
                        )
                        if group.id != groups.last?.id { Divider() }
                    }
                }

                // The list is paged, so it has to say how much of the result it
                // is showing. A list that stopped at one page and looked complete
                // would hide reclaimable space the scan had already found.
                if scan.hasMoreDuplicateGroups {
                    Divider()
                    HStack(spacing: SiftMetrics.spacingM) {
                        Text(
                            LocalizationKey.filesDuplicateGroupsShown.localized(
                                groups.count,
                                scan.duplicateGroupsTotal
                            )
                        )
                        .font(SiftFont.caption)
                        .foregroundStyle(.secondary)
                        Spacer()
                        if scan.hasMoreDuplicateGroups {
                            Button {
                                Task { await scan.loadMoreDuplicateGroups() }
                            } label: {
                                Text(LocalizationKey.commonLoadMore.localized)
                                    .font(SiftFont.caption)
                            }
                            .buttonStyle(SiftLinkButtonStyle())
                        }
                    }
                }
            }
        }
    }

    /// Opens or closes one group.
    ///
    /// A group's copies are read *before* it opens, so the height animates once
    /// over content that is already there. The previous order animated an empty
    /// container and filled it in afterwards, which reads as a slow row that
    /// eventually produces something.
    private func toggle(_ group: DuplicateGroup) {
        if expanded.contains(group.id) {
            withAnimation(reduceMotion ? nil : SiftMotion.expand) { _ = expanded.remove(group.id) }
            return
        }
        Task { await open(group) }
    }

    private func open(_ group: DuplicateGroup) async {
        if loadedMembers[group.id] == nil, !loadingMembers.contains(group.id) {
            loadingMembers.insert(group.id)
            let members = await scan.duplicateMembers(for: group)
            loadedMembers[group.id] = members
            loadingMembers.remove(group.id)
        }
        withAnimation(reduceMotion ? nil : SiftMotion.expand) { _ = expanded.insert(group.id) }
    }

    /// Selects every copy the scanner recommends removing, never the keepers.
    private func selectAllRemovable() {
        for group in groups {
            let members = loadedMembers[group.id] ?? group.members
            for member in members where !member.isRecommendedToKeep {
                let item = CleanupItem(
                    url: member.url,
                    displayName: member.displayName,
                    category: .duplicateFiles,
                    risk: .review,
                    sizeInBytes: member.sizeInBytes,
                    fileCount: 1,
                    explanationKey: "cleanup.explanation.duplicates",
                    sourceRuleID: "duplicate-files",
                    modifiedAt: member.modifiedAt
                )
                cleanup.setSelected(true, for: item)
                cleanup.appendItems([item])
            }
        }
    }
}

/// One duplicate group: the keeper, then the removable copies.
struct DuplicateGroupRow: View {
    let group: DuplicateGroup
    let members: [DuplicateMember]
    let isExpanded: Bool
    var isLoading: Bool = false
    @ObservedObject var cleanup: CleanupModel
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
            Button(action: onToggle) {
                HStack(spacing: SiftMetrics.spacingM) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(representativeName)
                            .font(SiftFont.body)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(LocalizationKey.filesGroupMembers.localized(members.count))
                            .font(SiftFont.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: SiftMetrics.spacingS)
                    Text(group.formattedReclaimable)
                        .font(SiftFont.monospacedNumber)
                        .foregroundStyle(SiftColor.review)
                    RiskBadge(risk: .review)
                }
                // The row is a target across its whole width, not only where
                // it happens to draw a glyph: without a content shape the space
                // between the name and the size was dead, which is why clicking
                // the row appeared to do nothing unless the pointer landed on
                // the file name or the chevron.
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(representativeName))
            .accessibilityValue(Text(group.formattedReclaimable))

            if isLoading && !isExpanded {
                Text(LocalizationKey.commonLoading.localized)
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, SiftMetrics.spacingL + 10)
            }

            if isExpanded {
                LazyVStack(alignment: .leading, spacing: SiftMetrics.spacingXS) {
                    ForEach(members) { member in
                        HStack(spacing: SiftMetrics.spacingM) {
                            if member.isRecommendedToKeep {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(SiftColor.safe)
                                    .accessibilityLabel(Text(LocalizationKey.filesKeepThis.localized))
                            } else {
                                Toggle(
                                    isOn: Binding(
                                        get: { cleanup.isSelected(item(for: member)) },
                                        set: { cleanup.setSelected($0, for: item(for: member)) }
                                    )
                                ) {
                                    EmptyView()
                                }
                                .labelsHidden()
                                .toggleStyle(.checkbox)
                                .accessibilityLabel(Text(member.displayName))
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(member.displayName)
                                    .font(SiftFont.body)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(member.displayPath)
                                    .font(SiftFont.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            // A copy that is not the keeper is a checkbox; its
                            // name is the thing the user reads, so clicking the
                            // name has to do what clicking the box does.
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard !member.isRecommendedToKeep else { return }
                                let item = item(for: member)
                                cleanup.setSelected(!cleanup.isSelected(item), for: item)
                            }
                            Spacer(minLength: SiftMetrics.spacingS)
                            if member.isRecommendedToKeep {
                                Text(LocalizationKey.filesKeepThis.localized)
                                    .font(SiftFont.caption)
                                    .foregroundStyle(SiftColor.safe)
                            } else {
                                Text(member.formattedSize)
                                    .font(SiftFont.monospacedNumber)
                            }
                        }
                        .padding(.leading, SiftMetrics.spacingL)
                    }
                }
            }
        }
        .padding(.vertical, SiftMetrics.spacingXS)
    }

    private var representativeName: String {
        members.first?.displayName ?? group.contentHash.prefix(12).description
    }

    /// The cleanup item a member maps to, so selection survives re-renders.
    private func item(for member: DuplicateMember) -> CleanupItem {
        CleanupItem(
            url: member.url,
            displayName: member.displayName,
            category: .duplicateFiles,
            risk: .review,
            sizeInBytes: member.sizeInBytes,
            fileCount: 1,
            explanationKey: "cleanup.explanation.duplicates",
            sourceRuleID: "duplicate-files",
            modifiedAt: member.modifiedAt
        )
    }
}
