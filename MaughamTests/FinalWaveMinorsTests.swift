import XCTest
import MaughamCore
@testable import Maugham

/// The shell p3 final wave's small items: the card editor's loading words,
/// Return in the Tags… sheet, Escape on the target popover.
@MainActor
final class FinalWaveMinorsTests: XCTestCase {

    /// A hand-over settling (or the first read not yet made) is loading,
    /// never "Card unavailable"; only a card that was read and is not there
    /// is unavailable.
    func test_theCardEditorSaysLoadingWhileAHandOverSettles() {
        XCTAssertTrue(PaletteCardEditor.isLoading(seededCardId: nil, cardId: "card-a"))
        XCTAssertTrue(PaletteCardEditor.isLoading(seededCardId: "card-b", cardId: "card-a"),
                      "the last card's read is not this card's")
        XCTAssertFalse(PaletteCardEditor.isLoading(seededCardId: "card-a", cardId: "card-a"))
    }

    /// Return in Tags… adds the tag (the field's own submit) and keeps the
    /// sheet: Done is not the default button there, nor over the target
    /// field's Set.
    func test_returnInTheTagsSheetDoesNotCloseIt() {
        XCTAssertFalse(PieceRowSheetView.doneIsDefault(for: .tags("p")))
        XCTAssertFalse(PieceRowSheetView.doneIsDefault(for: .target("p")))
        XCTAssertTrue(PieceRowSheetView.doneIsDefault(for: .addLink("p")))
        XCTAssertTrue(PieceRowSheetView.doneIsDefault(for: .publishing("p")))
    }

    /// Escape noted before the popover closes cancels the commit its
    /// disappearance makes; any other key does not.
    func test_escapeOnTheTargetPopoverWritesNothing() {
        let note = PieceTargetField.EscapeNote()
        note.note(keyCode: 0)        // "a"
        note.note(keyCode: 36)       // Return
        XCTAssertFalse(note.pressed)
        note.note(keyCode: PieceTargetField.EscapeNote.escapeKeyCode)
        XCTAssertTrue(note.pressed)

        let menu = PieceTargetMenu(write: .pieceWords("doc"), current: 1000)
        XCTAssertEqual(menu.commitValue(text: "2000"), 2000, "premise: an edit commits")
        XCTAssertNil(menu.commitValue(text: "2000", cancelled: note.pressed),
                     "after Escape the disappearance writes nothing")
    }
}
