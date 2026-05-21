# UI Polish — Right-Pane Width Resilience + Editor Status Footer

**Status:** Approved 2026-05-21 by user, ready for implementation planning.

**Goal:** Six small UI fixes bundled as one polish milestone. Right-pane filter rows degrade gracefully under width pressure; empty-state panes anchor their action bars at the top; the editor's floating page-count badge moves into a proper status footer; scene-navigator rows stop crowding sluglines.

**Why now:** Surfaced during normal use of the post-`milestone-history-rewind` build. None is severe in isolation — the writing experience works — but they collectively make the right pane feel unfinished at non-fullscreen widths and undermine the "focus editor" pitch when the page-count pill floats over manuscript text.

**Working title:** `milestone-ui-polish`.

**Conformance contract:** must not regress any test currently green (794 tests). No new manuscript-load entry point, no MCP tool changes, no editor binding contract changes, no op-log schema changes. This is a view-layer milestone.

---

## 1. Problems addressed

Six issues, three clusters.

### Cluster A — Filter rows don't degrade under width pressure
- **A1.** HistoryPane's filter row (All / Checkpoints / Edits / Annotations / External) wraps character-by-character at narrow right-pane widths (~260pt), producing a column of single characters per pill — unusable.
- **A2.** At fullscreen, the same row still hyphenates "Check-points" and "Annota-tions" into two lines; the trailing "Rewind…" header button truncates to "Re…". Even with room, the layout prefers wrapping/truncating over shrinking gracefully.
- **A3.** AnnotationsPane's filter row (All / Comments / Suggestions / Queries) shows the same pattern: "Queries" truncates to "Que…".

### Cluster B — Empty-state action bar drops to vertical center
- **B1.** LinkedResearchPane in its empty state vertically centers the action bar (segment picker) along with the "No linked research" placeholder. The action bar should always be top-anchored; the empty state should fill the remaining space below it. AnnotationsPane already does this correctly — it is the reference.

### Cluster C — Editor chrome overlaps content
- **C1.** The "0.3 pages" / "0.5 pages" badge floats at bottom-right of the manuscript and overlaps body text near the end of the visible content.
- **C2.** SceneNavigatorPane rows render the slugline plus "p.1" plus "½p" with the page metadata stacked vertically to the right of the slugline, crowding the row and competing visually with the slugline itself.

---

## 2. Architecture overview

One new shared SwiftUI view, one new editor-chrome view, targeted edits to four existing views.

### 2.1 New files

- `Maugham/Views/AdaptiveFilterRow.swift` — reusable horizontal segmented filter row, generic over a `FilterRowItem` protocol. Above the natural-fit threshold it shows full labels; below it shows SF Symbol icons with tooltip labels. Selection pill renders identically in both states.
- `Maugham/Views/EditorStatusFooter.swift` — thin always-on status row at the bottom of the editor pane, pulling from `SessionTracker`, `Document` page/word metrics (via the existing `GoalIndicatorState`), and current editor selection. **This view supersedes `GoalIndicatorView`**, which is the existing floating pill that today overlaps manuscript text.

### 2.2 Modified files

- `Maugham/Views/HistoryPane.swift` — `filterToolbar` adopts `AdaptiveFilterRow` for the All/Checkpoints/Edits/Annotations/External filter; the trailing "Rewind…" `Button` collapses to icon-only (`clock.arrow.circlepath` with a tooltip) when the row falls into icon-only mode, so the truncated "Re…" disappears.
- `Maugham/Views/AnnotationsPane.swift` — adopt `AdaptiveFilterRow` for the All/Comments/Suggestions/Queries/CraftNotes filter; remove the local row rendering.
- `Maugham/Views/LinkedResearchPane.swift` — restructure body to top-anchor the action bar; empty state fills remaining space.
- `Maugham/Views/ProjectWindow.swift` — `contentColumn(...)` currently uses `ZStack(alignment: .bottomTrailing) { editorPane(...); GoalIndicatorView(...) }`. Restructure to `editorPane(...).safeAreaInset(edge: .bottom) { EditorStatusFooter(...) }` (or equivalent VStack). The `GoalIndicatorView` overlay is removed.
- `Maugham/Views/SceneNavigatorPane.swift` — row layout becomes a single line: slugline left, compact "p1 · ½" caption right at smaller size and dim color.

### 2.3 Deleted code

- `Maugham/Views/GoalIndicatorView.swift` — its rendering logic moves into `EditorStatusFooter`; the `GoalIndicatorState` model in `Maugham/Models/GoalIndicatorState.swift` stays as the data source for the footer.
- Local filter-row rendering inside `HistoryPane` and `AnnotationsPane` that `AdaptiveFilterRow` replaces.

---

## 3. AdaptiveFilterRow — the shared control

### 3.1 Surface

```swift
protocol FilterRowItem: Hashable, Identifiable {
    var label: String { get }
    var symbolName: String { get }  // SF Symbol name for icon-only mode
    var tooltipLabel: String { get }  // usually == label
}

struct AdaptiveFilterRow<Item: FilterRowItem>: View {
    let items: [Item]
    @Binding var selection: Item
    // ...
}
```

### 3.2 Width-fit logic

Measure the natural width of the full-labels row using a hidden measuring pass (`background { HiddenMeasuringRow() }` and a `PreferenceKey`). If the natural width exceeds the available width, switch to icon-only mode. No hard pt threshold baked in — the threshold is derived from the actual content.

Selection state renders the same in both modes: a filled `accentColor` background with rounded corners on the selected segment. The "All" segment, if its label is ≤3 characters, may stay as text in icon-only mode (special case — `AdaptiveFilterRow` exposes a `keepShortLabels: Int = 3` parameter).

### 3.3 Icon mapping

| Pane | Filter | SF Symbol |
|---|---|---|
| History | All | (text "All", kept short) |
| History | Checkpoints | `flag.fill` |
| History | Edits | `pencil` |
| History | Annotations | `bubble.left` |
| History | External | `arrow.down.left` |
| Annotations | All | (text "All", kept short) |
| Annotations | Comments | `bubble.left` |
| Annotations | Suggestions | `pencil.line` |
| Annotations | Queries | `questionmark.circle` |
| Annotations | Craft notes | `book` |

The HistoryPane color-key legend stays as it is today and continues to color-code the same items.

### 3.4 Tests

- Snapshot tests at three widths (200, 320, 480pt) for both `HistoryPane` and `AnnotationsPane` filter rows, asserting:
  - 200pt: icon-only mode, "All" kept as text, selection pill on first item.
  - 320pt: same as above unless measured natural width fits — accept either state, assert no truncation and no wrapping.
  - 480pt: full-labels mode, no wrapping, no truncation.
- Logic test for the width-fit threshold: given a mock label set and a mock available width, `AdaptiveFilterRow.shouldShowIcons(...)` returns the expected boolean.

---

## 4. Empty-state anchoring (Cluster B)

### 4.1 Pattern

Every right-pane segment view must use the shape:

```swift
VStack(spacing: 0) {
    PaneActionBar()            // top-anchored
    Group {
        if itemsEmpty {
            EmptyStateView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ItemList()
        }
    }
}
```

The empty-state's `maxHeight: .infinity` (or equivalent) ensures it fills the remaining space without dragging the action bar with it. `AnnotationsPane` already follows this shape and is the reference.

### 4.2 Audit list

Confirm-and-fix all right-pane segment views during implementation:

- `InspectorView.swift` (Inspector segment) — confirm shape.
- `LinkedResearchPane.swift` (Linked Research segment) — known broken, fix.
- `OutlinePane.swift` (Outline segment) — confirm shape.
- `AnnotationsPane.swift` — reference, no change expected.
- `HistoryPane.swift` — confirm shape.

For any pane that wraps its body in a centering container, restructure to the pattern above.

### 4.3 Tests

A layout test per pane that constructs the pane in its empty state at a known frame, then asserts the action bar's frame origin is at `y == 0` (or within a tolerance of the natural inset).

---

## 5. EditorStatusFooter (Cluster C1)

### 5.1 Layout

A thin row (~24pt tall) anchored at the bottom of the editor pane, above any window chrome. Three sections, evenly distributed:

```
[ left: session metric        ]  [ center: cursor / element ]  [ right: page progress ]
```

- **Left.** Session word count and time range pulled from `SessionTracker`. Format: `520 words · session 18:00–19:07`.
- **Center.** Current paragraph ID + element type. Format: `¶ pdyx · CHAR` (mirrors the gutter element label in screenplay mode; in prose mode shows just the paragraph ID). Diagnostic, low-key — `secondaryLabelColor` at ~11pt.
- **Right.** Page progress for screenplay (`0.3 / 90 pages`) or word progress for prose (`4,320 / 80,000 words · today: 520`). Uses the exact format strings the existing `GoalIndicatorView.screenplayLabel` and `GoalIndicatorView.proseLabel` produce — no new formatting decisions in this milestone.

All three sections in `secondaryLabelColor` at 11pt to read as quiet chrome, not editing surface.

### 5.2 Visibility

- Visible by default.
- **Hidden** in no-chrome mode (`⌘\`, the `maughamToggleNoChrome` notification path) — when the writer asks for a clean surface, the footer goes with the rest of the chrome. This is a deliberate behavior change vs. today's `GoalIndicatorView`, which stays visible in no-chrome mode and is the visible offender in the screenshots.
- Hidden in full-screen focus mode (`⌘⇧F`) — same reasoning.
- The existing `userPreferences.goalIndicatorsVisible` preference continues to gate the footer (no rename; the underlying user intent is the same). Settings → General label updates from "Show goal indicators" to "Show editor status bar". Default stays on.
- Same binder-segment gating as the current `GoalIndicatorView` site: only when `binderSegment == .manuscript || binderSegment == .scenes`. Trash and Find segments don't show the footer.

### 5.3 What stays unchanged

- The `⌘S` save-flash overlay — different purpose (transient celebration of a checkpoint).
- The Project Statistics window — different purpose (deep-dive analytics).

The footer is the continuous, glanceable surface; the others remain their specialized roles.

### 5.4 Tests

- Snapshot of the footer in screenplay mode (renders page progress).
- Snapshot of the footer in prose mode (renders word progress).
- Test that the footer is omitted from the view hierarchy when no-chrome mode (`⌘\`) is active.
- Test that the footer is omitted in full-screen focus mode (`⌘⇧F`).
- Test that the footer is omitted when the `goalIndicatorsVisible` preference is off.

---

## 6. SceneNavigatorPane row layout (Cluster C2)

### 6.1 Current vs new

Current: a `HStack { Text(slugline); VStack { Text("p.1"); Text("½p") } }` — the trailing VStack has the page badge stacked vertically next to the slugline.

New: a single `HStack { Text(slugline); Spacer(); Text("p1 · ½").font(.caption2).foregroundStyle(.secondary) }`. One line, the slugline owns the row, the metadata is a quiet right-aligned caption.

### 6.2 Format

- "p1" (no period) for compactness. Reads naturally on one line.
- "·" separator between page and fraction.
- "½" / "¼" / "¾" / "1" — keep the existing fraction glyph vocabulary; just shrink and dim.

### 6.3 Tests

A snapshot of `SceneNavigatorPane` with two rows and one row of differing length confirms the new layout renders.

---

## 7. Out of scope

Captured to make the boundary explicit:

- **Annotations vs History onboarding affordance.** Carry-forward from `milestone-editing`; still open, but doesn't belong in a layout polish milestone. Will land as its own focused commit.
- **Dark-mode propagation to side panes.** Recurring carry-forward (lost twice). Re-check after this milestone but not a target.
- **Inline annotation marks in the editor.** Separate feature on the Group 2 roadmap.
- **Settings to customize the status footer's contents.** Default is opinionated. Could come later if a writer asks; not load-bearing.
- **Scrubber pan/zoom for >1k ops.** History-rewind carry-forward, unrelated.
- **Project-scope rewind.** History-rewind carry-forward, unrelated.

---

## 8. Risks and known unknowns

- **SwiftUI measurement loops.** The natural-width measurement in `AdaptiveFilterRow` uses a `PreferenceKey`. Done naively this can cause layout passes to feed back into themselves. Mitigate by measuring once on appear / size change, not every body re-eval. If the measurement approach proves tricky, fall back to a coarse character-count heuristic (sum of `label.count` × glyph-width estimate vs available width) — same UX, simpler implementation.
- **SF Symbol availability.** Targets macOS 14+, so the symbol set above is available. Confirm at implementation time that no chosen symbol is iOS-only or 17+.
- **No-chrome / focus-mode wiring.** The footer's visibility needs to react to the existing chrome-visibility and full-screen-focus state. Confirm the existing `maughamToggleNoChrome` / `maughamToggleFullScreen` notification flows expose a `Bool` observable from `ProjectWindow` (or wherever the footer is mounted). If not, wiring it up is the only meaningful new state plumbing in this milestone.
- **Page/word metric availability.** The `Document` may or may not expose page metrics directly today; the goal indicator does compute them. Worst case, lift that computation into a shared helper used by both the goal indicator and the footer.

---

## 9. Acceptance criteria

A writer can:

- Resize the right pane from very narrow (~200pt) to fullscreen and see the HistoryPane and AnnotationsPane filter rows transition cleanly between icon-only and full-label modes, with the selection pill always visible and no wrapping or truncation at any width.
- Open a project with no linked research (or any other empty right-pane state) and see the segment picker / action bar anchored at the top of the pane, with the empty state placeholder filling below.
- Look at the bottom of the editor and see a status row with session words, current paragraph/element, and page/word progress — no badge floating over manuscript text.
- Press `⌘\` (no-chrome) or `⌘⇧F` (full-screen focus) and see the status row disappear with the rest of the chrome.
- Open the scene navigator and see sluglines on single uncrowded rows with quiet trailing page metadata.

All 794 existing tests continue to pass. New tests added per sections 3.4, 4.3, 5.4, 6.3.
