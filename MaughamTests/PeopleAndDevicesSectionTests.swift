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
        absent: Bool = true,
        damaged: MalformedRecord? = nil,
        restorable: Set<RecordRef> = []
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
                : [],
            malformed: damaged.map { [$0] } ?? [])
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
            restorable: restorable,
            standing: standing,
            me: root)
    }

    private func mount(
        _ model: PeopleAndDevicesModel,
        admit: @escaping () -> Void = {},
        forget: @escaping (String) -> Void = { _ in },
        claim: ClaimOffer? = nil,
        notice: String? = nil
    ) -> NSWindow {
        let window = TestWindow.mount(
            AnyView(
                Form {
                    PeopleAndDevicesSection(
                        model: model, admit: admit, forget: forget,
                        claim: claim, notice: notice)
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
        // The header names no device (smoke find 2) and speaks in the writer's
        // words rather than the registry's (Denver's wording ruling,
        // 2026-09-18): the person row and the device row under it both name
        // this Mac already, and a third naming had one machine read as three.
        XCTAssertTrue(texts.contains { $0.contains("This book was started on this Mac") },
                      "and says what this Mac is, without naming it: \(texts)")
        XCTAssertTrue(texts.contains { $0.contains("Its code is") },
                      "and the code line reads as this Mac's: \(texts)")
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

    func test_eachPersonIsDrawnWithTheirLabelRoleAndDevice() throws {
        let window = mount(model())
        let texts = try axTexts(in: window)

        // **The label alone; the machine is the row beneath** (Denver's
        // re-smoke, 2026-09-19). Under P2 a person is one device, so a
        // bracketed own name here is the nested row's words said twice.
        XCTAssertTrue(texts.contains { $0 == "Amelia" },
                      "the person's label, unbracketed: \(texts)")
        XCTAssertFalse(texts.contains { $0.contains("Amelia (") },
                       "and not the machine's name beside it: \(texts)")
        XCTAssertTrue(texts.contains { $0.contains("Denver's iPhone") },
                      "which the device row beneath carries: \(texts)")
        XCTAssertTrue(texts.contains { $0.contains("author") },
                      "the role, read-only: \(texts)")
        // The root's PERSON row is marked *you*; *this Mac* is the device row's
        // badge (smoke find 2), and both are drawn.
        XCTAssertTrue(texts.contains { $0 == "you" },
                      "the root's own person row is marked: \(texts)")
        XCTAssertTrue(texts.contains { $0 == "this Mac" },
                      "and the machine badge is on the device row: \(texts)")
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
    func test_revokeIsLiveOnTheDeviceThisMacAdmittedAndAbsentOnTheRoot() throws {
        let window = mount(model())

        let labels = try axButtonLabels(in: window)
        let buttons = try axButtons(labelled: "Revoke", in: window)
        // **One, not two** (P2 smoke find 2). The root's row used to carry a
        // disabled Revoke saying *a root is claimed over, never revoked* — a
        // control that could not come alive on any folder, on any day, sitting
        // beside the writer's own name.
        XCTAssertEqual(buttons.count, 1, "the root's row draws none: \(labels)")
        XCTAssertEqual(buttons.filter { axEnabled($0) == true }.count, 1,
                       "and the one that is drawn is the one this Mac may press")
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
    /// **Said once, in the footer** (Denver's re-smoke, 2026-09-19). It used to
    /// be drawn again under every revocable person's row, so a pane with two
    /// people told the writer to remove a device from the iCloud share three
    /// times on one screen. The footer is a fact about what this whole section
    /// can and cannot do; a row is about one person.
    func test_theShareSentenceIsSaidOnceInTheWholeSection() throws {
        let window = mount(model())
        let texts = try axTexts(in: window)

        XCTAssertEqual(
            texts.filter { $0.contains("remove it from the iCloud share") }.count, 1,
            "once, and in the footer: \(texts)")
        XCTAssertTrue(
            texts.contains { $0.contains("Removing a device here stops Maugham applying") },
            "and it is the footer's spelling that survived: \(texts)")
    }

    /// A refusal is drawn where the writer pressed, in the verb's own words.
    func test_arefusedVerbSaysSoInTheSection() throws {
        let window = mount(
            model(), notice: AdmissionDecision.refusal(RegistryAdmissionError.notARoot))
        let texts = try axTexts(in: window)

        XCTAssertTrue(
            texts.contains { $0.contains("wasn\u{2019}t started on this Mac") },
            "the refusal reaches the writer, in the writer's words: \(texts)")
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
            texts.contains { $0.contains("keeps the book you started") },
            "and the row says what a merge is not — neither Mac gives way: \(texts)")
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
        // **None at all** as of smoke find 2: the revoked row carries Re-admit
        // in Revoke's place, and the root's row — which used to carry a dead
        // Revoke saying *a root is claimed over, never revoked* — carries none.
        XCTAssertTrue(
            try axButtons(labelled: "Revoke", in: window).isEmpty,
            "the revoked row has the way back instead, and a root offers no Revoke")
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

    /// Rename hands back the WHOLE row, not a fingerprint: the alert starts
    /// its field at the name that stands, and the row is the only thing that
    /// knows it (smoke find 3).
    func test_renameHandsBackTheRowSoTheFieldCanStartAtTheNameThatStands() throws {
        var renamed: [String] = []
        let drawn = model()
        let section = PeopleAndDevicesSection(
            model: drawn, rename: { renamed.append($0.label) })

        section.renameForTesting(try XCTUnwrap(drawn.people.first))

        XCTAssertEqual(renamed, [try XCTUnwrap(drawn.people.first).label])
    }

    /// Drawn on every person row, live on the ones this Mac admitted — which
    /// includes its own root row, the row the smoke was about.
    func test_renameIsDrawnOnEveryPersonRowAndLiveOnThisMacs() throws {
        let window = mount(model())

        let buttons = try axButtons(labelled: "Rename\u{2026}", in: window)
        XCTAssertEqual(buttons.count, 2, "one per person")
        XCTAssertEqual(buttons.filter { axEnabled($0) == true }.count, 2,
                       "this Mac is the root that admitted both, itself included")
    }

    // MARK: - Records that don't verify (P2 smoke find 1)

    /// The section a refused record had nowhere to appear in: its name, which
    /// of the three kinds it is, and the reader's own sentence for what is
    /// wrong with it.
    func test_arecordThatDoesNotVerifyIsDrawnWithItsReason() throws {
        let window = mount(model(damaged: MalformedRecord(
            url: URL(fileURLWithPath: "/Book/.maugham/people/\(phone).json"),
            reason: .signatureDoesNotVerify)))
        let texts = try axTexts(in: window)

        XCTAssertTrue(texts.contains { $0.contains("Records that don\u{2019}t verify") },
                      "the section names itself: \(texts)")
        XCTAssertTrue(
            texts.contains { $0.contains("person record") && $0.contains("changed after it was signed") },
            "with the reader's own reason: \(texts)")
    }

    /// Restore is drawn only where this Mac holds bytes that verified; where it
    /// does not, the row says so instead of offering a press that cannot work.
    func test_restoreIsDrawnOnlyWhereThereIsSomethingToPutBack() throws {
        let ref = RecordRef(directory: .people, fingerprint: phone)
        let fault = MalformedRecord(
            url: URL(fileURLWithPath: "/Book/.maugham/people/\(phone).json"),
            reason: .signatureDoesNotVerify)

        let without = mount(model(damaged: fault))
        XCTAssertTrue(try axButtons(labelled: "Restore", in: without).isEmpty)
        XCTAssertTrue(
            try axTexts(in: without).contains { $0.contains("can\u{2019}t put one back") },
            "and says why there is no button")

        let with = mount(model(damaged: fault, restorable: [ref]))
        XCTAssertEqual(try axButtons(labelled: "Restore", in: with).count, 1)
    }

    /// Called directly rather than pressed (tripwire 33): Restore hands back
    /// the whole row, because a record is a directory AND a fingerprint.
    func test_restoreHandsBackTheRecordItIsAbout() throws {
        let ref = RecordRef(directory: .people, fingerprint: phone)
        let drawn = model(
            damaged: MalformedRecord(
                url: URL(fileURLWithPath: "/Book/.maugham/people/\(phone).json"),
                reason: .signatureDoesNotVerify),
            restorable: [ref])
        var restored: [RecordRef] = []
        let section = PeopleAndDevicesSection(
            model: drawn, restore: { restored.append($0.ref) })

        section.restoreForTesting(try XCTUnwrap(drawn.unverifiable.first))

        XCTAssertEqual(restored, [ref])
    }

    // MARK: - This book is mine (P3b smoke find F3)

    /// Where `ClaimDecision` offers the claim — a Mac on no chain here — the
    /// verb is drawn, live, with the sentence telling an invited collaborator
    /// it is not for them.
    func test_theClaimVerbIsDrawnWhereItIsOffered() throws {
        let window = mount(
            model(), claim: ClaimOffer(roots: [claimant], names: ["Denver's old MacBook"]))
        let buttons = try axButtons(labelled: ClaimDecision.verbTitle, in: window)
        let texts = try axTexts(in: window)

        let labels = try axButtonLabels(in: window)
        XCTAssertFalse(buttons.isEmpty, "\(labels)")
        for button in buttons { XCTAssertEqual(axEnabled(button), true) }
        XCTAssertTrue(texts.contains { $0.contains("If somebody invited you") }, "\(texts)")
    }

    /// And absent where it is not — a Mac on a root, the model's own fixture.
    func test_theClaimVerbIsAbsentWhereItIsNotOffered() throws {
        let window = mount(model(), claim: nil)

        XCTAssertTrue(try axButtons(labelled: ClaimDecision.verbTitle, in: window).isEmpty)
    }

    func test_theClaimVerbAsksTheHostToConfirm() {
        var asked = 0
        let section = PeopleAndDevicesSection(
            model: model(),
            claim: ClaimOffer(roots: [claimant], names: []),
            claimBook: { asked += 1 })

        section.claimBook()

        XCTAssertEqual(asked, 1)
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
    func renameForTesting(_ person: PeopleAndDevicesModel.Person) { rename(person) }
    func restoreForTesting(_ record: PeopleAndDevicesModel.Unverifiable) { restore(record) }
}

/// **The P3b rows and controls reach the screen** (signed op log P3b Task 5).
///
/// What each one MEANS is pinned windowlessly in
/// `PeopleAndDevicesPermitRowTests`; this suite's whole job is that they are
/// drawn. Nothing here presses a control and waits for its effect (tripwire
/// 33): the verbs are closures the host supplies and are called directly, and
/// what is on screen is asserted as text and enabled-ness alone.
@MainActor
final class PeopleAndDevicesPermitSectionTests: XCTestCase {

    private var windows: [NSWindow] = []

    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    override func tearDown() async throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
    }

    private var rootIdentity: DeviceIdentity!
    private var root: String { rootIdentity.fingerprint }
    private let phone = "cccc3333dddd4444"
    private let contested = "aaaa1111aaaa1111"

    override func setUp() async throws {
        rootIdentity = .softwareForTesting()
    }

    private let made = Date(timeIntervalSince1970: 1_756_000_000)
    private let admitted = Date(timeIntervalSince1970: 1_757_000_000)

    private let pieces = [PermitControl.Piece(id: "ch4", title: "Chapter 4")]

    private func model(
        phonePermit: Permit = .author(.pieces(["ch4"])),
        events: [PermitEvent] = [],
        held: [String: Int] = [:],
        heldStreams: [String: Set<String>] = [:],
        unsignedStreams: [String] = [],
        malformed: [MalformedRecord] = [],
        // Two device records naming ONE assistant key: `Registry
        // .actorKeyOwners` drops a key two records claim, so it belongs to
        // nobody and nobody can be admitted for it.
        disputingAKey: Bool = false
    ) -> PeopleAndDevicesModel {
        let disputed = disputingAKey ? ["assistant": contested] : [:]
        let registry = Registry(
            devices: [
                DeviceRecord(device: root, name: "Denver's MacBook", kind: .mac,
                             actors: ["author": root].merging(
                                disputed, uniquingKeysWith: { _, new in new }),
                             madeAt: made),
                DeviceRecord(device: phone, name: "Denver's iPhone", kind: .phone,
                             actors: ["author": phone].merging(
                                disputed, uniquingKeysWith: { _, new in new }),
                             madeAt: made),
            ],
            people: [
                PersonRecord(person: root, label: "Denver",
                             ownName: "Denver's MacBook",
                             admittedAt: admitted, admittedBy: root),
                PersonRecord(person: phone, label: "Sam", ownName: "Denver's iPhone",
                             role: phonePermit.wireRole,
                             scope: phonePermit.wireScope,
                             pieces: phonePermit.wirePieces,
                             admittedAt: admitted, admittedBy: root),
            ],
            events: events,
            malformed: malformed)
        let table = TrustTable.resolve(
            registry: registry, mine: .forAuthor(rootIdentity), joinedRoot: nil)
        return PeopleAndDevicesModel.make(
            registry: registry, table: table, remembered: [:],
            requests: AdmissionDecision.requests(
                pending: held, streams: heldStreams, registry: registry,
                memory: [:], myRoot: table.myRoot),
            claimants: [],
            standing: DeviceStanding(
                code: DeviceCode.short(root), label: "Denver",
                rootLabel: "Denver", admitted: true, isRoot: true),
            me: root, held: held, heldStreams: heldStreams,
            unsignedStreams: unsignedStreams, pieces: pieces)
    }

    private func mount(_ model: PeopleAndDevicesModel) -> NSWindow {
        let window = TestWindow.mount(
            AnyView(
                Form {
                    PeopleAndDevicesSection(model: model)
                }
                .formStyle(.grouped)
                .frame(maxWidth: .infinity, maxHeight: .infinity)),
            size: CGSize(width: 560, height: 800))
        windows.append(window)
        pump(0.2)
        return window
    }

    // MARK: - What they may write, and the control that changes it

    func test_apersonsRowDrawsWhatTheyMayWriteAndTheControlThatChangesIt() throws {
        let window = mount(model())
        let texts = try axTexts(in: window)

        XCTAssertTrue(texts.contains { $0.contains("Author of some pieces") },
                      "the rung, in the words the control uses: \(texts)")
        XCTAssertTrue(texts.contains { $0.contains("Chapter 4") },
                      "and the pieces, by title: \(texts)")
        let labels = try axButtonLabels(in: window)
        XCTAssertTrue(labels.contains { $0.hasPrefix("Change") },
                      "with the control that moves it: \(labels)")
    }

    /// The root's own row draws no change control at all — it is not a disabled
    /// button, it is absent, because the condition it would wait on can never
    /// come (spec §2).
    func test_therootsOwnRowDrawsExactlyOneChangeControlForTheOtherPerson() throws {
        let window = mount(model())
        let labels = try axButtonLabels(in: window)

        XCTAssertEqual(labels.filter { $0.hasPrefix("Change") }.count, 1,
                       "one person here can be changed, and it is not the root: \(labels)")
    }

    /// Spec §3.2's crash window, and the one press that closes it.
    func test_arecordAStepBehindItsHistoryIsDrawnWithItsRepair() throws {
        let window = mount(model(events: [PermitEvent(
            event: "e-0001", kind: .roleChanged, subject: phone,
            role: Permit.reviewerRole, scope: Permit.bookScope, pieces: [],
            mark: [:], at: admitted, by: root)]))
        let texts = try axTexts(in: window)

        XCTAssertTrue(texts.contains { $0.contains("a step behind") },
                      "the disagreement is stated: \(texts)")
        let labels = try axButtonLabels(in: window)
        XCTAssertTrue(labels.contains("Re-sign"), "with the press: \(labels)")
    }

    // MARK: - The rows that had no voice

    func test_astreamNothingSignsIsDrawnWithWhatNarrowingWillDo() throws {
        let window = mount(model(unsignedStreams: [DeviceSlug.make(
            from: DeviceIdentity.deviceId(
                actor: "author", fingerprint: String(repeating: "5a", count: 32))).raw]))
        let texts = try axTexts(in: window)

        XCTAssertTrue(texts.contains { $0.contains("says who signs for") },
                      "what is true now: \(texts)")
        XCTAssertTrue(texts.contains { $0.contains("waits on the other Macs") },
                      "and what narrowing will do, before there is a reviewer: \(texts)")
    }

    /// **The released book's pane, drawn** (v0.41.1): one writer whose second
    /// record has no device record, beside pre-signing history. The label is
    /// on screen ONCE, the phone is a device row saying the book has no
    /// description of it, and the old streams are one row — no *who signs
    /// for* line at all.
    func test_oneWriterWithAnUnseenDeviceAndOlderHistoryIsDrawnAsOnePerson() throws {
        let phoneKey = "0ecb0ecb0ecb0ecb"
        let registry = Registry(
            devices: [DeviceRecord(device: root, name: "Denver's MacBook Air",
                                   kind: .mac, actors: ["author": root], madeAt: made)],
            people: [
                PersonRecord(person: root, label: "Denver Trouton",
                             ownName: "Denver's MacBook Air",
                             admittedAt: made, admittedBy: root),
                PersonRecord(person: phoneKey, label: "Denver Trouton",
                             ownName: DeviceCode.short(phoneKey),
                             admittedAt: admitted, admittedBy: root),
            ])
        let table = TrustTable.resolve(
            registry: registry, mine: .forAuthor(rootIdentity), joinedRoot: nil)
        let model = PeopleAndDevicesModel.make(
            registry: registry, table: table, remembered: [:], requests: [],
            claimants: [],
            standing: DeviceStanding(
                code: DeviceCode.short(root), label: "Denver Trouton",
                rootLabel: "Denver Trouton", admitted: true, isRoot: true),
            me: root,
            unsignedStreams: [DeviceSlug.make(from: "mcp").raw,
                              HeldLines.oldestHistoryStream])
        let window = mount(model)
        let texts = try axTexts(in: window)

        XCTAssertEqual(texts.filter { $0 == "Denver Trouton" }.count, 1,
                       "one person: \(texts)")
        XCTAssertTrue(texts.contains(PeopleAndDevicesModel.UnseenDevice.sentence),
                      "the phone is a device row: \(texts)")
        XCTAssertTrue(texts.contains(PeopleAndDevicesModel.OlderHistory.title),
                      "older history is one row: \(texts)")
        XCTAssertFalse(texts.contains { $0.contains("who signs for") },
                       "and no warning per old stream: \(texts)")
    }

    func test_acontestedKeyIsDrawnWithNoControlToPress() throws {
        let window = mount(model(held: [contested: 4], disputingAKey: true))
        let texts = try axTexts(in: window)

        XCTAssertTrue(texts.contains { $0.contains("4 lines waiting") },
                      "the fact has a size: \(texts)")
        let labels = try axButtonLabels(in: window)
        XCTAssertFalse(labels.contains { $0.hasPrefix("Admit") },
                       "and nothing to press about it: \(labels)")
    }

    /// F4's press, and the sentence that says what it is not.
    func test_thismacsOwnUnrestorableRecordDrawsWriteItAgain() throws {
        let window = mount(model(malformed: [MalformedRecord(
            url: URL(fileURLWithPath: "/Book/.maugham/devices/\(root).json"),
            reason: .signatureDoesNotVerify)]))
        let labels = try axButtonLabels(in: window)

        XCTAssertTrue(labels.contains("Write It Again"), "\(labels)")
        XCTAssertFalse(labels.contains("Restore"),
                       "the two are alternatives: \(labels)")
    }

    /// And somebody else's is a fact with a destination rather than a dead end.
    func test_anotherDevicesUnrestorableRecordNamesTheMacThatCanRepairIt() throws {
        let window = mount(model(malformed: [MalformedRecord(
            url: URL(fileURLWithPath: "/Book/.maugham/devices/\(phone).json"),
            reason: .signatureDoesNotVerify)]))
        let texts = try axTexts(in: window)
        let labels = try axButtonLabels(in: window)

        XCTAssertFalse(labels.contains("Write It Again"), "\(labels)")
        XCTAssertTrue(texts.contains { $0.contains("Open this book there") },
                      "never a dead end: \(texts)")
    }

    // MARK: - The sheet that asks the rung

    /// The control the writer moves is drawn, starting where they already are.
    /// Nothing is pressed and nothing is waited on (tripwire 33).
    func test_thepermitSheetDrawsTheControlAndTheConsequence() throws {
        let person = try XCTUnwrap(model().people.first { $0.fingerprint == phone })
        let window = TestWindow.mount(
            AnyView(PermitChangeSheet(
                person: person, pieces: pieces,
                book: PermitControl.BookNarrowing(),
                isReadmission: false, commit: { _ in }, cancel: {})),
            size: CGSize(width: 480, height: 520))
        windows.append(window)
        pump(0.2)
        let texts = try axTexts(in: window)

        XCTAssertTrue(texts.contains { $0.contains("Change what Sam may write?") },
                      "\(texts)")
        XCTAssertTrue(texts.contains { $0.contains("Author of some pieces") },
                      "the control starts where they already are: \(texts)")
        let labels = try axButtonLabels(in: window)
        XCTAssertTrue(labels.contains("Change"), "\(labels)")
        XCTAssertTrue(labels.contains("Cancel"), "\(labels)")
    }
}
