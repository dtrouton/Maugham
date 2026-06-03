import XCTest
import AppKit
import MaughamCore
@testable import Maugham

/// Cross-surface contract (depth B): the Mac editor must source its per-key
/// title-page treatment from `TitlePageFieldStyle.style(forKey:)`, the single
/// shared decision the iOS reader also consumes. This pins that the Mac's
/// rendered NSFont/paragraph attributes are the faithful translation of the
/// shared style — so the two surfaces can't drift again.
final class TitlePageStyleContractTests: XCTestCase {
    private let mode = ScreenplayMode()

    /// The Mac's production hook returns exactly the shared contract style.
    func test_macHook_returnsSharedContractStyle() {
        for key in ["Title", "Credit", "Author", "Source", "Draft date", "Contact"] {
            XCTAssertEqual(
                ScreenplayMode.titlePageStyle(forKey: key),
                TitlePageFieldStyle.style(forKey: key),
                "Mac must consume the shared contract for \(key)")
        }
    }

    private func style(_ text: String) -> NSTextStorage {
        let storage = NSTextStorage(string: text)
        let tokens = mode.tokenize(text)
        mode.applyTypography(in: storage, theme: .light,
                             typography: .screenplayDefaults, tokens: tokens)
        return storage
    }

    private var baseSize: CGFloat {
        CGFloat(TypographySettings.screenplayDefaults.fontSize)
    }

    /// For each representative key, the rendered attributes reflect the contract:
    /// font size = base * scale, bold/italic traits, alignment, dim color.
    func test_renderedAttributes_matchContract() {
        let cases: [(key: String, prefix: String, doc: String)] = [
            ("Title", "Title: ", "Title: My Screenplay\n\nINT. SCENE"),
            ("Credit", "Title: T\nCredit: ", "Title: T\nCredit: written by\n\nINT. SCENE"),
            ("Author", "Title: T\nAuthor: ", "Title: T\nAuthor: A Writer\n\nINT. SCENE"),
            ("Source", "Title: T\nSource: ", "Title: T\nSource: a novel\n\nINT. SCENE"),
            ("Draft date", "Title: T\nDraft date: ", "Title: T\nDraft date: 2026-05-10\n\nINT. SCENE"),
        ]
        let palette = Theme.light.resolved(systemAppearanceIsDark: false).palette

        for c in cases {
            let expected = TitlePageFieldStyle.style(forKey: c.key)
            let storage = style(c.doc)
            let valueStart = (c.prefix as NSString).length
            let attrs = storage.attributes(at: valueStart, effectiveRange: nil)

            let font = attrs[.font] as? NSFont
            XCTAssertNotNil(font, "\(c.key): font")
            XCTAssertEqual(font!.pointSize, baseSize * CGFloat(expected.scale),
                           accuracy: 0.01, "\(c.key): scale")
            XCTAssertEqual(font!.fontDescriptor.symbolicTraits.contains(.bold),
                           expected.bold, "\(c.key): bold")
            XCTAssertEqual(font!.fontDescriptor.symbolicTraits.contains(.italic),
                           expected.italic, "\(c.key): italic")

            let para = attrs[.paragraphStyle] as? NSParagraphStyle
            let expectedAlign: NSTextAlignment = expected.alignment == .center ? .center : .left
            XCTAssertEqual(para?.alignment, expectedAlign, "\(c.key): alignment")

            // Dim color appears only for dimmed keys (and overrides nothing on
            // the value run for non-dimmed keys — those keep the default fg).
            if expected.dimmed {
                XCTAssertEqual(attrs[.foregroundColor] as? NSColor,
                               palette.syntaxPunctuation, "\(c.key): dim color")
            }
        }
    }
}
