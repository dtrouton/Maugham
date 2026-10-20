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

    // MARK: - The section is keyed on its item

    /// The section's drafts are `@State`, and a commit runs in a `Task` that
    /// captured the item's id. Mounted without `.id(item.id)`, SwiftUI keeps
    /// one section across a selection change, so a draft typed for item A
    /// could be committed against B, or B shown with A's draft. A source
    /// census, since pressing a control and waiting is out (tripwire 33).
    static func mountsTheSectionKeyedOnItsItem(_ source: String) -> Bool {
        source.range(of: #"InspectorCitationSection\(store: store, item: item\)\s*\.id\(item\.id\)"#,
                     options: .regularExpression) != nil
    }

    func test_thePanelMountsTheCitationSectionKeyedOnItsItem() throws {
        let panel = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Maugham/Views/InspectorResearchPanel.swift")
        let source = try String(contentsOf: panel, encoding: .utf8)
        XCTAssertTrue(Self.mountsTheSectionKeyedOnItsItem(source))
    }

    func test_theKeyedMountCensusWouldCatchAnUnkeyedMount() {
        XCTAssertFalse(Self.mountsTheSectionKeyedOnItsItem(
            "InspectorCitationSection(store: store, item: item)\n    .padding()"))
        XCTAssertTrue(Self.mountsTheSectionKeyedOnItsItem(
            "InspectorCitationSection(store: store, item: item)\n        .id(item.id)"))
    }

    // MARK: - The re-seed keeps what the writer is typing (whole-branch review M8)

    /// The writer commits the source title, then types in Publisher before the
    /// commit lands. The landing must not wipe Publisher.
    func test_aCommitLandingKeepsTheFieldTheWriterIsTyping() {
        let stored = CitationInfo(key: "smith2026", authors: ["Smith"])
        var draft = CitationDraft(stored)
        draft.sourceTitle = "On Things"                 // committed …
        let landed = CitationInfo(key: "smith2026", authors: ["Smith"], sourceTitle: "On Things")
        draft.publisher = "Hachette"                    // … then typing, not yet committed
        let merged = draft.merging(storedFrom: stored, to: landed)
        XCTAssertEqual(merged.publisher, "Hachette", "the landing wiped the field being typed")
        XCTAssertEqual(merged.sourceTitle, "On Things")
        XCTAssertEqual(merged.key, "smith2026")
    }

    /// Claude's `update_research_citation` changes a field the writer has not
    /// touched: it shows. A field they are editing keeps their draft.
    func test_anExternalChangeShowsWhereTheWriterHasNotTyped() {
        let stored = CitationInfo(key: "smith2026", year: 2025, pages: "1")
        var draft = CitationDraft(stored)
        draft.pages = "12–14"                           // being typed
        let external = CitationInfo(key: "smith2026", year: 2026, pages: "3")
        let merged = draft.merging(storedFrom: stored, to: external)
        XCTAssertEqual(merged.year, 2026, "an untouched field did not follow the store")
        XCTAssertEqual(merged.pages, "12–14")
    }

    /// A field committed with spaces round it is stored trimmed; it is not
    /// "being typed", so a later change from Claude still shows there.
    func test_aCommittedFieldWithSurroundingSpacesFollowsLaterChanges() {
        var draft = CitationDraft(CitationInfo(key: "smith2026"))
        draft.publisher = "  Hachette "
        draft.authors = [" Smith ", "  "]
        let committed = CitationInfo(key: "smith2026", authors: ["Smith"], publisher: "Hachette")
        let afterCommit = draft.merging(storedFrom: CitationInfo(key: "smith2026"), to: committed)
        let external = CitationInfo(key: "smith2026", authors: ["Smith", "Jones"], publisher: "Gallimard")
        let merged = afterCommit.merging(storedFrom: committed, to: external)
        XCTAssertEqual(merged.publisher, "Gallimard", "a trimmed commit was still read as dirty")
        XCTAssertEqual(merged.authors, ["Smith", "Jones"])
    }

    func test_anUntouchedDraftBecomesTheStoredCitation() {
        let stored = CitationInfo(key: "a1", authors: ["A"])
        let new = CitationInfo(key: "b2", authors: ["B", "C"], publisher: "P", year: 2020,
                               accessed: Self.utcDay(2026, 1, 2), pages: "9")
        XCTAssertEqual(CitationDraft(stored).merging(storedFrom: stored, to: new), CitationDraft(new))
    }

    /// The section's re-seed goes through the merge (a census: nothing here
    /// mounts the view or presses a control, tripwire 33).
    func test_theSectionReSeedsThroughTheMerge() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Maugham/Views/InspectorCitationSection.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        XCTAssertNotNil(source.range(
            of: #"\.onChange\(of: item\.citation\)\s*\{\s*old, new in\s*draft = draft\.merging\(storedFrom: old, to: new\)"#,
            options: .regularExpression), "the stored citation re-seeds the whole draft again")
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
