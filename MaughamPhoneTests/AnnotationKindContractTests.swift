import XCTest
import MaughamCore

/// The iOS half of the cross-surface `AnnotationKind` icon + label contract
/// (sibling in `MaughamTests` covers the Mac). Pins the canonical
/// `systemImageName` / `displayName` values so the two surfaces can't silently
/// drift, and forces any new `AnnotationKind` case to be handled (the
/// exhaustive switch in `AnnotationKind.systemImageName` / `.displayName`
/// stops compiling otherwise).
final class AnnotationKindContractTests: XCTestCase {

    // MARK: - systemImageName

    func test_systemImageName_comment() {
        XCTAssertEqual(AnnotationKind.comment.systemImageName, "bubble.left")
    }

    func test_systemImageName_suggestedChange() {
        XCTAssertEqual(AnnotationKind.suggestedChange.systemImageName, "pencil.line")
    }

    func test_systemImageName_query() {
        XCTAssertEqual(AnnotationKind.query.systemImageName, "questionmark.circle")
    }

    func test_systemImageName_craftNote() {
        XCTAssertEqual(AnnotationKind.craftNote.systemImageName, "lightbulb")
    }

    func test_systemImageName_nonEmpty_forAllCases() {
        for kind in AnnotationKind.allCases {
            XCTAssertFalse(
                kind.systemImageName.isEmpty,
                "systemImageName is empty for \(kind)")
        }
    }

    // MARK: - displayName

    func test_displayName_comment() {
        XCTAssertEqual(AnnotationKind.comment.displayName, "Comment")
    }

    func test_displayName_suggestedChange() {
        XCTAssertEqual(AnnotationKind.suggestedChange.displayName, "Suggested change")
    }

    func test_displayName_query() {
        XCTAssertEqual(AnnotationKind.query.displayName, "Query")
    }

    func test_displayName_craftNote() {
        XCTAssertEqual(AnnotationKind.craftNote.displayName, "Craft note")
    }

    func test_displayName_nonEmpty_forAllCases() {
        for kind in AnnotationKind.allCases {
            XCTAssertFalse(
                kind.displayName.isEmpty,
                "displayName is empty for \(kind)")
        }
    }
}
