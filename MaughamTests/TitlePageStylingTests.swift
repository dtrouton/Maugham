import XCTest
import AppKit
@testable import Maugham

final class TitlePageStylingTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()   // absorbs the parallel-worker fontd cold-start window — see FontWarmup.swift
    }

    private let mode = ScreenplayMode()

    private func style(_ text: String) -> NSTextStorage {
        let storage = NSTextStorage(string: text)
        let tokens = mode.tokenize(text)
        mode.applyTypography(in: storage, theme: .light,
                             typography: .screenplayDefaults, tokens: tokens)
        return storage
    }

    func test_titleField_isBoldCentered() {
        let storage = style("Title: My Screenplay\n\nINT. SCENE")
        // The "My Screenplay" value text should be bold.
        let valueStart = ("Title: " as NSString).length
        let attrs = storage.attributes(at: valueStart, effectiveRange: nil)
        let font = attrs[.font] as? NSFont
        XCTAssertNotNil(font)
        XCTAssertTrue(font!.fontDescriptor.symbolicTraits.contains(.bold))
        let paragraph = attrs[.paragraphStyle] as? NSParagraphStyle
        XCTAssertEqual(paragraph?.alignment, .center)
    }

    func test_titleKey_isFaded() {
        let storage = style("Title: My Screenplay\n\nINT. SCENE")
        // The "Title:" key text should be in syntaxPunctuation color (faded).
        let attrs = storage.attributes(at: 0, effectiveRange: nil)
        let palette = Theme.light.resolved(systemAppearanceIsDark: false).palette
        XCTAssertEqual(attrs[.foregroundColor] as? NSColor, palette.syntaxPunctuation)
    }

    func test_authorField_isCentered_notBold() {
        let storage = style("Title: T\nAuthor: Test Writer\n\nINT. SCENE")
        let authorValueStart = ("Title: T\nAuthor: " as NSString).length
        let attrs = storage.attributes(at: authorValueStart, effectiveRange: nil)
        let paragraph = attrs[.paragraphStyle] as? NSParagraphStyle
        XCTAssertEqual(paragraph?.alignment, .center)
        let font = attrs[.font] as? NSFont
        XCTAssertNotNil(font)
        XCTAssertFalse(font!.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func test_draftDateField_isLeftAligned_andDim() {
        let storage = style("Title: T\nDraft date: 2026-05-10\n\nINT. SCENE")
        let dateStart = ("Title: T\nDraft date: " as NSString).length
        let attrs = storage.attributes(at: dateStart, effectiveRange: nil)
        let paragraph = attrs[.paragraphStyle] as? NSParagraphStyle
        XCTAssertEqual(paragraph?.alignment, .left)
        let palette = Theme.light.resolved(systemAppearanceIsDark: false).palette
        XCTAssertEqual(attrs[.foregroundColor] as? NSColor, palette.syntaxPunctuation)
    }

    func test_documentWithoutTitlePage_bodyStylesUnchanged() {
        let storage = style("INT. KITCHEN - DAY\n\nLarry sits.")
        // First line is sceneHeading — should be bold left-aligned.
        let attrs = storage.attributes(at: 0, effectiveRange: nil)
        let font = attrs[.font] as? NSFont
        XCTAssertTrue(font!.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func test_firstBodyLineAfterTitlePage_hasExtraParagraphSpacing() {
        let storage = style("Title: My Script\n\nINT. KITCHEN - DAY")
        // Find the location of "INT. KITCHEN - DAY".
        let bodyStart = (("Title: My Script\n\n") as NSString).length
        let attrs = storage.attributes(at: bodyStart, effectiveRange: nil)
        let para = attrs[.paragraphStyle] as? NSParagraphStyle
        XCTAssertNotNil(para)
        XCTAssertGreaterThan(para?.paragraphSpacingBefore ?? 0, 10)
    }

    func test_firstBodyLineWithoutTitlePage_hasNoExtraSpacing() {
        let storage = style("INT. KITCHEN - DAY\n\nLarry sits.")
        let attrs = storage.attributes(at: 0, effectiveRange: nil)
        let para = attrs[.paragraphStyle] as? NSParagraphStyle
        XCTAssertEqual(para?.paragraphSpacingBefore ?? 0, 0, accuracy: 0.5)
    }
}
