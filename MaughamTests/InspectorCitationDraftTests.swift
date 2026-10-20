import XCTest
@testable import Maugham
@testable import MaughamCore

/// The research inspector's Citation section, through its pure helpers only
/// (tripwire 33: nothing here presses a control). The rules themselves are the
/// door's (`CitationEditTests`); these pin what the section hands it and how it
/// shows what comes back.
final class InspectorCitationDraftTests: XCTestCase {

    private static func calendar(_ zone: String) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: zone)!
        return cal
    }

    private static func utcDay(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar("UTC").date(from: DateComponents(year: y, month: m, day: d))!
    }

    func test_anEmptyDraftHandsTheDoorABlankKeyAndNothingElse() {
        let draft = CitationDraft(nil)
        XCTAssertEqual(draft, CitationDraft())
        XCTAssertEqual(draft.citation(), CitationInfo(key: ""))
    }

    func test_blankTextFieldsBecomeAbsentFields() {
        var draft = CitationDraft()
        draft.key = "smith2026"
        draft.sourceTitle = "   "
        draft.publisher = ""
        draft.pages = " 12 "
        XCTAssertEqual(draft.citation(), CitationInfo(key: "smith2026", pages: "12"))
    }

    /// A stored citation seeds the draft and comes back unchanged, accessed
    /// day included, in a zone east of UTC, west of it and at UTC+14.
    func test_aStoredCitationRoundTripsThroughTheDraftInEveryZone() {
        let info = CitationInfo(key: "gartner2026", authors: ["Gartner", "Lovelace, Ada"],
                                sourceTitle: "Hype Cycle", publisher: "Gartner Inc.", year: 2026,
                                accessed: Self.utcDay(2026, 10, 20), pages: "4–9")
        for zone in ["Europe/Belgrade", "America/Los_Angeles", "Pacific/Kiritimati", "UTC"] {
            let cal = Self.calendar(zone)
            let draft = CitationDraft(info, calendar: cal)
            XCTAssertEqual(draft.citation(calendar: cal), info, zone)
        }
    }

    /// The picker works in the writer's zone; `CitationStyle` prints the day in
    /// UTC. The day the writer picked is the day that prints, east or west.
    func test_thePickedDayIsTheStoredDay() {
        for zone in ["Europe/Belgrade", "America/Los_Angeles", "Pacific/Kiritimati", "Asia/Tokyo"] {
            let cal = Self.calendar(zone)
            let pickedMidnight = cal.date(from: DateComponents(year: 2026, month: 3, day: 3))!
            let lateEvening = cal.date(from: DateComponents(year: 2026, month: 3, day: 3, hour: 23, minute: 30))!
            for picked in [pickedMidnight, lateEvening] {
                let stored = CitationDraft.storedDay(fromPicked: picked, calendar: cal)
                XCTAssertEqual(stored, Self.utcDay(2026, 3, 3), zone)
                XCTAssertEqual(ResearchCitationWire.formatDay(stored), "2026-03-03", zone)
            }
            let shown = CitationDraft.pickedDay(fromStored: Self.utcDay(2026, 3, 3), calendar: cal)
            XCTAssertEqual(cal.dateComponents([.year, .month, .day], from: shown),
                           DateComponents(year: 2026, month: 3, day: 3), zone)
        }
    }

    func test_theYearIsShownWithoutAGroupingSeparator() {
        XCTAssertEqual(2026.formatted(CitationDraft.yearFormat), "2026")
        XCTAssertEqual(try CitationDraft.yearFormat.parseStrategy.parse("1999"), 1999)
    }

    func test_aRefusalIsShownInTheDoorsWords() {
        XCTAssertEqual(CitationDraft.refusal(CitationEditError.needsAKey), "A citation needs a key")
        XCTAssertTrue(CitationDraft.refusal(CitationEditError.duplicateKey("smith2020")).contains("smith2020"))
        XCTAssertTrue(CitationDraft.refusal(ProjectStoreError.structureMissing).hasPrefix("Couldn’t save the citation"))
    }

    /// Authors go through the tags chip list, but an author may be written
    /// "Surname, Given" (`CitationStyle` reads the surname before the comma),
    /// so the authors field takes a typed line whole.
    func test_theAuthorsFieldKeepsACommaWhereTheTagsFieldSplitsOnIt() {
        XCTAssertEqual(InspectorTagsField.entries(from: "Lovelace, Ada", splitsOnCommas: false), ["Lovelace, Ada"])
        XCTAssertEqual(InspectorTagsField.entries(from: " a, b ,, c ", splitsOnCommas: true), ["a", "b", "c"])
        XCTAssertEqual(InspectorTagsField.entries(from: "   ", splitsOnCommas: false), [])
    }
}
