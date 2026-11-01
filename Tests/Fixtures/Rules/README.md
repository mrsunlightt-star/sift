# Shared rule-file fixtures

Every document in `accept/` must decode, and every document in `reject/` must be
refused — with the *same* verdict from both decoders:

* `Core/Rules/RuleEngine.decode` (`Tests/RuleEngineTests.swift`)
* `sift_rules::RuleSet::from_json` (`crates/sift-rules/src/lib.rs`)

They are one corpus rather than two suites because the failure mode this guards
against is asymmetric and silent. The Swift engine validates a user rule file and
then hands the document to the Rust core, which parses it again; a document one
accepts and the other refuses fails the whole scan with `invalidRequest`, and
nothing in that error points at the rule file. Each side having its own tests only
proves each side is self-consistent.

Adding a case: put the file in the directory that states the verdict, and say what
it is testing in this table.

| Fixture | Verdict | What it pins |
| --- | --- | --- |
| `accept/minimal.json` | accept | the smallest document that still does something |
| `accept/any-file-with-age.json` | accept | `anyFile` paired with an age is the only safe spelling |
| `accept/replaces-a-shipped-id.json` | accept | an overlay may retune a shipped rule and keep its level |
| `accept/empty-rule-list.json` | accept | an empty overlay is a no-op, not an error |
| `reject/negative-age.json` | reject | `-1` is outside the shared domain (`Int` vs `u32`) |
| `reject/age-beyond-the-shared-maximum.json` | reject | the upper bound is `MAX_RULE_MIN_AGE_DAYS` |
| `reject/container-of-every-application.json` | reject | `FORBIDDEN_RULE_DIRECTORIES` applies to rule files |
| `reject/any-file-without-age.json` | reject | `anyFile` without an age is "the whole tree" |
| `reject/relative-path-climbs-out.json` | reject | `..` may not leave the anchor |
| `reject/relative-path-is-absolute.json` | reject | an absolute path replaces the anchor under `join` |
| `reject/relative-path-with-a-dot-component.json` | reject | an interior `.` is refused by both, though `Path::components` drops it |
| `reject/duplicate-ids.json` | reject | one id, one rule |
| `reject/empty-id.json` | reject | a whitespace id is not an id |
| `reject/unknown-match-spec.json` | reject | a misspelled spec must not widen to "every file" |
| `reject/unsupported-schema-version.json` | reject | the version gate runs before anything else |
| `accept/wildcard-cache-directory.json` | accept | `*` as a whole component is the one wildcard both expanders handle |
| `reject/leading-wildcard.json` | reject | `*/…` would span every child of the anchor |
| `reject/partial-wildcard.json` | reject | a substring match the scanner cannot enumerate safely |
| `reject/recursive-wildcard.json` | reject | `**` is unbounded by construction |
| `reject/wildcard-directly-inside-a-container.json` | reject | `Application Support/*` with `childDirectories` is every application's data, one item each |
| `accept/directories-named.json` | accept | a name set is the filter `childDirectories` cannot express |
| `reject/directories-named-without-names.json` | reject | an empty set matches nothing and is a typo |
| `reject/directories-named-with-a-path-in-a-name.json` | reject | a name carrying `/` belongs in `relativePath` |
