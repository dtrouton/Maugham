import XCTest
@testable import Maugham

final class PalettePaneTests: XCTestCase {
    func test_senseSymbol_coversAllSenses() {
        for sense in PaletteCard.Sense.allCases {
            XCTAssertFalse(PalettePane.senseSymbol(for: sense).isEmpty)
        }
        XCTAssertEqual(PalettePane.senseSymbol(for: .sight), "eye")
        XCTAssertEqual(PalettePane.senseSymbol(for: .touch), "hand.raised")
    }

    func test_groupedNotes_ordersTaggedBySenseThenUntagged() {
        let notes: [PaletteCard.SensoryNote] = [
            .init(sense: nil, text: "loose"),
            .init(sense: .taste, text: "salt"),
            .init(sense: .sight, text: "green light"),
        ]
        let groups = PalettePane.groupedNotes(notes)
        XCTAssertEqual(groups.map(\.sense), [.sight, .taste, nil])
        XCTAssertEqual(groups.first?.notes.map(\.text), ["green light"])
    }
}
