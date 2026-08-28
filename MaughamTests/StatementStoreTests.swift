import XCTest
import AppKit
@testable import Maugham
import MaughamCore

/// The statement store seam (M1A Task 3): a statement is found by SCOPE in the
/// manifest, and find-or-create mints one when none exists.
@MainActor
final class StatementStoreTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// A loaded novel project with its async load work settled, so a test that
    /// asserts "nothing changed on disk" isn't racing `load`'s own tail.
    private func loadedNovel(named name: String) async throws -> (URL, ProjectStore) {
        let url = try await ProjectFactory.createNovelProject(named: name, in: temp.url)
        let store = try await ProjectStore.load(from: url)
        await store.wordCountPopulationTask?.value
        return (url, store)
    }

    /// A file's bytes AND its modification date.
    ///
    /// **Bytes alone are not enough to prove nothing was written.** The
    /// manifest's `modified` field round-trips through whole-second ISO8601, so
    /// a lookup that stamps and re-saves within the same second as the load
    /// produces a byte-identical file — a real write that a byte comparison
    /// calls unchanged. The mtime sees it.
    private struct FileState: Equatable {
        var bytes: Data
        var modified: Date?
    }

    /// Every file under the project, keyed by project-relative path. Both sides
    /// resolve symlinks, or `/var` vs `/private/var` leaves every key absolute
    /// and the relative-path assertions below silently match nothing.
    private func snapshot(of projectURL: URL) throws -> [String: FileState] {
        var out: [String: FileState] = [:]
        let fm = FileManager.default
        let root = projectURL.resolvingSymlinksInPath().path
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let walk = fm.enumerator(at: projectURL, includingPropertiesForKeys: keys)
        else { return out }
        for case let fileURL as URL in walk {
            let values = try? fileURL.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            let path = fileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(root + "/") else { continue }
            out[String(path.dropFirst(root.count + 1))] = FileState(
                bytes: try Data(contentsOf: fileURL), modified: values?.contentModificationDate)
        }
        return out
    }

    /// A real PNG's bytes, so the ingest under test is the production one — its
    /// first act is `ImagePasteHandler.isIngestableImage`, which a file merely
    /// named `.png` does not get past.
    private func pngBytes(_ side: Int = 8) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    /// The names in a directory, or none when there is no directory — an absent
    /// well and an empty one are both "nothing was deposited" here.
    private func files(in directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    // MARK: - Idempotency

    func test_creatingTwiceForOneScopeReturnsTheSameStatement() async throws {
        let (url, store) = try await loadedNovel(named: "IdempotentIntent")

        let first = try await store.createStatement(kind: .intent, scope: .project)
        XCTAssertEqual(first.path, "intent.md")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("intent.md").path))

        let second = try await store.createStatement(kind: .intent, scope: .project)
        XCTAssertEqual(second.id, first.id, "find-or-create must find before it creates")
        XCTAssertEqual(second.path, first.path)
        XCTAssertEqual(store.manifest.statements.count, 1,
                       "a second call must not register a second statement")

        // …and no second file for it to have registered.
        let intentFiles = try snapshot(of: url).keys.filter { $0.hasPrefix("intent") }.sorted()
        XCTAssertEqual(intentFiles, ["intent.md"])
    }

    // MARK: - The defect's grave

    /// The live defect this seam kills: `craftIntentItem(forPieceId:)` looked an
    /// intent doc up by the piece's research PATH PREFIX, and
    /// `ResearchScope.pieceResearchPrefix` opens `guard piece.pieceKind == .loose`
    /// — so for a NOVEL CHAPTER the lookup returned nil while creation went ahead,
    /// and the next call minted a second copy of the writer's intent.
    ///
    /// A statement is found by `scope`, in the manifest. There is no prefix, so
    /// there is nothing to be nil.
    func test_aNovelChapterGetsItsOwnIntent() async throws {
        let (_, store) = try await loadedNovel(named: "ChapterIntent")
        let chapter = try XCTUnwrap(store.manifest.structure.first)

        let created = try await store.createStatement(
            kind: .intent, scope: .document(chapter.id))
        XCTAssertEqual(created.path, "intent/chapter-1.md")

        let found = store.statement(kind: .intent, scope: .document(chapter.id))
        XCTAssertEqual(found?.id, created.id,
                       "a novel chapter's intent must be findable — this is the defect's grave")

        // Scope discriminates: the book's intent is a different statement, and
        // the chapter's must not answer for it.
        XCTAssertNil(store.statement(kind: .intent, scope: .project),
                     "the chapter's intent must not be returned as the project's")
        let project = try await store.createStatement(kind: .intent, scope: .project)
        XCTAssertNotEqual(project.id, created.id)
        XCTAssertEqual(project.path, "intent.md")
        XCTAssertEqual(store.manifest.statements.count, 2)
    }

    // MARK: - Absence is free

    func test_lookupOfAnUndeclaredScopeMintsNothing() async throws {
        let (url, store) = try await loadedNovel(named: "AbsentIntent")
        let chapter = try XCTUnwrap(store.manifest.structure.first)

        let before = try snapshot(of: url)

        XCTAssertNil(store.statement(kind: .intent, scope: .project))
        XCTAssertNil(store.statement(kind: .intent, scope: .document(chapter.id)))
        XCTAssertNil(store.statement(kind: .visualLanguage, scope: .project))
        XCTAssertTrue(store.manifest.statements.isEmpty)

        // Give a fire-and-forget stamp/heal Task (the shape `craftIntentItem`
        // uses) time to land, so a lookup that secretly writes is caught.
        try await Task.sleep(nanoseconds: 200_000_000)

        let after = try snapshot(of: url)
        let touched = Set(before.keys).union(after.keys)
            .filter { before[$0] != after[$0] }.sorted()
        XCTAssertEqual(touched, [],
                       "absence must cost nothing on disk — no mint, no stamp, no save")
    }

    // MARK: - An unknown scope is refused, not redirected

    func test_anUnknownDocumentScopeThrows() async throws {
        let (_, store) = try await loadedNovel(named: "UnknownScope")

        // The lookup is absence-is-valid: nil, no throw, nothing minted.
        XCTAssertNil(store.statement(kind: .intent, scope: .document("doc-nope")))

        do {
            let made = try await store.createStatement(
                kind: .intent, scope: .document("doc-nope"))
            XCTFail("expected a throw; got a statement at \(made.path)")
        } catch {
            // Expected. What must NOT happen is a silent fall back to project
            // scope, which would put a chapter's intent in the book's file.
        }
        XCTAssertTrue(store.manifest.statements.isEmpty,
                      "a refused scope registers nothing")
        XCTAssertNil(store.statement(kind: .intent, scope: .project),
                     "an unknown document scope must not become the project's")
    }

    /// A group id is *in* the structure but is not a manuscript document, so it
    /// is refused by the same rule.
    func test_aGroupScopeThrows() async throws {
        let (_, store) = try await loadedNovel(named: "GroupScope")
        let group = try await store.addStructureItem(
            parentId: nil, title: "Part One", kind: .group)

        do {
            _ = try await store.createStatement(kind: .intent, scope: .document(group.id))
            XCTFail("expected a throw for a manuscript GROUP")
        } catch {
            // Expected.
        }
        XCTAssertTrue(store.manifest.statements.isEmpty)
    }

    /// Visual language is project-scope only (spec §2.1) — the storage table has
    /// no row for a per-document one, so there is no path to mint.
    func test_visualLanguageAtDocumentScopeThrows() async throws {
        let (_, store) = try await loadedNovel(named: "VisualScope")
        let chapter = try XCTUnwrap(store.manifest.structure.first)

        do {
            _ = try await store.createStatement(
                kind: .visualLanguage, scope: .document(chapter.id))
            XCTFail("expected a throw: visual language is project-scope only")
        } catch {
            // Expected.
        }

        let project = try await store.createStatement(kind: .visualLanguage, scope: .project)
        XCTAssertEqual(project.path, "visual-language.md")
    }

    // MARK: - Collisions

    /// The manifest is the only authority on identity, so a statement minted at
    /// a path that already holds an UNTRACKED file would adopt that file's bytes
    /// as its bootstrap and then own the path — the writer's file eaten by a
    /// registry entry it never made. Creation steers around it instead.
    func test_creationSteersAroundAnUntrackedFileRatherThanAdoptingIt() async throws {
        let (url, store) = try await loadedNovel(named: "CollidingIntent")
        let squatter = "Someone else's intent.md, not ours.\n"
        try squatter.write(to: url.appendingPathComponent("intent.md"),
                           atomically: true, encoding: .utf8)

        let created = try await store.createStatement(kind: .intent, scope: .project)
        XCTAssertNotEqual(created.path, "intent.md",
                          "the untracked file must not become the statement's home")
        XCTAssertEqual(created.path, "intent-2.md")
        XCTAssertEqual(
            try String(contentsOf: url.appendingPathComponent("intent.md"), encoding: .utf8),
            squatter, "the untracked file is left byte-for-byte alone")
        XCTAssertEqual(store.statement(kind: .intent, scope: .project)?.id, created.id)
    }

    // MARK: - Undoing a mint nothing was deposited into (issue #29)

    /// Issue #29 (S5 residue + S6): `createStatement` commits a file and a
    /// manifest row **before** the thing it was minted for can fail — an image
    /// save that throws, a superseded mint nothing was deposited into. The
    /// rollback undoes exactly that commit.
    func test_rollbackRemovesAFreshlyMintedEmptyStatement() async throws {
        let (url, store) = try await loadedNovel(named: "RollbackFresh")
        let minted = try await store.createStatement(kind: .visualLanguage, scope: .project)
        let file = url.appendingPathComponent(minted.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                      "control: the mint committed a file")

        let rolled = await store.rollbackUnusedStatement(minted)

        XCTAssertTrue(rolled, "an empty scaffold nothing was deposited into rolls back")
        XCTAssertNil(store.statement(kind: .visualLanguage, scope: .project),
                     "the manifest row is gone — the writer's visual language is "
                     + "undeclared again, which is what it was a moment ago")
        XCTAssertTrue(store.manifest.statements.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path),
                       "and the empty file with it")

        // The rollback is durable, not merely in memory: a reload must not find
        // the row the writer's failed act left behind.
        let reloaded = try await ProjectStore.load(from: url)
        await reloaded.wordCountPopulationTask?.value
        XCTAssertTrue(reloaded.manifest.statements.isEmpty,
                      "the manifest was saved without the row")
    }

    /// **Words mean the mint was USED.** The verb exists for the
    /// mint-then-fail window, and a caller reaching for it any later is wrong —
    /// so it refuses rather than trusting them.
    func test_rollbackRefusesAStatementThatHasWords() async throws {
        let (url, store) = try await loadedNovel(named: "RollbackRefusesWords")
        let minted = try await store.createStatement(kind: .intent, scope: .project)
        try await store.appendToStatement("The writer's own intent.", to: minted,
                                          session: "test-\(UUID().uuidString)")

        let rolled = await store.rollbackUnusedStatement(minted)

        XCTAssertFalse(rolled, "words mean the mint was USED — rollback must refuse")
        XCTAssertEqual(store.statement(kind: .intent, scope: .project)?.id, minted.id,
                       "the statement is untouched")
        XCTAssertEqual(try store.statementText(of: minted), "The writer's own intent.",
                       "and so are its words")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(minted.path).path))
    }

    /// **The words can be in the FILE with the op log still empty**, and that is
    /// the state this guard is really for: a freshly promoted Collection piece
    /// carries its intent's prose in the `.md` and has no `.maugham/` at all
    /// (`stagePromotedIntent`), so the derivation answers `""` over a file full
    /// of the writer's paragraphs. Asked as a `stat` and never a read — the
    /// non-zero-size question `propagateWikiLinkRename` already asks (ADR 0018).
    func test_rollbackRefusesWhenTheWordsAreInTheFileAndNotYetInTheLog() async throws {
        let (url, store) = try await loadedNovel(named: "RollbackUnbootstrapped")
        let minted = try await store.createStatement(kind: .intent, scope: .project)
        let file = url.appendingPathComponent(minted.path)
        let prose = "Carried over from the Collection, never opened here.\n"
        try prose.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try store.statementText(of: minted), "",
                       "control: the op log is empty, so the derivation says nothing "
                       + "— which is exactly why an empty derive cannot be the whole test")

        let rolled = await store.rollbackUnusedStatement(minted)

        XCTAssertFalse(rolled, "a statement whose file has bytes is not an unused mint")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), prose,
                       "the writer's prose is untouched")
        XCTAssertEqual(store.statement(kind: .intent, scope: .project)?.id, minted.id)
    }

    /// **An OPEN statement is in use whatever its text says.** A pane binds a
    /// `Document` on that path and types into it; deleting the file out from
    /// under one leaves the writer typing into a `Document` whose file is gone.
    func test_rollbackRefusesWhileTheStatementIsOpen() async throws {
        let (url, store) = try await loadedNovel(named: "RollbackOpen")
        let minted = try await store.createStatement(kind: .intent, scope: .project)

        // Stand in for the Intent pane through the store's own open seam, which
        // is the pair `StatementEditorHost.load` performs.
        await store.lockStatementOpen(minted.id)
        let pane = try await Document.load(
            url: url.appendingPathComponent(minted.path),
            device: MacDeviceID.current, session: "pane-test", presenter: nil)
        store.noteStatementDocumentOpened(pane, id: minted.id)
        store.unlockStatementOpen(minted.id)

        let rolled = await store.rollbackUnusedStatement(minted)

        XCTAssertFalse(rolled, "an OPEN statement is in use whatever its text says")
        XCTAssertEqual(store.statement(kind: .intent, scope: .project)?.id, minted.id)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(minted.path).path))

        store.forgetStatementDocument(id: minted.id)
        await pane.close()
    }

    /// **A stale handle deletes nothing**, and the sharp case is a path reused:
    /// roll one back, mint another, and the first handle still names the path
    /// the second now lives at. Identity is the manifest `id` (tripwire 22), so
    /// the second call finds no row for it and refuses — rather than removing a
    /// live statement's file by path.
    func test_rollbackRefusesAHandleTheManifestNoLongerKnows() async throws {
        let (url, store) = try await loadedNovel(named: "RollbackStaleHandle")
        let first = try await store.createStatement(kind: .intent, scope: .project)
        let rolledFirst = await store.rollbackUnusedStatement(first)
        XCTAssertTrue(rolledFirst)

        let second = try await store.createStatement(kind: .intent, scope: .project)
        XCTAssertEqual(second.path, first.path, "control: the path was free again")
        XCTAssertNotEqual(second.id, first.id)

        let rolledAgain = await store.rollbackUnusedStatement(first)

        XCTAssertFalse(rolledAgain, "the manifest no longer knows this statement")
        XCTAssertEqual(store.statement(kind: .intent, scope: .project)?.id, second.id,
                       "and the live statement standing at that path is untouched")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(second.path).path),
            "a stale handle must never take a live statement's file with it")
    }

    // MARK: - …and never away from a picture already deposited (issue #35)

    /// **The race this guard is for.** The drop side writes the photograph into
    /// the well and only *then* takes the statement gate to append its ref
    /// (`addImage(toStatement:)`, then the caller's `appendToStatement`). A mint
    /// racing it holds the gate and asks every question that came before this
    /// one — nobody has it open, the derivation is empty, the file is empty, the
    /// row is known — and each says "roll back", because the ref has not landed
    /// yet. The writer's picture would be orphaned in a well whose statement no
    /// longer exists.
    ///
    /// So the well itself is the fifth question. Here the picture is deposited
    /// through the production ingest and the ref deliberately NOT appended —
    /// the race's first half, frozen.
    func test_rollbackRefusesWhenThePicturesWellIsNotEmpty() async throws {
        let (url, store) = try await loadedNovel(named: "RollbackWellHoldsAPicture")
        let minted = try await store.createStatement(kind: .visualLanguage, scope: .project)
        let source = temp.url.appendingPathComponent("dropped.png")
        try pngBytes().write(to: source)

        let deposited = try await store.addImage(
            toStatement: .visualLanguage, scope: .project, fileURL: source)
        XCTAssertEqual(deposited.statement.id, minted.id,
                       "control: find-or-create found the statement we minted, so this "
                       + "is one statement with a picture beside it and no ref in it yet")
        XCTAssertEqual(try store.statementText(of: minted), "",
                       "control: the ref has NOT been appended — every other refusal "
                       + "says roll back, which is what makes the well the only witness")
        let well = ImagePasteHandler.wellURL(forNoteAt: minted.path, in: url)
        XCTAssertEqual(files(in: well).count, 1, "control: the picture is in the well")

        let rolled = await store.rollbackUnusedStatement(minted)

        XCTAssertFalse(rolled, "a statement with a photograph beside it is not an "
                       + "unused mint, whatever its text says")
        XCTAssertEqual(store.statement(kind: .visualLanguage, scope: .project)?.id,
                       minted.id, "the row stands")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(minted.path).path), "and its file")
        XCTAssertEqual(files(in: well).count, 1,
                       "and the writer's photograph is untouched — a refusal leaves "
                       + "everything as it was")
    }

    /// **The same question, asked a second time, immediately before the file
    /// goes away.** `saveManifest` is an `await`, and an `await` is a suspension
    /// point whether or not today's callee happens to yield; the well is also a
    /// directory in the open that another process can write into while the save
    /// runs. Either way a picture can land *after* the guard above and *before*
    /// the removal, so the guard is asked again with nothing left between it and
    /// `removeItem`.
    ///
    /// **Forced deterministically through the coordinated write itself.** With a
    /// `DocumentStore` attached — the production arm; `saveManifest`'s other one
    /// exists for load, before there is a store to coordinate through — the save
    /// runs inside `NSFileCoordinator.coordinate(writingItemAt:)`, which
    /// messages every OTHER registered presenter of that URL and blocks the
    /// writer until each relinquishes. So a presenter armed one line before the
    /// call runs its hook inside the save, every time, with no sleep and no
    /// polling. `didFire` is the control: without it a guard that never ran and
    /// a coordinator that never called us would look identical from here.
    func test_rollbackRefusesAPictureThatLandedDuringItsOwnSave() async throws {
        let (url, store) = try await loadedNovel(named: "RollbackLatePicture")
        // Held strongly for the test's duration: `documentStore` is weak, and a
        // released one silently drops the save back onto the uncoordinated arm.
        let documentStore = try await DocumentStore.open(url: url)
        store.documentStore = documentStore
        defer { store.documentStore = nil }
        let minted = try await store.createStatement(kind: .visualLanguage, scope: .project)
        let well = ImagePasteHandler.wellURL(forNoteAt: minted.path, in: url)
        let bytes = try pngBytes()
        let stampBefore = store.manifest.modified

        let interloper = ManifestWriteInterloper(
            manifestAt: url.appendingPathComponent(ProjectManifest.fileName))
        NSFileCoordinator.addFilePresenter(interloper)
        defer { NSFileCoordinator.removeFilePresenter(interloper) }
        interloper.armOnce {
            try? FileManager.default.createDirectory(
                at: well, withIntermediateDirectories: true)
            try? bytes.write(to: well.appendingPathComponent("landed-late.png"))
        }

        let rolled = await store.rollbackUnusedStatement(minted)

        XCTAssertTrue(interloper.didFire,
                      "control: the hook must have run INSIDE the save — otherwise this "
                      + "test proves nothing about the second check")
        XCTAssertFalse(rolled, "a picture that landed during the save is still a "
                       + "picture this statement must not be taken away from")
        XCTAssertEqual(store.manifest.statements.map(\.id), [minted.id],
                       "the row went out and came back")
        XCTAssertEqual(store.manifest.modified.timeIntervalSince1970,
                       stampBefore.timeIntervalSince1970,
                       "and the stamp with it — nothing was modified")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(minted.path).path),
            "the file the picture belongs to is still there")
        XCTAssertEqual(files(in: well), ["landed-late.png"])

        // Durable, not merely in memory: the re-insert is saved again, or a
        // reload would find the row the first save had already dropped.
        let reloaded = try await ProjectStore.load(from: url)
        await reloaded.wordCountPopulationTask?.value
        XCTAssertEqual(reloaded.manifest.statements.map(\.id), [minted.id],
                       "the row is back on disk, not just in memory")

        // Closed rather than left to deinit: `DocumentStore.open` registers a
        // `ProjectFolderPresenter` process-wide, and a suite that leaves one
        // standing hands every later coordinated write an extra presenter to
        // message.
        await documentStore.close()
    }

    /// **The control for both guards above**, in the three shapes an untouched
    /// well comes in: no well at all (the mint never got as far as one), an
    /// empty well (the saver's `createDirectory` landed and its write did not —
    /// the state `rollBack` deliberately leaves behind), and a well holding
    /// nothing but a `.DS_Store` the Finder dropped while the writer looked at
    /// the folder. None of the three is a deposit, and a guard that refused any
    /// of them would make an ordinary empty mint permanently un-rollbackable.
    func test_rollbackStillRemovesAStatementWithAnEmptyOrAbsentWell() async throws {
        let (url, store) = try await loadedNovel(named: "RollbackEmptyWell")

        let noWell = try await store.createStatement(kind: .intent, scope: .project)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ImagePasteHandler.wellURL(forNoteAt: noWell.path, in: url).path),
            "control: no well was ever made")
        let rolledWithNoWell = await store.rollbackUnusedStatement(noWell)
        XCTAssertTrue(rolledWithNoWell,
                      "a mint with no well behind it rolls back as it always did")

        let emptyWell = try await store.createStatement(kind: .intent, scope: .project)
        let well = ImagePasteHandler.wellURL(forNoteAt: emptyWell.path, in: url)
        try FileManager.default.createDirectory(at: well, withIntermediateDirectories: true)
        let rolledWithEmptyWell = await store.rollbackUnusedStatement(emptyWell)
        XCTAssertTrue(rolledWithEmptyWell,
                      "an empty well is the failed-copy residue, not a deposit")

        let finderWell = try await store.createStatement(kind: .intent, scope: .project)
        let strayed = ImagePasteHandler.wellURL(forNoteAt: finderWell.path, in: url)
        try FileManager.default.createDirectory(at: strayed, withIntermediateDirectories: true)
        try Data("Finder".utf8).write(to: strayed.appendingPathComponent(".DS_Store"))
        XCTAssertFalse(store.statementWellHoldsAnything(finderWell),
                       "a hidden file the writer never put there is not a photograph")
        let rolledPastTheFinder = await store.rollbackUnusedStatement(finderWell)
        XCTAssertTrue(rolledPastTheFinder, "so the rollback still lands")
        XCTAssertTrue(store.manifest.statements.isEmpty)
    }

    /// **A refused save puts the row back where it was — and the stamp with
    /// it.** The same restore `commitProductionRoles` performs, pinned there by
    /// `ProductionRoleStoreTests.test_aFailedSaveLeavesNoPhantomTranslatorBehind`
    /// ("the stamp goes back with the row it was made for") and until now
    /// untested here: a verb that dropped the row from memory over a save that
    /// never reached disk would leave the writer's statement invisible in a
    /// project that still holds it.
    ///
    /// **Its INDEX, not merely its presence** — two statements, and the FIRST is
    /// the one rolled back, so a restore that appended instead of inserting
    /// would reorder the manifest and this would see it.
    ///
    /// The save is made to fail for real — the project directory is made
    /// unwritable, so `saveManifest`'s tmp file cannot be created — rather than
    /// through an injected seam: this store has none, and the failure under test
    /// is the disk's own (`ProductionRoleStoreTests`' idiom).
    func test_aFailedSaveDuringRollbackPutsTheRowAndTheStampBack() async throws {
        let (url, store) = try await loadedNovel(named: "RollbackFailedSave")
        let first = try await store.createStatement(kind: .intent, scope: .project)
        let second = try await store.createStatement(kind: .visualLanguage, scope: .project)
        XCTAssertEqual(store.manifest.statements.map(\.id), [first.id, second.id],
                       "control: the row under test is the FIRST of two")
        let stampBefore = store.manifest.modified
        let file = url.appendingPathComponent(first.path)

        let fm = FileManager.default
        let original = try XCTUnwrap(
            fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: url.path)
        defer { try? fm.setAttributes([.posixPermissions: original], ofItemAtPath: url.path) }

        let rolled = await store.rollbackUnusedStatement(first)

        XCTAssertFalse(rolled, "a row that could not be dropped from disk must not be "
                       + "dropped from memory either")
        XCTAssertEqual(store.manifest.statements.map(\.id), [first.id, second.id],
                       "the row went back at its own index, not onto the end")
        // Compared as intervals, not as `Date`s: two `Date`s differing only
        // sub-second print identically, so a failure here would read as
        // "X is not equal to X".
        XCTAssertEqual(store.manifest.modified.timeIntervalSince1970,
                       stampBefore.timeIntervalSince1970,
                       "the stamp goes back with the row it was made for")
        XCTAssertTrue(fm.fileExists(atPath: file.path),
                      "and the file stands — deleting it under a live row is the "
                      + "dangle the manifest-first order exists to avoid")

        try fm.setAttributes([.posixPermissions: original], ofItemAtPath: url.path)
        let reloaded = try await ProjectStore.load(from: url)
        await reloaded.wordCountPopulationTask?.value
        XCTAssertEqual(reloaded.manifest.statements.map(\.id), [first.id, second.id],
                       "disk never lost the row, so memory and disk agree again")
    }

    /// Two documents can share a title, so their slugs collide. Each still gets
    /// its own statement file — identity is the manifest id, not the path.
    func test_twoDocumentsWithTheSameTitleGetSeparateIntents() async throws {
        let (_, store) = try await loadedNovel(named: "TwinTitles")
        let first = try XCTUnwrap(store.manifest.structure.first)
        let twin = try await store.addStructureItem(
            parentId: nil, title: first.title, kind: .document(extension: "md"))

        let a = try await store.createStatement(kind: .intent, scope: .document(first.id))
        let b = try await store.createStatement(kind: .intent, scope: .document(twin.id))
        XCTAssertEqual(a.path, "intent/chapter-1.md")
        XCTAssertEqual(b.path, "intent/chapter-1-2.md")
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(store.statement(kind: .intent, scope: .document(twin.id))?.id, b.id)
    }
}

/// **A hook that runs INSIDE a coordinated manifest write**, so a test can put
/// the world into a state the verb under test only meets between two of its own
/// lines (issue #35: a picture landing in a statement's well during the save
/// that drops its row).
///
/// `NSFileCoordinator.coordinate(writingItemAt:)` messages every *other*
/// registered presenter of that URL and blocks the writer until each one
/// relinquishes. So `armOnce`'s closure is not raced against the save — it is
/// run by the save, before a byte of it lands, every time. That is why this is a
/// presenter rather than a `Task` hoping to be scheduled in the right window.
///
/// One-shot, and armed one line before the call under test, so an earlier
/// coordinated write in the same test cannot spend it. `didFire` is how a test
/// tells "the guard held" apart from "the coordinator never called us".
private final class ManifestWriteInterloper: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue

    private let lock = NSLock()
    private var hook: (() -> Void)?
    private var fired = false

    init(manifestAt url: URL) {
        presentedItemURL = url
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        presentedItemOperationQueue = queue
        super.init()
    }

    func armOnce(_ hook: @escaping () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        self.hook = hook
    }

    var didFire: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }

    func relinquishPresentedItem(toWriter writer: @escaping ((() -> Void)?) -> Void) {
        lock.lock()
        let armed = hook
        hook = nil
        if armed != nil { fired = true }
        lock.unlock()
        armed?()
        // Nothing to reacquire — this presenter holds no state over the file.
        writer(nil)
    }
}
