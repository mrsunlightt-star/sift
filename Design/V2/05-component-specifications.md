# 05 — Component-level implementation specification

This document translates the visual foundation into concrete changes to the current SwiftUI component system. It is deliberately incremental: the first pass should change visual primitives without changing domain behavior.

## 1. Current shell and layout constraints

Verified in the current `main` source:

- Window minimum: 960 × 640 pt.
- Default window: 1280 × 820 pt.
- Current navigation rail: 112 pt.
- Current rail item: 76 × 58 pt, with icon above label.
- Current summary column: 330 pt.
- Current page padding: 28 pt.
- Current page content maximum: 1180 pt.
- Current type roles: 32 pt display, 20 pt title, 15 pt section title, 13 pt body and caption.
- `SiftGlassCard` builds a layered material/tint/highlight/border/shadow surface.
- `SiftCanvasBackground` already renders a flat canvas; light mode is pure white.

Do not change window minimum size as a side effect of redesign. The existing 960 × 640 target is useful, but the new shell and scan inspector need responsive behavior.

## 2. Token migration

### Add explicit roles

The design system should expose distinct semantic tokens instead of one generic accent being reused for text, controls, selection, charts, and decoration.

Proposed roles:

- `brandGreen` = `#00BF63`
- `brandGold` = `#FFBA36`
- `actionGreen` = `#007E46`
- `actionGreenHover` = `#006B3C`
- `actionForeground` = white in light appearance
- `selectedFill` = `#E8F7EF`
- `selectedBorder` = `#B9E6CC`
- `canvas` = `#FFFFFF` in light appearance
- `mainText` = `#202722`
- `secondaryText` = `#5F6962`
- `subtleText` = `#68716B`
- `divider` = `#E5EAE6`
- `controlFill` = `#F6F8F6`
- `hoverFill` = `#F2F6F3`

Semantic roles (safe / review / danger / protected / information) remain independent of brand colors.

### Compatibility rule

Do not delete `SiftColor.accent`, `accentFill`, `accentDeep`, or other legacy properties in the first commit. Search and migrate call sites by semantic role. Keep temporary aliases only while they are still needed, with clear deprecation comments. Remove aliases after the final call-site audit.

Do not blindly replace the word “blue” with “green”: a chart series, risk state, ordinary glyph, or text role may need a different treatment.

## 3. Component map

| Current component / file | V2 behavior |
|---|---|
| `SiftCanvasBackground` — `SiftComponents.swift` | Keep flat pure white in light mode; remove any ambient wash if introduced later. |
| `SiftGlassCard` — `SiftComponents.swift` | Stop using as the default content wrapper. Introduce a plain section/surface primitive; retain a compatibility wrapper during migration. |
| `SiftPanel` — `SiftComponents.swift` | Re-evaluate whether it is still needed after sections are migrated. |
| `SiftPageHeader` — `SiftComponents.swift` | Reduce visual chrome; status is optional and meaningful; remove permanent green dot and gradient divider. |
| `SiftPrimaryButton` — `SiftComponents.swift` | Solid action green, no glow, no gradient highlight, concise action label. |
| `SiftSecondaryButton` — `SiftComponents.swift` | Prefer native macOS button treatment, quiet border only when necessary. |
| `SiftFilterChip` — shared components | Prefer a compact segmented/filter control; no oversized capsule collection. |
| `SiftMetricPill` — shared components | Use neutral metadata treatment by default; semantic color only when it conveys state. |
| `NoticeBanner` — shared components | Keep semantic role; simplify border/background and avoid large colored panels. |
| `SiftSelectableRow` / `ScanItemRow` | Become the primary list primitives: compact two-line hierarchy, visible focus, quiet hover, clear selection. |
| `SiftRailItemLabel` / `IconRailView` — `RootView.swift` | Convert from vertical icon rail to horizontal icon + label sidebar rows. |
| `SiftMark` — `RootView.swift` | Replace blue gradient mark with the real app icon or a faithful monochrome/star-derived mark. |

## 4. Surface component specification

Introduce a simple component such as `SiftSection` / `SiftContentSurface` with explicit variants:

- `plain`: no fill, no border, no shadow; content uses whitespace and separators.
- `outlined`: white fill, 1 pt neutral border, 10–12 pt radius, no shadow.
- `subtle`: optional neutral/green-tinted low-contrast fill for a small, meaningful group.
- `floating`: reserved for sheets, popovers, and transient overlays.

Default variant for page content must be `plain`, not `floating` or glass.

A page should not become a grid of outlined cards just because a reusable card component exists. Use a surface only when it groups a distinct task or complex visualization.

## 5. Navigation component specification

### Geometry

- Sidebar width: target 190 pt (allow 184–196 pt).
- Main navigation row height: 42–46 pt.
- Icon: 16–18 pt.
- Label: 13–14 pt, medium.
- Row horizontal padding: 12 pt.
- Row radius: 8 pt.
- Gap between icon and label: 10 pt.

### States

- Default: neutral text/icon, no fill.
- Hover: neutral `#F2F6F3`.
- Selected: `#E8F7EF`, text/icon `#007E46`, optional 2–3 pt leading indicator.
- Focus: visible system-appropriate focus ring.
- Disabled: readable secondary treatment.

Primary destinations remain Overview, Scan, Apps, Storage. Settings and Account stay in a distinct footer group. Appearance/language are window-level preferences and must not look like primary destinations. Purchase CTA must not masquerade as the currently selected page.

### Responsive layout

At the existing 960 pt minimum window width, the 190 pt sidebar leaves 770 pt for page content. The Scan inspector therefore cannot remain a fixed 280–330 pt column at every width.

Use a layout decision based on available content width:

- Wide: results list + 260–280 pt inspector.
- Intermediate: inspector narrows to approximately 240–260 pt.
- Narrow: inspector moves to a bottom summary/action bar; list gets the full width.

The breakpoint should be measured from available content width, not hard-coded solely from the outer window width.

## 6. Page header specification

- Header height should be compact and consistent.
- Page title is the primary anchor.
- Status appears only if it conveys last scan, partial/cancelled state, volume, or another decision-relevant fact.
- A trailing action is page-specific (e.g. Rescan).
- Remove the permanent decorative dot before status.
- Replace the gradient divider with a plain hairline or no divider where spacing already separates the header.
- Do not force every page to show a metric pill at the top right.

## 7. Button specification

### Primary

- 36–40 pt visual height.
- 8 pt radius.
- Solid `#007E46`, white text.
- No drop shadow glow, top highlight, or gradient.
- Hover: modest darkening to `#006B3C`.
- Pressed: subtle native-scale feedback only.
- Disabled: lower fill emphasis while keeping label readable.
- Keep action text short (e.g. “开始扫描”, “移入废纸篓”).

### Secondary

- Native macOS button where practical.
- Avoid multiple competing filled buttons in the same action group.
- Use text/link style for low-priority actions.

### Destructive / irreversible

- Semantic red for permanent deletion or dangerous irreversible actions.
- Moving to Trash should not be styled or described as permanent deletion.

## 8. List component specification

The list is a first-class component family in Sift.

- 48–52 pt for a compact single-line row.
- 54–60 pt for a two-line row.
- Name 14 pt, medium.
- Path / metadata 12 pt, secondary.
- Size 14 pt, medium, monospaced digits and right aligned.
- Risk label 11–12 pt, compact, semantic.
- Row divider `#E5EAE6`.
- Hover fill `#F2F6F3`.
- Selected fill `#E8F7EF`.
- Minimum pointer and keyboard hit target 44 × 44 pt.
- Row body and checkbox must have distinct behaviors.
- VoiceOver should announce a coherent row summary, not six unrelated nested controls.

Use `LazyVStack` / existing paging where it is appropriate. Do not replace the current paging model with an unbounded eager VStack.

## 9. Scan inspector specification

Width: 260–280 pt on wide screens.

It should contain:

1. Selected bytes.
2. Selected item count.
3. Selected Safe count.
4. Selected Review count.
5. Hidden selected item count, when applicable.
6. One sentence on Trash/recovery.
7. Primary action.

Protected items have a separate informational count only if useful. Never add protected entries to selected count or bytes.

The inspector should use plain sections and separators. A pale green surface may distinguish the primary action summary, but the entire inspector should not become a floating glass card.

## 10. Implementation sequencing and safeguards

1. Add new tokens and primitives without deleting old ones.
2. Convert the shell/sidebar and page header; verify width behavior.
3. Convert the Scan list and inspector; preserve selection model and paging.
4. Convert Overview, Apps, Storage, Settings.
5. Remove unused legacy components and aliases only after a repository-wide search.
6. Capture real SwiftUI screenshots and compare against the SVG studies.
7. Run `Scripts/verify.sh --quick` and the full verification workflow as required by the release process.

Do not modify cleanup model semantics, scanner results, preflight, file operations, Trash handling, bookmarks, App Management, Full Disk Access, entitlements, or FFI as part of this component migration.
