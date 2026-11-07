import Darwin
import Foundation

/// Removes a path this product owns, and refuses when an ancestor was re-pointed.
///
/// `FileManager.removeItem` does not follow a symbolic link in the *final*
/// component — it unlinks the link — but it does follow one in an ancestor. That
/// difference is the whole reason this type exists: `~/Library/Application
/// Support/Sift` replaced by a link to somewhere else turns "delete the reports
/// this app wrote" into a recursive delete of a tree the user never selected, and
/// every check in this repository is about the path, which reads as the app's own
/// directory either way.
///
/// Four call sites remove or sweep an app-owned path — the report directory, the
/// scan history, the engine index and the sweep that clears the index directory
/// before a scan — so the check lives in one place rather than four. It refuses
/// one shape, a symbolic link anywhere between the entry's parent and the home
/// directory, and does not try to be a general safe-delete. The device and inode
/// of the parent are not compared with a stored snapshot, because these
/// locations are created by the app and a repaired or restored directory is
/// still the app's own; a link is the shape that makes the path stop describing
/// its contents.
public enum OwnedLocationRemoval {
    public enum Refusal: Error, Equatable {
        /// A directory above the entry — its parent or any ancestor between
        /// that and the home — is a symbolic link. The entry behind the chain
        /// is not the tree this product created, so removing it would act on
        /// somebody else's files.
        case ancestorIsSymbolicLink
    }

    /// Removes an entry this product owns. Refuses when any ancestor — the
    /// parent first of all — is a symbolic link, so a re-pointed ancestor
    /// cannot turn an app-owned cleanup into a recursive delete of a tree the
    /// user never selected.
    ///
    /// `lstat` is used rather than `fileExists` or the URL resource values
    /// because both resolve the link and would answer about its target — the
    /// question here is what the directory entry *is*. A failed `lstat`
    /// propagates: an unreadable parent is not an absent one, and the caller's
    /// `catch` reports the real reason instead of a refusal about a link that
    /// may not be there.
    public static func remove(at url: URL, fileManager: FileManager = .default) throws {
        let parent = url.deletingLastPathComponent().path
        var info = stat()
        guard lstat(parent, &info) == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: parent]
            )
        }
        guard ancestorsSpellTheLocation(parent) else {
            throw Refusal.ancestorIsSymbolicLink
        }
        try fileManager.removeItem(at: url)
    }

    /// True when the chain above `path` still spells the location it names: no
    /// ancestor is a symbolic link a restore or a migration left behind.
    ///
    /// `removeItem` follows a link in *any* ancestor component, so an
    /// immediate-parent `lstat` closes only the shape where the removed entry
    /// sits directly in the app's own directory. The history and the engine
    /// index live one level deeper: with `…/Application Support/Sift`
    /// re-pointed, their parent (`…/Sift/Index`) reads as an ordinary
    /// directory whether or not `…/Sift` is a link. The comparison is
    /// lexical-versus-resolved through the product's own normalisation — the
    /// same reconciliation the pre-flight relocation check uses — so the
    /// documented macOS aliases (`/var` → `/private/var`, …) compare equal and
    /// a fixture under `/var/folders` is not refused for one.
    ///
    /// Read-only. A caller that creates or sweeps inside an app-owned
    /// directory asks this before writing; `remove(at:)` re-asks before it
    /// deletes.
    static func ancestorsSpellTheLocation(_ path: String) -> Bool {
        let written = RuleEngine.normalize(path)
        let resolved = RuleEngine.normalize(
            URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        )
        return written == resolved
    }
}
