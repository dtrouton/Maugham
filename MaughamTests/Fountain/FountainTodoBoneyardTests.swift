import XCTest
@testable import Maugham

/// Tests for the Fountain `[[todo: ...]]` / `[[done: ...]]` boneyard
/// discriminator added in Task 6. Covers:
/// - `FountainBoneyardScanner.flipTodoDone` (pure helper).
/// - `FountainBoneyardScanner.matchTodo` / `matchTodoAll` range-bearing
///   scanners used by `ScreenplayMode.tokenize` to emit `.checkbox` tokens.
/// - `ScreenplayMode.tokenize` checkbox-token emission over the 5-char
///   `todo:`/`done:` prefix range.
/// - Painted `MaughamCheckboxAttr` survives a full `applyTypography` re-run.
final class FountainTodoBoneyardTests: XCTestCase {

    // MARK: - flipTodoDone

    func test_flipTodoDone_todoBecomesDone() {
        XCTAssertEqual(
            FountainBoneyardScanner.flipTodoDone(
                in: "[[todo: write outline]]", atUTF16Offset: 2),
            "[[done: write outline]]")
    }

    func test_flipTodoDone_doneBecomesTodo() {
        XCTAssertEqual(
            FountainBoneyardScanner.flipTodoDone(
                in: "[[done: write outline]]", atUTF16Offset: 2),
            "[[todo: write outline]]")
    }

    func test_flipTodoDone_indented() {
        // Leading whitespace shifts the prefix location.
        XCTAssertEqual(
            FountainBoneyardScanner.flipTodoDone(
                in: "    [[todo: indented]]", atUTF16Offset: 6),
            "    [[done: indented]]")
    }

    func test_flipTodoDone_multipleOnLine_flipsOnlyTargeted() {
        let line = "[[todo: a]] and [[todo: b]]"
        // Flip only the second one. Its prefix starts at offset 18
        // (after "[[todo: a]] and [[" = 16 + 2 = 18).
        XCTAssertEqual(
            FountainBoneyardScanner.flipTodoDone(
                in: line, atUTF16Offset: 18),
            "[[todo: a]] and [[done: b]]")
    }

    func test_flipTodoDone_invalidOffset_negative_returnsUnchanged() {
        let input = "[[todo: foo]]"
        XCTAssertEqual(
            FountainBoneyardScanner.flipTodoDone(in: input, atUTF16Offset: -1),
            input)
    }

    func test_flipTodoDone_invalidOffset_pastEnd_returnsUnchanged() {
        let input = "[[todo: foo]]"
        XCTAssertEqual(
            FountainBoneyardScanner.flipTodoDone(in: input, atUTF16Offset: 100),
            input)
    }

    func test_flipTodoDone_offsetNotOnPrefix_returnsUnchanged() {
        // Offset 0 lands on "[[" not on "todo:".
        let input = "[[todo: foo]]"
        XCTAssertEqual(
            FountainBoneyardScanner.flipTodoDone(in: input, atUTF16Offset: 0),
            input)
        // Offset 9 lands inside the body, not on the prefix.
        XCTAssertEqual(
            FountainBoneyardScanner.flipTodoDone(in: input, atUTF16Offset: 9),
            input)
    }

    // MARK: - matchTodo / matchTodoAll

    func test_matchTodo_returnsPrefixAndBodyRanges() {
        let line = "[[todo: write outline]]"
        guard let hit = FountainBoneyardScanner.matchTodo(line) else {
            XCTFail("expected match")
            return
        }
        XCTAssertFalse(hit.done)
        // "todo:" prefix starts at offset 2, length 5.
        XCTAssertEqual(hit.prefixRange, NSRange(location: 2, length: 5))
        // Body capture is "write outline" — non-greedy after `:\s*`.
        XCTAssertEqual(
            (line as NSString).substring(with: hit.bodyRange),
            "write outline")
    }

    func test_matchTodo_doneVariant() {
        guard let hit = FountainBoneyardScanner.matchTodo(
            "[[done: shipped it]]") else {
            XCTFail("expected match")
            return
        }
        XCTAssertTrue(hit.done)
        XCTAssertEqual(hit.prefixRange, NSRange(location: 2, length: 5))
    }

    func test_matchTodo_plainNote_returnsNil() {
        XCTAssertNil(FountainBoneyardScanner.matchTodo("[[note: just a note]]"))
        XCTAssertNil(FountainBoneyardScanner.matchTodo("plain text"))
    }

    func test_matchTodoAll_returnsAllOccurrences() {
        let hits = FountainBoneyardScanner.matchTodoAll(
            "[[todo: a]] and [[done: b]] and [[note: c]]")
        XCTAssertEqual(hits.count, 2)
        XCTAssertFalse(hits[0].done)
        XCTAssertTrue(hits[1].done)
        // Second prefix begins where "[[done:" starts: after "[[todo: a]] and [["
        // = 16, so prefix.location = 18.
        XCTAssertEqual(hits[1].prefixRange.location, 18)
        XCTAssertEqual(hits[1].prefixRange.length, 5)
    }

    // MARK: - ScreenplayMode.tokenize emission

    func test_todoBoneyard_emitsCheckboxToken() {
        let mode = ScreenplayMode()
        let tokens = mode.tokenize("[[todo: write the outline]]\n")
        let checkboxTokens = tokens.filter {
            if case .checkbox = $0.kind { return true }
            return false
        }
        XCTAssertEqual(checkboxTokens.count, 1)
        guard let cb = checkboxTokens.first else { return }
        // Prefix sits 2 chars in (after "[["), 5 chars wide ("todo:").
        XCTAssertEqual(cb.range, NSRange(location: 2, length: 5))
        if case .checkbox(let checked) = cb.kind {
            XCTAssertFalse(checked, "todo: should be unchecked")
        } else {
            XCTFail("expected checkbox kind")
        }
    }

    func test_doneBoneyard_emitsCheckedToken() {
        let mode = ScreenplayMode()
        let tokens = mode.tokenize("[[done: shipped]]\n")
        guard let cb = tokens.first(where: {
            if case .checkbox = $0.kind { return true }
            return false
        }) else {
            XCTFail("expected checkbox token")
            return
        }
        if case .checkbox(let checked) = cb.kind {
            XCTAssertTrue(checked, "done: should be checked")
        } else {
            XCTFail("expected checkbox kind")
        }
    }

    func test_plainBoneyard_unchanged_noCheckboxToken() {
        let mode = ScreenplayMode()
        let tokens = mode.tokenize("[[note: just a note]]\n")
        let any = tokens.contains {
            if case .checkbox = $0.kind { return true }
            return false
        }
        XCTAssertFalse(any, "[[note: ...]] must not produce a checkbox token")
    }

    func test_multipleTodos_inOneParagraph_bothRecognized() {
        let mode = ScreenplayMode()
        let tokens = mode.tokenize("Action [[todo: a]] more [[todo: b]] end\n")
        let checkboxTokens = tokens.filter {
            if case .checkbox = $0.kind { return true }
            return false
        }
        XCTAssertEqual(checkboxTokens.count, 2)
        for cb in checkboxTokens {
            XCTAssertEqual(cb.range.length, 5)
            if case .checkbox(let checked) = cb.kind {
                XCTAssertFalse(checked)
            }
        }
        // Second prefix is after `Action [[todo: a]] more [[` = 26 chars
        // ("Action "=7, "[[todo: a]]"=11, " more "=6, "[["=2).
        XCTAssertEqual(checkboxTokens[1].range.location, 26)
    }

    // MARK: - Paint pass survives re-tokenize

    func test_paintPass_stampsMaughamCheckboxAttr_overPrefixRange() {
        let mode = ScreenplayMode()
        let source = "[[todo: paint test]]\n"
        let storage = NSTextStorage(string: source)
        let tokens = mode.tokenize(source)
        mode.applyTypography(
            in: storage,
            theme: .light,
            typography: .defaults,
            tokens: tokens)

        // The marker should be present at the bracket location (offset 2).
        let raw = storage.attribute(MaughamCheckboxAttr, at: 2,
                                    effectiveRange: nil)
        guard let marker = raw as? MaughamCheckboxMarker else {
            XCTFail("expected MaughamCheckboxMarker at offset 2; got \(String(describing: raw))")
            return
        }
        XCTAssertEqual(marker.bracketLocation, 2)
        XCTAssertEqual(marker.kind, .fountain)
        XCTAssertFalse(marker.checked)

        // Re-running applyTypography (as happens on every keystroke) must
        // preserve the marker — i.e., it lives downstream of the full-
        // storage setAttributes clear that the implementation does at the
        // top of applyTypography.
        mode.applyTypography(
            in: storage,
            theme: .light,
            typography: .defaults,
            tokens: tokens)
        let rawAgain = storage.attribute(MaughamCheckboxAttr, at: 2,
                                         effectiveRange: nil)
        XCTAssertNotNil(rawAgain as? MaughamCheckboxMarker,
                        "marker lost after second applyTypography pass")
    }
}
