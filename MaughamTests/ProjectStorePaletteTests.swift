import XCTest
import AppKit
@testable import Maugham
import MaughamCore

@MainActor
final class ProjectStorePaletteTests: XCTestCase {
    private var temp: TempDirectory!

    override func setUp() async throws { temp = try TempDirectory() }
    override func tearDown() async throws { temp = nil }

    private func makeNovel() async throws -> (URL, ProjectStore, DocumentStore) {
        let url = try await ProjectFactory.createNovelProject(named: "PaletteTest", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        return (url, store, ds)
    }

    /// Solid-color PNG fixture (no bundled assets). Mirrors
    /// `PaletteToolsTests.makePNG`'s NSBitmapImageRep approach — avoids the
    /// flakier lockFocus path and gives an NSImage with a real representation
    /// (a bare `NSImage(size:)` has no reps and `tiffRepresentation` returns
    /// nil, which `ImagePasteHandler` rejects as an encoding failure).
    private func makePNGData(width: Int, height: Int) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    func test_ensurePaletteGroup_createsFolderAndManifestGroup_once() async throws {
        let (url, store, ds) = try await makeNovel()
        XCTAssertNil(store.paletteGroup())
        let group = try await store.ensurePaletteGroup()
        XCTAssertEqual(group.type, .group)
        XCTAssertEqual(group.path, ProjectStore.paletteFolderPath)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(ProjectStore.paletteFolderPath).path))
        let again = try await store.ensurePaletteGroup()
        XCTAssertEqual(again.id, group.id)   // idempotent — no duplicate group
        await ds.close()
    }

    func test_addPaletteCard_writesTemplateAndManifestEntry() async throws {
        let (url, store, ds) = try await makeNovel()
        let item = try await store.addPaletteCard(title: "The Flat", kind: .location)
        XCTAssertEqual(item.kind, .document)
        XCTAssertTrue(item.path?.hasPrefix("research/palette/") ?? false)
        let fileURL = url.appendingPathComponent(item.path ?? "")
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        let card = PaletteCardParser.parse(
            markdown: contents, itemId: item.id, fallbackTitle: "x",
            cardDirectory: ProjectStore.paletteFolderPath)
        XCTAssertEqual(card.title, "The Flat")
        XCTAssertEqual(card.kind, .location)
        await ds.close()
    }

    func test_loadPaletteCards_returnsParsedCardsInManifestOrder() async throws {
        let (_, store, ds) = try await makeNovel()
        _ = try await store.addPaletteCard(title: "The Flat", kind: .location)
        _ = try await store.addPaletteCard(title: "Marlowe", kind: .character)
        let cards = store.loadPaletteCards()
        XCTAssertEqual(cards.map(\.title), ["The Flat", "Marlowe"])
        XCTAssertEqual(cards.map(\.kind), [.location, .character])
        XCTAssertEqual(store.paletteCardItems().count, 2)
        await ds.close()
    }

    func test_loadPaletteCards_emptyWithoutGroup() async throws {
        let (_, store, ds) = try await makeNovel()
        XCTAssertTrue(store.loadPaletteCards().isEmpty)
        XCTAssertTrue(store.paletteCardItems().isEmpty)
        await ds.close()
    }

    func test_updatePaletteCard_regeneratesCanonicalFile() async throws {
        let (url, store, ds) = try await makeNovel()
        let item = try await store.addPaletteCard(title: "The Flat", kind: .location)
        var card = store.loadPaletteCards()[0]
        card = PaletteCard(researchItemId: card.researchItemId, title: card.title,
                           kind: .location, swatches: ["#8A6F4D"],
                           notes: [.init(sense: .smell, text: "turpentine")],
                           imagePaths: [], body: "Walk-up.")
        try await store.updatePaletteCard(card)
        let reloaded = store.loadPaletteCards()[0]
        XCTAssertEqual(reloaded, card)
        let onDisk = try String(contentsOf: url.appendingPathComponent(item.path!), encoding: .utf8)
        XCTAssertTrue(onDisk.contains("- smell: turpentine"))
        await ds.close()
    }

    func test_updatePaletteCard_titleRename_movesFileAndAssets() async throws {
        let (url, store, ds) = try await makeNovel()
        _ = try await store.addPaletteCard(title: "Old Name", kind: .character)
        var card = store.loadPaletteCards()[0]
        // seed an asset image first, so the rename must carry it
        let png = try makePNGData(width: 40, height: 40)
        let tmp = url.appendingPathComponent("tmp.png"); try png.write(to: tmp)
        card = try await store.addImage(toPaletteCard: card.researchItemId, fileURL: tmp)
        XCTAssertTrue(card.imagePaths[0].contains("old-name_assets/"))

        let renamed = PaletteCard(researchItemId: card.researchItemId, title: "New Name",
                                  kind: card.kind, swatches: card.swatches,
                                  notes: card.notes, imagePaths: card.imagePaths, body: card.body)
        try await store.updatePaletteCard(renamed)
        let reloaded = store.loadPaletteCards()[0]
        XCTAssertEqual(reloaded.title, "New Name")
        XCTAssertTrue(reloaded.imagePaths[0].contains("new-name_assets/"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(reloaded.imagePaths[0]).path))
        await ds.close()
    }

    func test_addImage_nsimage_landsInAssetsAndModel() async throws {
        let (url, store, ds) = try await makeNovel()
        _ = try await store.addPaletteCard(title: "Pics", kind: .motif)
        let cardId = store.loadPaletteCards()[0].researchItemId
        let image = try XCTUnwrap(NSImage(data: makePNGData(width: 30, height: 30)))
        let card = try await store.addImage(toPaletteCard: cardId, image: image)
        XCTAssertEqual(card.imagePaths.count, 1)
        XCTAssertTrue(card.imagePaths[0].hasPrefix("research/palette/pics_assets/"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(card.imagePaths[0]).path))
        XCTAssertEqual(store.loadPaletteCards()[0], card)   // persisted
        await ds.close()
    }

    /// **A text file dropped on a card's image well is refused, and the writer
    /// is told which file and why** (M1A Task 12).
    ///
    /// This surface had no check at all: `PaletteCardEditor.handleDrop` reached
    /// the shared saver through `try?`, and the saver took `pathExtension` as
    /// given — so a `.txt` was copied into `<slug>_assets/`, appended to
    /// `imagePaths`, and drawn as a grey photo placeholder the writer could
    /// neither fix nor explain. Refusing at the saver is only half of it; a
    /// refusal that reaches a `try?` is the same silence one layer down, which
    /// is why the sentence is asserted here rather than only the throw.
    ///
    /// **Control, in the same test:** a real PNG through the same call still
    /// lands on the card, and produces no message.
    func test_aTextFileDroppedOnAPaletteCardIsRefusedAndSaysSo() async throws {
        let (url, store, ds) = try await makeNovel()
        _ = try await store.addPaletteCard(title: "Pics", kind: .motif)
        let cardId = store.loadPaletteCards()[0].researchItemId
        let notes = url.appendingPathComponent("notes.txt")
        try Data("not a picture".utf8).write(to: notes)

        var refusal: Error?
        do { _ = try await store.addImage(toPaletteCard: cardId, fileURL: notes) }
        catch { refusal = error }

        let error = try XCTUnwrap(refusal, "a text file is not an image")
        let sentence = ImagePasteHandler.failureMessage(for: error)
        XCTAssertTrue(sentence.contains("notes.txt"),
                      "the sentence NAMES the file: \(sentence)")
        XCTAssertTrue(store.loadPaletteCards()[0].imagePaths.isEmpty,
                      "nothing was appended to the card")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: url.appendingPathComponent(
                    "research/palette/pics_assets").path),
            "nothing was ingested, so the well was never even made")

        // Control.
        let png = url.appendingPathComponent("real.png")
        try makePNGData(width: 20, height: 20).write(to: png)
        let card = try await store.addImage(toPaletteCard: cardId, fileURL: png)
        XCTAssertEqual(card.imagePaths.count, 1, "a real picture still lands")
        await ds.close()
    }

    /// Control for the sentence above: **every** failure says something (a
    /// silent one is the defect this task fixed), and it blames the writer's
    /// file only when the writer's file is what is wrong.
    ///
    /// The second half is the one worth having, and it is what falsifies a
    /// `error.localizedDescription` passthrough: on an error that is not ours
    /// that reads *"The operation couldn’t be completed. (… error 1.)"*, which
    /// is a stack trace shown to a writer who dropped a picture.
    func test_theSentenceBlamesTheFileOnlyWhenTheFileIsToBlame() {
        struct DiskWentAway: Error {}

        XCTAssertTrue(
            ImagePasteHandler.failureMessage(
                for: ImagePasteHandler.ImagePasteError.notAnImage(filename: "notes.txt"))
                .contains("notes.txt"))

        let generic = ImagePasteHandler.failureMessage(for: DiskWentAway())
        XCTAssertFalse(generic.isEmpty, "a failure that says nothing is the defect")
        XCTAssertFalse(generic.contains("DiskWentAway"),
                       "an error's own description names a Swift type: \(generic)")
        XCTAssertFalse(generic.lowercased().contains("operation"),
                       "…and reads as a crash report: \(generic)")
        XCTAssertEqual(generic,
                       ImagePasteHandler.failureMessage(
                        for: ImagePasteHandler.ImagePasteError.encodingFailed),
                       "everything that is not the writer's file gets the one "
                       + "sentence, so there is no second spelling to drift")
    }

    func test_updatePaletteCard_unknownId_throws() async throws {
        let (_, store, ds) = try await makeNovel()
        let ghost = PaletteCard(researchItemId: "res-ghost", title: "G", kind: .other,
                                swatches: [], notes: [], imagePaths: [], body: "")
        do { try await store.updatePaletteCard(ghost); XCTFail("expected throw") } catch {}
        await ds.close()
    }

    // MARK: - Role-first identity (rename survival + lazy healing)

    func test_paletteGroup_survivesRename_andStampsLegacy() async throws {
        let (_, store, ds) = try await makeNovel()
        let group = try await store.ensurePaletteGroup()
        XCTAssertEqual(group.role, .paletteGroup)          // stamped at creation
        _ = try await store.addPaletteCard(title: "The Flat", kind: .location)
        try await store.updateResearchItem(id: group.id, title: "Moods")
        XCTAssertEqual(store.paletteGroup()?.id, group.id) // role survives rename
        XCTAssertEqual(store.loadPaletteCards().count, 1)  // wall still finds cards
        let again = try await store.ensurePaletteGroup()
        XCTAssertEqual(again.id, group.id)                 // no duplicate group minted
        await ds.close()
    }

    func test_legacyPaletteGroup_getsLazilyStamped() async throws {
        let (_, store, ds) = try await makeNovel()
        // Simulate a v0.19.0 project: group exists with path identity, no role.
        let legacy = try await store.addResearchItem(parentId: nil, title: "Palette", kind: nil)
        XCTAssertNil(legacy.role)
        let found = store.paletteGroup()
        XCTAssertEqual(found?.id, legacy.id)
        // Allow the deferred stamp to land, then verify persisted.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(TreeWalk.find(id: legacy.id, in: store.manifest.research)?.role, .paletteGroup)
        await ds.close()
    }

    /// S1: a LEGACY project (palette group by path, role == nil) whose group is
    /// renamed away from `research/palette` BEFORE the palette wall is ever
    /// opened must still resolve — the eager heal at load stamps the role first.
    func test_eagerHeal_stampsLegacyPaletteRoleAtLoad_survivingPreOpenRename() async throws {
        let (url, store, ds) = try await makeNovel()
        // Simulate a v0.19.0 project: group exists by path identity, no role.
        let legacy = try await store.addResearchItem(parentId: nil, title: "Palette", kind: nil)
        XCTAssertEqual(legacy.path, ProjectStore.paletteFolderPath)
        XCTAssertNil(legacy.role)
        await ds.close()

        // Reload: the eager heal (awaited inside `load`) stamps the role BEFORE
        // any lookup or rename is reachable — no sleep needed.
        let reloaded = try await ProjectStore.load(from: url)
        XCTAssertEqual(
            TreeWalk.find(id: legacy.id, in: reloaded.manifest.research)?.role, .paletteGroup,
            "eager heal stamps the legacy palette group's role at load")

        // A rename away from research/palette (the fragile pre-role path) still
        // resolves via the now-durable role, and mints no duplicate group.
        let ds2 = try await DocumentStore.open(url: url)
        reloaded.documentStore = ds2
        try await reloaded.updateResearchItem(id: legacy.id, title: "Moods")
        XCTAssertEqual(reloaded.paletteGroup()?.id, legacy.id)
        let ensured = try await reloaded.ensurePaletteGroup()
        XCTAssertEqual(ensured.id, legacy.id, "no duplicate group after a post-load rename")
        await ds2.close()
    }

    func test_paletteGroupDisplayTitle_reflectsLiveTitle() async throws {
        let (_, store, ds) = try await makeNovel()
        XCTAssertEqual(store.paletteGroupDisplayTitle, ProjectStore.paletteGroupTitle)
        let group = try await store.ensurePaletteGroup()
        XCTAssertEqual(store.paletteGroupDisplayTitle, "Palette")
        try await store.updateResearchItem(id: group.id, title: "Moods")
        XCTAssertEqual(store.paletteGroupDisplayTitle, "Moods")
        await ds.close()
    }
}
