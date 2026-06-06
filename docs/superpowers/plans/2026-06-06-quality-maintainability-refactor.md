# Quality & Maintainability Refactor — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pay down maintainability debt from four codebase audits and fix two correctness footguns, in five risk-ordered phases, each landing green before the next.

**Architecture:** Behavior-preserving deletions and file-splits ride the existing test suite; the two behavior-changing items (Find-Replace through the op log; tree-walk consolidation with a path-prefix reconciliation) get new tests first. New shared logic lands in MaughamCore (Foundation-only).

**Tech Stack:** Swift, SwiftUI, AppKit; XCTest; xcodegen (`./gen.sh`); local SPM package `MaughamCore`.

**Spec:** `docs/superpowers/specs/2026-06-06-quality-maintainability-refactor-design.md`

---

## Conventions used throughout this plan

**The two test commands** (referred to as "Mac suite" and "phone suite"):

```bash
# Mac suite (Mac app + MaughamCore)
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30

# Phone suite (iOS app + MaughamCore)
xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30
```

- After **adding or deleting any file**, run `./gen.sh` BEFORE building (xcodegen regenerates the project from `project.yml`; files are picked up by directory, but a removed file still referenced by stale DerivedData can phantom-link). If you hit `Undefined symbol` after a merge or a public-signature change, run the same command with `clean` before `test`.
- **Never** commit anything under `Maugham.xcodeproj/`. If `git status` shows `project.pbxproj`, discard it.
- A single XCTest method can be run with `-only-testing:MaughamTests/SuiteName/test_method`.
- Commit messages end with the Co-Authored-By trailer:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- Work happens on branch `quality-maintainability-refactor` (already created; the spec is committed there).

---

# PHASE 1 — Deletions & fixture hygiene

Behavior-preserving. The suite is the safety net; no new tests.

## Task 1.1: Delete dead CharacterAutocompleter

**Files:**
- Delete: `Maugham/Editor/Fountain/CharacterAutocompleter.swift`
- Delete: `MaughamTests/CharacterAutocompleterDataTests.swift` (confirm exact path with the grep below)
- Modify: `Maugham/Editor/EditorCoordinator.swift` (remove the `autocompleter` property near line 86 and the `updateAutocomplete(in:)` method, ~lines 770–837)

- [ ] **Step 1: Confirm it is dead.** Run:
```bash
grep -rn "updateAutocomplete\|CharacterAutocompleter\|autocompleter" Maugham/ MaughamPhone/ MaughamTests/ MaughamPhoneTests/ Packages/ | grep -v "Maugham.xcodeproj"
```
Expected: references ONLY in `CharacterAutocompleter.swift`, `EditorCoordinator.swift` (the property + the method definition), and the test file. If any OTHER production file calls `updateAutocomplete` or reads `autocompleter`, STOP — it is not dead; report and do not delete.

- [ ] **Step 2: Delete the two files.**
```bash
git rm Maugham/Editor/Fountain/CharacterAutocompleter.swift
git rm MaughamTests/CharacterAutocompleterDataTests.swift
```
(If the test file path differs, use the path from Step 1.)

- [ ] **Step 3: Remove the property and method from EditorCoordinator.swift.** Read the file, delete the `autocompleter` stored property declaration and the entire `func updateAutocomplete(in:)` method body. Do not touch `applyFocusDim` or anything else.

- [ ] **Step 4: Regenerate + build.**
```bash
./gen.sh
```
Then run the Mac suite. Expected: PASS (the removed test no longer exists; nothing references the deleted symbols).

- [ ] **Step 5: Commit.**
```bash
git add -A
git commit -m "refactor(editor): delete dead CharacterAutocompleter

NSPopover autocomplete was abandoned (tripwire 5); updateAutocomplete had
zero callers. Removes ~190 lines incl. ~68 in EditorCoordinator, the unused
property, and CharacterAutocompleterDataTests.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

## Task 1.2: Delete dead ProjectWindow.handleMCPNoteAdded

**Files:**
- Modify: `Maugham/Views/ProjectWindow.swift` (remove `handleMCPNoteAdded(researchId:title:)`, ~lines 999–1010)

- [ ] **Step 1: Confirm dead.** Run:
```bash
grep -rn "handleMCPNoteAdded" Maugham/ | grep -v "Maugham.xcodeproj"
```
Expected: exactly ONE hit — the definition in `ProjectWindow.swift`. If there is a call site, STOP and report.

- [ ] **Step 2: Delete the method.** Read `ProjectWindow.swift` around the definition; delete the whole `private func handleMCPNoteAdded(...)`. Leave `handleDismissMCPBanner`/`handleShowLatestMCPNote` and the inlined `.maughamMCPNoteAdded` handler in `SessionAndNavigationModifier` untouched (those are live).

- [ ] **Step 3: Build.** Run the Mac suite. Expected: PASS.

- [ ] **Step 4: Commit.**
```bash
git add Maugham/Views/ProjectWindow.swift
git commit -m "refactor(views): delete dead handleMCPNoteAdded

Zero callers; stale duplicate of the banner logic inlined in
SessionAndNavigationModifier's .maughamMCPNoteAdded handler.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

## Task 1.3: Replace print() with Logger in DocumentStore

**Files:**
- Modify: `Maugham/Stores/DocumentStore.swift:130`

- [ ] **Step 1: Find the print.** Run:
```bash
grep -n "print(" Maugham/Stores/DocumentStore.swift
```
Expected: the straggler-warning around line 130.

- [ ] **Step 2: Replace it.** Ensure `import os` is present at the top of the file (add if missing). Define a file-scoped logger if the file doesn't already have one:
```swift
private let documentStoreLog = Logger(subsystem: "com.maugham", category: "DocumentStore")
```
Replace the `print("[DocumentStore] WARNING: ... stragglers ...")` call with:
```swift
documentStoreLog.warning("Scratch stragglers found on open: \(stragglerDescription, privacy: .public)")
```
(Use whatever the existing interpolated value is named; keep the message content.)

- [ ] **Step 3: Build.** Run the Mac suite. Expected: PASS.

- [ ] **Step 4: Commit.**
```bash
git add Maugham/Stores/DocumentStore.swift
git commit -m "refactor(stores): route straggler warning through Logger not print

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

## Task 1.4: Fix fabricated doc-id test fixtures

**Files:**
- Modify: `MaughamPhoneTests/PhoneAnnotationIntegrationTests.swift:22`
- Modify: `MaughamPhoneTests/AnnotationWriterTests.swift:17`
- Modify: `MaughamPhoneTests/AnnotationLoadingTests.swift:63,72,81`

Real on-disk doc-ids are `doc-<hex>` / `scene-<hex>` (ADR 0008), NOT `d_<ULID>`. The corrected sibling `AnnotationLoadingTests.swift:10-14` already documents this.

- [ ] **Step 1: Find every fabricated id.** Run:
```bash
grep -rn 'd_01HQ\|"d_x"\|"d_"\|d_<' MaughamPhoneTests/ MaughamTests/ | grep -v "Maugham.xcodeproj"
```
Note each location.

- [ ] **Step 2: Replace the literals.** In each file, replace the fabricated id with a realistic one matching the corrected siblings, e.g. `"doc-a1b2c3d4"`. Use a single shared constant per test file (e.g. `private let docId = "doc-a1b2c3d4"`) so the value is consistent within the file. Keep the value DOT-FREE (the `.`-boundary is what separates docId from device slug in op-log filenames — tripwire 18).

- [ ] **Step 3: Run the affected suites.**
```bash
xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:MaughamPhoneTests/PhoneAnnotationIntegrationTests -only-testing:MaughamPhoneTests/AnnotationWriterTests -only-testing:MaughamPhoneTests/AnnotationLoadingTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```
Expected: PASS (these tests assert round-trip behavior, which is format-agnostic, so real ids pass too — the point is the fixtures now exercise the real shape).

- [ ] **Step 4: Commit.**
```bash
git add MaughamPhoneTests/
git commit -m "test(phone): use real doc-/scene- doc-ids not fabricated d_<ULID>

The d_<ULID> shape is the exact one behind the phone-v0.1.1 'No open
annotations' footgun; these fixtures passed only because OpLogStore.docId
is format-agnostic, giving false confidence. Matches the corrected
AnnotationLoadingTests sibling.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

## Task 1.5: Fix stale doc-id doc-comments

**Files:**
- Modify: `MaughamPhone/Annotations/AnnotationWriter.swift:19,25,65,67`
- Modify: `Packages/MaughamCore/Sources/MaughamCore/OpLogStore.swift:36`

- [ ] **Step 1: Find the stale prose.** Run:
```bash
grep -rn 'd_<ulid>\|d_<ULID>\|d_` + 26\|fixed-length' MaughamPhone/Annotations/AnnotationWriter.swift Packages/MaughamCore/Sources/MaughamCore/OpLogStore.swift
```

- [ ] **Step 2: Correct the comments.** Change descriptions of the docId shape from "`d_<ulid>`" / "fixed-length (`d_` + 26-char ULID)" to "`doc-<hex>` / `scene-<hex>` (ADR 0008)". For OpLogStore.swift specifically, the parse relies on "contains no dot" — make the comment say that, not "fixed-length." Do NOT change any code, only comments.

- [ ] **Step 3: Build both suites.** Run Mac suite and phone suite. Expected: PASS (comment-only change).

- [ ] **Step 4: Commit.**
```bash
git add MaughamPhone/Annotations/AnnotationWriter.swift Packages/MaughamCore/Sources/MaughamCore/OpLogStore.swift
git commit -m "docs: correct stale d_<ULID> doc-id comments to doc-/scene- shape

The code is right (OpLogStore parses on no-dot, not length); only the prose
described the wrong shape — the same wrong mental model that shipped the
v0.1.1 bug.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

**PHASE 1 GATE:** Both suites green. `grep` for `CharacterAutocompleter`, `handleMCPNoteAdded` returns nothing outside git history.

---

# PHASE 2 — Correctness fixes

## Task 2.1: Delete dead manuscript-write path (manuscriptText / save / readManuscript)

**Files:**
- Modify: `Maugham/Stores/ProjectStore.swift` (remove `manuscriptText` ~line 30; remove `readManuscript` ~line 224 and its call in load ~lines 174,183)
- Modify: `Maugham/Stores/ProjectStore+Metadata.swift` (remove `save()` ~lines 80–108)
- Modify: `MaughamTests/ProjectStoreTests.swift` (remove/rewrite the 3 cases that exercise them)

`manuscriptText` (public var) + `save()` write manuscript bytes straight to disk, bypassing the op log — contradicting the source-of-truth invariant. Confirmed dead in production: only `ProjectStoreTests` touches them.

- [ ] **Step 1: Confirm production-dead.** Run:
```bash
grep -rn "manuscriptText\|\.save()\|readManuscript" Maugham/ MaughamPhone/ | grep -v "Maugham.xcodeproj"
```
Expected: `manuscriptText` only assigned/read within `ProjectStore.swift` (load wiring) and tests; `save()` no production callers; `readManuscript` only called from `ProjectStore` load. If anything in `Maugham/Views/` or `MaughamPhone/` calls `.save()` on a ProjectStore, STOP and report (it would be a real caller).

- [ ] **Step 2: Identify the dependent tests.** Run:
```bash
grep -n "manuscriptText\|\.save()\|readManuscript" MaughamTests/ProjectStoreTests.swift
```
Note the test methods.

- [ ] **Step 3: Delete the three production members.** Remove `manuscriptText`, `save()`, and `readManuscript` plus the `readManuscript` call in `load`. If `load` stored the result only into `manuscriptText`, drop that line entirely (word counts come from `populateWordCountCache`, which does its own per-doc reads — verify it is still called in `load`).

- [ ] **Step 4: Delete/rewrite the dependent tests.** Delete the test methods that only existed to exercise `manuscriptText`/`save()`. If a test mixes dead and live assertions, keep the live assertions and drop the dead lines.

- [ ] **Step 5: Build.** Run the Mac suite. Expected: PASS.

- [ ] **Step 6: Commit.**
```bash
git add -A
git commit -m "refactor(stores): delete dead manuscriptText/save/readManuscript path

Public mutable manuscript field + atomic raw write bypassed the op log,
contradicting the source-of-truth invariant. Dead in production (only
ProjectStoreTests used them). Prunes those tests.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

## Task 2.2: Find-Replace through the op log

**Files:**
- Modify: `Maugham/Stores/ProjectStore+Search.swift:48-88` (`replaceMatch`, `replaceAll`)
- Test (new): `MaughamTests/Integration/FindReplaceOpLogTests.swift`
- Read first (do not modify yet): `Maugham/Stores/ProjectSearchEngine.swift` (to confirm the coordinate space of `SearchMatch.charRangeInDocument`), `Maugham/OpLog/Document.swift` `setFullText` (ends ~line 1269), `DocumentStore` registry accessors (how an open `Document` is obtained for a path/docId, and `flushPendingSave`).

**Approach (the contract):** A replace is a manuscript edit, so it must go through the op log. For each affected document:
1. Obtain a `Document` — the open one from the `DocumentStore` registry if present, else `Document.load(...)`.
2. Compute the new **display-form** text by applying the replacement(s).
3. Call `doc.setFullText(newText)` — the same path normal typing uses (records changes to the pending buffer, updates paragraphs/sequence, schedules burst + autosave).
4. For a doc that was NOT already open: force persistence after `setFullText` (`await doc.flushBurstNow()` then `await doc.performAutosave()`), then unregister it if `Document.load` registered it. (Confirm the exact persist + teardown calls against the open-doc lifecycle in `DocumentStore`.)

**Coordinate-space note (critical):** `SearchMatch.charRangeInDocument` is computed by `ProjectSearchEngine` against the form it reads. Confirm whether that is the stored `.md` (with `<!-- ¶id -->` anchors) or display form. `setFullText` consumes display form. If the match ranges are in stored coordinates, you MUST map them to display coordinates (anchors stripped) before splicing — do NOT splice into stored bytes and feed that to `setFullText`. For `replaceAll`, prefer re-finding occurrences in `doc.displayText` (respecting `SearchOptions`) over reusing stored-form ranges; for `replaceMatch` (single occurrence) you must target the specific match, so map that one range.

- [ ] **Step 1: Read the three sources above.** Write down: (a) the coordinate space of `charRangeInDocument`, (b) the exact registry accessor for an open Document by path, (c) the persist+unregister calls for a transiently-loaded Document.

- [ ] **Step 2: Write the failing integration test.** Create `MaughamTests/Integration/FindReplaceOpLogTests.swift`:

```swift
import XCTest
@testable import Maugham
import MaughamCore

@MainActor
final class FindReplaceOpLogTests: XCTestCase {

    // Builds a temp project with a single Novel manuscript document whose
    // body is `initialMd`, bootstrapped with real ¶id anchors. Returns the
    // project URL and the document's on-disk URL.
    private func makeProject(initialMd: String) throws -> (projectURL: URL, docURL: URL) {
        // TODO(implementer): reuse the existing temp-project scaffold helper.
        // Several tests define `makeProject(initialMd:)` (DocumentTests.swift:9,
        // DocumentOpLogAccessorTests.swift:8). Copy that scaffold here (it will
        // be unified in Task 2.x is NOT in scope — just reuse the pattern):
        //  - create temp dir, write project.maugham.json (Novel),
        //  - write manuscript/<file>.md with `initialMd`,
        //  - return (projectURL, docURL).
        fatalError("implement using the existing makeProject scaffold")
    }

    func test_replaceAll_closedDoc_goesThroughOpLog_and_survivesReload() async throws {
        let (projectURL, docURL) = try makeProject(
            initialMd: "The cat sat.\n\nThe cat ran.\n")
        let store = try await ProjectStore.load(url: projectURL /* match real signature */)

        // Search then Replace All "cat" -> "dog" on a CLOSED document.
        await store.performSearch(query: "cat", options: .init(caseSensitive: false, wholeWord: false))
        let results = try XCTUnwrap(store.currentSearch)
        try await store.replaceAll(in: results, with: "dog")

        // Op log must now carry the edit (source of truth), and the rendered
        // .md must reflect it after a fresh load.
        let device = "test-device"; let session = "test-session"
        let reloaded = try await Document.load(
            url: docURL, device: device, session: session, presenter: nil)
        XCTAssertTrue(reloaded.displayText.contains("dog"))
        XCTAssertFalse(reloaded.displayText.contains("cat"))

        // And the op log is non-empty for this doc (proves it went through ops).
        let docId = try Document.resolveDocId(for: docURL) // match real accessor
        let opStore = OpLogStore(projectURL: projectURL, presenter: nil)
        let ops = try await opStore.load(docId: docId)
        XCTAssertFalse(ops.filter { $0.kind == .typingBurst }.isEmpty)
    }

    func test_replaceMatch_openDoc_doesNotRaceAutosave() async throws {
        // TODO(implementer): open the doc through DocumentStore (so it is in
        // the registry), perform a single replaceMatch, and assert:
        //  - doc.displayText reflects the replacement immediately,
        //  - no applyExternalText fires (reuse the EditorIntegrationHarness
        //    assertion pattern if practical, else assert displayText only),
        //  - after flushBurstNow(), the op log carries the change.
    }
}
```
Adjust signatures to the real `ProjectStore.load`, `SearchOptions.init`, and `Document.resolveDocId` (confirm in Step 1). Fill the `makeProject` body from the existing scaffold.

- [ ] **Step 3: Run the test — verify it fails.**
```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/FindReplaceOpLogTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -25
```
Expected: FAIL (current `replaceAll` writes raw bytes; the op log will have NO typingBurst op, so the last assertion fails — and/or the reload reads the raw-written text without ops backing it).

- [ ] **Step 4: Rewrite `replaceMatch` and `replaceAll`.** Replace the raw `.write(to:)` bodies with the op-log path described above. Keep the stale-match out-of-bounds guard (re-run search on mismatch). Group `replaceAll` by document; for each doc obtain the Document once, apply all that doc's replacements (right-to-left if you reuse ranges), `setFullText`, persist if transient.

- [ ] **Step 5: Run the test — verify it passes.** Same command as Step 3. Expected: PASS.

- [ ] **Step 6: Run the full Mac suite.** Expected: PASS (no regression in existing search tests).

- [ ] **Step 7: Commit.**
```bash
git add Maugham/Stores/ProjectStore+Search.swift MaughamTests/Integration/FindReplaceOpLogTests.swift
git commit -m "fix(search): route Find-Replace through the op log

replaceMatch/replaceAll wrote raw bytes to the .md, bypassing the op log
(source of truth) and racing autosave on open docs. Now: open docs apply via
the live Document, closed docs via Document.load -> setFullText -> persist.
.md and op log never diverge. Adds integration coverage.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

## Task 2.3: Dedupe the task-anchor LCS

**Files:**
- Modify: `Maugham/OpLog/TaskAnchorAlignment.swift` (Pass 1, ~lines 93–119)
- Reference: `Maugham/OpLog/RenderFilter.swift` (`restoreTaskAnchors` ~line 126, `restoreLineByLine`)

`RenderFilter.restoreTaskAnchors`/`restoreLineByLine` are tested but unused; `TaskAnchorAlignment` Pass 1 ships a copy of the same LCS pairing. Make the tested code the production code.

- [ ] **Step 1: Compare the two implementations.** Read `RenderFilter.restoreLineByLine` and `TaskAnchorAlignment` Pass 1. Confirm they compute the same line-pairing result (note any input/output shape difference — e.g. one returns restored text, the other an id→text map).

- [ ] **Step 2: Decide the call boundary.** Preferred: have `TaskAnchorAlignment` Pass 1 call `RenderFilter.restoreLineByLine`. If the shapes don't line up cleanly (e.g. the aligner needs per-anchor pairing metadata the RenderFilter helper discards), instead DELETE `RenderFilter.restoreTaskAnchors`+`restoreLineByLine` and move their tests onto the aligner — but try the call-through first.

- [ ] **Step 3: Make the change** per Step 2. If calling through: replace the inline Pass-1 LCS with a call to the RenderFilter helper, adapting the result. If deleting: remove the unused RenderFilter helpers and relocate `RenderFilterTaskAnchorTests` cases to a `TaskAnchorAlignment` test, asserting the same round-trip.

- [ ] **Step 4: Build.** Run the Mac suite, paying attention to `RenderFilterTaskAnchorTests` and any `TaskAnchorAlignment` tests. Expected: PASS.

- [ ] **Step 5: Commit.**
```bash
git add Maugham/OpLog/
git commit -m "refactor(oplog): single task-anchor LCS shared by aligner and RenderFilter

The property-tested restoreLineByLine was unused while TaskAnchorAlignment
shipped a copy. Wire production to the tested code so the round-trip test
guards what ships.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

## Task 2.4: Surface silent autosave + id-backfill failures

**Files:**
- Modify: `Maugham/Stores/DocumentStore.swift:121` (research-note autosave `try?`)
- Modify: `Maugham/Stores/ProjectStore.swift:167-171` (id-backfill `try?`)

- [ ] **Step 1: Research-note autosave.** At `DocumentStore.swift:121`, the debounced `try? performFileSave(...)` drops failures silently. Change to a `do/catch` that logs via the `Logger` from Task 1.3 at `.error` and sets a UI-readable error flag if one exists (search for an existing `@Published`/observable error surface on DocumentStore; if none exists, just log — do NOT invent a new UI surface in this task).

- [ ] **Step 2: Id backfill.** At `ProjectStore.swift:167-171`, the one-time id-backfill write is `try?`. Wrap in `do/catch` and log at `.error` on failure (a missing persisted id resurfaces cross-surface on the phone). Keep it non-fatal (don't throw out of load), but make the failure visible in the log.

- [ ] **Step 3: Build.** Run the Mac suite. Expected: PASS.

- [ ] **Step 4: Commit.**
```bash
git add Maugham/Stores/DocumentStore.swift Maugham/Stores/ProjectStore.swift
git commit -m "fix(stores): log instead of swallowing research-autosave + id-backfill failures

A failed research-note autosave was indistinguishable from success; a failed
id backfill silently left a project id-less (the phone doc-id footgun class).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

## Task 2.5: Reconcile dual slug implementations

**Files:**
- Modify: `Maugham/Stores/ProjectStore+Research.swift` (`researchSlugify`, `researchDedupedFilename`)
- Reference: `Packages/MaughamCore/Sources/MaughamCore/Slugifier.swift` (already falls back to `"untitled"`, line 56)

- [ ] **Step 1: Diff the two slug rules.** Read `researchSlugify` and compare to `Slugifier.slug`. Record every behavioral difference (char set, max length, empty-fallback, dedup-counter format). NOTE: `Slugifier` already returns `"untitled"` for empty — confirm whether `researchSlugify` differs at all, and if so how.

- [ ] **Step 2: Write a characterization test (if any divergence exists).** In an existing Research test file (or a new `SlugifierParityTests.swift`), assert that the chosen single implementation produces the expected slug for the cases where the two used to differ (e.g. a title that is all punctuation → `"untitled"`; a title with accents → folded). This pins the reconciled behavior.

- [ ] **Step 3: Replace `researchSlugify` calls with `Slugifier.slug`.** Delete `researchSlugify`. If `researchDedupedFilename` adds only the numeric-suffix dedup, keep that logic but have it call `Slugifier.slug` for the base. (The dedup loop itself is consolidated separately in Task 5.3 — leave it here for now, just fix the base slug.)

- [ ] **Step 4: Build.** Run the Mac suite. Expected: PASS. Pay attention to any research-import/filename tests.

- [ ] **Step 5: Commit.**
```bash
git add Maugham/Stores/ProjectStore+Research.swift MaughamTests/
git commit -m "refactor(stores): one slug implementation (Slugifier) for research + structure

researchSlugify and Slugifier could slug the same title differently; fold
research filenames onto the shared Slugifier. Adds parity test.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

## Task 2.6: Route Publish stripAnchors through MarkdownDisplayFilter

**Files:**
- Modify: `Maugham/Publish/ProjectASTBuilder.swift:149-165` (`stripAnchors`)
- Reference: `Packages/MaughamCore/Sources/MaughamCore/MarkdownDisplayFilter.swift`

- [ ] **Step 1: Read both.** Confirm `MarkdownDisplayFilter` strips both `<!-- ¶id -->` paragraph anchors and `<!--t-XXXXXX-->` task anchors (it is the named single source of truth). Confirm `stripAnchors` is doing the same job locally.

- [ ] **Step 2: Replace the body.** Make `ProjectASTBuilder.stripAnchors` call `MarkdownDisplayFilter` (the exact entry-point name — confirm from the file; the Mac editor's `RenderFilter.stripComments` forwards to it). If `stripAnchors` had extra Publish-specific behavior beyond anchor removal, keep only that extra part and delegate the anchor removal.

- [ ] **Step 3: Build.** Run the Mac suite. Pay attention to publishing/emitter tests (`PublishFileToolsTests`, AST/emitter tests). Expected: PASS.

- [ ] **Step 4: Commit.**
```bash
git add Maugham/Publish/ProjectASTBuilder.swift
git commit -m "refactor(publish): strip anchors via MarkdownDisplayFilter (single source)

Target-local anchor strippers are the class that leaked anchors on the phone
twice. Route Publish through the named single source of truth.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

**PHASE 2 GATE:** Both suites green. New Find-Replace integration tests pass. `grep "write(to:" Maugham/Stores/ProjectStore+Search.swift` returns nothing. One slug implementation. `stripAnchors` delegates to `MarkdownDisplayFilter`.

---

# PHASE 3 — Tree-walk consolidation

## Task 3.1: Add the TreeNode protocol + generic walkers to MaughamCore

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/TreeNode.swift`
- Test (new): `Packages/MaughamCore/Tests/MaughamCoreTests/TreeNodeTests.swift` (confirm the MaughamCore test dir path; mirror an existing test's location)

`StructureItem` and `ResearchItem` are both `id: String` + `children: [Self]?`. Generalize the ~36 hand-rolled walkers.

- [ ] **Step 1: Write the failing test.** Create `TreeNodeTests.swift`:

```swift
import XCTest
@testable import MaughamCore

final class TreeNodeTests: XCTestCase {

    // Minimal conforming node for testing the generic algorithms in isolation.
    struct Node: TreeNode, Equatable {
        var id: String
        var children: [Node]?
    }

    private func sample() -> [Node] {
        [Node(id: "a", children: [
            Node(id: "a1", children: nil),
            Node(id: "a2", children: [Node(id: "a2x", children: nil)]),
        ]),
         Node(id: "b", children: nil)]
    }

    func test_find_returnsDeepNode() {
        XCTAssertEqual(TreeWalk.find(id: "a2x", in: sample())?.id, "a2x")
        XCTAssertNil(TreeWalk.find(id: "nope", in: sample()))
    }

    func test_contains() {
        XCTAssertTrue(TreeWalk.contains(id: "a2", in: sample()))
        XCTAssertFalse(TreeWalk.contains(id: "zzz", in: sample()))
    }

    func test_collect_ids_preorder() {
        XCTAssertEqual(TreeWalk.collectIds(in: sample()),
                       ["a", "a1", "a2", "a2x", "b"])
    }

    func test_mutate_returnsNewTree_leavesOthersUntouched() {
        let updated = TreeWalk.mutate(id: "a1", in: sample()) { node in
            var n = node; n.id = "a1-renamed"; return n
        }
        XCTAssertTrue(TreeWalk.contains(id: "a1-renamed", in: updated))
        XCTAssertFalse(TreeWalk.contains(id: "a1", in: updated))
        XCTAssertTrue(TreeWalk.contains(id: "b", in: updated))
    }

    func test_remove_dropsSubtree() {
        let after = TreeWalk.remove(id: "a2", in: sample())
        XCTAssertFalse(TreeWalk.contains(id: "a2", in: after))
        XCTAssertFalse(TreeWalk.contains(id: "a2x", in: after)) // subtree gone
        XCTAssertTrue(TreeWalk.contains(id: "a1", in: after))
    }
}
```

- [ ] **Step 2: Run it — verify it fails to compile.**
```bash
swift test --package-path Packages/MaughamCore 2>&1 | tail -25
```
Expected: FAIL — `TreeNode`/`TreeWalk` undefined.

- [ ] **Step 3: Implement `TreeNode.swift`.**

```swift
import Foundation

/// A node in an id-keyed tree whose children are the same type.
/// Both `StructureItem` and `ResearchItem` conform; the generic walkers in
/// `TreeWalk` replace the per-type hand-rolled recursion that had drifted
/// across the codebase. Cross-surface contract: MaughamCore owns this; the
/// phone shares it (do not re-implement — see cross-surface-contracts.md).
public protocol TreeNode: Identifiable where ID == String {
    var id: String { get }
    var children: [Self]? { get set }
}

public enum TreeWalk {

    /// Pre-order depth-first search for a node by id.
    public static func find<N: TreeNode>(id: String, in nodes: [N]) -> N? {
        for node in nodes {
            if node.id == id { return node }
            if let kids = node.children, let hit = find(id: id, in: kids) {
                return hit
            }
        }
        return nil
    }

    public static func contains<N: TreeNode>(id: String, in nodes: [N]) -> Bool {
        find(id: id, in: nodes) != nil
    }

    /// Pre-order id list (parent before children).
    public static func collectIds<N: TreeNode>(in nodes: [N]) -> [String] {
        var out: [String] = []
        for node in nodes {
            out.append(node.id)
            if let kids = node.children { out.append(contentsOf: collectIds(in: kids)) }
        }
        return out
    }

    /// Returns a new tree with the node matching `id` transformed by `body`.
    /// Non-matching nodes are returned unchanged. `body` sees the matched
    /// node (with its already-transformed children) and returns the replacement.
    public static func mutate<N: TreeNode>(
        id: String, in nodes: [N], _ body: (N) -> N
    ) -> [N] {
        nodes.map { node in
            var node = node
            if let kids = node.children {
                node.children = mutate(id: id, in: kids, body)
            }
            return node.id == id ? body(node) : node
        }
    }

    /// Returns a new tree with the node matching `id` (and its subtree) removed.
    public static func remove<N: TreeNode>(id: String, in nodes: [N]) -> [N] {
        nodes.compactMap { node -> N? in
            if node.id == id { return nil }
            var node = node
            if let kids = node.children { node.children = remove(id: id, in: kids) }
            return node
        }
    }
}
```

- [ ] **Step 4: Run it — verify it passes.**
```bash
swift test --package-path Packages/MaughamCore 2>&1 | tail -15
```
Expected: PASS.

- [ ] **Step 5: Commit.**
```bash
git add Packages/MaughamCore/Sources/MaughamCore/TreeNode.swift Packages/MaughamCore/Tests/
git commit -m "feat(core): TreeNode protocol + generic TreeWalk (find/contains/collect/mutate/remove)

Foundation for de-duplicating ~36 hand-rolled StructureItem/ResearchItem
walkers. Cross-surface contract: MaughamCore owns it.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

## Task 3.2: Add path-rewrite + idsByPath walkers with the prefix reconciliation

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/TreeNode.swift`
- Modify: `Packages/MaughamCore/Tests/MaughamCoreTests/TreeNodeTests.swift`

The store layer has `rewriteChildPaths` (`dropFirst(oldPrefix.count)`) and `researchRewriteChildPaths` (`dropFirst(oldPrefix.count + 1)`). These disagree by one — a latent bug. Decide the correct semantics and encode it once.

- [ ] **Step 1: Determine correct semantics.** Read both `rewriteChildPaths` (in `ProjectStore+Structure.swift`) and `researchRewriteChildPaths` (in `ProjectStore+Research.swift`) end to end, plus a caller of each (a group rename). Establish: when a group's folder moves from `oldPrefix` to `newPrefix`, a child path `oldPrefix + "/" + rest` must become `newPrefix + "/" + rest`. Work out which `dropFirst` produces that WITHOUT double-slashing or eating a leading char. Write the conclusion as a comment in the test.

- [ ] **Step 2: Write the failing test** for the reconciled rule. Add to `TreeNodeTests.swift`:

```swift
func test_rewritePaths_replacesPrefix_noDoubleSlash_noEatenChar() {
    struct PNode: TreeNode, Equatable {
        var id: String
        var path: String?
        var children: [PNode]?
    }
    let tree = [PNode(id: "g", path: "old/group", children: [
        PNode(id: "d", path: "old/group/chapter.md", children: nil),
    ])]
    let rewritten = TreeWalk.rewritePaths(
        in: tree, replacingPrefix: "old/group", with: "new/place",
        path: \.path, setPath: { $0.path = $1 })
    let child = TreeWalk.find(id: "d", in: rewritten)
    XCTAssertEqual(child?.path, "new/place/chapter.md")
}
```

- [ ] **Step 3: Run — verify it fails** (`rewritePaths` undefined). Command as in Task 3.1 Step 2.

- [ ] **Step 4: Implement `rewritePaths` and `idsByPath`** in `TreeNode.swift`, using the prefix rule from Step 1. Use a keypath/closure for the path field since `path` isn't part of the `TreeNode` protocol:

```swift
extension TreeWalk {
    /// Rewrite the `path` of every node whose path begins with `oldPrefix`,
    /// replacing that prefix with `newPrefix`. Prefix semantics: a path equal
    /// to oldPrefix becomes newPrefix; a path `oldPrefix + "/" + rest` becomes
    /// `newPrefix + "/" + rest` (no double slash, no eaten character).
    public static func rewritePaths<N: TreeNode>(
        in nodes: [N],
        replacingPrefix oldPrefix: String,
        with newPrefix: String,
        path: (N) -> String?,
        setPath: (inout N, String) -> Void
    ) -> [N] {
        nodes.map { node in
            var node = node
            if let p = path(node), p == oldPrefix || p.hasPrefix(oldPrefix + "/") {
                let suffix = p.dropFirst(oldPrefix.count) // keeps leading "/" if present
                setPath(&node, newPrefix + suffix)
            }
            if let kids = node.children {
                node.children = rewritePaths(
                    in: kids, replacingPrefix: oldPrefix, with: newPrefix,
                    path: path, setPath: setPath)
            }
            return node
        }
    }
}
```
(If Step 1 concludes the `+1` variant was correct for one tree because its stored paths lacked the leading prefix slash, encode that as the documented rule and adjust the test accordingly — the test must encode whatever you proved correct.)

- [ ] **Step 5: Run — verify it passes.**

- [ ] **Step 6: Commit.**
```bash
git add Packages/MaughamCore/
git commit -m "feat(core): TreeWalk.rewritePaths + idsByPath with reconciled prefix rule

Unifies the rewriteChildPaths / researchRewriteChildPaths dropFirst(+1)
divergence into one tested rule.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

## Task 3.3: Conform the models + migrate the store layer

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/StructureItem.swift` (add `: TreeNode`)
- Modify: `Packages/MaughamCore/Sources/MaughamCore/ResearchItem.swift` (add `: TreeNode`)
- Modify: `Maugham/Stores/ProjectStore+Structure.swift`, `ProjectStore+Research.swift`, `ProjectStore.swift` (replace the hand-rolled walkers with `TreeWalk.*`)

- [ ] **Step 1: Conform the models.** Add `TreeNode` conformance to both structs. They already have `id: String` and `children: [Self]?` with get/set, so conformance should be declaration-only:
```swift
public struct StructureItem: Codable, Equatable, Identifiable, Sendable, TreeNode {
```
```swift
public struct ResearchItem: Codable, Equatable, Identifiable, Sendable, TreeNode {
```
Build MaughamCore: `swift build --package-path Packages/MaughamCore`. Expected: compiles.

- [ ] **Step 2: Migrate `ProjectStore+Structure.swift`.** Replace each hand-rolled walker (`findItem`, `findItemStatic`, `containsId`, `collectGroupIds`, `rewriteChildPaths`, etc.) with calls to `TreeWalk.*`. For `find`/`mutate`/`remove`/`contains`/`collectIds` use the generics directly. For path rewrite use `TreeWalk.rewritePaths(..., path: { $0.path }, setPath: { $0.path = $1 })`. Keep the PUBLIC method names that callers depend on as thin forwarders (e.g. `static func findItemStatic(id:in:) -> StructureItem? { TreeWalk.find(id: id, in: in_) }`) so external call sites compile unchanged — the migration of those call sites happens in Task 3.4.

- [ ] **Step 3: Migrate `ProjectStore+Research.swift`.** Same, deleting the `research`-prefixed family (`findResearchItem`, `researchContains`, `researchRewriteChildPaths`, `researchFreshIds`, etc.), replacing internal uses with `TreeWalk.*` or thin forwarders if a public name is referenced elsewhere.

- [ ] **Step 4: Run `./gen.sh` then the Mac suite.** Expected: PASS. The existing structure/research CRUD tests now exercise the generic walkers. Pay special attention to any rename-with-children test (the path-prefix reconciliation).

- [ ] **Step 5: Run the phone suite** (MaughamCore changed). Expected: PASS.

- [ ] **Step 6: Commit.**
```bash
git add -A
git commit -m "refactor(stores): StructureItem/ResearchItem conform TreeNode; walkers via TreeWalk

Deletes the duplicated per-type recursion (incl. the research* prefix family)
in favor of the generic MaughamCore walkers. Public method names kept as thin
forwarders pending call-site migration.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

## Task 3.4: Migrate the view/MCP/phone call sites + delete forwarders

**Files:**
- Modify: `Maugham/Views/ProjectWindow.swift` (the duplicate `findStructureItemByPath`/`findResearchItemByPath` at 415/939 & 428/952; `collectDocIds`/`collectDocPaths`), `BinderView.swift`, `EditorHost.swift`, `InspectorView.swift`, `InspectorLinksSection.swift`, `OutlinePane.swift`, `ResearchView.swift`, `ResearchLinkPickerSheet.swift`
- Modify: `Maugham/MCP/Tools/DocumentTools.swift`, `ProjectTools.swift`, `ReferenceTools.swift`, `TaskReadTools.swift`, `ListAllLinksTool.swift`, `ListDocumentsByTagTool.swift`, `AddNoteTool.swift`
- Modify (if shareable): MaughamPhone call sites that walk the tree

- [ ] **Step 1: Enumerate the copies.** Run:
```bash
grep -rn "func find\(Structure\|Research\)ItemByPath\|func collectDocIds\|func collectDocPaths\|func findItem(\|func collectAllDocIds" Maugham/ MaughamPhone/ | grep -v "Maugham.xcodeproj"
```
List every private copy.

- [ ] **Step 2: Migrate each call site** to `TreeWalk.*` (or a small shared `StructureItem`/`ResearchItem` extension for the path-keyed variants, e.g. `TreeWalk.find(byPath:in:path:\.path)` — add that helper to TreeNode.swift if the by-path lookup recurs enough to warrant it). Delete the per-file private copies. Within `ProjectWindow.swift`, collapse the TWO definitions of each duplicated helper into a single call.

- [ ] **Step 3: Delete now-unused forwarders** added in Task 3.3, if nothing references them anymore. Re-run the Step 1 grep; it should return only `TreeWalk`/extension definitions.

- [ ] **Step 4: `./gen.sh` + both suites.** Expected: PASS.

- [ ] **Step 5: Update the cross-surface registry.** Add a TreeNode/TreeWalk entry to `docs/superpowers/notes/cross-surface-contracts.md` (shared-impl tier: MaughamCore owns tree traversal; phone must not re-implement).

- [ ] **Step 6: Commit.**
```bash
git add -A
git commit -m "refactor: migrate all tree-walk call sites to TreeWalk; delete copies

Removes ~15 view/MCP private tree-walk copies (incl. two duplicate defs in
ProjectWindow.swift). Registers TreeNode/TreeWalk as a cross-surface contract.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

**PHASE 3 GATE:** Both suites green; the Step-1 grep in 3.4 returns only canonical definitions; rename-with-children path tests pass for both trees.

---

# PHASE 4 — File splits & boilerplate

## Task 4.1: Extract the load-recovery branches into a pure reconcile()

**Files:**
- Modify: `Maugham/OpLog/Document.swift` (lines ~268–380, inside `load`)
- Test (new): `MaughamTests/OpLog/DocumentReconcileTests.swift`

Do this BEFORE the file split (4.2) so the diff is reviewable against the current file.

- [ ] **Step 1: Write the failing test** capturing the four branches as named cases:

```swift
import XCTest
@testable import Maugham
import MaughamCore

final class DocumentReconcileTests: XCTestCase {

    private func parsed(_ pairs: [(String?, String)]) -> [ParagraphParser.Paragraph] {
        // TODO(implementer): construct ParagraphParser.Paragraph values matching
        // the real type (confirm initializer/shape). Each pair is (id?, text).
        fatalError("construct real ParagraphParser.Paragraph values")
    }

    func test_branch1_emptyDerived_seedsFromParsedIds() {
        let derived = Deriver.DerivedState(paragraphs: [:], sequence: [])
        let out = Document.reconcile(
            derived: derived, parsed: parsed([("aaaa", "Hello"), ("bbbb", "World")]))
        XCTAssertEqual(out.sequence, ["aaaa", "bbbb"])
        XCTAssertEqual(out.paragraphs["aaaa"], "Hello")
    }

    func test_branch4_dropsOrphansNotInSequence() {
        let derived = Deriver.DerivedState(
            paragraphs: ["aaaa": "Hello", "zzzz": "orphan"], sequence: ["aaaa"])
        let out = Document.reconcile(
            derived: derived, parsed: parsed([("aaaa", "Hello")]))
        XCTAssertNil(out.paragraphs["zzzz"])
        XCTAssertEqual(Set(out.paragraphs.keys), Set(out.sequence))
    }

    func test_branch3_parsedHasNewIds_trustsParsedOrdering() {
        let derived = Deriver.DerivedState(
            paragraphs: ["aaaa": "old"], sequence: ["aaaa"])
        let out = Document.reconcile(
            derived: derived,
            parsed: parsed([("aaaa", "old"), ("cccc", "new para")]))
        XCTAssertEqual(out.sequence, ["aaaa", "cccc"])
        XCTAssertEqual(out.paragraphs["cccc"], "new para")
    }
}
```
Use 4-char alphabet-restricted ids (`aaaa`/`bbbb` etc.) — tripwire 8 (this test crosses the parsed-anchors boundary).

- [ ] **Step 2: Run — verify it fails** (`Document.reconcile` undefined).
```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham -only-testing:MaughamTests/DocumentReconcileTests test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

- [ ] **Step 3: Extract the function.** Create a `static func reconcile(derived: Deriver.DerivedState, parsed: [ParagraphParser.Paragraph]) -> Deriver.DerivedState` containing the EXACT logic currently at Document.swift lines ~282–380 (branches 1–4). Do not change the logic — only lift it. In `load`, replace those lines with `let initial = Document.reconcile(derived: Deriver.derive(ops: ops) /* the post-crash-recovery value */, parsed: parsed)`. Keep the crash-recovery block (lines 256–266) where it is — `reconcile` starts from the derived state AFTER recovery.

- [ ] **Step 4: Run the new test + full Mac suite.** Expected: PASS. The existing `Document` load tests still pass (logic unchanged); the new tests pin the branches.

- [ ] **Step 5: Commit.**
```bash
git add Maugham/OpLog/Document.swift MaughamTests/OpLog/DocumentReconcileTests.swift
git commit -m "refactor(oplog): extract load-recovery branches into pure Document.reconcile

The four reconstruction branches decided what the writer sees on open but were
untestable, inlined in an async factory. Lifted verbatim into a pure function
with direct unit tests. No logic change.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

## Task 4.2: Split Document.swift into extension files

**Files:**
- Create: `Maugham/OpLog/Document+Load.swift`, `Document+Tasks.swift`, `Document+Annotations.swift`, `Document+Rewind.swift`, `Document+ExternalChange.swift`
- Modify: `Maugham/OpLog/Document.swift` (keep the stored properties, init, and core display/paragraph members)

Pure file move. The stored properties of an `@Observable @MainActor` class must stay in the main declaration; only methods move to `extension Document` in peer files.

- [ ] **Step 1: Map the moves.** Read `Document.swift` and assign each method to a peer file by the spec's seams:
  - `Document+Load.swift`: `load` (both overloads), `reconcile`, `resolveDocId`, `resolveProjectURL`, `findItemByPath` (the free funcs), crash-recovery helpers.
  - `Document+Tasks.swift`: task read/mutation/anchor-splice + V2 alignment driving + `changeTouchesTaskMarkup`.
  - `Document+Annotations.swift`: annotation read + mutation + `isAnnotationOpKind`.
  - `Document+Rewind.swift`: `restoreToOp`, rewind base-op construction.
  - `Document+ExternalChange.swift`: external-change/conflict handling, `applyExternalText` routing.
  - Stays in `Document.swift`: stored props, `init`, `setFullText`, `setParagraph`, `recomputeDisplayText`, `displayText`/`paragraphId(at:)`/`paragraph(id:)`, burst/autosave scheduling.

- [ ] **Step 2: Move methods one file at a time.** For each peer file: create it with `import Foundation` (+ `import MaughamCore` / `import AppKit` as the moved code needs), an `extension Document { ... }` wrapper, and the cut methods. Cut (don't copy) from `Document.swift`. Keep `private` members that are only used within one peer file `private` IN that file; if a `private` member is used across files, change it to `internal` (no `private` cross-file access). After EACH file move, build:
```bash
./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```
Expected: compiles. (Build, not test, between moves for speed; full test at the end.)

- [ ] **Step 3: Fix the misplaced doc-comment.** While in `Document.swift`, fix the comment on `paragraph(id:)` (~line 455) that currently describes `paragraphId(at:)`. Split it so each function's comment matches it.

- [ ] **Step 4: Full Mac suite + phone suite.** Expected: PASS.

- [ ] **Step 5: Commit.**
```bash
git add -A
git commit -m "refactor(oplog): split Document.swift into Load/Tasks/Annotations/Rewind/ExternalChange

Pure file move following the ProjectStore+* precedent; no logic change. 2111-line
file becomes a focused core + five extension peers. Fixes misplaced paragraph(id:)
doc-comment.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

## Task 4.3: Extract MCPBannerModel + move embedded views out of ProjectWindow

**Files:**
- Create: `Maugham/Views/MCPBannerModel.swift`
- Create: `Maugham/Views/ResearchNoteEditor.swift` (move from ProjectWindow.swift ~1277–1367)
- Create: `Maugham/Views/WindowAccessor.swift` (move `WindowAccessor`)
- Modify: `Maugham/Views/ProjectWindow.swift`

- [ ] **Step 1: Move `ResearchNoteEditor` and `WindowAccessor`** to their own files verbatim (cut, add imports). `./gen.sh` + build. Expected: compiles.

- [ ] **Step 2: Create `MCPBannerModel`.**
```swift
import Foundation

/// Owns the transient "Claude added a note" banner state, extracted from
/// ProjectWindow so the four fields + dismiss task no longer thread through a
/// ViewModifier purely to dodge the SwiftUI type-checker.
@MainActor @Observable
final class MCPBannerModel {
    var title: String?
    var count: Int = 0
    var latestId: String?
    private var dismissTask: Task<Void, Never>?

    func show(title: String, count: Int, latestId: String) {
        self.title = title; self.count = count; self.latestId = latestId
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel(); dismissTask = nil
        title = nil; count = 0; latestId = nil
    }
}
```

- [ ] **Step 3: Wire it into ProjectWindow.** Replace the four `@State` banner fields (`mcpBannerTitle/Count/LatestId/DismissTask`) with `@State private var mcpBanner = MCPBannerModel()`. Update the `.maughamMCPNoteAdded` handler in `SessionAndNavigationModifier` to call `mcpBanner.show(...)`, and the dismiss/show-latest buttons to use the model. Remove the now-dead `handleDismissMCPBanner`/`handleShowLatestMCPNote` if the model subsumes them.

- [ ] **Step 4: `./gen.sh` + Mac suite.** Expected: PASS. Manually confirm no behavior change to the banner is testable; rely on build + existing tests.

- [ ] **Step 5: Commit.**
```bash
git add -A
git commit -m "refactor(views): extract MCPBannerModel; move ResearchNoteEditor/WindowAccessor out

Pulls the banner state machine off ProjectWindow's 30-property @State bag into a
small @Observable model; relocates two embedded views to their own files.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

## Task 4.4: Merge the two piece inspectors

**Files:**
- Create: `Maugham/Views/PieceInspector.swift`
- Delete: `Maugham/Views/ProsePieceInspector.swift`, `Maugham/Views/ScreenplayPieceInspector.swift`
- Modify: call sites of the two old inspectors

- [ ] **Step 1: Find call sites.** Run:
```bash
grep -rn "ProsePieceInspector\|ScreenplayPieceInspector" Maugham/ | grep -v "Maugham.xcodeproj"
```

- [ ] **Step 2: Create `PieceInspector`** parameterized by a kind enum capturing the only differences (word-target: range 0…100k step 100, label "Words", symbol; vs page-target: 0…500 step 1, label "Pages", symbol). Reuse the byte-identical `synopsisSection`/`statusSection` once. Honor tripwire 15 if it renders any empty state.

- [ ] **Step 3: Update call sites** to `PieceInspector(kind: .prose ...)` / `.screenplay`. `git rm` the two old files. `./gen.sh`.

- [ ] **Step 4: Mac suite.** Expected: PASS.

- [ ] **Step 5: Commit.**
```bash
git add -A
git commit -m "refactor(views): merge Prose/ScreenplayPieceInspector into one PieceInspector

~90% was identical (synopsis/status sections byte-for-byte); parameterize the
target field by a small kind enum.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

## Task 4.5: Shared MCP decode + project-resolve helpers; one unknown-project error

**Files:**
- Create: `Maugham/MCP/MCPToolHelpers.swift` (or add to the `MCPTool` protocol extension — confirm where `MCPToolCatalog`/`MCPTool` live)
- Modify: every tool in `Maugham/MCP/Tools/` that decodes params + looks up a project

- [ ] **Step 1: Inventory the patterns.** Run:
```bash
grep -rln "JSONDecoder().decode\|registry.lookup\|projectNotOpen\|unknown project_id" Maugham/MCP/Tools/ | grep -v "Maugham.xcodeproj"
```
Read `AnnotationCreationTools.swift` for the in-repo model (`decodeAnnotationParams` + `withAnnotationDocument`).

- [ ] **Step 2: Add the shared helpers.**
```swift
import Foundation
import MaughamCore

extension MCPTool {
    /// Decode tool params or throw a structured invalidArgument error.
    static func decodeParams<P: Decodable>(_ type: P.Type, from json: Data?) throws -> P {
        guard let json,
              let decoded = try? JSONDecoder().decode(P.self, from: json) else {
            throw MCPError.invalidArgument("malformed or missing parameters for \(method)")
        }
        return decoded
    }

    /// Resolve an open project by id or throw the canonical unknown-project error.
    static func resolveProject(
        _ id: String, in registry: ProjectRegistry  // match the real registry type
    ) throws -> ProjectStore {                       // match the real return type
        guard let store = registry.lookup(id: id) else {
            throw MCPError.unknownProjectID(id)
        }
        return store
    }
}
```
Confirm the real registry type and lookup signature; adapt names. `method` is the existing `MCPTool` requirement.

- [ ] **Step 3: Migrate each tool** to use `Self.decodeParams(...)` and `Self.resolveProject(...)`, removing the per-tool decode guard and lookup guard. Replace every `MCPError.projectNotOpen` / `invalidArgument("unknown project_id")` used for a *tool-level* unknown id with the `resolveProject` path (so the error is uniformly `unknownProjectID`). Leave `projectNotOpen` only where it is a genuine protocol-level condition (if any).

- [ ] **Step 4: `./gen.sh` + Mac suite.** Expected: PASS. The MCP tool tests assert on error codes — if any asserted `projectNotOpen` for an unknown id, update that assertion to the structured `unknown_project_id` error and note it in the commit.

- [ ] **Step 5: Commit.**
```bash
git add -A
git commit -m "refactor(mcp): shared decodeParams/resolveProject; uniform unknown_project_id error

Collapses the decode-guard + registry-lookup boilerplate repeated across ~34
tool sites and standardizes the three spellings of unknown-project on the
structured unknownProjectID error.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

**PHASE 4 GATE:** Both suites green. `Document.swift` and each peer comprehensible alone; `reconcile` unit-tested. One piece inspector. MCP unknown-project error uniform.

---

# PHASE 5 — CollectionPieces internal seams (opportunistic)

## Task 5.1: Extract resolveLoosePiece helper

**Files:**
- Modify: `Maugham/Stores/ProjectStore+CollectionPieces.swift`

- [ ] **Step 1: Identify the repeated preamble.** Read `addPieceResearchNote`/`addPieceResearchAsset`/`addPieceResearchLink`; confirm the verbatim `guard manifest.type == .collection ... guard let piece ... pieceFolder/researchFolder` opening.

- [ ] **Step 2: Add the helper.**
```swift
private func resolveLoosePiece(_ pieceId: String) throws
    -> (piece: StructureItem, pieceFolder: String, researchFolder: String) {
    // Move the shared preamble here verbatim; throw the same errors it threw.
}
```

- [ ] **Step 3: Replace the three preambles** with `let (piece, pieceFolder, researchFolder) = try resolveLoosePiece(pieceId)`.

- [ ] **Step 4: Mac suite** (watch `CollectionPiecesPane`/collection tests). Expected: PASS.

- [ ] **Step 5: Commit.**
```bash
git add Maugham/Stores/ProjectStore+CollectionPieces.swift
git commit -m "refactor(stores): extract resolveLoosePiece; collapse 3 verbatim preambles

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

## Task 5.2: Break up promotePieceToProject

**Files:**
- Modify: `Maugham/Stores/ProjectStore+CollectionPieces.swift` (`promotePieceToProject` ~179–331)

- [ ] **Step 1: Identify the staging steps.** The ~150-line method does: create staging folder, move doc, move research, build manifest, validate-by-load, atomic replace, convert to reference, prune research — under one rollback `catch`.

- [ ] **Step 2: Extract named private helpers** for each cohesive step (e.g. `stageDocument`, `stageResearch`, `buildPromotedManifest`, `validateByLoad`, `atomicReplaceIntoProjects`, `convertPieceToReference`). Keep them `throws` and keep the SINGLE top-level `do/catch` rollback in `promotePieceToProject` — the helpers throw, the orchestrator rolls back. Do not change the staging order or rollback semantics.

- [ ] **Step 3: Mac suite.** Expected: PASS. (If a promotion integration test exists, it is the safety net; if not, rely on build + manual smoke at milestone end.)

- [ ] **Step 4: Commit.**
```bash
git add Maugham/Stores/ProjectStore+CollectionPieces.swift
git commit -m "refactor(stores): decompose promotePieceToProject into named staging helpers

Same staging order + single rollback; the 8 steps are now individually
readable. No behavior change.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

## Task 5.3: Consolidate the slug-dedup loop

**Files:**
- Create or modify: a shared dedup helper in MaughamCore or `ProjectStore` (confirm best home)
- Modify: `ProjectStore+CollectionPieces.swift`, `ProjectStore+Structure.swift`, `ProjectStore+Research.swift`

- [ ] **Step 1: Find the variants.** Run:
```bash
grep -rn "while.*contains\|suffix\|counter\|-2\b\|append(\"-\\\\(" Maugham/Stores/ProjectStore+*.swift | grep -i "slug\|filename\|dedup"
```
Read each "dedup a base name against a Set with a numeric suffix" loop (~6 of them).

- [ ] **Step 2: Add one helper.**
```swift
/// Returns `base` if not in `taken`, else `base-2`, `base-3`, ... until free.
public static func dedupedName(_ base: String, taken: Set<String>) -> String {
    guard taken.contains(base) else { return base }
    var n = 2
    while taken.contains("\(base)-\(n)") { n += 1 }
    return "\(base)-\(n)"
}
```
Match the EXACT suffix format the existing loops use (confirm in Step 1 — `-2` vs `_2` vs ` 2`). If they differ, pick the dominant format and note the unification in the commit.

- [ ] **Step 3: Write a quick unit test** for `dedupedName` (free name, one collision, chain of collisions).

- [ ] **Step 4: Replace the ~6 loops** with calls to the helper.

- [ ] **Step 5: Both suites.** Expected: PASS.

- [ ] **Step 6: Commit.**
```bash
git add -A
git commit -m "refactor(stores): one dedupedName helper for slug/filename collision suffixes

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

**PHASE 5 GATE:** Both suites green.

---

# Milestone close-out

- [ ] **Full clean test run, both schemes.**
```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham clean test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```
- [ ] **Hand off for manual smoke** (user-run, per the smoke-test contract): launch → open a project → Find-Replace across an open AND a closed doc → confirm replaced + survives quit/relaunch; rename a binder group with children → child paths intact; Tasks + Annotations panes still populate; promote a loose piece to a project.
- [ ] **Offer the finishing-a-development-branch flow** (merge to main / PR) after smoke passes.

---

## Self-review notes (for the executor)

- **Spec coverage:** every spec phase item maps to a task (1.1–1.5, 2.1–2.6, 3.1–3.4, 4.1–4.5, 5.1–5.3). Out-of-scope items (Fountain classifier unification, MCP restart flake, Tasks off-main-actor) are intentionally absent.
- **Type names to confirm before coding** (the executor MUST verify these against the real source, noted inline where they occur): `ProjectStore.load` signature, `SearchOptions.init`, `Document.resolveDocId` visibility, `ParagraphParser.Paragraph` shape, the MCP registry type + `lookup` signature, the MaughamCore test directory path, and the exact `MarkdownDisplayFilter` entry-point name.
- **Risk-ordered:** safe deletions first, correctness fixes second, broad consolidation third, mechanical splits fourth, opportunistic last. Each phase gate is a hard stop.
