# Op-Log Growth (ADR 0016) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bound op-log disk growth, iCloud sync churn, and derive/load time WITHOUT truncating history — via sequence keyframing (M1), sealed compressed segments (M2), and a conditional derived-state cache (M3), gated on a measurement fixture (M0).

**Architecture:** Three independent mechanisms per ADR 0016. M1 changes one emit site (`Document.flushBurstNow`) to attach `sequence` only when ordering changed or at a keyframe floor — the deriver already carries forward the last explicit sequence, so zero deriver changes. M2 adds a checksummed LZFSE container (`OpLogSegment`, MaughamCore) and rotates oversized per-device tails into immutable `.mzseg` segments; recognition is added only at the single-source filename/load helpers in `OpLogStore`. M3 (only if the post-M2 load budget is violated) adds a pure, deletable derive cache read at exactly one site.

**Tech Stack:** Swift / XCTest. MaughamCore additions use CryptoKit (SHA-256) + Foundation `NSData.compressed(using:)` — Apple system frameworks only, both available on iOS for the phone read path.

**Contract documents (read before implementing any task):**
- Spec: `docs/superpowers/specs/2026-06-09-oplog-growth-design.md` (T1–T18, §§3–9)
- ADR: `docs/adr/0016-op-log-growth-without-compaction.md` (don't relitigate compaction)
- Area: `Maugham/OpLog/AREA.md` (merge/derive contract; area flagged "don't refactor structurally")
- Handoff: `docs/superpowers/notes/2026-06-09-oplog-growth-handoff.md` (session-verified facts)

**Ground truth (verified against this branch):**
- `Document.flushBurstNow` is `Maugham/OpLog/Document.swift:578-627`; the unconditional `sequence: sequence` at `:590` is the line M1 replaces.
- `setFullText` computes `sequenceChanged` at `Document.swift:398` (per-call; bursts span many calls — hence the accumulated flag).
- `Deriver.derive` (`Packages/MaughamCore/Sources/MaughamCore/Deriver.swift:53-81`) only assigns `sequence` when `op.sequence != nil` → carry-forward is already the semantics. **M1 requires zero deriver changes.**
- `derive(ops:upTo:)` (`Maugham/OpLog/Deriver+Rewind.swift`) folds prefixes via `deriveWithSequenceFallback`; every prefix of a keyframed log contains the sequence-bearing bootstrap op, so the legacy synthesis branch never fires on keyframed logs.
- `Bootstrap.run` always emits a sequence-bearing op (`Bootstrap.swift`, "Emit bootstrap op") → a keyframed fresh log can never present empty-sequence-with-paragraphs; `Document.load`'s legacy recovery branch (`Document+Load.swift:39-71` inside `reconcile`) is undisturbed.
- `Document.restoreToOp` stamps the post-restore sequence on its own op (`Document+Rewind.swift:124-134`) → rewind needs NO `orderingDirty`.
- `reorder(sequence:)` (`Document.swift:566-576`) emits NO op itself — it relies on the next burst carrying the sequence. It MUST set `orderingDirty` (the spec's "by definition carries it" describes the post-M1 outcome, which only holds via the flag).
- `OpLogStore.appendFailureForTesting` (`OpLogStore.swift:36`) is the existing injection seam for T7 — don't add another.
- `OpLogStore.mergeSortedDedup` collapses ops duplicated between a sealed segment and a not-yet-deleted tail → seal crash-safety is by construction; T10 just pins it.
- Suffix-sensitive sites that must learn `.mzseg` (complete audit): `OpLogStore.docId(fromOpLogFilename:)` (`:118`), `OpLogStore.opLogFileURLs` (`:145-146`), `OpLogStore.loadDiagnosed` / `loadSyncMerged`, `ProjectIntegrity.check` (`ProjectIntegrity.swift:54-62` — builds its own per-URL `JSONLAppendStore` loads; **must route through the new shared per-file loader or segments arrive as garbage skips**), `MaughamSidecarPath.classifySidecar` (`MaughamSidecarPath.swift:127-141`). `IntegrityChecks.conflictTwins` guards on `.jsonl` and stays untouched by construction.
- The current device string Mac-side is `MacDeviceID.current` (`Maugham/Stores/MacDeviceID.swift`); slugs via `DeviceSlug.make(from:)`.

**Non-goals (do not let these creep in):** no truncation ever; no live-tail framing fix (audit 0.6 remainder); no skew-aware LWW; no sealing of `__project__`/inbox/pending; no migration (tripwire 11). The audit punch-list items 1–5 are a separate pass — NOT in this plan.

**Process notes:** implementers = opus (Editor/OpLog seam + MaughamCore), reviewers = haiku. M2 touches MaughamCore → run BOTH schemes. Tests crossing the `.md` ↔ op-log boundary use `ParagraphID.mint()` or 4-char alphabet-restricted IDs (tripwire 8); pure in-memory op tests may use short ids. Build: `./gen.sh` after any `project.yml`/`Package.swift` change; clean DerivedData if phantom link errors appear after new public MaughamCore types.

**Milestone gates (spec §8):**

| Milestone | Gate to start | Exit criteria |
|---|---|---|
| M0 (Tasks 1–2) | — | metrics table recorded in `docs/superpowers/notes/2026-06-09-oplog-growth-m0-baseline.md`; keyframe floor / seal threshold / LZFSE-vs-LZMA confirmed from data |
| M1 (Tasks 3–5) | M0 baseline exists | T1–T7 green both schemes; fixture re-run: sequence share < 5% of new-write bytes |
| M2 (Tasks 6–12) | M1 shipped | T8–T15 green both schemes; fixture drafting-month < ~1 MB/doc; one-generation backup blip documented |
| M3 (Tasks 13–14) | ONLY if post-M2 `Document.load` at fixture scale > 150 ms | T16–T18 green; load within budget |

---

## Milestone 0 — Measure first

### Task 1: Fixture generator (production-API drafting-history synthesis)

**Files:**
- Create: `MaughamTests/Performance/OpLogGrowthFixture.swift`
- Create: `MaughamTests/Performance/OpLogGrowthFixtureSmokeTests.swift`

The fixture synthesizes a novel project (~100k words / ~5,000 paragraphs / 30 docs) and a 110-page single-file screenplay, each with N sessions × bursts of realistic edit locality, **through the production `Document` API** (`Document.load` → `setParagraph`/`insertParagraph`/`deleteParagraph` → `flushBurstNow` → `close`) — never hand-built `[Op]` arrays. Deterministic via a seeded LCG (no seeded stdlib RNG on Apple platforms).

- [ ] **Step 1: Write the fixture generator**

```swift
// MaughamTests/Performance/OpLogGrowthFixture.swift
import Foundation
@testable import Maugham
@testable import MaughamCore

/// Deterministic LCG so fixture content is identical across runs/machines.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
    mutating func int(_ bound: Int) -> Int {
        precondition(bound > 0)
        return Int(next() % UInt64(bound))
    }
}

/// Synthesizes drafting history through the production Document API
/// (ADR 0016 / growth spec §3). NOT checked-in data — regenerated per run.
@MainActor
enum OpLogGrowthFixture {

    struct Spec {
        let label: String
        let fileExtension: String      // "md" | "fountain"
        let docCount: Int
        let paragraphsPerDoc: Int
        let wordsPerParagraph: Int
        let sessions: Int
        let burstsPerSession: Int
        let editsPerBurst: Int
        /// Every Nth burst also performs an ordering change (insert/delete).
        let orderingChangeEveryNthBurst: Int
    }

    /// ~100k words / ~5,000 paragraphs over 30 docs (spec §3a).
    static let novel = Spec(
        label: "novel", fileExtension: "md", docCount: 30,
        paragraphsPerDoc: 167, wordsPerParagraph: 20,
        sessions: 12, burstsPerSession: 20, editsPerBurst: 3,
        orderingChangeEveryNthBurst: 7)

    /// 110-page single-file screenplay, ~every line a paragraph (spec §3b).
    static let screenplay = Spec(
        label: "screenplay", fileExtension: "fountain", docCount: 1,
        paragraphsPerDoc: 3000, wordsPerParagraph: 8,
        sessions: 12, burstsPerSession: 20, editsPerBurst: 3,
        orderingChangeEveryNthBurst: 7)

    /// Tiny variant for the always-on smoke test (keeps the generator from rotting).
    static let smoke = Spec(
        label: "smoke", fileExtension: "md", docCount: 2,
        paragraphsPerDoc: 10, wordsPerParagraph: 6,
        sessions: 2, burstsPerSession: 3, editsPerBurst: 2,
        orderingChangeEveryNthBurst: 2)

    static let deviceName = "fixture-mac"

    struct Result {
        let projectURL: URL
        let docURLs: [URL]
        let docIds: [String]
        /// Sync-churn proxy (spec §3): Σ tail-file size observed after each
        /// burst append — what iCloud would re-upload per burst.
        var tailBytesRewritten: Int = 0
        var burstCount: Int = 0
    }

    static func generate(spec: Spec, seed: UInt64 = 42) async throws -> Result {
        var rng = SeededRandom(seed: seed)
        let fm = FileManager.default
        let projectURL = fm.temporaryDirectory
            .appendingPathComponent("oplog-growth-\(spec.label)-\(UUID().uuidString)")
        let manuscriptDir = projectURL.appendingPathComponent("manuscript")
        try fm.createDirectory(at: manuscriptDir, withIntermediateDirectories: true)

        // Initial content. No manifest: Document.load hash-falls-back to a
        // stable docId and resolveProjectURL's 2-level fallback lands on
        // projectURL — the documented test-fixture path.
        var docURLs: [URL] = []
        for d in 0..<spec.docCount {
            let body = (0..<spec.paragraphsPerDoc).map { p in
                paragraphText(doc: d, para: p, words: spec.wordsPerParagraph, rng: &rng)
            }.joined(separator: "\n\n")
            let url = manuscriptDir.appendingPathComponent("doc-\(d).\(spec.fileExtension)")
            try body.write(to: url, atomically: true, encoding: .utf8)
            docURLs.append(url)
        }

        var result = Result(projectURL: projectURL, docURLs: docURLs, docIds: [])
        var docIds: [String] = []

        for session in 0..<spec.sessions {
            for url in docURLs {
                // Huge burst thresholds: the scheduler never fires; the
                // fixture drives flushBurstNow explicitly per burst.
                let doc = try await Document.load(
                    url: url, device: deviceName, session: "s\(session)",
                    presenter: nil,
                    burstIdle: .seconds(3600), burstMax: .seconds(3600))
                if session == 0 { docIds.append(doc.docId) }
                let tailURL = OpLogStore.opLogFileURL(
                    forDocId: doc.docId,
                    deviceSlug: DeviceSlug.make(from: deviceName),
                    in: projectURL)

                // Edit locality: a random-walking center per session.
                var center = rng.int(max(1, doc.sequence.count))
                for burst in 0..<spec.burstsPerSession {
                    for _ in 0..<spec.editsPerBurst {
                        guard !doc.sequence.isEmpty else { break }
                        center = min(max(0, center + rng.int(7) - 3),
                                     doc.sequence.count - 1)
                        let id = doc.sequence[center]
                        let prior = doc.paragraph(id: id) ?? ""
                        doc.setParagraph(
                            id: id,
                            text: prior + " edit\(session)x\(burst)w\(rng.int(1000))")
                    }
                    if burst % spec.orderingChangeEveryNthBurst
                        == spec.orderingChangeEveryNthBurst - 1 {
                        if rng.int(2) == 0 || doc.sequence.count < 4 {
                            _ = doc.insertParagraph(
                                after: doc.sequence[center],
                                text: paragraphText(
                                    doc: 0, para: 9_000 + burst,
                                    words: spec.wordsPerParagraph, rng: &rng))
                        } else {
                            doc.deleteParagraph(id: doc.sequence[center])
                            center = min(center, doc.sequence.count - 1)
                        }
                    }
                    try await doc.flushBurstNow()
                    result.burstCount += 1
                    let size = (try? fm.attributesOfItem(atPath: tailURL.path)[.size]
                                    as? Int) ?? 0
                    result.tailBytesRewritten += size ?? 0
                }
                await doc.close()
            }
        }
        result = Result(projectURL: projectURL, docURLs: docURLs, docIds: docIds,
                        tailBytesRewritten: result.tailBytesRewritten,
                        burstCount: result.burstCount)
        return result
    }

    private static func paragraphText(
        doc: Int, para: Int, words: Int, rng: inout SeededRandom
    ) -> String {
        let lexicon = ["the", "harbour", "light", "fell", "across", "her",
                       "letters", "unsent", "winter", "glass", "remember",
                       "quietly", "salt", "morning", "voice", "stairs"]
        var out: [String] = []
        for w in 0..<words {
            out.append(lexicon[rng.int(lexicon.count)] + (w == 0 ? "-d\(doc)p\(para)" : ""))
        }
        return out.joined(separator: " ") + "."
    }
}
```

Note the double-optional on `attributesOfItem`: write it as

```swift
let size = ((try? fm.attributesOfItem(atPath: tailURL.path))?[.size] as? Int) ?? 0
result.tailBytesRewritten += size
```

- [ ] **Step 2: Write the always-on smoke test (fails before generator exists — run it red first)**

```swift
// MaughamTests/Performance/OpLogGrowthFixtureSmokeTests.swift
import XCTest
@testable import Maugham
@testable import MaughamCore

/// Always-on tiny-scale check that the fixture generator produces genuine
/// op logs through the production Document API (growth spec §3). The full
/// baseline runs are env-gated in OpLogGrowthBaselineTests.
@MainActor
final class OpLogGrowthFixtureSmokeTests: XCTestCase {

    func test_smokeFixture_producesOpsAndSurvivesReload() async throws {
        let result = try await OpLogGrowthFixture.generate(spec: .smoke)
        defer { try? FileManager.default.removeItem(at: result.projectURL) }

        XCTAssertEqual(result.docIds.count, 2)
        XCTAssertGreaterThan(result.burstCount, 0)
        XCTAssertGreaterThan(result.tailBytesRewritten, 0)

        for (docId, url) in zip(result.docIds, result.docURLs) {
            let ops = try await OpLogStore(projectURL: result.projectURL)
                .load(docId: docId)
            XCTAssertGreaterThan(ops.count, 1, "bootstrap + bursts expected")
            XCTAssertTrue(ops.contains { $0.kind == .bootstrap })
            XCTAssertTrue(ops.contains { $0.kind == .typingBurst })

            // Reload through production load: derived text must be non-empty
            // and contain a fixture edit marker (history genuinely applied).
            let doc = try await Document.load(
                url: url, device: OpLogGrowthFixture.deviceName,
                session: "verify", presenter: nil)
            XCTAssertFalse(doc.displayText.isEmpty)
            XCTAssertTrue(doc.displayText.contains("edit"),
                          "session edits must survive reload")
            await doc.close()
        }
    }

    func test_seededRandom_isDeterministic() {
        var a = SeededRandom(seed: 7), b = SeededRandom(seed: 7)
        for _ in 0..<100 { XCTAssertEqual(a.next(), b.next()) }
    }
}
```

- [ ] **Step 3: Run the smoke test**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/OpLogGrowthFixtureSmokeTests`
Expected: PASS (after Step 1; if run before, FAIL with "cannot find 'OpLogGrowthFixture'").

- [ ] **Step 4: Commit**

```bash
git add MaughamTests/Performance/
git commit -m "test(perf): M0 op-log growth fixture generator (production Document API)"
```

### Task 2: Baseline measurement harness + recorded baseline + M0 decisions

**Files:**
- Create: `MaughamTests/Performance/OpLogGrowthBaselineTests.swift`
- Create (by running, not by hand-invention): `docs/superpowers/notes/2026-06-09-oplog-growth-m0-baseline.md`

- [ ] **Step 1: Write the env-gated baseline harness**

```swift
// MaughamTests/Performance/OpLogGrowthBaselineTests.swift
import XCTest
@testable import Maugham
@testable import MaughamCore

/// M0 measurement harness (growth spec §3). Heavy — env-gated so CI stays
/// fast. Run with:
///   TEST_RUNNER_MAUGHAM_PERF_FIXTURE=1 xcodebuild -project Maugham.xcodeproj \
///     -scheme Maugham test CODE_SIGNING_ALLOWED=NO \
///     -only-testing:MaughamTests/OpLogGrowthBaselineTests
/// Paste the printed tables into
/// docs/superpowers/notes/2026-06-09-oplog-growth-m0-baseline.md.
@MainActor
final class OpLogGrowthBaselineTests: XCTestCase {

    func test_baseline_novel() async throws {
        try await runBaseline(spec: .novel)
    }

    func test_baseline_screenplay() async throws {
        try await runBaseline(spec: .screenplay)
    }

    private func runBaseline(spec: OpLogGrowthFixture.Spec) async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MAUGHAM_PERF_FIXTURE"] == "1",
            "perf fixture: run with TEST_RUNNER_MAUGHAM_PERF_FIXTURE=1")

        let result = try await OpLogGrowthFixture.generate(spec: spec)
        defer { try? FileManager.default.removeItem(at: result.projectURL) }
        let fm = FileManager.default

        // -- Metric 1: total op-log bytes on disk.
        let opsDir = result.projectURL.appendingPathComponent(".maugham/ops")
        let opFiles = (try? fm.contentsOfDirectory(
            at: opsDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let totalBytes = opFiles.reduce(0) {
            $0 + (((try? fm.attributesOfItem(atPath: $1.path))?[.size] as? Int) ?? 0)
        }

        // -- Metric 2: bytes attributable to `sequence` (re-encode each op
        //    with sequence=nil and diff).
        var sequenceBytes = 0
        var encodedBytesTotal = 0
        var allOps: [Op] = []
        for docId in result.docIds {
            let ops = try await OpLogStore(projectURL: result.projectURL)
                .load(docId: docId)
            allOps.append(contentsOf: ops)
            for op in ops {
                let full = encodedByteCount(op)
                encodedBytesTotal += full
                if op.sequence != nil {
                    sequenceBytes += full - encodedByteCount(withoutSequence(op))
                }
            }
        }

        // -- Metric 3: Document.load wall time (largest doc, 3 runs, min).
        let heaviestURL = result.docURLs[0]
        var loadTimes: [Duration] = []
        for _ in 0..<3 {
            let clock = ContinuousClock()
            let start = clock.now
            let doc = try await Document.load(
                url: heaviestURL, device: OpLogGrowthFixture.deviceName,
                session: "measure", presenter: nil)
            loadTimes.append(clock.now - start)
            await doc.close()
        }

        // -- Metric 4: Deriver.derive at full log (largest doc, 5 runs, min).
        let heaviestOps = try await OpLogStore(projectURL: result.projectURL)
            .load(docId: result.docIds[0])
        var deriveTimes: [Duration] = []
        for _ in 0..<5 {
            let clock = ContinuousClock()
            let start = clock.now
            _ = Deriver.derive(ops: heaviestOps)
            deriveTimes.append(clock.now - start)
        }

        // -- Metric 6 (spec §9.3 decision input): LZFSE vs LZMA on real tail bytes.
        let biggestTail = opFiles.max {
            ((((try? fm.attributesOfItem(atPath: $0.path))?[.size]) as? Int) ?? 0)
                < ((((try? fm.attributesOfItem(atPath: $1.path))?[.size]) as? Int) ?? 0)
        }
        var compressionTable = "  (no tail found)"
        if let tail = biggestTail, let raw = try? Data(contentsOf: tail) {
            func probe(_ algo: NSData.CompressionAlgorithm, _ name: String) -> String {
                let clock = ContinuousClock()
                let start = clock.now
                let compressed = (try? (raw as NSData).compressed(using: algo)) as Data?
                let elapsed = clock.now - start
                let ratio = compressed.map {
                    String(format: "%.1f×", Double(raw.count) / Double($0.count))
                } ?? "fail"
                return "  \(name): \(raw.count) → \(compressed?.count ?? -1) B (\(ratio)) in \(elapsed)"
            }
            compressionTable = probe(.lzfse, "LZFSE") + "\n" + probe(.lzma, "LZMA ")
        }

        print("""
        ===== M0 BASELINE — \(spec.label) =====
        docs: \(spec.docCount), bursts: \(result.burstCount), ops: \(allOps.count)
        total op-log bytes on disk:      \(totalBytes)
        encoded op bytes (canonical):    \(encodedBytesTotal)
        sequence-attributable bytes:     \(sequenceBytes) (\(String(format: "%.1f", 100.0 * Double(sequenceBytes) / Double(max(1, encodedBytesTotal))))% of encoded)
        tail bytes rewritten (sync churn proxy): \(result.tailBytesRewritten)
        Document.load (largest doc, min of 3):   \(loadTimes.min()!)
        Deriver.derive (full log, min of 5):     \(deriveTimes.min()!)
        compression probe (largest tail):
        \(compressionTable)
        =======================================
        """)
    }

    private func encodedByteCount(_ op: Op) -> Int {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        enc.outputFormatting = [.sortedKeys]
        return (try? enc.encode(op))?.count ?? 0
    }

    private func withoutSequence(_ op: Op) -> Op {
        Op(opId: op.opId, docId: op.docId, at: op.at, device: op.device,
           session: op.session, kind: op.kind, changes: op.changes,
           sequence: nil, provenance: op.provenance)
    }
}
```

- [ ] **Step 2: Verify it compiles and skips by default**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/OpLogGrowthBaselineTests`
Expected: 2 tests SKIPPED (env var unset).

- [ ] **Step 3: Run the real baseline**

Run: `TEST_RUNNER_MAUGHAM_PERF_FIXTURE=1 xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/OpLogGrowthBaselineTests 2>&1 | tee /tmp/m0-baseline.log`
Expected: PASS with two printed `===== M0 BASELINE =====` tables.

- [ ] **Step 4: Record the baseline + make the M0 decisions (spec §9)**

Write `docs/superpowers/notes/2026-06-09-oplog-growth-m0-baseline.md` containing: both printed tables verbatim; the confirmed/adjusted budgets from spec §3; and explicit decisions with one-line data-backed rationale for (1) keyframe floor (default 50), (2) seal threshold (default 512 KB), (3) LZFSE vs LZMA default. Do NOT pre-decide — read the numbers first. If a default changes, the constants in Tasks 3/8 change with it.

- [ ] **Step 5: Commit**

```bash
git add MaughamTests/Performance/OpLogGrowthBaselineTests.swift docs/superpowers/notes/2026-06-09-oplog-growth-m0-baseline.md
git commit -m "test(perf): M0 baseline harness + recorded baseline (gates M1+)"
```

---

## Milestone 1 — Sequence keyframing

**GATE: do not start until the M0 baseline note exists.**

### Task 3: Keyframed emission rule (T1, T2, T6)

**Files:**
- Modify: `Maugham/OpLog/Document.swift` (state vars near `_pendingSweep` at `:145`; `setFullText:398`; `insertParagraph:528`; `deleteParagraph:546`; `reorder:566`; `flushBurstNow:578`)
- Create: `MaughamTests/OpLog/SequenceKeyframingTests.swift`

- [ ] **Step 1: Write the failing tests T1, T2, T6**

```swift
// MaughamTests/OpLog/SequenceKeyframingTests.swift
import XCTest
@testable import Maugham
@testable import MaughamCore

/// M1 — sequence keyframing (ADR 0016 / growth spec §4). Burst ops carry
/// `sequence` only when ordering changed, at the keyframe floor, or on the
/// first burst after load; otherwise nil (deriver carries forward).
@MainActor
final class SequenceKeyframingTests: XCTestCase {

    private var projectURL: URL!

    override func setUp() async throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("keyframing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: projectURL)
    }

    /// Real .md + Bootstrap-minted 4-char anchors (tripwire 8): every test
    /// here crosses the .md ↔ op-log boundary via Document.load.
    private func makeDoc(
        paragraphs: [String] = ["First paragraph.", "Second paragraph.", "Third paragraph."]
    ) async throws -> Document {
        let url = projectURL.appendingPathComponent("manuscript/doc.md")
        try paragraphs.joined(separator: "\n\n")
            .write(to: url, atomically: true, encoding: .utf8)
        return try await Document.load(
            url: url, device: "test-mac", session: "s1", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
    }

    private func lastBurst(of doc: Document) -> Op? {
        doc.opLogSnapshot.last { $0.kind == .typingBurst }
    }

    // T1 + spec §4.1 rule 3 (first burst after load anchors the session).
    func test_textOnlyBurst_omitsSequence() async throws {
        let doc = try await makeDoc()
        let id = doc.sequence[0]

        // First burst after load: carries sequence (rule 3).
        doc.setParagraph(id: id, text: "First paragraph, edited.")
        try await doc.flushBurstNow()
        XCTAssertNotNil(lastBurst(of: doc)?.sequence,
                        "first burst after load must anchor the session")

        // Second, text-only burst: ordering unchanged → nil.
        doc.setParagraph(id: id, text: "First paragraph, edited twice.")
        try await doc.flushBurstNow()
        XCTAssertNil(lastBurst(of: doc)?.sequence,
                     "text-only burst must omit the redundant sequence")
        await doc.close()
    }

    // T2 — every ordering mutator re-arms sequence capture.
    func test_orderingChange_capturesSequence() async throws {
        let doc = try await makeDoc()

        // Drain the first-burst keyframe so each case below isolates its mutator.
        doc.setParagraph(id: doc.sequence[0], text: "Edited 0.")
        try await doc.flushBurstNow()

        // insertParagraph
        _ = doc.insertParagraph(after: doc.sequence[0], text: "Inserted.")
        try await doc.flushBurstNow()
        XCTAssertEqual(lastBurst(of: doc)?.sequence, doc.sequence,
                       "insertParagraph must put sequence on the next burst")

        // deleteParagraph
        doc.deleteParagraph(id: doc.sequence[1])
        try await doc.flushBurstNow()
        XCTAssertEqual(lastBurst(of: doc)?.sequence, doc.sequence,
                       "deleteParagraph must put sequence on the next burst")

        // reorder — emits no op itself; needs a pending change to flush with.
        doc.reorder(sequence: doc.sequence.reversed())
        doc.setParagraph(id: doc.sequence[0], text: "Edited after reorder.")
        try await doc.flushBurstNow()
        XCTAssertEqual(lastBurst(of: doc)?.sequence, doc.sequence,
                       "reorder must put sequence on the next burst")

        // setFullText with a paragraph split (sequenceChanged path).
        let split = doc.displayText
            .replacingOccurrences(of: "Edited after reorder.",
                                  with: "Edited after reorder.\n\nBrand new split paragraph.")
        doc.setFullText(split)
        try await doc.flushBurstNow()
        XCTAssertEqual(lastBurst(of: doc)?.sequence, doc.sequence,
                       "setFullText with sequenceChanged must capture sequence")
        await doc.close()
    }

    // T6 — keyframe floor: the (interval+1)th sequence-less burst keyframes.
    func test_keyframeFloor_emitsEveryNth() async throws {
        let doc = try await makeDoc()
        let id = doc.sequence[0]

        // Burst 1: rule-3 keyframe.
        doc.setParagraph(id: id, text: "v0")
        try await doc.flushBurstNow()

        // Bursts 2..(interval+1): text-only → nil.
        for i in 1...Document.sequenceKeyframeInterval {
            doc.setParagraph(id: id, text: "v\(i)")
            try await doc.flushBurstNow()
            XCTAssertNil(lastBurst(of: doc)?.sequence, "burst \(i) within the floor window")
        }

        // Next burst crosses the floor → keyframe.
        doc.setParagraph(id: id, text: "floor")
        try await doc.flushBurstNow()
        XCTAssertNotNil(lastBurst(of: doc)?.sequence,
                        "the floor keyframe must fire after \(Document.sequenceKeyframeInterval) sequence-less bursts")
        await doc.close()
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/SequenceKeyframingTests`
Expected: FAIL — `test_textOnlyBurst_omitsSequence` (sequence non-nil on every burst today) and `test_keyframeFloor_emitsEveryNth` (no `sequenceKeyframeInterval` symbol → compile error first; that counts as red).

- [ ] **Step 3: Implement the emission rule in `Document.swift`**

Add state alongside `_pendingSweep` (after `Document.swift:145`):

```swift
    /// Keyframe floor (ADR 0016 / growth spec §4.1 rule 2): emit an explicit
    /// `sequence` at least every Nth burst even when ordering is unchanged —
    /// a robustness anchor bounding how far back a reader reconstructs
    /// ordering. Default confirmed against the M0 baseline (spec §9.1).
    internal static let sequenceKeyframeInterval = 50

    /// Accumulated "paragraph ordering changed since the last sequence-bearing
    /// burst" flag (growth spec §4.2). Starts TRUE so the first burst after
    /// load always carries an ordering anchor (rule 3). Set by every in-place
    /// sequence mutator; cleared ONLY after a *successful* sequence-bearing
    /// append — on append failure it survives so the durable re-flush still
    /// carries the ordering signal (T7). Per-instance, not persisted — same
    /// lifecycle shape as `_pendingSweep`.
    internal var _orderingDirty: Bool = true

    /// Consecutive bursts emitted without an explicit `sequence` (rule 2 counter).
    internal var _burstsSinceKeyframe: Int = 0
```

In `setFullText`, immediately after `let sequenceChanged = (newSequence != sequence)` (`:398`):

```swift
        if sequenceChanged { _orderingDirty = true }
```

In `insertParagraph` after the `sequence.insert/append` branch, in `deleteParagraph` after `sequence.removeAll { $0 == id }`, and in `reorder(sequence:)` after `self.sequence = sequence` — add one line each:

```swift
        _orderingDirty = true
```

(`restoreToOp` needs nothing: it stamps the post-restore sequence on its own op. `handleExternalLogChange` needs nothing: the ordering it assigns came from sequence-bearing ops already in the log.)

In `flushBurstNow`, replace the body of the `if hadPending` block (`:580-599`) with:

```swift
        if hadPending {
            let changes = pending.snapshot()
            // Keyframed sequence emission (ADR 0016 / growth spec §4.1):
            // attach `sequence` only when the ordering changed since the last
            // sequence-bearing burst (`_orderingDirty`, which starts true so
            // the first burst after load anchors the session), or every
            // `sequenceKeyframeInterval`th burst as a robustness floor.
            // Otherwise emit nil — the deriver carries the last explicit
            // sequence forward (`Deriver.derive`), so cross-Mac merge still
            // sees every ordering change.
            let emitSequence = _orderingDirty
                || _burstsSinceKeyframe >= Self.sequenceKeyframeInterval
            let op = Op(
                opId: ULID.generate(),
                docId: docId, at: Date(),
                device: device, session: session,
                kind: .typingBurst,
                changes: changes,
                sequence: emitSequence ? sequence : nil,
                provenance: nil)
            try await opStore.append(op)
            _opLogMirror.append(op)
            // Clear the ordering signal ONLY after the append succeeded — a
            // throw above leaves `_orderingDirty` set so the close()-path
            // durable re-flush still carries it (spec §4.2 / T7).
            if emitSequence {
                _orderingDirty = false
                _burstsSinceKeyframe = 0
            } else {
                _burstsSinceKeyframe += 1
            }
            try await pending.clear()
            // Inline tasks are derived from paragraph text — any pending
            // typing change may have added/removed/toggled a `- [ ]` line.
            // Invalidate unconditionally on burst; the cache rebuilds lazily
            // on the next `tasks(filter:)` read.
            invalidateTasksCache()
        }
```

Also add one comment (no behavior change) to the crash-recovery op in `Document+Load.swift` (above `:225`):

```swift
        // NOTE (growth spec §4.2): this recovery op keeps capturing `sequence`
        // from the parsed .md UNCONDITIONALLY — it is a recovery op; correctness
        // over bytes. Keyframing applies only to flushBurstNow.
```

- [ ] **Step 4: Run the new tests + the full OpLog/Editor suites**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/SequenceKeyframingTests`
Expected: PASS.
Then the full Mac scheme (existing tests asserted burst-carries-sequence in places — e.g. partitioning/echo-guard tests build their own ops, unaffected; but run everything):
Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`
Expected: PASS. If an existing test asserted `sequence != nil` on a *second* burst, fix the TEST only if it was pinning the redundancy itself; anything asserting merge/derive correctness must pass unmodified.

- [ ] **Step 5: Commit**

```bash
git add Maugham/OpLog/Document.swift Maugham/OpLog/Document+Load.swift MaughamTests/OpLog/SequenceKeyframingTests.swift
git commit -m "feat(oplog): M1 sequence keyframing — emit sequence only on ordering change / keyframe floor / first burst (ADR 0016)"
```

### Task 4: Keyframing correctness pins (T3, T4, T5, T7)

**Files:**
- Modify: `MaughamTests/OpLog/SequenceKeyframingTests.swift` (append tests)

- [ ] **Step 1: Write T3 — keyframed log derives identically to full capture, at every cursor**

The "full capture" twin substitutes the carried-forward sequence into every `sequence: nil` typing burst — byte-what the pre-M1 emitter would have written, *because keyframing guarantees ordering didn't change between keyframes*. Append to `SequenceKeyframingTests`:

```swift
    /// Reconstruct the pre-M1 "full capture" twin of a keyframed log.
    private func fullCaptureTwin(of ops: [Op]) -> [Op] {
        var last: [String]? = nil
        return ops.sorted { $0.opId < $1.opId }.map { op in
            if let s = op.sequence { last = s; return op }
            guard op.kind == .typingBurst, let carried = last else { return op }
            return Op(opId: op.opId, docId: op.docId, at: op.at,
                      device: op.device, session: op.session, kind: op.kind,
                      changes: op.changes, sequence: carried,
                      provenance: op.provenance)
        }
    }

    // T3 — parity with full capture, including rewind state at EVERY cursor.
    func test_keyframedLog_derivesIdenticalToFullCapture() async throws {
        let doc = try await makeDoc()
        // Edit script mixing text-only bursts and ordering changes.
        doc.setParagraph(id: doc.sequence[0], text: "alpha edit")
        try await doc.flushBurstNow()
        doc.setParagraph(id: doc.sequence[1], text: "beta edit")
        try await doc.flushBurstNow()                       // nil-sequence burst
        _ = doc.insertParagraph(after: doc.sequence[1], text: "gamma inserted")
        try await doc.flushBurstNow()                       // keyframe
        doc.setParagraph(id: doc.sequence[2], text: "gamma edited")
        try await doc.flushBurstNow()                       // nil-sequence burst
        doc.deleteParagraph(id: doc.sequence[0])
        try await doc.flushBurstNow()                       // keyframe
        doc.setParagraph(id: doc.sequence[0], text: "delta edit")
        try await doc.flushBurstNow()                       // nil-sequence burst
        await doc.close()

        let keyframed = doc.opLogSnapshot.sorted { $0.opId < $1.opId }
        XCTAssertTrue(keyframed.contains { $0.kind == .typingBurst && $0.sequence == nil },
                      "script must actually produce keyframed (nil) bursts")
        let full = fullCaptureTwin(of: keyframed)

        // Full-log parity.
        XCTAssertEqual(Deriver.derive(ops: keyframed), Deriver.derive(ops: full))

        // Rewind parity at EVERY cursor (derive(ops:upTo:) folds the prefix).
        for op in keyframed {
            let cursor = RewindCursor.atOp(opId: op.opId, at: op.at)
            XCTAssertEqual(
                Deriver.derive(ops: keyframed, upTo: cursor),
                Deriver.derive(ops: full, upTo: cursor),
                "state-at-cursor must be exact at op \(op.opId)")
        }
    }
```

Check `RewindCursor`'s case spelling in `Maugham/OpLog/RewindCursor.swift` before writing (`.atOp(opId:at:)` is the expected shape; mirror whatever it actually is).

- [ ] **Step 2: Write T4 — concurrent reorder survives a text-only burst merge (pins spec §4.5)**

```swift
    // T4 — cross-device improvement, pinned so nobody "fixes" it back:
    // B reorders; A's LATER text-only burst is sequence-nil → B's order survives.
    // (Pre-M1, A's burst stamped a stale full sequence and reverted B.)
    func test_concurrentReorder_survivesTextOnlyBurstMerge() async throws {
        let store = OpLogStore(projectURL: projectURL)
        let docId = "doc-t4"
        func op(_ opId: String, device: String, kind: OpKind,
                changes: [Op.ParagraphChange] = [], sequence: [String]? = nil) -> Op {
            Op(opId: opId, docId: docId, at: Date(timeIntervalSince1970: 0),
               device: device, session: "s", kind: kind,
               changes: changes, sequence: sequence)
        }
        // Shared history: bootstrap [p1, p2].
        try await store.append(op("01-boot", device: "deviceB", kind: .bootstrap,
            changes: [.init(paragraphId: "p1", prior: nil, next: "one"),
                      .init(paragraphId: "p2", prior: nil, next: "two")],
            sequence: ["p1", "p2"]))
        // B reorders → [p2, p1] (ordering change always carries sequence).
        try await store.append(op("02-reorder", device: "deviceB", kind: .typingBurst,
            changes: [], sequence: ["p2", "p1"]))
        // A types text-only with a LATER opId — keyframed → sequence nil.
        try await store.append(op("03-text", device: "deviceA", kind: .typingBurst,
            changes: [.init(paragraphId: "p1", prior: "one", next: "one edited")],
            sequence: nil))

        let derived = Deriver.derive(ops: try await store.load(docId: docId))
        XCTAssertEqual(derived.sequence, ["p2", "p1"],
                       "B's reorder must survive A's later text-only burst")
        XCTAssertEqual(derived.paragraphs["p1"], "one edited",
                       "A's text edit must still apply")
    }
```

- [ ] **Step 3: Write T5 — keyframed fresh log never enters the legacy `.md` recovery branch**

```swift
    // T5 — spec §4.4: fresh keyframed log can't present
    // empty-sequence-with-paragraphs, so reconcile()'s legacy branch is inert.
    func test_freshLog_neverTriggersEmptySequenceRecovery() async throws {
        let doc = try await makeDoc()
        let id = doc.sequence[0]
        doc.setParagraph(id: id, text: "First, edited.")
        try await doc.flushBurstNow()
        doc.setParagraph(id: id, text: "First, edited again.")
        try await doc.flushBurstNow()                       // nil-sequence burst
        await doc.close()

        // The op-log alone (no .md help) must carry a non-empty sequence:
        // op #1 is the sequence-bearing bootstrap op.
        let ops = try await OpLogStore(projectURL: projectURL).load(docId: doc.docId)
        let derived = Deriver.derive(ops: ops)
        XCTAssertFalse(derived.sequence.isEmpty,
                       "keyframed fresh log must never derive an empty sequence")
        XCTAssertFalse(derived.paragraphs.isEmpty)

        // And reconcile() must treat that derived state as canonical (the
        // branch-2 trigger `sequence.isEmpty && !paragraphs.isEmpty` is false).
        let parsedText = try String(contentsOf: doc.url, encoding: .utf8)
        let reconciled = Document.reconcile(
            derived: derived, parsed: ParagraphParser.parse(parsedText))
        XCTAssertEqual(reconciled.sequence, derived.sequence,
                       "legacy .md-recovery must not rewrite a keyframed log's ordering")

        // End-to-end: a fresh load shows the edited text.
        let reloaded = try await Document.load(
            url: doc.url, device: "test-mac", session: "s2", presenter: nil)
        XCTAssertTrue(reloaded.displayText.contains("First, edited again."))
        await reloaded.close()
    }
```

- [ ] **Step 4: Write T7 — append failure preserves the ordering signal**

```swift
    // T7 — spec §4.2: on append failure `_orderingDirty` survives; the next
    // successful flush still carries sequence. Uses the existing injection
    // seam OpLogStore.appendFailureForTesting — do not add another.
    func test_appendFailure_preservesOrderingDirty() async throws {
        struct Boom: Error {}
        let doc = try await makeDoc()
        // Drain the rule-3 keyframe.
        doc.setParagraph(id: doc.sequence[0], text: "warmup")
        try await doc.flushBurstNow()

        // Ordering change, then an injected append failure.
        _ = doc.insertParagraph(after: doc.sequence[0], text: "inserted")
        doc.opStore.appendFailureForTesting = Boom()
        do {
            try await doc.flushBurstNow()
            XCTFail("flush should rethrow the injected append failure")
        } catch {}

        // Recovery: the next successful flush must still carry the sequence.
        doc.opStore.appendFailureForTesting = nil
        try await doc.flushBurstNow()
        XCTAssertEqual(lastBurst(of: doc)?.sequence, doc.sequence,
                       "ordering signal must survive an append failure")
        await doc.close()
    }
```

- [ ] **Step 5: Run all keyframing tests**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/SequenceKeyframingTests`
Expected: PASS (7 tests). T3/T4/T5/T7 should pass against the Task 3 implementation — if any fails, the implementation (not the test) is wrong; debug before touching assertions.

- [ ] **Step 6: Commit**

```bash
git add MaughamTests/OpLog/SequenceKeyframingTests.swift
git commit -m "test(oplog): M1 pins — full-capture parity at every cursor, cross-device reorder survival, fresh-log recovery, append-failure dirty retention"
```

### Task 5: M1 docs + exit gate

**Files:**
- Modify: `Maugham/OpLog/AREA.md` (merge/derive contract section)
- Modify: `docs/roadmap.md` (ADR 0016 item: M1 status)
- Modify: `docs/superpowers/notes/2026-06-09-oplog-growth-m0-baseline.md` (append M1 re-run)

- [ ] **Step 1: AREA.md — keyframing rule beside the merge/derive contract**

Add to the "Merge / derive resolution contract" section of `Maugham/OpLog/AREA.md`:

```markdown
- **`sequence: nil` on a typing burst means "ordering unchanged-by-construction"
  — not legacy-only — from M1 (ADR 0016) on.** `flushBurstNow` attaches
  `sequence` only when ordering changed since the last sequence-bearing burst,
  at the keyframe floor (`Document.sequenceKeyframeInterval`), or on the first
  burst after load. The deriver carries the last explicit sequence forward, so
  state-at-cursor ordering is exact at every rewind cursor (pinned by
  `SequenceKeyframingTests.test_keyframedLog_derivesIdenticalToFullCapture`).
  A text-only burst can no longer stamp a stale sequence over a concurrent
  remote reorder (pinned by `…test_concurrentReorder_survivesTextOnlyBurstMerge`).
```

- [ ] **Step 2: Run BOTH schemes (M1 exit requires both green)**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`
Run: `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO`
Expected: PASS both. (Phone never writes bursts; this is the regression check on shared derive semantics.)

- [ ] **Step 3: Fixture re-run — the <5% gate**

Run: `TEST_RUNNER_MAUGHAM_PERF_FIXTURE=1 xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/OpLogGrowthBaselineTests 2>&1 | tee /tmp/m1-rerun.log`
Append both tables to the M0 baseline note under an "## After M1" heading. Exit criterion: sequence-attributable share of encoded bytes **< 5%** (spec §3). If violated, the keyframe interval or a missed dirty-site is wrong — investigate before proceeding.

- [ ] **Step 4: Commit**

```bash
git add Maugham/OpLog/AREA.md docs/roadmap.md docs/superpowers/notes/2026-06-09-oplog-growth-m0-baseline.md
git commit -m "docs(oplog): M1 keyframing contract in AREA.md + roadmap status + post-M1 fixture numbers"
```

---

## Milestone 2 — Sealed compressed segments

**GATE: M1 shipped (Tasks 3–5 complete, gates met).**

### Task 6: `OpLogSegment` container (T8 + tamper unit)

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/OpLogSegment.swift`
- Create: `Packages/MaughamCore/Tests/MaughamCoreTests/OpLogSegmentTests.swift`

No `Package.swift` change needed (CryptoKit + Foundation compression are system frameworks), so no `./gen.sh` — but if Xcode shows phantom `Undefined symbol` after the new public type, clean DerivedData.

- [ ] **Step 1: Write the failing round-trip + tamper tests**

```swift
// Packages/MaughamCore/Tests/MaughamCoreTests/OpLogSegmentTests.swift
import XCTest
@testable import MaughamCore

final class OpLogSegmentTests: XCTestCase {

    private let jsonl = Data("""
    {"op_id":"01A","doc_id":"doc-1","next":"hello"}
    {"op_id":"01B","doc_id":"doc-1","next":"world"}

    """.utf8)

    // T8 — encode → decode → byte-identical JSONL; checksum verifies.
    func test_roundTrip() throws {
        for algo in [OpLogSegment.Algorithm.lzfse, .lzma] {
            let container = try OpLogSegment.encode(jsonl: jsonl, algorithm: algo)
            XCTAssertEqual(container.prefix(4), Data("MZS1".utf8))
            let result = OpLogSegment.decodeVerifying(container)
            XCTAssertTrue(result.isVerified, "\(algo)")
            XCTAssertEqual(result.jsonl, jsonl, "byte-identical round-trip (\(algo))")
        }
    }

    func test_emptyPayload_roundTrips() throws {
        let container = try OpLogSegment.encode(jsonl: Data())
        let result = OpLogSegment.decodeVerifying(container)
        XCTAssertTrue(result.isVerified)
        XCTAssertEqual(result.jsonl, Data())
    }

    func test_truncatedHeader_failsClosed() {
        let result = OpLogSegment.decodeVerifying(Data("MZS".utf8))
        XCTAssertEqual(result.failure, .truncatedHeader)
        XCTAssertNil(result.jsonl)
    }

    func test_badMagic_failsClosed() throws {
        var container = try OpLogSegment.encode(jsonl: jsonl)
        container.replaceSubrange(0..<4, with: Data("NOPE".utf8))
        XCTAssertEqual(OpLogSegment.decodeVerifying(container).failure, .badMagic)
    }

    func test_unknownAlgorithm_failsClosed() throws {
        var container = try OpLogSegment.encode(jsonl: jsonl)
        container[4] = 99
        XCTAssertEqual(OpLogSegment.decodeVerifying(container).failure,
                       .unknownAlgorithm(99))
    }

    // Tamper in the PAYLOAD → decompression or checksum failure; salvage may
    // or may not yield bytes, but isVerified must be false.
    func test_flippedPayloadByte_failsVerification() throws {
        var container = try OpLogSegment.encode(jsonl: jsonl)
        container[container.count - 1] ^= 0xFF
        XCTAssertFalse(OpLogSegment.decodeVerifying(container).isVerified)
    }

    // Tamper in the stored DIGEST → decompression succeeds, checksum fails,
    // and the salvaged bytes are still surfaced (best-effort, spec §5.3).
    func test_flippedDigestByte_failsChecksumButSalvages() throws {
        var container = try OpLogSegment.encode(jsonl: jsonl)
        container[16] ^= 0xFF   // first digest byte
        let result = OpLogSegment.decodeVerifying(container)
        XCTAssertEqual(result.failure, .checksumMismatch)
        XCTAssertEqual(result.jsonl, jsonl, "salvage must surface the decompressed bytes")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Packages/MaughamCore && swift test --filter OpLogSegmentTests; cd ../..`
Expected: FAIL to compile ("cannot find 'OpLogSegment'").

- [ ] **Step 3: Implement the container**

```swift
// Packages/MaughamCore/Sources/MaughamCore/OpLogSegment.swift
import Foundation
import CryptoKit

/// Sealed, compressed, checksummed container for a closed op-log segment
/// (ADR 0016 / growth spec §5.1). The payload is the byte-exact JSONL tail
/// content at seal time; the digest is over the UNCOMPRESSED bytes so a
/// verified segment parses with the same JSONL parser as a live tail.
///
/// Layout (little-endian):
///   magic "MZS1" (4) | algorithm (1) | reserved zeros (3)
///   | uncompressedByteCount u64 (8) | sha256 of uncompressed JSONL (32)
///   | compressed payload (…)
///
/// The distinct `.mzseg` extension is deliberate: `.jsonl` recognizers
/// (conflict-twin regex, pending-buffer exclusion) skip segments by
/// construction. Recognition lives ONLY in `OpLogStore`'s single-source
/// helpers — never hand-roll segment filenames (grep tripwires enforce).
public enum OpLogSegment {

    public static let fileExtension = "mzseg"
    static let magic = Data("MZS1".utf8)
    static let headerLength = 4 + 1 + 3 + 8 + 32

    public enum Algorithm: UInt8, Sendable {
        case lzfse = 1
        case lzma = 2

        var nsAlgorithm: NSData.CompressionAlgorithm {
            switch self {
            case .lzfse: return .lzfse
            case .lzma: return .lzma
            }
        }
    }

    public enum SegmentError: Error, Equatable, Sendable {
        case truncatedHeader
        case badMagic
        case unknownAlgorithm(UInt8)
        case compressionFailed
        case decompressionFailed
        case lengthMismatch(expected: UInt64, actual: UInt64)
        case checksumMismatch
    }

    /// Decode outcome. `jsonl` carries the decompressed bytes whenever
    /// decompression succeeded — even on checksum mismatch — so callers can
    /// best-effort salvage (parse what decodes) while still quarantining
    /// the failure (spec §5.3). `isVerified == false` ⇒ corruption.
    public struct DecodeResult: Sendable {
        public let jsonl: Data?
        public let failure: SegmentError?
        public var isVerified: Bool { failure == nil }
    }

    /// Encode raw JSONL bytes into a sealed container.
    public static func encode(
        jsonl: Data, algorithm: Algorithm = .lzfse
    ) throws -> Data {
        // NSData.compressed throws on empty input on some OS versions; an
        // empty tail seals to an empty payload deterministically.
        let compressed: Data
        if jsonl.isEmpty {
            compressed = Data()
        } else {
            guard let c = try? (jsonl as NSData).compressed(
                using: algorithm.nsAlgorithm) as Data else {
                throw SegmentError.compressionFailed
            }
            compressed = c
        }
        var out = Data(capacity: headerLength + compressed.count)
        out.append(magic)
        out.append(algorithm.rawValue)
        out.append(contentsOf: [0, 0, 0])
        var count = UInt64(jsonl.count).littleEndian
        withUnsafeBytes(of: &count) { out.append(contentsOf: $0) }
        out.append(Data(SHA256.hash(data: jsonl)))
        out.append(compressed)
        return out
    }

    /// Decode + verify. Never throws — corruption is a data condition the
    /// read path must route to quarantine, not a control-flow surprise.
    public static func decodeVerifying(_ container: Data) -> DecodeResult {
        guard container.count >= headerLength else {
            return DecodeResult(jsonl: nil, failure: .truncatedHeader)
        }
        // Re-base: slices keep their parent's indices.
        let bytes = Data(container)
        guard bytes.prefix(4) == magic else {
            return DecodeResult(jsonl: nil, failure: .badMagic)
        }
        guard let algorithm = Algorithm(rawValue: bytes[4]) else {
            return DecodeResult(jsonl: nil, failure: .unknownAlgorithm(bytes[4]))
        }
        let expected = bytes.subdata(in: 8..<16).withUnsafeBytes {
            UInt64(littleEndian: $0.load(as: UInt64.self))
        }
        let storedDigest = bytes.subdata(in: 16..<48)
        let payload = bytes.subdata(in: 48..<bytes.count)

        let jsonl: Data
        if payload.isEmpty && expected == 0 {
            jsonl = Data()
        } else {
            guard let d = try? (payload as NSData).decompressed(
                using: algorithm.nsAlgorithm) as Data else {
                return DecodeResult(jsonl: nil, failure: .decompressionFailed)
            }
            jsonl = d
        }
        guard UInt64(jsonl.count) == expected else {
            return DecodeResult(
                jsonl: jsonl,
                failure: .lengthMismatch(expected: expected,
                                         actual: UInt64(jsonl.count)))
        }
        guard Data(SHA256.hash(data: jsonl)) == storedDigest else {
            return DecodeResult(jsonl: jsonl, failure: .checksumMismatch)
        }
        return DecodeResult(jsonl: jsonl, failure: nil)
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `cd Packages/MaughamCore && swift test --filter OpLogSegmentTests; cd ../..`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/MaughamCore/Sources/MaughamCore/OpLogSegment.swift Packages/MaughamCore/Tests/MaughamCoreTests/OpLogSegmentTests.swift
git commit -m "feat(core): M2 OpLogSegment — checksummed LZFSE/LZMA container for sealed op-log segments (T8)"
```

### Task 7: Segment recognition + read path at the single-source helpers

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/JSONLAppendStore.swift` (extract the private parse loop into a `nonisolated static` — the spec's "parse with the SAME JSONL parser" requires a bytes entry point; append/load semantics untouched)
- Modify: `Packages/MaughamCore/Sources/MaughamCore/OpLogStore.swift` (`docId(fromOpLogFilename:)`, `opLogFileURLs`, new `segmentFileURL`/`segmentIndex`, new shared `loadFileDiagnosed`, `loadDiagnosed`, `loadSyncMerged`)
- Modify: `Packages/MaughamCore/Sources/MaughamCore/ProjectIntegrity.swift` (route per-URL loads through `loadFileDiagnosed`)
- Modify: `docs/superpowers/notes/cross-surface-contracts.md` (rows 17/18: add `.mzseg` — SAME commit as the recognition change)
- Create: `Packages/MaughamCore/Tests/MaughamCoreTests/OpLogStoreSegmentTests.swift`

- [ ] **Step 1: Write the failing recognition + read tests**

```swift
// Packages/MaughamCore/Tests/MaughamCoreTests/OpLogStoreSegmentTests.swift
import XCTest
@testable import MaughamCore

@MainActor
final class OpLogStoreSegmentTests: XCTestCase {

    private let docId = "doc-seg1"
    private var projectURL: URL!

    override func setUp() async throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("seg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent(".maugham/ops"),
            withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: projectURL)
    }

    private func op(_ opId: String, pid: String = "aaaa", next: String) -> Op {
        Op(opId: opId, docId: docId, at: Date(timeIntervalSince1970: 0),
           device: "maca", session: "s", kind: .typingBurst,
           changes: [.init(paragraphId: pid, prior: nil, next: next)],
           sequence: [pid])
    }

    private func jsonlBytes(_ ops: [Op]) throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        enc.outputFormatting = [.sortedKeys]
        var out = Data()
        for o in ops {
            out.append(try enc.encode(o))
            out.append(0x0A)
        }
        return out
    }

    private func writeSegment(_ ops: [Op], slug: String = "maca", index: Int = 1) throws -> URL {
        let url = OpLogStore.segmentFileURL(
            forDocId: docId, deviceSlug: slug, index: index, in: projectURL)
        try OpLogSegment.encode(jsonl: jsonlBytes(ops)).write(to: url)
        return url
    }

    // Recognition: filename helpers are the ONLY places that know the shape.
    func test_filenameHelpers_recognizeSegments() {
        let url = OpLogStore.segmentFileURL(
            forDocId: docId, deviceSlug: "maca", index: 3, in: projectURL)
        XCTAssertEqual(url.lastPathComponent, "doc-seg1.maca.seg0003.mzseg")
        XCTAssertEqual(OpLogStore.docId(fromOpLogFilename: url.lastPathComponent), docId)
        XCTAssertEqual(OpLogStore.segmentIndex(
            fromFilename: url.lastPathComponent, docId: docId, deviceSlug: "maca"), 3)
        XCTAssertNil(OpLogStore.docId(fromOpLogFilename: "__project__.maca.seg0001.mzseg"),
                     "__project__ stays excluded")
        XCTAssertNil(OpLogStore.segmentIndex(
            fromFilename: "doc-seg1.OTHER.seg0001.mzseg", docId: docId, deviceSlug: "maca"),
            "another device's segment is not ours")
    }

    func test_opLogFileURLs_includeSegments() throws {
        let segURL = try writeSegment([op("01A", next: "x")])
        let tailURL = OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: "maca", in: projectURL)
        try Data("".utf8).write(to: tailURL)
        let urls = Set(OpLogStore.opLogFileURLs(forDocId: docId, in: projectURL)
            .map(\.lastPathComponent))
        XCTAssertTrue(urls.contains(segURL.lastPathComponent))
        XCTAssertTrue(urls.contains(tailURL.lastPathComponent))
    }

    // T9 — parity: derive over (segment + tail) == derive over one file.
    func test_parityAcrossSeal() async throws {
        let sealed = [op("01A", next: "first"), op("01B", next: "second")]
        let live = [op("01C", next: "third")]
        _ = try writeSegment(sealed)
        let store = OpLogStore(projectURL: projectURL)
        for o in live { try await store.append(o) }

        let merged = try await store.load(docId: docId)
        XCTAssertEqual(merged.map(\.opId), ["01A", "01B", "01C"])
        XCTAssertEqual(Deriver.derive(ops: merged),
                       Deriver.derive(ops: sealed + live),
                       "storage layout must not change derivation output")
    }

    // T10 — crash window between seal-write and tail-delete: duplicates dedupe.
    func test_crashBetweenSealAndTruncate_dedupes() async throws {
        let ops = [op("01A", next: "first"), op("01B", next: "second")]
        let store = OpLogStore(projectURL: projectURL)
        for o in ops { try await store.append(o) }      // tail still present
        _ = try writeSegment(ops)                        // same ops also sealed

        let merged = try await store.load(docId: docId)
        XCTAssertEqual(merged.map(\.opId), ["01A", "01B"],
                       "segment+tail overlap must collapse by opId")
        XCTAssertEqual(Deriver.derive(ops: merged), Deriver.derive(ops: ops))
    }

    // Tampered segment: skipped surfaced via diagnostics; salvageable ops kept.
    func test_tamperedSegment_surfacesDiagnosticsAndSalvages() async throws {
        let segURL = try writeSegment([op("01A", next: "first")])
        var bytes = try Data(contentsOf: segURL)
        bytes[16] ^= 0xFF                                // corrupt stored digest
        try bytes.write(to: segURL)
        let store = OpLogStore(projectURL: projectURL)
        try await store.append(op("01B", next: "second"))

        let (ops, diagnostics) = try await store.loadDiagnosed(docId: docId)
        XCTAssertFalse(diagnostics.skipped.isEmpty,
                       "checksum failure must surface in ParseDiagnostics")
        XCTAssertTrue(ops.contains { $0.opId == "01A" },
                      "salvageable ops inside the failed segment still derive")
        XCTAssertTrue(ops.contains { $0.opId == "01B" })
    }

    // Phone read path: loadSyncMerged sees segments through the same helpers.
    func test_loadSyncMerged_readsSegmentsPlusTail() async throws {
        _ = try writeSegment([op("01A", next: "first")])
        try await OpLogStore(projectURL: projectURL).append(op("01B", next: "second"))
        let ops = OpLogStore.loadSyncMerged(forDocId: docId, in: projectURL)
        XCTAssertEqual(ops.map(\.opId), ["01A", "01B"])
    }

    // T15 (first half) — opIds inside segments stay visible to the
    // dangling-checkpoint-pointer check via ProjectIntegrity.check.
    func test_integrityCheck_resolvesOpIdsInsideSegments() async throws {
        _ = try writeSegment([op("01A", next: "first")])
        let cp = Checkpoint(
            checkpointId: "cp1", label: "l", labelSource: .auto,
            at: Date(timeIntervalSince1970: 0), device: "maca",
            activeDoc: docId, docPointers: [docId: "01A"],
            manuscriptWordCount: 1)
        try await CheckpointStore(projectURL: projectURL).append(cp)

        let report = try await ProjectIntegrity.check(projectURL: projectURL)
        XCTAssertTrue(report.danglingPointers.isEmpty,
                      "a pointer into a sealed segment is NOT dangling")
        XCTAssertTrue(report.docSkips.isEmpty, "a healthy segment yields no skips")
    }

    // T15 (second half) — `.mzseg` never flagged as an iCloud conflict twin.
    func test_segmentNeverFlaggedAsConflictTwin() {
        let twins = IntegrityChecks.conflictTwins(inOpsDirectoryFilenames: [
            "doc-seg1.maca.seg0001.mzseg",
            "doc-seg1.maca.seg0001 2.mzseg",   // even an iCloud-suffixed segment
            "doc-seg1.maca 2.jsonl",           // real twin still caught
        ])
        XCTAssertEqual(twins, ["doc-seg1.maca 2.jsonl"])
    }
}
```

Check `Checkpoint`'s real initializer in `Packages/MaughamCore/Sources/MaughamCore/Checkpoint.swift` and `CheckpointStore`'s append API before writing — mirror the actual signatures (the shapes above follow `Bootstrap.swift`'s usage).

- [ ] **Step 2: Run to verify failure**

Run: `cd Packages/MaughamCore && swift test --filter OpLogStoreSegmentTests; cd ../..`
Expected: FAIL to compile (`segmentFileURL`/`segmentIndex` don't exist).

- [ ] **Step 3: Extract the JSONL parser to a static entry point**

In `JSONLAppendStore.swift`, change the private instance method into a thin wrapper over a new static (the loop body moves verbatim — `dedupKey`/`sortedBy` become parameters):

```swift
    private func parseDiagnosed(bytes: Data) -> (elements: [Element], diagnostics: ParseDiagnostics) {
        Self.parse(bytes: bytes, dedupKey: dedupKey, sortedBy: sortedBy)
    }

    /// Parse raw JSONL bytes — the SAME parser the file-backed load uses,
    /// callable on bytes that arrived another way (a decompressed sealed
    /// segment, ADR 0016). Nonisolated + static so the synchronous readers
    /// (`OpLogStore.loadSyncMerged`) can call it.
    nonisolated static func parse(
        bytes: Data,
        dedupKey: ((Element) -> String)? = nil,
        sortedBy: ((Element, Element) -> Bool)? = nil
    ) -> (elements: [Element], diagnostics: ParseDiagnostics) {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = Self.dateDecoding
        var elements: [Element] = []
        var seen = Set<String>()
        var skipped: [ParseDiagnostics.SkippedLine] = []
        var offset = 0
        for lineBytes in bytes.split(separator: 0x0A, omittingEmptySubsequences: false) {
            let lineLen = lineBytes.count
            defer { offset += lineLen + 1 }  // +1 for the consumed newline
            if lineBytes.isEmpty { continue }  // blank line: not corruption
            let data = Data(lineBytes)
            guard let element = try? dec.decode(Element.self, from: data) else {
                let raw = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                skipped.append(.init(byteOffset: offset, raw: raw))
                continue
            }
            if let key = dedupKey?(element), !seen.insert(key).inserted { continue }
            elements.append(element)
        }
        if let sortedBy { elements.sort(by: sortedBy) }
        return (elements, ParseDiagnostics(skipped: skipped))
    }
```

- [ ] **Step 4: Implement recognition + read in `OpLogStore.swift`**

`docId(fromOpLogFilename:)` — accept both suffixes (rule unchanged: docId = component before the first `.`):

```swift
    public nonisolated static func docId(fromOpLogFilename name: String) -> String? {
        let stem: String
        if name.hasSuffix(".jsonl") {
            stem = String(name.dropLast(".jsonl".count))
        } else if name.hasSuffix(".\(OpLogSegment.fileExtension)") {
            // Sealed segment `<docId>.<slug>.seg<NNNN>.mzseg` (ADR 0016).
            stem = String(name.dropLast(".\(OpLogSegment.fileExtension)".count))
        } else {
            return nil
        }
        let head = String(stem.split(separator: ".", maxSplits: 1,
                                     omittingEmptySubsequences: false)[0])
        guard !head.isEmpty, head != "__project__" else { return nil }
        return head
    }
```

`opLogFileURLs` filter gains one arm:

```swift
        return all.filter { url in
            let n = url.lastPathComponent
            return n == "\(docId).jsonl"
                || (n.hasPrefix("\(docId).") && n.hasSuffix(".jsonl"))
                || (n.hasPrefix("\(docId).")
                    && n.hasSuffix(".\(OpLogSegment.fileExtension)"))
        }
```

New segment filename helpers (beside `opLogFileURL` — the single source of truth for segment names; the grep tripwires in Task 11 forbid hand-rolling elsewhere):

```swift
    /// Sealed-segment URL: `.maugham/ops/<docId>.<deviceSlug>.seg<NNNN>.mzseg`
    /// (ADR 0016 / growth spec §5.1). SINGLE SOURCE OF TRUTH for segment
    /// filename construction — never hand-roll the template (grep tripwires
    /// on both targets enforce; see cross-surface-contracts.md).
    public nonisolated static func segmentFileURL(
        forDocId docId: String, deviceSlug: String, index: Int, in projectURL: URL
    ) -> URL {
        projectURL
            .appendingPathComponent(".maugham/ops", isDirectory: true)
            .appendingPathComponent(
                "\(docId).\(deviceSlug).seg\(String(format: "%04d", index)).\(OpLogSegment.fileExtension)")
    }

    /// Parse `<docId>.<deviceSlug>.seg<NNNN>.mzseg` → NNNN, or nil if `name`
    /// is not a segment of this (docId, deviceSlug) pair.
    nonisolated static func segmentIndex(
        fromFilename name: String, docId: String, deviceSlug: String
    ) -> Int? {
        let prefix = "\(docId).\(deviceSlug).seg"
        let suffix = ".\(OpLogSegment.fileExtension)"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let digits = name.dropFirst(prefix.count).dropLast(suffix.count)
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }
```

New shared per-file loader + rewire `loadDiagnosed`:

```swift
    /// Load + parse ONE op-log file — plain `.jsonl` tail or sealed `.mzseg`
    /// segment — into ops + diagnostics. The single per-file read shared by
    /// `loadDiagnosed(docId:)` and `ProjectIntegrity.check`, so opIds inside
    /// segments stay visible to the dangling-pointer check exactly as tail
    /// opIds are (growth spec §5.4).
    ///
    /// Segment verification failure (bad magic / decompress / checksum) is a
    /// data condition, not an error: surfaced as a `ParseDiagnostics.skipped`
    /// entry (so `ProjectIntegrity.check` marks the doc unhealthy and the
    /// load path quarantines it) while any salvageable decompressed lines
    /// still parse — best-effort, never silent (spec §5.3).
    public static func loadFileDiagnosed(
        url: URL, presenter: NSFilePresenter?
    ) async throws -> (ops: [Op], diagnostics: ParseDiagnostics) {
        if url.pathExtension == OpLogSegment.fileExtension {
            // Coordinated read of the container bytes.
            let coord = NSFileCoordinator(filePresenter: presenter)
            var coordErr: NSError?
            var bytes: Data?
            coord.coordinate(readingItemAt: url, options: [], error: &coordErr) { ru in
                bytes = try? Data(contentsOf: ru)
            }
            if let coordErr { throw coordErr }
            guard let container = bytes else { return ([], ParseDiagnostics()) }

            let decoded = OpLogSegment.decodeVerifying(container)
            var skipped: [ParseDiagnostics.SkippedLine] = []
            if let failure = decoded.failure {
                skipped.append(.init(
                    byteOffset: 0,
                    raw: "<segment \(url.lastPathComponent): \(failure)>"))
            }
            guard let jsonl = decoded.jsonl else {
                return ([], ParseDiagnostics(skipped: skipped))
            }
            let parsed = JSONLAppendStore<Op>.parse(
                bytes: jsonl,
                dedupKey: { $0.opId }, sortedBy: { $0.opId < $1.opId })
            // Per-line skips inside a salvaged segment only matter when the
            // container itself verified (otherwise the container record covers it).
            if decoded.isVerified {
                skipped.append(contentsOf: parsed.diagnostics.skipped)
            }
            return (parsed.elements, ParseDiagnostics(skipped: skipped))
        }
        let store = JSONLAppendStore<Op>(
            fileURL: url, presenter: presenter,
            dedupKey: { $0.opId }, sortedBy: { $0.opId < $1.opId })
        let result = try await store.loadDiagnosed()
        return (result.elements, result.diagnostics)
    }
```

Rewire `loadDiagnosed(docId:)`'s loop body:

```swift
        for url in urls {
            let result = try await Self.loadFileDiagnosed(url: url, presenter: presenter)
            merged.append(contentsOf: result.ops)
            skipped.append(contentsOf: result.diagnostics.skipped)
        }
```

`loadSyncMerged` — add the segment branch inside its URL loop (before the line-split):

```swift
        for url in opLogFileURLs(forDocId: docId, in: projectURL) {
            guard let data = try? Data(contentsOf: url) else { continue }
            if url.pathExtension == OpLogSegment.fileExtension {
                // Sealed segment: verify+decompress, then the same line parse.
                guard let jsonl = OpLogSegment.decodeVerifying(data).jsonl else { continue }
                ops.append(contentsOf: JSONLAppendStore<Op>.parse(bytes: jsonl).elements)
                continue
            }
            guard let text = String(data: data, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let lineData = String(line).data(using: .utf8),
                      let op = try? dec.decode(Op.self, from: lineData) else { continue }
                ops.append(op)
            }
        }
```

- [ ] **Step 5: Route `ProjectIntegrity.check` through the shared loader**

Replace the inner per-URL loop in `ProjectIntegrity.swift:54-63` with:

```swift
            for url in OpLogStore.opLogFileURLs(forDocId: docId, in: projectURL) {
                let result = try await OpLogStore.loadFileDiagnosed(url: url, presenter: nil)
                skips.append(contentsOf: result.diagnostics.skipped)
                opIds.formUnion(result.ops.map(\.opId))
                allOps.append(contentsOf: result.ops)
            }
```

- [ ] **Step 6: Update the contracts registry (same commit)**

In `docs/superpowers/notes/cross-surface-contracts.md`, extend rows 17/18: the parse row's helper now also recognizes `<docId>.<slug>.seg<NNNN>.mzseg`; add a build row for `OpLogStore.segmentFileURL(forDocId:deviceSlug:index:in:)` with enforcement "`OpLogStoreSegmentTests` + `.mzseg` grep tripwires (both targets, Task 11)".

- [ ] **Step 7: Run core tests, then both schemes**

Run: `cd Packages/MaughamCore && swift test; cd ../..`
Expected: PASS (all, including the new OpLogStoreSegmentTests).
Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Packages/MaughamCore docs/superpowers/notes/cross-surface-contracts.md
git commit -m "feat(core): M2 segment recognition + read path at the single-source helpers (T9, T10 parity, T15, phone read-for-free)"
```

### Task 8: Seal procedure (T13 + seal-specific behavior)

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/OpLogStore.swift` (add `segmentSealThreshold` + `sealTailIfNeeded`)
- Modify: `Packages/MaughamCore/Tests/MaughamCoreTests/OpLogStoreSegmentTests.swift` (append seal tests)

- [ ] **Step 1: Write the failing seal tests**

Append to `OpLogStoreSegmentTests`:

```swift
    // --- Seal procedure (spec §5.2) ---

    private func fillTail(_ store: OpLogStore, opCount: Int) async throws {
        for i in 0..<opCount {
            try await store.append(op(String(format: "02%04d", i),
                                      next: String(repeating: "x", count: 200)))
        }
    }

    func test_seal_underThreshold_isNoOp() async throws {
        let store = OpLogStore(projectURL: projectURL)
        try await fillTail(store, opCount: 3)
        let sealed = try await store.sealTailIfNeeded(
            docId: docId, deviceSlug: "maca", threshold: 1024 * 1024)
        XCTAssertNil(sealed)
    }

    func test_seal_rotatesTail_preservesOps_andRecreatesOnNextAppend() async throws {
        let store = OpLogStore(projectURL: projectURL)
        try await fillTail(store, opCount: 20)
        let before = try await store.load(docId: docId)

        let segURL = try await store.sealTailIfNeeded(
            docId: docId, deviceSlug: "maca", threshold: 1)   // tiny: force seal
        XCTAssertNotNil(segURL)
        XCTAssertEqual(segURL?.pathExtension, "mzseg")

        let tailURL = OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: "maca", in: projectURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tailURL.path),
                       "tail must be deleted after a successful seal")
        XCTAssertEqual(try await store.load(docId: docId), before,
                       "sealing must not change the logical op log")

        // Next append recreates the tail via the existing create branch.
        try await store.append(op("03zzzz", next: "after seal"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tailURL.path))
        XCTAssertEqual(try await store.load(docId: docId).count, before.count + 1)
    }

    func test_seal_indicesIncrement_neverOverwrite() async throws {
        let store = OpLogStore(projectURL: projectURL)
        try await fillTail(store, opCount: 5)
        let first = try await store.sealTailIfNeeded(
            docId: docId, deviceSlug: "maca", threshold: 1)
        try await store.append(op("04aaaa", next: "second wave"))
        let second = try await store.sealTailIfNeeded(
            docId: docId, deviceSlug: "maca", threshold: 1)
        XCTAssertEqual(first?.lastPathComponent, "doc-seg1.maca.seg0001.mzseg")
        XCTAssertEqual(second?.lastPathComponent, "doc-seg1.maca.seg0002.mzseg")
        XCTAssertEqual(try await store.load(docId: docId).map(\.opId).count, 6)
    }

    // T13 — a torn tail line aborts the seal; tail left for quarantine.
    func test_tornTail_abortsSeal() async throws {
        let store = OpLogStore(projectURL: projectURL)
        try await fillTail(store, opCount: 3)
        let tailURL = OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: "maca", in: projectURL)
        var bytes = try Data(contentsOf: tailURL)
        bytes.append(Data("{\"op_id\":\"torn".utf8))   // no newline, truncated JSON
        try bytes.write(to: tailURL)

        let sealed = try await store.sealTailIfNeeded(
            docId: docId, deviceSlug: "maca", threshold: 1)
        XCTAssertNil(sealed, "a tail with a skipped line must never be sealed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tailURL.path),
                      "tail must be left untouched for the quarantine path")
        let segs = OpLogStore.opLogFileURLs(forDocId: docId, in: projectURL)
            .filter { $0.pathExtension == "mzseg" }
        XCTAssertTrue(segs.isEmpty)
    }

    // T10 (convergence half) — re-running the seal after a crash window converges.
    func test_sealAfterCrashWindow_converges() async throws {
        let store = OpLogStore(projectURL: projectURL)
        try await fillTail(store, opCount: 5)
        // Simulate the crash: segment written, tail NOT deleted.
        let tailURL = OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: "maca", in: projectURL)
        let tailBytes = try Data(contentsOf: tailURL)
        try OpLogSegment.encode(jsonl: tailBytes).write(
            to: OpLogStore.segmentFileURL(
                forDocId: docId, deviceSlug: "maca", index: 1, in: projectURL))
        let before = try await store.load(docId: docId)
        XCTAssertEqual(before.count, 5, "duplicates dedupe in the interim")

        // Re-running the seal sees the still-oversized tail and converges:
        // the tail's ops land in seg0002; the log is unchanged.
        let segURL = try await store.sealTailIfNeeded(
            docId: docId, deviceSlug: "maca", threshold: 1)
        XCTAssertEqual(segURL?.lastPathComponent, "doc-seg1.maca.seg0002.mzseg")
        XCTAssertEqual(try await store.load(docId: docId), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tailURL.path))
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Packages/MaughamCore && swift test --filter OpLogStoreSegmentTests; cd ../..`
Expected: FAIL to compile (`sealTailIfNeeded` doesn't exist).

- [ ] **Step 3: Implement `sealTailIfNeeded`**

Add to `OpLogStore`:

```swift
    /// Tail size above which a device's live per-doc file is sealed into an
    /// immutable compressed segment (ADR 0016 / growth spec §5.2). Default
    /// confirmed against the M0 baseline (spec §9.1).
    public static let segmentSealThreshold = 512 * 1024

    /// Seal THIS device's live tail for `docId` into the next-numbered
    /// `.mzseg` segment, iff the tail exceeds `threshold` bytes. Returns the
    /// segment URL, or nil when nothing was sealed (missing/small/torn tail).
    ///
    /// Scope rules (enforced by tests T13/T14): only ever the caller's OWN
    /// per-device tail — sealing is a rewrite of a single-writer file, the
    /// exact case ADR 0012 makes conflict-twin-free. NEVER the legacy
    /// unsuffixed `<docId>.jsonl` (no unambiguous owner; frozen since ADR
    /// 0012), never another device's file, never `__project__`.
    ///
    /// Crash safety is by construction, not by care: dying between the
    /// segment write and the tail delete leaves the same ops in both files —
    /// `mergeSortedDedup` collapses them by opId, and the next seal converges
    /// (the still-oversized tail becomes the next segment). A half-written
    /// temp file is ignored forever (wrong extension, never renamed).
    @discardableResult
    public func sealTailIfNeeded(
        docId: String, deviceSlug: String,
        threshold: Int = OpLogStore.segmentSealThreshold
    ) async throws -> URL? {
        guard docId != "__project__" else { return nil }
        let fm = FileManager.default
        let tailURL = Self.opLogFileURL(
            forDocId: docId, deviceSlug: deviceSlug, in: projectURL)
        let size = ((try? fm.attributesOfItem(atPath: tailURL.path))?[.size] as? Int) ?? 0
        guard size > threshold else { return nil }

        // 1. Coordinated read of the tail's exact bytes; abort on any torn
        //    line — never bake unparseable bytes into a checksummed segment
        //    (the existing quarantine path owns torn tails).
        let coord = NSFileCoordinator(filePresenter: presenter)
        var coordErr: NSError?
        var tailBytes: Data?
        coord.coordinate(readingItemAt: tailURL, options: [], error: &coordErr) { ru in
            tailBytes = try? Data(contentsOf: ru)
        }
        if let coordErr { throw coordErr }
        guard let bytes = tailBytes, !bytes.isEmpty else { return nil }
        let parsed = JSONLAppendStore<Op>.parse(bytes: bytes)
        guard parsed.diagnostics.skipped.isEmpty else { return nil }

        // 2. Next index = max existing + 1 for this (docId, slug); write the
        //    container to a temp name, then atomic-rename. Never overwrite.
        let existing = Self.opLogFileURLs(forDocId: docId, in: projectURL)
            .compactMap {
                Self.segmentIndex(fromFilename: $0.lastPathComponent,
                                  docId: docId, deviceSlug: deviceSlug)
            }
        let index = (existing.max() ?? 0) + 1
        let segURL = Self.segmentFileURL(
            forDocId: docId, deviceSlug: deviceSlug, index: index, in: projectURL)
        guard !fm.fileExists(atPath: segURL.path) else { return nil }
        let container = try OpLogSegment.encode(jsonl: bytes)
        let tmpURL = segURL.deletingLastPathComponent()
            .appendingPathComponent(".seal-tmp-\(UUID().uuidString)")
        try container.write(to: tmpURL, options: .atomic)
        try fm.moveItem(at: tmpURL, to: segURL)

        // 3. Coordinated delete of the tail; the next append recreates it via
        //    JSONLAppendStore.append's create branch.
        var delErr: NSError?
        var removeErr: Error?
        coord.coordinate(writingItemAt: tailURL, options: .forDeleting,
                         error: &delErr) { wu in
            do { try fm.removeItem(at: wu) } catch { removeErr = error }
        }
        if let delErr { throw delErr }
        if let removeErr { throw removeErr }
        return segURL
    }
```

- [ ] **Step 4: Run core tests**

Run: `cd Packages/MaughamCore && swift test --filter OpLogStoreSegmentTests; cd ../..`
Expected: PASS (all seal tests + earlier segment tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/MaughamCore
git commit -m "feat(core): M2 seal procedure — threshold-gated tail rotation, torn-tail abort, crash-window convergence (T10, T13)"
```

### Task 9: Mac seal triggers + presenter routing (T11)

**Files:**
- Modify: `Maugham/OpLog/Document.swift` (`close()` at `:629`)
- Modify: `Maugham/Stores/DocumentStore.swift` (`open(url:)` at `:129`)
- Modify: `Maugham/Stores/MaughamSidecarPath.swift` (`classifySidecar` ops branch at `:127-141`)
- Create: `MaughamTests/Integration/SegmentSealTriggerTests.swift`

- [ ] **Step 1: Write the failing trigger + presenter tests**

```swift
// MaughamTests/Integration/SegmentSealTriggerTests.swift
import XCTest
@testable import Maugham
@testable import MaughamCore

@MainActor
final class SegmentSealTriggerTests: XCTestCase {

    private var projectURL: URL!

    override func setUp() async throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sealtrigger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: projectURL)
    }

    private func makeDoc(device: String = "test-mac") async throws -> Document {
        let url = projectURL.appendingPathComponent("manuscript/doc.md")
        if !FileManager.default.fileExists(atPath: url.path) {
            try "Alpha paragraph.\n\nBeta paragraph."
                .write(to: url, atomically: true, encoding: .utf8)
        }
        return try await Document.load(
            url: url, device: device, session: "s1", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
    }

    private func segmentURLs(docId: String) -> [URL] {
        OpLogStore.opLogFileURLs(forDocId: docId, in: projectURL)
            .filter { $0.pathExtension == "mzseg" }
    }

    func test_close_sealsOversizedTail() async throws {
        let doc = try await makeDoc()
        // Grow the tail past the test threshold with real bursts.
        for i in 0..<30 {
            doc.setParagraph(id: doc.sequence[0],
                             text: "Alpha grown \(i) " + String(repeating: "y", count: 300))
            try await doc.flushBurstNow()
        }
        let before = try await OpLogStore(projectURL: projectURL).load(docId: doc.docId)
        Document.segmentSealThresholdForTesting = 1   // force the seal at close
        defer { Document.segmentSealThresholdForTesting = nil }
        await doc.close()

        XCTAssertFalse(segmentURLs(docId: doc.docId).isEmpty,
                       "close() must seal an oversized tail")
        let after = try await OpLogStore(projectURL: projectURL).load(docId: doc.docId)
        XCTAssertEqual(after, before, "sealing at close must not change the logical log")

        // Full reload round-trip through the production path.
        let reloaded = try await makeDoc()
        XCTAssertTrue(reloaded.displayText.contains("Alpha grown 29"))
        await reloaded.close()
    }

    func test_close_underThreshold_doesNotSeal() async throws {
        let doc = try await makeDoc()
        doc.setParagraph(id: doc.sequence[0], text: "tiny edit")
        try await doc.flushBurstNow()
        await doc.close()    // default 512 KB threshold — far under
        XCTAssertTrue(segmentURLs(docId: doc.docId).isEmpty)
    }

    // T11 — a remote device's seal delivers as a no-op re-derive.
    func test_sealIsDeriveNoOp_acrossPresenter() async throws {
        // Remote device "other-mac" writes history into ITS tail.
        let remote = try await makeDoc(device: "other-mac")
        remote.setParagraph(id: remote.sequence[0], text: "Alpha from other-mac.")
        try await remote.flushBurstNow()
        await remote.close()

        // Local doc opens and sees the merged state.
        let local = try await makeDoc(device: "test-mac")
        let textBefore = local.displayText
        let seqBefore = local.sequence

        // The remote seals its own tail (segment appears, tail disappears).
        let store = OpLogStore(projectURL: projectURL)
        let sealed = try await store.sealTailIfNeeded(
            docId: local.docId, deviceSlug: DeviceSlug.make(from: "other-mac"),
            threshold: 1)
        XCTAssertNotNil(sealed)

        // The presenter delivery on the local device: identical op set → no-op.
        try await local.handleExternalLogChange()
        XCTAssertEqual(local.displayText, textBefore)
        XCTAssertEqual(local.sequence, seqBefore)
        await local.close()
    }

    func test_sidecarPath_routesSegmentAsOpLog() {
        let url = projectURL.appendingPathComponent(
            ".maugham/ops/doc-ab12.testmac.seg0001.mzseg")
        let routed = MaughamSidecarPath.classify(url: url, projectURL: projectURL)
        guard case .opLog(let docId) = routed else {
            return XCTFail("segment must route as .opLog, got \(routed)")
        }
        XCTAssertEqual(docId, "doc-ab12")
    }

    func test_documentStoreOpen_runsSealMaintenance() async throws {
        // Manifest so DocumentStore.open finds a real project shape.
        let doc = try await makeDoc(device: MacDeviceID.current)
        for i in 0..<30 {
            doc.setParagraph(id: doc.sequence[0],
                             text: "grown \(i) " + String(repeating: "z", count: 300))
            try await doc.flushBurstNow()
        }
        // Close WITHOUT the test threshold: tail stays unsealed.
        await doc.close()
        XCTAssertTrue(segmentURLs(docId: doc.docId).isEmpty)

        Document.segmentSealThresholdForTesting = 1
        defer { Document.segmentSealThresholdForTesting = nil }
        let store = try await DocumentStore.open(url: projectURL)
        XCTAssertFalse(segmentURLs(docId: doc.docId).isEmpty,
                       "project-open maintenance must seal this Mac's oversized tails")
        await store.close()
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/SegmentSealTriggerTests`
Expected: FAIL to compile (`segmentSealThresholdForTesting` doesn't exist).

- [ ] **Step 3: Implement the triggers**

In `Document.swift`, add beside the other internal state:

```swift
    /// Test-only override for the seal threshold used by close()/open-time
    /// maintenance. Production reads `OpLogStore.segmentSealThreshold`.
    internal static var segmentSealThresholdForTesting: Int? = nil
```

At the END of `Document.close()` (after `await autosaveScheduler.flush()`):

```swift
        // Seal-on-close (ADR 0016 / growth spec §5.2): rotate this device's
        // own oversized tail into an immutable compressed segment. Threshold-
        // gated (usually a no-op) and best-effort — a seal failure must never
        // block close; the next close or project-open maintenance retries.
        // Never mid-typing, never another device's file, never the legacy
        // unsuffixed file (sealTailIfNeeded's scope rules).
        do {
            _ = try await opStore.sealTailIfNeeded(
                docId: docId,
                deviceSlug: DeviceSlug.make(from: device),
                threshold: Self.segmentSealThresholdForTesting
                    ?? OpLogStore.segmentSealThreshold)
        } catch {
            documentLog.error(
                "op-log seal failed for \(self.docId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
```

In `DocumentStore.open(url:)`, before `return store`:

```swift
        // Project-open seal maintenance (ADR 0016 / growth spec §5.2): rotate
        // any of THIS Mac's oversized per-doc tails (e.g. grown while another
        // app instance crashed before close, or a crash-window leftover).
        // Idempotent; only our own device slug; awaited inline so it cannot
        // race the first Document.load (spec §9.2 default: seal on open AND
        // close — revisit if open-time cost shows up in the fixture).
        let sealSlug = DeviceSlug.make(from: MacDeviceID.current)
        let opsDirNames = ((try? FileManager.default.contentsOfDirectory(
            at: url.appendingPathComponent(".maugham/ops"),
            includingPropertiesForKeys: nil)) ?? []).map(\.lastPathComponent)
        let sealStore = OpLogStore(projectURL: url, presenter: store._presenter)
        for docId in OpLogStore.docIds(inOpsDirectoryFilenames: opsDirNames).sorted() {
            do {
                _ = try await sealStore.sealTailIfNeeded(
                    docId: docId, deviceSlug: sealSlug,
                    threshold: Document.segmentSealThresholdForTesting
                        ?? OpLogStore.segmentSealThreshold)
            } catch {
                documentStoreLog.error(
                    "open-time op-log seal failed for \(docId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
```

(Check whether `store._presenter` is set at this point in `open` — the presenter is created mid-`open`; place the maintenance AFTER the `ProjectFolderPresenter` wiring so coordinated writes announce properly, and use whatever the property is actually named.)

In `MaughamSidecarPath.classifySidecar`, widen the ops branch:

```swift
        let opsPrefix = ".maugham/ops/"
        if relativePath.hasPrefix(opsPrefix)
            && !relativePath.hasSuffix(".pending.jsonl")
            && (relativePath.hasSuffix(".jsonl") || relativePath.hasSuffix(".mzseg")) {
```

(keep the existing docId-before-first-dot comment and body unchanged).

- [ ] **Step 4: Run the new tests + both schemes**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/SegmentSealTriggerTests`
Expected: PASS.
Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`
Expected: PASS — pay attention to MCP transient-document tests (`AnnotationToolHelpers` closes transient docs; seal is threshold-gated so those stay no-ops).

- [ ] **Step 5: Commit**

```bash
git add Maugham/OpLog/Document.swift Maugham/Stores/DocumentStore.swift Maugham/Stores/MaughamSidecarPath.swift MaughamTests/Integration/SegmentSealTriggerTests.swift
git commit -m "feat(oplog): M2 seal triggers — close + project-open maintenance; segment presenter routing; remote-seal no-op pinned (T11)"
```

### Task 10: Integrity end-to-end (T12)

**Files:**
- Create: `MaughamTests/Integration/SegmentIntegrityTests.swift`

- [ ] **Step 1: Write the failing end-to-end tamper test**

```swift
// MaughamTests/Integration/SegmentIntegrityTests.swift
import XCTest
@testable import Maugham
@testable import MaughamCore

/// T12 — ADR 0016 enforcement: a tampered segment is quarantined + marks the
/// doc unhealthy (which pauses backups, existing v0.8.0 behavior), never
/// silently skipped; salvageable ops still derive.
@MainActor
final class SegmentIntegrityTests: XCTestCase {

    private var projectURL: URL!

    override func setUp() async throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("segintegrity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: projectURL)
    }

    func test_tamperedSegment_quarantinedNotSilent() async throws {
        // Build real history and seal it.
        let url = projectURL.appendingPathComponent("manuscript/doc.md")
        try "Alpha paragraph.\n\nBeta paragraph."
            .write(to: url, atomically: true, encoding: .utf8)
        let doc = try await Document.load(
            url: url, device: "test-mac", session: "s1", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
        doc.setParagraph(id: doc.sequence[0], text: "Alpha, sealed history.")
        try await doc.flushBurstNow()
        Document.segmentSealThresholdForTesting = 1
        defer { Document.segmentSealThresholdForTesting = nil }
        await doc.close()

        let segURL = OpLogStore.opLogFileURLs(forDocId: doc.docId, in: projectURL)
            .first { $0.pathExtension == "mzseg" }!
        // Flip a byte in the stored digest: decompression still succeeds →
        // salvage path; checksum fails → quarantine + unhealthy.
        var bytes = try Data(contentsOf: segURL)
        bytes[16] ^= 0xFF
        try bytes.write(to: segURL)

        // 1. The integrity report marks the doc unhealthy.
        let report = try await ProjectIntegrity.check(projectURL: projectURL)
        XCTAssertFalse(report.isHealthy)
        XCTAssertTrue(report.docSkips.contains { $0.docId == doc.docId })

        // 2. Loading the doc writes a forensic quarantine record.
        let reloaded = try await Document.load(
            url: url, device: "test-mac", session: "s2", presenter: nil)
        let quarantineDir = projectURL
            .appendingPathComponent(".maugham/conflicts/quarantine")
        let records = (try? FileManager.default.contentsOfDirectory(
            atPath: quarantineDir.path)) ?? []
        XCTAssertTrue(records.contains { $0.hasPrefix(doc.docId) },
                      "checksum failure must leave a quarantine record")

        // 3. Salvageable ops still derived — the sealed edit is visible.
        XCTAssertTrue(reloaded.displayText.contains("Alpha, sealed history."),
                      "salvage must keep the manuscript readable")
        await reloaded.close()
    }
}
```

- [ ] **Step 2: Run — this should pass already (wiring exists); verify, don't skip**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/SegmentIntegrityTests`
Expected: PASS — the quarantine call in `Document+Load.swift:204-214` and `ProjectIntegrity.check` (rerouted in Task 7) provide the behavior; this test pins the end-to-end chain. If it FAILS, the Task 7 diagnostics surfacing is wrong — fix that, not the test.

- [ ] **Step 3: Commit**

```bash
git add MaughamTests/Integration/SegmentIntegrityTests.swift
git commit -m "test(integrity): T12 — tampered segment quarantined + unhealthy + salvaged, end to end"
```

### Task 11: Scope rules + grep tripwires + docs (T14)

**Files:**
- Modify: `Packages/MaughamCore/Tests/MaughamCoreTests/OpLogStoreSegmentTests.swift` (T14 legacy-never-sealed)
- Modify: `MaughamTests/TripwireGrepTests.swift` (Mac `.mzseg` tripwire + planted-offender self-check)
- Modify: `MaughamPhoneTests/TripwirePhoneGrepTest.swift` (phone `.mzseg` tripwire — read its existing helper shape first and mirror it)
- Create: `MaughamPhoneTests/OpLogSegmentReadTests.swift` (phone reads segments through shared helpers)
- Modify: `Maugham/OpLog/AREA.md`, `CLAUDE.md` (tripwire 17 footnote), `docs/roadmap.md`

- [ ] **Step 1: T14a — the legacy unsuffixed file is never sealed**

Append to `OpLogStoreSegmentTests`:

```swift
    // T14 — the legacy unsuffixed `<docId>.jsonl` has no unambiguous owner
    // and is NEVER sealed; only the caller's own per-device tail is.
    func test_legacyFile_neverSealed() async throws {
        let legacyURL = projectURL
            .appendingPathComponent(".maugham/ops/\(docId).jsonl")
        let store = JSONLAppendStore<Op>(
            fileURL: legacyURL, dedupKey: { $0.opId }, sortedBy: { $0.opId < $1.opId })
        for i in 0..<10 {
            try await store.append(op(String(format: "05%04d", i),
                                      next: String(repeating: "L", count: 500)))
        }
        // Sealing for any slug must not touch the legacy file: there is no
        // per-device tail, so this is a no-op even at threshold 0.
        let sealed = try await OpLogStore(projectURL: projectURL)
            .sealTailIfNeeded(docId: docId, deviceSlug: "maca", threshold: 0)
        XCTAssertNil(sealed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path),
                      "legacy file must survive untouched")
        XCTAssertEqual(try await OpLogStore(projectURL: projectURL)
            .load(docId: docId).count, 10)
    }
```

Note `sealTailIfNeeded` targets `opLogFileURL(forDocId:deviceSlug:)` — it *cannot* name the legacy file; this test pins that by construction.

- [ ] **Step 2: T14b — phone never seals + reads segments for free**

First read `MaughamPhoneTests/TripwirePhoneGrepTest.swift` to mirror its scan-helper shape exactly. Then add a phone tripwire test: scan `MaughamPhone/` sources for the patterns `[".mzseg", "sealTailIfNeeded"]` with no allowed files — the phone must contain ZERO segment spellings (it reads through `loadSyncMerged`/`opLogFileURLs`). Include a planted-offender self-check mirroring the file's existing convention.

Then the phone read test:

```swift
// MaughamPhoneTests/OpLogSegmentReadTests.swift
import XCTest
@testable import MaughamCore

/// The phone gets sealed-segment reading FOR FREE through the shared
/// MaughamCore helpers (growth spec §5.3) — pinned here so a phone-local
/// reader regression (the phone-v0.1.1 class of bug) can't silently return.
@MainActor
final class OpLogSegmentReadTests: XCTestCase {

    func test_loadSyncMerged_readsSealedSegmentPlusTail() throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("phone-seg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: projectURL) }
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent(".maugham/ops"),
            withIntermediateDirectories: true)

        func op(_ opId: String, next: String) -> Op {
            Op(opId: opId, docId: "doc-ph1", at: Date(timeIntervalSince1970: 0),
               device: "mac", session: "s", kind: .typingBurst,
               changes: [.init(paragraphId: "aaaa", prior: nil, next: next)],
               sequence: ["aaaa"])
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        enc.outputFormatting = [.sortedKeys]
        var jsonl = Data()
        jsonl.append(try enc.encode(op("01A", next: "sealed")))
        jsonl.append(0x0A)
        try OpLogSegment.encode(jsonl: jsonl).write(
            to: OpLogStore.segmentFileURL(
                forDocId: "doc-ph1", deviceSlug: "mac", index: 1, in: projectURL))
        var tail = Data()
        tail.append(try enc.encode(op("01B", next: "live")))
        tail.append(0x0A)
        try tail.write(to: OpLogStore.opLogFileURL(
            forDocId: "doc-ph1", deviceSlug: "mac", in: projectURL))

        let ops = OpLogStore.loadSyncMerged(forDocId: "doc-ph1", in: projectURL)
        XCTAssertEqual(ops.map(\.opId), ["01A", "01B"])
        XCTAssertEqual(Deriver.derive(ops: ops).paragraphs["aaaa"], "live")
    }
}
```

- [ ] **Step 3: Mac `.mzseg` grep tripwire**

Add to `MaughamTests/TripwireGrepTests.swift` (mirroring the existing helper usage):

```swift
    // MARK: - Sealed-segment name tripwire (ADR 0016)

    /// Recurrence-tripper: segment filenames/extension are built ONLY by
    /// `OpLogStore.segmentFileURL` (MaughamCore). A hand-rolled ".mzseg"
    /// template in Maugham/ is the same reach-around class as the phone's
    /// doc-id parser bug. Sealing is invoked ONLY via sealTailIfNeeded on
    /// the device's own slug (CLAUDE.md tripwire 17 footnote).
    func test_noHandRolledSegmentNamesInMacSources() throws {
        let offenders = try grepSwift(
            in: sourceDir,
            patterns: [".mzseg"],
            allowed: ["MaughamSidecarPath.swift"],   // routes by suffix, sanctioned
            excludeLine: { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("//") || trimmed.hasPrefix("///")
            }
        )
        XCTAssertTrue(offenders.isEmpty,
            "Hand-rolled .mzseg segment naming in Maugham/. Use "
            + "OpLogStore.segmentFileURL / opLogFileURLs (MaughamCore). "
            + "See docs/superpowers/notes/cross-surface-contracts.md. Offenders:\n"
            + offenders.joined(separator: "\n"))
    }

    func test_segmentNameTripwireFiresOnPlantedOffender() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("tripwire-mzseg-selfcheck-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        try """
        func badSegmentName(_ docId: String) -> String {
            return "\\(docId).mac.seg0001.mzseg"
        }
        """.write(to: tmp.appendingPathComponent("BadSeg.swift"),
                  atomically: true, encoding: .utf8)
        let offenders = try grepSwift(in: tmp, patterns: [".mzseg"])
        XCTAssertEqual(offenders.count, 1)
    }
```

(Verify the `Document.swift`/`DocumentStore.swift` trigger code from Task 9 doesn't spell `.mzseg` — it doesn't; it calls `sealTailIfNeeded` and `pathExtension == "mzseg"` appears only in TESTS, which aren't scanned. If a production Mac file legitimately needs the suffix later, it goes through `OpLogSegment.fileExtension`.)

- [ ] **Step 4: Docs**

`Maugham/OpLog/AREA.md`:
- In "Invariants", extend the append-only bullet: *"Sealing (ADR 0016) is a storage-layout change to a single-writer file; the logical log is untouched — the merged, opId-deduped set is identical before and after a seal."*
- New subsection after the merge/derive contract:

```markdown
## Sealed segments (ADR 0016, M2)

When a device's own live tail `<docId>.<slug>.jsonl` exceeds
`OpLogStore.segmentSealThreshold`, `Document.close()` / project-open
maintenance rotate it into an immutable, LZFSE-compressed, SHA-256-checksummed
`<docId>.<slug>.seg<NNNN>.mzseg` (container: `OpLogSegment`, MaughamCore).
Readers see one merged `[Op]` exactly as before — recognition lives ONLY in
`OpLogStore.opLogFileURLs` / `docId(fromOpLogFilename:)` / `loadFileDiagnosed`
/ `loadSyncMerged` (single-source helpers; grep tripwires on both targets).
Scope: never the legacy unsuffixed file, never another device's tail, never
`__project__`/inbox/pending, never mid-typing, Mac-only in v1. Crash window
between segment-write and tail-delete is safe by construction
(`mergeSortedDedup` collapses the duplicates; the next seal converges).
A checksum failure quarantines + marks the doc unhealthy (backups pause) while
salvageable ops still derive. Tests: `OpLogSegmentTests`,
`OpLogStoreSegmentTests`, `SegmentSealTriggerTests`, `SegmentIntegrityTests`.
```

`CLAUDE.md` tripwire 17 — append a footnote sentence to its "Why" cell or below the table: *"Sealing (ADR 0016) is safe because of per-device partitioning; never seal the legacy unsuffixed file or another device's file (enforced by `OpLogStoreSegmentTests.test_legacyFile_neverSealed` + the phone `.mzseg` tripwire)."*

`docs/roadmap.md`: mark M2 status on the ADR 0016 item.

- [ ] **Step 5: Run BOTH schemes + core**

Run: `cd Packages/MaughamCore && swift test; cd ../..`
Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO`
Run: `xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO`
Expected: PASS ×3. (Simulator "Busy/preflight" failures are a flake — re-run.)

- [ ] **Step 6: Commit**

```bash
git add Packages/MaughamCore MaughamTests/TripwireGrepTests.swift MaughamPhoneTests/ Maugham/OpLog/AREA.md CLAUDE.md docs/roadmap.md
git commit -m "test(scope): T14 — legacy never sealed, phone never seals + reads segments via shared helpers; .mzseg grep tripwires both targets; docs"
```

### Task 12: M2 exit gates + milestone note

- [ ] **Step 1: Fixture re-run with sealing active**

The drafting-month budget needs seals to actually fire at fixture scale. Run:
`TEST_RUNNER_MAUGHAM_PERF_FIXTURE=1 xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/OpLogGrowthBaselineTests 2>&1 | tee /tmp/m2-rerun.log`
Then compute the per-doc on-disk total (segments + tail) from the printed table (the fixture's `close()` per session now seals when past threshold). Exit criteria: heavy-drafting-month per doc **< ~1 MB**; `Document.load` number recorded (this is the M3 gate input). Append an "## After M2" section to the baseline note with the tables + the load-time verdict vs the 150 ms budget.

- [ ] **Step 2: Backup-blip observation (spec §5.4 documentation duty)**

In the M2 section of the baseline note, document the expected one-generation backup signature change per seal (tail file-set changes once; segments immutable thereafter) — cite `MerkleManifest`/`BackupSignature` hashing files as files. No code change.

- [ ] **Step 3: Milestone note + commit**

Write `docs/superpowers/notes/2026-06-09-oplog-growth-m2-status.md` (what shipped, gates met, the M3 go/no-go verdict from Step 1, the user-run smoke checklist from spec §8). Commit:

```bash
git add docs/superpowers/notes/
git commit -m "docs: M2 exit — fixture numbers, backup-blip note, M3 go/no-go verdict"
```

- [ ] **Step 4: STOP — user-run manual smoke (CLAUDE.md format + spec §8)**

Ask the user to run: draft in a screenplay project past the seal threshold → ⌘Q → relaunch → text intact → History Rewind scrubs back through sealed history → Restore from a point inside a sealed segment's range. Plus the standard smoke (New project → type → quit → relaunch → intact). Do not tag before this.

---

## Milestone 3 — Derived-state cache (CONDITIONAL)

**GATE: implement ONLY if the post-M2 `Document.load` at fixture scale exceeds 150 ms (Task 12 Step 1 verdict). If within budget: record "M3 not needed" in the milestone note and STOP — this is the planned outcome, not a shortcut.**

### Task 13: Cache store + single read site (T16, T17, T18)

**Files:**
- Create: `Maugham/OpLog/DeriveCache.swift`
- Modify: `Maugham/OpLog/Document+Load.swift` (read at the initial derive), `Maugham/OpLog/Document+ExternalChange.swift` + `Document.close()` (refresh)
- Modify: `Maugham/Stores/MaughamSidecarPath.swift` (new case routed as ignore)
- Create: `MaughamTests/OpLog/DeriveCacheTests.swift`

- [ ] **Step 1: Write the failing tests (T16–T18)**

```swift
// MaughamTests/OpLog/DeriveCacheTests.swift
import XCTest
@testable import Maugham
@testable import MaughamCore

@MainActor
final class DeriveCacheTests: XCTestCase {

    private var projectURL: URL!

    override func setUp() async throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("derivecache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: projectURL)
    }

    private func makeAndCloseDoc() async throws -> (url: URL, docId: String, text: String) {
        let url = projectURL.appendingPathComponent("manuscript/doc.md")
        try "Alpha paragraph.\n\nBeta paragraph."
            .write(to: url, atomically: true, encoding: .utf8)
        let doc = try await Document.load(
            url: url, device: "test-mac", session: "s1", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
        doc.setParagraph(id: doc.sequence[0], text: "Alpha, cached state.")
        try await doc.flushBurstNow()
        let text = doc.displayText
        await doc.close()
        return (url, doc.docId, text)
    }

    private func cacheURL(_ docId: String) -> URL {
        DeriveCache.cacheURL(forDocId: docId, in: projectURL)
    }

    // T16 — deleting the cache changes nothing (pure cache, never truth).
    func test_deleteCache_rederivesIdentical() async throws {
        let (url, docId, text) = try await makeAndCloseDoc()
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL(docId).path),
                      "close() must write the cache")
        let cached = try await Document.load(
            url: url, device: "test-mac", session: "s2", presenter: nil)
        let cachedText = cached.displayText
        await cached.close()

        try FileManager.default.removeItem(at: cacheURL(docId))
        let fresh = try await Document.load(
            url: url, device: "test-mac", session: "s3", presenter: nil)
        XCTAssertEqual(fresh.displayText, cachedText)
        XCTAssertEqual(fresh.displayText, text)
        await fresh.close()
    }

    // T17 — a stale/corrupt cache never wins.
    func test_staleCache_neverWins() async throws {
        let (url, docId, text) = try await makeAndCloseDoc()
        // Poison the content but keep the file: the key check must reject it.
        var snapshot = try JSONDecoder().decode(
            DeriveCache.Snapshot.self, from: Data(contentsOf: cacheURL(docId)))
        snapshot = DeriveCache.Snapshot(
            key: snapshot.key, schemaRev: snapshot.schemaRev,
            paragraphs: ["zzzz": "POISON"], sequence: ["zzzz"])
        // Then append a new op so the real key moves on.
        let doc = try await Document.load(
            url: url, device: "test-mac", session: "s2", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
        doc.setParagraph(id: doc.sequence[0], text: "Alpha, newer than cache.")
        try await doc.flushBurstNow()
        await doc.close()
        try JSONEncoder().encode(snapshot).write(to: cacheURL(docId))

        let reloaded = try await Document.load(
            url: url, device: "test-mac", session: "s3", presenter: nil)
        XCTAssertFalse(reloaded.displayText.contains("POISON"))
        XCTAssertTrue(reloaded.displayText.contains("Alpha, newer than cache."))
        _ = text
        await reloaded.close()
    }

    // T18 — integrity + rewind never read the cache.
    func test_integrityAndRewind_neverReadCache() async throws {
        let (url, docId, _) = try await makeAndCloseDoc()
        // Poison the cache with a MATCHING key (worst case).
        let raw = try Data(contentsOf: cacheURL(docId))
        var snapshot = try JSONDecoder().decode(DeriveCache.Snapshot.self, from: raw)
        snapshot = DeriveCache.Snapshot(
            key: snapshot.key, schemaRev: snapshot.schemaRev,
            paragraphs: ["zzzz": "POISON"], sequence: ["zzzz"])
        try JSONEncoder().encode(snapshot).write(to: cacheURL(docId))

        // Integrity: healthy report, untouched by the poisoned cache.
        let report = try await ProjectIntegrity.check(projectURL: projectURL)
        XCTAssertTrue(report.isHealthy)

        // Rewind derivation reads ops, not the cache.
        let ops = try await OpLogStore(projectURL: projectURL).load(docId: docId)
        let derived = Deriver.derive(
            ops: ops, upTo: .atOp(opId: ops.last!.opId, at: ops.last!.at))
        XCTAssertNil(derived.paragraphs["zzzz"])
        _ = url
    }
}
```

(Adjust `RewindCursor` spelling to the real enum.)

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/DeriveCacheTests`
Expected: FAIL to compile (`DeriveCache` doesn't exist).

- [ ] **Step 3: Implement `DeriveCache`**

```swift
// Maugham/OpLog/DeriveCache.swift
import Foundation
import CryptoKit
import MaughamCore

/// Pure, deletable snapshot of `Deriver.derive` output (ADR 0016 / growth
/// spec §6). NEVER truth: read at exactly ONE site (`Document.load`'s initial
/// derive); rewind, integrity, merge, materialize, and the phone never read
/// it. Key = SHA-256 over the sorted (filename, byteSize) pairs of every
/// op-log file for the doc — segments are immutable, the tail is append-only
/// (size moves on every append), and a seal changes the file set — plus a
/// format revision. Any miss/parse-fail/poison → full derive, then rewrite.
enum DeriveCache {

    static let schemaRev = 1

    struct Snapshot: Codable {
        let key: String
        let schemaRev: Int
        let paragraphs: [String: String]
        let sequence: [String]
    }

    static func cacheURL(forDocId docId: String, in projectURL: URL) -> URL {
        projectURL
            .appendingPathComponent(".maugham/cache/derived", isDirectory: true)
            .appendingPathComponent("\(docId).json")
    }

    /// Cache key over the doc's current op-log file set.
    static func key(forDocId docId: String, in projectURL: URL) -> String {
        let fm = FileManager.default
        let pairs = OpLogStore.opLogFileURLs(forDocId: docId, in: projectURL)
            .map { url -> String in
                let size = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
                return "\(url.lastPathComponent):\(size)"
            }
            .sorted()
            .joined(separator: "|")
        let digest = SHA256.hash(data: Data("v\(schemaRev)|\(pairs)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Returns the snapshot iff its key matches the CURRENT file set.
    static func read(forDocId docId: String, in projectURL: URL)
        -> Deriver.DerivedState?
    {
        let url = cacheURL(forDocId: docId, in: projectURL)
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.schemaRev == schemaRev,
              snapshot.key == key(forDocId: docId, in: projectURL) else {
            return nil
        }
        return Deriver.DerivedState(
            paragraphs: snapshot.paragraphs, sequence: snapshot.sequence)
    }

    /// Write-behind; a failed cache write is a non-event by design (`try?`).
    static func write(
        state: Deriver.DerivedState, forDocId docId: String, in projectURL: URL
    ) {
        let url = cacheURL(forDocId: docId, in: projectURL)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let snapshot = Snapshot(
            key: key(forDocId: docId, in: projectURL), schemaRev: schemaRev,
            paragraphs: state.paragraphs, sequence: state.sequence)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
```

Wire-up:
- `Document+Load.swift`: replace `let initial = Document.reconcile(derived: Deriver.derive(ops: ops), parsed: parsed)` with a cache-first read — `let derived = DeriveCache.read(forDocId: docId, in: projectURL) ?? Deriver.derive(ops: ops)`; after constructing `doc`, call `DeriveCache.write(state: Deriver.DerivedState(paragraphs: initial.paragraphs, sequence: initial.sequence), forDocId: docId, in: projectURL)`. **Important subtlety:** the cache must be bypassed whenever the load path appended a crash-recovery op (the file set just changed → key self-invalidates, but read happened earlier) — read the cache AFTER the crash-recovery block.
- `Document.close()`: after the seal step, `DeriveCache.write(state: .init(paragraphs: paragraphs, sequence: sequence), forDocId: docId, in: projectURL)` — note `Document` has no stored `projectURL`; derive it via `opStore.projectURL`.
- `handleExternalLogChange`: after `recomputeDisplayText()`, same write call.
- `MaughamSidecarPath`: add `case deriveCache(relativePath: String)` matched on prefix `.maugham/cache/` and route it as ignore in the presenter switch (find the switch over sidecar cases in `DocumentStore.presenterDidChangeSubitem` and add the no-op arm; also add it to the backup classification table as *Derived* — locate via `grep -rn "MaughamSidecarPath\." Maugham/Stores/`).

- [ ] **Step 4: Grep tripwire for the single read site**

Add to `TripwireGrepTests`:

```swift
    /// ADR 0016: the derive cache is read at exactly ONE site. Any other
    /// reference to the cache path is a "cache became truth" regression.
    func test_deriveCacheReadIsolatedToLoadPath() throws {
        let offenders = try grepSwift(
            in: sourceDir,
            patterns: ["cache/derived"],
            allowed: ["DeriveCache.swift", "Document+Load.swift",
                      "MaughamSidecarPath.swift"],
            excludeLine: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        )
        XCTAssertTrue(offenders.isEmpty,
            "The derive cache is NEVER truth (ADR 0016). Offenders:\n"
            + offenders.joined(separator: "\n"))
    }
```

- [ ] **Step 5: Run T16–T18 + both schemes**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/DeriveCacheTests` → PASS, then the full Mac scheme + phone scheme → PASS.

- [ ] **Step 6: Commit**

```bash
git add Maugham/OpLog/DeriveCache.swift Maugham/OpLog/Document+Load.swift Maugham/OpLog/Document+ExternalChange.swift Maugham/OpLog/Document.swift Maugham/Stores/ MaughamTests/
git commit -m "feat(oplog): M3 derive cache — pure deletable snapshot, single read site, never truth (T16–T18)"
```

### Task 14: M3 docs + load-budget verification

- [ ] **Step 1:** Fixture re-run (same command as Task 12 Step 1); `Document.load` must now be within the 150 ms budget. Append "## After M3" to the baseline note.
- [ ] **Step 2:** `Maugham/OpLog/AREA.md`: add the cache to the layout list with the "never truth, delete ad lib" contract. Roadmap: M3 status. The user smoke gains: delete `.maugham/cache/` while the app is closed → relaunch → no behavior change.
- [ ] **Step 3:** Commit: `git commit -m "docs: M3 exit — load within budget, cache contract in AREA.md"`.

---

## Completion

After the final milestone (M2 or M3): update `docs/roadmap.md` ADR 0016 item to its final state, ensure the M0 baseline note carries every re-run table, and hand to the user for the manual smoke + tag decision (per `docs/RELEASING.md`; version is tag-derived). Use superpowers:finishing-a-development-branch.
