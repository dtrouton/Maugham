import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class AnnotationsProbe5: XCTestCase {
    static let outURL = URL(fileURLWithPath: "/tmp/annotations-char/probe5-out.txt")
    func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
        let line = items.map { "\($0)" }.joined(separator: separator) + terminator
        let d = line.data(using: .utf8)!
        if let h = try? FileHandle(forWritingTo: Self.outURL) { h.seekToEndOfFile(); h.write(d); try? h.close() }
        else { try? d.write(to: Self.outURL) }
    }
    struct Harness { let doc: Document; let pid: String }
    func makeHarness(_ md: String) async throws -> Harness {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("AnnProbe5-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        let rel = "manuscript/c1.md"
        try md.write(to: tmp.appendingPathComponent(rel), atomically: true, encoding: .utf8)
        let item = StructureItem(id: "doc-x", title: "C1", type: .document, path: rel)
        let m = ProjectManifest(type: .novel, title: "P5", author: "A", created: Date(), modified: Date(), structure: [item], research: [])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(m).write(to: tmp.appendingPathComponent("project.maugham.json"))
        let ds = try await DocumentStore.open(url: tmp)
        let doc = try await Document.load(url: tmp.appendingPathComponent(rel), device: "test", session: "s", presenter: nil)
        ds.register(document: doc, for: rel)
        let pid = try await doc.opLog().first { $0.kind == .bootstrap }!.changes.first!.paragraphId
        return Harness(doc: doc, pid: pid)
    }
    func one(_ d: Document, _ id: String) -> Annotation? {
        d.annotations(filter: AnnotationFilter(statuses: nil)).first { $0.id == id }
    }

    /// Mirrors the pane: the annotations are READ (cache warm) before the
    /// writer types, exactly as a rendered AnnotationsPane does.
    func test_probeW_warmCacheAcrossATypingEdit() async throws {
        let h = try await makeHarness("She was very angry about the whole business.")
        let span = SpanAnchor(quote: "very angry", prefix: "She was ", suffix: " about the", posHint: 8)
        let s = try await h.doc.addReviewerAnnotation(
            kind: .suggestedChange, paragraphId: h.pid, span: span, body: "t",
            suggestedText: "furious", authorName: "D")
        print("W: pane renders -> stale=\(one(h.doc, s)!.isStale)")   // warms the cache
        h.doc.setFullText("She was livid about the whole business.\n")
        print("W: writer types (setFullText); pane re-renders -> stale=\(one(h.doc, s)!.isStale)")
        print("W: live paragraph = \"\(h.doc.paragraphs[h.pid] ?? "-")\"")
        print("W: SuggestionDisplay before -> \(String(describing: SuggestionDisplay.before(for: one(h.doc, s)!))) after -> \(one(h.doc, s)!.suggestedText ?? "-")")
        try await h.doc.acceptAnnotation(id: s)
        print("W: accept in that window -> \"\(h.doc.paragraphs[h.pid] ?? "-")\"")

        // Same, but with a burst boundary in between
        let h2 = try await makeHarness("She was very angry about the whole business.")
        let s2 = try await h2.doc.addReviewerAnnotation(
            kind: .suggestedChange, paragraphId: h2.pid, span: span, body: "t",
            suggestedText: "furious", authorName: "D")
        _ = one(h2.doc, s2)!.isStale
        h2.doc.setFullText("She was livid about the whole business.\n")
        try await h2.doc.flushBurstNow()
        print("W: after a burst flush stale=\(one(h2.doc, s2)!.isStale)")
    }
}
