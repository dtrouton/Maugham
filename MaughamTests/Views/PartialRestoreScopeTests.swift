// MaughamTests/Views/PartialRestoreScopeTests.swift
import XCTest
@testable import MaughamCore
@testable import Maugham

/// **The restore picker must not open scoped to a document that does not
/// exist.**
///
/// `PartialRestorePicker.init` seeded `_scope = .document(checkpoint.activeDoc)`
/// from whatever the record held. `checkpoints.jsonl` could hold a group id, or
/// `BinderSubject.noDocumentSubject`, so the radio group opened on a
/// `.document(...)` tag matching none of the offered rows — and pressing Revert
/// ran a restore over an id with no op log at all.
///
/// The write side stopped recording those (`CheckpointSubjectRecordTests`), but
/// **old checkpoints on disk still hold them** and tripwire 11 says no
/// migration. So this is a *read* fallback, and it has to cover more than the
/// new `nil`: every legacy shape, plus the case the sentinel never covered —
/// a document that was recorded honestly and has since been deleted.
///
/// One rule covers all of them, and it is the same membership test the write
/// side makes (`CheckpointCapture.documentSubject(of:in:)`): a recorded id is a
/// document only if it is in this project's document census.
final class PartialRestoreScopeTests: XCTestCase {

    private func checkpoint(activeDoc: String?) -> Checkpoint {
        Checkpoint(
            checkpointId: "cp-1", label: "L", labelSource: .auto,
            at: Date(timeIntervalSince1970: 0), device: "m",
            activeDoc: activeDoc,
            docPointers: ["doc-1": "op-1"],
            manuscriptWordCount: 3)
    }

    private let census = ["doc-1", "doc-2"]

    // MARK: - The control

    /// **The good path, first.** Without it every refusal below would still
    /// pass if the seed were replaced by a constant `.wholeProject`, and the
    /// picker would have quietly lost the convenience it exists for.
    func test_aRecordedDocumentStillOpensScopedToIt() {
        XCTAssertEqual(
            PartialRestorePicker.initialScope(
                for: checkpoint(activeDoc: "doc-1"), allDocIds: census),
            .document("doc-1"),
            "the picker opens on the document you were in — that is the whole "
            + "point of recording it")
    }

    // MARK: - The refusals

    func test_noRecordedDocumentPreselectsNothing() {
        XCTAssertNil(
            PartialRestorePicker.initialScope(
                for: checkpoint(activeDoc: nil), allDocIds: census),
            "the checkpoint indicates no scope, so the sheet must not choose "
            + "one on the writer's behalf")
    }

    /// The legacy value the binder's project row would have made routine.
    func test_aLegacySentinelPreselectsNothing() {
        XCTAssertNil(
            PartialRestorePicker.initialScope(
                for: checkpoint(activeDoc: BinderSubject.noDocumentSubject),
                allDocIds: census),
            "an old checkpoint still holds the sentinel — tripwire 11 says "
            + "handle it on read, not with a migration")
    }

    /// The legacy value that has always been reachable: select a Part, ⌘S.
    func test_aLegacyGroupIdPreselectsNothing() {
        XCTAssertNil(
            PartialRestorePicker.initialScope(
                for: checkpoint(activeDoc: "grp-1"), allDocIds: census),
            "select a Part, press ⌘S — the reproduction the binder has always "
            + "been able to produce")
    }

    /// **The case the sentinel never covered**, and the reason the fallback is
    /// a census membership test rather than a nil-check plus a sentinel
    /// compare: this checkpoint recorded a real document honestly and the
    /// writer has since deleted it.
    func test_aDeletedDocumentPreselectsNothing() {
        XCTAssertNil(
            PartialRestorePicker.initialScope(
                for: checkpoint(activeDoc: "doc-gone"), allDocIds: census),
            "a nil-check alone would still seed a scope naming a document the "
            + "picker does not offer")
    }

    /// An empty census is the `.wholeProject`-only picker; nothing may seed a
    /// document scope there.
    func test_anEmptyCensusOffersOnlyTheWholeProject() {
        XCTAssertEqual(
            PartialRestorePicker.initialScope(
                for: checkpoint(activeDoc: "doc-1"), allDocIds: []),
            .wholeProject)
    }

    // MARK: - The seed is what the picker actually opens with

    /// **The delivery path.** `initialScope` being right is worth nothing if
    /// `init` still seeds `_scope` from the raw field, so this asserts through
    /// the initializer the sheet calls rather than the helper beside it.
    ///
    /// **`seededScope` reads the `@State`'s own box for that reason.** Written
    /// first as a second stored property assigned from `initialScope` in the
    /// same `init`, the plant — a raw `.document(checkpoint.activeDoc)` on the
    /// `_scope` line — left this green: it was asserting a copy of the right
    /// answer sitting beside the wrong one that shipped.
    @MainActor
    func test_theInitializerSeedsItsScopeThroughTheFallback() {
        let picker = PartialRestorePicker(
            checkpoint: checkpoint(activeDoc: BinderSubject.noDocumentSubject),
            projectURL: URL(fileURLWithPath: "/tmp/nowhere"),
            activeDocId: BinderSubject.noDocumentSubject,
            allDocIds: census,
            figures: [],
            device: "m", session: "s",
            docPaths: [:], documentStore: nil,
            onComplete: {}, onCancel: {})

        XCTAssertEqual(
            picker.seededScope, nil,
            "the sheet's own initializer must go through the fallback — a "
            + "correct helper beside a raw seed is the defect, not the fix")
    }
}

/// **A revert reaches the book's figures** (report plan 6c Task 3, rulings
/// Q-1, Q-2, Q-3): each figure in scope with a pointer in the checkpoint is
/// wound back through its host — a closed one through a host opened for it
/// and released after — behind its own `.editFigure` door. What it left as it
/// was is named in the sheet's sentence beside the documents; the text's
/// revert is unchanged.
@MainActor
final class PartialRestoreFigureTests: XCTestCase {

    private var projectURL: URL!

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("revertfig-\(UUID().uuidString)")
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
        FigureDocument.betweenRestoreOpsForTesting = nil
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        try? FileManager.default.removeItem(at: projectURL)
    }

    // MARK: - Fixture

    /// Chapters A and B, each bootstrapped by this Mac's hand, and a window.
    private func openBook() async throws -> (DocumentStore, ProjectStore) {
        for slug in ["a", "b"] {
            try "Words.\n".write(to: file("manuscript/\(slug).md"), atomically: true, encoding: .utf8)
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
        for slug in ["a", "b"] {
            let doc = try await Document.load(
                url: file("manuscript/\(slug).md"), actor: .author, session: "boot", presenter: nil)
            await doc.close()
        }
        let projectStore = try await ProjectStore.load(from: projectURL)
        projectStore.documentStore = store
        store.projectStore = projectStore
        return (store, projectStore)
    }

    private func file(_ relative: String) -> URL { projectURL.appendingPathComponent(relative) }

    private func text(_ s: String) -> Cell { Cell(content: .value(.text(s))) }

    /// A table figure with "then" in its first cell, closed.
    private func table(
        _ name: String, piece: String?, _ store: DocumentStore, _ projectStore: ProjectStore
    ) async throws -> FigureRecord {
        let record = try await projectStore.createFigure(kind: .table, name: name, piece: piece)
        let host = try await store.openFigure(figureId: record.id)
        try await host.setCell(text("then"), at: firstCell(host))
        await store.closeFigure(figureId: record.id)
        return record
    }

    private func firstCell(_ host: FigureDocument) -> CellKey {
        CellKey(row: host.state.table.rows[0], column: host.state.table.columns[0])
    }

    /// The figure's first cell now, through a host opened for the read.
    private func firstCellNow(_ id: String, _ store: DocumentStore) async throws -> Cell? {
        let wasOpen = store.openFigure(forId: id) != nil
        let host = try await store.openFigure(figureId: id)
        let cell = host.state.table[firstCell(host)]
        if !wasOpen { await store.closeFigure(figureId: id) }
        return cell
    }

    /// `next` written into the figure's first cell, through a host closed after.
    private func edit(_ id: String, _ next: String, _ store: DocumentStore) async throws {
        let host = try await store.openFigure(figureId: id)
        try await host.setCell(text(next), at: firstCell(host))
        await store.closeFigure(figureId: id)
    }

    /// Every op line in every file of `id`'s stream, seals excluded, read
    /// without judging who signed it.
    private func rawOps(of id: String) throws -> [Op] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = JSONLAppendStore<Op>.dateDecoding
        return try OpLogStore.opLogFileURLs(forDocId: id, in: projectURL).flatMap { url in
            try Data(contentsOf: url)
                .split(separator: UInt8(0x0A), omittingEmptySubsequences: true)
                .compactMap { line -> Op? in
                    let data = Data(line)
                    return OpLogChain.isSealLine(data) ? nil : try? dec.decode(Op.self, from: data)
                }
        }
    }

    private func streamBytes(of id: String) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for url in OpLogStore.opLogFileURLs(forDocId: id, in: projectURL) {
            out[url.lastPathComponent] = try Data(contentsOf: url)
        }
        return out
    }

    /// A checkpoint holding the newest op of every stream named, as
    /// `CheckpointCapture` records it.
    private func checkpoint(of ids: [String]) async throws -> Checkpoint {
        let opStore = OpLogStore(projectURL: projectURL)
        var pointers: [String: String] = [:]
        for id in ids {
            let ops = try await opStore.load(docId: id)
            pointers[id] = try XCTUnwrap(ops.last?.opId)
        }
        return Checkpoint(
            checkpointId: "ckpt-revert", label: "Then", labelSource: .user,
            at: Date(), device: "m", activeDoc: "doc-a",
            docPointers: pointers, manuscriptWordCount: 2)
    }

    private func picker(
        _ checkpoint: Checkpoint, _ store: DocumentStore, _ projectStore: ProjectStore
    ) -> PartialRestorePicker {
        PartialRestorePicker(
            checkpoint: checkpoint, projectURL: projectURL, activeDocId: "doc-a",
            allDocIds: ["doc-a", "doc-b"],
            figures: projectStore.manifest.figures ?? [],
            device: DeviceIdentity.author.deviceId,
            session: "s",
            docPaths: ["doc-a": "manuscript/a.md", "doc-b": "manuscript/b.md"],
            documentStore: store, onComplete: {}, onCancel: {})
    }

    /// What a chapter says now, derived from its op log.
    private func chapter(_ slug: String) async throws -> String {
        let doc = try await Document.load(
            url: file("manuscript/\(slug).md"), actor: .author, session: "read", presenter: nil)
        let text = doc.displayText
        await doc.close()
        return text
    }

    // MARK: - Review Focus 2

    /// **Whole-project revert with one figure parked and one created after
    /// the checkpoint**: the parked one is skipped and named, the new one is
    /// untouched, the rest restore (a closed figure through a host opened and
    /// released for it), and the text restores as before.
    func test_reviewFocus2_parkedSkippedAndNamed_newUntouched_restRestore_textAsBefore() async throws {
        let (store, projectStore) = try await openBook()
        let kept = try await table("kept", piece: nil, store, projectStore)
        let parked = try await table("parked", piece: nil, store, projectStore)
        let cp = try await checkpoint(of: ["doc-a", "doc-b", kept.id, parked.id])

        try await edit(kept.id, "since", store)
        let parkedHost = try await store.openFigure(figureId: parked.id)
        try await parkedHost.setCell(text("since"), at: firstCell(parkedHost))
        try await parkedHost.parkInResearch(
            path: "research/parked.csv", hash: "h", itemId: "item-1",
            expecting: parkedHost.state, alongside: {})
        await store.closeFigure(figureId: parked.id)
        let fresh = try await table("fresh", piece: nil, store, projectStore)
        try await edit(fresh.id, "new", store)
        let a = try await Document.load(
            url: file("manuscript/a.md"), actor: .author, session: "edit", presenter: nil)
        a.setFullText("Words, and more since.")
        await a.close()
        let changed = try await chapter("a")
        XCTAssertEqual(changed, "Words, and more since.", "precondition: the text changed")
        let parkedBefore = try streamBytes(of: parked.id)
        let freshBefore = try streamBytes(of: fresh.id)

        let sentence = await picker(cp, store, projectStore).restore(.wholeProject)

        let keptNow = try await firstCellNow(kept.id, store)
        XCTAssertEqual(keptNow, text("then"), "the rest restore")
        XCTAssertNil(store.openFigure(forId: kept.id), "the host opened for the revert is released")
        XCTAssertEqual(try streamBytes(of: parked.id), parkedBefore, "the parked figure is skipped")
        XCTAssertEqual(try streamBytes(of: fresh.id), freshBefore, "a figure made since is untouched")
        let said = try XCTUnwrap(sentence, "the sheet names the parked figure")
        XCTAssertTrue(said.contains("parked") && said.contains("bring it back first"), said)
        XCTAssertFalse(said.contains("kept") || said.contains("fresh"), said)
        // The text half is the picker's own raw `OpLogStore` append, signed by
        // this process's identities rather than the fixture's, so it is read
        // back raw: one `.checkpointRestore` for A, stamped, turning its
        // paragraph back to what it said then.
        let restores = try rawOps(of: "doc-a").filter { $0.kind == .checkpointRestore }
        XCTAssertEqual(restores.map { $0.provenance?.sourceCheckpoint }, [cp.checkpointId],
                       "the text restores as before")
        XCTAssertEqual(restores.first?.changes.map(\.next), ["Words."])
    }

    /// An open figure is wound back through the host the window holds, which
    /// stays open.
    func test_anOpenFigureRestoresThroughItsOwnHostAndStaysOpen() async throws {
        let (store, projectStore) = try await openBook()
        let kept = try await table("kept", piece: nil, store, projectStore)
        let cp = try await checkpoint(of: ["doc-a", "doc-b", kept.id])
        let host = try await store.openFigure(figureId: kept.id)
        try await host.setCell(text("since"), at: firstCell(host))

        let sentence = await picker(cp, store, projectStore).restore(.wholeProject)

        XCTAssertNil(sentence)
        XCTAssertTrue(store.openFigure(forId: kept.id) === host, "the window's host stays open")
        XCTAssertEqual(host.state.table[firstCell(host)], text("then"))
        await store.closeFigure(figureId: kept.id)
    }

    // MARK: - Scope

    /// **Document scope touches only that document's figures** (Q-3): A's
    /// figure restores; B's and the whole book's are left as they are.
    func test_documentScopeTouchesOnlyThatDocumentsFigures() async throws {
        let (store, projectStore) = try await openBook()
        let ofA = try await table("of_a", piece: "doc-a", store, projectStore)
        let ofB = try await table("of_b", piece: "doc-b", store, projectStore)
        let book = try await table("book", piece: nil, store, projectStore)
        let cp = try await checkpoint(of: ["doc-a", "doc-b", ofA.id, ofB.id, book.id])
        for id in [ofA.id, ofB.id, book.id] { try await edit(id, "since", store) }
        let ofBBefore = try streamBytes(of: ofB.id)
        let bookBefore = try streamBytes(of: book.id)

        let sentence = await picker(cp, store, projectStore).restore(.document("doc-a"))

        XCTAssertNil(sentence)
        let ofANow = try await firstCellNow(ofA.id, store)
        XCTAssertEqual(ofANow, text("then"))
        XCTAssertEqual(try streamBytes(of: ofB.id), ofBBefore, "another piece's figure is untouched")
        XCTAssertEqual(try streamBytes(of: book.id), bookBefore, "a whole-book figure is untouched")
    }

    // MARK: - The door

    /// **A refused figure is named and the rest restore** (Q-2): B is yielded
    /// to Sam, so B's figure is left as it was and named beside B's text; A's
    /// figure restores.
    func test_aRefusedFigureIsNamedAndTheRestRestore() async throws {
        let (store, projectStore) = try await openBook()
        let ofA = try await table("of_a", piece: "doc-a", store, projectStore)
        let ofB = try await table("of_b", piece: "doc-b", store, projectStore)
        let cp = try await checkpoint(of: ["doc-a", "doc-b", ofA.id, ofB.id])
        for id in [ofA.id, ofB.id] { try await edit(id, "since", store) }
        let sam = LocalIdentities.softwareForTesting()
        _ = try await store.admit(
            device: sam.author.fingerprint, label: "Sam", ownName: "Sam’s Mac",
            permit: .author(.pieces(["doc-b"])))
        await store.postureSettled()
        let ofBBefore = try streamBytes(of: ofB.id)

        let sentence = await picker(cp, store, projectStore).restore(.wholeProject)

        let ofANow = try await firstCellNow(ofA.id, store)
        XCTAssertEqual(ofANow, text("then"), "the rest restore")
        XCTAssertEqual(try streamBytes(of: ofB.id), ofBBefore, "the refused figure is left")
        let said = try XCTUnwrap(sentence)
        XCTAssertTrue(said.contains("figure of_b"), said)
        XCTAssertFalse(said.contains("of_a"), said)
    }

    /// **The picker asks the door itself, before any host opens** (Q-2): B's
    /// figure is parked, then B is yielded to Sam. The picker's door answers
    /// `.refused`; without it the host would answer `.skippedParked` (its
    /// park check runs before its posture check), so this pins the picker's.
    func test_theDoorIsAskedBeforeTheHost_aParkedFigureInAYieldedPieceIsRefused() async throws {
        let (store, projectStore) = try await openBook()
        let ofB = try await table("of_b", piece: "doc-b", store, projectStore)
        let cp = try await checkpoint(of: ["doc-a", "doc-b", ofB.id])
        let host = try await store.openFigure(figureId: ofB.id)
        try await host.setCell(text("since"), at: firstCell(host))
        try await host.parkInResearch(
            path: "research/of_b.csv", hash: "h", itemId: "item-1",
            expecting: host.state, alongside: {})
        await store.closeFigure(figureId: ofB.id)
        let sam = LocalIdentities.softwareForTesting()
        _ = try await store.admit(
            device: sam.author.fingerprint, label: "Sam", ownName: "Sam’s Mac",
            permit: .author(.pieces(["doc-b"])))
        await store.postureSettled()

        let results = await PartialRestorePicker.restoreFigures(
            projectStore.manifest.figures ?? [], in: .wholeProject, to: cp, documentStore: store)

        XCTAssertEqual(results.map(\.result), [.refused])
        XCTAssertNil(store.openFigure(forId: ofB.id), "no host was opened for a refused figure")
    }

    /// **A figure removed after the sheet was built is left alone** (Q-1): the
    /// sheet's list still names it, the live registry does not.
    func test_aFigureRemovedAfterThePickerWasBuiltIsLeftAlone() async throws {
        let (store, projectStore) = try await openBook()
        let gone = try await table("gone", piece: nil, store, projectStore)
        let cp = try await checkpoint(of: ["doc-a", "doc-b", gone.id])
        try await edit(gone.id, "since", store)
        let sheet = picker(cp, store, projectStore)
        try await projectStore.removeFigure(id: gone.id)
        let before = try streamBytes(of: gone.id)

        let results = await PartialRestorePicker.restoreFigures(
            sheet.figures, in: .wholeProject, to: cp, documentStore: store)
        let sentence = await sheet.restore(.wholeProject)

        XCTAssertTrue(results.isEmpty, "not reported at all: \(results.map(\.result))")
        XCTAssertNil(sentence)
        XCTAssertEqual(try streamBytes(of: gone.id), before, "its stream is untouched")
    }

    /// **A host someone else opened during the restore stays open**: the
    /// restore opened it for itself, and the window asked to keep it between
    /// the restore's two ops.
    func test_aHostOpenedByAnotherCallerDuringTheRestoreStaysOpen() async throws {
        let (store, projectStore) = try await openBook()
        let kept = try await table("kept", piece: nil, store, projectStore)
        let cp = try await checkpoint(of: ["doc-a", "doc-b", kept.id])
        let host = try await store.openFigure(figureId: kept.id)
        try await host.setCell(text("since"), at: firstCell(host))
        try await host.setCell(text("more"), at: CellKey(
            row: host.state.table.rows[1], column: host.state.table.columns[0]))
        await store.closeFigure(figureId: kept.id)
        var openedMeanwhile: FigureDocument?
        FigureDocument.betweenRestoreOpsForTesting = { _ in
            openedMeanwhile = try? await store.openFigure(figureId: kept.id)
        }

        let sentence = await picker(cp, store, projectStore).restore(.wholeProject)

        XCTAssertNil(sentence)
        XCTAssertNotNil(openedMeanwhile, "precondition: the restore made two ops")
        XCTAssertTrue(store.openFigure(forId: kept.id) === openedMeanwhile,
                      "the host the window opened meanwhile stays open")
        XCTAssertEqual(store.openFigure(forId: kept.id)?.state.table[firstCell(host)], text("then"))
        await store.closeFigure(figureId: kept.id)
    }

    /// `withFigureHost` closes a host it opened, keeps one already open, and
    /// keeps one someone opened during the loan.
    func test_withFigureHostClosesOnlyWhatItAloneOpened() async throws {
        let (store, projectStore) = try await openBook()
        let fig = try await table("fig", piece: nil, store, projectStore)

        try await store.withFigureHost(fig.id) { _ in }
        XCTAssertNil(store.openFigure(forId: fig.id), "a host it opened is closed")

        let open = try await store.openFigure(figureId: fig.id)
        try await store.withFigureHost(fig.id) { XCTAssertTrue($0 === open) }
        XCTAssertTrue(store.openFigure(forId: fig.id) === open, "a host already open stays open")
        await store.closeFigure(figureId: fig.id)

        try await store.withFigureHost(fig.id) { _ in
            _ = try await store.openFigure(figureId: fig.id)
        }
        XCTAssertNotNil(store.openFigure(forId: fig.id), "a host opened during the loan stays open")
        await store.closeFigure(figureId: fig.id)

        struct Boom: Error {}
        do { try await store.withFigureHost(fig.id) { _ in throw Boom() } } catch is Boom {}
        XCTAssertNil(store.openFigure(forId: fig.id), "a failed act still closes what it opened")
    }

    /// No door behind the sheet fails closed: every figure is refused.
    func test_noDoorRefusesEveryFigure() async throws {
        let cp = Checkpoint(
            checkpointId: "c", label: "L", labelSource: .auto, at: Date(), device: "m",
            activeDoc: nil, docPointers: ["fig-00000001": "op-1"], manuscriptWordCount: 0)
        let record = FigureRecord(
            id: "fig-00000001", name: "t", kind: .table, piece: nil, path: "figures/t.csv")
        let results = await PartialRestorePicker.restoreFigures(
            [record], in: .wholeProject, to: cp, documentStore: nil)
        XCTAssertEqual(results.map(\.result), [.refused])
    }

    /// The figures in scope: a pointer is required, and a document's are its
    /// piece's.
    func test_theFiguresInScope() {
        let cp = Checkpoint(
            checkpointId: "c", label: "L", labelSource: .auto, at: Date(), device: "m",
            activeDoc: nil, docPointers: ["fig-a": "1", "fig-b": "1", "fig-w": "1"],
            manuscriptWordCount: 0)
        let records = [("fig-a", "doc-a"), ("fig-b", "doc-b"), ("fig-w", nil), ("fig-new", nil)]
            .map { FigureRecord(id: $0.0, name: $0.0, kind: .table, piece: $0.1, path: "figures/x.csv") }
        XCTAssertEqual(
            PartialRestorePicker.figuresInScope(records, .wholeProject, of: cp).map(\.id),
            ["fig-a", "fig-b", "fig-w"], "a figure made since has no pointer")
        XCTAssertEqual(
            PartialRestorePicker.figuresInScope(records, .document("doc-a"), of: cp).map(\.id),
            ["fig-a"])
    }

    /// The sentence names each kind of figure a revert did not fully restore,
    /// and none it did.
    func test_theSentenceNamesEachFigureLeftOrPartlyRestored() {
        func r(_ name: String) -> FigureRecord {
            FigureRecord(id: "fig-\(name)", name: name, kind: .table, piece: nil, path: "figures/\(name).csv")
        }
        let said = PartialRestorePicker.figureSentence(for: [
            (r("done"), .outcome(.restored(opCount: 2))),
            (r("same"), .outcome(.unchanged)),
            (r("theirs"), .refused),
            (r("away"), .outcome(.skippedParked)),
            (r("chart"), .outcome(.skippedPicture(hash: "h", opCount: 1))),
            (r("half"), .outcome(.partlyRestored(opCount: 1, why: .changedElsewhere))),
            (r("broke"), .failed("disk full")),
        ])
        XCTAssertEqual(said, "Left as it was — this Mac may not change the figure theirs. "
            + "Not restored, in Research — bring it back first: away. "
            + "The rest restored, but the picture from then is no longer on disk: chart. "
            + "Partly restored — revert again to finish: half. "
            + "Not restored: broke (disk full).")
        XCTAssertNil(PartialRestorePicker.figureSentence(for: [
            (r("done"), .outcome(.restored(opCount: 1))), (r("same"), .outcome(.unchanged))]))
    }
}
