//! Storage analysis: volume usage, per-category rollups and the largest items.
//!
//! The specification asks three questions and warns against fancy charts: which
//! category uses the most space, which directories grew, and which files to
//! handle first. All three are answered from plain lists, so the accumulator
//! here is built for bounded memory rather than for visualisation.
//!
//! Memory bound: only `top_file_limit` files and `top_directory_limit`
//! directories are retained, no matter how many files the volume holds.

use crate::walker::{self, DEFAULT_SKIP_DIRECTORY_NAMES};
use sift_hasher::CancelToken;
use sift_rules::is_protected_path_authorized;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// Default number of large files returned.
pub const DEFAULT_TOP_FILE_LIMIT: u32 = 500;
/// Default number of directories returned.
pub const DEFAULT_TOP_DIRECTORY_LIMIT: u32 = 100;
/// Beyond this many entries the analysis aggregates instead of listing.
pub const MAX_LISTED_RESULTS: u64 = 10_000;

/// One file entry in the large-file list.
#[derive(Debug, Clone, PartialEq)]
pub struct StorageFile {
    pub path: String,
    pub display_name: String,
    pub parent_path: String,
    pub size_bytes: u64,
    pub modified_secs: i64,
}

/// One directory rollup.
#[derive(Debug, Clone, PartialEq)]
pub struct StorageDirectory {
    pub path: String,
    pub display_name: String,
    pub size_bytes: u64,
    pub file_count: u64,
}

/// Category totals for the type bar.
#[derive(Debug, Clone, PartialEq)]
pub struct StorageCategory {
    pub category: String,
    pub size_bytes: u64,
    pub file_count: u64,
}

/// Volume usage.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct VolumeInfo {
    pub mount_point: String,
    pub volume_name: String,
    pub total_bytes: u64,
    pub free_bytes: u64,
    pub used_bytes: u64,
    pub used_fraction: f64,
    pub is_external: bool,
    pub is_read_only: bool,
}

/// The whole analysis result.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct StorageAnalysis {
    pub volume: VolumeInfo,
    pub categories: Vec<StorageCategory>,
    pub top_files: Vec<StorageFile>,
    pub top_directories: Vec<StorageDirectory>,
    pub scanned_file_count: u64,
    pub scanned_byte_count: u64,
    pub skipped_count: u64,
    /// True when more entries existed than the requested listing limits.
    pub aggregated: bool,
    pub cancelled: bool,
    pub elapsed_millis: i64,
}

impl StorageAnalysis {
    /// Bytes the user can still free inside the analysed roots: only the
    /// categories that are also cleanup categories count.
    pub fn reclaimable_bytes(&self) -> u64 {
        self.categories
            .iter()
            .filter(|category| {
                matches!(
                    category.category.as_str(),
                    "applicationCache" | "logs" | "installers" | "temporaryFiles"
                )
            })
            .map(|category| category.size_bytes)
            .sum()
    }
}

/// Which bucket a file belongs to. Kept explicit so the UI can explain it.
pub fn category_for_extension(extension: &str) -> &'static str {
    match extension {
        "app" | "pkg" | "dmg" | "xip" => "installers",
        "log" | "logarchive" | "crash" | "diag" => "logs",
        "cache" | "tmp" | "temp" => "applicationCache",
        "jpg" | "jpeg" | "png" | "heic" | "tiff" | "gif" | "webp" | "raw" => "images",
        "mp4" | "mov" | "m4v" | "avi" | "mkv" | "hevc" => "video",
        "mp3" | "m4a" | "wav" | "aiff" | "flac" | "aac" => "audio",
        "pdf" | "doc" | "docx" | "xls" | "xlsx" | "ppt" | "pptx" | "pages" | "numbers" | "key"
        | "txt" | "md" | "rtf" => "documents",
        "zip" | "tar" | "gz" | "tgz" | "bz2" | "7z" | "rar" => "archives",
        "swift" | "rs" | "js" | "ts" | "py" | "go" | "java" | "c" | "cpp" | "h" | "sh" => "code",
        "sqlite" | "db" | "plist" | "json" | "xml" | "yaml" | "yml" => "data",
        _ => "other",
    }
}

/// Identifies the volume that holds `path`, without following symlinks.
pub fn volume_info(path: &Path) -> VolumeInfo {
    use std::os::unix::fs::MetadataExt;

    let fallback = VolumeInfo {
        mount_point: path.to_string_lossy().to_string(),
        volume_name: path
            .file_name()
            .map(|name| name.to_string_lossy().to_string())
            .unwrap_or_default(),
        ..Default::default()
    };
    let Ok(metadata) = std::fs::metadata(path) else {
        return fallback;
    };
    let device = metadata.dev();

    // `/` and `/Volumes/Macintosh HD` are the same device: the alias must not
    // win the longest-mount-point comparison, so every candidate is resolved
    // first and anything still under `/Volumes` is ignored as an alias or a
    // device-image mount.
    let mut best: Option<VolumeInfo> = None;
    for candidate in volume_candidates() {
        let candidate = std::fs::canonicalize(&candidate).unwrap_or(candidate);
        if candidate.starts_with("/Volumes/") {
            continue;
        }
        let Ok(candidate_metadata) = std::fs::metadata(&candidate) else {
            continue;
        };
        if candidate_metadata.dev() != device {
            continue;
        }
        let Some((total, free, is_read_only)) = filesystem_usage(&candidate) else {
            continue;
        };
        let info = VolumeInfo {
            volume_name: if candidate == Path::new("/") {
                "Macintosh HD".to_string()
            } else {
                candidate
                    .file_name()
                    .map(|name| name.to_string_lossy().to_string())
                    .unwrap_or_default()
            },
            mount_point: candidate.to_string_lossy().to_string(),
            total_bytes: total,
            free_bytes: free,
            used_bytes: total.saturating_sub(free),
            used_fraction: if total == 0 {
                0.0
            } else {
                total.saturating_sub(free) as f64 / total as f64
            },
            is_external: false,
            is_read_only,
        };
        let better = best
            .as_ref()
            .map(|current| info.mount_point.len() > current.mount_point.len())
            .unwrap_or(true);
        if better {
            best = Some(info);
        }
    }

    // Nothing matched: still report the volume the path is on, minus capacity,
    // rather than pretending the disk is empty.
    best.unwrap_or(fallback)
}

/// Description of one mounted volume, used by the storage page's volume list.
pub fn mounted_volumes() -> Vec<VolumeInfo> {
    let mut out = Vec::new();
    for candidate in volume_candidates() {
        let resolved = std::fs::canonicalize(&candidate).unwrap_or_else(|_| candidate.clone());
        if resolved.starts_with("/Volumes/") && !candidate.starts_with("/Volumes/") {
            continue;
        }
        let Some((total, free, is_read_only)) = filesystem_usage(&resolved) else {
            continue;
        };
        if total == 0 {
            continue;
        }
        let is_external = resolved.starts_with("/Volumes/");
        out.push(VolumeInfo {
            volume_name: if resolved == Path::new("/") {
                "Macintosh HD".to_string()
            } else {
                resolved
                    .file_name()
                    .map(|name| name.to_string_lossy().to_string())
                    .unwrap_or_default()
            },
            mount_point: resolved.to_string_lossy().to_string(),
            total_bytes: total,
            free_bytes: free,
            used_bytes: total.saturating_sub(free),
            used_fraction: total.saturating_sub(free) as f64 / total as f64,
            is_external,
            is_read_only,
        });
    }
    out.sort_by(|a, b| a.mount_point.cmp(&b.mount_point));
    out.dedup_by(|a, b| a.mount_point == b.mount_point);
    out
}

fn volume_candidates() -> Vec<PathBuf> {
    let mut candidates = vec![PathBuf::from("/")];
    if let Ok(entries) = std::fs::read_dir("/Volumes") {
        for entry in entries.flatten() {
            candidates.push(entry.path());
        }
    }
    candidates
}

/// `(total, free, is_read_only)` via `statfs`, with no external process.
fn filesystem_usage(path: &Path) -> Option<(u64, u64, bool)> {
    use std::ffi::CString;
    let c_path = CString::new(path.to_string_lossy().as_bytes()).ok()?;
    let mut stats: libc::statfs = unsafe { std::mem::zeroed() };
    // SAFETY: `c_path` is a valid NUL-terminated string and `stats` is a
    // correctly sized, initialised buffer for the duration of the call.
    if unsafe { libc::statfs(c_path.as_ptr(), &mut stats) } != 0 {
        return None;
    }
    let block_size = stats.f_bsize as u64;
    let total = (stats.f_blocks as u64).saturating_mul(block_size);
    let free = (stats.f_bavail as u64).saturating_mul(block_size);
    // Darwin's `MNT_RDONLY`.
    let is_read_only = stats.f_flags & 0x0000_0001 != 0;
    Some((total, free, is_read_only))
}

/// Tuning for one analysis pass.
#[derive(Debug, Clone)]
pub struct AnalysisOptions {
    pub home_dir: PathBuf,
    /// Roots the user authorised; protection checks consult them.
    pub authorized_roots: Vec<PathBuf>,
    pub roots: Vec<PathBuf>,
    pub ignore_paths: Vec<PathBuf>,
    pub top_file_limit: u32,
    pub top_directory_limit: u32,
    pub large_file_threshold_bytes: u64,
}

impl AnalysisOptions {
    pub fn new(home_dir: PathBuf, roots: Vec<PathBuf>) -> Self {
        Self {
            home_dir,
            authorized_roots: Vec::new(),
            roots,
            ignore_paths: Vec::new(),
            top_file_limit: DEFAULT_TOP_FILE_LIMIT,
            top_directory_limit: DEFAULT_TOP_DIRECTORY_LIMIT,
            large_file_threshold_bytes: 1024 * 1024 * 1024,
        }
    }
}

/// Accumulates the analysis while walking.
///
/// Directory sizes are rolled up as files are visited, so a file five levels
/// deep contributes to each ancestor's total without the accumulator holding a
/// tree.
struct Accumulator {
    options: AnalysisOptions,
    started: std::time::Instant,
    categories: HashMap<&'static str, (u64, u64)>,
    directory_sizes: HashMap<PathBuf, (u64, u64)>,
    top_files: Vec<StorageFile>,
    scanned_files: u64,
    scanned_bytes: u64,
    skipped: u64,
    aggregated: bool,
    cancelled: bool,
}

impl Accumulator {
    fn new(options: AnalysisOptions) -> Self {
        Self {
            options,
            started: std::time::Instant::now(),
            categories: HashMap::new(),
            directory_sizes: HashMap::new(),
            top_files: Vec::new(),
            scanned_files: 0,
            scanned_bytes: 0,
            skipped: 0,
            aggregated: false,
            cancelled: false,
        }
    }

    fn visit_file(&mut self, path: &Path, size: u64, modified_secs: i64) {
        self.scanned_files += 1;
        self.scanned_bytes += size;
        if self.scanned_files > MAX_LISTED_RESULTS {
            self.aggregated = true;
        }

        let extension = path
            .extension()
            .map(|e| e.to_string_lossy().to_ascii_lowercase())
            .unwrap_or_default();
        let entry = self
            .categories
            .entry(category_for_extension(&extension))
            .or_insert((0, 0));
        entry.0 += size;
        entry.1 += 1;

        if size >= self.options.large_file_threshold_bytes && size > 0 {
            self.top_files.push(StorageFile {
                path: path.to_string_lossy().to_string(),
                display_name: path
                    .file_name()
                    .map(|n| n.to_string_lossy().to_string())
                    .unwrap_or_default(),
                parent_path: path
                    .parent()
                    .map(|p| p.to_string_lossy().to_string())
                    .unwrap_or_default(),
                size_bytes: size,
                modified_secs,
            });
            if self.top_files.len() > self.options.top_file_limit as usize * 2 {
                // Trim to the requested bound so memory stays flat on a volume
                // with millions of files.
                self.top_files
                    .sort_unstable_by_key(|file| std::cmp::Reverse(file.size_bytes));
                self.top_files
                    .truncate(self.options.top_file_limit as usize);
            }
        }

        self.roll_up(path, size);
    }

    /// Adds the size to every ancestor directory up to (not including) its root.
    fn roll_up(&mut self, path: &Path, size: u64) {
        let Some(root) = self
            .options
            .roots
            .iter()
            .find(|root| path.starts_with(root))
            .cloned()
        else {
            return;
        };
        let mut current = path.parent();
        while let Some(directory) = current {
            if directory == root {
                break;
            }
            if is_protected_path_authorized(
                &self.options.home_dir.to_string_lossy(),
                &directory.to_string_lossy(),
                &self.options.authorized_roots,
            ) {
                break;
            }
            let entry = self
                .directory_sizes
                .entry(directory.to_path_buf())
                .or_insert((0, 0));
            entry.0 += size;
            entry.1 += 1;
            current = directory.parent();
        }
    }

    fn finish(mut self) -> StorageAnalysis {
        self.top_files
            .sort_unstable_by_key(|file| std::cmp::Reverse(file.size_bytes));
        self.top_files
            .truncate(self.options.top_file_limit as usize);

        let mut directories: Vec<StorageDirectory> = self
            .directory_sizes
            .into_iter()
            .map(|(path, (size, count))| StorageDirectory {
                display_name: path
                    .file_name()
                    .map(|n| n.to_string_lossy().to_string())
                    .unwrap_or_else(|| path.to_string_lossy().to_string()),
                path: path.to_string_lossy().to_string(),
                size_bytes: size,
                file_count: count,
            })
            .collect();
        directories.sort_unstable_by_key(|dir| std::cmp::Reverse(dir.size_bytes));
        directories.truncate(self.options.top_directory_limit as usize);

        let mut categories: Vec<StorageCategory> = self
            .categories
            .into_iter()
            .map(|(category, (size, count))| StorageCategory {
                category: category.to_string(),
                size_bytes: size,
                file_count: count,
            })
            .collect();
        categories.sort_unstable_by_key(|category| std::cmp::Reverse(category.size_bytes));

        let volume = self
            .options
            .roots
            .first()
            .map(|root| volume_info(root))
            .unwrap_or_default();

        StorageAnalysis {
            volume,
            categories,
            top_files: self.top_files,
            top_directories: directories,
            scanned_file_count: self.scanned_files,
            scanned_byte_count: self.scanned_bytes,
            skipped_count: self.skipped,
            aggregated: self.aggregated,
            cancelled: self.cancelled,
            elapsed_millis: self.started.elapsed().as_millis() as i64,
        }
    }
}

/// Runs the analysis over every root.
///
/// Protected locations are counted as skipped rather than traversed, so the
/// storage page can never present a user document as reclaimable space.
pub fn analyse(options: &AnalysisOptions, cancel: &CancelToken) -> StorageAnalysis {
    let mut accumulator = Accumulator::new(options.clone());
    // Depth-first with an explicit stack keeps the call stack flat on deep trees.
    let mut stack: Vec<PathBuf> = options
        .roots
        .iter()
        .filter(|root| {
            root.is_dir()
                && !options
                    .ignore_paths
                    .iter()
                    .any(|skip| root.starts_with(skip))
        })
        .cloned()
        .collect();
    let mut siblings: Vec<PathBuf> = Vec::new();

    while let Some(directory) = stack.pop() {
        if cancel.is_cancelled() {
            accumulator.cancelled = true;
            break;
        }
        let Ok(entries) = std::fs::read_dir(&directory) else {
            accumulator.skipped += 1;
            continue;
        };
        for entry in entries.flatten() {
            if cancel.is_cancelled() {
                accumulator.cancelled = true;
                break;
            }
            let path = entry.path();
            if options
                .ignore_paths
                .iter()
                .any(|skip| path.starts_with(skip))
            {
                continue;
            }
            if crate::scanners::is_in_excluded_location(&path) {
                continue;
            }
            if is_protected_path_authorized(
                &options.home_dir.to_string_lossy(),
                &path.to_string_lossy(),
                &options.authorized_roots,
            ) {
                accumulator.skipped += 1;
                continue;
            }
            let Ok(metadata) = std::fs::symlink_metadata(&path) else {
                accumulator.skipped += 1;
                continue;
            };
            if metadata.file_type().is_symlink() {
                continue;
            }
            if metadata.is_dir() {
                let name = path
                    .file_name()
                    .map(|n| n.to_string_lossy().to_string())
                    .unwrap_or_default();
                if DEFAULT_SKIP_DIRECTORY_NAMES.contains(&name.as_str()) {
                    continue;
                }
                if walker::is_package_directory_export(&name, &[]) {
                    // A bundle is one item: its contents are summed, not listed.
                    let (bytes, files) = measure_bundle(&path, cancel, &options.authorized_roots);
                    accumulator.visit_file(&path, bytes, modified_secs_of(&metadata));
                    accumulator.scanned_files += files.saturating_sub(1);
                    continue;
                }
                siblings.push(path);
            } else if metadata.is_file() {
                let size = walker::allocated_size(&metadata);
                accumulator.visit_file(&path, size, modified_secs_of(&metadata));
            }
        }
        if accumulator.cancelled {
            break;
        }
        if stack.is_empty() {
            stack.append(&mut siblings);
        }
    }

    accumulator.finish()
}

fn measure_bundle(path: &Path, cancel: &CancelToken, authorized_roots: &[PathBuf]) -> (u64, u64) {
    let mut options = walker::WalkOptions::new(
        path.parent().unwrap_or(Path::new("/")).to_path_buf(),
        walker::WalkMode::Files,
    );
    options.authorized_roots = authorized_roots.to_vec();
    let report = walker::walk(path, &options, cancel);
    (report.total_bytes, report.total_files)
}

fn modified_secs_of(metadata: &std::fs::Metadata) -> i64 {
    metadata
        .modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::walker::fixtures::TempTree;

    #[test]
    fn extension_categories_cover_the_common_types() {
        assert_eq!(category_for_extension("jpg"), "images");
        assert_eq!(category_for_extension("mp4"), "video");
        assert_eq!(category_for_extension("pdf"), "documents");
        assert_eq!(category_for_extension("rs"), "code");
        assert_eq!(category_for_extension("dmg"), "installers");
        assert_eq!(category_for_extension("weird"), "other");
    }

    #[test]
    fn analysis_rolls_up_categories_and_directories() {
        let tree = TempTree::new("storage-basic");
        tree.file("Photos/a.jpg", 3 * 1024 * 1024);
        tree.file("Photos/nested/b.jpg", 2 * 1024 * 1024);
        tree.file("Docs/report.pdf", 1024 * 1024);

        let mut options = AnalysisOptions::new(tree.root.clone(), vec![tree.root.clone()]);
        options.large_file_threshold_bytes = 1024 * 1024;
        let analysis = analyse(&options, &CancelToken::new());

        assert_eq!(analysis.scanned_file_count, 3);
        assert!(analysis.scanned_byte_count >= 6 * 1024 * 1024);

        let images = analysis
            .categories
            .iter()
            .find(|c| c.category == "images")
            .expect("images category");
        assert!(images.size_bytes >= 5 * 1024 * 1024);
        assert_eq!(images.file_count, 2);

        assert!(
            analysis.top_files.iter().any(|f| f.display_name == "a.jpg"),
            "large files list contains the big files"
        );
        assert!(
            analysis
                .top_directories
                .iter()
                .any(|d| d.display_name == "Photos"),
            "directory rollup contains Photos"
        );
    }

    #[test]
    fn top_file_list_is_bounded_and_sorted() {
        let tree = TempTree::new("storage-bounded");
        for i in 0..30 {
            tree.file(&format!("f{i}.bin"), (i as usize + 1) * 1024 * 1024);
        }
        let mut options = AnalysisOptions::new(tree.root.clone(), vec![tree.root.clone()]);
        options.large_file_threshold_bytes = 1024 * 1024;
        options.top_file_limit = 5;
        let analysis = analyse(&options, &CancelToken::new());

        assert_eq!(analysis.top_files.len(), 5);
        assert!(analysis.top_files[0].size_bytes >= analysis.top_files[4].size_bytes);
        assert_eq!(analysis.top_files[0].display_name, "f29.bin");
    }

    #[test]
    fn protected_directories_are_counted_as_skipped() {
        let tree = TempTree::new("storage-protected");
        tree.file("Library/Caches/a.bin", 4096);
        tree.file("Documents/private.txt", 4096);

        let options = AnalysisOptions::new(tree.root.clone(), vec![tree.root.clone()]);
        let analysis = analyse(&options, &CancelToken::new());

        assert_eq!(analysis.skipped_count, 1);
        assert!(
            analysis
                .top_directories
                .iter()
                .all(|d| !d.path.ends_with("Documents")),
            "a protected directory must not appear in the rollup"
        );
    }

    #[test]
    fn ignored_paths_are_not_analysed() {
        let tree = TempTree::new("storage-ignore");
        tree.file("keep/a.bin", 4096);
        tree.file("skip/b.bin", 4096);

        let mut options = AnalysisOptions::new(tree.root.clone(), vec![tree.root.clone()]);
        options.ignore_paths = vec![tree.root.join("skip")];
        let analysis = analyse(&options, &CancelToken::new());
        assert_eq!(analysis.scanned_file_count, 1);
    }

    #[test]
    fn an_ignored_root_is_not_analysed() {
        // The ignored location can also be a scan root itself, for example a
        // granted folder the user later excluded. Filtering only children would
        // still enter it.
        let tree = TempTree::new("storage-ignore-root");
        tree.file("skip/b.bin", 4096);
        let ignored = tree.root.join("skip");

        let mut options = AnalysisOptions::new(tree.root.clone(), vec![ignored.clone()]);
        options.ignore_paths = vec![ignored];
        let analysis = analyse(&options, &CancelToken::new());
        assert_eq!(analysis.scanned_file_count, 0);
    }

    #[test]
    fn excluded_application_data_is_not_analysed() {
        let tree = TempTree::new("storage-excluded");
        tree.file("Library/Caches/CloudKit/db.bin", 8192);
        tree.file("Library/Caches/com.example.app/blob.bin", 4096);

        let options = AnalysisOptions::new(tree.root.clone(), vec![tree.root.clone()]);
        let analysis = analyse(&options, &CancelToken::new());
        assert_eq!(analysis.scanned_file_count, 1);
        assert_eq!(analysis.scanned_byte_count, 4096);
    }

    #[test]
    fn cancellation_stops_the_analysis() {
        let tree = TempTree::new("storage-cancel");
        for i in 0..50 {
            tree.file(&format!("d{i}/f.bin"), 4096);
        }
        let cancel = CancelToken::new();
        cancel.cancel();
        let options = AnalysisOptions::new(tree.root.clone(), vec![tree.root.clone()]);
        let analysis = analyse(&options, &cancel);
        assert!(analysis.cancelled);
        assert_eq!(analysis.scanned_file_count, 0);
    }

    #[test]
    fn packages_are_measured_as_units() {
        let tree = TempTree::new("storage-package");
        tree.file("App.app/Contents/MacOS/App", 3 * 1024 * 1024);
        tree.file("App.app/Contents/Resources/data.bin", 2 * 1024 * 1024);

        let mut options = AnalysisOptions::new(tree.root.clone(), vec![tree.root.clone()]);
        options.large_file_threshold_bytes = 1024 * 1024;
        let analysis = analyse(&options, &CancelToken::new());

        let app = analysis
            .top_files
            .iter()
            .find(|f| f.display_name == "App.app")
            .expect("bundle appears as a single item");
        assert!(app.size_bytes >= 5 * 1024 * 1024);
    }

    #[test]
    fn volume_info_reports_the_real_mount_point() {
        let info = volume_info(Path::new("/"));
        assert!(info.total_bytes > 0, "total capacity is reported");
        assert!(info.free_bytes > 0);
        assert!(info.used_bytes <= info.total_bytes);
        assert!(info.used_fraction >= 0.0 && info.used_fraction <= 1.0);
        assert_eq!(
            info.mount_point, "/",
            "the /Volumes/Macintosh HD alias must not win"
        );
    }

    #[test]
    fn mounted_volumes_lists_the_boot_volume_once() {
        let volumes = mounted_volumes();
        let roots = volumes.iter().filter(|v| v.mount_point == "/").count();
        assert_eq!(roots, 1, "the boot volume appears exactly once");
        assert!(volumes.iter().all(|v| v.total_bytes > 0));
    }

    #[test]
    fn reclaimable_bytes_only_counts_cleanup_categories() {
        let analysis = StorageAnalysis {
            categories: vec![
                StorageCategory {
                    category: "applicationCache".into(),
                    size_bytes: 100,
                    file_count: 1,
                },
                StorageCategory {
                    category: "images".into(),
                    size_bytes: 900,
                    file_count: 1,
                },
            ],
            ..Default::default()
        };
        assert_eq!(analysis.reclaimable_bytes(), 100);
    }

    #[test]
    fn a_deep_tree_does_not_overflow_the_stack() {
        let tree = TempTree::new("storage-deep");
        let mut relative = String::new();
        for i in 0..60 {
            relative.push_str(&format!("d{i}/"));
        }
        tree.file(&format!("{relative}deep.bin"), 4096);
        let options = AnalysisOptions::new(tree.root.clone(), vec![tree.root.clone()]);
        let analysis = analyse(&options, &CancelToken::new());
        assert_eq!(analysis.scanned_file_count, 1);
    }

    #[test]
    fn analysis_is_aggregated_past_the_listing_limit() {
        let tree = TempTree::new("storage-aggregated");
        for i in 0..40 {
            tree.file(&format!("d/i{i}.bin"), 1024);
        }
        let mut options = AnalysisOptions::new(tree.root.clone(), vec![tree.root.clone()]);
        options.top_file_limit = 3;
        options.large_file_threshold_bytes = 1;
        let analysis = analyse(&options, &CancelToken::new());
        assert_eq!(analysis.top_files.len(), 3);
        assert_eq!(analysis.scanned_file_count, 40);
    }
}
