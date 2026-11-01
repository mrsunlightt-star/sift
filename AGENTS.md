# Working on Sift

Instructions for anyone — human or agent — changing this repository.

## Git workflow

**Commit directly to `main`. Do not create feature branches.** The owner of this
repository asked for a single-branch workflow: commit, then push to `main`.

Commit messages describe the change and, when relevant, the reason. No
co-authored or tool attribution lines.

## The build machine

**macOS is not upgraded.** The owner's standing rule: this machine stays on
macOS 15, and no tool, update or "fix" may upgrade it. A task that appears to
need a newer macOS is either solved on macOS 15 or left undone.

That fixes the Xcode version: the 16.x line is the one that runs on macOS 15
(Xcode 16.4 requires 15.3 or later, and is the last of that line). A newer Xcode
— 26.x and later — requires macOS 26 and must not be installed here.

Xcode itself is optional. The Command Line Tools that are installed provide
`swift build` and the SDK; they do **not** provide XCTest, so `swift test` and
`xcodebuild` fail until a full Xcode is present. `Scripts/run-tests.sh` is why the
suite still runs, and `Scripts/verify.sh` adds the Xcode stages automatically once
it finds an Xcode — in `xcode-select` or, before that step has been run, in
`/Applications`.

Four things about the Xcode path are load-bearing and were each a build failure
the first time a real Xcode compiled this project:

- the package exports `AppShell`, `Core` and `Shared` as **static** library
  products. A dynamic product becomes a framework, and a framework has no Rust
  symbols: the `-force_load` of `libsift_ffi.a` lives in the app target.
- the unit-test bundle links the app and nothing else. `TEST_HOST`/
  `BUNDLE_LOADER` give it the app's symbols; linking the package products into
  both the app and the bundle is rejected as duplicated code.
- `Shared` ships only the generated `.lproj` bundles. The `.xcstrings` is the
  source of record but not a build input: shipping both makes Xcode compile it
  *and* copy the bundles, i.e. two producers of `Localizable.strings`.
- `Config/Sift.xctestplan` names targets by their object IDs in the generated
  project. XcodeGen derives those IDs from the target names, so they survive
  regeneration; renaming a target means updating the plan.

`SiftTests` is deliberately **not** `parallelizable` in that plan. The unit
bundle is hosted by `Sift.app` itself, so parallel execution starts one copy of
the app per worker — seven at once on this machine, each running
`AppEnvironment.bootstrap()` and each registering as a foreground app, which is
one icon in the Dock per worker. Serial makes the Xcode run match `swift test`
and `Scripts/run-tests.sh`, which execute the same files in one process, and it
costs nothing measurable for a suite that finishes in seconds. `SiftUITests` was
already serial for the same reason. On top of that, `SiftApp.init` sets an
`.accessory` activation policy when the process is hosting XCTest — detected from
`XCTestBundlePath` / `XCTestSessionIdentifier`, because the test bundle is not
loaded yet when SwiftUI calls `init` and a class lookup answers nil there — so a
hosted suite never appears in the Dock at all. A UI-test launch is a plain app
launch (its only injected library is the main thread checker), keeps the normal
`.regular` policy, and is what XCUITest drives.

The Xcode stage builds the test plan and then runs the two test targets with
`test-without-building`. Two things about that are load-bearing, and each was
found by a failure rather than by reading documentation.

`build-for-testing` is given **no** `-destination`. With one, xcodebuild writes
`UITargetAppPath` into the generated `*.xctestrun` as `<products>/Debug/Sift` —
without the `.app` suffix, so it names a path that does not exist. Without one it
writes `Debug/Sift.app`. The run step does need a destination, because it has to
choose a runner, and there it is `platform=macOS,arch=$(uname -m)`: bare
`platform=macOS` matches both architectures on an Apple Silicon Mac and
xcodebuild picks one with "using the first of multiple matching destinations".

The two targets are then run **separately**, with `-only-testing:SiftTests` and
`-only-testing:SiftUITests`, and their two failure modes are told apart.

Xcode 16.4's UI-test runner sometimes does not start at all. It looks for the
target application at `<products>/Debug/Sift` — a path with no `.app` on it —
while the bundle is at `<products>/Debug/Sift.app`, and it reports

    Test target SiftUITests encountered an error (The bundle identifier for Sift
    couldn't be read. No such file or directory: ".../Debug/Sift".)

before any test case executes. It happens on this machine and on GitHub's
`macos-15` runners alike, and nothing in this repository causes it: the generated
`xctestrun` holds the correct `Sift.app` path on the failing runs, and the bundle
is present, correctly named and satisfies its designated requirement. Each of
these was suspected and then ruled out by running it: the app's debug-dylib
layout, the result-bundle location, the `-destination`, the test plan's target
list, and competing LaunchServices registrations for `com.siftmac.cleaner` from
other checkouts of this repository (four records, one of them from a review copy
in `~/Documents`).

**It is intermittent, and that is the part that matters.** On 2026-10-19 the
same commit failed both attempts in `Scripts/verify.sh` at 03:07 and then ran the
five UI tests to green five times in a row, including one run from a derived-data
directory built from scratch and one immediately after re-registering another
checkout's bundle with `lsregister -f`. Eight hours later, after the machine had
slept, it failed again — twice, reproducibly — but with a second shape:

    SiftUITests-Runner (40297) encountered an error (The test runner failed to
    initialize for UI testing. (Underlying Error: Timed out while enabling
    automation mode.))

That one is the automation grant rather than the path lookup, it also leaves zero
test cases executed, and on that machine neither killing the stray runners nor
waking the display nor restarting `testmanagerd` restored it — it wants a human
at the GUI. A third attempt then sat for thirteen minutes with nothing written to
its log at all, which is the worst outcome of the three: a gate that never prints
a verdict stops being a gate. So each attempt now has a five-minute deadline and
a runner that hangs is stopped and reported the same way the other two are, and
the stage and CI classify **all three** as `did not run` (matching `SiftUITests
encountered an error`, `failed to initialize for UI testing`, or the deadline's
own line) while still failing the run for anything else, unrecognised failures
included. A run that reports `did not run` should be re-run when the machine can
run it; the tests do execute. What is not acceptable is treating a green run as
evidence that the UI tests passed, which is why the verdict line stays explicit
about it. A release must have a run whose UI target actually executed (see
`RELEASE.md`).

The wedged daemon is worth knowing about on its own, because it takes the *unit*
stage down with it. That run failed the Xcode unit tests with

    Failure collecting logarchive: ... "Timed out after 120.0s while initiating
    control session with daemon."
    Sift (43086) encountered an error (Test runner never began executing tests
    after launching)

after 704 seconds, having passed the same 174 tests under `swift test` minutes
earlier. Killing the per-user `testmanagerd` (`kill -9`; `launchctl kickstart` is
refused under SIP, and launchd respawns it either way) brought the app-hosted
suite back green on the next run. Automation mode stayed unavailable, which is
the part that needs a person: the same session then reported the UI target as
`did not run` rather than as a failure, which is the classification doing its job.

So neither the stage nor CI treats "the runner did not start" as "a test failed".
A failing *test case* fails the run. A runner that never started is reported as
`did not run`, and the run's summary says so — a green verdict never implies the
UI tests executed. When both attempts fail on a machine where they used to pass,
the two things worth checking are that `xcodebuild -version` reports 16.x, and
that `lsregister -dump | grep -A2 com.siftmac.cleaner` does not list a checkout
of this repository that has since been deleted.

**The exit code cannot answer "did a test run", so the stage asks the result
bundle.** Both Xcode targets are launched with `-resultBundlePath`, and the
counts come from `xcrun xcresulttool get test-results summary`: a target passes
only when its bundle records cases that ran and none that failed. This is not
defensive decoration — a UI attempt that stops before the first case exits 0 on
this machine, and the first version of the stage printed `→ ok (UI target)` for a
run whose bundle held zero tests. A unit target that executed nothing fails the
run for the same reason: `-only-testing:` with a filter that matches nothing is
otherwise a silent skip. The summary line states what executed —
`XCUITest methods 8 (ran, 8 executed)` — and a bundle that is missing or
unreadable counts as zero, because an answer that was not given is not an
execution.

The zero-execution path is exercised on purpose rather than trusted:
`SIFT_UI_ONLY=SiftUITests/test_doesNotExist Scripts/verify.sh --quick` points the
attempt at a test that does not exist. `xcodebuild` exits **0** for that run and
its bundle records 0/0/0, which the old stage would have printed as `ok`; the
stage must instead end with `at least one check failed`.

## Before changing code

Run the bootstrap once per checkout:

```bash
Scripts/bootstrap.sh
```

It builds the Rust scanner core into `Bridge/macos-universal/libsift_ffi.a`
(SwiftPM and Xcode both link from that fixed path), regenerates the string
catalog, regenerates the Swift protection list, and regenerates `Sift.xcodeproj`
from `project.yml`.

Neither build system tracks that archive as an input — it reaches the linker
through `-force_load` in the manifest's unsafe flags — so a rebuilt archive used
to leave every already-linked product in place and the suite ran the previous
core without saying so. `Scripts/build-rust-core.sh` now compares the archive it
wrote against the one it replaced and touches `Core/RustBridge/RustScannerEngine.swift`
when it changed, which makes the modules that import the bridge recompile. That is
why the file's timestamp moves after a Rust change: it is the notification, not an
edit.

The touch recompiles; it does not by itself relink, and that was measured rather
than assumed. With the archive changed and the source merely touched,
`swift build --build-tests` printed "Compiling Core RustScannerEngine.swift …
Build complete" and never ran its link step: the recompiled object files came out
byte-identical, so the linked test bundle looked up to date and kept the previous
core — a Rust-side regression passed the suite. The same step therefore deletes
the products that force-load the archive (`.build/*/Sift`, `SiftSelfTest`,
`SiftPackageTests.xctest`) so the link cannot be skipped. An Xcode build's
`DerivedData` is a different build directory and gets the touch, not the sweep.

After changing `project.yml`, install XcodeGen if needed (`brew install
xcodegen`) and run `xcodegen generate --spec project.yml`. Commit the regenerated
project.

After changing anything under `Shared/Localization/`, regenerate the catalog and
its `.lproj` outputs with `python3 Scripts/generate-strings.py`. Never edit
`Localizable.xcstrings`, `LocalizationKey.swift` or `.lproj` files by hand.

After changing `PROTECTED_HOME_CHILDREN`, `PROTECTED_PREFIXES`,
`PROTECTED_LIBRARY_CHILDREN`, `PROTECTED_PHOTOS_LIBRARY_SUFFIX`,
`PROTECTED_RECYCLE_BIN_NAMES`, `MAX_RULE_MIN_AGE_DAYS`, `MAX_RULE_ROOTS`,
`RELATIVE_PATH_WILDCARD`, `FORBIDDEN_RULE_DIRECTORIES`, `SYMLINK_ALIASES` or
`SYMLINK_ALIAS_TARGETS` in
`RustCore/crates/sift-rules/src/lib.rs`, regenerate the Swift half with
`python3 Scripts/generate-protection.py`. Never edit `Core/Rules/ProtectedPaths.swift`
by hand: it exists so the two engines cannot protect different sets of paths, and
`SYMLINK_ALIASES`/`SYMLINK_ALIAS_TARGETS` are one table read index for index, so
moving one without the other is rejected by the generator.

After changing `default_rules()` in the same file, regenerate the rule table the
app ships with `python3 Scripts/generate-rules.py`. `default_rules()` is the
source for all three copies — the Rust engine's, `Core/Resources/CleaningRules.json`
and `Core/Rules/BuiltInRules.swift` — and the generator reads the table out of the
Rust core rather than parsing its source, so a rule the table gains cannot be
missing from the copies. Never edit either generated file by hand: the Rust test
`the_shipped_rule_file_is_the_built_in_table` and the Swift test
`test_theFallbackTableIsTheShippedRuleFile` both fail when they disagree.

`Scripts/check-explanation-keys.py` covers the other direction, and
`Scripts/verify.sh` runs it: every `explanation_key` the code attaches to an item
must be a key `Shared/Localization/Localizable.xcstrings` carries, and must have no
format placeholder, because a row renders its explanation with no arguments.

## Before committing

```bash
Scripts/verify.sh
```

It runs, in order: the generated-source checks, Rust formatting and lints, the
Rust test suites (including the FFI contract tests), the benchmark build, the
Swift build, the self-test suite, the XCTest suite, and the app bundle. A commit
should not land while any stage fails.

A release has requirements this script cannot check — a signing identity, a
notarised artefact, a UI target that actually executed, a live licence service —
and they are written down with their verification commands in `RELEASE.md`.

## Invariants that must not regress

These are product promises, not implementation details. Each has tests behind it.

1. **Nothing is deleted.** Every cleanup moves items to the Trash through
   `FileOperationService`; there is no permanent-delete path and no shell call.
2. **Protected paths are refused three times**: when results are shown, during
   pre-flight, and again immediately before the file operation. The compiled-in
   list wins over every rule file.
3. **A rule file can widen what is recognised, never what may be removed.**
4. **The Rust core only discovers and analyses.** It never deletes, moves, reads
   purchase state or touches the Trash.
5. **Every cleanup item carries a category, a risk level and an explanation.**
   `protected` items can never be selected.
6. **The free tier never performs a cleanup.** The paywall appears when the user
   asks to clean or uninstall, never at launch.
7. **Reports and logs contain no full paths, file names in bulk, or credentials.**
8. **A cleanup item's identity is derived from its target** (category plus
   normalised path), never a fresh random value; a SwiftUI re-render must not be
   able to lose a checkbox.
9. **A measure-only scan root produces no cleanup candidates**, in both engines.
10. **Mount points are never scanned without an explicit grant.** Only locations
    the user added are included, and a grant never unlocks user content, keychains
    or a photo library. Authorisation is an allowlist — one volume under
    `/Volumes`, or a folder inside home — and it lifts only the `/Volumes` blanket
    prefix. System prefixes (`/Library`, `/private/var`, `/System`, ...) stay
    protected even when a path appears to be authorised. The walk that scans
    consults the grants on every entry, not only on the root, and a stored grant
    is re-validated against the current allowlist before it is restored, so a
    bookmark written by an older build cannot widen what is reachable.
11. **A grant is one location, recorded and used under its resolved path.** The
    scope, the scan roots and the settings row all use the URL the authorisation
    service resolved, never the one the panel handed back, and one location has
    one row. A grant is in force only while the location can actually be read:
    the security-scope call reports success even for an unmounted volume and for
    a directory the process may not list, so readability is what decides.
12. **The authorised rule anchors expand to the grants, never to a container.**
    `authorized` and `externalVolume` resolve to every location the user granted
    (`externalVolume` to mounted volumes only), and to nothing when nothing was
    granted. `/Volumes` and the home directory are containers: a rule that fell
    back to either would apply to a tree nobody opened.
13. **Path comparisons normalise `.`, `..` and the macOS symlink aliases**
    (`/var`, `/tmp`, `/etc`) before matching, in both engines, from one table.
    `SYMLINK_ALIASES`/`SYMLINK_ALIAS_TARGETS` are the source and the Swift copy is
    generated; a private literal in either engine is how `/var/db/...` came to be
    refused by one and walked by the other.
14. **Two engines, one protection list.** `PROTECTED_*` in
    `RustCore/crates/sift-rules/src/lib.rs` is the source; the Swift list is
    generated from it. `Scripts/verify.sh` fails when the generated copy is stale,
    and both test suites assert every entry on the shared list is refused.
    `PROTECTED_RECYCLE_BIN_NAMES` is matched as a whole path **component** at any
    depth: every removal this product performs moves an item into the Trash, so
    offering an item that is already there turns the promised undo into a second
    move, and a grant for a volume does not open the `.Trashes` inside it.
15. **A measurement stays inside the volume it started on.** A mount point below a
    volume root belongs to another disk, and `/System/Volumes` holds the system's
    own mount points on the same device as `/`, so both are excluded explicitly:
    counting them attributes the whole disk to one directory, and reads a volume
    the user never authorised. A walk that hits its budget reports an estimate
    rather than a total.
16. **System diagnostics widen what the app can see, never what it may remove.**
    A `StorageFinding` is not a cleanup item: it carries no selection state, no
    risk level and no route into the cleanup pipeline, and no function in
    `Core/Diagnostics` produces anything a scan consumes. The diagnostic engine
    applies the protection list itself, so a protected location may be measured
    and explained but can never be `cleanable` or carry a Trash remediation —
    protection removes the deletion path and nothing else, which is what keeps a
    protected index's rebuild advice intact.
17. **One implementation per user operation.** A scan starts only through
    `AppEnvironment.runScan(_:)`. There is one scan page; it runs `.everything`
    and the chips filter the categories it displays, so "smart scan", "junk
    cleanup" and "file cleanup" cannot mean three different runs. A scan is
    single-flight for its whole run — request assembly, scanning and loading the
    first page — so two runs' phases and selections cannot interleave, and
    `hasResults` waits for the report, not merely the `.ready` phase. A
    destructive operation (cleanup or uninstall) claims its slot synchronously
    before any entitlement check and holds it through pre-flight and execution;
    the uninstaller and the cleanup flow share that one slot, and the
    entitlement is checked again at the execution boundary. Authorising a folder
    happens only in Settings, and every page that depends on a grant links there.
    Confirmation and the cleanup result come from the shell, so no page can reach
    a weaker flow by choosing a different entry point. Tests:
    `test_aPhaseWithoutAReportIsNotAResult`,
    `test_aSecondPrepareDoesNotReplaceTheOpenPlansOperation`,
    `test_theDestructiveSlotCannotBeClaimedTwice`,
    `test_aFailedPageStaysVisibleAfterASuccessfulPage`.
18. **Diagnostics only read.** The only programs the app runs are the two status
    queries in `Core/Diagnostics/SystemQuery.swift`: `mdutil -s` and
    `tmutil listlocalsnapshots`, by absolute path with fixed arguments and no
    shell, and never anything that changes state. A query that fails, times out
    or is refused is reported as unknown or as an incomplete result, never as a
    finding: an answer that was not given must not be invented.

19. **A rule descends from its anchor and from nothing else.** A `relativePath`
    that is absolute, or that contains a `..` component, is refused where the file
    is read: `Path::join` *replaces* the base for an absolute argument, and
    `/Users/alice/Library/../../Shared` is spelled as though it sits under the home
    directory while resolving to `/Users/Shared`. Resolution checks containment a
    second time, so a table assembled in code cannot climb out either, and the path
    the engine walks is the collapsed one the protection check judged. Both
    engines refuse the same two shapes.
20. **A move acts on the object the user selected.** `trashItem` follows a symlink
    in *any* component of the path, so an ancestor replaced by a link turns a cache
    path into a request to move something under `~/Documents` — and the protection
    list cannot see it, because the path as written is not protected. An item whose
    path no longer resolves to itself is refused with `itemChanged`, at the
    pre-flight check and again immediately before the move.
21. **The offline window is measured against the clock, not the process.** A
    refresh only happens when the channel answers, and an unreachable service is
    exactly the case where that does not, so the expiry is re-evaluated at every
    gate: a Mac left open past the end of the 14 days stops being unlocked without
    a relaunch. A stored timestamp in the future is not a verification and is not
    restored; a small forward skew is tolerated so a corrected clock cannot lock a
    paying user out.
22. **The merge order is the same in both engines: replace, then filter.** A rule
    file that switches a shipped rule off replaces it and is then dropped, so the
    rule really is off; filtering first would discard the override and leave the
    shipped rule running. Marking a shipped rule `protected` therefore leaves no
    hole where the shipped rule was.
23. **One rule table, and residue is the scanner's decision.** `default_rules()` is
    the single source; the shipped `CleaningRules.json` and the Swift fallback
    table are generated from it, and `Scripts/verify.sh` fails when either is
    stale. No shipped rule carries the `applicationResidue` category, and none
    *is* `~/Library/Containers`, `~/Library/Group Containers` or
    `~/Library/Application Support`, nor any path ending in one, nor one of their
    immediate children (`Containers/*`): a rule matches a name shape or an age and
    cannot know whether an application is installed, so those shapes offered the
    live data of installed applications — every directory under
    `Application Support` as "residue", and the whole store as one cleanup item.
    `FORBIDDEN_RULE_DIRECTORIES` is that list, and it is enforced at load time for
    any rule file, not only asserted for the shipped table.

    Descending *through* a container to a named location is a different thing and
    is what the three cache/artifact families do:
    `Containers/*/Data/Library/Caches` is one cache directory per application,
    named by the platform rather than guessed. Residue still comes from
    `scan_application_residue`, which compares the name against the installed
    bundle identifiers, and a container that belongs to a live application belongs
    to the uninstaller instead.

    The specification decides whether `<container>/*` is that shape:
    `childDirectories` there is one item per application's data root, so it is
    refused; `directoriesNamed` there is one item per *named* directory inside
    each application's data root, which is what `app-support-caches` uses, and it
    is allowed. `forbidden_rule_directory` carries the specification for exactly
    that reason.

    A child-directory rule with an age threshold is still allowed (the log rules
    use one), but the scanner may only offer a directory whose **every** file is
    past the threshold.

    `matchSpec: "directoriesNamed"` is `childDirectories` with the filter in the
    rule instead of in the path: `names` (a sibling of `matchSpec`, like
    `extensions`) lists the directory names that count, compared without case. It
    exists because an application names its cache directory `Cache`, `Caches`,
    `GPUCache` or `Code Cache` depending on the framework it was built with, and
    one rule per spelling is a list that grows with every framework. A rule whose
    name set cannot match a directory — empty, or carrying `/` or `*` — is
    refused where the file is read, in both decoders.

    `relativePath` may name `*` as a whole component, and only as a whole
    component: it matches exactly one directory name, expanded from the disk by
    `expand_relative_path` (Rust) and `RuleEngine.roots` (Swift), bounded by
    `MAX_RULE_ROOTS`. Partial (`com.apple.*`), recursive (`**`) and leading
    (`*/Caches`) wildcards are refused by both decoders, because the first two
    say something the scanner cannot enumerate safely and the third makes one
    rule span every child of its anchor. The item is moved whole, so a mixed directory would take
    fresh files the threshold did not count; both engines compare the filtered
    measurement with the whole-directory measurement and skip the directory when
    they differ.

    The three shapes above are enforced, not merely asserted. `FORBIDDEN_RULE_DIRECTORIES`
    is refused by `RuleSet::from_json` and by `RuleEngine.decode`, so a **user**
    rule file that names one is rejected with the reason instead of reaching the
    scanner, and `enforce_rule_invariants` (Rust) / `RuleEngine.sanitized`
    (Swift) drop the same shapes from a merged table. A rule this build does not
    ship is also capped at `review`: `safe` is the level that arrives
    pre-selected, and a release has to review a rule before it earns that. A rule
    that replaces a shipped id keeps the level the overlay states, because
    retuning a reviewed rule is what an overlay is for.

    `minAgeDays` has one domain (`0...MAX_RULE_MIN_AGE_DAYS`) in both decoders.
    A document one accepts and the other refuses fails the whole scan with
    `invalidRequest`, so `Tests/Fixtures/Rules/` holds one corpus that both
    suites run: documents in `accept/` must decode, documents in `reject/` must
    be refused. Add a case there rather than to one side alone.
24. **Every explanation the scanner attaches resolves.** A rule names the key of
    the sentence the user reads and the row renders it with no arguments, so the
    key has to exist in the catalog and carry no `%d`/`%@`; the parameterised
    sentences stay on the category-level keys the pages format for themselves. A
    key derived from the rule id resolves to nothing, which is how every item came
    to fall back to its category's generic line after the Rust rule table and the
    catalog were written in two different naming schemes. `Scripts/check-explanation-keys.py`
    checks the direction a test cannot: a key in the code that the catalog lacks.
25. **A path carries the most cautious risk that matched it.** Two rules that
    match one path produce one item, at the higher of the two risk levels, with the
    rule id breaking a tie — the index keeps one row per path and rewrites it, so
    otherwise the row the user saw was decided by the order an unstable sort left
    two equal keys in.
26. **Both engines find the same items, down to the row.** `Tests/EngineAgreementTests.swift`
    runs one fixture through the production engine (`ScannerEngineFactory`) and
    through the Swift reference engine and compares the whole row — path,
    category, risk, size, file count and explanation key — with hidden files in
    scope and out of it, with a measure-only root, and with the duplicate
    pipeline. One rule table says the two engines are *given* the same rules;
    nothing said they *do* the same thing with them until this test. What it
    found: the Rust walker recorded `metadata.len()` for files where the rest of
    the crate, the Swift walker and the Finder all use allocated size, so a
    residue directory of small files reported 3 KB instead of the 8 KB it
    occupies — and read differently depending on which core a Mac ran.
27. **A move acts on the object, not merely the path pre-flight checked.**
    Pre-flight records the device, inode and file type of every item it readies
    (`FileIdentitySnapshot`, read with `lstat`), and execution re-reads them
    immediately before `trashItem`; a path whose object was replaced is refused
    with `itemChanged`. The identity is captured from the same spelling the move
    will use, so an ancestor re-pointed to another directory changes it too. An
    item whose identity cannot be read is not approved at all.

    The approved plan is a snapshot, not the live selection: the confirmation
    panel's label, its category breakdown and the outcome's totals all come from
    `PreflightReport.ready`, so a selection change after pre-flight cannot make
    the summary and the move describe two batches. Pre-flight also preserves the
    scanner's explanation key, rule id and file count instead of stamping the
    placeholder row it used to build. Tests:
    `test_theMoveRefusesAnObjectReplacedAtTheSamePath`,
    `test_preflightPreservesTheItemsProvenance`,
    `test_theApprovedPlanDoesNotFollowTheLiveSelection`.
28. **A run with no verdict is reported as one.** A storage measurement that
    throws is a failure, not an empty disk: `StorageAnalysisModel` keeps the last
    good analysis and its timestamp, records `failed` with the reason, and the
    page offers a retry. Cancellation is its own outcome, and a completed run is
    `partial` when it skipped folders or hit its budget. A scan whose session
    finishes without ever publishing a terminal event is marked failed instead
    of leaving `waitUntilSettled()` waiting forever. Tests:
    `test_aFailedRunKeepsTheLastGoodResultAndItsTimestamp`,
    `test_cancellationIsItsOwnOutcome`,
    `test_aSessionThatEndsWithoutATerminalEventFails`.
29. **A scan root states which scans may visit it.** `isCleanable` decides
    whether a root may produce cleanup candidates at all; `includesThresholdFiles`
    separately decides whether the generic large-file and old-file scans walk it.
    `/Library/Logs` is in scope for the `system-logs` rule and out of the
    threshold scans, because a root added for one rule must not widen the search
    for files that rule never judged. Both engines read the same flag. Tests:
    `test_aRulesOnlyRootYieldsNoThresholdItemsInEitherEngine`,
    `a_root_can_be_excluded_from_the_threshold_scans`.
30. **A dropped storage rollup is dropped, not restarted.** The directory map is
    bounded, so a prune loses the tail. A directory whose total was dropped is
    remembered and never re-created from the files seen after the prune: that
    entry would state a partial total as the directory's whole size. Tests:
    `test_aPrunedRollupIsNotRecreatedFromLaterFiles`.
31. **`safe` is not a promise about a live process.** A rule whose items one
    application owns says so (`needsAppClosed`), and a scan takes such an item
    from `safe` down to `review` while that application is running: the item is
    still offered, it simply is not pre-selected, because the move would pull a
    cache directory out from under the process writing into it. The matcher
    compares every path component against the running applications' aliases
    (bundle identifier, the identifier's last component, Finder name, executable
    name), case-folded, with a bundle identifier also claiming the names below it
    and the `.savedState` suffix stripped first. Pre-flight refuses the item with
    `fileInUse` for the same reason, and execution re-asks with a fresh snapshot
    because the confirmation panel may stay open while the user launches the
    application. The list travels in `ScanRequest.runningApplicationTokens` — it
    is collected once, on the main actor, and read by both engines, so they
    downgrade the same rows. Tests:
    `test_theTwoEnginesAgreeAboutARunningApplication`,
    `a_running_application_takes_a_safe_cache_down_to_review`,
    `test_preflightRefusesAnItemWhoseApplicationIsRunning`.
32. **One anchor is not derived from the home directory.** `userTemp` is the
    session's `/var/folders/<xx>/<hash>`, resolved once by `confstr` and passed
    to both engines as a `ScanRoot` with `anchor: "userTemp"` — a rule cannot
    spell it and the Rust core cannot ask for it. Its `C` is the shipped
    `user-temp-caches` rule; `T` is deliberately not a rule, because live
    processes keep their sockets there and a rule can only look at a name or an
    age. A `userTemp` rule with no root named in the request resolves to
    nothing, never to `/var/folders`.

    That root is also the one scan root outside the home directory and outside
    `/Volumes`, so the ABI gate in `Engine::start_scan` accepts it — and only in
    the shape macOS produces, `anchor: "userTemp"` **and** exactly
    `/var/folders/<two characters>/<hash>` after alias normalisation. The anchor
    alone would let a caller name `/private/var` or `/var/folders` itself, which
    is every session on the machine. Taking neither was a shipped defect: the
    gate had no branch for the anchor, so every scan the app started was refused
    with `invalidRequest` before the engine read a single directory, and no test
    noticed because fixture homes put every root inside a tree the gate already
    allowlisted. Tests:
    `the_roots_the_app_builds_are_accepted`,
    `a_user_temp_root_is_accepted_only_at_the_session_depth`,
    `test_theRequestTheAppBuildsIsAcceptedByTheProductionEngine`,
    `the_user_temp_rule_reaches_only_the_root_the_request_named`,
    `test_theTwoEnginesAgreeAboutTheUserTempRoot`.
33. **Emptying the Trash is the only permanent removal.** `TrashService` acts on
    `~/.Trash` alone, rebuilds each entry's path from the bin and the entry's own
    name (a path that does not rebuild to the entry is refused), removes exactly
    the snapshot the confirmation described, and reports per entry. The
    protection list cannot be consulted — every recycle-bin path is on it, which
    is what keeps the bin's contents out of a cleanup — so the fixed root and the
    rebuild are what stand in its place. No privileged helper, no shell. Tests:
    `test_anEntryOutsideTheBinIsRefused`, `test_emptyRemovesExactlyTheSnapshotItWasGiven`.
34. **APFS snapshots are reported, never deleted.** Reclaiming them needs an
    administrator, so the storage page's snapshot card links to the Time Machine
    pane instead of offering a button that cannot work; `APFSSnapshotProvider`
    keeps reporting a count and the newest date, with `status: .protected`.
35. **The "show hidden files" scope decides whether a dot-directory rule runs.**
    The walkers skip hidden *entries*, and a rule's own `relativePath` never
    reaches a walker — so `~/.cache` was offered with the setting turned off. Both
    engines now drop a rule whose relative path names a dot-component before
    expanding its roots (`rule_has_hidden_component` /
    `ruleHasHiddenComponent`). The developer caches (`~/.cache`,
    `~/.gradle/caches`, `~/.cargo/registry/cache`, `~/.npm/_cacache`,
    `~/.android/cache`) are why the table now depends on it. Tests:
    `a_rule_under_a_hidden_directory_follows_the_hidden_file_setting`,
    `test_aRuleUnderAHiddenDirectoryFollowsTheHiddenFileSetting`.
36. **A rule may use more than one wildcard, and the names still decide.**
    `Application Support/*/*/*` + `directoriesNamed` is the Chromium profile
    shape: the vendor, the product and the profile level are whatever the vendor
    wrote, and only the cache directory's name is knowable. Multi-wildcard rules
    are bounded by `MAX_RULE_ROOTS` like every other expansion, and the
    invariant that a container's *direct child* is not an item still holds — the
    wildcards are above the named level, never at the item.

37. **Residue keeps its two claims apart.** `~/Library/Containers/<id>` is one
    application's private data; `~/Library/Group Containers/<team-id>.<id>` is a
    container an app group shares, and removing it can affect a sibling that is
    still installed. That is why the uninstaller has always shown a group
    container as "review" and a private one as confirmed, and why the scan page
    now has `groupContainerResidue` as its own category rather than folding it
    into `applicationResidue`: one heading for two different claims is how a
    shared container came to look as safe as a private one. Both engines report
    the same category for the same directory (`Category::GroupContainerResidue` /
    `.groupContainerResidue`), and `junkCategories` carries both so the page and
    its filter chips still read one list. Tests:
    `a_private_container_and_a_shared_one_are_different_categories`,
    `test_groupContainerResidueReadsBothSpellingsOfTheName`,
    `test_junkCleanupOwnsOneDefinedSetOfCategories`.

38. **A residue row says which application it belongs to, and whether another
    one answers for it.** `RelatedFile.sharedWith` is filled only for a group
    container, from LaunchServices: a container matched to one application by the
    `<identifier>.` spelling belongs to an installed helper, and removing it takes
    data that helper still uses, so the row says the name. The scan page's residue
    rows carry `relatedBundleID`, and the row's lookup asks LaunchServices for the
    application: found means it is revealed, not found means the identifier is
    copied and the page says the application is not installed — residue is
    normally an application that is gone, so "not found" is the usual answer and
    the row says so instead of offering a button that appears to do nothing.
    Tests: `test_aContainerNamedAfterAnotherInstalledApplicationIsMarkedShared`,
    `test_aPrivateContainerIsNeverMarkedShared`.

39. **A group container is claimed by the entitlement, not only by the name.**
    `com.apple.security.application-groups` is the only statement macOS accepts
    that an application may use a group container, and a container is named after
    the group, so two applications sharing one cannot be found from the name at
    all. `AppGroupEntitlements.read` reads that entitlement from the signature
    (`SecCodeCopySigningInformation`, no prompt, no Full Disk Access), and
    `AppGroupRegistry` answers "who declares this group" from one read per
    installed bundle — 135 bundles take about half a second, so the map is built
    once, lazily, and `groups(ofApplicationAt:)` caches a single bundle's answer
    for the page being shown, and the map is rebuilt whenever the installed set
    changes: every question is preceded by a fingerprint (bundle path, the bundle
    directory's timestamp and `Contents/Info.plist`'s), so an installation, a
    removal or an in-place update is noticed without reading a signature — the
    plist is the second signal because replacing files inside `Contents` does not
    necessarily touch the directory's own timestamp — a session outlives all three, and a user
    who installs an application and then scans must not get the declarations of
    the set that existed at launch. The uninstaller marks such a container
    `MatchReason.appGroup`, fills `sharedWith` from the same declarations, and
    keeps the group id on the row (`RelatedFile.groupIdentifier`) because that is
    the string a user can check against `codesign -d --entitlements`. The read is
    bounded (`AppGroupRegistry.defaultDeadline`, five seconds) and reports whether
    it finished: `ScanRequest.appGroupIdentifiersComplete` /
    `app_group_ids_complete` travels with the set, and when it is false both
    engines report **no** group-container residue for that run — half a set is
    worse than none, because every container whose owner went unread answers
    "nothing declares this". The same set
    decides scan residue: `ScanRequest.appGroupIdentifiers` /
    `ScanRequest.app_group_ids` carries it into both engines, and a group
    container whose whole name is a declared group is live, never a leftover —
    the check runs before the name readings because a declaration is a statement
    about the system and a name is a statement about spelling. Tests:
    `test_aGroupContainerSharedByAnotherApplicationIsFoundThroughItsEntitlement`,
    `test_aDeclaredAppGroupContainerIsNotResidue`,
    `test_theTwoEnginesAgreeAboutADeclaredAppGroup`,
    `residue_skips_a_container_an_app_group_declares`,
    `test_theSignatureIsReadOncePerBundle`, `test_aGroupIsMatchedWhateverCaseItIsWrittenIn`.

40. **The audit measures group containers, and says what the name alone misses.**
    `Scripts/audit-coverage.py` classifies every directory in
    `~/Library/Group Containers` as `declared` (an installed application's
    entitlement names the group), `named` (the name contains an installed
    application's identifier) or `residue` (neither), using `codesign -d
    --entitlements` because the audit runs without building the product. The
    number it exists to produce is `declaredWithoutAName` — the containers the
    name-based scan reports as residue while an application still declares them.
    It also ages each container from the same walk (`residueAges`, ladder
    7/30/90/180 days), and keeps "no files at all" out of that ladder instead of
    calling it zero days old. **No age filter is applied to residue, and that is a
    decision with a number behind it**: `staleFilter` prints what a `--stale-days`
    filter would do, and on the development machine 30 days would keep 17 of the
    20 containers that hold anything (10.5 MB), hide 3 (140 KB), and none of the
    hidden ones was written to within a week — they are the leftovers of
    applications deleted a few weeks ago, which is exactly what the user is looking
    for. The engines already skip a container that measures zero bytes, so an age
    filter can only hide rows that had something in them.
    On the development machine that is 34 containers, so the gap was real and not
    hypothetical; it is now closed in both engines, and the number is what keeps
    the claim honest (`--no-entitlements` reproduces the name-only view).
    `--only-group-containers` prints this section alone, without measuring the
    rule table; `--self-check` pins the classifier's three-way split.

41. **The coverage page lists what the scan produced, not only what the table
    contains, and knows which directories a scanner reads.** The residue scans and the threshold scans are code: they decide by
    comparing a name with the installed applications, which no rule can express.
    `RuleCoverageAnalyzer` used to drop their rows (`guard rules.rule(withID:) != nil`),
    so the one page that says "what does the scan actually find" omitted both
    residue claims entirely — including `groupContainerResidue`, the claim this
    file's other invariants are about. Such rows now appear with
    `Row.isSynthesized == true`, their own category and the most cautious risk
    among them, and a rule's own totals are still not mixed with a strategy's.
    `RuleCoverageAnalyzer.scannerCoveredDirectories` is the matching half of that:
    a directory a scanner reads is not "uncovered" even when today's run found
    nothing in it, because the page would otherwise offer a rule draft for a
    container folder — which `RuleDraft.make` refuses. The threshold scans are
    deliberately not in that list; they cover the whole tree and would empty the
    section. Tests: `test_aStrategyThatIsNotARuleGetsItsOwnRow`,
    `test_theTwoResidueClaimsAreSeparateRows`,
    `test_aDirectoryABuiltInScannerReadsIsNotReportedAsUncovered`, and the
    self-test's rule-coverage group.

## Layout notes

- `Core/` is one library; `Features/` are separate libraries so a change to one
  feature cannot break another's build.
- `App/Entry` is the only file the app target and the SwiftPM executable share;
  everything else lives in `App/Shell` or below.
- `Tests/` runs under XCTest (`swift test`, Xcode) and also under
  `Scripts/run-tests.sh`, which supplies a small XCTest-compatible runner for
  machines with only the Command Line Tools.
- `Core/Rules/ProtectedPaths.swift` is generated (`Scripts/generate-protection.py`)
  from the Rust constants; `Core/Rules/RuleEngine.swift` reads it and restates
  none of it. `Core/Rules/BuiltInRules.swift` is generated the same way
  (`Scripts/generate-rules.py`) from `default_rules()`, and is what
  `RuleEngine.builtInRules` reads.
- `Scripts/audit-coverage.py` reports, per rule, how many items this Mac holds
  and how much they occupy, then the top-level directories no rule reaches
  (distinguishing "no rule exists" from "the rule exists and this Mac has
  nothing"). It re-derives expansion and matching from the shipped
  `CleaningRules.json`, so it is an estimate rather than the engines' answer: run
  it to find a dead rule or an uncovered subtree, never to decide what is safe.
  `--self-check` (part of `Scripts/verify.sh`) is what keeps its arithmetic
  honest. `--age-sweep 7,30,90,180` prints the same measurement at several ages in
  one pass, which is how a threshold gets chosen from data instead of a guess:
  `android-sdk-idle-components` moved from 180 days to 90 because the sweep showed
  six months found nothing at all on a machine whose Android build was a quarter
  old, while a quarter offered 2.0 GB nothing had read since. Its last section
  classifies `~/Library/Group Containers` by entitlement, by name, or as residue,
  and prints `declaredWithoutAName`: the containers the name-based scan calls
  residue while an installed application still declares their group.
  `--skip-group-containers` avoids the signature reads, `--no-entitlements`
  reproduces the engines' name-only view.
- `Scripts/fix-ui-testrun.py` repairs the `.xctestrun` that `build-for-testing`
  writes: its `UITargetAppPath` is `<products>/Debug/Sift`, without the `.app`
  suffix, so the UI runner cannot read the bundle identifier and exits before a
  case runs. `Scripts/verify.sh` runs the fixer and then launches the UI target
  with `-xctestrun`, because `-scheme`/`-testPlan` regenerate the plan.
- `Features/Settings/RuleCoverageSheet.swift` is the same audit in the app, built
  from a real scan (`RuleCoverageAnalyzer`) rather than a second implementation,
  and `Core/Rules/RuleDraft.swift` turns an uncovered folder into a validated
  rule draft the user can paste into their own rule file.
- `Core/Diagnostics/` is the read-only half of the product: providers that report
  what occupies space, an engine that applies protection and aggregates coverage,
  and a measurer of its own (`DiagnosticMeasurement.swift`) rather than
  `FileWalker`, whose job is producing cleanup candidates and which therefore
  refuses the protected locations the diagnostics exist to explain.
- `Features/StorageAnalysis` is the one storage page: it runs the storage
  analyzer for bytes and the diagnostics engine for meaning, under one button.
  There is no second "what is using my disk" page; a second one is how the
  numbers start disagreeing.
- `Core/Scanner/ScanIntent.swift` is the one place the differences between scan
  scopes live, and `AppEnvironment.runScan` is the one function that starts a
  scan. The scan page passes `.everything`; the chips (`ScanFilter` in
  `Features/Scan`) only choose which categories of that one result are shown.
  A page never assembles a request.
- `App/Shell/RootView.swift` is the icon rail: four primary destinations
  (overview, scan, apps, storage) plus the appearance switcher, the account
  entry, the language control and settings. Every entry is the same two pieces —
  the label from `SiftRailItemLabel` and the hover/selection fill with its
  leading selection mark from `siftRailItemChrome` — so the footer cannot drift
  into a second style of button. A footer control that opens a popover passes
  its open state as `isSelected`, so the item lights while its picker is up.
  The category filters that used to be sidebar entries live in the scan page now.
- Presentation goes on a concrete view, never on the conditional wrapper that
  chooses a style. `LanguageMenu`'s popover was attached to
  `Group { if case .rail … }` and, on `_ConditionalContent`, silently never
  presented: the rail's language picker did nothing while the appearance
  switcher's picker — attached to its own button — worked. `UITests` now presses
  the control and looks for the picker's rows, not just for the control.
- `Shared/DesignSystem/SiftTheme.swift` and `Shared/Components/SiftComponents.swift`
  are the design system. A page uses `SiftPageHeader`, `SiftGlassCard`,
  `SiftPrimaryButton`, `SiftSecondaryButton`, `SiftCheckbox` and
  `SiftLinkButtonStyle`; it does not introduce a second palette, a system-blue
  link or a surface that skips the glass layers. `SiftProgressRing` is
  indeterminate only where the engine reports phases rather than a fraction.

## Two preferences that are scan scopes

Both of these change what a scan *produces*, not what a list happens to display.
Filtering at display time was the tempting shortcut in each case, and it is wrong
for the same reason: the rows, the category totals and the report would then
describe different runs, and the numbers the user acts on are the totals.

- **Show hidden files.** Off means an entry whose name starts with `.` is not a
  candidate: `WalkOptions.skip_hidden` in the Rust walker, `FileWalker.Options.skipHidden`
  in the Swift one, and the measuring functions take the same flag so a directory's
  reported size is the part a cleanup would actually reclaim. A file inside a
  package or an uninstalled app's data directory is still counted, because the item
  is the whole directory.
- **Stale threshold.** A rule whose `usesStaleThreshold` is true takes its age
  from `ScanRequest.staleThresholdDays`; every other rule keeps the age it states,
  so `download-archives` stays at 90 days. `effective_min_age_days` /
  `effectiveMinAgeDays` resolve it identically in both engines, and a threshold of
  zero leaves each rule's own value in force. Defaults match the shipped table
  (30 days where the rule opts in), so neither engine's behaviour depends on
  whether the request carried the field.
