//! The scan result index.
//!
//! The specification requires the Rust side to own the full scan result set and
//! to hand Swift only summary pages, so that scanning a large disk never builds a
//! giant object graph on the Swift side. This crate is that store.
//!
//! Storage rules it enforces:
//!
//! * only paths, sizes, dates, categories and digests are persisted — never file
//!   contents,
//! * the database lives in the app's own data directory,
//! * every row carries `session_id`, so a stale page request cannot leak results
//!   from an earlier scan.

use rusqlite::{params, Connection, OptionalExtension};
use std::collections::HashMap;
use std::path::Path;

/// Schema version of the index database. Bumping it forces a rebuild.
pub const INDEX_SCHEMA_VERSION: i64 = 1;

/// Default page size for `page_items` requests.
pub const DEFAULT_PAGE_SIZE: u32 = 512;

/// A per-path row written in one call.
#[derive(Debug, Clone)]
pub struct ItemRow {
    pub path: String,
    pub display_name: String,
    pub parent_path: String,
    pub category: String,
    pub risk: String,
    pub size_bytes: i64,
    pub file_count: i64,
    pub explanation: String,
    pub explanation_key: String,
    pub rule_id: String,
    pub bundle_id: Option<String>,
    pub modified_secs: i64,
    pub created_secs: i64,
    pub is_directory: bool,
    pub is_restorable: bool,
    pub is_selected_by_default: bool,
    pub resolve_warning: Option<String>,
}

impl ItemRow {
    /// Stable category ordering, used by the default page sort.
    pub fn category_order(category: &str) -> u8 {
        match category {
            "applicationCache" => 0,
            "logs" => 1,
            "installers" => 2,
            "temporaryFiles" => 3,
            "applicationResidue" => 4,
            "largeFiles" => 5,
            "oldFiles" => 6,
            "duplicateFiles" => 7,
            "groupContainerResidue" => 8,
            _ => 9,
        }
    }
}

/// A row of the `items` table as handed back to callers.
#[derive(Debug, Clone, PartialEq)]
pub struct ItemRecord {
    pub row_id: i64,
    pub path: String,
    pub display_name: String,
    pub parent_path: String,
    pub category: String,
    pub risk: String,
    pub size_bytes: i64,
    pub file_count: i64,
    pub explanation: String,
    pub explanation_key: String,
    pub rule_id: String,
    pub bundle_id: Option<String>,
    pub modified_secs: i64,
    pub created_secs: i64,
    pub is_directory: bool,
    pub is_selected_by_default: bool,
}

/// One member of a duplicate group.
#[derive(Debug, Clone, PartialEq)]
pub struct GroupMemberRow {
    pub path: String,
    pub size_bytes: i64,
    pub modified_secs: i64,
    pub keep: bool,
}

/// Rollups used by the dashboard and result headers.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct SummaryTotals {
    pub item_count: i64,
    pub total_bytes: i64,
    pub file_count: i64,
    pub category_count: i64,
    pub protected_count: i64,
}

/// A duplicate group header.
#[derive(Debug, Clone, PartialEq)]
pub struct GroupRecord {
    pub group_id: i64,
    pub digest: String,
    pub size_bytes: i64,
    pub member_count: i64,
    pub reclaimable_bytes: i64,
}

/// Sort orders supported by the paging interface.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScanSort {
    Size,
    Name,
    Modified,
    Category,
}

impl ScanSort {
    pub fn parse(value: &str) -> Self {
        match value {
            "name" => ScanSort::Name,
            "modified" => ScanSort::Modified,
            "category" => ScanSort::Category,
            _ => ScanSort::Size,
        }
    }

    fn order_by(self) -> &'static str {
        match self {
            ScanSort::Size => "size_bytes DESC, path ASC",
            ScanSort::Name => "display_name COLLATE NOCASE ASC, path ASC",
            ScanSort::Modified => "modified_secs DESC, path ASC",
            ScanSort::Category => "category_order ASC, size_bytes DESC, path ASC",
        }
    }
}

/// Index failures. Every variant maps to a stable FFI error code.
#[derive(Debug, thiserror::Error)]
pub enum IndexError {
    #[error("index database error: {0}")]
    Database(#[from] rusqlite::Error),
    #[error("index schema version {found} is not supported (expected {expected})")]
    SchemaMismatch { found: i64, expected: i64 },
}

/// Handle to a scan result database.
pub struct FileIndex {
    connection: Connection,
    session_id: String,
}

impl std::fmt::Debug for FileIndex {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("FileIndex")
            .field("session_id", &self.session_id)
            .finish_non_exhaustive()
    }
}

impl FileIndex {
    /// Opens (creating if needed) the index for one scan session.
    pub fn open<P: AsRef<Path>>(path: P, session_id: &str) -> Result<Self, IndexError> {
        let connection = Connection::open(path)?;
        Self::configure(&connection)?;
        let index = Self {
            connection,
            session_id: session_id.to_string(),
        };
        index.migrate()?;
        Ok(index)
    }

    /// In-memory index, used by tests and by the FFI layer's dry-run mode.
    pub fn open_in_memory(session_id: &str) -> Result<Self, IndexError> {
        let connection = Connection::open_in_memory()?;
        Self::configure(&connection)?;
        let index = Self {
            connection,
            session_id: session_id.to_string(),
        };
        index.migrate()?;
        Ok(index)
    }

    fn configure(connection: &Connection) -> Result<(), IndexError> {
        connection.pragma_update(None, "journal_mode", "WAL")?;
        connection.pragma_update(None, "synchronous", "NORMAL")?;
        connection.pragma_update(None, "temp_store", "MEMORY")?;
        connection.pragma_update(None, "foreign_keys", "ON")?;
        Ok(())
    }

    fn migrate(&self) -> Result<(), IndexError> {
        self.connection.execute_batch(
            "BEGIN;
             CREATE TABLE IF NOT EXISTS meta (
                 key TEXT PRIMARY KEY,
                 value TEXT NOT NULL
             );
             CREATE TABLE IF NOT EXISTS items (
                 row_id INTEGER PRIMARY KEY AUTOINCREMENT,
                 session_id TEXT NOT NULL,
                 path TEXT NOT NULL,
                 display_name TEXT NOT NULL,
                 parent_path TEXT NOT NULL,
                 category TEXT NOT NULL,
                 category_order INTEGER NOT NULL,
                 risk TEXT NOT NULL,
                 size_bytes INTEGER NOT NULL,
                 file_count INTEGER NOT NULL,
                 explanation TEXT NOT NULL,
                 explanation_key TEXT NOT NULL,
                 rule_id TEXT NOT NULL,
                 bundle_id TEXT,
                 modified_secs INTEGER NOT NULL,
                 created_secs INTEGER NOT NULL,
                 is_directory INTEGER NOT NULL,
                 is_restorable INTEGER NOT NULL,
                 is_selected_by_default INTEGER NOT NULL,
                 resolve_warning TEXT
             );
             CREATE INDEX IF NOT EXISTS items_session_size
                 ON items(session_id, size_bytes DESC);
             CREATE INDEX IF NOT EXISTS items_session_category
                 ON items(session_id, category_order, size_bytes DESC);
             CREATE UNIQUE INDEX IF NOT EXISTS items_session_path
                 ON items(session_id, path);
             CREATE TABLE IF NOT EXISTS duplicate_groups (
                 group_id INTEGER PRIMARY KEY AUTOINCREMENT,
                 session_id TEXT NOT NULL,
                 digest TEXT NOT NULL,
                 size_bytes INTEGER NOT NULL,
                 member_count INTEGER NOT NULL,
                 reclaimable_bytes INTEGER NOT NULL
             );
             CREATE INDEX IF NOT EXISTS groups_session_size
                 ON duplicate_groups(session_id, reclaimable_bytes DESC);
             CREATE TABLE IF NOT EXISTS duplicate_members (
                 member_id INTEGER PRIMARY KEY AUTOINCREMENT,
                 group_id INTEGER NOT NULL REFERENCES duplicate_groups(group_id) ON DELETE CASCADE,
                 path TEXT NOT NULL,
                 size_bytes INTEGER NOT NULL,
                 modified_secs INTEGER NOT NULL,
                 keep INTEGER NOT NULL
             );
             CREATE INDEX IF NOT EXISTS members_group ON duplicate_members(group_id);
             CREATE TABLE IF NOT EXISTS skipped (
                 skip_id INTEGER PRIMARY KEY AUTOINCREMENT,
                 session_id TEXT NOT NULL,
                 path TEXT NOT NULL,
                 reason_code TEXT NOT NULL,
                 message TEXT NOT NULL,
                 byte_count INTEGER NOT NULL
             );
             CREATE INDEX IF NOT EXISTS skipped_session ON skipped(session_id);
             COMMIT;",
        )?;

        let existing: Option<String> = self
            .connection
            .query_row(
                "SELECT value FROM meta WHERE key = 'schema_version'",
                [],
                |row| row.get(0),
            )
            .optional()?;
        match existing {
            Some(value) => {
                let found: i64 = value.parse().unwrap_or(-1);
                if found != INDEX_SCHEMA_VERSION {
                    return Err(IndexError::SchemaMismatch {
                        found,
                        expected: INDEX_SCHEMA_VERSION,
                    });
                }
            }
            None => {
                self.connection.execute(
                    "INSERT INTO meta(key, value) VALUES('schema_version', ?1)",
                    params![INDEX_SCHEMA_VERSION.to_string()],
                )?;
            }
        }
        Ok(())
    }

    pub fn session_id(&self) -> &str {
        &self.session_id
    }

    /// Drops everything belonging to earlier sessions.
    pub fn reset(&self) -> Result<(), IndexError> {
        self.connection.execute_batch(
            "DELETE FROM duplicate_members;
             DELETE FROM duplicate_groups;
             DELETE FROM items;
             DELETE FROM skipped;",
        )?;
        Ok(())
    }

    /// Inserts a batch inside a single transaction.
    ///
    /// The unique index on `(session_id, path)` makes this idempotent: a path
    /// reached twice (for example through a rule overlap) replaces its earlier
    /// row instead of duplicating it in the result list.
    pub fn insert_items(&mut self, rows: &[ItemRow]) -> Result<u64, IndexError> {
        if rows.is_empty() {
            return Ok(0);
        }
        let transaction = self.connection.transaction()?;
        {
            let mut statement = transaction.prepare_cached(
                "INSERT INTO items (
                    session_id, path, display_name, parent_path, category, category_order,
                    risk, size_bytes, file_count, explanation, explanation_key, rule_id,
                    bundle_id, modified_secs, created_secs, is_directory, is_restorable,
                    is_selected_by_default, resolve_warning
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19)
                 ON CONFLICT(session_id, path) DO UPDATE SET
                    display_name = excluded.display_name,
                    parent_path = excluded.parent_path,
                    size_bytes = excluded.size_bytes,
                    file_count = excluded.file_count,
                    risk = excluded.risk,
                    category = excluded.category,
                    category_order = excluded.category_order,
                    bundle_id = excluded.bundle_id,
                    modified_secs = excluded.modified_secs,
                    created_secs = excluded.created_secs,
                    is_directory = excluded.is_directory,
                    explanation = excluded.explanation,
                    explanation_key = excluded.explanation_key,
                    rule_id = excluded.rule_id,
                    is_selected_by_default = excluded.is_selected_by_default;",
            )?;
            for row in rows {
                statement.execute(params![
                    self.session_id,
                    row.path,
                    row.display_name,
                    row.parent_path,
                    row.category,
                    ItemRow::category_order(&row.category) as i64,
                    row.risk,
                    row.size_bytes,
                    row.file_count,
                    row.explanation,
                    row.explanation_key,
                    row.rule_id,
                    row.bundle_id,
                    row.modified_secs,
                    row.created_secs,
                    row.is_directory as i64,
                    row.is_restorable as i64,
                    row.is_selected_by_default as i64,
                    row.resolve_warning,
                ])?;
            }
        }
        transaction.commit()?;
        Ok(rows.len() as u64)
    }

    /// Adds one skipped location.
    pub fn insert_skipped(
        &self,
        path: &str,
        reason_code: &str,
        message: &str,
        byte_count: i64,
    ) -> Result<(), IndexError> {
        self.connection.execute(
            "INSERT INTO skipped(session_id, path, reason_code, message, byte_count)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![self.session_id, path, reason_code, message, byte_count],
        )?;
        Ok(())
    }

    /// Stores a duplicate group plus its members in one transaction.
    pub fn insert_duplicate_group(
        &mut self,
        digest: &str,
        size_bytes: i64,
        members: &[GroupMemberRow],
    ) -> Result<i64, IndexError> {
        let reclaimable: i64 = members
            .iter()
            .filter(|m| !m.keep)
            .map(|m| m.size_bytes)
            .sum();
        let transaction = self.connection.transaction()?;
        transaction.execute(
            "INSERT INTO duplicate_groups(session_id, digest, size_bytes, member_count, reclaimable_bytes)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![
                self.session_id,
                digest,
                size_bytes,
                members.len() as i64,
                reclaimable
            ],
        )?;
        let group_id = transaction.last_insert_rowid();
        {
            let mut statement = transaction.prepare_cached(
                "INSERT INTO duplicate_members(group_id, path, size_bytes, modified_secs, keep)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
            )?;
            for member in members {
                statement.execute(params![
                    group_id,
                    member.path,
                    member.size_bytes,
                    member.modified_secs,
                    member.keep as i64
                ])?;
            }
        }
        transaction.commit()?;
        Ok(group_id)
    }

    /// Total number of indexed cleanup items for this session.
    pub fn item_count(&self) -> Result<i64, IndexError> {
        let count = self.connection.query_row(
            "SELECT COUNT(*) FROM items WHERE session_id = ?1",
            params![self.session_id],
            |row| row.get(0),
        )?;
        Ok(count)
    }

    /// One page of results.
    pub fn page_items(
        &self,
        offset: u32,
        limit: u32,
        sort: ScanSort,
        category: Option<&str>,
    ) -> Result<Vec<ItemRecord>, IndexError> {
        let limit = if limit == 0 { DEFAULT_PAGE_SIZE } else { limit };
        let sql = format!(
            "SELECT row_id, path, display_name, parent_path, category, risk, size_bytes,
                    file_count, explanation, explanation_key, rule_id, bundle_id,
                    modified_secs, created_secs, is_directory, is_selected_by_default
             FROM items
             WHERE session_id = ?1 AND (?2 IS NULL OR category = ?2)
             ORDER BY {}
             LIMIT ?3 OFFSET ?4",
            sort.order_by()
        );
        let mut statement = self.connection.prepare(&sql)?;
        let rows =
            statement.query_map(params![self.session_id, category, limit, offset], |row| {
                Ok(ItemRecord {
                    row_id: row.get(0)?,
                    path: row.get(1)?,
                    display_name: row.get(2)?,
                    parent_path: row.get(3)?,
                    category: row.get(4)?,
                    risk: row.get(5)?,
                    size_bytes: row.get(6)?,
                    file_count: row.get(7)?,
                    explanation: row.get(8)?,
                    explanation_key: row.get(9)?,
                    rule_id: row.get(10)?,
                    bundle_id: row.get(11)?,
                    modified_secs: row.get(12)?,
                    created_secs: row.get(13)?,
                    is_directory: row.get::<_, i64>(14)? != 0,
                    is_selected_by_default: row.get::<_, i64>(15)? != 0,
                })
            })?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }

    /// Number of rows matching the same filter `page_items` applies.
    pub fn count_items(&self, category: Option<&str>) -> Result<i64, IndexError> {
        let count = self.connection.query_row(
            "SELECT COUNT(*) FROM items WHERE session_id = ?1 AND (?2 IS NULL OR category = ?2)",
            params![self.session_id, category],
            |row| row.get(0),
        )?;
        Ok(count)
    }

    /// Aggregate row for the whole session.
    pub fn summary(&self) -> Result<SummaryTotals, IndexError> {
        let totals = self.connection.query_row(
            "SELECT COUNT(*), COALESCE(SUM(size_bytes), 0), COALESCE(SUM(file_count), 0),
                    COUNT(DISTINCT category),
                    COALESCE(SUM(CASE WHEN risk = 'protected' THEN 1 ELSE 0 END), 0)
             FROM items WHERE session_id = ?1",
            params![self.session_id],
            |row| {
                Ok(SummaryTotals {
                    item_count: row.get(0)?,
                    total_bytes: row.get(1)?,
                    file_count: row.get(2)?,
                    category_count: row.get(3)?,
                    protected_count: row.get(4)?,
                })
            },
        )?;
        Ok(totals)
    }

    /// Per-category rollup: `(category, item_count, total_bytes)`.
    pub fn category_totals(&self) -> Result<Vec<(String, i64, i64)>, IndexError> {
        let mut statement = self.connection.prepare(
            "SELECT category, COUNT(*), COALESCE(SUM(size_bytes), 0)
             FROM items WHERE session_id = ?1
             GROUP BY category ORDER BY category_order ASC, SUM(size_bytes) DESC",
        )?;
        let rows = statement.query_map(params![self.session_id], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?))
        })?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }

    /// Pages duplicate groups, largest reclaimable first.
    pub fn page_duplicate_groups(
        &self,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<GroupRecord>, IndexError> {
        let limit = if limit == 0 { DEFAULT_PAGE_SIZE } else { limit };
        let mut statement = self.connection.prepare(
            "SELECT group_id, digest, size_bytes, member_count, reclaimable_bytes
             FROM duplicate_groups WHERE session_id = ?1
             ORDER BY reclaimable_bytes DESC, group_id ASC
             LIMIT ?2 OFFSET ?3",
        )?;
        let rows = statement.query_map(params![self.session_id, limit, offset], |row| {
            Ok(GroupRecord {
                group_id: row.get(0)?,
                digest: row.get(1)?,
                size_bytes: row.get(2)?,
                member_count: row.get(3)?,
                reclaimable_bytes: row.get(4)?,
            })
        })?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }

    /// One page of members of a duplicate group, in display order.
    ///
    /// Paging is explicit: a group can hold thousands of copies, and returning
    /// them all in one call would both allocate without bound and make the FFI
    /// caller re-read the same page (the defect this signature fixes).
    pub fn duplicate_members(
        &self,
        group_id: i64,
        offset: u32,
        limit: u32,
    ) -> Result<Vec<GroupMemberRow>, IndexError> {
        let limit = if limit == 0 { DEFAULT_PAGE_SIZE } else { limit };
        let mut statement = self.connection.prepare(
            "SELECT path, size_bytes, modified_secs, keep
             FROM duplicate_members WHERE group_id = ?1
             ORDER BY keep DESC, modified_secs ASC, path ASC
             LIMIT ?2 OFFSET ?3",
        )?;
        let rows = statement.query_map(params![group_id, limit, offset], |row| {
            Ok(GroupMemberRow {
                path: row.get(0)?,
                size_bytes: row.get(1)?,
                modified_secs: row.get(2)?,
                keep: row.get::<_, i64>(3)? != 0,
            })
        })?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }

    pub fn duplicate_group_count(&self) -> Result<i64, IndexError> {
        let count = self.connection.query_row(
            "SELECT COUNT(*) FROM duplicate_groups WHERE session_id = ?1",
            params![self.session_id],
            |row| row.get(0),
        )?;
        Ok(count)
    }

    pub fn duplicate_reclaimable_bytes(&self) -> Result<i64, IndexError> {
        let total = self.connection.query_row(
            "SELECT COALESCE(SUM(reclaimable_bytes), 0) FROM duplicate_groups WHERE session_id = ?1",
            params![self.session_id],
            |row| row.get(0),
        )?;
        Ok(total)
    }

    /// Skipped locations with their reasons, for the "partial" state UI.
    pub fn skipped_locations(&self) -> Result<Vec<(String, String, String, i64)>, IndexError> {
        let mut statement = self.connection.prepare(
            "SELECT path, reason_code, message, byte_count FROM skipped WHERE session_id = ?1",
        )?;
        let rows = statement.query_map(params![self.session_id], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
        })?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }

    /// Count of items per rule, used to prove rules match what the docs claim.
    pub fn counts_by_rule(&self) -> Result<HashMap<String, i64>, IndexError> {
        let mut statement = self.connection.prepare(
            "SELECT rule_id, COUNT(*) FROM items WHERE session_id = ?1 GROUP BY rule_id",
        )?;
        let rows = statement.query_map(params![self.session_id], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
        })?;
        let mut out = HashMap::new();
        for row in rows {
            let (rule, count) = row?;
            out.insert(rule, count);
        }
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(path: &str, category: &str, size: i64, risk: &str) -> ItemRow {
        ItemRow {
            path: path.to_string(),
            display_name: path.rsplit('/').next().unwrap_or(path).to_string(),
            parent_path: path
                .rsplit_once('/')
                .map(|(p, _)| p)
                .unwrap_or("")
                .to_string(),
            category: category.to_string(),
            risk: risk.to_string(),
            size_bytes: size,
            file_count: 1,
            explanation: "because".to_string(),
            explanation_key: "cleanup.x.explanation".to_string(),
            rule_id: "user-cache".to_string(),
            bundle_id: None,
            modified_secs: 1_700_000_000,
            created_secs: 1_600_000_000,
            is_directory: true,
            is_restorable: true,
            is_selected_by_default: risk == "safe",
            resolve_warning: None,
        }
    }

    fn index() -> FileIndex {
        FileIndex::open_in_memory("session-1").expect("index opens")
    }

    #[test]
    fn schema_version_is_recorded_on_first_open() {
        let index = index();
        let version: String = index
            .connection
            .query_row(
                "SELECT value FROM meta WHERE key = 'schema_version'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(version, INDEX_SCHEMA_VERSION.to_string());
    }

    #[test]
    fn inserting_a_path_twice_updates_instead_of_duplicating() {
        let mut index = index();
        index
            .insert_items(&[row("/a/b", "applicationCache", 100, "safe")])
            .unwrap();
        index
            .insert_items(&[row("/a/b", "applicationCache", 250, "review")])
            .unwrap();
        assert_eq!(index.item_count().unwrap(), 1);
        let page = index.page_items(0, 10, ScanSort::Size, None).unwrap();
        assert_eq!(page[0].size_bytes, 250);
        assert_eq!(page[0].risk, "review");
    }

    #[test]
    fn a_later_row_updates_the_bundle_id_it_adds() {
        let mut index = index();
        index
            .insert_items(&[row("/a/b", "applicationCache", 100, "safe")])
            .unwrap();
        let mut residue = row("/a/b", "applicationResidue", 100, "review");
        residue.bundle_id = Some("com.example.app".to_string());
        index.insert_items(&[residue]).unwrap();
        let page = index.page_items(0, 10, ScanSort::Size, None).unwrap();
        assert_eq!(page[0].bundle_id.as_deref(), Some("com.example.app"));
        assert_eq!(page[0].category, "applicationResidue");
    }

    #[test]
    fn paging_is_stable_and_ordered_by_size() {
        let mut index = index();
        let rows: Vec<ItemRow> = (0..25)
            .map(|i| row(&format!("/x/{i}"), "logs", i * 10, "safe"))
            .collect();
        index.insert_items(&rows).unwrap();

        let first = index.page_items(0, 10, ScanSort::Size, None).unwrap();
        let second = index.page_items(10, 10, ScanSort::Size, None).unwrap();
        assert_eq!(first.len(), 10);
        assert_eq!(second.len(), 10);
        assert_eq!(first[0].size_bytes, 240);
        assert_eq!(second[0].size_bytes, 140);
        let mut all: Vec<i64> = first
            .iter()
            .chain(second.iter())
            .map(|r| r.size_bytes)
            .collect();
        all.sort_unstable_by(|a, b| b.cmp(a));
        // The two pages cover the 20 largest rows: sizes 240 down to 50.
        let expected: Vec<i64> = (5..25).rev().map(|i| i * 10).collect();
        assert_eq!(all, expected);
    }

    #[test]
    fn default_limit_applies_when_zero_requested() {
        let mut index = index();
        let rows: Vec<ItemRow> = (0..600)
            .map(|i| row(&format!("/y/{i}"), "logs", i, "safe"))
            .collect();
        index.insert_items(&rows).unwrap();
        let page = index.page_items(0, 0, ScanSort::Size, None).unwrap();
        assert_eq!(page.len(), DEFAULT_PAGE_SIZE as usize);
    }

    #[test]
    fn category_filter_isolates_one_category() {
        let mut index = index();
        index
            .insert_items(&[
                row("/c/a", "applicationCache", 10, "safe"),
                row("/l/a", "logs", 20, "safe"),
            ])
            .unwrap();
        let filtered = index
            .page_items(0, 10, ScanSort::Size, Some("logs"))
            .unwrap();
        assert_eq!(filtered.len(), 1);
        assert_eq!(filtered[0].category, "logs");
    }

    #[test]
    fn count_items_honours_the_category_filter() {
        let mut index = index();
        index
            .insert_items(&[
                row("/c/a", "applicationCache", 10, "safe"),
                row("/l/a", "logs", 20, "safe"),
                row("/l/b", "logs", 30, "safe"),
            ])
            .unwrap();
        assert_eq!(index.count_items(None).unwrap(), 3);
        assert_eq!(index.count_items(Some("logs")).unwrap(), 2);
        assert_eq!(index.count_items(Some("installers")).unwrap(), 0);
    }

    #[test]
    fn summary_reports_totals_files_and_protected_counts() {
        let mut index = index();
        index
            .insert_items(&[
                row("/a", "applicationCache", 100, "safe"),
                row("/b", "logs", 200, "safe"),
                row("/c", "installers", 300, "protected"),
            ])
            .unwrap();
        let summary = index.summary().unwrap();
        assert_eq!(summary.item_count, 3);
        assert_eq!(summary.total_bytes, 600);
        assert_eq!(summary.file_count, 3);
        assert_eq!(summary.category_count, 3);
        assert_eq!(summary.protected_count, 1);
    }

    #[test]
    fn category_totals_follow_the_display_order() {
        let mut index = index();
        index
            .insert_items(&[
                row("/i", "installers", 500, "review"),
                row("/c", "applicationCache", 100, "safe"),
                row("/l", "logs", 200, "safe"),
            ])
            .unwrap();
        let totals = index.category_totals().unwrap();
        let order: Vec<&str> = totals.iter().map(|(c, _, _)| c.as_str()).collect();
        assert_eq!(order, vec!["applicationCache", "logs", "installers"]);
    }

    #[test]
    fn duplicate_groups_store_reclaimable_size_and_members() {
        let mut index = index();
        let members = vec![
            GroupMemberRow {
                path: "/dup/keep.bin".into(),
                size_bytes: 1000,
                modified_secs: 100,
                keep: true,
            },
            GroupMemberRow {
                path: "/dup/copy1.bin".into(),
                size_bytes: 1000,
                modified_secs: 200,
                keep: false,
            },
            GroupMemberRow {
                path: "/dup/copy2.bin".into(),
                size_bytes: 1000,
                modified_secs: 300,
                keep: false,
            },
        ];
        let group_id = index
            .insert_duplicate_group("digest-1", 1000, &members)
            .unwrap();
        let groups = index.page_duplicate_groups(0, 10).unwrap();
        assert_eq!(groups.len(), 1);
        assert_eq!(groups[0].group_id, group_id);
        assert_eq!(groups[0].member_count, 3);
        assert_eq!(groups[0].reclaimable_bytes, 2000);
        assert_eq!(index.duplicate_reclaimable_bytes().unwrap(), 2000);

        let stored = index.duplicate_members(group_id, 0, 100).unwrap();
        assert_eq!(stored.len(), 3);
        assert!(stored[0].keep, "the kept member sorts first");
    }

    #[test]
    fn duplicate_groups_page_largest_reclaimable_first() {
        let mut index = index();
        let members = |keep_path: &str, copy_path: &str, size: i64| {
            vec![
                GroupMemberRow {
                    path: keep_path.into(),
                    size_bytes: size,
                    modified_secs: 1,
                    keep: true,
                },
                GroupMemberRow {
                    path: copy_path.into(),
                    size_bytes: size,
                    modified_secs: 2,
                    keep: false,
                },
            ]
        };
        index
            .insert_duplicate_group("small", 10, &members("/k1", "/c1", 10))
            .unwrap();
        index
            .insert_duplicate_group("big", 90, &members("/k2", "/c2", 90))
            .unwrap();
        let groups = index.page_duplicate_groups(0, 10).unwrap();
        assert_eq!(groups[0].digest, "big");
        assert_eq!(groups[0].reclaimable_bytes, 90);
    }

    #[test]
    fn duplicate_members_page_without_repeating_rows() {
        let mut index = index();
        let members: Vec<GroupMemberRow> = (0..520)
            .map(|member| GroupMemberRow {
                path: format!("/dup/copy-{member:04}.bin"),
                size_bytes: 1024,
                modified_secs: 1_700_000_000,
                keep: member == 0,
            })
            .collect();
        let group_id = index
            .insert_duplicate_group("digest", 1024, &members)
            .unwrap();

        let first = index.duplicate_members(group_id, 0, 512).unwrap();
        let second = index.duplicate_members(group_id, 512, 512).unwrap();
        assert_eq!(first.len(), 512);
        assert_eq!(
            second.len(),
            8,
            "the second page is the remainder, not a repeat"
        );
        let first_paths: std::collections::HashSet<&str> =
            first.iter().map(|row| row.path.as_str()).collect();
        assert!(
            second
                .iter()
                .all(|row| !first_paths.contains(row.path.as_str())),
            "pages must not overlap"
        );
    }

    #[test]
    fn skipped_locations_keep_their_reason_code() {
        let index = index();
        index
            .insert_skipped("/private/var/db/x", "permissionDenied", "no access", 0)
            .unwrap();
        let skipped = index.skipped_locations().unwrap();
        assert_eq!(skipped.len(), 1);
        assert_eq!(skipped[0].1, "permissionDenied");
    }

    #[test]
    fn reset_clears_every_table_but_keeps_the_schema() {
        let mut index = index();
        index.insert_items(&[row("/a", "logs", 1, "safe")]).unwrap();
        index
            .insert_skipped("/b", "permissionDenied", "x", 0)
            .unwrap();
        index.reset().unwrap();
        assert_eq!(index.item_count().unwrap(), 0);
        assert!(index.skipped_locations().unwrap().is_empty());
        assert_eq!(index.duplicate_group_count().unwrap(), 0);
    }

    #[test]
    fn opening_a_foreign_schema_version_fails_loudly() {
        let path = std::env::temp_dir().join(format!(
            "sift-index-version-{}-{}.sqlite",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        {
            let connection = Connection::open(&path).unwrap();
            connection
                .execute_batch("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);")
                .unwrap();
            connection
                .execute(
                    "INSERT INTO meta(key, value) VALUES('schema_version', '99')",
                    [],
                )
                .unwrap();
        }
        let result = FileIndex::open(&path, "s");
        assert!(matches!(
            result,
            Err(IndexError::SchemaMismatch { found: 99, .. })
        ));
    }

    #[test]
    fn sort_parser_defaults_to_size_for_unknown_input() {
        assert_eq!(ScanSort::parse("name"), ScanSort::Name);
        assert_eq!(ScanSort::parse("modified"), ScanSort::Modified);
        assert_eq!(ScanSort::parse("category"), ScanSort::Category);
        assert_eq!(ScanSort::parse("nonsense"), ScanSort::Size);
    }

    #[test]
    fn counts_by_rule_groups_rows() {
        let mut index = index();
        let mut a = row("/a", "logs", 1, "safe");
        a.rule_id = "user-logs".into();
        let mut b = row("/b", "logs", 1, "safe");
        b.rule_id = "user-logs".into();
        let mut c = row("/c", "applicationCache", 1, "safe");
        c.rule_id = "user-cache".into();
        index.insert_items(&[a, b, c]).unwrap();
        let counts = index.counts_by_rule().unwrap();
        assert_eq!(counts.get("user-logs"), Some(&2));
        assert_eq!(counts.get("user-cache"), Some(&1));
    }
}
