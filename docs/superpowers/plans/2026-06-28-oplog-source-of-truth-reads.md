# Op-log-source-of-truth manuscript reads — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every manuscript-content read derive from the op log (never the `.md`), via one shared `DerivedManuscript` primitive, and add a tripwire so it can't recur (ADR 0018).

**Architecture:** New `DerivedManuscript` (MaughamCore) = `OpLogStore.loadSyncMerged` → `Deriver.deriveWithSequenceFallback` → `Materializer.materialize`, fully synchronous, no `Document` actor. Route the 9 audited violations through it (open doc → live `Document`; closed doc → `DerivedManuscript`). Tripwire grep test enforces it.

**Tech Stack:** Swift, MaughamCore (Apple frameworks only). Mac target + MaughamCore. No phone changes.

## Global Constraints

- **The op log is the sole source of truth for manuscripts; the `.md`/`.fountain` is a derived OUTPUT, never an INPUT.** No `String(contentsOf:)`/`Data(contentsOf:)` of a manuscript doc path as a source of truth — derive from the op log.
- **Open doc → live `Document`** (`doc.materialize()` / `doc.displayText` / `doc.paragraphs`); **closed doc → `DerivedManuscript`**. Keep the existing open-doc branches; only change the closed-doc/file-read branches.
- **Legacy logs: op-log-only.** Use `deriveWithSequenceFallback` (synthesises order from ops); NEVER read the `.md` to recover order. Approximate ancient ordering is accepted.
- **Do NOT change** `Document.load`/`Document+Load.swift` (its `.md` reads are the sanctioned reconciler/echo-guard), research-file reads, or manifest/config reads.
- `docId == StructureItem.id` for manuscript docs (the op-log filename key).
- Confirmed primitive signatures: `OpLogStore.loadSyncMerged(forDocId: String, in: URL) -> [Op]` (nonisolated static, sync); `Deriver.deriveWithSequenceFallback(ops: [Op]) -> Deriver.DerivedState` (`.paragraphs: [String:String]`, `.sequence: [String]`); `Materializer.materialize(paragraphs:sequence:) -> String` (emits `<!-- ¶id -->` anchored text).
- **Build/test:** `./gen.sh` after adding files to a target; `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`. MaughamCore-only tests: `cd Packages/MaughamCore && swift test --filter <Name>`. SourceKit "No such module 'MaughamCore'" is known noise — trust `xcodebuild`.
- Commit after each task. Branch: `feat/oplog-source-of-truth-reads` (spec + ADR already committed).

---

### Task 1: `DerivedManuscript` primitive + tests

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/DerivedManuscript.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/DerivedManuscriptTests.swift`

**Interfaces — Produces:**
- `DerivedManuscript.materialize(forDocId: String, in: URL) -> String`
- `DerivedManuscript.derivedState(forDocId: String, in: URL) -> Deriver.DerivedState`

- [ ] **Step 1: Write the failing test**

Create `Packages/MaughamCore/Tests/MaughamCoreTests/DerivedManuscriptTests.swift`:

```swift
import XCTest
@testable import MaughamCore

final class DerivedManuscriptTests: XCTestCase {

    /// Write an op-log JSONL file for `docId` under a temp project; return the URL.
    private func makeProject(docId: String, ops: [Op]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dm-\(UUID().uuidString)")
        let opsDir = root.appendingPathComponent(".maugham/ops")
        try FileManager.default.createDirectory(at: opsDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        let lines = try ops.map { String(data: try enc.encode($0), encoding: .utf8)! }
        try lines.joined(separator: "\n").appending("\n")
            .write(to: opsDir.appendingPathComponent("\(docId).jsonl"), atomically: true, encoding: .utf8)
        return root
    }

    private func op(_ id: String, seq: [String]?, changes: [(String, String)]) -> Op {
        Op(opId: id, docId: "doc-1", at: Date(timeIntervalSince1970: 0),
           device: "d", session: "s", kind: .typingBurst,
           changes: changes.map { Op.ParagraphChange(paragraphId: $0.0, prior: nil, next: $0.1) },
           sequence: seq, provenance: nil)
    }

    /// materialize equals Deriver+Materializer over the same ops (parity).
    func test_materialize_equalsDeriverMaterializer() throws {
        let ops = [op("01a", seq: ["n5sg", "xg8q"],
                      changes: [("n5sg", "First para."), ("xg8q", "Second para.")])]
        let root = try makeProject(docId: "doc-1", ops: ops)
        let want = Materializer.materialize(
            paragraphs: Deriver.deriveWithSequenceFallback(ops: ops).paragraphs,
            sequence: Deriver.deriveWithSequenceFallback(ops: ops).sequence)
        XCTAssertEqual(DerivedManuscript.materialize(forDocId: "doc-1", in: root), want)
        XCTAssertTrue(DerivedManuscript.materialize(forDocId: "doc-1", in: root).contains("xg8q"))
    }

    /// Legacy ops (no explicit sequence) still yield ordered, non-empty text — op-log-only.
    func test_materialize_legacyNoSequence_synthesisesOrder() throws {
        let ops = [op("01a", seq: nil, changes: [("aaaa", "Alpha.")]),
                   op("01b", seq: nil, changes: [("bbbb", "Beta.")])]
        let root = try makeProject(docId: "doc-1", ops: ops)
        let text = DerivedManuscript.materialize(forDocId: "doc-1", in: root)
        XCTAssertTrue(text.contains("Alpha.") && text.contains("Beta."),
            "legacy logs must still materialise, order synthesised from ops (never the .md)")
    }

    /// derivedState exposes paragraphs + sequence directly.
    func test_derivedState_exposesParagraphsAndSequence() throws {
        let ops = [op("01a", seq: ["n5sg"], changes: [("n5sg", "Only.")])]
        let root = try makeProject(docId: "doc-1", ops: ops)
        let s = DerivedManuscript.derivedState(forDocId: "doc-1", in: root)
        XCTAssertEqual(s.paragraphs["n5sg"], "Only.")
        XCTAssertEqual(s.sequence, ["n5sg"])
    }

    /// No ops → empty string (no crash, no .md read).
    func test_materialize_noOps_isEmpty() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dm-empty-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertEqual(DerivedManuscript.materialize(forDocId: "doc-x", in: root), "")
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd Packages/MaughamCore && swift test --filter DerivedManuscriptTests 2>&1 | tail -15`
Expected: compile failure — `cannot find 'DerivedManuscript'`.

- [ ] **Step 3: Implement the primitive**

Create `Packages/MaughamCore/Sources/MaughamCore/DerivedManuscript.swift`:

```swift
import Foundation

/// The single sanctioned way to read a CLOSED manuscript document's content —
/// derived from the op log, NEVER the `.md`/`.fountain` file (ADR 0018). Open
/// docs use the live in-memory `Document`; everything else uses this.
///
/// Fully synchronous; no `Document` actor. Composes the existing primitives:
/// `OpLogStore.loadSyncMerged` (ADR 0012 partition-aware merge) →
/// `Deriver.deriveWithSequenceFallback` (op-log-only; legacy order synthesised
/// from the ops, never the file) → `Materializer.materialize`.
public enum DerivedManuscript {

    /// Anchored (materialised) manuscript text for `docId`, derived from the op
    /// log. Contains the inline `<!-- ¶id -->` anchors, exactly as autosave would
    /// write the `.md`. Empty string when the doc has no ops.
    public static func materialize(forDocId docId: String, in projectURL: URL) -> String {
        let s = derivedState(forDocId: docId, in: projectURL)
        return Materializer.materialize(paragraphs: s.paragraphs, sequence: s.sequence)
    }

    /// The derived `paragraphs` map + `sequence`, for callers that need them
    /// directly (task derivation, word count) without re-anchoring.
    public static func derivedState(forDocId docId: String, in projectURL: URL) -> Deriver.DerivedState {
        Deriver.deriveWithSequenceFallback(
            ops: OpLogStore.loadSyncMerged(forDocId: docId, in: projectURL))
    }
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `cd Packages/MaughamCore && swift test --filter DerivedManuscriptTests 2>&1 | tail -10`
Expected: 4 tests PASS.

- [ ] **Step 5: Regenerate + full Mac suite (MaughamCore is a dep)**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Executed [0-9]+ tests.*failures"`
Expected: 0 failures.

- [ ] **Step 6: Commit**

```bash
git add Packages/MaughamCore/Sources/MaughamCore/DerivedManuscript.swift Packages/MaughamCore/Tests/MaughamCoreTests/DerivedManuscriptTests.swift Maugham.xcodeproj
git commit -m "feat(core): DerivedManuscript — op-log-derived read primitive (ADR 0018)"
```
(If `Maugham.xcodeproj` is gitignored, omit it — it is generated. `git add -A` then check `git status` shows no `.xcodeproj` tracked.)

---

### Task 2: Route `read_document` (closed doc) through the op log — the reported bug

**Files:**
- Modify: `Maugham/MCP/Tools/DocumentTools.swift` (closed-doc branch in `emitManuscriptDoc`, ~line 76–81)
- Test: `MaughamTests/MCP/ReadDocumentOpLogSourceTests.swift` (new)

**Interfaces — Consumes:** `DerivedManuscript.materialize(forDocId:in:)` (Task 1).

- [ ] **Step 1: Write the failing staleness + parity test**

Create `MaughamTests/MCP/ReadDocumentOpLogSourceTests.swift`:

```swift
import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class ReadDocumentOpLogSourceTests: XCTestCase {

    /// read_document on a CLOSED doc must reflect the OP LOG, not a stale `.md`.
    /// Build a doc, then write a deliberately STALE `.md` whose body differs from
    /// what the op log derives; read_document must return the op-log content.
    func test_readDocument_closedDoc_usesOpLogNotStaleMd() async throws {
        let h = try await AnnotationFlowTestsHarnessShim.make(initialMd: "Real op-log text.")
        defer { h.cleanup() }
        // Corrupt the on-disk .md so it disagrees with the op log.
        try "STALE WRONG CONTENT".write(to: h.docURL, atomically: true, encoding: .utf8)

        let result = try await ReadDocumentTool.handle(
            paramsJSON: try JSONSerialization.data(withJSONObject: [
                "project_id": h.projectId, "document_id": h.docId]),
            registry: h.registry)
        let text = (try JSONSerialization.jsonObject(with: result) as! [String: Any])["text"] as! String

        XCTAssertTrue(text.contains("Real op-log text."),
            "read_document must derive from the op log, not the stale .md")
        XCTAssertFalse(text.contains("STALE WRONG CONTENT"))
    }
}
```

NOTE to implementer: reuse the existing harness pattern from `MaughamTests/AnnotationFlowTests.swift` (`makeHarness`) — extract a tiny shared shim or inline the project/doc/registry setup. It must expose `projectId`, `docId`, `registry`, the doc's on-disk `.md` URL (`docURL`), and the doc must be CLOSED (not registered in `documentStore.openDocuments`) so the closed-doc branch runs. If extracting a shim is heavy, inline the setup in this test file.

- [ ] **Step 2: Run it — verify it FAILS (reads stale .md today)**

Run: `xcodebuild ... -only-testing:MaughamTests/ReadDocumentOpLogSourceTests 2>&1 | grep -E "passed|failed|XCTAssert"`
Expected: FAIL — `text` contains "STALE WRONG CONTENT".

- [ ] **Step 3: Route the closed-doc branch through the op log**

In `Maugham/MCP/Tools/DocumentTools.swift`, `emitManuscriptDoc`, replace the closed-doc branch:

```swift
        if let ds = store.documentStore, let doc = ds.document(for: path) {
            text = doc.materialize()
        } else {
            // ADR 0018: derive from the op log, NOT the .md (which can lag).
            text = DerivedManuscript.materialize(forDocId: item.id, in: projectURL)
        }
```

(`item.id` is the docId; `projectURL` is already in scope. Remove the now-unused `abs` line and update the stale comment.)

- [ ] **Step 4: Run the test + the existing read_document tests — verify pass**

Run: `xcodebuild ... -only-testing:MaughamTests/ReadDocumentOpLogSourceTests -only-testing:MaughamTests/AnnotationFlowTests 2>&1 | grep -E "Executed [0-9]+ tests.*failures"`
Expected: 0 failures (the original `read_document`/`add_comment` flow + the new staleness test).

- [ ] **Step 5: Commit**

```bash
git add Maugham/MCP/Tools/DocumentTools.swift MaughamTests/MCP/ReadDocumentOpLogSourceTests.swift
git commit -m "fix(mcp): read_document derives closed-doc body from the op log, not the .md (ADR 0018)"
```

---

### Task 3: Route the publish pipeline through the op log (highest impact)

**Files:**
- Modify: `Maugham/Publish/ProjectStoreASTSource.swift` (~line 30–45)
- Test: `MaughamTests/Publish/PublishOpLogSourceTests.swift` (new)

**Interfaces — Consumes:** `DerivedManuscript.materialize(forDocId:in:)`.

- [ ] **Step 1: Write the failing staleness test**

Create `MaughamTests/Publish/PublishOpLogSourceTests.swift` — build a project with a doc, write a stale `.md`, run `ProjectStoreASTSource` (the `PieceRef` source the AST builder consumes), assert the emitted `displayText` for the piece is the op-log content, not the stale file. Mirror the harness/setup of the existing publish tests (look in `MaughamTests/Publish/`). Assert the closed-doc piece's `displayText` contains the op-log text and not the stale marker.

```swift
import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class PublishOpLogSourceTests: XCTestCase {
    func test_publishASTSource_usesOpLogNotStaleMd() async throws {
        // Build a project + one manuscript doc with op-log content "Chapter body.",
        // then overwrite its .md with "STALE". (Reuse the existing publish-test
        // project harness in MaughamTests/Publish/.)
        // Drive ProjectStoreASTSource.pieces() (or the method ProjectASTBuilder calls)
        // and assert the piece's displayText derives from the op log.
        // XCTAssertTrue(piece.displayText.contains("Chapter body."))
        // XCTAssertFalse(piece.displayText.contains("STALE"))
    }
}
```

NOTE: fill in the harness using the existing publish tests as the template (the exact `ProjectStoreASTSource` entry point + how pieces are produced). The assertion is the contract: op-log content, not the stale `.md`.

- [ ] **Step 2: Run — verify FAIL (publishes stale .md today)**

Run the focused test; Expected: FAIL (displayText contains "STALE").

- [ ] **Step 3: Route the source through the op log**

In `Maugham/Publish/ProjectStoreASTSource.swift` (~line 38), replace the per-document file read:

```swift
        // ADR 0018: build from the op-log-derived manuscript, not the .md.
        let text = DerivedManuscript.materialize(forDocId: item.id, in: projectStore.url)
```

Keep the open-doc optimisation if one exists (if the doc is open, prefer `doc.materialize()` for the freshest unsaved state — check whether `ProjectStoreASTSource` has access to `documentStore`; if so add the open-doc branch, else the op-log derive is correct since publish flushes/reads committed ops). Anchor stripping still happens downstream in `ProjectASTBuilder.build`.

- [ ] **Step 4: Run the test + existing publish tests — verify pass**

Run: `xcodebuild ... -only-testing:MaughamTests/PublishOpLogSourceTests -only-testing:MaughamTests/Publish 2>&1 | grep -E "Executed [0-9]+ tests.*failures"`
Expected: 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Publish/ProjectStoreASTSource.swift MaughamTests/Publish/PublishOpLogSourceTests.swift
git commit -m "fix(publish): build the AST from the op-log-derived manuscript, not the .md (ADR 0018)"
```

---

### Task 4: Route cross-document search through the op log

**Files:**
- Modify: `Maugham/Stores/ProjectSearchEngine.swift` (manuscript pass, ~line 28–32)
- Test: `MaughamTests/Stores/SearchOpLogSourceTests.swift` (new)

**Interfaces — Consumes:** `DerivedManuscript.materialize(forDocId:in:)`.

- [ ] **Step 1: Failing staleness test** — build a project/doc with op-log content containing a unique token; write a stale `.md` lacking it; run the manuscript search for the token; assert it's found (op log), and a token only in the stale `.md` is NOT found. Mirror existing search tests' setup.

```swift
// XCTAssertFalse(results.isEmpty, "search must find op-log content")
// XCTAssertTrue(searchForStaleOnlyToken.isEmpty, "search must NOT find stale-.md-only content")
```

- [ ] **Step 2: Run — verify FAIL.**

- [ ] **Step 3: Route the manuscript pass.** In `ProjectSearchEngine.swift` manuscript loop, replace `guard let stored = try? String(contentsOf: url, ...)` with `let stored = DerivedManuscript.materialize(forDocId: item.id, in: <projectURL>)`. Keep the existing `MarkdownDisplayFilter.stripAnchors(stored)` step (anchors must be stripped before searching, same as today). Confirm the loop has the docId (`item.id`) and the project URL in scope; thread them if needed. Leave the **research** pass (which reads research files) untouched.

- [ ] **Step 4: Run the test + existing search tests — 0 failures.**

- [ ] **Step 5: Commit** `fix(search): cross-document search reads the op-log-derived manuscript, not the .md (ADR 0018)`

---

### Task 5: Route the link/reference MCP tools through the op log

**Files:**
- Modify: `Maugham/MCP/Tools/ListAllLinksTool.swift` (~71); `Maugham/MCP/Tools/ReferenceTools.swift` (~48 `list_scenes`, ~165 `find_references`)
- Test: `MaughamTests/MCP/ReferenceOpLogSourceTests.swift` (new)

**Interfaces — Consumes:** `DerivedManuscript.materialize(forDocId:in:)`.

- [ ] **Step 1: Failing staleness tests** — for each tool, build a doc whose op log contains a `[[Wiki Link]]` (for links/find_references) or a scene heading (for list_scenes) that the stale `.md` lacks; assert the tool surfaces the op-log content. One test method per tool is fine.

- [ ] **Step 2: Run — verify FAIL.**

- [ ] **Step 3: Route each closed-doc read.**
  - `ListAllLinksTool.swift:71`: replace `try? String(contentsOf: abs, ...)` with `DerivedManuscript.materialize(forDocId: doc.id, in: <projectURL>)` (the loop var `doc` is a `StructureItem`; use its `.id`).
  - `ReferenceTools.swift:165` (`find_references`): same replacement.
  - `ReferenceTools.swift:48` (`list_scenes`): the OPEN branch uses `doc.displayText`; replace the closed `try? String(contentsOf: abs, ...)` with `DerivedManuscript.materialize(forDocId: item.id, in: <projectURL>)`. (Fountain parsing runs on the derived text.)
  Confirm each site has the doc id + project URL in scope.

- [ ] **Step 4: Run the tests + existing reference/link tests — 0 failures.**

- [ ] **Step 5: Commit** `fix(mcp): list_all_links / find_references / list_scenes derive manuscript from the op log (ADR 0018)`

---

### Task 6: Route task derivation through the op log (reuse the already-loaded ops)

**Files:**
- Modify: `Maugham/Stores/ProjectStore+Tasks.swift` (~line 195–209)
- Test: `MaughamTests/Stores/TasksOpLogSourceTests.swift` (new)

**Interfaces — Consumes:** `DerivedManuscript`/`Deriver.deriveWithSequenceFallback` (the ops are already loaded here).

- [ ] **Step 1: Failing staleness test** — build a doc whose op log contains an inline `- [ ]` task in a paragraph the stale `.md` lacks; assert closed-doc task derivation surfaces it from the op log.

- [ ] **Step 2: Run — verify FAIL.**

- [ ] **Step 3: Replace the `.md` parse with the op-log paragraphs.** In `ProjectStore+Tasks.swift`, the loop already does `let ops = OpLogStore.loadSyncMerged(forDocId: item.id, in: url)` (line 207). Move that up and delete the `.md` read (197–203); build `paragraphs` from the ops:

```swift
            let ops = OpLogStore.loadSyncMerged(forDocId: item.id, in: url)
            let paragraphs = Deriver.deriveWithSequenceFallback(ops: ops).paragraphs
            let (closedTasks, _, _) = TaskDeriver.derive(
                ops: ops, paragraphs: paragraphs, docId: item.id)
```

(Removes the redundant double-load and the `.md` dependency in one move.)

- [ ] **Step 4: Run the test + existing task tests — 0 failures.**

- [ ] **Step 5: Commit** `fix(tasks): closed-doc task derivation reads paragraphs from the op log, not the .md (ADR 0018)`

---

### Task 7: Route project-open word counts through the op log

**Files:**
- Modify: `Maugham/Stores/ProjectStore.swift` (`populateWordCountCache`, ~line 225–232)
- Test: `MaughamTests/Stores/WordCountOpLogSourceTests.swift` (new)

**Interfaces — Consumes:** `DerivedManuscript.derivedState(forDocId:in:)`.

- [ ] **Step 1: Failing staleness test** — doc with op-log content of known word count N; stale `.md` with a different count; assert `recordWordCount` stores N (op log).

- [ ] **Step 2: Run — verify FAIL.**

- [ ] **Step 3: Derive the count from the op log.** Replace the `String(contentsOf:)` + `wordCount` with:

```swift
            let state = DerivedManuscript.derivedState(forDocId: item.id, in: fileURL.deletingLastPathComponent()... )
            let text = state.paragraphs.values.joined(separator: " ")
            let count = WritingModeFactory.mode(for: path).wordCount(text)
```

NOTE: use the project root URL (`store.url` / the project URL in scope), not the file URL, for `in:`. Confirm the correct project-root variable at the call site.

- [ ] **Step 4: Run the test + existing word-count/statistics tests — 0 failures.**

- [ ] **Step 5: Commit** `fix(stores): project-open word counts derive from the op log, not the .md (ADR 0018)`

---

### Task 8: Route the wiki-rename pre-check through the op log

**Files:**
- Modify: `Maugham/Stores/ProjectStore+Structure.swift` (`propagateWikiLinkRename` pre-check, ~line 415–419)
- Test: `MaughamTests/Stores/WikiRenamePreCheckOpLogTests.swift` (new)

**Interfaces — Consumes:** `DerivedManuscript.materialize(forDocId:in:)`.

- [ ] **Step 1: Failing test** — a doc whose op log contains `[[Old]]` but whose stale `.md` does not; rename `Old`→`New`; assert the rename propagates to that doc (pre-check must not skip it). Verify by checking the resulting op-log content has `[[New]]`.

- [ ] **Step 2: Run — verify FAIL (pre-check reads stale .md, skips).**

- [ ] **Step 3: Pre-check against the op-log-derived body.** Replace `try? String(contentsOf: docURL, ...)` with `DerivedManuscript.materialize(forDocId: item.id, in: <projectURL>)` in the `WikiLinkRewriter.rewrite(body:...) == nil` skip check. The actual mutation already goes through `Document.load`/`setFullText` — unchanged.

- [ ] **Step 4: Run the test + existing wiki-rename tests — 0 failures.**

- [ ] **Step 5: Commit** `fix(stores): wiki-rename pre-check derives from the op log, not the .md (ADR 0018)`

---

### Task 9: Tripwire + planted-offender + AREA.md note

**Files:**
- Modify: `MaughamTests/TripwireGrepTests.swift` (add a case + planted-offender test)
- Modify: `Maugham/OpLog/AREA.md` (ADR 0018 note)

- [ ] **Step 1: Write the tripwire test (it must pass now that Tasks 2–8 routed everything).**

Add to `MaughamTests/TripwireGrepTests.swift`, mirroring the existing grep-tripwire shape (see `test_noHardcodedIdentityStringsInMacSources`):

```swift
    /// ADR 0018: manuscript content/sequence/anchors are read ONLY from the op
    /// log (DerivedManuscript / the live Document) — never the .md/.fountain
    /// file. Fail if a known manuscript-read site reads a doc path off disk.
    /// The ONLY sanctioned manuscript .md reads are the reconciler/echo-guard in
    /// Document+Load.swift (comparison reference, op log authoritative).
    func test_noManuscriptFileReadsOutsideReconciler() throws {
        // Files that route manuscript reads and MUST NOT String/Data(contentsOf:)
        // a manuscript doc path. (Research-file reads live in other branches/files;
        // this list is the manuscript-read surface.)
        let guardedFiles = [
            "Maugham/MCP/Tools/DocumentTools.swift",
            "Maugham/MCP/Tools/ListAllLinksTool.swift",
            "Maugham/MCP/Tools/ReferenceTools.swift",
            "Maugham/Stores/ProjectSearchEngine.swift",
            "Maugham/Stores/ProjectStore+Tasks.swift",
            "Maugham/Publish/ProjectStoreASTSource.swift",
        ]
        // … grep each file's source for `contentsOf:` and assert none remain,
        // EXCEPT lines explicitly annotated `// adr-0018-ok:` (research/config reads).
        // Mirror the file-reading + assertion mechanics of the existing tripwire tests.
    }
```

The implementer fills in the grep mechanics from the sibling tripwire tests (they read source files from the repo root and assert on matches). Reads that are legitimately non-manuscript (e.g. `DocumentTools.emitResearchItem`, `ProjectStore+Search` research branch) must either be outside the guarded list or carry an `// adr-0018-ok:` annotation that the grep skips — choose the lower-noise option per file.

- [ ] **Step 2: Add the planted-offender test** (mirrors `test_*TripwireFiresOnPlantedOffender`): construct a synthetic source string containing a forbidden `String(contentsOf:` read and assert the tripwire's matcher flags it — proving the guard actually fires.

- [ ] **Step 3: Run the tripwire tests — verify PASS** (real sources clean; planted offender detected).

Run: `xcodebuild ... -only-testing:MaughamTests/TripwireGrepTests 2>&1 | grep -E "Executed [0-9]+ tests.*failures"`

- [ ] **Step 4: AREA.md note.** Add a short bullet to `Maugham/OpLog/AREA.md`: manuscript content/sequence/anchors derive ONLY from the op log — open doc → live `Document`, closed doc → `DerivedManuscript`; never read the `.md` as truth; the only sanctioned `.md` reads are this file's reconciler/echo-guard; enforced by `TripwireGrepTests.test_noManuscriptFileReadsOutsideReconciler` (ADR 0018).

- [ ] **Step 5: Full Mac suite + Release build (publish/search touched; ProjectStore is large).**

Run:
```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Executed [0-9]+ tests.*failures"
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -2
```
Expected: 0 failures; `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit** `feat(test): tripwire — manuscript reads must derive from the op log (ADR 0018); AREA.md note`

---

## Notes for the implementer

- **Every consumer task's load-bearing test is the staleness test:** op log says one thing, the `.md` on disk says another, the consumer must reflect the op log. If you can't make that test fail before the change, the test isn't exercising the closed-doc/file-read branch — fix the test (ensure the doc is CLOSED, i.e. not in `documentStore.openDocuments`).
- **Keep open-doc branches.** Only the closed-doc / raw-file-read branches change. The open-doc path (live `Document`) is already correct.
- **Don't touch** `Document+Load.swift`, research-file reads, or manifest/config reads.
- If a site doesn't have the project-root URL or `item.id` in scope, thread it from the caller — don't reach for the file path to recompute content.
- Perf: if a bulk loop (publish/search over a whole project) shows a regression, memoise `DerivedManuscript` results by `docId` within that single operation — but only if measured.
