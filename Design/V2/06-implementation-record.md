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
