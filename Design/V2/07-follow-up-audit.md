# 07 — Follow-up audit and completion gate

> Updated: 2026-11-05
> Target: `design/sift-v2-ui`
> Purpose: record what is present in the branch, what remains unverified, and the safe order for the next implementation pass.

## 1. Branch integrity

The comparison against `main` on 2026-11-05 reports:

- `design/sift-v2-ui` is **1 commit ahead** and **7 commits behind** `main`.
- The merge base is `24955ac2a372cb9530999107feb86172e3e49e72`.
- The branch contains the V2 UI migration, but it does not contain all subsequent fixes on `main`.

Do not merge this branch or ship it as-is. First reconcile the seven newer mainline commits with the V2 changes, paying particular attention to overlapping shell, overview, scan, and uninstaller files. Keep the V2 work on this branch; do not rewrite `main` as part of this task.

## 2. Source-level state confirmed in this branch

The following are present in the branch source:

- `SiftTheme.swift`: separate icon-brand, functional-action, semantic-risk, text, surface, and selected-state roles; pure-white light canvas; dark appearance tokens.
- `SiftComponents.swift`: opaque surfaces instead of material blur/highlight/shadow, compact page header, quieter buttons, and a short opacity entrance transition.
- `RootView.swift`: horizontal sidebar, app icon in the shell, language and text-scale subtree refresh, layout direction, and Reduce Motion environment propagation.
- `DashboardView.swift`: a single primary action/metric region and supporting operational facts/lists.
- `SmartScanView.swift`: list-first workbench, risk groups, paging, selection state, keyboard row navigation, and responsive selection summary.
- `UninstallerView.swift`: application list plus inspector, App Management notice, and preflight-backed uninstall flow.
- `StorageAnalysisView.swift`: analysis scope, coverage and outcome notices, visualization/results, findings, and suggestions.
- Cleanup confirmation, execution, and result views remain separate stages of the same cleanup workflow.

This is a source inspection, not a claim that every state has been visually accepted at runtime.

## 3. Mainline reconciliation gate

Before adding more feature code:

1. Compare the branch versions of `RootView.swift`, `DashboardView.swift`, `SmartScanView.swift`, and `UninstallerView.swift` with current `main`.
2. Bring forward newer correctness and safety fixes without discarding the V2 visual structure.
3. Preserve the scanner, selection model, protected-path checks, preflight approval, file identity revalidation, permissions, entitlements, FFI, Trash movement, and recovery semantics.
4. Regenerate the Xcode project after adding or moving test files, as required by the repository workflow.
5. Keep the resulting merge/reconciliation in this design branch until tests pass.

## 4. Remaining visual and interaction acceptance

### Scan lifecycle

Capture and inspect real app states for:

- First run / no results.
- Preparing, scanning, and indexing.
- Ready with results.
- Partial result and permission-incomplete result.
- User-cancelled scan with retained results.
- Failed scan while a previous valid result exists.
- Empty result for a selected filter.
- Loading another page and expanded/collapsed risk groups.

For each state, confirm that the header, list, selection summary, and primary action describe the same model state. A partial or failed run must never look like a complete clean scan.

### Responsive layout

Verify at the supported minimum window size (960 × 640 pt), at 1024 pt and 1280 pt widths, and at a wide window:

- Sidebar remains usable without stealing the result list's width.
- Scan inspector moves to the bottom summary at the content-width breakpoint.
- Apps and Storage panes do not clip, overlap, or create horizontal scrolling.
- Confirmation and result sheets fit vertically and remain scrollable when paths or failure lists are long.

Do not raise the minimum window size merely to hide a layout defect.

### Appearance and accessibility

Test:

- Light and dark appearances, including selected, hover, disabled, warning, and destructive states.
- Chinese and English first; then all 34 shipped locales, including long German/Russian strings and right-to-left layout.
- All three text-size preferences.
- VoiceOver labels and grouping, keyboard navigation/focus, and 44 pt hit targets.
- Increase Contrast, Reduce Transparency, and both system and in-app Reduce Motion.

### Secondary surfaces

Review purchase/paywall, account/license, permission notices, confirmation, execution, result, retry, undo, and empty states against the V2 component rules. Keep native sheets and distinct warnings where they communicate a real boundary; remove decorative glass/card repetition only where it does not weaken comprehension.

## 5. Verification status

As of this audit:

- GitHub source files were inspected on `design/sift-v2-ui`.
- The branch comparison against `main` was performed.
- No local macOS build, Xcode test, or runtime screenshot was performed during this pass because the linked development Mac was offline.
- Therefore, V2 is **not accepted as complete** and this document does not mark any runtime-only item as passed.

Run the repository's current `Scripts/verify.sh --quick` and full verification workflow after mainline reconciliation. Record the actual test counts and whether the XCUITest cases executed; a runner that never starts is not a passing UI test. Capture screenshots from the built app in both appearances and at the minimum supported window size.

## 6. Completion definition

The V2 UI pass is complete only when:

- Mainline fixes are reconciled into this branch.
- All scan lifecycle and cleanup checkpoint states are visually consistent.
- Responsive layouts pass at minimum, medium, and wide sizes.
- All shipped locales and accessibility settings pass.
- Real app screenshots are reviewed against the written design rules.
- Current verification scripts pass, with executed test counts recorded.
- No cleanup, uninstall, permission, entitlement, or recovery safety boundary has changed unintentionally.
