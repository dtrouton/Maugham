import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Maugham
import MaughamCore

/// The row thumbnails' one cache (`RowThumbnails`) and the rules for which
/// rows show one — the tree's fold, the tree's research rows, the Inbox.
@MainActor
final class RowThumbnailsTests: XCTestCase {

    // MARK: - The cache

    /// A picture replaced at the same path is a different key, so the row
    /// decodes the new one rather than serving the old.
    func test_theKeyChangesWhenTheFilesModificationDateChanges() throws {
        let root = TestTemp.root
        let url = root.appendingPathComponent("p.png")
        try Self.writePNG(width: 40, height: 20, to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: url.path)
        let before = try XCTUnwrap(RowThumbnails.key(for: url, points: 16))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000_000)], ofItemAtPath: url.path)
        let after = try XCTUnwrap(RowThumbnails.key(for: url, points: 16))
        XCTAssertNotEqual(before, after)
        // Control: an unchanged file keys the same.
        XCTAssertEqual(after, RowThumbnails.key(for: url, points: 16))
    }

    /// …and the cache acts on it: the replaced file decodes again.
    func test_aReplacedPictureDecodesAgain() async throws {
        let root = TestTemp.root
        let url = root.appendingPathComponent("p.png")
        try Self.writePNG(width: 40, height: 20, to: url)
        let cache = RowThumbnails(entryBudget: 8)
        let source = RowThumbnails.Source(path: "p.png", root: root)
        let first = await cache.thumbnail(for: source, points: 16)
        _ = await cache.thumbnail(for: source, points: 16)
        XCTAssertEqual(cache.decodeCount, 1, "an unchanged file is served from the cache")
        XCTAssertGreaterThan(try XCTUnwrap(first).width, try XCTUnwrap(first).height)

        try Self.writePNG(width: 20, height: 40, to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
        let secondImage = await cache.thumbnail(for: source, points: 16)
        let second = try XCTUnwrap(secondImage)
        XCTAssertEqual(cache.decodeCount, 2)
        XCTAssertLessThan(second.width, second.height, "the new picture, not the old")
        XCTAssertEqual(cache.count, 1, "the old picture's entry is dropped")
    }

    func test_aMissingFileYieldsNothing() async {
        let cache = RowThumbnails()
        let source = RowThumbnails.Source(path: "nowhere.png", root: TestTemp.root)
        let image = await cache.thumbnail(for: source, points: 16)
        XCTAssertNil(image)
        XCTAssertEqual(cache.decodeCount, 0, "no file, no decode")
    }

    /// A path that leaves its root is refused before the disk (tripwire 58).
    func test_aPathLeavingItsRootYieldsNothing() async throws {
        let root = TestTemp.root
        let inner = root.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Self.writePNG(width: 10, height: 10, to: root.appendingPathComponent("out.png"))
        let cache = RowThumbnails()
        let image = await cache.thumbnail(
            for: RowThumbnails.Source(path: "../out.png", root: inner), points: 16)
        XCTAssertNil(image)
    }

    func test_aLargePictureYieldsAThumbnailNoLargerThanTheCap() async throws {
        let root = TestTemp.root
        try Self.writePNG(width: 1600, height: 900, to: root.appendingPathComponent("big.png"))
        let cache = RowThumbnails()
        let source = RowThumbnails.Source(path: "big.png", root: root)

        let treeImage = await cache.thumbnail(for: source, points: RowThumbnail.treeSide)
        let tree = try XCTUnwrap(treeImage)
        XCTAssertLessThanOrEqual(max(tree.width, tree.height), RowThumbnails.pixels(for: RowThumbnail.treeSide))
        XCTAssertEqual(RowThumbnails.pixels(for: RowThumbnail.treeSide), 32)

        // Whatever a caller asks for, never past the cap.
        let hugeImage = await cache.thumbnail(for: source, points: 2000)
        let huge = try XCTUnwrap(hugeImage)
        XCTAssertLessThanOrEqual(max(huge.width, huge.height), RowThumbnails.maxPixelSize)
    }

    func test_theBoundEvictsTheLeastRecentlyUsed() async throws {
        let root = TestTemp.root
        for name in ["a", "b", "c"] {
            try Self.writePNG(width: 12, height: 12, to: root.appendingPathComponent("\(name).png"))
        }
        let cache = RowThumbnails(entryBudget: 2)
        func ask(_ name: String) async {
            _ = await cache.thumbnail(for: RowThumbnails.Source(path: "\(name).png", root: root), points: 16)
        }
        await ask("a"); await ask("b"); await ask("c")
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.decodeCount, 3)
        await ask("c")
        XCTAssertEqual(cache.decodeCount, 3, "control: the newest is still held")
        await ask("a")
        XCTAssertEqual(cache.decodeCount, 4, "the oldest was evicted, so it decodes again")
    }

    // MARK: - Which rows show a thumbnail

    func test_aFoldRowShowsAThumbnailForAPictureOnly() {
        let items = CanvasItemIndex.over(research: [
            ResearchItem(id: "res-img", title: "Gorge", type: .asset, kind: .image,
                         path: "research/research_assets/gorge.jpg"),
            ResearchItem(id: "res-pdf", title: "Survey", type: .asset, kind: .pdf,
                         path: "research/research_assets/survey.pdf"),
            ResearchItem(id: "res-note", title: "Note", type: .asset, kind: .document,
                         path: "research/note.md"),
            ResearchItem(id: "res-table", title: "Table", type: .asset, kind: .table,
                         path: "research/t.csv"),
        ])
        func card(_ kind: PinnedReference.Kind) -> PieceFoldEntry {
            .card(PinnedReference(id: "x", kind: kind, title: "x"))
        }
        XCTAssertEqual(PieceFoldIndex.thumbnailPath(for: card(.photo(path: "canvas_assets/p.png")), in: items),
                       "canvas_assets/p.png")
        XCTAssertEqual(PieceFoldIndex.thumbnailPath(for: card(.research(itemId: "res-img")), in: items),
                       "research/research_assets/gorge.jpg")
        XCTAssertNil(PieceFoldIndex.thumbnailPath(for: card(.research(itemId: "res-pdf")), in: items))
        XCTAssertNil(PieceFoldIndex.thumbnailPath(for: card(.research(itemId: "res-note")), in: items))
        XCTAssertNil(PieceFoldIndex.thumbnailPath(for: card(.research(itemId: "res-table")), in: items))
        XCTAssertNil(PieceFoldIndex.thumbnailPath(for: card(.scrap(nodeId: "n1")), in: items))
        XCTAssertNil(PieceFoldIndex.thumbnailPath(
            for: .region(id: "r", title: "R", cards: []), in: items))
        XCTAssertNil(PieceFoldIndex.thumbnailPath(for: .palette(id: "res-img", title: "P"), in: items))
        XCTAssertNil(PieceFoldIndex.thumbnailPath(for: .figure(id: "f", name: "F"), in: items))

        // The index resolves it once, for a region's cards too.
        let index = PieceFoldIndex(
            entries: ["doc": [.region(id: "r", title: "R", cards: [
                PinnedReference(id: "p", kind: .photo(path: "canvas_assets/p.png"), title: "p")])]],
            items: items)
        let inRegion = PieceFoldEntry.card(
            PinnedReference(id: "p", kind: .photo(path: "canvas_assets/p.png"), title: "p"))
        XCTAssertEqual(index.thumbnail(of: inRegion), "canvas_assets/p.png")
    }

    func test_aResearchRowShowsAThumbnailForAnImageOnly() {
        func item(_ kind: ResearchItem.AssetKind?, type: ResearchItem.ItemType = .asset) -> ResearchItem {
            ResearchItem(id: "r", title: "R", type: type, kind: kind, path: "research/r.x")
        }
        XCTAssertEqual(ResearchRow.thumbnailPath(of: item(.image)), "research/r.x")
        for kind: ResearchItem.AssetKind? in [.pdf, .document, .table, .audio, .link, nil] {
            XCTAssertNil(ResearchRow.thumbnailPath(of: item(kind)), "\(String(describing: kind))")
        }
        XCTAssertNil(ResearchRow.thumbnailPath(of: item(.image, type: .group)))
    }

    func test_anInboxRowShowsAThumbnailForAPhotoOnly() {
        let inbox = URL(fileURLWithPath: "/project/.maugham/inbox", isDirectory: true)
        func entry(_ kind: InboxEntry.Kind, file: String?) -> InboxEntry {
            InboxEntry(id: "e", createdAt: Date(), deviceId: "phone", kind: kind,
                       sourceFilename: file)
        }
        let photo = InboxStore.thumbnailSource(for: entry(.image, file: "IMG_1.heic"), inboxDir: inbox)
        XCTAssertEqual(photo?.path, "IMG_1.heic")
        XCTAssertEqual(photo?.root.standardizedFileURL,
                       InboxConvention.assetDir(for: .image, inboxDir: inbox)?.standardizedFileURL)
        XCTAssertNil(InboxStore.thumbnailSource(for: entry(.audio, file: "a.m4a"), inboxDir: inbox))
        XCTAssertNil(InboxStore.thumbnailSource(for: entry(.text, file: nil), inboxDir: inbox))
        XCTAssertNil(InboxStore.thumbnailSource(for: entry(.image, file: nil), inboxDir: inbox))
    }

    // MARK: - Fixtures

    static func writePNG(width: Int, height: Int, to url: URL) throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
