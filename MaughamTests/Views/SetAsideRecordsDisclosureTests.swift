import XCTest
import SwiftUI
@testable import Maugham

/// **Opening the *Set-aside records* chevron blanked the whole window** (signed
/// op log P2 smoke, find 8).
///
/// Not a hang — the main thread was idle when it was sampled. The rows are
/// archive names: an op-log filename, a content hash and an ISO8601 stamp, 99
/// characters with nothing in them to break at. Drawn as a plain `Text` with no
/// line limit, three of them ask for 559 pt inside a column pinned to the
/// writer's own width — and on the macOS 27 SDK a pane's demand is what the
/// column becomes rather than a hint (`DetailColumnWidthTests`' five fixed-width
/// cases all read 528 against 300/320/360 there).
///
/// **The causal step is not established and these tests do not assert it.** The
/// blanking would not reproduce in a real three-column split — see
/// `SetAsideRecordsDisclosure`'s doc comment for what was tried. What is pinned
/// here is narrower and sufficient: a forensic list does not get to bid for the
/// window.
///
/// Pinned WINDOWLESSLY (tripwire 33, and the headless-gate rule that only
/// `TestWindow` may build a window): `NSHostingView.fittingSize` asks the view
/// what it wants with nothing proposed, which is the question the split view
/// puts to it. The control below measures the shape that shipped, so the
/// measurement is known to be able to see the difference. The bound is
/// deliberately generous — SwiftUI's layout is exactly what moved at macOS 27,
/// so no case here asserts a width to the point.
@MainActor
final class SetAsideRecordsDisclosureTests: XCTestCase {

    /// An archive name in the smoke's own shape — an op-log filename, a content
    /// hash and an ISO8601 stamp, with no space anywhere in it.
    ///
    /// **99 characters, not the ~130 the smoke note estimates.** Measured
    /// against the three records the smoke left on disk: the longest is
    /// `doc-f6c15be9.author-20522482260c725a-1e0ac532.jsonl.40f6efa074baedad.2026-09-17T21-46-35.031Z.lines`,
    /// and the shape is fixed (an 8-hex docId, a 16-hex key prefix, an 8-hex
    /// slug, a 16-hex content hash, a stamp), so it does not vary much. It was
    /// enough.
    private static func recordName(_ index: Int) -> String {
        let name = "doc-f6c15be9.author-20522482260c725a-1e0ac53\(index).jsonl."
            + "40f6efa074baeda\(index).2026-09-17T21-46-3\(index).031Z.lines"
        XCTAssertGreaterThanOrEqual(name.count, 99, "premise: the real length")
        return name
    }

    /// The bound. Comfortably wider than the disclosure's declared ideal (so
    /// this is not a restatement of the constant) and far below the four figures
    /// the shipped shape asked for.
    private let bound: CGFloat = 400

    func test_theExpandedDisclosureDoesNotAskForTheWholeWindow() {
        let names = (1...3).map { Self.recordName($0) }
        let host = NSHostingView(
            rootView: SetAsideRecordsDisclosure(names: names, initiallyExpanded: true))

        XCTAssertLessThanOrEqual(
            host.fittingSize.width, bound,
            "an expanded list of 130-character names must not decide how wide "
            + "the History pane — and so every column of the window — is")
    }

    /// Collapsed was never the broken case; it is measured so a regression that
    /// moved the growth to the closed state could not hide.
    func test_theCollapsedDisclosureIsBoundedToo() {
        let names = (1...3).map { Self.recordName($0) }
        let host = NSHostingView(rootView: SetAsideRecordsDisclosure(names: names))

        XCTAssertLessThanOrEqual(host.fittingSize.width, bound)
    }

    /// Forty archives is a plausible number for a book that has been syncing
    /// against a revoked device; the width must not move with the count.
    func test_theWidthDoesNotGrowWithTheNumberOfRecords() {
        let three = NSHostingView(rootView: SetAsideRecordsDisclosure(
            names: (1...3).map { Self.recordName($0) }, initiallyExpanded: true))
        let forty = NSHostingView(rootView: SetAsideRecordsDisclosure(
            names: (1...40).map { Self.recordName($0) }, initiallyExpanded: true))

        XCTAssertEqual(forty.fittingSize.width, three.fittingSize.width,
                       accuracy: 1,
                       "every row is the same shape; more of them is taller, "
                       + "never wider")
        XCTAssertLessThanOrEqual(forty.fittingSize.width, bound)
    }

    /// **The control.** The shape that shipped — a `Text` per name with no line
    /// limit and no ideal width of its own — measured through the same
    /// `fittingSize`. If this does NOT blow past the bound, the measurement
    /// above is not testing anything.
    func test_theShapeThatShippedAsksForTheWholeWindow() {
        struct AsShipped: View {
            let names: [String]
            var body: some View {
                DisclosureGroup("Set-aside records", isExpanded: .constant(true)) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(names, id: \.self) { name in
                            Text(name)
                                .font(.caption2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        let host = NSHostingView(
            rootView: AsShipped(names: (1...3).map { Self.recordName($0) }))

        XCTAssertGreaterThan(
            host.fittingSize.width, bound,
            "premise of every assertion above: an unbounded row of a "
            + "130-character unbreakable name really does ask for far more "
            + "width than the column can give it")
    }
}
