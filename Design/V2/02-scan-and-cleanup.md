# 02 — Scan and cleanup experience

The Scan page is the main workbench of Sift. It should read like a carefully designed file-management tool, not a dashboard assembled from cards.

## 1. User goals

A user arriving here should be able to answer, in this order:

1. What did Sift find?
2. Where is it?
3. Why is it considered safe, review-needed, or protected?
4. What is selected?
5. What exactly will happen when the user proceeds?

The list is the page's primary visual object. Summary and actions support it; they must not compete with it.

## 2. Page structure

### Header

- Title: Scan.
- One trailing action: Rescan when a result is available.
- Status text only when it conveys useful state (last scan, partial scan, stopped scan, failed scan).
- Avoid a permanent decorative status dot.

### Filter row

Retain the current meaningful filters:

- All
- Junk
- Large files
- Old files
- Duplicates

Use a compact native segmented control or a quiet horizontal filter row. Counts and sizes may be shown as secondary values, but do not force each filter into a large capsule.

### Work area

Wide layout:

- Main results list takes approximately 70–75% of the usable content width.
- A 260–290 pt selection/cleanup inspector sits to the right.
- The inspector is separated by spacing or a fine vertical divider, not by a second large floating card.

Narrow layout:

- Below approximately 1000 pt of content width, allow the inspector to become a bottom action summary.
- Do not compress the list into unreadable columns to preserve a fixed right rail.

## 3. Result grouping and rows

Retain the three domain risk groups:

1. Safe
2. Needs review
3. Protected

Do not merge semantic risk with category. Category says what kind of content it is; risk says what action is permitted.

### Row anatomy

The common row contains:

- Selection control.
- Item/category name.
- Path or concise scope explanation.
- Size, right-aligned.
- Small risk label.
- Disclosure affordance when additional detail exists.

Recommended row height:

- One-line compact row: 48–52 pt.
- Two-line standard row: 54–60 pt.

Use a consistent baseline and alignment. Keep name and path in a stable left column; keep size and risk aligned on the right. Long explanations move to the detail view.

### Selection behavior

Preserve existing domain rules:

- Safe items may be selected by default according to the current product policy.
- Review items are not silently selected by default.
- Protected items are never selectable and never enter the cleanup plan.
- A protected count is informational; never include it in selected count or cleanable bytes.
- The summary always derives from the same authoritative selection model as the confirmation plan.
- If selected items are not currently visible because of collapsed groups or paging, state how many are hidden.
- “Select all” must name and apply to a clearly defined scope (current filter / visible items / all eligible items). Do not leave different bulk-selection entry points with different semantics.

### Row interaction

- Clicking the checkbox changes only selection.
- Clicking the row body opens the item's detail/inspection surface where applicable.
- Keyboard selection and navigation must remain available.
- Keep the full row's text readable when the pointer is not hovering.

## 4. Detail inspection

The default row should remain compact. An expanded detail or inspector should show relevant facts such as:

- Full path.
- Category and risk.
- File count (if the item represents a directory).
- Why Sift classified it.
- Whether the item is expected to be regenerated.
- Whether it is a duplicate set, associated residue, or a special case.
- Any warning that changes the user's decision.

Do not repeat the same multi-line description on every row.

## 5. Right-side selection summary

The inspector is an operational summary, not a marketing panel.

It contains:

- Selected total bytes.
- Selected item count.
- Selected safe count.
- Selected review count.
- Count of hidden selected items.
- One concise Trash/recovery explanation.
- Primary action.

The summary must not present protected items as selected or cleanable.

Primary action label: a concise action such as “Move to Trash” / localized equivalent. Place count and size adjacent to the button, not inside a long button label.

If no item is selected, explain why the action is disabled. Do not make the control disappear without explanation.

## 6. Confirmation and execution

The final confirmation is a trust checkpoint.

Before action, show:

- Exact count and total size of ready-to-move items.
- A concise summary of destination paths.
- A way to inspect the exact items.
- Protected and skipped counts as separate, explicit facts.
- A clear statement that items are moved to Trash and can be restored before Trash is emptied.
- Cancel and confirm actions with concise labels.

Continue to use the existing preflight-approved plan and existing safety rules. The UI must never construct a weaker plan from displayed rows or stale selection state.

During execution:

- Show progress in truthful terms (e.g. moved N of M).
- Offer soft cancellation only if the operation layer supports it safely.
- Do not invent a percentage, ETA, or reclaimed disk space.
- State that items were moved to Trash, not that disk space has already been released.

## 7. Result and recovery

The result view should make these distinctions clear:

- Items moved to Trash.
- Items skipped because they no longer exist.
- Items that failed and need attention.
- Protected items that were not moved.
- Whether the Trash can still restore the batch.

Do not call moved bytes “freed space” unless an actual disk-capacity measurement supports the claim. Keep retry, reveal, report export, and recovery actions clear and context-sensitive.

## 8. Scan lifecycle states

Design and validate each state separately:

- First run / no results.
- Preparing.
- Scanning.
- Indexing.
- Ready.
- Partial result.
- User-cancelled with retained results (where supported by the model).
- Failed.
- No results for the current filter.
- Loading another page of results.
- Permission denied / incomplete scope.

A partial or stopped scan must not be presented as a complete scan.

## 9. Visual hierarchy

Priority order:

1. Result rows.
2. Selected total and primary action.
3. Risk group headings.
4. Category filters.
5. Metadata and explanatory copy.

The right inspector must be visually quieter than the list. Use dividers and spacing before introducing more containers.

## 10. Mockup caveat

The file `assets/sift-v2-scan-results-concept.webp` is a visual exploration. Its sample counts are illustrative and may not be internally consistent. The protected group in that mockup must not be interpreted as part of selected items. The written interaction rules in this document are authoritative.
