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
        onAdmit: @escaping (String) -> Void = { _ in },
        onNotNow: @escaping () -> Void = {}
    ) -> NSWindow {
        let window = TestWindow.mount(
            AnyView(AdmissionSheet(
                request: request, projectTitle: "Playlist", refusal: refusal,
                onAdmit: onAdmit, onNotNow: onNotNow)
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

    func test_theSheetOffersTheLabelsThisBookAlreadyKnows() throws {
        let window = mount(request())
        let texts = try axTexts(in: window)

        XCTAssertTrue(texts.contains { $0.contains(AdmissionSheet.knownLabelsTitle) },
                      "the picker is drawn: \(texts)")
    }

    func test_withNoOtherLabelsThePickerIsNotDrawn() throws {
        let window = mount(request(knownLabels: []))
        let texts = try axTexts(in: window)

        XCTAssertFalse(texts.contains { $0.contains(AdmissionSheet.knownLabelsTitle) },
                       "an empty menu is a control that explains nothing: \(texts)")
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

        XCTAssertTrue(texts.contains { $0.contains("root") },
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
        let sheet = AdmissionSheet(
            request: request(), projectTitle: "Playlist",
            onAdmit: { handed.append($0) }, onNotNow: {})

        sheet.onAdmit("Amelia")

        XCTAssertEqual(handed, ["Amelia"])
    }

    func test_notNowRunsItsOwnVerbAndNoOther() {
        var admitted = 0
        var dismissed = 0
        let sheet = AdmissionSheet(
            request: request(), projectTitle: "Playlist",
            onAdmit: { _ in admitted += 1 }, onNotNow: { dismissed += 1 })

        sheet.onNotNow()

        XCTAssertEqual(dismissed, 1)
        XCTAssertEqual(admitted, 0, "Not now writes nothing")
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
