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

use crate::scanners::ProgressReporter;
use crate::scanners::{self, Candidate, ProgressSink, ScanContext};
use crate::types::{
    CategoryTotal, EngineError, Event, EventBatch, PhaseName, ScanItemSummary, ScanProgress,
    ScanRequest, ScanSummary, SkippedLocation,
};
use crate::walker;
use sift_file_index::{FileIndex, ItemRecord, ScanSort};
use sift_hasher::CancelToken;
use sift_rules::{collapse_path, normalize_path, Risk, RootAnchor};
use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// How often a progress event is published at most.
const PROGRESS_INTERVAL: Duration = Duration::from_millis(200);

/// How many live events one session may queue before its detail events are
/// folded together.
///
/// The UI drains batches at its own pace, and a scan of a full disk can produce
/// item batches far faster than a window redraws. The queue is the live view, so
/// it is bounded here — by merging batches rather than dropping them, because a
/// dropped batch is a row the index holds and the stream never carried, which is
/// how the counters and the index came to describe different runs. See
/// [`bound_queue`]: the memory itself is bounded by the walk's result budget.
const EVENT_QUEUE_LIMIT: usize = 4096;

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
    /// Skips kept beside the index.
    ///
    /// A skip write is best-effort: it must not fail a scan that is otherwise
    /// producing results. Keeping the same list here means the completion
    /// summary, the event stream and a later query answer with one set even
    /// when the index write did not land.
    skipped: Mutex<Vec<SkippedLocation>>,
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
            // The loop condition bounds `index`, so `None` is not reachable
            // today; skipping instead of unwinding keeps this FFI-facing
            // function panic-free even if a refactor ever breaks that
            // invariant. An event dropped is better than an unwind from a
            // thread Swift calls directly.
            match queue.remove(index) {
                Some(event) => out.push(event),
                None => continue,
            }
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
            bound_queue(&mut queue);
        }
    }

    fn push(&self, event: Event) {
        if let Ok(mut queue) = self.events.lock() {
            queue.push_back(event);
            bound_queue(&mut queue);
        }
    }

    fn push_batch(&self, items: Vec<ScanItemSummary>) {
        if items.is_empty() {
            return;
        }
        if let Ok(mut queue) = self.events.lock() {
            queue.push_back(Event::ItemBatch { items });
            bound_queue(&mut queue);
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

    /// The locations this session could not read.
    ///
    /// The in-memory list is authoritative for the current run; the index is
    /// the durable copy and fills in anything it holds that the list missed.
    pub fn skipped_locations(&self) -> Vec<SkippedLocation> {
        let mut locations = self
            .skipped
            .lock()
            .map(|value| value.clone())
            .unwrap_or_default();
        if let Ok(index) = self.index.lock() {
            if let Ok(stored) = index.skipped_locations() {
                for (path, code, message, byte_count) in stored {
                    if locations
                        .iter()
                        .any(|existing| existing.path == path && existing.code == code)
                    {
                        continue;
                    }
                    locations.push(SkippedLocation {
                        code,
                        path,
                        message,
                        byte_count,
                        needs_full_disk_access: false,
                    });
                }
            }
        }
        locations
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
    ///
    /// The request is normalised before anything reads it. The allowlist below
    /// judges a path by what it resolves to, and the walk visits the string it was
    /// given, so validating one spelling and walking another was a way past both:
    /// `~/Library/Caches/x/../Documents` passes a gate that compares the collapsed
    /// form, and the kernel then resolves `x` — a symlink, as far as the gate can
    /// tell — to a tree the request was never allowed to name. There is one string
    /// from here on, and it is the collapsed one.
    pub fn start_scan(
        self: &Arc<Self>,
        mut request: ScanRequest,
    ) -> Result<Arc<ScanHandle>, EngineError> {
        if request.session_id.trim().is_empty() {
            return Err(EngineError::InvalidRequest(
                "session id must not be empty".to_string(),
            ));
        }

        // Absoluteness is decided on the string that arrived, before it is
        // collapsed: `collapse_path` always answers a leading `/`, so collapsing
        // first turned `Library/Caches` into `/Library/Caches` and the check below
        // could never fail.
        if !Path::new(&request.home_dir).is_absolute() {
            return Err(EngineError::InvalidRequest(
                "home directory must be an absolute path".to_string(),
            ));
        }
        for root in &request.roots {
            if !Path::new(&root.path).is_absolute() {
                return Err(EngineError::InvalidRequest(
                    "a scan root is outside the allowlist".to_string(),
                ));
            }
        }
        for grant in &request.authorized_roots {
            if !Path::new(grant).is_absolute() {
                return Err(EngineError::InvalidRequest(
                    "an authorised root is outside the allowlist".to_string(),
                ));
            }
        }

        // From here there is one spelling of every path, and it is the collapsed
        // one: the gate, the walk, the rules and the protection check all read it.
        request.home_dir = collapse_path(&request.home_dir);
        for root in &mut request.roots {
            root.path = collapse_path(&root.path);
            // `collapse_path` removes `.` and `..`, so a component of either cannot
            // survive it. This is an assertion rather than a filter: if it ever
            // fires, the walk would be given a path the gate did not judge, and a
            // request is a better thing to refuse than a protection check to skip.
            if has_dot_component(&root.path) {
                return Err(EngineError::InvalidRequest(
                    "a scan root does not resolve to a path".to_string(),
                ));
            }
        }
        for grant in &mut request.authorized_roots {
            *grant = collapse_path(grant);
        }
        // The ABI is a trust boundary too. A request that named `/Volumes`, `/`
        // or the home directory itself as an authorised root would lift the
        // blanket volume guard for every disk, and the Swift allowlist cannot
        // protect a caller that never used it. The shape is checked here when
        // the request is read, not only where the UI happens to build one.
        let home_text = request.home_dir.clone();
        for root in &request.roots {
            let path = root.path.as_str();
            let inside_home = path == home_text || path.starts_with(&format!("{home_text}/"));
            let inside_volumes = path.starts_with("/Volumes/");
            let system_logs = path == "/Library/Logs" || path.starts_with("/Library/Logs/");
            // The per-user temporary root is the one scan root that is neither in
            // the home directory nor a volume: `/var/folders/<xx>/<hash>` is what
            // `$TMPDIR` sits in, and only the process that owns the session can
            // resolve it, so the request carries it with `anchor: "userTemp"`.
            // Without this branch every request the app builds was refused here
            // and the scan never started — the anchor was honoured by the rule
            // scanner and rejected by the gate in front of it.
            let user_temp =
                root.anchor == RootAnchor::UserTemp.as_str() && is_user_session_temp_root(path);
            if !(inside_home || inside_volumes || system_logs || user_temp) {
                return Err(EngineError::InvalidRequest(
                    "a scan root is outside the allowlist".to_string(),
                ));
            }
        }
        for grant in &request.authorized_roots {
            let path = grant.as_str();
            let inside_volumes = path.starts_with("/Volumes/");
            let inside_home = path.starts_with(&format!("{home_text}/"));
            if path == "/"
                || path == "/Volumes"
                || path == home_text
                || !(inside_volumes || inside_home)
            {
                return Err(EngineError::InvalidRequest(
                    "an authorised root is outside the allowlist".to_string(),
                ));
            }
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
            skipped: Mutex::new(Vec::new()),
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
        let owned_index = if request.index_path.trim().is_empty() {
            None
        } else {
            Some(PathBuf::from(&request.index_path))
        };
        std::thread::Builder::new()
            .name(format!("sift-scan-{}", request.session_id))
            .spawn(move || run_worker(&worker_handle, &request, owned_index))
            .map_err(|error| EngineError::Internal(error.to_string()))?;

        Ok(handle)
    }

    /// Cancels the active session, if any. Returns true when one was cancelled.
    pub fn cancel(&self) -> bool {
        self.cancel_current().is_some()
    }

    /// Cancels the active session, if any, and forgets its index path.
    ///
    /// The index files are deliberately *not* removed here. Cancellation is
    /// cooperative: the worker stops at its next checkpoint, so at this moment it
    /// is still writing through its `rusqlite` connection, and SQLite does not
    /// support unlinking `-wal`/`-shm` out from under one. The unlink used to
    /// happen right here and produced exactly that — the UI thread removing the
    /// write-ahead log while the worker committed into it.
    ///
    /// The worker no longer removes them either: every session keeps its index
    /// until the FFI session that owns the handle releases it, because a stopped
    /// run's items are still offered for cleanup. See [`run_worker`].
    fn cancel_current(&self) -> Option<Arc<ScanHandle>> {
        let previous = self.session.lock().ok().and_then(|mut slot| slot.take());
        if let Some(handle) = &previous {
            handle.cancel();
        }
        if let Ok(mut path_slot) = self.index_path.lock() {
            path_slot.take();
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

impl Drop for Engine {
    /// Stops the session and forgets the index path.
    ///
    /// The files are the session's to remove, for the reason
    /// [`Engine::cancel_current`] gives: only a holder that knows the index will
    /// not be read again may unlink `-wal` and `-shm`, and cancellation is
    /// cooperative, so the worker may still be at its last checkpoint when the
    /// engine goes away. What the engine can do without blocking is stop it and
    /// drop the path it wrote, so nothing that outlives it mistakes that file for
    /// its own.
    fn drop(&mut self) {
        drop(self.cancel_current());
    }
}

/// Runs one session to completion and leaves its index in place.
///
/// The index is never removed here any more. It used to be, for a session that
/// was cancelled or superseded, on the theory that such a session's index could
/// never be read — and that theory was what made "stop the scan" mean "throw away
/// everything it had already found". A stopped run's items are still offered for
/// cleanup now, so its index has to survive the worker.
///
/// Nothing is orphaned by this: the index belongs to the FFI session, and the
/// Swift session removes the files when it releases the handle (`shutDown`, its
/// `deinit`, or a new run replacing the old model), which is the only place that
/// knows the file will not be read again. Removing them here also had to take the
/// index lock, which put a file unlink between the worker's last write and the
/// `finished` flag the UI waits on.
fn run_worker(handle: &Arc<ScanHandle>, request: &ScanRequest, owned_index: Option<PathBuf>) {
    // A panic in the worker must not take the host process down.
    let outcome =
        std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| run_scan(handle, request)));
    if outcome.is_err() {
        handle.state.set_phase(PhaseName::Failed);
        handle.push_failed("internal", "The scan stopped unexpectedly.");
    }
    handle.state.finished.store(true, Ordering::Release);
    // `owned_index` names the file this worker created; releasing it is the
    // session's job now, not the worker's. See the note on this function.
    let _ = owned_index;
}

/// True when a normalised path still names a `.` or `..` component.
///
/// Checked on the raw segments rather than through `Path::components`, which
/// resolves an interior `.` away and would answer "no" for the one spelling the
/// caller might have sent.
fn has_dot_component(path: &str) -> bool {
    path.split('/')
        .any(|segment| segment == "." || segment == "..")
}

/// True when `path` names one login session's temporary root, and nothing wider.
///
/// `confstr(_CS_DARWIN_USER_TEMP_DIR)` answers `/var/folders/<xx>/<hash>/T/`, and
/// the Swift engine sends its parent as a scan root with `anchor: "userTemp"`.
/// That anchor cannot be derived from the home directory, which is exactly why
/// the shape is checked before it is accepted: taking the anchor on its own would
/// let a caller name `/private/var` or `/var/folders` itself — every session on
/// the machine — through a field the UI never offers. Shallower than
/// `<xx>/<hash>` is refused for the same reason; deeper is `T` or `C`, which the
/// rules reach from this root and which the walk still judges item by item.
fn is_user_session_temp_root(path: &str) -> bool {
    // `/var` is a symlink to `/private/var`, and either spelling may arrive.
    let normalized = normalize_path(path);
    let Some(rest) = normalized.strip_prefix("/private/var/folders/") else {
        return false;
    };
    let components: Vec<&str> = rest
        .split('/')
        .filter(|component| !component.is_empty())
        .collect();
    matches!(components.as_slice(), [session, hash] if session.len() == 2 && !hash.is_empty())
}

fn run_scan(handle: &Arc<ScanHandle>, request: &ScanRequest) {
    let started = Instant::now();
    // Borrowed, never cloned: every checkpoint must observe the same flag the
    // UI cancels.
    let cancel = &handle.cancel;
    let home = PathBuf::from(&request.home_dir);

    // The winner per path, carried across the strategies. The strategies run in
    // order within one session and can each name one path — a stale log
    // directory of an uninstalled application matches both the log rule and the
    // residue scan — so the row the user sees must be merged here rather than
    // left to which phase happened to run last. The Swift engine keeps the same
    // merge over its item index; holding `(risk, rule_id)` per path is all the
    // comparison needs.
    let mut merged: HashMap<PathBuf, (Risk, String)> = HashMap::new();

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
    // A walk that stopped at its result budget saw part of its tree. The items it
    // found are real, so they are kept; the run is not complete, so the summary
    // reports `partial` rather than presenting a truncated list as the result.
    let mut truncated = false;

    {
        let state = Arc::clone(&handle.state);
        let mut on_files = |files: u64, bytes: u64| {
            state.files_seen.fetch_add(files as i64, Ordering::Relaxed);
            state.bytes_seen.fetch_add(bytes as i64, Ordering::Relaxed);
        };
        // The same two counters behind an `Arc`, for the walks that report while
        // they run: they cannot borrow `on_files`, and borrowing the context
        // instead would make every argument of the call read what the closure
        // holds.
        // Publishes as it counts, not only between strategies. `scan_rules` walks
        // the whole tree in one call, so a publish that waits for it to return is
        // one event sixteen seconds after the phase changed and none before —
        // which is what the page showed as "0 files" followed by a number nobody
        // could believe. `Weak` because the handle owns this closure through the
        // context it builds.
        let reporter = {
            let state = Arc::clone(&handle.state);
            let handle = Arc::downgrade(handle);
            ProgressReporter::new(move |files: u64, bytes: u64| {
                state.files_seen.fetch_add(files as i64, Ordering::Relaxed);
                state.bytes_seen.fetch_add(bytes as i64, Ordering::Relaxed);
                if let Some(handle) = handle.upgrade() {
                    publish_if_due(&handle);
                }
            })
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
                reporter: Some(reporter),
            },
        };

        // 1. Rule-driven cleanup candidates.
        let (candidates, report) = scanners::scan_rules(&mut context, cancel);
        record_skips(handle, &report.skips, &mut skipped);
        truncated |= report.truncated;
        if report.cancelled || cancel.is_cancelled() {
            finish_cancelled(handle);
            return;
        }
        if let Err(error) = persist_candidates(
            handle,
            candidates,
            &batch_size,
            &mut pending_batch,
            &mut merged,
        ) {
            handle.state.set_phase(PhaseName::Failed);
            handle.push_failed(error.code().as_str(), &error.user_message());
            return;
        }
        handle.push_batch(std::mem::take(&mut pending_batch));
        publish_if_due(handle);

        // 2. Application residue, matched strictly by bundle identifier.
        if !cancel.is_cancelled() {
            let (residue, report) = scanners::scan_application_residue(&mut context, cancel);
            record_skips(handle, &report.skips, &mut skipped);
            truncated |= report.truncated;
            if let Err(error) = persist_candidates(
                handle,
                residue,
                &batch_size,
                &mut pending_batch,
                &mut merged,
            ) {
                handle.state.set_phase(PhaseName::Failed);
                handle.push_failed(error.code().as_str(), &error.user_message());
                return;
            }
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
            truncated |= report.truncated;
            if let Err(error) =
                persist_candidates(handle, large, &batch_size, &mut pending_batch, &mut merged)
            {
                handle.state.set_phase(PhaseName::Failed);
                handle.push_failed(error.code().as_str(), &error.user_message());
                return;
            }
            handle.push_batch(std::mem::take(&mut pending_batch));

            let (old, report) =
                scanners::scan_old_files(&mut context, cancel, request.old_file_threshold_days);
            record_skips(handle, &report.skips, &mut skipped);
            truncated |= report.truncated;
            if let Err(error) =
                persist_candidates(handle, old, &batch_size, &mut pending_batch, &mut merged)
            {
                handle.state.set_phase(PhaseName::Failed);
                handle.push_failed(error.code().as_str(), &error.user_message());
                return;
            }
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
        // to the ones the caller allowed to be cleaned. The scope allowlist is
        // applied to every root first: `duplicate_roots` honours the request's
        // own `duplicates.roots` list, the gate above judges only
        // `request.roots`, and a request that declared no roots used to skip
        // the containment test altogether — a crafted caller could name any
        // tree the protection list happens not to cover and walk it, hashing
        // its paths and contents into the index.
        let home_text = home.to_string_lossy().to_string();
        let roots: Vec<PathBuf> = scanners::duplicate_roots(request, &home)
            .into_iter()
            .filter(|root| {
                let path = root.to_string_lossy();
                let inside_home = path == home_text || path.starts_with(&format!("{home_text}/"));
                let inside_volumes = path.starts_with("/Volumes/");
                let system_logs = path == "/Library/Logs" || path.starts_with("/Library/Logs/");
                let user_temp = is_user_session_temp_root(&path);
                if !(inside_home || inside_volumes || system_logs || user_temp) {
                    return false;
                }
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
            )
            .with_skip_hidden(!request.include_hidden_files);
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
    let summary = match build_summary(
        handle,
        request,
        &skipped,
        started,
        &duplicate_report,
        truncated,
    ) {
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

/// Folds item batches together once the queue exceeds its bound.
///
/// A dropped `ItemBatch` used to be a row the user could page to in the index and
/// never saw arrive: Swift counts what the event stream carries, so the counters
/// and the index disagreed about one run. Rows are therefore merged rather than
/// dropped — the oldest batch's items are appended to the newest batch and the
/// batch itself goes away, which keeps the count of events down and loses none of
/// them.
///
/// `Progress` and `DuplicateGroup` are the events that are recalculated rather
/// than accumulated: a progress event is superseded by the next one, and a
/// duplicate group is a summary the index answers again. Phase changes, skipped
/// locations, the completion summary and a failure are never dropped at all: they
/// are verdicts and context, not the live list.
///
/// The memory bound this queue used to provide now comes from the walk's result
/// budget: a scan cannot produce more entries than the budget allows, so the
/// batches in the queue are bounded by the same number and sorting them into one
/// batch does not make the queue unbounded.
fn bound_queue(queue: &mut VecDeque<Event>) {
    while queue.len() > EVENT_QUEUE_LIMIT {
        if merge_oldest_item_batch(queue) {
            continue;
        }
        let droppable = queue
            .iter()
            .position(|event| matches!(event, Event::Progress(_)))
            .or_else(|| {
                queue
                    .iter()
                    .position(|event| matches!(event, Event::DuplicateGroup { .. }))
            });
        match droppable {
            Some(index) => {
                queue.remove(index);
            }
            None => break,
        }
    }
}

/// Appends the oldest item batch's items to the newest one. Returns false when
/// there is only one batch, which has nothing to fold into.
fn merge_oldest_item_batch(queue: &mut VecDeque<Event>) -> bool {
    let Some(newest) = queue
        .iter()
        .rposition(|event| matches!(event, Event::ItemBatch { .. }))
    else {
        return false;
    };
    let Some(oldest) = queue
        .iter()
        .position(|event| matches!(event, Event::ItemBatch { .. }))
    else {
        return false;
    };
    if oldest >= newest {
        return false;
    }
    let moved = match queue.get_mut(oldest) {
        Some(Event::ItemBatch { items }) => std::mem::take(items),
        _ => return false,
    };
    if let Some(Event::ItemBatch { items }) = queue.get_mut(newest) {
        items.extend(moved);
    }
    queue.remove(oldest);
    true
}

fn publish_if_due(handle: &Arc<ScanHandle>) {
    if handle.state.should_publish_progress() {
        handle.publish_progress();
    }
}

/// Writes the winning candidates into the index and emits summaries in batches.
///
/// `merged` decides which of two rows that name one path the user sees. Two
/// strategies can report the same directory — a stale log directory of an
/// uninstalled application matches both the `user-logs` rule and the residue
/// scan — and the upsert in the index otherwise lets the *last* write decide
/// the row's category, risk, rule id, explanation and preselection flag. That
/// made the row depend on strategy ordering, and in the ties the produced
/// preselection differed from the Swift engine, which compares the two rows
/// instead. The comparison is the one the Swift engine runs in `add`: the more
/// cautious risk wins, and an equal risk keeps the lexicographically greater
/// rule id, so two runs over the same tree produce the same row.
///
/// Losing candidates are neither written nor emitted. A candidate that
/// replaces an earlier winner is written, but not counted and not emitted: an
/// earlier batch already showed that path, so counting and emitting it again
/// would raise `items_found` above the number of distinct rows and carry the
/// path twice in the event stream — both of which the Swift engine's `add`
/// avoids by emitting only net-new items. The pages read the index, which
/// already holds the upgraded row.
fn persist_candidates(
    handle: &Arc<ScanHandle>,
    candidates: Vec<Candidate>,
    batch_size: &usize,
    pending_batch: &mut Vec<ScanItemSummary>,
    merged: &mut HashMap<PathBuf, (Risk, String)>,
) -> Result<(), EngineError> {
    if candidates.is_empty() {
        return Ok(());
    }
    // Rows the index should hold, with a flag saying whether the path is new
    // to the run: the comparison above rewrote `merged`'s entry, and the
    // summaries below are emitted for the net-new rows only.
    let mut winners: Vec<(Candidate, bool)> = Vec::with_capacity(candidates.len());
    for candidate in candidates {
        let keeper = merged
            .get(&candidate.path)
            .map(|(risk, rule)| (*risk, rule.as_str()));
        let replaces = match keeper {
            Some((kept_risk, kept_rule)) => {
                (candidate.risk, candidate.rule_id.as_str()) > (kept_risk, kept_rule)
            }
            None => true,
        };
        if replaces {
            let is_new = merged
                .insert(
                    candidate.path.clone(),
                    (candidate.risk, candidate.rule_id.clone()),
                )
                .is_none();
            winners.push((candidate, is_new));
        }
    }
    // `to_item_row` borrows, so the rows are built before the summaries below
    // move the diagnostics out of `winners`.
    let rows: Vec<_> = winners
        .iter()
        .map(|(candidate, _)| candidate.to_item_row())
        .collect();
    {
        let mut index = handle.index_checked()?;
        // Chunked transactions stay responsive while still amortising the WAL
        // sync cost.
        for chunk in rows.chunks(1024) {
            index.insert_items(chunk).map_err(|_| {
                EngineError::Internal("Scan results could not be stored.".to_string())
            })?;
        }
    }
    let net_new = winners.iter().filter(|(_, is_new)| *is_new).count();
    handle
        .state
        .items_found
        .fetch_add(net_new as i64, Ordering::Relaxed);

    for (candidate, is_new) in winners {
        if !is_new {
            continue;
        }
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
    Ok(())
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
            // Best effort, not a verdict: the scan may still produce a complete
            // result, and the same location is carried by the event, the
            // summary and the in-memory list below. A scan is not failed
            // because one diagnostic row could not be persisted.
            let _ = index.insert_skipped(
                &location.path,
                &location.code,
                &location.message,
                location.byte_count,
            );
        }
        if let Ok(mut kept) = handle.skipped.lock() {
            kept.push(location.clone());
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
    truncated: bool,
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

    // Three ways a run is incomplete, and all of them must reach the flag: a
    // location that could not be read, a walk that spent its budget, and a
    // duplicate stage that spent its hashes. `is_partial` is what the page shows
    // and what the phase becomes, so a run that hit any of them and reported
    // `ready` was claiming a comparison it never made.
    let is_partial = !skipped.is_empty() || duplicate_report.truncated || truncated;
    // The summary carries the final phase as well as the flag. The event stream
    // already says `partial`, but the completion event used to overwrite it with
    // `ready`, so the page showed a complete scan after a permission skip.
    let phase = if is_partial {
        PhaseName::Partial
    } else {
        PhaseName::Ready
    };

    Ok(ScanSummary {
        session_id: request.session_id.clone(),
        phase: phase.as_str().to_string(),
        scanned_file_count: handle.state.files_seen.load(Ordering::Relaxed),
        scanned_byte_count: handle.state.bytes_seen.load(Ordering::Relaxed),
        item_count: totals.item_count,
        item_bytes: totals.total_bytes,
        category_totals,
        duplicate_group_count,
        duplicate_reclaimable_bytes,
        skipped: skipped.to_vec(),
        elapsed_millis: started.elapsed().as_millis() as i64,
        is_partial,
    })
}

/// Ends a stopped run, reporting what it had already found.
///
/// The index outlives the stop (see [`run_worker`]), so the summary can carry the
/// same totals a completed run would: the item count, the bytes and the category
/// breakdown all come from the same rows the result page is about to page out. A
/// summary that reported only `items_found` from an atomic counter left the page
/// with a total and no categories, and a category list with no sizes.
///
/// An index that cannot be read is not an error here: the stop itself succeeded,
/// and a summary of zeros is still an honest account of "nothing to show".
fn finish_cancelled(handle: &Arc<ScanHandle>) {
    handle.state.set_phase(PhaseName::Cancelled);
    handle.push(Event::PhaseChanged {
        phase: PhaseName::Cancelled.as_str().to_string(),
    });

    let totals = handle.index_checked().ok().and_then(|index| {
        let summary = index.summary().ok()?;
        let categories = index.category_totals().ok()?;
        Some((summary, categories))
    });
    let (item_count, item_bytes, category_totals) = match totals {
        Some((summary, categories)) => (
            summary.item_count,
            summary.total_bytes,
            categories
                .into_iter()
                .map(|(category, item_count, total_bytes)| CategoryTotal {
                    category,
                    item_count,
                    total_bytes,
                })
                .collect(),
        ),
        None => (0, 0, Vec::new()),
    };

    let summary = ScanSummary {
        session_id: handle.session_id.clone(),
        phase: PhaseName::Cancelled.as_str().to_string(),
        scanned_file_count: handle.state.files_seen.load(Ordering::Relaxed),
        scanned_byte_count: handle.state.bytes_seen.load(Ordering::Relaxed),
        item_count,
        item_bytes,
        category_totals,
        skipped: Vec::new(),
        elapsed_millis: 0,
        is_partial: true,
        ..Default::default()
    };
    handle.push(Event::Completed(Box::new(summary)));
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::ScanRoot;
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

    /// The live event queue is bounded, but never at the cost of the verdict.
    #[test]
    fn the_event_queue_drops_detail_before_it_drops_the_completion() {
        let mut queue: VecDeque<Event> = (0..EVENT_QUEUE_LIMIT + 100)
            .map(|index| Event::ItemBatch {
                items: vec![ScanItemSummary {
                    path: format!("/tmp/item-{index}"),
                    display_name: String::new(),
                    parent_path: String::new(),
                    category: "applicationCache".to_string(),
                    risk: "safe".to_string(),
                    size_bytes: 1,
                    file_count: 1,
                    explanation_key: "cleanup.explanation.cache".to_string(),
                    rule_id: "test".to_string(),
                    bundle_id: None,
                    modified_secs: 0,
                    is_directory: false,
                }],
            })
            .collect();
        queue.push_back(Event::Completed(Box::default()));

        bound_queue(&mut queue);

        assert!(queue.len() <= EVENT_QUEUE_LIMIT);
        assert!(
            queue
                .iter()
                .any(|event| matches!(event, Event::Completed(_))),
            "the completion summary is never a detail event"
        );
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

    /// The app's own request is accepted.
    ///
    /// `AppEnvironment.makeScanRequest` sends three roots on an ordinary Mac: the
    /// home directory, `/Library/Logs` and the session's `/var/folders/<xx>/<hash>`
    /// with `anchor: "userTemp"`. The third one was outside the allowlist, so every
    /// scan the shipped app started was refused with `invalidRequest` before the
    /// engine did any work — and no test noticed, because the fixtures put every
    /// root inside a temporary home directory.
    #[test]
    fn the_roots_the_app_builds_are_accepted() {
        let engine = StdArc::new(Engine::new());
        let request = ScanRequest {
            session_id: "app-roots".to_string(),
            home_dir: std::env::var("HOME").unwrap_or_else(|_| "/Users/example".to_string()),
            roots: vec![
                ScanRoot::new(
                    std::env::var("HOME").unwrap_or_else(|_| "/Users/example".to_string()),
                    "home",
                ),
                ScanRoot::new("/Library/Logs", "systemLibrary"),
                ScanRoot::new("/var/folders/zz/0000000000000000000000", "userTemp"),
            ],
            ..Default::default()
        };
        let handle = engine
            .start_scan(request)
            .expect("the request the app builds must be accepted");
        // Cancelled and drained: the point is that the gate let the request
        // through, not what the walk of a real home directory finds.
        handle.cancel();
        wait_for_completion(&handle);
    }

    /// A `userTemp` root is accepted only in the shape macOS produces.
    ///
    /// The anchor cannot be derived from the home directory, so it is the request
    /// that names it — and that is why the shape is checked: `/var/folders` is
    /// every session on the machine, not this one.
    #[test]
    fn a_user_temp_root_is_accepted_only_at_the_session_depth() {
        for accepted in [
            "/var/folders/zz/0000000000000000000000",
            "/private/var/folders/zz/0000000000000000000000",
        ] {
            assert!(
                is_user_session_temp_root(accepted),
                "{accepted} is one session's temporary root"
            );
        }
        for refused in [
            "/var/folders",
            "/var/folders/",
            "/var/folders/zz",
            "/var/folders/zz/0000000000000000000000/T",
            "/var/folders/zz/0000000000000000000000/C/stale.app",
            "/private/var",
            "/Users/example",
            "/tmp",
        ] {
            assert!(
                !is_user_session_temp_root(refused),
                "{refused} is wider than one session"
            );
        }

        let engine = StdArc::new(Engine::new());
        let home = std::env::var("HOME").unwrap_or_else(|_| "/Users/example".to_string());
        // The shape is right but the anchor is not: a caller that never said
        // `userTemp` gets no temporary-root allowance.
        let request = ScanRequest {
            session_id: "wrong-anchor".to_string(),
            home_dir: home.clone(),
            roots: vec![
                ScanRoot::new(home, "home"),
                ScanRoot::new("/var/folders/zz/0000000000000000000000", "home"),
            ],
            ..Default::default()
        };
        assert!(matches!(
            engine.start_scan(request),
            Err(EngineError::InvalidRequest(_))
        ));

        // The anchor is right but the path is a whole tree of sessions.
        let request = ScanRequest {
            session_id: "too-wide".to_string(),
            home_dir: std::env::var("HOME").unwrap_or_else(|_| "/Users/example".to_string()),
            roots: vec![ScanRoot::new("/var/folders", "userTemp")],
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

        // The completion summary is what Swift applies last, so it has to carry
        // the same phase the event stream reported before it.
        let summary = summary_of(&events);
        assert!(
            summary.is_partial,
            "the skipped folder makes the scan partial"
        );
        assert_eq!(summary.phase, "partial");

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
            skipped: Mutex::new(Vec::new()),
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

    /// The rules and the residue scan can name one directory: a stale log
    /// directory of an uninstalled application matches both. The row the user
    /// sees is decided by the comparison, not by which strategy ran last — the
    /// rule row carries the preselection and the log explanation, and both
    /// engines must end there.
    #[test]
    fn a_stale_uninstalled_log_directory_keeps_the_rule_row() {
        let fixture = Fixture::new("engine-merge-stale-log");
        let stale = fixture.tree.file("Library/Logs/com.gone.app/old.log", 2048);
        fixture.tree.age(&stale, 60);

        let mut request = fixture.request("merge-stale-log");
        request.installed_bundle_ids = vec!["com.installed.app".to_string()];
        let engine = StdArc::new(Engine::new());
        let handle = engine.start_scan(request).unwrap();
        wait_for_completion(&handle);

        let page = handle.page_results(0, 100, "size", None).unwrap();
        let rows: Vec<_> = page
            .iter()
            .filter(|row| row.path.ends_with("Library/Logs/com.gone.app"))
            .collect();
        assert_eq!(rows.len(), 1, "one row for the met path: {rows:?}");
        let row = rows[0];
        assert_eq!(row.rule_id, "user-logs", "the rule row wins the tie");
        assert_eq!(row.explanation_key, "cleanup.explanation.logsItem");
        assert!(
            row.is_selected_by_default,
            "a safe rule row stays preselected"
        );
    }

    /// The mirror case: where the strategy rows differ in risk, the more
    /// cautious one wins even though the rule wrote first.
    #[test]
    fn a_cache_child_of_an_uninstalled_app_stays_the_residue_row() {
        let fixture = Fixture::new("engine-merge-residue-caches");
        fixture
            .tree
            .file("Library/Caches/com.gone.app/blob.bin", 4096);

        let mut request = fixture.request("merge-residue-caches");
        request.installed_bundle_ids = vec!["com.installed.app".to_string()];
        let engine = StdArc::new(Engine::new());
        let handle = engine.start_scan(request).unwrap();
        wait_for_completion(&handle);

        let page = handle.page_results(0, 100, "size", None).unwrap();
        let rows: Vec<_> = page
            .iter()
            .filter(|row| row.path.ends_with("Library/Caches/com.gone.app"))
            .collect();
        assert_eq!(rows.len(), 1, "one row for the met path: {rows:?}");
        let row = rows[0];
        assert_eq!(row.rule_id, "app-residue");
        assert_eq!(row.risk, "review", "the more cautious row wins");
        assert!(!row.is_selected_by_default);
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

        // The index holds one row per path, so both categories appear there:
        // `old-huge.bin` matches both threshold scans, and with the risks equal
        // the lexicographically greater rule id (`old-files`) wins the tie.
        let page = handle.page_results(0, 100, "size", None).unwrap();
        let categories: Vec<&str> = page.iter().map(|row| row.category.as_str()).collect();
        assert!(categories.contains(&"largeFiles"), "{categories:?}");
        assert!(categories.contains(&"oldFiles"), "{categories:?}");

        // The event stream shows each path once: the old-files phase replaced
        // the `old-huge.bin` row in place and neither emitted nor counted it
        // again, which is what the Swift engine's `add` does with a replaced
        // row. The two engines' streams and totals therefore say the same
        // thing, and `item_count` names the distinct rows.
        let events = drain(&handle);
        let streamed_paths: Vec<String> = events
            .iter()
            .filter_map(|event| match event {
                Event::ItemBatch { items } => Some(
                    items
                        .iter()
                        .map(|item| item.path.clone())
                        .collect::<Vec<_>>(),
                ),
                _ => None,
            })
            .flatten()
            .collect();
        let item_count = events
            .iter()
            .find_map(|event| match event {
                Event::Completed(summary) => Some(summary.item_count),
                _ => None,
            })
            .unwrap_or_default();
        let mut sorted_paths = streamed_paths.clone();
        sorted_paths.sort();
        assert!(
            sorted_paths.windows(2).all(|pair| pair[0] != pair[1]),
            "a path was streamed twice: {sorted_paths:?}"
        );
        assert_eq!(streamed_paths.len(), 2, "{sorted_paths:?}");
        assert_eq!(streamed_paths.len() as i64, item_count, "{sorted_paths:?}");
        assert_eq!(streamed_paths.len(), page.len(), "{sorted_paths:?}");
    }

    /// The database and the two files SQLite writes beside it, if any of them
    /// are still on disk.
    fn index_files(path: &Path) -> Vec<PathBuf> {
        let base = path.to_string_lossy();
        ["", "-wal", "-shm"]
            .iter()
            .map(|suffix| PathBuf::from(format!("{base}{suffix}")))
            .filter(|candidate| candidate.exists())
            .collect()
    }

    /// A cancelled session removes its own index files, and no file is unlinked
    /// under a live connection.
    ///
    /// The engine used to remove them inside `cancel_current`, immediately after
    /// asking the worker to stop — but cancellation is cooperative, so the worker
    /// was still committing into the `-wal` the UI thread had just unlinked.
    /// SQLite does not support that. The worker now removes its files as its last
    /// act, after `finished`, when it is the only thread that can touch the
    /// connection.
    #[test]
    fn a_stopped_scan_keeps_an_index_that_still_pages() {
        let fixture = Fixture::new("index-cancel");
        for i in 0..50 {
            fixture
                .tree
                .file(&format!("Library/Caches/com.app{i}/blob.bin"), 8192);
        }
        let store = TempTree::new("index-cancel-store");
        let index_path = store.root.join("scan.sqlite");

        let mut request = fixture.request("index-cancel");
        request.index_path = index_path.to_string_lossy().to_string();

        let engine = StdArc::new(Engine::new());
        let handle = engine.start_scan(request).expect("scan starts");
        // Long enough for the walk to judge something, short enough that the run
        // is still going: the point is a stop in the middle, not an empty index.
        std::thread::sleep(Duration::from_millis(40));
        handle.cancel();
        wait_for_completion(&handle);

        // A stopped run keeps its index: the page offers what the walk had
        // already judged, so the files must outlive the worker. Removing them
        // here is what made "stop" mean "discard everything found so far".
        assert!(
            !index_files(&index_path).is_empty(),
            "a stopped session keeps the index its result page is served from"
        );

        let summary = summary_of(&drain(&handle));
        assert_eq!(summary.phase, "cancelled");

        // The summary describes the index instead of carrying the default it
        // used to: a total with no categories left the page unable to say what
        // the stop had found.
        if summary.item_count > 0 {
            assert!(
                !summary.category_totals.is_empty(),
                "a stopped summary carries the categories it found"
            );
            let page = handle
                .page_results(0, 10, "size", None)
                .expect("a stopped session pages its rows");
            assert!(
                !page.is_empty(),
                "the stopped run's rows are still readable"
            );
        }
    }

    /// A session that completed keeps its index: the page is served out of it.
    #[test]
    fn a_completed_scan_keeps_an_index_that_still_pages() {
        let fixture = Fixture::new("index-kept");
        fixture
            .tree
            .file("Library/Caches/com.example.app/blob.bin", 4096);
        let store = TempTree::new("index-kept-store");
        let index_path = store.root.join("scan.sqlite");

        let mut request = fixture.request("index-kept");
        request.index_path = index_path.to_string_lossy().to_string();

        let engine = StdArc::new(Engine::new());
        let handle = engine.start_scan(request).expect("scan starts");
        wait_for_completion(&handle);

        let page = handle
            .page_results(0, 10, "size", None)
            .expect("paging works");
        assert!(
            page.iter()
                .any(|row| row.path.ends_with("Library/Caches/com.example.app")),
            "the completed session's rows are pageable: {:?}",
            page.iter().map(|row| &row.path).collect::<Vec<_>>()
        );
        assert!(
            index_path.exists(),
            "a finished scan keeps its index; the page reads from it"
        );
    }

    /// Going away cancels the session the engine held.
    ///
    /// `cancel()` is cooperative, so a worker outlives the engine by a checkpoint;
    /// what `Drop` can promise without blocking is that the session was told to
    /// stop and that its path is forgotten. A session whose index is left behind
    /// with a live connection is what H4 was: the engine removed the files while
    /// the worker was still writing them.
    #[test]
    fn dropping_the_engine_cancels_the_session_it_held() {
        let fixture = Fixture::new("engine-drop");
        for i in 0..50 {
            fixture
                .tree
                .file(&format!("Library/Caches/com.app{i}/blob.bin"), 8192);
        }
        let store = TempTree::new("engine-drop-store");
        let index_path = store.root.join("scan.sqlite");

        let mut request = fixture.request("engine-drop");
        request.index_path = index_path.to_string_lossy().to_string();

        let engine = StdArc::new(Engine::new());
        let handle = engine.start_scan(request).expect("scan starts");
        drop(engine);

        wait_for_completion(&handle);
        // The engine's job is to stop the worker, not to unlink its index: the
        // files belong to the session that owns the handle, and that holder is
        // the only one that knows when the index will not be read again.
        assert!(handle.is_finished(), "the session it held was stopped");
        assert!(
            !index_files(&index_path).is_empty(),
            "the index outlives the engine, because a stop no longer discards it"
        );
    }

    /// A root is judged by what it resolves to, and the walk visits that.
    ///
    /// The gate collapsed each path for validation and then handed the raw strings
    /// to the walk, so a root carrying `..` was approved as one location and
    /// resolved by the kernel as another.
    #[test]
    fn a_root_with_a_dotdot_component_is_collapsed_before_the_walk() {
        let fixture = Fixture::new("root-dotdot");
        fixture.tree.file("Library/Caches/large.bin", 8192);

        let mut request = fixture.request("root-dotdot");
        request.large_file_threshold_bytes = 1024;
        request.roots = vec![ScanRoot::new(
            format!(
                "{}/Library/../Library/Caches",
                fixture.tree.root.to_string_lossy()
            ),
            "home",
        )];

        let engine = StdArc::new(Engine::new());
        let handle = engine.start_scan(request).expect("the root is accepted");
        wait_for_completion(&handle);

        let page = handle.page_results(0, 50, "size", None).expect("paging");
        assert!(
            page.iter()
                .any(|row| row.path.ends_with("Library/Caches/large.bin")),
            "the file the root resolves to is reported: {:?}",
            page.iter().map(|row| &row.path).collect::<Vec<_>>()
        );
        assert!(
            page.iter().all(|row| !row.path.contains("..")),
            "no row carries the spelling the request used: {:?}",
            page.iter().map(|row| &row.path).collect::<Vec<_>>()
        );
    }

    /// A root that only leaves the allowlist after collapsing is refused.
    #[test]
    fn a_root_that_escapes_after_collapsing_is_refused() {
        let fixture = Fixture::new("root-escape");
        let engine = StdArc::new(Engine::new());
        let mut request = fixture.request("root-escape");
        request.roots = vec![ScanRoot::new(
            format!(
                "{}/Library/../../Documents",
                fixture.tree.root.to_string_lossy()
            ),
            "home",
        )];
        assert!(matches!(
            engine.start_scan(request),
            Err(EngineError::InvalidRequest(_))
        ));
    }

    /// A run that spent a walk budget is `partial`, never `ready`.
    ///
    /// The items a truncated walk found are real, so they stay; what the summary
    /// must not do is present a part of the tree as the whole of it. `is_partial`
    /// is what the page shows and what the phase becomes, so both are checked here
    /// rather than only the flag.
    #[test]
    fn a_scan_that_hit_its_walk_budget_is_reported_as_partial() {
        let handle = StdArc::new(ScanHandle {
            session_id: "partial".into(),
            cancel: CancelToken::new(),
            state: StdArc::new(SharedState::new()),
            events: StdArc::new(Mutex::new(VecDeque::new())),
            index: Mutex::new(FileIndex::open_in_memory("partial").unwrap()),
            skipped: Mutex::new(Vec::new()),
        });
        let request = ScanRequest {
            session_id: "partial".into(),
            ..Default::default()
        };
        let summary = |truncated: bool| {
            build_summary(
                &handle,
                &request,
                &[],
                Instant::now(),
                &scanners::DuplicateReport::default(),
                truncated,
            )
            .expect("the summary is built from an empty index")
        };

        let cut_short = summary(true);
        assert!(cut_short.is_partial);
        assert_eq!(
            cut_short.phase, "partial",
            "the completion event must not overwrite partial with ready"
        );

        let complete = summary(false);
        assert!(!complete.is_partial);
        assert_eq!(complete.phase, "ready");
    }

    /// A full queue folds item batches together instead of losing their rows.
    ///
    /// Dropping a batch meant the index held a row the event stream never carried,
    /// so Swift's counters and the index described different runs. Only the events
    /// that are recalculated — progress, duplicate groups — may go.
    #[test]
    fn a_full_queue_merges_item_batches_instead_of_dropping_rows() {
        let mut queue: VecDeque<Event> = VecDeque::new();
        let rows = EVENT_QUEUE_LIMIT + 50;
        for index in 0..rows {
            queue.push_back(Event::ItemBatch {
                items: vec![item_summary(&format!("/tmp/item-{index}"))],
            });
            queue.push_back(Event::Progress(ScanProgress::default()));
        }
        queue.push_back(Event::Completed(Box::default()));

        bound_queue(&mut queue);

        assert!(queue.len() <= EVENT_QUEUE_LIMIT);
        let delivered: usize = queue
            .iter()
            .filter_map(|event| match event {
                Event::ItemBatch { items } => Some(items.len()),
                _ => None,
            })
            .sum();
        assert_eq!(
            delivered, rows,
            "every row the index holds is still in the stream"
        );
        assert!(
            queue
                .iter()
                .any(|event| matches!(event, Event::Completed(_))),
            "the completion summary is never a detail event"
        );
    }

    fn item_summary(path: &str) -> ScanItemSummary {
        ScanItemSummary {
            path: path.to_string(),
            display_name: String::new(),
            parent_path: String::new(),
            category: "applicationCache".to_string(),
            risk: "safe".to_string(),
            size_bytes: 1,
            file_count: 1,
            explanation_key: "cleanup.explanation.cache".to_string(),
            rule_id: "test".to_string(),
            bundle_id: None,
            modified_secs: 0,
            is_directory: false,
        }
    }
}
