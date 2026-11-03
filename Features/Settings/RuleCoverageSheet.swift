import AppKit
import Core
import Shared
import SwiftUI

/// The coverage audit, as a page of its own (invariant 41).
///
/// The rule table is the product's definition of "cleanable", so two questions
/// about it are worth a page: which rules found nothing on this Mac (a rule nobody
/// exercises is a claim nobody checks), and which large directories no rule
/// reaches at all. The numbers come from a real scan — see `RuleCoverageAnalyzer` —
/// so they agree with the list the scan page shows.
///
/// The audit walks a whole home folder, so it runs once when the page opens and
/// again only when the user asks: a page that re-walked the disk every time it
/// appeared would be a page nobody leaves open.
///
/// The sheet is quieter than the page that opens it — a title, one table, one
/// well for the draft — because it is a report to read and close, not a place to
/// work. Nothing here is a card: the table's hairlines are its structure.
struct RuleCoverageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var environment: AppEnvironment

    @State private var report: RuleCoverageAnalyzer.Report?
    @State private var isRunning = false
    @State private var hasRun = false
    /// The draft the user asked for, and why one could not be built.
    @State private var draft: RuleDraft?
    @State private var draftRefusal: String?
    @Environment(\.siftReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            SiftHairline()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .animation(
                    SiftMotion.respectingReduceMotion(SiftMotion.quick, reduceMotion: reduceMotion),
                    value: isRunning
                )

            SiftHairline()

            footer
        }
        .padding(.horizontal, SiftMetrics.spacingXL)
        .padding(.vertical, SiftMetrics.spacingL)
        .frame(minWidth: 660, minHeight: 560, alignment: .leading)
        .background(SiftCanvasBackground())
        .task {
            // One run per opening. The result stays while the sheet is open, so
            // scrolling back up does not re-walk the disk.
            guard !hasRun else { return }
            await run()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingXS) {
            Text(LocalizationKey.diagnosticsCoverageTitle.localized)
                .font(SiftFont.title)
                .foregroundStyle(SiftColor.mainText)
            Text(LocalizationKey.diagnosticsCoverageDetail.localized)
                .font(SiftFont.supporting)
                .foregroundStyle(SiftColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, SiftMetrics.spacingM)
    }

    @ViewBuilder
    private var content: some View {
        if isRunning {
            HStack(spacing: SiftMetrics.spacingM) {
                SiftProgressRing(progress: nil, lineWidth: 3)
                    .frame(width: 20, height: 20)
                Text(LocalizationKey.commonLoading.localized)
                    .font(SiftFont.supporting)
                    .foregroundStyle(SiftColor.secondaryText)
            }
            .padding(.vertical, SiftMetrics.spacingL)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let report {
            ScrollView {
                VStack(alignment: .leading, spacing: SiftMetrics.spacingXL) {
                    summary(report)
                    ruleTable(report)
                    if !report.idleRows.isEmpty {
                        idleList(report)
                    }
                    if !report.uncovered.isEmpty {
                        uncoveredList(report)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, SiftMetrics.spacingL)
            }
        } else {
            Text(LocalizationKey.commonLoading.localized)
                .font(SiftFont.supporting)
                .foregroundStyle(SiftColor.secondaryText)
                .padding(.vertical, SiftMetrics.spacingL)
        }
    }

    // MARK: - Summary

    /// Three figures, not three cards: the sheet is read once, and a highlighted
    /// panel around each number would make it look like three separate answers.
    private func summary(_ report: RuleCoverageAnalyzer.Report) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SiftMetrics.spacingXXL) {
            metric(
                value: SiftFormat.count(report.totalItems),
                title: LocalizationKey.cleanupConfirmSelectedItems.localized
            )
            metric(
                value: SiftFormat.bytes(report.totalBytes),
                title: LocalizationKey.commonSize.localized
            )
            metric(
                value: "\(report.rows.count - report.idleRows.count)/\(report.rows.count)",
                title: LocalizationKey.diagnosticsCoverageTitle.localized
            )
            Spacer(minLength: 0)
        }
    }

    private func metric(value: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(SiftFont.sectionTitle)
                .monospacedDigit()
                .foregroundStyle(SiftColor.mainText)
            Text(title)
                .font(SiftFont.supporting)
                .foregroundStyle(SiftColor.secondaryText)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - The table

    /// One list for every row the audit produced, rule rows and synthesized
    /// strategy rows alike.
    ///
    /// A synthesized row is scanning code rather than a rule the user could edit,
    /// so it is marked where it appears: two residue claims are code, and a table
    /// that showed their ids without the mark would imply a rule exists (invariant
    /// 41). The mark is the word, not a colour, so it survives a palette change and
    /// a reader who cannot tell amber from grey.
    private func ruleTable(_ report: RuleCoverageAnalyzer.Report) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            tableHeader

            SiftHairline()

            ForEach(report.rows) { row in
                HStack(spacing: SiftMetrics.spacingM) {
                    HStack(spacing: SiftMetrics.spacingS) {
                        Circle()
                            .fill(Self.tint(for: row.risk))
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: SiftMetrics.spacingXS) {
                                Text(row.ruleID)
                                    .font(SiftFont.supporting)
                                    .foregroundStyle(SiftColor.mainText)
                                    .lineLimit(1)
                                if row.isSynthesized {
                                    Text(LocalizationKey.diagnosticsCoverageSynthesized.localized)
                                        .font(SiftFont.metadata)
                                        .foregroundStyle(SiftColor.reviewTextColor)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(
                                            RoundedRectangle(
                                                cornerRadius: 3,
                                                style: .continuous
                                            )
                                            .fill(SiftColor.reviewWash)
                                        )
                                }
                            }
                            Text(row.category.titleKey.localized)
                                .font(SiftFont.metadata)
                                .foregroundStyle(SiftColor.quietText)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(row.risk.level.labelKey.localized)
                        .font(SiftFont.supporting)
                        .foregroundStyle(SiftColor.secondaryText)
                        .frame(width: 76, alignment: .leading)

                    Text(row.itemCount == 0 ? "—" : SiftFormat.count(row.itemCount))
                        .font(SiftFont.monospacedNumber)
                        .foregroundStyle(row.itemCount == 0 ? SiftColor.quietText : SiftColor.mainText)
                        .frame(width: 70, alignment: .trailing)

                    Text(row.itemCount == 0 ? "—" : SiftFormat.bytes(row.totalBytes))
                        .font(SiftFont.monospacedNumber)
                        .foregroundStyle(row.itemCount == 0 ? SiftColor.quietText : SiftColor.mainText)
                        .frame(width: 84, alignment: .trailing)
                }
                .padding(.vertical, SiftMetrics.spacingXS)
                .frame(minHeight: 34)
                .accessibilityElement(children: .combine)
            }

            if report.rows.contains(where: \.isSynthesized) {
                Text(LocalizationKey.diagnosticsCoverageSynthesizedNote.localized)
                    .font(SiftFont.supporting)
                    .foregroundStyle(SiftColor.quietText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, SiftMetrics.spacingS)
            }
        }
    }

    private var tableHeader: some View {
        HStack(spacing: SiftMetrics.spacingM) {
            Text(LocalizationKey.diagnosticsCoverageRule.localized)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(LocalizationKey.commonRisk.localized)
                .frame(width: 76, alignment: .leading)
            Text(LocalizationKey.commonItemCount.localized)
                .frame(width: 70, alignment: .trailing)
            Text(LocalizationKey.commonSize.localized)
                .frame(width: 84, alignment: .trailing)
        }
        .font(SiftFont.supporting)
        .foregroundStyle(SiftColor.quietText)
        .padding(.bottom, SiftMetrics.spacingXS)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Idle and uncovered

    private func idleList(_ report: RuleCoverageAnalyzer.Report) -> some View {
        Text(
            LocalizationKey.diagnosticsCoverageIdle.localized(
                report.idleRows.map(\.ruleID).joined(separator: ", ")
            )
        )
        .font(SiftFont.supporting)
        .foregroundStyle(SiftColor.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func uncoveredList(_ report: RuleCoverageAnalyzer.Report) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(LocalizationKey.diagnosticsCoverageUncovered.localized)
                .font(SiftFont.sectionHeading)
                .foregroundStyle(SiftColor.mainText)
            Text(LocalizationKey.diagnosticsCoverageDraftDetail.localized)
                .font(SiftFont.supporting)
                .foregroundStyle(SiftColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
                .padding(.bottom, SiftMetrics.spacingS)

            SiftHairline()

            ForEach(report.uncovered) { entry in
                HStack(spacing: SiftMetrics.spacingM) {
                    Text(SiftFormat.bytes(entry.bytes))
                        .font(SiftFont.monospacedNumber)
                        .foregroundStyle(SiftColor.mainText)
                        .frame(width: 84, alignment: .trailing)
                    Text(CleanupItem.abbreviate(entry.url.path))
                        .font(SiftFont.supporting)
                        .foregroundStyle(SiftColor.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: SiftMetrics.spacingS)
                    // The next step for a folder nothing claims is a rule, not a
                    // deletion: the audit hands over the draft instead of acting.
                    Button {
                        makeDraft(for: entry.url)
                    } label: {
                        Text(LocalizationKey.diagnosticsCoverageDraftTitle.localized)
                            .font(SiftFont.supporting)
                    }
                    .buttonStyle(SiftLinkButtonStyle())
                }
                .padding(.vertical, SiftMetrics.spacingXS)
                .frame(minHeight: 34)
                .accessibilityElement(children: .contain)
            }

            if let draftRefusal {
                NoticeBanner(level: .information, message: draftRefusal)
                    .padding(.top, SiftMetrics.spacingS)
            }

            if let draft {
                draftCard(draft)
            }
        }
    }

    /// The draft itself, with the one action that makes it useful.
    ///
    /// It is already validated — `RuleDraft` decodes it through the app's own
    /// loader — so the page can say "this loads" rather than "try it". The text is
    /// selectable and the well behind it is `controlFill`: a field the user can
    /// select from, not a panel the page owns.
    private func draftCard(_ built: RuleDraft) -> some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
            Text(built.ruleID)
                .font(SiftFont.bodyEmphasis)
                .foregroundStyle(SiftColor.mainText)

            Text(built.json)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(SiftColor.mainText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(SiftMetrics.spacingM)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusS, style: .continuous)
                        .fill(SiftColor.controlFill)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusS, style: .continuous)
                        .strokeBorder(SiftColor.divider, lineWidth: SiftMetrics.panelBorderWidth)
                }

            Button {
                // The clipboard is the one transport the page needs: the draft
                // belongs in the user's own file, and Sift does not write there.
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(built.json, forType: .string)
                draft = nil
            } label: {
                Text(LocalizationKey.diagnosticsCoverageDraftCopy.localized)
                    .font(SiftFont.supporting)
            }
            .buttonStyle(SiftLinkButtonStyle())
        }
        .padding(.top, SiftMetrics.spacingM)
    }

    private func makeDraft(for url: URL) {
        switch RuleDraft.make(for: url, rules: environment.rules) {
        case let .success(built):
            draft = built
            draftRefusal = nil
        case let .failure(refusal):
            draft = nil
            draftRefusal = refusal.message
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: SiftMetrics.spacingM) {
            SiftSecondaryButton(titleKey: .diagnosticsCoverageRun) {
                Task { await run() }
            }
            .disabled(isRunning)

            Spacer()

            SiftPrimaryButton(title: LocalizationKey.commonClose.localized) {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.top, SiftMetrics.spacingM)
    }

    /// The dot beside a rule's id: the same three colours the rows use, in their
    /// text roles so the dot reads on both canvases.
    private static func tint(for risk: CleanupRisk) -> Color {
        switch risk {
        case .safe: SiftColor.safeTextColor
        case .review: SiftColor.reviewTextColor
        case .protected: SiftColor.dangerTextColor
        }
    }

    private func run() async {
        isRunning = true
        defer { isRunning = false; hasRun = true }
        report = await environment.ruleCoverage()
    }
}
