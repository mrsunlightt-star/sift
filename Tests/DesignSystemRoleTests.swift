import Foundation
import XCTest

/// The design system splits colour by role, and the pages used not to.
///
/// `SiftColor.accent` is a *fill*: the bright jade behind a wash, a gradient or a
/// selection mark. On a page's glass surface it is 2.54:1, which is not a colour
/// small text may be written in — `accentText` is, at 4.54:1. Both tokens existed
/// and the pages kept painting the rail labels, the eyebrows, the counters and
/// the small glyphs with the fill, so the split was a policy nobody enforced.
///
/// This file is the enforcement. It reads the app's own sources rather than its
/// types, because the defect is a call site: `SiftColor.accent` is perfectly
/// correct one character to the left, in `.fill(...)`, `.shadow(...)` and
/// `.background(...)`. Only `.foregroundStyle` is the text/glyph role, so only
/// that shape is refused.
final class DesignSystemRoleTests: XCTestCase, @unchecked Sendable {
    /// The two palette entries that must never reach a page foreground.
    ///
    /// `accentDeep` is not here: it is the pressed-control *fill*, and a control
    /// that paints a label on it writes `onAccent` for the label.
    private static let fillTokens = ["SiftColor.accent", "SiftColor.accentBright"]

    /// Where the pages live. `Shared/` is deliberately not scanned: it is where
    /// the two roles are defined, and the components there keep
    /// `SiftColor.accent` for the rail's selection mark, a usage bar's fill and a
    /// hero glyph's tile — all of them `.fill` or a gradient, never a foreground
    /// written on a page.
    private static let scannedDirectories = ["App", "Features"]

    /// The opt-out a call site may write at the end of the line.
    ///
    /// One legitimate case exists today: an illustration glyph drawn inside its
    /// own accent-tinted tile (the idiom `SiftHeroCard` and `IconTile` share),
    /// where the tile is a fill and the card's own title carries the meaning.
    /// The marker takes a reason after it and sits on the `.foregroundStyle(`
    /// call or on the line directly above it — the second test fails a marker
    /// that is not beside such a call, so one left behind after a fix cannot
    /// linger.
    private static let optOutMarker = "// fill-role:"

    // MARK: - The role split

    /// No page paints text or a glyph with the fill palette.
    func test_noPagePaintsTextOrAGlyphWithTheFillToken() throws {
        guard let root = Self.repositoryRoot() else { return }
        var findings: [String] = []
        var scanned: [String] = []

        for directory in Self.scannedDirectories {
            for file in try Self.swiftFiles(under: root.appendingPathComponent(directory)) {
                let relativePath = Self.relativePath(of: file, from: root)
                scanned.append(relativePath)
                let source = try String(contentsOf: file, encoding: .utf8)
                for foreground in Self.foregrounds(in: source) {
                    guard Self.fillTokens.contains(foreground.argument) else { continue }
                    guard !foreground.isOptedOut else { continue }
                    findings.append(
                        "\(relativePath):\(foreground.line) paints a foreground with \(foreground.argument); "
                            + "the text and glyph roles are SiftColor.accentText, and a label laid on an "
                            + "accent surface is SiftColor.onAccent over SiftColor.accentFill"
                    )
                }
            }
        }

        // A scan that reads nothing proves nothing, and a lookup that quietly
        // resolved to an empty directory would make this test pass forever.
        XCTAssertTrue(
            scanned.contains("App/Shell/RootView.swift"),
            "the page sources were not found under \(root.path); this test read \(scanned.count) files"
        )
        XCTAssertGreaterThanOrEqual(
            scanned.count,
            10,
            "only \(scanned.count) page sources were found under \(root.path)"
        )
        XCTAssertEqual(findings, [], "\n" + findings.joined(separator: "\n"))
    }

    /// An opt-out must excuse a foreground that actually uses a fill token.
    ///
    /// Otherwise the marker survives the fix that made it unnecessary, and the
    /// next fill token written on that line is excused by an argument that was
    /// about something else.
    func test_anOptOutIsOnlyWrittenOnAForegroundThatUsesAFillToken() throws {
        guard let root = Self.repositoryRoot() else { return }
        var offenders: [String] = []

        for directory in Self.scannedDirectories {
            for file in try Self.swiftFiles(under: root.appendingPathComponent(directory)) {
                let relativePath = Self.relativePath(of: file, from: root)
                let source = try String(contentsOf: file, encoding: .utf8)
                // The marker may sit on the call's own line or the one above it,
                // so a commented line excuses the next one — and only that one.
                var foregroundLines = Set<Int>()
                for foreground in Self.foregrounds(in: source)
                where Self.fillTokens.contains(foreground.argument) {
                    foregroundLines.insert(foreground.line)
                    foregroundLines.insert(foreground.line - 1)
                }
                for (number, text) in Self.lines(of: source) where text.contains(Self.optOutMarker) {
                    let reason = text
                        .components(separatedBy: Self.optOutMarker)
                        .dropFirst()
                        .joined()
                        .trimmingCharacters(in: .whitespaces)
                    if reason.isEmpty {
                        offenders.append("\(relativePath):\(number) has an empty fill-role reason")
                    }
                    if !foregroundLines.contains(number) {
                        offenders.append(
                            "\(relativePath):\(number) marks a fill role on a line that is not a "
                                + ".foregroundStyle(\(Self.fillTokens.joined(separator: " or "))) call"
                        )
                    }
                }
            }
        }

        XCTAssertEqual(offenders, [], "\n" + offenders.joined(separator: "\n"))
    }

    // MARK: - Reading the sources

    /// The repository root, found by walking up from this file.
    ///
    /// The suite runs from three places — Xcode, `swift test`, and
    /// `Scripts/run-tests.sh`, which compiles a rewritten copy of `Tests/` under
    /// `.build/test-run` — so the root comes from walking up to the directory
    /// that holds both page trees rather than from counting parent directories.
    /// When it is not reachable the test *fails*, naming every directory it
    /// tried: a guard that cannot find the sources must never report them clean.
    private static func repositoryRoot(
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> URL? {
        let manager = FileManager.default
        var tried: [String] = []
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

        while directory.path != "/" {
            tried.append(directory.path)
            let rootView = directory.appendingPathComponent("App/Shell/RootView.swift")
            let features = directory.appendingPathComponent("Features")
            if manager.fileExists(atPath: rootView.path), manager.fileExists(atPath: features.path) {
                return directory
            }
            directory.deleteLastPathComponent()
        }

        XCTFail(
            "the repository root is not reachable from \(#filePath); looked for "
                + "App/Shell/RootView.swift and Features/ in: \(tried.joined(separator: ", "))",
            file: file,
            line: line
        )
        // Reported already; the caller returns so the empty scan cannot be read
        // as a clean one. A guard that cannot find the sources is a failure, not
        // a pass.
        return nil
    }

    private static func swiftFiles(under directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func relativePath(of file: URL, from root: URL) -> String {
        let prefix = root.standardizedFileURL.path + "/"
        let path = file.standardizedFileURL.path
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    private static func lines(of source: String) -> [(number: Int, text: String)] {
        source
            .components(separatedBy: "\n")
            .enumerated()
            .map { (number: $0.offset + 1, text: $0.element) }
    }

    /// A `.foregroundStyle(...)` argument, the line it starts on, and that line.
    private struct Foreground {
        let line: Int
        let argument: String
        let lineText: String
        let previousLineText: String

        /// Whether the call site has written the one comment that excuses it.
        var isOptedOut: Bool {
            lineText.contains(DesignSystemRoleTests.optOutMarker)
                || previousLineText.contains(DesignSystemRoleTests.optOutMarker)
        }
    }

    /// Every `.foregroundStyle(...)` in a file.
    ///
    /// The argument is matched by balancing parentheses rather than by taking the
    /// rest of the line, so `.foregroundStyle(tint.opacity(0.5))` and a call
    /// broken across lines both read as one unit — and so that
    /// `SiftColor.accentText` is compared as the token it is instead of matching
    /// a prefix of `SiftColor.accent`.
    private static func foregrounds(in source: String) -> [Foreground] {
        let marker = ".foregroundStyle("
        let allLines = lines(of: source)
        var found: [Foreground] = []
        var searchStart = source.startIndex

        while let call = source.range(of: marker, range: searchStart..<source.endIndex) {
            var depth = 1
            var index = call.upperBound
            while index < source.endIndex {
                switch source[index] {
                case "(": depth += 1
                case ")": depth -= 1
                default: break
                }
                if depth == 0 { break }
                index = source.index(after: index)
            }

            let argument = source[call.upperBound..<index]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let line = lineNumber(of: source.distance(from: source.startIndex, to: call.lowerBound), in: source)
            found.append(
                Foreground(
                    line: line,
                    argument: argument,
                    lineText: allLines.indices.contains(line - 1) ? allLines[line - 1].text : "",
                    previousLineText: allLines.indices.contains(line - 2) ? allLines[line - 2].text : ""
                )
            )
            searchStart = index < source.endIndex ? source.index(after: index) : source.endIndex
        }
        return found
    }

    private static func lineNumber(of offset: Int, in source: String) -> Int {
        let end = source.index(source.startIndex, offsetBy: offset)
        var line = 1
        for character in source[source.startIndex..<end] where character == "\n" {
            line += 1
        }
        return line
    }
}
