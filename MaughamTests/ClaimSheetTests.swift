// MaughamTests/ClaimSheetTests.swift
import XCTest
import SwiftUI
import AppKit
@testable import MaughamCore
@testable import Maugham

/// **The claim sheet DRAWS what `ClaimDecision` decided** (signed op log P2b
/// Task 8, spec §5).
///
/// Whether the question is asked at all, and what it names, is pinned
/// windowlessly in `ClaimDecisionTests`; this suite's whole job is that it
/// reaches the screen and that both answers are reachable. So nothing here
/// presses a control and waits for its effect (tripwire 33) — the two verbs are
/// closures the host supplies and are called directly.
@MainActor
final class ClaimSheetTests: XCTestCase {

    private var windows: [NSWindow] = []

    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    override func tearDown() async throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
    }

    private let oldRoot = "aaaa1111bbbb2222"

    private func offer(names: [String] = ["Denver's old MacBook", "Denver's iPhone"])
    -> ClaimOffer {
        ClaimOffer(roots: [oldRoot], names: names)
    }

    private func mount(
        _ offer: ClaimOffer, refusal: String? = nil,
        onClaim: @escaping () -> Void = {},
        onNotMine: @escaping () -> Void = {}
    ) -> NSWindow {
        let window = TestWindow.mount(
            AnyView(ClaimSheet(
                offer: offer, projectTitle: "Playlist", refusal: refusal,
                onClaim: onClaim, onNotMine: onNotMine)
                .frame(maxWidth: .infinity, maxHeight: .infinity)),
            size: CGSize(width: 520, height: 400))
        windows.append(window)
        pump(0.2)
        return window
    }

    // MARK: - What it says

    func test_theSheetAsksAboutTheBookAndNamesWhatWroteIt() throws {
        let window = mount(offer())
        let texts = try axTexts(in: window)

        XCTAssertTrue(texts.contains { $0.contains("Playlist") },
                      "the book is named — a writer with three windows open is "
                      + "being asked about one of them: \(texts)")
        XCTAssertTrue(texts.contains { $0.contains("Denver's old MacBook") },
                      "and the devices whose history it is holding: \(texts)")
        XCTAssertTrue(texts.contains { $0.contains("Denver's iPhone") }, "\(texts)")
    }

    /// Both consequences are on screen before either press, because the two
    /// answers are not symmetrical: one writes two signed records with no way
    /// back through the app, and the other writes nothing.
    func test_bothAnswersSayWhatTheyWouldDo() throws {
        let window = mount(offer())
        let texts = try axTexts(in: window)

        XCTAssertTrue(texts.contains { $0.contains("adopts what those") },
                      "Claim says what it writes: \(texts)")
        XCTAssertTrue(texts.contains { $0.contains("changes nothing") },
                      "and Not mine says that it changes nothing: \(texts)")
    }

    func test_bothButtonsAreDrawnAndLive() throws {
        let window = mount(offer())
        let labels = try axButtonLabels(in: window)

        for title in [ClaimDecision.claimTitle, ClaimDecision.notMineTitle] {
            let buttons = try axButtons(labelled: title, in: window)
            XCTAssertFalse(buttons.isEmpty, "\(title) is drawn: \(labels)")
            for button in buttons {
                XCTAssertEqual(axEnabled(button), true, "\(title) is live")
            }
        }
    }

    /// RULING-7: a write that did not happen is never presented as a thing that
    /// did nothing. The sheet stays up carrying the refusal in the error's own
    /// words.
    func test_arefusalStaysOnTheSheet() throws {
        let window = mount(
            offer(),
            refusal: AdmissionDecision.refusal(
                RegistryAdmissionError.alreadyAdmittedElsewhere(root: oldRoot)))
        let texts = try axTexts(in: window)

        XCTAssertTrue(texts.contains { $0.contains("already admitted this device") },
                      "the refusal reaches the writer: \(texts)")
    }

    /// While the claim is being written neither answer may be pressed again —
    /// a second Claim on top of the first is a second root record being
    /// decided about a folder that is mid-write.
    func test_whileItIsWritingNeitherAnswerIsLive() throws {
        let window = TestWindow.mount(
            AnyView(ClaimSheet(
                offer: offer(), projectTitle: "Playlist", isClaiming: true,
                onClaim: {}, onNotMine: {})
                .frame(maxWidth: .infinity, maxHeight: .infinity)),
            size: CGSize(width: 520, height: 400))
        windows.append(window)
        pump(0.2)

        for title in [ClaimDecision.claimTitle, ClaimDecision.notMineTitle] {
            for button in try axButtons(labelled: title, in: window) {
                XCTAssertEqual(axEnabled(button), false, "\(title) while claiming")
            }
        }
    }

    // MARK: - The two verbs

    /// Called directly rather than pressed: what each closure does is the
    /// window's business, and a press-then-wait would pin nothing about it
    /// (tripwire 33).
    func test_eachAnswerCallsItsOwnClosureAndNothingElse() {
        var claimed = 0
        var declined = 0
        let sheet = ClaimSheet(
            offer: offer(), projectTitle: "Playlist",
            onClaim: { claimed += 1 }, onNotMine: { declined += 1 })

        sheet.claimForTesting()
        XCTAssertEqual(claimed, 1)
        XCTAssertEqual(declined, 0)

        sheet.notMineForTesting()
        XCTAssertEqual(claimed, 1)
        XCTAssertEqual(declined, 1)
    }
}

private extension ClaimSheet {
    func claimForTesting() { onClaim() }
    func notMineForTesting() { onNotMine() }
}
