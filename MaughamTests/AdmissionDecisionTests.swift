// MaughamTests/AdmissionDecisionTests.swift
import XCTest
@testable import MaughamCore
@testable import Maugham

/// **What the admission sheet would say, decided with no window at all**
/// (signed op log P2b, spec §4.1–4.2).
///
/// Every sentence and every button's meaning is a value here, so the suite that
/// mounts the sheet only has to prove it DRAWS them — no test presses a control
/// and waits to find out what admission means (tripwire 33).
final class AdmissionDecisionTests: XCTestCase {

    private let root = "aaaa1111"
    private let phone = "ffff2222"
    private let other = "bbbb3333"

    // MARK: - Fixtures

    private func person(
        _ fingerprint: String, label: String, ownName: String = "A device",
        admittedBy: String
    ) -> PersonRecord {
        PersonRecord(
            person: fingerprint, label: label, ownName: ownName,
            admittedAt: Date(timeIntervalSince1970: 10), admittedBy: admittedBy)
    }

    private func device(_ fingerprint: String, name: String, kind: DeviceKind = .phone)
        -> DeviceRecord
    {
        DeviceRecord(
            device: fingerprint, name: name, kind: kind,
            actors: [DeviceActor.author.rawValue: fingerprint],
            madeAt: Date(timeIntervalSince1970: 5))
    }

    private func rootedRegistry(
        devices: [DeviceRecord] = [], people: [PersonRecord] = []
    ) -> Registry {
        Registry(
            devices: devices,
            people: [person(root, label: "Denver", ownName: "Denver’s MacBook",
                            admittedBy: root)] + people)
    }

    // MARK: - One request per stranger

    func test_theRequestProposesTheDevicesOwnNameAndCarriesItsCode() {
        let registry = rootedRegistry(devices: [device(phone, name: "Denver’s iPhone")])

        let requests = AdmissionDecision.requests(
            pending: [phone: 14], registry: registry, memory: [:], myRoot: root)

        XCTAssertEqual(requests.count, 1)
        let request = requests.first
        XCTAssertEqual(request?.fingerprint, phone)
        XCTAssertEqual(request?.ownName, "Denver’s iPhone")
        XCTAssertEqual(request?.proposedLabel, "Denver’s iPhone",
                       "the ordinary answer to what shall I call this is what it calls itself")
        XCTAssertEqual(request?.waitingCount, 14)
        XCTAssertEqual(request?.code, DeviceCode.short(phone))
        XCTAssertEqual(request?.displayName, "Denver’s iPhone")
    }

    func test_aStrangerWithNoRecordIsStillAskedAboutButProposesNoLabel() {
        let requests = AdmissionDecision.requests(
            pending: [phone: 3], registry: rootedRegistry(), memory: [:], myRoot: root)

        let request = requests.first
        XCTAssertEqual(request?.fingerprint, phone,
                       "a device with no record of its own is exactly the case the sheet is for")
        XCTAssertNil(request?.ownName, "and Maugham does not invent a name for it")
        XCTAssertEqual(request?.proposedLabel, "")
        XCTAssertEqual(request?.displayName, "A device with code \(DeviceCode.short(phone))")
        XCTAssertEqual(request?.recordedOwnName, DeviceCode.short(phone),
                       "the record carries something a human can match against a screen")
    }

    func test_aDeviceAlreadyAdmittedIsNotAStranger() {
        let registry = rootedRegistry(
            devices: [device(phone, name: "Denver’s iPhone")],
            people: [person(phone, label: "Denver", admittedBy: root)])

        XCTAssertTrue(AdmissionDecision.requests(
            pending: [phone: 9], registry: registry, memory: [:], myRoot: root).isEmpty)
    }

    func test_aDeviceAdmittedUnderAnotherRootIsAClaimantAndNotASheet() {
        let registry = rootedRegistry(
            devices: [device(phone, name: "Denver’s iPhone")],
            people: [person(other, label: "Someone", admittedBy: other),
                     person(phone, label: "Theirs", admittedBy: other)])

        XCTAssertTrue(
            AdmissionDecision.requests(
                pending: [phone: 4], registry: registry, memory: [:], myRoot: root).isEmpty,
            "merging two chains is a claim, and RegistryAdmission.admit would refuse this")
    }

    func test_aDeviceIsAskedAboutOncePerStrangerAndInFingerprintOrder() {
        let requests = AdmissionDecision.requests(
            pending: [phone: 1, other: 2], registry: rootedRegistry(),
            memory: [:], myRoot: root)

        XCTAssertEqual(requests.map(\.fingerprint), [other, phone].sorted(),
                       "two runs over one folder ask in the same order")
    }

    func test_aFingerprintWithNothingWaitingIsNobodyToAskAbout() {
        XCTAssertTrue(AdmissionDecision.requests(
            pending: [phone: 0], registry: rootedRegistry(), memory: [:], myRoot: root).isEmpty)
    }

    // MARK: - Decision B3: no chain, nothing to admit

    func test_withNoRootOfItsOwnThisMacAsksNobody() {
        XCTAssertTrue(
            AdmissionDecision.requests(
                pending: [phone: 14], registry: Registry(), memory: [:], myRoot: nil).isEmpty,
            "a device no record names judges nobody, so nothing is held (B3)")
    }

    // MARK: - Known labels

    func test_knownLabelsComeFromTheRegistryAndFromWhatThisMacRemembers() {
        let registry = rootedRegistry(
            devices: [device(phone, name: "Denver’s iPhone")],
            people: [person(other, label: "Amelia", admittedBy: root)])
        let memory = [
            "cccc4444": AdmissionMemory.Label(
                label: "Rosa", ownName: "Rosa’s iPad",
                labelledAt: Date(timeIntervalSince1970: 1)),
        ]

        let labels = AdmissionDecision.requests(
            pending: [phone: 1], registry: registry, memory: memory, myRoot: root
        ).first?.knownLabels

        XCTAssertEqual(labels, ["Amelia", "Denver", "Rosa"],
                       "sorted, so 'this is also…' reads the same twice")
    }

    func test_oneLabelSpelledTwoWaysIsOneLabel() {
        let registry = rootedRegistry(
            people: [person(other, label: "denver ", admittedBy: root)])

        XCTAssertEqual(
            AdmissionDecision.knownLabels(registry: registry, memory: [:]), ["Denver"],
            "the first spelling stands; a case difference is not a second person")
    }

    // MARK: - What an answer means

    func test_aTypedLabelNobodyUsesAdmitsUnderIt() {
        let request = AdmissionDecision.requests(
            pending: [phone: 1], registry: rootedRegistry(), memory: [:], myRoot: root).first!

        XCTAssertEqual(AdmissionDecision.outcome(for: request, typedLabel: "Amelia"),
                       .admit(label: "Amelia"))
    }

    func test_aTypedLabelThatMatchesAnExistingOneMergesUnderItsOwnSpelling() {
        let request = AdmissionDecision.requests(
            pending: [phone: 1], registry: rootedRegistry(), memory: [:], myRoot: root).first!

        XCTAssertEqual(AdmissionDecision.outcome(for: request, typedLabel: "  denver "),
                       .mergeUnder(label: "Denver"),
                       "nobody is admitted AS a new Denver by asking (spec §4.1)")
    }

    func test_anEmptyLabelIsNotNow() {
        let request = AdmissionDecision.requests(
            pending: [phone: 1], registry: rootedRegistry(), memory: [:], myRoot: root).first!

        XCTAssertEqual(AdmissionDecision.outcome(for: request, typedLabel: "   "), .notNow,
                       "there is nothing to call this device, so nothing is written")
        XCTAssertEqual(request.waitingCount, 1,
                       "and the lines stay held — Not now changes no count")
    }

    func test_theProposedLabelOfADeviceWithNoRecordIsItselfNotNow() {
        let request = AdmissionDecision.requests(
            pending: [phone: 1], registry: rootedRegistry(), memory: [:], myRoot: root).first!

        XCTAssertEqual(
            AdmissionDecision.outcome(for: request, typedLabel: request.proposedLabel), .notNow,
            "Admit is refused until the writer says what to call it")
    }

    // MARK: - Refusals speak (RULING-7)

    func test_eachRefusalCarriesItsOwnSentence() {
        let notARoot = AdmissionDecision.refusal(RegistryAdmissionError.notARoot)
        XCTAssertTrue(notARoot.contains("root"), notARoot)

        let elsewhere = AdmissionDecision.refusal(
            RegistryAdmissionError.alreadyAdmittedElsewhere(root: root))
        XCTAssertTrue(elsewhere.contains(DeviceCode.short(root)),
                      "it names the Mac that already admitted it: \(elsewhere)")
        XCTAssertNotEqual(notARoot, elsewhere,
                          "two refusals with two different next moves")
    }
}
