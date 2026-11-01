import Foundation
import Shared

/// A rule the user could add for a directory no shipped rule reaches.
///
/// The coverage audit reports the large folders nothing claims — and the honest
/// next step is not "Sift will start cleaning it" but "here is the rule that would
/// recognise it, if you want it". The draft is therefore:
///
///  * **`review` and aged.** A directory Sift knows nothing about is not
///    pre-selected, and only its children untouched for a month are offered. A
///    draft that arrived at `safe` would clean data nobody had judged.
///  * **`childDirectories` of the folder**, not the folder itself: `~/Library/Huawei`
///    holds one `Sdk` directory, and offering a whole vendor tree as one item is
///    the shape this product refuses everywhere else.
///  * **Validated before it is shown.** It is decoded through the same loader the
///    app uses, so a draft that would be rejected at the next launch is never
///    handed to a user: the snippet either loads or the audit says why it cannot.
///
/// Nothing here applies the rule. It writes a document and copies it; the user
/// puts it in their own rule file, where `RuleEngine` validates it again.
public struct RuleDraft: Sendable, Equatable {
    /// Why a directory cannot become a rule.
    public enum Refusal: Error, Sendable, Equatable {
        /// Not inside the home directory, so no anchor names it.
        case outsideTheHome
        /// The path is the anchor itself — an anchor is a place to look inside.
        case anchorItself
        /// A container rule would offer every application's data at once.
        case container(String)
        /// The protection list refuses the directory.
        case protected
        /// The loader refused the draft, which means this build would not load it.
        case notLoadable(String)

        /// The sentence the page shows.
        public var message: String {
            switch self {
            case let .container(name):
                LocalizationKey.diagnosticsCoverageDraftCannot.localized(name)
            case let .notLoadable(reason):
                LocalizationKey.diagnosticsCoverageDraftCannot.localized(reason)
            case .outsideTheHome, .anchorItself, .protected:
                LocalizationKey.diagnosticsCoverageDraftCannot.localized(
                    LocalizationKey.commonNotAvailable.localized
                )
            }
        }
    }

    public let ruleID: String
    public let directory: URL
    /// The rule document, one rule, ready to paste into `CleaningRules.json`.
    public let json: String

    /// Builds the draft for `url`, or explains why there is none.
    public static func make(for url: URL, rules: RuleEngine) -> Result<RuleDraft, Refusal> {
        let home = rules.homeDirectory
        let path = RuleEngine.normalize(url.path)
        guard RuleEngine.isPrefix(home, path) else { return .failure(.outsideTheHome) }
        if path == home || path == "\(home)/Library" { return .failure(.anchorItself) }
        if rules.protectionReason(for: path) != nil { return .failure(.protected) }

        let anchor: (String, String)
        if let relative = Self.relative(path, below: "\(home)/Library") {
            anchor = ("homeLibrary", relative)
        } else if let relative = Self.relative(path, below: home) {
            anchor = ("home", relative)
        } else {
            return .failure(.outsideTheHome)
        }
        let relative = anchor.1
        guard !relative.isEmpty else { return .failure(.anchorItself) }
        // The same check the loader applies, made here so the refusal names the
        // container instead of a JSON parse error later.
        if let forbidden = RuleEngine.forbiddenRuleDirectory(relative, matchSpec: .childDirectories) {
            return .failure(.container(forbidden))
        }
        // And the shape a draft uses: its items are `relativePath/*`, so a
        // relative path one or two levels inside a container would offer an
        // application's data root as one item — `Application Support/Google` would
        // put `…/Google/Chrome` in the list.
        if RuleEngine.childrenWouldExposeApplicationData(relative) {
            return .failure(.container(relative.split(separator: "/").first.map(String.init) ?? relative))
        }

        let ruleID = "user-" + Self.slug(relative)
        let document = """
        {
          "id": "\(ruleID)",
          "category": "temporaryFiles",
          "risk": "review",
          "root": "\(anchor.0)",
          "relativePath": "\(relative)",
          "matchSpec": "childDirectories",
          "minAgeDays": 30,
          "explanationKey": "cleanup.explanation.temporary",
          "enabled": true
        }
        """

        // Loaded through the product's own decoder: a draft this build refuses is
        // a draft that would be dropped at the next launch, and handing it over
        // would be a promise the app cannot keep.
        let wrapper = #"{"schemaVersion":1,"rules":["# + document + "]}"
        do {
            let decoded = try RuleEngine.decode(Data(wrapper.utf8))
            guard decoded.count == 1, decoded[0].id == ruleID else {
                return .failure(.notLoadable(ruleID))
            }
        } catch {
            return .failure(.notLoadable(String(describing: error)))
        }

        return .success(RuleDraft(ruleID: ruleID, directory: url, json: document + "\n"))
    }

    /// `path` below `base`, or `nil` when it is not below it.
    private static func relative(_ path: String, below base: String) -> String? {
        guard RuleEngine.isPrefix(base, path), path != base else { return nil }
        return String(path.dropFirst(base.count + 1))
    }

    /// A rule id from a path: lower-case, dashes, nothing else.
    private static func slug(_ relativePath: String) -> String {
        let parts = relativePath
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        return parts.isEmpty ? "rule" : parts.joined(separator: "-")
    }
}
