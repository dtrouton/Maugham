import XCTest
@testable import MaughamPhone
import MaughamCore

final class FountainStylerTests: XCTestCase {
    /// Construct a FountainLine directly (public init) for a given element.
    private func line(_ element: ScreenplayElement,
                      content: String = "X",
                      isDualSecond: Bool = false) -> FountainLine {
        FountainLine(
            range: NSRange(location: 0, length: content.utf16.count),
            element: element,
            content: content,
            isForced: false,
            sourceCase: .mixed,
            isDualSecond: isDualSecond
        )
    }

    func test_sceneHeading_boldMonospacedUppercasedTopPadding() {
        let s = FountainStyler.style(for: line(.sceneHeading, content: "INT. ROOM - DAY"))
        XCTAssertEqual(s.weight, .bold)
        XCTAssertTrue(s.monospaced)
        XCTAssertTrue(s.uppercased)
        XCTAssertEqual(s.topPadding, 12)
    }

    func test_action_plainBodyLeadingNoIndent() {
        let s = FountainStyler.style(for: line(.action, content: "He walks in."))
        XCTAssertEqual(s.weight, .regular)
        XCTAssertEqual(s.align, .leading)
        XCTAssertEqual(s.role, .body)
        XCTAssertEqual(s.leadingIndent, 0)
        XCTAssertFalse(s.italic)
        XCTAssertFalse(s.uppercased)
    }

    func test_character_boldCentered() {
        let s = FountainStyler.style(for: line(.character, content: "ALICE"))
        XCTAssertEqual(s.weight, .bold)
        XCTAssertEqual(s.align, .center)
    }

    func test_parenthetical_italicIndented64() {
        let s = FountainStyler.style(for: line(.parenthetical, content: "(softly)"))
        XCTAssertTrue(s.italic)
        XCTAssertEqual(s.leadingIndent, 64)
    }

    func test_dialogue_indented48BothSides() {
        let s = FountainStyler.style(for: line(.dialogue, content: "Hello there."))
        XCTAssertEqual(s.leadingIndent, 48)
        XCTAssertEqual(s.trailingIndent, 48)
    }

    func test_transition_boldTrailingUppercased() {
        let s = FountainStyler.style(for: line(.transition, content: "CUT TO:"))
        XCTAssertEqual(s.weight, .bold)
        XCTAssertEqual(s.align, .trailing)
        XCTAssertTrue(s.uppercased)
    }

    func test_centered_aligned() {
        let s = FountainStyler.style(for: line(.centered, content: "THE END"))
        XCTAssertEqual(s.align, .center)
    }

    func test_lyric_italicIndented48() {
        let s = FountainStyler.style(for: line(.lyric, content: "la la la"))
        XCTAssertTrue(s.italic)
        XCTAssertEqual(s.leadingIndent, 48)
    }

    func test_section_headlineBold() {
        let s = FountainStyler.style(for: line(.section(level: 1), content: "Act One"))
        XCTAssertEqual(s.role, .headline)
        XCTAssertEqual(s.weight, .bold)
    }

    func test_synopsis_calloutItalicDimmed() {
        let s = FountainStyler.style(for: line(.synopsis, content: "Alice arrives."))
        XCTAssertEqual(s.role, .callout)
        XCTAssertTrue(s.italic)
        XCTAssertTrue(s.dimmed)
    }

    func test_note_dimmedNotHidden() {
        let s = FountainStyler.style(for: line(.note, content: "[[fix this]]"))
        XCTAssertTrue(s.dimmed)
        XCTAssertFalse(s.hidden)
    }

    func test_pageBreak_hidden() {
        let s = FountainStyler.style(for: line(.pageBreak, content: "==="))
        XCTAssertTrue(s.hidden)
    }

    func test_boneyard_dimmed() {
        // Choice documented in FountainStyler: boneyard renders dimmed, not hidden.
        let s = FountainStyler.style(for: line(.boneyard, content: "/* cut */"))
        XCTAssertTrue(s.dimmed)
        XCTAssertFalse(s.hidden)
    }

    func test_titlePage_calloutDimmed() {
        let s = FountainStyler.style(for: line(.titlePage, content: "Title: Foo"))
        XCTAssertEqual(s.role, .callout)
        XCTAssertTrue(s.dimmed)
    }

    func test_dualSecond_dialogue_deeperIndent() {
        let base = FountainStyler.style(for: line(.dialogue, content: "Hi."))
        let dual = FountainStyler.style(for: line(.dialogue, content: "Hi.", isDualSecond: true))
        XCTAssertEqual(dual.leadingIndent, base.leadingIndent + 24,
                       "dual-second adds a deeper indent on top of the base")
        XCTAssertEqual(dual.trailingIndent, base.trailingIndent)
    }
}
