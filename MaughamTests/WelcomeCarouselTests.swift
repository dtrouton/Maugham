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

    /// **The tour describes the window that ships** (shell p5 Task 9): the
    /// binder picks what the window is about; To resolve and Brief sit beside
    /// the draft. The words census reads every card for retired surfaces.
    func test_theStructureAndThreadsCardsDescribeTheBinderAndTheTwoFaces() throws {
        let structure = try XCTUnwrap(WelcomeSlide.all.first { $0.id == .structure })
        XCTAssertTrue(structure.body.contains("binder"), structure.body)
        let threads = try XCTUnwrap(WelcomeSlide.all.first { $0.id == .organize })
        XCTAssertTrue(threads.body.contains("To resolve"), threads.body)
        XCTAssertTrue(threads.body.contains("Brief"), threads.body)
    }
}
