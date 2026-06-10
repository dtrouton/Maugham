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

        // The canned specs live on `Spec` (not the enclosing enum) so they
        // resolve as contextual members of a `spec:` parameter — e.g.
        // `generate(spec: .smoke)`.

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
    }

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

        var docIds: [String] = []
        var tailBytesRewritten = 0
        var burstCount = 0

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
                    burstCount += 1
                    let size = ((try? fm.attributesOfItem(atPath: tailURL.path))?[.size] as? Int) ?? 0
                    tailBytesRewritten += size
                }
                await doc.close()
            }
        }
        return Result(projectURL: projectURL, docURLs: docURLs, docIds: docIds,
                      tailBytesRewritten: tailBytesRewritten,
                      burstCount: burstCount)
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
