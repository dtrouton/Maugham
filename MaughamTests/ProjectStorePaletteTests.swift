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

    func test_updatePaletteCard_unknownId_throws() async throws {
        let (_, store, ds) = try await makeNovel()
        let ghost = PaletteCard(researchItemId: "res-ghost", title: "G", kind: .other,
                                swatches: [], notes: [], imagePaths: [], body: "")
        do { try await store.updatePaletteCard(ghost); XCTFail("expected throw") } catch {}
        await ds.close()
    }
}
