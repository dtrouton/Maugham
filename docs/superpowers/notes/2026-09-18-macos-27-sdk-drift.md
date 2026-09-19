# macOS 27 / Xcode 27 — what moved under the app (2026-09-18)

Found while running the P2 smoke fix wave. This Mac went to **Xcode 27.0 (27A266a), MacOSX27.0.sdk, macOS 27.0** on 2026-09-15; CI is still `macos-26` + Xcode 26.6 and CLAUDE.md still records that pair as the pin. The last green local gate (8,580 / 0, 2026-09-11) predates the move. Nothing here was caused by P2 or the wave — every item reproduces at a pristine HEAD in a clean worktree.

## 1. Fixed — the test module would not compile

SwiftUI now declares `public protocol Document` (SDK `SwiftUI.swiftinterface:1763`). Every file in `MaughamTests` importing SwiftUI beside `@testable import Maugham` saw two, and the bare name went ambiguous; `InlineTaskToggleUndoTests`' "Generic parameter 'T' could not be inferred" was a knock-on, not a second break. The app target never notices (a module's own declaration shadows an import). Fix: `MaughamTests/TestSupport/DocumentDisambiguation.swift`, one `typealias` — a declaration in the TEST module shadows both imports (`f9636b9c`). `build-for-testing`: zero errors after it.

## 2. Open — fifteen mounted-view tests, two SDK changes

`./scripts/test.sh full` at a clean HEAD: 8,571 passed; the fifteen below are the SDK's.

**`NavigationSplitView`'s column tie-break flipped (7).** `DetailColumnWidthTests` ×6: five read **528** against the 300/320/360 they pin — the same number whatever the column asked for, i.e. the PANE's own demand. `test_theFixedColumnWinsAgainstAnUnbreakablePane` is the canary `ProjectWindow.detailColumn`'s doc comment installed on exactly this undocumented rule, and it has flipped: on macOS 27 an unbreakable pane takes the column rather than the fixed column winning. That is the references-shelf milestone's Task 1 guarantee gone — every fixed-width right column is now sized by whichever pane it shows. (The sixth, `hidingThePane…`, is 959 vs 952 — a 7pt inset drift; its `[240, 1199, 0]` is the intended hidden-detail state.) With them: `SectionChevronTests.test_bothSectionsCarryAChevronThatTogglesTheirOwnFlag` and `PaletteWallDoorHitAreaTests.test_control_aPlainSectionHeaderMeasuresTheSameLiveRegion` — "the collapsible header's button never fired".

**SwiftUI menus and pickers left the accessibility tree (8).** `InspectorPassLadderTests` ×6 (`expected non-nil value of type "NSPopUpButton"`, "published 0 ladder popups"; one case crashed inside the assert) and `AdmissionSheetTests.test_theSheetOffersTheLabelsThisBookAlreadyKnows` — that sheet's `Menu(.borderlessButton)` carries an explicit `.accessibilityLabel` and the walk still cannot see it.

**Checked in the running app on macOS 27 (Denver, 2026-09-18):** the tree's Research and Palette chevrons open and close (they now sit very close to the scrollbar and are hard to hit — move them left); the pass ladder's popups open and offer their four states; the admission sheet's *this is also…* menu opens and lists the known labels. So the eight AX-tree failures and the two chevron failures are TEST-SIDE: the controls work, the accessibility walk no longer sees them. The column tie-break (the six `DetailColumnWidthTests`) is the one product regression.

**Do not patch the assertions first.** Three of these describe something a writer would notice — a dragged column width ignored, a section chevron that may not click, a menu that at best is invisible to VoiceOver. Check the running app on 27 before deciding any is test-side. If the app is fine, the AX-tree decision spans the ladder and the sheet and is made ONCE.

## 3. Possibly related — History's disclosure blanked the window

Denver's P2 smoke: opening History's *Set-aside records* disclosure blanked all three columns (main thread idle — a layout collapse). NOT reproduced in eight mounted configurations. Measured: the shipped rows ask **559pt** of ideal width, the fixed `SetAsideRecordsDisclosure` asks 220 (`e7a5326c`, `10b72126`; `.lineLimit` lowers a row's minimum, only `.frame(idealWidth:)` bounds what it reports upward). 559pt of right column in a 1,200pt window leaves the prose ~393pt against a 480pt floor — a credible route, and an inference; the code says so.

## 4. Decisions (Denver, 2026-09-18)

- **CI moves to a macOS 27 runner — in the shell slice, not before the P2 release.** The only macOS 27 image is `xcode-27` (arm64, *Preview*: macOS 27.0 `26A5406e`, Xcode 27.0 **beta 6** `27A5252f`, image 20260907); `macos-latest` is still 26 and there is no `macos-27` label. Moving today would turn the release gate red on the fifteen until they are re-derived, so: release P2 on `macos-26`; the shell slice fixes the column tie-break, re-derives the ten AX-tree tests, moves the chevrons left, and moves the Mac jobs to `xcode-27` in the same branch. Phone jobs stay. CLAUDE.md's build-flow bullet records the interim.
- The shell slice runs after the P2 release and before P3.

## 4a. Decisions owed as first written (superseded above)

- The toolchain pin: accept the dev/CI gap and say so in CLAUDE.md (CI is then the authority for mounted-view tests until a macOS 27 runner exists), move CI when one does, or roll Xcode back here.
- When the macOS 27 shell slice runs. It is not P2's and does not block P2's release; it should precede P3, which adds mounted surfaces. If the chevron or menu check shows something unusable in the running app, it goes first.

## Outcome (2026-09-19 — the macOS 27 shell slice)

Closed by the slice planned in `docs/superpowers/plans/2026-09-19-macos-27-shell-slice.md`. What this note left open, and where it landed:

- **§2's fifteen** — re-derived, not suppressed. The column tie-break was fixed as a product change (the detail column frames its own content, so no pane can take it); the ten AX-tree reds were re-pinned on the decision each guarded, asserting only that the control is drawn; the chevrons moved to the **leading** edge (D1), which also answers Denver's "hard to hit, move them left".
- **§4's CI decision** — done. Every Mac job in `ci.yml` and `release.yml` moved to `runs-on: xcode-27` with `xcode-version: '27.0'`; the phone jobs stay on `macos-15` / `26.3` (their floor is iOS 17). **The image is not what this note measured**: it has moved from 20260907 to 20260912 and now carries Xcode **27.0 RELEASE (27A266a)** — the developer machine's exact build — not the beta 6 `27A5252f` recorded above. D2 accepted a beta and did not have to spend it.
- **The deployment target moved to 27 (D4)**, which this note did not propose. Under the rule set in `91512a74` — CI runs the developer machine's OS and the target says so — the machine is on 27, so the target is 27; no hedged code paths for a tie-break nobody exercises after the move. `LSMinimumSystemVersion` went with it, from the stale `14.0` that had been generating the Xcode warning about the two disagreeing.
- **The accepted cost of D4, and its fix**: a Mac still on 26 cannot run 0.40.0. `UpdateChecker` compared versions only, so such a Mac would have downloaded, verified and swapped in a binary that will not start. It now refuses one — `release.yml` publishes the built app's own `LSMinimumSystemVersion` into the release body, and a minimum above this Mac's macOS is *no update*, with one sentence saying what the newer Maugham needs. See `Maugham/Updates/MinimumSystemVersion.swift` and `docs/RELEASING.md`.
- **§3 (History's disclosure blanking the window)** stays an inference. The column fix removes the mechanism the measurement pointed at — a pane's own demand deciding the column — but nothing here reproduced the blanking, so it is not claimed as fixed. Re-check it on the next smoke.
