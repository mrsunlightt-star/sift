# 03 — Remaining page specifications

## 1. Overview

### Purpose

The overview answers two questions immediately:

- What is the state of this Mac / the last known scan?
- What should I do next?

It is not a generic KPI dashboard and should not contain several cards with equal visual weight.

### Recommended hierarchy

1. Page title and meaningful scan status.
2. One primary action region.
3. A prominent reclaimable estimate only when backed by a valid scan report.
4. Three compact operational facts: disk usage, last scan, last cleanup.
5. Recommended work list.
6. Recent activity, lower in the hierarchy.

### First-run state

- Explain briefly what Sift scans.
- State that scanning is local if that remains true for the shipped implementation.
- Give one primary “Start scan” action.
- Avoid a large empty metric slot or an em dash that looks like zero.
- Do not render two identical start-scan actions.

### Results state

- Use one prominent number with its meaning (e.g. potential cleanup estimate), not a synthetic “Mac health score”.
- Distinguish safe and review-needed amounts.
- Provide one main action to open or continue the scan workflow.
- Recommended items should correspond to real rows in the current scan model.
- Do not make overview selection a second, competing selection system unless it commits through the same authoritative model.

### Busy / partial / failure states

- While scanning, provide a direct route to the scan progress page.
- Partial scans must be identified as partial.
- Failures must not look like a clean Mac or a zero result.
- A previous valid result may remain visible, but it must be visibly distinguished from the failed new run.

### Visual treatment

- No four-card dashboard grid.
- One clear primary content area, followed by compact metrics and a plain recommendation list.
- Brand green only on the main action and a few meaningful highlights.
- Gold star may identify a rare “recommended” section, but do not add a star to every row or heading.

## 2. Apps / Uninstaller

### Purpose

Help users understand installed applications, decide what they no longer need, and inspect associated files before uninstalling.

### Layout

Use a two-pane application-management layout:

- Left: searchable, sortable application list.
- Right: details for the currently selected app.

Keep the two-pane structure because it suits the workflow. Do not wrap both panes in oversized floating glass cards.

### List rows

Show only the facts that help the user choose:

- Application icon.
- Application name.
- Last-used status/date.
- Application size.

Version, install date, bundle identifier, team/group identifier, and detailed dates belong in the inspector or secondary detail.

Use sorting controls grouped by attribute and direction. Keep the current sort visible without making the control visually loud.

### Filters

Provide explicit filters such as:

- All applications.
- Large applications.
- Long-unused applications.
- Running applications (where useful).

Do not make the full app inventory depend on an opaque hidden threshold. If a default subset is used for performance or relevance, label it clearly and provide an obvious “Show all” action.

### Inspector

When selected, show:

- App identity, version and bundle identifier.
- Main bundle size.
- Confirmed related files.
- Review-needed related files, separate from confirmed files.
- Shared-container warnings.
- Running-app state and quit action.
- Clear uninstall action.

When no app is selected, use a restrained empty prompt or hide the inspector boundary. Do not show a large blank card.

### Uninstall checkpoint

The confirmation must show the app bundle and all associated items that the preflight actually approved. Do not hide shared or review-needed files. The page must distinguish the application bundle from related files.

No UI redesign may broaden the set of files considered safe to move.

## 3. Storage analysis

### Initial state

- Clear page title.
- Volume selector / scope.
- One brief explanation of what will be measured.
- One primary “Analyze” action.

Do not fill an otherwise empty page with a huge decorative start card.

### Results state

Prioritize:

1. A meaningful space-distribution visualization (Treemap is appropriate when the data supports it).
2. A compact category legend / exact values.
3. Largest directories and files.
4. Diagnostic findings and actionable suggestions.

Keep the visualization as the main visual object. Use a quiet surface only around a complex chart; ordinary text and findings should remain unboxed.

### Color use

- Keep category colors muted and stable between chart and list.
- Do not use the brand green and gold as arbitrary category colors.
- Preserve consistent category identity in chart legend and rows.
- Label unavailable and unmeasured space honestly.

### Scope and coverage

The user must be able to see whether the report includes the volume root and authorized folders. Partial coverage, denied permissions, or inaccessible volumes must be visible, not buried.

## 4. Settings

### Purpose

Make preferences discoverable without turning the page into an endless unstructured form.

### Recommended groups

1. General: launch at login, interface text size, appearance.
2. Scan scope: hidden files, authorized folders and volumes, ignored folders.
3. Cleanup safety: confirmation behavior and related safeguards.
4. Privacy and permissions: Full Disk Access and App Management explanations/status.
5. History and reports: retention, export, clear history.
6. Diagnostics: rule coverage, self-test, logs.
7. Account and license: entitlement state and activation.

### Layout

- Use a restrained native settings organization.
- Group titles and concise descriptions.
- Standard macOS controls wherever practical.
- Keep destructive/reset actions visually separate and require confirmation when they remove permissions, history, or other user choices.
- Avoid cards nested inside cards.
- If the page becomes too long, use category navigation or a compact in-page index rather than increasingly large cards.

## 5. Shared shell

### Navigation

- Horizontal icon + label rows.
- Main destinations: Overview, Scan, Apps, Storage.
- Settings and account in a separate lower group.
- Language control easy to reach but visually secondary.
- Current destination is clear through a pale green surface and green text/icon; no glowing selection animation.

### Page header

- Page title is the main anchor.
- Status appears only when it answers a real user question.
- Trailing actions are page-specific.
- Remove permanent decorative dots and repeated micro-labels.

### Empty states

- One concise explanation and one useful action.
- Avoid illustrations that occupy large space without adding information.
- Empty filtered results must describe the current filter, not claim the entire Mac is clean.

## 6. Cross-page consistency

- Use the same typography roles and spacing scale.
- Use the same action and semantic color roles.
- Keep row heights, alignment, and focus treatment consistent.
- Do not force every page into the same card grid.
- Let each page's main task determine its layout.
