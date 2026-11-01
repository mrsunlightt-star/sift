import Foundation

/// What a directory name in `~/Library` could be the bundle identifier of.
///
/// macOS names per-application data three ways, and the uninstaller, the residue
/// scan and the group-container scan all have to read the same three:
///
///  * the identifier itself — `com.apple.Safari`;
///  * the identifier with a suffix — `com.apple.Safari.savedState`, `.plist`,
///    `.binarycookies`;
///  * a group container, which is `<team-id>.<identifier>` — `6N38VWS5BX.ru.keepcoder.Telegram`
///    — or the identifier on its own, and an app group may prefix `group.`.
///
/// The team id carries no dot, which is what makes splitting on the first dot
/// safe. Only names that carry a dot are written that way, so a plain folder name
/// (`notes`) yields exactly one reading — the name — and never a truncated one.
///
/// Two implementations of this existed (the residue scan's and the uninstaller's)
/// and they drifted: the uninstaller compared the *whole* name against the
/// identifier, so it never associated the team-prefixed spelling, and a group
/// container of an installed application was invisible in the uninstaller while
/// the scan knew perfectly well what it was.
enum BundleNameReadings {
    /// A name with the suffixes macOS appends to per-application files removed.
    static func stem(_ name: String) -> String {
        for suffix in [".plist", ".binarycookies", ".savedState", ".savedApplicationState"]
        where name.lowercased().hasSuffix(suffix.lowercased()) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    /// The identifiers `name` could stand for, lower-cased, most specific first.
    static func identifiers(_ name: String) -> [String] {
        let lowered = name.lowercased()
        var readings: [String] = []
        if let dot = lowered.firstIndex(of: ".") {
            let prefix = lowered[lowered.startIndex..<dot]
            let suffix = lowered[lowered.index(after: dot)...]
            if !prefix.contains("."), !suffix.isEmpty {
                readings.append(String(suffix))
            }
        }
        readings.append(lowered)
        return readings
    }

    /// True when `name` is the identifier, or one of the spellings that contains it.
    ///
    /// Used where a *confident* answer is required: the identifier is either the
    /// whole name, a prefix of it (`<id>.savedState`), or the part after a team
    /// id. A name match alone is never this, which is why it is not here.
    static func names(_ name: String, identifier: String) -> Bool {
        guard !identifier.isEmpty else { return false }
        let target = identifier.lowercased()
        if identifiers(stem(name)).contains(target) { return true }
        return name.lowercased().hasPrefix(target + ".")
    }
}
