import XCTest
@testable import Maugham

@MainActor
final class OnboardingModelTests: XCTestCase {
    func test_defaults() {
        let m = OnboardingModel()
        XCTAssertFalse(m.carouselRequested)
        XCTAssertNil(m.sampleRequested)
    }
    func test_intentRoundTrips() {
        let m = OnboardingModel()
        m.carouselRequested = true
        m.sampleRequested = .screenplay
        XCTAssertTrue(m.carouselRequested)
        XCTAssertEqual(m.sampleRequested, .screenplay)
    }
}
