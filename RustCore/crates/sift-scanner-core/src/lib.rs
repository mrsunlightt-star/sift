//! Scanner core: directory traversal, classification and duplicate grouping.
//!
//! This crate only *discovers and analyses*. It never deletes, moves, renames or
//! trashes anything, never touches settings, and holds no purchase state. Every
//! destructive action is performed by the Swift layer, which re-validates each
//! path before acting.
//!
//! Layout:
//!
//! * [`walker`] — one cancellable, symlink-safe traversal primitive used by
//!   every strategy,
//! * [`scanners`] — the rule-driven and file-based strategies
//!   (cache, logs, installers, temporary files, residue, large, old, duplicate),
//! * [`coordinator`] — runs the strategies, publishes events and writes results
//!   into the [`sift_file_index::FileIndex`],
//! * [`storage`] — volume and per-category rollups for the storage analysis page.

pub mod coordinator;
pub mod scanners;
pub mod storage;
pub mod types;
pub mod walker;

pub use coordinator::{Engine, ScanHandle};
pub use types::{
    CategoryTotal, DuplicateOptions, EngineError, ErrorCode, Event, EventBatch, PhaseName,
    ScanItemSummary, ScanProgress, ScanRequest, ScanRoot, ScanSortOrder, ScanSummary,
    SkippedLocation,
};
