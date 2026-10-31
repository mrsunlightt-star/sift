//! Directory listing with a deadline.
//!
//! `std::fs::read_dir` blocks until the kernel answers, and one directory that
//! never answers — a policy check waiting on a dialog nobody sees, a wedged
//! mount — stalls the whole walk behind it: on this machine a scan sat inside
//! one `opendir` for over forty minutes while a system index storm held the
//! metadata layer. The lister runs the listing on a worker thread and gives
//! the walker a deadline instead: a directory that has not answered within it
//! is reported as skipped and the walk moves on. The worker stuck inside that
//! one open is abandoned — the kernel cannot be interrupted — and the next
//! listing starts a fresh one, so a pathological filesystem degrades into
//! skipped directories rather than a frozen scan.

use std::io;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{channel, RecvTimeoutError, Sender};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use sift_hasher::CancelToken;

/// Lists one directory's direct children.
type Opener = Arc<dyn Fn(&Path) -> io::Result<Vec<PathBuf>> + Send + Sync>;
type Job = (PathBuf, Sender<io::Result<Vec<PathBuf>>>);

/// How often a wait checks the cancellation flag.
const SLICE: Duration = Duration::from_millis(100);

/// Lists directories on a worker thread, with a deadline per listing.
pub(crate) struct DirLister {
    /// `None` after a timeout abandoned the worker; the next listing spawns a
    /// fresh one.
    job_sender: Option<Sender<Job>>,
    opener: Opener,
}

impl DirLister {
    pub(crate) fn new() -> Self {
        Self::with_opener(Arc::new(default_opener))
    }

    pub(crate) fn with_opener(opener: Opener) -> Self {
        let job_sender = spawn_worker(&opener);
        Self {
            job_sender: Some(job_sender),
            opener,
        }
    }

    /// Lists `path`, giving up after `timeout`.
    ///
    /// A cancelled wait reports a timeout and lets the caller's own
    /// cancellation check decide what that means; the worker stays alive,
    /// because it is healthy, merely busy.
    pub(crate) fn list(
        &mut self,
        path: &Path,
        timeout: Duration,
        cancel: &CancelToken,
    ) -> Result<Option<Vec<PathBuf>>, io::Error> {
        if self.job_sender.is_none() {
            self.job_sender = Some(spawn_worker(&self.opener));
        }
        let (reply_tx, reply_rx) = channel();
        let job: Job = (path.to_path_buf(), reply_tx.clone());
        if self
            .job_sender
            .as_ref()
            .expect("worker present")
            .send(job)
            .is_err()
        {
            // The worker died between listings; one replacement attempt keeps a
            // spurious thread death from turning into empty listings.
            self.job_sender = Some(spawn_worker(&self.opener));
            let _ = self
                .job_sender
                .as_ref()
                .expect("worker present")
                .send((path.to_path_buf(), reply_tx));
        }

        let deadline = Instant::now() + timeout;
        loop {
            match reply_rx.recv_timeout(SLICE) {
                Ok(result) => return result.map(Some),
                Err(RecvTimeoutError::Timeout) => {
                    if Instant::now() >= deadline {
                        return Ok(self.abandon());
                    }
                }
                Err(RecvTimeoutError::Disconnected) => {
                    return Ok(self.abandon());
                }
            }
            if cancel.is_cancelled() {
                return Ok(None);
            }
        }
    }

    /// Drops the worker that may be stuck inside one open and reports a
    /// timeout. The abandoned thread finishes — or does not — on its own; the
    /// kernel cannot be asked to interrupt it.
    fn abandon(&mut self) -> Option<Vec<PathBuf>> {
        self.job_sender = None;
        None
    }
}

fn spawn_worker(opener: &Opener) -> Sender<Job> {
    let (job_tx, job_rx) = channel::<Job>();
    let opener = Arc::clone(opener);
    thread::Builder::new()
        .name("sift-dir-lister".to_string())
        .spawn(move || {
            while let Ok((path, reply)) = job_rx.recv() {
                let _ = reply.send(opener(&path));
            }
        })
        .expect("spawn dir lister worker");
    job_tx
}

fn default_opener(path: &Path) -> io::Result<Vec<PathBuf>> {
    let mut entries = Vec::new();
    for entry in std::fs::read_dir(path)? {
        entries.push(entry?.path());
    }
    Ok(entries)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_dir(path: &Path) {
        std::fs::create_dir_all(path).unwrap();
        std::fs::write(path.join("child.txt"), b"x").unwrap();
    }

    #[test]
    fn a_responsive_directory_lists_within_the_deadline() {
        let base = std::env::temp_dir().join(format!("sift-lister-ok-{}", std::process::id()));
        write_dir(&base);

        let mut lister = DirLister::new();
        let cancel = CancelToken::new();
        let listing = lister.list(&base, Duration::from_secs(5), &cancel);

        let entries = listing.expect("a real filesystem error");
        let entries = entries.expect("a local directory must not time out");
        assert_eq!(entries.len(), 1);
        assert!(entries[0].ends_with("child.txt"));
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn a_stuck_directory_times_out_and_the_next_listing_recovers() {
        let base = std::env::temp_dir().join(format!("sift-lister-stuck-{}", std::process::id()));
        write_dir(&base);

        // An opener that never answers, the shape of a kernel-side block.
        let stuck: Opener = Arc::new(|_path| loop {
            thread::sleep(Duration::from_secs(3600));
        });
        let mut lister = DirLister::with_opener(stuck);

        let cancel = CancelToken::new();
        let listing = lister.list(&base, Duration::from_millis(200), &cancel);
        assert!(
            matches!(listing, Ok(None)),
            "the stuck listing must time out"
        );

        // The abandoned worker is replaced, so a later listing still answers.
        let healthy: Opener = Arc::new(|path| {
            std::fs::read_dir(path)?
                .map(|entry| entry.map(|e| e.path()))
                .collect()
        });
        lister.opener = healthy;
        let listing = lister.list(&base, Duration::from_secs(5), &cancel);
        let entries = listing.expect("a real filesystem error");
        assert_eq!(entries.expect("a fresh worker must answer").len(), 1);
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn a_cancelled_wait_reports_without_waiting_out_the_deadline() {
        let base = std::env::temp_dir().join(format!("sift-lister-cancel-{}", std::process::id()));
        write_dir(&base);

        let slow: Opener = Arc::new(|_path| {
            thread::sleep(Duration::from_secs(3600));
            Ok(Vec::new())
        });
        let mut lister = DirLister::with_opener(slow);
        let cancel = CancelToken::new();
        cancel.cancel();

        let started = Instant::now();
        let listing = lister.list(&base, Duration::from_secs(30), &cancel);
        assert!(matches!(listing, Ok(None)));
        assert!(
            started.elapsed() < Duration::from_secs(1),
            "cancel must not wait out the deadline"
        );
        let _ = std::fs::remove_dir_all(&base);
    }
}
