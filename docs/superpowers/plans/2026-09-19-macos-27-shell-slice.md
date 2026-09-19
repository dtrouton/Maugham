# The macOS 27 shell slice — plan (2026-09-19)

**Brief:** `docs/superpowers/notes/2026-09-18-macos-27-sdk-drift.md`. **Status:** ruled and planned; spikes first, the fixes re-derived against what they measure (rule 11's spirit — nothing below commits to a mechanism the spike has not shown).

## Decisions of record (Denver, 2026-09-19)

- **D1 — the section chevrons move to the LEADING edge** of the tree's Research and Palette headers (Finder's and Xcode's convention; nothing on the left to collide with). Not trailing-with-padding.
- **D2 — CI moves to the `xcode-27` runner in this slice even if the image still carries an Xcode 27 BETA.** The beta SDK is what surfaced these problems and macOS 27 is what Denver runs. Condition: the fifteen are green there before merge.
- **D3 — scope stays tight:** the column tie-break, the ten AX-tree reds, the chevrons, the CI move. Nothing else in the shell. P3 is waiting.
- **D4 — the deployment target moves to macOS 27 (Denver, 2026-09-19).** The rule set in August (`91512a74`: CI runs the developer machine's OS, and the deployment target says so) holds; the machine is on 27, so the target is 27. One behaviour to fix and test; CI on `xcode-27` is the single authority; no hedged code paths for a tie-break nobody exercises after the move. Cost accepted: a Mac still on 26 cannot take 0.40.0 or later, so the updater must refuse a build the Mac cannot run (Task 6a) — `UpdateChecker` compares versions only today.

## What is known (measured, not guessed — see the brief)

- Five of six `DetailColumnWidthTests` read **528** whatever width they pin: the PANE's demand. `test_theFixedColumnWinsAgainstAnUnbreakablePane` is the canary on the undocumented `NavigationSplitView` tie-break, and it flipped at 27: an unbreakable pane takes the column. The sixth (`hidingThePane…`) is a 7pt inset drift.
- Ten reds are test-side — the controls work in the running app (checked 2026-09-18): `InspectorPassLadderTests` ×6 and `AdmissionSheetTests.test_theSheetOffersTheLabelsThisBookAlreadyKnows` cannot find an `NSPopUpButton` for a SwiftUI `Picker`/`Menu`; `SectionChevronTests` and `PaletteWallDoorHitAreaTests.test_control_…` report the header's button "never fired".
- `SwiftUI.Document` is already shadowed (`MaughamTests/TestSupport/DocumentDisambiguation.swift`).

## Tasks

Two spikes in parallel, then the fixes, then the CI move. One tree, `git commit -- <paths>`, never amend, stage by path; gate = `./scripts/test.sh full` with the red set SHRINKING from the fifteen and nothing new; the phone gate for anything in Core (nothing here should be).

### Task 1 — SPIKE: what wins the column on macOS 27, and why

Mount `ProjectWindow`'s three-column split through `TestWindow` (read the premise off the window you got — CI's display is 1024pt) with a detail pane that demands more than the column in each of three ways: an unbreakable MINIMUM (`.fixedSize()`), a large IDEAL only (an unbreakable `Text` in a flexible frame — `SetAsideRecordsDisclosure`'s shipped shape), and a `.frame(minWidth:)` above the column. Read `arrangedSubviews` widths. Write down, per shape, what the column resolves to on 27, and — from CI's xcresult or a `macos-26` run — what it resolved to on 26. Output: a table in `docs/superpowers/notes/2026-09-19-split-view-tie-break-spike.md` and a one-paragraph mechanism statement. No production change. **The fix task is written after this lands.**

### Task 2 — SPIKE: what the accessibility tree publishes for a SwiftUI Picker and Menu on macOS 27

Mount `PassLadder` and the admission sheet's `Menu(.borderlessButton)` through `TestWindow`; dump the AX tree (`AXReading` exists) and list every element, role and subrole published for each control, on 27, and — from the same fixtures under CI's 26 — what was published before. Answer: is there ANY element the walk can reach that proves the control is drawn (a role, a title, an `accessibilityIdentifier` we could add)? Output: a section in the same spike note. No production change beyond an `accessibilityIdentifier` if one is needed to make the control findable at all — say so.

### Task 3 — the column fix (written against Task 1)

**Task 1 measured (spike `16358eb8`, `docs/superpowers/notes/2026-09-19-split-view-tie-break-spike.md`):** `navigationSplitViewColumnWidth(w)` gives the split item a min AND max of `w`, and the pane's content contributes a minimum of its own; on 26 the item's max won, on 27 the content's minimum wins and the column resolves to `max(w, pane minimum)` — every measured cell exactly. A large IDEAL does nothing (the drift note's §3 loses that candidate). Nothing shipped currently exceeds a column, so the six reds are the guarantee gone, not a writer's layout. Winning mitigation, 48/48 cells: `.frame(width: w).clipped()` on the `HStack { handle; pane }`, with the effective width bound ONCE (`test_theRightColumnAsksForAWidthAndNotARange` counts the call). The 7pt in `hidingThePane…` is the sidebar inset: 1pt on 27, 8pt on 26.

Contract: the detail column's width is the writer's persisted width (`UIState.detailColumnWidth`, `ProjectWindow.effectiveDetailColumnWidth`), whatever any pane wants; a pane that wants more is CLIPPED or scrolls inside the column, never widens it; `hiddenDetailColumn` still holds zero. All six `DetailColumnWidthTests` green on 27 with their assertions unchanged (a 7pt tolerance is acceptable for `hidingThePane…` if the inset drift is real and explained). Pin the mechanism the spike names with its own planted-offender control: a pane with a `.fixedSize()` label wider than the column, mounted through `TestWindow` — the column reads `w` with the fix and `max(w, label)` with `.clipped()`/the width frame removed. `DetailColumnWidthTests`' own harness composes its own column and needs the same spelling; its `.range` planted-offender arm must NOT get it. The sixth test asserts the CLAIM (`0 < container − sidebar − centre <= sidebarInset`), true at 1pt and 8pt, rather than a 7pt tolerance; `sidebarInset` stays 8 (over-reserving is conservative). `hiddenDetailColumn` still zero; `⌘\`'s canvas collapse unaffected — test both. Delete `SplitViewTieBreakSpikeTests.swift` in the same change (its findings live in the note and the new pin). macOS 27 is the only target (D4).

### Task 4 — the ten AX-tree reds, re-derived (written against Task 2)

Placeholder until Task 2 lands. Contract: each of the ten pins the DECISION it guards windowlessly (the ladder's state per pass on the model; the sheet's known labels from `AdmissionDecision.knownLabels`) and asserts only that the control is DRAWN by what the tree publishes on 27 (the only target, D4). One decision for the ladder and the sheet together, not two. No press-then-wait (tripwire 33). Delete any case whose decision is already pinned elsewhere rather than re-deriving it.

### Task 5 — the chevrons lead (D1)

`BinderTreeSections`' Research and Palette headers: the disclosure chevron moves to the leading edge of the title, the tap target stays the whole header row, VoiceOver still reads it as a disclosure. `SectionChevronTests` and `PaletteWallDoorHitAreaTests.test_control_…` are re-derived under Task 4's rule (they are among the ten). Guide screenshot/text if either mentions the chevron.

### Task 6 — the target and CI move to 27 (D2, D4)

`project.yml`: `deploymentTarget.macOS` and both `MACOSX_DEPLOYMENT_TARGET` to `27.0`; `./gen.sh`; the `LSMinimumSystemVersion` 14.0-vs-target warning in the Xcode build fixed at the same time (find where 14.0 comes from). `.github/workflows/ci.yml` and `release.yml` Mac jobs: `runs-on: xcode-27` straight over, no `macos-26` overlap; Xcode selection to whatever the image carries (check `images/macos/xcode-27-arm64-Readme.md` at the time). Phone jobs stay on their own floor. CLAUDE.md: the toolchain bullet says the pin is 27 on both sides; the fifteen-red interim paragraph deleted; `docs/RELEASING.md` if it names the runner; the drift note gets an Outcome. `docs/release-notes/v0.40.0.md` draft says the floor is now macOS 27. **Merge condition:** the branch's CI run on `xcode-27` green across all jobs.

### Task 6a — the updater refuses a build this Mac cannot run (D4's cost)

`UpdateChecker` today compares versions only, so a 26 Mac would download 0.40.0 and fail to launch it. The release carries the build's minimum OS (read it from the release asset's `Info.plist`/`LSMinimumSystemVersion`, or publish it in the release body/a sidecar the workflow writes — pick the one the pipeline already makes available and say why); the checker treats a build above this Mac's OS as *no update*, with one sentence in the banner/sheet saying the newer Maugham needs macOS 27. Pin: a release above the OS → `.upToDate`-shaped state with the sentence; at or below → offered as today. The phone is untouched.

### Task 7 — whole-branch review + docs sweep

Rule 9. Seams: Task 3 × `hiddenDetailColumn` × the canvas collapse (`⌘\`); Task 4 × tripwire 33's allow-list; Task 6 × `release.yml`'s tectonic cache key.

## Out of scope (D3)

Anything in the shell not named above; the P3 handoff's carries; the leaking `TestWorkspace` worker folders (C10).
