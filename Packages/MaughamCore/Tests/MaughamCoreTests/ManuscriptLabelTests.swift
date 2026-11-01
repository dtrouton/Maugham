import XCTest
@testable import MaughamCore

final class ManuscriptLabelTests: XCTestCase {

    private func label(_ reference: String) -> ManuscriptLabel {
        ManuscriptLabel(reference: reference)!
    }

    /// The one rule (R7a-1): a table figure's line (its path a `.csv`, any
    /// case) is in the table list unless it is labelled `fig:`; every other
    /// figure line is in the figure list.
    func test_whichListAFigureLineNumbersIn() {
        XCTAssertEqual(ManuscriptLabel.Kind.ofFigureLine(path: "figures/cash.csv", label: label("tbl:cash")), .tbl)
        XCTAssertEqual(ManuscriptLabel.Kind.ofFigureLine(path: "../../figures/C.CSV", label: label("tbl:c")), .tbl)
        XCTAssertEqual(ManuscriptLabel.Kind.ofFigureLine(path: "figures/cash.csv", label: label("fig:cash")), .fig)
        XCTAssertEqual(ManuscriptLabel.Kind.ofFigureLine(path: "figures/cash.csv", label: nil), .tbl)
        XCTAssertEqual(ManuscriptLabel.Kind.ofFigureLine(path: "w.png", label: nil), .fig)
        XCTAssertEqual(ManuscriptLabel.Kind.ofFigureLine(path: "w.png", label: label("tbl:w")), .fig)
        XCTAssertEqual(ManuscriptLabel.Kind.ofFigureLine(path: "figures/csv", label: label("tbl:w")), .fig)
    }
}
