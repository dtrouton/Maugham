import XCTest
import SwiftUI
import AppKit
@testable import Maugham
@testable import MaughamCore

/// **People & Devices reaches the screen** (signed op log P2, spec §6).
///
/// What each row MEANS is pinned windowlessly in `PeopleAndDevicesModelTests`;
/// this suite's whole job is that the model's rows, the controls each row
/// carries — live, and disabled-with-a-reason — and the share sentence are
/// actually drawn. So nothing here presses a control and waits for its effect
/// (tripwire 33): the live verbs are closures the host supplies and are called
/// directly, and what is on screen is asserted as enabled-ness alone.
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
        revokedPhone: Bool = false,
        retiredThisMac: Bool = false,
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
                             madeAt: made,
                             retiredAt: retiredThisMac ? admitted : nil),
                DeviceRecord(device: phone, name: "Denver's iPhone", kind: .phone,
                             actors: ["author": phone], madeAt: made),
                DeviceRecord(device: stranger, name: "The old iPhone", kind: .phone,
                             actors: ["author": stranger], madeAt: made),
            ],
            people: [
                PersonRecord(person: root, label: "Denver", ownName: "Denver's MacBook",
                             admittedAt: admitted, admittedBy: root),
                PersonRecord(person: phone, label: "Amelia", ownName: "Denver's iPhone",
                             admittedAt: admitted, admittedBy: root,
                             revokedAt: revokedPhone ? admitted : nil,
                             revokedBy: revokedPhone ? root : nil),
            ],
            claims: merged
                ? [ClaimRecord(newRoot: root, adopted: [claimant], claimedAt: admitted)]
                : [])
        let standing = refusal.map {
            DeviceStanding(code: DeviceCode.short(root), refusal: $0)
        } ?? DeviceStanding(
            code: DeviceCode.short(root), label: "Denver", rootLabel: "Denver",
            admitted: true, isRoot: true)
        let table = TrustTable.resolve(
            registry: registry, mine: .forAuthor(rootIdentity), joinedRoot: nil)
        let remembered: [String: AdmissionMemory.Label] = absent
            ? [absentDevice: .init(label: "The lost phone", ownName: "iPhone",
                                   labelledAt: admitted)]
            : [:]
        return PeopleAndDevicesModel.make(
            registry: registry,
            table: table,
            remembered: remembered,
            requests: AdmissionDecision.requests(
                pending: pending ? [stranger: 14] : [:], registry: registry,
                memory: remembered, myRoot: table.myRoot),
            claimants: claimants ? [claimant] : [],
            standing: standing,
            me: root)
    }

    private func mount(
        _ model: PeopleAndDevicesModel,
        admit: @escaping () -> Void = {},
        forget: @escaping (String) -> Void = { _ in },
        notice: String? = nil
    ) -> NSWindow {
        let window = TestWindow.mount(
            AnyView(
                Form {
                    PeopleAndDevicesSection(
                        model: model, admit: admit, forget: forget, notice: notice)
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

    // MARK: - Revoke and Retire (P2b Task 7)

    /// **Both are drawn on every row, and live on the rows where this Mac may
    /// act.** Two people here: this Mac's own root record, which is claimed
    /// over rather than revoked, and the phone it admitted, which it may. Two
    /// devices: this Mac, which may retire itself, and the phone, which is not
    /// this Mac's to retire.
    ///
    /// Enabled-ness only — nothing is pressed and nothing is waited on
    /// (tripwire 33); what the verbs DO is pinned on the closures below and on
    /// `RegistryAdmission` in the package suite.
    func test_revokeIsLiveOnTheDeviceThisMacAdmittedAndRefusedOnTheRoot() throws {
        let window = mount(model())

        let labels = try axButtonLabels(in: window)
        let buttons = try axButtons(labelled: "Revoke", in: window)
        XCTAssertEqual(buttons.count, 2, "one per person: \(labels)")
        let enabled = buttons.filter { axEnabled($0) == true }
        XCTAssertEqual(enabled.count, 1,
                       "the admitted phone may be revoked; the root may not")
    }

    func test_retireIsLiveOnThisMacsOwnRowAlone() throws {
        let window = mount(model())

        let buttons = try axButtons(labelled: "Retire", in: window)
        XCTAssertEqual(buttons.count, 2, "one per device")
        XCTAssertEqual(buttons.filter { axEnabled($0) == true }.count, 1,
                       "a device signs its own retirement")
    }

    /// Spec §5's sentence, beside the button that earns it: what Revoke does,
    /// and the thing it does not do.
    func test_theRevokeSentenceSaysWhatItDoesNotDo() throws {
        let window = mount(model())
        let texts = try axTexts(in: window)

        XCTAssertTrue(
            texts.contains { $0.contains("stops Maugham applying what this device writes") },
            "\(texts)")
        XCTAssertTrue(texts.contains { $0.contains("remove it from the iCloud share") })
    }

    /// A refusal is drawn where the writer pressed, in the verb's own words.
    func test_arefusedVerbSaysSoInTheSection() throws {
        let window = mount(
            model(), notice: AdmissionDecision.refusal(RegistryAdmissionError.notARoot))
        let texts = try axTexts(in: window)

        XCTAssertTrue(texts.contains { $0.contains("root") && $0.contains("started the book") },
                      "the refusal reaches the writer: \(texts)")
    }

    /// **Live as of Task 8.** A claimant is another root that names this
    /// device, and the writer is the only one who can say whether that root is
    /// also them.
    func test_aclaimantOffersMergeAndItIsLive() throws {
        let window = mount(model())
        let buttons = try axButtons(labelled: "Merge: this is also me", in: window)
        let labels = try axButtonLabels(in: window)
        let texts = try axTexts(in: window)

        XCTAssertFalse(buttons.isEmpty, "the claimant's one control: \(labels)")
        for button in buttons {
            XCTAssertEqual(axEnabled(button), true, "merging shipped with Task 8")
        }
        XCTAssertTrue(
            texts.contains { $0.contains("keep their own root") },
            "and the row says what a merge is not — neither root gives way: \(texts)")
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

    // MARK: - The way back, and the retirement fact (fix round 1)

    /// A revoked row carries **Re-admit** where it carried a dead Revoke: a
    /// disabled button reading "Already revoked" restated the line above it and
    /// could never act, and the way back belongs in that space.
    func test_arevokedRowCarriesReadmitInPlaceOfADeadRevoke() throws {
        let window = mount(model(revokedPhone: true))

        let labels = try axButtonLabels(in: window)
        XCTAssertFalse(try axButtons(labelled: "Re-admit", in: window).isEmpty,
                       "the way back is drawn: \(labels)")
        XCTAssertEqual(
            try axButtons(labelled: "Revoke", in: window).count, 1,
            "the root's own row still carries its refused Revoke, the revoked row does not")
    }

    /// And it is LIVE — the one control on this section that undoes something.
    func test_readmitIsPressableAndHandsBackWhoItIsAbout() throws {
        let model = model(revokedPhone: true)
        var readmitted: [String] = []
        let section = PeopleAndDevicesSection(
            model: model, readmit: { readmitted.append($0.fingerprint) })
        let person = try XCTUnwrap(model.people.first { $0.fingerprint == phone })

        section.readmitForTesting(person)

        XCTAssertEqual(readmitted, [phone])
    }

    /// **The machine that retired is told what retirement means** — on its own
    /// row, in `DeviceStanding`'s own words.
    func test_thismacsRetiredRowSaysWhatItStillDoesAndWhatNobodyElseDoes() throws {
        let window = mount(model(retiredThisMac: true))
        let texts = try axTexts(in: window)

        XCTAssertTrue(
            texts.contains { $0.contains("retired on") && $0.contains("set aside everywhere else") },
            "\(texts)")
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

    /// Each verb hands back the fingerprint it is about — the PERSON's for
    /// Revoke, the DEVICE's for Retire, which under labels-only are the same
    /// key and are not the same argument.
    /// The third live verb hands back the claimant ROOT it is about — never
    /// this device's own root, and never a device inside that chain.
    func test_mergeHandsBackTheRootItIsAbout() {
        var merged: [String] = []
        let section = PeopleAndDevicesSection(
            model: model(), merge: { merged.append($0) })

        section.mergeForTesting(claimant)

        XCTAssertEqual(merged, [claimant])
    }

    func test_revokeAndRetireHandBackWhatTheyAreAbout() {
        var revoked: [String] = []
        var retired: [String] = []
        let section = PeopleAndDevicesSection(
            model: model(), revoke: { revoked.append($0) }, retire: { retired.append($0) })

        section.revokeForTesting(phone)
        section.retireForTesting(root)

        XCTAssertEqual(revoked, [phone])
        XCTAssertEqual(retired, [root])
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
    func revokeForTesting(_ fingerprint: String) { revoke(fingerprint) }
    func retireForTesting(_ fingerprint: String) { retire(fingerprint) }
    func readmitForTesting(_ person: PeopleAndDevicesModel.Person) { readmit(person) }
    func mergeForTesting(_ fingerprint: String) { merge(fingerprint) }
}
