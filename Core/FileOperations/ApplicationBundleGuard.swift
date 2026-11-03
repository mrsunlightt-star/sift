import Darwin
import Foundation

/// Decides whether one path may be moved out of `/Applications` by an uninstall.
///
/// The protection list refuses `/Applications` as a whole, and the uninstaller is
/// the one flow that has to get past it: its subject *is* the bundle, and it does
/// not come from a rule at all — the user picks an application from the installed
/// list — so the protection is not doing its job there, it is only making the
/// feature impossible. Lifting it for "any path under `/Applications` on an
/// uninstall", though, answers a question nobody asked. A prefix comparison
/// cannot tell an application bundle from a directory that merely sits in that
/// folder: a vendor subfolder, a bundle's own `Contents`, a link somebody dropped
/// there and Apple's own applications all read the same way.
///
/// This type is the missing question, and it answers with a *reason* rather than a
/// boolean so the flow can say which check refused the path. `nil` is returned
/// only for a bundle an uninstall may move: a directory whose name ends in `.app`,
/// whose parent is `/Applications` itself, which is not a link, which carries a
/// readable `CFBundleIdentifier`, and which is not Apple's.
///
/// Nothing here has a side effect: the only two things it reads are `lstat` on the
/// bundle and `Contents/Info.plist` inside it, and nothing throws, because a bundle
/// that cannot answer a question is a refusal rather than a failure. The check is
/// pure so it can run in pre-flight, again immediately before the move, and in a
/// test, and give the same answer each time.
public enum ApplicationBundleGuard {
    /// Why a path may not be moved by an uninstall.
    ///
    /// One case per question, in the order they are asked, so a caller that shows
    /// the reason to the user can say what is wrong with *this* path rather than
    /// "not uninstallable".
    public enum Refusal: String, Sendable, CaseIterable {
        /// The path does not name an application bundle at all.
        ///
        /// A plain file or folder in `/Applications` is not an application, and
        /// neither is a path that points *inside* one: `/Applications/Foo.app/
        /// Contents` is the bundle's data, not the bundle.
        case notAnApplicationBundle
        /// The bundle's parent directory is not `/Applications`.
        ///
        /// A vendor subfolder (`/Applications/Sub/Foo.app`), a mounted volume
        /// (`/Volumes/X/Foo.app`) and Apple's own `/System/Applications` are all
        /// bundles somewhere else. The uninstaller's subject is an application the
        /// user installed, and the exceptions this guard opens are keyed to one
        /// directory; a second spelling of "an application directory" would widen
        /// them without anybody deciding to.
        case notDirectlyInApplications
        /// The bundle is not a directory, or it is a symbolic link to one.
        ///
        /// A move acts on the object the user selected, not on a name that
        /// resolves to something else: `trashItem` follows a link, so a link
        /// standing where a bundle was selected would move whatever it points at —
        /// including an application outside `/Applications` that this guard never
        /// judged. `lstat` is what makes the question about the directory entry
        /// itself rather than about its target.
        case notADirectory
        /// `Contents/Info.plist` carries no usable `CFBundleIdentifier`.
        ///
        /// The identifier is what the rest of the uninstaller works from — the
        /// associated files, containers and app groups are found by it — so a
        /// bundle without one is a bundle this product cannot uninstall correctly,
        /// and a half-copied directory that happens to be called `.app` is the
        /// usual way that arrives.
        case missingBundleIdentifier
        /// The bundle is Apple's.
        ///
        /// System applications are replaced by software update and are not the
        /// user's to remove; the identifier prefix is the statement available
        /// without reading a signature, and reading one here would make a pure
        /// check depend on the code-signing subsystem.
        case systemApplication
    }

    /// The only directory this guard admits as a bundle's parent.
    ///
    /// A constant rather than a literal inside the function so the fixture seam
    /// below names the same thing, and so a reader can see that the directory is
    /// not configurable from outside the module.
    static let applicationsDirectory = "/Applications"

    /// The prefix an Apple bundle identifier carries. Compared case-folded,
    /// because the identifier is written by hand in an `Info.plist`.
    private static let appleIdentifierPrefix = "com.apple."

    /// `nil` when the URL may be moved by an uninstall; the reason otherwise.
    public static func refusal(for url: URL) -> Refusal? {
        refusal(for: url, applicationsDirectory: applicationsDirectory)
    }

    /// True when an uninstall may move the bundle at `url`.
    ///
    /// Expressed as the absence of a refusal and nothing else, so there cannot be
    /// a second opinion about what "uninstallable" means.
    public static func isUninstallable(_ url: URL) -> Bool {
        refusal(for: url) == nil
    }

    /// The same question with the parent directory stated.
    ///
    /// Internal, and for one reason: `/Applications` cannot be synthesised inside
    /// a test fixture — it is a real directory on the boot volume — so the accept
    /// path could otherwise only be tested against whatever this machine happens
    /// to have installed, which is a report about the machine rather than a test.
    /// A fixture bundle whose parent is passed in here runs the same code the
    /// public entry point runs, with the one input a temporary directory cannot
    /// supply.
    ///
    /// The order of the checks is deliberate. The two path-shape refusals are
    /// string facts and come first: they need no disk access, so they hold for a
    /// path that does not exist and they cannot be confused by a link. The disk
    /// identity comes next, because everything after it inspects *through* the
    /// path — reading a plist through a link is exactly the mistake this check
    /// exists to prevent. The identifier is read last, because it is the only
    /// check that reads content.
    static func refusal(for url: URL, applicationsDirectory: String) -> Refusal? {
        let path = RuleEngine.normalize(url.path)
        let name = RuleEngine.folded((path as NSString).lastPathComponent)

        // `.app` and not merely a name containing it: a bundle's name *ends* in the
        // suffix, and a path pointing inside a bundle ends in a component of its
        // own. A bare `.app` is a hidden directory, not an application.
        guard name.hasSuffix(".app"), name != ".app" else {
            return .notAnApplicationBundle
        }

        // Compared through the repository's one normaliser, and case-folded for the
        // same reason the protection list folds: macOS volumes are case-insensitive
        // by default, so `/applications` and `/Applications` are one directory and
        // two answers would be a bug on a volume that spells it either way.
        let parent = RuleEngine.folded((path as NSString).deletingLastPathComponent)
        let expected = RuleEngine.folded(RuleEngine.normalize(applicationsDirectory))
        guard parent == expected else {
            return .notDirectlyInApplications
        }

        // `lstat`, not `stat`: the question is what the directory entry is. A link
        // reports `S_IFLNK` here and fails the test below instead of being followed
        // to whatever it points at. A path that cannot be read at all is refused
        // too — an object this check could not see is not an object it verified.
        var info = stat()
        guard lstat(path, &info) == 0 else { return .notADirectory }
        guard info.st_mode & S_IFMT == S_IFDIR else { return .notADirectory }

        guard let identifier = bundleIdentifier(inBundleAt: path) else {
            return .missingBundleIdentifier
        }
        if RuleEngine.folded(identifier).hasPrefix(appleIdentifierPrefix) {
            return .systemApplication
        }
        return nil
    }

    /// `CFBundleIdentifier` as written in `Contents/Info.plist`, or `nil`.
    ///
    /// `Bundle(url:)` would be the shorter route and the wrong one. It answers for
    /// a bundle the platform considers launchable, so a directory that is missing
    /// `Contents/MacOS` — a half-copied or hand-assembled `.app` — comes back
    /// without an identifier even though the plist states one, and the row the
    /// user is about to approve would be refused for a reason that is not true.
    /// Reading the plist asks the question this guard means to ask.
    ///
    /// Every way the read can fail lands on `nil` rather than on an error: an
    /// absent file, an unreadable one, a plist that is not a dictionary, a value
    /// that is not a string and an identifier that is only whitespace all say the
    /// same thing to the caller — there is no identifier to work from.
    private static func bundleIdentifier(inBundleAt path: String) -> String? {
        let plist = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist) else { return nil }
        guard
            let decoded = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ),
            let fields = decoded as? [String: Any],
            let identifier = fields["CFBundleIdentifier"] as? String
        else {
            return nil
        }
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
