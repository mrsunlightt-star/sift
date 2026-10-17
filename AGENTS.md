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
`xcodebuild -version` succeeds.

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
`PROTECTED_LIBRARY_CHILDREN` or `PROTECTED_PHOTOS_LIBRARY_SUFFIX` in
`RustCore/crates/sift-rules/src/lib.rs`, regenerate the Swift half with
`python3 Scripts/generate-protection.py`. Never edit `Core/Rules/ProtectedPaths.swift`
by hand: it exists so the two engines cannot protect different sets of paths.

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
    (`/var`, `/tmp`, `/etc`) before matching.
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
