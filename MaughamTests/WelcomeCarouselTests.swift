import XCTest
@testable import Maugham

final class WelcomeCarouselTests: XCTestCase {
    func test_eightSlidesInOrderEndingWithGetStarted() {
        let slides = WelcomeSlide.all
        XCTAssertEqual(slides.count, 8)
        XCTAssertEqual(slides.first?.id, .welcome)
        XCTAssertEqual(slides.last?.id, .getStarted)
        for slide in slides {
            XCTAssertFalse(slide.heading.isEmpty)
            XCTAssertFalse(slide.body.isEmpty)
        }
    }
}
