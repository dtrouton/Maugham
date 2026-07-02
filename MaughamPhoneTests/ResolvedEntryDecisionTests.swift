import XCTest
@testable import MaughamPhone
import MaughamCore

final class ResolvedEntryDecisionTests: XCTestCase {
    func test_openedResolved_isReviewOnly() {
        let d = ResolvedEntryDecision.afterRederive(openedResolved: true, freshStatus: .accepted)
        XCTAssertFalse(d.raceCollapse); XCTAssertFalse(d.notifyList)
    }
    func test_openedResolved_disappeared_stillReviewOnly() {
        let d = ResolvedEntryDecision.afterRederive(openedResolved: true, freshStatus: nil)
        XCTAssertFalse(d.raceCollapse); XCTAssertFalse(d.notifyList)
    }
    func test_openedOpen_stillOpen_normal() {
        let d = ResolvedEntryDecision.afterRederive(openedResolved: false, freshStatus: .open)
        XCTAssertFalse(d.raceCollapse); XCTAssertFalse(d.notifyList)
    }
    func test_openedOpen_nowResolved_isRace() {
        let d = ResolvedEntryDecision.afterRederive(openedResolved: false, freshStatus: .rejected)
        XCTAssertTrue(d.raceCollapse); XCTAssertTrue(d.notifyList)
    }
    func test_openedOpen_disappeared_isRace() {
        let d = ResolvedEntryDecision.afterRederive(openedResolved: false, freshStatus: nil)
        XCTAssertTrue(d.raceCollapse); XCTAssertTrue(d.notifyList)
    }
}
