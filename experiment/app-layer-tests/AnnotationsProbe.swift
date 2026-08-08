import XCTest
import MaughamCore
@testable import Maugham

/// PROBE — prints observed behaviour of Document+Annotations. Assertions are
/// written from this output, never from reading the code.
@MainActor
final class AnnotationsProbe: XCTestCase {

    struct Harness { let doc: Document; let pid: String; let url: URL }

    static let outURL = URL(fileURLWithPath: "/tmp/annotations-char/probe-out.txt")
    func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
        let line = items.map { "\($0)" }.joined(separator: separator) + terminator
        let d = line.data(using: .utf8)!
        if let h = try? FileHandle(forWritingTo: Self.outURL) {
            h.seekToEndOfFile(); h.write(d); try? h.close()
        } else {
            try? d.write(to: Self.outURL)
        }
    }

    func makeHarness(_ initialMd: String = "One.") async throws -> Harness {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnnProbe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        let relativePath = "manuscript/c1.md"
        try initialMd.write(to: tmp.appendingPathComponent(relativePath),
                            atomically: true, encoding: .utf8)
        let item = StructureItem(id: "doc-x", title: "Chapter 1", type: .document,
                                 path: relativePath)
        let manifest = ProjectManifest(type: .novel, title: "Ann Probe", author: "A",
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

    func all(_ doc: Document) -> [Annotation] {
        doc.annotations(filter: AnnotationFilter(statuses: nil))
    }
    func one(_ doc: Document, _ id: String) -> Annotation? {
        all(doc).first { $0.id == id }
    }
    func describe(_ a: Annotation?) -> String {
        guard let a else { return "nil" }
        return "kind=\(a.kind) status=\(a.status) pid=\(a.paragraphId ?? "-") body=\"\(a.body)\" sugg=\(a.suggestedText.map { "\"\($0)\"" } ?? "nil") stale=\(a.isStale) prior=\(a.priorText.map { "\"\($0)\"" } ?? "nil") ur=\(a.userResponse ?? "-") author=\(a.author?.sourceKind.rawValue ?? "-")/\(a.author?.displayName ?? "-")"
    }

    // MARK: - A. filter defaults + cache

    func test_probeA_filterDefaults() async throws {
        let h = try await makeHarness()
        let cid = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "c1")
        let craft = try await h.doc.addAnnotation(kind: .craftNote, paragraphId: nil, body: "cn")
        print("A: default filter count=\(h.doc.annotations().count)")
        print("A: default filter statuses=\(String(describing: AnnotationFilter().statuses))")
        try await h.doc.archiveAnnotation(id: cid)
        print("A: after archive, default filter count=\(h.doc.annotations().count) allcount=\(all(h.doc).count)")
        print("A: filter kinds=[craftNote] -> \(h.doc.annotations(filter: AnnotationFilter(kinds: [.craftNote], statuses: nil)).count)")
        print("A: filter paragraphId=pid all-statuses -> \(h.doc.annotations(filter: AnnotationFilter(statuses: nil, paragraphId: h.pid)).count)")
        print("A: craft annotation = \(describe(one(h.doc, craft)))")
    }

    // MARK: - B. addAnnotation validation + payload

    func test_probeB_addValidation() async throws {
        let h = try await makeHarness()
        // craft note WITH a paragraph id supplied
        let craft = try await h.doc.addAnnotation(kind: .craftNote, paragraphId: h.pid, body: "cn")
        print("B: craftNote given pid -> \(describe(one(h.doc, craft)))")
        let craftOp = h.doc.opLogSnapshot.first { $0.opId == craft }!
        print("B: craftNote op changes=\(craftOp.changes.count) kind=\(craftOp.kind)")

        // comment with nil pid
        do { _ = try await h.doc.addAnnotation(kind: .comment, paragraphId: nil, body: "x") }
        catch { print("B: comment nil pid throws \(error)") }
        // comment with unknown pid
        do { _ = try await h.doc.addAnnotation(kind: .comment, paragraphId: "zzzz", body: "x") }
        catch { print("B: comment unknown pid throws \(error)") }
        // query with nil pid
        do { _ = try await h.doc.addAnnotation(kind: .query, paragraphId: nil, body: "x") }
        catch { print("B: query nil pid throws \(error)") }
        // suggestion with nil pid
        do { _ = try await h.doc.addAnnotation(kind: .suggestedChange, paragraphId: nil, body: "x", suggestedText: "s") }
        catch { print("B: suggestion nil pid throws \(error)") }

        // payloads
        let cid = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "c")
        let cop = h.doc.opLogSnapshot.first { $0.opId == cid }!
        print("B: comment op changes=\(cop.changes.map { "pid=\($0.paragraphId) prior=\($0.prior ?? "nil") next=\($0.next ?? "nil")" })")
        let sid = try await h.doc.addAnnotation(kind: .suggestedChange, paragraphId: h.pid, body: "s", suggestedText: "Two.")
        let sop = h.doc.opLogSnapshot.first { $0.opId == sid }!
        print("B: suggestion op changes=\(sop.changes.map { "pid=\($0.paragraphId) prior=\($0.prior ?? "nil") next=\($0.next ?? "nil")" })")
        print("B: suggestion derived = \(describe(one(h.doc, sid)))")
        // suggestion with NO suggestedText
        let s2 = try await h.doc.addAnnotation(kind: .suggestedChange, paragraphId: h.pid, body: "s2")
        print("B: suggestion w/o text = \(describe(one(h.doc, s2)))")
        // empty body
        let e = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "")
        print("B: empty body = \(describe(one(h.doc, e)))")
        print("B: sequence=\(h.doc.sequence) hasAnyAnnotationOps=\(h.doc.opLogSnapshot.contains { Document.isAnnotationOpKind($0.kind) })")
    }

    // MARK: - C. reviewer + span

    func test_probeC_reviewer() async throws {
        let h = try await makeHarness("The quick brown fox.")
        let span = SpanAnchor(quote: "quick", prefix: "The ", suffix: " brown", posHint: 4)
        let id = try await h.doc.addReviewerAnnotation(
            kind: .comment, paragraphId: h.pid, span: span, body: "b", authorName: "Denver", authorId: "d1")
        let a = one(h.doc, id)!
        print("C: \(describe(a)) span=\(String(describing: a.span?.quote)) resolved=\(String(describing: a.resolvedSpanRange)) collab=\(a.author?.collaboratorId ?? "-")")
        // Claude-authored (no author)
        let id2 = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "b2")
        print("C: no-author -> author=\(String(describing: one(h.doc, id2)?.author))")
        // span that cannot resolve
        let bad = SpanAnchor(quote: "elephant", prefix: "", suffix: "", posHint: 0)
        let id3 = try await h.doc.addReviewerAnnotation(
            kind: .comment, paragraphId: h.pid, span: bad, body: "b3", authorName: "D")
        print("C: unresolvable span -> \(describe(one(h.doc, id3)))")
    }

    // MARK: - D. edit

    func test_probeD_edit() async throws {
        let h = try await makeHarness("Alpha.")
        let cid = try await h.doc.addReviewerAnnotation(
            kind: .comment, paragraphId: h.pid, span: nil, body: "orig", authorName: "D")
        try await h.doc.editReviewerAnnotation(id: cid, newBody: "edited", newSuggestedText: nil, authorName: "D")
        print("D: after edit -> \(describe(one(h.doc, cid)))")

        let sid = try await h.doc.addReviewerAnnotation(
            kind: .suggestedChange, paragraphId: h.pid, span: nil, body: "sb",
            suggestedText: "Beta.", authorName: "D")
        try await h.doc.editReviewerAnnotation(id: sid, newBody: "sb2", newSuggestedText: nil, authorName: "D")
        print("D: suggestion edit body only -> \(describe(one(h.doc, sid)))")
        try await h.doc.editReviewerAnnotation(id: sid, newBody: "sb3", newSuggestedText: "Gamma.", authorName: "D")
        print("D: suggestion edit with text -> \(describe(one(h.doc, sid)))")

        // edit an unknown id
        let before = h.doc.opLogSnapshot.count
        try await h.doc.editReviewerAnnotation(id: "NOPE", newBody: "ghost", newSuggestedText: nil, authorName: "D")
        print("D: edit unknown id appended \(h.doc.opLogSnapshot.count - before) op(s); annotation count=\(all(h.doc).count)")

        // edit an ARCHIVED annotation
        try await h.doc.archiveAnnotation(id: cid)
        try await h.doc.editReviewerAnnotation(id: cid, newBody: "edited-while-archived", newSuggestedText: nil, authorName: "D")
        print("D: edit archived -> \(describe(one(h.doc, cid)))")

        // edit a WITHDRAWN annotation
        let wid = try await h.doc.addReviewerAnnotation(kind: .comment, paragraphId: h.pid, span: nil, body: "w", authorName: "D")
        try await h.doc.withdrawReviewerAnnotation(id: wid, authorName: "D")
        try await h.doc.editReviewerAnnotation(id: wid, newBody: "w2", newSuggestedText: nil, authorName: "D")
        print("D: edit withdrawn -> present=\(one(h.doc, wid) != nil)")
        try await h.doc.reopenAnnotation(id: wid)
        print("D: reopened after edit-while-withdrawn -> \(describe(one(h.doc, wid)))")

        // edit author stamping on the op
        let editOps = h.doc.opLogSnapshot.filter { $0.kind == .annotationEdit }
        print("D: edit ops=\(editOps.count) authors=\(editOps.map { ($0.provenance?.authorSourceKind ?? "-") })")
    }

    // MARK: - E. withdraw

    func test_probeE_withdraw() async throws {
        let h = try await makeHarness("Alpha.")
        let cid = try await h.doc.addReviewerAnnotation(kind: .comment, paragraphId: h.pid, span: nil, body: "c", authorName: "D")
        try await h.doc.withdrawReviewerAnnotation(id: cid, authorName: "D")
        print("E: withdrawn present in all-statuses = \(one(h.doc, cid) != nil), count=\(all(h.doc).count)")
        print("E: withdraw op still in log = \(h.doc.opLogSnapshot.contains { $0.kind == .annotationWithdraw })")
        try await h.doc.reopenAnnotation(id: cid)
        print("E: after reopen -> \(describe(one(h.doc, cid)))")
        try await h.doc.withdrawReviewerAnnotation(id: cid, authorName: "D")
        print("E: re-withdrawn -> present=\(one(h.doc, cid) != nil)")

        // withdraw an ACCEPTED suggestion — does the applied text survive?
        let sid = try await h.doc.addReviewerAnnotation(kind: .suggestedChange, paragraphId: h.pid, span: nil, body: "s", suggestedText: "Beta.", authorName: "D")
        try await h.doc.acceptAnnotation(id: sid)
        print("E: after accept text=\(h.doc.paragraphs[h.pid] ?? "nil") status=\(String(describing: one(h.doc, sid)?.status))")
        try await h.doc.withdrawReviewerAnnotation(id: sid, authorName: "D")
        print("E: after withdraw of accepted: present=\(one(h.doc, sid) != nil) text=\(h.doc.paragraphs[h.pid] ?? "nil")")

        // withdraw unknown id
        let before = h.doc.opLogSnapshot.count
        try await h.doc.withdrawReviewerAnnotation(id: "NOPE", authorName: "D")
        print("E: withdraw unknown appended \(h.doc.opLogSnapshot.count - before) op(s)")
    }

    // MARK: - F. accept

    func test_probeF_accept() async throws {
        let h = try await makeHarness("The quick brown fox.")
        // unknown id
        let before = h.doc.opLogSnapshot.count
        try await h.doc.acceptAnnotation(id: "NOPE")
        print("F: accept unknown appended \(h.doc.opLogSnapshot.count - before) op(s)")

        // accept a comment
        let cid = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "c")
        try await h.doc.acceptAnnotation(id: cid, userResponse: "ok")
        print("F: accepted comment -> \(describe(one(h.doc, cid))) text=\(h.doc.paragraphs[h.pid] ?? "-")")

        // accept a craft note
        let nid = try await h.doc.addAnnotation(kind: .craftNote, paragraphId: nil, body: "n")
        try await h.doc.acceptAnnotation(id: nid)
        print("F: accepted craftNote -> \(describe(one(h.doc, nid)))")

        // span-scoped suggestion splice
        let span = SpanAnchor(quote: "quick", prefix: "The ", suffix: " brown", posHint: 4)
        let sid = try await h.doc.addReviewerAnnotation(kind: .suggestedChange, paragraphId: h.pid, span: span, body: "s", suggestedText: "slow", authorName: "D")
        try await h.doc.acceptAnnotation(id: sid)
        print("F: after span accept text=\(h.doc.paragraphs[h.pid] ?? "-") status=\(String(describing: one(h.doc, sid)?.status))")

        // accept a REJECTED annotation (no status guard?)
        let rid = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "r")
        try await h.doc.rejectAnnotation(id: rid)
        print("F: rejected -> \(String(describing: one(h.doc, rid)?.status))")
        try await h.doc.acceptAnnotation(id: rid)
        print("F: accept after reject -> \(String(describing: one(h.doc, rid)?.status))")

        // accept a WITHDRAWN annotation
        let wid = try await h.doc.addReviewerAnnotation(kind: .suggestedChange, paragraphId: h.pid, span: nil, body: "w", suggestedText: "REPLACED.", authorName: "D")
        try await h.doc.withdrawReviewerAnnotation(id: wid, authorName: "D")
        let textBefore = h.doc.paragraphs[h.pid] ?? "-"
        try await h.doc.acceptAnnotation(id: wid)
        print("F: accept WITHDRAWN suggestion: present=\(one(h.doc, wid) != nil) textBefore=\(textBefore) textAfter=\(h.doc.paragraphs[h.pid] ?? "-")")

        // accept twice
        let tid = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "t")
        try await h.doc.acceptAnnotation(id: tid, userResponse: "first")
        try await h.doc.acceptAnnotation(id: tid, userResponse: "second")
        print("F: double accept -> \(describe(one(h.doc, tid)))")

        // accept a lifecycle op id (non-creation)
        let lifecycleId = h.doc.opLogSnapshot.first { $0.kind == .claudeAccept }!.opId
        let b2 = h.doc.opLogSnapshot.count
        try await h.doc.acceptAnnotation(id: lifecycleId)
        print("F: accept a lifecycle-op id appended \(h.doc.opLogSnapshot.count - b2) op(s)")
    }

    // MARK: - G. drift + revert

    func test_probeG_revert() async throws {
        let h = try await makeHarness("Alpha.")
        let sid = try await h.doc.addAnnotation(kind: .suggestedChange, paragraphId: h.pid, body: "s", suggestedText: "Beta.")
        print("G: drift before accept = \(h.doc.acceptedTextDrifted(annotationId: sid))")
        try await h.doc.acceptAnnotation(id: sid, userResponse: "yes")
        print("G: drift after accept = \(h.doc.acceptedTextDrifted(annotationId: sid)) text=\(h.doc.paragraphs[h.pid] ?? "-")")
        h.doc.setParagraph(id: h.pid, text: "Gamma.")
        print("G: drift after edit = \(h.doc.acceptedTextDrifted(annotationId: sid))")
        try await h.doc.revertAcceptedAnnotation(id: sid)
        print("G: after revert text=\(h.doc.paragraphs[h.pid] ?? "-") status=\(String(describing: one(h.doc, sid)?.status)) ur=\(String(describing: one(h.doc, sid)?.userResponse))")

        // revert an open comment (not a suggestion)
        let cid = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "c")
        let b = h.doc.opLogSnapshot.count
        try await h.doc.revertAcceptedAnnotation(id: cid)
        print("G: revert a comment appended \(h.doc.opLogSnapshot.count - b) op(s)")
        // revert a non-accepted suggestion
        let s2 = try await h.doc.addAnnotation(kind: .suggestedChange, paragraphId: h.pid, body: "s2", suggestedText: "Delta.")
        let b2 = h.doc.opLogSnapshot.count
        try await h.doc.revertAcceptedAnnotation(id: s2)
        print("G: revert a non-accepted suggestion appended \(h.doc.opLogSnapshot.count - b2) op(s)")
        print("G: drift for unknown id = \(h.doc.acceptedTextDrifted(annotationId: "NOPE"))")
    }

    // MARK: - H. reopen surface

    func test_probeH_reopen() async throws {
        let h = try await makeHarness("Alpha.")
        // open -> reopen
        let o = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "o")
        var b = h.doc.opLogSnapshot.count
        try await h.doc.reopenAnnotation(id: o)
        print("H: reopen an OPEN annotation appended \(h.doc.opLogSnapshot.count - b) op(s), status=\(String(describing: one(h.doc, o)?.status))")

        // accepted -> reopen
        let s = try await h.doc.addAnnotation(kind: .suggestedChange, paragraphId: h.pid, body: "s", suggestedText: "Beta.")
        try await h.doc.acceptAnnotation(id: s)
        b = h.doc.opLogSnapshot.count
        try await h.doc.reopenAnnotation(id: s)
        print("H: reopen an ACCEPTED annotation appended \(h.doc.opLogSnapshot.count - b) op(s), status=\(String(describing: one(h.doc, s)?.status)), text=\(h.doc.paragraphs[h.pid] ?? "-")")

        // rejected -> reopen
        let r = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "r")
        try await h.doc.rejectAnnotation(id: r, userResponse: "no")
        b = h.doc.opLogSnapshot.count
        try await h.doc.reopenAnnotation(id: r)
        print("H: reopen REJECTED appended \(h.doc.opLogSnapshot.count - b) op(s), -> \(describe(one(h.doc, r)))")

        // archived -> reopen
        let a = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "a")
        try await h.doc.archiveAnnotation(id: a)
        try await h.doc.reopenAnnotation(id: a)
        print("H: reopen ARCHIVED -> \(describe(one(h.doc, a)))")

        // unknown id
        b = h.doc.opLogSnapshot.count
        try await h.doc.reopenAnnotation(id: "NOPE")
        print("H: reopen unknown appended \(h.doc.opLogSnapshot.count - b) op(s)")

        // withdrawn
        let w = try await h.doc.addReviewerAnnotation(kind: .comment, paragraphId: h.pid, span: nil, body: "w", authorName: "D")
        try await h.doc.withdrawReviewerAnnotation(id: w, authorName: "D")
        try await h.doc.reopenAnnotation(id: w)
        print("H: reopen WITHDRAWN -> \(describe(one(h.doc, w)))")
        // reopen twice
        b = h.doc.opLogSnapshot.count
        try await h.doc.reopenAnnotation(id: w)
        print("H: reopen again appended \(h.doc.opLogSnapshot.count - b) op(s)")

        // reopen op provenance
        let reopens = h.doc.opLogSnapshot.filter { $0.kind == .annotationReopen }
        print("H: reopen ops=\(reopens.count) synthesis=\(reopens.map { String(describing: $0.provenance?.synthesisSource) })")

        // husked doc
        try await h.doc.close()
        b = h.doc.opLogSnapshot.count
        try await h.doc.reopenAnnotation(id: a)
        print("H: reopen on closed doc appended \(h.doc.opLogSnapshot.count - b) op(s), mirror=\(h.doc.opLogSnapshot.count)")
    }

    // MARK: - I. AnnotationInverse direct

    func test_probeI_inverse() {
        for k in [OpKind.claudeReject, .claudeArchive, .annotationWithdraw, .claudeAccept, .claudeComment, .annotationEdit] {
            for st in [AnnotationStatus?.none, .open, .accepted, .rejected, .archived] {
                let out = AnnotationInverse.reopenOp(
                    undoing: k, annotationId: "x", currentStatus: st,
                    docId: "d", device: "dev", session: "s")
                let desc: String
                switch out {
                case .op(let o): desc = "op(\(o.kind))"
                case .declined(let d): desc = "declined(\(d))"
                }
                print("I: undoing=\(k) current=\(String(describing: st)) -> \(desc)")
            }
        }
    }

    // MARK: - J. sweep

    func test_probeJ_sweep() async throws {
        let h = try await makeHarness("One.")
        h.doc.setFullText("One.\n\nTwo.\n"); try await h.doc.flushBurstNow()
        let burst = h.doc.opLogSnapshot.last { $0.kind == .typingBurst }!
        let pid2 = burst.changes.first { ($0.next ?? "").contains("Two") }!.paragraphId

        let openC = try await h.doc.addAnnotation(kind: .comment, paragraphId: pid2, body: "open")
        let accC = try await h.doc.addAnnotation(kind: .suggestedChange, paragraphId: pid2, body: "acc", suggestedText: "Two!")
        try await h.doc.acceptAnnotation(id: accC)
        let rejC = try await h.doc.addAnnotation(kind: .comment, paragraphId: pid2, body: "rej")
        try await h.doc.rejectAnnotation(id: rejC)
        let arcC = try await h.doc.addAnnotation(kind: .comment, paragraphId: pid2, body: "arc")
        try await h.doc.archiveAnnotation(id: arcC)
        let craft = try await h.doc.addAnnotation(kind: .craftNote, paragraphId: nil, body: "craft")
        let survivor = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "survivor")

        await h.doc.sweepOrphanedAnnotations(reason: SweepReason.externalLog(removed: [pid2])!)
        for (label, id) in [("open", openC), ("accepted", accC), ("rejected", rejC), ("archived", arcC), ("craft", craft), ("survivor", survivor)] {
            print("J: \(label) -> \(String(describing: one(h.doc, id)?.status))")
        }
        let arch = h.doc.opLogSnapshot.filter { $0.kind == .claudeArchive && $0.provenance?.synthesisSource != nil }
        print("J: synthesised archives=\(arch.count) sources=\(arch.map { String(describing: $0.provenance?.synthesisSource) })")

        // SweepReason factories
        print("J: externalLog(removed: []) -> \(String(describing: SweepReason.externalLog(removed: [])))")
        print("J: causes: \(String(describing: SweepReason.externalLog(removed: ["a"])?.cause))")

        // craft note carve-out: can a craft note ever carry a paragraphId?
        print("J: craft paragraphId=\(String(describing: one(h.doc, craft)?.paragraphId))")

        // sweep with a removed set naming a paragraph that still exists
        let b = h.doc.opLogSnapshot.count
        await h.doc.sweepOrphanedAnnotations(reason: SweepReason.externalLog(removed: [h.pid])!)
        print("J: sweep on a LIVE paragraph appended \(h.doc.opLogSnapshot.count - b) op(s); survivor=\(String(describing: one(h.doc, survivor)?.status))")

        // flagSweep merging
        h.doc.flagSweep(SweepReason.externalLog(removed: ["a"])!)
        h.doc.flagSweep(SweepReason.externalLog(removed: ["b"])!)
        print("J: merged pending sweep = \(String(describing: h.doc._pendingSweep?.removed.sorted()))")
    }

    // MARK: - K. staleness + ordering

    func test_probeK_staleAndOrder() async throws {
        let h = try await makeHarness("Alpha.")
        let cid = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "c")
        print("K: fresh stale=\(one(h.doc, cid)!.isStale) prior=\(one(h.doc, cid)!.priorText ?? "-")")
        h.doc.setParagraph(id: h.pid, text: "Alpha changed.")
        print("K: after paragraph edit stale=\(one(h.doc, cid)!.isStale)")
        h.doc.setParagraph(id: h.pid, text: "Alpha.")
        print("K: after restoring the text stale=\(one(h.doc, cid)!.isStale)")

        let a = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "first")
        let b = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "second")
        let bodies = all(h.doc).map { $0.body }
        print("K: order=\(bodies) (a=\(a.suffix(4)) b=\(b.suffix(4)))")

        // language tag on a query
        let q = try await h.doc.addAnnotation(kind: .query, paragraphId: h.pid, body: "q", toolArgs: "{\"language\":\"fr\"}")
        print("K: query language=\(String(describing: one(h.doc, q)?.language))")
        let q2 = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "q2", toolArgs: "{\"language\":\"fr\"}")
        print("K: comment with language toolArgs -> \(String(describing: one(h.doc, q2)?.language))")
        let q3 = try await h.doc.addAnnotation(kind: .query, paragraphId: h.pid, body: "q3", toolArgs: "not json")
        print("K: query malformed toolArgs -> \(String(describing: one(h.doc, q3)?.language))")
    }

    // MARK: - L. the mirror-ordering thread

    func test_probeL_mirrorOrder() async throws {
        let h = try await makeHarness("Alpha.")
        _ = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "c1")
        func sorted(_ ops: [Op]) -> Bool { zip(ops, ops.dropFirst()).allSatisfy { $0.opId < $1.opId } }
        print("L: mirror sorted after local appends = \(sorted(h.doc.opLogSnapshot))")

        // Inject a peer op with a FUTURE ULID directly into the on-disk log,
        // then merge it in and append locally afterwards.
        let futureId = "ZZZZZZZZZZ0000000000000000"  // max-timestamp ULID: sorts after everything
        let peer = Op(opId: futureId, docId: h.doc.docId, at: Date(),
                      device: "peer", session: "p", kind: .claudeComment,
                      changes: [.init(paragraphId: h.pid, prior: "Alpha.", next: "")],
                      sequence: nil,
                      provenance: Op.Provenance(sessionId: "p", annotationBody: "from-peer"))
        let store = OpLogStore(projectURL: h.url)
        try await store.append(peer)
        try await h.doc.handleExternalLogChange()
        print("L: after merge, mirror sorted = \(sorted(h.doc.opLogSnapshot)) count=\(h.doc.opLogSnapshot.count) last=\(h.doc.opLogSnapshot.last!.kind)")
        print("L: peer annotation visible = \(all(h.doc).contains { $0.body == "from-peer" })")

        let localId = try await h.doc.addAnnotation(kind: .comment, paragraphId: h.pid, body: "after-merge")
        print("L: local op id < peer future id? \(localId < futureId)")
        print("L: mirror sorted AFTER a local append following the merge = \(sorted(h.doc.opLogSnapshot))")
        print("L: currentFoldBasis = \(h.doc.currentFoldBasis == futureId ? "the PEER op" : "the LOCAL op")")
        print("L: annotations still correct? peer=\(all(h.doc).contains { $0.body == "from-peer" }) local=\(all(h.doc).contains { $0.body == "after-merge" })")

        // Does the unsorted mirror break the rewind prefix (derive(ops:upTo:))?
        let ops = h.doc.opLogSnapshot
        let atLocal = Deriver.derive(ops: ops, upTo: .atOp(opId: localId, at: Date()))
        let atLocalSorted = Deriver.derive(
            ops: ops.sorted { $0.opId < $1.opId }, upTo: .atOp(opId: localId, at: Date()))
        print("L: derive(upTo: local) over the LIVE mirror  = \(atLocal.sequence.count) paras")
        print("L: derive(upTo: local) over a SORTED copy     = \(atLocalSorted.sequence.count) paras")

        // And does an accept/reject lifecycle still resolve latest-wins?
        try await h.doc.rejectAnnotation(id: localId)
        print("L: reject after unsorted mirror -> \(String(describing: one(h.doc, localId)?.status))")
    }

    // MARK: - M. isAnnotationOpKind census

    func test_probeM_kinds() {
        var yes: [String] = [], no: [String] = []
        for k in OpKind.allCases {
            if Document.isAnnotationOpKind(k) { yes.append(k.rawValue) } else { no.append(k.rawValue) }
        }
        print("M: annotation kinds (\(yes.count)) = \(yes)")
        print("M: non-annotation kinds (\(no.count)) = \(no)")
    }
}
