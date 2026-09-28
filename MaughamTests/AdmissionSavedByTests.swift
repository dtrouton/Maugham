// MaughamTests/AdmissionSavedByTests.swift
import XCTest
@testable import MaughamCore
@testable import Maugham

/// **iCloud's saved-by hint on the admission sheet** (your devices are you,
/// plan 2 Task 3; ruling P2-3; Review Focus 3).
///
/// Every value is decided with no window and no iCloud (tripwire 33): the
/// reader is a closure the refresh is handed, and the sheet's lines are a
/// function of the request.
final class AdmissionSavedByTests: XCTestCase {

    private let stranger = "b7c1d2e3f4a5b6c7"
    private var rootMac: DeviceIdentity!

    override func setUpWithError() throws {
        try super.setUpWithError()
        rootMac = .softwareForTesting()
    }

    private var root: String { rootMac.fingerprint }

    private func request(
        hint: ClaimHint? = nil, savedBy: String? = nil
    ) -> AdmissionRequest {
        AdmissionRequest(
            fingerprint: stranger, ownName: "Sam’s MacBook Air",
            code: DeviceCode.short(stranger), waitingCount: 0,
            proposedLabel: "Sam’s MacBook Air", knownLabels: ["Denver"],
            hint: hint, savedBy: savedBy)
    }

    private func claim(_ person: String) -> ClaimHint {
        ClaimHint(personName: person, deviceName: "Sam’s MacBook Air",
                  linkedElsewhere: false)
    }

    // MARK: - The sheet's lines

    /// The saved-by line is independent of the claim: a device carrying no
    /// claim still shows what iCloud says about its record.
    func test_aSavedByNameShowsWithNoClaim() {
        XCTAssertEqual(AdmissionSheet.hintLines(for: request(savedBy: "Sam Ruiz")), [
            "iCloud says this device’s record was saved by Sam Ruiz.",
        ])
    }

    /// **Nil is the owner's own save** (the spike: nil means the current user
    /// saved it). No saved-by line at all — with a claim or without — and so
    /// nothing that could put the root's own save in somebody else's name.
    func test_noSavedByNameDrawsNoSavedByLine() {
        XCTAssertEqual(AdmissionSheet.hintLines(for: request()), [])
        XCTAssertEqual(AdmissionSheet.hintLines(for: request(hint: claim("Sam Ruiz"))), [
            "It calls itself Sam’s MacBook Air, belonging to Sam Ruiz.",
            AdmissionSheet.claimAttribution,
        ])
        XCTAssertEqual(AdmissionSheet.hintLines(for: request(savedBy: "  \n")), [],
                       "a blank name is no name")
    }

    /// A claim and iCloud agreeing — however the case and spacing differ —
    /// is one saved-by line and no remark.
    func test_agreeingNamesAddNoRemark() {
        for saved in ["Sam Ruiz", "sam ruiz", "  SAM   Ruiz ", "Sam\tRuiz"] {
            XCTAssertEqual(
                AdmissionSheet.hintLines(for: request(hint: claim("Sam Ruiz"), savedBy: saved)),
                ["It calls itself Sam’s MacBook Air, belonging to Sam Ruiz.",
                 AdmissionSheet.claimAttribution,
                 "iCloud says this device’s record was saved by \(saved.trimmingCharacters(in: .whitespacesAndNewlines))."],
                "\(saved) is the same name")
        }
    }

    /// A claim and iCloud disagreeing is said plainly, after the saved-by
    /// line.
    func test_disagreeingNamesAreSaidPlainly() {
        XCTAssertEqual(
            AdmissionSheet.hintLines(for: request(hint: claim("Sam Ruiz"), savedBy: "Rebecca Burgess")),
            ["It calls itself Sam’s MacBook Air, belonging to Sam Ruiz.",
             AdmissionSheet.claimAttribution,
             "iCloud says this device’s record was saved by Rebecca Burgess.",
             "That isn’t the name the device gives."])
    }

    /// A claim naming nobody has no name to disagree with.
    func test_aClaimNamingNobodyHasNothingToDisagreeWith() {
        XCTAssertEqual(
            AdmissionSheet.hintLines(for: request(hint: claim("  "), savedBy: "Rebecca Burgess")),
            ["It calls itself Sam’s MacBook Air.",
             AdmissionSheet.claimAttribution,
             "iCloud says this device’s record was saved by Rebecca Burgess."])
    }

    func test_sameNameBothDirections() {
        XCTAssertTrue(AdmissionSheet.sameName("Sam Ruiz", " sam  RUIZ\n"))
        XCTAssertFalse(AdmissionSheet.sameName("Sam Ruiz", "Sam Ruizz"))
        XCTAssertFalse(AdmissionSheet.sameName("Sam Ruiz", "SamRuiz"))
    }

    // MARK: - Folding the reader's answer into the requests

    func test_withSavedByKeepsNilWhereTheReaderSaidNothing() {
        let a = request()
        let b = AdmissionRequest(
            fingerprint: "c0ffee00c0ffee00", ownName: nil, code: "C0FF",
            waitingCount: 1, proposedLabel: "", knownLabels: [])
        let folded = AdmissionDecision.withSavedBy(
            [a, b], names: [stranger: "Rebecca Burgess", "c0ffee00c0ffee00": " \t "])
        XCTAssertEqual(folded.map(\.savedBy), ["Rebecca Burgess", nil],
                       "a blank name is no name; an absent one stays nil")
        XCTAssertEqual(AdmissionDecision.withSavedBy([a], names: [:]).map(\.savedBy), [nil])
    }

    // MARK: - The refresh asks the reader, after deciding who to ask about

    private func rootedRegistry(devices: [DeviceRecord]) -> Registry {
        Registry(
            devices: devices,
            people: [PersonRecord(
                person: root, label: "Denver", ownName: "Denver’s Mac",
                admittedAt: Date(timeIntervalSince1970: 10), admittedBy: root)])
    }

    private func strangerDevice() -> DeviceRecord {
        DeviceRecord(
            device: stranger, name: "Sam’s MacBook Air", kind: .mac,
            actors: [DeviceActor.author.rawValue: stranger],
            madeAt: Date(timeIntervalSince1970: 30))
    }

    @MainActor
    private func refresh(
        registry: Registry,
        acts: @escaping @MainActor (String) -> Void,
        savedBy: @escaping @MainActor ([String]) -> [String: String]
    ) async -> [AdmissionRequest]? {
        await AdmissionDecision.refreshedRequests(
            cause: .announcement,
            heldLines: { [:] },
            arrivedDevices: { [self.stranger] },
            thisDevice: root, memory: [:],
            admitRemembered: {},
            savedBy: { fingerprints in
                acts("savedBy \(fingerprints)")
                return savedBy(fingerprints)
            },
            resolve: {
                acts("resolve")
                return (registry: registry, myRoot: self.root)
            })
    }

    /// The reader is asked AFTER the verified read, about exactly the devices
    /// the sheet will ask about, and its answer reaches the request.
    @MainActor
    func test_theRefreshAsksTheReaderAboutWhoItAsksAboutAndCarriesTheName() async throws {
        var acts: [String] = []
        let requests = await refresh(
            registry: rootedRegistry(devices: [strangerDevice()]),
            acts: { acts.append($0) },
            savedBy: { _ in [self.stranger: "Rebecca Burgess"] })

        let asked = try XCTUnwrap(requests?.first)
        XCTAssertEqual(asked.savedBy, "Rebecca Burgess")
        XCTAssertEqual(acts, ["resolve", "savedBy [\"\(stranger)\"]"])
        XCTAssertEqual(asked.proposedLabel, "Sam’s MacBook Air",
                       "the saved-by name never becomes the proposal")
    }

    /// **The owner's Mac** (Review Focus 3): the reader answers nil for a
    /// record the root saved itself, and the sheet then says nothing about who
    /// saved it — never the root's own name, never anybody's.
    @MainActor
    func test_onTheOwnersMacTheirOwnSaveDrawsNoName() async throws {
        let requests = await refresh(
            registry: rootedRegistry(devices: [strangerDevice()]),
            acts: { _ in },
            savedBy: { _ in [:] })

        let asked = try XCTUnwrap(requests?.first)
        XCTAssertNil(asked.savedBy)
        let lines = AdmissionSheet.hintLines(for: asked)
        XCTAssertFalse(lines.contains { $0.contains("iCloud") }, "\(lines)")
        XCTAssertFalse(lines.contains { $0.contains("Denver") }, "\(lines)")
    }

    /// A saved-by name that is a label here never pre-fills a merge — the
    /// hint is information, and the field is decided without it.
    @MainActor
    func test_aSavedByNameMatchingALabelHereIsNeverAMerge() async throws {
        let requests = await refresh(
            registry: rootedRegistry(devices: [strangerDevice()]),
            acts: { _ in },
            savedBy: { _ in [self.stranger: "Denver"] })

        let asked = try XCTUnwrap(requests?.first)
        XCTAssertEqual(asked.savedBy, "Denver")
        XCTAssertEqual(AdmissionDecision.outcome(for: asked, typedLabel: asked.proposedLabel),
                       .admit(label: "Sam’s MacBook Air"))
    }

    /// Nobody to ask about: the reader is not asked at all.
    @MainActor
    func test_aRefreshAskingAboutNobodyReadsNoResourceValue() async {
        var acts: [String] = []
        let requests = await refresh(
            registry: rootedRegistry(devices: []),
            acts: { acts.append($0) },
            savedBy: { _ in [self.stranger: "Rebecca Burgess"] })

        XCTAssertEqual(requests, [])
        XCTAssertEqual(acts, ["resolve"])
    }
}
