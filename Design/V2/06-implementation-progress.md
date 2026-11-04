# 06 — V2 implementation progress (`design/sift-v2-ui`)

> Updated: 2026-11-04  
> Branch: `design/sift-v2-ui`  
> State: first source migration pass; runtime verification pending.

**Scope note.** This file records the state of the `design/sift-v2-ui` branch's
own migration pass, which was written without a build, a test run or a
screenshot on the machine that produced it. It is kept here because it is a
second reading of the same specification and its "Still to do" list is useful;
it is not a description of `main`. What `main` actually contains — every page,
the verification numbers, the deviations from this pack and the reasons — is
[06 — Implementation record](06-implementation-record.md). Where the two
disagree about a page, the record describes the code and this file describes an
earlier attempt at it.

## Implemented in the V2 branch

### Design system
- Introduced explicit brand roles for icon green (`#00BF63`) and icon gold (`#FFBA36`).
- Introduced a darker functional action green (`#007E46`) for filled controls and readable text.
- Kept semantic safe / review / error colors independent from brand gold and brand green.
- Added neutral text roles and pale green selected / hover surfaces.
- Kept light canvas pure white; removed the glass highlight token from ordinary UI.
- Adjusted type sizes, row sizing, radii, sidebar width, and inspector width.
- Kept legacy token names as compatibility aliases while existing feature call sites migrate.

### Shared components and shell
- The legacy `SiftGlassCard` API now renders an opaque surface with a fine divider border; it no longer applies material blur, highlight gradients, or decorative shadows.
- Simplified page header, primary/secondary buttons, filter chips, and icon tiles.
- Replaced the staggered fade-and-rise entrance with a short opacity transition.
- Replaced the old vertical icon rail with a horizontal 190 pt sidebar.
- The sidebar now uses the actual application icon and horizontal icon + label navigation rows.
- Kept route identifiers and existing navigation actions.

### Pages
- **Overview:** one primary action/metric area, compact disk and cleanup metrics, and plain suggestion/activity lists.
- **Scan:** result list is no longer wrapped in a large card; selection inspector is plain and quieter; a compact bottom action summary is used below the content-width breakpoint.
- **Apps:** all installed applications are visible by default; list metadata is reduced to recent-use information; version/install date and bundle identifier are moved to the inspector; list and inspector use a lightweight two-pane layout.
- **Storage:** the Treemap remains a bounded visualization surface; scope, category detail, top directories/files, findings, and suggestions are plain grouped sections; top directories and files stack vertically for readable paths.
- **Settings:** groups now use headings, normal controls, spacing, and dividers rather than one bordered card per group.

## Deliberately retained surfaces

Not every boundary is being removed. A surface remains appropriate when it groups one distinct task or complex object:

- The storage Treemap and its associated visualization header.
- Native modal confirmation / execution / result surfaces.
- A stopped/failed scan summary or a permission notice when it needs a distinct warning boundary.

The goal is to remove decorative repetition, not to remove useful grouping.

## Still to do

1. Inspect and refine secondary scan states (start, running, partial, cancelled, permission and duplicate states) against the same visual system.
2. Review purchase/paywall and all modal sheets for color, spacing, and native appearance consistency.
3. Verify app-inspector layout and storage results at the minimum supported window size.
4. Check all 34 shipped languages for clipping and long text; check right-to-left layout.
5. Capture real app screenshots in light and dark mode.
6. Run the full verification scripts and Xcode UI tests on macOS.
7. Review VoiceOver, keyboard navigation, Reduce Transparency, Increase Contrast and Reduce Motion.

## Verification status

- Repository source reads and static structure inspections: performed.
- Live macOS build: **not run in this turn**.
- Swift / Xcode tests: **not run in this turn**.
- Runtime screenshots: **not captured in this turn**.

The linked development Mac was offline during this pass, so no local Xcode build or UI test run could be performed. A green GitHub commit is not evidence of a successful build. Run the repository's verification script and Xcode test target before merging or shipping.

## Safety boundary

This UI pass does not intentionally change scanner behavior, item classification, default selection rules, protected paths, uninstall ownership, preflight approval, file identity checks, permissions, entitlements, FFI, Trash movement, or recovery.
