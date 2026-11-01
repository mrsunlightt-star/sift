import Foundation

/// A `UserDefaults` domain the test suites can use without leaving anything behind.
///
/// Two decisions here, and both came from a measurement rather than a preference:
///
/// * **The name is stable per test class, not unique per test.** The suites used a
///   UUID, which gave every test in every run its own persistent domain; a machine
///   that runs the suite daily accumulated 7865 files in `~/Library/Preferences`
///   (4609 `entitlement`, 2348 plain, 670 `environment`, 238 self-test). They were
///   invisible until the product's own scan reported them: `~/Library/Preferences`
///   is one of the places application residue lives, so the scan page offered 7.8k
///   rows of this repository's test artifacts as "leftovers you should confirm".
///   One stable name per class is rewritten instead of added to, and a fresh
///   `removePersistentDomain` in `setUp` is what keeps runs independent.
///
/// * **The name is not shaped like a bundle identifier.** Even a stable domain
///   leaves one empty `{ }` plist per class on disk, because `cfprefsd` writes the
///   file back after the keys are removed (measured: the file is gone immediately
///   after deleting it and back 1.5 s later while the process is alive). A name
///   with three or more dot-separated components — `sift.tests.settings` — is
///   exactly what `RuleEngine.looksLikeBundleIdentifier` accepts, so those four
///   files would themselves be reported as residue forever. Without the dots they
///   are not candidates for anything.
///
/// `sifttests-settings` therefore leaks one 42-byte empty plist per test class, and
/// the only thing that grows with the number of runs is nothing.
enum ScratchPreferences {
    /// A stable suite name for one test class.
    ///
    /// The separator is a hyphen and the name has no dots: see the note above.
    static func suite(_ label: String) -> String {
        "sifttests-\(label)"
    }

    /// The domain, opened. Does not clear it: a test that checks a value survived
    /// a second store has to open the same domain again.
    static func open(_ label: String) -> UserDefaults {
        UserDefaults(suiteName: suite(label)) ?? .standard
    }

    /// Clears the domain. Called from `setUp` so a run never inherits the last
    /// one, and from `tearDown` for the same reason.
    ///
    /// The empty plist stays on disk — `cfprefsd` writes it back — which is why the
    /// name has to be one nothing else will interpret as an application.
    static func reset(_ label: String) {
        let name = suite(label)
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        UserDefaults.standard.removePersistentDomain(forName: name)
    }
}
