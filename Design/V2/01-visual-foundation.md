# 01 — Sift V2 visual foundation

## 1. Brand color source

The palette starts with the current Sift app icon supplied by the product owner. The dominant sampled colors are:

| Token | Hex | Role |
|---|---|---|
| Brand green | `#00BF63` | Icon identity, small brand accents, selected decorative marks |
| Brand gold | `#FFBA36` | Star identity and rare brand highlights |

Do not replace these with blue or purple. Do not use both at full saturation in every section.

### Functional green

| Token | Hex | Role |
|---|---|---|
| Action green | `#007E46` | Primary action fill, important links, selected text/icon when contrast is required |
| Action green hover | `#006B3C` | Hover / pressed state |
| Selected green wash | `#E8F7EF` | Selected navigation or row background |
| Selected green border | `#B9E6CC` | Optional subtle selection boundary |
| Brand green wash | `#EAF8F0` | Occasional brand-tinted surface |

The exact icon green is too bright for small white text on a filled button. Measured contrast against white is approximately 2.43:1 for `#00BF63`; the darker `#007E46` is approximately 5.16:1. Use the darker action token for filled controls and readable text.

### Neutral palette

| Token | Hex | Role |
|---|---|---|
| Canvas | `#FFFFFF` | Main light-mode background; keep pure white |
| Surface | `#FFFFFF` | Ordinary content surface |
| Main text | `#202722` | Headings and primary content |
| Secondary text | `#5F6962` | Supporting information |
| Quiet text | `#68716B` | Metadata; never use for critical instructions without contrast verification |
| Divider | `#E5EAE6` | List separators and section rules |
| Control well | `#F6F8F6` | Search field / subtle input backgrounds |
| Hover neutral | `#F2F6F3` | Secondary hover feedback |

Pure white is a fixed product decision for the light canvas. Do not introduce a cool gray-white page background or ambient gradient. Surface separation should come from whitespace, typography, and hairline dividers.

### Semantic status palette

Brand gold is not the warning color. Brand green is not automatically the safe-state color. Keep semantic roles independent from brand roles.

| Semantic role | Text / icon | Background |
|---|---|---|
| Safe / completed | `#286D41` | `#EAF6EE` |
| Needs review | `#8A5A00` | `#FFF5E3` |
| Error / dangerous | `#B23A3A` | `#FCEEEE` |
| Protected / unavailable | `#5F6962` | `#F3F5F3` |
| Informational | `#46564B` | `#F3F6F3` |

Risk always has a word and, where useful, an icon. Never communicate risk by hue alone.

## 2. Color usage rules

- Most of the interface remains white, black/charcoal, and restrained neutral gray.
- Use action green for the primary action and a small number of selected states.
- The brighter icon green is for the logo, small brand details, and occasional large decorative shapes only.
- Gold is reserved for the star mark and very limited brand emphasis. Do not use it for warnings, selected rows, links, or primary buttons.
- Avoid a rainbow of category icons. Most category glyphs should be neutral; semantic state colors should be reserved for state.
- Do not tint every heading, icon, chip, divider, or metric green.
- Verify each text/background pair in both appearances against WCAG contrast targets.

## 3. Dark appearance

The dark appearance shares the same semantic roles; it is not a direct inversion of the light palette.

Initial direction (to be measured in implementation):

| Token | Hex |
|---|---|
| Canvas | `#111713` |
| Surface | `#191F1B` |
| Elevated surface | `#202923` |
| Divider | `#2B342E` |
| Main text | `#F1F5F2` |
| Secondary text | `#A8B2AA` |
| Brand green | `#00BF63` |
| Brand gold | `#FFBA36` |

Dark-mode action buttons may use the brighter brand green with dark foreground only after contrast testing. Do not assume white text works on the bright green.

## 4. Typography

Use the macOS system font. Do not introduce a decorative display font or use a font family to create artificial personality.

| Role | Target size | Weight |
|---|---:|---|
| Page title | 28 pt | Semibold |
| Primary metric | 40–44 pt | Semibold |
| Section heading | 16 pt | Semibold |
| Secondary heading | 14 pt | Medium |
| Body | 14 pt | Regular |
| Supporting copy | 12 pt | Regular |
| Compact metadata | 11–12 pt | Regular |

Rules:

- Body and supporting text must differ in both size and visual emphasis; do not make both 13 pt.
- Use monospaced digits for file sizes, counts, dates, and progress values that update.
- Keep paths readable but visually secondary.
- Avoid all-caps eyebrow labels and wide tracking as a default pattern.
- Keep the existing three-step interface text-size preference, but verify that all new components honor it.
- Support longer localized strings without truncating primary actions.

## 5. Spacing and geometry

Base spacing scale: 4 / 8 / 12 / 16 / 24 / 32 pt.

| Element | Target |
|---|---:|
| Compact control height | 32–34 pt |
| Standard button height | 36–40 pt |
| Search field height | 34–36 pt |
| Dense list row | 48–52 pt |
| Two-line list row | 54–60 pt |
| Minimum interactive hit target | 44 × 44 pt |
| Compact control radius | 6 pt |
| Button / field radius | 8 pt |
| Content group radius | 10–12 pt |
| Sheet radius | Native system behavior |

Avoid oversized 20–24 pt card corners throughout the app. Use a small number of consistent radii and let macOS controls retain native shapes where appropriate.

## 6. Surfaces and containers

### Ordinary page content

- No blur or material stack.
- No top-edge glass highlight.
- No soft glow.
- No decorative shadow.
- Use a white canvas, spacing, and separators.

### Grouped content

- Use a section title and divider.
- Use a light neutral well only when the group needs a visible boundary.
- Use a card only when the group is a distinct task, data visualization, or inspector.

### Floating surfaces

Native sheets, popovers, menus, and transient overlays may use platform materials and shadows. Glass is a floating-surface treatment, not the default surface of every page.

## 7. Components

### Primary button

- Action green fill: `#007E46`.
- White foreground.
- 36–40 pt target height, with at least 44 pt hit area where practical.
- 8 pt radius.
- No glow or prominent drop shadow.
- Hover/pressed state uses a restrained darkening.
- Label contains the action only; counts and size live adjacent to it.

### Secondary button

- Prefer native macOS button styles.
- Use a subtle border or neutral background only when needed.
- Do not give secondary actions the same visual weight as the primary action.

### Destructive action

Use semantic red and explicit wording for irreversible actions. A move-to-Trash action is not the same as permanent deletion.

### Search and filter

Prefer native text fields and segmented controls where possible. Keep filters compact and avoid oversized capsule chips.

### Risk badge

Small icon + short localized label. No large colored lozenges or decorative pills.

### List row

- Name and path are the normal two-line hierarchy.
- Size is right-aligned and uses monospaced digits.
- Risk is a compact label.
- Row hover is subtle.
- Selection is a light green wash, not a large saturated fill.
- Detail is revealed on demand; do not repeat long explanations in every row.

## 8. Navigation and window

- Target sidebar width: 184–196 pt.
- Primary destinations: Overview, Scan, Apps, Storage.
- Use icon-left / label-right horizontal rows.
- Selected destination: pale green wash and a restrained green indicator.
- Settings and account belong in a separate lower group.
- Language remains easy to access but is not styled like a primary destination.
- Retire the blue gradient square mark in the shell; use the actual Sift icon or a faithful simplified star mark.
- Initial minimum content width target: approximately 1000 pt; verify all layouts rather than assuming a fixed width.
- On wide windows, keep the content column readable instead of stretching every element to the edges.

## 9. Motion

Keep only motion that explains a state change:

- Page transition: 120–180 ms subtle fade.
- Row expansion: 180–240 ms.
- Selection: 120–180 ms.
- Numeric update: numeric text transition.
- Scan phase: brief state transition, not a celebratory animation.
- Cleanup result: clear and restrained completion feedback.

Remove staggered card entrances, glow pulses, oversized scale effects, and decorative loops. Every animation respects Reduce Motion.

## 10. Accessibility and quality bar

- Minimum 44 × 44 pt hit area for interactive controls.
- Maintain keyboard focus visibility and keyboard navigation.
- Use correct VoiceOver labels, values, and grouping.
- Risk is never color-only.
- Validate contrast in both light and dark modes.
- Test 1024 pt, 1280 pt, and wide window sizes.
- Test Chinese and English; also test long German/Russian strings if those localizations remain shipped.
- Verify Reduce Transparency, Increase Contrast, and Reduce Motion settings.
