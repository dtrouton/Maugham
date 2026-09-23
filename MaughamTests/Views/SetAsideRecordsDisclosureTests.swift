import XCTest
import SwiftUI
@testable import Maugham
import MaughamCore

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

    /// Rows carrying nothing to send — the forensic list as it was before P3b
    /// Task 8 gave it a control. `test_theDoorsButtonDoesNotWidenTheList`
    /// measures the other shape.
    private static func rows(_ names: [String]) -> [SetAsideDoor.Row] {
        names.map { SetAsideDoor.Row(name: $0, unsent: 0, sentCount: 0) }
    }

    func test_theExpandedDisclosureDoesNotAskForTheWholeWindow() {
        let names = (1...3).map { Self.recordName($0) }
        let host = NSHostingView(
            rootView: SetAsideRecordsDisclosure(
                rows: Self.rows(names), initiallyExpanded: true))

        XCTAssertLessThanOrEqual(
            host.fittingSize.width, bound,
            "an expanded list of 130-character names must not decide how wide "
            + "the History pane — and so every column of the window — is")
    }

    /// Collapsed was never the broken case; it is measured so a regression that
    /// moved the growth to the closed state could not hide.
    func test_theCollapsedDisclosureIsBoundedToo() {
        let names = (1...3).map { Self.recordName($0) }
        let host = NSHostingView(
            rootView: SetAsideRecordsDisclosure(rows: Self.rows(names)))

        XCTAssertLessThanOrEqual(host.fittingSize.width, bound)
    }

    /// Forty archives is a plausible number for a book that has been syncing
    /// against a revoked device; the width must not move with the count.
    func test_theWidthDoesNotGrowWithTheNumberOfRecords() {
        let three = NSHostingView(rootView: SetAsideRecordsDisclosure(
            rows: Self.rows((1...3).map { Self.recordName($0) }),
            initiallyExpanded: true))
        let forty = NSHostingView(rootView: SetAsideRecordsDisclosure(
            rows: Self.rows((1...40).map { Self.recordName($0) }),
            initiallyExpanded: true))

        XCTAssertEqual(forty.fittingSize.width, three.fittingSize.width,
                       accuracy: 1,
                       "every row is the same shape; more of them is taller, "
                       + "never wider")
        XCTAssertLessThanOrEqual(forty.fittingSize.width, bound)
    }

    /// **The door does not widen the list** (P3b Task 8). A row whose record
    /// held manuscript text grows a **Send to Inbox** button, and a row already
    /// sent grows a note; neither may put the History pane — and so every
    /// column of the window — back in the position this suite exists to keep it
    /// out of.
    ///
    /// C13 was re-run before the control was added and did not reproduce: the
    /// expanded disclosure in a real three-column split holds `[240, 639, 320]`
    /// at 1200 pt and `[200, 480, 320]` at 900 pt. This is the narrower thing
    /// that can be pinned.
    func test_theDoorsButtonDoesNotWidenTheList() {
        let names = (1...3).map { Self.recordName($0) }
        let offering = names.map {
            SetAsideDoor.Row(name: $0, unsent: 7, sentCount: 0)
        }
        let sent = names.map {
            SetAsideDoor.Row(name: $0, unsent: 0, sentCount: 7)
        }

        for rows in [offering, sent] {
            let host = NSHostingView(rootView: SetAsideRecordsDisclosure(
                rows: rows, initiallyExpanded: true))
            XCTAssertLessThanOrEqual(host.fittingSize.width, bound)
        }
        XCTAssertTrue(offering[0].offersTheDoor, "premise: the button is drawn")
        XCTAssertNotNil(sent[0].sentNote, "premise: the note is drawn")
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

    // MARK: - The OTHER door on the same pane (P3b Task 10; Task 8's M5)

    /// **A held-line row is under the same rule, and was outside this suite.**
    ///
    /// Task 8's fix round put a second **Send to Inbox** control on this pane —
    /// on the held-line rows, whose sentences are composed live and are far
    /// longer than a record's name. It was drawn inline in `HistoryPane.body`,
    /// so nothing could measure it without mounting the pane; `HeldLineNoticeRow`
    /// is that row extracted for exactly this reason (the disclosure beside it
    /// is the precedent).
    ///
    /// Both shapes are measured, as above: the row offering the door, and the
    /// row that has already sent.
    func test_theHeldRowsDoorDoesNotWidenThePane() {
        let sentence = HeldLines.sentence(
            .unsigned(stream: "author-20522482260c725a"), notes: 7) ?? ""
        XCTAssertGreaterThanOrEqual(
            sentence.count, 120, "premise: these sentences are long")
        let offering = SetAsideDoor.HeldRow(
            holder: HeldLines.unsignedHolder(
                forStreamKey: "author-20522482260c725a", deviceSlug: nil),
            sentence: sentence, unsent: 7, sentCount: 0)
        let sent = SetAsideDoor.HeldRow(
            holder: offering.holder, sentence: sentence, unsent: 0, sentCount: 7)

        for row in [offering, sent] {
            let host = NSHostingView(rootView: HeldLineNoticeRow(row: row))
            XCTAssertLessThanOrEqual(host.fittingSize.width, bound, "\(row)")
        }
        XCTAssertTrue(offering.offersTheDoor, "premise: the button is drawn")
        XCTAssertNotNil(sent.sentNote, "premise: the note is drawn")
    }

    /// The same control for the same reason: an unbounded single line of that
    /// sentence really does ask for more than the column has.
    func test_theHeldRowsSentenceUnboundedAsksForTheWholeWindow() {
        struct AsShipped: View {
            let sentence: String
            var body: some View {
                HStack(spacing: 8) {
                    Label(sentence, systemImage: "clock.badge.questionmark")
                        .font(.caption)
                    Spacer(minLength: 4)
                    Button("Send to Inbox") {}
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        let host = NSHostingView(rootView: AsShipped(
            sentence: HeldLines.sentence(
                .unsigned(stream: "author-20522482260c725a"), notes: 7) ?? ""))
        XCTAssertGreaterThan(host.fittingSize.width, bound)
    }
}
