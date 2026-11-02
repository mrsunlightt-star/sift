import AppKit
import Shared
import SwiftUI

/// Duplicate groups, largest reclaimable first.
///
/// Each group shows the copy it keeps and the copies that would be removed, and
/// the removal set is per group: §5.5 forbids a single "delete duplicates"
/// action that hides which copy survives.
///
/// Which copy survives is the user's decision. The scanner proposes one — the
/// oldest — but a proposal is all it is, and a page that rendered it as a fixed
/// green tick left the user with no way to say "keep the one in my project
/// folder instead". The card now records the choice per group and starts from
/// the proposal, so the first render still states which copy is kept.
public struct DuplicateGroupsCard: View {
    let groups: [DuplicateGroup]
    @ObservedObject var scan: ScanModel
    @ObservedObject var cleanup: CleanupModel
    @State private var expanded: Set<Int64> = []
    @State private var loadedMembers: [Int64: [DuplicateMember]] = [:]
    /// Which copy each group keeps. The scanner's proposal until the user makes
    /// one; `DuplicateKeeperSelection` holds the rule.
    @State private var keepers = DuplicateKeeperSelection()

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

                // Said once, above the list: the green copy is a starting point,
                // not a verdict, and the control that changes it is a word in a
                // row the user has not opened yet.
                Text(LocalizationKey.filesKeepHint.localized)
                    .font(SiftFont.caption)
                    .foregroundStyle(SiftColor.subtleText)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                // Lazy: a duplicate result is hundreds of groups, and an eager
                // VStack laid every one of them out on each frame of an
                // expansion. That re-layout — not the curve — is what made
                // opening a group feel slow.
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups) { group in
                        DuplicateGroupRow(
                            group: group,
                            members: members(of: group),
                            keeper: keeper(of: group),
                            isExpanded: expanded.contains(group.id),
                            cleanup: cleanup,
                            onToggle: { toggle(group) },
                            onKeep: { member in keep(member, in: group) }
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

    /// Opens or closes one group, in the frame the click happened in.
    ///
    /// A disclosure is a fact about what is on screen, not a performance: the
    /// rows were previously animated for 0.24 s, and the only thing that
    /// animation reliably produced was a wait between the click and the rows.
    /// The group's copies still load in the background — but they no longer
    /// gate the expansion, so the row opens onto the members the page already
    /// holds and the full list replaces them when it arrives.
    private func toggle(_ group: DuplicateGroup) {
        if expanded.contains(group.id) {
            expanded.remove(group.id)
            return
        }
        expanded.insert(group.id)
        guard loadedMembers[group.id] == nil else { return }
        Task {
            let members = await scan.duplicateMembers(for: group)
            guard !members.isEmpty else { return }
            loadedMembers[group.id] = members
        }
    }

    private func members(of group: DuplicateGroup) -> [DuplicateMember] {
        loadedMembers[group.id] ?? group.members
    }

    /// The copy this group keeps: the user's choice, or the scanner's proposal
    /// until the user makes one.
    private func keeper(of group: DuplicateGroup) -> URL? {
        keepers.keeper(of: group)
    }

    /// Makes `member` the copy this group keeps.
    ///
    /// Only the two rows whose meaning changed are touched: the copy the user
    /// just kept leaves the removal set and the copy it replaced joins it.
    /// Rebuilding the whole group's selection would discard the individual
    /// choices the user had already made in it.
    private func keep(_ member: DuplicateMember, in group: DuplicateGroup) {
        guard let change = keepers.choose(member.url, in: group) else { return }
        cleanup.setSelected(false, for: item(for: member))
        if let released = change.released,
           let previous = members(of: group).first(where: { $0.url == released }) {
            cleanup.setSelected(true, for: item(for: previous))
        }
    }

    /// Selects every copy except the one each group keeps.
    private func selectAllRemovable() {
        for group in groups {
            let keeperURL = keeper(of: group)
            for member in members(of: group) where member.url != keeperURL {
                cleanup.setSelected(true, for: item(for: member))
            }
        }
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

/// One duplicate group: the copy it keeps, then the copies that would go.
struct DuplicateGroupRow: View {
    let group: DuplicateGroup
    let members: [DuplicateMember]
    let keeper: URL?
    let isExpanded: Bool
    @ObservedObject var cleanup: CleanupModel
    let onToggle: () -> Void
    let onKeep: (DuplicateMember) -> Void

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

            if isExpanded {
                LazyVStack(alignment: .leading, spacing: SiftMetrics.spacingXS) {
                    ForEach(members) { member in
                        memberRow(member)
                    }
                }
            }
        }
        .padding(.vertical, SiftMetrics.spacingXS)
    }

    @ViewBuilder
    private func memberRow(_ member: DuplicateMember) -> some View {
        let isKeeper = keeper == member.url
        HStack(spacing: SiftMetrics.spacingM) {
            if isKeeper {
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
            // A copy that is not the keeper is a checkbox; its name is the thing
            // the user reads, so clicking the name has to do what clicking the
            // box does.
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isKeeper else { return }
                let item = item(for: member)
                cleanup.setSelected(!cleanup.isSelected(item), for: item)
            }

            Spacer(minLength: SiftMetrics.spacingS)

            // The same entry point every other row on this page has: the path is
            // the only thing that tells two copies of one file apart, so a
            // duplicate the page cannot judge has to be reachable in the Finder.
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([member.url])
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(SiftLinkButtonStyle())
            .help(LocalizationKey.filesRevealInFinder.localized)
            .accessibilityLabel(Text(LocalizationKey.filesRevealInFinder.localized))

            Text(member.formattedSize)
                .font(SiftFont.monospacedNumber)
                .foregroundStyle(.secondary)

            // Keeping this copy is a choice, not a label: the green text on the
            // kept row is the current state, and the same words on any other row
            // are the control that moves it there.
            if isKeeper {
                Text(LocalizationKey.filesKeepThis.localized)
                    .font(SiftFont.caption)
                    .foregroundStyle(SiftColor.safe)
            } else {
                Button {
                    onKeep(member)
                } label: {
                    Text(LocalizationKey.filesKeepThis.localized)
                        .font(SiftFont.caption)
                }
                .buttonStyle(SiftLinkButtonStyle())
                .help(member.displayPath)
                .accessibilityLabel(Text(LocalizationKey.filesKeepThis.localized))
            }
        }
        .padding(.leading, SiftMetrics.spacingL)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([member.url])
            } label: {
                Label(
                    LocalizationKey.filesRevealInFinder.localized,
                    systemImage: "folder"
                )
            }
            if !isKeeper {
                Button {
                    onKeep(member)
                } label: {
                    Label(
                        LocalizationKey.filesKeepThis.localized,
                        systemImage: "checkmark.circle"
                    )
                }
            }
        }
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
