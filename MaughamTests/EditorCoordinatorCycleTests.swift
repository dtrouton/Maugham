import XCTest
import AppKit
import SwiftUI
@testable import Maugham

@MainActor
final class EditorCoordinatorCycleTests: XCTestCase {

    private func makeTextView(text: String = "") -> NSTextView {
        let storage = NSTextStorage(string: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 600, height: 600))
        layout.addTextContainer(container)
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 600),
                            textContainer: container)
        return tv
    }

    private func makeCoordinator(textView: NSTextView,
                                 mode: any WritingMode) -> EditorCoordinator {
        let binding: Binding<String> = .init(
            get: { textView.string },
            set: { textView.string = $0 })
        let coord = EditorCoordinator(
            text: binding, mode: mode,
            theme: .light, typography: .screenplayDefaults,
            typewriterScroll: false,
            sentenceFocus: false, paragraphFocus: false)
        coord.attach(to: textView)
        return coord
    }

    // MARK: - Tests

    func test_tabOnEmptyDocument_insertsAtMarker() {
        let tv = makeTextView(text: "")
        let coord = makeCoordinator(textView: tv, mode: ScreenplayMode())
        _ = coord.textView(tv, doCommandBy: #selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(tv.string, "@")
    }

    func test_tabOnActionLine_cyclesForwardToCharacter() {
        // Action line "Some action." has prevIsBlank=true (first line),
        // nextIsBlank=true (only line). mutate to .character adds "@" prefix.
        let tv = makeTextView(text: "Some action.")
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        let coord = makeCoordinator(textView: tv, mode: ScreenplayMode())
        _ = coord.textView(tv, doCommandBy: #selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(tv.string, "@Some action.")
    }

    func test_shiftTabOnCharacterLine_cyclesBackwardToAction() {
        // "@BARRY" is a forced character line (isForced=true, so post-pass
        // does not demote it to action). Shift-Tab cycles backward:
        // order is [action, character, dialogue, parenthetical, transition],
        // so character→action. mutateToAction strips the "@" marker → "BARRY".
        let tv = makeTextView(text: "@BARRY")
        tv.setSelectedRange(NSRange(location: 6, length: 0))
        let coord = makeCoordinator(textView: tv, mode: ScreenplayMode())
        _ = coord.textView(tv, doCommandBy: #selector(NSResponder.insertBacktab(_:)))
        XCTAssertEqual(tv.string, "BARRY")
    }

    func test_tabOnAllCapsCharacter_cyclesForwardToDialogue_noAtAdded() {
        // "BARRY\nHello." — BARRY is inferred as .character (ALL-CAPS, prevBlank,
        // next non-blank). Tab forward → .dialogue. mutateToDialogue is a no-op
        // (returns line unchanged), so BARRY stays as-is without "@".
        let tv = makeTextView(text: "BARRY\nHello.")
        tv.setSelectedRange(NSRange(location: 5, length: 0))
        let coord = makeCoordinator(textView: tv, mode: ScreenplayMode())
        _ = coord.textView(tv, doCommandBy: #selector(NSResponder.insertTab(_:)))
        XCTAssertTrue(tv.string.contains("BARRY"))
        XCTAssertFalse(tv.string.contains("@BARRY"))
    }

    // TODO(follow-on): Test blank-line cycling (Tab×2 on blank after character
    // yields dialogue→parenthetical) once FountainTokenizer produces a second
    // line entry for trailing newlines in "text\n" inputs. Currently
    // enumerateSubstrings(.byLines) yields only one line for "text\n".
}
