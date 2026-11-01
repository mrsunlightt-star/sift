//! Cleaning rule definitions for the Sift scanner core.
//!
//! Rules are the only place that decides *what may be recognised* and *how risky*
//! a location is. They are deliberately declarative so that the same definition
//! drives the Rust scanner, the unit tests and the shipped `CleaningRules.json`.
//!
//! Two invariants matter for safety:
//!
//! 1. `PROTECTED_PREFIXES`, `PROTECTED_HOME_CHILDREN` and
//!    `PROTECTED_LIBRARY_CHILDREN` are compiled in. They are also the single
//!    source for the Swift protection list, which
//!    `Scripts/generate-protection.py` generates from this file. A rule file can
//!    only widen the *recognised* set, never unprotect these paths.
//! 2. Every rule carries an explicit `risk`. Nothing defaults to `Safe`.

use serde::{Deserialize, Serialize};
use std::path::{Component, Path};

/// Risk levels, mirroring `CleanupRisk` on the Swift side.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Risk {
    /// Rebuildable or explicitly temporary content.
    Safe,
    /// Usually removable but the user should confirm.
    Review,
    /// Must never enter a deletion queue.
    Protected,
}

impl Risk {
    pub const fn as_str(self) -> &'static str {
        match self {
            Risk::Safe => "safe",
            Risk::Review => "review",
            Risk::Protected => "protected",
        }
    }

    /// Risk levels combined for a whole directory: the most cautious one wins.
    pub fn combine(self, other: Risk) -> Risk {
        self.max(other)
    }
}

/// Cleanup categories, mirroring `CleanupCategory` on the Swift side.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Category {
    ApplicationCache,
    Logs,
    Installers,
    TemporaryFiles,
    LargeFiles,
    OldFiles,
    DuplicateFiles,
    ApplicationResidue,
    /// The shared container of an application that is gone.
    ///
    /// A separate category rather than a second kind of `applicationResidue`,
    /// because the claim is different: `~/Library/Containers/<id>` is one
    /// application's private data, while
    /// `~/Library/Group Containers/<team-id>.<id>` is a container an app group
    /// shares, and removing one can affect a sibling that is still installed. The
    /// uninstaller already treats the two differently (a group container is
    /// always "review"); this is the same distinction on the scan page.
    GroupContainerResidue,
}

impl Category {
    pub const fn as_str(self) -> &'static str {
        match self {
            Category::ApplicationCache => "applicationCache",
            Category::Logs => "logs",
            Category::Installers => "installers",
            Category::TemporaryFiles => "temporaryFiles",
            Category::LargeFiles => "largeFiles",
            Category::OldFiles => "oldFiles",
            Category::DuplicateFiles => "duplicateFiles",
            Category::ApplicationResidue => "applicationResidue",
            Category::GroupContainerResidue => "groupContainerResidue",
        }
    }

    /// Category order used when the UI groups results.
    pub const fn display_order(self) -> u8 {
        match self {
            Category::ApplicationCache => 0,
            Category::Logs => 1,
            Category::Installers => 2,
            Category::TemporaryFiles => 3,
            Category::ApplicationResidue => 4,
            Category::LargeFiles => 5,
            Category::OldFiles => 6,
            Category::DuplicateFiles => 7,
            Category::GroupContainerResidue => 8,
        }
    }
}

/// Where a rule's `relative_path` is anchored.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RootAnchor {
    /// `~/`
    Home,
    /// `~/Library/`
    HomeLibrary,
    /// `/Applications` plus `~/Applications`
    Applications,
    /// `/Library`
    SystemLibrary,
    /// The per-user temporary root macOS gives this login session.
    ///
    /// `/var/folders/<two>/<hash>` — the parent of `$TMPDIR`, holding `T` (the
    /// temporary directory) and `C` (the per-user cache directory). Unlike every
    /// other fixed anchor it is not derived from the home directory, so it is not
    /// resolvable from a rule: the request carries it, as a scan root with
    /// `anchor: "userTemp"`, and the Swift engine reads the same value.
    UserTemp,
    /// A directory the user explicitly authorised in settings.
    Authorized,
    /// An external volume the user explicitly selected.
    ExternalVolume,
}

impl RootAnchor {
    pub const fn as_str(self) -> &'static str {
        match self {
            RootAnchor::Home => "home",
            RootAnchor::HomeLibrary => "homeLibrary",
            RootAnchor::Applications => "applications",
            RootAnchor::SystemLibrary => "systemLibrary",
            RootAnchor::UserTemp => "userTemp",
            RootAnchor::Authorized => "authorized",
            RootAnchor::ExternalVolume => "externalVolume",
        }
    }
}

/// The match specification as a rule file writes it.
///
/// A rule file says `{"matchSpec": "filesByExtension", "extensions": ["dmg"]}`:
/// the extension list is a sibling of `matchSpec`, which is the shape
/// `Core/Resources/CleaningRules.json` ships and the shape a user rule file
/// copies. An externally tagged enum cannot express that — serde would demand
/// `{"filesByExtension": {"extensions": [...]}}` and reject the shipped file
/// with a parse error, which for an overlay means the whole scan fails.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MatchSpecName {
    /// The directory itself is the cleanup item.
    Directory,
    /// Direct children directories are individual cleanup items.
    ChildDirectories,
    /// Files under the root with one of the rule's extensions.
    FilesByExtension,
    /// Any file below the root; used together with an age threshold.
    AnyFile,
    /// Direct child directories whose own name is in the rule's `names`.
    DirectoriesNamed,
}

/// What a rule considers a match, with the extension list resolved.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MatchSpec {
    /// The directory itself is the cleanup item (`~/Library/Caches`).
    Directory,
    /// Direct children directories are individual cleanup items
    /// (`~/Library/Logs/<app>`).
    ChildDirectories,
    /// Files under the root matching the given lower-cased extensions.
    FilesByExtension { extensions: Vec<String> },
    /// Any file below the root; used together with an age threshold.
    AnyFile,
    /// Direct child directories whose own name is in the rule's `names`.
    ///
    /// `childDirectories` with a filter that is part of the rule rather than part
    /// of a path: an application names its cache directory `Cache`, `Caches`,
    /// `GPUCache` or `Code Cache` depending on the framework it was built with,
    /// and a model without a name set needs one rule per spelling.
    DirectoriesNamed { names: Vec<String> },
}

/// A single declarative cleaning rule.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Rule {
    pub id: String,
    pub category: Category,
    pub risk: Risk,
    pub root: RootAnchor,
    /// Path relative to the anchor, `""` means the anchor itself.
    #[serde(default)]
    pub relative_path: String,
    #[serde(default)]
    pub match_spec: Option<MatchSpecName>,
    /// Extensions a `filesByExtension` rule matches, lower-cased on use.
    ///
    /// A sibling of `match_spec` in the document, matching the Swift decoder and
    /// the shipped rule file.
    #[serde(default)]
    pub extensions: Vec<String>,
    /// Directory names a `directoriesNamed` rule matches, compared without case.
    ///
    /// A sibling of `match_spec` for the same reason `extensions` is: the
    /// document says `{"matchSpec":"directoriesNamed","names":["Cache"]}` and an
    /// externally tagged enum cannot express that without changing the shape the
    /// shipped file already uses.
    #[serde(default)]
    pub names: Vec<String>,
    /// Path fragments that must be skipped even inside a matching rule.
    #[serde(default)]
    pub excludes: Vec<String>,
    /// Only match entries not modified for at least this many days.
    #[serde(default)]
    pub min_age_days: Option<u32>,
    /// Whether the user's stale threshold replaces [`Rule::min_age_days`].
    ///
    /// §5.2 gives the user one age at which a log or installer counts as stale.
    /// A rule that says so here follows that setting; one that does not keeps the
    /// age it states, so `download-archives` stays at its own 90 days however the
    /// setting is moved.
    #[serde(default)]
    pub uses_stale_threshold: bool,
    /// Directory names below the root that are scanned as a unit instead of
    /// being expanded file by file (macOS application bundles).
    #[serde(default)]
    pub package_extensions: Vec<String>,
    #[serde(default)]
    pub requires_full_disk_access: bool,
    /// Whether the data under this rule belongs to an application, so that
    /// application must not be running while an item is removed.
    ///
    /// A cache directory is not locked the way an `.app` bundle is: the move
    /// succeeds, the application keeps writing into the path it remembers, and
    /// the directory reappears a moment later — or, worse, the application
    /// loses the state it was in the middle of writing. This flag says "the
    /// owner may be running, so check" and the scan downgrades a `safe` item to
    /// `review` when any running application's name or identifier appears in
    /// the item's path (see [`running_app_owns_path`]). The shipped flags are
    /// on the rules whose items a single application owns.
    #[serde(default)]
    pub needs_app_closed: bool,
    /// Localisation key for the explanation shown to users.
    pub explanation_key: String,
    #[serde(default = "default_enabled")]
    pub enabled: bool,
}

const fn default_enabled() -> bool {
    true
}

impl Rule {
    /// The concrete match specification, with the extension list resolved and
    /// the layout default applied.
    pub fn effective_match_spec(&self) -> MatchSpec {
        match self.match_spec {
            Some(MatchSpecName::Directory) => MatchSpec::Directory,
            Some(MatchSpecName::ChildDirectories) => MatchSpec::ChildDirectories,
            Some(MatchSpecName::AnyFile) => MatchSpec::AnyFile,
            Some(MatchSpecName::DirectoriesNamed) => MatchSpec::DirectoriesNamed {
                names: self.names.clone(),
            },
            Some(MatchSpecName::FilesByExtension) => MatchSpec::FilesByExtension {
                // Lower-cased here rather than at the comparison, so the defaults
                // and a hand-written rule file behave identically.
                extensions: self
                    .extensions
                    .iter()
                    .map(|e| e.to_ascii_lowercase())
                    .collect(),
            },
            None if self.relative_path.is_empty() => MatchSpec::ChildDirectories,
            None => MatchSpec::Directory,
        }
    }

    /// The age threshold this rule applies for a scan, in days.
    ///
    /// The user sets one stale threshold for logs and installers (§5.2), and a
    /// rule marked `uses_stale_threshold` takes its age from there. A threshold of
    /// zero leaves the rule's own age in force: a setting that was never stored
    /// must not make every file instantly stale.
    pub fn effective_min_age_days(&self, stale_threshold_days: u32) -> Option<u32> {
        if self.uses_stale_threshold && self.min_age_days.is_some() && stale_threshold_days > 0 {
            Some(stale_threshold_days)
        } else {
            self.min_age_days
        }
    }
}

/// A versioned collection of rules loaded from `CleaningRules.json`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RuleSet {
    pub schema_version: u32,
    pub rules: Vec<Rule>,
}

/// Rule schema version understood by this build.
pub const RULE_SCHEMA_VERSION: u32 = 1;

/// The largest age a rule file may state, in days.
///
/// The scanner compares a file's age against this number, so the domain is a
/// safety property rather than a formatting one: a negative age makes every
/// file stale, and an age past this bound is a typo that silently disables the
/// rule. Swift and Rust both validate it against this bound, because a document
/// one engine accepts and the other refuses fails the whole scan.
pub const MAX_RULE_MIN_AGE_DAYS: u32 = 3650;

/// Directory names no rule may target, whoever wrote the rule file.
///
/// Each of these holds the live data of *every* application at once, and a
/// rule can only match a name shape or an age — it cannot know whether an
/// application is installed. A `childDirectories` rule here offers each
/// application's data as one item, and with `risk: safe` that item arrives
/// pre-selected. Orphaned containers and residue are found at scan time by
/// [`Category::ApplicationResidue`] scanners instead, which compare names
/// against what is actually installed.
///
/// The shipped table is asserted against this list, and [`from_json`] refuses a
/// rule file that names one, so the invariant holds for a rule this build does
/// not ship as well.
pub const FORBIDDEN_RULE_DIRECTORIES: &[&str] =
    &["Containers", "Group Containers", "Application Support"];

/// The forbidden directory a relative path names, if it names one.
///
/// Two shapes are refused, and both offer every application's data as a set of
/// individual items:
///
/// * the container is the item — `Containers`, or any path ending in it;
/// * the wildcard is the container's direct child — `Containers/*`, which is
///   one item per installed application.
///
/// A path that *descends through* a container to a named location inside it is
/// a different thing and stays allowed: `Containers/*/Data/Library/Caches` is
/// one directory per application, named by the platform rather than guessed.
///
/// Components are compared after collapsing `.` and duplicate separators, and
/// case-folded, because these are ordinary directory names on a volume that
/// does not distinguish case.
pub fn forbidden_rule_directory(
    relative_path: &str,
    spec: Option<MatchSpecName>,
) -> Option<&'static str> {
    let components: Vec<&str> = relative_path
        .split('/')
        .filter(|component| !component.is_empty() && *component != ".")
        .collect();

    let forbidden = |name: &str| {
        FORBIDDEN_RULE_DIRECTORIES
            .iter()
            .find(|forbidden| name.eq_ignore_ascii_case(forbidden))
            .copied()
    };

    if let Some(last) = components.last() {
        if let Some(name) = forbidden(last) {
            return Some(name);
        }
    }
    // `<container>/*`: the container's own children, one item each — unless the
    // specification names what to look for inside them, which is what
    // `directoriesNamed` does. `Application Support/*` with `childDirectories`
    // offers every application's data root; with `directoriesNamed ["Cache"]` it
    // offers one named cache directory per application, which is the rule this
    // build ships.
    if components.len() == 2
        && components[1] == "*"
        && spec != Some(MatchSpecName::DirectoriesNamed)
    {
        if let Some(name) = forbidden(components[0]) {
            return Some(name);
        }
    }
    None
}

/// The one wildcard a relative path may use.
///
/// A component is either a literal directory name or exactly this, and it
/// matches exactly one directory name. Partial shapes (`com.apple.*`), recursive
/// shapes (`**`) and a leading wildcard are refused: the first two mean the rule
/// says something the scanner cannot enumerate safely, and a leading `*` would
/// make one rule span every child of its anchor — for `~/Library` that is every
/// application's data root, which is the shape
/// [`FORBIDDEN_RULE_DIRECTORIES`] exists to prevent.
pub const RELATIVE_PATH_WILDCARD: &str = "*";

/// The largest number of directories one rule may expand to.
///
/// A wildcard enumerates a directory the rule author never saw. The bound keeps
/// a pathological tree (or a rule pointed at one) from turning a scan into an
/// unbounded enumeration; a rule that exceeds it contributes nothing rather than
/// a partial, unpredictable set.
pub const MAX_RULE_ROOTS: usize = 4096;

/// True when a `relativePath` uses only the wildcard this build understands.
pub fn relative_path_glob_is_valid(path: &str) -> bool {
    let components: Vec<&str> = path
        .split('/')
        .filter(|component| !component.is_empty())
        .collect();
    if components.is_empty() {
        return true;
    }
    if components[0] == RELATIVE_PATH_WILDCARD {
        return false;
    }
    components
        .iter()
        .all(|component| !component.contains('*') || *component == RELATIVE_PATH_WILDCARD)
}

/// True when a `directoriesNamed` rule's name set can match a directory.
///
/// One or more names, each a single path component: no separator, no wildcard.
/// An empty set matches nothing and a set carrying `/` or `*` is a path the
/// author meant to put in `relativePath`, so both are refused where the file is
/// read rather than silently finding nothing.
pub fn directory_name_set_is_valid(names: &[String]) -> bool {
    !names.is_empty()
        && names.iter().all(|name| {
            !name.is_empty()
                && !name.contains('/')
                && !name.contains('*')
                && name != "."
                && name != ".."
        })
}

/// True when a relative path names at least one wildcard component.
pub fn relative_path_has_wildcard(path: &str) -> bool {
    path.split('/')
        .any(|component| component == RELATIVE_PATH_WILDCARD)
}

/// Suffixes a directory name keeps on top of the application it belongs to.
///
/// `~/Library/Saved Application State/com.apple.Safari.savedState` is Safari's
/// state, not the state of an application called `com.apple.Safari.savedState`.
/// The suffix is part of the *name*, and on a case-insensitive volume it may
/// come back in any case, which is why the comparison lower-cases both sides.
/// The list is short on purpose: a suffix that only sometimes appears is worse
/// than none, because it makes the answer depend on how the application was
/// written rather than on which application it is.
pub const APP_OWNED_NAME_SUFFIXES: &[&str] = &[".savedstate", ".savedapplicationstate"];

/// True when any of `tokens` names `path`, judging by the path's components.
///
/// `tokens` are the aliases of the applications that are running right now: the
/// bundle identifiers, the identifiers without their team prefix, the names the
/// Finder shows, and the executable names. The caller collects them because Rust
/// has no `NSWorkspace`; the Swift engine is handed exactly the same list, so the
/// two engines downgrade exactly the same items.
///
/// Two comparisons, and the difference matters:
///
///  * **equality**, case-folded, against every component of the path — a bundle
///    identifier names the directory it owns (`~/.Trash` aside, macOS names a
///    cache directory after the application that writes it);
///  * **prefix**, for aliases that contain a dot, so `com.apple.Safari` also
///    claims `com.apple.Safari.SafeBrowsing`. An alias without a dot is an
///    application name, and `Firefox` must not claim `Firefox Developer Edition`.
///
/// A component is compared twice when it carries one of
/// [`APP_OWNED_NAME_SUFFIXES`]. Every component is compared, not just the last
/// one, because the shape of the item differs by rule: the wildcard component in
/// `Containers/*/Data/Library/Caches` is the owner, the last component in
/// `Caches/<bundle-id>` is, and the rule has no way to say which. Matching too
/// much costs a `safe` item its pre-selection; matching too little moves a
/// directory out from under a running application.
pub fn running_app_owns_path(path: &str, tokens: &[String]) -> bool {
    let aliases: Vec<String> = tokens
        .iter()
        .map(|token| token.trim().to_lowercase())
        .filter(|token| !token.is_empty())
        .collect();
    if aliases.is_empty() {
        return false;
    }

    path.split('/')
        .filter(|component| !component.is_empty())
        .any(|component| {
            let name = component.to_lowercase();
            let trimmed = APP_OWNED_NAME_SUFFIXES
                .iter()
                .find_map(|suffix| name.strip_suffix(suffix));
            let owned = |candidate: &str| {
                aliases.iter().any(|alias| {
                    candidate == alias
                        || (alias.contains('.') && candidate.starts_with(&format!("{alias}.")))
                })
            };
            owned(&name) || trimmed.is_some_and(owned)
        })
}

/// Paths that are never scanned or cleaned, matched as `~/<child>` prefixes of
/// the user's home directory. Compiled in: a rule file cannot remove them.
pub const PROTECTED_HOME_CHILDREN: &[&str] = &[
    "Documents",
    "Desktop",
    "Movies",
    "Music",
    "Pictures",
    "Projects",
    "Developer",
    "Public",
];

/// Absolute path prefixes that are never scanned or cleaned.
pub const PROTECTED_PREFIXES: &[&str] = &[
    "/System",
    "/bin",
    "/sbin",
    "/usr",
    "/etc",
    "/private/etc",
    "/private/var/db",
    "/private/var/vm",
    "/Library/Apple",
    "/Library/Extensions",
    "/Library/LaunchDaemons",
    "/Library/LaunchAgents",
    "/Library/StagedExtensions",
    "/Volumes",
];

/// `~/Library` children that hold secrets or the user's own data.
///
/// Listed rather than inferred because the names here look like ordinary
/// application state, and a miss is a privacy failure rather than a bad result.
pub const PROTECTED_LIBRARY_CHILDREN: &[&str] = &[
    "Library/Keychains",
    "Library/Mobile Documents",
    "Library/Accounts",
    "Library/Messages",
    "Library/Mail",
    "Library/Safari",
    "Library/Cookies",
];

/// The [`PROTECTED_LIBRARY_CHILDREN`] that hold user data rather than
/// credentials, reported as user content through the FFI.
pub const PROTECTED_LIBRARY_USER_CONTENT: &[&str] = &["Library/Mobile Documents"];

/// Suffix of a photo library package, protected as one unit.
pub const PROTECTED_PHOTOS_LIBRARY_SUFFIX: &str = ".photoslibrary";

/// Directory names that mark a recycle bin, at any depth below any root.
///
/// Every removal this product performs moves an item *to* the Trash, and the
/// undo it promises is the user emptying that Trash later. Offering the Trash
/// itself turns that promise inside out: the item is moved into the bin it was
/// already in, and the next empty makes the "undo" unrecoverable. `~/.Trash` is
/// the usual spelling; a volume keeps `.Trashes` at its root, and a trash
/// folder can also appear in a path the user selected by hand.
///
/// Matched as a whole component rather than as a prefix, because the two names
/// are siblings and a directory called `.Trash-notes` is an ordinary folder.
/// The comparison folds case for the same reason the rest of this list does.
pub const PROTECTED_RECYCLE_BIN_NAMES: &[&str] = &[".Trash", ".Trashes"];

/// The directory aliases macOS ships as symlinks.
///
/// `/var` is a symlink to `/private/var`, `/tmp` to `/private/tmp` and `/etc` to
/// `/private/etc`, so the same directory can arrive under either spelling. The
/// protection list names `/private/etc` and `/private/var/db`, and a path handed
/// to [`normalize_path`] as `/var/db` has to match them: without this table the
/// two engines disagree about a path that is protected by construction.
///
/// These two arrays are one table read index for index, and
/// `Scripts/generate-protection.py` renders them into the Swift file the Swift
/// rule engine reads, so neither language carries a private copy that can drift.
pub const SYMLINK_ALIASES: &[&str] = &["/var", "/tmp", "/etc"];

/// Where each [`SYMLINK_ALIASES`] entry points, index for index.
pub const SYMLINK_ALIAS_TARGETS: &[&str] = &["/private/var", "/private/tmp", "/private/etc"];

/// macOS package directories treated as one unit; never expanded file by file.
pub const DEFAULT_PACKAGE_EXTENSIONS: &[&str] = &[
    "app",
    "appex",
    "bundle",
    "framework",
    "kext",
    "mpkg",
    "photoslibrary",
    "pkg",
    "plugin",
    "prefpane",
    "qlgenerator",
    "xcodeproj",
    "xcworkspace",
];

/// Errors produced while loading a rule set.
#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum RuleError {
    #[error("rule set JSON could not be parsed: {0}")]
    Parse(String),
    #[error("unsupported rule schema version {found}, this build understands {expected}")]
    UnsupportedVersion { found: u32, expected: u32 },
    #[error("rule `{0}` has an empty id")]
    EmptyRuleID(String),
    #[error("duplicate rule id `{0}`")]
    DuplicateRuleID(String),
    #[error("rule `{id}` has a relativePath that leaves its anchor: {path}")]
    EscapingRelativePath { id: String, path: String },
    #[error("rule `{id}` states minAgeDays {days}, this build accepts 0...{max}")]
    MinAgeOutOfRange { id: String, days: u32, max: u32 },
    #[error("rule `{id}` targets `{path}`, which holds the data of every application")]
    ForbiddenRuleDirectory { id: String, path: String },
    #[error("rule `{id}` matches any file without an age threshold")]
    AnyFileWithoutMinAge { id: String },
    #[error("rule `{id}` has a relativePath wildcard this build does not understand: {path}")]
    UnsupportedRelativePathWildcard { id: String, path: String },
    #[error("rule `{id}` is `directoriesNamed` without a usable name")]
    DirectoriesNamedWithoutNames { id: String },
}

impl RuleSet {
    /// Parses a rule set, rejecting unknown schema versions and duplicate ids.
    ///
    /// The rules are *additive*: callers merge them with [`default_rules`], and
    /// [`is_protected_path`] still has the final say on every candidate path.
    pub fn from_json(json: &str) -> Result<Self, RuleError> {
        let parsed: RuleSet =
            serde_json::from_str(json).map_err(|e| RuleError::Parse(e.to_string()))?;
        if parsed.schema_version != RULE_SCHEMA_VERSION {
            return Err(RuleError::UnsupportedVersion {
                found: parsed.schema_version,
                expected: RULE_SCHEMA_VERSION,
            });
        }
        let mut seen = std::collections::HashSet::new();
        for rule in &parsed.rules {
            if rule.id.trim().is_empty() {
                return Err(RuleError::EmptyRuleID(rule.id.clone()));
            }
            if !seen.insert(rule.id.clone()) {
                return Err(RuleError::DuplicateRuleID(rule.id.clone()));
            }
            if !relative_path_stays_inside_anchor(&rule.relative_path) {
                return Err(RuleError::EscapingRelativePath {
                    id: rule.id.clone(),
                    path: rule.relative_path.clone(),
                });
            }
            // The three checks below are what keeps a rule file from describing
            // a rule the shipped table is not allowed to hold. They are refused
            // here, where the user sees the reason, rather than dropped later,
            // where a rule would silently stop applying.
            if let Some(days) = rule.min_age_days {
                if days > MAX_RULE_MIN_AGE_DAYS {
                    return Err(RuleError::MinAgeOutOfRange {
                        id: rule.id.clone(),
                        days,
                        max: MAX_RULE_MIN_AGE_DAYS,
                    });
                }
            }
            if let Some(forbidden) = forbidden_rule_directory(&rule.relative_path, rule.match_spec)
            {
                return Err(RuleError::ForbiddenRuleDirectory {
                    id: rule.id.clone(),
                    path: forbidden.to_string(),
                });
            }
            if !relative_path_glob_is_valid(&rule.relative_path) {
                return Err(RuleError::UnsupportedRelativePathWildcard {
                    id: rule.id.clone(),
                    path: rule.relative_path.clone(),
                });
            }
            // A `directoriesNamed` rule with no name matches nothing, and a name
            // carrying a separator or a wildcard is a path the author meant to
            // write into `relativePath`: both are typos that would otherwise
            // read as "the rule found nothing today".
            if rule.match_spec == Some(MatchSpecName::DirectoriesNamed)
                && !directory_name_set_is_valid(&rule.names)
            {
                return Err(RuleError::DirectoriesNamedWithoutNames {
                    id: rule.id.clone(),
                });
            }
            if rule.effective_match_spec() == MatchSpec::AnyFile && rule.min_age_days.is_none() {
                // `anyFile` with no age is "every file under this root": no
                // install of this product has a place where that is safe.
                return Err(RuleError::AnyFileWithoutMinAge {
                    id: rule.id.clone(),
                });
            }
        }
        Ok(parsed)
    }

    /// Merges another rule set on top of this one. Rules with an id that already
    /// exists are replaced so that a newer rule file can retune a shipped rule.
    pub fn merge(self, overlay: RuleSet) -> RuleSet {
        let mut rules = self.rules;
        for new_rule in overlay.rules {
            match rules.iter_mut().find(|r| r.id == new_rule.id) {
                Some(existing) => *existing = new_rule,
                None => rules.push(new_rule),
            }
        }
        RuleSet {
            schema_version: RULE_SCHEMA_VERSION,
            rules: rules
                .into_iter()
                .filter(|r| r.enabled && r.risk != Risk::Protected)
                .collect(),
        }
    }
}

/// The ids this build ships.
///
/// Used to decide which rules a release reviewed: a rule whose id is not in
/// this set came from a user rule file.
pub fn shipped_rule_ids() -> std::collections::HashSet<String> {
    default_rules().into_iter().map(|rule| rule.id).collect()
}

/// Applies the invariants every merged rule table must satisfy.
///
/// [`RuleSet::from_json`] already refuses a document that names a forbidden
/// directory, pairs `anyFile` with no age, or states an out-of-range age, so
/// this is the second line rather than the only one: it also covers the
/// built-in table and a table assembled in code rather than read from a file.
///
/// The clamp is the part that needs to know what this build ships. `safe` is
/// the level that arrives pre-selected, and only a rule a release reviewed
/// earns it: a rule the user added is offered at `review`, which still lets it
/// find things and leaves the decision with the user. A rule that *replaces* a
/// shipped id keeps its level — retuning a reviewed rule is what an overlay is
/// for, and refusing the level there would make the overlay useless.
pub fn enforce_rule_invariants(
    rules: Vec<Rule>,
    shipped_ids: &std::collections::HashSet<String>,
) -> Vec<Rule> {
    rules
        .into_iter()
        .filter_map(|mut rule| {
            if forbidden_rule_directory(&rule.relative_path, rule.match_spec).is_some() {
                return None;
            }
            if !relative_path_glob_is_valid(&rule.relative_path) {
                return None;
            }
            if rule.match_spec == Some(MatchSpecName::DirectoriesNamed)
                && !directory_name_set_is_valid(&rule.names)
            {
                return None;
            }
            if rule.effective_match_spec() == MatchSpec::AnyFile && rule.min_age_days.is_none() {
                return None;
            }
            if rule.risk == Risk::Safe && !shipped_ids.contains(&rule.id) {
                rule.risk = Risk::Review;
            }
            Some(rule)
        })
        .collect()
}

/// A rule, with the localisation key of the sentence the user reads.
///
/// The key is a required argument rather than derived from the id. A derived key
/// (`cleanup.<id>.explanation`) reads well and resolves to nothing: no rule id is
/// a string the catalog knows, so every item fell back to its category's generic
/// sentence and the per-rule explanation never reached the user. Naming the key
/// here also makes it visible to `Scripts/check-explanation-keys.py`, which
/// refuses a key the catalog does not carry.
///
/// An explanation an *item* carries is rendered with no arguments, so these keys
/// must have no `%` placeholder; the sentences that take a number stay on the
/// category-level keys the pages format for themselves.
fn rule(
    id: &str,
    category: Category,
    risk: Risk,
    root: RootAnchor,
    rel: &str,
    explanation_key: &str,
) -> Rule {
    Rule {
        id: id.to_string(),
        category,
        risk,
        root,
        relative_path: rel.to_string(),
        match_spec: None,
        extensions: Vec::new(),
        names: Vec::new(),
        excludes: Vec::new(),
        min_age_days: None,
        uses_stale_threshold: false,
        package_extensions: Vec::new(),
        requires_full_disk_access: false,
        needs_app_closed: false,
        explanation_key: explanation_key.to_string(),
        enabled: true,
    }
}

fn with_spec(mut r: Rule, spec: MatchSpec) -> Rule {
    match spec {
        MatchSpec::Directory => r.match_spec = Some(MatchSpecName::Directory),
        MatchSpec::ChildDirectories => r.match_spec = Some(MatchSpecName::ChildDirectories),
        MatchSpec::AnyFile => r.match_spec = Some(MatchSpecName::AnyFile),
        MatchSpec::FilesByExtension { extensions } => {
            r.match_spec = Some(MatchSpecName::FilesByExtension);
            r.extensions = extensions;
        }
        MatchSpec::DirectoriesNamed { names } => {
            r.match_spec = Some(MatchSpecName::DirectoriesNamed);
            r.names = names;
        }
    }
    r
}

/// Marks a rule that matches child directories by name.
fn with_names(mut r: Rule, names: &[&str]) -> Rule {
    r.match_spec = Some(MatchSpecName::DirectoriesNamed);
    r.names = names.iter().map(|name| (*name).to_string()).collect();
    r
}

fn with_excludes(mut r: Rule, excludes: &[&str]) -> Rule {
    r.excludes = excludes.iter().map(|s| (*s).to_string()).collect();
    r
}

fn with_min_age(mut r: Rule, days: u32) -> Rule {
    r.min_age_days = Some(days);
    r
}

/// Marks a rule whose age the user's stale threshold governs.
fn following_stale_threshold(mut r: Rule) -> Rule {
    r.uses_stale_threshold = true;
    r
}

fn with_fda(mut r: Rule) -> Rule {
    r.requires_full_disk_access = true;
    r
}

/// Marks a rule whose items one application owns, so a scan checks whether that
/// application is running before it calls an item `safe`.
fn needing_app_closed(mut r: Rule) -> Rule {
    r.needs_app_closed = true;
    r
}

/// The v0.1 built-in rule table. Everything the scanner recognises is listed
/// here explicitly; there is no heuristic "looks like a cache" fallback.
///
/// The list is built by pushing, one named block per category: writing it as a
/// single literal would lose the per-category documentation.
///
/// This table is the only source for the shipped rule document and for the Swift
/// fallback table: `Scripts/generate-rules.py` renders `Core/Resources/CleaningRules.json`
/// and `Core/Rules/BuiltInRules.swift` from it, and `Scripts/verify.sh` fails when
/// either is stale. A rule added here therefore reaches both engines, and a rule
/// that must not be offered to the user cannot exist in only one of them.
///
/// Two things are deliberately **not** rules, because a rule can only match a name
/// shape or an age and both would offer data that belongs to an installed
/// application:
///
/// 1. **Residue.** `~/Library/Application Support/<bundle-id>` and its siblings are
///    found by [`scan_application_residue`], which requires the name to be the
///    bundle identifier of an application that is *not* installed. Rules named
///    `app-residue-*` used to sit here as ordinary child-directory rules, so every
///    directory under `Application Support` — including the live data of installed
///    applications — was offered as "application residue", which is the exact
///    guess the uninstaller's own documentation refuses to make.
/// 2. **Containers as a whole.** Every sandboxed application keeps its state in one
///    directory under `~/Library/Containers`, and applications that share state use
///    one under `~/Library/Group Containers`. A rule over either directory made one
///    cleanup item out of *every* application's data. The orphaned ones are reported
///    by the residue scanner (application gone, container left behind); a live one
///    belongs to the uninstaller, which shows it next to the application it came
///    from and only when the user asked to remove that application.
///
/// [`scan_application_residue`]: ../../sift_scanner_core/scanners/fn.scan_application_residue.html
#[allow(clippy::vec_init_then_push)]
pub fn default_rules() -> Vec<Rule> {
    use Category::*;
    use Risk::*;
    use RootAnchor::*;

    let mut rules = Vec::new();

    // --- Application caches ------------------------------------------------
    rules.push(with_spec(
        with_excludes(
            needing_app_closed(rule(
                "user-cache",
                ApplicationCache,
                Safe,
                HomeLibrary,
                "Caches",
                "cleanup.explanation.cache",
            )),
            // CloudKit and container caches hold state that is expensive to
            // rebuild or that belongs to a sandboxed app's data directory.
            &[
                "CloudKit",
                "com.apple.bird",
                "com.apple.iCloud",
                "FamilyCircle",
            ],
        ),
        MatchSpec::ChildDirectories,
    ));

    // --- Application caches inside an application's own data ---------------
    //
    // A sandboxed application keeps its cache inside its container, one level
    // below a name the platform generated rather than one this rule can know.
    // `*` is what makes that expressible without a rule per bundle identifier;
    // see `RELATIVE_PATH_WILDCARD`. The container itself stays off limits
    // (`FORBIDDEN_RULE_DIRECTORIES`), so what is offered is the cache directory
    // one level deeper, never the application's data as a whole.
    //
    // `com.apple` is excluded: macOS keeps one container per system application,
    // and there are hundreds of them holding a few kilobytes each, so offering
    // them buries the two dozen third-party caches that actually carry weight.
    // A rule file can override this id without the exclusion if a user wants
    // them; the overlay replaces the rule rather than adding to it.
    rules.push(with_spec(
        with_excludes(
            needing_app_closed(rule(
                "container-caches",
                ApplicationCache,
                Safe,
                HomeLibrary,
                "Containers/*/Data/Library/Caches",
                "cleanup.explanation.cache",
            )),
            &["com.apple"],
        ),
        MatchSpec::Directory,
    ));

    // `~/Library/Application Support/<app>/<name>` is named by the application,
    // not by the platform, so the same name can hold a cache in one application
    // and state the application cannot rebuild in another. The entries are
    // offered at `review` for that reason.
    //
    // The names are the ones the frameworks actually use: `Cache` and `Caches`
    // are the obvious pair, `GPUCache` and `Code Cache` are Chromium's. The set
    // is part of the rule so a new spelling is a new entry here rather than a new
    // rule that has to repeat the wildcard, the category and the explanation.
    rules.push(with_names(
        needing_app_closed(rule(
            "app-support-caches",
            ApplicationCache,
            Review,
            HomeLibrary,
            "Application Support/*",
            "cleanup.explanation.cache",
        )),
        &["Cache", "Caches", "GPUCache", "Code Cache"],
    ));

    // Chromium is not one application: it is a framework, and every browser
    // built on it (Chrome, Edge, Brave, Electron applications) keeps its profile
    // one level deeper than the vendor and product names — `Google/Chrome/<profile>`
    // — so `app-support-caches` above cannot see its cache directories. This rule
    // is the same idea with one more wildcard: the *names* still decide, and the
    // three levels above them are whatever the vendor wrote.
    //
    // `Service Worker` is the large one in practice (a cached copy of every web
    // app the profile has visited); `Cache` and `Caches` are the HTTP caches the
    // older Chromium builds kept here rather than in `~/Library/Caches`.
    rules.push(with_names(
        needing_app_closed(rule(
            "chromium-profile-caches",
            ApplicationCache,
            Review,
            HomeLibrary,
            "Application Support/*/*/*",
            "cleanup.explanation.cache",
        )),
        &[
            "Cache",
            "Caches",
            "Code Cache",
            "GPUCache",
            "Service Worker",
            "DawnGraphiteCache",
            "DawnWebGPUCache",
            "GrShaderCache",
        ],
    ));

    // --- Xcode build artifacts ---------------------------------------------
    //
    // `DerivedData` and `iOS DeviceSupport` are regenerated by Xcode on the next
    // build or device connection. `~/Library/Developer/Xcode/Archives` is
    // deliberately absent: an archive is the only copy of a build that was
    // shipped, and no rule can tell one that matters from one that does not.
    rules.push(with_spec(
        rule(
            "xcode-derived-data",
            TemporaryFiles,
            Safe,
            HomeLibrary,
            "Developer/Xcode/DerivedData",
            "cleanup.explanation.temporary",
        ),
        MatchSpec::Directory,
    ));
    rules.push(with_spec(
        rule(
            "xcode-device-support",
            TemporaryFiles,
            Safe,
            HomeLibrary,
            "Developer/Xcode/iOS DeviceSupport",
            "cleanup.explanation.temporary",
        ),
        MatchSpec::ChildDirectories,
    ));
    rules.push(with_spec(
        rule(
            "xcode-simulator-caches",
            TemporaryFiles,
            Safe,
            HomeLibrary,
            "Developer/CoreSimulator/Caches",
            "cleanup.explanation.temporary",
        ),
        MatchSpec::Directory,
    ));

    // --- Logs --------------------------------------------------------------
    //
    // The rule still matches each application's log directory, but the scanner
    // only offers one whose every file is stale. A directory is moved as a
    // whole, so a mixed directory would take fresh logs the threshold did not
    // count. DiagnosticReports is left to its own rule below.
    rules.push(following_stale_threshold(with_min_age(
        with_excludes(
            with_spec(
                rule(
                    "user-logs",
                    Logs,
                    Safe,
                    HomeLibrary,
                    "Logs",
                    "cleanup.explanation.logsItem",
                ),
                MatchSpec::ChildDirectories,
            ),
            &["DiagnosticReports"],
        ),
        30,
    )));
    rules.push(following_stale_threshold(with_min_age(
        with_spec(
            rule(
                "user-diagnostic-reports",
                Logs,
                Review,
                HomeLibrary,
                "Logs/DiagnosticReports",
                "cleanup.explanation.logsItem",
            ),
            MatchSpec::AnyFile,
        ),
        30,
    )));
    rules.push(with_fda(following_stale_threshold(with_min_age(
        with_spec(
            rule(
                "system-logs",
                Logs,
                Review,
                SystemLibrary,
                "Logs",
                "cleanup.explanation.systemLogsItem",
            ),
            MatchSpec::ChildDirectories,
        ),
        30,
    ))));

    // --- Installers --------------------------------------------------------
    rules.push(following_stale_threshold(with_min_age(
        with_spec(
            rule(
                "download-installers",
                Installers,
                Review,
                Home,
                "Downloads",
                "cleanup.explanation.installers",
            ),
            MatchSpec::FilesByExtension {
                extensions: vec![
                    "dmg".into(),
                    "pkg".into(),
                    "mpkg".into(),
                    "xip".into(),
                    "iso".into(),
                ],
            },
        ),
        30,
    )));
    rules.push(with_min_age(
        with_spec(
            rule(
                "download-archives",
                Installers,
                Review,
                Home,
                "Downloads",
                "cleanup.explanation.installers",
            ),
            MatchSpec::FilesByExtension {
                extensions: vec!["zip".into(), "tar".into(), "gz".into(), "tgz".into()],
            },
        ),
        90,
    ));

    // --- The per-user temporary root ---------------------------------------
    //
    // macOS gives every login session a private `/var/folders/<xx>/<hash>`,
    // holding `T` (the temporary directory) and `C` (the per-user cache
    // directory). Everything in `C` is reusable by definition: it is where the
    // platform puts what an application may throw away (compiled shaders, the
    // launch-services store, per-session conversion caches), and it survives
    // logout, so on a Mac that has been up for months it is real space.
    //
    // `T` is deliberately **not** a rule. Live processes keep their sockets and
    // mach ports there (`T/com.apple.launchd.*`), and a rule can only look at a
    // name or an age; offering `T` would hand the user a directory whose
    // removal breaks a running process. `T` is left to macOS, which clears it
    // when the session ends.
    //
    // The age threshold is what makes this safe without knowing what is inside:
    // a directory whose files have all been untouched for a week is not being
    // written by anything. `review`, because the user should see what is being
    // offered — the names are internal to the platform, not application names.
    rules.push(with_min_age(
        with_spec(
            rule(
                "user-temp-caches",
                TemporaryFiles,
                Review,
                UserTemp,
                "C",
                "cleanup.explanation.temporary",
            ),
            MatchSpec::ChildDirectories,
        ),
        7,
    ));

    // --- Developer caches ---------------------------------------------------
    //
    // The toolchains that build software keep their own caches outside
    // `~/Library/Caches`: each of these directories is documented by its tool as
    // safe to delete and rebuilt on the next run. They sit under a dot-directory
    // in the home folder, which is why the table had none of them — a rule could
    // not say it, and the "hidden files" setting decides what a scan may see.
    //
    // `review` throughout, with an age threshold: a cache that has not been read
    // in a month is not in use, and the user is asked before a build has to
    // re-download the internet. The exceptions are logs, which are `safe`.
    rules.push(with_spec(
        with_min_age(
            rule(
                "user-xdg-cache",
                ApplicationCache,
                Review,
                Home,
                ".cache",
                "cleanup.explanation.cache",
            ),
            30,
        ),
        MatchSpec::ChildDirectories,
    ));
    rules.push(with_spec(
        with_min_age(
            rule(
                "user-gradle-caches",
                ApplicationCache,
                Review,
                Home,
                ".gradle/caches",
                "cleanup.explanation.cache",
            ),
            30,
        ),
        // One item per cache family (`modules-2`, the version directory) rather
        // than one for the whole tree: Gradle rewrites the journal on every run,
        // and a single fresh file inside would hide a gigabyte of dependencies
        // that no build has read since.
        MatchSpec::ChildDirectories,
    ));
    rules.push(with_spec(
        with_min_age(
            rule(
                "user-cargo-cache",
                ApplicationCache,
                Review,
                Home,
                ".cargo/registry/cache",
                "cleanup.explanation.cache",
            ),
            30,
        ),
        MatchSpec::Directory,
    ));
    rules.push(with_spec(
        with_min_age(
            rule(
                "user-npm-cache",
                ApplicationCache,
                Review,
                Home,
                ".npm/_cacache",
                "cleanup.explanation.cache",
            ),
            30,
        ),
        MatchSpec::Directory,
    ));
    rules.push(with_spec(
        with_min_age(
            rule(
                "android-device-cache",
                ApplicationCache,
                Review,
                Home,
                ".android/cache",
                "cleanup.explanation.cache",
            ),
            30,
        ),
        MatchSpec::Directory,
    ));
    // Gradle's daemon logs are one file per build daemon, kept until the daemon
    // is killed; `anyFile` with an age so a build running right now is not
    // offered its own log.
    rules.push(with_spec(
        with_min_age(
            rule(
                "build-tool-logs",
                Logs,
                Safe,
                Home,
                ".gradle/daemon",
                "cleanup.explanation.logsItem",
            ),
            7,
        ),
        MatchSpec::AnyFile,
    ));
    // The Android SDK is installed software, not junk: `emulator` and
    // `platform-tools` are running binaries, and `avd` (next to it) is the user's
    // own virtual devices, which no rule touches. What *is* reclaimable is a
    // component nobody has read in a quarter — an NDK or build-tools version a
    // project stopped pinning. The names are the components that exist per
    // version, so the age test means "no file in this component was touched",
    // and the download is repeatable through `sdkmanager`.
    //
    // 90 days rather than six months, and the number came from
    // `Scripts/audit-coverage.py --age-sweep 7,30,90,180`: on a machine where
    // Android was last built in August, the components split 8 items / 6.6 GB at
    // a week, 4 / 2.0 GB at 90 days and nothing at all at 180. Six months found
    // none of it, which is the same as having no rule; a quarter offers the two
    // gigabytes that no build has read since, at `review`, unselected.
    rules.push(with_names(
        with_min_age(
            rule(
                "android-sdk-idle-components",
                TemporaryFiles,
                Review,
                HomeLibrary,
                "Android/sdk",
                "cleanup.explanation.temporary",
            ),
            90,
        ),
        &[
            "ndk",
            "build-tools",
            "platforms",
            "system-images",
            "cmake",
            "sources",
            "skins",
            "cmdline-tools",
        ],
    ));

    // --- Temporary files ---------------------------------------------------
    //
    // There is deliberately no rule over `Application Support`: it holds the
    // live data of installed applications (and this app's own data), and a
    // rule can only match a name shape or an age. Saved window state is
    // rebuildable and remains the one shipped temporary-files rule.
    rules.push(with_spec(
        needing_app_closed(rule(
            "user-saved-state",
            TemporaryFiles,
            Safe,
            HomeLibrary,
            "Saved Application State",
            "cleanup.explanation.savedState",
        )),
        MatchSpec::ChildDirectories,
    ));

    rules
}

/// The built-in rule table as the document the app ships.
///
/// One function decides the serialisation, so the file a reviewer reads
/// (`Core/Resources/CleaningRules.json`), the fallback table the Swift engine
/// keeps and the JSON the FFI hands to Swift are the same document rather than
/// three transcriptions of one table.
///
/// `Scripts/generate-rules.py` writes both artifacts from this; run it after
/// changing the table, and `Scripts/verify.sh` fails when a checked-in copy is
/// stale.
pub fn shipped_rules_json() -> String {
    let document = RuleSet {
        schema_version: RULE_SCHEMA_VERSION,
        rules: default_rules(),
    };
    let mut json =
        serde_json::to_string_pretty(&document).expect("the built-in rule table serialises");
    json.push('\n');
    json
}

/// Normalises a path for prefix comparison: no trailing slash, no `.`/`..`
/// segments, and no alias macOS ships as a symlink. The input must already be
/// absolute.
///
/// The alias step is what makes the same directory comparable however it is
/// spelled: `/var/db/secret` and `/private/var/db/secret` are one location, and
/// the protection list writes the `/private` spelling. A caller that skipped the
/// mapping would let a path through that the Swift engine refuses.
pub fn normalize_path(path: &str) -> String {
    let collapsed = collapse_segments(path);
    // The mapping is its own inverse-free, one step: every target is a real
    // directory, so a second pass would find nothing.
    for (alias, target) in SYMLINK_ALIASES.iter().zip(SYMLINK_ALIAS_TARGETS) {
        if collapsed == *alias {
            return (*target).to_string();
        }
        if let Some(rest) = collapsed.strip_prefix(&format!("{alias}/")) {
            return format!("{target}/{rest}");
        }
    }
    collapsed
}

/// Collapses `.`, `..` and duplicate separators, without touching the disk and
/// without the alias mapping.
///
/// Separate from [`normalize_path`], which also rewrites `/var` to
/// `/private/var`. That mapping is right for a protection comparison and wrong
/// for a scan root: it would rewrite a root under `/var/folders` into its
/// `/private` spelling, and the root would then no longer match the request that
/// authorised it.
pub fn collapse_path(path: &str) -> String {
    collapse_segments(path)
}

/// Collapses `.`, `..` and duplicate separators, without touching the disk.
fn collapse_segments(path: &str) -> String {
    let mut parts: Vec<&str> = Vec::new();
    for segment in path.split('/') {
        match segment {
            "" | "." => continue,
            ".." => {
                parts.pop();
            }
            other => parts.push(other),
        }
    }
    let mut out = String::with_capacity(path.len());
    for part in &parts {
        out.push('/');
        out.push_str(part);
    }
    if out.is_empty() {
        out.push('/');
    }
    out
}

/// True when a rule's `relativePath` only ever descends from its anchor.
///
/// Two shapes have to be refused, and both arrive as an ordinary-looking string:
/// an absolute path, because `Path::join` *replaces* the base rather than
/// extending it, and a `..` component, because `/Users/alice/Library/../../Shared`
/// is still spelled as though it sits under the home directory while the file
/// system resolves it to `/Users/Shared`. The check is per component, so a
/// directory genuinely named `..notes` is still allowed.
pub fn relative_path_stays_inside_anchor(path: &str) -> bool {
    // The raw-segment pass is not redundant: `Path::components()` normalises an
    // interior `.` away, so `Logs/./x` would look like `Logs/x` here while the
    // Swift decoder refuses it outright. Both engines have to accept the same
    // documents — a file one accepts and the other refuses fails the whole scan
    // with `invalidRequest`, and nothing in that error points at the rule file.
    path.split('/')
        .all(|segment| segment != "." && segment != "..")
        && Path::new(path)
            .components()
            .all(|c| matches!(c, Component::Normal(_)))
}

/// True when `path` is `prefix` or sits below it.
///
/// A whole-segment comparison, so `/Systematic` is not below `/System`. Both
/// sides are expected to be collapsed already.
pub fn is_prefix_of(prefix: &str, path: &str) -> bool {
    let prefix = prefix.trim_end_matches('/');
    if prefix.is_empty() {
        return false;
    }
    path == prefix || path.starts_with(&format!("{prefix}/"))
}

/// The protection list's comparison: case-folded, because macOS volumes are
/// case-insensitive by default.
///
/// The protection names are literals (`Documents`, `Library/Keychains`), while
/// the filesystem resolves `~/documents` and `~/library/keychains` to the same
/// directories. A byte-exact comparison therefore let a rule file (or any
/// caller that spelled the path differently) name a protected directory and
/// have both the scanner and the pre-flight check approve it. The fold is
/// applied only here: rule matching keeps `is_prefix_of`, so a case-sensitive
/// volume does not suddenly match a differently-cased sibling.
pub fn is_protected_prefix(prefix: &str, path: &str) -> bool {
    let prefix = prefix.trim_end_matches('/').to_lowercase();
    let path = path.to_lowercase();
    if prefix.is_empty() {
        return false;
    }
    path == prefix || path.starts_with(&format!("{prefix}/"))
}

/// Classifies a path that sits inside `~/Library`.
///
/// Secrets, private messages and synced documents live here under names that
/// look like ordinary application state, so they are listed rather than inferred.
fn protected_library_reason(home: &str, path: &str) -> Option<ProtectedReason> {
    for child in PROTECTED_LIBRARY_CHILDREN {
        if is_protected_prefix(&format!("{home}/{child}"), path) {
            return Some(if PROTECTED_LIBRARY_USER_CONTENT.contains(child) {
                ProtectedReason::UserContent {
                    child: (*child).to_string(),
                }
            } else {
                ProtectedReason::Secrets {
                    path: (*child).to_string(),
                }
            });
        }
    }
    // Case-insensitive on purpose: a package renamed to `.PhotosLibrary`
    // remains a photo library on a case-insensitive volume, and a protection
    // rule that only matched the canonical spelling could be sidestepped by a
    // rename. The Swift engine applies the same comparison.
    let lowered = path.to_ascii_lowercase();
    let suffix = PROTECTED_PHOTOS_LIBRARY_SUFFIX.to_ascii_lowercase();
    if lowered.ends_with(&suffix) || lowered.contains(&format!("{suffix}/")) {
        return Some(ProtectedReason::UserContent {
            child: "Photos Library".to_string(),
        });
    }
    None
}

/// Returns the reason a path inside a recycle bin is protected, or `None`.
///
/// Checked as a whole component at any depth, so `~/.Trash/x`, an item already
/// in `~/.Trash/` and `/Volumes/Backup/.Trashes/501/x` are all refused, while a
/// user folder that merely starts with the name is not.
fn recycle_bin_reason(path: &str) -> Option<ProtectedReason> {
    path.split('/').find_map(|component| {
        PROTECTED_RECYCLE_BIN_NAMES
            .iter()
            .any(|name| component.eq_ignore_ascii_case(name))
            .then(|| ProtectedReason::UserContent {
                child: component.to_string(),
            })
    })
}

/// Returns the reason a path is protected, or `None` when it is not.
///
/// This is the last line of defence: it runs on every candidate before it can
/// reach the UI, and again on the Swift side before any file operation.
pub fn protection_reason(home: &str, path: &str) -> Option<ProtectedReason> {
    let home = normalize_path(home);
    let path = normalize_path(path);

    for child in PROTECTED_HOME_CHILDREN {
        let candidate = format!("{home}/{child}");
        if is_protected_prefix(&candidate, &path) {
            return Some(ProtectedReason::UserContent {
                child: (*child).to_string(),
            });
        }
    }

    for prefix in PROTECTED_PREFIXES {
        if is_protected_prefix(prefix, &path) {
            return Some(ProtectedReason::SystemPath {
                prefix: (*prefix).to_string(),
            });
        }
    }

    if let Some(reason) = recycle_bin_reason(&path) {
        return Some(reason);
    }

    protected_library_reason(&home, &path)
}

/// Why a path may not be scanned or cleaned.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProtectedReason {
    /// The path is inside a user content directory (Documents, Desktop, ...).
    UserContent { child: String },
    /// The path is inside a system-managed prefix.
    SystemPath { prefix: String },
    /// The path holds secrets such as keychains.
    Secrets { path: String },
}

impl ProtectedReason {
    pub fn message(&self) -> String {
        match self {
            ProtectedReason::UserContent { child } => {
                format!("user content protected: {child}")
            }
            ProtectedReason::SystemPath { prefix } => {
                format!("system path protected: {prefix}")
            }
            ProtectedReason::Secrets { path } => format!("secrets protected: {path}"),
        }
    }

    /// Stable code reported to Swift for the `protectedLocation` error.
    pub const fn code(&self) -> &'static str {
        "protectedLocation"
    }
}

/// Convenience wrapper used by scanners.
pub fn is_protected_path(home: &str, path: &str) -> bool {
    protection_reason(home, path).is_some()
}

/// Classifies a path, honouring explicit authorisation.
///
/// Authorisation lifts only the blanket prefixes that exist to stop Sift
/// scanning a tree by default (`/Volumes`, `/private/var`). User content,
/// secrets and photo libraries stay protected: a grant for a folder cannot turn
/// a Documents directory into a cleanup target.
pub fn protection_reason_authorized(
    home: &str,
    path: &str,
    authorized_roots: &[std::path::PathBuf],
) -> Option<ProtectedReason> {
    let path_normalized = normalize_path(path);
    let home_normalized = normalize_path(home);

    // Hard rules first.
    for child in PROTECTED_HOME_CHILDREN {
        if is_protected_prefix(&format!("{home_normalized}/{child}"), &path_normalized) {
            return Some(ProtectedReason::UserContent {
                child: (*child).to_string(),
            });
        }
    }
    if let Some(reason) = protected_library_reason(&home_normalized, &path_normalized) {
        return Some(reason);
    }

    // Before the `/Volumes` grant is consulted: a grant opens a subtree the user
    // added, and the Trash inside it is exactly the place their undo lives.
    if let Some(reason) = recycle_bin_reason(&path_normalized) {
        return Some(reason);
    }

    // A grant lifts the blanket `/Volumes` guard for the authorised subtree only.
    // It never lifts a real system prefix: granting `/Library` or `/private/var`
    // would otherwise expose launch daemons and the system database.
    if is_protected_prefix("/Volumes", &path_normalized) {
        for root in authorized_roots {
            let root = normalize_path(&root.to_string_lossy());
            if is_protected_prefix(&root, &path_normalized) {
                return None;
            }
        }
        return Some(ProtectedReason::SystemPath {
            prefix: "/Volumes".to_string(),
        });
    }

    for prefix in PROTECTED_PREFIXES {
        if *prefix == "/Volumes" {
            continue;
        }
        if is_protected_prefix(prefix, &path_normalized) {
            return Some(ProtectedReason::SystemPath {
                prefix: (*prefix).to_string(),
            });
        }
    }

    None
}

/// True when the path is protected even with the user's grants applied.
pub fn is_protected_path_authorized(
    home: &str,
    path: &str,
    authorized_roots: &[std::path::PathBuf],
) -> bool {
    protection_reason_authorized(home, path, authorized_roots).is_some()
}

/// Returns true when the path is a macOS package directory that must be treated
/// as a single unit (`Cool.app`, `Photos.photoslibrary`).
pub fn is_package_directory(name: &str, extensions: &[String]) -> bool {
    match name.rsplit_once('.') {
        Some((_, ext)) => {
            let ext = ext.to_ascii_lowercase();
            extensions.iter().any(|e| e.eq_ignore_ascii_case(&ext))
                || DEFAULT_PACKAGE_EXTENSIONS.contains(&ext.as_str())
        }
        None => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const HOME: &str = "/Users/example";

    #[test]
    fn protected_home_children_are_rejected() {
        for child in PROTECTED_HOME_CHILDREN {
            let path = format!("{HOME}/{child}/report.pdf");
            assert!(is_protected_path(HOME, &path), "{path} should be protected");
        }
    }

    #[test]
    fn protected_home_directory_itself_is_rejected() {
        assert!(is_protected_path(HOME, &format!("{HOME}/Documents")));
    }

    #[test]
    fn similar_prefixes_are_not_treated_as_protected() {
        // `~/Documents-old` must not be swept up by the `~/Documents` rule.
        assert!(!is_protected_path(
            HOME,
            &format!("{HOME}/Documents-old/a.txt")
        ));
        // `/Systematic` is not `/System`.
        assert!(!is_protected_path(HOME, "/Systematic/a.txt"));
    }

    #[test]
    fn system_prefixes_are_rejected() {
        assert!(is_protected_path(HOME, "/System/Library/Caches"));
        assert!(is_protected_path(HOME, "/usr/local/bin/tool"));
        assert!(is_protected_path(HOME, "/Volumes/External/anything"));
    }

    #[test]
    fn caches_and_logs_are_allowed() {
        assert!(!is_protected_path(
            HOME,
            &format!("{HOME}/Library/Caches/com.foo")
        ));
        assert!(!is_protected_path(
            HOME,
            &format!("{HOME}/Library/Logs/foo.log")
        ));
        assert!(!is_protected_path(
            HOME,
            &format!("{HOME}/Downloads/thing.dmg")
        ));
    }

    #[test]
    fn path_traversal_is_normalised_before_comparison() {
        // `/Users/example/Downloads/../Documents/secret.txt` normalises into the
        // protected Documents directory.
        let sneaky = format!("{HOME}/Downloads/../Documents/secret.txt");
        assert!(is_protected_path(HOME, &sneaky));
        assert_eq!(
            normalize_path(&sneaky),
            format!("{HOME}/Documents/secret.txt")
        );
    }

    #[test]
    fn a_case_variant_cannot_reach_a_protected_location() {
        // macOS volumes are case-insensitive by default, so `~/documents` is the
        // user's Documents directory. A rule file (or any caller) that spells a
        // protected name in another case must still be refused, or the whole
        // protection list is one lower-case letter away from being bypassed.
        for path in [
            format!("{HOME}/documents/taxes.pdf"),
            format!("{HOME}/DESKTOP/notes.txt"),
            format!("{HOME}/library/keychains/login.keychain-db"),
            format!("{HOME}/library/mobile documents/com~apple~x/f"),
            format!("{HOME}/library/mail/inbox"),
            "/system/library/caches/x".to_string(),
            "/USR/local/bin/tool".to_string(),
            "/volumes/External/anything".to_string(),
            "/private/VAR/db/secret".to_string(),
        ] {
            assert!(
                is_protected_path(HOME, &path),
                "{path} must be refused despite its spelling"
            );
        }

        // A differently-cased sibling is still a different directory on a
        // case-sensitive volume, so the fold must not turn prefix matching into
        // a substring match.
        assert!(!is_protected_path(
            HOME,
            &format!("{HOME}/documents-old/a.txt")
        ));
        assert!(!is_protected_path(HOME, "/systematic/a.txt"));
    }

    #[test]
    fn a_case_variant_is_refused_under_an_authorised_grant_too() {
        use std::path::PathBuf;
        let grants = [PathBuf::from("/Volumes/Backup")];
        assert!(is_protected_path_authorized(
            HOME,
            &format!("{HOME}/LIBRARY/KEYCHAINS/login.keychain-db"),
            &grants
        ));
        assert!(
            !is_protected_path_authorized(HOME, "/volumes/Backup/file.bin", &grants),
            "the grant is the same volume however it is spelled"
        );
    }

    #[test]
    fn keychains_and_photos_library_are_protected() {
        assert!(is_protected_path(
            HOME,
            &format!("{HOME}/Library/Keychains/login.keychain-db")
        ));
        assert!(is_protected_path(
            HOME,
            &format!("{HOME}/Pictures/Photos Library.photoslibrary/db")
        ));
        // The suffix is a safety net, so a rename that only changes case must
        // not turn the library into an ordinary package.
        for spelling in ["Photos Library.PHOTOSLIBRARY", "Archive.PhotosLibrary"] {
            assert!(is_protected_path(
                HOME,
                &format!("{HOME}/Archive/{spelling}/db")
            ));
        }
        assert!(is_protected_path(
            HOME,
            &format!("{HOME}/Library/Mobile Documents/com~apple~x/f")
        ));
    }

    #[test]
    fn accounts_messages_mail_safari_and_cookies_are_protected() {
        // These hold the user's mail, messages and browsing history. They are
        // listed in `PROTECTED_LIBRARY_CHILDREN` and the Swift engine reads the
        // same list, so neither engine can walk a tree the other refuses.
        for child in PROTECTED_LIBRARY_CHILDREN {
            let path = format!("{HOME}/{child}/content");
            for reason in [protection_reason(HOME, &path), {
                let grants = [std::path::PathBuf::from("/Volumes/Backup")];
                protection_reason_authorized(HOME, &path, &grants)
            }] {
                assert!(reason.is_some(), "{path} must be protected");
            }
        }
    }

    #[test]
    fn application_state_in_the_library_is_still_allowed() {
        // The rule must not be so broad that it protects the library itself, or
        // every cache the product exists to clean would be refused.
        assert!(!is_protected_path(HOME, &format!("{HOME}/Library")));
        assert!(!is_protected_path(
            HOME,
            &format!("{HOME}/Library/Application Support/com.example.app")
        ));
        assert!(!is_protected_path(
            HOME,
            &format!("{HOME}/Library/Accounts-old/settings.json")
        ));
    }

    #[test]
    fn symlink_free_paths_with_special_characters_survive_normalisation() {
        let tricky = "/Users/example/Library/Caches/应用 缓存/v1.0 (beta)+test#1";
        assert_eq!(normalize_path(tricky), tricky);
        assert!(!is_protected_path(HOME, tricky));
    }

    #[test]
    fn the_symlink_alias_table_is_paired() {
        // Read index for index, so a mismatched pair would silently drop the
        // entries past the shorter array.
        assert_eq!(SYMLINK_ALIASES.len(), SYMLINK_ALIAS_TARGETS.len());
        for (alias, target) in SYMLINK_ALIASES.iter().zip(SYMLINK_ALIAS_TARGETS) {
            assert!(alias.starts_with('/'), "{alias} must be absolute");
            assert!(
                target.starts_with("/private/"),
                "{target} must be the real directory behind {alias}"
            );
        }
    }

    #[test]
    fn macos_symlink_aliases_normalise_to_their_targets() {
        // The same matrix the Swift engine asserts, so a path both engines see
        // receives the same answer.
        for (alias, target) in SYMLINK_ALIASES.iter().zip(SYMLINK_ALIAS_TARGETS) {
            assert_eq!(normalize_path(alias), *target, "{alias} itself");
            assert_eq!(
                normalize_path(&format!("{alias}/child/leaf")),
                format!("{target}/child/leaf"),
                "{alias} as a parent"
            );
            // Trailing separators and `.` collapse before the alias is looked
            // up, so an untidy caller still gets the mapped path.
            assert_eq!(normalize_path(&format!("{alias}/./")), *target);
        }
        // Aliases are a whole-segment match: a directory that merely starts with
        // the alias text is a different place.
        assert_eq!(normalize_path("/variables/file"), "/variables/file");
        assert_eq!(normalize_path("/tmpfile"), "/tmpfile");
        assert_eq!(normalize_path("/etcetera/x"), "/etcetera/x");
    }

    #[test]
    fn aliased_system_paths_are_protected() {
        // Without the alias mapping these reached the scanner spelled `/var/...`
        // and matched no `/private/var/...` prefix.
        assert!(is_protected_path(HOME, "/var/db/secret"));
        assert!(is_protected_path(HOME, "/var/vm/swapfile"));
        assert!(is_protected_path(HOME, "/etc/hosts"));
        assert!(is_protected_path(HOME, "/var/db/../db/secret"));
    }

    #[test]
    fn a_grant_for_an_alias_does_not_unlock_the_system_tree() {
        use std::path::PathBuf;
        // A grant is compared in its normalised spelling, so granting `/var` is
        // granting `/private/var` — which is not enough to reach the system
        // database or the swap files.
        let grants = [PathBuf::from("/var")];
        for target in [
            "/var/db/secret",
            "/private/var/db/secret",
            "/var/vm/swapfile",
        ] {
            assert!(
                is_protected_path_authorized(HOME, target, &grants),
                "{target} must stay protected under a /var grant"
            );
        }
    }

    #[test]
    fn package_extensions_are_recognised() {
        let exts: Vec<String> = vec!["app".into(), "dmg".into()];
        assert!(is_package_directory("Safari.app", &exts));
        assert!(is_package_directory("Photos.photoslibrary", &exts));
        assert!(is_package_directory("Installer.dmg", &exts));
        assert!(!is_package_directory("notes.txt", &exts));
        assert!(!is_package_directory("README", &exts));
    }

    #[test]
    fn rule_set_rejects_unknown_schema_version() {
        let json = r#"{"schemaVersion":99,"rules":[]}"#;
        assert_eq!(
            RuleSet::from_json(json),
            Err(RuleError::UnsupportedVersion {
                found: 99,
                expected: RULE_SCHEMA_VERSION
            })
        );
    }

    #[test]
    fn a_relative_path_that_leaves_its_anchor_is_rejected() {
        // `Path::join` replaces the base when the argument is absolute, and a
        // `..` component walks out of it, so both spellings have to be refused
        // where the file is read rather than where the root is walked.
        for escaping in [
            "/etc",
            "/Library/LaunchDaemons",
            "../Shared",
            "../../Shared",
            "Logs/../../Shared",
            "Logs/./../../Shared",
            ".",
            "..",
        ] {
            let json = format!(
                r#"{{"schemaVersion":1,"rules":[
                    {{"id":"escape","category":"logs","risk":"safe","root":"homeLibrary",
                     "relativePath":"{escaping}","explanationKey":"k"}}
                ]}}"#
            );
            assert!(
                matches!(
                    RuleSet::from_json(&json),
                    Err(RuleError::EscapingRelativePath { .. })
                ),
                "{escaping:?} must be refused"
            );
        }
    }

    #[test]
    fn ordinary_relative_paths_are_still_accepted() {
        for allowed in [
            "",
            "Logs",
            "Library/Logs/DiagnosticReports",
            "Saved Application State",
            "Logs/",
            "..notes",
        ] {
            let json = format!(
                r#"{{"schemaVersion":1,"rules":[
                    {{"id":"fine","category":"logs","risk":"safe","root":"homeLibrary",
                     "relativePath":"{allowed}","explanationKey":"k"}}
                ]}}"#
            );
            assert!(
                RuleSet::from_json(&json).is_ok(),
                "{allowed:?} must be accepted"
            );
        }
    }

    #[test]
    fn rule_set_rejects_duplicate_ids() {
        let json = r#"{"schemaVersion":1,"rules":[
            {"id":"a","category":"logs","risk":"safe","root":"homeLibrary","relativePath":"Logs","explanationKey":"k"},
            {"id":"a","category":"logs","risk":"safe","root":"homeLibrary","relativePath":"Logs","explanationKey":"k"}
        ]}"#;
        assert_eq!(
            RuleSet::from_json(json),
            Err(RuleError::DuplicateRuleID("a".to_string()))
        );
    }

    #[test]
    fn rule_set_parses_the_shipped_shape() {
        let json = r#"{
          "schemaVersion": 1,
          "rules": [{
            "id": "user-cache",
            "category": "applicationCache",
            "risk": "safe",
            "root": "homeLibrary",
            "relativePath": "Caches",
            "matchSpec": "childDirectories",
            "requiresFullDiskAccess": false,
            "explanationKey": "cleanup.cache.explanation"
          }]
        }"#;
        let set = RuleSet::from_json(json).expect("shipped rule shape must parse");
        assert_eq!(set.rules.len(), 1);
        assert_eq!(
            set.rules[0].effective_match_spec(),
            MatchSpec::ChildDirectories
        );
    }

    #[test]
    fn a_fixed_extension_rule_parses_in_the_shape_the_rule_file_ships() {
        // The extension list is a sibling of `matchSpec`, not nested inside it.
        // Reading it as an externally tagged enum rejected this document, and an
        // overlay that fails to parse fails the whole scan on the Rust side.
        let json = r#"{"schemaVersion":1,"rules":[
            {"id":"only-xip","category":"installers","risk":"review","root":"home",
             "relativePath":"Downloads","matchSpec":"filesByExtension",
             "extensions":["XIP","dmg"],"explanationKey":"k"}
        ]}"#;
        let set = RuleSet::from_json(json).expect("the shipped extension shape must parse");
        assert_eq!(
            set.rules[0].effective_match_spec(),
            MatchSpec::FilesByExtension {
                extensions: vec!["xip".to_string(), "dmg".to_string()]
            },
            "extensions are lower-cased so they match the comparison"
        );
    }

    #[test]
    fn the_shipped_rule_file_is_the_built_in_table() {
        // `Core/Resources/CleaningRules.json` is generated from `default_rules()`
        // by `Scripts/generate-rules.py`, and it is what a user copies to write
        // their own rules and what the Swift engine reads. Parsing it was the
        // whole check once, which passed while the document held seven rules and
        // the Rust table held twelve: both engines then recognised a different
        // set, and the rules one of them applied were invisible in the file a
        // reviewer reads.
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../Core/Resources/CleaningRules.json");
        let json = std::fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("{} must be readable: {error}", path.display()));

        let set = RuleSet::from_json(&json).expect("the shipped rule file must parse in Rust");
        assert_eq!(
            set,
            RuleSet {
                schema_version: RULE_SCHEMA_VERSION,
                rules: default_rules()
            },
            "the shipped rule file must be the built-in table; \
             run Scripts/generate-rules.py"
        );
    }

    #[test]
    fn no_built_in_rule_offers_a_container_of_other_applications() {
        // Two shapes are refused here rather than left to review, because both
        // read as one innocuous cleanup item and are not:
        //
        //   * a rule over `~/Library/Containers` or `~/Library/Group Containers`,
        //     where every sandboxed application keeps its state — `Directory`
        //     makes one item of all of it, `ChildDirectories` offers the live
        //     data of installed applications one by one;
        //   * a rule whose category is `ApplicationResidue`, which is decided at
        //     scan time by comparing names against installed bundle identifiers,
        //     not by a name shape or an age.
        for rule in default_rules() {
            assert!(
                rule.relative_path != "Containers" && rule.relative_path != "Group Containers",
                "rule `{}` targets a container of every application's data",
                rule.id
            );
            assert_ne!(
                rule.category,
                Category::ApplicationResidue,
                "rule `{}` claims residue; only the residue scanner may do that, \
                 because it is the only thing that knows which applications are installed",
                rule.id
            );
            // `Application Support` holds the live data of installed
            // applications (and this app's own data). A child-directory rule
            // there offers each application's data as one item without knowing
            // whether the application is installed; only the residue scanner may
            // make that decision.
            assert_ne!(
                rule.relative_path, "Application Support",
                "rule `{}` offers every application's data under Application Support",
                rule.id
            );
            // A child-directory rule with an age threshold is allowed (logs
            // use one), but the scanner must only offer a directory whose every
            // file is stale; `an_age_filtered_directory_rule_skips_a_directory_with_fresh_files`
            // covers that side.
        }
    }

    #[test]
    fn every_built_in_rule_names_an_explanation_without_a_placeholder() {
        // The scanner hands the key to the UI, which renders it with no
        // arguments. A key derived from the rule id (`cleanup.<id>.explanation`)
        // resolves to nothing and silently fell back to the category sentence;
        // a key carrying `%d` reaches the user with the placeholder in it, which
        // is why the item-level sentences are separate from the ones that take a
        // number. `Scripts/check-explanation-keys.py` holds the other half: that
        // the catalog actually carries each key.
        for rule in default_rules() {
            assert!(
                rule.explanation_key.starts_with("cleanup.explanation."),
                "rule `{}` names `{}`, which is not a shipped explanation key",
                rule.id,
                rule.explanation_key
            );
            assert!(
                !rule.explanation_key.contains('%'),
                "rule `{}` names a key with a format placeholder: {}",
                rule.id,
                rule.explanation_key
            );
        }
    }

    #[test]
    fn match_spec_defaults_follow_the_rule_shape() {
        let root_rule = rule(
            "x",
            Category::Logs,
            Risk::Safe,
            RootAnchor::HomeLibrary,
            "",
            "cleanup.explanation.logsItem",
        );
        assert_eq!(
            root_rule.effective_match_spec(),
            MatchSpec::ChildDirectories
        );
        let dir_rule = rule(
            "y",
            Category::Logs,
            Risk::Safe,
            RootAnchor::HomeLibrary,
            "Logs",
            "cleanup.explanation.logsItem",
        );
        assert_eq!(dir_rule.effective_match_spec(), MatchSpec::Directory);
    }

    #[test]
    fn the_stale_threshold_replaces_the_age_of_a_rule_that_follows_it() {
        let following = following_stale_threshold(with_min_age(
            rule(
                "logs",
                Category::Logs,
                Risk::Safe,
                RootAnchor::HomeLibrary,
                "Logs",
                "cleanup.explanation.logsItem",
            ),
            30,
        ));
        assert_eq!(following.effective_min_age_days(14), Some(14));
        assert_eq!(following.effective_min_age_days(90), Some(90));
        // A threshold that was never stored must not make everything stale now.
        assert_eq!(
            following.effective_min_age_days(0),
            Some(30),
            "zero leaves the rule's own age in force"
        );
    }

    #[test]
    fn a_rule_that_does_not_follow_the_threshold_keeps_its_own_age() {
        // `download-archives` states 90 days deliberately; the setting must not
        // quietly make every zip in Downloads stale after a fortnight.
        let fixed = with_min_age(
            rule(
                "archives",
                Category::Installers,
                Risk::Review,
                RootAnchor::Home,
                "Downloads",
                "cleanup.explanation.installers",
            ),
            90,
        );
        assert_eq!(fixed.effective_min_age_days(14), Some(90));
        assert_eq!(fixed.effective_min_age_days(365), Some(90));
        // And a rule with no age at all stays without one.
        let ageless = rule(
            "cache",
            Category::ApplicationCache,
            Risk::Safe,
            RootAnchor::HomeLibrary,
            "Caches",
            "cleanup.explanation.cache",
        );
        assert_eq!(ageless.effective_min_age_days(14), None);
    }

    #[test]
    fn overlay_merge_replaces_rules_and_drops_protected() {
        let base = RuleSet {
            schema_version: RULE_SCHEMA_VERSION,
            rules: default_rules(),
        };
        let overlay = RuleSet::from_json(
            r#"{"schemaVersion":1,"rules":[
                {"id":"user-logs","category":"logs","risk":"review","root":"homeLibrary","relativePath":"Logs","explanationKey":"custom"},
                {"id":"never","category":"logs","risk":"protected","root":"homeLibrary","relativePath":"Logs","explanationKey":"never"}
            ]}"#,
        )
        .unwrap();
        let merged = base.merge(overlay);
        let user_logs = merged
            .rules
            .iter()
            .find(|r| r.id == "user-logs")
            .expect("rule survives merge");
        assert_eq!(user_logs.risk, Risk::Review, "overlay must retune the rule");
        assert!(!merged.rules.iter().any(|r| r.id == "never"));
    }

    #[test]
    fn the_overlay_replaces_before_it_filters() {
        // Swift's counterpart is `test_aDisabledOverrideSwitchesTheShippedRuleOff`
        // in `RuleEngineTests`: the same document, the same semantics, so a rule
        // file cannot mean one thing to the scanner and another to the engine
        // that checks the results.
        let base = RuleSet {
            schema_version: RULE_SCHEMA_VERSION,
            rules: default_rules(),
        };

        // Switching a shipped rule off removes it.
        let disabling = RuleSet::from_json(
            r#"{"schemaVersion":1,"rules":[
                {"id":"user-logs","category":"logs","risk":"safe","root":"homeLibrary",
                 "relativePath":"Logs","matchSpec":"childDirectories","enabled":false,
                 "explanationKey":"k"}
            ]}"#,
        )
        .expect("the file parses");
        let merged = base.clone().merge(disabling);
        assert!(
            !merged.rules.iter().any(|r| r.id == "user-logs"),
            "a disabled override replaces the shipped rule and is then dropped"
        );
        assert!(
            merged.rules.iter().any(|r| r.id == "user-cache"),
            "and nothing else is touched"
        );

        // Marking one `protected` leaves no hole where the shipped rule was.
        let raising = RuleSet::from_json(
            r#"{"schemaVersion":1,"rules":[
                {"id":"user-logs","category":"logs","risk":"protected","root":"homeLibrary",
                 "relativePath":"Logs","matchSpec":"childDirectories","explanationKey":"k"}
            ]}"#,
        )
        .expect("the file parses");
        let merged = base.merge(raising);
        assert!(!merged.rules.iter().any(|r| r.id == "user-logs"));
    }

    #[test]
    fn default_rules_are_unique_and_named() {
        let rules = default_rules();
        let mut ids: Vec<&str> = rules.iter().map(|r| r.id.as_str()).collect();
        ids.sort_unstable();
        let before = ids.len();
        ids.dedup();
        assert_eq!(before, ids.len(), "built-in rule ids must be unique");
        for rule in &rules {
            assert!(!rule.explanation_key.is_empty(), "{}", rule.id);
            assert_ne!(rule.risk, Risk::Protected);
        }
    }

    #[test]
    fn authorisation_lifts_only_the_volumes_blanket_prefix() {
        use std::path::PathBuf;

        let home = "/Users/example";
        let make = |paths: &[&str]| paths.iter().map(PathBuf::from).collect::<Vec<_>>();

        // A concrete volume the user added opens.
        assert!(
            !is_protected_path_authorized(
                home,
                "/Volumes/External/file.bin",
                &make(&["/Volumes/External"])
            ),
            "an authorised volume is scannable"
        );
        // A different volume stays closed.
        assert!(is_protected_path_authorized(
            home,
            "/Volumes/Other/file.bin",
            &make(&["/Volumes/External"])
        ));

        // Granting the container or a system tree must not open the system.
        for grant in ["/", "/Volumes", "/Library", "/private", "/private/var"] {
            for target in [
                "/Library/Extensions/foo.kext",
                "/Library/LaunchDaemons/com.example.plist",
                "/Library/LaunchAgents/com.example.plist",
                "/private/var/db/secret",
                "/private/var/vm/swapfile",
            ] {
                assert!(
                    is_protected_path_authorized(home, target, &make(&[grant])),
                    "grant {grant} must not unlock {target}"
                );
            }
        }

        // And a grant never unlocks user content or secrets.
        assert!(is_protected_path_authorized(
            home,
            "/Users/example/Documents/taxes.pdf",
            &make(&["/Users/example"])
        ));
        assert!(is_protected_path_authorized(
            home,
            "/Users/example/Library/Keychains/login.keychain-db",
            &make(&["/Users/example"])
        ));
    }

    #[test]
    fn risk_combination_prefers_the_more_cautious_level() {
        assert_eq!(Risk::Safe.combine(Risk::Review), Risk::Review);
        assert_eq!(Risk::Review.combine(Risk::Protected), Risk::Protected);
        assert_eq!(Risk::Safe.combine(Risk::Safe), Risk::Safe);
    }

    #[test]
    fn the_recycle_bin_is_protected_at_any_depth() {
        // The product's undo is the Trash: every removal moves an item there,
        // and the user's recovery is emptying it later. Offering its contents
        // would move an item into the bin it is already in.
        for path in [
            format!("{HOME}/.Trash"),
            format!("{HOME}/.Trash/old-report.pdf"),
            format!("{HOME}/.Trash/folder/nested/file"),
            // The per-volume spelling, which is a sibling rather than a prefix.
            "/Volumes/Backup/.Trashes/501/item".to_string(),
            "/Volumes/Backup/.Trashes/501".to_string(),
        ] {
            assert!(is_protected_path(HOME, &path), "{path} must be refused");
        }

        // An ordinary folder whose name merely starts with the bin's name is
        // not a bin; whole-component matching is what keeps that true.
        for path in [
            format!("{HOME}/.Trash-notes/a.txt"),
            format!("{HOME}/Library/Caches/.Trashy/x"),
            format!("{HOME}/Documents/.Trashold/x"),
        ] {
            assert!(
                recycle_bin_reason(&path).is_none(),
                "{path} is an ordinary folder"
            );
        }
    }

    #[test]
    fn a_grant_does_not_open_the_trash_inside_the_granted_volume() {
        use std::path::PathBuf;
        let grants = [PathBuf::from("/Volumes/Backup")];
        assert!(is_protected_path_authorized(
            HOME,
            "/Volumes/Backup/.Trashes/501/item",
            &grants
        ));
        assert!(
            !is_protected_path_authorized(HOME, "/Volumes/Backup/Photos/a.jpg", &grants),
            "the rest of the granted volume stays open"
        );
    }

    fn one_rule_json(relative_path: &str, extra: &str) -> String {
        format!(
            r#"{{"schemaVersion":1,"rules":[
                {{"id":"x","category":"temporaryFiles","risk":"review","root":"homeLibrary",
                 "relativePath":"{relative_path}"{extra},"explanationKey":"k"}}
            ]}}"#
        )
    }

    #[test]
    fn a_rule_file_cannot_name_a_container_of_every_application() {
        // These three hold the live data of every application at once, and a
        // rule can only match a name shape or an age. The shipped table is
        // asserted against the same list; this is the other half, so the
        // invariant covers a rule the user wrote as well.
        for directory in FORBIDDEN_RULE_DIRECTORIES {
            for spelling in [directory.to_string(), directory.to_lowercase()] {
                let json = one_rule_json(&spelling, r#","matchSpec":"childDirectories""#);
                assert!(
                    matches!(
                        RuleSet::from_json(&json),
                        Err(RuleError::ForbiddenRuleDirectory { .. })
                    ),
                    "{spelling} must be refused"
                );
            }
        }
        // A path that merely contains the name as one component is a different
        // directory and stays usable.
        let deeper = one_rule_json(
            "Containers/com.example.app/Data/Library/Caches",
            r#","matchSpec":"childDirectories""#,
        );
        assert!(RuleSet::from_json(&deeper).is_ok());
    }

    #[test]
    fn the_forbidden_directory_check_collapses_before_comparing() {
        // `./Containers` and `//Application Support` name the same directory as
        // the bare spelling, so refusing only the tidy one would be a check on
        // formatting rather than on the target.
        for spelling in [
            "./Containers",
            "//Containers",
            "Containers/",
            "Application Support/./",
        ] {
            assert!(
                forbidden_rule_directory(spelling, None).is_some(),
                "{spelling} names a forbidden directory"
            );
        }
        for allowed in ["", "Caches", "Application Support/com.example.app/Cache"] {
            assert!(
                forbidden_rule_directory(allowed, None).is_none(),
                "{allowed}"
            );
        }
    }

    #[test]
    fn a_rule_file_cannot_match_every_file_without_an_age() {
        // `anyFile` with no threshold is "every file below this root", which no
        // place in this product is safe to offer.
        let json = one_rule_json("Caches", r#","matchSpec":"anyFile""#);
        assert!(matches!(
            RuleSet::from_json(&json),
            Err(RuleError::AnyFileWithoutMinAge { .. })
        ));
        let aged = one_rule_json("Caches", r#","matchSpec":"anyFile","minAgeDays":30"#);
        assert!(RuleSet::from_json(&aged).is_ok());
    }

    #[test]
    fn a_rule_file_cannot_state_an_age_beyond_the_documented_range() {
        // The Rust loader reads the field as a `u32`, so a negative age is a
        // parse error here — and the Swift decoder has to refuse it too, or the
        // scan fails with `invalidRequest` and nothing points at the rule file.
        for days in [MAX_RULE_MIN_AGE_DAYS + 1, MAX_RULE_MIN_AGE_DAYS * 1000] {
            let json = one_rule_json("Caches", &format!(r#","minAgeDays":{days}"#));
            assert!(matches!(
                RuleSet::from_json(&json),
                Err(RuleError::MinAgeOutOfRange { .. })
            ));
        }
        let boundary = one_rule_json(
            "Caches",
            &format!(r#","minAgeDays":{MAX_RULE_MIN_AGE_DAYS}"#),
        );
        assert!(RuleSet::from_json(&boundary).is_ok());
    }

    #[test]
    fn a_rule_this_build_does_not_ship_is_offered_at_review() {
        // `safe` is what arrives pre-selected. Only a review in a release earns
        // it, so a rule the user added is shown at `review`: it still finds
        // things, and the decision stays with the user.
        let overlay = RuleSet::from_json(
            r#"{"schemaVersion":1,"rules":[
                {"id":"my-junk","category":"temporaryFiles","risk":"safe","root":"homeLibrary",
                 "relativePath":"Caches/MyApp","matchSpec":"childDirectories","explanationKey":"k"}
            ]}"#,
        )
        .expect("the file parses");
        let shipped = shipped_rule_ids();
        let merged = enforce_rule_invariants(
            RuleSet {
                schema_version: RULE_SCHEMA_VERSION,
                rules: default_rules(),
            }
            .merge(overlay)
            .rules,
            &shipped,
        );
        let added = merged
            .iter()
            .find(|rule| rule.id == "my-junk")
            .expect("the rule survives the merge");
        assert_eq!(
            added.risk,
            Risk::Review,
            "an unshipped rule may not say safe"
        );

        // A shipped rule keeps the level its release gave it.
        for rule in merged.iter().filter(|rule| shipped.contains(&rule.id)) {
            assert_eq!(
                rule.risk,
                default_rules()
                    .into_iter()
                    .find(|shipped_rule| shipped_rule.id == rule.id)
                    .expect("shipped rule")
                    .risk,
                "rule `{}` changed level",
                rule.id
            );
        }
    }

    #[test]
    fn a_rule_that_replaces_a_shipped_id_keeps_its_level() {
        // Retuning a reviewed rule is what an overlay is for; refusing `safe`
        // there would make the feature useless.
        let overlay = RuleSet::from_json(
            r#"{"schemaVersion":1,"rules":[
                {"id":"user-cache","category":"applicationCache","risk":"safe","root":"homeLibrary",
                 "relativePath":"Caches","matchSpec":"childDirectories","explanationKey":"k"}
            ]}"#,
        )
        .expect("the file parses");
        let merged = enforce_rule_invariants(
            RuleSet {
                schema_version: RULE_SCHEMA_VERSION,
                rules: default_rules(),
            }
            .merge(overlay)
            .rules,
            &shipped_rule_ids(),
        );
        let cache = merged
            .iter()
            .find(|rule| rule.id == "user-cache")
            .expect("the shipped rule is still there");
        assert_eq!(cache.risk, Risk::Safe);
    }

    #[test]
    fn the_invariants_also_hold_for_a_table_built_in_code() {
        // Defence in depth: `from_json` is not the only way a rule can reach the
        // walker, and the shipped table itself must satisfy the same rules.
        let mut forged = rule(
            "forged",
            Category::TemporaryFiles,
            Risk::Review,
            RootAnchor::HomeLibrary,
            "Application Support",
            "cleanup.explanation.cached",
        );
        forged.match_spec = Some(MatchSpecName::ChildDirectories);
        let kept = enforce_rule_invariants(vec![forged], &shipped_rule_ids());
        assert!(kept.is_empty(), "a container target is dropped");

        let mut wide = rule(
            "wide",
            Category::TemporaryFiles,
            Risk::Review,
            RootAnchor::HomeLibrary,
            "Caches",
            "cleanup.explanation.cached",
        );
        wide.match_spec = Some(MatchSpecName::AnyFile);
        assert!(
            enforce_rule_invariants(vec![wide], &shipped_rule_ids()).is_empty(),
            "an ageless anyFile rule is dropped"
        );
    }

    #[test]
    fn the_shared_rule_fixtures_are_decided_the_same_way() {
        // One corpus, two decoders. The Swift engine validates a user rule file
        // and hands the document to this loader, which parses it again: a
        // document one accepts and the other refuses fails the whole scan with
        // `invalidRequest`, and nothing in that error points at the rule file.
        // Swift's counterpart is `test_theSharedRuleFixturesAreDecidedTheSameWay`.
        let root =
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../Tests/Fixtures/Rules");
        let mut checked = 0;

        for (directory, must_accept) in [("accept", true), ("reject", false)] {
            let folder = root.join(directory);
            let mut files: Vec<std::path::PathBuf> = std::fs::read_dir(&folder)
                .unwrap_or_else(|error| panic!("{} must be readable: {error}", folder.display()))
                .filter_map(|entry| entry.ok().map(|entry| entry.path()))
                .filter(|path| path.extension().is_some_and(|ext| ext == "json"))
                .collect();
            files.sort();
            assert!(
                !files.is_empty(),
                "the {directory} corpus must not be empty"
            );

            for file in files {
                let json = std::fs::read_to_string(&file)
                    .unwrap_or_else(|error| panic!("{} must be readable: {error}", file.display()));
                let name = format!(
                    "{directory}/{}",
                    file.file_name().unwrap().to_string_lossy()
                );
                let verdict = RuleSet::from_json(&json);
                if must_accept {
                    assert!(verdict.is_ok(), "{name} must be accepted: {verdict:?}");
                } else {
                    assert!(verdict.is_err(), "{name} must be refused");
                }
                checked += 1;
            }
        }

        assert!(checked >= 14, "the corpus is the point; keep it populated");
    }

    #[test]
    fn an_interior_dot_component_is_refused_like_the_swift_decoder_refuses_it() {
        // `Path::components()` drops an interior `.`, so `Logs/./x` looked like
        // `Logs/x` here while the Swift decoder refused it. The direction was
        // harmless (Swift refused, so the file never reached this loader), but
        // the two decoders disagreeing about a document is the bug.
        assert!(!relative_path_stays_inside_anchor("Logs/./x"));
        assert!(relative_path_stays_inside_anchor("Logs/"));
        assert!(relative_path_stays_inside_anchor("..notes/x"));
        assert!(relative_path_stays_inside_anchor(""));
    }

    #[test]
    fn a_wildcard_component_is_the_only_wildcard_this_build_accepts() {
        // One component, matching one directory name: that is what makes
        // `Containers/*/Data/Library/Caches` expressible without a rule per
        // bundle identifier.
        for accepted in [
            "Containers/*/Data/Library/Caches",
            "Application Support/*/Cache",
            "*/Caches", // refused below: leading wildcard
        ] {
            let valid = relative_path_glob_is_valid(accepted);
            assert_eq!(
                valid,
                accepted != "*/Caches",
                "{accepted} must be judged on the leading-wildcard rule"
            );
        }

        for refused in [
            "Containers/com.apple.*", // partial: a substring match the scanner cannot do safely
            "Containers/**",          // recursive: unbounded by construction
            "**",                     // recursive and the whole anchor
            "*/Caches",               // leading: one rule over every child of the anchor
            "a/*/b/*/c/*/d",
        ] {
            if refused == "a/*/b/*/c/*/d" {
                // Four single-segment wildcards are legal; the bound is on
                // expansion, not on the number of components.
                assert!(relative_path_glob_is_valid(refused), "{refused}");
                continue;
            }
            assert!(!relative_path_glob_is_valid(refused), "{refused}");
        }

        // A literal-only path is unchanged by the rule.
        for literal in ["", "Caches", "Application Support/com.example.app/Cache"] {
            assert!(relative_path_glob_is_valid(literal), "{literal}");
        }
    }

    #[test]
    fn a_wildcard_directly_inside_a_container_is_refused() {
        // `Containers/*` is one item per installed application: exactly the shape
        // `FORBIDDEN_RULE_DIRECTORIES` exists to refuse, spelled with a wildcard.
        // The specification decides: one that names what to look for inside the
        // children (`directoriesNamed`) is a named location, not the container.
        for refused in [
            "Containers/*",
            "Application Support/*",
            "Group Containers/*",
        ] {
            for spec in [
                None,
                Some(MatchSpecName::ChildDirectories),
                Some(MatchSpecName::Directory),
                Some(MatchSpecName::AnyFile),
                Some(MatchSpecName::FilesByExtension),
            ] {
                assert!(
                    forbidden_rule_directory(refused, spec).is_some(),
                    "{refused} with {spec:?} offers every application's data"
                );
            }
            assert!(
                forbidden_rule_directory(refused, Some(MatchSpecName::DirectoriesNamed)).is_none(),
                "{refused} with a name set offers one named directory each"
            );
        }
        // Descending *through* the container to a named location stays allowed
        // whatever the specification is.
        for allowed in [
            "Containers/*/Data/Library/Caches",
            "Application Support/*/Cache",
            "Application Support/com.example.app/Cache",
        ] {
            for spec in [
                None,
                Some(MatchSpecName::ChildDirectories),
                Some(MatchSpecName::DirectoriesNamed),
            ] {
                assert!(
                    forbidden_rule_directory(allowed, spec).is_none(),
                    "{allowed}"
                );
            }
        }
    }

    #[test]
    fn a_name_set_is_part_of_the_document() {
        // `names` is a sibling of `matchSpec`, the way `extensions` is, and the
        // resolved specification carries it.
        let json = r#"{"schemaVersion":1,"rules":[
            {"id":"named","category":"applicationCache","risk":"review","root":"homeLibrary",
             "relativePath":"Application Support/*","matchSpec":"directoriesNamed",
             "names":["Cache","Caches"],"explanationKey":"cleanup.explanation.cache"}
        ]}"#;
        let rule = RuleSet::from_json(json).expect("the shape parses").rules[0].clone();
        assert_eq!(
            rule.effective_match_spec(),
            MatchSpec::DirectoriesNamed {
                names: vec!["Cache".to_string(), "Caches".to_string()]
            }
        );

        // A set that cannot match a directory is refused where the file is read:
        // an empty one finds nothing, and a name carrying a separator or a
        // wildcard is a path the author meant to write in `relativePath`.
        for names in ["[]", r#"[""]"#, r#"["Cache/Sub"]"#, r#"["*"]"#, r#"[".."]"#] {
            let json = format!(
                r#"{{"schemaVersion":1,"rules":[
                    {{"id":"named","category":"applicationCache","risk":"review",
                     "root":"homeLibrary","relativePath":"Application Support/*",
                     "matchSpec":"directoriesNamed","names":{names},
                     "explanationKey":"cleanup.explanation.cache"}}
                ]}}"#
            );
            assert!(
                matches!(
                    RuleSet::from_json(&json),
                    Err(RuleError::DirectoriesNamedWithoutNames { .. })
                ),
                "names {names} must be refused"
            );
        }
    }

    #[test]
    fn a_rule_file_with_an_unsupported_wildcard_is_refused() {
        for refused in ["Containers/com.apple.*", "Containers/**", "*/Caches"] {
            let json = one_rule_json(refused, r#","matchSpec":"childDirectories""#);
            assert!(
                matches!(
                    RuleSet::from_json(&json),
                    Err(RuleError::UnsupportedRelativePathWildcard { .. })
                ),
                "{refused} must be refused"
            );
        }

        // The shape the shipped table uses parses.
        let accepted = one_rule_json(
            "Containers/*/Data/Library/Caches",
            r#","matchSpec":"directory""#,
        );
        assert!(RuleSet::from_json(&accepted).is_ok());
    }

    #[test]
    fn every_shipped_rule_uses_a_wildcard_this_build_understands() {
        for rule in default_rules() {
            assert!(
                relative_path_glob_is_valid(&rule.relative_path),
                "rule `{}` uses `{}`",
                rule.id,
                rule.relative_path
            );
        }
    }

    #[test]
    fn the_shipped_table_satisfies_every_rule_invariant() {
        // The runtime enforcement is the second line; this asserts the shipped
        // table never needs it.
        let shipped = shipped_rule_ids();
        let enforced = enforce_rule_invariants(default_rules(), &shipped);
        assert_eq!(
            enforced,
            default_rules(),
            "the built-in table must already satisfy the invariants"
        );
    }

    #[test]
    fn a_running_application_owns_the_paths_that_name_it() {
        let tokens = vec![
            "com.apple.safari".to_string(),
            "com.spotify.client".to_string(),
            "firefox".to_string(),
            "visual studio code".to_string(),
        ];

        // The wildcard component in `Containers/*/Data/Library/Caches` names the
        // owner, and so does the last component of a `Caches/<id>` rule.
        for owned in [
            "/Users/x/Library/Containers/com.apple.Safari/Data/Library/Caches",
            "/Users/x/Library/Caches/com.apple.Safari",
            "/Users/x/Library/Caches/com.spotify.client",
            "/Users/x/Library/Caches/Firefox",
            "/Users/x/Library/Application Support/Visual Studio Code/Code Cache",
            // A bundle identifier claims the names below it, which is how a
            // sandboxed application's own sub-container is recognised.
            "/Users/x/Library/Caches/com.apple.Safari.SafeBrowsing",
            // The suffix on a saved-state directory is not part of the name of
            // the application it belongs to.
            "/Users/x/Library/Saved Application State/com.apple.Safari.savedState",
        ] {
            assert!(
                running_app_owns_path(owned, &tokens),
                "{owned} belongs to a running application"
            );
        }

        for unowned in [
            // Another application that merely starts with a running one's name.
            "/Users/x/Library/Caches/Firefox Developer Edition",
            "/Users/x/Library/Caches/com.apple.SafariServices",
            "/Users/x/Library/Containers/com.example.other/Data/Library/Caches",
            "/Users/x/Library/Caches/Homebrew",
        ] {
            assert!(
                !running_app_owns_path(unowned, &tokens),
                "{unowned} must not be attributed to a running application"
            );
        }

        // No running applications is the ordinary case, and it must never
        // downgrade anything.
        assert!(!running_app_owns_path(
            "/Users/x/Library/Caches/com.apple.Safari",
            &[]
        ));
        assert!(!running_app_owns_path(
            "/Users/x/Library/Caches/com.apple.Safari",
            &["  ".to_string()]
        ));
    }

    #[test]
    fn the_application_owned_rules_are_the_ones_that_ask_for_a_quit() {
        // The flag decides whether a `safe` item survives a running application,
        // so which rules carry it is a property of the table rather than a detail
        // of the scanner. Every rule whose items one application owns carries it;
        // the age- and extension-based rules do not, because no single
        // application owns what they find.
        let flagged: Vec<String> = default_rules()
            .into_iter()
            .filter(|rule| rule.needs_app_closed)
            .map(|rule| rule.id)
            .collect();
        assert_eq!(
            flagged,
            vec![
                "user-cache",
                "container-caches",
                "app-support-caches",
                "chromium-profile-caches",
                "user-saved-state"
            ]
        );

        // The document carries it, and a rule file that omits it gets `false`.
        let json = RuleSet::from_json(&shipped_rules_json()).expect("the shipped table parses");
        assert!(json
            .rules
            .iter()
            .any(|rule| rule.id == "user-cache" && rule.needs_app_closed));
        let plain = one_rule_json("Caches", r#","matchSpec":"directory""#);
        assert!(
            !RuleSet::from_json(&plain).expect("the shape parses").rules[0].needs_app_closed,
            "a rule file that says nothing must not claim application ownership"
        );
    }
}
