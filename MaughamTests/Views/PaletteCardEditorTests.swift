import XCTest
import AppKit
@testable import Maugham

final class PaletteCardEditorTests: XCTestCase {
    func test_hexString_fromComponents() {
        XCTAssertEqual(PaletteCardEditor.hexString(r: 1, g: 0, b: 0), "#FF0000")
        XCTAssertEqual(PaletteCardEditor.hexString(r: 0.5411, g: 0.4352, b: 0.3019), "#8A6F4D")
        XCTAssertEqual(PaletteCardEditor.hexString(r: 2, g: -1, b: 0), "#FF0000") // clamped
    }

    func test_hexString_fromNSColor_sRGBConversion() {
        let c = NSColor(calibratedRed: 1, green: 0, blue: 0, alpha: 1)
        XCTAssertNotNil(PaletteCardEditor.hexString(from: c))
        XCTAssertEqual(PaletteCardEditor.hexString(from: NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)), "#00FF00")
    }

    func test_hexString_roundTripsThroughParserValidation() {
        let hex = PaletteCardEditor.hexString(r: 0.2, g: 0.4, b: 0.6)
        XCTAssertNotNil(PaletteCard.color(fromHex: hex))
    }

    // MARK: - Drop classification (shared DropClassification, canonical for all zones)

    func test_dropAction_fileURLWinsOverImage() {
        // A Finder drag carries both a file URL and rendered image data; the file
        // URL wins so the original name/extension is preserved.
        XCTAssertEqual(
            DropClassification.action(hasFileURL: true, canLoadImage: true), .fileURL)
        XCTAssertEqual(
            DropClassification.action(hasFileURL: true, canLoadImage: false), .fileURL)
    }

    func test_dropAction_browserDragFallsToImage() {
        // A browser drag carries no file URL but does carry a rendered bitmap.
        XCTAssertEqual(
            DropClassification.action(hasFileURL: false, canLoadImage: true), .image)
    }

    func test_dropAction_remoteURLOnlyIsIgnored() {
        // No file URL, no loadable image (e.g. a bare remote URL) — never fetched.
        XCTAssertEqual(
            DropClassification.action(hasFileURL: false, canLoadImage: false), .ignore)
    }
}
