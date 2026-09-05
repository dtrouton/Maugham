import XCTest
import SwiftUI
import AppKit
@testable import Maugham
import MaughamCore

/// **The opened letter is bounded, and the queue below it survives** (Denver's
/// 2026-09-03 Review smoke).
///
/// The cockpit lives in `AnnotationsPane.body`'s NON-scrolling `VStack`, above
/// the queue: every strip there demands its full height as a MINIMUM, and
/// SwiftUI cannot compress a minimum. So the letter disclosure, which draws the
/// host's whole `LetterSection` inline, used to demand a letter's worth of
/// height from a pane that had a column's — the letter ran off the bottom of
/// the pane unread and the queue below it was squeezed to nothing. Denver's
/// screenshot is the queue gone entirely under a half-visible letter.
///
/// Three measurements, one instrument. `onGeometryChange` reports what each of
/// the two views was actually LAID OUT at, in a window deliberately shorter
/// than a long letter — no accessibility frame walk, which reads a hosting
/// view's clipped backing rather than the SwiftUI layout, and no
/// `sizeThatFits`, which cannot ask a `DisclosureGroup` to be open.
///
/// The stack under test mirrors the pane's: the strip, then one greedy view
/// standing in for the scrolling queue. The mount deliberately omits
/// `.doesNotRaiseTheWindowFloor()`, which the pane ends in — that modifier
/// CLIPS, so under it every measurement would read the window's own height and
/// the defect would be invisible. What is under test is what the strip DEMANDS,
/// and the clip is what turns that demand into Denver's screenshot.
@MainActor
final class ReviewRoundCockpitLetterScrollTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        // Every assertion here is a text-layout measurement through production
        // typography (`.caption` lines, a letter's wrapped body) across parallel
        // workers — the fontd cold-start window, CLAUDE.md.
        FontWarmup.ensure()
    }

    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        super.tearDown()
    }

    private static let copyedit = ReviewPass(
        id: "copyedit", name: "Copyedit", brief: "b", editorName: "Gould")
    private static let line = ReviewPass(
        id: "line", name: "Line", brief: "b", editorName: "Lish")

    /// The letter line the disclosure is labelled with — the handle every test
    /// here presses.
    private static let letterLine = "Give the reader the dock before the fire."

    // MARK: - The claim

    /// **A letter longer than the pane scrolls inside the strip, and the queue
    /// below it keeps a height.**
    ///
    /// The window is `paneHeight` — the smallest pane production can actually
    /// draw this strip in, and a fraction of the ~2,200pt of letter mounted
    /// into it. Two assertions, because the defect has two halves and a fix
    /// that bounded the strip while starving the queue would pass only one.
    ///
    /// The ceiling is calibrated against this same strip COLLAPSED rather than
    /// hardcoded, so the test is about the letter's contribution and not about
    /// the height of a lane picker. Measured 2026-09-03 with the bound in
    /// place: the strip 403.0pt (83 collapsed plus the 320 ceiling) and the
    /// queue 97.0pt.
    ///
    /// **Disable experiment** (run 2026-09-03): with `BoundedHeightLayout`
    /// removed from `letterRow` — the disclosure content mounted bare, as it
    /// shipped — the expanded strip measured **2,239pt** against a ceiling of
    /// 443pt and the queue stand-in measured **0pt**, failing both assertions:
    /// *"an opened letter must be bounded by 320.0pt and scroll inside it"* and
    /// *"the queue below the strip must keep a height. It measured 0.0pt"*.
    func test_aLetterLongerThanThePaneScrollsInsteadOfPushingTheQueueOff() throws {
        let collapsed = try measure(disclosure: Self.tallLetter, expand: false)
        let expanded = try measure(disclosure: Self.tallLetter, expand: true)

        let ceiling = collapsed.strip
            + ReviewRoundCockpit.letterDisclosureMaxHeight
            + Self.disclosureChromeSlack
        XCTAssertLessThanOrEqual(
            expanded.strip, ceiling,
            "an opened letter must be bounded by "
            + "\(ReviewRoundCockpit.letterDisclosureMaxHeight)pt and scroll inside "
            + "it. The strip demanded \(expanded.strip)pt over a collapsed "
            + "\(collapsed.strip)pt, which is a letter's height reaching a "
            + "non-scrolling pane \u{2014} Denver's smoke exactly")
        XCTAssertGreaterThan(
            expanded.queue, 0,
            "the queue below the strip must keep a height. It measured "
            + "\(expanded.queue)pt, which is the strip having taken the whole "
            + "pane and left the writer's notes nowhere to draw")
    }

    /// **The bounded letter SCROLLS — it is not merely clipped.** The bound
    /// and the scroll are two claims, and only one of them is about whether the
    /// writer can read the letter: `frame(maxHeight: 320).clipped()` around the
    /// bare content bounds the strip, keeps the queue, costs a short letter
    /// nothing, and passes every other test in this file while leaving
    /// everything past line eleven unreachable — Denver's report, one layer in.
    ///
    /// Two halves. A scroll area must be PUBLISHED (read as a role off the
    /// accessibility tree rather than by hunting `NSScrollView`, which is a bet
    /// on which backing class SwiftUI picks this year), and the letter inside it
    /// must still be laid out at its own full height — a fix that made the
    /// letter itself smaller to fit would publish a scroll area over nothing to
    /// scroll.
    ///
    /// Measured 2026-09-03: the letter 2,156.0pt inside a 403.0pt strip
    /// (2,156 plus the strip’s own 83pt of chrome is the 2,239pt the
    /// unbounded strip used to demand).
    ///
    /// **Disable experiment** (run 2026-09-03): with the `ScrollView` replaced
    /// by `.frame(maxHeight: Self.letterDisclosureMaxHeight).clipped()`, the
    /// other three tests stayed green and this one went red on
    /// *"the opened letter must be inside a scroll area"*.
    func test_theBoundedLetterScrollsRatherThanBeingClipped() throws {
        let expanded = try measure(disclosure: Self.tallLetter, expand: true)

        XCTAssertTrue(
            expanded.hasScrollArea,
            "the opened letter must be inside a scroll area \u{2014} a bound that "
            + "merely clips leaves everything past the first few lines "
            + "unreachable, which is the smoke's own complaint one layer in")
        XCTAssertGreaterThan(
            expanded.content, ReviewRoundCockpit.letterDisclosureMaxHeight * 2,
            "and the letter inside it keeps its own full height. It measured "
            + "\(expanded.content)pt against a strip of \(expanded.strip)pt \u{2014} "
            + "a letter shrunk to fit is a scroll area with nothing to scroll")
    }

    /// **CONTROL: a short letter takes its own height, not the ceiling.** A
    /// bound written as a fixed `frame(height:)` would pass the claim above and
    /// put 320pt of empty scroll view under three lines in every ordinary
    /// round, which is the common case.
    ///
    /// **Disable experiment** (run 2026-09-03): with the layout's
    /// `min(ideal, maxHeight)` written as `maxHeight`, the short letter's strip
    /// grew by **320.0pt** against the 200pt allowance here and this test went
    /// red while the claim above stayed green.
    func test_aShortLetterTakesItsOwnHeightAndNotTheCeiling() throws {
        let collapsed = try measure(disclosure: Self.shortLetter, expand: false)
        let expanded = try measure(disclosure: Self.shortLetter, expand: true)

        let grew = expanded.strip - collapsed.strip
        XCTAssertGreaterThan(
            grew, 10,
            "the disclosure did open \u{2014} a control that reveals nothing is "
            + "not what this file measures (grew \(grew)pt)")
        XCTAssertLessThan(
            grew, 200,
            "three lines of letter must cost three lines of strip. It cost "
            + "\(grew)pt against a ceiling of "
            + "\(ReviewRoundCockpit.letterDisclosureMaxHeight)pt, which is a "
            + "fixed height wearing a bound's name")
    }

    /// **The collapsed row is untouched, however long the letter behind it.**
    /// The bound may not be paid for by the state a reviewer is in for most of
    /// their reading — the strip that draws over a 60-line letter must be the
    /// same strip that draws over a 3-line one until the triangle is pressed.
    ///
    /// Measured 2026-09-03: **83.0pt** for both, in a 320pt-wide column.
    ///
    /// **Disable experiment** (run 2026-09-03): a fix that drew the bounded
    /// letter UNCONDITIONALLY — the same `ScrollView` in a `VStack` beside the
    /// line rather than inside the `DisclosureGroup` — is bounded, scrolls, and
    /// leaves the queue a height, so it passes both tests above. Here it
    /// measured **135.0pt over three lines against 399.0pt over sixty**, red on
    /// both assertions: the reviewer would pay a third of the pane for a letter
    /// they never asked to see.
    func test_theCollapsedStripIsTheSameHeightWhateverTheLetterBehindItHolds()
        throws
    {
        let short = try measure(disclosure: Self.shortLetter, expand: false)
        let tall = try measure(disclosure: Self.tallLetter, expand: false)

        XCTAssertEqual(
            short.strip, tall.strip, accuracy: 0.5,
            "a collapsed disclosure draws none of its content, so the strip's "
            + "height cannot depend on it \u{2014} \(short.strip)pt over three "
            + "lines against \(tall.strip)pt over sixty")
        XCTAssertLessThan(
            tall.strip, ReviewRoundCockpit.letterDisclosureMaxHeight,
            "and the collapsed strip is a caption and three controls, well "
            + "under the letter's own ceiling (measured \(tall.strip)pt)")
    }

    // MARK: - The letters

    /// Sixty lines — a real letter, and about 2,200pt in a 320pt column.
    @ViewBuilder
    private static var tallLetter: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<60, id: \.self) { index in
                Text("The dock, the fire, and what the weather knows. \(index)")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Three lines — the ordinary round, and the control's subject.
    @ViewBuilder
    private static var shortLetter: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Text("A short letter, line \(index).")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What a `DisclosureGroup` spends on its own spacing and indent around the
    /// content it opens. Generous on purpose: the claim is that the LETTER is
    /// bounded, and a few points of AppKit chrome is not what this file is
    /// about.
    private static let disclosureChromeSlack: CGFloat = 40

    /// **About the shortest pane this strip is ever drawn in.**
    /// `ProjectWindow.windowHeightFloor` is 540, and the queue's column loses
    /// its title bar and toolbar off the top of that — so 500pt is a little
    /// under the worst case a writer can put the app into, and the queue's
    /// measured share here is that worst case's share. A window SHORTER than
    /// the ceiling plus the strip's own chrome would fail the queue assertion
    /// on arithmetic rather than on the bug, which is not what this file is
    /// about.
    private static let paneHeight: CGFloat = 500

    // MARK: - The instrument

    private struct Measurement {
        var strip: CGFloat
        var queue: CGFloat
        /// What the letter itself was laid out at INSIDE the strip — its full
        /// height when it is in a scroll view, whatever the strip's own bound.
        var content: CGFloat
        /// Whether the surface publishes a scroll area at all.
        var hasScrollArea: Bool
    }

    /// Mount the strip over a greedy stand-in for the queue, in a window too
    /// short for a long letter, and report what each was laid out at.
    ///
    /// `expand` presses the disclosure through the accessibility tree —
    /// `ReviewRoundCockpitTests`' own delivery path, and the one that needs no
    /// active app.
    private func measure(
        disclosure: some View, expand: Bool
    ) throws -> Measurement {
        let box = HeightBox()
        let content = VStack(spacing: 0) {
            ReviewRoundCockpit(
                passes: [Self.line, Self.copyedit],
                activePassId: "copyedit",
                round: 2,
                phase: .idle,
                reportLine: nil,
                onRun: { _ in },
                onSetActivePass: { _ in },
                onCancel: {},
                compilerModel: .standard,
                onCompilerModelChange: { _ in },
                letterLine: Self.letterLine,
                letterDisclosure: {
                    AnyView(disclosure
                        .onGeometryChange(for: CGFloat.self) { $0.size.height }
                            action: { box.content = $0 })
                })
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    box.strip = $0
                }
            Color.clear
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    box.queue = $0
                }
        }
        .frame(width: 320, height: Self.paneHeight, alignment: .top)

        let window = TestWindow.mount(
            content, size: CGSize(width: 320, height: Self.paneHeight))
        windows.append(window)
        pump(0.3)

        if expand {
            let control = try XCTUnwrap(
                disclosureControl(labelled: Self.letterLine, in: window),
                "the letter line must be a pressable disclosure. Read: "
                + "\((try? axTexts(in: window)) ?? [])")
            press(control)
            pump(0.4)
        }
        return Measurement(
            strip: box.strip, queue: box.queue, content: box.content,
            hasScrollArea: try axElements(in: window).contains {
                (axAttribute($0, "accessibilityRole") as? String) == "AXScrollArea"
            })
    }

    /// A `DisclosureGroup`'s own control, found by the label it draws —
    /// deliberately role-agnostic, per `ReviewRoundCockpitTests`' reader: the
    /// claim is "this is pressable", not which AppKit spelling macOS picked for
    /// a disclosure this year.
    private func disclosureControl(
        labelled label: String, in window: NSWindow
    ) throws -> AnyObject? {
        try axElements(in: window).first { element in
            guard let object = element as? NSObject,
                  object.responds(to: NSSelectorFromString("accessibilityPerformPress"))
            else { return false }
            let drawn = (axAttribute(element, "accessibilityLabel") as? String)
                ?? (axAttribute(element, "accessibilityValue") as? String) ?? ""
            return drawn == label
        }
    }

    /// Somewhere for a SwiftUI closure to leave a number the test can read.
    @MainActor
    private final class HeightBox {
        var strip: CGFloat = 0
        var queue: CGFloat = 0
        var content: CGFloat = 0
    }
}
