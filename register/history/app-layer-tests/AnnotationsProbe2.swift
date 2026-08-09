import XCTest
import MaughamCore
@testable import Maugham

/// PROBE round 2 — the threads round 1 opened.
@MainActor
final class AnnotationsProbe2: XCTestCase {

    static let outURL = URL(fileURLWithPath: "/tmp/annotations-char/probe2-out.txt")
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
            .appendingPathComponent("AnnProbe2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        let relativePath = "manuscript/c1.md"
        try initialMd.write(to: tmp.appendingPathComponent(relativePath),
                            atomically: true, encoding: .utf8)
        let item = StructureItem(id: "doc-x", title: "Chapter 1", type: .document, path: relativePath)
        let manifest = ProjectManifest(type: .novel, title: "Ann Probe2", author: "A",
                                       created: Date(), modified: Date(),
                                       structure: [item], research: [])
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

    // N. staleness invalidation timing
    func test_probeN_staleTiming() async throws {
        let h = try await makeHarness("Alpha.")
        let cid = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "c")
        print("N: fresh stale=\(one(h.doc, cid)!.isStale)")
        h.doc.setParagraph(id: h.pid, text: "Alpha changed.")
        print("N: after setParagraph, paragraphs=\(h.doc.paragraphs[h.pid] ?? "-") stale=\(one(h.doc, cid)!.isStale)")
        h.doc.invalidateAnnotationsCache()
        print("N: after explicit cache invalidation stale=\(one(h.doc, cid)!.isStale)")
        h.doc.setParagraph(id: h.pid, text: "Alpha.")
        h.doc.invalidateAnnotationsCache()
        print("N: after restoring the original text stale=\(one(h.doc, cid)!.isStale)")
        h.doc.setParagraph(id: h.pid, text: "Alpha again.")
        try await h.doc.flushBurstNow()
        print("N: after flushBurstNow stale=\(one(h.doc, cid)!.isStale)")
        // setFullText path
        let h2 = try await makeHarness("Alpha.")
        let c2 = try await h2.doc.addAnnotation(kind: .comment, paragraphId: h2.pid, body: "c")
        h2.doc.setFullText("Alpha edited.\n")
        print("N: setFullText -> stale=\(one(h2.doc, c2)!.isStale) para=\(h2.doc.paragraphs[h2.pid] ?? "-")")
    }

    // O. empty suggestion
    func test_probeO_emptySuggestion() async throws {
        let h = try await makeHarness("Alpha.")
        let s = try await h.doc.addAnnotation(kind: .suggestedChange, paragraphId: h.pid, body: "delete this", suggestedText: nil)
        print("O: derived sugg=\(String(describing: one(h.doc, s)?.suggestedText))")
        try await h.doc.acceptAnnotation(id: s)
        print("O: after accept of an EMPTY suggestion paragraph=\"\(h.doc.paragraphs[h.pid] ?? "-")\" sequence=\(h.doc.sequence)")
        print("O: materialize=\"\(h.doc.materialize())\"")
        // and with an explicit empty string
        let h2 = try await makeHarness("Beta.")
        let s2 = try await h2.doc.addAnnotation(kind: .suggestedChange, paragraphId: h2.pid, body: "b", suggestedText: "")
        try await h2.doc.acceptAnnotation(id: s2)
        print("O: explicit \"\" accept -> \"\(h2.doc.paragraphs[h2.pid] ?? "-")\"")
        // span-scoped empty suggestion (deletion of a phrase)
        let h3 = try await makeHarness("The quick brown fox.")
        let span = SpanAnchor(quote: "quick ", prefix: "The ", suffix: "brown", posHint: 4)
        let s3 = try await h3.doc.addReviewerAnnotation(kind: .suggestedChange, paragraphId: h3.pid, span: span, body: "cut", suggestedText: "", authorName: "D")
        try await h3.doc.acceptAnnotation(id: s3)
        print("O: span-scoped empty accept -> \"\(h3.doc.paragraphs[h3.pid] ?? "-")\"")
    }

    // P. closed-doc guards across the mutation surface
    func test_probeP_closedDoc() async throws {
        let h = try await makeHarness("Alpha.")
        let cid = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "c")
        try await h.doc.close()
        print("P: after close mirror=\(h.doc.opLogSnapshot.count) isClosed=\(h.doc.isClosed)")
        func delta(_ label: String, _ body: () async throws -> Void) async {
            let before = h.doc.opLogSnapshot.count
            do { try await body() } catch { print("P: \(label) threw \(type(of: error))"); return }
            print("P: \(label) appended \(h.doc.opLogSnapshot.count - before) op(s)")
        }
        await delta("addAnnotation(craftNote)") { _ = try await h.doc.addAnnotation(kind: .craftNote, paragraphId: nil, body: "x") }
        await delta("addAnnotation(comment)") { _ = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "x") }
        await delta("archiveAnnotation") { try await h.doc.archiveAnnotation(id: cid) }
        await delta("rejectAnnotation") { try await h.doc.rejectAnnotation(id: cid) }
        await delta("withdrawReviewerAnnotation") { try await h.doc.withdrawReviewerAnnotation(id: cid, authorName: "D") }
        await delta("editReviewerAnnotation") { try await h.doc.editReviewerAnnotation(id: cid, newBody: "x", newSuggestedText: nil, authorName: "D") }
        await delta("reopenAnnotation") { try await h.doc.reopenAnnotation(id: cid) }
        await delta("acceptAnnotation") { try await h.doc.acceptAnnotation(id: cid) }
        print("P: annotations visible on a closed doc = \(all(h.doc).count)")
        // do those ops reach DISK?
        let store = OpLogStore(projectURL: h.url)
        let onDisk = try await store.load(docId: h.doc.docId)
        print("P: on-disk op count=\(onDisk.count) kinds=\(onDisk.map { $0.kind.rawValue })")
    }

    // Q. the unsorted-mirror consequence, sharpened
    func test_probeQ_unsortedMirrorConsequence() async throws {
        let h = try await makeHarness("One.")
        // a peer op with a max-timestamp ULID that CHANGES the manuscript
        let futureId = "ZZZZZZZZZZ0000000000000000"
        let peer = Op(opId: futureId, docId: h.doc.docId, at: Date(),
                      device: "peer", session: "p", kind: .typingBurst,
                      changes: [.init(paragraphId: h.pid, prior: "One.", next: "PEER TEXT.")],
                      sequence: [h.pid], provenance: nil)
        let store = OpLogStore(projectURL: h.url)
        try await store.append(peer)
        try await h.doc.handleExternalLogChange()
        print("Q: after merge text=\(h.doc.paragraphs[h.pid] ?? "-")")
        // now a LOCAL edit, which lands with a SMALLER opId
        h.doc.setParagraph(id: h.pid, text: "LOCAL TEXT.")
        try await h.doc.flushBurstNow()
        let mirror = h.doc.opLogSnapshot
        func sorted(_ o: [Op]) -> Bool { zip(o, o.dropFirst()).allSatisfy { $0.opId < $1.opId } }
        print("Q: mirror sorted=\(sorted(mirror)) count=\(mirror.count)")
        print("Q: live paragraphs=\(h.doc.paragraphs[h.pid] ?? "-")")
        print("Q: Deriver.derive(mirror) [self-sorting] = \(Deriver.derive(ops: mirror).paragraphs[h.pid] ?? "-")")
        let localOpId = mirror.last!.opId
        let liveUpTo = Deriver.derive(ops: mirror, upTo: .atOp(opId: localOpId, at: Date()))
        let sortedUpTo = Deriver.derive(ops: mirror.sorted { $0.opId < $1.opId }, upTo: .atOp(opId: localOpId, at: Date()))
        print("Q: derive(upTo: localTip) over LIVE mirror   = \(liveUpTo.paragraphs[h.pid] ?? "-")")
        print("Q: derive(upTo: localTip) over SORTED mirror = \(sortedUpTo.paragraphs[h.pid] ?? "-")")
        print("Q: currentFoldBasis == newest opId? \(h.doc.currentFoldBasis == mirror.map(\.opId).max()!)")
        // Does an annotation added AFTER this resolve correctly?
        let cid = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "post")
        try await h.doc.archiveAnnotation(id: cid)
        print("Q: annotation added after the inversion -> \(String(describing: one(h.doc, cid)?.status))")
    }

    // R. AnnotationDeriver order-independence + latest-wins edges (pure)
    func test_probeR_deriverPure() {
        func op(_ id: String, _ kind: OpKind, src: String? = nil, body: String? = nil,
                pid: String? = nil, next: String? = nil, prior: String? = nil) -> Op {
            Op(opId: id, docId: "d", at: Date(timeIntervalSince1970: 0),
               device: "x", session: "s", kind: kind,
               changes: pid.map { [.init(paragraphId: $0, prior: prior, next: next ?? "")] } ?? [],
               sequence: nil,
               provenance: Op.Provenance(sessionId: "s", annotationBody: body, sourceAnnotationId: src))
        }
        let creation = op("A", .claudeComment, body: "orig", pid: "aaaa", prior: "P")
        let paras = ["aaaa": "P"]
        // archive then reopen
        let ops1 = [creation, op("B", .claudeArchive, src: "A"), op("C", .annotationReopen, src: "A")]
        print("R: archive→reopen = \(AnnotationDeriver.derive(ops: ops1, paragraphs: paras).first!.status)")
        print("R: reversed input  = \(AnnotationDeriver.derive(ops: ops1.reversed(), paragraphs: paras).first!.status)")
        // reopen with a LOWER opId than the archive
        let ops2 = [creation, op("D", .claudeArchive, src: "A"), op("C", .annotationReopen, src: "A")]
        print("R: reopen(C) older than archive(D) = \(AnnotationDeriver.derive(ops: ops2, paragraphs: paras).first!.status)")
        // withdraw then reopen then withdraw
        let ops3 = [creation, op("B", .annotationWithdraw, src: "A"), op("C", .annotationReopen, src: "A"), op("D", .annotationWithdraw, src: "A")]
        print("R: w→r→w count=\(AnnotationDeriver.derive(ops: ops3, paragraphs: paras).count)")
        // a reopen is BOTH a lifecycle op and a withdraw-state op
        let ops4 = [creation, op("B", .claudeArchive, src: "A"), op("C", .annotationWithdraw, src: "A")]
        print("R: archive then withdraw count=\(AnnotationDeriver.derive(ops: ops4, paragraphs: paras).count)")
        let ops5 = [creation, op("B", .annotationWithdraw, src: "A"), op("C", .claudeArchive, src: "A")]
        print("R: withdraw then archive count=\(AnnotationDeriver.derive(ops: ops5, paragraphs: paras).count)")
        // reopen undoing a withdraw ALSO clears an older archive (single reopen kind)
        let ops6 = [creation, op("B", .claudeArchive, src: "A"), op("C", .annotationWithdraw, src: "A"), op("D", .annotationReopen, src: "A")]
        let r6 = AnnotationDeriver.derive(ops: ops6, paragraphs: paras)
        print("R: archive→withdraw→reopen count=\(r6.count) status=\(r6.first.map { "\($0.status)" } ?? "-")")
        // edits: latest by opId wins regardless of array order
        let ops7 = [creation, op("C", .annotationEdit, src: "A", body: "second"), op("B", .annotationEdit, src: "A", body: "first")]
        print("R: edit latest-wins body=\(AnnotationDeriver.derive(ops: ops7, paragraphs: paras).first!.body)")
        // lifecycle op with NO sourceAnnotationId
        let ops8 = [creation, op("B", .claudeArchive)]
        print("R: archive without sourceAnnotationId -> \(AnnotationDeriver.derive(ops: ops8, paragraphs: paras).first!.status)")
        // an edit whose sourceAnnotationId names a NON-creation op
        let ops9 = [creation, op("B", .annotationEdit, src: "NOPE", body: "ghost")]
        print("R: orphan edit -> count=\(AnnotationDeriver.derive(ops: ops9, paragraphs: paras).count) body=\(AnnotationDeriver.derive(ops: ops9, paragraphs: paras).first!.body)")
        // creation with NO annotationBody
        let ops10 = [op("A", .claudeComment, pid: "aaaa", prior: "P")]
        print("R: creation without a body -> body=\"\(AnnotationDeriver.derive(ops: ops10, paragraphs: paras).first!.body)\"")
        // paragraph missing from the map entirely
        print("R: paragraph absent from map -> stale=\(AnnotationDeriver.derive(ops: [creation], paragraphs: [:]).first!.isStale)")
        // craft note staleness
        let cn = op("A", .claudeCraftNote, body: "n")
        print("R: craftNote stale=\(AnnotationDeriver.derive(ops: [cn], paragraphs: [:]).first!.isStale) pid=\(String(describing: AnnotationDeriver.derive(ops: [cn], paragraphs: [:]).first!.paragraphId))")
        // accept-revert as the latest lifecycle
        let ops11 = [creation, op("B", .claudeAccept, src: "A"), op("C", .claudeAcceptRevert, src: "A")]
        print("R: accept→revert = \(AnnotationDeriver.derive(ops: ops11, paragraphs: paras).first!.status)")
    }

    // S. userResponse + resolvedAt provenance
    func test_probeS_userResponse() async throws {
        let h = try await makeHarness("Alpha.")
        let cid = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "c")
        try await h.doc.rejectAnnotation(id: cid, userResponse: "no thanks")
        let a = one(h.doc, cid)!
        print("S: rejected ur=\(a.userResponse ?? "-") resolvedAt=\(a.resolvedAt != nil)")
        try await h.doc.reopenAnnotation(id: cid)
        let b = one(h.doc, cid)!
        print("S: after reopen ur=\(b.userResponse ?? "nil") resolvedAt=\(b.resolvedAt != nil)")
        try await h.doc.archiveAnnotation(id: cid)
        print("S: archived ur=\(one(h.doc, cid)!.userResponse ?? "nil")")
    }

    // T. double-resolve / idempotency
    func test_probeT_doubleResolve() async throws {
        let h = try await makeHarness("Alpha.")
        let cid = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "c")
        try await h.doc.archiveAnnotation(id: cid)
        let before = h.doc.opLogSnapshot.count
        try await h.doc.archiveAnnotation(id: cid)
        print("T: second archive appended \(h.doc.opLogSnapshot.count - before) op(s), status=\(String(describing: one(h.doc, cid)?.status))")
        let b2 = h.doc.opLogSnapshot.count
        try await h.doc.rejectAnnotation(id: cid)
        print("T: reject an ARCHIVED annotation appended \(h.doc.opLogSnapshot.count - b2) op(s), status=\(String(describing: one(h.doc, cid)?.status))")
        let b3 = h.doc.opLogSnapshot.count
        try await h.doc.archiveAnnotation(id: "NOPE")
        print("T: archive an unknown id appended \(h.doc.opLogSnapshot.count - b3) op(s), annotations=\(all(h.doc).count)")
        // archive an op id that is a PARAGRAPH op
        let burstId = h.doc.opLogSnapshot.first { $0.kind == .bootstrap }!.opId
        let b4 = h.doc.opLogSnapshot.count
        try await h.doc.archiveAnnotation(id: burstId)
        print("T: archive a bootstrap op id appended \(h.doc.opLogSnapshot.count - b4) op(s), annotations=\(all(h.doc).count)")
    }
}
