//! Shared value types crossing the scanner boundary.
//!
//! These mirror the strings that appear in the C ABI so that the FFI layer needs
//! no translation tables: `Category` and `Risk` already serialise to the exact
//! identifiers Swift uses.

use serde::{Deserialize, Deserializer, Serialize};

/// The bounds a request's numbers are held to.
///
/// The request arrives as JSON over the C ABI, so every number in it is a
/// caller's claim rather than a measurement. Three of them are used as a `Vec`
/// capacity or as a count of retained rows before any work is done — an item
/// batch sizes the summary vector, the full-hash cap sizes the hashing budget,
/// and the thresholds decide how much of the tree is offered — so a request that
/// asked for `u32::MAX` item batches asked for a multi-gigabyte allocation from
/// a string of twenty digits. They are clamped where they are read, and the
/// clamps are the values at which the product still behaves: a larger batch is
/// no faster, and a larger hash budget is a scan that never ends.
pub const MAX_EVENT_BATCH_ITEMS: u32 = 4096;
/// At least one item per batch: a zero batch would publish every summary
/// individually, which is the event-per-file stream the design forbids.
pub const MIN_EVENT_BATCH_ITEMS: u32 = 1;
/// The most full hashes one duplicate run may compute before it reports itself
/// truncated.
pub const MAX_FULL_HASHES: u64 = 1_000_000;
/// The largest byte threshold a request may ask for: above this a "large file"
/// is not a class of file on a consumer Mac.
pub const MAX_THRESHOLD_BYTES: u64 = 10 * 1024 * 1024 * 1024;
/// The largest age threshold in days, ten years. Zero stays valid: it is what a
/// rule or a request uses to mean "no age filter".
pub const MAX_THRESHOLD_DAYS: u32 = 3650;
/// The largest minimum size the duplicate scan may be told to ignore.
pub const MAX_DUPLICATE_MIN_SIZE_BYTES: u64 = 1024 * 1024 * 1024;

/// One root the scan is allowed to visit.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScanRoot {
    /// Absolute path, already resolved by Swift (no `~`, no relative segments).
    pub path: String,
    /// `home`, `homeLibrary`, `applications`, `systemLibrary`, `authorized`,
    /// `externalVolume`.
    pub anchor: String,
    /// `false` for roots the user only wants measured, never cleaned.
    #[serde(default = "default_true")]
    pub is_cleanable: bool,
    /// Whether the generic large-file and old-file scans may walk this root.
    ///
    /// The system log root exists for the `system-logs` rule; marking it
    /// cleanable made every large or old file under `/Library/Logs` a threshold
    /// candidate as well. Rules and the threshold scans are separate questions,
    /// so the root answers them separately.
    #[serde(default = "default_true")]
    pub includes_threshold_files: bool,
    /// Optional hard cap on traversal depth below this root.
    #[serde(default)]
    pub max_depth: Option<u32>,
    /// Volume identifier, used to report unplugged external disks.
    #[serde(default)]
    pub volume_id: Option<String>,
}

impl ScanRoot {
    pub fn new(path: impl Into<String>, anchor: impl Into<String>) -> Self {
        Self {
            path: path.into(),
            anchor: anchor.into(),
            is_cleanable: true,
            includes_threshold_files: true,
            max_depth: None,
            volume_id: None,
        }
    }

    pub fn read_only(mut self) -> Self {
        self.is_cleanable = false;
        self
    }
}

fn default_true() -> bool {
    true
}

/// Duplicate-scan tuning.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DuplicateOptions {
    /// Directories to search. Empty means "use the scan roots".
    pub roots: Vec<String>,
    /// Files smaller than this are ignored: tiny files are rarely worth the
    /// hash, and the candidate set explodes otherwise.
    #[serde(deserialize_with = "clamp_min_size_bytes")]
    pub min_size_bytes: u64,
    /// Cap on full hashes per session, so a pathological volume cannot pin the
    /// CPU forever. Reached groups are reported as truncated.
    #[serde(deserialize_with = "clamp_max_full_hashes")]
    pub max_full_hashes: u64,
}

/// Holds a requested hash budget to [`MAX_FULL_HASHES`].
fn clamp_max_full_hashes<'de, D>(deserializer: D) -> Result<u64, D::Error>
where
    D: Deserializer<'de>,
{
    let requested = u64::deserialize(deserializer)?;
    Ok(requested.min(MAX_FULL_HASHES))
}

/// Holds a requested duplicate floor to [`MAX_DUPLICATE_MIN_SIZE_BYTES`].
fn clamp_min_size_bytes<'de, D>(deserializer: D) -> Result<u64, D::Error>
where
    D: Deserializer<'de>,
{
    let requested = u64::deserialize(deserializer)?;
    Ok(requested.min(MAX_DUPLICATE_MIN_SIZE_BYTES))
}

/// Holds a requested byte threshold to [`MAX_THRESHOLD_BYTES`].
fn clamp_threshold_bytes<'de, D>(deserializer: D) -> Result<u64, D::Error>
where
    D: Deserializer<'de>,
{
    let requested = u64::deserialize(deserializer)?;
    Ok(requested.min(MAX_THRESHOLD_BYTES))
}

/// Holds a requested age threshold to [`MAX_THRESHOLD_DAYS`]; zero is kept.
fn clamp_threshold_days<'de, D>(deserializer: D) -> Result<u32, D::Error>
where
    D: Deserializer<'de>,
{
    let requested = u32::deserialize(deserializer)?;
    Ok(requested.min(MAX_THRESHOLD_DAYS))
}

/// Holds a requested item batch to [`MIN_EVENT_BATCH_ITEMS`]`..=`[`MAX_EVENT_BATCH_ITEMS`].
///
/// The coordinator reserves `event_batch_items` summaries per batch, so the
/// field is a `Vec` capacity before anything has been found.
fn clamp_event_batch_items<'de, D>(deserializer: D) -> Result<u32, D::Error>
where
    D: Deserializer<'de>,
{
    let requested = u32::deserialize(deserializer)?;
    Ok(requested.clamp(MIN_EVENT_BATCH_ITEMS, MAX_EVENT_BATCH_ITEMS))
}

impl Default for DuplicateOptions {
    fn default() -> Self {
        Self {
            roots: Vec::new(),
            min_size_bytes: 4 * 1024,
            max_full_hashes: 200_000,
        }
    }
}

/// Everything one scan needs to know.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScanRequest {
    pub session_id: String,
    /// Home directory, used for rule anchoring and protection checks.
    pub home_dir: String,
    pub roots: Vec<ScanRoot>,
    /// Large-file threshold in bytes (default 1 GB).
    #[serde(deserialize_with = "clamp_threshold_bytes")]
    pub large_file_threshold_bytes: u64,
    /// Age threshold in days for old files (default 180).
    #[serde(deserialize_with = "clamp_threshold_days")]
    pub old_file_threshold_days: u32,
    /// Age threshold in days before a log or installer counts as stale.
    #[serde(deserialize_with = "clamp_threshold_days")]
    pub stale_threshold_days: u32,
    /// Directories the user asked Sift never to look at.
    pub ignore_paths: Vec<String>,
    /// Roots the user explicitly authorised (security-scoped in the app).
    ///
    /// These lift the blanket `/Volumes` and `/private/var` prefixes for the
    /// named subtrees only.
    #[serde(default)]
    pub authorized_roots: Vec<String>,
    /// Bundle identifiers of installed applications, used for residue matching.
    pub installed_bundle_ids: Vec<String>,
    /// App groups declared by installed applications' entitlements.
    ///
    /// A group container is named after its group, not after the application
    /// that uses it, so a container two applications share cannot be recognised
    /// from any name. Swift reads `com.apple.security.application-groups` from
    /// every installed signature and sends the set here; a container whose name
    /// is one of these groups belongs to something installed and is not residue.
    ///
    /// It travels in the request for the same reason `installed_bundle_ids`
    /// does: this core has no signature reader, and the Swift engine must reach
    /// the same verdict from the same request. Empty means "nothing declared",
    /// which keeps the name-only behaviour for a caller that sends nothing.
    #[serde(default)]
    pub app_group_ids: Vec<String>,
    /// Whether `app_group_ids` is the complete set.
    ///
    /// `false` means the caller could not finish reading the signatures — a
    /// deadline, a cancelled scan, a volume that stopped answering. An incomplete
    /// set is worse than an empty one for the question it is used for: a group
    /// container is reported as residue when no application declares it, so an
    /// unread application would make a live container look like a leftover. When
    /// the set is incomplete this core reports no group-container residue at all
    /// for that run, which is the safe answer, and the name-based residue
    /// categories are unaffected.
    #[serde(default = "complete_by_default")]
    pub app_group_ids_complete: bool,
    /// Whether `installed_bundle_ids` is the complete set.
    ///
    /// The same judgement as `app_group_ids_complete`, about the other set. The
    /// residue scan asks "does no installed application answer for this name",
    /// and every location it reads — `~/Library/Caches`, `Containers`,
    /// `Application Support`, `Logs`, `Saved Application State`, the group
    /// containers and the preference files — is answered from this list. A read
    /// that stopped early (a deadline, a cancelled scan, a bundle directory that
    /// refused) leaves an installed application unnamed, so its live data reads
    /// as the leftover of something that was removed. When the set is incomplete
    /// this core reports no residue at all for that run: a scan that finds
    /// nothing is recoverable, one that offers a live container is not.
    ///
    /// It defaults to `true` so a caller that never sends the field keeps the
    /// behaviour it had.
    #[serde(default = "complete_by_default")]
    pub installed_bundle_ids_complete: bool,
    /// Aliases of the applications running when the scan started.
    ///
    /// Bundle identifiers, Finder names and executable names, lower-cased by the
    /// engine that compares them. A rule that marks its items as owned by one
    /// application (`needs_app_closed`) takes a `safe` item down to `review`
    /// while its owner is running, so the move cannot pull a cache directory out
    /// from under a live process.
    ///
    /// It travels here rather than being read inside the scanner because this
    /// core has no `NSWorkspace`. Swift collects the list once and sends it, and
    /// the Swift engine scans from the same request, so the two engines see the
    /// same list.
    #[serde(default)]
    pub running_app_tokens: Vec<String>,
    /// Whether entries whose name starts with `.` are part of the scan.
    ///
    /// A scope, not a display filter: the "show hidden files" setting decides
    /// what the walk produces, so the candidates, the totals and the report
    /// describe the same run. Defaults to scanning them, so a request that omits
    /// the field keeps the permissive behaviour.
    #[serde(default = "include_hidden_files_by_default")]
    pub include_hidden_files: bool,
    /// Extra rule definitions, already validated by Swift. Additive only.
    pub extra_rules_json: Option<String>,
    pub include_duplicates: bool,
    pub duplicates: DuplicateOptions,
    /// Per-batch summary size published to the event stream.
    ///
    /// Clamped where it is read: the coordinator reserves this many summaries
    /// per batch, and the field arrives from JSON.
    #[serde(deserialize_with = "clamp_event_batch_items")]
    pub event_batch_items: u32,
    /// Filesystem path of the SQLite index for this session.
    pub index_path: String,
}

/// A request that says nothing about the completeness of its group list.
///
/// True: a caller that sends nothing gets the name-only behaviour it always had,
/// and the field exists for the caller that knows its read was cut short.
fn complete_by_default() -> bool {
    true
}

/// The default for a request that does not mention hidden files.
fn include_hidden_files_by_default() -> bool {
    true
}

impl Default for ScanRequest {
    fn default() -> Self {
        Self {
            session_id: String::new(),
            home_dir: String::new(),
            roots: Vec::new(),
            large_file_threshold_bytes: 1024 * 1024 * 1024,
            old_file_threshold_days: 180,
            stale_threshold_days: 30,
            ignore_paths: Vec::new(),
            authorized_roots: Vec::new(),
            installed_bundle_ids: Vec::new(),
            app_group_ids: Vec::new(),
            app_group_ids_complete: true,
            installed_bundle_ids_complete: true,
            running_app_tokens: Vec::new(),
            include_hidden_files: true,
            extra_rules_json: None,
            include_duplicates: true,
            duplicates: DuplicateOptions::default(),
            event_batch_items: 512,
            index_path: String::new(),
        }
    }
}

/// The scan phases, in the order the coordinator runs them.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PhaseName {
    Idle,
    Preparing,
    Scanning,
    Indexing,
    Ready,
    Cancelled,
    Partial,
    Failed,
}

impl PhaseName {
    pub const fn as_str(self) -> &'static str {
        match self {
            PhaseName::Idle => "idle",
            PhaseName::Preparing => "preparing",
            PhaseName::Scanning => "scanning",
            PhaseName::Indexing => "indexing",
            PhaseName::Ready => "ready",
            PhaseName::Cancelled => "cancelled",
            PhaseName::Partial => "partial",
            PhaseName::Failed => "failed",
        }
    }

    pub fn parse(value: &str) -> Self {
        match value {
            "preparing" => PhaseName::Preparing,
            "scanning" => PhaseName::Scanning,
            "indexing" => PhaseName::Indexing,
            "ready" => PhaseName::Ready,
            "cancelled" => PhaseName::Cancelled,
            "partial" => PhaseName::Partial,
            "failed" => PhaseName::Failed,
            _ => PhaseName::Idle,
        }
    }
}

/// Sort order for result pages.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ScanSortOrder {
    Size,
    Name,
    Modified,
    Category,
}

impl ScanSortOrder {
    pub fn parse(value: &str) -> Self {
        match value {
            "name" => ScanSortOrder::Name,
            "modified" => ScanSortOrder::Modified,
            "category" => ScanSortOrder::Category,
            _ => ScanSortOrder::Size,
        }
    }
}

/// A cleanup item summary, small enough to travel through the event stream.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScanItemSummary {
    pub path: String,
    pub display_name: String,
    pub parent_path: String,
    pub category: String,
    pub risk: String,
    pub size_bytes: i64,
    pub file_count: i64,
    pub explanation_key: String,
    pub rule_id: String,
    pub bundle_id: Option<String>,
    pub modified_secs: i64,
    pub is_directory: bool,
}

/// A location that could not be read, with a code the UI can act on.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SkippedLocation {
    /// Error code from the product error table, e.g. `permissionDenied`.
    pub code: String,
    /// De-identified description: the UI shows the location, logs never do.
    pub path: String,
    pub message: String,
    pub byte_count: i64,
    /// True when the user can fix this by granting Full Disk Access.
    pub needs_full_disk_access: bool,
}

/// Live counters shown while scanning.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScanProgress {
    pub phase: String,
    pub files_seen: i64,
    pub bytes_seen: i64,
    pub items_found: i64,
    pub current_path: String,
    /// 0.0–1.0 within the current phase, or `None` when indeterminate.
    pub fraction: Option<f64>,
}

/// Final rollup for a scan session.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScanSummary {
    pub session_id: String,
    pub phase: String,
    pub scanned_file_count: i64,
    pub scanned_byte_count: i64,
    pub item_count: i64,
    pub item_bytes: i64,
    pub category_totals: Vec<CategoryTotal>,
    pub duplicate_group_count: i64,
    pub duplicate_reclaimable_bytes: i64,
    pub skipped: Vec<SkippedLocation>,
    pub elapsed_millis: i64,
    /// True when at least one root or rule could not be read completely.
    pub is_partial: bool,
}

/// One row of the per-category rollup.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CategoryTotal {
    pub category: String,
    pub item_count: i64,
    pub total_bytes: i64,
}

/// Scanner events. Deliberately coarse: Swift never receives one event per file.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum Event {
    PhaseChanged {
        phase: String,
    },
    Progress(ScanProgress),
    ItemBatch {
        items: Vec<ScanItemSummary>,
    },
    DuplicateGroup {
        group_index: i64,
        member_count: i64,
        reclaimable_bytes: i64,
    },
    LocationSkipped(SkippedLocation),
    Completed(Box<ScanSummary>),
    Failed {
        code: String,
        message: String,
    },
}

/// A drained batch of events.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct EventBatch {
    pub events: Vec<Event>,
    /// Number of events still queued after this batch.
    pub remaining: u32,
}

/// Stable error codes shared with Swift and with the product error table.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ErrorCode {
    PermissionDenied,
    FileNotFound,
    FileInUse,
    VolumeUnavailable,
    ProtectedLocation,
    PartialFailure,
    LicenseServiceUnavailable,
    StoreUnavailable,
    Cancelled,
    InvalidRequest,
    Internal,
}

impl ErrorCode {
    pub const fn as_str(self) -> &'static str {
        match self {
            ErrorCode::PermissionDenied => "permissionDenied",
            ErrorCode::FileNotFound => "fileNotFound",
            ErrorCode::FileInUse => "fileInUse",
            ErrorCode::VolumeUnavailable => "volumeUnavailable",
            ErrorCode::ProtectedLocation => "protectedLocation",
            ErrorCode::PartialFailure => "partialFailure",
            ErrorCode::LicenseServiceUnavailable => "licenseServiceUnavailable",
            ErrorCode::StoreUnavailable => "storeUnavailable",
            ErrorCode::Cancelled => "cancelled",
            ErrorCode::InvalidRequest => "invalidRequest",
            ErrorCode::Internal => "internal",
        }
    }
}

/// Errors raised by the scanner core.
#[derive(Debug, thiserror::Error)]
pub enum EngineError {
    #[error("invalid scan request: {0}")]
    InvalidRequest(String),
    #[error("scan session {0} not found")]
    SessionNotFound(String),
    #[error("index error: {0}")]
    Index(#[from] sift_file_index::IndexError),
    #[error("operation cancelled")]
    Cancelled,
    #[error("internal error: {0}")]
    Internal(String),
}

impl EngineError {
    pub const fn code(&self) -> ErrorCode {
        match self {
            EngineError::InvalidRequest(_) => ErrorCode::InvalidRequest,
            EngineError::SessionNotFound(_) => ErrorCode::FileNotFound,
            EngineError::Index(_) => ErrorCode::Internal,
            EngineError::Cancelled => ErrorCode::Cancelled,
            EngineError::Internal(_) => ErrorCode::Internal,
        }
    }

    /// A message safe to show a user: no absolute user paths.
    pub fn user_message(&self) -> String {
        match self {
            EngineError::InvalidRequest(_) => "The scan request was not valid.".to_string(),
            EngineError::SessionNotFound(_) => {
                "That scan session is no longer available. Please scan again.".to_string()
            }
            EngineError::Index(_) => {
                "Scan results could not be read. Please scan again.".to_string()
            }
            EngineError::Cancelled => "Scan cancelled.".to_string(),
            EngineError::Internal(_) => "Something went wrong. Please try again.".to_string(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};

    /// The request the app sends, as data, so a test can replace single fields.
    fn request_value() -> Value {
        json!({
            "sessionId": "s",
            "homeDir": "/Users/example",
            "roots": [{"path": "/Users/example", "anchor": "home"}],
            "largeFileThresholdBytes": 1024 * 1024 * 1024u64,
            "oldFileThresholdDays": 180,
            "staleThresholdDays": 30,
            "ignorePaths": [],
            "installedBundleIds": ["com.example.app"],
            "extraRulesJson": null,
            "includeDuplicates": true,
            "duplicates": {"roots": [], "minSizeBytes": 4096, "maxFullHashes": 200_000},
            "eventBatchItems": 512,
            "indexPath": "",
        })
    }

    /// Overwrites fields, descending into an object so `duplicates` can be
    /// patched one key at a time.
    fn merge(base: &mut Value, over: Value) {
        match (base, over) {
            (Value::Object(base), Value::Object(over)) => {
                for (key, value) in over {
                    match base.get_mut(&key) {
                        Some(existing) if existing.is_object() && value.is_object() => {
                            merge(existing, value);
                        }
                        _ => {
                            base.insert(key, value);
                        }
                    }
                }
            }
            (base, over) => *base = over,
        }
    }

    fn decode(overrides: Value) -> ScanRequest {
        let mut value = request_value();
        merge(&mut value, overrides);
        serde_json::from_value(value).expect("the request decodes")
    }

    /// The numbers a request carries are claims, not measurements.
    ///
    /// `event_batch_items` is reserved as a `Vec` capacity before the scan finds
    /// anything, and the thresholds decide how much of the tree is offered, so a
    /// request asking for `u32::MAX` batches asked for a multi-gigabyte
    /// allocation from a string of ten digits.
    #[test]
    fn a_pathological_request_is_clamped_where_it_is_read() {
        let request = decode(json!({
            "largeFileThresholdBytes": u64::MAX,
            "oldFileThresholdDays": u32::MAX,
            "staleThresholdDays": 0,
            "eventBatchItems": u32::MAX,
            "duplicates": {
                "minSizeBytes": u64::MAX,
                "maxFullHashes": u64::MAX,
            },
        }));

        assert_eq!(request.event_batch_items, MAX_EVENT_BATCH_ITEMS);
        assert_eq!(request.large_file_threshold_bytes, MAX_THRESHOLD_BYTES);
        assert_eq!(request.old_file_threshold_days, MAX_THRESHOLD_DAYS);
        assert_eq!(
            request.stale_threshold_days, 0,
            "zero is a threshold the product uses: no age filter"
        );
        assert_eq!(request.duplicates.max_full_hashes, MAX_FULL_HASHES);
        assert_eq!(
            request.duplicates.min_size_bytes,
            MAX_DUPLICATE_MIN_SIZE_BYTES
        );
    }

    /// A batch of zero items would publish one event per file, which is the
    /// stream the design forbids; it becomes the smallest batch instead.
    #[test]
    fn an_empty_batch_size_becomes_one_item() {
        let request = decode(json!({"eventBatchItems": 0}));
        assert_eq!(request.event_batch_items, MIN_EVENT_BATCH_ITEMS);
    }

    /// A request inside the bounds is taken as written.
    #[test]
    fn a_request_inside_the_bounds_is_unchanged() {
        let request = decode(json!({}));
        assert_eq!(request.event_batch_items, 512);
        assert_eq!(request.large_file_threshold_bytes, 1024 * 1024 * 1024);
        assert_eq!(request.old_file_threshold_days, 180);
        assert_eq!(request.duplicates.max_full_hashes, 200_000);
        assert_eq!(request.duplicates.min_size_bytes, 4096);
    }

    /// The installed set's completeness travels under the struct's camelCase
    /// name and defaults to complete, so an old caller keeps its behaviour.
    #[test]
    fn the_installed_set_is_complete_unless_the_request_says_otherwise() {
        let defaulted = decode(json!({}));
        assert!(defaulted.installed_bundle_ids_complete);
        assert!(defaulted.app_group_ids_complete);

        let incomplete = decode(json!({"installedBundleIdsComplete": false}));
        assert!(!incomplete.installed_bundle_ids_complete);
        assert!(
            incomplete.app_group_ids_complete,
            "the two sets answer different questions"
        );
    }
}
