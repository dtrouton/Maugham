# Clean `.md` on disk — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Write manuscript files as clean Markdown/Fountain (no `¶id` or `t-` anchors), keeping the anchored truth only in the op log; make the load/recovery path op-log-self-sufficient (ADR 0019).

**Architecture:** The op log + pending buffer become the complete truth. The `.md` is written as `stripAnchors(materialize())` (the editor display form). `PendingBuffer` carries the current `sequence` so crash recovery is op-log-domain (no `.md` anchors). The bootstrap signal moves from "`.md` has no anchors" to "op log is empty." Lazy migration (clean on next autosave). Scope: clean OUTPUT only — editing stays Maugham-only, external edits discarded.

**Tech Stack:** Swift, MaughamCore. Mac target + MaughamCore. (Phone shares MaughamCore; verify its suite.)

## Global Constraints

- **The op log + pending buffer are the complete truth.** For an EXISTING doc, never read the `.md` for content, sequence, or anchors. The only `.md` reads that remain in `Document.load` are (a) import-bootstrap of a new/imported file when the op log is empty, and (b) the echo-guard comparison seed — both comparison/initial-input, not truth.
- **Clean `.md` = `MarkdownDisplayFilter.stripAnchors(materialize())`** — strips BOTH own-line `<!-- ¶id -->` and inline `<!--t-XXXXXX-->`. The op log and in-memory NSTextStorage keep anchors (unchanged).
- **Editing stays Maugham-only**; an external edit to a manuscript file is discarded on re-materialize (existing invariant). This milestone does NOT honor external edits.
- **Do NOT change** the op-log on-disk format, the in-memory editor representation, or the annotation layer (annotations are never inline in the `.md`).
- **Ordering matters:** Task 1 (pending-buffer sequence + recovery) and Task 2 (bootstrap signal + op-log-only load) must land BEFORE Task 3 (clean write), so nothing relies on the `.md`'s anchors by the time the file goes clean. Each task leaves the suite green; the `.md` stays anchored until Task 3.
- Confirmed code anchors: write at `Document.performAutosave` (`Document.swift` ~226, `let bytes = materialize()` then `write` + `lastDiskEcho = .afterWrite(bytes:)`); bootstrap detection + crash recovery in `Document+Load.swift` (~180, ~227); `PendingBuffer` is `Maugham/OpLog/PendingBuffer.swift` (`[String: Op.ParagraphChange]`, no order; old pending files abandoned-by-design on format change).
- **Build/test:** `./gen.sh` after adding files; `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`; phone `-scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17'`; MaughamCore `cd Packages/MaughamCore && swift test --filter <Name>`. SourceKit "No such module 'MaughamCore'" is noise.
- Commit after each task. Branch: `feat/clean-md-on-disk` (spec + ADR 0019 already committed).

---

### Task 1: `PendingBuffer` carries the sequence; crash recovery uses it (not the `.md`)

The foundational recovery fix — makes the op-log domain self-sufficient for an un-flushed reorder, so dropping the `.md` belt (Task 3) is lossless.

**Files:**
- Modify: `Maugham/OpLog/PendingBuffer.swift` (add durable `sequence`)
- Modify: `Maugham/OpLog/Document.swift` (`performAutosave`: set pending sequence before flush)
- Modify: `Maugham/OpLog/Document+Load.swift` (crash-recovery op captures sequence from the pending buffer)
- Test: `MaughamTests/OpLog/PendingBufferSequenceTests.swift` (new) + a crash-recovery test

**Interfaces — Produces:** `PendingBuffer.setSequence(_ sequence: [String])`, `PendingBuffer.sequence: [String]` (current, durable). The on-disk pending file becomes a single JSON object `{ "sequence": [...], "changes": [...] }` (old JSONL pending files are abandoned-by-design — already the documented contract).

- [ ] **Step 1: Write the failing tests**

`MaughamTests/OpLog/PendingBufferSequenceTests.swift`:

```swift
import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class PendingBufferSequenceTests: XCTestCase {
    private func tmpProject() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("pb-\(UUID())")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// setSequence is durable across flush + reload.
    func test_sequence_roundTripsThroughDisk() async throws {
        let root = tmpProject()
        let a = PendingBuffer(projectURL: root, docId: "doc-1", device: "d")
        a.recordChange(paragraphId: "aaaa", prior: nil, next: "Alpha.")
        a.setSequence(["bbbb", "aaaa"])           // order differs from any op-log default
        try await a.flushToDisk()

        let b = PendingBuffer(projectURL: root, docId: "doc-1", device: "d")
        try await b.loadFromDisk()
        XCTAssertEqual(b.sequence, ["bbbb", "aaaa"])
        XCTAssertEqual(b.snapshot().map(\.paragraphId), ["aaaa"])  // changes intact
    }

    /// Empty by default; clear wipes both.
    func test_sequence_defaultsEmpty_clearWipes() async throws {
        let root = tmpProject()
        let a = PendingBuffer(projectURL: root, docId: "doc-1", device: "d")
        XCTAssertEqual(a.sequence, [])
        a.setSequence(["aaaa"]); a.recordChange(paragraphId: "aaaa", prior: nil, next: "x")
        try await a.clear()
        XCTAssertEqual(a.sequence, [])
        XCTAssertTrue(a.isEmpty())
    }
}
```

For the crash-recovery test, add to an existing Document-load test file (find the one that exercises pending recovery — `grep -rl "pending" MaughamTests/OpLog`): seed a pending buffer on disk with a `sequence` that differs from the op log's last bursted sequence, `Document.load`, and assert the recovered op's `sequence` equals the **pending buffer's** sequence (not the `.md`'s). The implementer writes this against the real harness; the assertion contract is: recovery order comes from the pending buffer.

- [ ] **Step 2: Run — verify FAIL** (`setSequence`/`sequence` don't exist).

- [ ] **Step 3: Add `sequence` to `PendingBuffer`**

In `Maugham/OpLog/PendingBuffer.swift`: add `private var seq: [String] = []`; `public var sequence: [String] { seq }`; `public func setSequence(_ s: [String]) { seq = s }`. Change the durable format to a single JSON object so order survives:

```swift
    private struct DiskState: Codable { let sequence: [String]; let changes: [Op.ParagraphChange] }

    public func flushToDisk() async throws {
        let url = file()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let state = DiskState(sequence: seq, changes: snapshot())
        try enc.encode(state).write(to: url, options: .atomic)
    }

    public func loadFromDisk() async throws {
        let url = file()
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(DiskState.self, from: data) else { return }
        seq = state.sequence
        for change in state.changes { buffer[change.paragraphId] = change }
    }
```

(`clear()` already wipes the file; also reset `seq = []`. Old JSONL pending files fail to decode as `DiskState` → ignored = abandoned-by-design, per the file's existing contract — keep that comment accurate.)

- [ ] **Step 4: Set the sequence at autosave + use it in recovery**

In `Maugham/OpLog/Document.swift` `performAutosave`, before `try? await pending.flushToDisk()`, add `pending.setSequence(self.sequence)` so the durable pending file carries the live order.

In `Maugham/OpLog/Document+Load.swift` crash-recovery (~line 227-233), replace the `.md`-derived sequence with the pending buffer's:

```swift
        if !pending.isEmpty() {
            // Order comes from the pending buffer (durable, op-log-domain) — not
            // the .md (ADR 0019). Fall back to the op log's own last sequence via
            // the deriver when pending carried none (legacy pending file).
            let recoveredSequence = pending.sequence
            let recovered = Op(
                opId: ULID.generate(), docId: docId, at: Date(),
                device: device, session: session, kind: .typingBurst,
                changes: pending.snapshot(),
                sequence: recoveredSequence.isEmpty ? nil : recoveredSequence)
            try await opStore.append(recovered)
            try await pending.clear()
            ops.append(recovered)
        }
```

- [ ] **Step 5: Run the new tests + full Mac suite — verify pass**

Run: `./gen.sh && xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Executed [0-9]+ tests.*failures"`
Expected: 0 failures. (Existing pending-recovery tests may need their seeded pending file updated to the new JSON-object format — fix them; do NOT keep the old JSONL format.)

- [ ] **Step 6: Commit**

```bash
git add Maugham/OpLog/PendingBuffer.swift Maugham/OpLog/Document.swift Maugham/OpLog/Document+Load.swift MaughamTests/OpLog/PendingBufferSequenceTests.swift
git commit -m "feat(oplog): PendingBuffer carries sequence; crash recovery is op-log-domain (ADR 0019)"
```

---

### Task 2: Bootstrap signal → op-log emptiness; load content op-log-only

`Document.load` stops depending on the `.md`'s anchors for an existing doc. The `.md` stays anchored on disk (Task 3 makes it clean).

**Files:**
- Modify: `Maugham/OpLog/Document+Load.swift` (bootstrap signal; reconcile op-log-only)
- Test: `MaughamTests/OpLog/LoadFromOpLogNotMdTests.swift` (new)

- [ ] **Step 1: Write the failing tests**

Two cases:
1. **Existing doc with an anchor-less `.md` does NOT re-bootstrap.** Build a doc (op log populated via `Document.load`/Bootstrap), then overwrite its `.md` with a CLEAN (anchor-stripped) version, `Document.load` again, and assert: the op log did NOT gain a fresh bootstrap op (op count unchanged modulo recovery), and the loaded content matches the op log. (Today the `parsed.allSatisfy { id == nil }` clause would re-bootstrap.)
2. **New/imported plain `.md` (no op log) DOES bootstrap.** A clean `.md`, no op-log files, `Document.load` → ids minted, op log created, content present.

Mirror the existing `Document.load` test harness (`grep -rl "Document.load" MaughamTests/OpLog`). The assertion contracts are above.

- [ ] **Step 2: Run — verify FAIL** (case 1 re-bootstraps today).

- [ ] **Step 3: Change the bootstrap signal**

In `Maugham/OpLog/Document+Load.swift` (~line 180), replace:

```swift
        let needsBootstrap = (!logExists || parsed.allSatisfy { $0.id == nil })
            && !parsed.isEmpty
```

with:

```swift
        // ADR 0019: the .md is clean (no anchors), so "no anchors" no longer
        // signals "needs bootstrap". An existing op log is authoritative; only a
        // doc with NO op log (brand-new or imported plain file) bootstraps from
        // its .md. Reading the .md to MINT ids for a new/imported doc is the
        // sanctioned import read — not reading it as truth for an existing doc.
        let needsBootstrap = !logExists && !parsed.isEmpty
```

- [ ] **Step 4: Make reconcile op-log-only**

The load (~line 239) does `Document.reconcile(derived: Deriver.derive(ops: ops), parsed: parsed)`. With a clean `.md`, `parsed` has no ids and contributes nothing. Change the derive to the sequence-fallback and drop the `.md` dependency for content/order:

```swift
        let initial = Deriver.deriveWithSequenceFallback(ops: ops)
```

(If `Document.reconcile` does orphan repair that other call sites rely on, keep the function but pass an empty `parsed` / a derived-only path; the goal is that load content + sequence come ONLY from `ops`. Confirm by reading `reconcile` — if its only job was the `.md` join, inline the derive. Do NOT remove the echo-seed `lastWritten` read or the import-bootstrap read.)

- [ ] **Step 5: Run the new tests + full Mac suite**

Run: `xcodebuild ... test ... 2>&1 | grep -E "Executed [0-9]+ tests.*failures"`
Expected: 0 failures. (Load/reconcile tests that fed an anchored `.md` expecting it to drive ordering may need re-pointing to the op log — fix them; the op log is the source.)

- [ ] **Step 6: Commit**

```bash
git add Maugham/OpLog/Document+Load.swift MaughamTests/OpLog/LoadFromOpLogNotMdTests.swift
git commit -m "feat(oplog): load content + bootstrap signal from the op log, not the .md anchors (ADR 0019)"
```

---

### Task 3: Write the `.md` clean (strip anchors) + echo-guard clean bytes

Now safe: load + recovery are op-log-only. The file becomes standard Markdown/Fountain.

**Files:**
- Modify: `Maugham/OpLog/Document.swift` (`performAutosave`: write `stripAnchors(materialize())`; echo holds clean bytes)
- Test: `MaughamTests/OpLog/CleanMdWriteTests.swift` (new)

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class CleanMdWriteTests: XCTestCase {
    /// After autosave the on-disk file has NO ¶id and NO t- anchors, and a
    /// reload reproduces the content + ordering (op log restores anchors).
    func test_autosave_writesCleanFile_roundTrips() async throws {
        // Build a doc with ≥2 paragraphs (and ideally an inline `- [ ]` task),
        // trigger an autosave/flush, then read the file bytes off disk:
        //   XCTAssertFalse(disk.contains("<!-- ¶"))
        //   XCTAssertFalse(disk.contains("<!--t-"))
        // Reload via Document.load and assert displayText + paragraph order match.
        // (Reuse the AnnotationFlowTests / Document harness; this is the contract.)
    }

    /// Task-anchor round-trip: a doc with an inline task → clean file omits the
    /// t- anchor; reload → the inline task still derives (op log kept the anchor).
    func test_inlineTask_roundTrips_throughCleanFile() async throws {
        // seed a paragraph "- [ ] do it" with its t- anchor in the op log,
        // autosave, assert the file lacks "<!--t-", reload, assert the task derives.
    }
}
```

Fill the harness from the sibling tests; the assertions are the contract. Verify RED (today the file contains anchors).

- [ ] **Step 2: Run — verify FAIL** (file contains anchors today).

- [ ] **Step 3: Write clean**

In `Maugham/OpLog/Document.swift` `performAutosave`, change:

```swift
        let bytes = materialize()
```

to:

```swift
        // ADR 0019: the on-disk file is the clean display form (no ¶id / t-
        // anchors). The op log + in-memory NSTextStorage keep the anchors.
        let bytes = MarkdownDisplayFilter.stripAnchors(materialize())
```

`self.lastDiskEcho = .afterWrite(bytes: bytes)` then naturally holds the clean bytes (the echo-guard now compares clean-to-clean). No other change needed there.

- [ ] **Step 4: Verify external-edit is still discarded**

Add/extend a test: externally overwrite a clean `.md` with different content, drive the external-change path (`handleExternalDiskChange`), and assert the op log is unchanged and the next materialize re-writes the op-log truth (the external edit is discarded). Reuse the existing external-change test harness. (This proves invariant A holds with clean bytes.)

- [ ] **Step 5: Run all new tests + full Mac suite**

Run: `xcodebuild ... test ... 2>&1 | grep -E "Executed [0-9]+ tests.*failures"`
Expected: 0 failures. (Tests asserting the on-disk `.md` CONTAINS anchors must flip to asserting it's clean, or assert via the op log / `materialize()`. Update them — the disk form changed by design.)

- [ ] **Step 6: Commit**

```bash
git add Maugham/OpLog/Document.swift MaughamTests/OpLog/CleanMdWriteTests.swift
git commit -m "feat(oplog): write manuscript files clean (strip ¶id + t- anchors); echo-guard clean-to-clean (ADR 0019)"
```

---

### Task 4: Legacy-load check, docs, full verification

End-to-end hardening + the invariant-refinement docs + Release build + phone suite.

**Files:**
- Test: extend the load tests with a legacy-log case
- Modify: `Maugham/OpLog/AREA.md`, and the CLAUDE.md "Hard invariants" `¶id` line

- [ ] **Step 1: Legacy-load test**

Add a test: a doc whose op log has NO explicit `sequence` (legacy — ops with `changes` but `sequence: nil`) loads with non-empty, ordered content via `deriveWithSequenceFallback`, independent of the `.md` (overwrite the `.md` with junk; load still correct from the op log). RED only if a regression exists; otherwise it's a pinning test (run it, confirm GREEN).

- [ ] **Step 2: Update the docs (invariant refinement)**

`Maugham/OpLog/AREA.md`: add a note — the on-disk manuscript file is the clean display form (`stripAnchors(materialize())`, no `¶id`/`t-` anchors); the anchors live only in the op log + in-memory; load/recovery are op-log-domain (the pending buffer carries the sequence); the only `.md` reads in `Document.load` are import-bootstrap + echo-guard (ADR 0019).

CLAUDE.md "Hard invariants": refine the `¶id` sentence — the inline `<!-- ¶id -->` anchors are the join key **in the op log and in-memory representation**; the on-disk `.md` is a clean derived render (ADR 0019). Keep the rest of the op-log-is-source-of-truth invariant intact.

- [ ] **Step 3: Full Mac suite + phone suite + Release build**

Run:
```bash
xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Executed [0-9]+ tests.*failures"
xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Executed [0-9]+ tests.*failures"
xcodebuild -project Maugham.xcodeproj -scheme Maugham -configuration Release build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -2
```
Expected: 0 failures both; `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add MaughamTests Maugham/OpLog/AREA.md CLAUDE.md
git commit -m "test+docs: legacy-load pin; clean-.md invariant refinement (ADR 0019)"
```

---

## Notes for the implementer

- **Manual smoke is the real gate (controller/user runs it):** edit a doc, ⌘Q, reopen → content intact AND the `.md` on disk is clean (open it in Finder/a plain editor — no `<!-- ¶ -->` lines, no `<!--t- -->`). Toggle an inline task, reopen → still works. Crash-recovery smoke: edit (reorder a paragraph), force-quit before the 30s burst, reopen → order preserved.
- **The fragile area is `Document.load` / recovery.** Keep each task's change minimal and its test falsifiable (the file is clean / order comes from the pending buffer / an existing doc doesn't re-bootstrap). If a load test's intent is unclear, read it before changing its fixture.
- **Don't** read the `.md` for content/order/anchors of an existing doc anywhere; the import-bootstrap (op log empty) and echo-guard seed are the only `.md` reads that stay.
- The ADR 0018 tripwire guards the MCP/search/publish/store read surface — it does not cover `Document+Load`/`Document` (the sanctioned reconciler family). No tripwire change needed; the AREA note documents the new shape.
