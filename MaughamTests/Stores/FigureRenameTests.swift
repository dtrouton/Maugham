import XCTest
import AppKit
@testable import Maugham
@testable import MaughamCore

/// **Renaming and removing a figure** (report plan 6b Task 5, ruling P-3).
///
/// A rename relabels the text, all or nothing: every door — the figure's own
/// `.editFigure` posture and the `.writeText` door of every manuscript that
/// holds its line or a cross-reference to its label — is asked first, and any
/// refusal changes nothing (Review Focus 4). A removal sends the figure's file
/// to the project Trash carrying its record, and keeps its stream.
@MainActor
final class FigureRenameTests: XCTestCase {

    private var projectURL: URL!

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("figrename-\(UUID().uuidString)")
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
        try? FileManager.default.removeItem(at: projectURL)
    }

    // MARK: - Fixture

    /// Chapters A, B and C with these bodies, each bootstrapped into its op
    /// log by this Mac's hand, and a window over the book.
    private func openBook(
        a: String = "Words.\n", b: String = "More words.\n", c: String = "Last words.\n"
    ) async throws -> (DocumentStore, ProjectStore) {
        for (slug, body) in [("a", a), ("b", b), ("c", c)] {
            try body.write(to: chapter(slug), atomically: true, encoding: .utf8)
        }
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: ["a", "b", "c"].map {
                StructureItem(id: "doc-\($0)", title: $0.uppercased(), type: .document,
                              path: "manuscript/\($0).md")
            },
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: projectURL.appendingPathComponent(ProjectManifest.fileName))
        let store = try await DocumentStore.open(url: projectURL)
        for slug in ["a", "b", "c"] {
            let doc = try await Document.load(url: chapter(slug), actor: .author, session: "boot", presenter: nil)
            await doc.close()
        }
        let projectStore = try await ProjectStore.load(from: projectURL)
        projectStore.documentStore = store
        store.projectStore = projectStore
        return (store, projectStore)
    }

    private func chapter(_ slug: String) -> URL {
        projectURL.appendingPathComponent("manuscript/\(slug).md")
    }

    /// What a chapter says now, derived from its op log.
    private func text(_ slug: String) async throws -> String {
        let doc = try await Document.load(url: chapter(slug), actor: .author, session: "read", presenter: nil)
        let text = doc.displayText
        await doc.close()
        return text
    }

    private func file(_ relative: String) -> URL { projectURL.appendingPathComponent(relative) }

    private func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: file(relative).path)
    }

    private func csv(_ relative: String) throws -> String {
        try String(contentsOf: file(relative), encoding: .utf8)  // adr-0018-ok: test reads the derived render to assert what was written
    }

    private func number(_ x: Double) -> Cell { Cell(content: .value(.number(x))) }

    /// `cash` with 5 in A1, and `total` whose A1 is `cash!A1*2`.
    private func cashAndTotal(
        _ store: DocumentStore, _ projectStore: ProjectStore
    ) async throws -> (cash: FigureRecord, total: FigureRecord, totalCell: CellKey) {
        let cash = try await projectStore.createFigure(kind: .table, name: "cash", piece: nil)
        let total = try await projectStore.createFigure(kind: .table, name: "total", piece: nil)
        let cashDoc = try await store.openFigure(figureId: cash.id)
        try await cashDoc.setCell(number(5), at: CellKey(
            row: cashDoc.state.table.rows[0], column: cashDoc.state.table.columns[0]))
        let totalDoc = try await store.openFigure(figureId: total.id)
        let t1 = CellKey(row: totalDoc.state.table.rows[0], column: totalDoc.state.table.columns[0])
        let names = FormulaNames(figures: [.init(id: cash.id, name: "cash", table: cashDoc.state.table)])
        guard case .success(let f) = FormulaParser.parse("cash!A1*2", in: totalDoc.state.table, names: names)
        else { throw FigureEditInvalid(reason: "the formula did not parse") }
        try await totalDoc.setCell(Cell(content: .formula(f)), at: t1)
        await store.closeFigure(figureId: cash.id)
        await store.closeFigure(figureId: total.id)
        return (cash, total, t1)
    }

    /// How `total`'s formula reads now, under the registry's current names —
    /// each table read windowless (`documentStore: nil`), so asking renders
    /// nothing.
    private func formulaText(
        _ store: DocumentStore, _ projectStore: ProjectStore,
        total: FigureRecord, cell: CellKey
    ) async throws -> String? {
        var tables: [String: FigureTable] = [:]
        for record in projectStore.manifest.figures ?? [] where record.kind == .table {
            let doc = try await FigureDocument.load(
                figureId: record.id, projectURL: projectURL, actor: .author,
                session: "read", presenter: nil, documentStore: nil)
            tables[record.id] = doc.state.table
            await doc.close()
        }
        guard let table = tables[total.id],
              case .formula(let f)? = table[cell]?.content else { return nil }
        let names = FormulaNames(records: projectStore.manifest.figures ?? [],
                                 tables: tables, research: projectStore.manifest.research)
        return FormulaParser.render(f, in: table, names: names)
    }

    /// Runs `body` with the project folder read-only, so `saveManifest`'s
    /// temporary file cannot be made — the disk's own failure, not a seam.
    /// Its subfolders stay writable.
    private func withUnwritableProjectFolder(_ body: () async throws -> Void) async throws {
        let fm = FileManager.default
        let original = try XCTUnwrap(fm.attributesOfItem(atPath: projectURL.path)[.posixPermissions] as? NSNumber)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: projectURL.path)
        defer { try? fm.setAttributes([.posixPermissions: original], ofItemAtPath: projectURL.path) }
        try await body()
    }

    /// A real PNG outside the project, of one colour.
    private func png(_ name: String, _ color: NSColor) throws -> URL {
        let dir = TestTemp.root.appendingPathComponent("figrename-png-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        let url = dir.appendingPathComponent(name)
        try ImagePasteHandler.encodePNG(image).write(to: url)
        return url
    }

    // MARK: - A rename relabels the text

    /// **A rename relabels the figure's line and a cross-reference in another
    /// document**, moves its render, and a formula in another figure shows
    /// the new name with nothing written to it (R-D1).
    func test_aRenameRelabelsTheLineAndACrossReferenceElsewhere_andMovesTheRender() async throws {
        let (store, projectStore) = try await openBook(
            a: "![Cash](../figures/cash.csv){#tbl:cash}\n",
            b: "See @tbl:cash and [@tbl:cash], not @tbl:cashflow.\n")
        let (cash, total, t1) = try await cashAndTotal(store, projectStore)
        XCTAssertTrue(exists("figures/cash.csv"), "precondition: the render is there")
        let totalOps = try OpLogStore.loadSyncMerged(forDocId: total.id, in: projectURL, facts: .empty).count

        let renamed = try await projectStore.renameFigure(id: cash.id, to: "costs")

        XCTAssertEqual(renamed.name, "costs")
        XCTAssertEqual(renamed.path, "figures/costs.csv")
        XCTAssertEqual(projectStore.manifest.figures?.first { $0.id == cash.id }, renamed)
        let a = try await text("a")
        let b = try await text("b")
        XCTAssertEqual(a, "![Cash](../figures/costs.csv){#tbl:costs}")
        XCTAssertEqual(b, "See @tbl:costs and [@tbl:costs], not @tbl:cashflow.")
        XCTAssertFalse(exists("figures/cash.csv"), "the old render is gone")
        XCTAssertEqual(try csv("figures/costs.csv"), "5,,\n,,\n,,\n", "the new render is there")
        let shown = try await formulaText(store, projectStore, total: total, cell: t1)
        XCTAssertEqual(shown, "costs!A1*2")
        XCTAssertEqual(try OpLogStore.loadSyncMerged(forDocId: total.id, in: projectURL, facts: .empty).count,
                       totalOps, "the reader's stream was not written")
    }

    /// **The relabel's sites, and only those**: the line's label and file,
    /// bare and bracketed references; a longer label, a code fence and a
    /// line naming another file are left.
    func test_theRelabelChangesOnlyTheFiguresOwnSites() {
        let change = ProjectStore.FigureLabelChange(
            old: ManuscriptLabel(reference: "tbl:cash")!, newName: "costs",
            oldFile: "cash.csv", newFile: "costs.csv")
        let text = """
        ![Cash](figures/cash.csv){#tbl:cash}

        See @tbl:cash, [@tbl:cash; @fig:map] and @tbl:cashflow.

        ```
        @tbl:cash stays in code
        ```
        """
        XCTAssertEqual(ProjectStore.relabelled(text, change), """
        ![Cash](figures/costs.csv){#tbl:costs}

        See @tbl:costs, [@tbl:costs; @fig:map] and @tbl:cashflow.

        ```
        @tbl:cash stays in code
        ```
        """)
        XCTAssertNil(ProjectStore.relabelled("Nothing here about @tbl:cashflow.\n", change))
    }

    /// **A rename that separates two records sharing one file renders both**:
    /// the shared file is the other record's, so it is not moved, and the
    /// renamed one renders at its own new file.
    func test_aRenameThatSeparatesTwoRecordsSharingAFileRendersBoth() async throws {
        let (store, projectStore) = try await openBook()
        let one = try await projectStore.createFigure(kind: .table, name: "cash", piece: nil)
        let two = try await projectStore.createFigure(kind: .table, name: "other", piece: nil)
        var figures = try XCTUnwrap(projectStore.manifest.figures)
        figures[1] = FigureRecord(id: two.id, name: "cash", kind: .table, piece: nil, path: one.path)
        projectStore.manifest.figures = figures
        try "edited,in,Excel\n".write(to: file(one.path), atomically: true, encoding: .utf8)

        _ = try await projectStore.renameFigure(id: two.id, to: "split")

        XCTAssertEqual(try csv("figures/cash.csv"), ",,\n,,\n,,\n", "the one left on the file renders it")
        XCTAssertEqual(try csv("figures/split.csv"), ",,\n,,\n,,\n", "the renamed one renders its own")
        withExtendedLifetime(store) {}
    }

    /// **A rename that changes only the name's case is the figure's own**:
    /// not refused as taken, and the render file takes the new case on a
    /// case-insensitive disk.
    func test_aCaseOnlyRenameIsAllowedAndTheFileTakesTheNewCase() async throws {
        let (store, projectStore) = try await openBook()
        defer { withExtendedLifetime(store) {} }
        let cash = try await projectStore.createFigure(kind: .table, name: "cash", piece: nil)

        let renamed = try await projectStore.renameFigure(id: cash.id, to: "Cash")

        XCTAssertEqual(renamed.path, "figures/Cash.csv")
        let names = try FileManager.default.contentsOfDirectory(atPath: file("figures").path)
        XCTAssertEqual(names.filter { !$0.hasPrefix(".") }, ["Cash.csv"])
    }

    /// **A file standing at the renamed table's new render path goes to the
    /// Trash first**, never overwritten unlisted.
    func test_aStrayFileAtTheNewRenderPathGoesToTheTrashFirst() async throws {
        let (store, projectStore) = try await openBook()
        let (cash, _, _) = try await cashAndTotal(store, projectStore)
        try "my own notes\n".write(to: file("figures/costs.csv"), atomically: true, encoding: .utf8)

        _ = try await projectStore.renameFigure(id: cash.id, to: "costs")

        XCTAssertEqual(try csv("figures/costs.csv"), "5,,\n,,\n,,\n")
        let kept = try await projectStore.trashStore.entriesIncludingInternal()
        let stray = try XCTUnwrap(kept.first { $0.subject == .internalArtifact && $0.displayTitle == "costs.csv" })
        let trashed = try XCTUnwrap(projectStore.trashStore.entryFileURL(trashId: stray.id))
        XCTAssertEqual(try String(contentsOf: trashed, encoding: .utf8), "my own notes\n")  // adr-0018-ok: test reads the trashed stray file
    }

    /// **A failed save puts a rename back**: the picture is moved back and
    /// the stream names its old file again; the record, the text and the
    /// files are as they were.
    func test_aRenameWhoseSaveFailsPutsThePictureBackAndWritesNoText() async throws {
        let (store, projectStore) = try await openBook()
        defer { withExtendedLifetime(store) {} }
        let image = try await projectStore.createImageFigure(
            fromURL: try png("map.png", .red), name: "map", piece: nil)
        let a = try await Document.load(url: chapter("a"), actor: .author, session: "t", presenter: nil)
        a.setFullText("![Map](../figures/map.png){#fig:map}")
        await a.close()

        try await withUnwritableProjectFolder {
            do {
                _ = try await projectStore.renameFigure(id: image.id, to: "chart")
                XCTFail("the save did not fail")
            } catch let error as ProjectStoreError {
                guard case .manifestUnwritable = error else { return XCTFail("\(error)") }
            }
        }
        XCTAssertEqual(projectStore.manifest.figures, [image])
        XCTAssertTrue(exists("figures/map.png"))
        XCTAssertFalse(exists("figures/chart.png"))
        let last = try OpLogStore.loadSyncMerged(forDocId: image.id, in: projectURL, facts: .empty)
            .compactMap { $0.figure?.image }.last
        XCTAssertEqual(last?.filename, "map.png", "the stream names the old file again")
        let text = try await text("a")
        XCTAssertEqual(text, "![Map](../figures/map.png){#fig:map}")
    }

    /// **A manuscript whose door closed after it was held refuses the whole
    /// rename** (M1): A is written first, B refuses at the write, so A is put
    /// back and the record goes back too — nothing changed.
    func test_aDoorClosingAfterTheHoldRefusesTheWholeRenameAndPutsEverythingBack() async throws {
        let (store, projectStore) = try await openBook(
            a: "![Cash](../figures/cash.csv){#tbl:cash}\n", b: "See @tbl:cash.\n")
        let (cash, total, t1) = try await cashAndTotal(store, projectStore)
        let before = try await snapshot(store, projectStore, total: total, cell: t1)
        ProjectStore.beforeFigureRelabelWriteForTesting = { held in
            if let b = held.manuscripts.first(where: { $0.title == "B" }) { await b.manuscript.doc.close() }
        }
        defer { ProjectStore.beforeFigureRelabelWriteForTesting = nil }

        do {
            _ = try await projectStore.renameFigure(id: cash.id, to: "costs")
            XCTFail("the rename was not refused")
        } catch let refused as FigureRenameRefused {
            XCTAssertEqual(refused.reason, .piecesNotWritable(["B"]))
        }
        ProjectStore.beforeFigureRelabelWriteForTesting = nil
        let after = try await snapshot(store, projectStore, total: total, cell: t1)
        XCTAssertEqual(after, before, "registry, files, text and formulas are all as they were")
    }

    // MARK: - Review Focus 4: refused, nothing changed

    /// What a refused rename must leave exactly as it was.
    private struct Snapshot: Equatable {
        let figures: [FigureRecord]?
        let a: String
        let b: String
        let cashCSV: Bool
        let costsCSV: Bool
        let formula: String?
    }

    private func snapshot(
        _ store: DocumentStore, _ projectStore: ProjectStore,
        total: FigureRecord, cell: CellKey
    ) async throws -> Snapshot {
        let onDisk = try ProjectManifest.decodeGuardingSchema(Data(contentsOf: file(ProjectManifest.fileName)))
        XCTAssertEqual(onDisk.figures, projectStore.manifest.figures, "the registry on disk is the one in memory")
        let a = try await text("a")
        let b = try await text("b")
        let formula = try await formulaText(store, projectStore, total: total, cell: cell)
        return Snapshot(
            figures: projectStore.manifest.figures, a: a, b: b,
            cashCSV: exists("figures/cash.csv"), costsCSV: exists("figures/costs.csv"),
            formula: formula)
    }

    /// **A name another figure has — exactly, or in another case — is
    /// refused** (the `lowercased()` fold formulas match names with), and
    /// nothing changes: registry, files, text, formulas.
    func test_aNameAnotherFigureHasInAnyCaseIsRefusedAndNothingChanges() async throws {
        let (store, projectStore) = try await openBook(
            a: "![Cash](../figures/cash.csv){#tbl:cash}\n", b: "See @tbl:cash.\n")
        let (cash, total, t1) = try await cashAndTotal(store, projectStore)
        let before = try await snapshot(store, projectStore, total: total, cell: t1)

        for name in ["total", "TOTAL", "  Total "] {
            do {
                _ = try await projectStore.renameFigure(id: cash.id, to: name)
                XCTFail("renaming to \(name) was not refused")
            } catch let refused as FigureRenameRefused {
                XCTAssertEqual(refused.reason, .nameTaken("total"))
            }
            let after = try await snapshot(store, projectStore, total: total, cell: t1)
            XCTAssertEqual(after, before, "renaming to \(name) changed something")
        }
        do {
            _ = try await projectStore.renameFigure(id: cash.id, to: "   ")
            XCTFail("an empty name was not refused")
        } catch let refused as FigureRenameRefused {
            XCTAssertEqual(refused.reason, .emptyName)
        }
        XCTAssertEqual(before.formula, "cash!A1*2")
    }

    /// **A figure referenced in a piece this Mac may not write is not
    /// renamed**: this Mac roots the book and yields on B to Sam, its author.
    /// A holds the figure's line and is writable, B refers to it: the rename
    /// is refused naming B, and A is NOT relabelled — nothing changed. After
    /// *Edit Anyway* on B, the same rename goes through: both directions.
    func test_aFigureReferencedInAPieceThisMacMayNotWriteIsRefusedAndNothingChanges() async throws {
        let (store, projectStore) = try await openBook(
            a: "![Cash](../figures/cash.csv){#tbl:cash}\n", b: "See @tbl:cash.\n")
        let (cash, total, t1) = try await cashAndTotal(store, projectStore)
        let sam = LocalIdentities.softwareForTesting()
        _ = try await store.admit(
            device: sam.author.fingerprint, label: "Sam", ownName: "Sam’s Mac",
            permit: .author(.pieces(["doc-b"])))
        await store.postureSettled()
        XCTAssertEqual(store.posture(forDocId: "doc-b").yieldingTo, "Sam", "precondition: this Mac yields on B")
        let before = try await snapshot(store, projectStore, total: total, cell: t1)

        do {
            _ = try await projectStore.renameFigure(id: cash.id, to: "costs")
            XCTFail("the rename was not refused")
        } catch let refused as FigureRenameRefused {
            XCTAssertEqual(refused.reason, .piecesNotWritable(["B"]))
            XCTAssertTrue(refused.localizedDescription.contains("B"))
        }
        let after = try await snapshot(store, projectStore, total: total, cell: t1)
        XCTAssertEqual(after, before, "registry, files, text and formulas are all as they were")
        XCTAssertEqual(after.a, "![Cash](../figures/cash.csv){#tbl:cash}", "A, writable, was not relabelled alone")

        store.overrideYield(docId: "doc-b")
        _ = try await projectStore.renameFigure(id: cash.id, to: "costs")
        let b = try await text("b")
        XCTAssertEqual(b, "See @tbl:costs.", "Edit Anyway: B follows the rename")
    }

    /// **A figure this Mac may not change is neither renamed nor removed**:
    /// B's figure, once this Mac yields on B to Sam, refuses both at its own
    /// door, and its record and render are as they were.
    func test_aFigureThisMacMayNotChangeIsNeitherRenamedNorRemoved() async throws {
        let (store, projectStore) = try await openBook()
        let prices = try await projectStore.createFigure(kind: .table, name: "prices", piece: "doc-b")
        let sam = LocalIdentities.softwareForTesting()
        _ = try await store.admit(
            device: sam.author.fingerprint, label: "Sam", ownName: "Sam’s Mac",
            permit: .author(.pieces(["doc-b"])))
        await store.postureSettled()

        do {
            _ = try await projectStore.renameFigure(id: prices.id, to: "costs")
            XCTFail("the rename was not refused")
        } catch let refused as FigureEditRefused {
            XCTAssertEqual(refused.site, "renameFigure")
        }
        do {
            try await projectStore.removeFigure(id: prices.id)
            XCTFail("the removal was not refused")
        } catch let refused as FigureEditRefused {
            XCTAssertEqual(refused.site, "removeFigure")
        }
        XCTAssertEqual(projectStore.manifest.figures, [prices])
        XCTAssertTrue(exists("figures/prices.csv"))
        XCTAssertFalse(exists("figures/costs.csv"))
    }

    /// **A piece whose text cannot be read refuses the rename, named** (N1):
    /// whether it refers to the figure cannot be checked, so nothing changes.
    func test_aPieceWhoseTextCannotBeReadRefusesTheRenameNamingIt() async throws {
        let (store, projectStore) = try await openBook(
            a: "![Cash](../figures/cash.csv){#tbl:cash}\n", b: "See @tbl:cash.\n")
        let (cash, total, t1) = try await cashAndTotal(store, projectStore)
        let before = try await snapshot(store, projectStore, total: total, cell: t1)
        ProjectStore.figureRelabelReadFailsForTesting = ["doc-c"]
        defer { ProjectStore.figureRelabelReadFailsForTesting = [] }

        do {
            _ = try await projectStore.renameFigure(id: cash.id, to: "costs")
            XCTFail("the rename was not refused")
        } catch let refused as FigureRenameRefused {
            XCTAssertEqual(refused.reason, .unreadable(["C"]))
            XCTAssertEqual(refused.localizedDescription, "C can't be read, so its references can't be checked.")
        }
        ProjectStore.figureRelabelReadFailsForTesting = []
        let after = try await snapshot(store, projectStore, total: total, cell: t1)
        XCTAssertEqual(after, before, "registry, files, text and formulas are all as they were")
    }

    // MARK: - Images

    /// **An image's rename moves its picture** and appends a `figureImageSet`
    /// with the same hash and the new file name, so the next `setImage`
    /// writes the new file; the line's path and label follow.
    func test_anImageRenameMovesThePicture_andTheNextReplaceWritesTheNewName() async throws {
        let (store, projectStore) = try await openBook()
        let image = try await projectStore.createImageFigure(
            fromURL: try png("map.png", .red), name: "map", piece: nil)
        let a = try await Document.load(url: chapter("a"), actor: .author, session: "t", presenter: nil)
        a.setFullText("![Map](../figures/map.png){#fig:map}")
        await a.close()
        let hash = try OpLogStore.loadSyncMerged(forDocId: image.id, in: projectURL, facts: .empty)
            .compactMap { $0.figure?.image?.contentHash }.last

        let renamed = try await projectStore.renameFigure(id: image.id, to: "chart")

        XCTAssertEqual(renamed.path, "figures/chart.png")
        XCTAssertFalse(exists("figures/map.png"))
        XCTAssertTrue(exists("figures/chart.png"))
        let set = try OpLogStore.loadSyncMerged(forDocId: image.id, in: projectURL, facts: .empty)
            .compactMap { $0.figure?.image }.last
        XCTAssertEqual(set, FigureImageRef(filename: "chart.png", contentHash: try XCTUnwrap(hash)),
                       "same hash, new file name")
        let text = try await text("a")
        XCTAssertEqual(text, "![Map](../figures/chart.png){#fig:chart}")

        let doc = try await store.openFigure(figureId: image.id)
        try await doc.setImage(fromURL: try png("blue.png", .blue))
        XCTAssertEqual(doc.state.image?.filename, "chart.png")
        XCTAssertFalse(exists("figures/map.png"), "the replace wrote the new name, not the old")
        await store.closeFigure(figureId: image.id)
    }

    // MARK: - Remove

    /// **Removing a figure sends its CSV to the Trash** carrying its record;
    /// the record leaves the registry, the stream stays, and restoring the
    /// entry brings the figure back, rendered. Pins claim M3-TR-065
    /// (`register/reconciliation/Trash.claims.json`); its refusal half is
    /// `test_aRestoreWhoseNameIsNowTakenIsRefusedAndTheEntryStays`.
    func test_removeSendsTheCSVToTrash_andARestoreBringsTheFigureBack() async throws {
        let (store, projectStore) = try await openBook()
        let (cash, total, _) = try await cashAndTotal(store, projectStore)

        try await projectStore.removeFigure(id: cash.id)

        XCTAssertEqual(projectStore.manifest.figures?.map(\.id), [total.id])
        XCTAssertFalse(exists("figures/cash.csv"))
        let entries = try await projectStore.trashStore.list()
        let entry = try XCTUnwrap(entries.first { $0.subject == .figure })
        XCTAssertEqual(entry.displayTitle, "Table: cash")
        XCTAssertFalse(OpLogStore.opLogFileURLs(forDocId: cash.id, in: projectURL).isEmpty,
                       "the stream stays")

        try await projectStore.restoreTrashEntry(id: entry.id)

        XCTAssertEqual(projectStore.manifest.figures?.first { $0.id == cash.id }?.name, "cash")
        XCTAssertEqual(try csv("figures/cash.csv"), "5,,\n,,\n,,\n", "back, and rendered from its stream")
    }

    /// **A restore whose name another figure now has is refused**, naming
    /// it — never brought back as `cash_2`, which would leave the text's
    /// `tbl:cash` broken — and the entry stays in the Trash.
    func test_aRestoreWhoseNameIsNowTakenIsRefusedAndTheEntryStays() async throws {
        let (store, projectStore) = try await openBook()
        defer { withExtendedLifetime(store) {} }
        let cash = try await projectStore.createFigure(kind: .table, name: "cash", piece: nil)
        try await projectStore.removeFigure(id: cash.id)
        let listed = try await projectStore.trashStore.list()
        let entry = try XCTUnwrap(listed.first { $0.subject == .figure })
        let newcomer = try await projectStore.createFigure(kind: .table, name: "Cash", piece: nil)

        do {
            try await projectStore.restoreTrashEntry(id: entry.id)
            XCTFail("the restore was not refused")
        } catch let refused as FigureRestoreRefused {
            XCTAssertEqual(refused.name, "Cash")
            XCTAssertEqual(refused.localizedDescription, "A figure called Cash already exists; rename it first.")
        }
        XCTAssertEqual(projectStore.manifest.figures, [newcomer])
        let still = try await projectStore.trashStore.list()
        XCTAssertTrue(still.contains { $0.id == entry.id }, "the entry is still in the Trash")
    }

    /// **A restored image keeps its stream's file name, and a stray file at
    /// that path goes to the Trash first**: the op log and the file agree, so
    /// the restored figure's next Replace Picture writes its own file.
    func test_anImageRestoreTrashesAStrayFileAndKeepsItsStreamsFileName() async throws {
        let (store, projectStore) = try await openBook()
        let image = try await projectStore.createImageFigure(
            fromURL: try png("map.png", .red), name: "map", piece: nil)
        let original = try Data(contentsOf: file("figures/map.png"))
        try await projectStore.removeFigure(id: image.id)
        let listed = try await projectStore.trashStore.list()
        let entry = try XCTUnwrap(listed.first { $0.subject == .figure })
        try Data("not a picture".utf8).write(to: file("figures/map.png"))

        try await projectStore.restoreTrashEntry(id: entry.id)

        XCTAssertEqual(projectStore.manifest.figures?.first { $0.id == image.id }?.path, "figures/map.png")
        XCTAssertEqual(try Data(contentsOf: file("figures/map.png")), original, "its own picture is back at its own name")
        let kept = try await projectStore.trashStore.entriesIncludingInternal()
        XCTAssertTrue(kept.contains { $0.subject == .internalArtifact && $0.displayTitle == "map.png" },
                      "the stray file went to the Trash, not overwritten")
        let names = try FileManager.default.contentsOfDirectory(atPath: file("figures").path)
        XCTAssertEqual(names.filter { !$0.hasPrefix(".") }, ["map.png"], "nothing landed beside it")
        let doc = try await store.openFigure(figureId: image.id)
        XCTAssertEqual(doc.state.image?.filename, "map.png")
        await store.closeFigure(figureId: image.id)
    }

    /// **A failed save puts a remove back**: the record stays, the CSV comes
    /// back from the Trash, and no figure entry is left there.
    func test_aRemoveWhoseSaveFailsPutsTheFileAndRecordBack() async throws {
        let (store, projectStore) = try await openBook()
        defer { withExtendedLifetime(store) {} }
        let cash = try await projectStore.createFigure(kind: .table, name: "cash", piece: nil)
        try FileManager.default.createDirectory(at: file(".trash"), withIntermediateDirectories: true)

        try await withUnwritableProjectFolder {
            do {
                try await projectStore.removeFigure(id: cash.id)
                XCTFail("the save did not fail")
            } catch let error as ProjectStoreError {
                guard case .manifestUnwritable = error else { return XCTFail("\(error)") }
            }
        }
        XCTAssertEqual(projectStore.manifest.figures, [cash])
        XCTAssertTrue(exists("figures/cash.csv"), "the CSV came back from the Trash")
        let entries = try await projectStore.trashStore.list()
        XCTAssertFalse(entries.contains { $0.subject == .figure })
    }

    /// **A file that lands anywhere but the record's path refuses the
    /// restore** (N2): the file goes back to the Trash with its record, the
    /// registry gains nothing, and nothing is left beside the occupant.
    func test_aRestoreWhoseFileLandsElsewhereIsRefusedAndGoesBackToTheTrash() async throws {
        let (store, projectStore) = try await openBook()
        defer { withExtendedLifetime(store) {} }
        let cash = try await projectStore.createFigure(kind: .table, name: "cash", piece: nil)
        try await projectStore.removeFigure(id: cash.id)
        let listed = try await projectStore.trashStore.list()
        let entry = try XCTUnwrap(listed.first { $0.subject == .figure })
        let occupant = file(cash.path)
        ProjectStore.beforeFigureRestoreLandsForTesting = { _ in
            try "arrived meanwhile\n".write(to: occupant, atomically: true, encoding: .utf8)
        }
        defer { ProjectStore.beforeFigureRestoreLandsForTesting = nil }

        do {
            try await projectStore.restoreTrashEntry(id: entry.id)
            XCTFail("the restore was not refused")
        } catch let error as ProjectStoreError {
            guard case .trashEntryNotRewirable = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(projectStore.manifest.figures ?? [], [])
        XCTAssertEqual(try csv(cash.path), "arrived meanwhile\n", "the occupant is untouched")
        let names = try FileManager.default.contentsOfDirectory(atPath: file("figures").path)
        XCTAssertEqual(names.filter { !$0.hasPrefix(".") }, ["cash.csv"], "nothing was left beside it")
        let after = try await projectStore.trashStore.list()
        XCTAssertTrue(after.contains { $0.subject == .figure && $0.displayTitle == "Table: cash" },
                      "the figure is still in the Trash, with its record")
    }

    // MARK: - renderFigures' early exits

    /// **A pass that renders nothing leaves no stale lists**: with no figures
    /// in the registry, the last pass's parked and unreadable figures are
    /// cleared rather than left standing.
    func test_aPassWithNoFiguresClearsTheParkedAndUnreadableLists() async throws {
        let (store, _) = try await openBook()
        store.lastParkedFigures = ["fig-0a1b2c3d"]
        store.lastUnreadableFigures = [("cash", "unreadable")]

        await store.renderFigures(changed: [])

        XCTAssertEqual(store.lastParkedFigures, [])
        XCTAssertTrue(store.lastUnreadableFigures.isEmpty)
    }

    /// **A pass whose registry will not read leaves no stale lists** either:
    /// the registry's people folder is unreadable, the trust resolution
    /// throws, and the last pass's lists are cleared.
    func test_aPassWhoseRegistryWillNotReadClearsTheParkedAndUnreadableLists() async throws {
        let (store, projectStore) = try await openBook()
        let cash = try await projectStore.createFigure(kind: .table, name: "cash", piece: nil)
        try "edited,in,Excel\n".write(to: file(cash.path), atomically: true, encoding: .utf8)
        let people = file(".maugham/people")
        XCTAssertTrue(FileManager.default.fileExists(atPath: people.path), "precondition: the book has a registry")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: people.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: people.path) }
        Document.registryCacheForTesting = RegistryCache(
            fileURL: file("registry-cache-2.json"),
            identity: Document.loadIdentities.author.fingerprint)
        store.lastParkedFigures = ["fig-0a1b2c3d"]
        store.lastUnreadableFigures = [("cash", "unreadable")]

        await store.renderFigures(changed: [cash.id])

        XCTAssertEqual(try csv(cash.path), "edited,in,Excel\n", "precondition: the pass stopped at the registry")
        XCTAssertEqual(store.lastParkedFigures, [])
        XCTAssertTrue(store.lastUnreadableFigures.isEmpty)
    }

    // MARK: - Final review I-3: a removal always leaves a way back

    /// **A parked table removed and restored comes back parked, and its
    /// readers recover** (final review I-3): its render is in Research, so the
    /// entry carries a CSV rendered from its op state; the restore re-lists
    /// it, still parked, with no stray render left in `figures/`, and a
    /// reader shows its parked value again.
    func test_aParkedTableRemovedAndRestoredComesBackParked_andItsReadersRecover() async throws {
        let (store, projectStore) = try await openBook()
        let (cash, total, _) = try await cashAndTotal(store, projectStore)
        _ = try await projectStore.sendToResearch(figureId: cash.id, scope: .shared)
        await store.renderFigures(changed: [total.id])
        XCTAssertEqual(try csv("figures/total.csv"), "10,,\n,,\n,,\n", "precondition: the parked value")
        XCTAssertFalse(exists("figures/cash.csv"), "precondition: no render while parked")

        try await projectStore.removeFigure(id: cash.id)
        await store.renderFigures(changed: [total.id])
        XCTAssertEqual(try csv("figures/total.csv"), "#REF!,,\n,,\n,,\n", "removed: the reader breaks")
        let entries = try await projectStore.trashStore.list()
        let entry = try XCTUnwrap(entries.first { $0.subject == .figure }, "a Trash entry, always")

        try await projectStore.restoreTrashEntry(id: entry.id)

        XCTAssertEqual(projectStore.manifest.figures?.first { $0.id == cash.id }, cash)
        let back = try await store.figureIsParked(cash.id)
        XCTAssertTrue(back, "still parked")
        XCTAssertFalse(exists("figures/cash.csv"), "the entry's CSV is not left as a render")
        await store.renderFigures(changed: [total.id])
        XCTAssertEqual(try csv("figures/total.csv"), "10,,\n,,\n,,\n", "the reader recovers")
    }

    /// **A table whose render is gone (evicted, never written) is still
    /// restorable** (final review I-3): the entry carries a CSV rendered from
    /// its op state, and the restore puts it back, rendered.
    func test_aTableWithNoRenderFileIsRemovedRestorably() async throws {
        let (store, projectStore) = try await openBook()
        defer { withExtendedLifetime(store) {} }
        let (cash, _, _) = try await cashAndTotal(store, projectStore)
        try FileManager.default.removeItem(at: file(cash.path))

        try await projectStore.removeFigure(id: cash.id)
        let entries = try await projectStore.trashStore.list()
        let entry = try XCTUnwrap(entries.first { $0.subject == .figure }, "a Trash entry, always")
        try await projectStore.restoreTrashEntry(id: entry.id)

        XCTAssertEqual(projectStore.manifest.figures?.first { $0.id == cash.id }, cash)
        XCTAssertEqual(try csv("figures/cash.csv"), "5,,\n,,\n,,\n", "back, rendered from its stream")
    }

    /// **A picture whose file is gone is still restorable** (final review
    /// I-3): the entry holds the record only; the restore brings the figure
    /// back, its picture missing as before.
    func test_aPictureWithNoFileIsRemovedRestorably() async throws {
        let (store, projectStore) = try await openBook()
        defer { withExtendedLifetime(store) {} }
        let map = try await projectStore.createImageFigure(fromURL: try png("map.png", .red), name: "map", piece: nil)
        try FileManager.default.removeItem(at: file(map.path))

        try await projectStore.removeFigure(id: map.id)
        XCTAssertEqual(projectStore.manifest.figures ?? [], [])
        let entries = try await projectStore.trashStore.list()
        let entry = try XCTUnwrap(entries.first { $0.subject == .figure }, "a Trash entry, always")
        XCTAssertFalse(entry.carriesFile, "the record only")
        try await projectStore.restoreTrashEntry(id: entry.id)

        XCTAssertEqual(projectStore.manifest.figures, [map])
        XCTAssertFalse(exists(map.path), "its picture still missing")
    }

    // MARK: - Final review M-4: a parked figure is not renamed

    /// **Renaming a parked figure is refused up front, for either kind**
    /// (final review M-4): nothing changes.
    func test_aParkedFigureIsNotRenamed_tableOrPicture() async throws {
        let (store, projectStore) = try await openBook(a: "![Cash](../figures/cash.csv){#tbl:cash}\n")
        defer { withExtendedLifetime(store) {} }
        let cash = try await projectStore.createFigure(kind: .table, name: "cash", piece: nil)
        let map = try await projectStore.createImageFigure(fromURL: try png("map.png", .red), name: "map", piece: nil)
        _ = try await projectStore.sendToResearch(figureId: cash.id, scope: .shared)
        _ = try await projectStore.sendToResearch(figureId: map.id, scope: .shared)
        let figures = projectStore.manifest.figures

        for (record, sentence) in [
            (cash, "This table is in Research; bring it back to rename it."),
            (map, "This picture is in Research; bring it back to rename it."),
        ] {
            do {
                _ = try await projectStore.renameFigure(id: record.id, to: "renamed")
                XCTFail("\(record.name): the rename was not refused")
            } catch let refused as FigureRenameRefused {
                XCTAssertEqual(refused.reason, .inResearch(record.kind))
                XCTAssertEqual(refused.localizedDescription, sentence)
            }
        }
        XCTAssertEqual(projectStore.manifest.figures, figures, "nothing renamed")
    }

    // MARK: - Final review I-2: a rename relabels the translations too

    /// The es translation of every paragraph of `slug`, fresh: its text the
    /// source's with `Cash` → `Efectivo`, its hash the source's.
    private func translateToSpanish(_ slug: String) async throws {
        let doc = try await Document.load(url: chapter(slug), actor: .author, session: "tr", presenter: nil)
        let records = doc.sequence.compactMap { id -> TranslationRecord? in
            guard let source = doc.paragraphs[id] else { return nil }
            return TranslationRecord(
                paragraphId: id, language: "es",
                text: source.replacingOccurrences(of: "Cash", with: "Efectivo")
                    .replacingOccurrences(of: "See", with: "Véase"),
                sourceHash: TranslationHash.hash(source))
        }
        await doc.close()
        let identities = Document.loadIdentities
        try await TranslationStore.appendBatch(
            records, forDocId: "doc-\(slug)", language: "es",
            identity: identities.translator, identities: identities,
            state: try XCTUnwrap(Document.deviceStateForTesting), in: projectURL)
    }

    /// `slug`'s es translation as the edition derives it: each paragraph's
    /// text and freshness.
    private func spanish(_ slug: String) async throws -> [(text: String?, status: TranslationStatus)] {
        let doc = try await Document.load(url: chapter(slug), actor: .author, session: "tr", presenter: nil)
        let derived = TranslationDeriver.derive(
            records: try TranslationStore.loadMerged(forDocId: "doc-\(slug)", language: "es", in: projectURL),
            sequence: doc.sequence, paragraphs: doc.paragraphs, language: "es")
        await doc.close()
        return derived.entries.map { ($0.translatedText, $0.status) }
    }

    /// **A rename relabels the translated figure line and a translated
    /// cross-reference, and the edition stays fresh** (final review I-2):
    /// the es records hold the new label and file, re-stamped against the
    /// relabelled source, so nothing reads stale because of the rename.
    func test_aRenameRelabelsTheTranslations_andTheEditionStaysFresh() async throws {
        let (store, projectStore) = try await openBook(
            a: "![Cash](../figures/cash.csv){#tbl:cash}\n", b: "See @tbl:cash.\n")
        defer { withExtendedLifetime(store) {} }
        let cash = try await projectStore.createFigure(kind: .table, name: "cash", piece: nil)
        try await translateToSpanish("a")
        try await translateToSpanish("b")
        let beforeA = try await spanish("a")
        XCTAssertEqual(beforeA.map(\.status), [.fresh], "precondition: fresh")

        _ = try await projectStore.renameFigure(id: cash.id, to: "costs")

        let a = try await spanish("a")
        let b = try await spanish("b")
        XCTAssertEqual(a.map(\.text), ["![Efectivo](../figures/costs.csv){#tbl:costs}"])
        XCTAssertEqual(b.map(\.text), ["Véase @tbl:costs."])
        XCTAssertEqual(a.map(\.status) + b.map(\.status), [.fresh, .fresh], "not stale because of the rename")
    }

    /// **A translation door that refuses, or a translation that will not
    /// read, refuses the whole rename, naming the language** (final review
    /// I-2): registry, files, source text and translations are as they were.
    func test_aTranslationThatCannotBeRelabelledRefusesTheWholeRename() async throws {
        let (store, projectStore) = try await openBook(
            a: "![Cash](../figures/cash.csv){#tbl:cash}\n", b: "See @tbl:cash.\n")
        defer { withExtendedLifetime(store) {} }
        let cash = try await projectStore.createFigure(kind: .table, name: "cash", piece: nil)
        try await translateToSpanish("a")
        try await translateToSpanish("b")
        let before = (try await text("a"), try await text("b"), try await spanish("b").map(\.text))
        let spanishABefore = try await spanish("a")

        ProjectStore.translationRelabelDoorRefusesForTesting = ["doc-b"]
        defer { ProjectStore.translationRelabelDoorRefusesForTesting = [] }
        do {
            _ = try await projectStore.renameFigure(id: cash.id, to: "costs")
            XCTFail("the rename was not refused")
        } catch let refused as FigureRenameRefused {
            XCTAssertEqual(refused.reason, .translationsNotWritable(["es"]))
            XCTAssertTrue(refused.localizedDescription.contains("es"))
        }
        ProjectStore.translationRelabelDoorRefusesForTesting = []
        let refusedAfter = (try await text("a"), try await text("b"), try await spanish("b").map(\.text))
        XCTAssertEqual(refusedAfter.0, before.0)
        XCTAssertEqual(refusedAfter.1, before.1)
        XCTAssertEqual(refusedAfter.2, before.2)
        XCTAssertEqual(projectStore.manifest.figures, [cash])
        XCTAssertTrue(exists("figures/cash.csv"))

        // A batch that fails after the text and A's batch were written puts
        // the text back, then A's translation, fresh against it.
        var batches = 0
        ProjectStore.beforeTranslationRelabelAppendForTesting = { _ in
            batches += 1
            if batches == 2 { throw CocoaError(.fileWriteUnknown) }
        }
        defer { ProjectStore.beforeTranslationRelabelAppendForTesting = nil }
        do {
            _ = try await projectStore.renameFigure(id: cash.id, to: "costs")
            XCTFail("the failed append was not said")
        } catch is CocoaError {}
        ProjectStore.beforeTranslationRelabelAppendForTesting = nil
        let failedAfter = (try await text("a"), try await text("b"), try await spanish("b").map(\.text))
        XCTAssertEqual(failedAfter.0, before.0, "the source text went back")
        XCTAssertEqual(failedAfter.1, before.1)
        XCTAssertEqual(failedAfter.2, before.2)
        let spanishA = try await spanish("a")
        XCTAssertEqual(spanishA.map(\.text), spanishABefore.map(\.text), "A's landed batch was put back")
        XCTAssertEqual(spanishA.map(\.status), [.fresh], "and is fresh against the restored source")
        XCTAssertEqual(projectStore.manifest.figures, [cash])
    }
}
