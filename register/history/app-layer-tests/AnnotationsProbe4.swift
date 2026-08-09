import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class AnnotationsProbe4: XCTestCase {

    static let outURL = URL(fileURLWithPath: "/tmp/annotations-char/probe4-out.txt")
    func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
        let line = items.map { "\($0)" }.joined(separator: separator) + terminator
        let d = line.data(using: .utf8)!
        if let h = try? FileHandle(forWritingTo: Self.outURL) {
            h.seekToEndOfFile(); h.write(d); try? h.close()
        } else { try? d.write(to: Self.outURL) }
    }

    struct Harness { let doc: Document; let pid: String; let url: URL }
    func makeHarness(_ md: String) async throws -> Harness {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnProbe4-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        let rel = "manuscript/c1.md"
        try md.write(to: tmp.appendingPathComponent(rel), atomically: true, encoding: .utf8)
        let item = StructureItem(id: "doc-x", title: "C1", type: .document, path: rel)
        let manifest = ProjectManifest(type: .novel, title: "P4", author: "A", created: Date(),
                                       modified: Date(), structure: [item], research: [])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: tmp.appendingPathComponent("project.maugham.json"))
        let ds = try await DocumentStore.open(url: tmp)
        let doc = try await Document.load(url: tmp.appendingPathComponent(rel),
                                          device: "test", session: "s", presenter: nil)
        ds.register(document: doc, for: rel)
        let pid = try await doc.opLog().first { $0.kind == .bootstrap }!.changes.first!.paragraphId
        return Harness(doc: doc, pid: pid, url: tmp)
    }
    func one(_ d: Document, _ id: String) -> Annotation? {
        d.annotations(filter: AnnotationFilter(statuses: nil)).first { $0.id == id }
    }

    func test_probeV_lostAnchorAccept() async throws {
        let text = "She was very angry about the whole business."
        let h = try await makeHarness(text)
        let span = SpanAnchor(quote: "very angry", prefix: "She was ", suffix: " about the", posHint: 8)
        let s = try await h.doc.addReviewerAnnotation(
            kind: .suggestedChange, paragraphId: h.pid, span: span, body: "tighter",
            suggestedText: "furious", authorName: "D")
        let a0 = one(h.doc, s)!
        print("V: at creation stale=\(a0.isStale) resolved=\(String(describing: a0.resolvedSpanRange)) before=\(String(describing: SuggestionDisplay.before(for: a0))) after=\(a0.suggestedText ?? "-")")

        // The writer rewrites the sentence so the quoted phrase is gone.
        h.doc.setParagraph(id: h.pid, text: "She was livid about the whole business.")
        let a1 = one(h.doc, s)!
        print("V: immediately after the edit (no burst yet) stale=\(a1.isStale) resolved=\(String(describing: a1.resolvedSpanRange))")
        h.doc.invalidateAnnotationsCache()
        let a2 = one(h.doc, s)!
        print("V: after the cache catches up stale=\(a2.isStale) resolved=\(String(describing: a2.resolvedSpanRange)) before=\(String(describing: SuggestionDisplay.before(for: a2)))")

        try await h.doc.acceptAnnotation(id: s)
        print("V: paragraph AFTER accept = \"\(h.doc.paragraphs[h.pid] ?? "-")\"")
        print("V: (the writer's sentence was \"She was livid about the whole business.\")")

        // Control: the same accept while the span STILL resolves
        let h2 = try await makeHarness(text)
        let s2 = try await h2.doc.addReviewerAnnotation(
            kind: .suggestedChange, paragraphId: h2.pid, span: span, body: "t",
            suggestedText: "furious", authorName: "D")
        try await h2.doc.acceptAnnotation(id: s2)
        print("V: control (span resolves) -> \"\(h2.doc.paragraphs[h2.pid] ?? "-")\"")

        // And the paragraph-level (no span) stale accept
        let h3 = try await makeHarness(text)
        let s3 = try await h3.doc.addAnnotation(
            kind: .suggestedChange, paragraphId: h3.pid, body: "t",
            suggestedText: "She was furious about the whole business.")
        h3.doc.setParagraph(id: h3.pid, text: "Rewritten entirely by the author.")
        h3.doc.invalidateAnnotationsCache()
        print("V: paragraph-level stale=\(one(h3.doc, s3)!.isStale)")
        try await h3.doc.acceptAnnotation(id: s3)
        print("V: paragraph-level stale accept -> \"\(h3.doc.paragraphs[h3.pid] ?? "-")\"")
    }
}
