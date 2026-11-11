import XCTest
@testable import Maugham
@testable import MaughamCore

/// **Every writer of an existing Research note's text goes through the note
/// door** (note versions plan 2, Task 4): a wiki rename's link sweep, Search &
/// Replace, and a note's asset refs rewritten after a rename or a move each
/// keep the text they replace as a version, and none is undone by an edit the
/// editor had queued. A palette card keeps a version the same way (Denver,
/// 2026-11-11). The promotion writers are pinned in
/// `PromotionPerformerTests` beside their fixture.
@MainActor
final class ResearchNoteWritersTests: XCTestCase {

    private var projectURL: URL!
    private var stores: [DocumentStore] = []
    private var lockedPaths: [URL] = []

    override func setUp() async throws {
        projectURL = TestTemp.root.appendingPathComponent("notewriters-\(UUID().uuidString)")
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
        for path in lockedPaths {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
        lockedPaths = []
        for observer in noticeObservers { NotificationCenter.default.removeObserver(observer) }
        noticeObservers = []
        for store in stores { await store.close() }
        stores = []
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        try? FileManager.default.removeItem(at: projectURL)
    }

    // MARK: - Fixture

    /// A novel with one chapter, "Alpha", and both stores wired both ways, as
    /// `ProjectSession.open` wires them.
    private func openBook() async throws -> (DocumentStore, ProjectStore) {
        try "Words.\n".write(to: file("manuscript/a.md"), atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [StructureItem(id: "doc-a", title: "Alpha", type: .document, path: "manuscript/a.md")],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: file(ProjectManifest.fileName))
        let store = try await DocumentStore.open(url: projectURL)
        stores.append(store)
        let doc = try await Document.load(
            url: file("manuscript/a.md"), actor: .author, session: "boot", presenter: nil)
        await doc.close()
        let projectStore = try await ProjectStore.load(from: projectURL)
        projectStore.documentStore = store
        store.projectStore = projectStore
        return (store, projectStore)
    }

    private func file(_ relative: String) -> URL { projectURL.appendingPathComponent(relative) }

    /// A note made the way the writer makes one, holding `text` on disk.
    private func note(_ text: String, titled title: String = "Notes",
                      in projectStore: ProjectStore) async throws -> ResearchItem {
        let item = try await projectStore.createResearchNote(scope: .shared, title: title)
        try Data(text.utf8).write(to: file(try XCTUnwrap(item.path)))
        return item
    }

    private func current(_ item: ResearchItem, _ projectStore: ProjectStore) throws -> ResearchItem {
        try XCTUnwrap(projectStore.findResearchItem(id: item.id, in: projectStore.manifest.research))
    }

    private func text(of item: ResearchItem, _ projectStore: ProjectStore) throws -> String {
        String(decoding: try Data(contentsOf: file(try XCTUnwrap(current(item, projectStore).path))),
               as: UTF8.self)
    }

    private func versions(of item: ResearchItem) -> [ResearchVersion] {
        ResearchVersionStore(projectURL: projectURL).versions(itemId: item.id)
    }

    /// The text of the newest version kept for `item`.
    private func newestVersionText(of item: ResearchItem) throws -> String {
        let newest = try XCTUnwrap(versions(of: item).max(by: { $0.savedAt < $1.savedAt }),
                                   "no version was kept")
        XCTAssertEqual(newest.payload, .note)
        return String(decoding: try ResearchVersionStore(projectURL: projectURL).read(newest).0,
                      as: UTF8.self)
    }

    /// An edit the open editor has queued and not yet saved (its debounce
    /// never fires on its own inside the test).
    private func queueEdit(_ text: String, of item: ResearchItem, _ store: DocumentStore) {
        store.researchNoteDoor.saveDelay = .seconds(3600)
        store.scheduleNoteSave(itemId: item.id, text: text)
        XCTAssertTrue(store.researchNoteHasPendingSave(itemId: item.id))
    }

    /// The editor's own save of `text`, flushed now: afterwards the store
    /// knows the bytes on disk and the writer's typing run is under way.
    private func typed(_ text: String, into item: ResearchItem, _ store: DocumentStore) async throws {
        store.researchNoteDoor.saveDelay = .seconds(3600)
        store.scheduleNoteSave(itemId: item.id, text: text)
        try await store.flushPendingSave()
    }

    private func versionTexts(of item: ResearchItem) throws -> [String] {
        let versions = ResearchVersionStore(projectURL: projectURL)
        return try versions.versions(itemId: item.id).map {
            String(decoding: try versions.read($0).0, as: UTF8.self)
        }
    }

    private final class Heard: @unchecked Sendable { var notices: [String] = [] }   // touched on the main actor only
    private var noticeObservers: [NSObjectProtocol] = []

    private func listen() -> Heard {
        let heard = Heard()
        noticeObservers.append(NotificationCenter.default.addObserver( // adr-0021-ok: a test observing the production post, not a production subscription
            forName: .maughamDocumentNotice, object: nil, queue: nil
        ) { note in
            if let message = note.userInfo?[MaughamEvent.noticeMessageKey] as? String {
                MainActor.assumeIsolated { heard.notices.append(message) }
            }
        })
        return heard
    }

    private func search(_ query: String, _ projectStore: ProjectStore) async -> SearchResults {
        await ProjectSearchEngine().search(query: query, options: SearchOptions(), in: projectStore)
    }

    private func lock(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path)
        lockedPaths.append(url)
    }

    // MARK: - The rename's link sweep (recon §6 row 4)

    func test_aWikiRenameKeepsTheLinkingNotesTextAsAVersion() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await note("See [[Alpha]] for the fog.", in: projectStore)

        await projectStore.propagateWikiLinkRename(excludeId: "doc-a", oldTitle: "Alpha", newTitle: "Omega")

        XCTAssertEqual(try text(of: item, projectStore), "See [[Omega]] for the fog.")
        XCTAssertEqual(try newestVersionText(of: item), "See [[Alpha]] for the fog.",
                       "the text the rename replaced is a version")
        XCTAssertGreaterThan(store.researchNoteReloadCount(itemId: item.id), 0,
                             "an editor open on the note re-reads it")
    }

    func test_aWikiRenameOverAQueuedEditKeepsTheEdit() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await note("See [[Alpha]].", in: projectStore)
        queueEdit("See [[Alpha]]. Typed a moment ago.", of: item, store)

        await projectStore.propagateWikiLinkRename(excludeId: "doc-a", oldTitle: "Alpha", newTitle: "Omega")
        try await store.flushPendingSave()

        XCTAssertEqual(try text(of: item, projectStore), "See [[Omega]]. Typed a moment ago.",
                       "the queued edit is saved first and renamed with the rest")
    }

    func test_aWikiRenameThatRewritesAPaletteCardKeepsItsTextAsAVersion() async throws {
        let (store, projectStore) = try await openBook()
        let card = try await projectStore.addPaletteCard(title: "Fog", kind: .other)
        let cardText = "# Fog\n\nThe light in [[Alpha]].\n"
        try Data(cardText.utf8).write(to: file(try XCTUnwrap(card.path)))

        await projectStore.propagateWikiLinkRename(excludeId: "doc-a", oldTitle: "Alpha", newTitle: "Omega")

        XCTAssertEqual(try text(of: card, projectStore), "# Fog\n\nThe light in [[Omega]].\n",
                       "the card is still rewritten")
        XCTAssertEqual(try newestVersionText(of: card), cardText, "the card's text the rename replaced is a version")
        XCTAssertGreaterThan(store.researchNoteReloadCount(itemId: card.id), 0,
                             "a card editor open on it re-reads it")
    }

    // MARK: - Search & Replace (recon §6 row 5)

    func test_replaceAllKeepsTheNotesTextAsAVersion() async throws {
        let (_, projectStore) = try await openBook()
        let item = try await note("The fog came in. The fog stayed.", in: projectStore)

        let results = await search("fog", projectStore)
        XCTAssertEqual(results.matches.filter { $0.documentSource == .research }.count, 2)
        try await projectStore.replaceAll(in: results, with: "mist")

        XCTAssertEqual(try text(of: item, projectStore), "The mist came in. The mist stayed.")
        XCTAssertEqual(try newestVersionText(of: item), "The fog came in. The fog stayed.")
    }

    func test_replaceMatchKeepsTheNotesTextAsAVersion() async throws {
        let (_, projectStore) = try await openBook()
        let item = try await note("The fog came in.", in: projectStore)

        let results = await search("fog", projectStore)
        projectStore.currentSearch = results
        let match = try XCTUnwrap(results.matches.first { $0.documentSource == .research })
        try await projectStore.replaceMatch(match, with: "mist")

        XCTAssertEqual(try text(of: item, projectStore), "The mist came in.")
        XCTAssertEqual(try newestVersionText(of: item), "The fog came in.")
    }

    /// The editor's queued edit used to land AFTER the raw write and put the
    /// unreplaced text back: Replace now flushes first and writes through the
    /// door, so both the edit and the replacement stand.
    func test_replaceAllOverANoteWithAnUnflushedEditDoesNotClobberIt() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await note("The fog came in.", in: projectStore)
        let results = await search("fog", projectStore)
        queueEdit("The fog came in. Then the rain.", of: item, store)

        try await projectStore.replaceAll(in: results, with: "mist")
        try await store.flushPendingSave()

        XCTAssertEqual(try text(of: item, projectStore), "The mist came in. Then the rain.")
        XCTAssertFalse(store.researchNoteHasPendingSave(itemId: item.id))
    }

    func test_replaceAllInAPaletteCardKeepsItsTextAsAVersion() async throws {
        let (_, projectStore) = try await openBook()
        let card = try await projectStore.addPaletteCard(title: "Weather", kind: .other)
        try Data("# Weather\n\nCold fog.\n".utf8).write(to: file(try XCTUnwrap(card.path)))

        try await projectStore.replaceAll(in: await search("fog", projectStore), with: "mist")

        XCTAssertEqual(try text(of: card, projectStore), "# Weather\n\nCold mist.\n")
        XCTAssertEqual(try newestVersionText(of: card), "# Weather\n\nCold fog.\n")
    }

    /// `.notSaved` is not swallowed: Replace throws as any failed write of
    /// it does, and the note is as it was.
    func test_aReplaceWhoseVersionCannotBeKeptThrowsAndLeavesTheNote() async throws {
        let (_, projectStore) = try await openBook()
        let item = try await note("The fog came in.", in: projectStore)
        try lock(file(".maugham/research-versions"))

        do {
            try await projectStore.replaceAll(in: await search("fog", projectStore), with: "mist")
            XCTFail("a replace the door refused must say so")
        } catch ProjectStoreError.fileSystemError(let reason) {
            XCTAssertTrue(reason.contains("Notes"), reason)
        }
        XCTAssertEqual(try text(of: item, projectStore), "The fog came in.")
    }

    // MARK: - Asset refs after a rename or a move (recon §6 row 6)

    func test_renamingANoteWithAssetsKeepsItsTextAsAVersion() async throws {
        let (_, projectStore) = try await openBook()
        let item = try await note("![](./harbor_assets/img.png)", titled: "Harbor", in: projectStore)
        let assets = file("research/harbor_assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data([0xFF]).write(to: assets.appendingPathComponent("img.png"))

        try await projectStore.updateResearchItem(id: item.id, title: "Quay")

        XCTAssertEqual(try current(item, projectStore).path, "research/quay.md")
        XCTAssertEqual(try text(of: item, projectStore), "![](./quay_assets/img.png)")
        XCTAssertEqual(try newestVersionText(of: item), "![](./harbor_assets/img.png)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file("research/harbor.md").path),
                       "the write lands where the note now is, not at its old path")
    }

    func test_movingANoteWhoseStemDedupsKeepsItsTextAsAVersion() async throws {
        let (_, projectStore) = try await openBook()
        let group = try await projectStore.addResearchItem(parentId: nil, title: "World", kind: nil)
        let groupPath = try XCTUnwrap(current(group, projectStore).path)
        let item = try await note("![](./sarah_assets/img.png)", titled: "Sarah", in: projectStore)
        let assets = file("research/sarah_assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data([0xFF]).write(to: assets.appendingPathComponent("img.png"))
        // An orphaned `sarah_assets` at the destination makes the stem dedup.
        try FileManager.default.createDirectory(
            at: file("\(groupPath)/sarah_assets"), withIntermediateDirectories: true)

        try await projectStore.moveResearchItems(ids: [item.id], to: .group(group.id))

        XCTAssertEqual(try current(item, projectStore).path, "\(groupPath)/sarah-2.md")
        XCTAssertEqual(try text(of: item, projectStore), "![](./sarah-2_assets/img.png)")
        XCTAssertEqual(try newestVersionText(of: item), "![](./sarah_assets/img.png)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file("research/sarah.md").path))
    }

    // MARK: - A direct write inside the writer's typing run (fix round 1)

    /// The editor saved a moment ago, so the store knows the bytes and the
    /// writer's run is open: Replace still keeps what it replaces (it has no
    /// undo), whatever the run says.
    func test_aReplaceInsideTheWritersTypingRunStillKeepsWhatItReplaces() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await note("Before.", in: projectStore)
        try await typed("The fog I typed.", into: item, store)
        let before = versions(of: item).count

        try await projectStore.replaceAll(in: await search("fog", projectStore), with: "mist")

        XCTAssertEqual(try text(of: item, projectStore), "The mist I typed.")
        XCTAssertEqual(versions(of: item).count, before + 1)
        XCTAssertTrue(try versionTexts(of: item).contains("The fog I typed."))
    }

    func test_aRenameSweepInsideTheWritersTypingRunStillKeepsWhatItReplaces() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await note("Before.", in: projectStore)
        try await typed("Typed: see [[Alpha]].", into: item, store)
        let before = versions(of: item).count

        await projectStore.propagateWikiLinkRename(excludeId: "doc-a", oldTitle: "Alpha", newTitle: "Omega")

        XCTAssertEqual(try text(of: item, projectStore), "Typed: see [[Omega]].")
        XCTAssertEqual(versions(of: item).count, before + 1)
        XCTAssertTrue(try versionTexts(of: item).contains("Typed: see [[Alpha]]."))
    }

    /// A direct write ends the writer's run: their next typed save keeps the
    /// direct write's text, so it can be got back too.
    func test_theWritersNextTypedSaveAfterADirectWriteKeepsAgain() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await note("Before.", in: projectStore)
        try await typed("The fog I typed.", into: item, store)
        try await projectStore.replaceAll(in: await search("fog", projectStore), with: "mist")
        // The open editor reloads what the Replace wrote (it has now seen it).
        store.researchNoteWasRead(itemId: item.id, bytes: Data(try text(of: item, projectStore).utf8))
        let before = versions(of: item).count

        try await typed("The mist I typed, and more.", into: item, store)

        XCTAssertEqual(versions(of: item).count, before + 1, "the run ended at the Replace")
        XCTAssertTrue(try versionTexts(of: item).contains("The mist I typed."))
    }

    // MARK: - Asset refs land even when the version cannot be kept (fix round 1)

    /// The move has happened, so refs left stale would point at a folder that
    /// is gone: the rewrite is saved anyway, and the writer is told the
    /// earlier version was not kept.
    func test_anAssetRefRewriteWhoseVersionCannotBeKeptStillLands_andSaysSo() async throws {
        let (_, projectStore) = try await openBook()
        let item = try await note("![](./harbor_assets/img.png)", titled: "Harbor", in: projectStore)
        let assets = file("research/harbor_assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data([0xFF]).write(to: assets.appendingPathComponent("img.png"))
        try lock(file(".maugham/research-versions"))
        let heard = listen()

        try await projectStore.updateResearchItem(id: item.id, title: "Quay")

        XCTAssertEqual(try text(of: item, projectStore), "![](./quay_assets/img.png)",
                       "the refs follow the folder that moved")
        XCTAssertTrue(versions(of: item).isEmpty)
        XCTAssertTrue(heard.notices.contains("“Quay”’s previous version couldn’t be kept; its picture links were updated anyway."),
                      "the notice speaks of the refs, not of edits the writer never typed: \(heard.notices)")
    }

    // MARK: - A writer that reads the note waits for a save in flight (whole-branch C1)

    /// An edit is pending; a flush (a note switch, ⌘S, any MCP tool's
    /// `flushPendingSave`) takes it and is in its keep when a
    /// read-modify-write writer reaches the note. The writer must read the
    /// flushed text, not the bytes before it: its own save queues behind the
    /// flush, so text made from the older bytes would be written over the
    /// writer's edit.
    func test_aWriterThatReadsTheNoteWaitsForAFlushAlreadyInFlight() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await note("v1 ![](./harbor_assets/img.png)", titled: "Harbor", in: projectStore)
        queueEdit("v2, typed ![](./harbor_assets/img.png)", of: item, store)

        var writer: Task<Void, Never>?
        store.researchNoteDoor.keepWillRunForTesting = {
            guard writer == nil else { return }
            // Started, not awaited: the writer waits for this very save.
            writer = Task { @MainActor in
                await projectStore.rewriteMovedNoteAssetRefs(itemId: item.id, oldStem: "harbor", newStem: "quay")
            }
            // Let it run as far as it goes while this save is mid-keep.
            for _ in 0..<20 { await Task.yield() }
        }
        try await store.flushPendingSave()
        let started = try XCTUnwrap(writer)
        await started.value

        XCTAssertEqual(try text(of: item, projectStore), "v2, typed ![](./quay_assets/img.png)",
                       "the typed text and the writer's change both stand")
    }

    /// Two direct writers on one note: the second, reaching the note while
    /// the first's save is mid-keep, reads the first's text.
    func test_twoWritersOnOneNoteEachKeepTheOthersChange() async throws {
        let (store, projectStore) = try await openBook()
        let item = try await note("![](./a_assets/1.png) ![](./b_assets/2.png)", titled: "Harbor", in: projectStore)

        var second: Task<Void, Never>?
        store.researchNoteDoor.keepWillRunForTesting = {
            guard second == nil else { return }
            second = Task { @MainActor in
                await projectStore.rewriteMovedNoteAssetRefs(itemId: item.id, oldStem: "b", newStem: "d")
            }
            for _ in 0..<20 { await Task.yield() }
        }
        await projectStore.rewriteMovedNoteAssetRefs(itemId: item.id, oldStem: "a", newStem: "c")
        let started = try XCTUnwrap(second)
        await started.value

        XCTAssertEqual(try text(of: item, projectStore), "![](./c_assets/1.png) ![](./d_assets/2.png)")
    }

    // MARK: - No writer's fallback writes outside a research root (whole-branch C2)

    /// A `.document` Research item planted at `path` (as a synced manifest
    /// can list one), its file holding `text`.
    private func stray(_ path: String, _ text: String, id: String,
                       in projectStore: ProjectStore) throws -> ResearchItem {
        let url = file(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        let item = ResearchItem(id: id, title: "Stray \(id)", type: .asset, kind: .document, path: path)
        projectStore.manifest.research.append(item)
        return item
    }

    private static let outsidePaths = ["manuscript/stray.md", ".maugham/stray.md", "research-old/stray.md"]

    func test_theRenameSweepWritesNothingOutsideAResearchRoot() async throws {
        let (_, projectStore) = try await openBook()
        let strays = try Self.outsidePaths.enumerated().map {
            try stray($1, "See [[Alpha]].", id: "res-sweep00\($0)", in: projectStore)
        }
        await projectStore.propagateWikiLinkRename(excludeId: "doc-a", oldTitle: "Alpha", newTitle: "Omega")
        for item in strays {
            XCTAssertEqual(try text(of: item, projectStore), "See [[Alpha]].", item.path ?? "")
            XCTAssertTrue(versions(of: item).isEmpty)
        }
    }

    func test_anAssetRefRewriteWritesNothingOutsideAResearchRoot() async throws {
        let (_, projectStore) = try await openBook()
        for (n, path) in Self.outsidePaths.enumerated() {
            let item = try stray(path, "![](./a_assets/1.png)", id: "res-asset00\(n)", in: projectStore)
            await projectStore.rewriteMovedNoteAssetRefs(itemId: item.id, oldStem: "a", newStem: "b")
            XCTAssertEqual(try text(of: item, projectStore), "![](./a_assets/1.png)", path)
            XCTAssertTrue(versions(of: item).isEmpty)
        }
    }

    /// Replace All leaves a file outside a research root as it was and names
    /// it (its existing "left alone" story); Replace (one match) throws.
    /// A Research file with no manifest item keeps its raw write only inside
    /// a research root.
    func test_replaceWritesNothingOutsideAResearchRoot() async throws {
        let (_, projectStore) = try await openBook()
        let strays = try Self.outsidePaths.enumerated().map {
            try stray($1, "The fog.", id: "res-repla00\($0)", in: projectStore)
        }
        let loose = try stray("research/loose.md", "The fog.", id: "res-loose000", in: projectStore)
        let unlisted = try stray("manuscript/unlisted.md", "The fog.", id: "res-unlist00", in: projectStore)
        let results = await search("fog", projectStore)
        XCTAssertEqual(Set(results.matches.map(\.documentPath)),
                       Set(Self.outsidePaths + ["research/loose.md", "manuscript/unlisted.md"]),
                       "premise: Search finds every planted file")
        // Gone from the manifest since the search: no item names these paths.
        projectStore.manifest.research.removeAll { $0.id == loose.id || $0.id == unlisted.id }

        projectStore.currentSearch = results
        for path in Self.outsidePaths {
            let match = try XCTUnwrap(results.matches.first { $0.documentPath == path })
            do {
                try await projectStore.replaceMatch(match, with: "mist")
                XCTFail("\(path): a replace outside a research root must refuse")
            } catch {}
        }
        let outcome = try await projectStore.replaceAll(in: results, with: "mist")

        for item in strays {
            XCTAssertEqual(try String(contentsOf: file(try XCTUnwrap(item.path)), encoding: .utf8), "The fog.")
            XCTAssertTrue(outcome.leftAlone.contains(item.title), "\(outcome.leftAlone)")
        }
        XCTAssertEqual(try String(contentsOf: file("manuscript/unlisted.md"), encoding: .utf8), "The fog.")
        XCTAssertEqual(try String(contentsOf: file("research/loose.md"), encoding: .utf8), "The mist.",
                       "an unlisted file inside research/ keeps its raw write")
    }
}
