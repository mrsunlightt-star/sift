//! The C ABI that Swift talks to.
//!
//! Rules this boundary follows, taken from the specification:
//!
//! * no Swift types cross here — only UTF-8 byte buffers, fixed-width integers
//!   and opaque handles,
//! * results arrive in **batches** and **pages**, never one call per file,
//! * every cross-language struct carries a version field, and the layout is
//!   covered by the contract tests in `tests/ffi_contract.rs`,
//! * a Rust panic is caught at every entry point and converted into a controlled
//!   error code, so no `panic!` can unwind into Swift,
//! * the Rust side never deletes, moves or trashes a file: it only reports what
//!   *could* be cleaned, and Swift performs every destructive action after
//!   re-validating each path.
//!
//! # Ownership
//!
//! `SiftString` values are owned by the caller and released with
//! [`sift_string_free`]. `SiftEngine` and `SiftScanHandle` are opaque handles
//! released with [`sift_engine_free`] and [`sift_scan_free`]. Arrays embedded in
//! an event, page or analysis are released by the matching `_free` function.

use sift_hasher::CancelToken;
use sift_rules::{default_rules, protection_reason, Risk};
use sift_scanner_core::storage::{self, AnalysisOptions};
use sift_scanner_core::{Engine, Event, ScanHandle, ScanRequest};
use std::ffi::{c_char, CStr};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;
use std::sync::Arc;

/// Version of the FFI contract. Swift compares this on load so a mismatched
/// framework fails loudly instead of silently misreading a struct.
pub const SIFT_FFI_VERSION: u32 = 1;

/// A UTF-8 buffer. Always valid UTF-8 on the Rust side.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SiftString {
    pub ptr: *mut u8,
    pub len: usize,
}

impl SiftString {
    /// An empty string with a null pointer, used for absent values.
    pub const EMPTY: SiftString = SiftString {
        ptr: std::ptr::null_mut(),
        len: 0,
    };

    pub fn from_string(value: String) -> Self {
        let mut bytes = value.into_bytes().into_boxed_slice();
        let string = Self {
            ptr: bytes.as_mut_ptr(),
            len: bytes.len(),
        };
        // Ownership moves to the caller; `sift_string_free` rebuilds the box.
        std::mem::forget(bytes);
        string
    }

    fn from_str(value: &str) -> Self {
        Self::from_string(value.to_string())
    }
}

/// Frees a string returned by this library. Null pointers are ignored.
///
/// # Safety
/// `value` must come from this library and must be freed at most once.
#[no_mangle]
pub unsafe extern "C" fn sift_string_free(value: SiftString) {
    if value.ptr.is_null() || value.len == 0 {
        return;
    }
    let slice = std::ptr::slice_from_raw_parts_mut(value.ptr, value.len);
    drop(Box::from_raw(slice));
}

/// Borrows a `SiftString` as a `&str`.
///
/// # Safety
/// The pointer must be valid for `len` bytes and hold UTF-8, which is
/// guaranteed when the value came from Swift's `String` bridging.
unsafe fn as_str<'a>(value: &SiftString) -> Option<&'a str> {
    if value.ptr.is_null() {
        return None;
    }
    let slice = std::slice::from_raw_parts(value.ptr, value.len);
    std::str::from_utf8(slice).ok()
}

/// Opaque engine handle.
///
/// The layout is deliberately private: callers only ever hold the pointer, so
/// there is no struct to version here. The contract is enforced by
/// [`sift_ffi_version`] and by the version field on every data struct.
pub struct SiftEngine {
    engine: Arc<Engine>,
    session: std::sync::Mutex<Option<Arc<ScanHandle>>>,
}

/// Opaque scan handle. Allocated separately so Swift can keep a pointer while a
/// new scan replaces the session.
pub struct SiftScanHandle {
    handle: Arc<ScanHandle>,
}

/// A single event, flattened for C.
///
/// `kind` selects which payload fields are meaningful:
///
/// | `kind` | name | payload |
/// |---|---|---|
/// | 0 | phase | `text` |
/// | 1 | progress | `phase`, counters, `text` = current item name |
/// | 2 | items | `items`, `item_count` |
/// | 3 | duplicateGroup | `group_index`, `member_count`, `reclaimable_bytes` |
/// | 4 | skipped | `text` = code, `detail` = path, `flag` = needs FDA |
/// | 5 | completed | `text` = summary JSON |
/// | 6 | failed | `text` = code, `detail` = user message |
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SiftScanEvent {
    pub version: u32,
    pub kind: i32,
    pub phase: i32,
    pub files_seen: i64,
    pub bytes_seen: i64,
    pub items_found: i64,
    pub group_index: i64,
    pub member_count: i64,
    pub reclaimable_bytes: i64,
    pub byte_count: i64,
    pub flag: i32,
    pub text: SiftString,
    pub detail: SiftString,
    /// Contiguous `SiftItemSummary` array; null unless `kind == 2`.
    pub items: *mut SiftItemSummary,
    pub item_count: usize,
}

/// One cleanup item summary crossing the boundary.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SiftItemSummary {
    pub version: u32,
    pub path: SiftString,
    pub display_name: SiftString,
    pub parent_path: SiftString,
    pub category: SiftString,
    pub risk: SiftString,
    pub explanation_key: SiftString,
    pub rule_id: SiftString,
    pub bundle_id: SiftString,
    pub size_bytes: i64,
    pub file_count: i64,
    pub modified_secs: i64,
    pub is_directory: bool,
}

/// A page of scan results.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SiftPage {
    pub version: u32,
    pub items: *mut SiftItemSummary,
    pub item_count: usize,
    pub remaining: i64,
}

/// A category rollup row.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SiftCategoryTotal {
    pub version: u32,
    pub category: SiftString,
    pub item_count: i64,
    pub total_bytes: i64,
}

/// A duplicate group row.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SiftDuplicateGroup {
    pub version: u32,
    pub group_id: i64,
    pub digest: SiftString,
    pub size_bytes: i64,
    pub member_count: i64,
    pub reclaimable_bytes: i64,
}

/// One member of a duplicate group.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SiftDuplicateMember {
    pub version: u32,
    pub path: SiftString,
    pub size_bytes: i64,
    pub modified_secs: i64,
    pub keep: bool,
}

/// Outcome of an operation that can fail, with a code the UI can act on.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SiftResult {
    pub version: u32,
    pub ok: bool,
    pub code: SiftString,
    pub message: SiftString,
}

/// A large file row.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SiftStorageFile {
    pub version: u32,
    pub path: SiftString,
    pub display_name: SiftString,
    pub parent_path: SiftString,
    pub size_bytes: u64,
    pub modified_secs: i64,
}

/// A directory rollup row.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SiftStorageDirectory {
    pub version: u32,
    pub path: SiftString,
    pub display_name: SiftString,
    pub size_bytes: u64,
    pub file_count: u64,
}

/// Storage analysis outcome.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SiftStorageAnalysis {
    pub version: u32,
    pub ok: bool,
    pub mount_point: SiftString,
    pub volume_name: SiftString,
    pub total_bytes: u64,
    pub free_bytes: u64,
    pub used_bytes: u64,
    pub used_fraction: f64,
    pub scanned_file_count: u64,
    pub scanned_byte_count: u64,
    pub skipped_count: u64,
    pub elapsed_millis: i64,
    pub aggregated: bool,
    /// Contiguous arrays owned by the caller.
    pub categories: *mut SiftCategoryTotal,
    pub category_count: usize,
    pub files: *mut SiftStorageFile,
    pub file_count: usize,
    pub directories: *mut SiftStorageDirectory,
    pub directory_count: usize,
    pub error: SiftString,
}

const EVENT_PHASE: i32 = 0;
const EVENT_PROGRESS: i32 = 1;
const EVENT_ITEMS: i32 = 2;
const EVENT_DUPLICATE_GROUP: i32 = 3;
const EVENT_SKIPPED: i32 = 4;
const EVENT_COMPLETED: i32 = 5;
const EVENT_FAILED: i32 = 6;

/// Runs `body`, converting a Rust panic into a controlled error value.
///
/// A panic must never unwind across the FFI boundary; the specification
/// requires panics to become controlled errors.
fn guard<T>(fallback: T, body: impl FnOnce() -> T) -> T {
    match catch_unwind(AssertUnwindSafe(body)) {
        Ok(value) => value,
        Err(_) => fallback,
    }
}

fn result_ok() -> SiftResult {
    SiftResult {
        version: SIFT_FFI_VERSION,
        ok: true,
        code: SiftString::EMPTY,
        message: SiftString::EMPTY,
    }
}

fn result_err(code: &str, message: &str) -> SiftResult {
    SiftResult {
        version: SIFT_FFI_VERSION,
        ok: false,
        code: SiftString::from_str(code),
        message: SiftString::from_str(message),
    }
}

/// Returns the FFI contract version Swift must match.
#[no_mangle]
pub extern "C" fn sift_ffi_version() -> u32 {
    SIFT_FFI_VERSION
}

/// Returns the built-in rule table as JSON so Swift can show the same
/// explanations and risk levels the scanner applies.
///
/// The document is the one the app ships (`Core/Resources/CleaningRules.json`),
/// not a projection of it: a second shape for the same table is a second thing to
/// keep in step, and this one had already fallen behind — it carried the rule ids
/// and risk levels but not the match specification or the exclusions, and nothing
/// read it, so the drift was invisible.
#[no_mangle]
pub extern "C" fn sift_rules_json() -> SiftString {
    guard(SiftString::EMPTY, || {
        SiftString::from_string(sift_rules::shipped_rules_json())
    })
}

/// Classifies a path against the compiled-in protection list.
///
/// Returns `0` when scannable, `1` for user content, `2` for a system prefix,
/// `3` for secrets and `-1` when the question could not be answered (invalid
/// UTF-8, or a panic). Callers must treat `-1` as protected, not as scannable:
/// an answer that was not given must never unlock a path.
///
/// # Safety
/// Both strings must be valid `SiftString` values.
#[no_mangle]
pub unsafe extern "C" fn sift_path_protection(home_dir: SiftString, path: SiftString) -> i32 {
    const UNKNOWN: i32 = -1;
    guard(UNKNOWN, || {
        let (Some(home), Some(path)) = (as_str(&home_dir), as_str(&path)) else {
            return UNKNOWN;
        };
        match protection_reason(home, path) {
            None => 0,
            Some(reason) => match reason {
                sift_rules::ProtectedReason::UserContent { .. } => 1,
                sift_rules::ProtectedReason::SystemPath { .. } => 2,
                sift_rules::ProtectedReason::Secrets { .. } => 3,
            },
        }
    })
}

/// Creates an engine. Free it with [`sift_engine_free`].
#[no_mangle]
pub extern "C" fn sift_engine_new() -> *mut SiftEngine {
    guard(std::ptr::null_mut(), || {
        Box::into_raw(Box::new(SiftEngine {
            engine: Arc::new(Engine::new()),
            session: std::sync::Mutex::new(None),
        }))
    })
}

/// Frees an engine and every handle it handed out.
///
/// # Safety
/// `engine` must come from [`sift_engine_new`] and be freed once.
#[no_mangle]
pub unsafe extern "C" fn sift_engine_free(engine: *mut SiftEngine) {
    if engine.is_null() {
        return;
    }
    guard((), || drop(Box::from_raw(engine)));
}

/// Starts a scan from a JSON `ScanRequest` and returns a handle.
///
/// On failure the returned pointer is null and `error` carries the code and a
/// user-safe message.
///
/// # Safety
/// `engine` must be valid, `request_json` must be a valid `SiftString`, and
/// `error` may be null.
#[no_mangle]
pub unsafe extern "C" fn sift_scan_start(
    engine: *mut SiftEngine,
    request_json: SiftString,
    error: *mut SiftResult,
) -> *mut SiftScanHandle {
    // The outcome is computed inside the guard and written to `error` after it
    // returns, so the caller's slot is borrowed exactly once.
    let outcome: Result<*mut SiftScanHandle, (&str, String)> = guard(
        Err(("internal", "The scan could not be started.".to_string())),
        || {
            if engine.is_null() {
                return Err((
                    "invalidRequest",
                    "The scanner engine is not available.".to_string(),
                ));
            }
            let Some(json) = as_str(&request_json) else {
                return Err((
                    "invalidRequest",
                    "The scan request was not valid UTF-8.".to_string(),
                ));
            };
            let request: ScanRequest = match serde_json::from_str(json) {
                Ok(request) => request,
                Err(_) => {
                    return Err((
                        "invalidRequest",
                        "The scan request could not be read.".to_string(),
                    ))
                }
            };

            let engine_ref = &*engine;
            match engine_ref.engine.start_scan(request) {
                Ok(handle) => {
                    if let Ok(mut slot) = engine_ref.session.lock() {
                        *slot = Some(Arc::clone(&handle));
                    }
                    Ok(Box::into_raw(Box::new(SiftScanHandle { handle })))
                }
                Err(scan_error) => Err((scan_error.code().as_str(), scan_error.user_message())),
            }
        },
    );

    match outcome {
        Ok(handle_ref) => {
            if !error.is_null() {
                *error = result_ok();
            }
            handle_ref
        }
        Err((code, message)) => {
            if !error.is_null() {
                *error = result_err(code, &message);
            }
            std::ptr::null_mut()
        }
    }
}

/// Cancels the active scan. Safe from any thread and in any state.
///
/// # Safety
/// `engine` must be valid, or null.
#[no_mangle]
pub unsafe extern "C" fn sift_scan_cancel(engine: *mut SiftEngine) {
    guard((), || {
        if engine.is_null() {
            return;
        }
        (*engine).engine.cancel();
    });
}

/// Reports whether the scan behind `handle` has stopped producing results.
///
/// # Safety
/// `handle` must be valid, or null.
#[no_mangle]
pub unsafe extern "C" fn sift_scan_is_finished(handle: *mut SiftScanHandle) -> bool {
    guard(true, || {
        if handle.is_null() {
            return true;
        }
        (*handle).handle.is_finished()
    })
}

/// Drains up to `max_events` events into a caller-provided array.
///
/// Returns how many events were written. Each written event must be released
/// with [`sift_event_free_items`].
///
/// # Safety
/// `handle` must be valid and `out` must point to `max_events` writable slots.
#[no_mangle]
pub unsafe extern "C" fn sift_scan_poll_events(
    handle: *mut SiftScanHandle,
    max_events: u32,
    out: *mut SiftScanEvent,
) -> u32 {
    guard(0, || {
        if handle.is_null() || out.is_null() || max_events == 0 {
            return 0;
        }
        let batch = (*handle).handle.poll_events(max_events);
        let mut written = 0u32;
        for event in batch.events {
            if written >= max_events {
                break;
            }
            *out.add(written as usize) = convert_event(event);
            written += 1;
        }
        written
    })
}

fn convert_event(event: Event) -> SiftScanEvent {
    let base = SiftScanEvent {
        version: SIFT_FFI_VERSION,
        kind: EVENT_PHASE,
        phase: 0,
        files_seen: 0,
        bytes_seen: 0,
        items_found: 0,
        group_index: 0,
        member_count: 0,
        reclaimable_bytes: 0,
        byte_count: 0,
        flag: 0,
        text: SiftString::EMPTY,
        detail: SiftString::EMPTY,
        items: std::ptr::null_mut(),
        item_count: 0,
    };

    match event {
        Event::PhaseChanged { phase } => SiftScanEvent {
            kind: EVENT_PHASE,
            text: SiftString::from_string(phase),
            ..base
        },
        Event::Progress(progress) => SiftScanEvent {
            kind: EVENT_PROGRESS,
            phase: phase_code(&progress.phase),
            files_seen: progress.files_seen,
            bytes_seen: progress.bytes_seen,
            items_found: progress.items_found,
            text: SiftString::from_string(progress.current_path),
            ..base
        },
        Event::ItemBatch { items } => {
            let summaries: Vec<SiftItemSummary> = items.iter().map(convert_item_summary).collect();
            // `into_boxed_slice` pins the allocation to exactly `len` elements.
            // Taking `as_mut_ptr()` from a `Vec` and later rebuilding a
            // `Box<[T]>` is only correct when capacity == len, and `collect`
            // does not promise that (it over-allocates past 1024 elements).
            let boxed = summaries.into_boxed_slice();
            let count = boxed.len();
            let pointer = Box::into_raw(boxed) as *mut SiftItemSummary;
            SiftScanEvent {
                kind: EVENT_ITEMS,
                items: pointer,
                item_count: count,
                ..base
            }
        }
        Event::DuplicateGroup {
            group_index,
            member_count,
            reclaimable_bytes,
        } => SiftScanEvent {
            kind: EVENT_DUPLICATE_GROUP,
            group_index,
            member_count,
            reclaimable_bytes,
            ..base
        },
        Event::LocationSkipped(skipped) => SiftScanEvent {
            kind: EVENT_SKIPPED,
            text: SiftString::from_str(&skipped.code),
            detail: SiftString::from_string(skipped.path),
            byte_count: skipped.byte_count,
            flag: if skipped.needs_full_disk_access { 1 } else { 0 },
            ..base
        },
        Event::Completed(summary) => SiftScanEvent {
            kind: EVENT_COMPLETED,
            // The summary travels as JSON: its shape is owned by the core crate
            // and re-encoding keeps the C surface small.
            text: SiftString::from_str(
                &serde_json::to_string(&*summary).unwrap_or_else(|_| "{}".to_string()),
            ),
            ..base
        },
        Event::Failed { code, message } => SiftScanEvent {
            kind: EVENT_FAILED,
            text: SiftString::from_string(code),
            detail: SiftString::from_string(message),
            ..base
        },
    }
}

fn convert_item_summary(item: &sift_scanner_core::ScanItemSummary) -> SiftItemSummary {
    SiftItemSummary {
        version: SIFT_FFI_VERSION,
        path: SiftString::from_str(&item.path),
        display_name: SiftString::from_str(&item.display_name),
        parent_path: SiftString::from_str(&item.parent_path),
        category: SiftString::from_str(&item.category),
        risk: SiftString::from_str(&item.risk),
        explanation_key: SiftString::from_str(&item.explanation_key),
        rule_id: SiftString::from_str(&item.rule_id),
        bundle_id: item
            .bundle_id
            .as_ref()
            .map(|id| SiftString::from_str(id))
            .unwrap_or(SiftString::EMPTY),
        size_bytes: item.size_bytes,
        file_count: item.file_count,
        modified_secs: item.modified_secs,
        is_directory: item.is_directory,
    }
}

fn convert_item_record(row: &sift_file_index::ItemRecord) -> SiftItemSummary {
    SiftItemSummary {
        version: SIFT_FFI_VERSION,
        path: SiftString::from_str(&row.path),
        display_name: SiftString::from_str(&row.display_name),
        parent_path: SiftString::from_str(&row.parent_path),
        category: SiftString::from_str(&row.category),
        risk: SiftString::from_str(&row.risk),
        explanation_key: SiftString::from_str(&row.explanation_key),
        rule_id: SiftString::from_str(&row.rule_id),
        bundle_id: row
            .bundle_id
            .as_ref()
            .map(|id| SiftString::from_str(id))
            .unwrap_or(SiftString::EMPTY),
        size_bytes: row.size_bytes,
        file_count: row.file_count,
        modified_secs: row.modified_secs,
        is_directory: row.is_directory,
    }
}

fn phase_code(phase: &str) -> i32 {
    match phase {
        "idle" => 0,
        "preparing" => 1,
        "scanning" => 2,
        "indexing" => 3,
        "ready" => 4,
        "cancelled" => 5,
        "partial" => 6,
        "failed" => 7,
        _ => 0,
    }
}

/// Releases the arrays and strings inside an event.
///
/// # Safety
/// `event` must be one returned by [`sift_scan_poll_events`], freed once.
#[no_mangle]
pub unsafe extern "C" fn sift_event_free_items(event: *mut SiftScanEvent) {
    guard((), || {
        if event.is_null() {
            return;
        }
        let event = &mut *event;
        if !event.items.is_null() && event.item_count > 0 {
            for index in 0..event.item_count {
                free_item_summary(event.items.add(index));
            }
            let slice = std::ptr::slice_from_raw_parts_mut(event.items, event.item_count);
            drop(Box::from_raw(slice));
            event.items = std::ptr::null_mut();
            event.item_count = 0;
        }
        sift_string_free(event.text);
        sift_string_free(event.detail);
        event.text = SiftString::EMPTY;
        event.detail = SiftString::EMPTY;
    });
}

/// Releases one item summary in place.
///
/// # Safety
/// `item` must point to a summary owned by the caller.
unsafe fn free_item_summary(item: *mut SiftItemSummary) {
    if item.is_null() {
        return;
    }
    let item = &mut *item;
    for field in [
        &mut item.path,
        &mut item.display_name,
        &mut item.parent_path,
        &mut item.category,
        &mut item.risk,
        &mut item.explanation_key,
        &mut item.rule_id,
        &mut item.bundle_id,
    ] {
        sift_string_free(*field);
        *field = SiftString::EMPTY;
    }
}

/// Reads one page of results out of the session index.
///
/// `sort` is one of `size`, `name`, `modified`, `category`. Pass a null
/// `category` to page every category. On success `out` must be freed with
/// [`sift_page_free`].
///
/// # Safety
/// `handle` must be valid, `out` must be writable and `error` may be null.
#[no_mangle]
pub unsafe extern "C" fn sift_scan_page_results(
    handle: *mut SiftScanHandle,
    offset: u32,
    limit: u32,
    sort: SiftString,
    category: SiftString,
    out: *mut SiftPage,
    error: *mut SiftResult,
) -> bool {
    guard(false, || {
        if !error.is_null() {
            *error = result_ok();
        }
        if handle.is_null() || out.is_null() {
            if !error.is_null() {
                *error = result_err("invalidRequest", "No scan session is available.");
            }
            return false;
        }
        let sort_value = as_str(&sort).unwrap_or("size");
        // An empty string means "every category", the same as a null pointer.
        // Treating "" as a real category silently returned no rows.
        let category_value = as_str(&category).filter(|value| !value.is_empty());
        let handle_ref = &(*handle).handle;
        match handle_ref.page_results(offset, limit, sort_value, category_value) {
            Ok(rows) => {
                // Counted with the same filter as the page, so `remaining`
                // never promises rows the filter cannot produce.
                let total = handle_ref.index().count_items(category_value).unwrap_or(0);
                let items: Vec<SiftItemSummary> = rows.iter().map(convert_item_record).collect();
                // See `convert_event`: the free path rebuilds a `Box<[T]>`, so
                // the allocation must be exactly `len` elements.
                let boxed = items.into_boxed_slice();
                let count = boxed.len();
                let pointer = Box::into_raw(boxed) as *mut SiftItemSummary;
                *out = SiftPage {
                    version: SIFT_FFI_VERSION,
                    items: pointer,
                    item_count: count,
                    remaining: (total - (offset as i64 + count as i64)).max(0),
                };
                true
            }
            Err(scan_error) => {
                if !error.is_null() {
                    *error = result_err(scan_error.code().as_str(), &scan_error.user_message());
                }
                false
            }
        }
    })
}

/// Frees a page and every string it owns.
///
/// # Safety
/// `page` must come from [`sift_scan_page_results`] and be freed once.
#[no_mangle]
pub unsafe extern "C" fn sift_page_free(page: *mut SiftPage) {
    guard((), || {
        if page.is_null() {
            return;
        }
        let page = &mut *page;
        if !page.items.is_null() && page.item_count > 0 {
            for index in 0..page.item_count {
                free_item_summary(page.items.add(index));
            }
            let slice = std::ptr::slice_from_raw_parts_mut(page.items, page.item_count);
            drop(Box::from_raw(slice));
            page.items = std::ptr::null_mut();
            page.item_count = 0;
        }
    });
}

/// Reads one page of duplicate groups, largest reclaimable first.
///
/// # Safety
/// `handle` must be valid and `out` must point to `max_groups` slots. Each
/// written row must be released with [`sift_duplicate_group_free`].
#[no_mangle]
pub unsafe extern "C" fn sift_scan_page_duplicate_groups(
    handle: *mut SiftScanHandle,
    offset: u32,
    limit: u32,
    out: *mut SiftDuplicateGroup,
    max_groups: u32,
) -> u32 {
    guard(0, || {
        if handle.is_null() || out.is_null() {
            return 0;
        }
        let index = (*handle).handle.index();
        let Ok(groups) = index.page_duplicate_groups(offset, limit) else {
            return 0;
        };
        let mut written = 0u32;
        for group in groups {
            if written >= max_groups {
                break;
            }
            *out.add(written as usize) = SiftDuplicateGroup {
                version: SIFT_FFI_VERSION,
                group_id: group.group_id,
                digest: SiftString::from_str(&group.digest),
                size_bytes: group.size_bytes,
                member_count: group.member_count,
                reclaimable_bytes: group.reclaimable_bytes,
            };
            written += 1;
        }
        written
    })
}

/// Reads the members of one duplicate group.
///
/// # Safety
/// `handle` must be valid and `out` must point to `max_members` slots. Each
/// written row must be released with [`sift_duplicate_member_free`].
#[no_mangle]
pub unsafe extern "C" fn sift_scan_duplicate_members(
    handle: *mut SiftScanHandle,
    group_id: i64,
    offset: u32,
    limit: u32,
    out: *mut SiftDuplicateMember,
    max_members: u32,
) -> u32 {
    guard(0, || {
        if handle.is_null() || out.is_null() {
            return 0;
        }
        let index = (*handle).handle.index();
        let Ok(members) = index.duplicate_members(group_id, offset, limit) else {
            return 0;
        };
        let mut written = 0u32;
        for member in members {
            if written >= max_members {
                break;
            }
            *out.add(written as usize) = SiftDuplicateMember {
                version: SIFT_FFI_VERSION,
                path: SiftString::from_str(&member.path),
                size_bytes: member.size_bytes,
                modified_secs: member.modified_secs,
                keep: member.keep,
            };
            written += 1;
        }
        written
    })
}

/// Frees a duplicate group row.
///
/// # Safety
/// The value must come from this library and be freed once.
#[no_mangle]
pub unsafe extern "C" fn sift_duplicate_group_free(group: *mut SiftDuplicateGroup) {
    guard((), || {
        if group.is_null() {
            return;
        }
        sift_string_free((*group).digest);
        (*group).digest = SiftString::EMPTY;
    });
}

/// Frees a duplicate member row.
///
/// # Safety
/// The value must come from this library and be freed once.
#[no_mangle]
pub unsafe extern "C" fn sift_duplicate_member_free(member: *mut SiftDuplicateMember) {
    guard((), || {
        if member.is_null() {
            return;
        }
        sift_string_free((*member).path);
        (*member).path = SiftString::EMPTY;
    });
}

/// Frees a scan handle wrapper. The engine keeps the session alive.
///
/// # Safety
/// `handle` must come from [`sift_scan_start`] and be freed once.
#[no_mangle]
pub unsafe extern "C" fn sift_scan_free(handle: *mut SiftScanHandle) {
    guard((), || {
        if handle.is_null() {
            return;
        }
        drop(Box::from_raw(handle));
    });
}

/// Lists the skipped locations recorded for the active session, as JSON.
///
/// # Safety
/// `handle` must be valid, or null.
#[no_mangle]
pub unsafe extern "C" fn sift_scan_skipped_json(handle: *mut SiftScanHandle) -> SiftString {
    guard(SiftString::EMPTY, || {
        if handle.is_null() {
            return SiftString::EMPTY;
        }
        let skipped = (*handle).handle.skipped_locations();
        #[derive(serde::Serialize)]
        struct Row {
            path: String,
            code: String,
            message: String,
            byte_count: i64,
        }
        let rows: Vec<Row> = skipped
            .into_iter()
            .map(|location| Row {
                path: location.path,
                code: location.code,
                message: location.message,
                byte_count: location.byte_count,
            })
            .collect();
        match serde_json::to_string(&rows) {
            Ok(json) => SiftString::from_string(json),
            Err(_) => SiftString::EMPTY,
        }
    })
}

/// A cancellation token for a storage analysis.
///
/// The analyse call is blocking, so the UI runs it on a background thread and
/// calls [`sift_storage_cancel`] from the thread that owns the cancel button.
/// The token is an atomic flag; cloning it would copy the value rather than
/// share it, which is why the pointer is passed through.
pub struct SiftStorageCancel {
    token: CancelToken,
}

/// Creates a storage cancellation token. Free it with
/// [`sift_storage_cancel_free`].
#[no_mangle]
pub extern "C" fn sift_storage_cancel_new() -> *mut SiftStorageCancel {
    guard(std::ptr::null_mut(), || {
        Box::into_raw(Box::new(SiftStorageCancel {
            token: CancelToken::new(),
        }))
    })
}

/// Requests cancellation. Safe from any thread and in any state.
///
/// # Safety
/// `cancel` must come from [`sift_storage_cancel_new`], or be null.
#[no_mangle]
pub unsafe extern "C" fn sift_storage_cancel(cancel: *mut SiftStorageCancel) {
    guard((), || {
        if !cancel.is_null() {
            (*cancel).token.cancel();
        }
    });
}

/// Frees a storage cancellation token.
///
/// # Safety
/// `cancel` must come from [`sift_storage_cancel_new`] and be freed once.
#[no_mangle]
pub unsafe extern "C" fn sift_storage_cancel_free(cancel: *mut SiftStorageCancel) {
    guard((), || {
        if !cancel.is_null() {
            drop(Box::from_raw(cancel));
        }
    });
}

/// Runs a storage analysis from a JSON options object.
///
/// `cancel` may be null. When it is not, the analysis stops at its next
/// checkpoint when [`sift_storage_cancel`] is called from another thread.
///
/// # Safety
/// `options_json` must be a valid `SiftString`, `cancel` must come from
/// [`sift_storage_cancel_new`] or be null, and the result must be freed with
/// [`sift_storage_analysis_free`].
#[no_mangle]
pub unsafe extern "C" fn sift_storage_analyse(
    options_json: SiftString,
    cancel: *mut SiftStorageCancel,
) -> *mut SiftStorageAnalysis {
    guard(std::ptr::null_mut(), || {
        #[derive(serde::Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Options {
            home_dir: String,
            roots: Vec<String>,
            #[serde(default)]
            ignore_paths: Vec<String>,
            #[serde(default)]
            top_file_limit: Option<u32>,
            #[serde(default)]
            top_directory_limit: Option<u32>,
            #[serde(default)]
            directory_rollup_limit: Option<u32>,
            #[serde(default)]
            large_file_threshold_bytes: Option<u64>,
            /// Roots the caller authorised. Storage analysis honours the same
            /// grants as a scan, or an authorised volume would be skipped.
            #[serde(default)]
            authorized_roots: Vec<String>,
            /// Whether dot entries are part of the measurement. Missing means
            /// the historical, permissive behaviour.
            #[serde(default = "storage_hidden_default")]
            include_hidden_files: bool,
        }

        fn storage_hidden_default() -> bool {
            true
        }

        let fail = |message: &str| {
            Box::into_raw(Box::new(SiftStorageAnalysis {
                version: SIFT_FFI_VERSION,
                ok: false,
                error: SiftString::from_str(message),
                ..empty_storage_analysis()
            }))
        };

        let Some(json) = as_str(&options_json) else {
            return fail("The analysis options were not valid UTF-8.");
        };
        let Ok(options) = serde_json::from_str::<Options>(json) else {
            return fail("The analysis options could not be read.");
        };

        let mut analysis_options =
            AnalysisOptions::new(PathBuf::from(&options.home_dir), Vec::new());
        analysis_options.roots = options.roots.iter().map(PathBuf::from).collect();
        analysis_options.ignore_paths = options.ignore_paths.iter().map(PathBuf::from).collect();
        analysis_options.authorized_roots =
            options.authorized_roots.iter().map(PathBuf::from).collect();
        analysis_options.include_hidden_files = options.include_hidden_files;
        if let Some(limit) = options.top_file_limit {
            analysis_options.top_file_limit = limit;
        }
        if let Some(limit) = options.top_directory_limit {
            analysis_options.top_directory_limit = limit;
        }
        if let Some(limit) = options.directory_rollup_limit {
            analysis_options.directory_rollup_limit = limit as usize;
        }
        if let Some(threshold) = options.large_file_threshold_bytes {
            analysis_options.large_file_threshold_bytes = threshold;
        }

        // Borrow the caller's token, never a clone: `CancelToken::clone` copies
        // the current flag rather than sharing it, so a clone could never be
        // cancelled from the UI thread.
        let own_token;
        let token = if cancel.is_null() {
            own_token = CancelToken::new();
            &own_token
        } else {
            &(*cancel).token
        };
        let analysis = storage::analyse(&analysis_options, token);

        let categories: Vec<SiftCategoryTotal> = analysis
            .categories
            .iter()
            .map(|category| SiftCategoryTotal {
                version: SIFT_FFI_VERSION,
                category: SiftString::from_str(&category.category),
                item_count: category.file_count as i64,
                total_bytes: category.size_bytes as i64,
            })
            .collect::<Vec<_>>();
        let category_boxed = categories.into_boxed_slice();
        let category_count = category_boxed.len();
        let category_pointer = Box::into_raw(category_boxed) as *mut SiftCategoryTotal;

        let files: Vec<SiftStorageFile> = analysis
            .top_files
            .iter()
            .map(|file| SiftStorageFile {
                version: SIFT_FFI_VERSION,
                path: SiftString::from_str(&file.path),
                display_name: SiftString::from_str(&file.display_name),
                parent_path: SiftString::from_str(&file.parent_path),
                size_bytes: file.size_bytes,
                modified_secs: file.modified_secs,
            })
            .collect::<Vec<_>>();
        let file_boxed = files.into_boxed_slice();
        let file_count = file_boxed.len();
        let file_pointer = Box::into_raw(file_boxed) as *mut SiftStorageFile;

        let directories: Vec<SiftStorageDirectory> = analysis
            .top_directories
            .iter()
            .map(|directory| SiftStorageDirectory {
                version: SIFT_FFI_VERSION,
                path: SiftString::from_str(&directory.path),
                display_name: SiftString::from_str(&directory.display_name),
                size_bytes: directory.size_bytes,
                file_count: directory.file_count,
            })
            .collect::<Vec<_>>();
        let directory_boxed = directories.into_boxed_slice();
        let directory_count = directory_boxed.len();
        let directory_pointer = Box::into_raw(directory_boxed) as *mut SiftStorageDirectory;

        Box::into_raw(Box::new(SiftStorageAnalysis {
            version: SIFT_FFI_VERSION,
            ok: true,
            mount_point: SiftString::from_str(&analysis.volume.mount_point),
            volume_name: SiftString::from_str(&analysis.volume.volume_name),
            total_bytes: analysis.volume.total_bytes,
            free_bytes: analysis.volume.free_bytes,
            used_bytes: analysis.volume.used_bytes,
            used_fraction: analysis.volume.used_fraction,
            scanned_file_count: analysis.scanned_file_count,
            scanned_byte_count: analysis.scanned_byte_count,
            skipped_count: analysis.skipped_count,
            elapsed_millis: analysis.elapsed_millis,
            aggregated: analysis.aggregated,
            categories: category_pointer,
            category_count,
            files: file_pointer,
            file_count,
            directories: directory_pointer,
            directory_count,
            error: SiftString::EMPTY,
        }))
    })
}

fn empty_storage_analysis() -> SiftStorageAnalysis {
    SiftStorageAnalysis {
        version: SIFT_FFI_VERSION,
        ok: false,
        mount_point: SiftString::EMPTY,
        volume_name: SiftString::EMPTY,
        total_bytes: 0,
        free_bytes: 0,
        used_bytes: 0,
        used_fraction: 0.0,
        scanned_file_count: 0,
        scanned_byte_count: 0,
        skipped_count: 0,
        elapsed_millis: 0,
        aggregated: false,
        categories: std::ptr::null_mut(),
        category_count: 0,
        files: std::ptr::null_mut(),
        file_count: 0,
        directories: std::ptr::null_mut(),
        directory_count: 0,
        error: SiftString::EMPTY,
    }
}

/// Frees a storage analysis and every array it owns.
///
/// # Safety
/// `analysis` must come from [`sift_storage_analyse`] and be freed once.
#[no_mangle]
pub unsafe extern "C" fn sift_storage_analysis_free(analysis: *mut SiftStorageAnalysis) {
    guard((), || {
        if analysis.is_null() {
            return;
        }
        let value = Box::from_raw(analysis);

        sift_string_free(value.mount_point);
        sift_string_free(value.volume_name);
        sift_string_free(value.error);

        if !value.categories.is_null() && value.category_count > 0 {
            for index in 0..value.category_count {
                sift_string_free((*value.categories.add(index)).category);
            }
            drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(
                value.categories,
                value.category_count,
            )));
        }
        if !value.files.is_null() && value.file_count > 0 {
            for index in 0..value.file_count {
                let row = value.files.add(index);
                sift_string_free((*row).path);
                sift_string_free((*row).display_name);
                sift_string_free((*row).parent_path);
            }
            drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(
                value.files,
                value.file_count,
            )));
        }
        if !value.directories.is_null() && value.directory_count > 0 {
            for index in 0..value.directory_count {
                let row = value.directories.add(index);
                sift_string_free((*row).path);
                sift_string_free((*row).display_name);
            }
            drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(
                value.directories,
                value.directory_count,
            )));
        }
    });
}

/// Asks the scanner whether a risk level may enter the deletion queue. Swift
/// calls this before enabling a checkbox, so a `protected` item can never be
/// selected even if a rule file were wrong.
#[no_mangle]
pub extern "C" fn sift_risk_is_cleanable(risk: SiftString) -> bool {
    guard(false, || {
        let Some(value) = (unsafe { as_str(&risk) }) else {
            return false;
        };
        matches!(value, "safe" | "review")
    })
}

/// Returns the most cautious risk level the library assigns to a category.
#[no_mangle]
pub extern "C" fn sift_default_risk_for_category(category: SiftString) -> SiftString {
    guard(SiftString::EMPTY, || {
        let Some(value) = (unsafe { as_str(&category) }) else {
            return SiftString::EMPTY;
        };
        let risk = default_rules()
            .iter()
            .filter(|rule| rule.category.as_str() == value)
            .map(|rule| rule.risk)
            // `Risk` orders Safe < Review < Protected, so the most cautious
            // level is the maximum. `min` answered `safe` for `logs`, which has
            // both safe and review rules, and would have preselected
            // diagnostic reports.
            .max()
            .unwrap_or(Risk::Review);
        SiftString::from_str(risk.as_str())
    })
}

/// Byte length of a NUL-terminated C string. Used by the contract tests and by
/// Swift's string bridging helper.
///
/// # Safety
/// `value` must be NUL-terminated UTF-8, or null.
#[no_mangle]
pub unsafe extern "C" fn sift_cstr_len(value: *const c_char) -> usize {
    if value.is_null() {
        return 0;
    }
    CStr::from_ptr(value).to_bytes().len()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn string(value: &str) -> SiftString {
        SiftString::from_str(value)
    }

    fn empty_event() -> SiftScanEvent {
        SiftScanEvent {
            version: 0,
            kind: -1,
            phase: 0,
            files_seen: 0,
            bytes_seen: 0,
            items_found: 0,
            group_index: 0,
            member_count: 0,
            reclaimable_bytes: 0,
            byte_count: 0,
            flag: 0,
            text: SiftString::EMPTY,
            detail: SiftString::EMPTY,
            items: std::ptr::null_mut(),
            item_count: 0,
        }
    }

    fn scan_request_json(session: &str, home: &str) -> String {
        serde_json::json!({
            "sessionId": session,
            "homeDir": home,
            "roots": [{
                "path": home,
                "anchor": "home",
                "isCleanable": true,
                "maxDepth": null,
                "volumeId": null
            }],
            "largeFileThresholdBytes": 1048576u64,
            "oldFileThresholdDays": 180,
            "staleThresholdDays": 30,
            "ignorePaths": [],
            "installedBundleIds": [],
            "extraRulesJson": null,
            "includeDuplicates": false,
            "duplicates": { "roots": [], "minSizeBytes": 4096, "maxFullHashes": 1000 },
            "eventBatchItems": 8,
            "indexPath": ""
        })
        .to_string()
    }

    #[test]
    fn ffi_version_is_stable() {
        assert_eq!(sift_ffi_version(), SIFT_FFI_VERSION);
        assert_eq!(sift_ffi_version(), 1);
    }

    #[test]
    fn strings_round_trip_and_free() {
        let value = string("路径 with spaces and ünïcödé");
        unsafe {
            assert_eq!(as_str(&value), Some("路径 with spaces and ünïcödé"));
            sift_string_free(value);
        }
    }

    #[test]
    fn empty_and_null_strings_are_safe_to_free() {
        unsafe {
            sift_string_free(SiftString::EMPTY);
            let null_len = SiftString {
                ptr: std::ptr::null_mut(),
                len: 4,
            };
            sift_string_free(null_len);
        }
    }

    #[test]
    fn rules_json_contains_the_shipped_rules() {
        let json = sift_rules_json();
        let text = unsafe { as_str(&json) }.expect("valid utf8").to_string();
        unsafe { sift_string_free(json) };
        assert!(text.contains("user-cache"));
        assert!(text.contains("explanationKey"));
        assert!(text.contains("requiresFullDiskAccess"));
    }

    #[test]
    fn path_protection_classifies_each_reason() {
        unsafe {
            let home = string("/Users/example");
            let documents = string("/Users/example/Documents/a.txt");
            let system = string("/System/Library/Caches/x");
            let keychain = string("/Users/example/Library/Keychains/login.keychain-db");
            let cache = string("/Users/example/Library/Caches/com.a/b");

            assert_eq!(sift_path_protection(home, documents), 1);
            assert_eq!(sift_path_protection(home, system), 2);
            assert_eq!(sift_path_protection(home, keychain), 3);
            assert_eq!(sift_path_protection(home, cache), 0);

            for value in [home, documents, system, keychain, cache] {
                sift_string_free(value);
            }
        }
    }

    #[test]
    fn a_case_variant_is_classified_as_protected() {
        unsafe {
            let home = string("/Users/example");
            let documents = string("/Users/example/documents/a.txt");
            let keychain = string("/Users/example/LIBRARY/KEYCHAINS/login.keychain-db");
            assert_eq!(sift_path_protection(home, documents), 1);
            assert_eq!(sift_path_protection(home, keychain), 3);
            sift_string_free(home);
            sift_string_free(documents);
            sift_string_free(keychain);
        }
    }

    #[test]
    fn an_unanswerable_protection_query_is_not_scannable() {
        unsafe {
            let home = string("/Users/example");
            // Invalid UTF-8: the answer is unknown, and the caller must treat
            // unknown as protected.
            let mut invalid = [0xFFu8];
            let value = SiftString {
                ptr: invalid.as_mut_ptr(),
                len: invalid.len(),
            };
            assert_eq!(sift_path_protection(home, value), -1);
            sift_string_free(home);
        }
    }

    #[test]
    fn a_large_item_batch_frees_with_the_boxed_slice_layout() {
        // More than 1024 items is where `Vec::collect` starts over-allocating;
        // the free path rebuilds a `Box<[T]>`, so the allocation must be exact.
        let items: Vec<sift_scanner_core::ScanItemSummary> = (0..5000)
            .map(|index| sift_scanner_core::ScanItemSummary {
                path: format!("/tmp/item-{index}"),
                display_name: format!("item-{index}"),
                parent_path: "/tmp".to_string(),
                category: "logs".to_string(),
                risk: "safe".to_string(),
                size_bytes: 1,
                file_count: 1,
                explanation_key: "cleanup.explanation.logsItem".to_string(),
                rule_id: "test".to_string(),
                bundle_id: None,
                modified_secs: 0,
                is_directory: false,
            })
            .collect();
        let mut event = convert_event(Event::ItemBatch { items });
        assert_eq!(event.item_count, 5000);
        assert!(!event.items.is_null());
        unsafe { sift_event_free_items(&mut event) };
        assert!(event.items.is_null());
        assert_eq!(event.item_count, 0);
    }

    #[test]
    fn engine_lifecycle_is_balanced() {
        let engine = sift_engine_new();
        assert!(!engine.is_null());
        unsafe {
            sift_engine_free(engine);
            sift_engine_free(std::ptr::null_mut());
        }
    }

    #[test]
    fn invalid_request_json_reports_an_error_instead_of_panicking() {
        let engine = sift_engine_new();
        let mut error = result_ok();
        unsafe {
            let handle = sift_scan_start(engine, string("not json"), &mut error);
            assert!(handle.is_null());
            assert!(!error.ok);
            assert_eq!(as_str(&error.code), Some("invalidRequest"));
            assert!(!as_str(&error.message).unwrap().contains('/'));
            sift_string_free(error.code);
            sift_string_free(error.message);
            sift_engine_free(engine);
        }
    }

    #[test]
    fn a_scan_runs_end_to_end_through_the_abi() {
        let tree = sift_scanner_core::walker::fixtures::TempTree::new("ffi-scan");
        tree.file("Library/Caches/com.example.app/blob.bin", 8192);
        tree.file("Library/Caches/com.other.app/blob.bin", 4096);

        let engine = sift_engine_new();
        let mut error = result_ok();
        let request = scan_request_json("ffi-session", &tree.root.to_string_lossy());
        let handle = unsafe { sift_scan_start(engine, string(&request), &mut error) };
        let code = unsafe { as_str(&error.code) }.unwrap_or("");
        let message = unsafe { as_str(&error.message) }.unwrap_or("");
        assert!(
            !handle.is_null(),
            "scan starts (code={code:?} message={message:?})"
        );
        assert!(error.ok, "no error expected: {code} {message}");

        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
        while unsafe { !sift_scan_is_finished(handle) } && std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        assert!(unsafe { sift_scan_is_finished(handle) }, "scan finishes");

        let mut events = vec![empty_event(); 64];
        let mut saw_completed = false;
        let mut item_batches = 0u32;
        loop {
            let written = unsafe { sift_scan_poll_events(handle, 64, events.as_mut_ptr()) };
            if written == 0 {
                break;
            }
            for event in events.iter_mut().take(written as usize) {
                match event.kind {
                    EVENT_COMPLETED => saw_completed = true,
                    EVENT_ITEMS => {
                        item_batches += 1;
                        assert!(!event.items.is_null());
                        assert!(event.item_count > 0);
                    }
                    _ => {}
                }
                unsafe { sift_event_free_items(event) };
            }
        }
        assert!(saw_completed, "a completed event arrives");
        assert!(item_batches > 0, "items arrive in batches");

        let mut page = SiftPage {
            version: 0,
            items: std::ptr::null_mut(),
            item_count: 0,
            remaining: 0,
        };
        let mut page_error = result_ok();
        let ok = unsafe {
            sift_scan_page_results(
                handle,
                0,
                10,
                string("size"),
                SiftString::EMPTY,
                &mut page,
                &mut page_error,
            )
        };
        assert!(ok, "paging works");
        assert!(page.item_count > 0);
        assert_eq!(page.version, SIFT_FFI_VERSION);
        unsafe { sift_page_free(&mut page) };

        // A page request for a category never reports a negative remainder.
        let mut empty_page = SiftPage {
            version: 0,
            items: std::ptr::null_mut(),
            item_count: 0,
            remaining: 0,
        };
        let ok = unsafe {
            sift_scan_page_results(
                handle,
                0,
                10,
                string("size"),
                string("duplicateFiles"),
                &mut empty_page,
                &mut page_error,
            )
        };
        assert!(ok);
        assert_eq!(empty_page.item_count, 0);
        assert_eq!(empty_page.remaining, 0);
        unsafe { sift_page_free(&mut empty_page) };

        unsafe {
            sift_scan_free(handle);
            sift_engine_free(engine);
            sift_string_free(error.code);
            sift_string_free(error.message);
            sift_string_free(page_error.code);
            sift_string_free(page_error.message);
        }
    }

    #[test]
    fn paging_without_a_session_reports_an_error() {
        let mut page = SiftPage {
            version: 0,
            items: std::ptr::null_mut(),
            item_count: 0,
            remaining: 0,
        };
        let mut error = result_ok();
        let ok = unsafe {
            sift_scan_page_results(
                std::ptr::null_mut(),
                0,
                10,
                string("size"),
                SiftString::EMPTY,
                &mut page,
                &mut error,
            )
        };
        assert!(!ok);
        assert!(!error.ok);
        unsafe {
            sift_string_free(error.code);
            sift_string_free(error.message);
        }
    }

    #[test]
    fn duplicate_paging_handles_an_empty_index() {
        let engine = sift_engine_new();
        let request = scan_request_json("empty", "/tmp");
        let mut error = result_ok();
        let handle = unsafe { sift_scan_start(engine, string(&request), &mut error) };
        assert!(!handle.is_null());
        let mut groups = [SiftDuplicateGroup {
            version: 0,
            group_id: 0,
            digest: SiftString::EMPTY,
            size_bytes: 0,
            member_count: 0,
            reclaimable_bytes: 0,
        }; 4];
        let written =
            unsafe { sift_scan_page_duplicate_groups(handle, 0, 4, groups.as_mut_ptr(), 4) };
        assert_eq!(written, 0);
        let mut members = [SiftDuplicateMember {
            version: 0,
            path: SiftString::EMPTY,
            size_bytes: 0,
            modified_secs: 0,
            keep: false,
        }; 4];
        let written =
            unsafe { sift_scan_duplicate_members(handle, 1, 0, 4, members.as_mut_ptr(), 4) };
        assert_eq!(written, 0);
        unsafe {
            sift_scan_free(handle);
            sift_engine_free(engine);
            sift_string_free(error.code);
            sift_string_free(error.message);
        }
    }

    #[test]
    fn duplicate_results_survive_the_abi_round_trip() {
        let tree = sift_scanner_core::walker::fixtures::TempTree::new("ffi-duplicates");
        tree.file_with("Downloads/copy-one.bin", b"same payload for both files");
        tree.file_with("Downloads/copy-two.bin", b"same payload for both files");

        let mut request: serde_json::Value =
            serde_json::from_str(&scan_request_json("dups", &tree.root.to_string_lossy())).unwrap();
        request["includeDuplicates"] = serde_json::json!(true);
        request["duplicates"]["minSizeBytes"] = serde_json::json!(1);
        request["duplicates"]["roots"] = serde_json::json!([tree.root.to_string_lossy()]);

        let engine = sift_engine_new();
        let mut error = result_ok();
        let handle = unsafe { sift_scan_start(engine, string(&request.to_string()), &mut error) };
        assert!(!handle.is_null());

        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
        while unsafe { !sift_scan_is_finished(handle) } && std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        // Drain events so every string is released before the handle is freed.
        let mut events = vec![empty_event(); 32];
        loop {
            let written = unsafe { sift_scan_poll_events(handle, 32, events.as_mut_ptr()) };
            if written == 0 {
                break;
            }
            for event in events.iter_mut().take(written as usize) {
                unsafe { sift_event_free_items(event) };
            }
        }

        let mut groups = [SiftDuplicateGroup {
            version: 0,
            group_id: 0,
            digest: SiftString::EMPTY,
            size_bytes: 0,
            member_count: 0,
            reclaimable_bytes: 0,
        }; 8];
        let written =
            unsafe { sift_scan_page_duplicate_groups(handle, 0, 8, groups.as_mut_ptr(), 8) };
        assert_eq!(written, 1, "one duplicate group crosses the boundary");
        assert_eq!(groups[0].member_count, 2);
        assert!(groups[0].reclaimable_bytes > 0);
        assert!(!groups[0].digest.ptr.is_null());

        let group_id = groups[0].group_id;
        let mut members = [SiftDuplicateMember {
            version: 0,
            path: SiftString::EMPTY,
            size_bytes: 0,
            modified_secs: 0,
            keep: false,
        }; 8];
        let written =
            unsafe { sift_scan_duplicate_members(handle, group_id, 0, 8, members.as_mut_ptr(), 8) };
        assert_eq!(written, 2);
        assert_eq!(
            members.iter().take(2).filter(|member| member.keep).count(),
            1,
            "exactly one copy is recommended to keep"
        );

        unsafe {
            for group in groups.iter_mut() {
                sift_duplicate_group_free(group);
            }
            for member in members.iter_mut() {
                sift_duplicate_member_free(member);
            }
            sift_scan_free(handle);
            sift_engine_free(engine);
            sift_string_free(error.code);
            sift_string_free(error.message);
        }
    }

    #[test]
    fn a_duplicate_group_larger_than_one_page_pages_without_repeating() {
        // The defect this covers: the FFI call ignored the caller's offset and
        // re-read the first page, so a group of more than 512 copies accumulated
        // duplicates on the Swift side.
        let tree = sift_scanner_core::walker::fixtures::TempTree::new("ffi-duplicate-paging");
        let payload = vec![b'x'; 4096];
        for index in 0..520 {
            tree.file_with(&format!("Downloads/copy-{index:04}.bin"), &payload);
        }

        let mut request: serde_json::Value =
            serde_json::from_str(&scan_request_json("paging", &tree.root.to_string_lossy()))
                .unwrap();
        request["includeDuplicates"] = serde_json::json!(true);
        request["duplicates"]["minSizeBytes"] = serde_json::json!(1);
        request["duplicates"]["roots"] = serde_json::json!([tree.root.to_string_lossy()]);

        let engine = sift_engine_new();
        let mut error = result_ok();
        let handle = unsafe { sift_scan_start(engine, string(&request.to_string()), &mut error) };
        assert!(!handle.is_null());

        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(60);
        while unsafe { !sift_scan_is_finished(handle) } && std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        let mut events = vec![empty_event(); 32];
        loop {
            let written = unsafe { sift_scan_poll_events(handle, 32, events.as_mut_ptr()) };
            if written == 0 {
                break;
            }
            for event in events.iter_mut().take(written as usize) {
                unsafe { sift_event_free_items(event) };
            }
        }

        let mut groups = [SiftDuplicateGroup {
            version: 0,
            group_id: 0,
            digest: SiftString::EMPTY,
            size_bytes: 0,
            member_count: 0,
            reclaimable_bytes: 0,
        }; 4];
        let written =
            unsafe { sift_scan_page_duplicate_groups(handle, 0, 4, groups.as_mut_ptr(), 4) };
        assert_eq!(written, 1, "the 520 copies form one group");
        assert_eq!(groups[0].member_count, 520);
        let group_id = groups[0].group_id;

        let page_size = 512u32;
        let mut buffer = vec![
            SiftDuplicateMember {
                version: 0,
                path: SiftString::EMPTY,
                size_bytes: 0,
                modified_secs: 0,
                keep: false,
            };
            page_size as usize
        ];
        let mut seen = std::collections::HashSet::new();
        let mut offset = 0u32;
        let mut total = 0usize;
        loop {
            let written = unsafe {
                sift_scan_duplicate_members(
                    handle,
                    group_id,
                    offset,
                    page_size,
                    buffer.as_mut_ptr(),
                    page_size,
                )
            };
            if written == 0 {
                break;
            }
            for member in buffer.iter_mut().take(written as usize) {
                let path = unsafe { as_str(&member.path) }
                    .unwrap_or_default()
                    .to_string();
                assert!(seen.insert(path), "a member appeared on two pages");
                unsafe { sift_duplicate_member_free(member) };
            }
            total += written as usize;
            offset += written;
            if written < page_size {
                break;
            }
        }
        assert_eq!(total, 520, "every member is reachable exactly once");

        unsafe {
            for group in groups.iter_mut() {
                sift_duplicate_group_free(group);
            }
            sift_scan_free(handle);
            sift_engine_free(engine);
            sift_string_free(error.code);
            sift_string_free(error.message);
        }
    }

    #[test]
    fn risk_helpers_match_the_rule_table() {
        for value in ["safe", "review", "protected"] {
            let input = string(value);
            let expected = value != "protected";
            assert_eq!(sift_risk_is_cleanable(input), expected, "risk {value}");
            unsafe { sift_string_free(input) };
        }
        assert!(!sift_risk_is_cleanable(SiftString::EMPTY));

        let risk = sift_default_risk_for_category(string("applicationCache"));
        let text = unsafe { as_str(&risk) }.unwrap().to_string();
        unsafe { sift_string_free(risk) };
        assert_eq!(text, "safe");

        // `logs` holds both safe and review rules; the category default is the
        // more cautious one, or diagnostic reports would be preselected.
        let logs = sift_default_risk_for_category(string("logs"));
        let text = unsafe { as_str(&logs) }.unwrap().to_string();
        unsafe { sift_string_free(logs) };
        assert_eq!(text, "review");

        let unknown = sift_default_risk_for_category(string("nonsense"));
        let text = unsafe { as_str(&unknown) }.unwrap().to_string();
        unsafe { sift_string_free(unknown) };
        assert_eq!(text, "review", "an unknown category is never pre-selected");
    }

    #[test]
    fn storage_analysis_reports_a_volume() {
        let tree = sift_scanner_core::walker::fixtures::TempTree::new("ffi-storage");
        tree.file("Photos/a.jpg", 2 * 1024 * 1024);
        let options = serde_json::json!({
            "homeDir": tree.root.to_string_lossy(),
            "roots": [tree.root.to_string_lossy()],
            "largeFileThresholdBytes": 1024 * 1024,
            "topFileLimit": 10,
            "topDirectoryLimit": 10
        })
        .to_string();

        let analysis = unsafe { sift_storage_analyse(string(&options), std::ptr::null_mut()) };
        assert!(!analysis.is_null());
        unsafe {
            assert!((*analysis).ok, "analysis succeeds");
            assert!((*analysis).total_bytes > 0);
            assert!((*analysis).file_count > 0);
            assert!((*analysis).category_count > 0);
            assert!(!(*analysis).mount_point.ptr.is_null());
            sift_storage_analysis_free(analysis);
        }
    }

    #[test]
    fn storage_analysis_rejects_broken_options() {
        let analysis = unsafe { sift_storage_analyse(string("{bad"), std::ptr::null_mut()) };
        assert!(!analysis.is_null());
        unsafe {
            assert!(!(*analysis).ok);
            assert!(!(*analysis).error.ptr.is_null());
            sift_storage_analysis_free(analysis);
        }
        let null_analysis =
            unsafe { sift_storage_analyse(SiftString::EMPTY, std::ptr::null_mut()) };
        assert!(!null_analysis.is_null());
        unsafe {
            assert!(!(*null_analysis).ok);
            sift_storage_analysis_free(null_analysis);
        }
        unsafe { sift_storage_analysis_free(std::ptr::null_mut()) };
    }

    #[test]
    fn a_cancelled_storage_analysis_stops_early() {
        let tree = sift_scanner_core::walker::fixtures::TempTree::new("ffi-storage-cancel");
        tree.file("a/data.bin", 4096);
        let options = serde_json::json!({
            "homeDir": tree.root.to_string_lossy(),
            "roots": [tree.root.to_string_lossy()]
        })
        .to_string();

        let cancel = sift_storage_cancel_new();
        assert!(!cancel.is_null());
        unsafe {
            sift_storage_cancel(cancel);
            let analysis = sift_storage_analyse(string(&options), cancel);
            assert!(!analysis.is_null());
            assert!((*analysis).ok);
            assert_eq!(
                (*analysis).scanned_file_count,
                0,
                "a pre-cancelled analysis visits nothing"
            );
            sift_storage_analysis_free(analysis);
            sift_storage_cancel_free(cancel);
            sift_storage_cancel_free(std::ptr::null_mut());
        }
    }

    #[test]
    fn cancelling_a_finished_scan_is_harmless() {
        let engine = sift_engine_new();
        unsafe {
            sift_scan_cancel(engine);
            sift_scan_cancel(std::ptr::null_mut());
            sift_engine_free(engine);
        }
    }

    #[test]
    fn skipping_json_for_a_missing_session_returns_empty() {
        let json = unsafe { sift_scan_skipped_json(std::ptr::null_mut()) };
        assert!(json.ptr.is_null());
        unsafe { sift_string_free(json) };
    }

    #[test]
    fn engine_outlives_a_freed_handle() {
        // The engine owns the session; freeing the Swift-side wrapper must not
        // invalidate the engine's own state.
        let engine = sift_engine_new();
        let mut error = result_ok();
        let request = scan_request_json("handle-lifetime", "/tmp");
        let handle = unsafe { sift_scan_start(engine, string(&request), &mut error) };
        assert!(!handle.is_null());
        unsafe {
            sift_scan_free(handle);
            sift_scan_cancel(engine);
            sift_engine_free(engine);
            sift_string_free(error.code);
            sift_string_free(error.message);
        }
    }

    #[test]
    fn a_second_scan_replaces_the_first() {
        let engine = sift_engine_new();
        let mut error = result_ok();
        let first = unsafe {
            sift_scan_start(
                engine,
                string(&scan_request_json("one", "/tmp")),
                &mut error,
            )
        };
        let second = unsafe {
            sift_scan_start(
                engine,
                string(&scan_request_json("two", "/tmp")),
                &mut error,
            )
        };
        assert!(!first.is_null());
        assert!(!second.is_null());
        unsafe {
            sift_scan_free(first);
            sift_scan_free(second);
            sift_engine_free(engine);
            sift_string_free(error.code);
            sift_string_free(error.message);
        }
    }

    #[test]
    fn cstr_len_handles_null() {
        assert_eq!(unsafe { sift_cstr_len(std::ptr::null()) }, 0);
        let text = b"hello\0";
        assert_eq!(unsafe { sift_cstr_len(text.as_ptr() as *const c_char) }, 5);
    }
}
