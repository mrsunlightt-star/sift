import AppKit
import Core
import Shared
import SwiftUI

/// The coverage audit, as a page of its own.
///
/// The rule table is the product's definition of "cleanable", so two questions
/// about it are worth a page: which rules found nothing on this Mac (a rule
/// nobody exercises is a claim nobody checks), and which large directories no
/// rule reaches at all. The numbers come from a real scan — see
/// `RuleCoverageAnalyzer` — so they agree with the list the scan page shows.
///
/// The audit walks a whole home folder, so it runs once when the page opens and
/// again only when the user asks: a page that re-walked the disk every time it
/// appeared would be a page nobody leaves open.
struct RuleCoverageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var environment: AppEnvironment

    @State private var report: RuleCoverageAnalyzer.Report?
    @State private var isRunning = false
    @State private var hasRun = false
    /// The draft the user asked for, and why one could not be built.
    @State private var draft: RuleDraft?
    @State private var draftRefusal: String?

    var body: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingL) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .padding(SiftMetrics.spacingXL)
        .frame(minWidth: 620, minHeight: 520, alignment: .leading)
        .task {
            // One run per opening. The result stays while the sheet is open, so
            // scrolling back up does not re-walk the disk.
            guard !hasRun else { return }
            await run()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
            Text(LocalizationKey.diagnosticsCoverageTitle.localized)
                .font(SiftFont.title)
            Text(LocalizationKey.diagnosticsCoverageDetail.localized)
                .font(SiftFont.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var content: some View {
        if isRunning {
            HStack(spacing: SiftMetrics.spacingM) {
                ProgressView().controlSize(.small)
                Text(LocalizationKey.commonLoading.localized)
                    .font(SiftFont.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let report {
            ScrollView {
                VStack(alignment: .leading, spacing: SiftMetrics.spacingL) {
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
            }
        } else {
            Text(LocalizationKey.commonLoading.localized)
                .font(SiftFont.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func summary(_ report: RuleCoverageAnalyzer.Report) -> some View {
        HStack(spacing: SiftMetrics.spacingL) {
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
            Spacer()
        }
    }

    private func metric(value: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(SiftFont.metric)
            Text(title)
                .font(SiftFont.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func ruleTable(_ report: RuleCoverageAnalyzer.Report) -> some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingXS) {
            HStack(spacing: SiftMetrics.spacingM) {
                Text(LocalizationKey.diagnosticsCoverageRule.localized)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(LocalizationKey.commonRisk.localized)
                    .frame(width: 70, alignment: .leading)
                Text(LocalizationKey.commonItemCount.localized)
                    .frame(width: 80, alignment: .trailing)
                Text(LocalizationKey.commonSize.localized)
                    .frame(width: 90, alignment: .trailing)
            }
            .font(SiftFont.caption)
            .foregroundStyle(.secondary)

            Divider()

            ForEach(report.rows) { row in
                HStack(spacing: SiftMetrics.spacingM) {
                    HStack(spacing: SiftMetrics.spacingS) {
                        Circle()
                            .fill(Self.tint(for: row.risk))
                            .frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: SiftMetrics.spacingXS) {
                                Text(row.ruleID)
                                    .font(SiftFont.caption)
                                    .lineLimit(1)
                                // A row from scanning code, not from the rule file:
                                // without the badge the id reads like any other
                                // rule name, and the list would imply a rule exists
                                // that the user could edit.
                                if row.isSynthesized {
                                    Text(LocalizationKey.diagnosticsCoverageSynthesized.localized)
                                        .font(SiftFont.badge)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(SiftColor.review.opacity(0.12))
                                        .clipShape(Capsule())
                                }
                            }
                            Text(row.category.titleKey.localized)
                                .font(SiftFont.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(row.risk.level.labelKey.localized)
                        .font(SiftFont.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .leading)
                    Text(row.itemCount == 0 ? "—" : SiftFormat.count(row.itemCount))
                        .font(SiftFont.monospacedNumber)
                        .foregroundStyle(row.itemCount == 0 ? .tertiary : .secondary)
                        .frame(width: 80, alignment: .trailing)
                    Text(row.itemCount == 0 ? "—" : SiftFormat.bytes(row.totalBytes))
                        .font(SiftFont.monospacedNumber)
                        .foregroundStyle(row.itemCount == 0 ? .tertiary : .secondary)
                        .frame(width: 90, alignment: .trailing)
                }
                .padding(.vertical, 2)
            }

            if report.rows.contains(where: \.isSynthesized) {
                Text(LocalizationKey.diagnosticsCoverageSynthesizedNote.localized)
                    .font(SiftFont.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, SiftMetrics.spacingXS)
            }
        }
    }

    private func idleList(_ report: RuleCoverageAnalyzer.Report) -> some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
            Text(
                LocalizationKey.diagnosticsCoverageIdle.localized(
                    report.idleRows.map(\.ruleID).joined(separator: ", ")
                )
            )
            .font(SiftFont.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func uncoveredList(_ report: RuleCoverageAnalyzer.Report) -> some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
            Text(LocalizationKey.diagnosticsCoverageUncovered.localized)
                .font(SiftFont.sectionTitle)
            Text(LocalizationKey.diagnosticsCoverageDraftDetail.localized)
                .font(SiftFont.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(report.uncovered) { entry in
                HStack(spacing: SiftMetrics.spacingM) {
                    Text(SiftFormat.bytes(entry.bytes))
                        .font(SiftFont.monospacedNumber)
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .trailing)
                    Text(CleanupItem.abbreviate(entry.url.path))
                        .font(SiftFont.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: SiftMetrics.spacingS)
                    // The next step for a folder nothing claims is a rule, not a
                    // deletion: the audit hands over the draft instead of acting.
                    Button {
                        makeDraft(for: entry.url)
                    } label: {
                        Text(LocalizationKey.diagnosticsCoverageDraftTitle.localized)
                            .font(SiftFont.caption)
                    }
                    .buttonStyle(SiftLinkButtonStyle())
                }
            }
            if let draftRefusal {
                NoticeBanner(level: .information, message: draftRefusal)
            }
            if let draft {
                draftCard(draft)
            }
        }
    }

    /// The draft itself, with the one action that makes it useful.
    ///
    /// It is already validated — `RuleDraft` decodes it through the app's own
    /// loader — so the page can say "this loads" rather than "try it".
    private func draftCard(_ built: RuleDraft) -> some View {
        VStack(alignment: .leading, spacing: SiftMetrics.spacingS) {
            Text(built.ruleID)
                .font(SiftFont.bodyEmphasis)
            Text(built.json)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(SiftMetrics.spacingM)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: SiftMetrics.cornerRadiusS, style: .continuous)
                        .fill(SiftColor.subtleFill)
                }
            Button {
                // The clipboard is the one transport the page needs: the draft
                // belongs in the user's own file, and Sift does not write there.
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(built.json, forType: .string)
                draft = nil
            } label: {
                Text(LocalizationKey.diagnosticsCoverageDraftCopy.localized)
                    .font(SiftFont.caption)
            }
            .buttonStyle(SiftLinkButtonStyle())
        }
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

    private var footer: some View {
        HStack(spacing: SiftMetrics.spacingM) {
            Button {
                Task { await run() }
            } label: {
                Text(LocalizationKey.diagnosticsCoverageRun.localized)
                    .font(SiftFont.caption)
            }
            .buttonStyle(SiftLinkButtonStyle())
            .disabled(isRunning)

            Spacer()

            SiftPrimaryButton(title: LocalizationKey.commonClose.localized) {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    /// The dot beside a rule's id: the same three colours the rows use.
    private static func tint(for risk: CleanupRisk) -> Color {
        switch risk {
        case .safe: SiftColor.safe
        case .review: SiftColor.review
        case .protected: SiftColor.danger
        }
    }

    private func run() async {
        isRunning = true
        defer { isRunning = false; hasRun = true }
        report = await environment.ruleCoverage()
    }
}
