import XCTest
@testable import Maugham
import MaughamCore
import AppKit

@MainActor
final class PaletteToolsTests: XCTestCase {
    private var temp: TempDirectory!

    override func setUp() async throws { temp = try TempDirectory() }
    override func tearDown() async throws { temp = nil }

    func makeProjectWithCard() async throws -> (URL, ProjectStore, DocumentStore, ProjectRegistry, ResearchItem) {
        let url = try await ProjectFactory.createNovelProject(named: "PaletteMCP", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        let item = try await store.addPaletteCard(title: "The Flat", kind: .location)
        try """
        # The Flat

        kind: location

        ## Swatches

        - #8A6F4D

        ## Senses

        - smell: turpentine
        - sound: tram-rattle
        """.data(using: .utf8)!.write(to: url.appendingPathComponent(item.path!))
        let reg = ProjectRegistry()
        reg.register(url: url, store: store)
        return (url, store, ds, reg, item)
    }

    func test_listPaletteCards_returnsSummaries() async throws {
        let (url, _, ds, reg, item) = try await makeProjectWithCard()
        let id = ProjectIdentifier.id(for: url)
        let json = try await ListPaletteCardsTool.handle(
            paramsJSON: Data("{\"project_id\":\"\(id)\"}".utf8), registry: reg)
        let result = try JSONDecoder().decode(ListPaletteCardsTool.Result.self, from: json)
        XCTAssertEqual(result.cards.count, 1)
        let card = try XCTUnwrap(result.cards.first)
        XCTAssertEqual(card.id, item.id)
        XCTAssertEqual(card.title, "The Flat")
        XCTAssertEqual(card.kind, "location")
        XCTAssertEqual(card.swatches, ["#8A6F4D"])
        XCTAssertEqual(card.note_count, 2)
        XCTAssertTrue(card.image_paths.isEmpty)
        await ds.close()
    }

    func test_readPaletteCard_textOnly_returnsContentEnvelopeWithMarkdown() async throws {
        let (url, _, ds, reg, item) = try await makeProjectWithCard()
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\",\"card_id\":\"\(item.id)\"}"
        let json = try await ReadPaletteCardTool.handle(
            paramsJSON: Data(req.utf8), registry: reg)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        let content = try XCTUnwrap(obj["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1)   // no images on this card → text block only
        XCTAssertEqual(content[0]["type"] as? String, "text")
        let text = try XCTUnwrap(content[0]["text"] as? String)
        XCTAssertTrue(text.contains("turpentine"))
        await ds.close()
    }

    func test_readPaletteCard_withImages_appendsThumbnailBlocks() async throws {
        let (url, store, ds, reg, item) = try await makeProjectWithCard()
        // Write a real image into research/ and reference it from the card.
        let imageURL = url.appendingPathComponent("research/flat.png")
        try makePNG(width: 900, height: 600).write(to: imageURL)
        let md = try String(contentsOf: url.appendingPathComponent(item.path!), encoding: .utf8)
            + "\n## Images\n\n- ../flat.png\n"
        try md.data(using: .utf8)!.write(to: url.appendingPathComponent(item.path!))
        _ = store  // silence unused warning
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\",\"card_id\":\"\(item.id)\"}"
        let json = try await ReadPaletteCardTool.handle(paramsJSON: Data(req.utf8), registry: reg)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        let content = try XCTUnwrap(obj["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["type"] as? String, "text")
        XCTAssertEqual(content[1]["type"] as? String, "image")
        XCTAssertEqual(content[1]["mimeType"] as? String, "image/jpeg")
        XCTAssertNotNil(content[1]["data"] as? String)
        await ds.close()
    }

    func test_readPaletteCard_singleImage_usesCropOnDemandEnvelope() async throws {
        let (url, _, ds, reg, item) = try await makeProjectWithCard()
        let imageURL = url.appendingPathComponent("research/flat.png")
        try makePNG(width: 900, height: 600).write(to: imageURL)
        let md = try String(contentsOf: url.appendingPathComponent(item.path!), encoding: .utf8)
            + "\n## Images\n\n- ../flat.png\n"
        try md.data(using: .utf8)!.write(to: url.appendingPathComponent(item.path!))
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\",\"card_id\":\"\(item.id)\",\"image\":\"research/flat.png\"}"
        let json = try await ReadPaletteCardTool.handle(paramsJSON: Data(req.utf8), registry: reg)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        let content = try XCTUnwrap(obj["content"] as? [[String: Any]])
        XCTAssertEqual(content.last?["type"] as? String, "image")
        await ds.close()
    }

    func test_readPaletteCard_unknownCard_throwsInvalidArgument() async throws {
        let (url, _, ds, reg, _) = try await makeProjectWithCard()
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\",\"card_id\":\"res-nope\"}"
        do {
            _ = try await ReadPaletteCardTool.handle(paramsJSON: Data(req.utf8), registry: reg)
            XCTFail("expected throw")
        } catch let MCPError.toolError(payload) {
            XCTAssertEqual(payload.error, "invalid_argument")
        } catch MCPError.invalidArgument {
            // acceptable — MCPToolsCallHandler maps this to invalid_argument
        }
        await ds.close()
    }

    /// Solid-color PNG fixture (no bundled assets needed). Mirrors
    /// `DocumentToolsTests.makeSolidPNG`'s NSBitmapImageRep approach (avoiding
    /// the flakier lockFocus path); that helper is private to another class.
    private func makePNG(width: Int, height: Int) throws -> Data {
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

    func test_listPaletteCards_emptyProject_returnsEmpty() async throws {
        let url = try await ProjectFactory.createNovelProject(named: "Empty", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        let reg = ProjectRegistry()
        reg.register(url: url, store: store)
        let json = try await ListPaletteCardsTool.handle(
            paramsJSON: Data("{\"project_id\":\"\(ProjectIdentifier.id(for: url))\"}".utf8),
            registry: reg)
        let result = try JSONDecoder().decode(ListPaletteCardsTool.Result.self, from: json)
        XCTAssertTrue(result.cards.isEmpty)
        await ds.close()
    }
}
