# Working on Sift

Instructions for anyone — human or agent — changing this repository.

## Git workflow

**Commit directly to `main`. Do not create feature branches.** The owner of this
repository asked for a single-branch workflow: commit, then push to `main`.

Commit messages describe the change and, when relevant, the reason. No
co-authored or tool attribution lines.

## Before changing code

Run the bootstrap once per checkout:

```bash
Scripts/bootstrap.sh
```

It builds the Rust scanner core into `Bridge/macos-universal/libsift_ffi.a`
(SwiftPM and Xcode both link from that fixed path), regenerates the string
catalog, and regenerates `Sift.xcodeproj` from `project.yml`.

After changing `project.yml`, install XcodeGen if needed (`brew install
xcodegen`) and run `xcodegen generate --spec project.yml`. Commit the regenerated
project.

After changing anything under `Shared/Localization/`, regenerate the catalog and
its `.lproj` outputs with `python3 Scripts/generate-strings.py`. Never edit
`Localizable.xcstrings`, `LocalizationKey.swift` or `.lproj` files by hand.

## Before committing

```bash
Scripts/verify.sh
```

It runs, in order: Rust formatting and lints, the Rust test suites (including the
FFI contract tests), the benchmark build, the Swift build, the self-test suite,
the XCTest suite, and the app bundle. A commit should not land while any stage
fails.

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
    or a photo library.
11. **Path comparisons normalise `.`, `..` and the macOS symlink aliases**
    (`/var`, `/tmp`, `/etc`) before matching.

## Layout notes

- `Core/` is one library; `Features/` are separate libraries so a change to one
  feature cannot break another's build.
- `App/Entry` is the only file the app target and the SwiftPM executable share;
  everything else lives in `App/Shell` or below.
- `Tests/` runs under XCTest (`swift test`, Xcode) and also under
  `Scripts/run-tests.sh`, which supplies a small XCTest-compatible runner for
  machines with only the Command Line Tools.
