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

## The accessibility tree on 27

**Task 2.** Measured on macOS **27.0 (build 26A428)**, Xcode 27.0 (27A266a),
MacOSX27.0.sdk, deployment target 26.0, main screen 1470×956, assistive client
attachable (`AXUIElementCopyAttributeValue` → `.success`, `AXApplication`).
Reproduce with `MAUGHAM_SPIKE=1 … -only-testing:MaughamTests/MacOS27ControlTreeSpikeTests`
(`MaughamTests/MacOS27ControlTreeSpikeTests.swift`; skipped by name in every
other run — it asserts nothing, so it has nothing to say in a gate). Dumps land
in `$TMPDIR/maugham-ax-spike.txt`.

### 1. A SwiftUI `Picker(.menu)` is no longer an `NSPopUpButton` at all

The pass ladder mounts **zero** AppKit controls on 27. The whole view-hierarchy
trace of a bare `Picker(.menu)` is two decorations:

```
NSHostingView<AnyView>
  KeyViewProxy   frame=(136.0,88.0 116.0×24.0)
  _FocusRingView frame=(84.0,16.0 116.0×24.0)
```

`PieceInspector`, `InspectorView` and the bare probe all report *ZERO
`NSPopUpButton` in the whole window*. That is the single cause of all six
`InspectorPassLadderTests` failures — `ladderPopups` filters an empty array, and
the two `choose(…)` cases unwrap `nil`.

It **is** in the accessibility tree, as a SwiftUI `AccessibilityNode`:

```
AccessibilityNode role=“AXStaticText”   value=“Structural” enabled=true kids=0
AccessibilityNode role=“AXPopUpButton”  value=“Untouched”  enabled=true kids=0
AccessibilityNode role=“AXStaticText”   value=“Line”       enabled=true kids=0
AccessibilityNode role=“AXPopUpButton”  value=“Untouched”  enabled=true kids=0
AccessibilityNode role=“AXStaticText”   value=“Copyedit”   enabled=true kids=0
AccessibilityNode role=“AXPopUpButton”  value=“Untouched”  enabled=true kids=0
AccessibilityNode role=“AXStaticText”   value=“Proof”      enabled=true kids=0
AccessibilityNode role=“AXPopUpButton”  value=“Untouched”  enabled=true kids=0
…
AccessibilityNode role=“AXPopUpButton”  value=“Any page”   enabled=true kids=0   ← Publishing's "Start on"
```

So the control's **selected state is readable** (`accessibilityValue` is the
selected item's title — `"Untouched"`, and `"awaiting_reader"` for an unknown
state, since the picker's rendered title is what the node publishes), its label
is a **separate sibling** `AXStaticText`, and `axEnabled` answers it (a
`.disabled(true)` picker reports `enabled=false`; measured).

It **cannot be driven.** `accessibilityActionNames` is `[]` on every one of
those nodes, `accessibilityChildren` is empty, and there is no `NSMenu`
anywhere. The mounted delivery path the suite's doc comment describes — perform
the menu item, because `selectItem(withTitle:)` + `sendAction` wrote nothing —
does not exist on 27 in any form.

### 2. A `Menu(.borderlessButton)` is still a real control, but its label moved

The admission sheet's menu **does** still mount AppKit:

```
AppKitPlatformViewHost<PlatformViewRepresentableAdaptor<PlatformView>>
  SwiftUIPopupButton frame=(401.0,179.0 99.0×16.0) enabled=true items=[] title=“this is also…”
    NSButtonTextField string=“this is also…”
    NSPopUpIndicatorView
```

and in the tree:

```
SwiftUIPopupButtonCell role=“AXMenuButton” roledescription=“menu button”
    title=“this is also…” enabled=true actions=["AXPress"] kids=0
```

**Why the walk cannot see it.** The explicit `.accessibilityLabel(Text(…))` does
not arrive as a label. Measured by type:

| attribute | type | `as? String` | `(as? NSAttributedString)?.string` |
|---|---|---|---|
| `accessibilityTitle` | `NSConcreteMutableAttributedString` | ✗ | `this is also…` |
| `accessibilityLabel` | `__NSCFConstantString` | `""` (empty) | ✗ |
| `accessibilityValue` | nil | ✗ | ✗ |

`AXReading.axTexts` reads `accessibilityValue` and `accessibilityLabel`, casts
both `as? String`, and drops empties — so the string is in the one attribute it
does not read, in the one type it cannot cast. The failing assertion's own
message lists what it *did* see, and the menu is simply absent from it:

```
["Denver’s iPhone wants to write in Playlist", "14 notes waiting", "Denver’s iPhone",
 "Label", "A label is your word for whoever writes on this device. …",
 "Code FFFF is shown on the device’s Settings too.", "Not now", "Admit"]
```

### 3. `accessibilityIdentifier` reaches BOTH controls, as a plain `String`

The decisive measurement. A `Picker(.menu)` and a `Menu(.borderlessButton)`,
each given `.accessibilityIdentifier`:

```
AccessibilityNode      role=“AXPopUpButton” identifier=“ladder.structural”     value=“Untouched” enabled=true
AccessibilityNode      role=“AXPopUpButton” identifier=“ladder.line”           value=“Untouched” enabled=false
SwiftUIPopupButtonCell role=“AXMenuButton”  identifier=“admission.knownLabels” title=“this is also…” enabled=true actions=["AXPress"]
```

One attribute, one type (`String`), across a SwiftUI-native node and an AppKit
cell, carrying **drawn** (it is in the tree), **which one** (the identifier) and
**enabled** (separately, and honestly — the disabled row says so).

### 4. The two "never fired" reds are not about a control at all

The tree's section headers are unchanged in structure on 27. Research mounts one
`_FocusRingView` (its chevron), Palette mounts two (door leftmost, chevron
trailing) — exactly the `[1, 2]` asymmetry both suites derive their subject from:

```
Research header (14.0,87.0 304×19):  _FocusRingView (297.0,89.0 21×15)
Palette  header (14.0,183.0 304×19): _FocusRingView (239.0,185.0 21×15)   ← door
                                     _FocusRingView (297.0,185.0 21×15)   ← chevron
```

**`SectionChevronTests.test_bothSectionsCarryAChevronThatTogglesTheirOwnFlag` —
the second click in one window is swallowed after a relayout.** Replayed step by
step: the Research click fires; collapsing Research moves the Palette header from
y=183 to y=119 (relayout complete and stable — identical geometry immediately
after the `pumpUntil` and after a further 0.5 s pump); the Palette click at the
chevron's centre does **nothing**; and a sweep down that same column immediately
afterwards fires on every one of its thirty samples, 121.0 through 135.5 — the
failing point (128.5) included.

The control is fine. Three measurements say so:

| what was clicked | prior clicks in that window | fired |
|---|---|---|
| Palette chevron, five times, nothing before | 0 | 5 / 5 |
| Palette door (control), then chevron ten times | 1 | 10 / 10 |
| Palette chevron, immediately after Research's click collapsed a section | 1 + relayout | **0 / 1**, then every later one |

And `test_dump_thePaletteChevronAlone` **passes in isolation and fails when the
sweep case ran before it in the same process** — so the swallow follows the
process's event history, not the view. This is CLAUDE.md's recorded shape
(`TreeTravelTests.click(at:)` quiesces the event queue first, because stale
`appKitDefined` traffic feeds `NSTableView`'s drag-disambiguation loop and eats
the pair) arriving one relayout later. It is tripwire 33 with a mouse instead of
a press: the test clicks, waits for the effect, and clicks again in the same
window, and what it measures is the wait.

**Measured fix:** one freshly-mounted window per section. `research: fired=true`,
`palette: fired=true`, first click each.

**`PaletteWallDoorHitAreaTests.test_control_aPlainSectionHeaderMeasuresTheSameLiveRegion`
is a different thing, and it is unmeasurable on 27.** Its probe mounts two
headers, one plain and one `Section(isExpanded:)`, each with the same
`Button(.plain) { Image }`. Swept a click at a time down each button's own
column:

```
ring 0 (plain,       273.5,13.5 15.5×12.5): live y 14.5 … 24.5   (10pt, as recorded)
ring 1 (collapsible, 273.5,77.5 15.5×12.5): live y []            ← nothing, anywhere
```

Thirty-three clicks, zero fired. On 27 a `Section(isExpanded:)` header's own
button takes no synthetic click at all — the row mounts the system's
hover-revealed `NSButton (295.0,74.0 15.0×19.0) hidden=true axlabel="Hide"` and
the header no longer passes clicks through to what SwiftUI drew in it. The claim
this control protects ("the `isExpanded:` conversion did not cause the door's
dead band") is about a shape **production has not had since the chevrons
landed**, and the comparison it makes cannot be made on this SDK.

### 5. The sidebar `List` publishes nothing the walk can reach

Worth recording because it bounds what Task 4 may use for the chevrons. The
whole accessibility tree under a mounted `BinderView` is:

```
NSHostingView<AnyView> role=“AXGroup”
  ListCoreScrollView role=“AXScrollArea”
    SwiftUIOutlineListView role=“AXOutline” label=“Sidebar” kids=7
      NSOutlineRow kids=0      ×6
      NSTableColumn kids=0
```

Zero `AXButton` anywhere. `NSOutlineRow` builds its children lazily for a real
assistive client and answers `[]` to a KVC walk, so **no accessibility hook —
identifier included — reaches inside a `List(.sidebar)`**. The `_FocusRingView`
census is the only instrument for the two header chevrons, and it still reads
what production builds.

### Per control: is there something the walk can reach?

| control | drawn? | enabled? | which one? | same on 26? |
|---|---|---|---|---|
| ladder `Picker(.menu)` | yes — `AccessibilityNode` role `AXPopUpButton` | yes — `axEnabled` | **needs an identifier** (four ladder rows + Publishing's "Start on" are distinguishable only by the preceding sibling `AXStaticText`) | role/value: yes, via the real `NSPopUpButton`'s cell the suite measured there. Identifier: expected, unverified |
| ladder — *driving* it | — | — | **no**: no actions, no children, no `NSMenu` | 26 could perform the menu item; 27 cannot |
| sheet `Menu(.borderlessButton)` | yes — `SwiftUIPopupButtonCell` role `AXMenuButton`, `actions=["AXPress"]` | yes | `accessibilityTitle` (attributed) or **an identifier** | 26 published the string somewhere `label`/`value` read — it does not now |
| tree section chevrons | **not via AX** (the outline is opaque) — via the `_FocusRingView` census, `[1, 2]` per header | — | door leftmost, chevron trailing | unchanged |

### Recommended Task 4 rule — one rule, ladder and sheet together

> **A mounted menu-like control is found by its `accessibilityIdentifier` in
> the accessibility tree, and what a test may assert about it is: that it is
> there (role `AXPopUpButton` or `AXMenuButton`), what it currently reads
> (`accessibilityValue`, else `accessibilityTitle`'s `.string`), and whether it
> is enabled (`axEnabled`). Nothing presses it, and nothing waits on it.**

Concretely, one helper in `MaughamTests/TestSupport/AXReading.swift` —
`axMenuControl(_ identifier: String, in: NSWindow)` answering a small value
(`role`, `reading`, `isEnabled`) — and every one of the eight ladder/sheet cases
expressed through it. `reading` reads `accessibilityValue` first and falls back
to `accessibilityTitle` bridged through `NSAttributedString.string`, because the
two controls put their text in different attributes and a test should not have
to know which. It is one rule and not two because the difference between the
ladder and the sheet is *which attribute holds the string*, and that is the
helper's business, not each suite's.

That leaves each red case with a decision to make windowlessly:

- **`choosingDone…` / `choosingUntouched…`** — the ladder's write cannot be
  delivered through the mounted control on 27 at all. Their decision is
  `PassLadder.onSet` reaching the store verb, which
  `test_theDocumentInspectorLadderWritesTheVerbAndNotTheDebouncedDraft` already
  pins by calling `view.setPass(…)` directly **and which is green on 27**. Pin
  the two remaining halves (the manifest round-trip; the nil arm clearing the
  key) the same way, and keep a drawn-assertion that the ladder is mounted.
- **`theLadderIsOneRowPerEffectivePass…`, `theDocumentInspectorMountsAPassBound…`,
  `aPassStateSetElsewhereReaches…`, `aNewerBuildsStateIsShown…`** — all four are
  *drawn* and *reads* assertions, which the rule serves directly: one control per
  `effectiveReviewPasses` entry, each identified, each reading the state the
  store holds. The live-projection case keeps its whole point (set the state
  elsewhere, read the mounted control's `value`).
- **`theSheetOffersTheLabelsThisBookAlreadyKnows` / `withNoOtherLabelsThePickerIsNotDrawn`**
  — present/absent by identifier. The second currently passes for the right
  reason and will keep doing so.
- **`bothSectionsCarryAChevronThatTogglesTheirOwnFlag`** — a freshly-mounted
  window per section (measured above). It is the only one of the ten that still
  needs a click, and the click is then the first the window ever sees, which is
  what its three green siblings already rely on.
- **`test_control_aPlainSectionHeaderMeasuresTheSameLiveRegion`** — **delete**.
  Its subject is a shape production no longer has, its comparison cannot be made
  on 27, and the archaeology it exists to preserve is already written out in
  full in `PaletteWallDoorHitAreaTests`' own header comment and in
  `openWallButton`'s.

### Does an identifier have to go into production? Yes — two lines, both additive

Not to make the controls *findable* (role + value finds the ladder; the
attributed title finds the sheet's menu), but to make them findable **without
positional arithmetic over siblings**, which is the fixture shape
`BinderTreeMultiselectMountTests` and `PaletteWallDoorHitAreaTests.doorGeometry`
both have their own written lessons about. Specifically:

- **`Maugham/Views/PassLadder.swift`**, on the `Picker` inside `ForEach(passes)`:
  `.accessibilityIdentifier("passLadder.\(pass.id)")`. Without it the only way
  to say *which pass this row is* is "the `AXStaticText` immediately before it",
  and the inspector mounts a fifth `AXPopUpButton` that is not a ladder row at
  all (Publishing's "Start on", `value="Any page"`) — the suite's own comment
  records the page-range menu arriving asynchronously at index 0 mid-test, which
  is that drift already having happened once.
- **`Maugham/Views/AdmissionSheet.swift`**, on the `Menu`, beside the
  `.accessibilityLabel` it already carries:
  `.accessibilityIdentifier(Self.knownLabelsIdentifier)`. Without it the test
  must reach for `accessibilityTitle` and bridge an `NSAttributedString` — which
  the helper can do, but the identifier is what makes the *same* helper serve
  both controls with no per-suite knowledge.

Both are invisible, change no behaviour, and change nothing VoiceOver reads (the
sheet keeps its explicit label; the ladder keeps its sibling label).

### The 26 half, and how to prove it

What is hard evidence for 26: these ten were green in the last full gate before
the toolchain moved (8,580 / 0, 2026-09-11), and two of the suites record their
own 26 measurements in their doc comments — `InspectorPassLadderTests` measured
"one `SwiftUIPopupButton` per ladder row" on macOS 26.5, and
`PaletteWallDoorHitAreaTests` records `SwiftUI.Menu` mounting a real
`SwiftUIPopupButton` there. An `NSPopUpButton`'s cell publishes role
`AXPopUpButton` with the selected title as its value, so the rule's role-and-value
half is expected to hold unchanged on 26.

What is **not** verified and cannot be from this Mac: that
`.accessibilityIdentifier` reaches the bridged `NSPopUpButton`'s cell on 26.

**So the merge order matters, and it is cheap:** land Task 4 while CI is still
`macos-26` and let that run be the 26 proof; Task 6 flips the runner to
`xcode-27` only after the ten have gone green on 26 at least once. The plan
already requires both ("Must hold on 26 (CI)"; "`macos-26` dropped only after
that") — this is the one place in the slice where the ordering is load-bearing
rather than tidy, because a rule that reads an attribute 26 does not publish
would go red on a runner nobody is watching any more.

### Addendum — D4 supersedes the section above (same day)

`024ceeb7` moved the deployment target to macOS 27, so *the only target* is 27
and the merge-ordering recommendation above is moot: nothing has to hold on 26,
and Task 6 takes CI to `xcode-27` straight over with no overlap to hold open.
The unverified claim the ordering existed to cover — whether
`.accessibilityIdentifier` reaches a bridged `NSPopUpButton`'s cell on 26 — is
now a question nobody needs answered. Everything else in this section is a
measurement on 27 and stands. Kept rather than deleted because the 26 numbers
are the record of what the ten tests used to be asserting.
