# The split-view tie-break on macOS 27 — spike (2026-09-19)

Task 1 of `docs/superpowers/plans/2026-09-19-macos-27-shell-slice.md`. **No
production file was changed.** The instrument is
`MaughamTests/SplitViewTieBreakSpikeTests.swift`, marked a spike in its own
header; Task 3 may delete it once what it establishes is re-pinned by a real
test.

## Where the two OSes' numbers come from

| | |
|---|---|
| **27** | This Mac — macOS 27.0 (26A428), Xcode 27.0 (27A266a), `MacOSX27.0.sdk`, 1470pt display. Every number below was measured by the spike, twice (two runs, identical). |
| **26** | CI run **35446195343**'s sibling on `main`, run **35444948746** (2026-09-19, `macos-26` + Xcode 26.6), artifact `TestResults-Mac.xcresult`, downloaded and read with `xcresulttool get test-results tests`. A GREEN run records no widths, so 26's column is read off **which assertions held** — each named in the table — plus the constraint-conflict logs that run captured verbatim. |

The spike prints to a file rather than to stdout: a `print` from the xctest host
does **not** reach `xcodebuild`'s stdout, and the xcresult carries no console
log (`xcresulttool get log --type console` → *No console log available*).
Measured here; it cost one wasted run.

## The table

A three-column `NavigationSplitView` built from production's own floors
(`ProjectWindow.binderColumnFloor` / `centreColumnFloor` / `sidebarInset`) and
production's own `effectiveDetailColumnWidth`. The writer's wish is 320
throughout; the column's effective width is **320** in a 1200pt window and
**312** in a 1000pt one. *before* is the whole split with a neutral pane,
*after* is the same split once the demanding pane is swapped in.

### Production's spelling today — `.navigationSplitViewColumnWidth(w)` alone

| pane shape | window | before `[binder centre detail]` | **after** | 26 |
|---|---|---|---|---|
| (a) unbreakable MINIMUM (`.fixedSize()`, intrinsic 593.5) | 1200 | `[240 879 320]` | `[240 879 **593.5**]` | **column wins** — `test_theFixedColumnWinsAgainstAnUnbreakablePane` and `test_theWidthSurvivesAPaneSwitch` both Passed on run 35444948746, and both drive exactly this shape |
| (a) | 1000 | `[207 687 312]` | `[207 687 **593.5**]` | as above |
| (b) large IDEAL only (truncating row in a flexible frame — `SetAsideRecordsDisclosure`'s shape) | 1200 | `[240 879 320]` | `[240 879 **320**]` | not measured on 26 — no shipped test drives this shape, and a green run cannot be asked a question nobody put to it |
| (b) | 1000 | `[207 687 312]` | `[207 687 **312**]` | as above |
| (c) `.frame(minWidth: 560)` | 1200 | `[240 879 320]` | `[240 879 **560**]` | not measured on 26, same reason |
| (c) | 1000 | `[207 687 312]` | `[207 687 **560**]` | as above |

### The same, on production's ACTUAL shape

`detailColumn` is not a bare pane — it is `HStack { detailResizeHandle; pane }`,
the handle an 8pt gutter. The regression reproduces there and the demand is the
pane's minimum **plus the handle**:

| pane shape | window | after |
|---|---|---|
| (a) | 1200 / 1000 | `593.5 + 8 = ` **601.5** |
| (b) | 1200 / 1000 | **320 / 312** — held |
| (c) | 1200 / 1000 | `560 + 8 = ` **568** |

`UIState.detailColumnWidth` was written **zero** times in all 48 rows. Nothing
about this touches the stored wish; it is purely what the column is laid out at.

## The mechanism, in one paragraph

`navigationSplitViewColumnWidth(w)` gives the split item a MinSize and a MaxSize
of `w`, and the pane's content contributes a minimum-width demand of its own. On
macOS 26 the item's `NSSplitViewItem.MaxSize` won that conflict and the column
came out at `w` whatever the pane wanted; on macOS 27 the content's minimum wins
and **the column resolves to `max(w, the pane's minimum width)`**. Every number
above is that sum exactly — 593.5 for a `.fixedSize()` label whose intrinsic
width is 593.5, 560 for a declared `.frame(minWidth: 560)`, 601.5 and 568 for
the same two behind production's 8pt handle. The flipped tie-break is
specifically **minimum versus declared width**: a pane with a large IDEAL and a
small minimum — shape (b), which is `SetAsideRecordsDisclosure`'s shipped shape
— moves the column not at all, at either window size. So the brief's reading
("the PANE's own demand") is right, and the demand in question is the pane's
FLOOR, never its preference. The five tests that read 528 all drive shape (a);
528 is the intrinsic width of `DetailColumnWidthTests`' own long label, the way
593.5 is the intrinsic width of the spike's.

## The mitigations

Five spellings tried, each across all three shapes and both window widths. All
of them hold the column at its effective width (320 / 312) in **every** cell:

| spelling | holds the column | note |
|---|---|---|
| `.frame(minWidth: 0, maxWidth: w).clipped()` | ✓ | the plan's mitigation 1 |
| `.frame(minWidth: 0, maxWidth: w)` — no clip | ✓ | so **`.clipped()` is not load-bearing for LAYOUT**. It is still wanted: without it a `.fixedSize()` child draws past the frame into the centre column. |
| `.frame(width: w)` | ✓ | the plan's mitigation 2 |
| `.frame(width: w).clipped()` | ✓ | |
| `.frame(width: w).clipped()`, on `HStack { handle; pane }` | ✓ | **the one that matters** — production's real composition |
| `.frame(minWidth: 0, maxWidth: w).clipped()`, on the same `HStack` | ✓ | |

The canary, run under each spelling at 1200pt with the wish at 300:

```
production            expected=300  got=593.5  PANE WINS
productionWithHandle  expected=300  got=601.5  PANE WINS
clippedContent        expected=300  got=300    COLUMN WINS
maxWidthOnly          expected=300  got=300    COLUMN WINS
fixedFrame            expected=300  got=300    COLUMN WINS
fixedFrameClipped     expected=300  got=300    COLUMN WINS
fixedFrameWithHandle  expected=300  got=300    COLUMN WINS
maxWidthWithHandle    expected=300  got=300    COLUMN WINS
```

**Either mitigation restores all six `DetailColumnWidthTests` numbers with their
assertions unchanged** — five of them because the column is once again given
exactly the width it asked for, which is what those five pin. The sixth is a
different mechanism; see below.

## The sixth red — the 7pt is the sidebar inset, and it is real

`test_hidingThePaneGivesTheProseWhatTheBinderDoesNot` asserts
`centre == container − sidebar − ProjectWindow.sidebarInset` (8pt). Measured on
27, with the hidden arm in the detail slot:

| window | container | binder | centre | split's own frames | observed inset | drift |
|---|---|---|---|---|---|---|
| 1200 | 1200 | 240 | 959 | `[0+240  0+1199  1200+0]` | **1.0** | +7 |
| 1000 | 1000 | 240 | 759 | `[0+240  0+999  1000+0]` | **1.0** | +7 |

The gap the split leaves between the binder's content and the prose's is **1pt
on 27 and 8pt on 26** (26's value is what makes that assertion green on run
35444948746, within its 2pt accuracy). Nothing else drifted: the detail column
holds **0** under `ProjectWindow.hiddenDetailColumn` at both widths, so that
static is untouched by any of this.

`ProjectWindow.sidebarInset = 8` is not only a test constant — it is a term in
`effectiveDetailColumnWidth`'s affordability sum, so on 27 the window reserves
7pt it no longer needs and the column is 7pt narrower than it could be. Over-
reserving is the conservative direction and is correct on 26, which is still the
deployment target.

## Recommended Task 3 contract

1. **The change.** In `ProjectWindow.detailColumn`, bind the effective width
   ONCE and apply it twice — `.frame(width: w).clipped()` on the `HStack`,
   then `.navigationSplitViewColumnWidth(w)`. `.frame(width:)` over
   `maxWidth:`: both were measured to hold, and the one-argument spelling
   states the same number the column modifier states, so there is no second
   interval for a later reader to reason about. `.clipped()` for drawing
   overflow, not for layout — say so in the comment, because the measurement
   above says a reviewer who deletes it will see every test stay green.

2. **Bind it once, or the existing census goes red.**
   `test_theRightColumnAsksForAWidthAndNotARange` counts lines containing
   `Self.effectiveDetailColumnWidth(persisted: detailColumnWidth,` and requires
   exactly **1**. A second spelled-out call satisfies the layout and fails that
   test. `let w = Self.effectiveDetailColumnWidth(…)` at the top of the
   `@ViewBuilder` keeps the count at one and is the honest shape anyway.

3. **`DetailColumnWidthTests`' harness takes the same spelling.** It composes
   its own detail column (`DetailColumnHarness.detailColumn`); left as it is,
   the six tests would measure a column the app no longer has. The harness's
   `.range` arm — the planted offender — must NOT get the frame: it exists to
   keep the two rows of the original diagnosis reproducing.

4. **The planted-offender control is a source census, not a mounted case.** A
   mounted "the pane wins without the frame" assertion is OS-dependent (green
   on 27, red on 26) and CI is on both sides of this slice. Pin it instead as:
   the file binds one effective width and applies it to BOTH
   `.frame(width:` and `.navigationSplitViewColumnWidth(`, with a planted
   offender that has the column modifier and no frame. That is OS-independent,
   and it is the thing a later author would actually undo.

5. **The sixth test.** Do not widen it to a 7pt tolerance — assert the claim
   rather than the number: the prose takes everything the binder does not, up
   to the declared inset. `container − sidebar − centre` is `> 0` and
   `<= ProjectWindow.sidebarInset`, which is true at 1 and at 8 and false for
   the defect that assertion was written against (a prose column short by a
   whole detail column). Leave `sidebarInset` at 8.

6. **Hold on 26.** Both mitigations are strictly more constraining than
   today's spelling — they remove the upward demand rather than relying on a
   tie-break being decided one way — so there is no 26-specific reason for
   them to fail. That is a reason to expect it, not a measurement: **this Mac
   carries only `MacOSX27.0.sdk`, so nothing here was run against 26.** The
   CI run of this branch is the measurement, and it has to happen while CI is
   still `macos-26` — i.e. **Task 3's gate must be a pushed CI run BEFORE
   Task 6 moves the runner**, or the slice ships a fix nobody checked on the
   OS the deployment target names.

## Two things that surprised me

**A large ideal does nothing.** Shape (b) — a truncating row in a flexible
frame, which is exactly `SetAsideRecordsDisclosure`'s shipped shape — left the
column at 320 and 312, unchanged, at both window widths. The drift brief's §3
offers the shelf's 559pt of ideal as "a credible route" to History's disclosure
blanking the window; that reading needs the ideal to push the column, and on
this measurement it does not. §3 is still unreproduced and now has one fewer
candidate mechanism. (It is not in this slice's scope — D3 — but whoever picks
it up should not start from the ideal.)

**No shipped pane was measured to out-demand the column, so the regression is
latent rather than live.** Denver checked the running app on 27 (2026-09-18) and
the column was not visibly wrong, which fits: the `.fixedSize()` sites in the
right-column panes are small borderless menus and two-label segmented pickers
(`AnnotationsPane` ×2, `TasksPane` ×2, `TaskRow`), and `InboxPane`'s
`minWidth: 360` is inside a sheet rather than the pane body. Every
`.frame(minWidth: ≥300)` in `Maugham/Views/` is a sheet or a window. So the six
red tests are the guarantee going, not a writer's layout breaking — and the
guarantee is worth restoring precisely because the next long unbreakable label
(a research title, a filename, a device label) would take the column with
nothing red anywhere.
