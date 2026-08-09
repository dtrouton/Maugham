import XCTest
import MaughamCore
@testable import Maugham

@MainActor
final class AnnotationsProbe3: XCTestCase {

    static let outURL = URL(fileURLWithPath: "/tmp/annotations-char/probe3-out.txt")
    func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
        let line = items.map { "\($0)" }.joined(separator: separator) + terminator
        let d = line.data(using: .utf8)!
        if let h = try? FileHandle(forWritingTo: Self.outURL) {
            h.seekToEndOfFile(); h.write(d); try? h.close()
        } else { try? d.write(to: Self.outURL) }
    }

    struct Harness { let doc: Document; let pid: String; let url: URL }

    func makeHarness(_ initialMd: String = "One.") async throws -> Harness {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnProbe3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        let relativePath = "manuscript/c1.md"
        try initialMd.write(to: tmp.appendingPathComponent(relativePath), atomically: true, encoding: .utf8)
        let item = StructureItem(id: "doc-x", title: "Chapter 1", type: .document, path: relativePath)
        let manifest = ProjectManifest(type: .novel, title: "P3", author: "A", created: Date(),
                                       modified: Date(), structure: [item], research: [])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: tmp.appendingPathComponent("project.maugham.json"))
        let ds = try await DocumentStore.open(url: tmp)
        let doc = try await Document.load(url: tmp.appendingPathComponent(relativePath),
                                          device: "test", session: "s", presenter: nil)
        ds.register(document: doc, for: relativePath)
        let pid = try await doc.opLog().first { $0.kind == .bootstrap }!.changes.first!.paragraphId
        return Harness(doc: doc, pid: pid, url: tmp)
    }
    func all(_ d: Document) -> [Annotation] { d.annotations(filter: AnnotationFilter(statuses: nil)) }
    func one(_ d: Document, _ id: String) -> Annotation? { all(d).first { $0.id == id } }

    func test_probeU() async throws {
        // U1. archive → withdraw → reopen, through the live Document
        let h = try await makeHarness("Alpha.")
        let cid = try await h.doc.addReviewerAnnotation(
            kind: .comment, paragraphId: h.pid, span: nil, body: "c", authorName: "D")
        try await h.doc.archiveAnnotation(id: cid)
        print("U1: archived -> \(String(describing: one(h.doc, cid)?.status))")
        try await h.doc.withdrawReviewerAnnotation(id: cid, authorName: "D")
        print("U1: withdrawn -> present=\(one(h.doc, cid) != nil)")
        try await h.doc.reopenAnnotation(id: cid)
        print("U1: after reopen(undo of the withdraw) -> \(String(describing: one(h.doc, cid)?.status))")

        // U2. the pane's 'Got it' on an ARCHIVED comment
        let a2 = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "a2")
        try await h.doc.archiveAnnotation(id: a2)
        try await h.doc.acceptAnnotation(id: a2, userResponse: nil)
        print("U2: accept an ARCHIVED comment -> \(String(describing: one(h.doc, a2)?.status))")

        // U3. annotationsVersion bumps
        let v0 = h.doc.annotationsVersion
        _ = try await h.doc.addAnnotation(kind: .craftNote, paragraphId: nil, body: "n")
        let v1 = h.doc.annotationsVersion
        h.doc.setParagraph(id: h.pid, text: "Alpha two.")
        let v2 = h.doc.annotationsVersion
        print("U3: version add=\(v1 - v0) setParagraph=\(v2 - v1)")

        // U4. sticky flag rebuilt from a merged log
        let h2 = try await makeHarness("Beta.")
        print("U4: fresh doc hasAnyAnnotationOps=\(h2.doc._hasAnyAnnotationOps)")
        let peer = Op(opId: ULID.generate(), docId: h2.doc.docId, at: Date(), device: "peer",
                      session: "p", kind: .claudeComment,
                      changes: [.init(paragraphId: h2.pid, prior: "Beta.", next: "")], sequence: nil,
                      provenance: Op.Provenance(sessionId: "p", annotationBody: "peer note"))
        try await OpLogStore(projectURL: h2.url).append(peer)
        try await h2.doc.handleExternalLogChange()
        print("U4: after merge hasAnyAnnotationOps=\(h2.doc._hasAnyAnnotationOps) visible=\(all(h2.doc).map(\.body))")

        // U5. a suggestion created through the REVIEWER path with no text
        let h3 = try await makeHarness("Gamma.")
        let s = try await h3.doc.addReviewerAnnotation(
            kind: .suggestedChange, paragraphId: h3.pid, span: nil, body: "cut it",
            suggestedText: nil, authorName: "D")
        print("U5: reviewer suggestion w/o text sugg=\(String(describing: one(h3.doc, s)?.suggestedText))")
        try await h3.doc.acceptAnnotation(id: s)
        print("U5: after accept paragraph=\"\(h3.doc.paragraphs[h3.pid] ?? "-")\" displayText=\"\(h3.doc.displayText)\"")

        // U6. reject a WITHDRAWN annotation, then reopen — which wins?
        let h4 = try await makeHarness("Delta.")
        let w = try await h4.doc.addReviewerAnnotation(kind: .comment, paragraphId: h4.pid, span: nil, body: "w", authorName: "D")
        try await h4.doc.withdrawReviewerAnnotation(id: w, authorName: "D")
        try await h4.doc.rejectAnnotation(id: w, userResponse: "r")
        print("U6: reject while withdrawn -> present=\(one(h4.doc, w) != nil)")
        try await h4.doc.reopenAnnotation(id: w)
        print("U6: reopen after that -> \(String(describing: one(h4.doc, w)?.status))")
    }
}
