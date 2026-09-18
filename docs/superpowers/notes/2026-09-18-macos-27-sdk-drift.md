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

## 4. Decisions owed (Denver)

- The toolchain pin: accept the dev/CI gap and say so in CLAUDE.md (CI is then the authority for mounted-view tests until a macOS 27 runner exists), move CI when one does, or roll Xcode back here.
- When the macOS 27 shell slice runs. It is not P2's and does not block P2's release; it should precede P3, which adds mounted surfaces. If the chevron or menu check shows something unusable in the running app, it goes first.
