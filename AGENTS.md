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
`-only-testing:SiftUITests`. Xcode 16.4's UI-test runner on this machine fails to
start about half the time, reporting

    Test target SiftUITests encountered an error (The bundle identifier for Sift
    couldn't be read. No such file or directory: ".../Debug/Sift".)

about a bundle that is present and correctly named. It is the runner, not the
tests: the same built products, the same `xctestrun` and the same command pass or
fail from one minute to the next, and the unit tests in the same plan always run.
(The `xctestrun` on a failing run still says `Sift.app`; the debug-dylib app
layout, the result-bundle location and the destination were each suspected and
each ruled out.) Running the targets apart is what stops a flaky runner from
being reported as a failing suite — and stops a real failure in the unit tests
from being written off as the runner. The UI target gets one retry, and every
attempt is printed. If both attempts fail the stage fails, and the log path is
the first thing to read.

## Before changing code

Run the bootstrap once per checkout:

```bash
Scripts/bootstrap.sh
```

It builds the Rust scanner core into `Bridge/macos-universal/libsift_ffi.a`
(SwiftPM and Xcode both link from that fixed path), regenerates the string
catalog, regenerates the Swift protection list, and regenerates `Sift.xcodeproj`
from `project.yml`.

After changing `project.yml`, install XcodeGen if needed (`brew install
xcodegen`) and run `xcodegen generate --spec project.yml`. Commit the regenerated
project.

After changing anything under `Shared/Localization/`, regenerate the catalog and
its `.lproj` outputs with `python3 Scripts/generate-strings.py`. Never edit
`Localizable.xcstrings`, `LocalizationKey.swift` or `.lproj` files by hand.

After changing `PROTECTED_HOME_CHILDREN`, `PROTECTED_PREFIXES`,
`PROTECTED_LIBRARY_CHILDREN`, `PROTECTED_PHOTOS_LIBRARY_SUFFIX`,
`SYMLINK_ALIASES` or `SYMLINK_ALIAS_TARGETS` in
`RustCore/crates/sift-rules/src/lib.rs`, regenerate the Swift half with
`python3 Scripts/generate-protection.py`. Never edit `Core/Rules/ProtectedPaths.swift`
by hand: it exists so the two engines cannot protect different sets of paths, and
`SYMLINK_ALIASES`/`SYMLINK_ALIAS_TARGETS` are one table read index for index, so
moving one without the other is rejected by the generator.

## Before committing

```bash
Scripts/verify.sh
```

It runs, in order: the generated-source checks, Rust formatting and lints, the
Rust test suites (including the FFI contract tests), the benchmark build, the
Swift build, the self-test suite, the XCTest suite, and the app bundle. A commit
should not land while any stage fails.

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
    `AppEnvironment.runScan(_:)`; the pages differ in the `ScanIntent` they pass
    and the category they show, not in how a scan runs or in what "a scan has run"
    means. Authorising a folder happens only in Settings, and every page that
    depends on a grant links there. Confirmation and the cleanup result come from
    the shell, so no page can reach a weaker flow by choosing a different entry
    point.
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
  none of it.
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
  scan. A page supplies an intent and renders its own categories; it does not
  assemble a request.

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
