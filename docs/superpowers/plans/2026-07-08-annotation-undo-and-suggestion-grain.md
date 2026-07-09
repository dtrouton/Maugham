# Annotation Undo + Suggestion Grain Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix four confirmed annotation/undo bugs: the ⌘Z segfault after external text applies, ⌘Z not undoing an accepted suggestion, accepted annotations stranded invisible after a rewind, and whole-paragraph `suggested_text` spliced into a sub-paragraph quote.

**Architecture:** A new append-only op kind `claudeAcceptRevert` is the inverse of `claudeAccept`'s "two effects, one op" (restores pre-accept text + returns the annotation to `.open`). The Mac registers a window-UndoManager action at accept time; `applyExternalText` clears the (now-unsound) native typing-undo stack on every external buffer replace unless the incoming apply is flagged "undo-coherent" by the Document that produced it. Rewind appends changes-free `claudeAcceptRevert` ops for accepts past the rewind target. Grain salvage lives in shared `SuggestionSplice` (Mac + phone accept paths, tripwire 19).

**Tech Stack:** Swift / SwiftUI / AppKit; XCTest; MaughamCore local SPM package.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-08-annotation-undo-and-suggestion-grain.md`.
- MaughamCore uses Apple system frameworks only; **no AppKit/UndoManager coupling inside MaughamCore** — undo wiring is Mac-target only.
- Op log is append-only; never mutate or delete existing ops.
- Adding an `OpKind` case ⇒ bump `ProjectManifest.currentSchemaVersion` (contract comment in `OpKind.swift:50-57`) — done once, in Task 1.
- New `OpKind` case makes `Deriver.appliesToManuscript` fail to compile until classified — that's the designed gate; classify it in the same commit.
- Tripwires in play: 2/3/6/7 (Editor binding seam — no new observable state on EditorHost, no 4th `applyExternalText` caller, no heavy work in binding setters), 8 (4-char alphabet-restricted paragraph ids in `.md`↔op-log tests — use `ParagraphID.mint()` or literals from `[0-9a-hjkmnp-tv-z]`), 12 (no stringly-typed synthesis sources), 19 (shared logic in MaughamCore).
- Test both schemes: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO` and `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO`. Run `./gen.sh` first if `project.yml` or package sources changed (adding new source files under existing dirs requires `./gen.sh` because xcodegen globs are snapshotted into the generated project).
- Simulator "Busy / failed preflight checks" is a flake — re-run.
- Commit after each task with a conventional message; never commit anything under `Maugham.xcodeproj/`.

---

### Task 1: MaughamCore — `claudeAcceptRevert` op kind, schema bump, Deriver classification

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/OpKind.swift`
- Modify: `Packages/MaughamCore/Sources/MaughamCore/ProjectManifest.swift:29`
- Modify: `Packages/MaughamCore/Sources/MaughamCore/Deriver.swift:185-207`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/AcceptRevertOpTests.swift` (create)

**Interfaces:**
- Produces: `OpKind.claudeAcceptRevert` (raw `"claude_accept_revert"`); `Deriver.appliesToManuscript(.claudeAcceptRevert) == true`. Every later task depends on this case existing.

- [ ] **Step 1: Write the failing test**

Create `Packages/MaughamCore/Tests/MaughamCoreTests/AcceptRevertOpTests.swift`:

```swift
import XCTest
@testable import MaughamCore

final class AcceptRevertOpTests: XCTestCase {

    private func op(
        _ opId: String, kind: OpKind,
        changes: [Op.ParagraphChange] = [],
        sequence: [String]? = nil,
        sourceAnnotationId: String? = nil
    ) -> Op {
        Op(opId: opId, docId: "doc-1", at: Date(timeIntervalSince1970: 1_000),
           device: "test", session: "s1", kind: kind,
           changes: changes, sequence: sequence,
           provenance: Op.Provenance(sourceAnnotationId: sourceAnnotationId))
    }

    func test_rawValue_roundTrips() throws {
        XCTAssertEqual(OpKind.claudeAcceptRevert.rawValue, "claude_accept_revert")
        let data = try JSONEncoder().encode(OpKind.claudeAcceptRevert)
        let back = try JSONDecoder().decode(OpKind.self, from: data)
        XCTAssertEqual(back, .claudeAcceptRevert)
    }

    func test_revertWithChanges_restoresParagraphText() {
        let ops = [
            op("01A", kind: .bootstrap,
               changes: [.init(paragraphId: "abcd", prior: nil, next: "original")],
               sequence: ["abcd"]),
            op("01B", kind: .claudeAccept,
               changes: [.init(paragraphId: "abcd", prior: "original", next: "accepted")],
               sourceAnnotationId: "01A0"),
            op("01C", kind: .claudeAcceptRevert,
               changes: [.init(paragraphId: "abcd", prior: "accepted", next: "original")],
               sourceAnnotationId: "01A0"),
        ]
        let state = Deriver.derive(ops: ops)
        XCTAssertEqual(state.paragraphs["abcd"], "original")
    }

    func test_revertWithEmptyChanges_isManuscriptNoOp() {
        let ops = [
            op("01A", kind: .bootstrap,
               changes: [.init(paragraphId: "abcd", prior: nil, next: "current")],
               sequence: ["abcd"]),
            op("01B", kind: .claudeAcceptRevert, changes: [],
               sourceAnnotationId: "01A0"),
        ]
        let state = Deriver.derive(ops: ops)
        XCTAssertEqual(state.paragraphs["abcd"], "current")
        XCTAssertEqual(state.sequence, ["abcd"])
    }

    func test_schemaVersionBumped() {
        // Contract: adding an OpKind case bumps the manifest schema version
        // (OpKind.swift ADR 0015 comment). claudeAcceptRevert is new in v2.
        XCTAssertGreaterThanOrEqual(ProjectManifest.currentSchemaVersion, 2)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/denver/src/Maugham/Packages/MaughamCore && swift test --filter AcceptRevertOpTests 2>&1 | tail -20`
Expected: FAIL to compile — `type 'OpKind' has no member 'claudeAcceptRevert'`.

- [ ] **Step 3: Add the case, classify it, bump the schema version**

In `OpKind.swift`, directly under `case claudeArchive = "claude_archive"` (line 19), add:

```swift
    // Inverse of claudeAccept's "two effects, one op": restores the pre-accept
    // paragraph text (when `changes` is populated — the Mac ⌘Z path) and
    // returns the annotation's derived status to `.open`. The rewind path
    // appends it with EMPTY changes (status-only reopen: the checkpointRestore
    // already reverted the text; a second text-apply would fight it). The
    // derive loop only folds `op.changes`, so the empty-changes variant is
    // inherently a manuscript no-op despite the `appliesToManuscript` yes.
    case claudeAcceptRevert = "claude_accept_revert"
```

In `ProjectManifest.swift:29` change:

```swift
    public static let currentSchemaVersion = 2
```

In `Deriver.swift`, the exhaustive switch now fails to compile. Add `.claudeAcceptRevert` to the **applies** arm:

```swift
        case .typingBurst, .bootstrap, .externalEdit,
             .checkpointRestore, .claudeAccept, .claudeAcceptRevert:
            return true
```

- [ ] **Step 4: Run the new tests and the package suite**

Run: `cd /Users/denver/src/Maugham/Packages/MaughamCore && swift test 2>&1 | tail -20`
Expected: PASS, including `SchemaEvolutionToleranceTests` and `ProjectManifestCodingTests`. If any existing test pins `currentSchemaVersion == 1` or asserts a fixture manifest round-trip, update the pinned value to 2 (that is the intended contract effect, not a regression).

- [ ] **Step 5: Check for other schema-version-pinned fixtures**

Run: `grep -rn "schemaVersion" /Users/denver/src/Maugham/Packages/MaughamCore/Tests /Users/denver/src/Maugham/MaughamTests | grep -v "\.swift:.*//" | head -30`
Fix any test that hardcodes version 1 as "current". Do NOT touch fixtures that deliberately test old-version tolerance.

- [ ] **Step 6: Commit**

```bash
cd /Users/denver/src/Maugham && git add -A Packages/MaughamCore && git commit -m "feat(core): claudeAcceptRevert op kind — inverse of claudeAccept (schema v2)"
```

---

### Task 2: MaughamCore — AnnotationDeriver derives revert → `.open`

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/AnnotationDeriver.swift:132-154`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/AcceptRevertOpTests.swift` (extend)

**Interfaces:**
- Consumes: `OpKind.claudeAcceptRevert` (Task 1).
- Produces: annotation with latest lifecycle op `.claudeAcceptRevert` derives `status == .open`. Tasks 5 and 7 rely on this.

- [ ] **Step 1: Write the failing tests**

Append to `AcceptRevertOpTests.swift` (inside the class):

```swift
    private func annotationOps() -> [Op] {
        [
            op("01A", kind: .bootstrap,
               changes: [.init(paragraphId: "abcd", prior: nil, next: "original")],
               sequence: ["abcd"]),
            Op(opId: "01B", docId: "doc-1", at: Date(timeIntervalSince1970: 1_001),
               device: "test", session: "s1", kind: .claudeSuggestion,
               changes: [.init(paragraphId: "abcd", prior: "original", next: "better")],
               sequence: nil,
               provenance: Op.Provenance(annotationBody: "tighten this")),
        ]
    }

    func test_acceptThenRevert_derivesOpen() {
        var ops = annotationOps()
        ops.append(op("01C", kind: .claudeAccept,
                      changes: [.init(paragraphId: "abcd", prior: "original", next: "better")],
                      sourceAnnotationId: "01B"))
        ops.append(op("01D", kind: .claudeAcceptRevert,
                      changes: [.init(paragraphId: "abcd", prior: "better", next: "original")],
                      sourceAnnotationId: "01B"))
        let anns = AnnotationDeriver.derive(ops: ops, paragraphs: ["abcd": "original"])
        XCTAssertEqual(anns.count, 1)
        XCTAssertEqual(anns[0].status, .open)
    }

    func test_revertThenReAccept_derivesAccepted() {
        var ops = annotationOps()
        ops.append(op("01C", kind: .claudeAccept,
                      changes: [.init(paragraphId: "abcd", prior: "original", next: "better")],
                      sourceAnnotationId: "01B"))
        ops.append(op("01D", kind: .claudeAcceptRevert,
                      changes: [.init(paragraphId: "abcd", prior: "better", next: "original")],
                      sourceAnnotationId: "01B"))
        ops.append(op("01E", kind: .claudeAccept,
                      changes: [.init(paragraphId: "abcd", prior: "original", next: "better")],
                      sourceAnnotationId: "01B"))
        let anns = AnnotationDeriver.derive(ops: ops, paragraphs: ["abcd": "better"])
        XCTAssertEqual(anns[0].status, .accepted)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `cd /Users/denver/src/Maugham/Packages/MaughamCore && swift test --filter AcceptRevertOpTests 2>&1 | tail -15`
Expected: `test_acceptThenRevert_derivesOpen` FAILS — status stays `.accepted` (revert isn't a lifecycle kind yet, so `01C` remains the latest lifecycle op).

- [ ] **Step 3: Implement**

In `AnnotationDeriver.swift`:

`isLifecycleKind` (line 132):

```swift
    private static func isLifecycleKind(_ kind: OpKind) -> Bool {
        switch kind {
        case .claudeAccept, .claudeReject, .claudeArchive, .claudeAcceptRevert:
            return true
        default: return false
        }
    }
```

`resolution` status switch (line 145):

```swift
        let status: AnnotationStatus = {
            switch lifecycle.kind {
            case .claudeAccept:       return .accepted
            case .claudeReject:       return .rejected
            case .claudeArchive:      return .archived
            case .claudeAcceptRevert: return .open
            default:                  return .open
            }
        }()
```

Note: `resolution` returns `resolvedAt = lifecycle.at` for the revert too — a reopened annotation showing the revert timestamp as `resolvedAt` would be wrong. Change the `return` to nil-out `resolvedAt` (and `userResponse`) for the reopen case:

```swift
        if lifecycle.kind == .claudeAcceptRevert {
            return (.open, creation.provenance?.userResponse, nil)
        }
        return (status, lifecycle.provenance?.userResponse, lifecycle.at)
```

- [ ] **Step 4: Run tests**

Run: `cd /Users/denver/src/Maugham/Packages/MaughamCore && swift test 2>&1 | tail -10`
Expected: PASS (whole package).

- [ ] **Step 5: Commit**

```bash
cd /Users/denver/src/Maugham && git add -A Packages/MaughamCore && git commit -m "feat(core): AnnotationDeriver — claudeAcceptRevert reopens the annotation"
```

---

### Task 3: MaughamCore — SuggestionSplice grain salvage + SuggestionDisplay alignment

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/SuggestionSplice.swift`
- Modify: `Packages/MaughamCore/Sources/MaughamCore/SuggestionDisplay.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/SuggestionSpliceGrainTests.swift` (create)

**Interfaces:**
- Produces: `SuggestionSplice.isWholeParagraphGrain(bare:prefix:suffix:) -> Bool` (internal, `@testable`-visible); `SuggestionSplice.apply` gains the salvage branch (public signature UNCHANGED — both existing callers get it free); `SuggestionDisplay.before(for:)` returns `priorText` for whole-grain span suggestions.

- [ ] **Step 1: Write the failing tests**

Create `Packages/MaughamCore/Tests/MaughamCoreTests/SuggestionSpliceGrainTests.swift`:

```swift
import XCTest
@testable import MaughamCore

final class SuggestionSpliceGrainTests: XCTestCase {

    // Paragraph: prefix "The rain fell hard on the tin roof, " +
    // span "and nobody spoke" + suffix " for a long time."
    private let paragraph = "The rain fell hard on the tin roof, and nobody spoke for a long time."
    private var span: SpanAnchor {
        SpanAnchor(quote: "and nobody spoke",
                   prefix: "tin roof, ", suffix: " for a long",
                   posHint: 37)
    }

    func test_correctGrain_splicesSpanOnly() {
        let out = SuggestionSplice.apply(
            suggestion: "and the silence held", span: span, to: paragraph)
        XCTAssertEqual(out, "The rain fell hard on the tin roof, and the silence held for a long time.")
    }

    func test_wholeParagraphBare_bothContextsPresent_replacesWholeParagraph() {
        // Claude followed the old contract: suggested_text is the WHOLE new
        // paragraph, but a quote was also supplied. Salvage: detect the
        // surrounding context inside the bare text and use it verbatim.
        let bare = "The rain fell hard on the tin roof, and the silence held for a long time."
        let out = SuggestionSplice.apply(suggestion: bare, span: span, to: paragraph)
        XCTAssertEqual(out, bare)
    }

    func test_wholeParagraphBare_spanAtStart_longSuffixMatch_replacesWholeParagraph() {
        let startSpan = SpanAnchor(quote: "The rain fell hard",
                                   prefix: "", suffix: " on the tin", posHint: 0)
        let bare = "Rain hammered down on the tin roof, and nobody spoke for a long time."
        let out = SuggestionSplice.apply(suggestion: bare, span: startSpan, to: paragraph)
        XCTAssertEqual(out, bare)
    }

    func test_shortSuffixCoincidence_doesNotTriggerSalvage() {
        // Span near the end; suffix is just ".". A correct bare replacement
        // ending in "." must NOT be misread as whole-paragraph grain (that
        // would silently DELETE the rest of the paragraph).
        let p = "Hello world. Goodbye."
        let endSpan = SpanAnchor(quote: "Goodbye", prefix: "world. ", suffix: ".", posHint: 13)
        let out = SuggestionSplice.apply(suggestion: "Farewell.", span: endSpan, to: p)
        XCTAssertEqual(out, "Hello world. Farewell..")
    }

    func test_noSpan_bareIsWholeParagraph_unchangedBehavior() {
        XCTAssertEqual(SuggestionSplice.apply(suggestion: "New.", span: nil, to: paragraph), "New.")
    }

    func test_unresolvableSpan_fallsBackToBare_unchangedBehavior() {
        let ghost = SpanAnchor(quote: "zebra quantum", prefix: "", suffix: "", posHint: 0)
        XCTAssertEqual(SuggestionSplice.apply(suggestion: "New.", span: ghost, to: paragraph), "New.")
    }

    func test_display_wholeGrain_beforeIsPriorText() {
        let ann = Annotation(
            id: "01AA", kind: .suggestedChange, paragraphId: "abcd",
            body: "b",
            suggestedText: "The rain fell hard on the tin roof, and the silence held for a long time.",
            priorText: paragraph,
            createdAt: Date(), createdBySession: nil, status: .open,
            userResponse: nil, resolvedAt: nil, isStale: false,
            author: nil, span: span, resolvedSpanRange: nil)
        XCTAssertEqual(SuggestionDisplay.before(for: ann), paragraph)
    }

    func test_display_correctGrain_beforeIsQuote() {
        let ann = Annotation(
            id: "01AB", kind: .suggestedChange, paragraphId: "abcd",
            body: "b", suggestedText: "and the silence held",
            priorText: paragraph,
            createdAt: Date(), createdBySession: nil, status: .open,
            userResponse: nil, resolvedAt: nil, isStale: false,
            author: nil, span: span, resolvedSpanRange: nil)
        XCTAssertEqual(SuggestionDisplay.before(for: ann), "and nobody spoke")
    }
}
```

NOTE: `Annotation`'s memberwise init may have a different parameter order/optionality — check `Annotation.swift:17-52` and adjust the two display tests to compile against the real initializer. If `Annotation` has no public memberwise init visible to tests, build it via `AnnotationDeriver.derive` from ops instead (pattern in Task 2's tests).

- [ ] **Step 2: Run to verify failure**

Run: `cd /Users/denver/src/Maugham/Packages/MaughamCore && swift test --filter SuggestionSpliceGrainTests 2>&1 | tail -20`
Expected: `test_wholeParagraphBare_*` and `test_display_wholeGrain_*` FAIL (splice duplicates the paragraph today); the `unchangedBehavior` tests PASS.

- [ ] **Step 3: Implement**

Replace `SuggestionSplice.apply` body and add the classifier:

```swift
    public static func apply(
        suggestion bare: String, span: SpanAnchor?, to paragraph: String
    ) -> String {
        guard let span,
              let range = SpanAnchorResolver.resolve(anchor: span, in: paragraph)
        else { return bare }
        let chars = Array(paragraph)
        let prefix = String(chars[..<range.lowerBound])
        let suffix = String(chars[range.upperBound...])
        // Grain salvage: a bare text that already carries the paragraph's
        // surrounding context was authored at whole-paragraph grain (the
        // pre-v2 add_suggested_change contract read that way). Splicing it
        // into the span would duplicate the surroundings — use it verbatim.
        if isWholeParagraphGrain(bare: bare, prefix: prefix, suffix: suffix) {
            return bare
        }
        return prefix + bare + suffix
    }

    /// Minimum context length (in characters, whitespace-trimmed) for a
    /// ONE-SIDED match to count as whole-paragraph evidence. Guards against
    /// coincidences like a suffix of "." matching a replacement that ends in
    /// a period — which would silently delete the rest of the paragraph.
    /// A match on BOTH sides is strong evidence at any length.
    static let grainContextMinLength = 12

    /// True when `bare` was authored at whole-paragraph grain: it embeds the
    /// text surrounding the span. Trimmed comparison so a trailing newline or
    /// space difference doesn't defeat detection.
    static func isWholeParagraphGrain(
        bare: String, prefix: String, suffix: String
    ) -> Bool {
        let b = bare.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixMatches = !p.isEmpty && b.hasPrefix(p)
        let suffixMatches = !s.isEmpty && b.hasSuffix(s)
        if prefixMatches && suffixMatches { return true }
        if prefixMatches && p.count >= grainContextMinLength { return true }
        if suffixMatches && s.count >= grainContextMinLength { return true }
        return false
    }
```

In `SuggestionDisplay.swift`, make `before(for:)` use the same decision (resolve the span against `priorText`, the text the suggestion was authored against):

```swift
    public static func before(for annotation: Annotation) -> String? {
        guard annotation.kind == .suggestedChange else { return nil }
        if let span = annotation.span, !span.quote.isEmpty {
            // Mirror SuggestionSplice.apply's grain decision so the previewed
            // diff is exactly what accept will do. Resolve against priorText —
            // the paragraph as it was when the suggestion was authored.
            if let prior = annotation.priorText,
               let bare = annotation.suggestedText,
               let range = SpanAnchorResolver.resolve(anchor: span, in: prior) {
                let chars = Array(prior)
                if SuggestionSplice.isWholeParagraphGrain(
                    bare: bare,
                    prefix: String(chars[..<range.lowerBound]),
                    suffix: String(chars[range.upperBound...])) {
                    return prior
                }
            }
            return span.quote
        }
        return annotation.priorText
    }
```

- [ ] **Step 4: Run the package suite**

Run: `cd /Users/denver/src/Maugham/Packages/MaughamCore && swift test 2>&1 | tail -10`
Expected: PASS. If an existing `SuggestionSplice`/`AnnotationFlow` test now fails, inspect it: a test asserting the OLD duplicate-splice behavior on whole-grain input should be updated to the salvaged expectation; any other failure is a real regression — stop and re-check the classifier.

- [ ] **Step 5: Commit**

```bash
cd /Users/denver/src/Maugham && git add -A Packages/MaughamCore && git commit -m "fix(core): salvage whole-paragraph-grain suggested_text on span suggestions"
```

---

### Task 4: MCP — unambiguous `add_suggested_change` contract text

**Files:**
- Modify: `Maugham/MCP/Tools/AnnotationCreationTools.swift:66-71`
- Tests: run + update any snapshot/description assertions that pin the old text.

**Interfaces:** none new — description string only.

- [ ] **Step 1: Rewrite the description**

Replace the `description` constant of `AddSuggestedChangeTool`:

```swift
    public static let description =
        "Propose a specific replacement. `body` is the editorial justification. " +
        "Two grains — match `suggested_text` to the grain you use: " +
        "(1) omit `quote` → `suggested_text` is the COMPLETE replacement " +
        "paragraph; (2) pass `quote` (an exact phrase from the paragraph) → " +
        "`suggested_text` replaces ONLY that quoted span, so it must contain " +
        "just the span's replacement — never the whole paragraph and never the " +
        "text surrounding the quote. The user accepts (applies the change) or " +
        "rejects (with reasoning)."
```

- [ ] **Step 2: Find and update pinned copies**

Run: `grep -rn "proposed new paragraph" /Users/denver/src/Maugham --include="*.swift" --include="*.md" | grep -v docs/superpowers`
Update every hit: test assertions in `MaughamTests/MCP/` (e.g. `MCPToolsListSmokeTest`, `AnnotationCreationToolsTests`, `MCPProtocolHandlersTests`) and any `Maugham/MCP/AREA.md` or `docs/guide/` text describing the old contract. (Milestone lesson: an MCP surface change breaks ≥3 tools-list tests — find them all now, not via CI.)

- [ ] **Step 3: Build & run the Mac MCP tests**

Run: `cd /Users/denver/src/Maugham && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/MCPToolsListSmokeTest -only-testing:MaughamTests/AnnotationCreationToolsTests -only-testing:MaughamTests/MCPProtocolHandlersTests 2>&1 | tail -15`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
cd /Users/denver/src/Maugham && git add -A && git commit -m "fix(mcp): add_suggested_change description — span grain vs whole-paragraph grain made explicit"
```

---

### Task 5: Mac Document — `revertAcceptedAnnotation` + undo registration in `acceptAnnotation`

**Files:**
- Modify: `Maugham/OpLog/Document+Annotations.swift` (accept + new revert method)
- Modify: `Maugham/OpLog/Document.swift` (one-shot `_undoCoherentApplyPending` flag + consume func — put it next to the other internal state; find the `_pendingSweep` declaration and add adjacent)
- Modify: `Maugham/OpLog/Document+Annotations.swift:6-15` (`isAnnotationOpKind` gains the new case)
- Test: `MaughamTests/AnnotationAcceptUndoTests.swift` (create)

**Interfaces:**
- Consumes: `OpKind.claudeAcceptRevert`, `AnnotationDeriver` reopen (Tasks 1–2).
- Produces:
  - `Document.acceptAnnotation(id:userResponse:undoManager:)` — new optional `undoManager: UndoManager? = nil` trailing parameter (existing 5 call sites compile unchanged).
  - `Document.revertAcceptedAnnotation(id:undoManager:) async throws`
  - `Document.consumeUndoCoherentApplyFlag() -> Bool` — one-shot; Task 6 plumbs it to the editor.

**Undo-ordering contract (read before coding):** `applyExternalText` (Task 6) clears the native undo stack on every external buffer replace UNLESS the Document flagged the apply as undo-coherent. `acceptAnnotation` therefore: (1) clears stale typing actions up front, (2) mutates, (3) registers the revert action, (4) sets the one-shot flag so the editor's subsequent apply preserves the registration. Redo works via nested registration INSIDE the undo closure (synchronously, while `NSUndoManager` is mid-undo, so it lands on the redo stack) — a `Task`-hopped registration would land on the wrong stack.

- [ ] **Step 1: Add the flag + consume func to `Document.swift`**

Find the line `internal var _pendingSweep: SweepReason?` (grep for `_pendingSweep` in `Maugham/OpLog/Document.swift`) and add below it:

```swift
    /// One-shot: the next external buffer apply (`applyExternalText`) was
    /// produced by a document-local mutation that registered its own
    /// UndoManager action (accept/revert of a suggestion) — the editor must
    /// NOT clear the undo stack for that one apply or it wipes the fresh
    /// registration. NOT observable (tripwire 6): consumed via
    /// `consumeUndoCoherentApplyFlag()` from EditorSurface.updateNSView.
    internal var _undoCoherentApplyPending = false

    /// One-shot read+clear. See `_undoCoherentApplyPending`.
    public func consumeUndoCoherentApplyFlag() -> Bool {
        let v = _undoCoherentApplyPending
        _undoCoherentApplyPending = false
        return v
    }
```

- [ ] **Step 2: Extend `isAnnotationOpKind`**

In `Document+Annotations.swift:8-10` add `.claudeAcceptRevert` to the `true` arm:

```swift
        case .claudeComment, .claudeSuggestion, .claudeQuery, .claudeCraftNote,
             .claudeAccept, .claudeReject, .claudeArchive, .claudeAcceptRevert,
             .annotationEdit, .annotationWithdraw:
            return true
```

- [ ] **Step 3: Write the failing test**

Create `MaughamTests/AnnotationAcceptUndoTests.swift`. Model the Document construction on an existing test — open `MaughamTests/AnnotationFlowTests.swift` first and copy its setup pattern (how it builds a `Document` with a temp dir + op store; reuse its helpers verbatim). The test bodies:

```swift
import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class AnnotationAcceptUndoTests: XCTestCase {

    // Use AnnotationFlowTests' Document construction helper pattern here.
    // Paragraph ids must be 4-char alphabet-restricted (tripwire 8):
    // use ParagraphID.mint() when seeding the doc.

    /// Bounded settle: undo closures hop through Task { @MainActor } — drain
    /// until the predicate holds or fail after ~2s.
    private func settle(
        _ predicate: @autoclosure () -> Bool, timeout: TimeInterval = 2
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func test_acceptRegistersUndo_undoRestoresTextAndReopens() async throws {
        let (doc, pid) = try await makeDocWithParagraph("The night was very dark and stormy.")
        let annId = try await doc.addAnnotation(
            kind: .suggestedChange, paragraphId: pid,
            body: "stronger", suggestedText: "pitch-black",
            span: SpanAnchor(quote: "very dark", prefix: "was ", suffix: " and", posHint: 14))
        let um = UndoManager()
        um.groupsByEvent = false   // deterministic grouping in tests

        um.beginUndoGrouping()
        try await doc.acceptAnnotation(id: annId, undoManager: um)
        um.endUndoGrouping()

        XCTAssertEqual(doc.paragraph(id: pid), "The night was pitch-black and stormy.")
        XCTAssertTrue(doc.consumeUndoCoherentApplyFlag(), "accept must flag the next external apply as undo-coherent")
        XCTAssertTrue(um.canUndo)

        um.undo()
        await settle(doc.paragraph(id: pid) == "The night was very dark and stormy.")
        XCTAssertEqual(doc.paragraph(id: pid), "The night was very dark and stormy.")
        let ann = doc.annotations().first { $0.id == annId }
        XCTAssertEqual(ann?.status, .open)
    }

    func test_undoThenRedo_reAccepts() async throws {
        let (doc, pid) = try await makeDocWithParagraph("The night was very dark and stormy.")
        let annId = try await doc.addAnnotation(
            kind: .suggestedChange, paragraphId: pid,
            body: "stronger", suggestedText: "pitch-black",
            span: SpanAnchor(quote: "very dark", prefix: "was ", suffix: " and", posHint: 14))
        let um = UndoManager()
        um.groupsByEvent = false

        um.beginUndoGrouping()
        try await doc.acceptAnnotation(id: annId, undoManager: um)
        um.endUndoGrouping()

        um.undo()
        await settle(doc.annotations().first { $0.id == annId }?.status == .open)
        XCTAssertTrue(um.canRedo, "revert must nest a re-accept registration onto the redo stack")

        um.redo()
        await settle(doc.paragraph(id: pid) == "The night was pitch-black and stormy.")
        XCTAssertEqual(doc.paragraph(id: pid), "The night was pitch-black and stormy.")
        XCTAssertEqual(doc.annotations().first { $0.id == annId }?.status, .accepted)
    }

    func test_revertOnNonAcceptedAnnotation_isLoudNoOp() async throws {
        let (doc, pid) = try await makeDocWithParagraph("Some text here.")
        let annId = try await doc.addAnnotation(
            kind: .suggestedChange, paragraphId: pid,
            body: "b", suggestedText: "Other text here.")
        let textBefore = doc.paragraph(id: pid)
        try await doc.revertAcceptedAnnotation(id: annId, undoManager: nil)  // never accepted
        XCTAssertEqual(doc.paragraph(id: pid), textBefore)
        XCTAssertEqual(doc.annotations().first { $0.id == annId }?.status, .open)
    }

    func test_acceptWithoutUndoManager_setsNoFlag() async throws {
        let (doc, pid) = try await makeDocWithParagraph("Some text here.")
        let annId = try await doc.addAnnotation(
            kind: .suggestedChange, paragraphId: pid,
            body: "b", suggestedText: "Other text here.")
        try await doc.acceptAnnotation(id: annId)
        XCTAssertFalse(doc.consumeUndoCoherentApplyFlag())
    }
}
```

Wait on `um.undo()` semantics with `groupsByEvent = false`: `undo()` undoes the top-level group — the explicit group works. If the existing suite already has an UndoManager test pattern, follow it.

- [ ] **Step 4: Run to verify failure**

Run: `cd /Users/denver/src/Maugham && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/AnnotationAcceptUndoTests 2>&1 | tail -15`
Expected: FAIL to compile (`acceptAnnotation` has no `undoManager:` parameter; `revertAcceptedAnnotation` undefined).

- [ ] **Step 5: Implement in `Document+Annotations.swift`**

Change `acceptAnnotation`'s signature and add the undo block. Full replacement for the method's signature line and the tail after the existing `if kind == .suggestedChange` block (the op-append middle stays as-is):

```swift
    public func acceptAnnotation(
        id: String,
        userResponse: String? = nil,
        undoManager: UndoManager? = nil
    ) async throws {
        guard let creation = _opLogMirror.first(where: { $0.opId == id }),
              let kind = AnnotationKind.fromOpKind(creation.kind) else {
            return  // unknown id or non-annotation op — no-op
        }

        // ⌘Z contract: the buffer replace that follows this accept invalidates
        // every native typing-undo action (they reference the pre-replace text
        // storage — the ⌘Z segfault class). Clear them NOW, then register the
        // revert action, then flag the editor's next external apply as
        // undo-coherent so it doesn't wipe the fresh registration. Skipped
        // mid-undo/redo: NSUndoManager forbids removeAllActions during
        // undo/redo, and the stacks are coherent in that flow anyway.
        if kind == .suggestedChange, let um = undoManager,
           !um.isUndoing, !um.isRedoing {
            um.removeAllActions()
        }
```

…existing `changes` computation and op append stay untouched… then extend the mutation tail:

```swift
        if kind == .suggestedChange, let change = changes.first {
            paragraphs[change.paragraphId] = change.next
            pending.recordChange(
                paragraphId: change.paragraphId,
                prior: change.prior, next: change.next)
            burstScheduler.recordActivity()
            autosaveScheduler.schedule(())

            if let um = undoManager {
                um.registerUndo(withTarget: self) { doc in
                    // Nested registration runs SYNCHRONOUSLY inside undo, so
                    // NSUndoManager routes it to the REDO stack. The actual
                    // revert hops to a Task (op append is async).
                    um.registerUndo(withTarget: doc) { d2 in
                        Task { @MainActor in
                            try? await d2.acceptAnnotation(id: id, undoManager: um)
                        }
                    }
                    Task { @MainActor in
                        try? await doc.revertAcceptedAnnotation(id: id, undoManager: nil)
                    }
                }
                um.setActionName("Accept Suggestion")
                _undoCoherentApplyPending = true
            }

            recomputeDisplayText()
        }

        invalidateAnnotationsCache()
        invalidateTasksCache()   // accept may have changed paragraph text → inline tasks
    }
```

(Note the flag is set BEFORE `recomputeDisplayText()` — the recompute is what schedules the SwiftUI pass that consumes it.)

Add the revert method after `acceptAnnotation`:

```swift
    /// Inverse of an accepted suggestion — the ⌘Z path. Appends a
    /// `claudeAcceptRevert` op carrying the restore (prior = post-accept text,
    /// next = pre-accept text) and returns the annotation to `.open`
    /// (AnnotationDeriver). Append-only: the accept op is never touched.
    ///
    /// Loud no-op (log, no throw) when the annotation isn't currently
    /// `.accepted` or its paragraph no longer exists — an undo action can
    /// outlive the state it captured (e.g. a rewind in between); never crash.
    public func revertAcceptedAnnotation(
        id: String, undoManager: UndoManager? = nil
    ) async throws {
        _ = undoManager  // redo is registered by the undo closure, not here
        guard let creation = _opLogMirror.first(where: { $0.opId == id }),
              AnnotationKind.fromOpKind(creation.kind) == .suggestedChange else {
            documentLog.error("revertAcceptedAnnotation: \(id, privacy: .public) is not a suggestion creation op — ignoring")
            return
        }
        let current = annotations().first { $0.id == id }
        guard current?.status == .accepted else {
            documentLog.error("revertAcceptedAnnotation: \(id, privacy: .public) is not accepted (\(String(describing: current?.status), privacy: .public)) — ignoring")
            return
        }
        // Latest accept op for this annotation carries the definitive
        // prior (pre-accept) / next (post-accept) pair.
        guard let acceptOp = _opLogMirror.last(where: {
                  $0.kind == .claudeAccept
                      && $0.provenance?.sourceAnnotationId == id
              }),
              let acceptChange = acceptOp.changes.first else {
            documentLog.error("revertAcceptedAnnotation: no claudeAccept op with changes for \(id, privacy: .public) — ignoring")
            return
        }
        let pid = acceptChange.paragraphId
        guard sequence.contains(pid) else {
            documentLog.error("revertAcceptedAnnotation: paragraph \(pid, privacy: .public) no longer exists — ignoring")
            return
        }
        let currentText = paragraphs[pid] ?? ""
        let restored = acceptChange.prior ?? ""
        let change = Op.ParagraphChange(
            paragraphId: pid, prior: currentText, next: restored)

        let op = Op(
            opId: ULID.generate(),
            docId: docId, at: Date(),
            device: device, session: session,
            kind: .claudeAcceptRevert,
            changes: [change],
            sequence: nil,
            provenance: Op.Provenance(
                sessionId: session,
                sourceAnnotationId: id))
        try await opStore.append(op)
        _opLogMirror.append(op)
        _hasAnyAnnotationOps = true

        paragraphs[pid] = restored
        pending.recordChange(paragraphId: pid, prior: currentText, next: restored)
        burstScheduler.recordActivity()
        autosaveScheduler.schedule(())
        _undoCoherentApplyPending = true
        recomputeDisplayText()

        invalidateAnnotationsCache()
        invalidateTasksCache()
    }
```

Check the logger name: grep `Maugham/OpLog/Document.swift` for `Logger(` — if the OpLog area's logger isn't named `documentLog` or isn't visible in this file, reuse whatever this file already uses (or add `os.Logger` matching area convention). Don't invent a new logging pattern.

- [ ] **Step 6: Run the tests**

Run: `cd /Users/denver/src/Maugham && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/AnnotationAcceptUndoTests 2>&1 | tail -15`
Expected: PASS (the `settle` helper absorbs the Task hops).

- [ ] **Step 7: Run the annotation-adjacent suites**

Run: `cd /Users/denver/src/Maugham && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/AnnotationFlowTests -only-testing:MaughamTests/DeriverAcceptContractTests -only-testing:MaughamTests/AnnotationKindContractTests 2>&1 | tail -10`
Expected: PASS. `AnnotationKindContractTests` / `DeriverAcceptContractTests` may enumerate annotation op kinds — extend them with `.claudeAcceptRevert` if they fail on exhaustiveness.

- [ ] **Step 8: Commit**

```bash
cd /Users/denver/src/Maugham && git add -A && git commit -m "feat(oplog): revertAcceptedAnnotation + undo registration on accept (claudeAcceptRevert)"
```

---

### Task 6: Editor — clear stale undo stack on external apply; plumb the undo-coherent flag; pass UndoManager from UI

**Files:**
- Modify: `Maugham/Editor/EditorCoordinator.swift:609-638` (`applyExternalText`)
- Modify: `Maugham/Editor/EditorSurface.swift` (new closure property + `updateNSView` call site at ~line 276)
- Modify: `Maugham/Views/EditorHost.swift` (env undoManager; wire closure; pass to accept handlers at :190, :202)
- Modify: `Maugham/Views/AnnotationsPane.swift` (env undoManager; pass at :149, :162, :247)
- Test: `MaughamTests/Editor/` — extend the harness (find the exact file: `grep -rln "applyExternalTextCallCount" MaughamTests`)

**Interfaces:**
- Consumes: `Document.consumeUndoCoherentApplyFlag()` (Task 5).
- Produces: `EditorCoordinator.applyExternalText(_:preserveUndoStack:)` (default `false`, so existing callers/tests compile); `EditorCoordinator.undoManagerOverrideForTesting: UndoManager?`; `EditorSurface.consumeUndoCoherentApplyFlag: (() -> Bool)?` closure property.

**READ `Maugham/Editor/AREA.md` BEFORE TOUCHING ANYTHING.** Tripwire 7: this task adds ZERO new callers of `applyExternalText` — only a parameter.

- [ ] **Step 1: Write the failing harness test**

Locate the harness: `grep -rln "applyExternalTextCallCount\|EditorIntegrationHarness" /Users/denver/src/Maugham/MaughamTests`. Add to that file (or a sibling `EditorUndoStackClearTests.swift` in the same directory using the same harness setup):

```swift
    @MainActor
    func test_applyExternalText_clearsStaleUndoStack() {
        // (build coordinator + textView exactly as the neighboring harness
        //  tests do)
        let um = UndoManager()
        coordinator.undoManagerOverrideForTesting = um
        um.registerUndo(withTarget: self) { _ in }   // simulate stale typing action
        XCTAssertTrue(um.canUndo)
        coordinator.applyExternalText("replaced buffer contents")
        XCTAssertFalse(um.canUndo, "external replace must drop the stale native undo stack (⌘Z segfault class)")
    }

    @MainActor
    func test_applyExternalText_preserveUndoStack_keepsRegistrations() {
        let um = UndoManager()
        coordinator.undoManagerOverrideForTesting = um
        um.registerUndo(withTarget: self) { _ in }   // simulate accept-revert registration
        coordinator.applyExternalText("replaced buffer contents", preserveUndoStack: true)
        XCTAssertTrue(um.canUndo, "undo-coherent apply must not wipe the accept-undo registration")
    }

    @MainActor
    func test_applyExternalText_noBufferChange_touchesNothing() {
        let um = UndoManager()
        coordinator.undoManagerOverrideForTesting = um
        um.registerUndo(withTarget: self) { _ in }
        coordinator.applyExternalText(textView.string)  // same text — early return
        XCTAssertTrue(um.canUndo)
    }
```

- [ ] **Step 2: Run to verify failure**

Run the harness test class via `-only-testing:` (exact class name from Step 1's grep).
Expected: FAIL to compile (`undoManagerOverrideForTesting` / `preserveUndoStack` unknown).

- [ ] **Step 3: Implement in `EditorCoordinator.swift`**

Near the other test seams (search for `applyExternalTextCallCount` declaration, add adjacent):

```swift
    /// Test seam: NSTextView.undoManager is nil without a window; harness
    /// tests inject a manager here. Production always resolves through the
    /// text view (the window's undo manager — the one ⌘Z reaches).
    var undoManagerOverrideForTesting: UndoManager?
```

Change `applyExternalText` (line 610):

```swift
    func applyExternalText(_ text: String, preserveUndoStack: Bool = false) {
```

and insert after the `guard let textView, textView.string != text else { return }` (line 625), before `isApplyingExternalUpdate = true`:

```swift
        // Replacing the buffer out from under NSTextView invalidates every
        // native typing-undo action (they capture text-storage state; popping
        // one afterwards is the ⌘Z EXC_BAD_ACCESS in _NSUndoStack
        // popAndInvoke — crash 2026-07-08). Drop them — unless this apply was
        // flagged undo-coherent by the Document (accept/revert registered its
        // own action and already cleared the stale ones; wiping here would
        // kill that registration).
        if !preserveUndoStack {
            (undoManagerOverrideForTesting ?? textView.undoManager)?
                .removeAllActions()
        }
```

- [ ] **Step 4: Plumb the flag through `EditorSurface`**

Add to `EditorSurface`'s properties (next to the other closure properties, e.g. near `createAnnotationHandler`):

```swift
    /// One-shot pull from the Document: was the pending displayText change
    /// produced by an undo-registered mutation (accept/revert)? Consumed ONLY
    /// when a buffer replace actually happens. See tripwire discussion in
    /// EditorCoordinator.applyExternalText.
    var consumeUndoCoherentApplyFlag: (() -> Bool)? = nil
```

In `updateNSView` change the apply site (~line 276):

```swift
        if textView.string != text {
            context.coordinator.applyExternalText(
                text,
                preserveUndoStack: consumeUndoCoherentApplyFlag?() ?? false)
        }
```

- [ ] **Step 5: Wire `EditorHost` and `AnnotationsPane`**

`EditorHost.swift`:
- Add `@Environment(\.undoManager) private var undoManager` to the view struct (top, with the other `@Environment`s).
- In the `EditorSurface(...)` initializer call, pass `consumeUndoCoherentApplyFlag: { doc.consumeUndoCoherentApplyFlag() }` (match the argument-label position the initializer ends up with).
- Line 190: `try? await doc.acceptAnnotation(id: id, undoManager: undoManager)`
- Line 202: `try? await doc.acceptAnnotation(id: id, userResponse: reply, undoManager: undoManager)`

`AnnotationsPane.swift`:
- Add `@Environment(\.undoManager) private var undoManager`.
- All three accept sites gain `undoManager: undoManager` (`:149` keeps its `userResponse:` argument; `:162` and `:247` are plain accepts).

Closure-capture note: `@Environment` values can't be captured by escaping closures built in the initializer list in some SwiftUI versions — if the compiler objects, snapshot it first (`let um = undoManager`) inside `body` before constructing `EditorSurface`.

- [ ] **Step 6: Run the editor + annotation suites, then both full schemes**

```bash
cd /Users/denver/src/Maugham && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```
Expected: PASS, including `EditorIntegrationHarnessTests` (its existing `applyExternalText` tests compile via the default parameter) and `BootstrapWiringTests`.

- [ ] **Step 7: Commit**

```bash
cd /Users/denver/src/Maugham && git add -A && git commit -m "fix(editor): clear stale native undo stack on external apply; ⌘Z undo of accepted suggestions"
```

---

### Task 7: Rewind — reopen accepts past the rewind target

**Files:**
- Modify: `Maugham/OpLog/Document+Rewind.swift` (after step 7's sweep, before building the result)
- Modify: `Maugham/OpLog/RewindRestoreResult.swift` (new field)
- Modify: the rewind modal's toast — find with `grep -rn "archivedAnnotationOpIds" Maugham/ --include="*.swift"` (the `RewindWindow`/modal caller renders the impact summary)
- Test: `MaughamTests/RewindReopensAcceptsTests.swift` (create)

**Interfaces:**
- Consumes: `OpKind.claudeAcceptRevert` (empty-changes variant), AnnotationDeriver reopen (Task 2).
- Produces: `RewindRestoreResult.reopenedAnnotationOpIds: [String]` (creation-op ids reopened by this restore).

- [ ] **Step 1: Write the failing test**

Create `MaughamTests/RewindReopensAcceptsTests.swift` (Document construction pattern from `AnnotationFlowTests` again; there are existing rewind tests — `grep -rln "restoreToOp" MaughamTests` — reuse their fixture style):

```swift
import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class RewindReopensAcceptsTests: XCTestCase {

    func test_rewindPastAccept_reopensAnnotation_andRevertsText() async throws {
        let (doc, pid) = try await makeDocWithParagraph("Original sentence here.")
        // Capture the last op id BEFORE the suggestion+accept — the rewind target.
        let targetOpId = doc._opLogMirrorForTesting.last!.opId

        let annId = try await doc.addAnnotation(
            kind: .suggestedChange, paragraphId: pid,
            body: "b", suggestedText: "Improved sentence here.")
        try await doc.acceptAnnotation(id: annId)
        XCTAssertEqual(doc.paragraph(id: pid), "Improved sentence here.")
        XCTAssertEqual(doc.annotations().first { $0.id == annId }?.status, .accepted)

        let result = try await doc.restoreToOp(opId: targetOpId)

        XCTAssertEqual(doc.paragraph(id: pid), "Original sentence here.")
        XCTAssertEqual(doc.annotations().first { $0.id == annId }?.status, .open,
            "an accept whose effect was rewound away must not stay 'accepted'")
        XCTAssertEqual(result.reopenedAnnotationOpIds, [annId])
    }

    func test_rewindAfterAccept_leavesAcceptAlone() async throws {
        let (doc, pid) = try await makeDocWithParagraph("Original sentence here.")
        let annId = try await doc.addAnnotation(
            kind: .suggestedChange, paragraphId: pid,
            body: "b", suggestedText: "Improved sentence here.")
        try await doc.acceptAnnotation(id: annId)
        // Type something AFTER the accept, then rewind only past the typing.
        let acceptOpId = doc._opLogMirrorForTesting.last!.opId
        doc.setParagraph(id: pid, text: "Improved sentence here. And more.")
        try await doc.flushBurstNow()

        let result = try await doc.restoreToOp(opId: acceptOpId)

        XCTAssertEqual(doc.paragraph(id: pid), "Improved sentence here.")
        XCTAssertEqual(doc.annotations().first { $0.id == annId }?.status, .accepted)
        XCTAssertEqual(result.reopenedAnnotationOpIds, [])
    }
}
```

If `_opLogMirror` has no test accessor, check how existing rewind tests obtain op ids (they may return them from helpers or use `doc.opLog`-style accessors) and use that instead of inventing `_opLogMirrorForTesting`; only add a test seam if none exists (name it to match existing seam conventions).

- [ ] **Step 2: Run to verify failure**

Run: `-only-testing:MaughamTests/RewindReopensAcceptsTests`
Expected: first test FAILS on the `.open` assertion (status stays `.accepted`) and on the missing `reopenedAnnotationOpIds` field (compile error first — add the field as part of implementation, Step 3).

- [ ] **Step 3: Implement**

`RewindRestoreResult.swift` — add the field + init param (keep Equatable/Sendable):

```swift
    /// Creation-op ids of accepted suggestions whose `claudeAccept` lay past
    /// the rewind target: the restore reverted their applied text, so the
    /// restore also appended a changes-free `claudeAcceptRevert` per id to
    /// return them to `.open` (a stranded "accepted" row whose change no
    /// longer exists would otherwise hide in the resolved filter).
    public let reopenedAnnotationOpIds: [String]
```

(add `reopenedAnnotationOpIds: [String],` to the init parameter list after `archivedAnnotationOpIds` and assign it; update BOTH early-return constructions in `Document+Rewind.swift` with `reopenedAnnotationOpIds: []`.)

`Document+Rewind.swift` — insert between the sweep flush (line ~176 block) and the final `return`:

```swift
        // 8. Reopen accepts stranded past the rewind target. The restore
        //    derived from the log PREFIX, so text applied by any claudeAccept
        //    AFTER `targetOpId` is already reverted — but the accept op itself
        //    survives (append-only), so the annotation would still derive
        //    `.accepted` while its change no longer exists. Append a
        //    changes-free claudeAcceptRevert (status-only: the restore op
        //    already carries the text) for each annotation whose LATEST
        //    lifecycle op is a post-target accept of a pre/at-target creation.
        var reopenedIds: [String] = []
        var latestLifecycleBySource: [String: Op] = [:]
        for op in currentOps
        where [.claudeAccept, .claudeReject, .claudeArchive,
               .claudeAcceptRevert].contains(op.kind) {
            guard let src = op.provenance?.sourceAnnotationId else { continue }
            if let prior = latestLifecycleBySource[src], prior.opId > op.opId { continue }
            latestLifecycleBySource[src] = op
        }
        for (src, lifecycleOp) in latestLifecycleBySource.sorted(by: { $0.key < $1.key }) {
            guard lifecycleOp.kind == .claudeAccept,
                  lifecycleOp.opId > targetOpId,
                  src <= targetOpId,                     // creation at/before target (ULID order)
                  !lifecycleOp.changes.isEmpty           // suggestion accepts only
            else { continue }
            let reopenOp = Op(
                opId: ULID.generate(),
                docId: docId, at: Date(),
                device: device, session: session,
                kind: .claudeAcceptRevert,
                changes: [],
                sequence: nil,
                provenance: Op.Provenance(
                    sessionId: session,
                    synthesisSource: .rewind,
                    sourceAnnotationId: src))
            try await opStore.append(reopenOp)
            _opLogMirror.append(reopenOp)
            reopenedIds.append(src)
        }
        if !reopenedIds.isEmpty {
            _hasAnyAnnotationOps = true
            invalidateAnnotationsCache()
        }
```

and extend the final `return` (plus the two early-return sites) with `reopenedAnnotationOpIds: reopenedIds` (early returns: `[]`).

Check `Op.Provenance`'s init exposes `synthesisSource` in that label position — mirror the exact init usage from the pure-deletion branch at `Document+Rewind.swift:76-78`.

- [ ] **Step 4: Update the rewind modal's impact summary**

Find the caller: `grep -rn "archivedAnnotationOpIds" /Users/denver/src/Maugham/Maugham --include="*.swift"`. Where the toast says "N annotations auto-archived", extend: when `reopenedAnnotationOpIds` is non-empty, append `", M suggestions reopened"` (pluralize the same way the neighboring copy does). Keep it one line; match the existing string-building style.

- [ ] **Step 5: Run tests**

Run: `-only-testing:MaughamTests/RewindReopensAcceptsTests` plus the existing rewind suite (grep from Step 1) and fix any `RewindRestoreResult` construction in older tests (add `reopenedAnnotationOpIds: []`).
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd /Users/denver/src/Maugham && git add -A && git commit -m "fix(rewind): reopen suggestion accepts stranded past the rewind target"
```

---

### Task 8: Cross-surface verification — phone scheme, tripwire greps, full suites

**Files:**
- Test: `MaughamPhone` tests may enumerate op kinds — run and fix exhaustiveness fallout only.
- Possibly modify: `docs/superpowers/notes/cross-surface-contracts.md` (registry — add `claudeAcceptRevert` to the accept-lifecycle contract row if one exists).

- [ ] **Step 1: Regenerate and run BOTH schemes end-to-end**

```bash
cd /Users/denver/src/Maugham && ./gen.sh && \
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5 && \
xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: `** TEST SUCCEEDED **` twice. (Simulator "Busy" = flake; re-run.) `TripwireGrepTests` and `TripwirePhoneGrepTest` must pass untouched.

- [ ] **Step 2: Phone round-trip test for the new op kind**

Find the phone deriver tests: `grep -rln "AnnotationDeriver\|Deriver.derive" /Users/denver/src/Maugham/MaughamPhoneTests 2>/dev/null || ls /Users/denver/src/Maugham/MaughamPhoneTests 2>/dev/null | head`. Add one test in the phone test target mirroring Task 2's `test_acceptThenRevert_derivesOpen` but decoding the ops from JSONL bytes (the cross-device path): encode the ops with `JSONLAppendStore<Op>.dateEncoding` + `.sortedKeys` exactly as `AnnotationWriter.encode` does, decode via the store, then assert `Deriver.derive` restores the text and `AnnotationDeriver` yields `.open`. This is the "Mac writes revert op → phone reads it" contract test (tripwire 19's real safety net is round-trip tests, not greps).

- [ ] **Step 3: Update the cross-surface contract registry**

Open `docs/superpowers/notes/cross-surface-contracts.md`; if it has a row for the accept/lifecycle op contract (it should — `AnnotationWriter` cites spec §3.9), note that `claude_accept_revert` joined the lifecycle set in schema v2, derived by shared `AnnotationDeriver`/`Deriver` (no phone-side writer — the phone never authors reverts; ⌘Z is Mac-only).

- [ ] **Step 4: Commit**

```bash
cd /Users/denver/src/Maugham && git add -A && git commit -m "test(phone): claudeAcceptRevert round-trip; cross-surface registry note"
```

---

### Task 9: Docs — help topics describe the shipped behavior

**Files:**
- Modify: whichever `docs/guide/` topics describe suggestions/accepting/undo — find with `grep -rln "suggested\|Accept" /Users/denver/src/Maugham/docs/guide/`

- [ ] **Step 1: Update guide copy**

Rules: help describes what SHIPS. Add/adjust, in the existing topic voice:
- Accepting a suggestion can be undone with ⌘Z (Edit ▸ Undo Accept Suggestion); the suggestion returns to Open and the paragraph text is restored. Redo re-applies it.
- Rewinding to a point before an accepted suggestion re-opens that suggestion (its change was rewound away).
- (If the guide documents `add_suggested_change` for MCP users: the quote/span grain rule from Task 4.)
Do NOT create a new topic file unless no suggestions/annotations topic exists; `HelpTopicIndex` serves these files to Help ▸ Maugham Help AND the `get_help` MCP tool — one docs source.

- [ ] **Step 2: Run the help/docs tests**

`grep -rln "HelpTopicIndex" /Users/denver/src/Maugham/MaughamTests` → run that suite (topic index/anchor tests catch malformed guide edits).
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
cd /Users/denver/src/Maugham && git add -A && git commit -m "docs(guide): undo of accepted suggestions, rewind reopen, suggestion grain"
```

---

## Completion

- Full Mac + phone suites green (Task 8 Step 1 command).
- Manual smoke (user runs): open a project → Claude adds a span suggestion via `mcp__maugham_test__add_suggested_change` with a whole-paragraph `suggested_text` + quote → accept → paragraph must NOT duplicate; ⌘Z → text restored, suggestion back in Open; ⌘Z repeatedly after typing + accepting → no crash; History rewind to before an accept → suggestion reopens.
- This milestone bumps the project schema to v2: Mac and phone releases ship together (older builds refuse newer manifests by design, ADR 0015).
- Use `superpowers:finishing-a-development-branch` when done.
