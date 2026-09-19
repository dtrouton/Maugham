# The macOS 27 shell slice — the two spikes (2026-09-19)

Measurements for tasks 1 and 2 of `docs/superpowers/plans/2026-09-19-macos-27-shell-slice.md`.
No production change is made by either spike. Each section is its own task's;
append, never rewrite.

<!-- Task 1's section (the NavigationSplitView column tie-break) goes here. -->

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
