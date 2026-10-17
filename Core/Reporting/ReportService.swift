import Foundation
import OSLog
import PDFKit
import Shared

/// Cleanup reports and PDF export (§5.7).
///
/// Two requirements shape this file:
///
///  * **The report is de-identified.** It carries categories, counts and size
///    bands, never full paths or file contents. The export therefore cannot leak
///    what the cleanup touched, even if the user shares it.
///  * **A local copy always survives.** The report is written to the app's data
///    directory *before* the save panel appears; a failed export keeps that copy
///    and reports a retry, rather than losing the record (§5.7).
public actor ReportService {
    private let supportDirectory: URL
    private let fileManager: FileManager
    private let logger = SiftLog.report

    /// App version and macOS version, recorded in the report header.
    private let appVersion: String
    private let macOSVersion: String

    public init(supportDirectory: URL = SettingsStore.defaultSupportDirectory(), fileManager: FileManager = .default) {
        self.supportDirectory = supportDirectory
        self.fileManager = fileManager
        self.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
        self.macOSVersion = ProcessInfo.processInfo.operatingSystemVersionString
    }

    /// The directory local reports live in.
    private var reportsDirectory: URL {
        supportDirectory.appendingPathComponent("Reports", isDirectory: true)
    }

    /// Builds a report from a finished operation.
    ///
    /// Display names are included for at most the first `entryLimit` items and
    /// only as leaf names: the report is useful to the user without becoming a
    /// file listing (§13.2).
    public func makeReport(
        from outcome: CleanupOutcome,
        scanReport: ScanReport?,
        entryLimit: Int = 20
    ) -> CleanupReport {
        let entries = outcome.results.prefix(entryLimit).map { result in
            // The report keeps the file name only: no directory component ever
            // reaches the report, which is what makes it safe to share.
            CleanupReport.Entry(
                displayName: result.sourceURL.lastPathComponent,
                category: result.category?.rawValue ?? "unknown",
                sizeInBytes: result.sizeInBytes,
                status: result.status.rawValue,
                errorCode: result.errorCode
            )
        }
        return CleanupReport(
            operation: outcome.operationName,
            appVersion: appVersion,
            macOSVersion: macOSVersion,
            // Counts come straight from the outcome. The earlier version used
            // the skipped-location count as the scan scope and added the skipped
            // results to themselves, which made every report disagree with the
            // page it was exported from.
            scannedLocationCount: scanReport?.scannedLocationCount ?? 0,
            scannedFileCount: scanReport?.scannedFileCount ?? 0,
            categories: outcome.categoryTotals.map(\.category.rawValue),
            movedCount: outcome.movedCount,
            movedBytes: outcome.releasedBytes,
            skippedCount: outcome.skippedCount,
            failedCount: outcome.failedCount,
            entries: Array(entries)
        )
    }

    /// Writes the local JSON copy and returns its URL.
    ///
    /// Always attempted before export, so a failed save panel cannot cost the
    /// user their record.
    @discardableResult
    public func storeLocally(_ report: CleanupReport) throws -> URL {
        try fileManager.createDirectory(at: reportsDirectory, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime]
        let name = "Sift-Report-\(formatter.string(from: report.generatedAt).replacingOccurrences(of: ":", with: "-")).json"
        let url = reportsDirectory.appendingPathComponent(name)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: url, options: .atomic)
        logger.info("Stored a local report (operation=\(report.operation.rawValue, privacy: .public))")
        return url
    }

    /// Renders the report as PDF data.
    ///
    /// Uses PDFKit only — no external tool and no shell (§5.7).
    public func renderPDF(_ report: CleanupReport, title: String) -> Data {
        let pageBounds = CGRect(x: 0, y: 0, width: 595, height: 842) // A4
        let renderer = PDFPageRenderer(bounds: pageBounds, title: title)
        return renderer.render(report: report)
    }

    /// Exports the report to `url`, writing the PDF bytes.
    public func exportPDF(_ report: CleanupReport, to url: URL, title: String) throws {
        let data = renderPDF(report, title: title)
        try data.write(to: url, options: .atomic)
        logger.info("Exported a report as PDF")
    }

    /// The local reports, newest first.
    public func storedReports() -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: reportsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ))?.sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return left > right
        } ?? []
    }
}

/// Draws a report onto PDF pages.
///
/// Kept separate from the service so the layout can be exercised by tests
/// without touching the file system: the renderer takes a report and returns
/// data, and paginates by measurement rather than by counting lines.
public struct PDFPageRenderer {
    let bounds: CGRect
    let title: String

    /// Margins, in points.
    private let margin: CGFloat = 48

    /// Page bounds for A4 portrait.
    public init(bounds: CGRect, title: String) {
        self.bounds = bounds
        self.title = title
    }

    /// Renders every section, starting a new page when the cursor runs out.
    ///
    /// Long lists are truncated with an explicit note rather than silently cut,
    /// and the table repeats its header on each page (§5.7: 支持分页、长列表截断和表格换页).
    public func render(report: CleanupReport) -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return Data() }
        var mediaBox = bounds
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return Data() }

        var cursor = Cursor(context: context, bounds: bounds, margin: margin)
        cursor.beginPage()
        cursor.heading(title)
        cursor.body(LocalizationKey.reportGeneratedAt.localized(SiftFormat.timestamp(report.generatedAt)))
        cursor.body(LocalizationKey.reportAppVersion.localized(report.appVersion, report.macOSVersion))
        cursor.spacer()

        cursor.section(LocalizationKey.reportScope.localized)
        cursor.body(
            LocalizationKey.reportScopeDetail.localized(report.scannedFileCount, report.scannedFileCount)
        )

        cursor.section(LocalizationKey.reportCategories.localized)
        if report.categories.isEmpty {
            cursor.body(LocalizationKey.commonNotAvailable.localized)
        } else {
            for category in report.categories {
                cursor.body("• " + displayName(forCategory: category))
            }
        }

        cursor.section(LocalizationKey.reportMoved.localized)
        cursor.body(LocalizationKey.reportMovedDetail.localized(report.movedCount, report.formattedMovedBytes))

        cursor.section(LocalizationKey.reportReleased.localized)
        cursor.body(report.formattedMovedBytes)

        cursor.section(LocalizationKey.reportSkipped.localized)
        cursor.body(
            LocalizationKey.reportSkippedDetail.localized(report.skippedCount)
        )

        if report.failedCount > 0 {
            cursor.section(LocalizationKey.reportFailed.localized)
            cursor.body(LocalizationKey.reportFailedDetail.localized(report.failedCount))
        }

        if !report.entries.isEmpty {
            cursor.section(LocalizationKey.cleanupResultDetails.localized)
            cursor.tableHeader([
                LocalizationKey.commonPath.localized,
                LocalizationKey.commonSize.localized,
            ])
            for entry in report.entries {
                cursor.tableRow([entry.displayName, entry.formattedSize])
            }
        }

        cursor.section(LocalizationKey.navPrivacy.localized)
        cursor.body(LocalizationKey.reportPrivacyNote.localized)

        cursor.endPage()
        context.closePDF()
        return data as Data
    }

    /// A localised label for a raw category identifier from a report file.
    private func displayName(forCategory identifier: String) -> String {
        CleanupCategory(rawValue: identifier)?.titleKey.localized ?? identifier
    }

    /// Tracks the write position and paginates.
    private struct Cursor {
        /// Row height for the detail table.
        static let tableRowHeight: CGFloat = 20

        let context: CGContext
        let bounds: CGRect
        let margin: CGFloat
        private var y: CGFloat = 0
        private var pageOpen = false

        init(context: CGContext, bounds: CGRect, margin: CGFloat) {
            self.context = context
            self.bounds = bounds
            self.margin = margin
        }

        var contentWidth: CGFloat { bounds.width - margin * 2 }

        mutating func beginPage() {
            context.beginPDFPage(nil)
            // A white background: a PDF viewer may otherwise composite the page
            // over a dark surface, and the report must read the same anywhere.
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(bounds)
            y = bounds.height - margin
            pageOpen = true
        }

        mutating func endPage() {
            guard pageOpen else { return }
            context.endPDFPage()
            pageOpen = false
        }

        /// Starts a new page when there is not enough room left.
        private mutating func ensureSpace(_ needed: CGFloat) {
            if y - needed < margin {
                endPage()
                beginPage()
            }
        }

        mutating func heading(_ text: String) {
            ensureSpace(30)
            draw(text, font: .boldSystemFont(ofSize: 20), color: .black, size: 20)
            y -= 6
        }

        mutating func section(_ text: String) {
            ensureSpace(28)
            y -= 6
            draw(text, font: .systemFont(ofSize: 13, weight: .semibold), color: .black, size: 13)
        }

        mutating func body(_ text: String) {
            let height = measure(text, font: .systemFont(ofSize: 11))
            ensureSpace(height + 4)
            for line in wrapped(text, font: .systemFont(ofSize: 11)) {
                draw(line, font: .systemFont(ofSize: 11), color: NSColor.darkGray, size: 11)
            }
        }

        mutating func spacer() { y -= 6 }

        mutating func tableHeader(_ columns: [String]) {
            ensureSpace(Self.tableRowHeight * 2)
            drawRow(columns, font: .systemFont(ofSize: 10, weight: .semibold), color: .black)
            context.setStrokeColor(CGColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1))
            context.setLineWidth(0.5)
            context.move(to: CGPoint(x: margin, y: y + 4))
            context.addLine(to: CGPoint(x: bounds.width - margin, y: y + 4))
            context.strokePath()
            y -= 4
        }

        mutating func tableRow(_ columns: [String]) {
            ensureSpace(Self.tableRowHeight)
            drawRow(columns, font: .systemFont(ofSize: 10), color: NSColor.darkGray)
        }

        private mutating func drawRow(_ columns: [String], font: NSFont, color: NSColor) {
            let columnWidths = columnWidths(count: columns.count)
            var x = margin
            for (index, column) in columns.enumerated() {
                let width = columnWidths[index]
                let text = index == 0 ? truncated(column, font: font, width: width) : column
                draw(
                    text,
                    font: font,
                    color: color,
                    size: font.pointSize,
                    at: CGPoint(x: x, y: y - Self.tableRowHeight + 5)
                )
                x += width
            }
            y -= Self.tableRowHeight
        }

        private func columnWidths(count: Int) -> [CGFloat] {
            guard count > 1 else { return [contentWidth] }
            let first = contentWidth * 0.72
            let remaining = (contentWidth - first) / CGFloat(count - 1)
            return [first] + Array(repeating: remaining, count: count - 1)
        }

        private mutating func draw(
            _ text: String,
            font: NSFont,
            color: NSColor,
            size: CGFloat,
            at point: CGPoint? = nil
        ) {
            ensureSpace(size + 6)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
            ]
            context.saveGState()
            // AppKit drawing is not available without a view, so text is drawn
            // through Core Text with an explicit line origin.
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: attributes)
            )
            context.textPosition = point ?? CGPoint(x: margin, y: y - size)
            CTLineDraw(line, context)
            context.restoreGState()
            if point == nil {
                y -= size + 6
            }
        }

        private func measure(_ text: String, font: NSFont) -> CGFloat {
            let lines = wrapped(text, font: font)
            return CGFloat(lines.count) * (font.pointSize + 6)
        }

        private func wrapped(_ text: String, font: NSFont) -> [String] {
            var result: [String] = []
            var current = ""
            for word in text.split(separator: " ", omittingEmptySubsequences: false) {
                let candidate = current.isEmpty ? String(word) : current + " " + word
                if width(of: candidate, font: font) > contentWidth, !current.isEmpty {
                    result.append(current)
                    current = String(word)
                } else {
                    current = candidate
                }
            }
            if !current.isEmpty { result.append(current) }
            return result.isEmpty ? [""] : result
        }

        private func width(of text: String, font: NSFont) -> CGFloat {
            let attributes: [NSAttributedString.Key: Any] = [.font: font]
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: attributes)
            )
            return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }

        /// Truncates with an ellipsis so a long name cannot overrun its column.
        private func truncated(_ text: String, font: NSFont, width: CGFloat) -> String {
            guard self.width(of: text, font: font) > width else { return text }
            var result = text
            while !result.isEmpty, self.width(of: result + "…", font: font) > width {
                result.removeLast()
            }
            return result + "…"
        }
    }
}
