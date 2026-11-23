import AppKit
import Shared
import SwiftUI

/// Duplicate groups, largest reclaimable first.
///
/// Each group shows every copy with the same checkbox, and the removal set is
/// per group: §5.5 forbids a single "delete duplicates" action that hides which
/// copies the user chose.
///
/// Which copy survives is the user's decision. The scanner proposes one — the
/// oldest — but the page does not apply that proposal or select any member.
/// Every copy starts unchecked and is independently selectable.
public struct DuplicateGroupsCard: View {
    let groups: [DuplicateGroup]
    @ObservedObject var scan: ScanModel
    @ObservedObject var cleanup: CleanupModel
    @State private var expanded: Set<Int64> = []
    @State private var loadedMembers: [Int64: [DuplicateMember]] = [:]
    private let showsHeading: Bool

    public init(
        groups: [DuplicateGroup],
        scan: ScanModel,
        cleanup: CleanupModel,
        showsHeading: Bool = true
    ) {
        self.groups = groups
        self.scan = scan
        self.cleanup = cleanup
        self.showsHeading = showsHeading
    }

    public var body: some View {
        // No panel: a bordered card around one result set made this section look
        // like a different species from the risk groups above it — it had its own
        // icon tile, its own padding and its own heading ramp. It is one more
        // group of the same result set, so it wears the same heading the rest of
        // the list wears and sits on the page with no surface of its own.
        VStack(alignment: .leading, spacing: 0) {
            if showsHeading {
                heading

                Text(LocalizationKey.filesKeepHint.localized)
                    .font(SiftFont.caption)
                    .foregroundStyle(SiftColor.quietText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 14 + SiftMetrics.spacingS)
                    .padding(.bottom, SiftMetrics.spacingS)
            }

            // Lazy: a duplicate result is hundreds of groups, and an eager
            // VStack laid every one of them out on each frame of an expansion.
            // That re-layout — not the curve — is what made opening a group feel
            // slow.
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groups) { group in
                    DuplicateGroupRow(
                        group: group,
                        members: members(of: group),
                        isExpanded: expanded.contains(group.id),
                        cleanup: cleanup,
                        onToggle: { toggle(group) }
                    )
                }
            }

            // The list is paged, so it has to say how much of the result it is
            // showing. A list that stopped at one page and looked complete would
            // hide reclaimable space the scan had already found.
            if scan.hasMoreDuplicateGroups {
                HStack(spacing: SiftMetrics.spacingM) {
                    Text(
                        LocalizationKey.filesDuplicateGroupsShown.localized(
                            groups.count,
                            scan.duplicateGroupsTotal
                        )
                    )
                    .font(SiftFont.caption)
                    .foregroundStyle(SiftColor.quietText)
                    Spacer()
                    Button {
                        Task { await scan.loadMoreDuplicateGroups() }
                    } label: {
                        Text(LocalizationKey.commonLoadMore.localized)
                            .font(SiftFont.caption)
                    }
                    .buttonStyle(SiftLinkButtonStyle())
                }
                .padding(.vertical, SiftMetrics.spacingM)
            }
        }
        .padding(.top, SiftMetrics.spacingL)
    }

    /// The section's heading, in the shape the risk groups use.
    ///
    /// Same glyph slot, same type ramp, same count-then-bytes order, and the same
    /// select-all on the right. A reader should not have to learn that this one
    /// section is a heading of a different kind.
    private var heading: some View {
        HStack(spacing: SiftMetrics.spacingM) {
            HStack(spacing: SiftMetrics.spacingS) {
                Image(systemName: CleanupCategory.duplicateFiles.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SiftColor.quietText)
                    .frame(width: 14)
                Text(LocalizationKey.filesModeDuplicates.localized)
                    .font(SiftFont.secondaryHeading)
                    .foregroundStyle(SiftColor.mainText)
                Text(LocalizationKey.filesDuplicateGroups.localized(
                    groups.count,
                    SiftFormat.bytes(groups.reduce(0) { $0 + $1.reclaimableSizeInBytes })
                ))
                .font(SiftFont.caption)
                .foregroundStyle(SiftColor.secondaryText)
                .monospacedDigit()
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: SiftMetrics.spacingS)

            Button {
                toggleAllDuplicates()
            } label: {
                Text(
                    allDuplicatesSelected
                        ? LocalizationKey.scanDeselectAll.localized
                        : LocalizationKey.scanSelectAll.localized
                )
                    .font(SiftFont.caption)
            }
            .buttonStyle(SiftLinkButtonStyle())
        }
        .padding(.bottom, SiftMetrics.spacingS)
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

    /// Every member represented by the currently loaded groups.
    private var duplicateItems: [CleanupItem] {
        groups.flatMap { group in
            members(of: group).map { item(for: $0) }
        }
    }

    private var allDuplicatesSelected: Bool {
        let items = duplicateItems
        return !items.isEmpty && items.allSatisfy { cleanup.isSelected($0) }
    }

    /// All duplicate rows start unchecked. Bulk selection changes the set only
    /// when the user asks for it, and the same control clears that explicit set.
    private func toggleAllDuplicates() {
        let items = duplicateItems
        if items.allSatisfy({ cleanup.isSelected($0) }) {
            for item in items {
                cleanup.setSelected(false, for: item)
            }
        } else {
            cleanup.selectAll(in: items)
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

/// One duplicate group and its independently selectable copies.
struct DuplicateGroupRow: View {
    let group: DuplicateGroup
    let members: [DuplicateMember]
    let isExpanded: Bool
    @ObservedObject var cleanup: CleanupModel
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: SiftMetrics.spacingM) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(SiftColor.quietText)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .accessibilityHidden(true)
                    Text(representativeName)
                        .font(SiftFont.bodyEmphasis)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(LocalizationKey.filesGroupMembers.localized(members.count))
                        .font(SiftFont.caption)
                        .foregroundStyle(SiftColor.secondaryText)
                    Spacer(minLength: SiftMetrics.spacingS)
                    Text(group.formattedReclaimable)
                        .font(SiftFont.caption)
                        .monospacedDigit()
                        .foregroundStyle(SiftColor.secondaryText)
                    // No risk badge here: every group in this section is `review`
                    // by construction — the section's own heading says so — and a
                    // word repeated on 136 rows is not a label, it is a texture.
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
            .padding(.leading, 14 + SiftMetrics.spacingS)
            .padding(.vertical, SiftMetrics.spacingS)
            .accessibilityLabel(Text(representativeName))
            .accessibilityValue(Text(group.formattedReclaimable))
            .accessibilityHint(Text(LocalizationKey.scanResultsReviewHint.localized))

            if isExpanded {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(members) { member in
                        DuplicateMemberRow(
                            member: member,
                            cleanup: cleanup
                        )
                    }
                }
                .padding(.bottom, SiftMetrics.spacingS)
            }
        }
    }

    private var representativeName: String {
        members.first?.displayName ?? group.contentHash.prefix(12).description
    }
}

/// One copy inside a group: its checkbox, its two lines and its size.
///
/// A view of its own because the reveal control appears on hover and hover is a
/// row's own state — a group that held one flag for all of its copies lit every
/// folder glyph in the group at once.
struct DuplicateMemberRow: View {
    let member: DuplicateMember
    @ObservedObject var cleanup: CleanupModel

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: SiftMetrics.spacingM) {
            SiftCheckbox(
                isOn: Binding(
                    get: { cleanup.isSelected(item) },
                    set: { cleanup.setSelected($0, for: item) }
                )
            )
            .accessibilityLabel(Text(member.displayName))

            VStack(alignment: .leading, spacing: 1) {
                Text(member.displayName)
                    .font(SiftFont.supporting)
                    .fontWeight(.medium)
                    .foregroundStyle(SiftColor.mainText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(member.displayPath)
                    .font(SiftFont.metadata)
                    .foregroundStyle(SiftColor.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // The name is the thing the user reads, so clicking it has to do
            // what clicking the checkbox does.
            .contentShape(Rectangle())
            .onTapGesture {
                cleanup.setSelected(!cleanup.isSelected(item), for: item)
            }

            Spacer(minLength: SiftMetrics.spacingS)

            // The same entry point every other row on this page has: the path is
            // the only thing that tells two copies of one file apart, so a
            // duplicate the page cannot judge has to be reachable in the Finder.
            // It appears on hover — the row it belongs to is one of hundreds, and
            // a permanent glyph per copy was a column of identical folders — and
            // stays in the accessibility tree and the context menu either way.
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([member.url])
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(SiftLinkButtonStyle())
            .help(LocalizationKey.filesRevealInFinder.localized)
            .accessibilityLabel(Text(LocalizationKey.filesRevealInFinder.localized))
            .opacity(isHovering ? 1 : 0)

            Text(member.formattedSize)
                .font(SiftFont.monospacedNumber)
                .foregroundStyle(SiftColor.mainText)
                .frame(minWidth: 76, alignment: .trailing)
        }
        .padding(.leading, 14 + SiftMetrics.spacingL)
        .padding(.trailing, SiftMetrics.spacingS)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([member.url])
            } label: {
                Label(
                    LocalizationKey.filesRevealInFinder.localized,
                    systemImage: "folder"
                )
            }
        }
    }

    /// The cleanup item a member maps to, so selection survives re-renders.
    private var item: CleanupItem {
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
