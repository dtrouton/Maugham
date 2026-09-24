import XCTest
import MaughamCore
@testable import Maugham

/// **F7 (P3b smoke, 2026-09-23): an open window adopts a manifest another
/// device wrote, and the copy it replaces is the one archived.**
///
/// Until this fix `DocumentStore.handleManifestChanged` archived the INCOMING
/// manifest as a conflict and never assigned `projectStore.manifest`, so a
/// chapter another Mac added never appeared here and this Mac's next
/// structural save wrote its stale copy straight over it — last-writer-wins
/// with the wrong loser. The master spec's rule is: *"Last-writer-wins; the
/// loser is `.maugham/conflicts/manifest-<ts>.json`."*
@MainActor
final class ManifestAdoptionTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    /// The window's two stores, wired both ways exactly as `ProjectWindow.load`
    /// wires them.
    private func openWindow() async throws -> (URL, ProjectStore, DocumentStore) {
        let url = try await ProjectFactory.createNovelProject(
            named: "Adoption", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        ds.projectStore = store
        return (url, store, ds)
    }

    private func manifestURL(_ url: URL) -> URL {
        url.appendingPathComponent(ProjectManifest.fileName)
    }

    private func manifestOnDisk(_ url: URL) throws -> ProjectManifest {
        try ProjectManifest.makeDecoder().decode(
            ProjectManifest.self, from: Data(contentsOf: manifestURL(url)))
    }

    private func archives(in url: URL) -> [URL] {
        let dir = url.appendingPathComponent(".maugham/conflicts")
        return ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("manifest-") }
    }

    /// Another Mac, holding its own copy of the book, adds a chapter through
    /// the ordinary store verb. With no `DocumentStore` wired it writes the
    /// manifest directly — which is what arriving through sync looks like to
    /// this window's presenter.
    private func anotherMacAddsAChapter(
        _ url: URL, title: String = "Chapter Three"
    ) async throws -> StructureItem {
        let other = try await ProjectStore.load(from: url)
        return try await other.addStructureItem(
            parentId: nil, title: title, kind: .document(extension: "md"))
    }

    // MARK: - The headline

    func test_aManifestAnotherMacWroteIsAdopted() async throws {
        let (url, store, ds) = try await openWindow()
        let added = try await anotherMacAddsAChapter(url)
        XCTAssertNil(TreeWalk.find(id: added.id, in: store.manifest.structure))

        ds.presenterDidChangeSubitem(at: manifestURL(url))

        XCTAssertNotNil(TreeWalk.find(id: added.id, in: store.manifest.structure),
                        "the chapter another Mac added must appear in this window")
        await ds.close()
    }

    /// The consequence that made F7 a data-loss defect rather than a stale
    /// view: this Mac's next structural save must carry the other Mac's
    /// chapter, not write the stale copy over it.
    func test_theNextOwnStructuralSaveKeepsTheAdoptedChapter() async throws {
        let (url, store, ds) = try await openWindow()
        let added = try await anotherMacAddsAChapter(url)
        ds.presenterDidChangeSubitem(at: manifestURL(url))

        let mine = try await store.addStructureItem(
            parentId: nil, title: "Chapter Four", kind: .document(extension: "md"))

        let disk = try manifestOnDisk(url)
        XCTAssertNotNil(TreeWalk.find(id: added.id, in: disk.structure),
                        "the other Mac's chapter survived this Mac's save")
        XCTAssertNotNil(TreeWalk.find(id: mine.id, in: disk.structure))
        await ds.close()
    }

    /// The archive is the LOSER — the in-memory manifest the adoption replaced
    /// — and not the winner, which is already on disk and in the window.
    func test_theArchiveHoldsTheReplacedManifestNotTheIncomingOne() async throws {
        let (url, store, ds) = try await openWindow()
        let before = store.manifest
        let added = try await anotherMacAddsAChapter(url)

        ds.presenterDidChangeSubitem(at: manifestURL(url))

        let archived = archives(in: url)
        XCTAssertEqual(archived.count, 1, "\(archived)")
        let loser = try ProjectManifest.makeDecoder().decode(
            ProjectManifest.self, from: Data(contentsOf: archived[0]))
        XCTAssertNil(TreeWalk.find(id: added.id, in: loser.structure),
                     "the archive must not be the manifest that won")
        XCTAssertEqual(loser.structure.map(\.id), before.structure.map(\.id))
        await ds.close()
    }

    /// Bytes that differ but decode to the manifest this window already holds
    /// replace nothing, so there is no loser and nothing is archived.
    func test_aManifestThatSaysWhatThisWindowHoldsArchivesNothing() async throws {
        let (url, store, ds) = try await openWindow()
        let object = try JSONSerialization.jsonObject(
            with: ProjectManifest.makeEncoder().encode(store.manifest))
        // Same content, different bytes: compact rather than pretty-printed.
        try JSONSerialization.data(withJSONObject: object)
            .write(to: manifestURL(url), options: [.atomic])

        ds.presenterDidChangeSubitem(at: manifestURL(url))

        XCTAssertTrue(archives(in: url).isEmpty, "\(archives(in: url))")
        await ds.close()
    }

    // MARK: - What the adoption refuses

    /// A manifest from a LATER build is refused, never adopted: this build
    /// would decode it lossily and its next save would drop what it could not
    /// represent. The incoming bytes are archived so they outlive that save,
    /// which is today's behaviour for this case, kept.
    func test_aTooNewManifestIsNotAdoptedAndIsArchivedWhole() async throws {
        let (url, store, ds) = try await openWindow()
        let before = store.manifest
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: ProjectManifest.makeEncoder().encode(store.manifest)) as? [String: Any])
        object["schemaVersion"] = ProjectManifest.currentSchemaVersion + 1
        object["title"] = "Written by a later build"
        let incoming = try JSONSerialization.data(withJSONObject: object)
        try incoming.write(to: manifestURL(url), options: [.atomic])

        ds.presenterDidChangeSubitem(at: manifestURL(url))

        XCTAssertEqual(store.manifest, before, "a too-new manifest is never adopted")
        let archived = archives(in: url)
        XCTAssertEqual(archived.count, 1)
        XCTAssertEqual(try Data(contentsOf: archived[0]), incoming)
        await ds.close()
    }

    /// **A change of this window's own that never reached disk — a verb whose
    /// save threw — does not keep the window out of step for ever** (review
    /// M1). Outside a verb nothing is in flight, so the incoming manifest is
    /// adopted, and the unsaved copy is the loser the archive keeps.
    func test_anUnsavedChangeOutsideAVerbIsArchivedAndTheIncomingAdopted() async throws {
        let (url, store, ds) = try await openWindow()
        let firstId = store.manifest.structure[0].id
        store.mutateItem(id: firstId) { $0.title = "Renamed Here, Never Saved" }
        let added = try await anotherMacAddsAChapter(url)

        ds.presenterDidChangeSubitem(at: manifestURL(url))

        XCTAssertNotNil(TreeWalk.find(id: added.id, in: store.manifest.structure))
        let archived = archives(in: url)
        XCTAssertEqual(archived.count, 1)
        let loser = try ProjectManifest.makeDecoder().decode(
            ProjectManifest.self, from: Data(contentsOf: archived[0]))
        XCTAssertEqual(TreeWalk.find(id: firstId, in: loser.structure)?.title,
                       "Renamed Here, Never Saved",
                       "the unsaved change is kept aside, not dropped")
        await ds.close()
    }

    // MARK: - A manifest arriving mid-verb (review I1)

    /// **The verb that copies, waits and writes back.** `moveStructureItem`
    /// copies the destination's children, awaits `relocate` (which really
    /// suspends: it closes and flushes open Documents) and writes the copy
    /// back. A manifest adopted in that wait used to be undone by the write,
    /// and archived nowhere. Now it is held; the verb writes last, so it is the
    /// loser, and the archive keeps it.
    func test_aManifestArrivingMidVerbIsHeldAndKeptAsTheLoser() async throws {
        let (url, store, ds) = try await openWindow()
        let second = try await store.addStructureItem(
            parentId: nil, title: "Chapter Two", kind: .document(extension: "md"))
        var added: StructureItem?
        var adoptedMidVerb = false
        ds.relocateWillMove = { [weak ds, weak store] in
            guard let ds, let store else { return }
            added = try? await self.anotherMacAddsAChapter(url)
            ds.presenterDidChangeSubitem(at: self.manifestURL(url))
            adoptedMidVerb = added.map {
                TreeWalk.find(id: $0.id, in: store.manifest.structure) != nil
            } ?? false
        }

        try await store.moveStructureItem(id: second.id, toParentId: nil, atIndex: 0)
        ds.relocateWillMove = nil
        await ds.waitForStructuralVerbs()

        let chapter3 = try XCTUnwrap(added)
        XCTAssertFalse(adoptedMidVerb, "nothing is adopted while the verb holds its copy")
        XCTAssertEqual(store.manifest.structure.first?.id, second.id, "the move landed")
        let keptAside = try archives(in: url).map {
            try ProjectManifest.makeDecoder().decode(ProjectManifest.self, from: Data(contentsOf: $0))
        }
        XCTAssertTrue(
            keptAside.contains { TreeWalk.find(id: chapter3.id, in: $0.structure) != nil },
            "the manifest that lost is in .maugham/conflicts, not nowhere")
        await ds.close()
    }

    /// And a held manifest that nothing wrote over is taken on as soon as the
    /// verb is done.
    func test_aManifestHeldThroughAVerbThatWroteNothingIsAdoptedAfterIt() async throws {
        let (url, store, ds) = try await openWindow()
        store.beginStructuralVerb()
        let added = try await anotherMacAddsAChapter(url)
        ds.presenterDidChangeSubitem(at: manifestURL(url))
        XCTAssertNil(TreeWalk.find(id: added.id, in: store.manifest.structure),
                     "held while the verb runs")

        store.endStructuralVerb()
        await ds.waitForStructuralVerbs()

        XCTAssertNotNil(TreeWalk.find(id: added.id, in: store.manifest.structure))
        await ds.close()
    }

    // MARK: - A manifest nobody announced (review M2)

    /// The narrowing gate and the heal read the disk manifest and write it
    /// back, which records the bytes as this window's own echo. A manifest
    /// whose presenter callback had not yet run would then never be adopted.
    /// The read takes it on first.
    func test_readingTheManifestTakesOnOneWhoseCallbackHasNotRun() async throws {
        let (url, store, ds) = try await openWindow()
        let added = try await anotherMacAddsAChapter(url)

        _ = try await ds.readManifest()

        XCTAssertNotNil(TreeWalk.find(id: added.id, in: store.manifest.structure))
        await ds.close()
    }

    // MARK: - A piece open here, moved or trashed elsewhere (Denver, 2026-09-23)

    private func openAndType(
        _ path: String, in url: URL, ds: DocumentStore, text: String
    ) async throws -> Document {
        let doc = try await Document.load(
            url: url.appendingPathComponent(path), actor: .author,
            session: "adoption-test", presenter: ds.presenter)
        ds.register(document: doc, for: path)
        doc.setFullText(doc.displayText + "\n\n" + text)
        return doc
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func wordsInOpLog(_ id: String, _ store: ProjectStore) -> String {
        let state = try? store.derivedCache.state(forDocId: id, in: store.url)
        return state?.paragraphs.values.joined(separator: " ") ?? ""
    }

    /// **A remote rename follows.** The adoption moves the item's path, which
    /// is what the editor's path-keyed reload fires on (tripwire 22), and the
    /// Document open at the old path is let go of WITHOUT rendering there — a
    /// flush at the old path would be tripwire 14's phantom, arriving from
    /// another Mac. The words typed here are in the op log.
    func test_aRemoteRenameClosesTheOpenPieceWithoutAPhantomAtTheOldPath() async throws {
        let (url, store, ds) = try await openWindow()
        let item = store.manifest.structure[0]
        let oldPath = try XCTUnwrap(item.path)
        let doc = try await openAndType(oldPath, in: url, ds: ds, text: "Typed here before the rename.")
        // The other Mac's rename: the file moves, then the manifest says so.
        let newPath = "manuscript/01-renamed-elsewhere.md"
        try FileManager.default.moveItem(
            at: url.appendingPathComponent(oldPath), to: url.appendingPathComponent(newPath))
        var external = store.manifest
        external.structure[0].path = newPath
        try ProjectManifest.makeEncoder().encode(external)
            .write(to: manifestURL(url), options: [.atomic])

        ds.presenterDidChangeSubitem(at: manifestURL(url))
        await waitUntil { doc.isClosed }

        XCTAssertEqual(TreeWalk.find(id: item.id, in: store.manifest.structure)?.path, newPath)
        XCTAssertTrue(EditorHost.needsReload(
            itemId: item.id, path: newPath, loadedItemId: item.id, loadedPath: oldPath,
            loadedIsClosed: true),
            "the editor re-binds at the new path")
        XCTAssertTrue(doc.isClosed)
        XCTAssertNil(ds.document(for: oldPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent(oldPath).path),
                       "nothing was rendered back at the old path")
        XCTAssertTrue(wordsInOpLog(item.id, store).contains("Typed here before the rename."))
        await ds.close()
    }

    /// Every notice posted while `body` runs.
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

    /// **A remote trash closes the piece, with a notice.** The other Mac
    /// trashes it through the ordinary verb, so Trash really holds it. The
    /// editor has no item left to show, the Document takes no more keystrokes,
    /// nothing is rendered back at the old path, the words are in the op log,
    /// and the writer is told — "another device", because the trash record
    /// names none — that it can be restored from Trash, which lists it.
    func test_aRemoteTrashClosesTheOpenPieceAndSaysSo() async throws {
        let (url, store, ds) = try await openWindow()
        let item = store.manifest.structure[0]
        let path = try XCTUnwrap(item.path)
        let doc = try await openAndType(path, in: url, ds: ds, text: "Typed here before the trash.")
        let other = try await ProjectStore.load(from: url)
        try await other.deleteStructureItem(id: item.id)

        let seen = await notices {
            ds.presenterDidChangeSubitem(at: manifestURL(url))
            await waitUntil { doc.isClosed && !store.trashEntries.isEmpty }
            for _ in 0..<5 { await Task.yield() }
        }

        XCTAssertNil(TreeWalk.find(id: item.id, in: store.manifest.structure))
        XCTAssertTrue(doc.isClosed, "no more keystrokes into a piece that has left the structure")
        XCTAssertNil(ds.document(for: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent(path).path),
                       "nothing was rendered back where the piece used to be")
        XCTAssertTrue(wordsInOpLog(item.id, store).contains("Typed here before the trash."))
        // **Named** (F7 final round, M1 — Denver: "a notice naming who moved
        // it to Trash"). The Mac that trashed it recorded itself on the entry.
        let who = await DocumentStore.trashedByLabel(in: url)
        XCTAssertEqual(store.trashEntries.first?.trashedBy, who,
                       "the trashing Mac records who it is on the entry")
        XCTAssertEqual(seen, [DocumentStore.trashedElsewhereNotice(title: item.title, by: who)])
        XCTAssertTrue(seen.first?.contains("moved to Trash by \(who)") ?? false,
                      "the notice names who moved it")
        XCTAssertFalse(store.trashEntries.isEmpty, "the Trash the notice names lists the piece")
    }

    /// An entry an OLDER build wrote names nobody, and the notice says
    /// "another device" rather than inventing a name. No migration: the field
    /// is simply absent from its `meta.json`.
    func test_aRemoteTrashByAnOlderBuildSaysAnotherDevice() async throws {
        let (url, store, ds) = try await openWindow()
        let item = store.manifest.structure[0]
        let path = try XCTUnwrap(item.path)
        let doc = try await openAndType(path, in: url, ds: ds, text: "Typed here first.")
        let other = try await ProjectStore.load(from: url)
        try await other.deleteStructureItem(id: item.id)
        // What an older build's entry looks like: no `trashedBy` key at all.
        let entry = try XCTUnwrap(other.trashEntries.first)
        let metaURL = url.appendingPathComponent(".trash/\(entry.id)/meta.json")
        var meta = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: metaURL)) as? [String: Any])
        XCTAssertNotNil(meta.removeValue(forKey: "trashedBy"), "premise: this build records it")
        try JSONSerialization.data(withJSONObject: meta).write(to: metaURL, options: .atomic)

        let seen = await notices {
            ds.presenterDidChangeSubitem(at: manifestURL(url))
            await waitUntil { doc.isClosed && !store.trashEntries.isEmpty }
            for _ in 0..<5 { await Task.yield() }
        }

        XCTAssertNil(store.trashEntries.first?.trashedBy)
        XCTAssertEqual(seen, [DocumentStore.trashedElsewhereNotice(title: item.title, by: nil)])
        XCTAssertTrue(seen.first?.contains("on another device") ?? false)
        XCTAssertFalse(seen.first?.contains("Trash by") ?? true, "no name is invented")
    }

    /// **Absence is not trash** (second fix round, I-B). A piece can leave the
    /// structure without going to Trash — an older build saving its stale
    /// window over this book drops every piece it never saw. The notice must
    /// not send the writer to a Trash that is empty.
    func test_aPieceThatLeftWithoutGoingToTrashIsNotSaidToBeInTrash() async throws {
        let (url, store, ds) = try await openWindow()
        let item = store.manifest.structure[0]
        let path = try XCTUnwrap(item.path)
        let doc = try await openAndType(path, in: url, ds: ds, text: "Typed here, then dropped elsewhere.")
        var external = store.manifest
        external.structure.removeAll { $0.id == item.id }
        try ProjectManifest.makeEncoder().encode(external)
            .write(to: manifestURL(url), options: [.atomic])

        let seen = await notices {
            ds.presenterDidChangeSubitem(at: manifestURL(url))
            await waitUntil { doc.isClosed }
            for _ in 0..<20 { await Task.yield() }
            try? await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertEqual(seen, [DocumentStore.removedElsewhereNotice(title: item.title)])
        XCTAssertFalse(seen.first?.contains("restored from Trash") ?? true,
                       "the notice must not send the writer to an empty Trash")
        // The way back it names is real (Denver's ruling, 2026-09-24): the
        // adoption archived the outline that held it, so the list has it.
        XCTAssertTrue(seen.first?.contains("Removed Elsewhere") ?? false)
        // It says what happened to the BINDER, as Removed Elsewhere does
        // (review M6): the archive cannot tell another device's stale outline
        // from an addition that lost a last-writer-wins race, so the notice
        // names no device and no act of one.
        XCTAssertTrue(seen.first?.contains("left the binder when two devices\u{2019} outlines crossed") ?? false,
                      "\(seen)")
        XCTAssertFalse(seen.first?.contains("another device") ?? true,
                       "the notice claims a device removed it, which the archive cannot say")
        await store.refreshRemovedElsewhere()
        XCTAssertEqual(store.removedElsewhere.map(\.id), [item.id])
        XCTAssertTrue(wordsInOpLog(item.id, store).contains("Typed here, then dropped elsewhere."))
    }

    // MARK: - Word counts (Denver, 2026-09-23)

    /// Another Mac's chapter, with words in its op log.
    private func anotherMacWritesAChapter(_ url: URL, words: String) async throws -> StructureItem {
        let added = try await anotherMacAddsAChapter(url, title: "Their Chapter")
        let doc = try await Document.load(
            url: url.appendingPathComponent(try XCTUnwrap(added.path)),
            actor: .author, session: "other-mac", presenter: nil)
        doc.setFullText(words)
        await doc.close()
        return added
    }

    /// **Half one: a piece that arrived shows its true count.**
    func test_aPieceAnotherMacAddedShowsItsTrueCount() async throws {
        let (url, store, ds) = try await openWindow()
        let before = store.projectWordCount
        let added = try await anotherMacWritesAChapter(url, words: "one two three four five")

        ds.presenterDidChangeSubitem(at: manifestURL(url))
        await store.opLogRecountTask?.value

        XCTAssertEqual(store.cachedWordCount(for: added.id), 5)
        XCTAssertEqual(store.projectWordCount, before + 5)
        await ds.close()
    }

    /// **I2 (final round): the adoption itself derives nothing.** Counting an
    /// arrived piece is a verified registry read plus a full derive; inside the
    /// presenter callback — or inside `readManifest()` under a permit verb's
    /// gate — that was main-actor work per piece. The adoption hands the pieces
    /// over and returns; the counting pass resolves ONE trust table for all of
    /// them, and the counts still converge.
    func test_theAdoptionDerivesNothingAndTheCountsStillConverge() async throws {
        let (url, store, ds) = try await openWindow()
        let before = store.projectWordCount
        let first = try await anotherMacWritesAChapter(url, words: "one two three")
        let second = try await anotherMacWritesAChapter(url, words: "four five")
        let derivesBefore = store.derivedCache.deriveCount
        let resolutionsBefore = store.recountTrustResolutions

        ds.presenterDidChangeSubitem(at: manifestURL(url))

        XCTAssertNotNil(TreeWalk.find(id: second.id, in: store.manifest.structure),
                        "premise: the manifest was adopted")
        XCTAssertEqual(store.derivedCache.deriveCount, derivesBefore,
                       "the adoption derived a piece inside the presenter callback")
        XCTAssertNil(store.cachedWordCount(for: first.id),
                     "nothing is counted until the pass runs")

        await store.opLogRecountTask?.value

        XCTAssertEqual(store.cachedWordCount(for: first.id), 3)
        XCTAssertEqual(store.cachedWordCount(for: second.id), 2)
        XCTAssertEqual(store.projectWordCount, before + 5)
        XCTAssertEqual(store.recountTrustResolutions, resolutionsBefore + 1,
                       "one trust table for the pass, not one per piece")
        await ds.close()
    }

    /// And the pass never revives a piece that left before it was counted: the
    /// other Mac adds a chapter and removes it again before this window's
    /// counting pass reaches it.
    func test_aLateCountDoesNotReviveAPieceThatHasLeft() async throws {
        let (url, store, ds) = try await openWindow()
        let added = try await anotherMacWritesAChapter(url, words: "one two three")
        ds.presenterDidChangeSubitem(at: manifestURL(url))
        var external = store.manifest
        external.structure.removeAll { $0.id == added.id }
        try ProjectManifest.makeEncoder().encode(external)
            .write(to: manifestURL(url), options: [.atomic])
        ds.presenterDidChangeSubitem(at: manifestURL(url))

        await store.opLogRecountTask?.value

        XCTAssertNil(store.cachedWordCount(for: added.id))
        await ds.close()
    }

    /// And a piece that left takes its count with it.
    func test_aPieceAnotherMacRemovedLeavesTheCount() async throws {
        let (url, store, ds) = try await openWindow()
        let added = try await anotherMacWritesAChapter(url, words: "one two three")
        ds.presenterDidChangeSubitem(at: manifestURL(url))
        await store.opLogRecountTask?.value
        XCTAssertEqual(store.cachedWordCount(for: added.id), 3)
        var external = store.manifest
        external.structure.removeAll { $0.id == added.id }
        try ProjectManifest.makeEncoder().encode(external)
            .write(to: manifestURL(url), options: [.atomic])

        ds.presenterDidChangeSubitem(at: manifestURL(url))

        XCTAssertNil(store.cachedWordCount(for: added.id))
        await ds.close()
    }

    /// **Half two: another person's words never enter this writer's session**
    /// — not the live count and not the session event that goes into the log
    /// behind wordsToday and the streaks.
    func test_anotherMacsWordsNeverEnterThisWritersSession() async throws {
        let (url, store, ds) = try await openWindow()
        // The writer starts a session here.
        ds.recordSessionActivity(
            documentId: store.manifest.structure[0].id,
            projectWordCount: store.projectWordCount)
        XCTAssertEqual(ds.liveSessionWordsNet, 0)

        _ = try await anotherMacWritesAChapter(url, words: "one two three four five six seven")
        ds.presenterDidChangeSubitem(at: manifestURL(url))
        await store.opLogRecountTask?.value

        XCTAssertEqual(ds.liveSessionWordsNet, 0, "their seven words are not this session's")
        // The writer's next keystroke reports the project total, which now
        // includes the other Mac's piece: still none of it is theirs.
        ds.recordSessionActivity(
            documentId: store.manifest.structure[0].id,
            projectWordCount: store.projectWordCount)
        XCTAssertEqual(ds.liveSessionWordsNet, 0, "not even at the next keystroke")
        await ds.flushSessionOnQuit()
        let log = try await ds.loadSessionLog()
        XCTAssertEqual(log.events.last?.wordsNet, 0)
        await ds.close()
    }

    // MARK: - Second fix round

    /// **m1: the gate and the heal wait for a held manifest to settle.** They
    /// read the disk manifest and write it back raised. Reading while a
    /// manifest is held would write the HELD bytes back, make them this
    /// window's echo, and the settle would then conclude this window wrote
    /// last and archive them without ever adopting them.
    func test_theGatesReadWaitsForAHeldManifestAndItIsAdopted() async throws {
        let (url, store, ds) = try await openWindow()
        store.beginStructuralVerb()
        let added = try await anotherMacAddsAChapter(url)
        ds.presenterDidChangeSubitem(at: manifestURL(url))
        // The gate's shape: read, then write back raised.
        let gate = Task { @MainActor in
            let data = try await ds.readManifest()
            try await ds.writeManifest(ProjectManifest.raising(
                data, toAtLeast: ProjectManifest.currentSchemaVersion))
        }
        for _ in 0..<20 { await Task.yield() }

        store.endStructuralVerb()
        try await gate.value

        XCTAssertNotNil(TreeWalk.find(id: added.id, in: store.manifest.structure),
                        "the held manifest was adopted, not archived as this window's loser")
        XCTAssertNotNil(TreeWalk.find(id: added.id, in: try manifestOnDisk(url).structure))
        await ds.close()
    }

    /// **m2: a verb's rollback lands before a held manifest is adopted.**
    /// `commitProductionRoles` puts its old roles and stamp back in a `catch`
    /// when its save fails. If the save's own verb settled first, that rollback
    /// would land ON the manifest another device just wrote.
    func test_aFailedSavesRollbackDoesNotLandOnAnAdoptedManifest() async throws {
        let (url, store, ds) = try await openWindow()
        let fm = FileManager.default
        let original = try XCTUnwrap(
            fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
        defer { try? fm.setAttributes([.posixPermissions: original], ofItemAtPath: url.path) }
        var external = store.manifest
        external.title = "Written Elsewhere"
        external.modified = Date(timeIntervalSince1970: 2_000_000_000)
        let externalBytes = try ProjectManifest.makeEncoder().encode(external)
        ds.writeManifestWillWrite = { [weak ds] in
            guard let ds else { return }
            ds.writeManifestWillWrite = nil
            // The other device's manifest lands mid-save (written in place: the
            // folder is read-only, which is also what makes this save fail).
            let handle = try? FileHandle(forWritingTo: self.manifestURL(url))
            try? handle?.truncate(atOffset: 0)
            try? handle?.write(contentsOf: externalBytes)
            try? handle?.close()
            ds.presenterDidChangeSubitem(at: self.manifestURL(url))
        }
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: url.path)

        do {
            _ = try await store.translatorRole(for: "es")
            XCTFail("expected the manifest write to be refused")
        } catch {}
        try fm.setAttributes([.posixPermissions: original], ofItemAtPath: url.path)
        await ds.waitForStructuralVerbs()

        XCTAssertEqual(store.manifest.title, "Written Elsewhere")
        XCTAssertEqual(store.manifest.modified.timeIntervalSince1970, 2_000_000_000,
                       "the rollback's old stamp did not land on the adopted manifest")
        XCTAssertTrue(store.manifest.productionRoles.isEmpty)
        await ds.close()
    }

    /// **m3, the lagging op log.** The manifest names the other Mac's piece
    /// before its op log has synced, so the adoption can count nothing. When
    /// the words arrive and the writer opens the piece and types one word, the
    /// session gains one word — not the piece's whole count.
    func test_aPieceWhoseWordsArriveAfterItsManifestNeverEntersTheSession() async throws {
        let (url, store, ds) = try await openWindow()
        ds.recordSessionActivity(
            documentId: store.manifest.structure[0].id,
            projectWordCount: store.projectWordCount)
        let added = try await anotherMacAddsAChapter(url, title: "Late Words")
        ds.presenterDidChangeSubitem(at: manifestURL(url))
        await store.opLogRecountTask?.value
        let path = try XCTUnwrap(added.path)
        // Their words arrive afterwards.
        let theirs = try await Document.load(
            url: url.appendingPathComponent(path), actor: .author,
            session: "other-mac", presenter: nil)
        theirs.setFullText("one two three four five six")
        await theirs.close()

        // The writer opens the piece and types one word.
        let doc = try await Document.load(
            url: url.appendingPathComponent(path), actor: .author,
            session: "adoption-test", presenter: ds.presenter)
        ds.register(document: doc, for: path)
        let typed = doc.displayText + " seven"
        doc.setFullText(typed)
        ds.recordEditorTextWrite(
            documentId: doc.docId, newText: typed,
            mode: WritingModeFactory.mode(for: path), store: store)

        XCTAssertEqual(ds.liveSessionWordsNet, 1, "one word typed, one word in the session")
        XCTAssertEqual(store.cachedWordCount(for: added.id), 7, "and the piece shows its true count")
        await doc.close()
        await ds.close()
    }

    /// **m3, the load-time pass.** The word-count pass iterates the manifest
    /// as it stood at open; a piece another device has since removed must stay
    /// forgotten, and nothing the pass counts enters a session under way.
    func test_theLoadTimeCountingPassNeitherRevivesARemovedPieceNorFeedsTheSession() async throws {
        let (url, store, ds) = try await openWindow()
        let added = try await anotherMacWritesAChapter(url, words: "one two three four")
        ds.presenterDidChangeSubitem(at: manifestURL(url))
        await store.opLogRecountTask?.value
        let withIt = store.manifest
        ds.recordSessionActivity(
            documentId: store.manifest.structure[0].id,
            projectWordCount: store.projectWordCount)
        var external = store.manifest
        external.structure.removeAll { $0.id == added.id }
        try ProjectManifest.makeEncoder().encode(external)
            .write(to: manifestURL(url), options: [.atomic])
        ds.presenterDidChangeSubitem(at: manifestURL(url))
        XCTAssertNil(store.cachedWordCount(for: added.id))

        // A pass that began over the manifest that still held the piece.
        store.beginWordCountPopulation(from: withIt, at: url)
        await store.wordCountPopulationTask?.value

        XCTAssertNil(store.cachedWordCount(for: added.id), "a removed piece stays forgotten")
        ds.recordSessionActivity(
            documentId: store.manifest.structure[0].id,
            projectWordCount: store.projectWordCount)
        XCTAssertEqual(ds.liveSessionWordsNet, 0)
        await ds.close()
    }
}
