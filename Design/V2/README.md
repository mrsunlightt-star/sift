# Sift V2 — UI / Visual Design

> Status: design direction, page specification, and implemented (see 06)
> Branch: `main`  
> Scope: macOS application UI only; no changes to scanner, file-operation, entitlement, permission, or cleanup-safety behavior.

## Design decision

Sift V2 is a **clean, refined, efficient native macOS utility**. It should feel carefully crafted without looking like a generic SaaS dashboard, an AI-generated template, or a clone of CleanMyMac.

The design is anchored in the existing Sift app icon:

- Brand green: `#00BF63`
- Brand gold: `#FFBA36`
- Main light appearance canvas: pure white `#FFFFFF`

The icon colors are brand identifiers, not colors to spread indiscriminately across every control. Action green is a darker derivative, `#007E46`, so white button text remains readable.

## Read in this order

1. [01 — Visual foundation](01-visual-foundation.md)
2. [02 — Scan and cleanup experience](02-scan-and-cleanup.md)
3. [03 — Remaining page specifications](03-page-specifications.md)
4. [04 — Implementation and acceptance plan](04-implementation-plan.md)
5. [05 — Component-level implementation specification](05-component-specifications.md)
6. [06 — Implementation record](06-implementation-record.md) — what was built, what was decided, what is open
7. [06 — Implementation progress (`design/sift-v2-ui`)](06-implementation-progress.md) — the branch's own first pass, kept as a second reading

## Visual explorations

The SVGs below are repository-ready vector redraws of the agreed visual direction. They are design studies, not production screenshots or exact interaction prototypes. Their sample text and numbers are illustrative; the written specifications are authoritative.

They were redrawn on 2026-11-04 (second revision, on `design/sift-v2-ui`): the navigation rows are 44 pt with a leading indicator, the primary region carries no card border, the overview states its dates as a two-column band, and the filter row marks the selected scope with a solid action-green pill. Where the redraw and the written specification disagree — the all-caps page eyebrow above the title — the specification wins, and `main` follows it.

| Overview concept A | Overview concept B |
|---|---|
| ![Overview concept A](assets/sift-v2-overview-concept-a.svg) | ![Overview concept B](assets/sift-v2-overview-concept-b.svg) |

![Scan results concept](assets/sift-v2-scan-results-concept.svg)

## Implemented screenshots

Captured from the built app, not from a preview: the overview and the scan
results in both appearances, the overview at a compact width, and the Apps page
in the dark appearance. See [06 — Implementation record](06-implementation-record.md)
§7 and §9; the second-pass screenshots were taken after a real scan on the
development machine, so the numbers in them are that Mac's.

| Overview, light | Overview, dark | Apps, dark |
|---|---|---|
| ![Overview in the light appearance](assets/screenshots/overview-light-1280.png) | ![Overview in the dark appearance](assets/screenshots/overview-dark.png) | ![Apps in the dark appearance](assets/screenshots/apps-dark.png) |

| Scan results, light | Scan results, dark | Overview, compact |
|---|---|---|
| ![Scan results in the light appearance](assets/screenshots/scan-results-light-1280.png) | ![Scan results in the dark appearance](assets/screenshots/scan-results-dark.png) | ![Overview at a compact width](assets/screenshots/overview-light-compact.png) |

## Product principles

1. Efficiency before decoration.
2. Trust before delight.
3. Typography and spacing create hierarchy.
4. Native before novel.
5. Brand without over-branding.
6. Visual refactoring must not weaken cleanup safety.

## Decisions

| Area | Decision |
|---|---|
| Product character | Refined, quiet, professional macOS utility |
| Light canvas | Pure white |
| Brand colors | Icon green and icon gold |
| Existing blue brand treatment | Retire as a brand treatment |
| Purple redesign direction | Do not continue it |
| Glass / blur | Remove from ordinary page content; reserve for native floating surfaces |
| Cards | Reduce substantially; ordinary lists and sections should not be boxed |
| Motion | Functional, brief, and restrained |
| Main workbench | Scan results list is the visual and functional center |

## Not in scope

- Rewriting the Rust scanner or Swift file-operation service.
- Changing scan scope, default selection, protection, or file movement policy.
- Changing entitlement or purchase policy.
- Treating the vector studies as final pixel specifications.

## Change log

- 2026-11-03: V2 direction established from the user-provided app icon and the preference for pure white over cool gray-white.
- 2026-11-03: Scan workflow and all page specifications expanded; visual studies added.
- 2026-11-04: Implemented. Token layer, shell and all six pages converted; `06`
  records the decisions, the measurements and what remains open.
