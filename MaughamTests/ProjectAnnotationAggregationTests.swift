import XCTest
import MaughamCore
@testable import Maugham

/// M3 P2 Task 6 — the project-wide annotation walk. An open document
/// contributes its LIVE projection, a closed one is derived from its op log on
/// disk (ADR 0018/tripwire 20 — never the `.md`), an unreadable one is named
/// rather than silently counted short (RULING-54), and the whole thing sits
/// behind the `ProjectStore+Tasks` cache-key shape.
///
/// Paragraph ids in the hand-built op logs are 4-char and from `ParagraphID`'s
/// alphabet (tripwire 8) — these ops cross the `.md` ↔ op-log boundary.
@MainActor
final class ProjectAnnotationAggregationTests: XCTestCase {

    // MARK: - Fixture

    /// Three documents: `doc-c1` (opened by the test), `doc-c2` (closed, its
    /// notes seeded straight into the op log), `doc-c3` (closed, and its op-log
    /// file deliberately unreadable). `doc-c2` sits inside a group so the walk
    /// has to recurse.
    @MainActor
    private struct Fixture {
        let store: ProjectStore
        let ds: DocumentStore
        var url: URL { store.url }
    }

    private func makeFixture(unreadableC3: Bool = false) async throws -> Fixture {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PROJ-ANN-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        try fm.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        for name in ["c1", "c2", "c3"] {
            try "\(name) body.".data(using: .utf8)!.write(
                to: tmp.appendingPathComponent("manuscript/\(name).md"))
        }
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [
                StructureItem(
                    id: "doc-c1", title: "C1", type: .document,
                    path: "manuscript/c1.md"),
                StructureItem(
                    id: "grp-1", title: "Part One", type: .group, path: nil,
                    children: [
                        StructureItem(
                            id: "doc-c2", title: "C2", type: .document,
                            path: "manuscript/c2.md"),
                        StructureItem(
                            id: "doc-c3", title: "C3", type: .document,
                            path: "manuscript/c3.md"),
                    ]),
            ],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))

        try await seedClosedDocLog(docId: "doc-c2", in: tmp)
        if unreadableC3 {
            // An op-log file that is present but cannot be read: a DIRECTORY
            // where the reader expects bytes. `loadSyncMerged` throws
            // `ReadError.unreadableFile` on it (RULING-54), which is exactly
            // what a permission-denied or corrupt-inode file does in the field.
            try fm.createDirectory(
                at: tmp.appendingPathComponent(".maugham/ops/doc-c3.jsonl"),
                withIntermediateDirectories: true)
        }

        let store = try await ProjectStore.load(from: tmp)
        let ds = try await DocumentStore.open(url: tmp)
        store.documentStore = ds
        return Fixture(store: store, ds: ds)
    }

    /// `doc-c2`'s op log, written through the production store: two
    /// paragraphs, three open notes (two stamped with a review pass, one
    /// unstamped) and one accepted note.
    private func seedClosedDocLog(docId: String, in projectURL: URL) async throws {
        let store = OpLogStore(projectURL: projectURL)
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let bootstrap = Op(
            opId: "01AAAA", docId: docId, at: t, device: "mac", session: "s",
            kind: .bootstrap,
            changes: [
                .init(paragraphId: "aa11", prior: nil, next: "Two opens."),
                .init(paragraphId: "bb22", prior: nil, next: "Two continues."),
            ],
            sequence: ["aa11", "bb22"])
        try await store.append(bootstrap)

        func comment(
            _ opId: String, pid: String, body: String, pass: String?
        ) -> Op {
            Op(opId: opId, docId: docId, at: t, device: "mac", session: "s",
               kind: .claudeComment,
               changes: [.init(paragraphId: pid, prior: "Two opens.", next: "")],
               provenance: Op.Provenance(
                   sessionId: "s", annotationBody: body, reviewPassId: pass))
        }
        try await store.append(comment("01BBB1", pid: "aa11", body: "closed open one", pass: "pass-1"))
        try await store.append(comment("01BBB2", pid: "bb22", body: "closed open two", pass: "pass-1"))
        try await store.append(comment("01BBB3", pid: "aa11", body: "closed unstamped", pass: nil))
        try await store.append(comment("01BBB4", pid: "aa11", body: "closed accepted", pass: "pass-1"))
        try await store.append(Op(
            opId: "01CCC1", docId: docId, at: t, device: "mac", session: "s",
            kind: .claudeAccept, changes: [],
            provenance: Op.Provenance(
                sessionId: "s", sourceAnnotationId: "01BBB4")))
    }

    /// Open `doc-c1` into the document store and hand back the live Document.
    @discardableResult
    private func openC1(_ f: Fixture) async throws -> Document {
        let doc = try await Document.load(
            url: f.url.appendingPathComponent("manuscript/c1.md"),
            device: "m", session: "s", presenter: nil)
        f.ds.register(document: doc, for: "manuscript/c1.md")
        return doc
    }

    private func firstParagraphId(of doc: Document) throws -> String {
        try XCTUnwrap(doc.sequence.first, "the doc bootstrapped no paragraphs")
    }

    // MARK: - Control

    /// CONTROL: the fixture's closed-doc op log is real and readable on its
    /// own terms. If this fails, nothing below is about the walk.
    func test_control_theSeededClosedLogIsReadable() async throws {
        let f = try await makeFixture()
        let ops = try OpLogStore.loadSyncMerged(forDocId: "doc-c2", in: f.url)
        XCTAssertEqual(ops.count, 6)
    }

    // MARK: - The walk

    func test_aClosedDocsNotesComeFromItsOpLog() async throws {
        let f = try await makeFixture()
        let snapshot = f.store.listAnnotationsAcrossProject()
        let c2 = snapshot.annotations.filter { $0.docId == "doc-c2" }
        XCTAssertEqual(c2.count, 4, "three open + one accepted")
        XCTAssertEqual(
            Set(c2.map(\.annotation.body)),
            ["closed open one", "closed open two", "closed unstamped", "closed accepted"])
        XCTAssertTrue(snapshot.unreadableDocIds.isEmpty)
    }

    func test_anOpenDocsNotesComeFromTheLiveDocument() async throws {
        let f = try await makeFixture()
        let doc = try await openC1(f)
        let pid = try firstParagraphId(of: doc)
        _ = try await doc.addAnnotation(
            kind: .comment, paragraphId: pid, body: "live note")

        let snapshot = f.store.listAnnotationsAcrossProject()
        let c1 = snapshot.annotations.filter { $0.docId == "doc-c1" }
        XCTAssertEqual(c1.map(\.annotation.body), ["live note"],
                       "the open document's own projection, not a disk read")
    }

    /// The live projection wins WITHOUT waiting for the fire-and-forget disk
    /// append: a note added to an open doc is in the walk immediately.
    func test_theOpenDocsProjectionIsNotBehindTheDisk() async throws {
        let f = try await makeFixture()
        let doc = try await openC1(f)
        let pid = try firstParagraphId(of: doc)
        _ = try await doc.addAnnotation(
            kind: .comment, paragraphId: pid, body: "first")
        XCTAssertEqual(
            f.store.listAnnotationsAcrossProject()
                .annotations.filter { $0.docId == "doc-c1" }.count, 1)
        _ = try await doc.addAnnotation(
            kind: .comment, paragraphId: pid, body: "second")
        XCTAssertEqual(
            f.store.listAnnotationsAcrossProject()
                .annotations.filter { $0.docId == "doc-c1" }.count, 2,
            "the second note must be visible on the very next call")
    }

    // MARK: - RULING-54: lenient, but never silent

    func test_anUnreadableClosedDocIsNamedAndNotCountedShort() async throws {
        let f = try await makeFixture(unreadableC3: true)
        let snapshot = f.store.listAnnotationsAcrossProject()
        XCTAssertEqual(snapshot.unreadableDocIds, ["doc-c3"])
        XCTAssertFalse(snapshot.annotations.contains { $0.docId == "doc-c3" })
        XCTAssertEqual(
            snapshot.annotations.filter { $0.docId == "doc-c2" }.count, 4,
            "one unreadable document must not cost the readable ones their notes")
        XCTAssertNil(snapshot.sequences["doc-c3"],
                     "no sequence is honest; an empty one would read as an empty chapter")
    }

    /// The complement: a doc with no op log at all is NOT unreadable — there
    /// is simply nothing to read, and a false alarm would put an em-dash on
    /// every untouched chapter in Task 9's board.
    func test_aDocWithNoOpLogIsNotUnreadable() async throws {
        let f = try await makeFixture()
        let snapshot = f.store.listAnnotationsAcrossProject()
        XCTAssertTrue(snapshot.unreadableDocIds.isEmpty)
        XCTAssertFalse(snapshot.annotations.contains { $0.docId == "doc-c3" })
    }

    // MARK: - Sequences (Task 7's document-order sort)

    func test_sequencesCarryPerDocParagraphOrder() async throws {
        let f = try await makeFixture()
        let doc = try await openC1(f)
        let snapshot = f.store.listAnnotationsAcrossProject()
        XCTAssertEqual(snapshot.sequences["doc-c2"], ["aa11", "bb22"],
                       "a closed doc's order comes from the same derive as its notes")
        XCTAssertEqual(snapshot.sequences["doc-c1"], doc.sequence,
                       "an open doc's order is the live document's")
    }

    // MARK: - Open-notes summaries

    func test_summariesCountOpenNotesOnlyAndBucketByPass() async throws {
        let f = try await makeFixture()
        let summaries = f.store.openNotesSummaries()
        let c2 = try XCTUnwrap(summaries["doc-c2"])
        XCTAssertEqual(c2.total, 3, "the accepted note is resolved, not open")
        XCTAssertEqual(c2.byPass, ["pass-1": 2],
                       "an unstamped note counts in total only")
    }

    func test_summariesOmitPiecesWithNoOpenNote() async throws {
        let f = try await makeFixture()
        try await openC1(f)
        let summaries = f.store.openNotesSummaries()
        XCTAssertNil(summaries["doc-c1"], "no notes at all — no row")
        XCTAssertNil(summaries["doc-c3"])
        XCTAssertEqual(Set(summaries.keys), ["doc-c2"])
    }

    /// A stet resolves. A chapter whose last open note is stetted drops out of
    /// the summaries entirely — the M3 P2 case the pre-stet count would miss.
    func test_aStettedNoteIsNotAnOpenNote() async throws {
        let f = try await makeFixture()
        let doc = try await openC1(f)
        let pid = try firstParagraphId(of: doc)
        let id = try await doc.addAnnotation(
            kind: .comment, paragraphId: pid, body: "will stand")
        XCTAssertEqual(f.store.openNotesSummaries()["doc-c1"]?.total, 1)
        try await doc.stetAnnotation(id: id)
        XCTAssertNil(f.store.openNotesSummaries()["doc-c1"],
                     "a stetted note leaves the chapter with nothing open")
    }

    // MARK: - The cache

    func test_asecondCallWithNothingChangedHitsTheCache() async throws {
        let f = try await makeFixture()
        try await openC1(f)
        _ = f.store.listAnnotationsAcrossProject()
        #if DEBUG
        let before = f.store._debugAnnotationsRebuildCount
        _ = f.store.listAnnotationsAcrossProject()
        _ = f.store.openNotesSummaries()
        XCTAssertEqual(f.store._debugAnnotationsRebuildCount, before,
                       "neither read should re-derive with nothing changed")
        #endif
    }

    func test_anOpenDocsNewNoteInvalidatesTheCache() async throws {
        let f = try await makeFixture()
        let doc = try await openC1(f)
        let pid = try firstParagraphId(of: doc)
        _ = f.store.listAnnotationsAcrossProject()
        #if DEBUG
        let before = f.store._debugAnnotationsRebuildCount
        _ = try await doc.addAnnotation(
            kind: .comment, paragraphId: pid, body: "new")
        _ = f.store.listAnnotationsAcrossProject()
        XCTAssertGreaterThan(f.store._debugAnnotationsRebuildCount, before)
        #endif
    }

    func test_aClosedDocsLogChangingInvalidatesTheCache() async throws {
        let f = try await makeFixture()
        let first = f.store.listAnnotationsAcrossProject()
        XCTAssertEqual(first.annotations.filter { $0.docId == "doc-c2" }.count, 4)
        #if DEBUG
        let before = f.store._debugAnnotationsRebuildCount
        #endif
        // A peer device's file lands in the ops directory (ADR 0012): the key
        // folds every op-log file's mtime, not just `<docId>.jsonl`.
        let peer = f.url.appendingPathComponent(
            ".maugham/ops/doc-c2.peerdevice.jsonl")
        let op = Op(
            opId: "01DDD1", docId: "doc-c2",
            at: Date(timeIntervalSince1970: 1_700_000_000),
            device: "peer", session: "p", kind: .claudeComment,
            changes: [.init(paragraphId: "aa11", prior: "Two opens.", next: "")],
            provenance: Op.Provenance(sessionId: "p", annotationBody: "from the phone"))
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        var line = try enc.encode(op)
        line.append(0x0A)
        try line.write(to: peer)

        let second = f.store.listAnnotationsAcrossProject()
        #if DEBUG
        XCTAssertGreaterThan(f.store._debugAnnotationsRebuildCount, before)
        #endif
        XCTAssertTrue(
            second.annotations.contains { $0.annotation.body == "from the phone" },
            "a peer device's notes must reach the project-wide walk")
    }
}
