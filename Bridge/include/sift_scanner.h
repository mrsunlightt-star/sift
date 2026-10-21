/*
 * Sift scanner C ABI.
 *
 * Generated contract for the Rust core. The structure layouts, field order and
 * versioning rules in this header are verified against the Rust definitions by
 * `RustCore/crates/sift-ffi/tests/ffi_contract.rs`, which parses this file.
 *
 * Rules for callers:
 *
 *  1. Read `sift_ffi_version()` on load and refuse to run if it does not match
 *     the value the caller was compiled against.
 *  2. Every `SiftString` returned by this library is owned by the caller and
 *     must be released with `sift_string_free`.
 *  3. Every array embedded in an event, page or analysis is released by the
 *     matching `sift_*_free` function.
 *  4. No function in this library deletes, moves or trashes a file. The caller
 *     performs every destructive action, after re-validating each path.
 */
#ifndef SIFT_SCANNER_H
#define SIFT_SCANNER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Contract version. Bump only together with the Rust constant. */
#define SIFT_FFI_VERSION 1

/* ------------------------------------------------------------------------- */
/* Values                                                                    */
/* ------------------------------------------------------------------------- */

/* A UTF-8 buffer. `len` is a byte count, not a character count. */
typedef struct SiftString {
  uint8_t *ptr;
  size_t len;
} SiftString;

/* Event discriminators for `SiftScanEvent.kind`. */
typedef enum SiftEventKind {
  SIFT_EVENT_PHASE = 0,
  SIFT_EVENT_PROGRESS = 1,
  SIFT_EVENT_ITEMS = 2,
  SIFT_EVENT_DUPLICATE_GROUP = 3,
  SIFT_EVENT_SKIPPED = 4,
  SIFT_EVENT_COMPLETED = 5,
  SIFT_EVENT_FAILED = 6
} SiftEventKind;

/* Scan phase codes for `SiftScanEvent.phase` and progress payloads. */
typedef enum SiftPhase {
  SIFT_PHASE_IDLE = 0,
  SIFT_PHASE_PREPARING = 1,
  SIFT_PHASE_SCANNING = 2,
  SIFT_PHASE_INDEXING = 3,
  SIFT_PHASE_READY = 4,
  SIFT_PHASE_CANCELLED = 5,
  SIFT_PHASE_PARTIAL = 6,
  SIFT_PHASE_FAILED = 7
} SiftPhase;

/* Result of `sift_path_protection`. `UNKNOWN` must be treated as protected. */
typedef enum SiftPathProtection {
  SIFT_PATH_UNKNOWN = -1,
  SIFT_PATH_SCANNABLE = 0,
  SIFT_PATH_USER_CONTENT = 1,
  SIFT_PATH_SYSTEM = 2,
  SIFT_PATH_SECRETS = 3
} SiftPathProtection;

/* One cleanup item summary. */
typedef struct SiftItemSummary {
  uint32_t version;
  SiftString path;
  SiftString display_name;
  SiftString parent_path;
  SiftString category;
  SiftString risk;
  SiftString explanation_key;
  SiftString rule_id;
  SiftString bundle_id;
  int64_t size_bytes;
  int64_t file_count;
  int64_t modified_secs;
  bool is_directory;
} SiftItemSummary;

/* One event. See `kind` for which payload fields are meaningful. */
typedef struct SiftScanEvent {
  uint32_t version;
  int32_t kind;
  int32_t phase;
  int64_t files_seen;
  int64_t bytes_seen;
  int64_t items_found;
  int64_t group_index;
  int64_t member_count;
  int64_t reclaimable_bytes;
  int64_t byte_count;
  int32_t flag;
  SiftString text;
  SiftString detail;
  SiftItemSummary *items;
  size_t item_count;
} SiftScanEvent;

/* A page of scan results. */
typedef struct SiftPage {
  uint32_t version;
  SiftItemSummary *items;
  size_t item_count;
  int64_t remaining;
} SiftPage;

/* A category rollup row. */
typedef struct SiftCategoryTotal {
  uint32_t version;
  SiftString category;
  int64_t item_count;
  int64_t total_bytes;
} SiftCategoryTotal;

/* A duplicate group row. */
typedef struct SiftDuplicateGroup {
  uint32_t version;
  int64_t group_id;
  SiftString digest;
  int64_t size_bytes;
  int64_t member_count;
  int64_t reclaimable_bytes;
} SiftDuplicateGroup;

/* One member of a duplicate group. */
typedef struct SiftDuplicateMember {
  uint32_t version;
  SiftString path;
  int64_t size_bytes;
  int64_t modified_secs;
  bool keep;
} SiftDuplicateMember;

/* Outcome of an operation that can fail. */
typedef struct SiftResult {
  uint32_t version;
  bool ok;
  SiftString code;
  SiftString message;
} SiftResult;

/* A large file row. */
typedef struct SiftStorageFile {
  uint32_t version;
  SiftString path;
  SiftString display_name;
  SiftString parent_path;
  uint64_t size_bytes;
  int64_t modified_secs;
} SiftStorageFile;

/* A directory rollup row. */
typedef struct SiftStorageDirectory {
  uint32_t version;
  SiftString path;
  SiftString display_name;
  uint64_t size_bytes;
  uint64_t file_count;
} SiftStorageDirectory;

/* Storage analysis outcome. */
typedef struct SiftStorageAnalysis {
  uint32_t version;
  bool ok;
  SiftString mount_point;
  SiftString volume_name;
  uint64_t total_bytes;
  uint64_t free_bytes;
  uint64_t used_bytes;
  double used_fraction;
  uint64_t scanned_file_count;
  uint64_t scanned_byte_count;
  uint64_t skipped_count;
  int64_t elapsed_millis;
  bool aggregated;
  SiftCategoryTotal *categories;
  size_t category_count;
  SiftStorageFile *files;
  size_t file_count;
  SiftStorageDirectory *directories;
  size_t directory_count;
  SiftString error;
} SiftStorageAnalysis;

/* Opaque handles. */
typedef struct SiftEngine SiftEngine;
typedef struct SiftScanHandle SiftScanHandle;

/* ------------------------------------------------------------------------- */
/* Functions                                                                 */
/* ------------------------------------------------------------------------- */

/* Returns the FFI contract version. Call this once and compare it against the
 * value the caller was built with. */
uint32_t sift_ffi_version(void);

/* Releases a string returned by this library. Null pointers are ignored. */
void sift_string_free(SiftString value);

/* Returns the built-in rule table as a JSON array. Caller frees. */
SiftString sift_rules_json(void);

/* Classifies a path against the compiled-in protection list.
 * Returns a `SiftPathProtection` value. */
int32_t sift_path_protection(SiftString home_dir, SiftString path);

/* Returns true when a risk level may enter the deletion queue. */
bool sift_risk_is_cleanable(SiftString risk);

/* Returns the most cautious risk level the library assigns to a category.
 * Caller frees. */
SiftString sift_default_risk_for_category(SiftString category);

/* Creates an engine. Free with `sift_engine_free`. */
SiftEngine *sift_engine_new(void);

/* Frees an engine and every handle it handed out. */
void sift_engine_free(SiftEngine *engine);

/* Starts a scan from a JSON `ScanRequest`. On failure returns NULL and writes
 * `error`; on success writes `error.ok = true`. */
SiftScanHandle *sift_scan_start(SiftEngine *engine, SiftString request_json,
                               SiftResult *error);

/* Cancels the active scan. Safe from any thread, in any state. */
void sift_scan_cancel(SiftEngine *engine);

/* True once the scan has stopped producing results. */
bool sift_scan_is_finished(SiftScanHandle *handle);

/* Drains up to `max_events` events into `out`, returning the count written.
 * Each written event must be released with `sift_event_free_items`. */
uint32_t sift_scan_poll_events(SiftScanHandle *handle, uint32_t max_events,
                              SiftScanEvent *out);

/* Releases the arrays and strings inside one event. */
void sift_event_free_items(SiftScanEvent *event);

/* Reads one page of results. `sort` is "size", "name", "modified" or
 * "category"; an empty `category` pages every category. On success `out` must
 * be released with `sift_page_free`. */
bool sift_scan_page_results(SiftScanHandle *handle, uint32_t offset,
                           uint32_t limit, SiftString sort, SiftString category,
                           SiftPage *out, SiftResult *error);

/* Releases a page and every string it owns. */
void sift_page_free(SiftPage *page);

/* Reads one page of duplicate groups, largest reclaimable first. */
uint32_t sift_scan_page_duplicate_groups(SiftScanHandle *handle, uint32_t offset,
                                        uint32_t limit, SiftDuplicateGroup *out,
                                        uint32_t max_groups);

/* Reads one page of the members of a duplicate group.
 *
 * `offset` and `limit` page the group; a group can hold thousands of copies.
 * Callers must advance `offset` by the number returned until it is smaller than
 * `limit`. */
uint32_t sift_scan_duplicate_members(SiftScanHandle *handle, int64_t group_id,
                                     uint32_t offset, uint32_t limit,
                                     SiftDuplicateMember *out,
                                     uint32_t max_members);

/* Releases a duplicate group row. */
void sift_duplicate_group_free(SiftDuplicateGroup *group);

/* Releases a duplicate member row. */
void sift_duplicate_member_free(SiftDuplicateMember *member);

/* Frees a scan handle wrapper. The engine keeps the session alive. */
void sift_scan_free(SiftScanHandle *handle);

/* Skipped locations for the active session, as a JSON array. Caller frees. */
SiftString sift_scan_skipped_json(SiftScanHandle *handle);

/* Opaque cancellation token for a storage analysis. */
typedef struct SiftStorageCancel SiftStorageCancel;

/* Creates a storage cancellation token. Free it with
 * `sift_storage_cancel_free`. */
SiftStorageCancel *sift_storage_cancel_new(void);

/* Requests cancellation. Safe from any thread. */
void sift_storage_cancel(SiftStorageCancel *cancel);

/* Frees a storage cancellation token. */
void sift_storage_cancel_free(SiftStorageCancel *cancel);

/* Runs a storage analysis from a JSON options object. `cancel` may be NULL.
 * Free the result with `sift_storage_analysis_free`. */
SiftStorageAnalysis *sift_storage_analyse(SiftString options_json,
                                          SiftStorageCancel *cancel);

/* Frees a storage analysis and every array it owns. */
void sift_storage_analysis_free(SiftStorageAnalysis *analysis);

/* Byte length of a NUL-terminated C string, or 0 for NULL. */
size_t sift_cstr_len(const char *value);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* SIFT_SCANNER_H */
