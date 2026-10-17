//! Cleaning rule definitions for the Sift scanner core.
//!
//! Rules are the only place that decides *what may be recognised* and *how risky*
//! a location is. They are deliberately declarative so that the same definition
//! drives the Rust scanner, the unit tests and the shipped `CleaningRules.json`.
//!
//! Two invariants matter for safety:
//!
//! 1. `PROTECTED_PATHS` and `PROTECTED_HOME_CHILDREN` are compiled in. A rule file
//!    can only widen the *recognised* set, never unprotect these paths.
//! 2. Every rule carries an explicit `risk`. Nothing defaults to `Safe`.

use serde::{Deserialize, Serialize};

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

/// What a rule considers a match.
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
    pub match_spec: Option<MatchSpec>,
    /// Path fragments that must be skipped even inside a matching rule.
    #[serde(default)]
    pub excludes: Vec<String>,
    /// Only match entries not modified for at least this many days.
    #[serde(default)]
    pub min_age_days: Option<u32>,
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
    /// The concrete relative path, defaulting the match spec from the layout.
    pub fn effective_match_spec(&self) -> MatchSpec {
        if let Some(spec) = &self.match_spec {
            return spec.clone();
        }
        if self.relative_path.is_empty() {
            MatchSpec::ChildDirectories
        } else {
            MatchSpec::Directory
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
        excludes: Vec::new(),
        min_age_days: None,
        package_extensions: Vec::new(),
        requires_full_disk_access: false,
        explanation_key: format!("cleanup.{id}.explanation"),
        enabled: true,
    }
}

fn with_spec(mut r: Rule, spec: MatchSpec) -> Rule {
    r.match_spec = Some(spec);
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
    rules.push(with_min_age(
        with_spec(
            rule("user-logs", Logs, Safe, HomeLibrary, "Logs"),
            MatchSpec::ChildDirectories,
        ),
        30,
    ));
    rules.push(with_min_age(
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
    ));
    rules.push(with_fda(with_min_age(
        with_spec(
            rule("system-logs", Logs, Review, SystemLibrary, "Logs"),
            MatchSpec::ChildDirectories,
        ),
        30,
    )));

    // --- Installers --------------------------------------------------------
    rules.push(with_min_age(
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
    ));
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
/// segments. The input must already be absolute.
pub fn normalize_path(path: &str) -> String {
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

fn is_prefix_of(prefix: &str, path: &str) -> bool {
    let prefix = prefix.trim_end_matches('/');
    if prefix.is_empty() {
        return false;
    }
    path == prefix || path.starts_with(&format!("{prefix}/"))
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

    // Extra care for paths that look like user data even without a known name.
    if is_prefix_of(&format!("{home}/Library/Mobile Documents"), &path) {
        return Some(ProtectedReason::UserContent {
            child: "Library/Mobile Documents".to_string(),
        });
    }
    if is_prefix_of(&format!("{home}/Library/Keychains"), &path) {
        return Some(ProtectedReason::Secrets {
            path: "Library/Keychains".to_string(),
        });
    }
    if path.ends_with(".photoslibrary") || path.contains(".photoslibrary/") {
        return Some(ProtectedReason::UserContent {
            child: "Photos Library".to_string(),
        });
    }

    None
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
    if is_prefix_of(
        &format!("{home_normalized}/Library/Mobile Documents"),
        &path_normalized,
    ) {
        return Some(ProtectedReason::UserContent {
            child: "Library/Mobile Documents".to_string(),
        });
    }
    if is_prefix_of(
        &format!("{home_normalized}/Library/Keychains"),
        &path_normalized,
    ) {
        return Some(ProtectedReason::Secrets {
            path: "Library/Keychains".to_string(),
        });
    }
    if path_normalized.ends_with(".photoslibrary") || path_normalized.contains(".photoslibrary/") {
        return Some(ProtectedReason::UserContent {
            child: "Photos Library".to_string(),
        });
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
    fn symlink_free_paths_with_special_characters_survive_normalisation() {
        let tricky = "/Users/example/Library/Caches/应用 缓存/v1.0 (beta)+test#1";
        assert_eq!(normalize_path(tricky), tricky);
        assert!(!is_protected_path(HOME, tricky));
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
