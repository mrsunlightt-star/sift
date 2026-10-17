//! Performance benchmarks for the scanning stages the specification calls out.
//!
//! Every benchmark builds its own synthetic tree under the system temporary
//! directory and removes it afterwards, so a benchmark run never touches real
//! user data. Baseline numbers recorded from these are what the CI regression
//! check compares against.
//!
//! Run with: `cargo bench -p sift-scanner-core`

use criterion::{black_box, criterion_group, criterion_main, BenchmarkId, Criterion, Throughput};
use sift_file_index::{FileIndex, GroupMemberRow, ItemRow};
use sift_hasher::{hash_file, sample_fingerprint, CancelToken};
use sift_scanner_core::walker::{self, WalkMode, WalkOptions};
use std::path::{Path, PathBuf};

/// A synthetic tree that removes itself on drop.
struct Tree {
    root: PathBuf,
}

impl Tree {
    fn new(tag: &str) -> Self {
        let mut root = std::env::temp_dir();
        root.push(format!(
            "sift-bench-{tag}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&root).expect("create benchmark tree");
        Self { root }
    }

    fn path(&self) -> &Path {
        &self.root
    }

    /// Creates `directories` folders with `files_each` files of `bytes` each.
    fn populate(&self, directories: usize, files_each: usize, bytes: usize) -> Vec<PathBuf> {
        let payload = vec![b'x'; bytes];
        let mut written = Vec::with_capacity(directories * files_each);
        for directory in 0..directories {
            let directory_path = self.root.join(format!("d{directory}"));
            std::fs::create_dir_all(&directory_path).expect("create directory");
            for file in 0..files_each {
                let path = directory_path.join(format!("f{file}.bin"));
                std::fs::write(&path, &payload).expect("write file");
                written.push(path);
            }
        }
        written
    }
}

impl Drop for Tree {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

/// Directory metadata scanning: the walker is the hottest path in a full scan.
fn bench_directory_metadata(c: &mut Criterion) {
    let mut group = c.benchmark_group("directory_metadata");
    for (directories, files_each) in [(20usize, 50usize), (50, 100)] {
        let tree = Tree::new(&format!("meta-{directories}x{files_each}"));
        tree.populate(directories, files_each, 4096);
        let total_files = (directories * files_each) as u64;

        let options = WalkOptions::new(tree.path().to_path_buf(), WalkMode::Files);
        let cancel = CancelToken::new();

        group.throughput(Throughput::Elements(total_files));
        group.bench_with_input(
            BenchmarkId::from_parameter(format!("{directories}x{files_each}")),
            &total_files,
            |b, _| {
                b.iter(|| {
                    let report = walker::walk(black_box(tree.path()), black_box(&options), &cancel);
                    black_box(report.entries.len())
                })
            },
        );
    }
    group.finish();
}

/// Local comparison: the cheap stage that rejects most non-duplicates.
fn bench_partial_comparison(c: &mut Criterion) {
    let mut group = c.benchmark_group("partial_comparison");
    for megabytes in [4u64, 64] {
        let tree = Tree::new(&format!("sample-{megabytes}mb"));
        let bytes = (megabytes * 1024 * 1024) as usize;
        let payload = vec![b's'; bytes];
        let paths = tree.populate(1, 4, bytes);
        let size = bytes as u64;
        let _ = payload;

        group.throughput(Throughput::Bytes(size * 4));
        group.bench_with_input(
            BenchmarkId::from_parameter(format!("{megabytes}mb_x4")),
            &paths,
            |b, paths| {
                b.iter(|| {
                    let mut digest = String::new();
                    for path in paths {
                        digest = sample_fingerprint(black_box(path), black_box(size))
                            .expect("sample succeeds");
                    }
                    black_box(digest)
                })
            },
        );
    }
    group.finish();
}

/// Full hashing throughput, which dominates duplicate scanning of large files.
fn bench_full_hash(c: &mut Criterion) {
    let mut group = c.benchmark_group("full_hash");
    for megabytes in [8u64, 128] {
        let tree = Tree::new(&format!("hash-{megabytes}mb"));
        let bytes = (megabytes * 1024 * 1024) as usize;
        let paths = tree.populate(1, 1, bytes);
        let path = &paths[0];
        let cancel = CancelToken::new();

        group.throughput(Throughput::Bytes(megabytes * 1024 * 1024));
        group.bench_with_input(
            BenchmarkId::from_parameter(format!("{megabytes}mb")),
            path,
            |b, path| {
                b.iter(|| {
                    let digest = hash_file(black_box(path), &cancel).expect("hash succeeds");
                    black_box(digest.len())
                })
            },
        );
    }
    group.finish();
}

/// Index writes: every discovered item lands here, so the batch size matters.
fn bench_index_insert(c: &mut Criterion) {
    let mut group = c.benchmark_group("index_insert");

    let row = |index: usize| ItemRow {
        path: format!("/Users/example/Library/Caches/com.example.app/item{index}.bin"),
        display_name: format!("item{index}.bin"),
        parent_path: "/Users/example/Library/Caches/com.example.app".to_string(),
        category: "applicationCache".to_string(),
        risk: "safe".to_string(),
        size_bytes: 4096,
        file_count: 1,
        explanation: String::new(),
        explanation_key: "cleanup.cache.explanation".to_string(),
        rule_id: "user-cache".to_string(),
        bundle_id: Some("com.example.app".to_string()),
        modified_secs: 1_700_000_000,
        created_secs: 1_600_000_000,
        is_directory: false,
        is_restorable: true,
        is_selected_by_default: true,
        resolve_warning: None,
    };

    for batch in [256u32, 1024] {
        let rows: Vec<ItemRow> = (0..batch as usize).map(row).collect();
        group.throughput(Throughput::Elements(batch as u64));
        group.bench_with_input(
            BenchmarkId::from_parameter(format!("batch_{batch}")),
            &rows,
            |b, rows| {
                b.iter(|| {
                    let mut index =
                        FileIndex::open_in_memory("bench").expect("in-memory index opens");
                    index
                        .insert_items(black_box(rows))
                        .expect("insert succeeds");
                    black_box(index.item_count().expect("count"))
                })
            },
        );
    }

    // Reading a page back out is the other half of the FFI contract.
    let rows: Vec<ItemRow> = (0..2000).map(row).collect();
    group.bench_function("page_512_of_2000", |b| {
        let mut index = FileIndex::open_in_memory("bench-page").expect("index opens");
        index.insert_items(&rows).expect("insert succeeds");
        b.iter(|| {
            let page = index
                .page_items(0, black_box(512), sift_file_index::ScanSort::Size, None)
                .expect("page succeeds");
            black_box(page.len())
        })
    });

    group.bench_function("duplicate_group_insert_100", |b| {
        let members: Vec<GroupMemberRow> = (0..3)
            .map(|member| GroupMemberRow {
                path: format!("/Users/example/Downloads/copy-{member}.bin"),
                size_bytes: 1024 * 1024,
                modified_secs: 1_700_000_000,
                keep: member == 0,
            })
            .collect();
        b.iter(|| {
            let mut index = FileIndex::open_in_memory("bench-groups").expect("index opens");
            for group in 0..100 {
                index
                    .insert_duplicate_group(
                        &format!("digest-{group}"),
                        1024 * 1024,
                        black_box(&members),
                    )
                    .expect("group insert succeeds");
            }
            black_box(index.duplicate_group_count().expect("count"))
        })
    });

    group.finish();
}

criterion_group!(
    benches,
    bench_directory_metadata,
    bench_partial_comparison,
    bench_full_hash,
    bench_index_insert
);
criterion_main!(benches);
