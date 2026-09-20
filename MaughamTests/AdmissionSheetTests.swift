// MaughamTests/AdmissionSheetTests.swift
import XCTest
import SwiftUI
import AppKit
@testable import MaughamCore
@testable import Maugham

/// **The admission sheet DRAWS what `AdmissionDecision` decided** (signed op
/// log P2b, spec §4.1).
///
/// What a press MEANS is pinned windowlessly in `AdmissionDecisionTests`; this
/// suite's whole job is that each of those decisions reaches the screen. So
/// nothing here presses a control and waits for its effect (tripwire 33) — the
/// verbs are closures the host supplies, and the two that matter are asserted
/// by calling them directly, with no window between the call and the answer.
@MainActor
final class AdmissionSheetTests: XCTestCase {

    private var windows: [NSWindow] = []

    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    override func tearDown() async throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
    }

    private let phone = "ffff2222"

    private func request(
        ownName: String? = "Denver’s iPhone", waiting: Int = 14,
        knownLabels: [String] = ["Amelia", "Denver"]
    ) -> AdmissionRequest {
        AdmissionRequest(
            fingerprint: phone, ownName: ownName,
            code: DeviceCode.short(phone), waitingCount: waiting,
            proposedLabel: ownName ?? "", knownLabels: knownLabels)
    }

    private func mount(
        _ request: AdmissionRequest, refusal: String? = nil,
        pieces: [PermitControl.Piece] = [],
        onAdmit: @escaping (String, Permit) -> Void = { _, _ in },
        onNotNow: @escaping () -> Void = {}
    ) -> NSWindow {
        let window = TestWindow.mount(
            AnyView(AdmissionSheet(
                request: request, projectTitle: "Playlist", refusal: refusal,
                pieces: pieces, onAdmit: onAdmit, onNotNow: onNotNow)
                .frame(maxWidth: .infinity, maxHeight: .infinity)),
            size: CGSize(width: 520, height: 400))
        windows.append(window)
        pump(0.2)
        return window
    }

    // MARK: - What it says

    func test_theSheetNamesTheDeviceTheBookAndWhatIsWaiting() throws {
        let window = mount(request())
        let texts = try axTexts(in: window)

        XCTAssertTrue(
            texts.contains { $0.contains("Denver’s iPhone") && $0.contains("Playlist") },
            "the title names the device and the book: \(texts)")
        XCTAssertTrue(texts.contains { $0.contains("14 notes waiting") },
                      "and how much of its history is held: \(texts)")
    }

    func test_theSheetShowsTheCodeTheDeviceShowsForItself() throws {
        let window = mount(request())
        let texts = try axTexts(in: window)

        XCTAssertTrue(texts.contains { $0.contains(DeviceCode.short(phone)) },
                      "the code is on screen to be compared: \(texts)")
        XCTAssertTrue(texts.contains { $0.contains("Settings") },
                      "and it says where the other screen is: \(texts)")
    }

    func test_theSheetDrawsTheLabelFieldProposingTheDevicesOwnName() throws {
        let window = mount(request())

        let fields = collect(NSTextField.self, in: window)
            .filter { $0.isEditable }
        XCTAssertFalse(fields.isEmpty, "there is a label field to type in")
        XCTAssertTrue(fields.contains { $0.stringValue == "Denver’s iPhone" },
                      "proposing what the device calls itself: "
                      + "\(fields.map(\.stringValue))")
    }

    /// **Read through `axMenuControl`, because this menu's words are not where
    /// a label is.** On macOS 27 the explicit `.accessibilityLabel` arrives as
    /// an EMPTY `accessibilityLabel` beside an `NSAttributedString`
    /// `accessibilityTitle`, so `axTexts` — which reads values and labels, and
    /// casts both `as? String` — is blind to it: the one attribute it does not
    /// read, in the one type it cannot cast. The helper knows both spellings,
    /// which is what lets the same call serve this menu and the pass ladder's
    /// pickers (macOS 27 shell slice, Task 4).
    func test_theSheetOffersTheLabelsThisBookAlreadyKnows() throws {
        let window = mount(request())

        let found = try axMenuControl(AdmissionSheet.knownLabelsIdentifier, in: window)
        let published = try axIdentifiers(in: window)
        let control = try XCTUnwrap(
            found, "the picker is not drawn. Identifiers on the sheet: \(published)")
        XCTAssertEqual(control.role, "AXMenuButton",
                       "published as \(control.role ?? "nothing")")
        XCTAssertEqual(control.reading, AdmissionSheet.knownLabelsTitle,
                       "and it says what it is for")
        XCTAssertEqual(control.isEnabled, true, "and it can be opened")
    }

    func test_withNoOtherLabelsThePickerIsNotDrawn() throws {
        let window = mount(request(knownLabels: []))

        let found = try axMenuControl(AdmissionSheet.knownLabelsIdentifier, in: window)
        XCTAssertNil(
            found,
            "an empty menu is a control that explains nothing, and this sheet "
            + "drew one anyway")
    }

    func test_bothButtonsAreDrawn() throws {
        let window = mount(request())
        let labels = try axButtonLabels(in: window)

        XCTAssertTrue(labels.contains(AdmissionSheet.admitTitle), "\(labels)")
        XCTAssertTrue(labels.contains(AdmissionSheet.notNowTitle), "\(labels)")
    }

    func test_aRefusalStaysOnTheSheetInItsOwnWords() throws {
        let sentence = AdmissionDecision.refusal(RegistryAdmissionError.notARoot)
        let window = mount(request(), refusal: sentence)
        let texts = try axTexts(in: window)

        // In the writer's words, not the registry's (Denver's wording ruling,
        // 2026-09-18): the refusal says where to go, not what a root is.
        XCTAssertTrue(texts.contains { $0.contains("started on") },
                      "the sheet stays up carrying what went wrong: \(texts)")
        XCTAssertTrue(try axButtonLabels(in: window).contains(AdmissionSheet.admitTitle),
                      "and the writer can try again")
    }

    // MARK: - The verbs, called directly

    /// The closure the host supplies is what a press runs. Asserting it by
    /// CALLING it — rather than by pressing a mounted button and waiting — is
    /// tripwire 33's rule: the wiring is a closure append, and a window between
    /// the call and the answer only adds a way for the test to flake.
    func test_admitHandsBackWhatWasTyped() {
        var handed: [String] = []
        var permits: [Permit] = []
        let sheet = AdmissionSheet(
            request: request(), projectTitle: "Playlist",
            onAdmit: { handed.append($0); permits.append($1) }, onNotNow: {})

        sheet.onAdmit("Amelia", PermitControl.permit(for: .reviewer, pieces: []))

        XCTAssertEqual(handed, ["Amelia"])
        // **And what they may write** (P3b Task 4): the label alone was the
        // whole answer until the sheet gained a rung.
        XCTAssertEqual(permits, [.reviewer])
    }

    func test_notNowRunsItsOwnVerbAndNoOther() {
        var admitted = 0
        var dismissed = 0
        let sheet = AdmissionSheet(
            request: request(), projectTitle: "Playlist",
            onAdmit: { _, _ in admitted += 1 }, onNotNow: { dismissed += 1 })

        sheet.onNotNow()

        XCTAssertEqual(dismissed, 1)
        XCTAssertEqual(admitted, 0, "Not now writes nothing")
    }

    // MARK: - What they may write (P3b Task 4)

    /// The control is DRAWN; what each rung means is pinned windowlessly in
    /// `PermitControlTests` (tripwire 33 — nothing here presses it).
    func test_theSheetDrawsTheControlForWhatTheyMayWrite() throws {
        let window = mount(request())

        let found = try axMenuControl(PermitPicker.choiceIdentifier, in: window)
        let published = try axIdentifiers(in: window)
        XCTAssertNotNil(
            found,
            "the sheet asks for a label and nothing about what may be written. "
            + "Identifiers on the sheet: \(published)")
        let texts = try axTexts(in: window)
        XCTAssertTrue(
            texts.contains { $0.contains(PermitControl.Choice.wholeBook.explanation) },
            "and says what the chosen rung means: \(texts)")
    }

    /// **Admit waits for the book, and only where the rung narrows it** — the
    /// first-narrowing sentence is something the writer is owed BEFORE they
    /// press, not after. Both directions, and the dead end: a book this Mac
    /// cannot read answers nothing, and the press must still be possible,
    /// because the act itself refuses in its own words.
    func test_admitWaitsForTheBookOnlyWhereTheRungNarrowsIt() {
        XCTAssertTrue(
            AdmissionSheet.admitWaits(whileNarrowing: true, asked: false),
            "a narrowing rung, and nothing asked yet")
        XCTAssertFalse(
            AdmissionSheet.admitWaits(whileNarrowing: true, asked: true),
            "asked — whatever the answer was, including none at all")
        XCTAssertFalse(
            AdmissionSheet.admitWaits(whileNarrowing: false, asked: false),
            "the ordinary admission waits for nothing")
    }

    /// **The default is the whole book** — what every admission meant before
    /// this milestone. A writer who reads none of this and presses Admit makes
    /// exactly the admission P2b made.
    func test_theSheetOpensOnTheAdmissionItAlwaysMade() throws {
        let window = mount(request())
        let texts = try axTexts(in: window)

        XCTAssertTrue(
            texts.contains { $0.contains(PermitControl.Choice.wholeBook.explanation) },
            "\(texts)")
        XCTAssertFalse(
            texts.contains { $0.contains("no longer open this book") },
            "and nothing that narrows nobody warns about narrowing: \(texts)")
    }

    // MARK: - The copy itself

    func test_oneWaitingNoteIsSingular() {
        XCTAssertEqual(AdmissionSheet.waitingLine(count: 1), "1 note waiting")
        XCTAssertEqual(AdmissionSheet.waitingLine(count: 2), "2 notes waiting")
    }

    func test_aDeviceWithNoNameIsTitledByItsCode() {
        let title = AdmissionSheet.title(
            request: request(ownName: nil), projectTitle: "Playlist")

        XCTAssertTrue(title.contains(DeviceCode.short(phone)), title)
        XCTAssertTrue(title.contains("Playlist"), title)
    }
}
