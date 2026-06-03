import XCTest
import SwiftUI
import MaughamCore
@testable import MaughamPhone

/// Cross-surface contract (depth B): the iOS reader must source its per-key
/// title-page treatment from `TitlePageFieldStyle.style(forKey:)`, the same
/// shared decision the Mac editor consumes. SwiftUI `Font` is opaque, so we
/// assert the renderer consumes the shared style for each key and that its
/// font-translation hook is a pure function of that style (distinct keys with
/// distinct styles yield distinct fonts; equal styles yield equal fonts).
final class TitlePageStyleContractTests: XCTestCase {

    /// The renderer's font hook is keyed entirely by the shared style: keys that
    /// map to the same `TitlePageFieldStyle` produce the same `Font`, and the
    /// representative differentiated keys all produce distinct fonts.
    func test_phoneFont_isPureFunctionOfSharedStyle() {
        // "Other" keys share one style → one font.
        let contactFont = FountainSemanticRenderer.titlePageFont(
            for: TitlePageFieldStyle.style(forKey: "Contact"))
        let draftFont = FountainSemanticRenderer.titlePageFont(
            for: TitlePageFieldStyle.style(forKey: "Draft date"))
        let copyrightFont = FountainSemanticRenderer.titlePageFont(
            for: TitlePageFieldStyle.style(forKey: "Copyright"))
        XCTAssertEqual(contactFont, draftFont)
        XCTAssertEqual(contactFont, copyrightFont)

        // The differentiated keys (Title/Credit/Author/Source) carry distinct
        // styles → distinct fonts (Author is the only "plain" one and differs
        // from the dimmed "other" style by alignment/scale).
        let fonts = ["Title", "Credit", "Author", "Source"].map {
            FountainSemanticRenderer.titlePageFont(for: TitlePageFieldStyle.style(forKey: $0))
        }
        for i in fonts.indices {
            for j in (i + 1)..<fonts.count {
                XCTAssertNotEqual(fonts[i], fonts[j],
                                  "differentiated title-page keys must render distinct fonts")
            }
        }
    }

    /// Pin that the reader consumes the canonical contract values for the
    /// representative keys (mirrors the Mac contract test's key set).
    func test_sharedStyleValues_matchContract() {
        XCTAssertEqual(TitlePageFieldStyle.style(forKey: "Title"),
                       TitlePageFieldStyle(scale: 1.5, bold: true, italic: false,
                                           dimmed: false, alignment: .center))
        XCTAssertEqual(TitlePageFieldStyle.style(forKey: "Credit"),
                       TitlePageFieldStyle(scale: 1.0, bold: false, italic: true,
                                           dimmed: false, alignment: .center))
        XCTAssertEqual(TitlePageFieldStyle.style(forKey: "Author"),
                       TitlePageFieldStyle(scale: 1.0, bold: false, italic: false,
                                           dimmed: false, alignment: .center))
        XCTAssertEqual(TitlePageFieldStyle.style(forKey: "Source"),
                       TitlePageFieldStyle(scale: 0.9, bold: false, italic: true,
                                           dimmed: false, alignment: .center))
        XCTAssertEqual(TitlePageFieldStyle.style(forKey: "Draft date"),
                       TitlePageFieldStyle(scale: 0.85, bold: false, italic: false,
                                           dimmed: true, alignment: .leading))
    }
}
