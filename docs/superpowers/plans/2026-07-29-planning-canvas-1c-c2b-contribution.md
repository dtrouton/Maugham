# M1C-c2b — a contributing card knows its words are in the note

> **For agentic workers:** REQUIRED SUB-SKILL: use `superpowers:subagent-driven-development`. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Promote a region and every card whose words went into the note says so — without any of them being able to rewrite it.

**Architecture:** One new optional field on `CanvasNode`, deliberately separate from `promotedItemID`, recorded at promotion time from the members whose text actually contributed, written in the same undo bracket as the region's own mark. Three tasks: the model, the performer, the surface.

**Tech Stack:** Swift 6, SwiftUI + AppKit, XCTest. Mac only.

## Global Constraints

- **Spec §6.3** (`docs/superpowers/specs/2026-07-25-planning-canvas-design.md`) is the authority. Read it first.
- **The contribution record is NOT the promotion mark.** `promotedItemID` means *"I am this artifact"* and `Promotion.existingArtifact` reads it to offer **Rewrite**. The new field must never reach `existingArtifact`, or promoting a contributing card offers to rewrite a joint note with one card's text — 1C-c2's Critical returning as a cardinality error rather than a kind error.
- **Recorded, not derived.** A card added to the region after the promotion has no words in that note and must not claim to.
- **One gesture, one undo step:** the region's mark and every contribution record go in a single `mutateFromInspector` bracket.
- **Tripwire 32:** `PromotionPerformer` stays in the census and keeps using `mutateFromInspector`.
- Every new guard proven by the **disable experiment**.
- `./gen.sh` after adding a file; **never commit anything under `Maugham.xcodeproj/`**; foreground `xcodebuild`, one at a time; `-only-testing MaughamTests/<ClassName>` never a folder path; **do not run any MCP suite** (`docs/superpowers/notes/2026-07-29-mcp-clock-dependent-tests.md`).
- SourceKit's `No such module` / `Cannot find type … in scope` is stale-index noise here.

## Verified on this branch at `a2676c6`

| Fact | Where |
|---|---|
| `Promotion.regionBodies(_:in:scraps:)` returns `[(CanvasNodeID, String)]` — home members, non-empty text, reading order — and is already read by the plan, the refusal and the body | `Promotion.swift:668-675` |
| The region plan arm builds `offeredLinks` from those same `bodies` | `Promotion.swift:541-562` |
| `PromotionPlan` has no contributor list | `Promotion.swift:330-360` |
| `PromotionPerformer.mark(_:for:named:)` marks the source only; `setPromotedItem` has exactly one production caller | `PromotionPerformer.swift:519-531` |
| Sidecar is at schema **5** | `CanvasSceneCodec.swift` |
| `CanvasNode.promotedItemID` / `.boundPieceID` are the shape to mirror — last init parameter, `nil` default, additive-optional DTO | `CanvasNode.swift` |

---

### Task 1: The record in the model, and the guard that keeps it out of Update

**Files:** modify `CanvasNode.swift`, `CanvasScene.swift`, `CanvasSceneCodec.swift`, `Promotion.swift`; test `MaughamTests/Canvas/PromotionContributionTests.swift` (new)

**Produces:** `CanvasNode.contributedToItemID: String?`; `CanvasScene.setContributedItem(_ itemID: String?, for id: CanvasNodeID)`; `CanvasSceneDTO.currentSchemaVersion == 6` with `NodeDTO.contributedToItemID`; `PromotionPlan.contributors: [CanvasNodeID]`, populated from `regionBodies` for a region source and **empty for every other source**.

- [ ] **Step 1: Write the failing tests.** At minimum: a region plan's `contributors` are its home members with text, in reading order; a member with **empty** text is not a contributor; an appearance-only card is not; a scrap plan and a line plan have **no** contributors. Then the guard that matters — **a card carrying only a contribution record offers no Update**: set `contributedToItemID` on a card, leave `promotedItemID` nil, and assert `Promotion.existingArtifact(for:target:in:artifacts:)` returns **nil** for both `.researchNote` and `.paletteCard`. Plus the schema trio: round-trip; a **schema-5** literal decodes with the field nil and loses nothing else; an unrecorded canvas encodes without the key.
- [ ] **Step 2: Run, watch it fail.**
- [ ] **Step 3: Implement**, mirroring `promotedItemID` exactly. If an existing test asserts the literal schema `5`, move it to 6 and say which.
- [ ] **Step 4: Run, then the disable experiment** — make `existingArtifact` fall back to `contributedToItemID` when `promotedItemID` is nil, and confirm the no-Update test goes red. That is the defect the field exists to avoid; prove the guard is what prevents it.
- [ ] **Step 5: Commit.**

---

### Task 2: The performer records it, in one bracket, and re-records on an update

**Files:** modify `PromotionPerformer.swift`; test `MaughamTests/Canvas/PromotionContributionPerformerTests.swift` (new)

**The whole change is in the region path.** After a region produces a research note or a palette card, every contributor is stamped with the produced item id — **inside the same `mutateFromInspector` bracket as the region's own mark**, so one ⌘Z takes back the region's mark and every contribution record together. `mark(_:for:named:)` is where the bracket is; extend it rather than opening a second one.

**On an `.update`,** rebuild the record set: clear `contributedToItemID` on every node that currently names this artifact, then stamp the current contributors. A card that has left the region since must stop claiming the note; a card that joined must start. The note is rewritten from the current members, so the record follows the same set.

A scrap or line promotion records nothing — `contributors` is empty and the loop is a no-op.

- [ ] **Step 1: Write the failing tests.** Every contributing member carries the produced item's id after a region → research note; an empty-text member does not; a member cited but not resident does not; **one ⌘Z takes back the region's mark and every contribution record in one step** (assert the undo step's *name*, not just the scene — a scene-only assertion cannot tell its own step from a folded one); an update clears a departed member's record and stamps a newly-joined one; a palette-card region promotion records the same way; a scrap promotion records nothing.
- [ ] **Step 2: Run, watch it fail.** **Step 3: Implement. Step 4: Run**, plus the disable experiment on the single-bracket claim: open a second bracket for the stamping and confirm the one-⌘Z test goes red.
- [ ] **Step 5: Commit.**

---

### Task 3: The card says it, and the record catches up

**Files:** modify `ScrapInspector.swift` (and `PromotedArtifactSection.swift` if the shape fits there); `Maugham/Canvas/AREA.md`, `docs/adr/0026-planning-canvas-rendering.md`, `CLAUDE.md`, `docs/roadmap.md`, `docs/guide/getting-started.md`, `docs/guide/right-pane.md`; tests alongside

The scrap arm gains a line that is **visibly different from "Became …"**: its words are *in* something, along with others'. Resolve the id through the artifact index the pane already has, so a deleted note says so rather than showing a raw id — the treatment `promotedItemID` already gets.

**A card may carry both**, and they say different things. Show both; do not choose. Put the decision on the model as a testable value, because which SwiftUI arm renders cannot be asserted.

Docs: schema 6; §6.3's rule and *why the record is not the mark*; the census/tripwire lists if they moved; the guide's promotion section; and fold this into 1C-c2's roadmap entry as the smoke correction it is.

- [ ] **Step 1: Write the failing tests** — the three display states (own only, contribution only, both) as model values, plus the dangling-artifact case. **Step 2-4: fail, implement, run**, including the doc-guarding suites (check the real class names first).
- [ ] **Step 5: Commit.**

---

## Whole-slice verification

```
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO \
  -skip-testing:MaughamTests/MCPServerLifecycleTests
xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone \
  -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO
```

~5 minutes for the Mac suite. Then `grep -rn "contributedToItemID" Maugham/ --include=*.swift | grep -v Tests` — every symbol needs a production reader — and a whole-branch review whose question is: **can any surface offer to rewrite an artifact this card only contributed to?**

## Smoke

- [ ] **The reported bug.** Promote a region of several cards to a research note. **Every** card that had text now says its words are in it; a card you left empty does not.
- [ ] **It is not an Update.** Select one of those cards and Promote… → the sheet offers only a **new** artifact, never "Rewrite". This is the one that matters.
- [ ] **Both at once.** Promote a card on its own first, then promote its region. Its inspector says what it became **and** what it is part of.
- [ ] **One ⌘Z.** After promoting the region, a single ⌘Z clears the region's mark and every card's record together.
- [ ] **An update follows the members.** Drag a card out of the region, add another, re-promote with Rewrite: the departed card stops claiming the note and the new one starts.
- [ ] **A deleted note.** Delete the note in the research tree; the cards say what they produced is gone rather than showing an id.
