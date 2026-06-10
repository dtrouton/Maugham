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

        // Build the report string in pieces; the single big interpolated
        // literal trips the type-checker budget (CLAUDE.md: restructure,
        // don't suppress).
        let header = "===== M0 BASELINE — \(spec.label) ====="
        let counts = "docs: \(spec.docCount), bursts: \(result.burstCount), ops: \(allOps.count)"
        let seqPct = String(format: "%.1f",
            100.0 * Double(sequenceBytes) / Double(max(1, encodedBytesTotal)))
        var lines: [String] = []
        lines.append(header)
        lines.append(counts)
        lines.append("total op-log bytes on disk:      \(totalBytes)")
        lines.append("encoded op bytes (canonical):    \(encodedBytesTotal)")
        lines.append("sequence-attributable bytes:     \(sequenceBytes) (\(seqPct)% of encoded)")
        lines.append("tail bytes rewritten (sync churn proxy): \(result.tailBytesRewritten)")
        lines.append("Document.load (largest doc, min of 3):   \(loadTimes.min()!)")
        lines.append("Deriver.derive (full log, min of 5):     \(deriveTimes.min()!)")
        lines.append("compression probe (largest tail):")
        lines.append(compressionTable)
        lines.append("=======================================")
        print(lines.joined(separator: "\n"))
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
