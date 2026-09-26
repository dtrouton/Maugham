import XCTest
@testable import Maugham
@testable import MaughamCore

/// **Every manuscript writer outside the editor asks first** (signed op log
/// P3c, the whole-branch fix wave's C1).
///
/// The editor's membrane is in front of the keystroke, so a burst's EMISSION is
/// deliberately not permit-guarded. Three doors reached the manuscript from
/// outside that membrane with neither a surface gate nor a storage door:
/// History's restore, project Replace / Replace All, and the rename's wiki-link
/// sweep. On a reviewer's Mac each signed text in her name that every read then
/// set aside — a whole chapter, in the restore's case. These pin the doors
/// (both directions: what may be written is, what may not is left and SAID)
/// and the surfaces' pure decisions (tripwire 33: no mounted press).
@MainActor
final class ManuscriptWriterPostureTests: XCTestCase {

    private var roots: [URL] = []

    override func tearDown() async throws {
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
    }

    // MARK: - The restore door (History's Rewind / Restore here…)

    private func loadOne(prefix: String) async throws -> Document {
        let (dir, docURL) = try makeTestProject(prefix: prefix, initialMd: "First words.\n")
        roots.append(dir)
        return try await Document.load(
            url: docURL, device: "test", session: "s", presenter: nil)
    }

    private func beAReviewer(_ doc: Document) {
        doc.stamp(localWritePermit: LocalWritePermit(
            permit: .reviewer, actor: .author, documentClass: .piece(doc.docId)))
    }

    /// A document with two moments: the bootstrap, and one edit after it.
    private func twoMoments(_ doc: Document) async throws -> String {
        let first = try XCTUnwrap(doc._opLogMirror.last?.opId)
        doc.setFullText("First words.\n\nSecond words.")
        try await doc.flushBurstNow()
        return first
    }

    private func assertRefused(
        _ doc: Document, _ label: String, _ act: () async throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        let before = doc._opLogMirror.count
        let text = doc.displayText
        do {
            try await act()
            XCTFail("\(label) was not refused", file: file, line: line)
        } catch is Document.PostureRefusal {
        } catch {
            XCTFail("\(label) threw \(error), not PostureRefusal", file: file, line: line)
        }
        XCTAssertEqual(doc._opLogMirror.count, before,
                       "\(label) appended nothing — not even the pending burst",
                       file: file, line: line)
        XCTAssertEqual(doc.displayText, text, "\(label) moved no words", file: file, line: line)
    }

    /// **A reviewer's restore is refused before the flush and before any op**;
    /// the promotion back restores normally (the other direction).
    func test_aRestoreThisMacMayNotWriteIsRefusedBeforeAnyOp() async throws {
        let doc = try await loadOne(prefix: "RestoreDoor")
        let first = try await twoMoments(doc)
        // A pending burst: the door is in front of the flush too.
        doc.setFullText("First words.\n\nSecond words.\n\nThird, pending.")
        beAReviewer(doc)

        await assertRefused(doc, "restoreToOp") {
            _ = try await doc.restoreToOp(opId: first)
        }

        doc.stamp(localWritePermit: .unrestricted)
        let result = try await doc.restoreToOp(opId: first)
        XCTAssertNotNil(result.restoreOp, "promoted: the restore lands")
        XCTAssertEqual(doc.displayText, "First words.")
        await doc.close()
    }

    /// **The undoable wrapper refuses before its stack clear**, so a refused
    /// restore costs the writer's undo history nothing.
    func test_aRefusedUndoableRestoreLeavesTheUndoStackAlone() async throws {
        let doc = try await loadOne(prefix: "RestoreDoorUndo")
        let first = try await twoMoments(doc)
        beAReviewer(doc)
        let um = UndoManager()
        um.groupsByEvent = false
        um.beginUndoGrouping()
        um.registerUndo(withTarget: self) { _ in }
        um.endUndoGrouping()
        XCTAssertTrue(um.canUndo, "precondition: the writer has something to undo")

        await assertRefused(doc, "restoreToOpUndoable") {
            _ = try await doc.restoreToOpUndoable(opId: first, undoManager: um)
        }
        XCTAssertTrue(um.canUndo, "the refused restore did not clear the undo stack")
        await doc.close()
    }

    /// **`applyRestore` refuses for the caller that does not come through
    /// `restoreToOp`** — the inline-task archive undo.
    func test_applyRestoreRefusesTheCallerThatBypassesRestoreToOp() async throws {
        let doc = try await loadOne(prefix: "RestoreDoorApply")
        let first = try await twoMoments(doc)
        let target = Deriver.derive(
            ops: doc._opLogMirror, upTo: .atOp(opId: first, at: Date()))
        beAReviewer(doc)

        await assertRefused(doc, "applyRestore") {
            _ = try await doc.applyRestore(
                target: target, sourceCheckpoint: first, synthesisSource: .undoRewind)
        }
        await doc.close()
    }

    /// **A restore registered while she could, undone after she can't**: the
    /// compensating restore is refused, and SAID in the restore's own words.
    func test_anUndoOfARestoreAfterADemotionIsRefusedAndSaysSo() async throws {
        let doc = try await loadOne(prefix: "RestoreDoorUndoLater")
        let first = try await twoMoments(doc)
        let um = UndoManager()
        _ = try await doc.restoreToOpUndoable(opId: first, undoManager: um)
        XCTAssertTrue(um.canUndo, "precondition: the restore registered its undo")
        beAReviewer(doc)
        let before = doc._opLogMirror.count

        let said = await notices {
            um.undo()
            await doc.awaitPendingUndoWork()
        }
        XCTAssertEqual(said, [
            "Couldn't undo the restore — this Mac can no longer change this piece's text."])
        XCTAssertEqual(doc._opLogMirror.count, before, "the undo appended nothing")
        XCTAssertEqual(doc.displayText, "First words.", "the restored text stays")
        await doc.close()
    }

    private func notices(during body: () async throws -> Void) async rethrows -> [String] {
        var seen: [String] = []
        let token = NotificationCenter.default.addObserver( // adr-0021-ok: a test observing the production post, not a production subscription
            forName: .maughamDocumentNotice, object: nil, queue: nil
        ) { note in
            if let m = note.userInfo?[MaughamEvent.noticeMessageKey] as? String {
                seen.append(m)
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        try await body()
        return seen
    }

    // MARK: - The paragraph primitives (re-review item 1)

    /// **`setParagraph`/`insertParagraph`/`deleteParagraph`/`reorder` write
    /// nothing where the stamp refuses the text** — the floor under every
    /// caller — and write normally where it allows (both directions).
    func test_theParagraphPrimitivesWriteNothingWhereTheStampRefuses() async throws {
        let doc = try await loadOne(prefix: "ParagraphFloor")
        _ = try await twoMoments(doc)
        let pid = try XCTUnwrap(doc.sequence.first)
        beAReviewer(doc)
        let text = doc.displayText
        let sequence = doc.sequence

        doc.setParagraph(id: pid, text: "Rewritten.")
        XCTAssertEqual(doc.insertParagraph(after: pid, text: "Inserted."), "")
        doc.deleteParagraph(id: pid)
        doc.reorder(sequence: sequence.reversed())
        XCTAssertEqual(doc.displayText, text, "no primitive moved a word")
        XCTAssertEqual(doc.sequence, sequence)
        let before = doc._opLogMirror.count
        try await doc.flushBurstNow()
        XCTAssertEqual(doc._opLogMirror.count, before, "and no burst was pending")

        doc.stamp(localWritePermit: .unrestricted)
        doc.setParagraph(id: pid, text: "Rewritten.")
        XCTAssertTrue(doc.displayText.hasPrefix("Rewritten."), "promoted: it writes")
        await doc.close()
    }

    /// **History's recovered-orphans Append**: the door on the stamp refuses
    /// and writes nothing; promoted, it appends.
    func test_recoveredHistoryAppendIsRefusedWhereTheStampRefuses() async throws {
        let doc = try await loadOne(prefix: "RecoveredAppend")
        let orphan = RecoveredHistoryReport.Orphan(paragraphId: "abcd", text: "Lost words.")
        beAReviewer(doc)
        let text = doc.displayText

        XCTAssertFalse(RecoveredHistorySheet.mayAppend(to: doc))
        XCTAssertEqual(RecoveredHistorySheet.append(orphan, to: doc), "")
        XCTAssertEqual(doc.displayText, text, "nothing was appended")

        doc.stamp(localWritePermit: .unrestricted)
        XCTAssertTrue(RecoveredHistorySheet.mayAppend(to: doc))
        XCTAssertNotEqual(RecoveredHistorySheet.append(orphan, to: doc), "")
        XCTAssertTrue(doc.displayText.hasSuffix("Lost words."))
        await doc.close()
    }

    /// **The inline checkbox flip and its ⌘Z ask the stamp and SAY a refusal**
    /// (the existing `declineUndo` path).
    func test_theInlineToggleAndItsUndoAreRefusedAndSaid() async throws {
        let doc = try await loadOne(prefix: "InlineToggle")
        let pid = try XCTUnwrap(doc.sequence.first)
        let prior = try XCTUnwrap(doc.paragraph(id: pid))
        let flipped = prior + " (done)"

        // Refused forward press: said, nothing written, nothing registered.
        beAReviewer(doc)
        let um = UndoManager()
        let saidOnPress = await notices {
            InlineToggleUndo.perform(on: doc, paragraphId: pid, prior: prior,
                                     flipped: flipped, undoManager: um)
            await doc.awaitPendingUndoWork()
        }
        XCTAssertEqual(saidOnPress, [
            "Couldn't change that task — this Mac can no longer file tasks in this piece."])
        XCTAssertEqual(doc.paragraph(id: pid), prior)
        XCTAssertFalse(um.canUndo)

        // Permitted press, then a demotion, then ⌘Z: refused and said.
        doc.stamp(localWritePermit: .unrestricted)
        InlineToggleUndo.perform(on: doc, paragraphId: pid, prior: prior,
                                 flipped: flipped, undoManager: um)
        XCTAssertEqual(doc.paragraph(id: pid), flipped)
        beAReviewer(doc)
        let saidOnUndo = await notices {
            um.undo()
            await doc.awaitPendingUndoWork()
        }
        XCTAssertEqual(saidOnUndo, [
            "Couldn't change that task — this Mac can no longer file tasks in this piece."])
        XCTAssertEqual(doc.paragraph(id: pid), flipped, "the flip stays")
        await doc.close()
    }

    /// **An adoption's ⌘Z refused by the statement door is SAID** (re-review
    /// item 2) — `StatementProposalGate.sayingARefusal` around the real door.
    func test_aRefusedAdoptUndoIsSaid() async throws {
        let (store, statement, open) = try await aReviewersOpenStatement(prefix: "AdoptUndo")
        let said = await notices {
            await StatementProposalGate.sayingARefusal(store) {
                try await store.mutateStatementText(of: statement, session: "s") { _ in "Before." }
            }
        }
        XCTAssertEqual(said, [
            "This Mac may not change that statement's text, so it was left as it was."])
        XCTAssertEqual(open.displayText, "What it is for.")
        await open.close()
    }

    private func aReviewersOpenStatement(
        prefix: String
    ) async throws -> (ProjectStore, Statement, Document) {
        let (dir, _) = try makeTestProject(prefix: prefix, initialMd: "Hello.\n")
        roots.append(dir)
        let statementPath = "intent/c1.md"
        let statement = Statement(
            id: "stmt-c1-intent", kind: .intent, scope: .document("doc-test"),
            path: statementPath)
        let manifestURL = dir.appendingPathComponent(ProjectManifest.fileName)
        var manifest = try ProjectManifest.makeDecoder()
            .decode(ProjectManifest.self, from: Data(contentsOf: manifestURL))
        manifest.statements = [statement]
        try ProjectManifest.makeEncoder().encode(manifest).write(to: manifestURL)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("intent"), withIntermediateDirectories: true)
        try "What it is for.\n".write(
            to: dir.appendingPathComponent(statementPath), atomically: true, encoding: .utf8)
        let store = try await ProjectStore.load(from: dir)
        let open = try await Document.load(
            url: dir.appendingPathComponent(statementPath),
            device: "test", session: "s", presenter: nil)
        store.noteStatementDocumentOpened(open, id: statement.id)
        open.stamp(localWritePermit: LocalWritePermit(
            permit: .reviewer, actor: .author,
            documentClass: .pieceStatement(piece: "doc-test")))
        return (store, statement, open)
    }

    // MARK: - The surfaces' decisions (pure)

    private let bookAuthor = Posture(.unrestricted)
    private let reviewer = Posture(LocalWritePermit(
        permit: .reviewer, actor: .author, documentClass: .piece("doc-a")))

    func test_historyOffersRewindAndRevertOnlyWhereTheTextMayBeWritten() {
        XCTAssertTrue(HistoryPane.offersRewind(bookAuthor))
        XCTAssertFalse(HistoryPane.offersRewind(reviewer), "a reviewer reads history")
        XCTAssertFalse(HistoryPane.offersRewind(nil), "no door behind the pane fails closed")

        // Revert follows the picker's own list (Task 9: asked through the
        // picker's `mayWrite`, over its documents).
        let checkpointRow = [HistoryEntry.checkpoint(Checkpoint(
            checkpointId: "cp", label: "A", labelSource: .user,
            at: Date(), device: "d", activeDoc: "doc-a",
            docPointers: [:], manuscriptWordCount: 1))]
        XCTAssertTrue(HistoryPane.offersRevert(
            for: checkpointRow, docIds: ["doc-b", "doc-a"], mayWrite: { $0 == "doc-a" }),
            "one document she may write is enough to open the picker")
        XCTAssertFalse(HistoryPane.offersRevert(
            for: checkpointRow, docIds: ["doc-a", "doc-b"], mayWrite: { _ in false }))
        XCTAssertFalse(HistoryPane.offersRevert(
            for: checkpointRow, docIds: ["doc-a"],
            mayWrite: PartialRestorePicker.mayWrite(through: nil)),
            "no door behind the pane fails closed")

        XCTAssertTrue(RewindWindow.offersRestore(bookAuthor))
        XCTAssertFalse(RewindWindow.offersRestore(reviewer))
        XCTAssertFalse(RewindWindow.offersRestore(nil))
        XCTAssertTrue(RewindWindow.offersSnapshot(bookAuthor))
        XCTAssertFalse(RewindWindow.offersSnapshot(reviewer), "ruling R5: no checkpoint")
    }

    func test_theRevertPickerListsOnlyWhatThisMacMayWrite() {
        let mayWrite: (String) -> Bool = { $0 == "doc-a" }
        let all = ["doc-a", "doc-b"]
        XCTAssertEqual(PartialRestorePicker.offeredDocIds(all, mayWrite: mayWrite), ["doc-a"])
        XCTAssertFalse(PartialRestorePicker.offersWholeProject(all, mayWrite: mayWrite),
                       "a whole-project revert that skipped some would not be what it says")
        XCTAssertTrue(PartialRestorePicker.offersWholeProject(all, mayWrite: { _ in true }))
        XCTAssertEqual(PartialRestorePicker.offered(
            .document("doc-b"), allDocIds: all, mayWrite: mayWrite), nil)
        XCTAssertEqual(PartialRestorePicker.offered(
            .document("doc-a"), allDocIds: all, mayWrite: mayWrite), .document("doc-a"))
        XCTAssertFalse(PartialRestorePicker.mayWrite(through: nil)("doc-a"),
                       "no door behind the sheet fails closed")
    }

    func test_findOffersReplaceOnlyWhereTheMatchsOwnDocumentMayBeWritten() {
        let inA = match("manuscript/a.md", "A")
        let inB = match("manuscript/b.md", "B")
        let note = SearchMatch(
            documentPath: "research/n.md", documentTitle: "N", documentSource: .research,
            lineNumber: 1, charRangeInDocument: NSRange(location: 0, length: 3),
            linePreview: "Bob", matchRangeInLine: NSRange(location: 0, length: 3))

        XCTAssertTrue(ProjectSearchView.mayReplace(inA, posture: bookAuthor))
        XCTAssertFalse(ProjectSearchView.mayReplace(inA, posture: reviewer))
        XCTAssertFalse(ProjectSearchView.mayReplace(inA, posture: nil), "fails closed")
        XCTAssertTrue(ProjectSearchView.mayReplace(note, posture: nil),
                      "a research note is outside the permit")

        let results = SearchResults(query: "Bob", options: SearchOptions(),
                                    matches: [inA, inB, note])
        let split = ProjectSearchView.replaceability(
            results, mayReplace: { $0.documentPath != "manuscript/b.md" })
        XCTAssertEqual(split.replaceable, 2)
        XCTAssertEqual(split.leftAlone, ["B"])
        XCTAssertTrue(ProjectSearchView.offersReplaceAll(split))
        XCTAssertEqual(ProjectSearchView.replaceAllMessage(split),
            "2 matches will be replaced. Left as it was — this Mac may not change the text of B.")

        let none = ProjectSearchView.replaceability(
            SearchResults(query: "Bob", options: SearchOptions(), matches: [inA, inB]),
            mayReplace: { _ in false })
        XCTAssertFalse(ProjectSearchView.offersReplaceAll(none),
                       "a reviewer whose results are all manuscript sees no Replace All")
    }

    // MARK: - Asked once per document, and only what is listed (P3c plan 2 Task 9)

    /// **Find asks each DOCUMENT's posture once**, not each match row's: a
    /// chapter with many matches is one question, a research match none — and
    /// every row reads the answer its own document got, both directions.
    func test_findAsksEachDocumentsPostureOnceNotEachMatch() {
        let inA = (0..<6).map { _ in match("manuscript/a.md", "A") }
        let inB = (0..<4).map { _ in match("manuscript/b.md", "B") }
        let note = SearchMatch(
            documentPath: "research/n.md", documentTitle: "N", documentSource: .research,
            lineNumber: 1, charRangeInDocument: NSRange(location: 0, length: 3),
            linePreview: "Bob", matchRangeInLine: NSRange(location: 0, length: 3))
        let results = SearchResults(
            query: "Bob", options: SearchOptions(), matches: inA + inB + [note])

        var asked: [String] = []
        let gate = ProjectSearchView.ReplaceGate(results) { path in
            asked.append(path)
            return path == "manuscript/a.md" ? self.bookAuthor : self.reviewer
        }
        XCTAssertEqual(asked.sorted(), ["manuscript/a.md", "manuscript/b.md"],
                       "ten manuscript matches, two documents, two questions; the note none")
        XCTAssertTrue(inA.allSatisfy(gate.mayReplace), "hers: every row")
        XCTAssertFalse(inB.contains(where: gate.mayReplace), "not hers: no row")
        XCTAssertTrue(gate.mayReplace(note), "a research note is outside the permit")

        let noDoor = ProjectSearchView.ReplaceGate(results) { _ in nil }
        XCTAssertFalse(noDoor.mayReplace(inA[0]), "no door behind the host fails closed")
        XCTAssertEqual(asked.count, 2, "control: the second gate asked its own closure")
    }

    /// **History's Revert asks as little as it can**: nothing where no row is
    /// a checkpoint, and only until the first document the picker would list.
    func test_historysRevertAsksOnlyUntilThePickerHasADocument() {
        let checkpointRow = HistoryEntry.checkpoint(Checkpoint(
            checkpointId: "cp", label: "A", labelSource: .user,
            at: Date(), device: "d", activeDoc: "doc-a",
            docPointers: [:], manuscriptWordCount: 1))
        var asked: [String] = []
        let mayWrite: (String) -> Bool = { asked.append($0); return $0 == "doc-b" }

        XCTAssertFalse(HistoryPane.offersRevert(
            for: [], docIds: ["doc-a", "doc-b", "doc-c"], mayWrite: mayWrite))
        XCTAssertEqual(asked, [], "no checkpoint row: nothing to draw, nothing asked")

        XCTAssertTrue(HistoryPane.offersRevert(
            for: [checkpointRow], docIds: ["doc-a", "doc-b", "doc-c"], mayWrite: mayWrite))
        XCTAssertEqual(asked, ["doc-a", "doc-b"], "stops at the first listed document")

        asked = []
        XCTAssertFalse(HistoryPane.offersRevert(
            for: [checkpointRow], docIds: ["doc-a", "doc-c"], mayWrite: mayWrite))
        XCTAssertEqual(asked, ["doc-a", "doc-c"], "a reviewer's list: every one, once")
    }

    /// **The revert picker says what it left alone by TITLE**, in Replace
    /// All's words; a document the manifest does not name keeps its id rather
    /// than vanishing from the sentence.
    func test_theRevertPickersLeftAloneSentenceNamesTitles() {
        let structure = [
            StructureItem(id: "part", title: "Part One", type: .group, children: [
                StructureItem(id: "doc-a", title: "The Harbour", type: .document,
                              path: "manuscript/a.md"),
            ]),
            StructureItem(id: "doc-b", title: "Nightfall", type: .document,
                          path: "manuscript/b.md"),
        ]
        XCTAssertEqual(
            PartialRestorePicker.leftAloneSentence(
                for: ["doc-a", "doc-b", "doc-gone"], in: structure),
            "Left as it was — this Mac may not change the text of "
                + "The Harbour, Nightfall, doc-gone.")
        XCTAssertEqual(
            PartialRestorePicker.leftAloneSentence(for: ["doc-a"], in: structure),
            ProjectStore.leftAloneSentence(["The Harbour"]),
            "the same words as Replace All's")
        XCTAssertNil(PartialRestorePicker.leftAloneSentence(for: [], in: structure))
        XCTAssertEqual(PartialRestorePicker.titles(of: ["doc-a"], in: nil), ["doc-a"],
                       "no manifest: the id, never nothing")
    }

    // MARK: - Replace and the rename sweep, through the real registry

    private func match(_ path: String, _ title: String) -> SearchMatch {
        SearchMatch(
            documentPath: path, documentTitle: title, documentSource: .manuscript,
            lineNumber: 1, charRangeInDocument: NSRange(location: 0, length: 3),
            linePreview: "Bob", matchRangeInLine: NSRange(location: 0, length: 3))
    }

    private func results(_ titles: [String]) -> SearchResults {
        SearchResults(query: "Bob", options: SearchOptions(), matches: titles.map {
            match("manuscript/\($0.lowercased()).md", $0)
        })
    }

    /// A book of three chapters — A, B and C — each mentioning Bob, and B and
    /// C each linking to A.
    private func makeThreePieceProject() throws -> URL {
        let dir = TestTemp.root
            .appendingPathComponent("ManuscriptWriters-\(UUID().uuidString)")
        roots.append(dir)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        let bodies = [
            "a": "Bob in A.\n",
            "b": "Bob in B. See [[A]].\n",
            "c": "Bob in C. See [[A]].\n",
        ]
        for (slug, body) in bodies {
            try body.write(to: dir.appendingPathComponent("manuscript/\(slug).md"),
                           atomically: true, encoding: .utf8)
        }
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: ["a", "b", "c"].map {
                StructureItem(id: "doc-\($0)", title: $0.uppercased(), type: .document,
                              path: "manuscript/\($0).md")
            },
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: dir.appendingPathComponent("project.maugham.json"))
        return dir
    }

    private func beASigningMac(_ projectURL: URL) -> LocalIdentities {
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
        return identities
    }

    /// Every chapter bootstrapped into its op log, by this Mac's hand.
    private func bootstrap(_ projectURL: URL) async throws {
        for slug in ["a", "b", "c"] {
            let doc = try await Document.load(
                url: projectURL.appendingPathComponent("manuscript/\(slug).md"),
                actor: .author, session: "boot", presenter: nil)
            await doc.close()
        }
    }

    /// What a chapter says now, derived from its op log.
    private func text(_ projectURL: URL, _ slug: String) async throws -> String {
        let doc = try await Document.load(
            url: projectURL.appendingPathComponent("manuscript/\(slug).md"),
            actor: .author, session: "read", presenter: nil)
        let text = doc.displayText
        await doc.close()
        return text
    }

    /// This Mac roots the book and has admitted Sam as the author of B — so
    /// this Mac YIELDS on B (spec §2/§8) until it presses Edit Anyway. Wired:
    /// a `ProjectStore` with its window's `DocumentStore` behind it.
    private func aRootYieldingOnB() async throws -> (URL, ProjectStore, DocumentStore) {
        let projectURL = try makeThreePieceProject()
        _ = beASigningMac(projectURL)
        let documentStore = try await DocumentStore.open(url: projectURL)
        try await bootstrap(projectURL)
        let sam = LocalIdentities.softwareForTesting()
        _ = try await documentStore.admit(
            device: sam.author.fingerprint, label: "Sam", ownName: "Sam’s Mac",
            permit: .author(.pieces(["doc-b"])))
        await documentStore.postureSettled()
        let store = try await ProjectStore.load(from: projectURL)
        store.documentStore = documentStore
        documentStore.projectStore = store
        XCTAssertEqual(documentStore.posture(forDocId: "doc-b").yieldingTo, "Sam",
                       "precondition: this Mac yields on B")
        return (projectURL, store, documentStore)
    }

    /// **Replace All skips and names a document this Mac may not write**
    /// (ruling AI) — asked of the SETTLED posture, so the root's yield is
    /// honoured as the hidden per-match button honours it — and replaces the
    /// rest. After Edit Anyway, B is replaced too: both directions.
    func test_replaceAllSkipsAndNamesWhatThisMacMayNotWrite() async throws {
        let (projectURL, store, documentStore) = try await aRootYieldingOnB()

        let outcome = try await store.replaceAll(in: results(["A", "B", "C"]), with: "Ann")

        XCTAssertEqual(outcome.leftAlone, ["B"], "B was left, and named")
        let a = try await text(projectURL, "a")
        let b = try await text(projectURL, "b")
        let c = try await text(projectURL, "c")
        XCTAssertEqual(a, "Ann in A.")
        XCTAssertEqual(b, "Bob in B. See [[A]].", "nothing was written in B")
        XCTAssertEqual(c, "Ann in C. See [[A]].")

        documentStore.overrideYield(docId: "doc-b")
        let again = try await store.replaceAll(in: results(["B"]), with: "Ann")
        XCTAssertEqual(again.leftAlone, [])
        let bAfter = try await text(projectURL, "b")
        XCTAssertEqual(bAfter, "Ann in B. See [[A]].", "Edit Anyway: B is hers to change")
    }

    /// **A single Replace on a match this Mac may not write is refused** and
    /// says which piece.
    func test_replaceMatchRefusesAMatchThisMacMayNotWrite() async throws {
        // The window's DocumentStore is held for the whole test:
        // `ProjectStore.documentStore` is weak.
        let (projectURL, store, documentStore) = try await aRootYieldingOnB()
        defer { withExtendedLifetime(documentStore) {} }
        let found = results(["B"])
        store.currentSearch = found

        do {
            try await store.replaceMatch(found.matches[0], with: "Ann")
            XCTFail("the replace was not refused")
        } catch let refused as ProjectStore.ManuscriptReplaceRefused {
            XCTAssertEqual(refused.titles, ["B"])
        }
        let b = try await text(projectURL, "b")
        XCTAssertEqual(b, "Bob in B. See [[A]].")
    }

    /// **The rename's wiki-link sweep skips and names a piece this Mac may not
    /// write** (ruling AH): C's link follows the new title, B's is left and
    /// named — the rename itself is not refused.
    func test_theRenameSweepSkipsAndNamesWhatThisMacMayNotWrite() async throws {
        let (projectURL, store, documentStore) = try await aRootYieldingOnB()
        defer { withExtendedLifetime(documentStore) {} }

        let outcome = try await store.renameStructureItem(id: "doc-a", newTitle: "Omega")

        XCTAssertEqual(outcome.linksLeftIn, ["B"])
        XCTAssertNotNil(outcome.sentence)
        let b = try await text(projectURL, "b")
        let c = try await text(projectURL, "c")
        XCTAssertEqual(b, "Bob in B. See [[A]].", "B's link was left")
        XCTAssertEqual(c, "Bob in C. See [[Omega]].", "C's link followed the rename")
    }

    /// **The revert picker's door** asks each document the settled answer:
    /// B, yielded, is left; A and C are the root's to revert. No door behind
    /// the sheet leaves everything.
    func test_theRevertPickersDoorLeavesWhatThisMacMayNotWrite() async throws {
        let (_, _, documentStore) = try await aRootYieldingOnB()
        let split = await PartialRestorePicker.splitByTheDoor(
            ["doc-a", "doc-b", "doc-c"], documentStore: documentStore)
        XCTAssertEqual(split.writable, ["doc-a", "doc-c"])
        XCTAssertEqual(split.leftAlone, ["doc-b"])

        documentStore.overrideYield(docId: "doc-b")
        let overridden = await PartialRestorePicker.splitByTheDoor(
            ["doc-b"], documentStore: documentStore)
        XCTAssertEqual(overridden.writable, ["doc-b"], "Edit Anyway: B is hers")

        let noDoor = await PartialRestorePicker.splitByTheDoor(["doc-a"], documentStore: nil)
        XCTAssertEqual(noDoor.leftAlone, ["doc-a"], "no door behind the sheet fails closed")
    }

    /// **Every statement writer's one door**: `mutateStatementText` refuses
    /// where the statement Document's stamp refuses its text — for the open
    /// editor's Document here — and writes where it allows.
    func test_aStatementWriteIsRefusedWhereTheStatementsStampRefuses() async throws {
        let (dir, _) = try makeTestProject(prefix: "StatementDoor", initialMd: "Hello.\n")
        roots.append(dir)
        let statementPath = "intent/c1.md"
        let statement = Statement(
            id: "stmt-c1-intent", kind: .intent, scope: .document("doc-test"),
            path: statementPath)
        let manifestURL = dir.appendingPathComponent(ProjectManifest.fileName)
        var manifest = try ProjectManifest.makeDecoder()
            .decode(ProjectManifest.self, from: Data(contentsOf: manifestURL))
        manifest.statements = [statement]
        try ProjectManifest.makeEncoder().encode(manifest).write(to: manifestURL)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("intent"), withIntermediateDirectories: true)
        try "What it is for.\n".write(
            to: dir.appendingPathComponent(statementPath), atomically: true, encoding: .utf8)
        let store = try await ProjectStore.load(from: dir)
        let open = try await Document.load(
            url: dir.appendingPathComponent(statementPath),
            device: "test", session: "s", presenter: nil)
        store.noteStatementDocumentOpened(open, id: statement.id)
        open.stamp(localWritePermit: LocalWritePermit(
            permit: .reviewer, actor: .author,
            documentClass: .pieceStatement(piece: "doc-test")))

        do {
            try await store.mutateStatementText(of: statement, session: "s") { $0 + "\n\nMore." }
            XCTFail("the statement write was not refused")
        } catch is ProjectStore.StatementWriteRefused {}
        XCTAssertEqual(open.displayText, "What it is for.", "nothing was written")

        open.stamp(localWritePermit: .unrestricted)
        try await store.mutateStatementText(of: statement, session: "s") { $0 + "\n\nMore." }
        XCTAssertEqual(open.displayText, "What it is for.\n\nMore.", "promoted: written")
        await open.close()
    }

    // MARK: - No door behind the host fails closed (whole-branch fix wave, Minor 2)

    func test_aStoreWithNoDoorBehindItStartsNoPieceAndDrawsNoVerb() async throws {
        let (dir, _) = try makeTestProject(prefix: "NoDoor", initialMd: "Hello.\n")
        roots.append(dir)
        let store = try await ProjectStore.load(from: dir)
        XCTAssertNil(store.documentStore, "precondition: no window's door")

        XCTAssertEqual(StartAPieceDoor.drawn(store: store), false,
                       "a store with no door behind it says no, never the P1 menu")
        XCTAssertNil(StartAPieceDoor.drawn(store: nil), "no store at all says nothing")
        let admitted = await StartAPieceDoor.admits(store: store)
        XCTAssertFalse(admitted, "and the receiver starts nothing")
        XCTAssertFalse(TreeStructureVerbs.none.offersAny)
        XCTAssertEqual(TranslationAuthorVerbs.none.answer, false)
        XCTAssertEqual(TranslationAuthorVerbs.none.rule, false)
        XCTAssertEqual(TranslationAuthorVerbs.none.keepMine, false)
    }

    /// An author of A alone, admitted by another Mac — with NO `DocumentStore`
    /// behind the project store, so the loaded Document's own stamp is the
    /// only door.
    private func aPiecesAuthorOfAWithNoWindow() async throws -> (URL, ProjectStore) {
        let projectURL = try makeThreePieceProject()
        let identities = beASigningMac(projectURL)
        let root = try makeForeignRoot(projectURL, identities: identities)
        try await bootstrap(projectURL)
        let permit = Permit.author(.pieces(["doc-a"]))
        let mark = try OpLogStore.appliedPositions(
            ofDeviceIds: Set(identities.all.map(\.deviceId)), in: projectURL,
            trust: try TrustResolution.resolve(projectURL: projectURL, identities: identities))
        _ = try RegistryAdmission.changePermit(
            person: identities.author.fingerprint,
            role: permit.wireRole, scope: permit.wireScope, pieces: permit.wirePieces,
            mark: mark, unsigned: permit.narrows ? .nothingApplied : nil,
            in: projectURL, by: root,
            cache: RegistryCache(
                fileURL: projectURL.appendingPathComponent("root-cache.json"),
                identity: root.fingerprint))
        let store = try await ProjectStore.load(from: projectURL)
        XCTAssertNil(store.documentStore, "precondition: no window's door")
        return (projectURL, store)
    }

    func test_withNoWindowTheDocumentsStampIsTheReplaceDoor() async throws {
        let (projectURL, store) = try await aPiecesAuthorOfAWithNoWindow()

        let outcome = try await store.replaceAll(in: results(["A", "B"]), with: "Ann")

        XCTAssertEqual(outcome.leftAlone, ["B"])
        let a = try await text(projectURL, "a")
        let b = try await text(projectURL, "b")
        XCTAssertEqual(a, "Ann in A.", "her own piece is replaced")
        XCTAssertEqual(b, "Bob in B. See [[A]].", "somebody else's is left")
    }

    func test_withNoWindowTheDocumentsStampIsTheRenameSweepsDoor() async throws {
        let (projectURL, store) = try await aPiecesAuthorOfAWithNoWindow()

        let outcome = try await store.renameStructureItem(id: "doc-a", newTitle: "Omega")

        XCTAssertEqual(Set(outcome.linksLeftIn), ["B", "C"])
        let b = try await text(projectURL, "b")
        XCTAssertEqual(b, "Bob in B. See [[A]].")
    }

    private func makeForeignRoot(
        _ projectURL: URL, identities: LocalIdentities
    ) throws -> DeviceIdentity {
        let root = DeviceIdentity.softwareForTesting()
        try RegistryWriter.write(
            DeviceRecord(
                device: root.fingerprint, name: "The other Mac", kind: .mac,
                actors: [DeviceActor.author.rawValue: root.fingerprint],
                madeAt: Date(timeIntervalSince1970: 1_000)),
            signedBy: root, in: projectURL)
        try RegistryWriter.write(
            PersonRecord(
                person: root.fingerprint, label: "Sam", ownName: "The other Mac",
                role: Permit.authorRole,
                admittedAt: Date(timeIntervalSince1970: 1_000),
                admittedBy: root.fingerprint),
            signedBy: root, in: projectURL)
        try RegistryWriter.write(
            DeviceRecord(
                device: identities.author.fingerprint, name: "This Mac", kind: .mac,
                actors: Dictionary(uniqueKeysWithValues: DeviceActor.allCases.map {
                    ($0.rawValue, identities[$0].fingerprint)
                }),
                madeAt: Date(timeIntervalSince1970: 2_000)),
            signedBy: identities.author, in: projectURL)
        try RegistryWriter.write(
            PersonRecord(
                person: identities.author.fingerprint, label: "Denver",
                ownName: "This Mac", role: Permit.authorRole,
                admittedAt: Date(timeIntervalSince1970: 2_000),
                admittedBy: root.fingerprint),
            signedBy: root, in: projectURL)
        return root
    }
}
