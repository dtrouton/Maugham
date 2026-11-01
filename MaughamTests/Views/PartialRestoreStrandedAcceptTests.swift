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

    private func checkpoint(_ ids: [String], id: String = "ckpt-acc") async throws -> Checkpoint {
        let opStore = OpLogStore(projectURL: projectURL)
        var pointers: [String: String] = [:]
        for id in ids {
            let ops = try await opStore.load(docId: id)
            pointers[id] = try XCTUnwrap(ops.last?.opId)
        }
        return Checkpoint(
            checkpointId: id, label: "Then", labelSource: .user,
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

    // MARK: - Failures are said (RULING-52)

    private struct DiskFull: LocalizedError {
        var errorDescription: String? { "disk full" }
    }

    /// A book with one accept on A since the checkpoint.
    private func oneStrandedAccept() async throws -> (DocumentStore, Checkpoint, String) {
        let store = try await openBook()
        await (try await load("a")).close()
        let cp = try await checkpoint(["doc-a"])
        let a = try await load("a")
        let id = try await accept(a, 0, "One, improved.")
        await a.close()
        return (store, cp, id)
    }

    /// The restore op lands and the reopen behind it will not write: the note
    /// is still accepted over text without its change, so the sheet names it
    /// rather than closing — never only a log line.
    func test_aReopenThatWillNotWriteIsNamed() async throws {
        let (store, cp, id) = try await oneStrandedAccept()
        let opStore = OpLogStore(projectURL: projectURL)
        // Every append after the first (the restore op) fails.
        opStore.beforeChainedAppendForTesting = { [unowned opStore] in
            opStore.appendFailureForTesting = DiskFull()
        }

        let sentence = await picker(cp, store).restore(.document("doc-a"), opStore: opStore)

        XCTAssertEqual(try rawOps("doc-a").filter { $0.kind == .checkpointRestore }.count, 1,
                       "precondition: the text was restored")
        XCTAssertEqual(try statuses("doc-a")[id], .accepted, "precondition: the reopen did not land")
        XCTAssertEqual(sentence,
                       "Couldn't reopen 1 accepted suggestion on A — still marked accepted.",
                       "a failed reopen is said, and the sheet stays up on it")
    }

    /// The restore op itself will not write: the document is named as not
    /// restored, and nothing is reopened behind text that did not change.
    func test_aRestoreThatWillNotWriteIsNamedAndReopensNothing() async throws {
        let (store, cp, id) = try await oneStrandedAccept()
        let opStore = OpLogStore(projectURL: projectURL)
        opStore.appendFailureForTesting = DiskFull()
        // A marker no render would write: any save over the `.md` replaces it.
        let md = file("manuscript/a.md")
        try "untouched\n".write(to: md, atomically: true, encoding: .utf8)

        let sentence = await picker(cp, store).restore(.document("doc-a"), opStore: opStore)
        try await store.flushPendingSave()

        XCTAssertEqual(sentence, "Not restored: A (disk full).")
        XCTAssertEqual(try statuses("doc-a")[id], .accepted)
        XCTAssertFalse(try rawOps("doc-a").contains { $0.kind == .claudeAcceptRevert },
                       "no reopen behind a restore that did not land")
        XCTAssertEqual(try String(contentsOf: md, encoding: .utf8), "untouched\n",
                       "the .md renders the log, so text the log never took is not written")
    }

    /// A legacy log — no op carries a sequence, so the order is synthesised
    /// from first appearance, as `Document.load` derives it. The revert's
    /// `.md` renders every paragraph, not the empty render `derive` gives.
    func test_aRevertOfASequencelessLogRendersEveryParagraph() async throws {
        let store = try await openBook()
        let opStore = OpLogStore(projectURL: projectURL)
        func burst(_ changes: [Op.ParagraphChange]) -> Op {
            Op(opId: ULID.generate(), docId: "doc-a", at: Date(), device: "m",
               session: "legacy", kind: .typingBurst, changes: changes, sequence: nil)
        }
        let seed = burst([.init(paragraphId: "a1b2", prior: nil, next: "One."),
                          .init(paragraphId: "c3d4", prior: nil, next: "Two.")])
        try await opStore.append(seed)
        let cp = Checkpoint(
            checkpointId: "ckpt-legacy", label: "Then", labelSource: .user,
            at: Date(), device: "m", activeDoc: "doc-a",
            docPointers: ["doc-a": seed.opId], manuscriptWordCount: 2)
        try await opStore.append(burst([.init(paragraphId: "a1b2", prior: "One.", next: "One, since.")]))

        let sentence = await picker(cp, store).restore(.document("doc-a"))
        try await store.flushPendingSave()

        XCTAssertNil(sentence)
        XCTAssertTrue(try rawOps("doc-a").allSatisfy { $0.sequence == nil },
                      "precondition: no op in the log carries a sequence")
        let md = try String(contentsOf: file("manuscript/a.md"), encoding: .utf8)
        XCTAssertFalse(md.contains("One, since."), "precondition: the revert landed — \(md)")
        let one = try XCTUnwrap(md.range(of: "One."), "the reverted paragraph renders — \(md)")
        let two = try XCTUnwrap(md.range(of: "Two."), "every other paragraph renders — \(md)")
        XCTAssertLessThan(one.lowerBound, two.lowerBound, "in first-appearance order")
    }

    // MARK: - The confirm line

    /// A scope changed while its plan was worked out cancels the sheet's
    /// task; that plan's sentence must not land and promise the old scope's
    /// notes. The work cancels its own task mid-flight, as a scope change does.
    func test_aCancelledScopesSentenceDoesNotLand() async {
        let stale = await Task { () -> String?? in
            await PartialRestorePicker.unlessCancelled { () -> String? in
                withUnsafeCurrentTask { $0?.cancel() }
                return "the old scope's notes"
            }
        }.value
        XCTAssertNil(stale, "a cancelled scope's sentence is dropped")
        let live = await PartialRestorePicker.unlessCancelled { () -> String? in "fresh" }
        XCTAssertEqual(live, .some("fresh"), "a live scope's sentence lands")
    }

    // MARK: - The render

    /// A landed revert renders the log as it now stands: the reverted
    /// paragraph is back, and a paragraph made since the checkpoint — which
    /// the restore op leaves alone — is still in the `.md`.
    func test_aRevertsRenderKeepsAParagraphMadeSinceTheCheckpoint() async throws {
        let store = try await openBook()
        await (try await load("a")).close()
        let cp = try await checkpoint(["doc-a"])
        let a = try await load("a")
        a.setParagraph(id: a.sequence[0], text: "One, since.")
        a.setFullText(a.displayText + "\n\nFour.")
        try await a.flushBurstNow()
        await a.close()

        let sentence = await picker(cp, store).restore(.document("doc-a"))
        try await store.flushPendingSave()

        XCTAssertNil(sentence)
        let md = try String(contentsOf: file("manuscript/a.md"), encoding: .utf8)
        XCTAssertTrue(md.contains("One.") && !md.contains("One, since."),
                      "precondition: the revert put the first paragraph back — \(md)")
        XCTAssertTrue(md.contains("Four."), "a paragraph made since the checkpoint stays — \(md)")
        let log = Deriver.derive(ops: try rawOps("doc-a"))
        XCTAssertEqual(md, MarkdownDisplayFilter.stripAnchors(Materializer.materialize(
            paragraphs: log.paragraphs, sequence: log.sequence)),
                       "the .md is the log's clean render (ADR 0019)")
        XCTAssertFalse(md.contains("¶"), "no anchors in the .md")
    }

    // MARK: - An open document

    /// A revert of an open document reaches it through the presenter path
    /// (`DocumentStore.reReadAfterExternalChange`): its text and the note's
    /// status both come back as the log now says. The picker is handed the
    /// store a load builds, so the open document trusts its lines.
    func test_anOpenDocumentReReadsTheRevertAndTheReopen() async throws {
        let (store, cp, id) = try await oneStrandedAccept()
        let a = try await load("a")
        store.register(document: a, for: "manuscript/a.md")
        XCTAssertEqual(a.annotations(filter: AnnotationFilter(statuses: nil))
            .first { $0.id == id }?.status, .accepted, "precondition")

        let sentence = await picker(cp, store).restore(
            .document("doc-a"),
            opStore: Document.makeLoadOpStore(projectURL: projectURL, presenter: nil))
        try await store.reReadAfterExternalChange(a)

        XCTAssertEqual(sentence, "Reopened 1 accepted suggestion on A.")
        XCTAssertEqual(a.annotations(filter: AnnotationFilter(statuses: nil))
            .first { $0.id == id }?.status, .open, "the open document shows the reopen")
        XCTAssertEqual(a.paragraph(id: a.sequence[0]), "One.", "and the reverted text")
        await a.close()
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
        let mixed = Notes(entries: [.init(title: "A", reopened: 2, notReopened: 1),
                                    .init(title: "B", reopened: 0, notReopened: 2)])
        XCTAssertEqual(mixed.confirmSentence, "2 accepted suggestions will be reopened on A.")
        XCTAssertEqual(mixed.reportSentence,
                       "Reopened 2 accepted suggestions on A. "
                       + "Couldn't reopen 3 accepted suggestions on A, B — still marked accepted.")
    }

    // MARK: - An accept the revert puts back (RULING-57, RULING-26)

    /// Accept → checkpoint → the writer's Revert: reverting to the checkpoint
    /// puts the accepted text back, so the note returns to accepted — said
    /// before and after, and written status only behind the restore op.
    func test_aRevertRestoresToAcceptedTheAcceptTheWriterRevertedSince() async throws {
        let store = try await openBook()
        let a = try await load("a")
        let id = try await accept(a, 0, "One, improved.")
        await a.close()
        let cp = try await checkpoint(["doc-a"])
        let a2 = try await load("a")
        try await a2.revertAcceptedAnnotation(id: id)
        try await a2.flushBurstNow()
        await a2.close()
        XCTAssertEqual(try statuses("doc-a")[id], .open, "precondition: the Revert reopened it")
        let sheet = picker(cp, store)

        let before = await sheet.revertNotes(for: .document("doc-a"))
        XCTAssertEqual(before.confirmSentence, "1 suggestion will be restored to accepted on A.")
        let sentence = await sheet.restore(.document("doc-a"))

        XCTAssertEqual(sentence, "Restored 1 suggestion to accepted on A.")
        XCTAssertEqual(try statuses("doc-a")[id], .accepted)
        let ops = try rawOps("doc-a")
        let reaccept = try XCTUnwrap(ops.last {
            $0.kind == .claudeAccept && $0.provenance?.sourceAnnotationId == id })
        XCTAssertEqual(reaccept.changes, [], "status only: the restore op carries the text")
        XCTAssertEqual(reaccept.provenance?.sourceCheckpoint, cp.checkpointId)
        XCTAssertEqual(reaccept.provenance?.userResponse, "yes", "the writer's reply is kept")
        let restore = try XCTUnwrap(ops.last { $0.kind == .checkpointRestore })
        XCTAssertTrue(restore.changes.contains { $0.next == "One, improved." })
        XCTAssertLessThan(restore.opId, reaccept.opId, "the re-accept follows the text it answers")
        let after = await sheet.revertNotes(for: .document("doc-a"))
        XCTAssertNil(after.confirmSentence, "nothing is left to restore")
    }

    /// A revert's own reopen (Maugham's travel, RULING-26) comes back the
    /// same way: revert to a checkpoint from before the accept, then to one
    /// after it.
    func test_aRevertOverAnEarlierRevertsReopen_restoresToAccepted() async throws {
        let store = try await openBook()
        await (try await load("a")).close()
        let early = try await checkpoint(["doc-a"], id: "ckpt-early")
        let a = try await load("a")
        let id = try await accept(a, 0, "One, improved.")
        await a.close()
        let later = try await checkpoint(["doc-a"], id: "ckpt-later")
        _ = await picker(early, store).restore(.document("doc-a"))
        XCTAssertEqual(try statuses("doc-a")[id], .open, "precondition: the first revert reopened it")

        let sentence = await picker(later, store).restore(.document("doc-a"))

        XCTAssertEqual(sentence, "Restored 1 suggestion to accepted on A.")
        XCTAssertEqual(try statuses("doc-a")[id], .accepted)
    }

    /// A paragraph the revert does not write keeps the writer's answer: the
    /// note stays open though the checkpoint had it accepted.
    func test_aParagraphTheRevertDoesNotWriteStaysOpen() async throws {
        let store = try await openBook()
        let a = try await load("a")
        let id = try await accept(a, 0, "One, improved.")
        await a.close()
        let cp = try await checkpoint(["doc-a"])
        let a2 = try await load("a")
        try await a2.revertAcceptedAnnotation(id: id)
        a2.setParagraph(id: a2.sequence[0], text: "One, improved.")
        a2.setParagraph(id: a2.sequence[1], text: "Two, since.")
        try await a2.flushBurstNow()
        await a2.close()
        let sheet = picker(cp, store)

        let before = await sheet.revertNotes(for: .document("doc-a"))
        let sentence = await sheet.restore(.document("doc-a"))

        XCTAssertNotNil(try rawOps("doc-a").last { $0.kind == .checkpointRestore },
                        "precondition: the revert wrote something")
        XCTAssertNil(before.confirmSentence)
        XCTAssertNil(sentence)
        XCTAssertEqual(try statuses("doc-a")[id], .open)
    }

    /// A re-accept that will not write is named, never only logged.
    func test_aReacceptThatWillNotWriteIsNamed() async throws {
        let store = try await openBook()
        let a = try await load("a")
        let id = try await accept(a, 0, "One, improved.")
        await a.close()
        let cp = try await checkpoint(["doc-a"])
        let a2 = try await load("a")
        try await a2.revertAcceptedAnnotation(id: id)
        try await a2.flushBurstNow()
        await a2.close()
        let opStore = OpLogStore(projectURL: projectURL)
        opStore.beforeChainedAppendForTesting = { [unowned opStore] in
            opStore.appendFailureForTesting = DiskFull()
        }

        let sentence = await picker(cp, store).restore(.document("doc-a"), opStore: opStore)

        XCTAssertEqual(try statuses("doc-a")[id], .open, "precondition: the re-accept did not land")
        XCTAssertEqual(sentence,
                       "Couldn't restore 1 suggestion to accepted on A — still open.")
    }

    /// The re-accept sentences' wording, beside the reopens'.
    func test_theReacceptSentences() {
        typealias Notes = PartialRestorePicker.RevertNotes
        let one = Notes(entries: [.init(title: "A", reopened: 0, reaccepted: 1)])
        XCTAssertEqual(one.confirmSentence, "1 suggestion will be restored to accepted on A.")
        XCTAssertEqual(one.reportSentence, "Restored 1 suggestion to accepted on A.")
        let mixed = Notes(entries: [
            .init(title: "A", reopened: 1, reaccepted: 2),
            .init(title: "B", reopened: 0, reaccepted: 0, notReaccepted: 1)])
        XCTAssertEqual(mixed.confirmSentence,
                       "1 accepted suggestion will be reopened on A. "
                       + "2 suggestions will be restored to accepted on A.")
        XCTAssertEqual(mixed.reportSentence,
                       "Reopened 1 accepted suggestion on A. "
                       + "Restored 2 suggestions to accepted on A. "
                       + "Couldn't restore 1 suggestion to accepted on B — still open.")
    }

    /// Accept → checkpoint → Revert → accept again → typed over: the revert
    /// writes the paragraph back to the accepted text it held at the
    /// checkpoint, so the note is not stranded and stays accepted (M4-RW-042).
    func test_aNoteAcceptedAgainSinceTheCheckpointStaysAccepted() async throws {
        let store = try await openBook()
        let a = try await load("a")
        let id = try await accept(a, 0, "One, improved.")
        await a.close()
        let cp = try await checkpoint(["doc-a"])
        let a2 = try await load("a")
        try await a2.revertAcceptedAnnotation(id: id)
        try await a2.acceptAnnotation(id: id, userResponse: "again")
        a2.setParagraph(id: a2.sequence[0], text: "One, improved, and more.")
        try await a2.flushBurstNow()
        await a2.close()
        let sheet = picker(cp, store)

        let before = await sheet.revertNotes(for: .document("doc-a"))
        let sentence = await sheet.restore(.document("doc-a"))

        let restore = try XCTUnwrap(rawOps("doc-a").last { $0.kind == .checkpointRestore })
        XCTAssertTrue(restore.changes.contains { $0.next == "One, improved." },
                      "precondition: the revert wrote the note's paragraph")
        XCTAssertNil(before.confirmSentence, "nothing is promised")
        XCTAssertNil(sentence, "nothing is reported")
        XCTAssertEqual(try statuses("doc-a")[id], .accepted)
    }
}
