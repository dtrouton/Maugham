import XCTest
@testable import Maugham

final class TitlePageParserTests: XCTestCase {
    private let parser = FountainTokenizer()

    func test_documentWithoutTitlePage_titlePageIsNil() {
        let script = parser.parse("INT. KITCHEN - DAY\n\nLarry sits.")
        XCTAssertNil(script.titlePage)
    }

    func test_simpleTitlePage_parsesFields() {
        let text = """
        Title: My Screenplay
        Author: Test Writer

        INT. KITCHEN - DAY
        """
        let script = parser.parse(text)
        XCTAssertNotNil(script.titlePage)
        XCTAssertEqual(script.titlePage?.count, 2)
        XCTAssertEqual(script.titlePage?[0].key, "Title")
        XCTAssertEqual(script.titlePage?[0].value, "My Screenplay")
        XCTAssertEqual(script.titlePage?[1].key, "Author")
        XCTAssertEqual(script.titlePage?[1].value, "Test Writer")
    }

    func test_titlePage_classifiesLinesAsTitlePageElement() {
        let text = """
        Title: My Screenplay
        Author: Test Writer

        INT. KITCHEN - DAY
        """
        let script = parser.parse(text)
        XCTAssertEqual(script.lines[0].element, .titlePage)
        XCTAssertEqual(script.lines[1].element, .titlePage)
    }

    func test_titlePage_recognizesAuthorsKey_normalizedToAuthor() {
        let script = parser.parse("Authors: A and B\n\nINT. ROOM")
        XCTAssertEqual(script.titlePage?[0].key, "Author")
        XCTAssertEqual(script.titlePage?[0].value, "A and B")
    }

    func test_titlePage_recognizesAllStandardKeys() {
        let text = """
        Title: T
        Credit: C
        Author: A
        Source: S
        Notes: N
        Draft date: D
        Contact: K
        Copyright: P

        INT. SCENE
        """
        let script = parser.parse(text)
        XCTAssertEqual(script.titlePage?.count, 8)
    }

    func test_titlePage_unknownKeyStillParsed() {
        let text = """
        Title: T
        Custom Key: Value

        INT. SCENE
        """
        let script = parser.parse(text)
        XCTAssertEqual(script.titlePage?.count, 2)
        XCTAssertEqual(script.titlePage?[1].key, "Custom Key")
    }

    func test_titlePage_caseInsensitiveKey_normalizedToCanonical() {
        let script = parser.parse("title: T\n\nINT. SCENE")
        XCTAssertEqual(script.titlePage?[0].key, "Title")
    }

    func test_titlePage_continuationViaIndent_joinsWithNewline() {
        let text = """
        Notes: First line of notes
            second line indented
            third line indented
        Author: A

        INT. SCENE
        """
        let script = parser.parse(text)
        XCTAssertEqual(script.titlePage?[0].key, "Notes")
        XCTAssertEqual(
            script.titlePage?[0].value,
            "First line of notes\nsecond line indented\nthird line indented")
        XCTAssertEqual(script.titlePage?[1].key, "Author")
    }

    func test_titlePage_closesOnBlankLine() {
        let text = """
        Title: T

        Author: A
        """
        // Blank after Title closes the title page; "Author: A" is parsed as
        // body action (not a title page line).
        let script = parser.parse(text)
        XCTAssertEqual(script.titlePage?.count, 1)
        XCTAssertEqual(script.titlePage?[0].key, "Title")
    }

    func test_titlePage_closesOnNonKeyNonIndentedLine() {
        // INT. KITCHEN doesn't match Key: Value, so title page closes there.
        let text = """
        Title: T
        INT. KITCHEN - DAY
        """
        let script = parser.parse(text)
        XCTAssertEqual(script.titlePage?.count, 1)
        XCTAssertEqual(script.lines[1].element, .sceneHeading)
    }

    func test_documentStartingWithSceneHeading_noTitlePage() {
        // First non-empty line doesn't match Key: Value → no title page.
        let script = parser.parse("INT. KITCHEN - DAY\n\nLarry sits.")
        XCTAssertNil(script.titlePage)
    }

    func test_documentStartingWithUnrecognizedKey_noTitlePage() {
        // Trigger requires a RECOGNIZED key. "Foo: bar" alone doesn't trigger.
        let script = parser.parse("Foo: bar\n\nINT. SCENE")
        XCTAssertNil(script.titlePage)
    }
}
