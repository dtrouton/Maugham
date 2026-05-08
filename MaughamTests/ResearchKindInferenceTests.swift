import XCTest
@testable import Maugham

final class ResearchKindInferenceTests: XCTestCase {

    func test_imageExtensions() {
        for ext in ["jpg", "JPEG", "png", "heic", "heif", "gif", "webp", "tiff", "bmp"] {
            XCTAssertEqual(
                ResearchKindInference.kind(forFilename: "x.\(ext)"),
                .image,
                "expected .image for .\(ext)")
        }
    }

    func test_pdfExtension() {
        XCTAssertEqual(ResearchKindInference.kind(forFilename: "x.pdf"), .pdf)
        XCTAssertEqual(ResearchKindInference.kind(forFilename: "x.PDF"), .pdf)
    }

    func test_documentExtensions() {
        for ext in ["txt", "md", "markdown", "rtf"] {
            XCTAssertEqual(
                ResearchKindInference.kind(forFilename: "x.\(ext)"),
                .document)
        }
    }

    func test_audioExtensions() {
        for ext in ["mp3", "m4a", "wav", "aac", "flac", "aiff", "ogg"] {
            XCTAssertEqual(
                ResearchKindInference.kind(forFilename: "x.\(ext)"),
                .audio)
        }
    }

    func test_unknownExtension_returnsNil() {
        XCTAssertNil(ResearchKindInference.kind(forFilename: "x.exe"))
        XCTAssertNil(ResearchKindInference.kind(forFilename: "x.unknown"))
    }

    func test_filenameWithoutExtension_returnsNil() {
        XCTAssertNil(ResearchKindInference.kind(forFilename: "README"))
    }
}
