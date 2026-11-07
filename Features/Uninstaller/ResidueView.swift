import AppKit
import Core
import Shared
import SwiftUI

/// What applications that are no longer installed left behind, one entry per
/// application.
///
/// The scan already found these rows — `applicationResidue` and
/// `groupContainerResidue` have been part of a junk scan since the residue
/// strategy was written. What was missing is a place to ask the question. On the
/// scan page the answer arrived at the bottom of a full-disk run, one row per
/// directory, under a category chip called "Junk"; here the page runs the residue
/// strategy alone, which reads seven known locations one level deep, and groups
/// the rows by the application they belonged to.
///
/// The page never decides that a directory is a leftover. That judgement is the
/// engines', and it is made from the set of installed bundle identifiers before
/// the walk starts. This page presents the verdict and lets the user act on it —
/// which is why every row is `review`, selected by nobody, and offered with its
/// path, its size and the identifier it was matched by.
public struct ResidueView: View {
    @EnvironmentObject private var environment: AppEnvironment
    private let onRequestPurchase: () -> Void

    /// The groups on screen. Derived from rows, never from the filesystem, and
    /// kept here rather than read back from the cleanup model because the model
    /// holds one flat list whose order is the scanner's, not the grouping's.
    @State private var groups: [ResidueGroup] = []
    /// Which groups are open. Collapsed by default: the summary line is what a
    /// user reads first, and seven expanded paths under every application is the
    /// list this page exists to avoid.
    @State private var expanded: Set<String> = []
    /// Whether this page has run its check. Distinct from "no groups": a Mac with
    /// nothing left over must not look like a page that never looked.
    @State private var didCheck = false
    @State private var isChecking = false
    @State private var notice: String?

    public init(onRequestPurchase: @escaping () -> Void = {}) {
        self.onRequestPurchase = onRequestPurchase
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if let notice {
                NoticeBanner(level: .warning, message: notice)
                    .padding(.top, SiftMetrics.spacingM)
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, SiftMetrics.pagePadding)
        .padding(.top, SiftMetrics.spacingL)
        .padding(.bottom, SiftMetrics.spacingXXL)
        .frame(maxWidth: SiftMetrics.contentWidthWide, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Header

    /// The one sentence that says what the check does, and the control that
    /// starts it.
    ///
    /// The button stays on screen after a run: this page is a check, not a
    /// report, and an application installed and removed between two visits is the
    /// ordinary way its answer changes.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: SiftMetrics.spacingL) {
            VStack(alignment: .leading, spacing: SiftMetrics.spacingXS) {
                Text(LocalizationKey.residueIntroDetail.localized)
                    .font(SiftFont.body)
                    .foregroundStyle(SiftColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if didCheck, !isChecking {
                    Text(summaryLine)
                        .font(SiftFont.caption)
                        .foregroundStyle(SiftColor.quietText)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 0)
            SiftPrimaryButton(
                titleKey: didCheck ? .scanRescan : .residueScanAction,
                symbolName: didCheck ? "arrow.clockwise" : "questionmark.folder",
                isEnabled: !isChecking && !environment.scan.isRunning
            ) {
                Task { await check() }
            }
            .accessibilityIdentifier("residue.check")
        }
    }

    /// What the last check found, in one line.
    private var summaryLine: String {
        let locations = groups.reduce(0) { $0 + $1.locationCount }
        let bytes = groups.reduce(Int64(0)) { $0 + $1.totalBytes }
        return "\(LocalizationKey.residueLocations.localized(locations)) · \(SiftFormat.bytes(bytes))"
    }

    // MARK: - Body states

    @ViewBuilder
    private var content: some View {
        if isChecking || environment.scan.isRunning {
            running
        } else if let outcome = environment.cleanup.outcome {
            finished(outcome)
        } else if !didCheck {
            // Never checked: the page states what it will do rather than showing
            // an empty result it has not earned.
            SiftEmptyState(
                symbolName: "questionmark.folder",
                titleKey: .cleanupCategoryApplicationResidue,
                detailKey: .residueIntroDetail
            )
            .padding(.top, SiftMetrics.spacingXL)
        } else if groups.isEmpty {
            SiftEmptyState(
                symbolName: "checkmark.circle",
                titleKey: .scanNothingFound,
                detailKey: .scanNothingFoundDetail
            )
            .padding(.top, SiftMetrics.spacingXL)
        } else {
            list
        }
    }

    private var running: some View {
        VStack(spacing: SiftMetrics.spacingM) {
            ProgressView()
                .controlSize(.small)
            Text(LocalizationKey.scanPhaseScanning.localized)
                .font(SiftFont.body)
                .foregroundStyle(SiftColor.secondaryText)
            if environment.scan.progress.itemsFound > 0 {
                Text(
                    LocalizationKey.commonItemCount.counted(
                        Int(environment.scan.progress.itemsFound)
                    )
                )
                .font(SiftFont.caption)
                .foregroundStyle(SiftColor.quietText)
                .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, SiftMetrics.spacingXXL)
    }

    /// The result of a cleanup this page started.
    ///
    /// One card rather than the full report page: the leftovers view is a
    /// question with a short answer, and the report belongs to the scan page,
    /// which is where the run that produced it is described. The numbers are the
    /// operation's own — what actually moved — not the size of what was selected.
    private func finished(_ outcome: CleanupOutcome) -> some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingM) {
            Text(LocalizationKey.cleanupResultTitle.localized)
                .siftFont(.sectionTitle)
                .foregroundStyle(SiftColor.mainText)
            Text(LocalizationKey.cleanupResultMoved.localized(outcome.movedCount))
                .font(SiftFont.body)
                .foregroundStyle(SiftColor.secondaryText)
            if outcome.failedCount > 0 {
                Text(LocalizationKey.cleanupResultRetryCount.localized(outcome.failedCount))
                    .font(SiftFont.caption)
                    .foregroundStyle(SiftColor.reviewTextColor)
            }
            HStack(spacing: SiftMetrics.spacingM) {
                SiftPrimaryButton(titleKey: .commonDone, symbolName: "checkmark") {
                    environment.cleanup.acknowledgeOutcome()
                    Task { await check() }
                }
                .accessibilityIdentifier("residue.done")
            }
            .padding(.top, SiftMetrics.spacingXS)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(SiftMetrics.spacingXL)
        .background(
            RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusL, style: .continuous)
                .fill(SiftColor.surfaceColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusL, style: .continuous)
                .strokeBorder(SiftColor.divider, lineWidth: SiftMetrics.panelBorderWidth)
        )
        .padding(.top, SiftMetrics.spacingXL)
    }

    // MARK: - The list

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: SiftMetrics.spacingM) {
                ForEach(groups) { group in
                    groupCard(group)
                }
            }
            .padding(.top, SiftMetrics.spacingL)
            .padding(.bottom, SiftMetrics.spacingS)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            selectionBar
        }
    }

    private func groupCard(_ group: ResidueGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: SiftMetrics.spacingM) {
                SiftCheckbox(isOn: groupBinding(group))
                VStack(alignment: .leading, spacing: SiftMetrics.spacingXS) {
                    HStack(alignment: .firstTextBaseline, spacing: SiftMetrics.spacingS) {
                        Text(group.displayName)
                            .font(SiftFont.bodyEmphasis)
                            .foregroundStyle(SiftColor.mainText)
                            .lineLimit(1)
                        Text(group.formattedSize)
                            .font(SiftFont.metadata)
                            .foregroundStyle(SiftColor.secondaryText)
                            .monospacedDigit()
                        if group.hasGroupContainer {
                            // A shared container can belong to an app group, not
                            // just to the application named here. The row says so
                            // instead of relying on the user to expand it.
                            Text(LocalizationKey.cleanupCategoryGroupContainerResidue.localized)
                                .font(SiftFont.metadata)
                                .foregroundStyle(SiftColor.reviewTextColor)
                                .padding(.horizontal, SiftMetrics.spacingS)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(SiftColor.reviewWash)
                                )
                        }
                    }
                    // The identifier is the only fact about ownership that
                    // survives an uninstall, so it is shown in full and in a
                    // face where characters cannot be confused.
                    Text(group.bundleIdentifier)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(SiftColor.quietText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    HStack(spacing: SiftMetrics.spacingS) {
                        Text(LocalizationKey.residueLocations.localized(group.locationCount))
                        if let modified = group.latestModified {
                            Text("·")
                            Text(modified.formatted(date: .abbreviated, time: .omitted))
                        }
                    }
                    .font(SiftFont.metadata)
                    .foregroundStyle(SiftColor.quietText)
                    .monospacedDigit()
                }
                Spacer(minLength: 0)
                Button {
                    toggle(group.id)
                } label: {
                    Image(systemName: expanded.contains(group.id) ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SiftColor.secondaryText)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    Text(LocalizationKey.residueLocations.localized(group.locationCount))
                )
            }
            .padding(SiftMetrics.spacingM)

            if expanded.contains(group.id) {
                SiftHairline()
                VStack(spacing: 0) {
                    ForEach(group.items) { item in
                        row(item)
                    }
                }
                .padding(.vertical, SiftMetrics.spacingXS)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusL, style: .continuous)
                .fill(SiftColor.surfaceColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusL, style: .continuous)
                .strokeBorder(SiftColor.divider, lineWidth: SiftMetrics.panelBorderWidth)
        )
    }

    /// One location inside a group.
    ///
    /// The category travels with the row because the two are not the same
    /// decision: a cache is rebuilt, a container is an application's whole data
    /// directory, and a shared container may belong to another application too.
    private func row(_ item: CleanupItem) -> some View {
        HStack(alignment: .top, spacing: SiftMetrics.spacingM) {
            SiftCheckbox(isOn: itemBinding(item))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(SiftColor.mainText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                HStack(spacing: SiftMetrics.spacingS) {
                    Text(item.category.titleKey.localized)
                    if item.fileCount > 1 {
                        Text("·")
                        Text(LocalizationKey.commonItemCount.counted(item.fileCount))
                    }
                }
                .font(SiftFont.metadata)
                .foregroundStyle(SiftColor.quietText)
            }
            Spacer(minLength: 0)
            Text(item.formattedSize)
                .font(SiftFont.metadata)
                .foregroundStyle(SiftColor.secondaryText)
                .monospacedDigit()
        }
        .padding(.horizontal, SiftMetrics.spacingM)
        .padding(.leading, 18)
        .padding(.vertical, SiftMetrics.spacingS)
        .contentShape(Rectangle())
    }

    // MARK: - Selection

    private var selectionBar: some View {
        HStack(spacing: SiftMetrics.spacingM) {
            Text(selectionSummary)
                .font(SiftFont.supporting)
                .foregroundStyle(SiftColor.secondaryText)
                .monospacedDigit()
            Spacer(minLength: 0)
            SiftPrimaryButton(
                title: LocalizationKey.cleanupConfirmMoveAction.localized,
                symbolName: "trash",
                isEnabled: environment.cleanup.selectedCount > 0 && !environment.cleanup.isWorking
            ) {
                Task { await clean() }
            }
            .accessibilityIdentifier("residue.clean")
        }
        .padding(.horizontal, SiftMetrics.spacingM)
        .padding(.vertical, SiftMetrics.spacingM)
        .background(.regularMaterial)
        .overlay(alignment: .top) { SiftHairline() }
    }

    private var selectionSummary: String {
        let selected = environment.cleanup.selectedCount
        let total = groups.reduce(0) { $0 + $1.locationCount }
        let bytes = environment.cleanup.selectedBytes
        return "\(selected) / \(total) · \(SiftFormat.bytes(bytes))"
    }

    /// A group's box is the whole group: on when every location is on, and a
    /// click sets all of them. That is the decision the card represents.
    private func groupBinding(_ group: ResidueGroup) -> Binding<Bool> {
        Binding(
            get: { group.items.allSatisfy { environment.cleanup.isSelected($0) } },
            set: { isOn in
                for item in group.items {
                    environment.cleanup.setSelected(isOn, for: item)
                }
            }
        )
    }

    private func itemBinding(_ item: CleanupItem) -> Binding<Bool> {
        Binding(
            get: { environment.cleanup.isSelected(item) },
            set: { environment.cleanup.setSelected($0, for: item) }
        )
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
        }
    }

    // MARK: - Actions

    /// Runs the residue strategy and groups what it finds.
    ///
    /// Three separate facts are read back, and each is checked rather than
    /// assumed: that the run the model now holds is the one this page asked for,
    /// that it did not fail, and that paging reached the end. A report that says
    /// "nothing found" while the index still had pages would be the worst answer
    /// this page could give.
    private func check() async {
        guard !isChecking else { return }
        isChecking = true
        notice = nil
        defer { isChecking = false }

        await environment.runScan(.residue)

        guard environment.scan.scope == .residue else {
            // The scan page (or the overview) was already running, so this request
            // was refused by the single-flight gate. Saying "nothing found" here
            // would describe a run that never happened.
            didCheck = true
            notice = LocalizationKey.cleanupBusyNotice.localized
            groups = []
            return
        }
        guard environment.scan.failure == nil else {
            didCheck = true
            groups = []
            return
        }

        let rows = await loadResidueRows()
        let items = rows.map { $0.asCleanupItem() }
        environment.cleanup.setItems(items, preselect: false)
        groups = ResidueGrouping.groups(from: items)
        expanded = []
        didCheck = true
    }

    /// Every residue row, read a page at a time.
    ///
    /// A page of 200 is the scan page's own first screenful; the leftovers list
    /// is short by nature but not bounded by anything, and a truncated list would
    /// understate what a check found while looking complete.
    private func loadResidueRows() async -> [CleanupItemSummary] {
        var rows: [CleanupItemSummary] = []
        var offset = 0
        let pageSize = 200
        while true {
            let page = await environment.scan.page(
                offset: offset,
                limit: pageSize,
                sort: .size,
                category: nil
            )
            rows.append(contentsOf: page.items)
            if page.remaining <= 0 || page.items.isEmpty { break }
            offset += page.items.count
        }
        return rows
    }

    private func clean() async {
        notice = nil
        let result = await environment.beginCleanup(
            operation: .residue,
            requiresConfirmation: environment.preferences.showsConfirmationPanel,
            scanReport: environment.scan.report
        )
        switch result {
        case .purchaseRequired:
            onRequestPurchase()
        case .busy:
            notice = LocalizationKey.cleanupBusyNotice.localized
        case .nothingToDo:
            notice = environment.cleanup.failure?.message
                ?? LocalizationKey.cleanupNothingToDo.localized
        case .awaitingConfirmation, .executed:
            break
        }
    }
}
