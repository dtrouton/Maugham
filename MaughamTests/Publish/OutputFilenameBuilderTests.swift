import XCTest
@testable import Maugham

final class OutputFilenameBuilderTests: XCTestCase {

    private func makeConfig(
        title: String, sanitizeSpaces: Bool = false, nextVersion: String = "0.1"
    ) -> PublishConfig {
        var cfg = PublishConfig(metadata: .init(title: title, author: "T"))
        cfg.outputs.sanitizeSpaces = sanitizeSpaces
        cfg.nextVersion = nextVersion
        return cfg
    }

    // MARK: - happy path

    func testInterpolatesTemplate() {
        let cfg = makeConfig(title: "The Playlist Sessions")
        let name = OutputFilenameBuilder.make(
            config: cfg, format: .pdf, label: nil)
        XCTAssertEqual(name, "The Playlist Sessions-v0.1.pdf")
    }

    func testLabelSuffix() {
        let cfg = makeConfig(title: "Book", nextVersion: "0.3")
        let name = OutputFilenameBuilder.make(
            config: cfg, format: .epub, label: "galley")
        XCTAssertEqual(name, "Book-v0.3-galley.epub")
    }

    // MARK: - sanitize_spaces flag (cosmetic — writer-controlled)

    func testSpaces_preservedWhenFlagFalse() {
        let cfg = makeConfig(title: "A Real Title", sanitizeSpaces: false)
        XCTAssertEqual(
            OutputFilenameBuilder.make(config: cfg, format: .pdf, label: nil),
            "A Real Title-v0.1.pdf")
    }

    func testSpaces_hyphenatedWhenFlagTrue() {
        let cfg = makeConfig(title: "A Real Title", sanitizeSpaces: true)
        XCTAssertEqual(
            OutputFilenameBuilder.make(config: cfg, format: .pdf, label: nil),
            "A-Real-Title-v0.1.pdf")
    }

    // MARK: - always-on safety sanitization (NOT writer-controllable)

    func testSlashes_alwaysStripped() {
        // Slash in title would create a subdirectory path on macOS, not a
        // filename. Strip it regardless of sanitize_spaces.
        for flag in [true, false] {
            let cfg = makeConfig(title: "This/That", sanitizeSpaces: flag)
            let name = OutputFilenameBuilder.make(
                config: cfg, format: .pdf, label: nil)
            XCTAssertFalse(name.contains("/"),
                           "slash leaked through with sanitizeSpaces=\(flag): \(name)")
        }
    }

    func testLeadingDot_alwaysStripped() {
        // A leading dot creates a hidden file on macOS — invisible in
        // Finder. Strip leading dots even when sanitize_spaces is off.
        let cfg = makeConfig(title: ".secret", sanitizeSpaces: false)
        let name = OutputFilenameBuilder.make(
            config: cfg, format: .pdf, label: nil)
        XCTAssertFalse(name.hasPrefix("."),
                       "leading dot leaked: \(name)")
        XCTAssertEqual(name, "secret-v0.1.pdf")
    }

    func testMultipleLeadingDots_allStripped() {
        let cfg = makeConfig(title: "...weird", sanitizeSpaces: false)
        let name = OutputFilenameBuilder.make(
            config: cfg, format: .pdf, label: nil)
        XCTAssertEqual(name, "weird-v0.1.pdf")
    }

    func testNullByte_alwaysStripped() {
        let cfg = makeConfig(title: "Title\u{0000}With Null", sanitizeSpaces: false)
        let name = OutputFilenameBuilder.make(
            config: cfg, format: .pdf, label: nil)
        XCTAssertFalse(name.contains("\u{0000}"),
                       "null byte leaked: \(name.unicodeScalars.map { $0.value })")
    }

    func testControlCharacters_stripped() {
        // Vertical tab + bell — would show as garbage in Finder.
        let cfg = makeConfig(title: "Bell\u{0007}Vt\u{000B}Title", sanitizeSpaces: false)
        let name = OutputFilenameBuilder.make(
            config: cfg, format: .pdf, label: nil)
        XCTAssertEqual(name, "BellVtTitle-v0.1.pdf")
    }

    // MARK: - label sanitization

    func testLabel_alsoSanitized() {
        let cfg = makeConfig(title: "Book")
        // Label with a slash would also break the path.
        let name = OutputFilenameBuilder.make(
            config: cfg, format: .pdf, label: "first/draft")
        XCTAssertFalse(name.contains("/"))
        XCTAssertTrue(name.contains("firstdraft"),
                      "expected sanitized label, got: \(name)")
    }
}
