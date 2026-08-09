import XCTest
@testable import Maugham

/// CHARACTERISATION of the research-note READ that backs `ResearchNoteEditor`
/// (`ResearchNoteLoad`), pinning claim `M1-C-055`'s first half.
///
/// `M1-C-055` — an unreadable research note opened as a BLANK editor whose
/// binding setter schedules an atomic whole-file save on the first keystroke,
/// so one character replaced bytes that have no op log and no checkpoint
/// behind them. **Fixed under RULING-7, 2026-08-09** ("unreadable is never
/// presented as empty"): the read reports the failure as what it is, and the
/// editor is not mounted over it. The SECOND half — that a whole-file
/// replacement of a research note keeps nothing recoverable — is the
/// research-protection milestone's tier-2 question and is deliberately still
/// open (`experiment/MILESTONE-research-protection.md`).
@MainActor
final class ResearchNoteReadCharacterization: XCTestCase {

    private var temp: TempDirectory!
    override func setUp() { super.setUp(); temp = TempDirectory() }
    override func tearDown() { temp = nil; super.tearDown() }

    /// M1-C-055 — a file that exists and cannot be decoded reports UNREADABLE.
    func test_aNoteThatCannotBeDecodedIsReportedAsUnreadable_neverAsEmpty() throws {
        let url = temp.url.appendingPathComponent("note.md")
        // Lone continuation bytes: valid on disk, not valid UTF-8 — the shape
        // an import of a Latin-1 or UTF-16 note from another tool leaves.
        try Data([0xFF, 0xFE, 0x80, 0x81]).write(to: url)

        switch ResearchNoteLoad.read(url) {
        case .text(let text):
            XCTFail("presented as text (\(text.count) chars) rather than unreadable")
        case .unreadable(let reason):
            XCTAssertFalse(reason.isEmpty, "the refusal names its cause")
        }
    }

    /// M1-C-061 — a readable note still reads as its text, byte for byte.
    func test_aReadableNoteReadsAsItsText() throws {
        let url = temp.url.appendingPathComponent("note.md")
        try "The lamp, and under it the letter.".write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(ResearchNoteLoad.read(url),
                       .text("The lamp, and under it the letter."))
    }

    /// M1-C-062 — a note whose file is not there at all still reads as empty,
    /// as it always has. Nothing is at risk in that case: there are no bytes
    /// for a first keystroke to replace.
    func test_aMissingFileStillReadsAsEmpty() {
        XCTAssertEqual(
            ResearchNoteLoad.read(temp.url.appendingPathComponent("nothing-here.md")),
            .text(""))
    }
}
