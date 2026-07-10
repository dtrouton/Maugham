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

    func test_readPaletteCard_moreThanSixImages_omittedNoteListsExtras() async throws {
        let (url, _, ds, reg, item) = try await makeProjectWithCard()
        // Seven small images → count cap (6) trims the seventh into the note.
        var lines = ["", "## Images", ""]
        for n in 0..<7 {
            try makePNG(width: 200, height: 200)
                .write(to: url.appendingPathComponent("research/img\(n).png"))
            lines.append("- ../img\(n).png")
        }
        let base = try String(contentsOf: url.appendingPathComponent(item.path!), encoding: .utf8)
        try (base + "\n" + lines.joined(separator: "\n") + "\n").data(using: .utf8)!
            .write(to: url.appendingPathComponent(item.path!))
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\",\"card_id\":\"\(item.id)\"}"
        let json = try await ReadPaletteCardTool.handle(paramsJSON: Data(req.utf8), registry: reg)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        let content = try XCTUnwrap(obj["content"] as? [[String: Any]])
        let imageBlocks = content.filter { $0["type"] as? String == "image" }
        XCTAssertEqual(imageBlocks.count, 6, "count cap should thumbnail exactly six")
        let text = try XCTUnwrap((content.first { $0["type"] as? String == "text" })?["text"] as? String)
        XCTAssertTrue(text.contains("not thumbnailed"), "trimmed image must be in the omitted note")
        XCTAssertTrue(text.contains("research/img6.png"), "omitted note must list the trimmed path")
        await ds.close()
    }

    func test_readPaletteCard_largeImages_respectCombinedByteBudget() async throws {
        let (url, _, ds, reg, item) = try await makeProjectWithCard()
        // Six high-entropy images: each 512px thumbnail is ~130–160 KB, so the
        // unbudgeted six would blow past the 1 MB transport cap. The running
        // byte budget must trim them and stay under the cap.
        var lines = ["", "## Images", ""]
        for n in 0..<6 {
            try makeNoisePNG(width: 700, height: 700)
                .write(to: url.appendingPathComponent("research/noise\(n).png"))
            lines.append("- ../noise\(n).png")
        }
        let base = try String(contentsOf: url.appendingPathComponent(item.path!), encoding: .utf8)
        try (base + "\n" + lines.joined(separator: "\n") + "\n").data(using: .utf8)!
            .write(to: url.appendingPathComponent(item.path!))
        let id = ProjectIdentifier.id(for: url)
        let req = "{\"project_id\":\"\(id)\",\"card_id\":\"\(item.id)\"}"
        let json = try await ReadPaletteCardTool.handle(paramsJSON: Data(req.utf8), registry: reg)
        XCTAssertLessThan(json.count, 1_048_576,
            "combined envelope must stay under the 1 MB transport cap")
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        let content = try XCTUnwrap(obj["content"] as? [[String: Any]])
        let rawThumbBytes = content
            .compactMap { $0["data"] as? String }
            .compactMap { Data(base64Encoded: $0) }
            .reduce(0) { $0 + $1.count }
        XCTAssertLessThanOrEqual(rawThumbBytes, 720_000,
            "combined raw thumbnail bytes must respect the running budget")
        await ds.close()
    }

    func test_readPaletteCard_imageNotOnCard_throwsInvalidArgumentListingImages() async throws {
        let (url, _, ds, reg, item) = try await makeProjectWithCard()
        try makePNG(width: 400, height: 400)
            .write(to: url.appendingPathComponent("research/flat.png"))
        let md = try String(contentsOf: url.appendingPathComponent(item.path!), encoding: .utf8)
            + "\n## Images\n\n- ../flat.png\n"
        try md.data(using: .utf8)!.write(to: url.appendingPathComponent(item.path!))
        let id = ProjectIdentifier.id(for: url)
        // A path that exists nowhere on the card — distinct from an unknown card_id.
        let req = "{\"project_id\":\"\(id)\",\"card_id\":\"\(item.id)\",\"image\":\"research/missing.png\"}"
        do {
            _ = try await ReadPaletteCardTool.handle(paramsJSON: Data(req.utf8), registry: reg)
            XCTFail("expected throw for image not on card")
        } catch let MCPError.invalidArgument(message) {
            XCTAssertTrue(message.contains("research/missing.png"), "message should name the bad path")
            XCTAssertTrue(message.contains("research/flat.png"), "message should list the card's images")
        }
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

    /// High-entropy PNG (random RGB, opaque). JPEG-compresses poorly, so its
    /// 512px thumbnail lands ~130–160 KB — used to exercise the running byte
    /// budget across overview thumbnails.
    private func makeNoisePNG(width: Int, height: Int) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        if let data = rep.bitmapData {
            let count = rep.bytesPerRow * height
            for i in 0..<count { data[i] = (i % 4 == 3) ? 255 : UInt8.random(in: 0...255) }
        }
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
