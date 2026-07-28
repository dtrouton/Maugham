import XCTest
@testable import Maugham

final class CanvasRegionTests: XCTestCase {

    private func region(_ raw: String = "r1") -> CanvasRegion {
        CanvasRegion(id: CanvasRegionID(raw), label: "Act II fog",
                     frame: CGRect(x: 0, y: 0, width: 600, height: 400))
    }

    func test_anUnlabelledRegionStillHasSomethingToShow() {
        var r = region()
        r.label = ""
        XCTAssertEqual(r.displayLabel, CanvasRegion.untitledLabel)
        r.label = "Falls"
        XCTAssertEqual(r.displayLabel, "Falls")
    }

    func test_aFreshRegionOwnsNothing() {
        let r = region()
        XCTAssertTrue(r.homeMembers.isEmpty)
        XCTAssertTrue(r.appearances.isEmpty)
        XCTAssertNil(r.boundPieceID)
        XCTAssertFalse(r.isCollapsed)
    }

    /// The chrome bar is the only part of a region a writer can grab, so its
    /// geometry is read by BOTH the renderer and the hit test. One spelling.
    func test_theChromeBarSitsAtTheTopOfTheRegionAndInsideIt() {
        let f = CGRect(x: 10, y: 20, width: 600, height: 400)
        let chrome = CanvasRegionMetrics.chromeRect(in: f)
        XCTAssertEqual(chrome.minY, f.minY)
        XCTAssertEqual(chrome.height, CanvasRegionMetrics.chromeHeight)
        XCTAssertEqual(chrome.width, f.width)
        XCTAssertTrue(f.contains(chrome))
    }

    func test_theResizeHandleSitsInTheBottomRightCornerAndInsideIt() {
        let f = CGRect(x: 10, y: 20, width: 600, height: 400)
        let handle = CanvasRegionMetrics.resizeHandleRect(in: f)
        XCTAssertEqual(handle.maxX, f.maxX)
        XCTAssertEqual(handle.maxY, f.maxY)
        XCTAssertEqual(handle.width, CanvasRegionMetrics.resizeHandleSide)
        XCTAssertTrue(f.contains(handle))
    }

    /// The two targets must not overlap, or a corner press on a short region is
    /// a coin flip between resizing it and dragging it.
    func test_theChromeBarAndTheResizeHandleNeverOverlap() {
        let f = CGRect(x: 0, y: 0, width: CanvasRegionMetrics.minimumSide,
                       height: CanvasRegionMetrics.minimumSide)
        XCTAssertFalse(CanvasRegionMetrics.chromeRect(in: f)
            .intersects(CanvasRegionMetrics.resizeHandleRect(in: f)),
            "at the SMALLEST region a writer can make — larger ones only "
            + "separate them further")
    }

    func test_regionsAreOrderedDeterministicallyByID() {
        var s = CanvasScene()
        for raw in ["r3", "r1", "r2"] {
            s.insertRegion(CanvasRegion(id: CanvasRegionID(raw), label: raw, frame: .zero))
        }
        XCTAssertEqual(s.regions.map(\.id.raw), ["r1", "r2", "r3"])
    }
}
