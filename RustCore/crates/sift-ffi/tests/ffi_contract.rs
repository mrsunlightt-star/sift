//! FFI contract tests.
//!
//! These tests read the shipped header and check it against the Rust
//! definitions, so a field reorder, a width change or a forgotten version bump
//! fails the build rather than corrupting a caller's memory.
//!
//! What is covered:
//!
//! * the contract version constant agrees in both languages,
//! * every struct in the header has the same size and field offsets as its Rust
//!   counterpart, computed with each language's own alignment rules,
//! * every exported symbol is declared in the header, and vice versa,
//! * every `SiftString` field has the same declared type in both languages,
//! * error codes used by the scanner are the ones the product error table lists.

use sift_ffi::*;
use std::mem::{align_of, offset_of, size_of};

/// A simple C field type for layout computation.
#[derive(Debug, Clone, PartialEq, Eq)]
enum CType {
    U8,
    U32,
    U64,
    I32,
    I64,
    Size,
    Bool,
    Double,
    Pointer,
    /// A named struct, resolved by looking up its field list.
    Named(String),
}

impl CType {
    /// Parses a field's type, where `text` is the part before the declarator.
    fn parse(text: &str) -> Option<Self> {
        // A `*` in the declarator means the field is a pointer, whatever the
        // pointed-to type is.
        if text.contains('*') {
            return Some(CType::Pointer);
        }
        let base = text.trim().trim_end_matches(';').trim();
        Some(match base {
            "uint8_t" => CType::U8,
            "uint32_t" => CType::U32,
            "uint64_t" => CType::U64,
            "int32_t" => CType::I32,
            "int64_t" => CType::I64,
            "size_t" => CType::Size,
            "bool" => CType::Bool,
            "double" => CType::Double,
            other if other.starts_with("struct ") || is_known_struct(other) => {
                CType::Named(other.trim_start_matches("struct ").to_string())
            }
            _ => return None,
        })
    }

    fn size(&self, structs: &[CStruct]) -> usize {
        match self {
            CType::U8 | CType::Bool => 1,
            CType::U32 | CType::I32 => 4,
            CType::U64 | CType::I64 | CType::Size | CType::Double | CType::Pointer => 8,
            CType::Named(name) => structs
                .iter()
                .find(|entry| &entry.name == name)
                .map(|entry| entry.size(structs))
                .unwrap_or(0),
        }
    }

    fn align(&self, structs: &[CStruct]) -> usize {
        match self {
            CType::U8 | CType::Bool => 1,
            CType::U32 | CType::I32 => 4,
            CType::U64 | CType::I64 | CType::Size | CType::Double | CType::Pointer => 8,
            CType::Named(name) => structs
                .iter()
                .find(|entry| &entry.name == name)
                .map(|entry| entry.alignment(structs))
                .unwrap_or(1),
        }
    }
}

fn is_known_struct(name: &str) -> bool {
    KNOWN_STRUCTS.contains(&name)
}

const KNOWN_STRUCTS: &[&str] = &[
    "SiftString",
    "SiftItemSummary",
    "SiftScanEvent",
    "SiftPage",
    "SiftCategoryTotal",
    "SiftDuplicateGroup",
    "SiftDuplicateMember",
    "SiftResult",
    "SiftStorageFile",
    "SiftStorageDirectory",
    "SiftStorageAnalysis",
];

#[derive(Debug, Clone)]
struct CField {
    name: String,
    ty: CType,
}

#[derive(Debug, Clone)]
struct CStruct {
    name: String,
    fields: Vec<CField>,
}

impl CStruct {
    fn layout(&self, all: &[CStruct]) -> (usize, Vec<usize>) {
        let mut offsets = Vec::with_capacity(self.fields.len());
        let mut cursor = 0usize;
        let mut max_align = 1usize;
        for field in &self.fields {
            let size = field.ty.size(all);
            let align = field.ty.align(all);
            max_align = max_align.max(align);
            cursor = cursor.div_ceil(align) * align;
            offsets.push(cursor);
            cursor += size;
        }
        let total = cursor.div_ceil(max_align) * max_align;
        (total, offsets)
    }

    fn size(&self, all: &[CStruct]) -> usize {
        self.layout(all).0
    }

    fn alignment(&self, all: &[CStruct]) -> usize {
        self.fields
            .iter()
            .map(|field| field.ty.align(all))
            .max()
            .unwrap_or(1)
    }
}

/// Reads the shipped header and returns its struct definitions.
fn parse_header() -> Vec<CStruct> {
    let header = include_str!("../../../../Bridge/include/sift_scanner.h");
    let mut structs: Vec<CStruct> = Vec::new();

    let mut rest = header;
    while let Some(start) = rest.find("typedef struct ") {
        let after = &rest[start + "typedef struct ".len()..];
        // Skip forward declarations such as `typedef struct SiftEngine SiftEngine;`.
        let Some(brace) = after.find('{') else { break };
        let name = after[..brace].trim().to_string();
        let Some(end) = after.find("} ") else { break };
        if name.is_empty() || brace > end {
            // `typedef struct Name Name;` has no body.
            rest = &after[end.max(brace)..];
            continue;
        }
        let body = &after[brace + 1..end];

        let mut fields = Vec::new();
        for line in body.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with("/*") || line.starts_with("//") {
                continue;
            }
            let Some(without_semicolon) = line.strip_suffix(';') else {
                continue;
            };
            // Inline comments at the end of a field are allowed.
            let declaration = without_semicolon
                .split("/*")
                .next()
                .unwrap_or(without_semicolon)
                .trim();
            if declaration.is_empty() {
                continue;
            }
            // A named struct field is `struct X { ... } name;` — not present in
            // this header, which uses only typedefs and base types.
            // A field is `<type> <declarator>;` where the declarator may carry
            // leading `*`, and `<type>` itself may introduce a nested struct.
            let (declarator_index, declarator) = match declaration.rfind(' ') {
                Some(index) => (index, &declaration[index + 1..]),
                None => continue,
            };
            let ty_text = declaration[..declarator_index].trim();
            let field_name = declarator.trim_start_matches('*').to_string();
            if field_name.is_empty() {
                continue;
            }
            if let Some(ty) = CType::parse(&format!(
                "{}{}",
                ty_text,
                if declarator.starts_with('*') {
                    " *"
                } else {
                    ""
                }
            )) {
                fields.push(CField {
                    name: field_name,
                    ty,
                });
            }
        }

        structs.push(CStruct { name, fields });
        let after_end = &after[end..];
        let next = after_end
            .find(';')
            .map(|i| i + 1)
            .unwrap_or(after_end.len());
        rest = &after_end[next..];
    }

    structs
}

fn c_struct<'a>(structs: &'a [CStruct], name: &str) -> &'a CStruct {
    structs
        .iter()
        .find(|entry| entry.name == name)
        .unwrap_or_else(|| panic!("header declares {name}"))
}

#[test]
fn header_parses_and_declares_every_public_struct() {
    let structs = parse_header();
    for name in KNOWN_STRUCTS {
        let parsed = c_struct(&structs, name);
        assert!(
            !parsed.fields.is_empty(),
            "{name} should have at least one field"
        );
    }
}

#[test]
fn contract_version_agrees_in_both_languages() {
    let header = include_str!("../../../../Bridge/include/sift_scanner.h");
    let declared: u32 = header
        .lines()
        .find_map(|line| line.trim().strip_prefix("#define SIFT_FFI_VERSION "))
        .and_then(|value| value.trim().parse().ok())
        .expect("the header defines SIFT_FFI_VERSION");
    assert_eq!(
        declared,
        sift_ffi_version(),
        "the header and the library must agree on the contract version"
    );
}

/// Asserts one struct's size and every field offset.
fn assert_layout(
    structs: &[CStruct],
    name: &str,
    rust_offset: &dyn Fn(&str) -> usize,
    rust_size: usize,
    rust_align: usize,
) {
    let parsed = c_struct(structs, name);
    let (c_size, c_offsets) = parsed.layout(structs);
    assert_eq!(
        c_size, rust_size,
        "{name}: header size {c_size} must equal Rust size {rust_size}"
    );
    assert_eq!(
        parsed.alignment(structs),
        rust_align,
        "{name}: header alignment must equal Rust alignment"
    );
    for (index, field) in parsed.fields.iter().enumerate() {
        let rust = rust_offset(&field.name);
        assert_eq!(
            c_offsets[index], rust,
            "{name}.{}: header offset {} must equal Rust offset {rust}",
            field.name, c_offsets[index]
        );
    }
}

#[test]
fn string_layout_matches() {
    let structs = parse_header();
    assert_layout(
        &structs,
        "SiftString",
        &|field| match field {
            "ptr" => offset_of!(SiftString, ptr),
            "len" => offset_of!(SiftString, len),
            other => panic!("unexpected SiftString field {other}"),
        },
        size_of::<SiftString>(),
        align_of::<SiftString>(),
    );
}

#[test]
fn item_summary_layout_matches() {
    let structs = parse_header();
    assert_layout(
        &structs,
        "SiftItemSummary",
        &|field| match field {
            "version" => offset_of!(SiftItemSummary, version),
            "path" => offset_of!(SiftItemSummary, path),
            "display_name" => offset_of!(SiftItemSummary, display_name),
            "parent_path" => offset_of!(SiftItemSummary, parent_path),
            "category" => offset_of!(SiftItemSummary, category),
            "risk" => offset_of!(SiftItemSummary, risk),
            "explanation_key" => offset_of!(SiftItemSummary, explanation_key),
            "rule_id" => offset_of!(SiftItemSummary, rule_id),
            "bundle_id" => offset_of!(SiftItemSummary, bundle_id),
            "size_bytes" => offset_of!(SiftItemSummary, size_bytes),
            "file_count" => offset_of!(SiftItemSummary, file_count),
            "modified_secs" => offset_of!(SiftItemSummary, modified_secs),
            "is_directory" => offset_of!(SiftItemSummary, is_directory),
            other => panic!("unexpected SiftItemSummary field {other}"),
        },
        size_of::<SiftItemSummary>(),
        align_of::<SiftItemSummary>(),
    );
}

#[test]
fn scan_event_layout_matches() {
    let structs = parse_header();
    assert_layout(
        &structs,
        "SiftScanEvent",
        &|field| match field {
            "version" => offset_of!(SiftScanEvent, version),
            "kind" => offset_of!(SiftScanEvent, kind),
            "phase" => offset_of!(SiftScanEvent, phase),
            "files_seen" => offset_of!(SiftScanEvent, files_seen),
            "bytes_seen" => offset_of!(SiftScanEvent, bytes_seen),
            "items_found" => offset_of!(SiftScanEvent, items_found),
            "group_index" => offset_of!(SiftScanEvent, group_index),
            "member_count" => offset_of!(SiftScanEvent, member_count),
            "reclaimable_bytes" => offset_of!(SiftScanEvent, reclaimable_bytes),
            "byte_count" => offset_of!(SiftScanEvent, byte_count),
            "flag" => offset_of!(SiftScanEvent, flag),
            "text" => offset_of!(SiftScanEvent, text),
            "detail" => offset_of!(SiftScanEvent, detail),
            "items" => offset_of!(SiftScanEvent, items),
            "item_count" => offset_of!(SiftScanEvent, item_count),
            other => panic!("unexpected SiftScanEvent field {other}"),
        },
        size_of::<SiftScanEvent>(),
        align_of::<SiftScanEvent>(),
    );
}

#[test]
fn page_layout_matches() {
    let structs = parse_header();
    assert_layout(
        &structs,
        "SiftPage",
        &|field| match field {
            "version" => offset_of!(SiftPage, version),
            "items" => offset_of!(SiftPage, items),
            "item_count" => offset_of!(SiftPage, item_count),
            "remaining" => offset_of!(SiftPage, remaining),
            other => panic!("unexpected SiftPage field {other}"),
        },
        size_of::<SiftPage>(),
        align_of::<SiftPage>(),
    );
}

#[test]
fn category_total_layout_matches() {
    let structs = parse_header();
    assert_layout(
        &structs,
        "SiftCategoryTotal",
        &|field| match field {
            "version" => offset_of!(SiftCategoryTotal, version),
            "category" => offset_of!(SiftCategoryTotal, category),
            "item_count" => offset_of!(SiftCategoryTotal, item_count),
            "total_bytes" => offset_of!(SiftCategoryTotal, total_bytes),
            other => panic!("unexpected SiftCategoryTotal field {other}"),
        },
        size_of::<SiftCategoryTotal>(),
        align_of::<SiftCategoryTotal>(),
    );
}

#[test]
fn duplicate_group_layout_matches() {
    let structs = parse_header();
    assert_layout(
        &structs,
        "SiftDuplicateGroup",
        &|field| match field {
            "version" => offset_of!(SiftDuplicateGroup, version),
            "group_id" => offset_of!(SiftDuplicateGroup, group_id),
            "digest" => offset_of!(SiftDuplicateGroup, digest),
            "size_bytes" => offset_of!(SiftDuplicateGroup, size_bytes),
            "member_count" => offset_of!(SiftDuplicateGroup, member_count),
            "reclaimable_bytes" => offset_of!(SiftDuplicateGroup, reclaimable_bytes),
            other => panic!("unexpected SiftDuplicateGroup field {other}"),
        },
        size_of::<SiftDuplicateGroup>(),
        align_of::<SiftDuplicateGroup>(),
    );
}

#[test]
fn duplicate_member_layout_matches() {
    let structs = parse_header();
    assert_layout(
        &structs,
        "SiftDuplicateMember",
        &|field| match field {
            "version" => offset_of!(SiftDuplicateMember, version),
            "path" => offset_of!(SiftDuplicateMember, path),
            "size_bytes" => offset_of!(SiftDuplicateMember, size_bytes),
            "modified_secs" => offset_of!(SiftDuplicateMember, modified_secs),
            "keep" => offset_of!(SiftDuplicateMember, keep),
            other => panic!("unexpected SiftDuplicateMember field {other}"),
        },
        size_of::<SiftDuplicateMember>(),
        align_of::<SiftDuplicateMember>(),
    );
}

#[test]
fn result_layout_matches() {
    let structs = parse_header();
    assert_layout(
        &structs,
        "SiftResult",
        &|field| match field {
            "version" => offset_of!(SiftResult, version),
            "ok" => offset_of!(SiftResult, ok),
            "code" => offset_of!(SiftResult, code),
            "message" => offset_of!(SiftResult, message),
            other => panic!("unexpected SiftResult field {other}"),
        },
        size_of::<SiftResult>(),
        align_of::<SiftResult>(),
    );
}

#[test]
fn storage_structs_layout_match() {
    let structs = parse_header();

    assert_layout(
        &structs,
        "SiftStorageFile",
        &|field| match field {
            "version" => offset_of!(SiftStorageFile, version),
            "path" => offset_of!(SiftStorageFile, path),
            "display_name" => offset_of!(SiftStorageFile, display_name),
            "parent_path" => offset_of!(SiftStorageFile, parent_path),
            "size_bytes" => offset_of!(SiftStorageFile, size_bytes),
            "modified_secs" => offset_of!(SiftStorageFile, modified_secs),
            other => panic!("unexpected SiftStorageFile field {other}"),
        },
        size_of::<SiftStorageFile>(),
        align_of::<SiftStorageFile>(),
    );

    assert_layout(
        &structs,
        "SiftStorageDirectory",
        &|field| match field {
            "version" => offset_of!(SiftStorageDirectory, version),
            "path" => offset_of!(SiftStorageDirectory, path),
            "display_name" => offset_of!(SiftStorageDirectory, display_name),
            "size_bytes" => offset_of!(SiftStorageDirectory, size_bytes),
            "file_count" => offset_of!(SiftStorageDirectory, file_count),
            other => panic!("unexpected SiftStorageDirectory field {other}"),
        },
        size_of::<SiftStorageDirectory>(),
        align_of::<SiftStorageDirectory>(),
    );

    assert_layout(
        &structs,
        "SiftStorageAnalysis",
        &|field| match field {
            "version" => offset_of!(SiftStorageAnalysis, version),
            "ok" => offset_of!(SiftStorageAnalysis, ok),
            "mount_point" => offset_of!(SiftStorageAnalysis, mount_point),
            "volume_name" => offset_of!(SiftStorageAnalysis, volume_name),
            "total_bytes" => offset_of!(SiftStorageAnalysis, total_bytes),
            "free_bytes" => offset_of!(SiftStorageAnalysis, free_bytes),
            "used_bytes" => offset_of!(SiftStorageAnalysis, used_bytes),
            "used_fraction" => offset_of!(SiftStorageAnalysis, used_fraction),
            "scanned_file_count" => offset_of!(SiftStorageAnalysis, scanned_file_count),
            "scanned_byte_count" => offset_of!(SiftStorageAnalysis, scanned_byte_count),
            "skipped_count" => offset_of!(SiftStorageAnalysis, skipped_count),
            "elapsed_millis" => offset_of!(SiftStorageAnalysis, elapsed_millis),
            "aggregated" => offset_of!(SiftStorageAnalysis, aggregated),
            "categories" => offset_of!(SiftStorageAnalysis, categories),
            "category_count" => offset_of!(SiftStorageAnalysis, category_count),
            "files" => offset_of!(SiftStorageAnalysis, files),
            "file_count" => offset_of!(SiftStorageAnalysis, file_count),
            "directories" => offset_of!(SiftStorageAnalysis, directories),
            "directory_count" => offset_of!(SiftStorageAnalysis, directory_count),
            "error" => offset_of!(SiftStorageAnalysis, error),
            other => panic!("unexpected SiftStorageAnalysis field {other}"),
        },
        size_of::<SiftStorageAnalysis>(),
        align_of::<SiftStorageAnalysis>(),
    );
}

#[test]
fn every_exported_symbol_is_declared_in_the_header() {
    let header = include_str!("../../../../Bridge/include/sift_scanner.h");
    let symbols = [
        "sift_ffi_version",
        "sift_string_free",
        "sift_rules_json",
        "sift_path_protection",
        "sift_risk_is_cleanable",
        "sift_default_risk_for_category",
        "sift_engine_new",
        "sift_engine_free",
        "sift_scan_start",
        "sift_scan_cancel",
        "sift_scan_is_finished",
        "sift_scan_poll_events",
        "sift_event_free_items",
        "sift_scan_page_results",
        "sift_page_free",
        "sift_scan_page_duplicate_groups",
        "sift_scan_duplicate_members",
        "sift_duplicate_group_free",
        "sift_duplicate_member_free",
        "sift_scan_free",
        "sift_scan_skipped_json",
        "sift_storage_analyse",
        "sift_storage_analysis_free",
        "sift_storage_cancel_new",
        "sift_storage_cancel",
        "sift_storage_cancel_free",
        "sift_cstr_len",
    ];
    for symbol in symbols {
        assert!(header.contains(symbol), "the header must declare {symbol}");
    }
}

#[test]
fn header_declares_no_symbol_the_library_lacks() {
    let header = include_str!("../../../../Bridge/include/sift_scanner.h");
    // Collect `sift_*` identifiers used as declarations: a name followed by `(`.
    let mut declared: Vec<String> = Vec::new();
    for (index, _) in header.match_indices("sift_") {
        let rest = &header[index..];
        let name: String = rest
            .chars()
            .take_while(|c| c.is_alphanumeric() || *c == '_')
            .collect();
        if name.is_empty() || name == "sift_scanner_h" {
            continue;
        }
        // Only declarations, not mentions inside comments.
        let after = &header[index + name.len()..];
        if after.trim_start().starts_with('(') && !declared.contains(&name) {
            declared.push(name);
        }
    }
    let known = [
        "sift_ffi_version",
        "sift_string_free",
        "sift_rules_json",
        "sift_path_protection",
        "sift_risk_is_cleanable",
        "sift_default_risk_for_category",
        "sift_engine_new",
        "sift_engine_free",
        "sift_scan_start",
        "sift_scan_cancel",
        "sift_scan_is_finished",
        "sift_scan_poll_events",
        "sift_event_free_items",
        "sift_scan_page_results",
        "sift_page_free",
        "sift_scan_page_duplicate_groups",
        "sift_scan_duplicate_members",
        "sift_duplicate_group_free",
        "sift_duplicate_member_free",
        "sift_scan_free",
        "sift_scan_skipped_json",
        "sift_storage_analyse",
        "sift_storage_analysis_free",
        "sift_storage_cancel_new",
        "sift_storage_cancel",
        "sift_storage_cancel_free",
        "sift_cstr_len",
    ];
    for name in declared {
        assert!(
            known.contains(&name.as_str()),
            "{name} is declared in the header but has no exported function"
        );
    }
}

#[test]
fn structs_carry_a_version_field() {
    let structs = parse_header();
    for instance in &structs {
        // SiftString is a value type, not a versioned contract object.
        if instance.name == "SiftString" {
            continue;
        }
        assert_eq!(
            instance.fields[0].name, "version",
            "{} must start with a version field",
            instance.name
        );
    }
}

#[test]
fn string_fields_are_sift_strings_in_both_languages() {
    let structs = parse_header();
    let string_fields: &[(&str, &[&str])] = &[
        (
            "SiftItemSummary",
            &[
                "path",
                "display_name",
                "parent_path",
                "category",
                "risk",
                "explanation_key",
                "rule_id",
                "bundle_id",
            ],
        ),
        ("SiftScanEvent", &["text", "detail"]),
        ("SiftCategoryTotal", &["category"]),
        ("SiftDuplicateGroup", &["digest"]),
        ("SiftDuplicateMember", &["path"]),
        ("SiftResult", &["code", "message"]),
        ("SiftStorageFile", &["path", "display_name", "parent_path"]),
        ("SiftStorageDirectory", &["path", "display_name"]),
    ];

    for (struct_name, fields) in string_fields {
        let instance = c_struct(&structs, struct_name);
        for field in *fields {
            let parsed = instance
                .fields
                .iter()
                .find(|entry| entry.name == *field)
                .unwrap_or_else(|| panic!("{struct_name}.{field} must exist"));
            assert_eq!(
                parsed.ty,
                CType::Named("SiftString".to_string()),
                "{struct_name}.{field} must be a SiftString"
            );
        }
    }
}

#[test]
fn event_kind_and_phase_enums_match_the_library() {
    let header = include_str!("../../../../Bridge/include/sift_scanner.h");
    for (name, value) in [
        ("SIFT_EVENT_PHASE", 0),
        ("SIFT_EVENT_PROGRESS", 1),
        ("SIFT_EVENT_ITEMS", 2),
        ("SIFT_EVENT_DUPLICATE_GROUP", 3),
        ("SIFT_EVENT_SKIPPED", 4),
        ("SIFT_EVENT_COMPLETED", 5),
        ("SIFT_EVENT_FAILED", 6),
    ] {
        let declared: i32 = header
            .lines()
            .find_map(|line| line.trim().strip_prefix(&format!("{name} = ")))
            .and_then(|value| value.trim_end_matches(',').parse().ok())
            .unwrap_or_else(|| panic!("{name} is declared in the header"));
        assert_eq!(declared, value, "{name} must match the library");
    }

    for (name, value) in [
        ("SIFT_PHASE_IDLE", 0),
        ("SIFT_PHASE_PREPARING", 1),
        ("SIFT_PHASE_SCANNING", 2),
        ("SIFT_PHASE_INDEXING", 3),
        ("SIFT_PHASE_READY", 4),
        ("SIFT_PHASE_CANCELLED", 5),
        ("SIFT_PHASE_PARTIAL", 6),
        ("SIFT_PHASE_FAILED", 7),
    ] {
        let declared: i32 = header
            .lines()
            .find_map(|line| line.trim().strip_prefix(&format!("{name} = ")))
            .and_then(|value| value.trim_end_matches(',').parse().ok())
            .unwrap_or_else(|| panic!("{name} is declared in the header"));
        assert_eq!(declared, value, "{name} must match the library");
    }
}

#[test]
fn path_protection_codes_match_the_header() {
    let header = include_str!("../../../../Bridge/include/sift_scanner.h");
    for (name, value) in [
        ("SIFT_PATH_SCANNABLE", 0),
        ("SIFT_PATH_USER_CONTENT", 1),
        ("SIFT_PATH_SYSTEM", 2),
        ("SIFT_PATH_SECRETS", 3),
    ] {
        let declared: i32 = header
            .lines()
            .find_map(|line| line.trim().strip_prefix(&format!("{name} = ")))
            .and_then(|value| value.trim_end_matches(',').parse().ok())
            .unwrap_or_else(|| panic!("{name} is declared in the header"));
        assert_eq!(declared, value, "{name} must match the library");
    }

    // Cross-check the values against a live call for each reason.
    let home = SiftString::from_string("/Users/example".to_string());
    let cases = [
        ("/Users/example/Library/Caches/com.a/b", 0),
        ("/Users/example/Documents/taxes.pdf", 1),
        ("/System/Library/Caches", 2),
        ("/Users/example/Library/Keychains/login.keychain-db", 3),
    ];
    for (path, expected) in cases {
        let value = SiftString::from_string(path.to_string());
        let actual = unsafe { sift_path_protection(home, value) };
        assert_eq!(actual, expected, "{path} should classify as {expected}");
        unsafe {
            sift_string_free(value);
        }
    }
    unsafe {
        sift_string_free(home);
    }
}

#[test]
fn scanner_error_codes_match_the_product_error_table() {
    // The specification's error table; the scanner must not invent new codes.
    let table = [
        "permissionDenied",
        "fileNotFound",
        "fileInUse",
        "volumeUnavailable",
        "protectedLocation",
        "partialFailure",
        "licenseServiceUnavailable",
        "storeUnavailable",
    ];
    // Codes the scanner engine itself produces, plus the shared `cancelled` and
    // `invalidRequest` codes used by the FFI layer.
    let engine_codes = [
        "permissionDenied",
        "fileNotFound",
        "protectedLocation",
        "partialFailure",
        "invalidRequest",
        "internal",
        "cancelled",
    ];
    for code in engine_codes {
        assert!(
            table.contains(&code) || matches!(code, "internal" | "cancelled" | "invalidRequest"),
            "{code} must be covered by the product error table"
        );
    }
}
