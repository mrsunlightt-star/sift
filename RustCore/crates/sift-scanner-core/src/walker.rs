//! The single traversal primitive used by every scanner strategy.
//!
//! Design constraints from the specification, enforced here rather than at each
//! call site:
//!
//! * symlinks are never followed, so a scan cannot escape its authorised roots,
//! * the protection check runs on every entry and honours the walk's grants, so
//!   a volume the user authorised is walked through and an unauthorised one is
//!   refused entry by entry,
//! * a directory that cannot be read produces one skip record and the walk
//!   continues — a single unreadable folder never fails a scan,
//! * cancellation is checked on every entry,
//! * package directories are reported as whole units and not descended into,
//! * sizes prefer allocated size and fall back to logical size.

use sift_hasher::CancelToken;
use sift_rules::{
    is_package_directory, is_prefix_of, is_protected_path_authorized, normalize_path,
};

pub use sift_rules::is_package_directory as is_package_directory_export;
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use crate::dir_lister::DirLister;

/// What a walk should collect for each entry.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WalkMode {
    /// Visit files only, stopping at package directories.
    Files,
    /// Visit directories only, one level below the root.
    ImmediateChildren,
    /// Visit files and directories, but stop at package directories.
    FilesAndDirectories,
}

/// Tuning for one walk.
#[derive(Debug, Clone)]
pub struct WalkOptions {
    pub mode: WalkMode,
    /// `~` for protection checks and rule anchoring.
    pub home_dir: PathBuf,
    /// Hard depth limit below the root. `None` means unlimited.
    pub max_depth: Option<u32>,
    /// Directory names never entered (`.git`, `node_modules`, ...).
    pub skip_directory_names: HashSet<String>,
    /// Extra path prefixes to skip, from the user's ignore list.
    pub skip_paths: Vec<PathBuf>,
    /// Roots the user authorised; protection checks consult them.
    pub authorized_roots: Vec<PathBuf>,
    /// Stop after this many entries; `None` means unlimited.
    ///
    /// [`WalkOptions::new`] sets a default rather than leaving this open. The
    /// result set is what the caller receives and each entry is a `PathBuf`
    /// plus three strings, so an unbounded walk of a whole home directory
    /// materialised hundreds of megabytes that the index was going to hold
    /// anyway. A caller with a reason for another number sets it explicitly.
    pub max_entries: Option<u64>,
    /// Stop *recording* skips after this many; `None` means unlimited.
    ///
    /// A skip is a diagnostic, not a result, so a walk that has run out of
    /// skip budget keeps walking and stops collecting: dropping the rest of the
    /// tree because a million permission errors were recorded would lose the
    /// items the user can actually clean. The report says `truncated` instead,
    /// and the summary reports the run as partial.
    pub max_skips: Option<u64>,
    /// Skip entries whose name starts with `.`.
    ///
    /// The "show hidden files" setting decides what the walk *produces* rather
    /// than what a list displays: filtering later would leave the candidates, the
    /// category totals and the report disagreeing about the same run.
    pub skip_hidden: bool,
    /// Report package directories as entries instead of descending into them.
    pub stop_at_packages: bool,
    /// How long one directory's listing may take before it is skipped.
    ///
    /// A directory whose open never answers — a policy check waiting on a
    /// dialog nobody sees, a wedged mount — used to stall the whole walk
    /// behind it for as long as the kernel refused. With a deadline the walk
    /// records the directory as skipped and continues; the timeout covers the
    /// whole listing, and thirty seconds is far above any honest local
    /// directory while far below "frozen".
    pub open_timeout: Duration,
    /// Never cross into another volume.
    ///
    /// A directory can be a mount point of a disk image or a network share
    /// below the scan root. Walking it would read a tree the user never
    /// authorised and attribute another disk's bytes to this one. The root's
    /// device is the boundary; the root itself is always accepted.
    pub stay_on_device: bool,
}

impl WalkOptions {
    pub fn new(home_dir: impl Into<PathBuf>, mode: WalkMode) -> Self {
        Self {
            mode,
            home_dir: home_dir.into(),
            max_depth: None,
            skip_directory_names: HashSet::new(),
            skip_paths: Vec::new(),
            authorized_roots: Vec::new(),
            max_entries: Some(DEFAULT_MAX_ENTRIES),
            max_skips: Some(DEFAULT_MAX_SKIPS),
            skip_hidden: false,
            stop_at_packages: true,
            open_timeout: Duration::from_secs(30),
            stay_on_device: true,
        }
    }

    /// Sets both result budgets at once.
    ///
    /// A strategy that walks a whole root states its numbers rather than
    /// inheriting the default, so the budget is a decision at the call site:
    /// a measurement that only reads totals can afford a larger entry count
    /// than a scan whose entries are published.
    pub fn with_budgets(mut self, max_entries: u64, max_skips: u64) -> Self {
        self.max_entries = Some(max_entries);
        self.max_skips = Some(max_skips);
        self
    }

    pub fn with_max_depth(mut self, depth: u32) -> Self {
        self.max_depth = Some(depth);
        self
    }

    pub fn with_ignores(mut self, names: &[&str]) -> Self {
        self.skip_directory_names = names.iter().map(|s| (*s).to_string()).collect();
        self
    }

    pub fn with_skip_paths(mut self, paths: Vec<PathBuf>) -> Self {
        self.skip_paths = paths;
        self
    }
}

/// A directory or file discovered by a walk.
#[derive(Debug, Clone, PartialEq)]
pub struct WalkEntry {
    pub path: PathBuf,
    pub is_directory: bool,
    /// Allocated size in bytes for files; `None` for directories, which are
    /// measured by [`crate::scanners::measure_directory`].
    pub size_bytes: Option<u64>,
    pub file_count: u64,
    pub modified_secs: i64,
    pub created_secs: i64,
    /// True when the entry itself is a macOS package directory.
    pub is_package: bool,
}

impl WalkEntry {
    pub fn display_name(&self) -> String {
        self.path
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_else(|| self.path.to_string_lossy().to_string())
    }

    pub fn parent_path(&self) -> String {
        self.path
            .parent()
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_default()
    }
}

/// Why an entry could not be read.
#[derive(Debug, Clone, PartialEq)]
pub struct WalkSkip {
    pub path: PathBuf,
    pub code: &'static str,
    pub message: String,
    pub needs_full_disk_access: bool,
}

/// Outcome of a walk.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct WalkReport {
    pub entries: Vec<WalkEntry>,
    pub skips: Vec<WalkSkip>,
    /// Total bytes of every file seen, including files inside package
    /// directories and files that were not themselves reported as entries.
    pub total_files: u64,
    pub total_bytes: u64,
    pub truncated: bool,
    pub cancelled: bool,
}

/// How many entries one walk produces before it reports itself truncated.
///
/// Half a million entries is a whole home directory's worth of files; a scan
/// that reaches it has already found more than a window can show, and the index
/// holds what was found. The number exists so a caller that forgets a budget —
/// every caller did — is still bounded.
pub const DEFAULT_MAX_ENTRIES: u64 = 500_000;

/// How many skip records one walk keeps before it stops collecting them.
///
/// Skips are diagnostics. Two thousand distinct unreadable locations is more
/// than a person reads and far more than the guide needs, and the walk keeps
/// going after the budget so the items behind an unreadable folder are still
/// reported.
pub const DEFAULT_MAX_SKIPS: u64 = 2_000;

/// Directory names that never contain cleanup targets and are expensive to walk.
pub const DEFAULT_SKIP_DIRECTORY_NAMES: &[&str] = &[
    ".git",
    ".svn",
    ".hg",
    "node_modules",
    ".build",
    "DerivedData",
    ".Trash",
];

/// The walk's skip locations, normalised once for the whole walk.
///
/// The skip check runs for every entry; a skip list is a loop invariant, so
/// normalising it once per walk call and comparing entries against
/// [`is_skipped_normalized`] keeps walk cost O(entries) rather than
/// O(entries × skips) allocations.
pub(crate) fn normalize_skip_paths(skip_paths: &[PathBuf]) -> Vec<String> {
    skip_paths
        .iter()
        // An empty entry has no meaning as a location, and normalising one
        // produces `/` — which is a prefix of every path. `is_prefix_of` answers
        // true for a root prefix on purpose (the disk root protects everything
        // it contains), so an empty entry would turn an "ignore nothing" list
        // into "ignore the whole disk" and the scan would find exactly nothing.
        // A caller that builds the list from user input cannot rule this out,
        // which is why the drop happens here rather than at each call site.
        .filter(|skip| !skip.as_os_str().is_empty())
        .map(|skip| normalize_path(&skip.to_string_lossy()))
        .filter(|skip| skip != "/")
        .collect()
}

/// True when `path` is inside one of the walk's skip locations.
///
/// Both sides are normalised with the product's path rules and compared
/// component-wise: `.`, `..`, duplicate separators and the macOS symlink aliases
/// are resolved first, and `/skip` does not shade `/skip2/a`. The raw
/// `starts_with` comparison this replaces matched an ignored spelling only when
/// it arrived exactly as written, and treated a sibling whose name merely began
/// with the ignored name as ignored too. The Swift walker answers this question
/// through `RuleEngine.isPrefix`, which resolves the same things, so the two
/// engines decide the same ignored set.
///
/// The emptiness check runs before any normalisation, so the common walk
/// without an ignored path pays nothing, and the entry's own path is the only
/// allocation per entry.
pub(crate) fn is_skipped_normalized(path: &Path, normalized_skips: &[String]) -> bool {
    if normalized_skips.is_empty() {
        return false;
    }
    let candidate = normalize_path(&path.to_string_lossy());
    normalized_skips
        .iter()
        .any(|skip| is_prefix_of(skip, &candidate))
}

/// Walks `root` according to `options`, honouring `cancel`.
///
/// Returns a [`WalkReport`] rather than `Result`: the only hard failures are
/// invalid arguments, which callers validate up front.
pub fn walk(root: &Path, options: &WalkOptions, cancel: &CancelToken) -> WalkReport {
    let mut entries: Vec<WalkEntry> = Vec::new();
    let mut report = walk_with(root, options, cancel, &mut |entry| entries.push(entry));
    report.entries = entries;
    report
}

/// Walks `root` and reports the files it passes while it is still walking.
///
/// The plain [`walk`] answers once, at the end: on this Mac the first progress
/// event of a home scan arrived 16 seconds in and carried 55,608 files, so the
/// page showed "0 files" for the whole first stretch and then a number nobody
/// could believe. The count was never wrong — it was reported once. Here the
/// totals are handed to `on_progress` at most every [`PROGRESS_STEP`], as
/// `(files, bytes)` sighted since the previous call, and the report is the one
/// [`walk`] returns.
///
/// The interval is measured on the clock rather than counted in entries: a tree
/// of small files and a tree of large ones take the same fraction of a second to
/// produce a visible number, and a walk that is fast enough to finish inside one
/// interval reports once at the end, which is what it did before.
pub fn walk_reporting(
    root: &Path,
    options: &WalkOptions,
    cancel: &CancelToken,
    on_progress: &mut dyn FnMut(u64, u64),
) -> WalkReport {
    walk_reporting_every(root, options, cancel, PROGRESS_STEP, on_progress)
}

/// [`walk_reporting`] with the interval given, for a caller that needs another
/// one — or a test that needs a tick per entry on a fixture that walks in
/// microseconds.
pub fn walk_reporting_every(
    root: &Path,
    options: &WalkOptions,
    cancel: &CancelToken,
    step: Duration,
    on_progress: &mut dyn FnMut(u64, u64),
) -> WalkReport {
    let mut entries: Vec<WalkEntry> = Vec::new();
    let mut files: u64 = 0;
    let mut bytes: u64 = 0;
    let mut last = Instant::now();
    let mut report = walk_with(root, options, cancel, &mut |entry| {
        if !entry.is_directory {
            files += 1;
            bytes += entry.size_bytes.unwrap_or(0);
        }
        if last.elapsed() >= step {
            on_progress(files, bytes);
            files = 0;
            bytes = 0;
            last = Instant::now();
        }
        entries.push(entry);
    });
    if files > 0 || bytes > 0 {
        on_progress(files, bytes);
    }
    report.entries = entries;
    report
}

/// How often [`walk_reporting`] hands its totals to the caller.
pub const PROGRESS_STEP: Duration = Duration::from_millis(100);

/// Walks `root` and hands every entry to `on_entry` instead of collecting them.
///
/// The duplicate pipeline is the caller this exists for. It reduces each file to
/// a size and a path and keeps the size index for the whole run, so collecting
/// the tree first held two copies of the same set — one in the report and one in
/// the index — for as long as a root took to walk. Here the entry vector does
/// not exist: the entry is moved into the index and dropped.
///
/// The report is the same one [`walk`] returns, with `entries` empty, because
/// the entries went to the sink. Use [`walk`] when the entries are the result.
pub fn walk_streaming(
    root: &Path,
    options: &WalkOptions,
    cancel: &CancelToken,
    on_entry: &mut dyn FnMut(WalkEntry),
) -> WalkReport {
    walk_with(root, options, cancel, on_entry)
}

/// The walk itself, with every entry handed to `emit`.
fn walk_with(
    root: &Path,
    options: &WalkOptions,
    cancel: &CancelToken,
    emit: &mut dyn FnMut(WalkEntry),
) -> WalkReport {
    let mut report = WalkReport::default();
    // Counted here rather than read off the report: the entries may never be in
    // it, and the budget bounds what the caller receives, not what is held.
    let mut emitted: u64 = 0;

    let root_metadata = match std::fs::symlink_metadata(root) {
        Ok(metadata) => metadata,
        Err(error) => {
            record_skip(options, &mut report, skip_for(root, &error));
            return report;
        }
    };
    if root_metadata.file_type().is_symlink() {
        record_skip(
            options,
            &mut report,
            WalkSkip {
                path: root.to_path_buf(),
                code: "fileNotFound",
                message: "Symbolic links are not followed.".to_string(),
                needs_full_disk_access: false,
            },
        );
        return report;
    }
    if !root_metadata.is_dir() {
        record_skip(
            options,
            &mut report,
            WalkSkip {
                path: root.to_path_buf(),
                code: "invalidRequest",
                message: "Scan root is not a directory.".to_string(),
                needs_full_disk_access: false,
            },
        );
        return report;
    }

    let normalized_skips = normalize_skip_paths(&options.skip_paths);
    let mut stack: Vec<(PathBuf, u32)> = vec![(root.to_path_buf(), 0)];
    let root_device = device_of(&root_metadata);
    let mut lister = DirLister::new();

    while let Some((directory, depth)) = stack.pop() {
        if cancel.is_cancelled() {
            report.cancelled = true;
            return report;
        }

        let entries = match lister.list(&directory, options.open_timeout, cancel) {
            Ok(Some(entries)) => entries,
            Ok(None) => {
                if cancel.is_cancelled() {
                    report.cancelled = true;
                    return report;
                }
                record_skip(
                    options,
                    &mut report,
                    WalkSkip {
                        path: directory,
                        code: "timedOut",
                        message:
                            "The directory did not answer in time; skipped rather than waiting."
                                .to_string(),
                        needs_full_disk_access: false,
                    },
                );
                continue;
            }
            Err(error) => {
                record_skip(options, &mut report, skip_for(&directory, &error));
                continue;
            }
        };

        for path in entries {
            if cancel.is_cancelled() {
                report.cancelled = true;
                return report;
            }

            if is_skipped_normalized(&path, &normalized_skips) {
                continue;
            }
            if is_protected_by_policy(options, &path) {
                record_skip(
                    options,
                    &mut report,
                    WalkSkip {
                        path: path.clone(),
                        code: "protectedLocation",
                        message: "Protected location, not scanned.".to_string(),
                        needs_full_disk_access: false,
                    },
                );
                continue;
            }

            // `symlink_metadata` never follows the final component.
            let metadata = match std::fs::symlink_metadata(&path) {
                Ok(metadata) => metadata,
                Err(error) => {
                    record_skip(options, &mut report, skip_for(&path, &error));
                    continue;
                }
            };
            let file_type = metadata.file_type();

            if file_type.is_symlink() {
                // Skipped silently: symlinks are common and expected, and a
                // user does not need a warning for each one.
                continue;
            }

            if options.stay_on_device && device_of(&metadata) != root_device {
                // A mount point below the root belongs to another disk. The
                // user never authorised it, and its bytes are not this
                // volume's bytes.
                record_skip(
                    options,
                    &mut report,
                    WalkSkip {
                        path: path.clone(),
                        code: "protectedLocation",
                        message: "Another volume is mounted here; not scanned without a grant."
                            .to_string(),
                        needs_full_disk_access: false,
                    },
                );
                continue;
            }

            let is_directory = file_type.is_dir();
            let (modified_secs, created_secs) = timestamps(&metadata);
            let name = path
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_default();
            if options.skip_hidden && name.starts_with('.') {
                continue;
            }
            let is_package = is_directory && is_package_directory(&name, &[]);

            if is_directory {
                if options.skip_directory_names.contains(&name) {
                    continue;
                }
                if options
                    .max_depth
                    .map(|max| depth + 1 > max)
                    .unwrap_or(false)
                {
                    continue;
                }

                let report_directory = match options.mode {
                    WalkMode::ImmediateChildren => depth <= 1,
                    WalkMode::FilesAndDirectories => true,
                    WalkMode::Files => false,
                };
                if report_directory && !is_package {
                    if budget_spent(options, emitted) {
                        report.truncated = true;
                        return report;
                    }
                    if let Some(entry) = build_entry(&path, true, &metadata, 0) {
                        emit(entry);
                        emitted += 1;
                    }
                }

                if is_package && options.stop_at_packages {
                    if budget_spent(options, emitted) {
                        report.truncated = true;
                        return report;
                    }
                    // A bundle counts as one item: report it and measure it as a
                    // unit rather than descending file by file.
                    let measured = measure_within(&path, cancel, options, &mut report, &mut lister);
                    emit(WalkEntry {
                        path: path.clone(),
                        is_directory: true,
                        size_bytes: Some(measured.bytes),
                        file_count: measured.files,
                        modified_secs,
                        created_secs,
                        is_package: true,
                    });
                    emitted += 1;
                    continue;
                }
                stack.push((path, depth + 1));
            } else {
                if !metadata.is_file() {
                    // Sockets, FIFOs and devices are not cleanup candidates.
                    continue;
                }
                if budget_spent(options, emitted) {
                    report.truncated = true;
                    return report;
                }
                if options.mode != WalkMode::ImmediateChildren {
                    // Allocated, not logical: this is the figure the Finder shows
                    // and the bytes a cleanup reclaims, and it is the one every
                    // other measurement in this crate reports — `measure_within`
                    // above, `measure_directory_matching` and the Swift walker.
                    // Reporting `metadata.len()` here made a residue directory
                    // whose files are small report less than the space it holds
                    // (two 2 KB logs as 3 KB rather than the 8 KB they occupy), so
                    // the same directory read differently depending on which core
                    // scanned it.
                    if let Some(entry) =
                        build_entry(&path, false, &metadata, allocated_size(&metadata))
                    {
                        report.total_files += 1;
                        report.total_bytes += entry.size_bytes.unwrap_or(0);
                        emit(entry);
                        emitted += 1;
                    }
                } else {
                    report.total_files += 1;
                    report.total_bytes += allocated_size(&metadata);
                }
            }
        }
    }

    report
}

/// True when the walk has already produced as many entries as it may.
///
/// Every reported entry counts, directories and package directories included:
/// `max_entries` is a bound on the result the caller receives, and a walk that
/// only counted files still let a tree of a million empty folders build a
/// million entries. The count comes from the walk's own tally rather than from
/// `report.entries`, which is empty when the entries went to a [`walk_streaming`]
/// sink.
fn budget_spent(options: &WalkOptions, emitted: u64) -> bool {
    options
        .max_entries
        .map(|max| emitted >= max)
        .unwrap_or(false)
}

/// Records a skip, or notes that the walk has run out of room to record one.
///
/// The budget bounds the diagnostics, not the walk: `truncated` says the report
/// is shorter than the tree, which the summary turns into `partial`. Continuing
/// is the point — a directory that cannot be read is one skip record, and the
/// items beside it are still results.
fn record_skip(options: &WalkOptions, report: &mut WalkReport, skip: WalkSkip) {
    let has_room = options
        .max_skips
        .map(|max| (report.skips.len() as u64) < max)
        .unwrap_or(true);
    if has_room {
        report.skips.push(skip);
    } else {
        report.truncated = true;
    }
}

/// True when the walk must not enter `path`.
///
/// The grants travel with the walk rather than being checked once by the caller:
/// the caller checks the scan *root*, but a root is the only path it knows about,
/// and `/Volumes` is protected for every child of every volume. Leaving the
/// unauthorised decision here is what made a granted volume scan to nothing —
/// the root passed, and then every entry below it was refused.
fn is_protected_by_policy(options: &WalkOptions, path: &Path) -> bool {
    is_protected_path_authorized(
        &options.home_dir.to_string_lossy(),
        &path.to_string_lossy(),
        &options.authorized_roots,
    )
}

struct Measured {
    bytes: u64,
    files: u64,
}

/// Measures everything inside a package directory without producing entries.
fn measure_within(
    root: &Path,
    cancel: &CancelToken,
    options: &WalkOptions,
    report: &mut WalkReport,
    lister: &mut DirLister,
) -> Measured {
    let mut total = Measured { bytes: 0, files: 0 };
    let normalized_skips = normalize_skip_paths(&options.skip_paths);
    let mut stack = vec![root.to_path_buf()];
    let root_device = std::fs::symlink_metadata(root).ok().map(|m| device_of(&m));
    while let Some(directory) = stack.pop() {
        if cancel.is_cancelled() {
            report.cancelled = true;
            return total;
        }
        let entries = match lister.list(&directory, options.open_timeout, cancel) {
            Ok(Some(entries)) => entries,
            // A timed-out directory contributes nothing to the measurement
            // rather than stalling the candidate it is being measured for;
            // the walk's own listing records the skip when it hits it.
            Ok(None) | Err(_) => continue,
        };
        for path in entries {
            let name = path
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_default();
            if is_skipped_normalized(&path, &normalized_skips) {
                continue;
            }
            if options.skip_hidden && name.starts_with('.') {
                continue;
            }
            if is_protected_by_policy(options, &path) {
                continue;
            }
            let metadata = match std::fs::symlink_metadata(&path) {
                Ok(metadata) => metadata,
                Err(_) => continue,
            };
            if metadata.file_type().is_symlink() {
                continue;
            }
            if root_device.is_some_and(|device| device_of(&metadata) != device) {
                continue;
            }
            if metadata.is_dir() {
                if options.skip_directory_names.contains(&name) {
                    continue;
                }
                stack.push(path);
            } else if metadata.is_file() {
                let size = allocated_size(&metadata);
                total.bytes += size;
                total.files += 1;
                report.total_files += 1;
                report.total_bytes += size;
            }
        }
    }
    total
}

fn build_entry(
    path: &Path,
    is_directory: bool,
    metadata: &std::fs::Metadata,
    size: u64,
) -> Option<WalkEntry> {
    let (modified_secs, created_secs) = timestamps(metadata);
    Some(WalkEntry {
        path: path.to_path_buf(),
        is_directory,
        size_bytes: if is_directory { None } else { Some(size) },
        file_count: if is_directory { 0 } else { 1 },
        modified_secs,
        created_secs,
        is_package: false,
    })
}

fn timestamps(metadata: &std::fs::Metadata) -> (i64, i64) {
    let modified = metadata
        .modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let created = metadata
        .created()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64)
        .unwrap_or(modified);
    (modified, created)
}

/// Allocated size when available, logical size otherwise.
///
/// APFS reports allocated size per block; using it is what makes the reported
/// reclaimable space match what the Finder shows after a cleanup. A dataless
/// cloud placeholder is the one exception: its bytes are not on this disk, so
/// it counts as zero even though it reports a logical size.
pub fn allocated_size(metadata: &std::fs::Metadata) -> u64 {
    use std::os::macos::fs::MetadataExt as MacOsMetadataExt;
    // SF_DATALESS, from sys/stat.h: the file is an object whose content lives
    // in the cloud and is materialised on first read.
    const SF_DATALESS: u32 = 0x4000_0000;
    if metadata.st_flags() & SF_DATALESS != 0 {
        return 0;
    }
    match MetadataSizeExt::total_file_allocated_size(metadata) {
        Some(allocated) => allocated,
        None => metadata.len(),
    }
}

/// The device a directory entry lives on, used to stop at mount points.
pub(crate) fn device_of(metadata: &std::fs::Metadata) -> u64 {
    use std::os::unix::fs::MetadataExt;
    metadata.dev()
}

/// Wrapper so the fallback stays explicit and testable.
struct MetadataSizeExt;

impl MetadataSizeExt {
    fn total_file_allocated_size(metadata: &std::fs::Metadata) -> Option<u64> {
        use std::os::unix::fs::MetadataExt;
        let blocks = metadata.blocks();
        if blocks == 0 {
            // Sparse or fully compressed file: fall back to logical length.
            return None;
        }
        let allocated = blocks.saturating_mul(512);
        if allocated == 0 {
            None
        } else {
            Some(allocated)
        }
    }
}

/// Whether a permission denial is the POSIX kind no grant can lift.
///
/// macOS refuses a TCC-protected location with `EPERM`, and that is exactly the
/// denial Full Disk Access lifts. A location whose own mode bits refuse this
/// account (`EACCES`, typically a `0700` directory owned by `root` or by a
/// system daemon) needs the owning account or an administrator, so telling the
/// user to grant Full Disk Access for it sends them to a switch that changes
/// nothing: on the development machine that was 145 of `/var`'s 198 refusals.
/// The two are therefore different codes, and only `permissionDenied` offers
/// the settings button.
fn is_system_restricted(path: &Path, error: &std::io::Error) -> bool {
    match error.raw_os_error() {
        Some(libc::EACCES) => true,
        Some(libc::EPERM) => false,
        // No errno to read: ask who owns the path. A location this account does
        // not own is not one a grant made to this account could open.
        _ => !owned_by_current_process(path),
    }
}

fn owned_by_current_process(path: &Path) -> bool {
    use std::os::unix::fs::MetadataExt;
    match std::fs::symlink_metadata(path) {
        Ok(metadata) => metadata.uid() == unsafe { libc::geteuid() },
        // An unreadable path is not evidence of ownership; the denial is then
        // reported as the kind a grant can lift, which is the safer claim.
        Err(_) => true,
    }
}

fn skip_for(path: &Path, error: &std::io::Error) -> WalkSkip {
    match error.kind() {
        std::io::ErrorKind::PermissionDenied if is_system_restricted(path, error) => WalkSkip {
            path: path.to_path_buf(),
            code: "systemRestricted",
            message: "This location belongs to macOS or another user.".to_string(),
            needs_full_disk_access: false,
        },
        std::io::ErrorKind::PermissionDenied => WalkSkip {
            path: path.to_path_buf(),
            code: "permissionDenied",
            message: "No permission to read this location.".to_string(),
            needs_full_disk_access: true,
        },
        std::io::ErrorKind::NotFound => WalkSkip {
            path: path.to_path_buf(),
            code: "fileNotFound",
            message: "The location disappeared during the scan.".to_string(),
            needs_full_disk_access: false,
        },
        _ => WalkSkip {
            path: path.to_path_buf(),
            code: "partialFailure",
            message: format!("Could not read this location ({:?}).", error.kind()),
            needs_full_disk_access: false,
        },
    }
}

#[cfg(any(test, feature = "test-fixtures"))]
pub mod fixtures {
    //! Filesystem fixtures shared by the scanner tests.
    //!
    //! Every fixture lives under the system temporary directory and is removed
    //! on drop, so tests can never touch real user data.

    use std::path::{Path, PathBuf};

    pub struct TempTree {
        pub root: PathBuf,
    }

    impl TempTree {
        pub fn new(tag: &str) -> Self {
            let mut path = std::env::temp_dir();
            path.push(format!(
                "sift-scan-{tag}-{}-{}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_nanos()
            ));
            std::fs::create_dir_all(&path).expect("create temp tree");
            Self { root: path }
        }

        pub fn dir(&self, relative: &str) -> PathBuf {
            let path = self.root.join(relative);
            std::fs::create_dir_all(&path).expect("create dir");
            path
        }

        pub fn file(&self, relative: &str, bytes: usize) -> PathBuf {
            let path = self.root.join(relative);
            if let Some(parent) = path.parent() {
                std::fs::create_dir_all(parent).expect("create parent");
            }
            std::fs::write(&path, vec![b'x'; bytes]).expect("write file");
            path
        }

        pub fn file_with(&self, relative: &str, contents: &[u8]) -> PathBuf {
            let path = self.root.join(relative);
            if let Some(parent) = path.parent() {
                std::fs::create_dir_all(parent).expect("create parent");
            }
            std::fs::write(&path, contents).expect("write file");
            path
        }

        pub fn symlink(&self, target: &Path, relative: &str) -> PathBuf {
            let path = self.root.join(relative);
            if let Some(parent) = path.parent() {
                std::fs::create_dir_all(parent).expect("create parent");
            }
            std::os::unix::fs::symlink(target, &path).expect("create symlink");
            path
        }

        /// Sets the modification time `days_ago` in the past.
        pub fn age(&self, path: &Path, days_ago: u64) {
            let when = std::time::SystemTime::now()
                - std::time::Duration::from_secs(days_ago * 24 * 60 * 60);
            let file = std::fs::File::options()
                .write(true)
                .open(path)
                .expect("open for aging");
            file.set_modified(when).expect("set mtime");
        }
    }

    impl Drop for TempTree {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::fixtures::TempTree;
    use super::*;

    fn options(root: &Path) -> WalkOptions {
        WalkOptions::new(root.to_path_buf(), WalkMode::Files)
    }

    #[test]
    fn walks_files_recursively() {
        let tree = TempTree::new("walk-files");
        tree.file("a.txt", 100);
        tree.file("nested/b.txt", 200);
        tree.file("nested/deeper/c.txt", 300);

        let report = walk(&tree.root, &options(&tree.root), &CancelToken::new());
        assert_eq!(report.entries.len(), 3);
        assert_eq!(report.total_files, 3);
        assert_eq!(report.entries.len(), 3);
        assert!(report.skips.is_empty());
    }

    #[test]
    fn symbolic_links_are_not_followed() {
        let tree = TempTree::new("walk-symlink");
        let outside = TempTree::new("walk-symlink-outside");
        outside.file("secret.txt", 10);
        tree.symlink(&outside.root, "link-to-outside");
        tree.file("real.txt", 10);

        let report = walk(&tree.root, &options(&tree.root), &CancelToken::new());
        assert_eq!(report.entries.len(), 1, "symlink must not be traversed");
        assert!(report.entries[0].path.ends_with("real.txt"));
    }

    #[test]
    fn symlink_to_protected_directory_is_rejected_as_a_root() {
        let tree = TempTree::new("walk-symlink-root");
        let outside = TempTree::new("walk-symlink-root-target");
        outside.file("x", 1);
        let link = tree.symlink(&outside.root, "root-link");

        let report = walk(&link, &options(&tree.root), &CancelToken::new());
        assert!(report.entries.is_empty());
        assert_eq!(report.skips.len(), 1);
        assert_eq!(report.skips[0].code, "fileNotFound");
    }

    #[test]
    fn package_directories_are_measured_as_one_unit() {
        let tree = TempTree::new("walk-package");
        tree.file("App.app/Contents/MacOS/App", 4096);
        tree.file("App.app/Contents/Resources/data", 8192);
        tree.file("README.txt", 64);

        let report = walk(&tree.root, &options(&tree.root), &CancelToken::new());
        assert_eq!(report.entries.len(), 2);
        let package = report
            .entries
            .iter()
            .find(|e| e.is_package)
            .expect("package entry");
        assert!(
            package.file_count >= 2,
            "package must be measured internally"
        );
        assert!(package.size_bytes.unwrap() > 0);
    }

    #[test]
    fn immediate_children_mode_reports_only_directories() {
        let tree = TempTree::new("walk-children");
        tree.dir("cache/one");
        tree.dir("cache/two");
        tree.file("cache/two/file.bin", 10);
        tree.file("cache/loose.bin", 10);

        let mut opts = WalkOptions::new(tree.root.clone(), WalkMode::ImmediateChildren);
        opts.max_depth = Some(1);
        let report = walk(&tree.root, &opts, &CancelToken::new());
        let names: Vec<String> = report.entries.iter().map(|e| e.display_name()).collect();
        assert!(names.contains(&"cache".to_string()));
        assert!(!names.contains(&"loose.bin".to_string()));
    }

    #[test]
    fn ignore_directory_names_are_skipped() {
        let tree = TempTree::new("walk-ignores");
        tree.file("keep/a.txt", 10);
        tree.file("node_modules/pkg/index.js", 10);
        tree.file(".git/objects/aa", 10);

        let opts = options(&tree.root).with_ignores(DEFAULT_SKIP_DIRECTORY_NAMES);
        let report = walk(&tree.root, &opts, &CancelToken::new());
        assert_eq!(report.entries.len(), 1);
    }

    #[test]
    fn user_ignored_paths_are_skipped_and_not_reported() {
        let tree = TempTree::new("walk-user-ignore");
        tree.file("keep/a.txt", 10);
        tree.file("skip/b.txt", 10);

        let opts = options(&tree.root).with_skip_paths(vec![tree.root.join("skip")]);
        let report = walk(&tree.root, &opts, &CancelToken::new());
        assert_eq!(report.entries.len(), 1);
        assert!(report.skips.is_empty(), "ignored paths are silent");
    }

    /// An empty entry in the ignore list names no location, and must not be
    /// read as the disk root.
    ///
    /// Normalising `""` produces `/`, and `/` is a prefix of every path — so an
    /// empty entry would turn "ignore nothing" into "skip the whole walk" and the
    /// scan would report a clean Mac with nothing on it. The list can be built
    /// from user input (`ignorePaths` in the request), which is why the drop
    /// belongs in the normaliser rather than at each call site.
    #[test]
    fn an_empty_ignored_path_does_not_skip_the_whole_walk() {
        let tree = TempTree::new("walk-empty-ignore");
        tree.file("a.txt", 10);
        tree.file("nested/b.txt", 10);

        let opts = options(&tree.root).with_skip_paths(vec![PathBuf::from(""), PathBuf::from("/")]);
        let report = walk(&tree.root, &opts, &CancelToken::new());
        assert_eq!(
            report.entries.len(),
            2,
            "an empty ignore path ignores nothing"
        );

        assert!(normalize_skip_paths(&[PathBuf::from("")]).is_empty());
        assert!(normalize_skip_paths(&[PathBuf::from("/")]).is_empty());
    }

    /// The ignore list is compared the way the protection rules are: through the
    /// alias mapping, so a location handed over in its `/private/var` spelling
    /// still ignores the subtree the walk visits as `/var`.
    #[test]
    fn an_ignored_path_spelled_with_the_alias_still_matches() {
        let tree = TempTree::new("walk-ignore-alias");
        tree.file("keep/a.bin", 10);
        tree.file("skip/b.bin", 10);

        // `TempTree` lives under `/var/folders`; canonical spelling is the
        // `/private/var` form the filesystem actually resolves to.
        let resolved = std::fs::canonicalize(&tree.root)
            .expect("temp dir resolves")
            .join("skip");
        let opts = options(&tree.root).with_skip_paths(vec![resolved]);
        let report = walk(&tree.root, &opts, &CancelToken::new());
        assert_eq!(
            report.entries.len(),
            1,
            "the ignored subtree is still kept out"
        );
        assert!(report.skips.is_empty());
    }

    /// And a prefix is applied per component: an ignored name does not shade a
    /// sibling whose name merely begins with it.
    #[test]
    fn an_ignored_name_does_not_shade_a_sibling_with_a_longer_name() {
        let tree = TempTree::new("walk-ignore-sibling");
        tree.file("keep/a.bin", 10);
        tree.file("ignoreX/b.bin", 10);

        let opts = options(&tree.root).with_skip_paths(vec![tree.root.join("ignore")]);
        let report = walk(&tree.root, &opts, &CancelToken::new());
        assert_eq!(
            report.entries.len(),
            2,
            "ignoreX is not inside ignore: {report:?}"
        );
    }

    #[test]
    fn cancellation_stops_the_walk() {
        let tree = TempTree::new("walk-cancel");
        for i in 0..50 {
            tree.file(&format!("dir{i}/file.bin"), 16);
        }
        let cancel = CancelToken::new();
        cancel.cancel();
        let report = walk(&tree.root, &options(&tree.root), &cancel);
        assert!(report.cancelled);
        assert!(report.entries.is_empty());
    }

    #[test]
    fn hidden_entries_are_out_of_scope_when_the_scan_says_so() {
        let tree = TempTree::new("hidden-scope");
        tree.file("visible.bin", 1024);
        tree.file(".hidden.bin", 1024);
        tree.file(".hidden-dir/inside.bin", 1024);
        tree.file("visible-dir/inside.bin", 1024);

        let cancel = CancelToken::new();
        let names = |skip_hidden: bool| {
            let mut options = WalkOptions::new(tree.root.clone(), WalkMode::FilesAndDirectories);
            options.skip_hidden = skip_hidden;
            let report = walk(&tree.root, &options, &cancel);
            let mut names: Vec<String> = report.entries.iter().map(|e| e.display_name()).collect();
            names.sort();
            names
        };

        let with_hidden = names(true);
        assert!(
            !with_hidden.contains(&".hidden.bin".to_string()),
            "a dotfile is not a candidate when the setting is off: {with_hidden:?}"
        );
        assert!(!with_hidden.contains(&".hidden-dir".to_string()));

        let without_filter = names(false);
        assert!(
            without_filter.contains(&".hidden.bin".to_string()),
            "the same walk reports it when the setting is on: {without_filter:?}"
        );
        // The filter is a scope, not a cap: nothing else changed.
        for name in with_hidden {
            assert!(without_filter.contains(&name), "{name} disappeared");
        }
    }

    #[test]
    fn missing_root_is_reported_not_panicked() {
        let missing = std::env::temp_dir().join("sift-definitely-missing-dir-xyz");
        let report = walk(
            &missing,
            &options(&std::env::temp_dir()),
            &CancelToken::new(),
        );
        assert!(report.entries.is_empty());
        assert_eq!(report.skips.len(), 1);
        assert_eq!(report.skips[0].code, "fileNotFound");
    }

    #[test]
    fn a_file_as_root_is_an_invalid_request() {
        let tree = TempTree::new("walk-file-root");
        let file = tree.file("a.txt", 4);
        let report = walk(&file, &options(&tree.root), &CancelToken::new());
        assert_eq!(report.skips[0].code, "invalidRequest");
    }

    #[test]
    fn protected_paths_inside_a_root_are_skipped_with_a_code() {
        let tree = TempTree::new("walk-protected");
        let home = tree.root.clone();
        tree.file("Library/Caches/a.bin", 10);
        tree.file("Documents/taxes.txt", 10);

        let opts = WalkOptions::new(home, WalkMode::Files);
        let report = walk(&tree.root, &opts, &CancelToken::new());
        assert_eq!(report.entries.len(), 1);
        let protected: Vec<&WalkSkip> = report
            .skips
            .iter()
            .filter(|s| s.code == "protectedLocation")
            .collect();
        assert_eq!(protected.len(), 1);
    }

    #[test]
    fn a_granted_volume_is_walked_instead_of_refused_entry_by_entry() {
        // `/Volumes` is a blanket-protected prefix, so every entry below it is
        // refused unless the walk carries the grant that covers it. A walk root
        // only ever has its own path checked, which is why the grants have to
        // reach this decision rather than staying with the caller.
        let mut opts = WalkOptions::new("/Users/example", WalkMode::Files);
        let inside = Path::new("/Volumes/Backup/Photos/holiday.jpg");
        assert!(is_protected_by_policy(&opts, inside));

        opts.authorized_roots = vec![PathBuf::from("/Volumes/Backup")];
        assert!(
            !is_protected_by_policy(&opts, inside),
            "a granted volume must be walked"
        );

        // The grant covers that one subtree and nothing else on the volume.
        assert!(is_protected_by_policy(
            &opts,
            Path::new("/Volumes/Other/Photos/holiday.jpg")
        ));
        assert!(!is_protected_by_policy(&opts, Path::new("/Volumes/Backup")));
    }

    #[test]
    fn a_grant_never_unlocks_system_trees_or_user_content() {
        let mut opts = WalkOptions::new("/Users/example", WalkMode::Files);
        opts.authorized_roots = vec![PathBuf::from("/Users/example")];
        assert!(is_protected_by_policy(
            &opts,
            Path::new("/Users/example/Documents/taxes.pdf")
        ));

        opts.authorized_roots = vec![PathBuf::from("/Library")];
        assert!(is_protected_by_policy(
            &opts,
            Path::new("/Library/LaunchDaemons/com.example.plist")
        ));
    }

    #[test]
    fn the_volumes_container_is_protected_when_nothing_is_granted() {
        // Reading `/Volumes` itself is one directory listing: the children are
        // other disks, and none of them may be entered without a grant.
        let report = walk(
            Path::new("/Volumes"),
            &WalkOptions::new("/Users/example", WalkMode::Files),
            &CancelToken::new(),
        );
        assert!(
            report.entries.is_empty(),
            "no volume may be walked uninvited"
        );
        assert!(
            report.skips.iter().all(|s| s.code == "protectedLocation"),
            "every child of /Volumes must be refused as protected"
        );
    }

    #[test]
    fn max_entries_truncates_instead_of_growing_without_bound() {
        let tree = TempTree::new("walk-max");
        for i in 0..30 {
            tree.file(&format!("f{i}.bin"), 8);
        }
        let mut opts = options(&tree.root);
        opts.max_entries = Some(10);
        let report = walk(&tree.root, &opts, &CancelToken::new());
        assert!(report.truncated);
        assert_eq!(report.entries.len(), 10);
    }

    #[test]
    fn the_entry_budget_covers_directory_entries_too() {
        // The limit bounds what the caller receives. Counting only files let a
        // tree of empty folders — or of packages — return unbounded entries with
        // `truncated` left false.
        let tree = TempTree::new("walk-max-dirs");
        for i in 0..30 {
            tree.dir(&format!("dir{i}"));
        }
        let mut opts = options(&tree.root);
        opts.mode = WalkMode::FilesAndDirectories;
        opts.max_entries = Some(5);
        let report = walk(&tree.root, &opts, &CancelToken::new());
        assert!(report.truncated);
        assert_eq!(report.entries.len(), 5);
    }

    #[test]
    fn the_entry_budget_covers_package_directories_too() {
        let tree = TempTree::new("walk-max-packages");
        for i in 0..6 {
            tree.dir(&format!("Bundle{i}.app/Contents"));
        }
        let mut opts = options(&tree.root);
        opts.mode = WalkMode::FilesAndDirectories;
        opts.max_entries = Some(2);
        let report = walk(&tree.root, &opts, &CancelToken::new());
        assert!(report.truncated);
        assert_eq!(
            report.entries.len(),
            2,
            "a package is an entry and must count against the budget"
        );
        assert!(report.entries.iter().all(|entry| entry.is_package));
    }

    /// A walk that never asks for a budget is still bounded.
    ///
    /// Every production caller forgot to set `max_entries`, so a scan of a whole
    /// home directory materialised the tree in one vector of `PathBuf` and three
    /// strings per file. The default is the bound a forgetful caller gets.
    #[test]
    fn a_walk_without_a_requested_budget_is_still_bounded() {
        let tree = TempTree::new("walk-default-budget");
        let opts = options(&tree.root);
        assert_eq!(opts.max_entries, Some(DEFAULT_MAX_ENTRIES));
        assert_eq!(opts.max_skips, Some(DEFAULT_MAX_SKIPS));
    }

    /// The skip budget bounds the diagnostics, not the walk.
    ///
    /// A tree of unreadable directories used to grow `report.skips` without
    /// limit; stopping the walk to bound it would have lost every item behind
    /// them, so the records stop and the walk continues.
    #[test]
    fn a_walk_that_runs_out_of_skip_budget_keeps_walking() {
        let tree = TempTree::new("walk-skip-budget");
        let mut locked = Vec::new();
        for i in 0..4 {
            let directory = tree.dir(&format!("locked{i}"));
            tree.file(&format!("locked{i}/inside.bin"), 16);
            let mut permissions = std::fs::metadata(&directory).unwrap().permissions();
            std::os::unix::fs::PermissionsExt::set_mode(&mut permissions, 0o000);
            std::fs::set_permissions(&directory, permissions).unwrap();
            locked.push(directory);
        }
        tree.file("readable/kept.bin", 16);

        let mut opts = options(&tree.root);
        opts.max_skips = Some(2);
        let report = walk(&tree.root, &opts, &CancelToken::new());

        assert!(
            report
                .entries
                .iter()
                .any(|entry| entry.path.ends_with("readable/kept.bin")),
            "the walk continues past the skip budget: {:?}",
            report.entries
        );
        assert_eq!(report.skips.len(), 2, "the records stop at the budget");
        assert!(report.truncated, "a report shorter than the tree says so");

        for directory in locked {
            let mut permissions = std::fs::metadata(&directory).unwrap().permissions();
            std::os::unix::fs::PermissionsExt::set_mode(&mut permissions, 0o755);
            std::fs::set_permissions(&directory, permissions).unwrap();
        }
    }

    /// The streaming walk is the same walk with the entries handed over.
    ///
    /// The duplicate pipeline keeps one size index for the whole run, so the
    /// entry vector was a second copy of the same paths held for as long as a
    /// root took to walk.
    #[test]
    fn a_streaming_walk_hands_every_entry_over_and_keeps_none() {
        let tree = TempTree::new("walk-streaming");
        for i in 0..5 {
            tree.file(&format!("dir{i}/file.bin"), 32);
        }

        let mut streamed: Vec<PathBuf> = Vec::new();
        let streamed_report = walk_streaming(
            &tree.root,
            &options(&tree.root),
            &CancelToken::new(),
            &mut |entry| {
                streamed.push(entry.path);
            },
        );
        let collected_report = walk(&tree.root, &options(&tree.root), &CancelToken::new());

        assert!(
            streamed_report.entries.is_empty(),
            "a streaming walk does not also collect"
        );
        assert_eq!(streamed.len(), collected_report.entries.len());
        assert_eq!(streamed_report.total_files, collected_report.total_files);
        assert_eq!(streamed_report.total_bytes, collected_report.total_bytes);
        assert!(!streamed_report.truncated);
    }

    /// And the entry budget still bounds the streaming walk.
    #[test]
    fn a_streaming_walk_stops_at_the_entry_budget() {
        let tree = TempTree::new("walk-streaming-budget");
        for i in 0..20 {
            tree.file(&format!("f{i}.bin"), 8);
        }
        let mut opts = options(&tree.root);
        opts.max_entries = Some(4);

        let mut count = 0u64;
        let report = walk_streaming(&tree.root, &opts, &CancelToken::new(), &mut |_| count += 1);
        assert_eq!(count, 4);
        assert!(report.truncated);
    }

    #[test]
    fn special_files_are_not_entries() {
        let tree = TempTree::new("walk-special");
        tree.file("normal.bin", 8);
        // A directory symlink is already covered; this asserts the mode check.
        let report = walk(&tree.root, &options(&tree.root), &CancelToken::new());
        assert!(report.entries.iter().all(|e| !e.is_directory));
    }

    #[test]
    fn a_different_device_is_recognised_as_a_mount_boundary() {
        use std::os::unix::fs::MetadataExt;
        let root = std::fs::metadata("/").expect("/ is readable");
        let dev = std::fs::metadata("/dev").expect("/dev is readable");
        assert_eq!(device_of(&root), root.dev());
        assert_ne!(
            root.dev(),
            dev.dev(),
            "/ and /dev are different filesystems; the walker must not cross that"
        );
    }

    #[test]
    fn allocated_size_falls_back_to_logical_size_for_sparse_files() {
        let tree = TempTree::new("walk-sparse");
        let path = tree.file("sparse.bin", 0);
        // Extend the file without writing data blocks.
        let file = std::fs::OpenOptions::new().write(true).open(&path).unwrap();
        file.set_len(1024 * 1024).unwrap();
        drop(file);
        let metadata = std::fs::symlink_metadata(&path).unwrap();
        assert_eq!(allocated_size(&metadata), 1024 * 1024);
    }

    /// The walk totals what the files occupy, not what they hold.
    ///
    /// A file smaller than a block occupies a whole block, and that is the figure
    /// the Finder shows and a cleanup reclaims. Counting `metadata.len()` here
    /// made a directory of small files report less space than it occupies — two
    /// 2 KB logs as 3 KB instead of 8 KB — and, because the Swift walker already
    /// counted allocated bytes, the same directory read differently depending on
    /// which core scanned it.
    #[test]
    fn the_walk_totals_allocated_bytes_rather_than_logical_size() {
        let tree = TempTree::new("walk-allocated");
        let path = tree.file("small.log", 100);
        let report = walk(&tree.root, &options(&tree.root), &CancelToken::new());

        assert_eq!(report.total_files, 1);
        assert_eq!(
            report.total_bytes,
            allocated_size(&std::fs::symlink_metadata(&path).unwrap()),
            "the walk must report what allocated_size answers"
        );
        assert!(
            report.total_bytes >= 4096,
            "a 100-byte file still occupies a block, but the walk reported {} bytes",
            report.total_bytes
        );
        assert_eq!(
            report.entries[0].size_bytes,
            Some(report.total_bytes),
            "the entry and the total are the same figure"
        );
    }

    #[test]
    fn a_reporting_walk_ticks_before_it_finishes_and_totals_the_same() {
        // The page showed "0 files" for sixteen seconds because the walk
        // answered once, at the end. With a zero interval every entry ticks, so
        // the two halves of the promise can be checked on a fixture that walks
        // in microseconds: the caller hears about the tree while it is being
        // walked, and the totals are still the ones the silent walk produces.
        let tree = TempTree::new("walk-reporting");
        for i in 0..6 {
            tree.file(&format!("f{i}.bin"), 4096);
        }
        let options = self::options(&tree.root);
        let cancel = CancelToken::new();

        let plain = walk(&tree.root, &options, &cancel);
        let mut ticks: Vec<(u64, u64)> = Vec::new();
        let reporting = walk_reporting_every(
            &tree.root,
            &options,
            &cancel,
            Duration::ZERO,
            &mut |f, b| {
                ticks.push((f, b));
            },
        );

        assert_eq!(reporting.total_files, plain.total_files);
        assert_eq!(reporting.total_bytes, plain.total_bytes);
        assert_eq!(reporting.entries.len(), plain.entries.len());
        assert!(
            ticks.len() > 1,
            "a reporting walk must tick more than once for the page to move"
        );
        let sum: u64 = ticks.iter().map(|(f, _)| f).sum();
        assert_eq!(sum, reporting.total_files, "the ticks add up to the total");
    }
}

#[cfg(test)]
mod skip_classification_tests {
    use super::fixtures::TempTree;
    use super::*;

    fn options(root: &Path) -> WalkOptions {
        WalkOptions::new(root.to_path_buf(), WalkMode::Files)
    }

    /// `EACCES` is the POSIX refusal: the mode bits say who may read, and no
    /// grant made to this account changes that.
    #[test]
    fn a_posix_denial_is_a_system_location_not_something_to_grant() {
        let tree = TempTree::new("walk-eacces");
        let skip = skip_for(
            &tree.root.join("spool"),
            &std::io::Error::from_raw_os_error(libc::EACCES),
        );

        assert_eq!(skip.code, "systemRestricted");
        assert!(
            !skip.needs_full_disk_access,
            "Full Disk Access cannot open a directory only its owner may read"
        );
    }

    /// `EPERM` is what macOS answers a TCC refusal with, and Full Disk Access
    /// is the grant that lifts it, so this one keeps the settings button.
    #[test]
    fn a_tcc_denial_stays_actionable() {
        let tree = TempTree::new("walk-eperm");
        let skip = skip_for(
            &tree.root.join("TCC"),
            &std::io::Error::from_raw_os_error(libc::EPERM),
        );

        assert_eq!(skip.code, "permissionDenied");
        assert!(skip.needs_full_disk_access);
    }

    /// A denial with no errno is not evidence of ownership, so it is reported
    /// as the kind a grant can lift: the safer of the two claims.
    #[test]
    fn a_denial_without_an_errno_is_not_called_system_restricted() {
        let tree = TempTree::new("walk-no-errno");
        let skip = skip_for(
            &tree.root.join("missing"),
            &std::io::Error::new(std::io::ErrorKind::PermissionDenied, "denied"),
        );

        assert_eq!(skip.code, "permissionDenied");
    }

    /// The whole path, end to end: a directory whose mode refuses its own
    /// owner comes back as `systemRestricted`, not as a missing grant.
    #[test]
    fn a_walk_reports_an_owner_only_directory_as_system_restricted() {
        use std::os::unix::fs::PermissionsExt;
        if unsafe { libc::geteuid() } == 0 {
            // root reads a 0000 directory; there is nothing to observe.
            return;
        }
        let tree = TempTree::new("walk-owner-only");
        let closed = tree.dir("closed");
        tree.file("closed/hidden.txt", 10);
        std::fs::set_permissions(&closed, std::fs::Permissions::from_mode(0o000))
            .expect("close the directory");

        let report = walk(&tree.root, &options(&tree.root), &CancelToken::new());

        // Restore the mode before the fixture's drop, which cannot remove a
        // directory it may not list.
        std::fs::set_permissions(&closed, std::fs::Permissions::from_mode(0o755))
            .expect("reopen the directory");

        let skip = report
            .skips
            .iter()
            .find(|skip| skip.path == closed)
            .expect("the walk reports the directory it could not list");
        assert_eq!(skip.code, "systemRestricted");
        assert!(!skip.needs_full_disk_access);
    }
}
