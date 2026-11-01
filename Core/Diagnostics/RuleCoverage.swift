import Foundation
import OSLog
import Shared

/// What the rule table actually finds on this Mac.
///
/// The table states what Sift *recognises*; nothing in the product said what that
/// reaches. Two questions this answers, and neither has a test that can answer it:
///
///  1. **Which rules find nothing?** A rule that reports zero items on every Mac
///     is either dead or aimed at a shape no application writes any more. The
///     table is the product's definition of "cleanable", so a rule nobody
///     exercises is a claim nobody checks.
///  2. **Which large directories does no rule reach?** `~/Library/Application
///     Support/<app>` is deliberately not an item — it is the application's live
///     data — but the page says so instead of leaving the user to wonder.
///
/// The numbers are the scanner's own: this runs a real scan through the
/// reference engine and groups the rows by the rule that produced them. Nothing
/// here re-implements matching, so the counts cannot disagree with the list the
/// scan page shows — which is exactly why `Scripts/audit-coverage.py`, a separate
/// implementation for a machine without the app, keeps its own self-check.
public struct RuleCoverageAnalyzer: Sendable {
    public init(rules: RuleEngine, request: ScanRequest) {
        self.rules = rules
        self.request = request
    }

    private let rules: RuleEngine
    private let request: ScanRequest
    private let logger = SiftLog.make("Coverage")

    /// One rule's contribution.
    public struct Row: Sendable, Identifiable, Hashable {
        public let ruleID: String
        public let category: CleanupCategory
        public let risk: CleanupRisk
        public let itemCount: Int
        public let fileCount: Int
        public let totalBytes: Int64
        /// Whether the rows came from a scanner the rule table does not contain.
        ///
        /// The residue scans are code, not rules: they decide by comparing a name
        /// with the installed applications, which no rule can express. They still
        /// produce items, so a table that listed only the shipped rules silently
        /// dropped them — including both residue categories, which are the two
        /// claims this page is supposed to keep apart.
        public let isSynthesized: Bool

        public var id: String { ruleID }
        /// A rule that matched nothing. Not an error — most rules are for data
        /// this Mac does not have — but the list of them is what makes a dead
        /// rule visible.
        public var isIdle: Bool { itemCount == 0 }
    }

    /// A directory no rule reaches.
    public struct Uncovered: Sendable, Hashable, Identifiable {
        public let url: URL
        public let bytes: Int64
        public var id: String { url.path }
    }

    /// The finished report.
    public struct Report: Sendable, Equatable {
        public let rows: [Row]
        public let uncovered: [Uncovered]
        public let measuredAt: Date

        public var totalItems: Int { rows.reduce(0) { $0 + $1.itemCount } }
        public var totalBytes: Int64 { rows.reduce(0) { $0 + $1.totalBytes } }
        public var idleRows: [Row] { rows.filter(\.isIdle) }

        public static let empty = Report(rows: [], uncovered: [], measuredAt: .distantPast)
    }

    /// The evaluation itself.
    ///
    /// The scan is the reference engine's: it is compiled into every build, so
    /// the report is available whether or not this build links the Rust core, and
    /// `EngineAgreementTests` is what says the two engines answer the same
    /// question.
    public func run() async -> Report {
        let engine = SwiftScannerEngine(rules: rules)
        let session: (any ScanSession)?
        do {
            session = try await engine.startScan(request)
        } catch {
            logger.error("Coverage scan could not start (\(String(describing: error)))")
            return .empty
        }
        guard let session else { return .empty }

        // Drain until the session says it is finished. The deadline is generous
        // because this is an explicit, user-initiated audit on a whole home
        // folder, and a report that gives up early would understate every rule.
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            _ = await session.pollEvents(maxEvents: 256)
            if await session.isFinished() { break }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        // The index is the settled answer: the live event stream cannot retract a
        // row when a later rule replaces the same path.
        var items: [CleanupItemSummary] = []
        var offset = 0
        while true {
            guard let page = try? await session.page(offset: offset, limit: 256, sort: .size, category: nil)
            else { break }
            items.append(contentsOf: page.items)
            offset += page.items.count
            if page.remaining == 0 || page.items.isEmpty { break }
        }

        return report(from: items)
    }

    /// Groups what the scan found by rule, then measures what nothing claimed.
    ///
    /// Split from `run()` so a test can hand it a fixed set of items: the grouping
    /// and the uncovered list are the part with the arithmetic in it, and they do
    /// not need a filesystem to be wrong.
    public func report(from items: [CleanupItemSummary]) -> Report {
        var totals: [String: (items: Int, files: Int, bytes: Int64)] = [:]
        // The scanner's own attribution, kept for the rows the rule table does not
        // know about: which category they landed in, and the most cautious risk
        // among them — one `review` row must not be summarised as `safe`.
        var synthesized: [String: (category: CleanupCategory, risk: CleanupRisk)] = [:]
        for item in items {
            var entry = totals[item.sourceRuleID] ?? (0, 0, 0)
            entry.items += 1
            entry.files += max(item.fileCount, 1)
            entry.bytes += item.sizeInBytes
            totals[item.sourceRuleID] = entry

            guard rules.rule(withID: item.sourceRuleID) == nil else { continue }
            let existing = synthesized[item.sourceRuleID]
            synthesized[item.sourceRuleID] = (
                category: existing?.category ?? item.category,
                risk: existing.map { $0.risk.severity >= item.risk.severity ? $0.risk : item.risk }
                    ?? item.risk
            )
        }

        // Every enabled rule appears, including the ones that found nothing: a
        // table that only lists hits cannot show a rule that never hits.
        var rows = rules.rules
            .filter(\.isEnabled)
            .map { rule -> Row in
                let entry = totals[rule.id] ?? (0, 0, 0)
                return Row(
                    ruleID: rule.id,
                    category: rule.category,
                    risk: rule.risk,
                    itemCount: entry.items,
                    fileCount: entry.files,
                    totalBytes: entry.bytes,
                    isSynthesized: false
                )
            }
        rows.append(
            contentsOf: synthesized.map { id, attribution in
                let entry = totals[id] ?? (0, 0, 0)
                return Row(
                    ruleID: id,
                    category: attribution.category,
                    risk: attribution.risk,
                    itemCount: entry.items,
                    fileCount: entry.files,
                    totalBytes: entry.bytes,
                    isSynthesized: true
                )
            }
        )
        rows.sort { left, right in
            if left.totalBytes != right.totalBytes { return left.totalBytes > right.totalBytes }
            return left.ruleID < right.ruleID
        }

        return Report(rows: rows, uncovered: uncovered(after: items), measuredAt: Date())
    }

    /// Directories a built-in scanner already looks inside.
    ///
    /// The residue scanner owns these: a container, an application support folder,
    /// a cache or a log directory is read for data belonging to an application
    /// that is gone. Listing them as "no rule reaches this" was doubly wrong — the
    /// page then offered a rule draft for a container folder, which
    /// `RuleDraft.make` refuses, so the suggestion could not be acted on and the
    /// user was told nothing covers a place the scan reads every run.
    ///
    /// The threshold scans (large files, old files) are deliberately absent: they
    /// cover the whole tree, so counting them would empty this list and with it the
    /// one signal that says which folders the product does not recognise.
    static let scannerCoveredDirectories: [String] = [
        "Library/Application Support",
        "Library/Caches",
        "Library/Containers",
        "Library/Group Containers",
        "Library/HTTPStorages",
        "Library/Logs",
        "Library/Preferences",
        "Library/Saved Application State",
        "Library/WebKit",
    ]

    /// The large directories no row lands in.
    ///
    /// Measured at the granularity the user thinks in: the children of `~` and of
    /// `~/Library`. A directory that holds no item and sits inside no item is what
    /// "no rule reaches this" means — `~/Library/Application Support` holds items
    /// three levels down, so it counts as reached, while `~/Library/Huawei` holds
    /// none and appears here with its size. A directory a scanner reads is counted
    /// as reached even when the scan found nothing in it today.
    private func uncovered(after items: [CleanupItemSummary]) -> [Uncovered] {
        let home = URL(fileURLWithPath: rules.homeDirectory)
        let itemPaths = items.map { RuleEngine.normalize($0.url.path) }
        var candidates: [URL] = []
        for base in [home, home.appendingPathComponent("Library")] {
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: base,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for child in children {
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                else { continue }
                if rules.isCleanupContainer(child.path) { continue }
                if rules.protectionReason(for: child.path) != nil { continue }
                let path = RuleEngine.normalize(child.path)
                if Self.scannerCoveredDirectories.contains(where: {
                    path == RuleEngine.normalize(home.appendingPathComponent($0).path)
                }) {
                    continue
                }
                // Inside an item, or an ancestor of one: reached or irrelevant.
                if itemPaths.contains(where: { RuleEngine.isPrefix(path, $0) || RuleEngine.isPrefix($0, path) }) {
                    continue
                }
                candidates.append(child)
            }
        }

        var found: [Uncovered] = []
        for candidate in candidates {
            let measured = FileWalker.measure(
                url: candidate,
                rules: rules,
                skipHidden: !request.includeHiddenFiles,
                skipPaths: request.ignoredPaths,
                isCancelled: { false }
            )
            guard measured.bytes > 0 else { continue }
            found.append(Uncovered(url: candidate, bytes: measured.bytes))
        }
        return found.sorted { $0.bytes > $1.bytes }.prefix(12).map { $0 }
    }
}
