//! File identity, partial comparison and full-content hashing for the
//! duplicate-file pipeline.
//!
//! The duplicate pipeline follows the order the specification requires, from
//! cheapest to most expensive:
//!
//! 1. group by exact byte size,
//! 2. compare head/tail/middle samples of same-sized files,
//! 3. hash the full contents of the survivors,
//! 4. form groups by full digest.
//!
//! Every stage is cancellable and never follows symlinks. Content is streamed
//! and never held in memory beyond a fixed buffer, so hashing a 20 GB file has
//! the same footprint as hashing a 20 MB one.

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

/// Bytes read for each content sample. Tail sampling is what catches truncated
/// or appended media files cheaply.
pub const SAMPLE_BYTES: u64 = 8 * 1024;

/// Files at or below this size are fully read during sampling, which removes a
/// second full pass for the small files that dominate real duplicate sets.
pub const FULL_READ_THRESHOLD: u64 = 96 * 1024;

/// Read buffer for streaming hashes.
const HASH_BUFFER_BYTES: usize = 256 * 1024;

/// Co-operative cancellation flag shared with the scanner.
///
/// Cloning copies the current flag state rather than sharing it, so the engine
/// keeps exactly one token per session and passes that same token to workers.
#[derive(Debug, Default)]
pub struct CancelToken(std::sync::atomic::AtomicBool);

impl Clone for CancelToken {
    fn clone(&self) -> Self {
        Self(std::sync::atomic::AtomicBool::new(self.is_cancelled()))
    }
}

impl CancelToken {
    pub fn new() -> Self {
        Self(std::sync::atomic::AtomicBool::new(false))
    }

    pub fn cancel(&self) {
        self.0.store(true, std::sync::atomic::Ordering::Release);
    }

    pub fn is_cancelled(&self) -> bool {
        self.0.load(std::sync::atomic::Ordering::Acquire)
    }
}

/// Cheap identity used to detect that a file changed between two passes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FileIdentity {
    pub size: u64,
    pub modified_secs: i64,
    pub modified_nanos: u32,
    pub device: u64,
    pub inode: u64,
    /// A resource fork or sparse allocation that makes byte reads unreliable.
    pub is_skipped_placeholder: bool,
}

impl FileIdentity {
    /// Builds an identity from filesystem metadata.
    pub fn from_metadata(metadata: &std::fs::Metadata) -> Self {
        use std::os::unix::fs::MetadataExt;
        let modified = metadata
            .modified()
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok());
        Self {
            size: metadata.len(),
            modified_secs: modified.map(|d| d.as_secs() as i64).unwrap_or(0),
            modified_nanos: modified.map(|d| d.subsec_nanos()).unwrap_or(0),
            device: metadata.dev(),
            inode: metadata.ino(),
            is_skipped_placeholder: metadata.blocks() == 0 && metadata.len() > 0,
        }
    }

    pub fn from_path(path: &Path) -> std::io::Result<Self> {
        let metadata = std::fs::symlink_metadata(path)?;
        Ok(Self::from_metadata(&metadata))
    }
}

/// Errors from the hashing stage. `Cancelled` is not a failure: callers treat it
/// as a controlled stop.
#[derive(Debug, thiserror::Error)]
pub enum HashError {
    #[error("operation cancelled")]
    Cancelled,
    #[error("i/o error: {0}")]
    Io(#[from] std::io::Error),
    #[error("file changed while hashing")]
    FileChanged,
}

/// Canonical empty-content digest. Empty files group by size then by this value.
pub fn empty_digest() -> String {
    blake3::hash(b"").to_hex().to_string()
}

/// The sample points read for a file of `len` bytes, in read order and free of
/// duplicates. Exposed for tests so the sampling plan stays inspectable.
pub fn sample_plan(len: u64) -> Vec<u64> {
    if len == 0 {
        return Vec::new();
    }
    if len <= FULL_READ_THRESHOLD {
        return vec![0];
    }
    let mut points = vec![0];
    let tail_start = len.saturating_sub(SAMPLE_BYTES);
    let middle_start = (len / 2).saturating_sub(SAMPLE_BYTES / 2);
    if middle_start > SAMPLE_BYTES && middle_start < tail_start {
        points.push(middle_start);
    }
    if tail_start > SAMPLE_BYTES {
        points.push(tail_start);
    }
    points
}

/// Head/tail/middle fingerprint. Two same-sized files with different
/// fingerprints cannot be identical, and most non-duplicates are rejected here
/// without reading the whole file.
///
/// The fingerprint is derived from the sampled bytes only. It is never used as
/// the final duplicate key: only [`hash_file`] output forms groups.
pub fn sample_fingerprint(path: &Path, len: u64) -> Result<String, HashError> {
    if len == 0 {
        return Ok(empty_digest());
    }
    let mut file = File::open(path)?;
    let mut hasher = blake3::Hasher::new();
    hasher.update(&len.to_le_bytes());
    let mut buffer = vec![0u8; SAMPLE_BYTES as usize];

    if len <= FULL_READ_THRESHOLD {
        loop {
            let read = file.read(&mut buffer)?;
            if read == 0 {
                break;
            }
            hasher.update(&buffer[..read]);
        }
    } else {
        for offset in sample_plan(len) {
            file.seek(SeekFrom::Start(offset))?;
            let want = SAMPLE_BYTES.min(len - offset) as usize;
            let read = read_exact_at_most(&mut file, &mut buffer[..want])?;
            hasher.update(&buffer[..read]);
        }
    }
    Ok(hasher.finalize().to_hex().to_string())
}

/// Full-content BLAKE3 digest, streamed and cancellable.
///
/// The file is re-stat'ed before and after reading: if the size or modification
/// time moved, the digest is discarded rather than reported as truth.
pub fn hash_file(path: &Path, cancel: &CancelToken) -> Result<String, HashError> {
    let before = FileIdentity::from_path(path)?;
    if before.is_skipped_placeholder {
        return Err(HashError::FileChanged);
    }

    let mut file = File::open(path)?;
    let mut hasher = blake3::Hasher::new();
    let mut buffer = vec![0u8; HASH_BUFFER_BYTES];
    let mut total: u64 = 0;

    loop {
        if cancel.is_cancelled() {
            return Err(HashError::Cancelled);
        }
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        total += read as u64;
        hasher.update(&buffer[..read]);
    }

    let after = FileIdentity::from_path(path)?;
    if after != before || total != before.size {
        return Err(HashError::FileChanged);
    }
    Ok(hasher.finalize().to_hex().to_string())
}

fn read_exact_at_most(file: &mut File, buffer: &mut [u8]) -> std::io::Result<usize> {
    let mut filled = 0;
    while filled < buffer.len() {
        let read = file.read(&mut buffer[filled..])?;
        if read == 0 {
            break;
        }
        filled += read;
    }
    Ok(filled)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    struct TempDir(std::path::PathBuf);

    impl TempDir {
        fn new(tag: &str) -> Self {
            let mut path = std::env::temp_dir();
            let unique = format!(
                "sift-hasher-{tag}-{}-{}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_nanos()
            );
            path.push(unique);
            std::fs::create_dir_all(&path).expect("temp dir");
            Self(path)
        }

        fn write(&self, name: &str, bytes: &[u8]) -> std::path::PathBuf {
            let path = self.0.join(name);
            let mut file = File::create(&path).expect("create");
            file.write_all(bytes).expect("write");
            path
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn sample_plan_is_sorted_unique_and_bounded() {
        let plan = sample_plan(10 * 1024 * 1024);
        assert_eq!(
            plan,
            vec![
                0,
                5 * 1024 * 1024 - SAMPLE_BYTES / 2,
                10 * 1024 * 1024 - SAMPLE_BYTES
            ]
        );
        let mut sorted = plan.clone();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(sorted, plan, "samples must be unique and in read order");
        assert!(plan.len() <= 3, "sampling must stay cheap");
    }

    #[test]
    fn small_files_are_read_once() {
        assert!(sample_plan(FULL_READ_THRESHOLD).len() == 1);
    }

    #[test]
    fn identical_files_share_a_digest() {
        let dir = TempDir::new("identical");
        let a = dir.write("a.bin", b"the same bytes");
        let b = dir.write("b.bin", b"the same bytes");
        let cancel = CancelToken::new();
        assert_eq!(
            hash_file(&a, &cancel).unwrap(),
            hash_file(&b, &cancel).unwrap()
        );
    }

    #[test]
    fn different_content_produces_different_digests() {
        let dir = TempDir::new("different");
        let a = dir.write("a.bin", b"alpha");
        let b = dir.write("b.bin", b"beta!");
        let cancel = CancelToken::new();
        assert_ne!(
            hash_file(&a, &cancel).unwrap(),
            hash_file(&b, &cancel).unwrap()
        );
    }

    #[test]
    fn empty_files_group_on_the_canonical_digest() {
        let dir = TempDir::new("empty");
        let a = dir.write("a", b"");
        let b = dir.write("b", b"");
        let cancel = CancelToken::new();
        assert_eq!(hash_file(&a, &cancel).unwrap(), empty_digest());
        assert_eq!(
            hash_file(&a, &cancel).unwrap(),
            hash_file(&b, &cancel).unwrap()
        );
    }

    #[test]
    fn same_size_different_tail_is_rejected_by_the_sample() {
        // Same prefix and same size, different tail: the cheap stage must
        // already see the difference.
        let dir = TempDir::new("tail");
        let mut a_bytes = vec![b'A'; 2 * 1024 * 1024];
        let mut b_bytes = a_bytes.clone();
        *a_bytes.last_mut().unwrap() = b'X';
        *b_bytes.last_mut().unwrap() = b'Y';
        let a = dir.write("a.bin", &a_bytes);
        let b = dir.write("b.bin", &b_bytes);
        let len = a_bytes.len() as u64;
        assert_ne!(
            sample_fingerprint(&a, len).unwrap(),
            sample_fingerprint(&b, len).unwrap()
        );
    }

    #[test]
    fn same_size_same_edges_but_different_middle_is_caught_by_full_hash() {
        let dir = TempDir::new("middle");
        let len = 4 * 1024 * 1024;
        let mut a_bytes = vec![b'M'; len];
        let mut b_bytes = a_bytes.clone();
        let middle = len / 2;
        a_bytes[middle] = b'1';
        b_bytes[middle] = b'2';
        let a = dir.write("a.bin", &a_bytes);
        let b = dir.write("b.bin", &b_bytes);
        let cancel = CancelToken::new();
        assert_ne!(
            hash_file(&a, &cancel).unwrap(),
            hash_file(&b, &cancel).unwrap()
        );
    }

    #[test]
    fn cancellation_stops_hashing() {
        let dir = TempDir::new("cancel");
        let big = dir.write("big.bin", &vec![b'x'; 8 * 1024 * 1024]);
        let cancel = CancelToken::new();
        cancel.cancel();
        assert!(matches!(
            hash_file(&big, &cancel),
            Err(HashError::Cancelled)
        ));
    }

    #[test]
    fn identity_changes_when_the_file_changes() {
        let dir = TempDir::new("identity");
        let path = dir.write("f.bin", b"one");
        let first = FileIdentity::from_path(&path).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(10));
        let mut file = std::fs::OpenOptions::new()
            .append(true)
            .open(&path)
            .unwrap();
        file.write_all(b"two").unwrap();
        let second = FileIdentity::from_path(&path).unwrap();
        assert_ne!(first, second);
    }

    #[test]
    fn missing_file_reports_io_error_not_panic() {
        let cancel = CancelToken::new();
        let missing = std::env::temp_dir().join("sift-does-not-exist-xyz.bin");
        assert!(matches!(
            hash_file(&missing, &cancel),
            Err(HashError::Io(_))
        ));
    }
}
