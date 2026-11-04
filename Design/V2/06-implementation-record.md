# Sift V2 — implementation record

What was built for `Design/V2/01`–`05`, what was decided along the way, and what
is deliberately still open. Read this together with `04-implementation-plan.md`
(what to protect) and `05-component-specifications.md` §10 (the order the work
was done in).

The short version: the token layer, the shell and all six pages were converted in
one pass, `Scripts/verify.sh` is green, and nothing on the protected list in
`04` §1 was touched — no change to the cleanup model, the scanner, pre-flight,
file operations, Trash handling, bookmarks, App Management, Full Disk Access,
entitlements or the FFI.

## 1. What moved

| Area | Before | After |
| --- | --- | --- |
| `Shared/DesignSystem/SiftTheme.swift` | one blue palette, `13 pt` for nearly every label | V2 roles with measured ratios, a seven-step type ladder |
| `Shared/Components/SiftComponents.swift` | glass cards, gradient buttons, travelling selection slider | `SiftSection`, flat surfaces, 40 pt primary button |
| `App/Shell/RootView.swift` | 112 pt icon rail | 190 pt sidebar with icon-left rows |
| `Features/Scan/SmartScanView.swift` | 1933 lines, list in a glass card | 2303 lines, list + inspector/bottom bar |
| `Features/JunkCleanup/CleanupConfirmationView.swift` | 354 | 431 |
| `Core/UI/CleanupResultView.swift` | 571 | 652 |
| `Core/UI/CleanupExecutionView.swift` | 103 | 112 |
| `Features/Dashboard/DashboardView.swift` | 611 | 799 |
| `Features/Uninstaller/UninstallerView.swift` | 833 | 1007 |
| `Features/StorageAnalysis/StorageAnalysisView.swift` | 892 | 1087 |
| `Features/Settings/SettingsView.swift` | 828 | 1038 |
| `Features/Settings/RuleCoverageSheet.swift` | 319 | 396 |
| `Features/Purchase/PurchaseView.swift` | 375 | 410 |
| `Core/UI/ScanCategoryPreview.swift` | grid of material cards | plain tinted glyph + name |

New files: `Tests/V2PaletteTests.swift` (the palette is now a test, not a
comment), `Design/V2/assets/screenshots/`.

## 2. The token layer

`SiftColor` gained a `// MARK: - Sift V2 roles` block. Every role carries the
pair it was measured at in its doc comment, and `Tests/V2PaletteTests.swift`
pins those numbers in both appearances, so a role that drifts fails the suite
instead of the user's eyes reading it against a white page.

The rule the palette is built on: **the bright brand green is a fill and
decoration token, and text is the darker green.** `brandGreen #00BF63` is
2.43:1 on white — it is the app icon's colour, it belongs on the mark, the
progress fill and a 6–12 % wash, and nowhere near a sentence. `actionGreen
#007E46` is 5.16:1 and is what a link, a label and a glyph use.

Dark mode is not an inversion of those numbers. The light-mode values were
reused for *surfaces* and replaced for *text*: `actionGreen` becomes `#2ECC7A`
(8.68:1 on the dark canvas), `safeTextColor` `#4FD07E`, `reviewTextColor
#E8B34A`, `dangerTextColor` `#F58A8A`, `quietText` `#96A19A`. The inline pair
`actionFill`/`onActionFill` follows the same logic — light mode fills `#007E46`
and writes white on it (5.16:1), dark mode fills `#00BF63` and writes `#0B1E14`
(7.13:1) — because `#007E46` under white text is 3.52:1 on the dark canvas and a
button nobody can read is not a button.

One defect the palette test caught, and the reason the test measures against a
*wash* and not only the canvas: dark `quietText` was first `#8A948E`, which is
5.80:1 on the canvas but **4.31:1 on the dark selected row**, because the
selection wash is lighter than the ground. `#96A19A` is 5.06:1 there and
6.80:1 on the canvas.

Legacy names (`accent`, `accentDeep`, `baseGlass`, `glassBorder`, …) are now
aliases onto the V2 roles rather than a second palette. That is what made a
page-by-page migration safe: an untouched page came out green and readable
instead of wrong, and the alias set is what remains to be deleted once nothing
reads it.

## 3. Geometry

| Token | V2 | Was |
| --- | --- | --- |
| `sidebarWidth` | 190 | 112 |
| `sidebarRowHeight` | 44 | 58 |
| `rowHeight` / `rowHeightTwoLine` | 52 / 56 | 44 / — |
| `summaryColumnWidth` / `Min` | 272 / 240 | 330 / — |
| `buttonHeight` | 40 | 36 |
| `fieldHeight` | 34 | — |
| `controlCornerRadius` | 8 | 12 |
| `cornerRadiusXL` | 12 | 20 |
| `pageTitle` / `metricPrimary` | 28 / 42 | 20 / 32 |
| `sectionHeading` / `supporting` | 16 / 12 | 15 / 13 |

The scan page's column resolves from the **content** width, not the window
width (`ScanWorkspaceLayout.resolve(availableWidth:)`,
`Features/Scan/SmartScanView.swift`): 272 pt at ≥1000, 240 pt at 860–1000, and
below 860 the inspector becomes a bottom action bar under a full-width list.
At the 960 pt minimum window the sidebar leaves 770 pt of content, which is why
a fixed 330 pt column could not stay.

## 4. Surfaces

Ordinary page content is `SiftSection(.plain)`: no fill, no border, no shadow.
`SiftGlassCard` and `SiftPanel` survive with their exact public API and now
render `SiftSection(.outlined)`, so the two sheets that are genuinely floating
(`CleanupConfirmationView`, the rule-coverage sheet) keep a surface and every
other page keeps whitespace.

What was removed from the product, not merely restyled: the material stack, the
top-edge highlight, the glow shadow, the 20 pt card corner, the gradient
primary button, the travelling rail selection slider, the staggered card
entrance, the decorative dot before the header's status line, the gradient
divider, the coloured activity dots on the overview and the six coloured group
dots on the scan page. The one gradient left in the design system is the
indeterminate progress arc (`Shared/Components/SiftComponents.swift`), where the
moving segment is the only thing that reads as "in progress".

`ScanCategoryPreview` lost its per-category card in the same spirit: eight
options do not become eight boxes because a card component exists.

## 5. Deviations from the pack, each with a reason

1. **Dark mode inverts the *role*, not the hex** (§2). The pack names light-mode
   values; re-using `#007E46` under white text on `#111713` is 3.52:1.
2. **The header's left eyebrow is sentence case, no tracking.** The SVG studies
   letter-space "SIFT / OVERVIEW"; `01` says "no all-caps eyebrow labels or wide
   tracking by default", and the rule is the specification, the drawing is an
   illustration. Every `.textCase(.uppercase)` and `.tracking()` is gone.
3. **The Apps page's scope chips got their own copy.** They borrowed the scan
   page's `large`/`old`, which are file words on a list of applications. Three
   keys were added in all 34 languages (`apps.filter.large`, `apps.filter.unused`,
   `apps.noMatches`).
4. **Sidebar preference rows are 44 pt, not 32.** `01` also says minimum hit
   target 44×44; the compact-control range loses to that.
5. **The Apps inspector is 320 pt, a local constant.** The pack names no
   inspector token for that page, and inventing one in `SiftMetrics` for a single
   caller is worse than a named constant beside its use.
6. **The purchase page states `purchase.unavailable` where the store would be.**
   This build wires no licence service (`Core/App/AppEnvironment.swift` throws
   `licenseServiceUnavailable`), so the page must not imply a purchase succeeded.
7. **`SiftHeroCard` kept its name.** It is the purchase page's own block; renaming
   it would have touched a page with no design change to make.

## 6. What was preserved on purpose

Every item below was on the protected list and was verified in the diff, not
assumed: `CleanupModel.selection` and its duplicate-keeper rule, `LazyVStack`
paging (`pageSize` 100), `PreflightReport.ready` as the approved snapshot,
`CleanupOutcome.headline` deciding a result page's title, protected rows never
selectable, partial/cancelled/failed never reading as complete, the three-valued
App Management probe and a real move overriding it, both dates printed with a
year and both directions for every sort axis, `sharedWith`/`groupIdentifier`,
diagnostics read-only with snapshots reported and never deleted, the coverage
page listing what the scan produced (synthesized rows included), the three
refusal reasons staying apart, and a stopped scan keeping its index.

`Core/` was not edited for this work except `Core/UI/CleanupResultView.swift`,
`Core/UI/CleanupExecutionView.swift` and `Core/UI/ScanCategoryPreview.swift` —
presentation only.

## 7. Verification

`Scripts/verify.sh`, all nine stages: Rust 291, Swift XCTest **409**, self-test
265, Xcode unit target **409**, XCUITest 8 (ran, 8 executed), app bundle built
and signed. Verdict: every check passed.

Two things this pass found that had nothing to do with appearance:

- **A stale generated project.** `project.yml` gives `SiftTests` `sources: Tests`,
  which XcodeGen expands into an explicit file list, so a new test file is
  invisible to the Xcode target until `xcodegen generate` runs. Measured as
  "409 methods against a 402-case unit target". `AGENTS.md` now says so next to
  the XcodeGen instructions.
- **A test that only compiled under a full Xcode.** `XCTAssertEqual(_:_:accuracy:)`
  does not exist in the Command-Line-Tools shim that `Scripts/run-tests.sh`
  supplies, so `Tests/V2PaletteTests.swift` broke the suite on a machine without
  Xcode while `swift test` stayed green. It now asserts
  `XCTAssertLessThanOrEqual(abs(measured - expected), tolerance, …)`, which every
  XCTest-compatible runner has.

Screenshots (`assets/screenshots/`), captured from the built app rather than
from a preview: `overview-light-1280.png`, `overview-light-compact.png`,
`overview-dark.png`, `apps-dark.png`. They are evidence for the surfaces and the
type ladder; they are not a substitute for the checklist in `01` §Accessibility.

## 8. Open

- **Long-localisation and RTL passes** (German, Russian, Arabic, Hebrew) at
  1024 pt, and Increase Contrast / Reduce Transparency / Reduce Motion. The
  layout is built for them (every label truncates rather than pushes, the
  inspector becomes a bottom bar) but no run has been made with those
  translations actually installed.
- **XCUITest coverage of the new shell and pages.** The eight existing tests
  still pass and still exercise the identifiers they name; nothing new drives the
  sidebar's popovers or the scan page's inspector.
- **Release blockers that predate this work and are unaffected by it**:
  Developer ID signing, notarisation, and a real licence service — see
  `RELEASE.md` and `Research/security-audit-2026-11.md`.
- **Legacy aliases** (`accent`, `baseGlass`, `glassBorder`, `SiftGlassCard` as a
  card) are still referenced by a few call sites and can be deleted once the
  repo-wide search is empty. `05` §10 step 5 is that step.

## 9. Second pass — the studies were redrawn

On 2026-11-04 the `design/sift-v2-ui` branch was force-pushed with a second
revision of the three vector studies and a progress note of its own. The written
specification did not move (`01`–`05` are byte-identical to this branch), so what
followed was a **visual** reconciliation: the code already agreed with the words,
and five places where it disagreed with the pictures were settled in the pictures'
favour because the pictures were the more specific statement of the same intent.

What came across, and why each one is a real improvement rather than a restyle:

1. **A subtitle slot in the page header.** `SiftPageHeader` gained
   `subtitle: String?` under the title. The overview had been printing today's
   date above its own title while its facts band printed "Last scan — Today ·
   06:55" — the same day, twice, in two formats. The header now says what the page
   *is* (`Mac status and available actions`), and a date lives where its number
   does. The scan page uses the same slot for `96 items · 2.68 GB can be
   reclaimed`, because `05 §6` allows a status only when it says something the
   title does not, and "some locations could not be read" already owns the status
   line.
2. **The facts band.** Five label-left/value-right rows read as a settings table;
   the studies draw two columns of label-above-value with a vertical hairline
   between and one horizontal rule between the pairs. The same five facts now sit
   in a 2 × 2 band (`Last scan` / `Last cleanup`, `Disk used` / `Results`), and the
   vertical rule is drawn only where two cells exist, so a page with no result set
   does not end a row with a line and nothing after it.
3. **The clock time with the day.** `Today` cannot tell a 09:42 run from a 14:10
   one, and the result set behind the number is exactly that distinction.
   `SiftFormat.relativeDateTime` composes the existing localised relative day with
   `SiftFormat.time`, so `Today · 09:42` needs no new date vocabulary in any of the
   34 languages.
4. **One filled button per page.** The studies give the overview a solid primary
   plus a text link; the code had a primary plus a bordered secondary, and the
   scan page had a filled `Rescan` in the header competing with the filled
   `Move to Trash` in the inspector. `View scan results` is now a
   `SiftLinkButtonStyle` link with a chevron, `Rescan` is a ghost button, and the
   second copy of `View scan results` that sat in the suggestions header was
   deleted — two identical labels 400 pt apart are two controls for one
   destination.
5. **The selected filter chip is a solid pill.** `SiftFilterChip`'s selected state
   was a pale wash with green text; the studies make it `actionFill` with
   `onActionFill` text, which measures 5.16:1 light and 7.13:1 dark. The fill is
   also a shape difference, which is what `01` §Accessibility asks for when a
   state must not rest on hue alone.

Two sentences came with the drawings and are now in all 34 languages
(`Scripts/generate-strings.py` is still the only source): `overview.purpose`
(what the overview is for), `overview.suggestionsNote` (recommendations describe a
*previous* run, and the safety check runs again before anything moves) and
`scan.header.ready` (the counts-and-bytes line). The catalog went from 483 to 486
keys.

Deliberate deviations from this revision, recorded rather than silently ignored:

- **No all-caps page eyebrow.** The redrawn studies still carry `SIFT / OVERVIEW`
  above the title; `01` §Typography retires all-caps eyebrow labels with wide
  tracking by default, and a written rule outranks a drawing. The 12 pt semibold
  rank line stays.
- **No coloured dot on the group headers.** The drawings mark `Safe to clean` /
  `Needs your confirmation` / `Protected` with a small dot. The list already
  carries a word-based `RiskBadge` on every row and a word in every group header;
  a dot would be the only risk signal that is colour-only.
- **The running-scan card keeps its outline.** A scan in progress is a distinct
  task with its own ring, phase and cancel action, which is the case `05` §4 keeps
  a surface for. Flattening it would leave a 4-step progress ring floating in the
  page.
- **`/var` and `~/.Trash` rows in the skipped-locations card still explain
  themselves in place**; the studies do not draw that card at all.

Verification for this pass: `swift build` green; `swift test` **411 tests, 0
failures** (two new: `test_aRelativeDayCarriesItsClockTime`,
`test_theStudySentencesResolveTheirArguments`); `Scripts/verify.sh` Rust 291,
Swift XCTest 411, self-test 265, Xcode unit target 411, app bundle signed. The
first full run of the pass was green end to end including
`XCUITest 8 (ran, 8 executed)`; the later runs on the same machine reported the UI
target as `did not run`, which is the intermittent automation grant
`AGENTS.md` describes — every other stage stayed green, and the UI target is
re-run when the machine can run it.

That run also taught the gate a shape it had been mis-reading: a bundle for an
attempt whose log holds only "Timed out while enabling automation mode" records
`totalTestCount 1, failedTests 1`, because Xcode 16.4 counts the runner's own
failure as a failed test. The stage read the count first and printed
`FAILED (UI target: 1 test(s) failed)` for a run in which no case executed, which
sends a reader looking for a test that does not exist. It now asks the log first
(`runner_did_not_start`) and reports the failure as the runner's, then falls
through to the did-not-run path. `AGENTS.md` records the measurement.

Screenshots replaced from the running app: `overview-light-1280.png`,
`scan-results-light-1280.png`, `overview-dark.png`, `scan-results-dark.png`.
