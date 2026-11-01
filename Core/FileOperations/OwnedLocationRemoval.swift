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
/// Three services remove an app-owned path — the report directory, a settings
/// backup and the Rust engine's on-disk index — so the check lives in one place
/// rather than three. It is deliberately narrow: it refuses one shape (a symbolic
/// link where the parent directory should be) and does not try to be a general
/// safe-delete. The device and inode of the parent are not compared with a stored
/// snapshot, because these locations are created by the app and a repaired or
/// restored directory is still the app's own; a link is the shape that makes the
/// path stop describing its contents.
public enum OwnedLocationRemoval {
    public enum Refusal: Error, Equatable {
        /// The immediate parent of `url` is a symbolic link. The entry behind it
        /// is not the tree this product created, so removing it would act on
        /// somebody else's files.
        case parentIsSymbolicLink
    }

    /// Removes an entry this product owns. Refuses when the parent directory is a
    /// symbolic link, so a re-pointed ancestor cannot turn an app-owned cleanup
    /// into a recursive delete of a tree the user never selected.
    ///
    /// `lstat` is used rather than `fileExists` or the URL resource values
    /// because both resolve the link and would answer about its target — the
    /// question here is what the directory entry *is*. A failed `lstat`
    /// propagates: an unreadable parent is not an absent one, and the caller's
    /// `catch` reports the real reason instead of a refusal about a link that may
    /// not be there.
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
        if info.st_mode & S_IFMT == S_IFLNK {
            throw Refusal.parentIsSymbolicLink
        }
        try fileManager.removeItem(at: url)
    }
}
