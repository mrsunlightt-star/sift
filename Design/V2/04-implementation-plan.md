# 04 — Implementation and acceptance plan

## 1. Non-negotiable safety constraints

This is a UI redesign, not a cleanup-engine redesign.

Do not change or bypass:

- File identity snapshots and post-await revalidation.
- Protected-path and system-application guards.
- Preflight approval and confirmation semantics.
- Security-scoped bookmark authorization.
- Rust / Swift FFI validation.
- Trash-based file movement and recovery behavior.
- Permission boundaries.
- Entitlement enforcement.

Do not use UI-only filtering as a security boundary. Core services must remain authoritative.

## 2. Existing code areas

| Area | Existing source |
|---|---|
| App shell and navigation | `App/Shell/RootView.swift` |
| Design tokens | `Shared/DesignSystem/SiftTheme.swift` |
| Shared components | `Shared/Components/SiftComponents.swift` |
| Overview | `Features/Dashboard/DashboardView.swift` |
| Scan workbench | `Features/Scan/SmartScanView.swift` |
| Apps / uninstall | `Features/Uninstaller/UninstallerView.swift` |
| Storage analysis | `Features/StorageAnalysis/StorageAnalysisView.swift` |
| Settings | `Features/Settings/SettingsView.swift` |
| Cleanup confirmation | `Features/JunkCleanup/CleanupConfirmationView.swift` |
| Cleanup execution/result | `Core/UI/CleanupExecutionView.swift`, `Core/UI/CleanupResultView.swift` |

## 3. Migration strategy

### Phase A — Design tokens and component primitives

1. Introduce explicit color roles: brand green, brand gold, action green, selected fill, neutral text/surface, and semantic risk roles.
2. Audit every use of old blue accent tokens. Do not replace text, fill, chart, risk, and decoration roles with one global green token.
3. Replace the default glass card treatment with simple surface/section primitives.
4. Keep compatibility wrappers during migration if many call sites depend on `SiftGlassCard`; remove them only after all pages compile and are visually verified.
5. Rework primary/secondary buttons, list rows, filter controls, badges, and page header.
6. Revisit the product mark in the shell; use the actual icon or a faithful simplified star mark.

### Phase B — Scan workbench

1. Implement the list-first layout.
2. Align selection summary with the cleanup model.
3. Make hidden selected rows explicit.
4. Preserve safe / review / protected rules.
5. Rework the preflight confirmation and result hierarchy without changing domain behavior.
6. Verify loading, paging, partial, cancelled, and failed states.

### Phase C — Overview and Apps

1. Replace the dashboard-like equal-card grid with one primary action / metric region and supporting facts.
2. Keep recommended items connected to the authoritative scan model.
3. Simplify the app list; keep useful metadata in the inspector.
4. Make app filters explicit and the full inventory discoverable.
5. Improve the empty inspector state.

### Phase D — Storage and Settings

1. Make the storage initial state compact and useful.
2. Preserve chart meaning, category consistency, and coverage warnings.
3. Reorganize settings groups and make permission explanations discoverable.
4. Keep reset and destructive preference changes explicit.

### Phase E — Polish and verification

- Light and dark appearances.
- 1024 / 1280 / wide window widths.
- Chinese and English first; long localized strings.
- Long paths, large numbers, zero results, partial results, large lists.
- VoiceOver labels and grouping.
- Keyboard navigation / focus.
- 44 pt hit targets.
- Increase Contrast, Reduce Transparency, Reduce Motion.
- Existing unit tests, UI tests, and cleanup-safety tests.

## 4. Component migration notes

- Avoid rewriting all call sites in one giant change.
- Introduce new primitives first, migrate one page at a time, and remove obsolete components only after search shows they are unused.
- Keep colors semantic and typed by role; do not allow arbitrary fill colors to become readable text colors.
- Reuse existing formatters and localization keys; do not hard-code user-visible numbers or English labels in the UI.
- Prefer native SwiftUI / AppKit controls where they improve accessibility and keyboard behavior.

## 5. Suggested implementation order

1. Scan page (highest usage and strongest test of the design direction).
2. Shared shell and navigation (coordinate with scan layout rather than design in isolation).
3. Overview.
4. Apps.
5. Storage.
6. Settings.
7. Confirmation, execution, and result polish as one connected flow.

The shell and scan page should be reviewed together in screenshots before migrating the remaining pages. Navigation width changes alter every page's available content width.

## 6. Acceptance criteria

V2 is not considered complete until:

- The light canvas is pure white, with no cool gray-white wash or ambient gradient.
- The icon green and gold remain recognizable but are not overused.
- The old blue and purple brand treatments are gone from primary UI.
- Ordinary content is not wrapped in glass cards by default.
- The scan list visually outweighs the inspector and decorative chrome.
- The user can understand selected, hidden-selected, review, and protected counts without ambiguity.
- Protected items never enter selection or cleanup totals.
- Confirmation reflects the preflight-approved plan.
- “Moved to Trash” is not mislabeled as freed disk space.
- Every primary action is clear, concise, and accessible.
- Keyboard, VoiceOver, contrast, text scaling, and Reduce Motion work.
- Existing cleanup, permissions, and file-operation safety tests continue to pass.
- No core cleanup or permission boundary is weakened by the redesign.

## 7. Review artifacts

The AI-generated images in `assets/` are inspiration / composition references only. Before implementation approval, create real SwiftUI previews or screenshots from the app with realistic sample states and run the acceptance checklist above.
