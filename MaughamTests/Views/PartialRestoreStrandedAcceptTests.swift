import XCTest
@testable import MaughamCore
@testable import Maugham

/// **A revert answers the accepted suggestions it takes back** (#128 item 2,
/// RULING-28): a checkpoint revert that puts a paragraph back to its text
/// from before an accept reopens that note — the full rewind's step 8, asked
/// of the same rule (`RewindImpact.strandedAccepts`) — and the sheet says so
/// before the writer presses Revert and again after. Windowless: the picker's
/// own `restore(_:)` and its value-type sentences.
@MainActor
final class PartialRestoreStrandedAcceptTests: XCTestCase {

    private var projectURL: URL!
    /// Held: the window's store keeps its project store weakly.
    private var projectStore: ProjectStore?

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("revertacc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        let identities = LocalIdentities.softwareForTesting()
        Document.localIdentitiesForTesting = identities
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("op-log-state.json"))
        Document.registryCacheForTesting = RegistryCache(
            fileURL: projectURL.appendingPathComponent("registry-cache.json"),
            identity: identities.author.fingerprint)
        Document.admissionMemoryForTesting = AdmissionMemory(
            fileURL: projectURL.appendingPathComponent("admission-memory.json"),
            identity: identities.author.fingerprint)
    }

    override func tearDown() async throws {
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        projectStore = nil
        try? FileManager.default.removeItem(at: projectURL)
    }

    // MARK: - Fixture

    /// Chapters A and B — three paragraphs each — and a window.
    private func openBook() async throws -> DocumentStore {
        for slug in ["a", "b"] {
            try "One.\n\nTwo.\n\nThree.\n".write(
                to: file("manuscript/\(slug).md"), atomically: true, encoding: .utf8)
        }
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: ["a", "b"].map {
                StructureItem(id: "doc-\($0)", title: $0.uppercased(), type: .document,
                              path: "manuscript/\($0).md")
            },
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: file(ProjectManifest.fileName))
        let store = try await DocumentStore.open(url: projectURL)
        let projectStore = try await ProjectStore.load(from: projectURL)
        projectStore.documentStore = store
        store.projectStore = projectStore
        self.projectStore = projectStore
        return store
    }

    private func file(_ relative: String) -> URL { projectURL.appendingPathComponent(relative) }

    private func load(_ slug: String) async throws -> Document {
        try await Document.load(
            url: file("manuscript/\(slug).md"), actor: .author, session: "edit", presenter: nil)
    }

    /// A suggestion on paragraph `index`, accepted.
    @discardableResult
    private func accept(_ doc: Document, _ index: Int, _ text: String) async throws -> String {
        let id = try await doc.addAnnotation(
            kind: .suggestedChange, paragraphId: doc.sequence[index],
            body: "b", suggestedText: text)
        try await doc.acceptAnnotation(id: id, userResponse: "yes")
        return id
    }

    private func checkpoint(_ ids: [String]) async throws -> Checkpoint {
        let opStore = OpLogStore(projectURL: projectURL)
        var pointers: [String: String] = [:]
        for id in ids {
            let ops = try await opStore.load(docId: id)
            pointers[id] = try XCTUnwrap(ops.last?.opId)
        }
        return Checkpoint(
            checkpointId: "ckpt-acc", label: "Then", labelSource: .user,
            at: Date(), device: "m", activeDoc: "doc-a",
            docPointers: pointers, manuscriptWordCount: 6)
    }

    private func picker(_ cp: Checkpoint, _ store: DocumentStore) -> PartialRestorePicker {
        PartialRestorePicker(
            checkpoint: cp, projectURL: projectURL, activeDocId: "doc-a",
            allDocIds: ["doc-a", "doc-b"], figures: [],
            device: DeviceIdentity.author.deviceId, session: "s",
            docPaths: ["doc-a": "manuscript/a.md", "doc-b": "manuscript/b.md"],
            documentStore: store, onComplete: {}, onCancel: {})
    }

    /// Every op line of `docId`, read raw: the picker appends through its own
    /// store, signed by this process's identities rather than the fixture's.
    private func rawOps(_ docId: String) throws -> [Op] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = JSONLAppendStore<Op>.dateDecoding
        return try OpLogStore.opLogFileURLs(forDocId: docId, in: projectURL).flatMap { url in
            try Data(contentsOf: url)
                .split(separator: UInt8(0x0A), omittingEmptySubsequences: true)
                .compactMap { line -> Op? in
                    let data = Data(line)
                    return OpLogChain.isSealLine(data) ? nil : try? dec.decode(Op.self, from: data)
                }
        }.sorted { $0.opId < $1.opId }
    }

    /// Each note's status, derived from the raw log.
    private func statuses(_ docId: String) throws -> [String: AnnotationStatus] {
        let ops = try rawOps(docId)
        let state = Deriver.deriveWithSequenceFallback(ops: ops)
        return Dictionary(uniqueKeysWithValues: AnnotationDeriver.derive(
            ops: ops, paragraphs: state.paragraphs).map { ($0.id, $0.status) })
    }

    // MARK: - The restore

    /// An accept the revert takes back is reopened, status only, stamped with
    /// the checkpoint; an accept from before the checkpoint, a Stet the
    /// writer put over an accept, and an accept on a paragraph the revert
    /// does not write all stand. The text restores as before.
    func test_aRevertReopensTheAcceptItTakesBack_andLeavesEveryOtherAnswer() async throws {
        let store = try await openBook()
        let a = try await load("a")
        let early = try await accept(a, 0, "One, then.")
        await (try await load("b")).close()
        await a.close()
        let cp = try await checkpoint(["doc-a", "doc-b"])

        let a2 = try await load("a")
        // The early accept's paragraph is typed over since, so the revert
        // rewrites it too — back to text that still holds that accept.
        a2.setParagraph(id: a2.sequence[0], text: "One, then, and since.")
        try await a2.flushBurstNow()
        let stranded = try await accept(a2, 1, "Two, improved.")
        let stetted = try await accept(a2, 2, "Three, improved.")
        try await a2.stetAnnotation(id: stetted, userResponse: "leave it")
        a2.setFullText(a2.displayText + "\n\nFour.")
        try await a2.flushBurstNow()
        let fresh = try await accept(a2, 3, "Four, improved.")
        await a2.close()

        let sentence = await picker(cp, store).restore(.document("doc-a"))

        let s = try statuses("doc-a")
        XCTAssertEqual(s[stranded], .open, "the accept the revert took back is offered again")
        XCTAssertEqual(s[early], .accepted,
                       "an accept from before the checkpoint stands, though its paragraph was rewritten")
        let restoreOp = try XCTUnwrap(rawOps("doc-a").last { $0.kind == .checkpointRestore })
        XCTAssertTrue(restoreOp.changes.contains { $0.next == "One, then." },
                      "precondition: the revert rewrote the early accept's paragraph")
        XCTAssertEqual(s[stetted], .stetted, "the writer's Stet over an accept stands")
        XCTAssertEqual(s[fresh], .accepted,
                       "a paragraph the revert does not write keeps its accepted text")
        let reverts = try rawOps("doc-a").filter { $0.kind == .claudeAcceptRevert }
        XCTAssertEqual(reverts.map { $0.provenance?.sourceAnnotationId }, [stranded])
        XCTAssertEqual(reverts.first?.changes, [], "status only: the restore op carries the text")
        XCTAssertEqual(reverts.first?.provenance?.sourceCheckpoint, cp.checkpointId)
        let restore = try XCTUnwrap(rawOps("doc-a").last { $0.kind == .checkpointRestore })
        XCTAssertLessThan(restore.opId, try XCTUnwrap(reverts.first?.opId),
                          "the reopen follows the text it answers")
        XCTAssertEqual(sentence, "Reopened 1 accepted suggestion on A.",
                       "the AFTER half names what the revert reopened")
    }

    /// Document scope reopens nothing in another document.
    func test_documentScopeAnswersOnlyThatDocumentsNotes() async throws {
        let store = try await openBook()
        for slug in ["a", "b"] { await (try await load(slug)).close() }
        let cp = try await checkpoint(["doc-a", "doc-b"])
        let a = try await load("a"); let inA = try await accept(a, 0, "One, A."); await a.close()
        let b = try await load("b"); let inB = try await accept(b, 0, "One, B."); await b.close()

        _ = await picker(cp, store).restore(.document("doc-a"))

        XCTAssertEqual(try statuses("doc-a")[inA], .open)
        XCTAssertEqual(try statuses("doc-b")[inB], .accepted, "B was not reverted")
    }

    /// A deleted note still gets its reopen in the log, but is neither
    /// promised nor reported — the full rewind's rule.
    func test_aWithdrawnStrandedAcceptIsLoggedButNotNamed() async throws {
        let store = try await openBook()
        await (try await load("a")).close()
        let cp = try await checkpoint(["doc-a"])
        let a = try await load("a")
        let id = try await a.addReviewerAnnotation(
            kind: .suggestedChange, paragraphId: a.sequence[0], span: nil, body: "b",
            suggestedText: "One, improved.", authorName: "Denver")
        try await a.acceptAnnotation(id: id)
        try await a.withdrawReviewerAnnotation(id: id, authorName: "Denver")
        await a.close()

        let sheet = picker(cp, store)
        let before = await sheet.revertNotes(for: .document("doc-a"))
        XCTAssertNil(before.confirmSentence, "a deleted note is not promised")
        let sentence = await sheet.restore(.document("doc-a"))

        XCTAssertNil(sentence, "a deleted note is not reported")
        XCTAssertTrue(try rawOps("doc-a").contains {
            $0.kind == .claudeAcceptRevert && $0.provenance?.sourceAnnotationId == id
        }, "the log still records the revert, should the note be restored")
    }

    // MARK: - The sheet

    /// RULING-28's BEFORE half: the sheet names what Revert will reopen, from
    /// the same plan the restore then acts on.
    func test_theSheetNamesTheReopensBeforeAndConfirmsThemAfter() async throws {
        let store = try await openBook()
        for slug in ["a", "b"] { await (try await load(slug)).close() }
        let cp = try await checkpoint(["doc-a", "doc-b"])
        let a = try await load("a")
        try await accept(a, 0, "One, A."); try await accept(a, 1, "Two, A.")
        await a.close()
        let b = try await load("b"); try await accept(b, 2, "Three, B."); await b.close()
        let sheet = picker(cp, store)

        let docOnly = await sheet.revertNotes(for: .document("doc-b"))
        XCTAssertEqual(docOnly.confirmSentence, "1 accepted suggestion will be reopened on B.")
        let before = await sheet.revertNotes(for: .wholeProject)
        XCTAssertEqual(before.confirmSentence, "3 accepted suggestions will be reopened on A, B.")

        let sentence = await sheet.restore(.wholeProject)

        XCTAssertEqual(sentence, "Reopened 3 accepted suggestions on A, B.")
        let after = await sheet.revertNotes(for: .wholeProject)
        XCTAssertNil(after.confirmSentence, "nothing is left to reopen")
    }

    /// The value type's wording, every class: none, one, several.
    func test_theNotesSentences() {
        typealias Notes = PartialRestorePicker.RevertNotes
        XCTAssertNil(Notes(entries: []).confirmSentence)
        XCTAssertNil(Notes(entries: []).reportSentence)
        XCTAssertNil(Notes(entries: [.init(title: "A", reopened: 0)]).reportSentence,
                     "a document with nothing reopened is not named")
        let one = Notes(entries: [.init(title: "A", reopened: 1), .init(title: "B", reopened: 0)])
        XCTAssertEqual(one.confirmSentence, "1 accepted suggestion will be reopened on A.")
        XCTAssertEqual(one.reportSentence, "Reopened 1 accepted suggestion on A.")
        let two = Notes(entries: [.init(title: "A", reopened: 1), .init(title: "B", reopened: 2)])
        XCTAssertEqual(two.reportSentence, "Reopened 3 accepted suggestions on A, B.")
    }
}
