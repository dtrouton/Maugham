import XCTest
@testable import Maugham

final class MarkdownCheckboxTokenizerTests: XCTestCase {

    // MARK: - Scanner basics (existing surface)

    func test_match_emptyCheckbox_returnsOpen() {
        let result = MarkdownCheckboxScanner.match("- [ ] do thing")
        XCTAssertNotNil(result)
        XCTAssertFalse(result!.checked)
        XCTAssertEqual(result!.body, "do thing")
    }

    func test_match_checkedBox_returnsDone() {
        let result = MarkdownCheckboxScanner.match("- [x] done thing")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.checked)
        XCTAssertEqual(result!.body, "done thing")
    }

    func test_match_uppercaseCheckedBox_returnsDone() {
        // GFM treats `[X]` as equivalent to `[x]`; the scanner must too so
        // derivation matches detection (Task 22b).
        let result = MarkdownCheckboxScanner.match("- [X] loud thing")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.checked)
        XCTAssertEqual(result!.body, "loud thing")
    }

    func test_match_indented_alsoMatches() {
        XCTAssertNotNil(MarkdownCheckboxScanner.match("    - [ ] indented"))
    }

    func test_match_notACheckbox_returnsNil() {
        XCTAssertNil(MarkdownCheckboxScanner.match("regular text"))
        XCTAssertNil(MarkdownCheckboxScanner.match("- bullet without box"))
        XCTAssertNil(MarkdownCheckboxScanner.match("- [Y] wrong char"))
    }

    // MARK: - flipBracket

    func test_flipBracket_unchecked_becomesChecked() {
        XCTAssertEqual(
            MarkdownCheckboxScanner.flipBracket(in: "- [ ] foo", atUTF16Offset: 2),
            "- [x] foo")
    }

    func test_flipBracket_checked_becomesUnchecked() {
        XCTAssertEqual(
            MarkdownCheckboxScanner.flipBracket(in: "- [x] foo", atUTF16Offset: 2),
            "- [ ] foo")
    }

    func test_flipBracket_indented() {
        XCTAssertEqual(
            MarkdownCheckboxScanner.flipBracket(in: "    - [ ] foo", atUTF16Offset: 6),
            "    - [x] foo")
    }

    func test_flipBracket_invalidOffset_negative_returnsUnchanged() {
        XCTAssertEqual(
            MarkdownCheckboxScanner.flipBracket(in: "- [ ] foo", atUTF16Offset: -1),
            "- [ ] foo")
    }

    func test_flipBracket_invalidOffset_pastEnd_returnsUnchanged() {
        XCTAssertEqual(
            MarkdownCheckboxScanner.flipBracket(in: "- [ ] foo", atUTF16Offset: 100),
            "- [ ] foo")
    }

    func test_flipBracket_offsetNotOnBracket_returnsUnchanged() {
        // Offset 0 is "-", not "[".
        XCTAssertEqual(
            MarkdownCheckboxScanner.flipBracket(in: "- [ ] foo", atUTF16Offset: 0),
            "- [ ] foo")
        // Offset 6 lands on " foo" not on a bracket.
        XCTAssertEqual(
            MarkdownCheckboxScanner.flipBracket(in: "- [ ] foo", atUTF16Offset: 5),
            "- [ ] foo")
    }

    func test_flipBracket_uppercaseChecked_becomesUnchecked() {
        // Clicking an uppercase `[X]` must clear it (Task 22b) — otherwise
        // the box paints/derives as checked but can't be toggled off.
        XCTAssertEqual(
            MarkdownCheckboxScanner.flipBracket(in: "- [X] foo", atUTF16Offset: 2),
            "- [ ] foo")
    }

    // MARK: - Tokenizer emission

    func test_tokenizer_emitsCheckboxToken_forOpenBox() {
        let tokens = MarkdownTokenizer().tokenize("- [ ] thing")
        let checkboxTokens = tokens.filter { token in
            if case .checkbox = token.kind { return true }
            return false
        }
        XCTAssertEqual(checkboxTokens.count, 1)
        guard let cb = checkboxTokens.first else { return }
        XCTAssertEqual(cb.range, NSRange(location: 2, length: 3))
        if case .checkbox(let checked) = cb.kind {
            XCTAssertFalse(checked)
        } else {
            XCTFail("expected checkbox kind")
        }
    }

    func test_tokenizer_emitsCheckboxToken_forCheckedBox() {
        let tokens = MarkdownTokenizer().tokenize("- [x] thing")
        guard let cb = tokens.first(where: {
            if case .checkbox = $0.kind { return true }; return false
        }) else {
            XCTFail("no checkbox token")
            return
        }
        if case .checkbox(let checked) = cb.kind {
            XCTAssertTrue(checked)
        } else {
            XCTFail("expected checkbox kind")
        }
    }

    func test_tokenizer_emitsCheckboxToken_forUppercaseCheckedBox() {
        // Editor paint/hit-test path must recognize `[X]` too (Task 22b).
        let tokens = MarkdownTokenizer().tokenize("- [X] thing")
        guard let cb = tokens.first(where: {
            if case .checkbox = $0.kind { return true }; return false
        }) else {
            XCTFail("no checkbox token for uppercase box")
            return
        }
        if case .checkbox(let checked) = cb.kind {
            XCTAssertTrue(checked, "capital X reads as checked")
        } else {
            XCTFail("expected checkbox kind")
        }
    }

    func test_tokenizer_doesNotEmitCheckbox_forPlainBullet() {
        let tokens = MarkdownTokenizer().tokenize("- not a checkbox")
        let any = tokens.contains { token in
            if case .checkbox = token.kind { return true }
            return false
        }
        XCTAssertFalse(any)
    }
}
