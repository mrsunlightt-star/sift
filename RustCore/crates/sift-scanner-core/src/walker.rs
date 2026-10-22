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
    pub max_entries: Option<u64>,
    /// Skip entries whose name starts with `.`.
    ///
    /// The "show hidden files" setting decides what the walk *produces* rather
    /// than what a list displays: filtering later would leave the candidates, the
    /// category totals and the report disagreeing about the same run.
    pub skip_hidden: bool,
    /// Report package directories as entries instead of descending into them.
    pub stop_at_packages: bool,
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
            max_entries: None,
            skip_hidden: false,
            stop_at_packages: true,
            stay_on_device: true,
        }
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
        .map(|skip| normalize_path(&skip.to_string_lossy()))
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
    let mut report = WalkReport::default();

    let root_metadata = match std::fs::symlink_metadata(root) {
        Ok(metadata) => metadata,
        Err(error) => {
            report.skips.push(skip_for(root, &error));
            return report;
        }
    };
    if root_metadata.file_type().is_symlink() {
        report.skips.push(WalkSkip {
            path: root.to_path_buf(),
            code: "fileNotFound",
            message: "Symbolic links are not followed.".to_string(),
            needs_full_disk_access: false,
        });
        return report;
    }
    if !root_metadata.is_dir() {
        report.skips.push(WalkSkip {
            path: root.to_path_buf(),
            code: "invalidRequest",
            message: "Scan root is not a directory.".to_string(),
            needs_full_disk_access: false,
        });
        return report;
    }

    let normalized_skips = normalize_skip_paths(&options.skip_paths);
    let mut stack: Vec<(PathBuf, u32)> = vec![(root.to_path_buf(), 0)];
    let root_device = device_of(&root_metadata);

    while let Some((directory, depth)) = stack.pop() {
        if cancel.is_cancelled() {
            report.cancelled = true;
            return report;
        }

        let read_dir = match std::fs::read_dir(&directory) {
            Ok(entries) => entries,
            Err(error) => {
                report.skips.push(skip_for(&directory, &error));
                continue;
            }
        };

        for entry_result in read_dir {
            if cancel.is_cancelled() {
                report.cancelled = true;
                return report;
            }
            let entry = match entry_result {
                Ok(entry) => entry,
                Err(error) => {
                    report.skips.push(skip_for(&directory, &error));
                    continue;
                }
            };
            let path = entry.path();

            if is_skipped_normalized(&path, &normalized_skips) {
                continue;
            }
            if is_protected_by_policy(options, &path) {
                report.skips.push(WalkSkip {
                    path: path.clone(),
                    code: "protectedLocation",
                    message: "Protected location, not scanned.".to_string(),
                    needs_full_disk_access: false,
                });
                continue;
            }

            // `symlink_metadata` never follows the final component.
            let metadata = match std::fs::symlink_metadata(&path) {
                Ok(metadata) => metadata,
                Err(error) => {
                    report.skips.push(skip_for(&path, &error));
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
                report.skips.push(WalkSkip {
                    path: path.clone(),
                    code: "protectedLocation",
                    message: "Another volume is mounted here; not scanned without a grant."
                        .to_string(),
                    needs_full_disk_access: false,
                });
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
                    if budget_spent(options, &report) {
                        report.truncated = true;
                        return report;
                    }
                    if let Some(entry) = build_entry(&path, true, &metadata, 0) {
                        report.entries.push(entry);
                    }
                }

                if is_package && options.stop_at_packages {
                    if budget_spent(options, &report) {
                        report.truncated = true;
                        return report;
                    }
                    // A bundle counts as one item: report it and measure it as a
                    // unit rather than descending file by file.
                    let measured = measure_within(&path, cancel, options, &mut report);
                    report.entries.push(WalkEntry {
                        path: path.clone(),
                        is_directory: true,
                        size_bytes: Some(measured.bytes),
                        file_count: measured.files,
                        modified_secs,
                        created_secs,
                        is_package: true,
                    });
                    continue;
                }
                stack.push((path, depth + 1));
            } else {
                if !metadata.is_file() {
                    // Sockets, FIFOs and devices are not cleanup candidates.
                    continue;
                }
                if budget_spent(options, &report) {
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
                        report.entries.push(entry);
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
/// million entries.
fn budget_spent(options: &WalkOptions, report: &WalkReport) -> bool {
    options
        .max_entries
        .map(|max| report.entries.len() as u64 >= max)
        .unwrap_or(false)
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
        let read_dir = match std::fs::read_dir(&directory) {
            Ok(entries) => entries,
            Err(error) => {
                report.skips.push(skip_for(&directory, &error));
                continue;
            }
        };
        for entry in read_dir.flatten() {
            let path = entry.path();
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

fn skip_for(path: &Path, error: &std::io::Error) -> WalkSkip {
    match error.kind() {
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
}
