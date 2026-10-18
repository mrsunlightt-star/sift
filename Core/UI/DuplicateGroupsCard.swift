import Shared
import SwiftUI

/// Duplicate groups, largest reclaimable first.
///
/// Each group shows its keeper and the copies that would be removed, and the
/// removal set is per group: §5.5 forbids a single "delete duplicates" action
/// that hides which copy survives.
struct DuplicateGroupsCard: View {
    let groups: [DuplicateGroup]
    @ObservedObject var scan: ScanModel
    @ObservedObject var cleanup: CleanupModel
    @State private var expanded: Set<Int64> = []
    @State private var loadedMembers: [Int64: [DuplicateMember]] = [:]

    var body: some View {
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
                    .buttonStyle(.link)
                }

                Divider()

                ForEach(groups) { group in
                    DuplicateGroupRow(
                        group: group,
                        members: loadedMembers[group.id] ?? group.members,
                        isExpanded: expanded.contains(group.id),
                        cleanup: cleanup,
                        onToggle: { Task { await toggle(group) } }
                    )
                    if group.id != groups.last?.id { Divider() }
                }

                // The list is paged, so it has to say how much of the result it
                // is showing. A list that stopped at one page and looked complete
                // would hide reclaimable space the scan had already found.
                if scan.hasMoreDuplicateGroups || groups.count < scan.duplicateGroupsTotal {
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
                            .buttonStyle(.link)
                        }
                    }
                }
            }
        }
    }

    private func toggle(_ group: DuplicateGroup) async {
        if expanded.contains(group.id) {
            expanded.remove(group.id)
            return
        }
        expanded.insert(group.id)
        if loadedMembers[group.id] == nil {
            loadedMembers[group.id] = await scan.duplicateMembers(for: group)
        }
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
    @ObservedObject var cleanup: CleanupModel
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
            Button(action: onToggle) {
                HStack(spacing: SiftMetrics.spacingM) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
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
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(representativeName))
            .accessibilityValue(Text(group.formattedReclaimable))

            if isExpanded {
                VStack(alignment: .leading, spacing: SiftMetrics.spacingXS) {
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
