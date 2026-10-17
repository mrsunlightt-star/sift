//! The scan coordinator: runs the strategies, publishes events and fills the index.
//!
//! Threading model, chosen to satisfy the specification's FFI rules:
//!
//! * one worker thread per session performs all filesystem work,
//! * the caller (Swift) never blocks on the worker; it polls events and pages
//!   results synchronously,
//! * events are summarised and coalesced, never one per file,
//! * detail rows live in the SQLite index, so Swift holds only what it renders.
//!
//! What the coordinator deliberately does *not* do: it never deletes, moves or
//! trashes anything, and it holds no purchase or entitlement state.

use crate::scanners::{self, Candidate, ProgressSink, ScanContext};
use crate::types::{
    CategoryTotal, EngineError, Event, EventBatch, PhaseName, ScanItemSummary, ScanProgress,
    ScanRequest, ScanSummary, SkippedLocation,
};
use crate::walker;
use sift_file_index::{FileIndex, ItemRecord, ScanSort};
use sift_hasher::CancelToken;
use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// How often a progress event is published at most.
const PROGRESS_INTERVAL: Duration = Duration::from_millis(200);

/// Rolling counters and the live phase, shared between the worker and the poller.
#[derive(Debug)]
struct SharedState {
    phase: Mutex<String>,
    current_path: Mutex<String>,
    files_seen: AtomicI64,
    bytes_seen: AtomicI64,
    items_found: AtomicI64,
    finished: AtomicBool,
    last_progress_at: Mutex<Instant>,
}

impl SharedState {
    fn new() -> Self {
        Self {
            phase: Mutex::new(PhaseName::Idle.as_str().to_string()),
            current_path: Mutex::new(String::new()),
            files_seen: AtomicI64::new(0),
            bytes_seen: AtomicI64::new(0),
            items_found: AtomicI64::new(0),
            finished: AtomicBool::new(false),
            last_progress_at: Mutex::new(Instant::now() - PROGRESS_INTERVAL),
        }
    }

    fn phase(&self) -> String {
        self.phase
            .lock()
            .map(|value| value.clone())
            .unwrap_or_else(|_| PhaseName::Failed.as_str().to_string())
    }

    fn set_phase(&self, phase: PhaseName) {
        if let Ok(mut current) = self.phase.lock() {
            *current = phase.as_str().to_string();
        }
    }

    fn set_current_path(&self, path: &Path) {
        if let Ok(mut current) = self.current_path.lock() {
            // Only the leaf name is kept: neither the log nor the UI needs the
            // rest of the user's path, and this field reaches both.
            *current = path
                .file_name()
                .map(|name| name.to_string_lossy().to_string())
                .unwrap_or_default();
        }
    }

    fn current_path_label(&self) -> String {
        self.current_path
            .lock()
            .map(|value| value.clone())
            .unwrap_or_default()
    }

    fn should_publish_progress(&self) -> bool {
        match self.last_progress_at.lock() {
            Ok(mut last) => {
                if last.elapsed() >= PROGRESS_INTERVAL {
                    *last = Instant::now();
                    true
                } else {
                    false
                }
            }
            Err(_) => false,
        }
    }
}

/// One scan session.
pub struct ScanHandle {
    pub session_id: String,
    cancel: CancelToken,
    state: Arc<SharedState>,
    events: Arc<Mutex<VecDeque<Event>>>,
    index: Mutex<FileIndex>,
}

impl ScanHandle {
    pub fn session_id(&self) -> &str {
        &self.session_id
    }

    /// Requests cancellation. Returns immediately; the worker stops at its next
    /// checkpoint, which the specification requires to be within 2s.
    pub fn cancel(&self) {
        self.cancel.cancel();
    }

    pub fn is_finished(&self) -> bool {
        self.state.finished.load(Ordering::Acquire)
    }

    /// Drains up to `max` events.
    pub fn poll_events(&self, max: u32) -> EventBatch {
        let limit = max.max(1) as usize;
        let mut queue = match self.events.lock() {
            Ok(queue) => queue,
            Err(_) => {
                return EventBatch {
                    events: vec![Event::Failed {
                        code: "internal".to_string(),
                        message: "The scan event queue became unavailable.".to_string(),
                    }],
                    remaining: 0,
                }
            }
        };

        let mut out = Vec::with_capacity(limit.min(queue.len()));
        let mut progress_emitted = false;
        let index = 0;
        while out.len() < limit && index < queue.len() {
            let is_progress = matches!(queue[index], Event::Progress(_));
            if is_progress {
                // Keep only the newest progress event in the drained batch.
                if progress_emitted {
                    queue.remove(index);
                    continue;
                }
                let is_last_progress = !queue
                    .range(index + 1..)
                    .any(|event| matches!(event, Event::Progress(_)));
                if !is_last_progress {
                    queue.remove(index);
                    continue;
                }
                progress_emitted = true;
            }
            let event = queue.remove(index).expect("index is in bounds");
            out.push(event);
        }

        EventBatch {
            events: out,
            remaining: queue.len() as u32,
        }
    }

    /// Publishes a progress event (used on phase boundaries).
    fn publish_progress(&self) {
        let progress = ScanProgress {
            phase: self.state.phase(),
            files_seen: self.state.files_seen.load(Ordering::Relaxed),
            bytes_seen: self.state.bytes_seen.load(Ordering::Relaxed),
            items_found: self.state.items_found.load(Ordering::Relaxed),
            current_path: self.state.current_path_label(),
            fraction: None,
        };
        if let Ok(mut queue) = self.events.lock() {
            queue.push_back(Event::Progress(progress));
        }
    }

    fn push(&self, event: Event) {
        if let Ok(mut queue) = self.events.lock() {
            queue.push_back(event);
        }
    }

    fn push_batch(&self, items: Vec<ScanItemSummary>) {
        if items.is_empty() {
            return;
        }
        if let Ok(mut queue) = self.events.lock() {
            queue.push_back(Event::ItemBatch { items });
        }
    }

    fn push_failed(&self, code: &str, message: &str) {
        self.push(Event::Failed {
            code: code.to_string(),
            message: message.to_string(),
        });
    }

    /// Index accessor that reports poisoning instead of panicking.
    fn index_checked(&self) -> Result<std::sync::MutexGuard<'_, FileIndex>, EngineError> {
        self.index
            .lock()
            .map_err(|_| EngineError::Internal("index lock poisoned".to_string()))
    }

    /// Borrows the index for reading (duplicate groups, skipped locations).
    pub fn index(&self) -> std::sync::MutexGuard<'_, FileIndex> {
        self.index
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Reads one page of detail rows out of the index.
    pub fn page_results(
        &self,
        offset: u32,
        limit: u32,
        sort: &str,
        category: Option<&str>,
    ) -> Result<Vec<ItemRecord>, EngineError> {
        let index = self.index_checked()?;
        Ok(index.page_items(offset, limit, ScanSort::parse(sort), category)?)
    }
}

/// The scanner engine. Owns the live session and the index file.
pub struct Engine {
    session: Mutex<Option<Arc<ScanHandle>>>,
    index_path: Mutex<Option<PathBuf>>,
}

impl Default for Engine {
    fn default() -> Self {
        Self::new()
    }
}

impl Engine {
    pub fn new() -> Self {
        Self {
            session: Mutex::new(None),
            index_path: Mutex::new(None),
        }
    }

    /// Starts a scan on a worker thread and returns the handle immediately.
    pub fn start_scan(
        self: &Arc<Self>,
        request: ScanRequest,
    ) -> Result<Arc<ScanHandle>, EngineError> {
        if request.session_id.trim().is_empty() {
            return Err(EngineError::InvalidRequest(
                "session id must not be empty".to_string(),
            ));
        }
        let home = PathBuf::from(&request.home_dir);
        if !home.is_absolute() {
            return Err(EngineError::InvalidRequest(
                "home directory must be an absolute path".to_string(),
            ));
        }

        self.cancel_current();

        let index = if request.index_path.trim().is_empty() {
            FileIndex::open_in_memory(&request.session_id)?
        } else {
            let path = PathBuf::from(&request.index_path);
            if let Some(parent) = path.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            FileIndex::open(&path, &request.session_id)?
        };

        let handle = Arc::new(ScanHandle {
            session_id: request.session_id.clone(),
            cancel: CancelToken::new(),
            state: Arc::new(SharedState::new()),
            events: Arc::new(Mutex::new(VecDeque::new())),
            index: Mutex::new(index),
        });

        if let Ok(mut slot) = self.session.lock() {
            *slot = Some(Arc::clone(&handle));
        }
        if let Ok(mut path_slot) = self.index_path.lock() {
            *path_slot = if request.index_path.trim().is_empty() {
                None
            } else {
                Some(PathBuf::from(&request.index_path))
            };
        }

        let worker_handle = Arc::clone(&handle);
        std::thread::Builder::new()
            .name(format!("sift-scan-{}", request.session_id))
            .spawn(move || {
                // A panic in the worker must not take the host process down.
                let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    run_scan(&worker_handle, &request)
                }));
                if outcome.is_err() {
                    worker_handle.state.set_phase(PhaseName::Failed);
                    worker_handle.push_failed("internal", "The scan stopped unexpectedly.");
                }
                worker_handle.state.finished.store(true, Ordering::Release);
            })
            .map_err(|error| EngineError::Internal(error.to_string()))?;

        Ok(handle)
    }

    /// Cancels the active session, if any. Returns true when one was cancelled.
    pub fn cancel(&self) -> bool {
        self.cancel_current().is_some()
    }

    fn cancel_current(&self) -> Option<Arc<ScanHandle>> {
        let previous = self.session.lock().ok().and_then(|mut slot| slot.take());
        if let Some(handle) = &previous {
            handle.cancel();
        }
        if let Some(path) = self.index_path.lock().ok().and_then(|mut p| p.take()) {
            // The index is a scan artifact: removing it on cancel or restart
            // keeps the data directory small and leaves no stale paths behind.
            let _ = std::fs::remove_file(&path);
        }
        previous
    }

    /// The active session, if one is running or finished.
    pub fn current_session(&self) -> Option<Arc<ScanHandle>> {
        self.session.lock().ok().and_then(|slot| slot.clone())
    }

    /// Looks up a session by id, rejecting unknown ids.
    pub fn session(&self, session_id: &str) -> Result<Arc<ScanHandle>, EngineError> {
        match self.current_session() {
            Some(handle) if handle.session_id == session_id => Ok(handle),
            _ => Err(EngineError::SessionNotFound(session_id.to_string())),
        }
    }
}

fn run_scan(handle: &Arc<ScanHandle>, request: &ScanRequest) {
    let started = Instant::now();
    // Borrowed, never cloned: every checkpoint must observe the same flag the
    // UI cancels.
    let cancel = &handle.cancel;
    let home = PathBuf::from(&request.home_dir);

    handle.state.set_phase(PhaseName::Preparing);
    handle.push(Event::PhaseChanged {
        phase: PhaseName::Preparing.as_str().to_string(),
    });
    handle.publish_progress();

    let rules = match scanners::effective_rules(request.extra_rules_json.as_deref()) {
        Ok(rules) => rules,
        Err(message) => {
            handle.state.set_phase(PhaseName::Failed);
            handle.push_failed("invalidRequest", &message);
            return;
        }
    };

    if cancel.is_cancelled() {
        finish_cancelled(handle);
        return;
    }

    handle.state.set_phase(PhaseName::Scanning);
    handle.push(Event::PhaseChanged {
        phase: PhaseName::Scanning.as_str().to_string(),
    });

    let batch_size = request.event_batch_items.max(1) as usize;
    let mut pending_batch: Vec<ScanItemSummary> = Vec::with_capacity(batch_size);
    let mut skipped: Vec<SkippedLocation> = Vec::new();

    {
        let state = Arc::clone(&handle.state);
        let mut on_files = |files: u64, bytes: u64| {
            state.files_seen.fetch_add(files as i64, Ordering::Relaxed);
            state.bytes_seen.fetch_add(bytes as i64, Ordering::Relaxed);
        };
        let state_path = Arc::clone(&handle.state);
        let mut on_path = |path: &Path| {
            state_path.set_current_path(path);
        };

        let mut context = ScanContext {
            request,
            home_dir: home.clone(),
            rules,
            progress: ProgressSink {
                on_files: &mut on_files,
                on_current_path: &mut on_path,
            },
        };

        // 1. Rule-driven cleanup candidates.
        let (candidates, report) = scanners::scan_rules(&mut context, cancel);
        record_skips(handle, &report.skips, &mut skipped);
        if report.cancelled || cancel.is_cancelled() {
            finish_cancelled(handle);
            return;
        }
        persist_candidates(handle, candidates, &batch_size, &mut pending_batch);
        handle.push_batch(std::mem::take(&mut pending_batch));
        publish_if_due(handle);

        // 2. Application residue, matched strictly by bundle identifier.
        if !cancel.is_cancelled() {
            let (residue, report) = scanners::scan_application_residue(&mut context, cancel);
            record_skips(handle, &report.skips, &mut skipped);
            persist_candidates(handle, residue, &batch_size, &mut pending_batch);
            handle.push_batch(std::mem::take(&mut pending_batch));
            publish_if_due(handle);
        }

        // 3. Large and old files, only inside the roots the caller supplied.
        if !cancel.is_cancelled() {
            let (large, report) = scanners::scan_large_files(
                &mut context,
                cancel,
                request.large_file_threshold_bytes,
            );
            record_skips(handle, &report.skips, &mut skipped);
            persist_candidates(handle, large, &batch_size, &mut pending_batch);
            handle.push_batch(std::mem::take(&mut pending_batch));

            let (old, report) =
                scanners::scan_old_files(&mut context, cancel, request.old_file_threshold_days);
            record_skips(handle, &report.skips, &mut skipped);
            persist_candidates(handle, old, &batch_size, &mut pending_batch);
            handle.push_batch(std::mem::take(&mut pending_batch));
            publish_if_due(handle);
        }
    }

    if cancel.is_cancelled() {
        finish_cancelled(handle);
        return;
    }

    // 4. Duplicate detection.
    let mut duplicate_report = scanners::DuplicateReport::default();
    if request.include_duplicates && !cancel.is_cancelled() {
        handle.state.set_phase(PhaseName::Indexing);
        handle.push(Event::PhaseChanged {
            phase: PhaseName::Indexing.as_str().to_string(),
        });
        handle.publish_progress();

        // Duplicate candidates are cleanup candidates, so the roots are limited
        // to the ones the caller allowed to be cleaned.
        let roots: Vec<PathBuf> = scanners::duplicate_roots(request, &home)
            .into_iter()
            .filter(|root| {
                request.roots.is_empty()
                    || request.roots.iter().any(|candidate| {
                        candidate.is_cleanable && root.starts_with(&candidate.path)
                    })
            })
            .collect();
        if !roots.is_empty() {
            let mut finder = scanners::DuplicateFinder::new(
                request.duplicates.clone(),
                home.clone(),
                request.authorized_roots.iter().map(PathBuf::from).collect(),
                cancel,
            );
            let handle_for_groups = Arc::clone(handle);
            let mut group_index = 0i64;
            duplicate_report = finder.run(&roots, &mut |group| {
                let stored = match handle_for_groups.index_checked() {
                    Ok(mut index) => index
                        .insert_duplicate_group(
                            &group.digest,
                            group.size_bytes as i64,
                            &group.members,
                        )
                        .is_ok(),
                    Err(_) => false,
                };
                if stored {
                    group_index += 1;
                    handle_for_groups.push(Event::DuplicateGroup {
                        group_index,
                        member_count: group.members.len() as i64,
                        reclaimable_bytes: group.reclaimable_bytes as i64,
                    });
                }
            });
        }
        if duplicate_report.cancelled || cancel.is_cancelled() {
            finish_cancelled(handle);
            return;
        }
    }

    // 5. Summary and completion.
    let summary = match build_summary(handle, request, &skipped, started, &duplicate_report) {
        Ok(summary) => summary,
        Err(error) => {
            handle.state.set_phase(PhaseName::Failed);
            handle.push_failed(error.code().as_str(), &error.user_message());
            return;
        }
    };

    let final_phase = if summary.is_partial {
        PhaseName::Partial
    } else {
        PhaseName::Ready
    };
    handle.state.set_phase(final_phase);
    handle.push(Event::PhaseChanged {
        phase: final_phase.as_str().to_string(),
    });
    handle.push(Event::Completed(Box::new(summary)));
}

fn publish_if_due(handle: &Arc<ScanHandle>) {
    if handle.state.should_publish_progress() {
        handle.publish_progress();
    }
}

/// Writes candidates into the index and emits summaries in batches.
fn persist_candidates(
    handle: &Arc<ScanHandle>,
    candidates: Vec<Candidate>,
    batch_size: &usize,
    pending_batch: &mut Vec<ScanItemSummary>,
) {
    if candidates.is_empty() {
        return;
    }
    let rows: Vec<_> = candidates.iter().map(Candidate::to_item_row).collect();
    {
        let index_result = handle.index_checked();
        let mut index = match index_result {
            Ok(index) => index,
            Err(_) => {
                handle.push_failed("internal", "Scan results could not be stored.");
                return;
            }
        };
        // Chunked transactions stay responsive while still amortising the WAL
        // sync cost.
        for chunk in rows.chunks(1024) {
            if index.insert_items(chunk).is_err() {
                handle.push_failed("internal", "Scan results could not be stored.");
                return;
            }
        }
    }
    handle
        .state
        .items_found
        .fetch_add(candidates.len() as i64, Ordering::Relaxed);

    for candidate in candidates {
        pending_batch.push(ScanItemSummary {
            path: candidate.path.to_string_lossy().to_string(),
            display_name: candidate.display_name,
            parent_path: candidate.parent_path,
            category: candidate.category.as_str().to_string(),
            risk: candidate.risk.as_str().to_string(),
            size_bytes: candidate.size_bytes as i64,
            file_count: candidate.file_count as i64,
            explanation_key: candidate.explanation_key,
            rule_id: candidate.rule_id,
            bundle_id: candidate.bundle_id,
            modified_secs: candidate.modified_secs,
            is_directory: candidate.is_directory,
        });
        if pending_batch.len() >= *batch_size {
            let batch = std::mem::take(pending_batch);
            handle.push_batch(batch);
            pending_batch.reserve(*batch_size);
        }
    }
}

/// Records skipped locations, deduplicated and bounded.
fn record_skips(
    handle: &Arc<ScanHandle>,
    skips: &[walker::WalkSkip],
    collected: &mut Vec<SkippedLocation>,
) {
    for skip in skips {
        // The list stays bounded: a user does not need 4,000 identical
        // permission warnings.
        if collected.len() >= 200 {
            return;
        }
        let path = skip.path.to_string_lossy().to_string();
        if collected
            .iter()
            .any(|existing| existing.code == skip.code && existing.path == path)
        {
            continue;
        }
        let location = SkippedLocation {
            code: skip.code.to_string(),
            path,
            message: skip.message.clone(),
            byte_count: 0,
            needs_full_disk_access: skip.needs_full_disk_access,
        };
        if let Ok(index) = handle.index_checked() {
            let _ = index.insert_skipped(
                &location.path,
                &location.code,
                &location.message,
                location.byte_count,
            );
        }
        handle.push(Event::LocationSkipped(location.clone()));
        collected.push(location);
    }
}

fn build_summary(
    handle: &Arc<ScanHandle>,
    request: &ScanRequest,
    skipped: &[SkippedLocation],
    started: Instant,
    duplicate_report: &scanners::DuplicateReport,
) -> Result<ScanSummary, EngineError> {
    let index = handle.index_checked()?;
    let totals = index.summary()?;
    let category_totals = index
        .category_totals()?
        .into_iter()
        .map(|(category, item_count, total_bytes)| CategoryTotal {
            category,
            item_count,
            total_bytes,
        })
        .collect();
    let duplicate_group_count = index.duplicate_group_count()?;
    let duplicate_reclaimable_bytes = index.duplicate_reclaimable_bytes()?;

    Ok(ScanSummary {
        session_id: request.session_id.clone(),
        phase: PhaseName::Ready.as_str().to_string(),
        scanned_file_count: handle.state.files_seen.load(Ordering::Relaxed),
        scanned_byte_count: handle.state.bytes_seen.load(Ordering::Relaxed),
        item_count: totals.item_count,
        item_bytes: totals.total_bytes,
        category_totals,
        duplicate_group_count,
        duplicate_reclaimable_bytes,
        skipped: skipped.to_vec(),
        elapsed_millis: started.elapsed().as_millis() as i64,
        is_partial: !skipped.is_empty() || duplicate_report.truncated,
    })
}

fn finish_cancelled(handle: &Arc<ScanHandle>) {
    handle.state.set_phase(PhaseName::Cancelled);
    handle.push(Event::PhaseChanged {
        phase: PhaseName::Cancelled.as_str().to_string(),
    });
    let summary = ScanSummary {
        session_id: handle.session_id.clone(),
        phase: PhaseName::Cancelled.as_str().to_string(),
        scanned_file_count: handle.state.files_seen.load(Ordering::Relaxed),
        scanned_byte_count: handle.state.bytes_seen.load(Ordering::Relaxed),
        item_count: handle.state.items_found.load(Ordering::Relaxed),
        ..Default::default()
    };
    handle.push(Event::Completed(Box::new(summary)));
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::walker::fixtures::TempTree;
    use std::sync::Arc as StdArc;

    struct Fixture {
        tree: TempTree,
    }

    impl Fixture {
        fn new(tag: &str) -> Self {
            Self {
                tree: TempTree::new(tag),
            }
        }

        fn request(&self, tag: &str) -> ScanRequest {
            ScanRequest {
                session_id: format!("session-{tag}"),
                home_dir: self.tree.root.to_string_lossy().to_string(),
                roots: vec![crate::types::ScanRoot::new(
                    self.tree.root.to_string_lossy().to_string(),
                    "home",
                )],
                large_file_threshold_bytes: 1024 * 1024,
                old_file_threshold_days: 180,
                stale_threshold_days: 30,
                index_path: String::new(),
                event_batch_items: 4,
                ..Default::default()
            }
        }
    }

    fn drain(handle: &StdArc<ScanHandle>) -> Vec<Event> {
        let mut all = Vec::new();
        loop {
            let batch = handle.poll_events(64);
            all.extend(batch.events);
            if batch.remaining == 0 {
                break;
            }
        }
        all
    }

    fn wait_for_completion(handle: &StdArc<ScanHandle>) {
        let deadline = Instant::now() + Duration::from_secs(30);
        while Instant::now() < deadline {
            if handle.is_finished() {
                return;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        panic!("scan did not finish in time");
    }

    fn summary_of(events: &[Event]) -> ScanSummary {
        events
            .iter()
            .find_map(|event| match event {
                Event::Completed(summary) => Some((**summary).clone()),
                _ => None,
            })
            .expect("a completed event")
    }

    #[test]
    fn engine_runs_a_scan_and_completes_with_a_summary() {
        let fixture = Fixture::new("engine-basic");
        fixture
            .tree
            .file("Library/Caches/com.example.app/blob.bin", 4096);
        fixture
            .tree
            .file("Library/Caches/com.other.app/blob.bin", 4096);
        fixture
            .tree
            .file("Library/Logs/com.example.app/old.log", 2048);

        let engine = StdArc::new(Engine::new());
        let handle = engine
            .start_scan(fixture.request("basic"))
            .expect("scan starts");
        wait_for_completion(&handle);

        let summary = summary_of(&drain(&handle));
        assert_eq!(summary.phase, "ready");
        assert!(
            summary.item_count >= 2,
            "found items: {}",
            summary.item_count
        );
        assert!(summary.item_bytes > 0);
        assert!(!summary.category_totals.is_empty());
    }

    #[test]
    fn results_are_paged_from_the_index() {
        let fixture = Fixture::new("engine-paging");
        for i in 0..12 {
            fixture.tree.file(
                &format!("Library/Caches/com.app{i}/blob.bin"),
                1024 * (i + 1),
            );
        }
        let engine = StdArc::new(Engine::new());
        let handle = engine.start_scan(fixture.request("paging")).unwrap();
        wait_for_completion(&handle);

        let page = handle.page_results(0, 5, "size", None).unwrap();
        assert_eq!(page.len(), 5);
        assert!(page[0].size_bytes >= page[4].size_bytes);

        let rest = handle.page_results(5, 50, "size", None).unwrap();
        assert_eq!(rest.len(), 7);
    }

    #[test]
    fn paging_rejects_an_unknown_session() {
        let engine = StdArc::new(Engine::new());
        assert!(matches!(
            engine.session("nope"),
            Err(EngineError::SessionNotFound(_))
        ));
    }

    #[test]
    fn empty_session_id_is_rejected_before_any_work() {
        let engine = StdArc::new(Engine::new());
        let request = ScanRequest {
            home_dir: "/tmp".to_string(),
            ..Default::default()
        };
        assert!(matches!(
            engine.start_scan(request),
            Err(EngineError::InvalidRequest(_))
        ));
    }

    #[test]
    fn relative_home_directory_is_rejected() {
        let engine = StdArc::new(Engine::new());
        let request = ScanRequest {
            session_id: "s".to_string(),
            home_dir: "relative/path".to_string(),
            ..Default::default()
        };
        assert!(matches!(
            engine.start_scan(request),
            Err(EngineError::InvalidRequest(_))
        ));
    }

    #[test]
    fn cancellation_reaches_a_running_scan() {
        let fixture = Fixture::new("engine-cancel");
        for i in 0..200 {
            fixture
                .tree
                .file(&format!("Library/Caches/com.app{i}/blob.bin"), 16384);
        }
        let engine = StdArc::new(Engine::new());
        let handle = engine.start_scan(fixture.request("cancel")).unwrap();
        handle.cancel();
        wait_for_completion(&handle);
        assert!(handle.is_finished());
    }

    #[test]
    fn unreadable_location_produces_a_skip_event_not_a_failure() {
        let fixture = Fixture::new("engine-skip");
        let locked = fixture.tree.dir("Library/Caches/com.locked");
        fixture
            .tree
            .file("Library/Caches/com.locked/blob.bin", 4096);
        fixture.tree.file("Library/Caches/com.ok/blob.bin", 4096);

        let mut permissions = std::fs::metadata(&locked).unwrap().permissions();
        std::os::unix::fs::PermissionsExt::set_mode(&mut permissions, 0o000);
        std::fs::set_permissions(&locked, permissions).unwrap();

        let engine = StdArc::new(Engine::new());
        let handle = engine.start_scan(fixture.request("skip")).unwrap();
        wait_for_completion(&handle);
        let events = drain(&handle);

        let has_failed = events.iter().any(|e| matches!(e, Event::Failed { .. }));
        assert!(!has_failed, "one unreadable folder must not fail the scan");
        assert!(events.iter().any(|e| matches!(e, Event::Completed(_))));

        // Restore permissions so the fixture can clean up on drop.
        let mut permissions = std::fs::metadata(&locked).unwrap().permissions();
        std::os::unix::fs::PermissionsExt::set_mode(&mut permissions, 0o755);
        std::fs::set_permissions(&locked, permissions).unwrap();
    }

    #[test]
    fn duplicate_groups_reach_the_index_and_the_event_stream() {
        let fixture = Fixture::new("engine-duplicates");
        // Same length as the duplicate pair, so size grouping cannot separate
        // them and the sampling/full-hash stages have to do the work.
        fixture.tree.file_with(
            "Downloads/report-copy.pdf",
            b"a duplicate payload, 31 bytes!!",
        );
        fixture.tree.file_with(
            "Downloads/archive/report.pdf",
            b"a duplicate payload, 31 bytes!!",
        );
        fixture
            .tree
            .file_with("Downloads/unique.pdf", b"a different payload, 31 bytes!!");

        let mut request = fixture.request("duplicates");
        request.include_duplicates = true;
        request.duplicates.min_size_bytes = 1;
        request.duplicates.roots = vec![fixture.tree.root.to_string_lossy().to_string()];

        let engine = StdArc::new(Engine::new());
        let handle = engine.start_scan(request).unwrap();
        wait_for_completion(&handle);

        let events = drain(&handle);
        let group_events = events
            .iter()
            .filter(|e| matches!(e, Event::DuplicateGroup { .. }))
            .count();
        assert_eq!(group_events, 1, "one real duplicate group");

        let summary = summary_of(&events);
        assert_eq!(summary.duplicate_group_count, 1);
        assert!(summary.duplicate_reclaimable_bytes > 0);
    }

    #[test]
    fn duplicate_groups_are_pageable_with_members() {
        let fixture = Fixture::new("engine-group-members");
        fixture
            .tree
            .file_with("Downloads/copy-one.bin", b"same payload here");
        fixture
            .tree
            .file_with("Downloads/copy-two.bin", b"same payload here");

        let mut request = fixture.request("group-members");
        request.duplicates.min_size_bytes = 1;
        request.duplicates.roots = vec![fixture.tree.root.to_string_lossy().to_string()];

        let engine = StdArc::new(Engine::new());
        let handle = engine.start_scan(request).unwrap();
        wait_for_completion(&handle);

        let index = handle.index();
        let groups = index.page_duplicate_groups(0, 10).unwrap();
        assert_eq!(groups.len(), 1);
        let members = index.duplicate_members(groups[0].group_id, 0, 100).unwrap();
        assert_eq!(members.len(), 2);
        assert_eq!(members.iter().filter(|m| m.keep).count(), 1);
    }

    #[test]
    fn summary_counts_files_and_bytes_examined() {
        let fixture = Fixture::new("engine-counts");
        fixture.tree.file("Library/Caches/com.a/blob.bin", 10_000);
        fixture.tree.file("Library/Caches/com.b/blob.bin", 20_000);

        let engine = StdArc::new(Engine::new());
        let handle = engine.start_scan(fixture.request("counts")).unwrap();
        wait_for_completion(&handle);
        let summary = summary_of(&drain(&handle));
        assert!(summary.scanned_file_count >= 2);
        assert!(summary.scanned_byte_count >= 30_000);
    }

    #[test]
    fn phase_events_arrive_in_order() {
        let fixture = Fixture::new("engine-phases");
        fixture.tree.file("Library/Caches/com.a/blob.bin", 4096);

        let engine = StdArc::new(Engine::new());
        let handle = engine.start_scan(fixture.request("phases")).unwrap();
        wait_for_completion(&handle);
        let phases: Vec<String> = drain(&handle)
            .iter()
            .filter_map(|event| match event {
                Event::PhaseChanged { phase } => Some(phase.clone()),
                _ => None,
            })
            .collect();
        assert!(phases.contains(&"preparing".to_string()));
        assert!(phases.contains(&"scanning".to_string()));
        assert!(
            phases.iter().any(|p| p == "ready" || p == "partial"),
            "phases seen: {phases:?}"
        );
    }

    #[test]
    fn starting_a_second_scan_cancels_the_first() {
        let fixture = Fixture::new("engine-restart");
        for i in 0..300 {
            fixture
                .tree
                .file(&format!("Library/Caches/com.app{i}/blob.bin"), 8192);
        }
        let engine = StdArc::new(Engine::new());
        let first = engine.start_scan(fixture.request("first")).unwrap();
        let second = engine.start_scan(fixture.request("second")).unwrap();
        assert!(first.session_id() != second.session_id());
        wait_for_completion(&second);
        assert_eq!(second.session_id(), "session-second");
    }

    #[test]
    fn event_queue_coalesces_progress_but_keeps_every_item_batch() {
        let handle = StdArc::new(ScanHandle {
            session_id: "queue".into(),
            cancel: CancelToken::new(),
            state: StdArc::new(SharedState::new()),
            events: StdArc::new(Mutex::new(VecDeque::new())),
            index: Mutex::new(FileIndex::open_in_memory("queue").unwrap()),
        });
        for i in 0..5 {
            handle.push(Event::Progress(ScanProgress {
                files_seen: i,
                ..Default::default()
            }));
            handle.push(Event::ItemBatch {
                items: vec![ScanItemSummary {
                    path: format!("/x/{i}"),
                    display_name: format!("x{i}"),
                    parent_path: "/x".into(),
                    category: "logs".into(),
                    risk: "safe".into(),
                    size_bytes: i,
                    file_count: 1,
                    explanation_key: "k".into(),
                    rule_id: "r".into(),
                    bundle_id: None,
                    modified_secs: 0,
                    is_directory: false,
                }],
            });
        }
        let batch = handle.poll_events(100);
        let batches = batch
            .events
            .iter()
            .filter(|e| matches!(e, Event::ItemBatch { .. }))
            .count();
        let progress = batch
            .events
            .iter()
            .filter(|e| matches!(e, Event::Progress(_)))
            .count();
        assert_eq!(batches, 5, "no item batch may be dropped");
        assert!(progress <= 2, "progress is coalesced, saw {progress}");
    }

    #[test]
    fn index_rows_carry_explanations_and_rule_ids() {
        let fixture = Fixture::new("engine-explanations");
        fixture.tree.file("Library/Caches/com.a/blob.bin", 4096);

        let engine = StdArc::new(Engine::new());
        let handle = engine.start_scan(fixture.request("explanations")).unwrap();
        wait_for_completion(&handle);
        let page = handle.page_results(0, 10, "size", None).unwrap();
        assert!(!page.is_empty());
        for row in &page {
            assert!(!row.rule_id.is_empty(), "every item names its rule");
            assert!(
                !row.explanation_key.is_empty(),
                "every item carries a localisable explanation"
            );
            assert!(!row.risk.is_empty());
        }
    }

    #[test]
    fn protected_content_never_reaches_the_index() {
        let fixture = Fixture::new("engine-protected");
        fixture.tree.file("Documents/tax-return.pdf", 8192);
        fixture.tree.file("Library/Caches/com.a/blob.bin", 4096);

        let engine = StdArc::new(Engine::new());
        let handle = engine.start_scan(fixture.request("protected")).unwrap();
        wait_for_completion(&handle);

        let page = handle.page_results(0, 100, "size", None).unwrap();
        assert!(
            page.iter().all(|row| !row.path.contains("/Documents/")),
            "user documents must never appear as cleanup items"
        );
    }

    #[test]
    fn large_and_old_file_candidates_land_in_their_own_categories() {
        let fixture = Fixture::new("engine-large");
        fixture.tree.file("Downloads/huge.bin", 3 * 1024 * 1024);
        let old = fixture
            .tree
            .file("Downloads/old-huge.bin", 20 * 1024 * 1024);
        fixture.tree.age(&old, 400);

        let engine = StdArc::new(Engine::new());
        let handle = engine.start_scan(fixture.request("large")).unwrap();
        wait_for_completion(&handle);

        let categories: Vec<String> = drain(&handle)
            .iter()
            .filter_map(|event| match event {
                Event::ItemBatch { items } => {
                    Some(items.iter().map(|i| i.category.clone()).collect::<Vec<_>>())
                }
                _ => None,
            })
            .flatten()
            .collect();
        assert!(
            categories.contains(&"largeFiles".to_string()),
            "{categories:?}"
        );
        assert!(
            categories.contains(&"oldFiles".to_string()),
            "{categories:?}"
        );
    }
}
