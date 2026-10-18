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

fn rule(id: &str, category: Category, risk: Risk, root: RootAnchor, rel: &str) -> Rule {
    Rule {
        id: id.to_string(),
        category,
        risk,
        root,
        relative_path: rel.to_string(),
        match_spec: None,
        extensions: Vec::new(),
        excludes: Vec::new(),
        min_age_days: None,
        uses_stale_threshold: false,
        package_extensions: Vec::new(),
        requires_full_disk_access: false,
        explanation_key: format!("cleanup.{id}.explanation"),
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
    }
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

/// The v0.1 built-in rule table. Everything the scanner recognises is listed
/// here explicitly; there is no heuristic "looks like a cache" fallback.
///
/// The list is built by pushing, one named block per category: writing it as a
/// single literal would lose the per-category documentation.
#[allow(clippy::vec_init_then_push)]
pub fn default_rules() -> Vec<Rule> {
    use Category::*;
    use Risk::*;
    use RootAnchor::*;

    let mut rules = Vec::new();

    // --- Application caches ------------------------------------------------
    rules.push(with_spec(
        with_excludes(
            rule("user-cache", ApplicationCache, Safe, HomeLibrary, "Caches"),
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
    rules.push(with_spec(
        rule(
            "user-cache-sandboxed",
            ApplicationCache,
            Review,
            HomeLibrary,
            "Containers",
        ),
        MatchSpec::Directory,
    ));
    rules.push(with_spec(
        rule(
            "user-group-cache",
            ApplicationCache,
            Review,
            HomeLibrary,
            "Group Containers",
        ),
        MatchSpec::Directory,
    ));

    // --- Logs --------------------------------------------------------------
    rules.push(following_stale_threshold(with_min_age(
        with_spec(
            rule("user-logs", Logs, Safe, HomeLibrary, "Logs"),
            MatchSpec::ChildDirectories,
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
            ),
            MatchSpec::AnyFile,
        ),
        30,
    )));
    rules.push(with_fda(following_stale_threshold(with_min_age(
        with_spec(
            rule("system-logs", Logs, Review, SystemLibrary, "Logs"),
            MatchSpec::ChildDirectories,
        ),
        30,
    ))));

    // --- Installers --------------------------------------------------------
    rules.push(following_stale_threshold(with_min_age(
        with_spec(
            rule("download-installers", Installers, Review, Home, "Downloads"),
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
            rule("download-archives", Installers, Review, Home, "Downloads"),
            MatchSpec::FilesByExtension {
                extensions: vec!["zip".into(), "tar".into(), "gz".into(), "tgz".into()],
            },
        ),
        90,
    ));

    // --- Temporary files ---------------------------------------------------
    rules.push(with_min_age(
        with_spec(
            rule(
                "user-temporary-items",
                TemporaryFiles,
                Review,
                HomeLibrary,
                "Application Support",
            ),
            MatchSpec::ChildDirectories,
        ),
        30,
    ));
    rules.push(with_spec(
        rule(
            "user-saved-state",
            TemporaryFiles,
            Safe,
            HomeLibrary,
            "Saved Application State",
        ),
        MatchSpec::ChildDirectories,
    ));

    // --- Application residue ----------------------------------------------
    // Populated at scan time from installed bundle identifiers, never guessed
    // from a name match.
    rules.push(with_spec(
        rule(
            "app-residue-caches",
            ApplicationResidue,
            Review,
            HomeLibrary,
            "Caches",
        ),
        MatchSpec::ChildDirectories,
    ));
    rules.push(with_spec(
        rule(
            "app-residue-support",
            ApplicationResidue,
            Review,
            HomeLibrary,
            "Application Support",
        ),
        MatchSpec::ChildDirectories,
    ));

    rules
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
    Path::new(path)
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

/// Classifies a path that sits inside `~/Library`.
///
/// Secrets, private messages and synced documents live here under names that
/// look like ordinary application state, so they are listed rather than inferred.
fn protected_library_reason(home: &str, path: &str) -> Option<ProtectedReason> {
    for child in PROTECTED_LIBRARY_CHILDREN {
        if is_prefix_of(&format!("{home}/{child}"), path) {
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
    if path.ends_with(PROTECTED_PHOTOS_LIBRARY_SUFFIX)
        || path.contains(&format!("{PROTECTED_PHOTOS_LIBRARY_SUFFIX}/"))
    {
        return Some(ProtectedReason::UserContent {
            child: "Photos Library".to_string(),
        });
    }
    None
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
        if is_prefix_of(&candidate, &path) {
            return Some(ProtectedReason::UserContent {
                child: (*child).to_string(),
            });
        }
    }

    for prefix in PROTECTED_PREFIXES {
        if is_prefix_of(prefix, &path) {
            return Some(ProtectedReason::SystemPath {
                prefix: (*prefix).to_string(),
            });
        }
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
        if is_prefix_of(&format!("{home_normalized}/{child}"), &path_normalized) {
            return Some(ProtectedReason::UserContent {
                child: (*child).to_string(),
            });
        }
    }
    if let Some(reason) = protected_library_reason(&home_normalized, &path_normalized) {
        return Some(reason);
    }

    // A grant lifts the blanket `/Volumes` guard for the authorised subtree only.
    // It never lifts a real system prefix: granting `/Library` or `/private/var`
    // would otherwise expose launch daemons and the system database.
    if is_prefix_of("/Volumes", &path_normalized) {
        for root in authorized_roots {
            let root = normalize_path(&root.to_string_lossy());
            if is_prefix_of(&root, &path_normalized) {
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
        if is_prefix_of(prefix, &path_normalized) {
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
    fn keychains_and_photos_library_are_protected() {
        assert!(is_protected_path(
            HOME,
            &format!("{HOME}/Library/Keychains/login.keychain-db")
        ));
        assert!(is_protected_path(
            HOME,
            &format!("{HOME}/Pictures/Photos Library.photoslibrary/db")
        ));
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
    fn the_shipped_rule_file_parses_as_an_overlay() {
        // `Core/Resources/CleaningRules.json` is what a user copies to write
        // their own rules and what the Swift engine reads. The Rust core receives
        // the same document as `extraRulesJson`, so it has to parse it.
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../Core/Resources/CleaningRules.json");
        let json = std::fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("{} must be readable: {error}", path.display()));

        let set = RuleSet::from_json(&json).expect("the shipped rule file must parse in Rust");
        assert!(!set.rules.is_empty());

        let installers = set
            .rules
            .iter()
            .find(|rule| rule.id == "download-installers")
            .expect("the shipped file still has the installer rule");
        match installers.effective_match_spec() {
            MatchSpec::FilesByExtension { extensions } => {
                assert!(extensions.contains(&"dmg".to_string()), "{extensions:?}");
            }
            other => panic!("download-installers must match by extension, got {other:?}"),
        }
    }

    #[test]
    fn match_spec_defaults_follow_the_rule_shape() {
        let root_rule = rule("x", Category::Logs, Risk::Safe, RootAnchor::HomeLibrary, "");
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
}
