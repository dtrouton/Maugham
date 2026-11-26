import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **`ProposalExactWidth` absorbs a floating-point sum and nothing else.**
/// The right column's control shares its row among flexible segments, and
/// the shares can sum a hair past the row; the column's stack then took the
/// control's width and widened the pane below it (CI, 2026-11-26:
/// "Brief, outside" one point past the column at 1x).
@MainActor
final class ProposalExactWidthTests: XCTestCase {

    private static func measured(_ view: some View, width: CGFloat) -> CGFloat {
        NSHostingController(rootView: AnyView(view))
            .sizeThatFits(in: CGSize(width: width, height: 10_000)).width
    }

    /// The rule: an excess under the tolerance answers the proposal; a real
    /// overflow, a narrower child and an unspecified proposal answer the child.
    func test_onlyAnExcessUnderTheToleranceAnswersTheProposal() {
        XCTAssertEqual(ProposalExactWidth.width(child: 216.00000000000003, proposed: 216), 216)
        XCTAssertEqual(ProposalExactWidth.width(child: 216.5, proposed: 216), 216.5,
                       "half a point is an overflow, not an error")
        XCTAssertEqual(ProposalExactWidth.width(child: 240, proposed: 216), 240)
        XCTAssertEqual(ProposalExactWidth.width(child: 200, proposed: 216), 200)
        XCTAssertEqual(ProposalExactWidth.width(child: 216.00000000000003, proposed: nil), 216.00000000000003)
    }

    /// Mounted: the wrapper still reports a row that really overflows, so a
    /// width census measuring through it is not blinded (the difference from
    /// a `.frame(minWidth: 0, …)`).
    func test_aRealOverflowStillMeasuresThroughIt() {
        let overWide = ProposalExactWidth { Color.clear.frame(width: 260, height: 20) }
        XCTAssertEqual(Self.measured(overWide, width: 232), 260)
    }

    /// **The control at the column's floor measures exactly the pane's
    /// width** — the evenly shared row of three segments, where the shares'
    /// sum ran 3e-14 past it — and, as the control, the same row unwrapped
    /// does run past (if SwiftUI ever sums it exactly, this premise says the
    /// wrapper has become unnecessary).
    func test_theControlAtTheFloorIsExactlyThePanesWidth() async throws {
        let url = try await ProjectFactory.createNovelProject(
            named: "Exact-\(UUID().uuidString.prefix(6))", in: TestTemp.root)
        let store = try await ProjectStore.load(from: url)
        let width = CGFloat(UIState.detailColumnWidthRange.lowerBound) - RightColumn.resizeHandleWidth
        let control = RightColumnControlFixture.control(
            store: store, position: .constant(.brief),
            subject: WindowSubject(open: .canvas, faces: .canvas),
            width: width, canvasModel: CanvasModel())
        XCTAssertEqual(Self.measured(control, width: width), width)

        let row = width - 16
        let shared = HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { _ in
                Color.clear.frame(minWidth: 36, maxWidth: .infinity, minHeight: 22)
            }
        }
        XCTAssertGreaterThan(Self.measured(shared, width: row), row,
                             "premise: three shares of the row sum past it")
        XCTAssertEqual(Self.measured(ProposalExactWidth { shared }, width: row), row)
    }
}
