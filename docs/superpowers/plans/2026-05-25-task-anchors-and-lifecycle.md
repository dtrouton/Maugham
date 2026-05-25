# Task Anchors and Lifecycle — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Use **opus** for tasks marked `[opus]` (substantive design decisions); **sonnet** for tasks marked `[sonnet]` (mechanical scaffolding).

**Goal:** Replace paragraph-derived inline task identity with **per-task `<!--t-XXXXXX-->` anchors** persisted to the `.md`. Add **open / done / archived** lifecycle where Archive removes text from the manuscript, manual line deletion auto-archives, and a **bulk "Archive all done"** action lives in the pane kebab. Cursor-bias **V2 alignment** preserves anchors through cross-paragraph cut/paste of any size.

**Reference spec:** [`docs/superpowers/specs/2026-05-25-task-anchors-and-lifecycle.md`](../specs/2026-05-25-task-anchors-and-lifecycle.md). **Reference ADR:** [`docs/adr/0011-tasks-first-class-with-inline-anchors.md`](../../adr/0011-tasks-first-class-with-inline-anchors.md).

**Tech stack:** Swift, SwiftUI, AppKit, XCTest. macOS 14+. xcodegen via `./gen.sh`. Branch: `claude/friendly-hamilton-60i0v`.

**Pre-flight:**

```bash
./gen.sh
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Test count at branch tip: 990. Plan target: ~1030 (40+ new tests across all phases).

**Migration:** Existing test data is discarded per CLAUDE.md tripwire #11 and user okay. The Test Novel and any other test projects must be deleted before first launch with the new code. The implementation includes no migration shim.

---

## Task 1: `TaskAnchorID` type [sonnet]

Mechanical: a 6-char alphabet-restricted anchor ID mint + comment-format helpers. Mirrors `ParagraphID`.

**Files:**
- Create: `Maugham/OpLog/TaskAnchorID.swift`
- Create: `MaughamTests/TaskAnchorIDTests.swift`

- [ ] **Step 1.1: Write failing tests**

```swift
import XCTest
@testable import Maugham

final class TaskAnchorIDTests: XCTestCase {
    func test_mint_returnsSixCharFromAlphabet() {
        for _ in 0..<200 {
            let id = TaskAnchorID.mint()
            XCTAssertEqual(id.count, 6)
            XCTAssertTrue(id.allSatisfy {
                "0123456789abcdefghjkmnpqrstvwxyz".contains($0)
            })
        }
    }

    func test_parseComment_validAnchor_returnsId() {
        XCTAssertEqual(TaskAnchorID.parseComment("<!--t-9k2x6a-->"), "9k2x6a")
        XCTAssertEqual(TaskAnchorID.parseComment("<!--t-abcdef-->"), "abcdef")
    }

    func test_parseComment_rejectsInvalid() {
        XCTAssertNil(TaskAnchorID.parseComment("<!-- ¶mnj6qx -->"))  // paragraph
        XCTAssertNil(TaskAnchorID.parseComment("<!--t-toolong-1-->"))
        XCTAssertNil(TaskAnchorID.parseComment("<!--t-12345-->"))  // 5 chars
        XCTAssertNil(TaskAnchorID.parseComment("<!--t-9K2X6A-->"))  // uppercase
        XCTAssertNil(TaskAnchorID.parseComment("ignore <!--t-9k2x6a-->"))  // surrounding text
        XCTAssertNil(TaskAnchorID.parseComment(""))
    }

    func test_formatComment_roundTrips() {
        let id = TaskAnchorID.mint()
        let comment = TaskAnchorID.formatComment(id)
        XCTAssertEqual(TaskAnchorID.parseComment(comment), id)
    }
}
```

- [ ] **Step 1.2: Run, expect FAIL** (type undefined)
- [ ] **Step 1.3: Create `Maugham/OpLog/TaskAnchorID.swift`**

```swift
import Foundation

public enum TaskAnchorID {
    /// Alphabet chosen to skip homoglyphs (no `i`, `l`, `o`, `u`) so anchors
    /// remain visually distinguishable in raw .md inspection. Matches
    /// ParagraphID's alphabet.
    private static let alphabet: [Character] = Array(
        "0123456789abcdefghjkmnpqrstvwxyz")

    /// Mint a fresh 6-char anchor id. 32^6 = ~1B combinations; birthday
    /// collision risk becomes meaningful only past ~30K anchors per doc.
    public static func mint() -> String {
        String((0..<6).map { _ in alphabet.randomElement()! })
    }

    /// Parse `<!--t-XXXXXX-->` (exact form, no surrounding chars) and return
    /// the inner 6-char id. Returns nil for any non-matching input.
    public static func parseComment(_ s: String) -> String? {
        let pattern = #"^<!--t-([0123456789abcdefghjkmnpqrstvwxyz]{6})-->$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: s,
                  range: NSRange(s.startIndex..., in: s)),
              let range = Range(match.range(at: 1), in: s) else { return nil }
        return String(s[range])
    }

    public static func formatComment(_ id: String) -> String {
        "<!--t-\(id)-->"
    }
}
```

- [ ] **Step 1.4: Run tests, expect PASS**
- [ ] **Step 1.5: Full suite green**

```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

- [ ] **Step 1.6: Commit**

```bash
git add Maugham/OpLog/TaskAnchorID.swift MaughamTests/TaskAnchorIDTests.swift
git commit -m "feat(oplog): TaskAnchorID — 6-char inline task anchor id"
```

---

## Task 2: `RenderFilter` extension — strip + restore task anchors [opus]

The critical seam. Property: `restoreComments(stripComments(x)) == x` for any anchored input. Mirrors paragraph-anchor handling.

**Files:**
- Edit: `Maugham/OpLog/RenderFilter.swift`
- Create: `MaughamTests/RenderFilterTaskAnchorTests.swift`

- [ ] **Step 2.1: Write failing tests**

```swift
final class RenderFilterTaskAnchorTests: XCTestCase {

    func test_stripComments_removesTaskAnchor() {
        let stored = "- [ ] foo <!--t-9k2x6a-->"
        XCTAssertEqual(RenderFilter.stripComments(stored), "- [ ] foo")
    }

    func test_stripComments_removesMultipleTaskAnchorsAcrossLines() {
        let stored = """
        - [ ] foo <!--t-9k2x6a-->
        - [x] bar <!--t-p3rtab-->
        """
        let expected = """
        - [ ] foo
        - [x] bar
        """
        XCTAssertEqual(RenderFilter.stripComments(stored), expected)
    }

    func test_stripComments_removesInlineFountainAnchor() {
        let stored = "Anna walked [[todo: tighten]]<!--t-9k2x6a--> across the room."
        XCTAssertEqual(
            RenderFilter.stripComments(stored),
            "Anna walked [[todo: tighten]] across the room.")
    }

    func test_stripComments_preservesParagraphAnchors() {
        // Paragraph anchors are stripped by a different pass; the test
        // here asserts the task-anchor strip doesn't accidentally touch them.
        let stored = "<!-- ¶mnj6qx -->\n- [ ] foo <!--t-9k2x6a-->"
        let stripped = RenderFilter.stripComments(stored)
        // Paragraph anchor handling lives elsewhere; assert task anchor
        // is gone and the paragraph anchor remains for the paragraph-pass.
        XCTAssertFalse(stripped.contains("<!--t-"))
        XCTAssertTrue(stripped.contains("<!-- ¶mnj6qx -->"))
    }

    func test_restoreComments_reInjectsTaskAnchorOnUnchangedLine() {
        let prior = "- [ ] foo <!--t-9k2x6a-->"
        let displayed = "- [ ] foo"
        XCTAssertEqual(RenderFilter.restoreTaskAnchors(
            prior: prior, displayed: displayed), prior)
    }

    func test_restoreComments_reInjectsAnchorOnRenamedLine_positionMatch() {
        let prior = "- [ ] foo <!--t-9k2x6a-->"
        let displayed = "- [ ] Tighten foo"
        // Body changed but line position is the same — anchor follows.
        XCTAssertEqual(
            RenderFilter.restoreTaskAnchors(prior: prior, displayed: displayed),
            "- [ ] Tighten foo <!--t-9k2x6a-->")
    }

    func test_restoreComments_inlineFountainTodo() {
        let prior = "Anna [[todo: tighten]]<!--t-9k2x6a--> walked."
        let displayed = "Anna [[todo: tighten]] walked."
        XCTAssertEqual(
            RenderFilter.restoreTaskAnchors(prior: prior, displayed: displayed),
            prior)
    }

    func test_roundTrip_property_unchangedTextStripsAndRestores() {
        let cases: [String] = [
            "- [ ] foo <!--t-9k2x6a-->",
            "- [x] done it <!--t-p3rtab-->",
            "Anna [[todo: tighten]]<!--t-w8mqcd--> walked.",
            "[[todo: scene rework]]<!--t-jqdz7n--> Opening line of paragraph.",
            // Multiple anchored lines:
            """
            - [ ] foo <!--t-aaaaaa-->
            - [ ] bar <!--t-bbbbbb-->
            - [x] baz <!--t-cccccc-->
            """,
        ]
        for input in cases {
            let stripped = RenderFilter.stripComments(input)
            let restored = RenderFilter.restoreTaskAnchors(
                prior: input, displayed: stripped)
            XCTAssertEqual(restored, input, "round-trip failed for: \(input)")
        }
    }
}
```

- [ ] **Step 2.2: Run, expect FAIL** (helper not yet defined)
- [ ] **Step 2.3: Extend `RenderFilter` with task-anchor strip + restore**

The existing `RenderFilter.stripComments` strips paragraph anchors via a regex. Add a second regex pass for task anchors:

```swift
private static let taskAnchorRegex = try! NSRegularExpression(
    pattern: #"\s?<!--t-[0123456789abcdefghjkmnpqrstvwxyz]{6}-->"#)

// Inside stripComments, after the paragraph-anchor strip:
let nsStripped = taskAnchorRegex.stringByReplacingMatches(
    in: result, range: NSRange(0..<(result as NSString).length),
    withTemplate: "")
```

Note the `\s?` consumes the **leading** space if present — preserves spacing when displaying inline `[[todo: …]]<!--t-X-->` inside prose.

Then add `restoreTaskAnchors(prior:displayed:) -> String` which runs Pass 1 of the V2 alignment (per-paragraph body-match + LCS). This stub is the building block Task 3 below extends:

```swift
public static func restoreTaskAnchors(
    prior: String, displayed: String
) -> String {
    // Single-paragraph restore. Used by tests directly; the Document
    // setFullText path uses the multi-paragraph version in Task 5.
    let priorLines = prior.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let displayedLines = displayed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    return restoreLineByLine(priorLines: priorLines, displayedLines: displayedLines)
        .joined(separator: "\n")
}

internal static func restoreLineByLine(
    priorLines: [String], displayedLines: [String]
) -> [String] {
    // Pass 1 — body-match across the line pool.
    // Pass 2 — LCS over unclaimed.
    // Re-attach anchors from paired prior lines.
    // ... full impl in §2.4.1 of the spec.
}
```

- [ ] **Step 2.4: Iterate to green**

The body-match + LCS implementation has subtleties. Iterate against the test cases until green. Likely needs 1–2 rounds.

- [ ] **Step 2.5: Full suite green + commit**

```bash
git add Maugham/OpLog/RenderFilter.swift MaughamTests/RenderFilterTaskAnchorTests.swift
git commit -m "feat(oplog): RenderFilter strip + per-paragraph restore for task anchors"
```

---

## Task 3: Scanner extensions — recognize anchors inline [opus]

Extend `MarkdownCheckboxScanner.match` and `FountainBoneyardScanner.matchTodo` (and `matchAll`) to return an optional `anchorId` field. Body capture group excludes the anchor markup.

**Files:**
- Edit: `Maugham/OpLog/InlineTaskScanners.swift`
- Create: `MaughamTests/InlineTaskScannerAnchorTests.swift`

- [ ] **Step 3.1: Write failing tests**

```swift
final class InlineTaskScannerAnchorTests: XCTestCase {

    func test_markdownScanner_recognizesAnchor() {
        let match = MarkdownCheckboxScanner.match(
            "- [ ] tighten this <!--t-9k2x6a-->")
        XCTAssertEqual(match?.body, "tighten this")
        XCTAssertEqual(match?.anchorId, "9k2x6a")
    }

    func test_markdownScanner_unanchoredLine_anchorIdIsNil() {
        let match = MarkdownCheckboxScanner.match("- [ ] tighten this")
        XCTAssertEqual(match?.body, "tighten this")
        XCTAssertNil(match?.anchorId)
    }

    func test_markdownScanner_anchorMustBeAtEndOfLine() {
        // Trailing content after anchor is not allowed (well-formed lines
        // only have anchor at very end after a single space).
        let match = MarkdownCheckboxScanner.match(
            "- [ ] tighten this <!--t-9k2x6a--> extra stuff")
        // Either parse body to include "<!--t-...-->" + "extra stuff",
        // or treat as no-anchor. Choose: body includes everything past
        // the bracket, anchorId is nil. Test pins this.
        XCTAssertNil(match?.anchorId)
    }

    func test_fountainScanner_matchAll_recognizesAnchors() {
        let para = "First [[todo: a]]<!--t-aaaaaa--> middle [[done: b]]<!--t-bbbbbb--> last."
        let matches = FountainBoneyardScanner.matchAll(para)
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches[0].body, "a")
        XCTAssertEqual(matches[0].anchorId, "aaaaaa")
        XCTAssertEqual(matches[0].done, false)
        XCTAssertEqual(matches[1].body, "b")
        XCTAssertEqual(matches[1].anchorId, "bbbbbb")
        XCTAssertEqual(matches[1].done, true)
    }

    func test_fountainScanner_unanchoredTodo_anchorIdIsNil() {
        let matches = FountainBoneyardScanner.matchAll("[[todo: x]]")
        XCTAssertEqual(matches.count, 1)
        XCTAssertNil(matches[0].anchorId)
    }
}
```

- [ ] **Step 3.2: Run, expect FAIL**
- [ ] **Step 3.3: Extend `MarkdownCheckboxScanner.Match` + `FountainBoneyardScanner.Match`**

Add `anchorId: String?` to each Match struct. Extend regexes to capture an optional `\s+<!--t-([a-z0-9]{6})-->` group at the end of the body region.

- [ ] **Step 3.4: Run tests, iterate to green**
- [ ] **Step 3.5: Full suite green + commit**

```bash
git add Maugham/OpLog/InlineTaskScanners.swift MaughamTests/InlineTaskScannerAnchorTests.swift
git commit -m "feat(oplog): scanners return optional anchorId for inline tasks"
```

---

## Task 4: `TaskDeriver` — anchor-based synth-id + mint on first encounter [opus]

The deriver moves from `inline:<docId>:<paraId>:<bodyHash>` to `inline:<docId>:<anchorId>`. Tasks without anchors get freshly minted ids; the deriver returns a side-channel `mintedAnchors: [(paragraphId, body, anchorId)]` so the caller can persist them back to paragraph text.

**Files:**
- Edit: `Maugham/OpLog/TaskDeriver.swift`
- Edit: `MaughamTests/TaskDeriverTests.swift` (extend; some prior assertions about `bodyHash`-based ids must update)

- [ ] **Step 4.1: Update existing TaskDeriverTests for new id shape**

Every existing test that asserts an `id` field of an inline task currently uses `inline:<docId>:<paraId>:<bodyHash>`. Update to expect `inline:<docId>:<anchorId>` where `<anchorId>` matches `[a-z0-9]{6}`. Use regex assertions or capture-the-id helpers since the minted value is random.

- [ ] **Step 4.2: Add new minting tests**

```swift
func test_derive_unanchoredInlineTask_mintsAnchor() {
    let paraId = ParagraphID.mint()
    let paragraphs = [paraId: "- [ ] foo"]
    let result = TaskDeriver.derive(
        ops: [], paragraphs: paragraphs, docId: "doc-x")
    XCTAssertEqual(result.tasks.count, 1)
    XCTAssertEqual(result.mintedAnchors.count, 1)
    let minted = result.mintedAnchors[0]
    XCTAssertEqual(minted.paragraphId, paraId)
    XCTAssertEqual(minted.body, "foo")
    XCTAssertTrue(minted.anchorId.count == 6)
    XCTAssertEqual(result.tasks[0].id, "inline:doc-x:\(minted.anchorId)")
}

func test_derive_anchoredInlineTask_preservesAnchor() {
    let paraId = ParagraphID.mint()
    let paragraphs = [paraId: "- [ ] foo <!--t-9k2x6a-->"]
    let result = TaskDeriver.derive(
        ops: [], paragraphs: paragraphs, docId: "doc-x")
    XCTAssertEqual(result.tasks.count, 1)
    XCTAssertEqual(result.tasks[0].id, "inline:doc-x:9k2x6a")
    XCTAssertTrue(result.mintedAnchors.isEmpty,
        "anchored tasks should NOT trigger minting")
}

func test_derive_duplicateBodyAnchoredDistinctly_yieldsTwoTasks() {
    let paraId = ParagraphID.mint()
    let paragraphs = [paraId: """
    - [ ] foo <!--t-aaaaaa-->
    - [ ] foo <!--t-bbbbbb-->
    """]
    let result = TaskDeriver.derive(
        ops: [], paragraphs: paragraphs, docId: "doc-x")
    XCTAssertEqual(result.tasks.count, 2,
        "two anchored duplicates must be distinct tasks")
    XCTAssertEqual(Set(result.tasks.map(\.id)),
        ["inline:doc-x:aaaaaa", "inline:doc-x:bbbbbb"])
}
```

- [ ] **Step 4.3: Extend `TaskDeriver.derive` return type**

Currently returns `(tasks: [WriterTask], rebalanceOps: [Op])`. Add `mintedAnchors: [MintedAnchor]`:

```swift
public struct MintedAnchor: Equatable, Sendable {
    public let paragraphId: String
    public let body: String
    public let anchorId: String
    /// 0-based line index within the paragraph, used by callers to re-inject
    /// the anchor at the right line.
    public let lineIndex: Int
}

public static func derive(
    ops: [Op], paragraphs: [String: String], docId: String
) -> (tasks: [WriterTask], rebalanceOps: [Op], mintedAnchors: [MintedAnchor])
```

- [ ] **Step 4.4: Update inline-task derivation loop**

For each `MarkdownCheckboxScanner.match` and `FountainBoneyardScanner.matchAll` result:
- If `match.anchorId` is non-nil: use it as the synth-id suffix
- If nil: mint via `TaskAnchorID.mint()`, append a `MintedAnchor` entry, use the minted id as the synth-id suffix

Drop the body-hash dedupe (each anchor is unique by construction).

- [ ] **Step 4.5: Update all callers of `TaskDeriver.derive`**

`Document.rebuildTasksCache`, `Document.lowestPriorityForDoc`, `ProjectStore+Tasks.lowestProjectTaskPriority`, and `ProjectStore+Tasks.rebuildAggregationCache` — all destructure the tuple return. The caller in `Document.rebuildTasksCache` will USE `mintedAnchors` (Task 5); others can ignore via `_`.

- [ ] **Step 4.6: Run tests, iterate to green**
- [ ] **Step 4.7: Commit**

```bash
git add Maugham/OpLog/TaskDeriver.swift MaughamTests/TaskDeriverTests.swift
git commit -m "feat(oplog): TaskDeriver anchor-based synth-id + mint-on-first-encounter"
```

---

## Task 5: `Document` — persist minted anchors + V2 cross-paragraph alignment [opus]

Wires the deriver's `mintedAnchors` back into `paragraphs[paragraphId]` (so the autosave persists them) and implements the V2 alignment algorithm for `setFullText`.

This is the largest task in the milestone. Has two distinct sub-parts:
1. **Persist mints**: `rebuildTasksCache` injects newly-minted anchors into the corresponding paragraph text
2. **V2 alignment**: `setFullText` threads cursor info, runs three-pass alignment, emits archive ops for unpaired-prior, re-injects anchors into the round-tripped paragraph text

**Files:**
- Edit: `Maugham/OpLog/Document.swift`
- Create: `MaughamTests/DocumentTaskAnchorPersistTests.swift`
- Create: `MaughamTests/DocumentTaskAlignmentTests.swift`

- [ ] **Step 5.1: Write failing persistence tests**

```swift
final class DocumentTaskAnchorPersistTests: XCTestCase {
    func test_writingUnanchoredLine_persistsAnchor_onNextDerive() async throws {
        let doc = try await makeDoc(text: "")
        let pid = doc.firstParagraphId  // bootstrap minted one
        doc.setParagraph(id: pid, text: "- [ ] foo")
        // First read triggers derive; minting happens; paragraph is updated.
        _ = doc.tasks(filter: TaskFilter(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases)))
        let para = doc.paragraph(id: pid)!
        XCTAssertTrue(para.contains("<!--t-"),
            "paragraph text should now carry the minted anchor")
        XCTAssertTrue(para.matches(of: /<!--t-[a-z0-9]{6}-->/).count == 1)
    }

    func test_anchorPersists_acrossReload() async throws {
        // Round-trip via disk: type, mint, autosave, reload, verify.
        // ... follows existing DocumentTests fixture pattern with a real
        //     project dir on tmp.
    }
}
```

- [ ] **Step 5.2: Add minting persistence in `rebuildTasksCache`**

After deriver returns:

```swift
let (tasks, rebalanceOps, mintedAnchors) = TaskDeriver.derive(
    ops: _opLogMirror, paragraphs: paragraphs, docId: docId)
_tasksCache = tasks
_tasksCacheValid = true

// Persist minted anchors back to paragraph text. Each MintedAnchor
// names the (paragraphId, lineIndex) we should rewrite to include the
// anchor at end of line.
if !mintedAnchors.isEmpty {
    var pendingParagraphUpdates: [String: String] = [:]
    for mint in mintedAnchors {
        let current = pendingParagraphUpdates[mint.paragraphId]
            ?? paragraphs[mint.paragraphId] ?? ""
        let updated = Self.injectAnchor(
            into: current,
            atLineIndex: mint.lineIndex,
            body: mint.body,
            anchorId: mint.anchorId)
        pendingParagraphUpdates[mint.paragraphId] = updated
    }
    for (pid, newText) in pendingParagraphUpdates {
        paragraphs[pid] = newText
    }
    // Also emit a .taskCreate op per mint so cross-Mac merge sees the
    // creation event with an authoritative timestamp.
    for mint in mintedAnchors {
        let op = Op(/* ...taskCreate keyed by mint.anchorId... */)
        appendTaskOpInternal(op)
    }
    // Schedule autosave so the .md is written with anchors.
    autosaveScheduler.schedule(())
}
```

`Self.injectAnchor` is a static helper: for the given paragraph text, split by `\n`, find the target line, append ` <!--t-XXXXXX-->` (or splice after `]]` for Fountain), rejoin.

- [ ] **Step 5.3: Write failing alignment tests**

The big one. Test cases mirroring spec §2.4:

```swift
final class DocumentTaskAlignmentTests: XCTestCase {

    func test_bodyEditPreservesAnchor() async throws {
        // Stored: "- [ ] foo <!--t-A-->"
        // Display: "- [ ] foo" → writer types "Tighten foo"
        // Result: "- [ ] Tighten foo <!--t-A-->"
    }

    func test_insertNewLineBetweenAnchored_leavesNewUnanchored() async throws {
        // foo, bar anchored. Writer adds baz between.
        // Result: foo (anchor A), baz (no anchor — minted on next derive),
        //         bar (anchor B)
    }

    func test_deleteOneOfThreeDuplicatesInParagraph_archivesOne() async throws {
        // 3x "foo" anchored A, B, C. Writer deletes middle.
        // Result: 2 anchored lines; one .taskArchive op fires.
        //         Which anchor goes to archive is deterministic (LCS-picks-
        //         arbitrary); test asserts one of (A, B, C) is archived
        //         and the other two are present.
    }

    func test_reorderTwoLinesWithinParagraph_preservesBothAnchors() async throws {
        // A, B → B, A. Both anchors must survive.
    }

    func test_crossParagraphCutPaste_anchorFollowsBody() async throws {
        // Para X has "- [ ] foo <!--t-A-->"
        // Para Y has nothing relevant.
        // Cut from X, paste into Y.
        // Cursor: pre on X, post on Y.
        // Result: X loses the line. Y gains "- [ ] foo <!--t-A-->".
        //         No .taskArchive op (the move is detected).
    }

    func test_searchReplaceAcrossDoc_preservesAnchors() async throws {
        // Many lines: "- [ ] tighten X <!--t-?-->"
        // Replace "tighten" with "polish" globally.
        // All anchors preserved; bodies updated.
    }

    func test_deleteWholeParagraphContainingTask_archivesAnchor() async throws {
        // Para Z is "- [ ] foo <!--t-A-->" (sole content).
        // Writer deletes the whole paragraph.
        // Result: .taskArchive op for A fires with userResponse="user-deleted".
    }
}
```

- [ ] **Step 5.4: Implement V2 alignment in `setFullText`**

Thread `preEditCursor` and `postEditCursor` through `setFullText`. Run three-pass alignment per spec §2.4.1:
- Pass 1: per-paragraph body-match + LCS
- Pass 2: cross-paragraph correlation for unpaired-prior + unpaired-new, cursor-biased
- Pass 3: emit `.taskArchive` for unmatched-prior; re-inject anchors into round-tripped paragraph text

Note: this changes `setFullText`'s signature. Existing callers either:
- Pass actual cursor info (EditorHost binding setter — needs work)
- Pass `nil` and accept per-paragraph-only alignment (legacy callers, tests)

```swift
public func setFullText(
    _ text: String,
    preEditCursor: Int? = nil,
    postEditCursor: Int? = nil
)
```

- [ ] **Step 5.5: Update `EditorHost` binding setter to thread cursor**

The binding `Binding(get: { doc.displayText }, set: { doc.setFullText($0) })` doesn't have cursor info. We need to thread it. Options:
- Capture pre-edit cursor in a `@State` on EditorHost, updated by NSTextView delegate
- Or have EditorCoordinator pass the cursor as a side-channel via the existing onTextChange callback

Simpler: add `Document.recordCursorAt(_ offset: Int)` that EditorCoordinator calls on selection change. setFullText reads the last recorded cursor as `preEditCursor`. Post-edit cursor is read from textView after the call.

Implementation detail decided during work; test cases validate the end-to-end behavior either way.

- [ ] **Step 5.6: Iterate to green**

Expect 2–4 rounds. Alignment subtleties around duplicate body lines and cross-paragraph correlation will need careful pass.

- [ ] **Step 5.7: Commit**

```bash
git add Maugham/OpLog/Document.swift MaughamTests/DocumentTaskAnchor* MaughamTests/DocumentTaskAlignment*
git commit -m "feat(oplog): persist task anchors + V2 cursor-bias alignment"
```

---

## Task 6: Editor — distinct todo styling + invisible anchor [sonnet]

Add `Token.Kind.taskBody` (styled distinctly) and `Token.Kind.invisibleAnchor` (transparent). Apply to both prose-mode markdown checkboxes and Fountain todo boneyards.

**Files:**
- Edit: `Maugham/Editor/Token.swift`
- Edit: `Maugham/Editor/Tokenizer/MarkdownTokenizer.swift`
- Edit: `Maugham/Editor/Fountain/FountainTokenizer.swift`
- Edit: `Maugham/Editor/ProseMode.swift`
- Edit: `Maugham/Editor/ScreenplayMode.swift`
- Create: `MaughamTests/EditorTaskAnchorVisibilityTests.swift`

- [ ] **Step 6.1: Write failing styling tests**

```swift
func test_taskBodyToken_emittedForMarkdownCheckbox() {
    let tokens = MarkdownTokenizer().tokenize("- [ ] foo <!--t-9k2x6a-->")
    let kinds = tokens.map(\.kind)
    XCTAssertTrue(kinds.contains { if case .taskBody = $0 { return true } else { return false } })
    XCTAssertTrue(kinds.contains { if case .invisibleAnchor = $0 { return true } else { return false } })
}

func test_taskBodyToken_emittedForFountainBoneyardTodo() {
    let tokens = FountainTokenizer().tokenize("[[todo: foo]]<!--t-9k2x6a-->")
    // ... similar assertions
}
```

- [ ] **Step 6.2: Add `Token.Kind.taskBody` and `Token.Kind.invisibleAnchor`**
- [ ] **Step 6.3: Update tokenizers to emit the new kinds**
- [ ] **Step 6.4: Update ProseMode + ScreenplayMode `attributes(for:)` and `applyTypography`**

For `.taskBody`: distinct color — try `palette.secondary` or a custom hue from the theme. Italic optional.
For `.invisibleAnchor`: `foregroundColor: NSColor.clear` and `kern: -anchor.length` (or full transparent without kerning if NSAttributedString supports that cleanly).

- [ ] **Step 6.5: Commit**

```bash
git add Maugham/Editor/ MaughamTests/EditorTaskAnchorVisibilityTests.swift
git commit -m "feat(editor): distinct task-body styling + invisible task-anchor token"
```

---

## Task 7: Archive lifecycle — text-mutation rules [opus]

Implements the archive action's text mutation per spec §2.7 case-by-case:
- Line-style: delete the line + its terminating `\n`
- Inline `[[todo: …]]`: splice segment with at-most-one adjacent whitespace
- Sole task in paragraph → paragraph collapse
- Auto-archive on detected manual line delete (this is already partially in Task 5's Pass 3; verify here)

**Files:**
- Edit: `Maugham/OpLog/Document.swift`
- Create: `MaughamTests/DocumentArchiveTextMutationTests.swift`

- [ ] **Step 7.1: Write tests for each §2.7 case (2.1 through 2.7 in spec)**
- [ ] **Step 7.2: Extend `archiveTask(id:)` to perform the text mutation**

```swift
public func archiveTask(id: String) {
    // Existing: emit .taskArchive op.
    // New: locate the anchor in paragraph text, splice it out.
    guard let anchorId = Self.extractAnchorId(fromTaskId: id) else { return }
    guard let (paraId, range) = locateAnchor(anchorId: anchorId) else { return }
    let para = paragraphs[paraId] ?? ""
    let mutated = Self.spliceOutAnchoredSegment(in: para, range: range)
    if mutated.isEmpty {
        // Sole task → paragraph collapses
        deleteParagraph(id: paraId)
    } else {
        setParagraph(id: paraId, text: mutated)
    }
    // Now emit .taskArchive op (after the text mutation so the order in
    // the op log is text-change-then-archive — useful for rewind).
    let op = /* .taskArchive */
    appendTaskOpInternal(op)
}
```

- [ ] **Step 7.3: Helpers: `locateAnchor` and `spliceOutAnchoredSegment`**

`locateAnchor(anchorId:)` scans `paragraphs` for `<!--t-XXXXXX-->`, returns `(paragraphId, NSRange)`.

`spliceOutAnchoredSegment` per spec §2.7 algorithm:
- Identify the segment by anchor location:
  - Line-style: walk backward to `\n` or start, forward to `\n` or end, delete the line + one `\n`
  - Inline: walk backward through optional whitespace and `[[(todo|done): …]]` to find the segment start; the anchor is the segment end. Apply whitespace-collapse rule.

- [ ] **Step 7.4: Iterate to green + commit**

---

## Task 8: Bulk "Archive all done" + pane wiring [sonnet]

Pane kebab gets a new menu item. Iterates current scope's done tasks, calls `archiveTask` on each in one batch.

**Files:**
- Edit: `Maugham/Views/TasksPane.swift`
- Edit: `MaughamTests/Integration/TasksPaneIntegrationTests.swift`

- [ ] **Step 8.1: Write failing test**

```swift
func test_archiveAllDone_archivesEveryDoneTaskInScope() async throws {
    let doc = try await makeDocument(initialMd: "")
    let pid = try await firstParagraphId(of: doc)
    doc.setParagraph(id: pid, text: """
    - [x] done one
    - [x] done two
    - [ ] still open
    """)
    let pane = try await makePane(for: doc, registering: doc)
    pane.archiveAllDone(in: .document)
    // Wait briefly for async ops to settle, then assert:
    let remaining = doc.tasks(filter: TaskFilter(
        scope: .document(docId: doc.docId),
        statuses: [.open, .done]))
    XCTAssertEqual(remaining.count, 1)
    XCTAssertEqual(remaining[0].body, "still open")
}
```

- [ ] **Step 8.2: Add `archiveAllDone(in scope:)` to TasksPane**

```swift
internal func archiveAllDone(in scope: TaskFilter.Scope) {
    let toArchive = visibleTasks(/* statuses: [.done] */)
    for task in toArchive {
        guard let doc = ownerDoc(of: task) else { continue }
        doc.archiveTask(id: task.id)
    }
}
```

Wire into the pane's toolbar kebab:

```swift
Menu {
    Button("Archive all done") { archiveAllDone(in: scope) }
} label: { ... }
```

- [ ] **Step 8.3: Commit**

---

## Task 9: Add "manuscript-membrane footnote" to AREA.md + ADR cross-references [sonnet]

Small docs update reflecting the architectural shift.

**Files:**
- Edit: `Maugham/OpLog/AREA.md`
- Edit: `Maugham/Editor/AREA.md`

- [ ] **Step 9.1: Note in `Maugham/OpLog/AREA.md`** that task anchors join paragraph anchors as the "first-class inline identity" pattern; reference ADR 0011.

- [ ] **Step 9.2: Note in `Maugham/Editor/AREA.md`** that `Token.Kind.taskBody` gets distinct styling and `.invisibleAnchor` paints transparent.

- [ ] **Step 9.3: Commit**

---

## Task 10: Manual smoke + tag [user-driven]

User deletes existing test data, builds, creates fresh project, exercises:

- [ ] **Step 10.1: Delete test data**

```bash
rm -rf ~/Documents/"Test Novel"
```

(Or any other test project — only data created since the milestone-tasks branch).

- [ ] **Step 10.2: Build + launch**

```bash
./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
open /Users/denver/Library/Developer/Xcode/DerivedData/Maugham-*/Build/Products/Debug/Maugham.app
```

- [ ] **Step 10.3: Run smoke per spec §6**

The 12 acceptance criteria. Particular attention to:
- Open .md externally; confirm `<!--t-XXXXXX-->` markers
- Type three identical `- [ ] tighten` lines; verify three distinct rows in pane
- Drag-reorder; verify priority survives across restart
- Cut a `- [ ]` line, paste into another paragraph; verify anchor follows
- Rename a body; verify identity preserved
- Click Archive on a Done task; verify line removed from manuscript
- "Archive all done" — bulk
- Verify Fountain `[[todo: …]]` mid-paragraph works the same way

- [ ] **Step 10.4: Tag**

```bash
git tag milestone-task-anchors
git push -u origin claude/friendly-hamilton-60i0v
git push --tags
```

---

## Test count target

Pre-flight: 990 passing.

Expected new tests:
- `TaskAnchorIDTests` (4)
- `RenderFilterTaskAnchorTests` (8)
- `InlineTaskScannerAnchorTests` (4)
- `TaskDeriverTests` extension (5+)
- `DocumentTaskAnchorPersistTests` (3+)
- `DocumentTaskAlignmentTests` (7+)
- `EditorTaskAnchorVisibilityTests` (3+)
- `DocumentArchiveTextMutationTests` (7+)
- `TasksPaneIntegrationTests` extension (1)

Total approximate: ~42 new tests. Target: **1032 passing.**

---

## Tripwires to respect

- **Tripwire #1**: don't subclass NSTextStorage. (Not at risk here; we use the existing tokenizer + paint passes.)
- **Tripwire #3**: no heavy work in synchronous SwiftUI binding setters. The V2 alignment runs inside `setFullText` — Document is `@MainActor`, alignment is pure-CPU on small data, no I/O. OK.
- **Tripwire #6**: no parallel observable state on `EditorHost`. Adding `recordCursorAt` is a method call, not state.
- **Tripwire #7**: `applyExternalText` callers stay at 1 production caller. Verify with grep before + after each task.
- **Tripwire #8**: 4-char alphabet-restricted paragraph IDs in tests. Task anchors are 6-char in same alphabet; use `TaskAnchorID.mint()` in tests where you need a literal, OR use a fixed-value literal matching `[0123456789abcdefghjkmnpqrstvwxyz]{6}`.
- **Tripwire #9**: `Button(.plain)` for clickable rows in sidebar lists. Not at risk in this milestone.
- **Tripwire #11**: no migration for test data. Honored — user deletes.
- **Tripwire #12**: don't add SynthesisSource cases. Task anchors don't change rewind synthesis sources.
- **xcodebuild is ground truth**. SourceKit IDE noise is expected.

---

## Per-task model selection

- Task 1: **sonnet** (mechanical types)
- Task 2: **opus** (strip/restore round-trip property; subtle)
- Task 3: **opus** (regex extension, capture-group correctness)
- Task 4: **opus** (deriver redesign, multiple callers updated)
- Task 5: **opus** (V2 alignment — the hardest task)
- Task 6: **sonnet** (tokenizer + paint additions, mechanical)
- Task 7: **opus** (text-mutation rules, splice algorithm)
- Task 8: **sonnet** (bulk action wiring)
- Task 9: **sonnet** (docs)
- Task 10: **user** (manual smoke)
