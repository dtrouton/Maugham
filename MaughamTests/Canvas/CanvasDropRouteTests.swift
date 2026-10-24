import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import Maugham

/// **A PNG dragged from the Finder slid back to the Finder, and a browser image
/// with it** (spec §4). The canvas mounted two drop modifiers, and SwiftUI
/// gives each its own AppKit view registered for every type; AppKit hands a
/// drag to the frontmost one only, which was the String destination. It
/// answered a Finder file "no operation" at hover, so nothing fired, and took
/// a browser image by its page-URL text, which `handleDrop` refused as an
/// unknown id. Now one provider `.onDrop` takes every drag and
/// `CanvasDropRoute` sends it by type: a file or an image always wins over
/// text.
///
/// What a Finder file drag carries is recorded here, both the ways a test can
/// build one, so the route is asked over type lists the system really sends.
@MainActor
final class CanvasDropRouteTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = TestTemp.root
            .appendingPathComponent("canvas-drop-route-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func writePNG() throws -> URL {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let url = root.appendingPathComponent("falls.png")
        try data.write(to: url)
        return url
    }

    private static func conformsToText(_ id: String) -> Bool {
        guard let type = UTType(id) else { return false }
        return type.conforms(to: .utf8PlainText) || type.conforms(to: .plainText)
    }

    // MARK: - What a Finder file drag carries

    func test_aFinderFileDragCarriesTheseTypes() throws {
        let png = try writePNG()

        // (a) The provider a file drag is built as.
        let provider = try XCTUnwrap(NSItemProvider(contentsOf: png))
        let providerTypes = provider.registeredTypeIdentifiers
        XCTAssertEqual(Set(providerTypes),
                       ["public.png", "public.file-url", "public.url"],
                       "recorded 2026-10-24 on macOS 27: \(providerTypes)")
        XCTAssertEqual(providerTypes.filter(Self.conformsToText), [],
                       "nothing a String destination imports: \(providerTypes)")

        // (b) What the Finder writes to the drag pasteboard.
        let board = NSPasteboard(name: .init("test-\(UUID())"))
        defer { board.releaseGlobally() }
        board.clearContents()
        XCTAssertTrue(board.writeObjects([png as NSURL]))
        let itemTypes = (board.pasteboardItems ?? []).map { $0.types.map(\.rawValue) }
        XCTAssertEqual(itemTypes, [["public.file-url"]],
                       "recorded 2026-10-24 on macOS 27: \(itemTypes)")
        XCTAssertEqual(itemTypes.flatMap { $0.filter(Self.conformsToText) }, [],
                       "nothing a String destination imports: \(itemTypes)")
    }

    // MARK: - The route

    func test_aFinderPNGRoutesExternal() {
        // As built by the Finder (Step 1's census), and as SwiftUI hands the
        // one `.onDrop` its provider (`public.png` alone).
        XCTAssertEqual(CanvasDropRoute.route(
            typeIdentifiers: ["public.png", "public.file-url", "public.url"]), .external)
        XCTAssertEqual(CanvasDropRoute.route(typeIdentifiers: ["public.file-url"]), .external)
        XCTAssertEqual(CanvasDropRoute.route(typeIdentifiers: ["public.png"]), .external)
    }

    func test_aResearchRowRoutesInternal() {
        XCTAssertEqual(CanvasDropRoute.route(
            typeIdentifiers: [UTType.utf8PlainText.identifier]), .internalPayload)
        XCTAssertEqual(CanvasDropRoute.route(
            typeIdentifiers: [UTType.plainText.identifier]), .internalPayload)
    }

    /// The probe's browser drag: its text is the PAGE's URL, which is no id
    /// this canvas knows, so text must not win while an image is there.
    func test_aBrowserImageRoutesExternal() {
        XCTAssertEqual(CanvasDropRoute.route(typeIdentifiers: [
            UTType.png.identifier, UTType.url.identifier, UTType.utf8PlainText.identifier,
        ]), .external)
        XCTAssertEqual(CanvasDropRoute.route(typeIdentifiers: [
            UTType.utf8PlainText.identifier, UTType.jpeg.identifier,
        ]), .external, "order does not matter: an image wins wherever it sits")
        XCTAssertEqual(CanvasDropRoute.route(typeIdentifiers: [
            UTType.utf8PlainText.identifier, UTType.url.identifier,
        ]), .external, "a URL is never an id: the external route declines it")
    }

    func test_nothingUsableIsRefused() {
        XCTAssertEqual(CanvasDropRoute.route(typeIdentifiers: []), .refuse)
        XCTAssertEqual(CanvasDropRoute.route(typeIdentifiers: ["com.adobe.pdf"]), .refuse)
        XCTAssertEqual(CanvasDropRoute.route(typeIdentifiers: ["not a type"]), .refuse)
    }

    func test_theAcceptedTypesAreFileImageAndText() {
        XCTAssertEqual(CanvasDropRoute.acceptedTypes, [.fileURL, .image, .utf8PlainText])
    }
}
