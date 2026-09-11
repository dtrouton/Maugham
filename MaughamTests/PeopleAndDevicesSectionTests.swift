import XCTest
import SwiftUI
import AppKit
@testable import Maugham
@testable import MaughamCore

/// **People & Devices reaches the screen** (signed op log P2, spec §6).
///
/// What each row MEANS is pinned windowlessly in `PeopleAndDevicesModelTests`;
/// this suite's whole job is that the model's rows, the three controls that are
/// drawn-but-not-yet-wired, and the share sentence are actually drawn. So
/// nothing here presses a control and waits for its effect (tripwire 33): the
/// two live verbs are closures the host supplies and are called directly.
@MainActor
final class PeopleAndDevicesSectionTests: XCTestCase {

    private var windows: [NSWindow] = []

    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    override func tearDown() async throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
    }

    // MARK: - Fixture

    private var rootIdentity: DeviceIdentity!
    private var root: String { rootIdentity.fingerprint }
    private let phone = "cccc3333dddd4444"
    private let stranger = "eeee5555ffff6666"
    private let claimant = "9999777788886666"
    private let absentDevice = "1212343456567878"

    override func setUp() async throws {
        rootIdentity = .softwareForTesting()
    }

    private func model(
        refusal: String? = nil,
        pending: Bool = true,
        claimants: Bool = true,
        merged: Bool = false,
        absent: Bool = true
    ) -> PeopleAndDevicesModel {
        let made = Date(timeIntervalSince1970: 1_756_000_000)
        let admitted = Date(timeIntervalSince1970: 1_757_000_000)
        let registry = Registry(
            devices: [
                DeviceRecord(device: root, name: "Denver's MacBook", kind: .mac,
                             actors: ["author": root, "assistant": "assist-\(root)"],
                             madeAt: made),
                DeviceRecord(device: phone, name: "Denver's iPhone", kind: .phone,
                             actors: ["author": phone], madeAt: made),
                DeviceRecord(device: stranger, name: "The old iPhone", kind: .phone,
                             actors: ["author": stranger], madeAt: made),
            ],
            people: [
                PersonRecord(person: root, label: "Denver", ownName: "Denver's MacBook",
                             admittedAt: admitted, admittedBy: root),
                PersonRecord(person: phone, label: "Amelia", ownName: "Denver's iPhone",
                             admittedAt: admitted, admittedBy: root),
            ],
            claims: merged
                ? [ClaimRecord(newRoot: root, adopted: [claimant], claimedAt: admitted)]
                : [])
        let standing = refusal.map {
            DeviceStanding(code: DeviceCode.short(root), refusal: $0)
        } ?? DeviceStanding(
            code: DeviceCode.short(root), label: "Denver", rootLabel: "Denver",
            admitted: true, isRoot: true)
        return PeopleAndDevicesModel.make(
            registry: registry,
            table: TrustTable.resolve(
                registry: registry, mine: .forAuthor(rootIdentity),
                joinedRoot: nil),
            remembered: absent
                ? [absentDevice: .init(label: "The lost phone", ownName: "iPhone",
                                       labelledAt: admitted)]
                : [:],
            pending: pending ? [stranger: 14] : [:],
            claimants: claimants ? [claimant] : [],
            standing: standing,
            me: root)
    }

    private func mount(
        _ model: PeopleAndDevicesModel,
        admit: @escaping () -> Void = {},
        forget: @escaping (String) -> Void = { _ in }
    ) -> NSWindow {
        let window = TestWindow.mount(
            AnyView(
                Form {
                    PeopleAndDevicesSection(model: model, admit: admit, forget: forget)
                }
                .formStyle(.grouped)
                .frame(maxWidth: .infinity, maxHeight: .infinity)),
            size: CGSize(width: 560, height: 720))
        windows.append(window)
        pump(0.2)
        return window
    }

    // MARK: - What it says

    func test_theSectionIsTitledAndSaysWhatThisMacIs() throws {
        let window = mount(model())
        let texts = try axTexts(in: window)

        XCTAssertTrue(texts.contains { $0.contains("People & Devices") },
                      "the section names itself: \(texts)")
        XCTAssertTrue(texts.contains { $0.contains("the root of this book") },
                      "and says what this Mac is: \(texts)")
        XCTAssertTrue(texts.contains { $0.contains(DeviceCode.short(root)) },
                      "with the code the phone's own screen shows: \(texts)")
    }

    func test_apendingDeviceIsDrawnWithWhatItIsWaitingOn() throws {
        let window = mount(model())
        let texts = try axTexts(in: window)

        XCTAssertTrue(texts.contains { $0.contains("The old iPhone") },
                      "the waiting device is named: \(texts)")
        XCTAssertTrue(texts.contains { $0.contains("14") && $0.contains("waiting") },
                      "and what it is waiting on is said: \(texts)")
        let labels = try axButtonLabels(in: window)
        XCTAssertTrue(labels.contains { $0.hasPrefix("Admit") },
                      "with the one control that asks: \(labels)")
    }

    func test_eachPersonIsDrawnWithTheirOwnNameRoleAndDevice() throws {
        let window = mount(model())
        let texts = try axTexts(in: window)

        XCTAssertTrue(texts.contains { $0.contains("Amelia") && $0.contains("Denver's iPhone") },
                      "the label and the device's own name: \(texts)")
        XCTAssertTrue(texts.contains { $0.contains("author") },
                      "the role, read-only: \(texts)")
        XCTAssertTrue(texts.contains { $0.contains("this Mac") },
                      "and the root is marked: \(texts)")
    }

    func test_theShareSentenceIsDrawn() throws {
        let window = mount(model())
        let texts = try axTexts(in: window)

        XCTAssertTrue(texts.contains { $0.contains("iCloud share") },
                      "the one sentence about what this section cannot do: \(texts)")
    }

    // MARK: - The controls that do not work yet

    /// Drawn, and drawn DISABLED. Hiding them would move everything under them
    /// when the verbs arrive; a live one would promise something no code does.
    func test_revokeAndRetireAreDrawnDisabled() throws {
        let window = mount(model())

        let labels = try axButtonLabels(in: window)
        for label in ["Revoke", "Retire"] {
            let buttons = try axButtons(labelled: label, in: window)
            XCTAssertFalse(buttons.isEmpty, "\(label) is drawn: \(labels)")
            for button in buttons {
                XCTAssertEqual(axEnabled(button), false, "\(label) cannot be pressed")
            }
        }
    }

    func test_aclaimantOffersMergeAndItIsDisabled() throws {
        let window = mount(model())
        let buttons = try axButtons(labelled: "Merge: this is also me", in: window)
        let labels = try axButtonLabels(in: window)

        XCTAssertFalse(buttons.isEmpty, "the claimant's one control: \(labels)")
        for button in buttons {
            XCTAssertEqual(axEnabled(button), false, "merging arrives with Task 8")
        }
    }

    /// A root this device has adopted is a fact, not a question: it is drawn as
    /// merged and offers nothing to press.
    func test_anAdoptedRootIsDrawnAsMergedWithNoControl() throws {
        let window = mount(model(claimants: true, merged: true))
        let texts = try axTexts(in: window)

        XCTAssertTrue(texts.contains { $0.contains("merged") },
                      "the adopted root says what it is: \(texts)")
        XCTAssertTrue(try axButtons(labelled: "Merge: this is also me", in: window).isEmpty,
                      "and asks nothing")
    }

    // MARK: - The two live verbs

    /// Called directly rather than pressed: what the closure does is the host's
    /// business, and a press-then-wait would pin nothing about it (tripwire 33).
    func test_forgetHandsBackTheDeviceItIsAbout() {
        var forgotten: [String] = []
        let section = PeopleAndDevicesSection(
            model: model(), forget: { forgotten.append($0) })

        section.forgetForTesting(absentDevice)

        XCTAssertEqual(forgotten, [absentDevice])
    }

    func test_admitAsksWithoutNamingADevice() {
        var asked = 0
        let section = PeopleAndDevicesSection(model: model(), admit: { asked += 1 })

        section.admitForTesting()

        XCTAssertEqual(asked, 1, "which device is waiting is the window's answer")
    }

    func test_forgetThisDeviceIsDrawnForARememberedButAbsentDevice() throws {
        let window = mount(model())

        let labels = try axButtonLabels(in: window)
        XCTAssertFalse(try axButtons(labelled: "Forget this device", in: window).isEmpty,
                       "the row's one live control: \(labels)")
        XCTAssertTrue(try axTexts(in: window).contains { $0.contains("The lost phone") },
                      "named by what this Mac called it")
    }

    // MARK: - A registry that cannot be read

    func test_anUnreadableRegistryDrawsItsRefusalAndNoRows() throws {
        let window = mount(model(refusal: "people/deadbeef.json is present and unreadable"))
        let texts = try axTexts(in: window)

        XCTAssertTrue(texts.contains { $0.contains("present and unreadable") },
                      "the read's own sentence: \(texts)")
        XCTAssertFalse(texts.contains { $0.contains("The old iPhone") },
                       "and nothing is claimed about who may write: \(texts)")
        XCTAssertTrue(try axButtonLabels(in: window).isEmpty,
                      "no verb over a registry nobody could read")
    }
}

private extension PeopleAndDevicesSection {
    /// Call the forget closure the host supplied, with no window between the
    /// call and the answer (tripwire 33).
    func forgetForTesting(_ fingerprint: String) { forget(fingerprint) }
    func admitForTesting() { admit() }
}
