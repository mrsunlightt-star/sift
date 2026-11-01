//! Scanner strategies.
//!
//! Each strategy turns filesystem facts into [`Candidate`] values. Candidates
//! are inert data: the coordinator decides what reaches the index, and only the
//! Swift layer can act on a result. Nothing here deletes or moves anything.
//!
//! The rule-driven strategies share three safety behaviours:
//!
//! * every path is re-checked against the compiled-in protection list,
//! * a `protected` risk candidate is dropped rather than downgraded,
//! * failures inside one rule never abort the scan.

use crate::dir_lister::DirLister;
use crate::types::{DuplicateOptions, ScanRequest};
use crate::walker::{self, WalkEntry, WalkMode, WalkOptions, WalkReport};

/// How long one measurement listing may take before the measured directory is
/// treated as unreadable. Same reasoning as the walk's own deadline: far above
/// any honest local directory, far below frozen.
const MEASURE_OPEN_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);
use sift_file_index::{GroupMemberRow, ItemRow};
use sift_hasher::{hash_file, sample_fingerprint, CancelToken, FileIdentity};
use sift_rules::{
    collapse_path, default_rules, is_prefix_of, is_protected_path_authorized,
    running_app_owns_path, Category, MatchSpec, Risk, RootAnchor, Rule, RuleSet,
};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

/// A cleanup candidate found by a strategy.
#[derive(Debug, Clone, PartialEq)]
pub struct Candidate {
    pub path: PathBuf,
    pub display_name: String,
    pub parent_path: String,
    pub category: Category,
    pub risk: Risk,
    pub size_bytes: u64,
    pub file_count: u64,
    pub modified_secs: i64,
    pub created_secs: i64,
    pub explanation_key: String,
    pub rule_id: String,
    pub bundle_id: Option<String>,
    pub is_directory: bool,
    /// Pre-selected in the UI. Only `safe` candidates default to selected.
    pub selected_by_default: bool,
    /// Set when the candidate overlaps another one (parent/child).
    pub note: Option<String>,
}

impl Candidate {
    pub fn to_item_row(&self) -> ItemRow {
        ItemRow {
            path: self.path.to_string_lossy().to_string(),
            display_name: self.display_name.clone(),
            parent_path: self.parent_path.clone(),
            category: self.category.as_str().to_string(),
            risk: self.risk.as_str().to_string(),
            size_bytes: self.size_bytes as i64,
            file_count: self.file_count as i64,
            explanation: String::new(),
            explanation_key: self.explanation_key.clone(),
            rule_id: self.rule_id.clone(),
            bundle_id: self.bundle_id.clone(),
            modified_secs: self.modified_secs,
            created_secs: self.created_secs,
            is_directory: self.is_directory,
            is_restorable: true,
            is_selected_by_default: self.selected_by_default,
            resolve_warning: self.note.clone(),
        }
    }
}

/// Everything a strategy needs besides the request itself.
pub struct ScanContext<'a> {
    pub request: &'a ScanRequest,
    pub home_dir: PathBuf,
    /// Rules in effect: shipped defaults merged with the user's rule file.
    pub rules: Vec<Rule>,
    /// Counters the strategy may update.
    pub progress: ProgressSink<'a>,
}

/// Callback used to publish progress without handing strategies an event bus.
pub struct ProgressSink<'a> {
    pub on_files: &'a mut dyn FnMut(u64, u64),
    pub on_current_path: &'a mut dyn FnMut(&Path),
}

impl ProgressSink<'_> {
    pub fn note_files(&mut self, files: u64, bytes: u64) {
        (self.on_files)(files, bytes);
    }

    pub fn note_path(&mut self, path: &Path) {
        (self.on_current_path)(path);
    }
}

/// Builds the effective rule list for a scan request.
///
/// The overlay is additive and can only retune or add rules: `protected` rules
/// and the compiled-in protection list always win. Both paths run the merged
/// table through [`sift_rules::enforce_rule_invariants`], so a rule that would
/// offer a container of every application's data — or claim `safe` without
/// being shipped — cannot reach the walker even if it arrived some other way
/// than `from_json`.
pub fn effective_rules(extra_rules_json: Option<&str>) -> Result<Vec<Rule>, String> {
    let shipped = sift_rules::shipped_rule_ids();
    let base = RuleSet {
        schema_version: sift_rules::RULE_SCHEMA_VERSION,
        rules: default_rules(),
    };
    let Some(json) = extra_rules_json else {
        return Ok(sift_rules::enforce_rule_invariants(base.rules, &shipped));
    };
    if json.trim().is_empty() {
        return Ok(sift_rules::enforce_rule_invariants(base.rules, &shipped));
    }
    let overlay = RuleSet::from_json(json).map_err(|e| e.to_string())?;
    let merged = base.merge(overlay).rules;
    Ok(sift_rules::enforce_rule_invariants(merged, &shipped))
}

/// Turns a fixed rule anchor into an absolute directory.
///
/// Returns `None` for the two authorised anchors: they do not name a directory
/// of their own, they name *the locations the user granted*, which only the
/// request knows. Those go through [`rule_roots`]; answering "/Volumes" or the
/// home directory here would silently widen a rule to a tree nobody authorised.
pub fn resolve_root(anchor: RootAnchor, relative_path: &str, home: &Path) -> Option<PathBuf> {
    let base = match anchor {
        RootAnchor::Home => home.to_path_buf(),
        RootAnchor::HomeLibrary => home.join("Library"),
        RootAnchor::Applications => PathBuf::from("/Applications"),
        RootAnchor::SystemLibrary => PathBuf::from("/Library"),
        // The per-user temporary root is named by the request, not by the anchor.
        RootAnchor::UserTemp | RootAnchor::Authorized | RootAnchor::ExternalVolume => return None,
    };
    // An anchor is a place to look inside, never a cleanup item. A rule with an
    // empty relative path used to resolve to the home directory itself, or to
    // `~/Library`, and one click could move the whole tree to the Trash.
    if relative_path.trim_matches('/').is_empty() {
        return None;
    }
    let joined = join_inside(&base, relative_path)?;
    if is_cleanup_container(&joined, home) {
        return None;
    }
    Some(joined)
}

/// True when `path` is a container rather than a cleanup target.
///
/// The home directory, `~/Library`, `~/Applications` and the system containers
/// hold many independent things; a rule that resolved to one of them would move
/// the entire tree as a single item. They remain scannable (the product lives
/// inside `~/Library`), but they are never a candidate themselves.
fn is_cleanup_container(path: &Path, home: &Path) -> bool {
    // Case-folded for the same reason the protection list is: `~/library` is
    // `~/Library` on a default APFS volume, and a rule that spelled it in
    // another case must not turn the whole library into one item.
    let path = collapse_path(&path.to_string_lossy()).to_lowercase();
    let home = collapse_path(&home.to_string_lossy()).to_lowercase();
    matches!(
        path.as_str(),
        "/" | "/volumes" | "/applications" | "/library"
    ) || path == home
        || path == format!("{home}/library")
        || path == format!("{home}/applications")
}

/// Joins `relative_path` under `base`, or refuses when the result leaves it.
///
/// `RuleSet::from_json` already rejects a relative path that is absolute or
/// contains `..`, so this is the second line rather than the only one: it also
/// covers the built-in table and pins down the *resolved* root. Without it the
/// protection check and the walk would disagree — the check normalises the path
/// it is given, so `/Users/alice/Library/../../Shared` is judged as
/// `/Users/Shared` and then walked as written.
fn join_inside(base: &Path, relative_path: &str) -> Option<PathBuf> {
    let joined = if relative_path.is_empty() {
        base.to_path_buf()
    } else {
        base.join(relative_path)
    };
    let base_text = collapse_path(&base.to_string_lossy());
    let joined_text = collapse_path(&joined.to_string_lossy());
    if is_prefix_of(&base_text, &joined_text) {
        Some(PathBuf::from(joined_text))
    } else {
        None
    }
}

/// Every root a rule applies to.
///
/// A rule anchored at `authorized` or `externalVolume` applies inside each
/// location the user granted, with its relative path under each of them: the
/// rule file cannot know those locations, and one rule has to cover the folder
/// the user happens to have added.
///
/// A `*` component is expanded against the disk — one directory listing per
/// wildcard, never a substring or a recursive match — so `Containers/*/Data/Library/Caches`
/// is one root per installed application. An empty relative path names the
/// anchor itself, which is a container rather than an item, so it yields
/// nothing; every expanded root is filtered through the same container check.
fn rule_roots(
    rule: &Rule,
    home: &Path,
    grants: &[PathBuf],
    user_temp: Option<&Path>,
) -> Vec<PathBuf> {
    let bases: Vec<PathBuf> = match rule.root {
        RootAnchor::Home => vec![home.to_path_buf()],
        RootAnchor::HomeLibrary => vec![home.join("Library")],
        RootAnchor::Applications => vec![PathBuf::from("/Applications")],
        RootAnchor::SystemLibrary => vec![PathBuf::from("/Library")],
        // The session directory the request named. Absent means this process has
        // no per-user temporary root, which resolves to nothing rather than to a
        // guess: `/var/folders` holds every session on the machine.
        RootAnchor::UserTemp => user_temp.map(Path::to_path_buf).into_iter().collect(),
        RootAnchor::Authorized => grants.to_vec(),
        RootAnchor::ExternalVolume => grants
            .iter()
            .filter(|root| is_mounted_volume(root))
            .cloned()
            .collect(),
    };

    let mut roots: Vec<PathBuf> = Vec::new();
    for base in bases {
        let is_excluded = |name: &str| exclude_matches(&rule.excludes, name);
        for root in expand_relative_path(&base, &rule.relative_path, &is_excluded) {
            // The anchor is a place to look inside. Granting `~/Library` as a
            // rule target is the same container mistake as naming the home
            // directory: one click would move every application's data.
            if root == base || is_cleanup_container(&root, home) {
                continue;
            }
            roots.push(root);
        }
    }
    roots.sort();
    roots.dedup();
    roots
}

/// Expands a rule's `relativePath` below one anchor.
///
/// Literal components are joined; a `*` component lists the directories at that
/// position, once per candidate, and the expansion stops at
/// [`sift_rules::MAX_RULE_ROOTS`]. The enumerated names are the only thing this
/// function adds to the path, so a rule cannot reach outside the anchor it
/// names — the components it supplies cannot be `..`, `.` or absolute (see
/// [`sift_rules::relative_path_stays_inside_anchor`]).
///
/// Symlinks are skipped rather than followed: a link inside `Containers` is not
/// a container, and following one would put a root outside the tree the rule
/// named. Names are yielded in sorted order so one scan of one tree produces the
/// same roots twice.
fn expand_relative_path(
    base: &Path,
    relative_path: &str,
    is_excluded: &dyn Fn(&str) -> bool,
) -> Vec<PathBuf> {
    let mut current = vec![base.to_path_buf()];

    for component in relative_path
        .split('/')
        .filter(|component| !component.is_empty())
    {
        if component == sift_rules::RELATIVE_PATH_WILDCARD {
            let mut next: Vec<PathBuf> = Vec::new();
            for directory in &current {
                for child in child_directories(directory) {
                    // A name on the rule's `excludes` list is skipped here as
                    // well as below the root: the wildcard is part of the path
                    // the rule names, so `excludes: ["com.apple"]` has to cover
                    // the container the `*` matched or it would only ever filter
                    // what is inside it.
                    if child
                        .file_name()
                        .is_some_and(|name| is_excluded(&name.to_string_lossy()))
                    {
                        continue;
                    }
                    next.push(child);
                    if next.len() >= sift_rules::MAX_RULE_ROOTS {
                        break;
                    }
                }
                if next.len() >= sift_rules::MAX_RULE_ROOTS {
                    break;
                }
            }
            current = next;
        } else {
            if is_excluded(component) {
                return Vec::new();
            }
            current = current
                .into_iter()
                .map(|directory| directory.join(component))
                .collect();
        }
        if current.is_empty() {
            break;
        }
    }

    current
}

/// The directories directly inside `directory`, sorted, symlinks excluded.
///
/// An unreadable directory contributes nothing: the rule simply finds nothing
/// there, the same way a walk of a tree the user cannot read does.
fn child_directories(directory: &Path) -> Vec<PathBuf> {
    let Ok(entries) = std::fs::read_dir(directory) else {
        return Vec::new();
    };
    let mut children: Vec<PathBuf> = entries
        .filter_map(|entry| entry.ok())
        .filter_map(|entry| {
            let metadata = std::fs::symlink_metadata(entry.path()).ok()?;
            if metadata.file_type().is_symlink() || !metadata.is_dir() {
                return None;
            }
            Some(entry.path())
        })
        .collect();
    children.sort();
    children
}

/// True when the path is the mount point of a volume rather than a folder on
/// one. `/Volumes` itself is the container of every disk, not a volume.
fn is_mounted_volume(path: &Path) -> bool {
    path.starts_with("/Volumes") && path.parent() == Some(Path::new("/Volumes"))
}

/// True when a dotfile is outside this scan, from the request's scope.
fn skips_hidden(context: &ScanContext<'_>) -> bool {
    !context.request.include_hidden_files
}

/// The grants a scan may use, as paths.
fn authorized_paths(context: &ScanContext<'_>) -> Vec<PathBuf> {
    context
        .request
        .authorized_roots
        .iter()
        .map(PathBuf::from)
        .collect()
}

/// The user's "never visit" list, as paths.
fn ignored_paths(context: &ScanContext<'_>) -> Vec<PathBuf> {
    context
        .request
        .ignore_paths
        .iter()
        .map(PathBuf::from)
        .collect()
}

/// Measured size of a directory tree, without producing per-file entries.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct Measured {
    pub bytes: u64,
    pub files: u64,
}

/// Measures a directory tree, stopping at package directories.
pub fn measure_directory(
    path: &Path,
    cancel: &CancelToken,
    home: &Path,
    authorized_roots: &[PathBuf],
    skip_hidden: bool,
    skip_paths: &[PathBuf],
) -> (Measured, WalkReport) {
    let mut options = WalkOptions::new(home.to_path_buf(), WalkMode::Files)
        .with_ignores(walker::DEFAULT_SKIP_DIRECTORY_NAMES);
    options.authorized_roots = authorized_roots.to_vec();
    options.skip_hidden = skip_hidden;
    options.skip_paths = skip_paths.to_vec();
    options.stop_at_packages = true;
    skip_excluded_directories(&mut options);
    let _ = &mut options;
    let report = walker::walk(path, &options, cancel);
    let measured = Measured {
        bytes: report.total_bytes,
        files: report.total_files,
    };
    (measured, report)
}

/// Runs every enabled rule and returns its candidates.
pub fn scan_rules(
    context: &mut ScanContext<'_>,
    cancel: &CancelToken,
) -> (Vec<Candidate>, WalkReport) {
    let mut candidates = Vec::new();
    let mut skips = WalkReport::default();
    let rules = context.rules.clone();
    let grants = authorized_paths(context);
    let user_temp = user_temp_root(context.request);

    for rule in &rules {
        if cancel.is_cancelled() {
            break;
        }
        // The "show hidden files" setting decides what a scan may see, so a rule
        // that lives inside a dot-directory is out of scope when it is off. The
        // walkers skip hidden *entries*; a rule's own relative path never reaches
        // them, so `~/.cache` was offered with the setting turned off — the one
        // shape where the scope was decided by which rule asked.
        if skips_hidden(context) && rule_has_hidden_component(rule) {
            continue;
        }
        for root in rule_roots(rule, &context.home_dir, &grants, user_temp.as_deref()) {
            if !root.exists() {
                continue;
            }

            // Authorised roots and external volumes are only scanned when the user
            // actually added them to the request.
            if !root_is_authorised(&root, context.request) {
                continue;
            }

            let (found, mut report) = scan_one_rule(rule, &root, context, cancel);
            candidates.extend(found);
            skips.skips.append(&mut report.skips);
            skips.total_files += report.total_files;
            skips.total_bytes += report.total_bytes;
            if report.cancelled || cancel.is_cancelled() {
                break;
            }
        }
    }

    let deduped = dedupe_parent_child(candidates);
    (deduped, skips)
}

/// True when the home directory sits inside a root marked cleanable.
fn home_is_cleanable(context: &ScanContext<'_>) -> bool {
    if context.request.roots.is_empty() {
        return true;
    }
    let home = context.home_dir.to_string_lossy().to_string();
    context.request.roots.iter().any(|root| {
        root.is_cleanable && (home == root.path || home.starts_with(&format!("{}/", root.path)))
    })
}

/// True when the rule's own relative path names a hidden directory.
///
/// `~/.cache`, `~/.gradle/caches`: the first component is a dot-entry, so the
/// whole subtree is what the "show hidden files" preference hides. Both engines
/// ask this the same way, because the answer decides whether a rule runs at all.
fn rule_has_hidden_component(rule: &Rule) -> bool {
    rule.relative_path
        .split('/')
        .any(|component| component.starts_with('.'))
}

/// The per-user temporary root the request named, if any.
///
/// It arrives as a scan root with `anchor: "userTemp"` because only the process
/// that owns the session can resolve it: `confstr` answers on the Swift side and
/// this core has no equivalent. Reading it from the root list also keeps it
/// inside the same authorisation the rest of the scan uses — a `userTemp` rule
/// cannot reach a directory the request did not name.
fn user_temp_root(request: &ScanRequest) -> Option<PathBuf> {
    request
        .roots
        .iter()
        .find(|root| root.anchor == RootAnchor::UserTemp.as_str())
        .map(|root| PathBuf::from(&root.path))
}

fn root_is_authorised(root: &Path, request: &ScanRequest) -> bool {
    if !root.is_absolute() {
        return false;
    }
    if request.roots.is_empty() {
        // No explicit roots means the caller wants the standard home rules only.
        return true;
    }
    request
        .roots
        .iter()
        .any(|candidate| candidate.is_cleanable && root.starts_with(&candidate.path))
}

fn scan_one_rule(
    rule: &Rule,
    root: &Path,
    context: &mut ScanContext<'_>,
    cancel: &CancelToken,
) -> (Vec<Candidate>, WalkReport) {
    let authorized: Vec<PathBuf> = context
        .request
        .authorized_roots
        .iter()
        .map(PathBuf::from)
        .collect();
    if is_protected_path_authorized(
        &context.home_dir.to_string_lossy(),
        &root.to_string_lossy(),
        &authorized,
    ) {
        return (Vec::new(), WalkReport::default());
    }
    // A rule root that is a container is not a cleanup item: `~/Library` is a
    // container, and moving it would take every application's data with it.
    if is_cleanup_container(root, &context.home_dir) {
        return (Vec::new(), WalkReport::default());
    }

    match rule.effective_match_spec() {
        MatchSpec::Directory => (
            directory_candidate(rule, root, context, cancel)
                .into_iter()
                .collect(),
            WalkReport::default(),
        ),
        MatchSpec::ChildDirectories => {
            child_directory_candidates(rule, root, None, context, cancel)
        }
        MatchSpec::DirectoriesNamed { names } => {
            child_directory_candidates(rule, root, Some(&names), context, cancel)
        }
        MatchSpec::FilesByExtension { extensions } => {
            file_candidates(rule, root, &extensions, true, context, cancel)
        }
        MatchSpec::AnyFile => file_candidates(rule, root, &[], false, context, cancel),
    }
}

/// The risk an item from `rule` carries in this scan.
///
/// A rule that says its items belong to one application (`needs_app_closed`)
/// loses the `safe` level while that application is running. The item is still
/// offered, so the user keeps the decision; it is simply no longer pre-selected.
/// The rule's own level is the ceiling: a rule that is already `review` stays
/// `review`, and one the loader refused keeps the level that refused it.
fn candidate_risk(rule: &Rule, path: &Path, request: &ScanRequest) -> Risk {
    if rule.risk == Risk::Safe
        && rule.needs_app_closed
        && running_app_owns_path(&path.to_string_lossy(), &request.running_app_tokens)
    {
        return Risk::Review;
    }
    rule.risk
}

fn directory_candidate(
    rule: &Rule,
    path: &Path,
    context: &mut ScanContext<'_>,
    cancel: &CancelToken,
) -> Option<Candidate> {
    let authorized: Vec<PathBuf> = context
        .request
        .authorized_roots
        .iter()
        .map(PathBuf::from)
        .collect();
    if is_protected_path_authorized(
        &context.home_dir.to_string_lossy(),
        &path.to_string_lossy(),
        &authorized,
    ) {
        return None;
    }
    if is_cleanup_container(path, &context.home_dir) {
        return None;
    }
    context.progress.note_path(path);
    let (measured, report, modified) = match rule
        .effective_min_age_days(context.request.stale_threshold_days)
    {
        // A `directory` rule with an age threshold has to mean the same thing in
        // both engines. Swift measured the directory through the filter from the
        // start; this side offered it whatever its files' ages were, so one
        // engine called a directory of fresh files a cleanup item and the other
        // did not. The move is whole, so the same rule as the child-directory
        // case applies: the threshold may decide eligibility, never which files
        // move, and a mixed directory is therefore not a cleanup item.
        Some(min_age_days) => {
            let matching = measure_directory_matching(
                path,
                cancel,
                &context.home_dir,
                &authorized,
                skips_hidden(context),
                &ignored_paths(context),
                &|modified| older_than_days(modified, min_age_days),
            );
            let (whole, report) = measure_directory(
                path,
                cancel,
                &context.home_dir,
                &authorized,
                skips_hidden(context),
                &ignored_paths(context),
            );
            if matching.bytes == 0 || matching.bytes != whole.bytes || matching.files != whole.files
            {
                return None;
            }
            let oldest = oldest_matching_modified_secs(
                path,
                cancel,
                &context.home_dir,
                &authorized,
                skips_hidden(context),
                min_age_days,
            );
            if oldest == 0 {
                return None;
            }
            (whole, report, oldest)
        }
        None => {
            let (measured, report) = measure_directory(
                path,
                cancel,
                &context.home_dir,
                &authorized,
                skips_hidden(context),
                &ignored_paths(context),
            );
            let metadata = std::fs::symlink_metadata(path).ok()?;
            (measured, report, modified_secs(&metadata))
        }
    };
    context
        .progress
        .note_files(report.total_files, report.total_bytes);
    let metadata = std::fs::symlink_metadata(path).ok()?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        // A `directory` rule whose relative path names a file used to produce a
        // zero-byte item labelled as a directory.
        return None;
    }
    let risk = candidate_risk(rule, path, context.request);
    Some(Candidate {
        path: path.to_path_buf(),
        display_name: path
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_else(|| path.to_string_lossy().to_string()),
        parent_path: path
            .parent()
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_default(),
        category: rule.category,
        risk,
        size_bytes: measured.bytes,
        file_count: measured.files,
        modified_secs: modified,
        created_secs: created_secs(&metadata),
        explanation_key: rule.explanation_key.clone(),
        rule_id: rule.id.clone(),
        bundle_id: None,
        is_directory: true,
        selected_by_default: risk == Risk::Safe,
        note: None,
    })
}

/// Child-directory candidates, optionally restricted to a set of names.
///
/// `names` is what `directoriesNamed` adds: the walk is the same, and only the
/// directory's own name decides without changing anything else about how the
/// item is measured, aged or excluded.
fn child_directory_candidates(
    rule: &Rule,
    root: &Path,
    names: Option<&[String]>,
    context: &mut ScanContext<'_>,
    cancel: &CancelToken,
) -> (Vec<Candidate>, WalkReport) {
    let mut options = WalkOptions::new(context.home_dir.clone(), WalkMode::ImmediateChildren);
    options.max_depth = Some(1);
    options.authorized_roots = authorized_paths(context);
    options.skip_directory_names = walker::DEFAULT_SKIP_DIRECTORY_NAMES
        .iter()
        .map(|s| (*s).to_string())
        .collect();
    skip_excluded_directories(&mut options);
    options.skip_paths = context
        .request
        .ignore_paths
        .iter()
        .map(PathBuf::from)
        .collect();
    options.skip_hidden = skips_hidden(context);

    // The user's stale threshold governs a rule that opted into it (§5.2); every
    // other rule keeps the age its own definition states.
    let min_age_days = rule.effective_min_age_days(context.request.stale_threshold_days);

    let report = walker::walk(root, &options, cancel);
    let mut candidates = Vec::new();

    for entry in &report.entries {
        if !entry.is_directory {
            continue;
        }
        if let Some(names) = names {
            // The name is the whole point of the specification, so it is checked
            // before anything is measured.
            if !names
                .iter()
                .any(|name| entry.display_name().eq_ignore_ascii_case(name))
            {
                continue;
            }
        }
        if cancelled_or_excluded(entry, rule, root, context) {
            continue;
        }
        // A child that is a container (a `home` rule with an empty relative
        // path used to report `~/Library`) is never a single item.
        if is_cleanup_container(&entry.path, &context.home_dir) {
            continue;
        }

        context.progress.note_path(&entry.path);

        // With an age threshold the directory is measured through the filter, so
        // the reported size is exactly the reclaimable part. Filtering on the
        // directory's own mtime would be wrong: creating one fresh log inside it
        // would hide every stale log sitting next to it.
        let measured = match min_age_days {
            Some(min_age_days) => {
                let authorized: Vec<PathBuf> = context
                    .request
                    .authorized_roots
                    .iter()
                    .map(PathBuf::from)
                    .collect();
                let matching = measure_directory_matching(
                    &entry.path,
                    cancel,
                    &context.home_dir,
                    &authorized,
                    skips_hidden(context),
                    &ignored_paths(context),
                    &|modified| older_than_days(modified, min_age_days),
                );
                // The item is the directory, so moving it takes every file in
                // it. The age filter may only decide eligibility, never which
                // files move: a directory with one stale file next to fresh
                // ones is not a cleanup item, because the move would take the
                // fresh files too.
                let (whole, _) = measure_directory(
                    &entry.path,
                    cancel,
                    &context.home_dir,
                    &authorized,
                    skips_hidden(context),
                    &ignored_paths(context),
                );
                if matching.bytes != whole.bytes || matching.files != whole.files {
                    continue;
                }
                whole
            }
            None => {
                let authorized: Vec<PathBuf> = context
                    .request
                    .authorized_roots
                    .iter()
                    .map(PathBuf::from)
                    .collect();
                measure_directory(
                    &entry.path,
                    cancel,
                    &context.home_dir,
                    &authorized,
                    skips_hidden(context),
                    &ignored_paths(context),
                )
                .0
            }
        };
        context.progress.note_files(measured.files, measured.bytes);

        if measured.bytes == 0 {
            // Nothing to reclaim: an empty directory, or a directory whose files
            // are all still fresh, is not a cleanup item.
            continue;
        }

        let modified = match min_age_days {
            // The oldest surviving file is what the explanation reports.
            Some(min_age_days) => {
                let authorized: Vec<PathBuf> = context
                    .request
                    .authorized_roots
                    .iter()
                    .map(PathBuf::from)
                    .collect();
                oldest_matching_modified_secs(
                    &entry.path,
                    cancel,
                    &context.home_dir,
                    &authorized,
                    skips_hidden(context),
                    min_age_days,
                )
            }
            None => entry.modified_secs,
        };
        if min_age_days.is_some() && modified == 0 {
            continue;
        }

        let risk = candidate_risk(rule, &entry.path, context.request);
        candidates.push(Candidate {
            path: entry.path.clone(),
            display_name: entry.display_name(),
            parent_path: entry.parent_path(),
            category: rule.category,
            risk,
            size_bytes: measured.bytes,
            file_count: measured.files,
            modified_secs: modified,
            created_secs: entry.created_secs,
            explanation_key: rule.explanation_key.clone(),
            rule_id: rule.id.clone(),
            bundle_id: None,
            is_directory: true,
            selected_by_default: risk == Risk::Safe,
            note: None,
        });
    }

    (candidates, report)
}

fn file_candidates(
    rule: &Rule,
    root: &Path,
    extensions: &[String],
    filter_by_extension: bool,
    context: &mut ScanContext<'_>,
    cancel: &CancelToken,
) -> (Vec<Candidate>, WalkReport) {
    let mut options = WalkOptions::new(context.home_dir.clone(), WalkMode::Files);
    options.authorized_roots = authorized_paths(context);
    options.skip_directory_names = walker::DEFAULT_SKIP_DIRECTORY_NAMES
        .iter()
        .map(|s| (*s).to_string())
        .collect();
    skip_excluded_directories(&mut options);
    options.skip_paths = context
        .request
        .ignore_paths
        .iter()
        .map(PathBuf::from)
        .collect();
    options.skip_hidden = skips_hidden(context);

    // Same rule as the directory case above: only a rule that opted into the
    // stale threshold reads its age from the request.
    let min_age_days = rule.effective_min_age_days(context.request.stale_threshold_days);

    let report = walker::walk(root, &options, cancel);
    let mut candidates = Vec::new();

    for entry in &report.entries {
        if entry.is_directory {
            continue;
        }
        if cancelled_or_excluded(entry, rule, root, context) {
            continue;
        }
        if filter_by_extension && !has_extension(entry, extensions) {
            continue;
        }
        if let Some(min_age_days) = min_age_days {
            if !older_than_days(entry.modified_secs, min_age_days) {
                continue;
            }
        }
        context.progress.note_path(&entry.path);
        let risk = candidate_risk(rule, &entry.path, context.request);
        candidates.push(Candidate {
            path: entry.path.clone(),
            display_name: entry.display_name(),
            parent_path: entry.parent_path(),
            category: rule.category,
            risk,
            size_bytes: entry.size_bytes.unwrap_or(0),
            file_count: 1,
            modified_secs: entry.modified_secs,
            created_secs: entry.created_secs,
            explanation_key: rule.explanation_key.clone(),
            rule_id: rule.id.clone(),
            bundle_id: None,
            is_directory: false,
            selected_by_default: risk == Risk::Safe,
            note: None,
        });
    }

    (candidates, report)
}

/// Measures a directory tree while keeping only the files a predicate accepts.
///
/// Age thresholds belong to files, not directories: `~/Library/Logs/<app>` may
/// hold both a week-old and a year-old log, and only the stale one is a cleanup
/// item. A directory-level filter would either drop the whole folder or offer
/// files that are still in use.
pub fn measure_directory_matching(
    path: &Path,
    cancel: &CancelToken,
    home: &Path,
    authorized_roots: &[PathBuf],
    skip_hidden: bool,
    skip_paths: &[PathBuf],
    accept_file: &dyn Fn(i64) -> bool,
) -> Measured {
    let mut measured = Measured::default();
    // The skip list is a loop invariant; normalise it once for the whole walk.
    let normalized_skips = walker::normalize_skip_paths(skip_paths);
    let mut stack = vec![path.to_path_buf()];
    let root_device = std::fs::symlink_metadata(path)
        .ok()
        .map(|metadata| walker::device_of(&metadata));
    // One deadline covers the whole measurement: a directory that never
    // answers contributes nothing instead of stalling the candidate it is
    // being measured for.
    let mut lister = DirLister::new();
    while let Some(directory) = stack.pop() {
        if cancel.is_cancelled() {
            return measured;
        }
        let entries = match lister.list(&directory, MEASURE_OPEN_TIMEOUT, cancel) {
            Ok(Some(entries)) => entries,
            Ok(None) | Err(_) => continue,
        };
        for entry_path in entries {
            let Ok(metadata) = std::fs::symlink_metadata(&entry_path) else {
                continue;
            };
            if metadata.file_type().is_symlink() {
                continue;
            }
            if root_device.is_some_and(|device| walker::device_of(&metadata) != device) {
                // A mount point below the directory belongs to another volume.
                continue;
            }
            if skip_hidden && is_hidden_name(&entry_path) {
                continue;
            }
            if walker::is_skipped_normalized(&entry_path, &normalized_skips) {
                continue;
            }
            if is_in_excluded_location(&entry_path) {
                continue;
            }
            if metadata.is_dir() {
                stack.push(entry_path);
                continue;
            }
            if !metadata.is_file() {
                continue;
            }
            if is_protected_path_authorized(
                &home.to_string_lossy(),
                &entry_path.to_string_lossy(),
                authorized_roots,
            ) {
                continue;
            }
            if !accept_file(modified_secs(&metadata)) {
                continue;
            }
            measured.bytes += walker::allocated_size(&metadata);
            measured.files += 1;
        }
    }
    measured
}

/// Modification time of the oldest file that satisfies the age threshold.
fn oldest_matching_modified_secs(
    path: &Path,
    cancel: &CancelToken,
    home: &Path,
    authorized_roots: &[PathBuf],
    skip_hidden: bool,
    min_age_days: u32,
) -> i64 {
    let mut stack = vec![path.to_path_buf()];
    let root_device = std::fs::symlink_metadata(path)
        .ok()
        .map(|metadata| walker::device_of(&metadata));
    let mut oldest: i64 = 0;
    let mut lister = DirLister::new();
    while let Some(directory) = stack.pop() {
        if cancel.is_cancelled() {
            break;
        }
        let entries = match lister.list(&directory, MEASURE_OPEN_TIMEOUT, cancel) {
            Ok(Some(entries)) => entries,
            Ok(None) | Err(_) => continue,
        };
        for entry_path in entries {
            let Ok(metadata) = std::fs::symlink_metadata(&entry_path) else {
                continue;
            };
            if metadata.file_type().is_symlink() {
                continue;
            }
            if root_device.is_some_and(|device| walker::device_of(&metadata) != device) {
                // A mount point below the directory belongs to another volume.
                continue;
            }
            if skip_hidden && is_hidden_name(&entry_path) {
                continue;
            }
            if metadata.is_dir() {
                stack.push(entry_path);
                continue;
            }
            if is_protected_path_authorized(
                &home.to_string_lossy(),
                &entry_path.to_string_lossy(),
                authorized_roots,
            ) {
                continue;
            }
            let modified = modified_secs(&metadata);
            if !older_than_days(modified, min_age_days) {
                continue;
            }
            if oldest == 0 || modified < oldest {
                oldest = modified;
            }
        }
    }
    oldest
}

fn cancelled_or_excluded(
    entry: &WalkEntry,
    rule: &Rule,
    root: &Path,
    context: &ScanContext<'_>,
) -> bool {
    let authorized: Vec<PathBuf> = context
        .request
        .authorized_roots
        .iter()
        .map(PathBuf::from)
        .collect();
    if is_protected_path_authorized(
        &context.home_dir.to_string_lossy(),
        &entry.path.to_string_lossy(),
        &authorized,
    ) {
        return true;
    }
    // Excluding a directory excludes its subtree. Checking only the entry's own
    // name let a file inside `~/Library/Caches/CloudKit` through whenever the
    // rule matched files rather than directories.
    if is_in_excluded_location(&entry.path) {
        return true;
    }
    is_excluded_by_rule(rule, &entry.path, root)
}

/// True when any component of `path` is an excluded application's data.
pub fn is_in_excluded_location(path: &Path) -> bool {
    path.components()
        .any(|component| is_excluded_bundle_name(&component.as_os_str().to_string_lossy()))
}

/// True when a rule's `excludes` covers any component below its root.
fn is_excluded_by_rule(rule: &Rule, path: &Path, root: &Path) -> bool {
    let Ok(relative) = path.strip_prefix(root) else {
        return false;
    };
    relative
        .components()
        .any(|component| exclude_matches(&rule.excludes, &component.as_os_str().to_string_lossy()))
}

/// True when a directory name is on a rule's `excludes` list.
///
/// A name matches whole, or as the prefix of a bundle identifier (`com.apple`
/// covers `com.apple.Safari` but not `com.appleby`), which is the same
/// comparison the excluded-application list uses.
fn exclude_matches(excludes: &[String], name: &str) -> bool {
    excludes
        .iter()
        .any(|exclude| name == exclude.as_str() || name.starts_with(&format!("{exclude}.")))
}

/// Adds the never-clean bundle directories to a walk's skip list.
///
/// The entries would otherwise be visited and filtered later, which still spends
/// the walk on a tree no candidate may come from. The same names are skipped by
/// the Swift walker.
fn skip_excluded_directories(options: &mut WalkOptions) {
    options.skip_directory_names.extend(
        EXCLUDED_BUNDLE_IDENTIFIERS
            .iter()
            .map(|name| (*name).to_string()),
    );
}

fn has_extension(entry: &WalkEntry, extensions: &[String]) -> bool {
    match entry.path.extension() {
        Some(ext) => {
            let ext = ext.to_string_lossy().to_ascii_lowercase();
            extensions.iter().any(|wanted| wanted == &ext)
        }
        None => false,
    }
}

/// True when the path's last component starts with `.`.
fn is_hidden_name(path: &Path) -> bool {
    path.file_name()
        .map(|name| name.to_string_lossy().starts_with('.'))
        .unwrap_or(false)
}

fn older_than_days(modified_secs: i64, days: u32) -> bool {
    if modified_secs <= 0 {
        return false;
    }
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    now.saturating_sub(modified_secs) >= (days as i64) * 86_400
}

fn modified_secs(metadata: &std::fs::Metadata) -> i64 {
    metadata
        .modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn created_secs(metadata: &std::fs::Metadata) -> i64 {
    metadata
        .created()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64)
        .unwrap_or_else(|| modified_secs(metadata))
}

/// Large files: every file at or above the threshold inside the scan roots.
pub fn scan_large_files(
    context: &mut ScanContext<'_>,
    cancel: &CancelToken,
    threshold_bytes: u64,
) -> (Vec<Candidate>, WalkReport) {
    file_threshold_scan(
        context,
        cancel,
        FileThreshold::Large {
            bytes: threshold_bytes,
        },
    )
}

/// Old files: unchanged for at least `days`, above a usefulness floor.
pub fn scan_old_files(
    context: &mut ScanContext<'_>,
    cancel: &CancelToken,
    days: u32,
) -> (Vec<Candidate>, WalkReport) {
    file_threshold_scan(context, cancel, FileThreshold::Old { days })
}

enum FileThreshold {
    Large { bytes: u64 },
    Old { days: u32 },
}

/// Home-relative subtrees the generic large-file and old-file scans must not
/// walk.
///
/// These hold live user data rather than disposable copies: an iOS backup is a
/// set of interdependent chunks, a contacts or calendar store is an SQLite
/// database, and a group container is an application's shared state. Offering
/// one file from them as a "large file" and moving it silently corrupts the
/// database even though the Trash makes the bytes recoverable. The rule scan
/// and the residue scan keep their own targeted access to these locations;
/// this list only narrows the two threshold scans.
pub const THRESHOLD_EXCLUDED_HOME_PATHS: &[&str] = &[
    "Library/Application Support/AddressBook",
    "Library/Application Support/MobileSync",
    "Library/Application Support/com.apple.sharedfilelist",
    "Library/Application Support/Knowledge",
    "Library/Calendars",
    "Library/Reminders",
    "Library/Containers",
    "Library/Group Containers",
    "Library/Photos",
];

fn threshold_excluded_paths(home: &Path) -> Vec<PathBuf> {
    THRESHOLD_EXCLUDED_HOME_PATHS
        .iter()
        .map(|relative| home.join(relative))
        .collect()
}

fn file_threshold_scan(
    context: &mut ScanContext<'_>,
    cancel: &CancelToken,
    threshold: FileThreshold,
) -> (Vec<Candidate>, WalkReport) {
    let mut candidates = Vec::new();
    let mut combined = WalkReport::default();

    // A root the caller marked measure-only contributes nothing to a cleanup
    // queue: it is scanned for storage totals, never for candidates.
    let mut roots: Vec<(PathBuf, Option<u32>)> = context
        .request
        .roots
        .iter()
        .filter(|root| root.is_cleanable && root.includes_threshold_files)
        .map(|root| (PathBuf::from(&root.path), root.max_depth))
        .collect();
    // A granted folder inside the home directory is covered by the home root.
    // Walking both would offer the same file twice. The max depth travels with
    // the root: the Swift fallback limits its walk, and the two engines must
    // offer the same deep files.
    roots.sort_by(|(left, _), (right, _)| {
        left.components()
            .count()
            .cmp(&right.components().count())
            .then_with(|| left.cmp(right))
    });
    let mut collapsed: Vec<(PathBuf, Option<u32>)> = Vec::with_capacity(roots.len());
    for (root, max_depth) in roots {
        if collapsed
            .iter()
            .any(|(parent, _)| is_prefix_of(&parent.to_string_lossy(), &root.to_string_lossy()))
        {
            continue;
        }
        collapsed.push((root, max_depth));
    }
    let mut seen_paths: HashSet<PathBuf> = HashSet::new();
    // A root marked `includesThresholdFiles: false` must stay out even when
    // another root contains it: collapsing `~/RulesOnly` into `~` would
    // otherwise walk the very tree the flag excluded.
    let threshold_excluded_roots: Vec<PathBuf> = context
        .request
        .roots
        .iter()
        .filter(|root| !root.includes_threshold_files)
        .map(|root| PathBuf::from(&root.path))
        .collect();

    for (root, max_depth) in collapsed {
        let mut options = WalkOptions::new(context.home_dir.clone(), WalkMode::Files);
        options.max_depth = max_depth;
        options.authorized_roots = authorized_paths(context);
        options.skip_directory_names = walker::DEFAULT_SKIP_DIRECTORY_NAMES
            .iter()
            .map(|s| (*s).to_string())
            .collect();
        options.skip_paths = context
            .request
            .ignore_paths
            .iter()
            .map(PathBuf::from)
            .collect();
        options
            .skip_paths
            .extend(threshold_excluded_roots.iter().cloned());
        options
            .skip_paths
            .extend(threshold_excluded_paths(&context.home_dir));
        options.skip_hidden = skips_hidden(context);

        let report = walker::walk(&root, &options, cancel);
        combined.total_files += report.total_files;
        combined.total_bytes += report.total_bytes;
        combined.truncated |= report.truncated;
        combined.cancelled |= report.cancelled;
        combined.skips.extend(report.skips.iter().cloned());

        for entry in &report.entries {
            if entry.is_directory {
                continue;
            }
            if is_in_excluded_location(&entry.path) {
                continue;
            }
            if !seen_paths.insert(entry.path.clone()) {
                continue;
            }
            let size = entry.size_bytes.unwrap_or(0);
            let (category, rule_id, explanation_key, age_ok) = match threshold {
                FileThreshold::Large { bytes } => (
                    Category::LargeFiles,
                    "large-files",
                    "cleanup.explanation.largeFilesItem",
                    size >= bytes,
                ),
                FileThreshold::Old { days } => (
                    Category::OldFiles,
                    "old-files",
                    "cleanup.explanation.oldFilesItem",
                    // Small files are excluded: cleaning thousands of 4 KB files
                    // is noise, not space recovery.
                    size >= 10 * 1024 * 1024 && older_than_days(entry.modified_secs, days),
                ),
            };
            if !age_ok {
                continue;
            }
            let authorized: Vec<PathBuf> = context
                .request
                .authorized_roots
                .iter()
                .map(PathBuf::from)
                .collect();
            if is_protected_path_authorized(
                &context.home_dir.to_string_lossy(),
                &entry.path.to_string_lossy(),
                &authorized,
            ) {
                continue;
            }
            context.progress.note_path(&entry.path);
            candidates.push(Candidate {
                path: entry.path.clone(),
                display_name: entry.display_name(),
                parent_path: entry.parent_path(),
                category,
                risk: Risk::Review,
                size_bytes: size,
                file_count: 1,
                modified_secs: entry.modified_secs,
                created_secs: entry.created_secs,
                explanation_key: explanation_key.to_string(),
                rule_id: rule_id.to_string(),
                bundle_id: None,
                is_directory: false,
                selected_by_default: false,
                note: None,
            });
        }
        if combined.cancelled {
            break;
        }
    }

    // Largest first: the UI shows a bounded list and users act on the top.
    candidates.sort_unstable_by_key(|candidate| std::cmp::Reverse(candidate.size_bytes));
    combined.entries.clear();
    (candidates, combined)
}

/// Application residue, discovered strictly through bundle identifiers.
///
/// A directory is residue only when its name matches the bundle identifier of an
/// app that is **not** installed. Fuzzy name matching is deliberately absent:
/// `~/Library/Application Support/Editor` must never be classified as residue
/// because some app is called "Editor".
///
/// This is the only thing that decides residue. A rule in the shipped table
/// cannot: it can match a name shape or an age, and neither knows whether the
/// application is still installed, so a rule over `Application Support` offered
/// the live data of installed applications as leftover (§`default_rules`).
pub fn scan_application_residue(
    context: &mut ScanContext<'_>,
    cancel: &CancelToken,
) -> (Vec<Candidate>, WalkReport) {
    // Residue is derived from the home directory, so it inherits that root's
    // policy: a measure-only home contributes no cleanup candidates. An empty
    // installed list is not "no applications": every Mac has system bundles, so
    // it means discovery failed, and without that list every live container
    // would be reported as belonging to an uninstalled application.
    if !home_is_cleanable(context) || context.request.installed_bundle_ids.is_empty() {
        return (Vec::new(), WalkReport::default());
    }
    let mut candidates = Vec::new();
    let mut combined = WalkReport::default();
    let installed: Vec<String> = context
        .request
        .installed_bundle_ids
        .iter()
        .map(|id| id.to_ascii_lowercase())
        .collect();

    // Where residue may live, mirroring the specification's association list.
    //
    // `Library/Containers` is here rather than in a rule because a sandboxed
    // application's container is its whole data directory: it may only be offered
    // when the application it belongs to is gone.
    let residue_locations: &[(&str, Category, Risk)] = &[
        (
            "Library/Application Support",
            Category::ApplicationResidue,
            Risk::Review,
        ),
        ("Library/Caches", Category::ApplicationResidue, Risk::Review),
        (
            "Library/Containers",
            Category::ApplicationResidue,
            Risk::Review,
        ),
        ("Library/Logs", Category::ApplicationResidue, Risk::Safe),
        (
            "Library/Saved Application State",
            Category::ApplicationResidue,
            Risk::Review,
        ),
    ];

    for (relative, category, risk) in residue_locations {
        if cancel.is_cancelled() {
            combined.cancelled = true;
            break;
        }
        let directory = context.home_dir.join(relative);
        if !directory.is_dir() {
            continue;
        }
        let mut options = WalkOptions::new(context.home_dir.clone(), WalkMode::ImmediateChildren)
            .with_max_depth(1);
        options.authorized_roots = authorized_paths(context);
        options.skip_hidden = skips_hidden(context);
        let report = walker::walk(&directory, &options, cancel);
        combined.skips.extend(report.skips.iter().cloned());

        for entry in &report.entries {
            if !entry.is_directory {
                continue;
            }
            let name = entry.display_name();
            if is_excluded_bundle_name(&name) {
                continue;
            }
            if !looks_like_bundle_identifier(&name) {
                continue;
            }
            if installed.iter().any(|id| *id == name.to_ascii_lowercase()) {
                continue;
            }
            let authorized: Vec<PathBuf> = context
                .request
                .authorized_roots
                .iter()
                .map(PathBuf::from)
                .collect();
            if is_protected_path_authorized(
                &context.home_dir.to_string_lossy(),
                &entry.path.to_string_lossy(),
                &authorized,
            ) {
                continue;
            }
            // Measured whole and without the hidden filter: the item is the
            // directory, and trashing it takes the dotfiles inside it as well.
            let (measured, inner) = measure_directory(
                &entry.path,
                cancel,
                &context.home_dir,
                &authorized,
                false,
                &ignored_paths(context),
            );
            if measured.bytes == 0 {
                continue;
            }
            context
                .progress
                .note_files(inner.total_files, inner.total_bytes);
            candidates.push(Candidate {
                path: entry.path.clone(),
                display_name: name.clone(),
                parent_path: entry.parent_path(),
                category: *category,
                risk: *risk,
                size_bytes: measured.bytes,
                file_count: measured.files,
                modified_secs: entry.modified_secs,
                created_secs: entry.created_secs,
                explanation_key: "cleanup.explanation.residue".to_string(),
                rule_id: "app-residue".to_string(),
                bundle_id: Some(name),
                is_directory: true,
                selected_by_default: false,
                note: Some(
                    "No matching application is installed; confirm before removing.".to_string(),
                ),
            });
        }

        // `~/Library/Preferences/<bundle-id>.plist` and
        // `~/Library/Logs/<app>` style single files are handled below.
    }

    // `~/Library/Group Containers/<team-id>.<bundle-id>` belongs to an
    // application that is gone when the bundle identifier after the team prefix
    // names no installed application.
    //
    // The name is accepted in either spelling, because macOS writes both: the
    // App Store style `TEAMID.com.example.app` (the team prefix has no dots) and
    // the name that is already a bundle identifier, `com.example.app`. What is
    // *not* accepted is a name that is neither, so a container with a bare name
    // is left alone.
    //
    // An app group is the second way a container stays in use: the group it is
    // named after is declared in some installed application's entitlements, and
    // then the name resolves to nothing even though the container is live. That
    // set arrives in the request (this core does not read signatures); it is
    // checked before the readings because it is a statement about the system
    // rather than about how a name is spelled.
    let declared_groups: Vec<String> = context
        .request
        .app_group_ids
        .iter()
        .map(|id| id.to_ascii_lowercase())
        .collect();
    let group_containers = context.home_dir.join("Library/Group Containers");
    // Only with a complete list of declared groups: this block's question is "is
    // no application using this container", and a set that was cut short answers
    // "no" for every container whose owner was not read — which is how a live
    // container becomes a cleanup row.
    if group_containers.is_dir() && context.request.app_group_ids_complete {
        let mut options = WalkOptions::new(context.home_dir.clone(), WalkMode::ImmediateChildren)
            .with_max_depth(1);
        options.authorized_roots = authorized_paths(context);
        options.skip_hidden = skips_hidden(context);
        let report = walker::walk(&group_containers, &options, cancel);
        for entry in &report.entries {
            if !entry.is_directory {
                continue;
            }
            let name = entry.display_name();
            if is_excluded_bundle_name(&name) {
                continue;
            }
            let lowered_name = name.to_ascii_lowercase();
            if declared_groups.contains(&lowered_name) {
                continue;
            }
            let readings = group_container_bundle_ids(&name);
            if readings
                .iter()
                .any(|id| installed.iter().any(|app| app == id))
            {
                continue;
            }
            let Some(bundle_id) = readings
                .into_iter()
                .find(|id| looks_like_bundle_identifier(id))
            else {
                // A name in neither spelling. The specification says to
                // associate a group container only when the rule is
                // unambiguous, so it is left alone.
                continue;
            };
            let authorized: Vec<PathBuf> = context
                .request
                .authorized_roots
                .iter()
                .map(PathBuf::from)
                .collect();
            if is_protected_path_authorized(
                &context.home_dir.to_string_lossy(),
                &entry.path.to_string_lossy(),
                &authorized,
            ) {
                continue;
            }
            // Whole, as above: the container is the item.
            let (measured, inner) = measure_directory(
                &entry.path,
                cancel,
                &context.home_dir,
                &authorized,
                false,
                &ignored_paths(context),
            );
            if measured.bytes == 0 {
                continue;
            }
            context
                .progress
                .note_files(inner.total_files, inner.total_bytes);
            candidates.push(Candidate {
                path: entry.path.clone(),
                display_name: name,
                parent_path: entry.parent_path(),
                category: Category::GroupContainerResidue,
                risk: Risk::Review,
                size_bytes: measured.bytes,
                file_count: measured.files,
                modified_secs: entry.modified_secs,
                created_secs: entry.created_secs,
                explanation_key: "cleanup.explanation.residueGroupContainer".to_string(),
                rule_id: "app-residue-group-containers".to_string(),
                bundle_id: Some(bundle_id),
                is_directory: true,
                selected_by_default: false,
                note: Some("Shared container of an uninstalled application.".to_string()),
            });
        }
    }

    // Preference files are matched on the full `<bundle-id>.plist` name.
    for prefix in ["Library/Preferences", "Library/HTTPStorages"] {
        let directory = context.home_dir.join(prefix);
        if !directory.is_dir() {
            continue;
        }
        // One loop over both directories, but not one sentence: a preference file
        // and a web-storage file are different things to the user deciding
        // whether to remove them.
        let (explanation_key, note) = if prefix.ends_with("HTTPStorages") {
            (
                "cleanup.explanation.residueWebStorage",
                "Web storage for an application that is no longer installed.",
            )
        } else {
            (
                "cleanup.explanation.residuePreferences",
                "Preference file without an installed matching application.",
            )
        };
        let mut options =
            WalkOptions::new(context.home_dir.clone(), WalkMode::Files).with_max_depth(1);
        options.authorized_roots = authorized_paths(context);
        options.skip_hidden = skips_hidden(context);
        let report = walker::walk(&directory, &options, cancel);
        for entry in &report.entries {
            let name = entry.display_name();
            let stem = name
                .strip_suffix(".plist")
                .or_else(|| name.strip_suffix(".binarycookies"))
                .unwrap_or(&name);
            // The never-clean list applies here as well: a preference file of
            // an excluded system service is not residue. The Swift engine
            // already checks it, and both engines must agree on the row.
            if is_excluded_bundle_name(stem) {
                continue;
            }
            if !looks_like_bundle_identifier(stem) {
                continue;
            }
            if installed.iter().any(|id| *id == stem.to_ascii_lowercase()) {
                continue;
            }
            candidates.push(Candidate {
                path: entry.path.clone(),
                display_name: name.clone(),
                parent_path: entry.parent_path(),
                category: Category::ApplicationResidue,
                risk: Risk::Review,
                size_bytes: entry.size_bytes.unwrap_or(0),
                file_count: 1,
                modified_secs: entry.modified_secs,
                created_secs: entry.created_secs,
                explanation_key: explanation_key.to_string(),
                rule_id: "app-residue-preferences".to_string(),
                bundle_id: Some(stem.to_string()),
                is_directory: false,
                selected_by_default: false,
                note: Some(note.to_string()),
            });
        }
    }

    (candidates, combined)
}

/// Bundle identifiers whose data is never offered for cleanup, whatever rule
/// reaches it. These hold state that is expensive or impossible to rebuild
/// (iCloud sync databases, keychain scaffolding), so the exclusion is applied
/// per directory name rather than per rule.
pub const EXCLUDED_BUNDLE_IDENTIFIERS: &[&str] = &[
    "CloudKit",
    "com.apple.bird",
    "com.apple.iCloud",
    "com.apple.cloudd",
    "FamilyCircle",
    "com.apple.security.cloudkeychainproxy",
];

/// True when a directory name is on the never-clean list.
pub fn is_excluded_bundle_name(name: &str) -> bool {
    EXCLUDED_BUNDLE_IDENTIFIERS
        .iter()
        .any(|excluded| name.eq_ignore_ascii_case(excluded))
}

/// The bundle identifiers the name of a group container could stand for.
///
/// macOS writes a group container as `<team-id>.<bundle-id>`, where the team id
/// carries no dot — which is what makes splitting on the first dot safe — or as
/// the bundle identifier on its own, and an app group may add a leading `group.`.
/// The readings come in the order the caller prefers to report them — the part
/// after a dot-free first component, then the whole name — and in lower case,
/// because the caller compares *every* reading against the installed
/// applications.
///
/// That comparison is the point of the list. Deciding on one reading alone is how
/// a shared container of an installed application gets offered for removal: the
/// App Store spelling `TEAMID.com.example.app` never equals an installed
/// identifier, so the reading that does name the application has to be consulted
/// as well.
fn group_container_bundle_ids(name: &str) -> Vec<String> {
    let lowered = name.to_ascii_lowercase();
    let mut readings = Vec::new();
    if let Some((prefix, suffix)) = lowered.split_once('.') {
        if !prefix.contains('.') && !suffix.is_empty() {
            readings.push(suffix.to_string());
        }
    }
    readings.push(lowered);
    readings
}

/// A name that can only come from a reverse-DNS identifier, never a folder a
/// user would plausibly have created themselves.
pub fn looks_like_bundle_identifier(name: &str) -> bool {
    let parts: Vec<&str> = name.split('.').collect();
    if parts.len() < 3 {
        return false;
    }
    let (tld, domain) = (parts[0], parts[1]);
    if tld.len() < 2 || domain.len() < 2 {
        return false;
    }
    if !tld.chars().all(|c| c.is_ascii_alphabetic()) {
        return false;
    }
    // Reject anything that reads like a person's folder name: spaces, or a
    // leading capitalised word followed by lowercase words without a domain.
    if name.contains(' ') {
        return false;
    }
    parts.iter().all(|part| {
        !part.is_empty()
            && part
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    })
}

/// Duplicate discovery.
///
/// The four stages are separated so each one can be unit tested and cancelled:
/// size grouping, sampling, full hashing, group formation.
pub struct DuplicateFinder<'a> {
    options: DuplicateOptions,
    cancel: &'a CancelToken,
    home_dir: PathBuf,
    authorized_roots: Vec<PathBuf>,
    /// Whether dotfiles are outside this run, from the request's scope.
    skip_hidden: bool,
    hashes_computed: u64,
}

/// A duplicate group ready for the index.
#[derive(Debug, Clone, PartialEq)]
pub struct DuplicateGroupResult {
    pub digest: String,
    pub size_bytes: u64,
    pub members: Vec<GroupMemberRow>,
    pub reclaimable_bytes: u64,
}

/// Outcome of the duplicate stage.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct DuplicateReport {
    pub groups: Vec<DuplicateGroupResult>,
    pub candidates_considered: u64,
    pub full_hashes: u64,
    pub truncated: bool,
    pub cancelled: bool,
}

impl<'a> DuplicateFinder<'a> {
    pub fn new(
        options: DuplicateOptions,
        home_dir: PathBuf,
        authorized_roots: Vec<PathBuf>,
        cancel: &'a CancelToken,
    ) -> Self {
        Self {
            options,
            cancel,
            home_dir,
            authorized_roots,
            skip_hidden: false,
            hashes_computed: 0,
        }
    }

    /// Sets whether dotfiles are outside this run.
    pub fn with_skip_hidden(mut self, skip_hidden: bool) -> Self {
        self.skip_hidden = skip_hidden;
        self
    }

    pub fn report(&self) -> DuplicateReport {
        DuplicateReport {
            full_hashes: self.hashes_computed,
            truncated: self.hashes_computed >= self.options.max_full_hashes,
            ..Default::default()
        }
    }

    /// Runs the whole pipeline over `roots`.
    pub fn run(
        &mut self,
        roots: &[PathBuf],
        on_group: &mut dyn FnMut(&DuplicateGroupResult),
    ) -> DuplicateReport {
        let mut report = DuplicateReport::default();
        let mut by_size: HashMap<u64, Vec<PathBuf>> = HashMap::new();
        let roots = collapse_nested_roots(roots.to_vec());
        let mut seen_paths: HashSet<PathBuf> = HashSet::new();

        // Stage 1: group by exact byte size.
        for root in &roots {
            let mut options = WalkOptions::new(self.home_dir.clone(), WalkMode::Files);
            options.authorized_roots = self.authorized_roots.clone();
            options.skip_hidden = self.skip_hidden;
            options.skip_directory_names = walker::DEFAULT_SKIP_DIRECTORY_NAMES
                .iter()
                .map(|s| (*s).to_string())
                .collect();
            skip_excluded_directories(&mut options);
            let walk = walker::walk(root, &options, self.cancel);
            if walk.cancelled {
                report.cancelled = true;
                return report;
            }
            for entry in walk.entries {
                if entry.is_directory {
                    continue;
                }
                if is_in_excluded_location(&entry.path) {
                    continue;
                }
                if !seen_paths.insert(entry.path.clone()) {
                    continue;
                }
                let size = entry.size_bytes.unwrap_or(0);
                if size == 0 && self.options.min_size_bytes > 0 {
                    // Empty files are cheap to compare and are grouped, but they
                    // reclaim nothing; keep them out of the reclaimable report.
                    continue;
                }
                if size < self.options.min_size_bytes {
                    continue;
                }
                if self.is_cloud_placeholder(&entry.path) {
                    continue;
                }
                by_size.entry(size).or_default().push(entry.path);
            }
        }

        // Stage 2 and 3: sample, then hash the survivors.
        let mut by_digest: HashMap<String, (u64, Vec<PathBuf>)> = HashMap::new();
        for (size, paths) in by_size {
            if paths.len() < 2 {
                continue;
            }
            if self.cancel.is_cancelled() {
                report.cancelled = true;
                return report;
            }

            let mut by_fingerprint: HashMap<String, Vec<PathBuf>> = HashMap::new();
            for path in &paths {
                if self.cancel.is_cancelled() {
                    report.cancelled = true;
                    return report;
                }
                report.candidates_considered += 1;
                match sample_fingerprint(path, size) {
                    Ok(fingerprint) => by_fingerprint
                        .entry(fingerprint)
                        .or_default()
                        .push(path.clone()),
                    Err(_) => continue,
                }
            }

            for (_, same_sample) in by_fingerprint {
                if same_sample.len() < 2 {
                    continue;
                }
                for path in same_sample {
                    if self.cancel.is_cancelled() {
                        report.cancelled = true;
                        return report;
                    }
                    if self.hashes_computed >= self.options.max_full_hashes {
                        report.truncated = true;
                        break;
                    }
                    match hash_file(&path, self.cancel) {
                        Ok(digest) => {
                            self.hashes_computed += 1;
                            let entry = by_digest
                                .entry(digest)
                                .or_insert_with(|| (size, Vec::new()));
                            entry.1.push(path);
                        }
                        Err(sift_hasher::HashError::Cancelled) => {
                            report.cancelled = true;
                            return report;
                        }
                        Err(_) => continue,
                    }
                }
            }
        }

        // Stage 4: build groups, choosing a keeper for each.
        let mut groups: Vec<DuplicateGroupResult> = Vec::new();
        for (digest, (size, mut paths)) in by_digest {
            if paths.len() < 2 {
                continue;
            }
            paths.sort();
            let keeper = choose_keeper(&paths);
            let members: Vec<GroupMemberRow> = paths
                .iter()
                .map(|path| GroupMemberRow {
                    path: path.to_string_lossy().to_string(),
                    size_bytes: size as i64,
                    modified_secs: modified_for(path),
                    keep: *path == keeper,
                })
                .collect();
            let reclaimable = size * (paths.len() as u64 - 1);
            groups.push(DuplicateGroupResult {
                digest,
                size_bytes: size,
                members,
                reclaimable_bytes: reclaimable,
            });
        }

        groups.sort_unstable_by_key(|group| std::cmp::Reverse(group.reclaimable_bytes));
        for group in &groups {
            on_group(group);
        }
        report.groups = groups;
        report.full_hashes = self.hashes_computed;
        report
    }

    /// iCloud and other cloud placeholders must never be offered for deletion.
    fn is_cloud_placeholder(&self, path: &Path) -> bool {
        let text = path.to_string_lossy();
        if text.contains(".icloud") || text.contains("com~apple~") {
            return true;
        }
        match std::fs::symlink_metadata(path) {
            Ok(metadata) => {
                let identity = FileIdentity::from_metadata(&metadata);
                identity.is_skipped_placeholder
            }
            Err(_) => true,
        }
    }
}

fn modified_for(path: &Path) -> i64 {
    std::fs::symlink_metadata(path)
        .ok()
        .map(|metadata| modified_secs(&metadata))
        .unwrap_or(0)
}

/// Picks the copy to keep: oldest modification time wins, and ties fall back to
/// the shortest path, which is the more stable location in practice.
pub fn choose_keeper(paths: &[PathBuf]) -> PathBuf {
    let mut best = paths[0].clone();
    let mut best_modified = modified_for(&best);
    for path in &paths[1..] {
        let modified = modified_for(path);
        let better = if modified == 0 {
            false
        } else if best_modified == 0 {
            true
        } else if modified != best_modified {
            modified < best_modified
        } else {
            path.as_os_str().len() < best.as_os_str().len()
        };
        if better {
            best = path.clone();
            best_modified = modified;
        }
    }
    best
}

/// Drops candidates contained inside another candidate, and folds the ones that
/// name the same path into a single item.
///
/// Selecting both a folder and the files inside it would double-count bytes and
/// double-report items, so the parent is kept and the child is dropped with a
/// note explaining why.
pub fn dedupe_parent_child(candidates: Vec<Candidate>) -> Vec<Candidate> {
    if candidates.len() < 2 {
        return candidates;
    }
    let mut candidates = merge_same_path(candidates);
    candidates.sort_unstable_by(|a, b| {
        a.path
            .components()
            .count()
            .cmp(&b.path.components().count())
            .then_with(|| a.path.cmp(&b.path))
    });

    let mut kept: Vec<Candidate> = Vec::with_capacity(candidates.len());
    for candidate in candidates {
        let mut subsumed = false;
        for parent in &kept {
            if parent.is_directory
                && parent.path != candidate.path
                && candidate.path.starts_with(&parent.path)
            {
                subsumed = true;
                break;
            }
        }
        if !subsumed {
            kept.push(candidate);
        }
    }
    kept
}

/// Turns candidates that name the same path into one.
///
/// Two rules can match one path. The index keeps a single row per
/// `(session, path)` and its upsert rewrites category, risk and the preselection
/// flag, so whichever candidate was written last decided all three — and which
/// one that was fell out of the order the sort happened to leave two equal keys
/// in. The same directory was therefore sometimes a preselected cache and
/// sometimes an unchecked item of another category, from the same files on disk.
///
/// The more cautious risk wins, because a path carries one risk level and
/// reporting the lower of two would understate it. The rule id then breaks the
/// tie, so two runs over the same tree produce the same list.
fn merge_same_path(candidates: Vec<Candidate>) -> Vec<Candidate> {
    let mut merged: Vec<Candidate> = Vec::with_capacity(candidates.len());
    let mut seen: std::collections::HashMap<PathBuf, usize> =
        std::collections::HashMap::with_capacity(candidates.len());

    for candidate in candidates {
        match seen.get(&candidate.path) {
            Some(&index) => {
                let kept = &merged[index];
                let more_cautious =
                    (candidate.risk, &candidate.rule_id) > (kept.risk, &kept.rule_id);
                if more_cautious {
                    merged[index] = candidate;
                }
            }
            None => {
                seen.insert(candidate.path.clone(), merged.len());
                merged.push(candidate);
            }
        }
    }
    merged
}

/// Builds the roots a duplicate scan should use, defaulting to the user's
/// selection and never widening to system directories on its own.
pub fn duplicate_roots(request: &ScanRequest, home_dir: &Path) -> Vec<PathBuf> {
    let authorized: Vec<PathBuf> = request.authorized_roots.iter().map(PathBuf::from).collect();
    let roots: Vec<PathBuf> = if !request.duplicates.roots.is_empty() {
        request
            .duplicates
            .roots
            .iter()
            .map(PathBuf::from)
            .filter(|path| {
                !is_protected_path_authorized(
                    &home_dir.to_string_lossy(),
                    &path.to_string_lossy(),
                    &authorized,
                )
            })
            .collect()
    } else {
        ["Downloads", "Desktop", "Documents"]
            .iter()
            .map(|candidate| home_dir.join(candidate))
            .filter(|path| path.is_dir())
            // The default branch is a fallback, not a policy exemption: a root
            // the protection list refuses must not be walked just because the
            // caller omitted `duplicates.roots`. Without this, `~/Documents`
            // and `~/Desktop` were entered and their children refused one by
            // one — a protected tree still appeared in the skip records.
            .filter(|path| {
                !is_protected_path_authorized(
                    &home_dir.to_string_lossy(),
                    &path.to_string_lossy(),
                    &authorized,
                )
            })
            .collect()
    };
    collapse_nested_roots(roots)
}

/// Drops duplicate roots and roots contained in another one.
///
/// The duplicate pipeline walks every root it is given. A granted folder inside
/// `~/Downloads` therefore used to be searched twice, putting the same path into
/// the size index twice — which could form a group of a file with itself and
/// count its bytes as reclaimable twice.
fn collapse_nested_roots(roots: Vec<PathBuf>) -> Vec<PathBuf> {
    // Normalise and drop exact duplicates while keeping the caller's order, so
    // the default search order (Downloads, Desktop, Documents) is unchanged.
    let mut seen: HashSet<PathBuf> = HashSet::new();
    let unique: Vec<PathBuf> = roots
        .into_iter()
        .map(|root| PathBuf::from(collapse_path(&root.to_string_lossy())))
        .filter(|root| seen.insert(root.clone()))
        .collect();

    // Decide containment shortest-first, then report in the original order.
    let mut by_depth = unique.clone();
    by_depth.sort_by(|first, second| {
        first
            .components()
            .count()
            .cmp(&second.components().count())
            .then_with(|| first.cmp(second))
    });
    let mut kept: Vec<PathBuf> = Vec::with_capacity(by_depth.len());
    for root in by_depth {
        if kept.iter().any(|parent| root.starts_with(parent)) {
            continue;
        }
        kept.push(root);
    }
    unique
        .into_iter()
        .filter(|root| kept.contains(root))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{ScanRequest, ScanRoot};
    use crate::walker::fixtures::TempTree;

    struct Harness {
        tree: TempTree,
        request: ScanRequest,
    }

    impl Harness {
        fn new(tag: &str) -> Self {
            let tree = TempTree::new(tag);
            let request = ScanRequest {
                session_id: "test".into(),
                home_dir: tree.root.to_string_lossy().to_string(),
                roots: vec![ScanRoot::new(
                    tree.root.to_string_lossy().to_string(),
                    "home",
                )],
                ..Default::default()
            };
            Self { tree, request }
        }

        fn context<'a>(
            &'a self,
            on_files: &'a mut dyn FnMut(u64, u64),
            on_path: &'a mut dyn FnMut(&Path),
        ) -> ScanContext<'a> {
            ScanContext {
                request: &self.request,
                home_dir: self.tree.root.clone(),
                rules: effective_rules(None).unwrap(),
                progress: ProgressSink {
                    on_files,
                    on_current_path: on_path,
                },
            }
        }
    }

    #[test]
    fn effective_rules_default_to_built_ins() {
        let rules = effective_rules(None).unwrap();
        assert!(rules.iter().any(|r| r.id == "user-cache"));
        assert!(rules.iter().all(|r| r.risk != Risk::Protected));
    }

    /// A rule in the shape a user rule file would use for the given anchor.
    fn anchored_rule(anchor: RootAnchor, relative_path: &str) -> Rule {
        RuleSet::from_json(&format!(
            r#"{{"schemaVersion":1,"rules":[
                 {{"id":"granted-caches","category":"applicationCache","risk":"review",
                  "root":"{}","relativePath":"{}","matchSpec":"childDirectories",
                  "explanationKey":"cleanup.explanation.cache"}}
               ]}}"#,
            anchor.as_str(),
            relative_path
        ))
        .expect("the rule parses")
        .rules
        .into_iter()
        .next()
        .expect("one rule")
    }

    /// A wildcard names one root per directory it finds, and nothing else.
    ///
    /// This is the shape the shipped `container-caches` rule uses: the platform
    /// generates the middle component, so a rule cannot spell it and a rule per
    /// bundle identifier would be a list that goes stale on the next install.
    #[test]
    fn a_wildcard_expands_to_one_root_per_directory() {
        let harness = Harness::new("wildcard-roots");
        harness
            .tree
            .file("Library/Containers/com.one/Data/Library/Caches/a.bin", 1024);
        harness
            .tree
            .file("Library/Containers/com.two/Data/Library/Caches/b.bin", 2048);
        // A container without the named directory, and a sibling of it, must not
        // become a candidate: the wildcard matches one component, not a subtree.
        harness.tree.file(
            "Library/Containers/com.three/Data/Library/Preferences/p",
            512,
        );

        let rule = wildcard_directory_rule("Containers/*/Data/Library/Caches");
        let roots = rule_roots(&rule, &harness.tree.root, &[], None);
        let mut sorted = roots.clone();
        sorted.sort();
        assert_eq!(roots, sorted, "roots are yielded in a stable order");

        let found = scan_with_rule(&harness, &rule);
        assert_eq!(
            found,
            vec![
                "Library/Containers/com.one/Data/Library/Caches".to_string(),
                "Library/Containers/com.two/Data/Library/Caches".to_string(),
            ],
            "one item per container that actually holds the named directory"
        );
        assert!(
            !found.iter().any(|path| path.contains("com.three")),
            "a container without the directory contributes nothing"
        );
    }

    /// The wildcard does not follow a symlink out of the tree it names.
    #[test]
    fn a_wildcard_root_that_is_a_symlink_is_not_offered() {
        let harness = Harness::new("wildcard-symlink");
        harness
            .tree
            .file("Library/Containers/com.one/Data/Library/Caches/a.bin", 1024);
        let outside = harness.tree.dir("Elsewhere/Caches");
        harness
            .tree
            .symlink(&outside, "Library/Containers/com.two/Data/Library/Caches");

        let rule = wildcard_directory_rule("Containers/*/Data/Library/Caches");
        let found = scan_with_rule(&harness, &rule);

        assert_eq!(
            found,
            vec!["Library/Containers/com.one/Data/Library/Caches".to_string()],
            "a link is not the directory the rule named"
        );
    }

    /// A `directory` rule over a wildcard path: the shape the shipped
    /// `container-caches` rule uses.
    fn wildcard_directory_rule(relative_path: &str) -> Rule {
        RuleSet::from_json(&format!(
            r#"{{"schemaVersion":1,"rules":[
                 {{"id":"wildcard-directory","category":"applicationCache","risk":"safe",
                  "root":"homeLibrary","relativePath":"{relative_path}","matchSpec":"directory",
                  "explanationKey":"cleanup.explanation.cache"}}
               ]}}"#
        ))
        .expect("the rule parses")
        .rules
        .into_iter()
        .next()
        .expect("one rule")
    }

    /// Runs one rule and returns its candidates as home-relative paths.
    fn scan_with_rule(harness: &Harness, rule: &Rule) -> Vec<String> {
        let cancel = CancelToken::new();
        let mut files = |_: u64, _: u64| {};
        let mut path = |_: &Path| {};
        let mut context = harness.context(&mut files, &mut path);
        context.rules = vec![rule.clone()];
        let (candidates, _) = scan_rules(&mut context, &cancel);
        let mut found: Vec<String> = candidates
            .iter()
            .map(|candidate| {
                candidate
                    .path
                    .strip_prefix(&harness.tree.root)
                    .unwrap_or(&candidate.path)
                    .to_string_lossy()
                    .to_string()
            })
            .collect();
        found.sort();
        found
    }

    /// An exclusion naming the wildcard's own directory drops that root.
    ///
    /// `container-caches` excludes `com.apple`, because macOS keeps hundreds of
    /// system-application containers holding a few kilobytes each. The exclusion
    /// has to apply to the name the `*` matched, which sits *above* the rule's
    /// root, or it would only ever filter what is inside the cache directory.
    #[test]
    fn an_exclusion_filters_the_directory_a_wildcard_matched() {
        let harness = Harness::new("wildcard-exclude");
        harness.tree.file(
            "Library/Containers/com.example.app/Data/Library/Caches/a.bin",
            4096,
        );
        harness.tree.file(
            "Library/Containers/com.apple.Safari/Data/Library/Caches/b.bin",
            4096,
        );
        harness.tree.file(
            "Library/Containers/com.appleby.app/Data/Library/Caches/c.bin",
            4096,
        );

        let shipped = effective_rules(None)
            .expect("the shipped rules load")
            .into_iter()
            .find(|rule| rule.id == "container-caches")
            .expect("the shipped rule exists");
        let found = scan_with_rule(&harness, &shipped);

        assert_eq!(
            found,
            vec![
                "Library/Containers/com.appleby.app/Data/Library/Caches".to_string(),
                "Library/Containers/com.example.app/Data/Library/Caches".to_string(),
            ],
            "`com.apple` covers `com.apple.Safari`, and not `com.appleby.app`"
        );
    }

    /// A `directory` rule with an age threshold means what it means in Swift.
    ///
    /// The move takes the whole directory, so the threshold may only decide
    /// eligibility: a directory holding one fresh file is not a cleanup item,
    /// and this side used to offer it regardless of age while the Swift engine
    /// measured it through the filter.
    #[test]
    fn a_directory_rule_with_an_age_only_offers_a_wholly_stale_directory() {
        let harness = Harness::new("directory-age");
        let stale = harness.tree.file("Library/Caches/Old/blob.bin", 4096);
        harness.tree.age(&stale, 60);
        let fresh = harness.tree.file("Library/Caches/Mixed/blob.bin", 4096);
        harness.tree.age(&fresh, 60);
        harness.tree.file("Library/Caches/Mixed/new.bin", 4096);

        let rule = RuleSet::from_json(
            r#"{"schemaVersion":1,"rules":[
                {"id":"aged-directory","category":"applicationCache","risk":"review",
                 "root":"homeLibrary","relativePath":"Caches/*","matchSpec":"directory",
                 "minAgeDays":30,"explanationKey":"cleanup.explanation.cache"}
            ]}"#,
        )
        .expect("the rule parses")
        .rules
        .into_iter()
        .next()
        .expect("one rule");

        let found = scan_with_rule(&harness, &rule);
        assert_eq!(
            found,
            vec!["Library/Caches/Old".to_string()],
            "only a directory whose every file is stale may be moved whole"
        );
    }

    /// A name set decides which children are items, and nothing else changes.
    ///
    /// `directoriesNamed` is `childDirectories` with the filter in the rule: the
    /// shipped `app-support-caches` rule uses it so `Cache`, `Caches`, `GPUCache`
    /// and `Code Cache` are one rule instead of four.
    #[test]
    fn a_name_set_selects_the_child_directories_it_names() {
        let harness = Harness::new("named-children");
        harness
            .tree
            .file("Library/Application Support/com.one/Cache/a.bin", 1024);
        harness
            .tree
            .file("Library/Application Support/com.one/Caches/b.bin", 2048);
        harness
            .tree
            .file("Library/Application Support/com.one/GPUCache/c.bin", 4096);
        harness
            .tree
            .file("Library/Application Support/com.one/Code Cache/d.bin", 4096);
        harness
            .tree
            .file("Library/Application Support/com.one/State/e.bin", 1024);
        // Case is not part of the identity: macOS compares these names without it.
        harness
            .tree
            .file("Library/Application Support/com.two/cache/f.bin", 1024);

        let rule = effective_rules(None)
            .expect("the shipped rules load")
            .into_iter()
            .find(|rule| rule.id == "app-support-caches")
            .expect("the shipped rule exists");
        let found = scan_with_rule(&harness, &rule);

        assert_eq!(
            found,
            vec![
                "Library/Application Support/com.one/Cache".to_string(),
                "Library/Application Support/com.one/Caches".to_string(),
                "Library/Application Support/com.one/Code Cache".to_string(),
                "Library/Application Support/com.one/GPUCache".to_string(),
                "Library/Application Support/com.two/cache".to_string(),
            ],
            "the named directories, in path order, and nothing else"
        );
        assert!(
            !found.iter().any(|path| path.ends_with("/State")),
            "a sibling the set does not name is not offered"
        );
    }

    /// The per-user temporary root is the directory the request named.
    ///
    /// `/var/folders/<xx>/<hash>` is generated per login session, so no rule can
    /// spell it and this core cannot derive it: the request carries it as a scan
    /// root with `anchor: "userTemp"`. Two things have to hold — the rule finds
    /// the aged children of `C`, and it finds nothing at all when the request does
    /// not name the root, which is what keeps a rule from reaching `/var/folders`
    /// on its own.
    #[test]
    fn the_user_temp_rule_reaches_only_the_root_the_request_named() {
        // Outside the home tree on purpose: a session directory inside it would
        // be reachable through the home root, and the test would pass without the
        // request ever naming it.
        let session = TempTree::new("user-temp-session");
        session.dir("C/stale.app");
        let stale = session.file("C/stale.app/cache.bin", 4096);
        session.age(&stale, 8);
        session.dir("C/fresh.app");
        session.file("C/fresh.app/cache.bin", 4096);

        let mut harness = Harness::new("user-temp");
        // Something the rule must not report: it is in `T`, not `C`, and live
        // processes keep their sockets there.
        session.dir("T/live/");
        let live = session.file("T/live/port", 128);
        session.age(&live, 30);

        let rule = effective_rules(None)
            .expect("the shipped rules load")
            .into_iter()
            .find(|rule| rule.id == "user-temp-caches")
            .expect("the shipped rule exists");

        // Without the root, the rule resolves to nothing.
        assert!(
            scan_with_rule(&harness, &rule).is_empty(),
            "a rule may not reach the per-user temporary root on its own"
        );

        harness.request.roots.push(ScanRoot::new(
            session.root.to_string_lossy().to_string(),
            "userTemp",
        ));

        let found = scan_with_rule(&harness, &rule);
        let relative: Vec<String> = found
            .iter()
            .map(|path| {
                Path::new(path)
                    .strip_prefix(&session.root)
                    .unwrap_or(Path::new(path))
                    .to_string_lossy()
                    .to_string()
            })
            .collect();
        assert_eq!(
            relative,
            vec!["C/stale.app".to_string()],
            "only the aged child of `C`, and never `T`"
        );
    }

    /// A rule inside a dot-directory follows the "show hidden files" setting.
    ///
    /// The walkers skip hidden entries; a rule's own `relativePath` never reaches
    /// them, so `~/.cache` used to be offered with the setting turned off. The
    /// scope is a property of the scan, so the rule has to be dropped rather than
    /// its items filtered afterwards.
    #[test]
    fn a_rule_under_a_hidden_directory_follows_the_hidden_file_setting() {
        let mut harness = Harness::new("hidden-rule-scope");
        // Aged past the 30-day threshold both rules carry: a cache read this
        // morning is not idle, and the rule would not offer it either way.
        let jar = harness.tree.file(".gradle/caches/jars/a.jar", 4096);
        harness.tree.age(&jar, 60);
        let blob = harness.tree.file(".cache/thing/blob.bin", 4096);
        harness.tree.age(&blob, 60);

        let rules = effective_rules(None).expect("the shipped rules load");
        let visible = |harness: &Harness| -> Vec<String> {
            let cancel = CancelToken::new();
            let mut files = |_: u64, _: u64| {};
            let mut path = |_: &Path| {};
            let mut context = harness.context(&mut files, &mut path);
            context.rules = rules.clone();
            let (candidates, _) = scan_rules(&mut context, &cancel);
            let mut found: Vec<String> = candidates
                .iter()
                .map(|candidate| {
                    candidate
                        .path
                        .strip_prefix(&harness.tree.root)
                        .unwrap_or(&candidate.path)
                        .to_string_lossy()
                        .to_string()
                })
                .collect();
            found.sort();
            found
        };

        // Hidden entries in scope: both developer caches are offered.
        let in_scope = visible(&harness);
        assert!(
            in_scope
                .iter()
                .any(|path| path.starts_with(".gradle/caches/")),
            "a dot-directory rule runs while hidden files are in scope: {in_scope:?}"
        );
        assert!(in_scope.iter().any(|path| path == ".cache/thing"));

        // Out of scope: the same rules contribute nothing.
        harness.request.include_hidden_files = false;
        let out_of_scope = visible(&harness);
        assert!(
            !out_of_scope.iter().any(|path| path.starts_with('.')),
            "no hidden rule root is scanned with hidden files out of scope: {out_of_scope:?}"
        );
    }

    /// A rule that owns one application's data loses `safe` while it runs.
    ///
    /// The item stays in the list — the user may still choose it — but it is no
    /// longer pre-selected, because the move would pull a cache directory out
    /// from under a live process. Both shapes the shipped table uses are covered:
    /// the bundle identifier as the last component (`Caches/<id>`) and as the
    /// component a wildcard matched (`Containers/<id>/...`).
    #[test]
    fn a_running_application_takes_a_safe_cache_down_to_review() {
        let mut harness = Harness::new("running-app");
        harness
            .tree
            .file("Library/Caches/com.running.app/a.bin", 4096);
        harness.tree.file("Library/Caches/com.idle.app/b.bin", 2048);
        harness.tree.file(
            "Library/Containers/com.running.app/Data/Library/Caches/c.bin",
            1024,
        );
        harness.request.running_app_tokens = vec!["com.running.app".to_string()];

        let cancel = CancelToken::new();
        let mut files = |_: u64, _: u64| {};
        let mut path = |_: &Path| {};
        let mut context = harness.context(&mut files, &mut path);
        let (candidates, _) = scan_rules(&mut context, &cancel);

        let mut rows: Vec<(String, Risk, bool)> = candidates
            .iter()
            .map(|candidate| {
                (
                    candidate
                        .path
                        .strip_prefix(&harness.tree.root)
                        .unwrap_or(&candidate.path)
                        .to_string_lossy()
                        .to_string(),
                    candidate.risk,
                    candidate.selected_by_default,
                )
            })
            .collect();
        rows.sort();

        assert_eq!(
            rows,
            vec![
                ("Library/Caches/com.idle.app".to_string(), Risk::Safe, true),
                (
                    "Library/Caches/com.running.app".to_string(),
                    Risk::Review,
                    false
                ),
                (
                    "Library/Containers/com.running.app/Data/Library/Caches".to_string(),
                    Risk::Review,
                    false
                ),
            ],
            "only the running application's items lose their pre-selection"
        );
    }

    /// A leading wildcard is refused at parse time, so there is no shape in which
    /// one rule covers every child of `~/Library`.
    #[test]
    fn a_leading_wildcard_never_reaches_the_walker() {
        let json = r#"{"schemaVersion":1,"rules":[
            {"id":"everything","category":"applicationCache","risk":"review",
             "root":"homeLibrary","relativePath":"*/Caches","matchSpec":"directory",
             "explanationKey":"cleanup.explanation.cache"}
        ]}"#;
        assert!(RuleSet::from_json(json).is_err());
    }

    /// The three new rule families find what they name, through the shipped table.
    #[test]
    fn the_shipped_wildcard_and_xcode_rules_find_their_targets() {
        let harness = Harness::new("shipped-wildcard-rules");
        harness
            .tree
            .file("Library/Containers/com.one/Data/Library/Caches/a.bin", 1024);
        harness
            .tree
            .file("Library/Application Support/com.two/Cache/c.bin", 2048);
        harness
            .tree
            .file("Library/Application Support/com.two/Caches/d.bin", 4096);
        harness
            .tree
            .file("Library/Application Support/com.two/State/e.bin", 8192);
        harness
            .tree
            .file("Library/Developer/Xcode/DerivedData/Sift/Build/f.o", 1024);
        harness.tree.file(
            "Library/Developer/Xcode/iOS DeviceSupport/17.0/Symbols/arm64",
            1024,
        );
        harness
            .tree
            .file("Library/Developer/CoreSimulator/Caches/dyld/g.bin", 1024);

        let cancel = CancelToken::new();
        let mut files = |_: u64, _: u64| {};
        let mut path = |_: &Path| {};
        let mut context = harness.context(&mut files, &mut path);
        let (candidates, _) = scan_rules(&mut context, &cancel);

        let found: Vec<String> = candidates
            .iter()
            .map(|candidate| {
                candidate
                    .path
                    .strip_prefix(&harness.tree.root)
                    .unwrap_or(&candidate.path)
                    .to_string_lossy()
                    .trim_start_matches('/')
                    .to_string()
            })
            .collect();

        for expected in [
            "Library/Containers/com.one/Data/Library/Caches",
            "Library/Application Support/com.two/Cache",
            "Library/Application Support/com.two/Caches",
            "Library/Developer/Xcode/DerivedData",
            "Library/Developer/Xcode/iOS DeviceSupport/17.0",
            "Library/Developer/CoreSimulator/Caches",
        ] {
            assert!(
                found.iter().any(|path| path == expected),
                "`{expected}` missing from {found:?}"
            );
        }
        // `State` is a sibling of the caches and is not offered by any rule.
        assert!(
            !found.iter().any(|path| path.contains("com.two/State")),
            "the rule names `Cache`, not every child of the application"
        );
    }

    #[test]
    fn an_authorised_anchor_expands_to_every_grant() {
        let home = Path::new("/Users/example");
        let grants = vec![
            PathBuf::from("/Volumes/Backup"),
            PathBuf::from("/Volumes/Media"),
        ];
        let rule = anchored_rule(RootAnchor::Authorized, "Caches");
        assert_eq!(
            rule_roots(&rule, home, &grants, None),
            vec![
                PathBuf::from("/Volumes/Backup/Caches"),
                PathBuf::from("/Volumes/Media/Caches"),
            ]
        );
    }

    #[test]
    fn an_external_volume_anchor_covers_mounted_volumes_only() {
        let home = Path::new("/Users/example");
        let grants = vec![
            PathBuf::from("/Volumes/Backup"),
            PathBuf::from("/Volumes/Backup/Photos"),
            PathBuf::from("/Users/example/Downloads"),
        ];
        let rule = anchored_rule(RootAnchor::ExternalVolume, "Caches");
        assert_eq!(
            rule_roots(&rule, home, &grants, None),
            vec![PathBuf::from("/Volumes/Backup/Caches")],
            "a folder inside a volume and a folder inside home are not volumes"
        );
    }

    #[test]
    fn a_relative_path_cannot_climb_out_of_its_anchor() {
        let home = Path::new("/Users/example");
        // The file is refused when it is read, so this is the second line: a
        // rule built in code, or one that reached the table another way.
        for escaping in ["../Shared", "../../Shared", "Logs/../../../Shared", "/etc"] {
            assert_eq!(
                resolve_root(RootAnchor::HomeLibrary, escaping, home),
                None,
                "{escaping:?} must not resolve"
            );
        }
        // And an ordinary descendant still resolves, in its collapsed form.
        assert_eq!(
            resolve_root(RootAnchor::HomeLibrary, "Logs/./DiagnosticReports", home),
            Some(PathBuf::from(
                "/Users/example/Library/Logs/DiagnosticReports"
            ))
        );
    }

    #[test]
    fn a_rule_under_a_grant_cannot_climb_out_of_the_grant() {
        let home = Path::new("/Users/example");
        let grants = vec![PathBuf::from("/Volumes/Backup")];
        // The review's case, one level up: a rule anchored at a grant must not
        // reach the rest of the disk through `..`.
        let escaping = RuleSet::from_json(
            r#"{"schemaVersion":1,"rules":[
                {"id":"climb","category":"logs","risk":"safe","root":"authorized",
                 "relativePath":"..","matchSpec":"childDirectories","explanationKey":"k"}
            ]}"#,
        );
        assert!(
            escaping.is_err(),
            "a file with this rule is refused before it can be scanned"
        );

        // A rule built directly, since the parser is what refuses the file.
        let shipped = effective_rules(None).unwrap();
        let mut climbing = shipped
            .iter()
            .find(|r| r.id == "user-logs")
            .expect("the shipped log rule")
            .clone();
        climbing.root = RootAnchor::Authorized;
        climbing.relative_path = "../..".to_string();
        assert!(
            rule_roots(&climbing, home, &grants, None).is_empty(),
            "a rule that reaches the table anyway resolves to no root"
        );

        // A legitimate descendant under the grant still works.
        let mut inside = climbing.clone();
        inside.relative_path = "var/log".to_string();
        assert_eq!(
            rule_roots(&inside, home, &grants, None),
            vec![PathBuf::from("/Volumes/Backup/var/log")]
        );
    }

    #[test]
    fn a_fixed_anchor_never_resolves_to_a_grant_container() {
        let home = Path::new("/Users/example");
        // `/Volumes` and the home directory are containers, not the location a
        // rule asked about; a caller that guessed one would widen the rule.
        assert_eq!(resolve_root(RootAnchor::Authorized, "", home), None);
        assert_eq!(resolve_root(RootAnchor::ExternalVolume, "", home), None);
        assert_eq!(
            resolve_root(RootAnchor::Home, "Library/Logs", home),
            Some(PathBuf::from("/Users/example/Library/Logs"))
        );
    }

    #[test]
    fn a_rule_anchor_is_not_a_cleanup_item() {
        let home = Path::new("/Users/example");
        // An empty relative path used to resolve to the anchor itself:
        // `root: home` offered the whole home directory (or, as
        // `childDirectories`, `~/Library`) as one item.
        for anchor in [
            RootAnchor::Home,
            RootAnchor::HomeLibrary,
            RootAnchor::Applications,
            RootAnchor::SystemLibrary,
        ] {
            assert_eq!(resolve_root(anchor, "", home), None, "{anchor:?}");
            assert_eq!(resolve_root(anchor, "/", home), None, "{anchor:?}");
        }
        // A container is refused even when it is named explicitly, and even when
        // the name arrives in another case (the volume is case-insensitive).
        for relative in [
            "Library",
            "library",
            "LIBRARY",
            "Applications",
            "applications",
        ] {
            assert_eq!(resolve_root(RootAnchor::Home, relative, home), None);
        }
        assert_eq!(
            resolve_root(RootAnchor::Home, "Library/Logs", home),
            Some(PathBuf::from("/Users/example/Library/Logs")),
            "a descendant of a container is still scannable"
        );
        assert_eq!(
            resolve_root(RootAnchor::Home, "Downloads", home),
            Some(PathBuf::from("/Users/example/Downloads"))
        );
    }

    #[test]
    fn a_grant_is_not_a_cleanup_item() {
        let home = Path::new("/Users/example");
        let grants = vec![PathBuf::from("/Volumes/Backup")];
        let rule = anchored_rule(RootAnchor::Authorized, "");
        assert!(
            rule_roots(&rule, home, &grants, None).is_empty(),
            "an authorised rule with an empty relative path must not offer the volume itself"
        );
        let inside = anchored_rule(RootAnchor::Authorized, "Caches");
        assert_eq!(
            rule_roots(&inside, home, &grants, None),
            vec![PathBuf::from("/Volumes/Backup/Caches")]
        );
    }

    #[test]
    fn a_home_rule_cannot_report_the_library_as_one_item() {
        let harness = Harness::new("container-home-rule");
        harness
            .tree
            .file("Library/Caches/com.example.app/blob.bin", 4096);
        let rule = anchored_rule(RootAnchor::Home, "");
        let cancel = CancelToken::new();
        let mut files = |_: u64, _: u64| {};
        let mut path = |_: &Path| {};
        let mut context = ScanContext {
            request: &harness.request,
            home_dir: harness.tree.root.clone(),
            rules: vec![rule],
            progress: ProgressSink {
                on_files: &mut files,
                on_current_path: &mut path,
            },
        };
        let (candidates, _) = scan_rules(&mut context, &cancel);
        assert!(
            candidates.iter().all(|candidate| {
                candidate.path != harness.tree.root
                    && candidate.path != harness.tree.root.join("Library")
            }),
            "a container must never reach the candidate list: {candidates:?}"
        );
    }

    #[test]
    fn an_authorised_rule_scans_the_grant_and_nothing_else() {
        let tree = TempTree::new("authorised-rule");
        let granted = tree.root.join("granted");
        // Only the granted subtree holds anything reclaimable.
        tree.file("granted/Caches/junk.one/blob.bin", 4096);
        tree.file("other/Caches/junk.two/blob.bin", 4096);

        let request = ScanRequest {
            session_id: "test".into(),
            home_dir: tree.root.to_string_lossy().to_string(),
            roots: vec![ScanRoot::new(
                granted.to_string_lossy().to_string(),
                "authorized",
            )],
            authorized_roots: vec![granted.to_string_lossy().to_string()],
            ..Default::default()
        };
        let cancel = CancelToken::new();
        let mut files = |_: u64, _: u64| {};
        let mut path = |_: &Path| {};
        let mut context = ScanContext {
            request: &request,
            home_dir: tree.root.clone(),
            rules: vec![anchored_rule(RootAnchor::Authorized, "Caches")],
            progress: ProgressSink {
                on_files: &mut files,
                on_current_path: &mut path,
            },
        };

        let (found, _) = scan_rules(&mut context, &cancel);
        assert_eq!(found.len(), 1, "only the granted subtree is scanned");
        assert!(found[0].path.ends_with("granted/Caches/junk.one"));
    }

    #[test]
    fn an_authorised_rule_without_the_grant_finds_nothing() {
        let tree = TempTree::new("authorised-rule-ungranted");
        tree.file("granted/Caches/junk.one/blob.bin", 4096);

        // The rule names an authorised anchor, but nothing was authorised: the
        // anchor must expand to no roots rather than to a container.
        let request = ScanRequest {
            session_id: "test".into(),
            home_dir: tree.root.to_string_lossy().to_string(),
            roots: vec![ScanRoot::new(
                tree.root.to_string_lossy().to_string(),
                "home",
            )],
            ..Default::default()
        };
        let cancel = CancelToken::new();
        let mut files = |_: u64, _: u64| {};
        let mut path = |_: &Path| {};
        let mut context = ScanContext {
            request: &request,
            home_dir: tree.root.clone(),
            rules: vec![anchored_rule(RootAnchor::Authorized, "Caches")],
            progress: ProgressSink {
                on_files: &mut files,
                on_current_path: &mut path,
            },
        };

        let (found, _) = scan_rules(&mut context, &cancel);
        assert!(found.is_empty());
    }

    #[test]
    fn effective_rules_merge_an_overlay() {
        let json = r#"{"schemaVersion":1,"rules":[
            {"id":"custom-cache","category":"applicationCache","risk":"review","root":"homeLibrary","relativePath":"Caches","explanationKey":"k"}
        ]}"#;
        let rules = effective_rules(Some(json)).unwrap();
        assert!(rules.iter().any(|r| r.id == "custom-cache"));
        assert!(rules.iter().any(|r| r.id == "user-cache"));
    }

    #[test]
    fn invalid_overlay_is_reported_as_an_error() {
        let json = r#"{"schemaVersion":42,"rules":[]}"#;
        assert!(effective_rules(Some(json)).is_err());
    }

    #[test]
    fn rule_scan_finds_cache_children_and_skips_protected_directories() {
        let harness = Harness::new("rules-cache");
        harness
            .tree
            .file("Library/Caches/com.example.app/blob.bin", 4096);
        harness
            .tree
            .file("Library/Caches/com.other.app/blob.bin", 8192);
        harness.tree.file("Documents/private.txt", 4096);

        let cancel = CancelToken::new();
        let mut files = |_: u64, _: u64| {};
        let mut path = |_: &Path| {};
        let mut context = harness.context(&mut files, &mut path);
        let (candidates, _) = scan_rules(&mut context, &cancel);

        let cache_paths: Vec<String> = candidates
            .iter()
            .filter(|c| c.category == Category::ApplicationCache)
            .map(|c| c.path.to_string_lossy().to_string())
            .collect();
        assert_eq!(cache_paths.len(), 2, "both cache children found");
        assert!(
            candidates
                .iter()
                .all(|c| !c.path.to_string_lossy().contains("Documents")),
            "protected user content must never become a candidate"
        );
    }

    #[test]
    fn log_rule_respects_the_age_threshold() {
        let harness = Harness::new("rules-logs");
        let stale = harness
            .tree
            .file("Library/Logs/com.example.app/old.log", 2048);
        harness.tree.age(&stale, 60);
        harness
            .tree
            .file("Library/Logs/com.example.app/fresh.log", 2048);
        let all_old = harness
            .tree
            .file("Library/Logs/com.allold.app/old.log", 2048);
        harness.tree.age(&all_old, 60);

        let cancel = CancelToken::new();
        let mut files = |_: u64, _: u64| {};
        let mut path = |_: &Path| {};
        let mut context = harness.context(&mut files, &mut path);
        let (candidates, _) = scan_rules(&mut context, &cancel);

        let logs: Vec<&Candidate> = candidates
            .iter()
            .filter(|c| c.category == Category::Logs)
            .collect();
        assert_eq!(
            logs.len(),
            1,
            "only the directory whose every file is stale qualifies"
        );
        assert!(logs[0].path.to_string_lossy().contains("com.allold.app"));
        assert!(
            logs[0].is_directory,
            "the log rule offers the directory as its unit of cleanup"
        );
    }

    #[test]
    fn an_age_filtered_directory_rule_skips_a_directory_with_fresh_files() {
        // A user rule may still combine `childDirectories` with an age. The
        // directory is moved whole, so a mixed directory would take files the
        // age filter did not count. It must be skipped rather than offered with
        // a size smaller than the move.
        //
        // The fixture sits under `Caches` rather than `Application Support`:
        // no rule may name that directory at all (see
        // `FORBIDDEN_RULE_DIRECTORIES`), and the age-filter behaviour under
        // test has nothing to do with which directory the rule points at.
        let harness = Harness::new("mixed-directory-age");
        let old = harness.tree.file("Library/Caches/Mixed/old.bin", 4096);
        harness.tree.age(&old, 60);
        harness.tree.file("Library/Caches/Mixed/fresh.bin", 4096);
        let all_old = harness.tree.file("Library/Caches/AllOld/old.bin", 4096);
        harness.tree.age(&all_old, 60);

        let rule = RuleSet::from_json(
            r#"{"schemaVersion":1,"rules":[
                {"id":"mixed-age","category":"temporaryFiles","risk":"review",
                 "root":"homeLibrary","relativePath":"Caches",
                 "matchSpec":"childDirectories","minAgeDays":30,
                 "explanationKey":"cleanup.explanation.temporary"}
            ]}"#,
        )
        .expect("the test rule parses")
        .rules
        .into_iter()
        .next()
        .expect("one rule");

        let cancel = CancelToken::new();
        let mut files = |_: u64, _: u64| {};
        let mut path = |_: &Path| {};
        let mut context = harness.context(&mut files, &mut path);
        let root = harness.tree.root.join("Library/Caches");
        let (candidates, _) = child_directory_candidates(&rule, &root, None, &mut context, &cancel);

        let names: Vec<&str> = candidates
            .iter()
            .map(|candidate| candidate.display_name.as_str())
            .collect();
        assert_eq!(
            names,
            vec!["AllOld"],
            "only a directory whose every file is stale may be moved whole"
        );
        assert_eq!(candidates[0].size_bytes, 4096);
    }

    #[test]
    fn the_stale_threshold_setting_reaches_the_log_scan() {
        // §5.2: the user sets one age at which a log or installer counts as stale.
        // A 60-day-old log is stale at the default 30 and still fresh at 90, so
        // this fails if the request field never reaches the walk.
        let harness = Harness::new("stale-threshold");
        let log = harness
            .tree
            .file("Library/Logs/com.example.app/old.log", 2048);
        harness.tree.age(&log, 60);

        let cancel = CancelToken::new();
        let count_logs = |days: u32| {
            let mut request = harness.request.clone();
            request.stale_threshold_days = days;
            let mut files = |_: u64, _: u64| {};
            let mut path = |_: &Path| {};
            let mut context = ScanContext {
                request: &request,
                home_dir: harness.tree.root.clone(),
                rules: effective_rules(None).unwrap(),
                progress: ProgressSink {
                    on_files: &mut files,
                    on_current_path: &mut path,
                },
            };
            let (candidates, _) = scan_rules(&mut context, &cancel);
            candidates
                .iter()
                .filter(|c| c.category == Category::Logs)
                .count()
        };

        assert_eq!(
            count_logs(30),
            1,
            "60 days is stale at the default threshold"
        );
        assert_eq!(count_logs(90), 0, "the same log is still fresh at 90 days");
        assert_eq!(
            count_logs(0),
            1,
            "an unset threshold leaves each rule's own age in force"
        );
    }

    #[test]
    fn the_stale_threshold_leaves_a_fixed_age_rule_alone() {
        // The shipped archive rule states 90 days and must not follow the
        // setting, or every zip in Downloads would become stale at 14 days.
        let rules = effective_rules(None).unwrap();
        let archives = rules
            .iter()
            .find(|r| r.id == "download-archives")
            .expect("the shipped archive rule");
        assert_eq!(archives.effective_min_age_days(14), Some(90));

        // While the installer rule the setting is meant to govern does follow it.
        let installers = rules
            .iter()
            .find(|r| r.id == "download-installers")
            .expect("the shipped installer rule");
        assert_eq!(installers.effective_min_age_days(14), Some(14));
    }

    #[test]
    fn installer_rule_only_matches_installer_extensions() {
        let harness = Harness::new("rules-installers");
        let dmg = harness.tree.file("Downloads/App.dmg", 4096);
        harness.tree.age(&dmg, 45);
        let zip = harness.tree.file("Downloads/Archive.zip", 4096);
        harness.tree.age(&zip, 120);
        let notes = harness.tree.file("Downloads/notes.txt", 4096);
        harness.tree.age(&notes, 400);

        let cancel = CancelToken::new();
        let mut files = |_: u64, _: u64| {};
        let mut path = |_: &Path| {};
        let mut context = harness.context(&mut files, &mut path);
        let (candidates, _) = scan_rules(&mut context, &cancel);

        let names: Vec<String> = candidates
            .iter()
            .filter(|c| c.category == Category::Installers)
            .map(|c| c.display_name.clone())
            .collect();
        assert!(names.contains(&"App.dmg".to_string()));
        assert!(names.contains(&"Archive.zip".to_string()));
        assert!(!names.contains(&"notes.txt".to_string()));
    }

    #[test]
    fn recent_installers_are_not_reported() {
        let harness = Harness::new("rules-fresh-installer");
        harness.tree.file("Downloads/JustDownloaded.dmg", 4096);
        let cancel = CancelToken::new();
        let mut files = |_: u64, _: u64| {};
        let mut path = |_: &Path| {};
        let mut context = harness.context(&mut files, &mut path);
        let (candidates, _) = scan_rules(&mut context, &cancel);
        assert!(candidates.is_empty(), "a fresh download is still wanted");
    }

    #[test]
    fn cloudkit_caches_are_excluded_by_rule_excludes() {
        let harness = Harness::new("rules-excludes");
        harness.tree.file("Library/Caches/CloudKit/blob", 4096);
        harness
            .tree
            .file("Library/Caches/com.example.app/blob", 4096);
        let cancel = CancelToken::new();
        let mut files = |_: u64, _: u64| {};
        let mut path = |_: &Path| {};
        let mut context = harness.context(&mut files, &mut path);
        let (candidates, _) = scan_rules(&mut context, &cancel);
        assert!(
            !candidates
                .iter()
                .any(|c| c.path.to_string_lossy().contains("CloudKit")),
            "CloudKit must be excluded: rebuilding it costs the user data"
        );
    }

    #[test]
    fn a_rule_exclude_covers_the_subtree_for_file_specs() {
        // `excludes` is a subtree rule, not a last-component test. The Swift
        // engine applies the same shape; a file rule that only checked its own
        // name would walk straight into the excluded directory.
        let harness = Harness::new("rules-excludes-files");
        harness.tree.file("Downloads/private/secret.txt", 4096);
        harness.tree.file("Downloads/open.txt", 4096);

        let overlay = RuleSet::from_json(
            r#"{"schemaVersion":1,"rules":[
                {"id":"excluded-files","category":"installers","risk":"review",
                 "root":"home","relativePath":"Downloads","matchSpec":"filesByExtension",
                 "extensions":["txt"],"excludes":["private"],
                 "explanationKey":"cleanup.explanation.installers"}
            ]}"#,
        )
        .expect("the overlay parses")
        .rules;
        let mut rules = effective_rules(None).unwrap();
        rules.extend(overlay);

        let cancel = CancelToken::new();
        let mut files = |_: u64, _: u64| {};
        let mut path = |_: &Path| {};
        let mut context = ScanContext {
            request: &harness.request,
            home_dir: harness.tree.root.clone(),
            rules,
            progress: ProgressSink {
                on_files: &mut files,
                on_current_path: &mut path,
            },
        };
        let (candidates, _) = scan_rules(&mut context, &cancel);
        let names: Vec<String> = candidates
            .iter()
            .filter(|c| c.category == Category::Installers)
            .map(|c| c.display_name.clone())
            .collect();

        assert!(names.contains(&"open.txt".to_string()));
        assert!(
            !names.contains(&"secret.txt".to_string()),
            "the excluded directory's files must not be candidates: {names:?}"
        );
    }

    #[test]
    fn excluded_bundle_directories_are_invisible_to_the_large_file_scan() {
        let harness = Harness::new("large-excluded");
        harness
            .tree
            .file("Library/Caches/CloudKit/large.bin", 2 * 1024 * 1024);
        harness.tree.file("Downloads/large.bin", 2 * 1024 * 1024);

        let cancel = CancelToken::new();
        let mut files = |_: u64, _: u64| {};
        let mut path = |_: &Path| {};
        let mut context = harness.context(&mut files, &mut path);
        let (candidates, _) = scan_large_files(&mut context, &cancel, 1024 * 1024);

        assert!(
            candidates
                .iter()
                .all(|c| !c.path.to_string_lossy().contains("CloudKit")),
            "a large file inside excluded application data is not a cleanup item"
        );
        assert!(
            candidates.iter().any(|c| c.display_name == "large.bin"),
            "the ordinary large file is still reported"
        );
    }

    #[test]
    fn the_threshold_scan_skips_live_user_databases_and_backups() {
        // A large or old file inside one of these trees is a shard of a live
        // database or a device backup. Moving it silently corrupts the store,
        // so neither threshold scan may offer it even though the bytes are
        // large enough.
        let harness = Harness::new("threshold-live-data");
        harness.tree.file(
            "Library/Application Support/MobileSync/Backup/chunk.bin",
            4096,
        );
        harness
            .tree
            .file("Library/Application Support/AddressBook/db.bin", 4096);
        harness
            .tree
            .file("Library/Group Containers/group.com.example/data.bin", 4096);
        harness.tree.file("Downloads/ordinary.bin", 4096);

        let cancel = CancelToken::new();
        let mut files = |_: u64, _: u64| {};
        let mut path = |_: &Path| {};
        let mut context = harness.context(&mut files, &mut path);
        let (candidates, _) = scan_large_files(&mut context, &cancel, 1024);

        let names: Vec<&str> = candidates
            .iter()
            .map(|candidate| candidate.display_name.as_str())
            .collect();
        assert!(
            names.contains(&"ordinary.bin"),
            "an ordinary large file is still reported: {names:?}"
        );
        for excluded in ["chunk.bin", "db.bin", "data.bin"] {
            assert!(
                !names.contains(&excluded),
                "{excluded} belongs to live user data and must not be a threshold candidate"
            );
        }
    }

    #[test]
    fn an_excluded_preference_file_is_not_residue() {
        let harness = Harness::new("residue-excluded-preference");
        harness
            .tree
            .file("Library/Preferences/com.apple.bird.plist", 100);
        harness
            .tree
            .file("Library/Preferences/com.gone.app.plist", 100);
        let mut request = harness.request.clone();
        request.installed_bundle_ids = vec!["com.installed.app".to_string()];

        let cancel = CancelToken::new();
        let mut files = |_: u64, _: u64| {};
        let mut path = |_: &Path| {};
        let mut context = ScanContext {
            request: &request,
            home_dir: harness.tree.root.clone(),
            rules: effective_rules(None).unwrap(),
            progress: ProgressSink {
                on_files: &mut files,
                on_current_path: &mut path,
            },
        };
        let (candidates, _) = scan_application_residue(&mut context, &cancel);
        let names: Vec<&str> = candidates
            .iter()
            .map(|candidate| candidate.display_name.as_str())
            .collect();
        assert!(!names.contains(&"com.apple.bird.plist"), "{names:?}");
        assert!(names.contains(&"com.gone.app.plist"), "{names:?}");
    }

    #[test]
    fn the_hidden_file_setting_decides_what_a_rule_scan_produces() {
        // The setting is a scope: with it off, a dotfile is not a candidate and
        // the bytes it holds are not reported as reclaimable either.
        let harness = Harness::new("hidden-scope-rules");
        harness
            .tree
            .file("Library/Caches/com.example.app/blob.bin", 4096);
        harness
            .tree
            .file("Library/Caches/com.example.app/.hidden.bin", 4096);

        let cancel = CancelToken::new();
        let measured = |include_hidden: bool| {
            let mut request = harness.request.clone();
            request.include_hidden_files = include_hidden;
            let mut files = |_: u64, _: u64| {};
            let mut path = |_: &Path| {};
            let mut context = ScanContext {
                request: &request,
                home_dir: harness.tree.root.clone(),
                rules: effective_rules(None).unwrap(),
                progress: ProgressSink {
                    on_files: &mut files,
                    on_current_path: &mut path,
                },
            };
            let (candidates, _) = scan_rules(&mut context, &cancel);
            candidates
                .iter()
                .find(|c| c.category == Category::ApplicationCache)
                .map(|c| c.size_bytes)
                .unwrap_or(0)
        };

        let shown = measured(true);
        let hidden = measured(false);
        assert!(
            hidden < shown,
            "excluding the dotfile must reduce the measured size: {hidden} vs {shown}"
        );
    }

    #[test]
    fn parent_child_overlap_is_deduplicated_keeping_the_parent() {
        let parent = Candidate {
            path: PathBuf::from("/tmp/x/Caches"),
            display_name: "Caches".into(),
            parent_path: "/tmp/x".into(),
            category: Category::ApplicationCache,
            risk: Risk::Safe,
            size_bytes: 100,
            file_count: 1,
            modified_secs: 1,
            created_secs: 1,
            explanation_key: "k".into(),
            rule_id: "a".into(),
            bundle_id: None,
            is_directory: true,
            selected_by_default: true,
            note: None,
        };
        let mut child = parent.clone();
        child.path = PathBuf::from("/tmp/x/Caches/com.example");
        child.display_name = "com.example".into();
        child.is_directory = false;

        let deduped = dedupe_parent_child(vec![child, parent]);
        assert_eq!(deduped.len(), 1);
        assert!(deduped[0].is_directory);
    }

    #[test]
    fn similarly_named_siblings_are_not_treated_as_nested() {
        let mut a = Candidate {
            path: PathBuf::from("/tmp/x/Caches"),
            display_name: "Caches".into(),
            parent_path: "/tmp/x".into(),
            category: Category::ApplicationCache,
            risk: Risk::Safe,
            size_bytes: 100,
            file_count: 1,
            modified_secs: 1,
            created_secs: 1,
            explanation_key: "k".into(),
            rule_id: "a".into(),
            bundle_id: None,
            is_directory: true,
            selected_by_default: true,
            note: None,
        };
        let mut b = a.clone();
        b.path = PathBuf::from("/tmp/x/Caches-old");
        a.note = None;
        let deduped = dedupe_parent_child(vec![a, b]);
        assert_eq!(deduped.len(), 2);
    }

    #[test]
    fn bundle_identifier_detection_rejects_ordinary_folder_names() {
        assert!(looks_like_bundle_identifier("com.apple.Safari"));
        assert!(looks_like_bundle_identifier("org.mozilla.firefox"));
        assert!(looks_like_bundle_identifier("com.example.editor-pro"));
        assert!(!looks_like_bundle_identifier("Editor"));
        assert!(!looks_like_bundle_identifier("My Project"));
        assert!(!looks_like_bundle_identifier("Notes"));
        assert!(!looks_like_bundle_identifier("com..x"));
    }

    /// A candidate for `path`, with the fields the merge under test reads.
    fn candidate_for(path: &str, risk: Risk, rule_id: &str) -> Candidate {
        Candidate {
            path: PathBuf::from(path),
            display_name: "x".into(),
            parent_path: "/tmp/x".into(),
            category: Category::ApplicationCache,
            risk,
            size_bytes: 100,
            file_count: 1,
            modified_secs: 1,
            created_secs: 1,
            explanation_key: "cleanup.explanation.cache".into(),
            rule_id: rule_id.into(),
            bundle_id: None,
            is_directory: true,
            selected_by_default: risk == Risk::Safe,
            note: None,
        }
    }

    #[test]
    fn one_path_from_two_rules_becomes_one_candidate_at_the_more_cautious_risk() {
        // The index keeps one row per `(session, path)` and its upsert rewrites
        // category, risk and preselection, so without this merge the row the user
        // saw was decided by whichever candidate happened to be written last.
        let path = "/tmp/x/Library/Caches/com.example.app";

        for pair in [
            vec![
                candidate_for(path, Risk::Safe, "user-cache"),
                candidate_for(path, Risk::Review, "user-residue"),
            ],
            // The other order must give the same answer: the result may not
            // depend on which rule the walk reached first.
            vec![
                candidate_for(path, Risk::Review, "user-residue"),
                candidate_for(path, Risk::Safe, "user-cache"),
            ],
        ] {
            let deduped = dedupe_parent_child(pair);
            assert_eq!(deduped.len(), 1, "one path is one item");
            assert_eq!(
                deduped[0].risk,
                Risk::Review,
                "the more cautious risk is the one a path carries"
            );
            assert_eq!(deduped[0].rule_id, "user-residue");
            assert!(!deduped[0].selected_by_default);
        }
    }

    #[test]
    fn one_path_from_two_rules_is_resolved_by_rule_id_when_the_risk_is_equal() {
        let path = "/tmp/x/Library/Caches/com.example.app";
        let mut first = candidate_for(path, Risk::Review, "aaa-rule");
        first.size_bytes = 1;
        let mut second = candidate_for(path, Risk::Review, "zzz-rule");
        second.size_bytes = 2;

        let forward = dedupe_parent_child(vec![first.clone(), second.clone()]);
        let backward = dedupe_parent_child(vec![second, first]);
        assert_eq!(forward.len(), 1);
        assert_eq!(backward.len(), 1);
        assert_eq!(
            forward[0].rule_id, backward[0].rule_id,
            "order must not decide"
        );
        assert_eq!(forward[0].rule_id, "zzz-rule");
    }

    #[test]
    fn container_residue_requires_the_application_to_be_gone() {
        // `~/Library/Containers/<bundle-id>` is an application's whole sandbox.
        let harness = Harness::new("residue-containers");
        harness
            .tree
            .file("Library/Containers/com.gone.app/Data/blob.bin", 4096);
        harness
            .tree
            .file("Library/Containers/com.installed.app/Data/blob.bin", 4096);

        let mut request = harness.request.clone();
        request.installed_bundle_ids = vec!["com.installed.app".to_string()];
        let cancel = CancelToken::new();
        let mut files = |_: u64, _: u64| {};
        let mut path = |_: &Path| {};
        let mut context = ScanContext {
            request: &request,
            home_dir: harness.tree.root.clone(),
            rules: effective_rules(None).unwrap(),
            progress: ProgressSink {
                on_files: &mut files,
                on_current_path: &mut path,
            },
        };

        let (candidates, _) = scan_application_residue(&mut context, &cancel);
        let paths: Vec<String> = candidates
            .iter()
            .map(|c| c.path.to_string_lossy().to_string())
            .collect();
        assert!(
            paths.iter().any(|p| p.contains("com.gone.app")),
            "the container of an uninstalled application is residue: {paths:?}"
        );
        assert!(
            !paths.iter().any(|p| p.contains("com.installed.app")),
            "the container of an installed application is its data: {paths:?}"
        );
    }

    #[test]
    fn group_container_residue_reads_both_spellings_of_the_name() {
        let harness = Harness::new("residue-group-containers");
        // App Store spelling: a team prefix with no dot, then the bundle id.
        harness
            .tree
            .file("Library/Group Containers/TEAM1.com.gone.app/blob.bin", 4096);
        harness.tree.file(
            "Library/Group Containers/TEAM2.com.installed.app/blob.bin",
            4096,
        );
        // The bundle identifier on its own.
        harness
            .tree
            .file("Library/Group Containers/com.also-gone.app/blob.bin", 4096);
        // `com.also-gone.app` is not installed, but the container names an
        // application that is: the reading after the dot decides.
        harness
            .tree
            .file("Library/Group Containers/TEAM3.com.half.app/blob.bin", 4096);
        // A name in neither spelling is left alone.
        harness
            .tree
            .file("Library/Group Containers/UBF8T346G9.Office/blob.bin", 4096);

        let mut request = harness.request.clone();
        request.installed_bundle_ids =
            vec!["com.installed.app".to_string(), "com.half.app".to_string()];
        let cancel = CancelToken::new();
        let mut files = |_: u64, _: u64| {};
        let mut path = |_: &Path| {};
        let mut context = ScanContext {
            request: &request,
            home_dir: harness.tree.root.clone(),
            rules: effective_rules(None).unwrap(),
            progress: ProgressSink {
                on_files: &mut files,
                on_current_path: &mut path,
            },
        };

        let (candidates, _) = scan_application_residue(&mut context, &cancel);
        let paths: Vec<String> = candidates
            .iter()
            .map(|c| c.path.to_string_lossy().to_string())
            .collect();

        assert!(
            paths.iter().any(|p| p.contains("TEAM1.com.gone.app")),
            "the shared container of a gone application is residue: {paths:?}"
        );
        assert!(
            paths.iter().any(|p| p.contains("com.also-gone.app")),
            "a container named after the bundle id alone is residue too: {paths:?}"
        );
        assert!(
            !paths.iter().any(|p| p.contains("TEAM2.com.installed.app")),
            "an installed application keeps its shared container: {paths:?}"
        );
        assert!(
            !paths.iter().any(|p| p.contains("TEAM3.com.half.app")),
            "one reading naming an installed application is enough to keep it: {paths:?}"
        );
        assert!(
            !paths.iter().any(|p| p.contains("UBF8T346G9.Office")),
            "a name in neither spelling is left alone: {paths:?}"
        );

        let half = candidates
            .iter()
            .find(|c| c.path.to_string_lossy().contains("com.also-gone.app"))
            .expect("the bare-name container");
        assert_eq!(half.bundle_id.as_deref(), Some("com.also-gone.app"));

        // A shared container is its own category on the scan page: it belongs to
        // an app group rather than to one application, so it is not the same
        // claim as a private container and the page keeps the two totals apart.
        assert_eq!(
            half.category,
            Category::GroupContainerResidue,
            "a group container residue has its own category"
        );
        assert_eq!(
            half.explanation_key,
            "cleanup.explanation.residueGroupContainer"
        );
    }

    /// The two kinds of residue keep their own categories.
    ///
    /// `~/Library/Containers/<id>` is one application's private data;
    /// `~/Library/Group Containers/<team-id>.<id>` is shared by an app group, and
    /// the uninstaller has always treated them differently. The scan page reads
    /// the same way, so one page cannot call them the same thing.
    #[test]
    fn a_private_container_and_a_shared_one_are_different_categories() {
        let harness = Harness::new("residue-categories");
        harness
            .tree
            .file("Library/Containers/com.gone.app/Data/blob.bin", 4096);
        harness
            .tree
            .file("Library/Group Containers/TEAM1.com.gone.app/blob.bin", 4096);

        let mut request = harness.request.clone();
        request.installed_bundle_ids = vec!["com.installed.app".to_string()];
        let cancel = CancelToken::new();
        let mut files = |_: u64, _: u64| {};
        let mut path = |_: &Path| {};
        let mut context = ScanContext {
            request: &request,
            home_dir: harness.tree.root.clone(),
            rules: effective_rules(None).unwrap(),
            progress: ProgressSink {
                on_files: &mut files,
                on_current_path: &mut path,
            },
        };
        let (candidates, _) = scan_application_residue(&mut context, &cancel);

        let category = |name: &str| {
            candidates
                .iter()
                .find(|candidate| candidate.path.to_string_lossy().contains(name))
                .map(|candidate| candidate.category)
        };
        assert_eq!(
            category("Library/Containers/com.gone.app"),
            Some(Category::ApplicationResidue),
            "a private container is per-application residue"
        );
        assert_eq!(
            category("TEAM1.com.gone.app"),
            Some(Category::GroupContainerResidue),
            "a shared container is its own category"
        );
    }

    #[test]
    fn residue_matches_only_uninstalled_bundle_identifiers() {
        let harness = Harness::new("residue");
        harness
            .tree
            .file("Library/Application Support/com.gone.app/data.bin", 4096);
        harness.tree.file(
            "Library/Application Support/com.installed.app/data.bin",
            4096,
        );
        harness
            .tree
            .file("Library/Application Support/Editor/notes.txt", 4096);
        harness
            .tree
            .file("Library/Preferences/com.gone.app.plist", 512);
        harness
            .tree
            .file("Library/Preferences/com.installed.app.plist", 512);

        let mut request = harness.request.clone();
        request.installed_bundle_ids = vec!["com.installed.app".to_string()];
        let cancel = CancelToken::new();
        let mut files = |_: u64, _: u64| {};
        let mut path = |_: &Path| {};
        let mut context = ScanContext {
            request: &request,
            home_dir: harness.tree.root.clone(),
            rules: effective_rules(None).unwrap(),
            progress: ProgressSink {
                on_files: &mut files,
                on_current_path: &mut path,
            },
        };

        let (candidates, _) = scan_application_residue(&mut context, &cancel);
        let paths: Vec<String> = candidates
            .iter()
            .map(|c| c.path.to_string_lossy().to_string())
            .collect();

        assert!(
            paths.iter().any(|p| p.contains("com.gone.app")),
            "uninstalled app residue should be found: {paths:?}"
        );
        assert!(
            !paths.iter().any(|p| p.contains("com.installed.app")),
            "installed apps are not residue"
        );
        assert!(
            !paths.iter().any(|p| p.contains("/Editor")),
            "a name that is not a bundle identifier must never be residue"
        );
    }

    /// A container an installed application's app group declares is not residue.
    ///
    /// The group container is named after the group, so neither application that
    /// shares it appears in the name: `readings` resolves to nothing and the
    /// container was offered as a leftover of an uninstalled application. The
    /// declared groups arrive in the request, and a container whose whole name
    /// is one of them is live.
    #[test]
    fn residue_skips_a_container_an_app_group_declares() {
        let harness = Harness::new("group-declared");
        harness.tree.file(
            "Library/Group Containers/group.com.vendor.shared/store.db",
            4096,
        );
        harness.tree.file(
            "Library/Group Containers/group.com.vendor.gone/store.db",
            4096,
        );

        let mut request = harness.request.clone();
        request.installed_bundle_ids = vec!["com.installed.app".to_string()];
        request.app_group_ids = vec!["GROUP.com.vendor.shared".to_string()];
        let cancel = CancelToken::new();
        let mut files = |_: u64, _: u64| {};
        let mut path = |_: &Path| {};
        let mut context = ScanContext {
            request: &request,
            home_dir: harness.tree.root.clone(),
            rules: effective_rules(None).unwrap(),
            progress: ProgressSink {
                on_files: &mut files,
                on_current_path: &mut path,
            },
        };

        let (candidates, _) = scan_application_residue(&mut context, &cancel);
        let paths: Vec<String> = candidates
            .iter()
            .map(|c| c.path.to_string_lossy().to_string())
            .collect();

        assert!(
            !paths.iter().any(|p| p.contains("group.com.vendor.shared")),
            "a declared app group owns its container: {paths:?}"
        );
        assert!(
            paths.iter().any(|p| p.contains("group.com.vendor.gone")),
            "a container nothing declares is still residue: {paths:?}"
        );
        let shared = candidates
            .iter()
            .find(|c| c.path.to_string_lossy().contains("group.com.vendor.gone"))
            .expect("the undeclared container is a candidate");
        assert_eq!(shared.category, Category::GroupContainerResidue);
    }

    /// An incomplete declared set reports no group-container residue.
    ///
    /// The set answers "is no application using this container". A set cut short
    /// by a deadline answers "no" for every container whose owner was not read, so
    /// the safe answer is to offer none of them this run rather than a list that
    /// may include live data.
    #[test]
    fn an_incomplete_app_group_set_reports_no_group_container_residue() {
        let harness = Harness::new("group-incomplete");
        harness.tree.file(
            "Library/Group Containers/group.com.vendor.gone/store.db",
            4096,
        );
        harness
            .tree
            .file("Library/Containers/com.gone.app/Data/blob.bin", 4096);

        let mut request = harness.request.clone();
        request.installed_bundle_ids = vec!["com.installed.app".to_string()];
        request.app_group_ids = Vec::new();
        request.app_group_ids_complete = false;
        let cancel = CancelToken::new();
        let mut files = |_: u64, _: u64| {};
        let mut path = |_: &Path| {};
        let mut context = ScanContext {
            request: &request,
            home_dir: harness.tree.root.clone(),
            rules: effective_rules(None).unwrap(),
            progress: ProgressSink {
                on_files: &mut files,
                on_current_path: &mut path,
            },
        };

        let (candidates, _) = scan_application_residue(&mut context, &cancel);
        assert!(
            !candidates
                .iter()
                .any(|c| c.category == Category::GroupContainerResidue),
            "no container is a leftover while the declared set is unknown"
        );
        assert!(
            candidates
                .iter()
                .any(|c| c.category == Category::ApplicationResidue),
            "the private container is still residue: it does not depend on the set"
        );
    }

    /// A root can exist for its rules without feeding the threshold scans.
    ///
    /// `/Library/Logs` is added to the scan scope so the `system-logs` rule can
    /// reach it. Treating that root as a general cleanup root also offered every
    /// large or old file below it as a separate `.largeFiles` / `.oldFiles`
    /// candidate, which is a different decision from the rule's.
    #[test]
    fn a_root_can_be_excluded_from_the_threshold_scans() {
        let harness = Harness::new("threshold-scope");
        harness.tree.file("Downloads/inside.bin", 2 * 1024 * 1024);
        let outside = TempTree::new("threshold-scope-outside");
        outside.file("large.bin", 2 * 1024 * 1024);

        let mut request = harness.request.clone();
        let mut excluded =
            ScanRoot::new(outside.root.to_string_lossy().to_string(), "systemLibrary");
        excluded.includes_threshold_files = false;
        request.roots.push(excluded);

        let cancel = CancelToken::new();
        let mut files = |_: u64, _: u64| {};
        let mut path = |_: &Path| {};
        let mut context = ScanContext {
            request: &request,
            home_dir: harness.tree.root.clone(),
            rules: effective_rules(None).unwrap(),
            progress: ProgressSink {
                on_files: &mut files,
                on_current_path: &mut path,
            },
        };
        let (candidates, _) = scan_large_files(&mut context, &cancel, 1024 * 1024);

        assert!(
            candidates
                .iter()
                .any(|candidate| candidate.display_name == "inside.bin"),
            "the ordinary root still feeds the large-file scan"
        );
        assert!(
            candidates
                .iter()
                .all(|candidate| !candidate.path.starts_with(&outside.root)),
            "a rules-only root must not produce threshold candidates: {candidates:?}"
        );
    }

    #[test]
    fn large_file_scan_applies_the_byte_threshold() {
        let harness = Harness::new("large");
        harness.tree.file("big.bin", 3 * 1024 * 1024);
        harness.tree.file("small.bin", 1024);

        let cancel = CancelToken::new();
        let mut files = |_: u64, _: u64| {};
        let mut path = |_: &Path| {};
        let mut context = harness.context(&mut files, &mut path);
        let (candidates, _) = scan_large_files(&mut context, &cancel, 1024 * 1024);
        assert_eq!(candidates.len(), 1);
        assert!(candidates[0].display_name == "big.bin");
        assert_eq!(candidates[0].category, Category::LargeFiles);
        assert!(!candidates[0].selected_by_default);
    }

    #[test]
    fn old_file_scan_needs_both_age_and_size() {
        let harness = Harness::new("old");
        let old_big = harness.tree.file("old-big.bin", 20 * 1024 * 1024);
        harness.tree.age(&old_big, 400);
        let old_small = harness.tree.file("old-small.bin", 1024);
        harness.tree.age(&old_small, 400);
        harness.tree.file("fresh-big.bin", 20 * 1024 * 1024);

        let cancel = CancelToken::new();
        let mut files = |_: u64, _: u64| {};
        let mut path = |_: &Path| {};
        let mut context = harness.context(&mut files, &mut path);
        let (candidates, _) = scan_old_files(&mut context, &cancel, 180);
        assert_eq!(candidates.len(), 1);
        assert_eq!(candidates[0].display_name, "old-big.bin");
    }

    #[test]
    fn duplicate_pipeline_groups_identical_files_only() {
        let harness = Harness::new("dup");
        harness
            .tree
            .file_with("a/one.bin", b"identical content here");
        harness
            .tree
            .file_with("b/one-copy.bin", b"identical content here");
        harness
            .tree
            .file_with("c/different.bin", b"other content, same len");
        // Same size as the above but different bytes.
        harness
            .tree
            .file_with("d/another.bin", b"another content, eq len");

        let cancel = CancelToken::new();
        let options = DuplicateOptions {
            min_size_bytes: 1,
            ..Default::default()
        };
        let mut finder =
            DuplicateFinder::new(options, harness.tree.root.clone(), Vec::new(), &cancel);
        let mut seen: Vec<DuplicateGroupResult> = Vec::new();
        let report = finder.run(std::slice::from_ref(&harness.tree.root), &mut |group| {
            seen.push(group.clone())
        });

        assert_eq!(report.groups.len(), 1, "only one true duplicate pair");
        let group = &report.groups[0];
        assert_eq!(group.members.len(), 2);
        assert_eq!(group.reclaimable_bytes, group.size_bytes);
        assert_eq!(group.members.iter().filter(|m| m.keep).count(), 1);
    }

    #[test]
    fn nested_duplicate_roots_do_not_make_a_file_its_own_duplicate() {
        let harness = Harness::new("dup-nested-roots");
        let payload = b"a duplicate payload inside one project";
        harness.tree.file_with("Downloads/Project/one.bin", payload);
        harness.tree.file_with("Downloads/Project/two.bin", payload);

        let downloads = harness.tree.root.join("Downloads");
        let project = downloads.join("Project");
        let cancel = CancelToken::new();
        let options = DuplicateOptions {
            min_size_bytes: 1,
            ..Default::default()
        };
        let mut finder =
            DuplicateFinder::new(options, harness.tree.root.clone(), Vec::new(), &cancel);
        let report = finder.run(&[downloads.clone(), project.clone()], &mut |_| {});

        assert_eq!(report.groups.len(), 1);
        assert_eq!(
            report.groups[0].members.len(),
            2,
            "walking the inner root twice must not duplicate a member"
        );
        assert_eq!(
            report.groups[0].reclaimable_bytes, report.groups[0].size_bytes,
            "one copy is reclaimed, not two"
        );
    }

    #[test]
    fn duplicate_roots_collapse_a_nested_grant() {
        let harness = Harness::new("dup-root-collapse");
        let downloads = harness.tree.root.join("Downloads");
        let project = downloads.join("Project");
        std::fs::create_dir_all(&project).expect("the fixture directory");

        let mut request = harness.request.clone();
        request.duplicates.roots = vec![
            downloads.to_string_lossy().to_string(),
            project.to_string_lossy().to_string(),
        ];
        let roots = duplicate_roots(&request, &harness.tree.root);
        assert_eq!(
            roots,
            vec![downloads],
            "the outer root already covers the inner one"
        );
    }

    #[test]
    fn duplicate_pipeline_keeps_the_oldest_copy() {
        let harness = Harness::new("dup-keeper");
        let older = harness
            .tree
            .file_with("a/keep.bin", b"duplicate payload bytes");
        harness.tree.age(&older, 30);
        std::thread::sleep(std::time::Duration::from_millis(20));
        harness
            .tree
            .file_with("b/newer.bin", b"duplicate payload bytes");

        let cancel = CancelToken::new();
        let options = DuplicateOptions {
            min_size_bytes: 1,
            ..Default::default()
        };
        let mut finder =
            DuplicateFinder::new(options, harness.tree.root.clone(), Vec::new(), &cancel);
        let report = finder.run(std::slice::from_ref(&harness.tree.root), &mut |_| {});

        let group = &report.groups[0];
        let kept = group.members.iter().find(|m| m.keep).expect("a keeper");
        assert!(kept.path.ends_with("keep.bin"), "oldest copy is kept");
    }

    #[test]
    fn duplicate_pipeline_ignores_cloud_placeholders() {
        let harness = Harness::new("dup-cloud");
        harness.tree.file_with("a/real.bin", b"payload payload");
        harness
            .tree
            .file_with("a/.hidden.icloud", b"payload payload");

        let cancel = CancelToken::new();
        let options = DuplicateOptions {
            min_size_bytes: 1,
            ..Default::default()
        };
        let mut finder =
            DuplicateFinder::new(options, harness.tree.root.clone(), Vec::new(), &cancel);
        let report = finder.run(std::slice::from_ref(&harness.tree.root), &mut |_| {});
        assert!(
            report.groups.is_empty(),
            "an iCloud placeholder is never a deletion candidate"
        );
    }

    #[test]
    fn duplicate_cancellation_stops_early() {
        let harness = Harness::new("dup-cancel");
        for i in 0..20 {
            harness
                .tree
                .file_with(&format!("g{i}/x.bin"), b"same payload for all");
        }
        let cancel = CancelToken::new();
        cancel.cancel();
        let mut finder = DuplicateFinder::new(
            Default::default(),
            harness.tree.root.clone(),
            Vec::new(),
            &cancel,
        );
        let report = finder.run(std::slice::from_ref(&harness.tree.root), &mut |_| {});
        assert!(report.cancelled);
    }

    #[test]
    fn duplicate_roots_default_to_user_folders_and_respect_ignore_list() {
        let harness = Harness::new("dup-roots");
        harness.tree.dir("Downloads");
        harness.tree.dir("Desktop");
        harness.tree.dir("Documents");
        let mut request = harness.request.clone();
        request.duplicates.roots = vec![harness
            .tree
            .root
            .join("Library")
            .to_string_lossy()
            .to_string()];

        let roots = duplicate_roots(&request, &harness.tree.root);
        assert_eq!(roots.len(), 1);

        request.duplicates.roots.clear();
        let defaults = duplicate_roots(&request, &harness.tree.root);
        let names: Vec<String> = defaults
            .iter()
            .map(|p| p.file_name().unwrap().to_string_lossy().to_string())
            .collect();
        // Desktop and Documents are on the protection list, so the fallback
        // must not enter them even when the caller named no roots.
        assert_eq!(names, vec!["Downloads"]);
    }

    #[test]
    fn measure_directory_counts_nested_files() {
        let harness = Harness::new("measure");
        harness.tree.file("dir/a.bin", 4096);
        harness.tree.file("dir/nested/b.bin", 8192);
        let cancel = CancelToken::new();
        let (measured, report) = measure_directory(
            &harness.tree.root.join("dir"),
            &cancel,
            &harness.tree.root,
            &[],
            false,
            &[],
        );
        assert_eq!(report.total_files, 2);
        assert!(measured.bytes >= 4096 + 8192);
    }

    #[test]
    fn empty_directories_are_not_candidates() {
        let harness = Harness::new("empty-dir");
        harness.tree.dir("Library/Caches/com.empty.app");
        let cancel = CancelToken::new();
        let mut files = |_: u64, _: u64| {};
        let mut path = |_: &Path| {};
        let mut context = harness.context(&mut files, &mut path);
        let (candidates, _) = scan_rules(&mut context, &cancel);
        assert!(candidates.is_empty());
    }
}
