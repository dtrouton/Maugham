// MaughamTests/Views/AdmissionKeyStandingTests.swift
import XCTest
@testable import MaughamCore
@testable import Maugham

/// **The keys the admission sheet never offers** (signed op log P3b Task 4,
/// spec §7.1).
///
/// P2b had one question — *is this a device this book has no record of* — and
/// the answer was the whole of the sheet's queue. Three more holders can reach
/// that queue now, and none of them is a person to let in:
///
/// - a **non-author actor key** whose device record has not arrived yet. It is
///   not a person: it is one of a machine's other three writers, and admitting
///   it would let the machine into the book under the name of its assistant.
///   It stays HELD and is admitted for real the moment its device record lands
///   and names it — which is the other direction, pinned below.
/// - a **contested key**, which two verified device records both claim and
///   `Registry.actorKeyOwners` awards to nobody for good.
/// - a holder that is not a stranger at all — a permit-pending line from
///   somebody already in the book, or an unsigned stream, both of which
///   `HeldLines.holder` decides and this file never re-decides.
///
/// **The narrowing must not cost an honest stranger her sheet**, and the case
/// that would is the one this suite spends most of its length on: a stranger
/// whose held lines happen to be in her own ASSISTANT file. Her lines are held
/// under her DEVICE's fingerprint, the slug says `assistant`, and the checked
/// parse is what tells the two apart.
final class AdmissionKeyStandingTests: XCTestCase {

    private let root = String(repeating: "a1", count: 32)
    /// A stranger's author key. 64 hex, like every fingerprint.
    private let samsKey =
        "ffff2222aaaa3333bbbb4444cccc5555dddd6666eeee7777ffff8888aaaa9999"
    private let herAssistantKey =
        "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
    private let otherKey =
        "9999888877776666555544443333222211110000aaaabbbbccccddddeeeeffff"

    // MARK: - Fixtures

    private func person(
        _ fingerprint: String, label: String, admittedBy: String
    ) -> PersonRecord {
        PersonRecord(
            person: fingerprint, label: label, ownName: "A device",
            admittedAt: Date(timeIntervalSince1970: 10), admittedBy: admittedBy)
    }

    private func device(
        _ fingerprint: String, name: String, actors: [String: String] = [:]
    ) -> DeviceRecord {
        DeviceRecord(
            device: fingerprint, name: name, kind: .mac,
            actors: [DeviceActor.author.rawValue: fingerprint].merging(
                actors, uniquingKeysWith: { _, new in new }),
            madeAt: Date(timeIntervalSince1970: 5))
    }

    private func rootedRegistry(
        devices: [DeviceRecord] = [], people: [PersonRecord] = []
    ) -> Registry {
        Registry(
            devices: devices,
            people: [person(root, label: "Denver", admittedBy: root)] + people)
    }

    /// The slug the files of one actor key carry — `DeviceSlug.make` over the
    /// device id that key writes under, which is exactly what production puts
    /// in a filename.
    private func slug(actor: DeviceActor, key: String) -> String {
        DeviceSlug.make(from: DeviceIdentity.deviceId(
            actor: actor.rawValue, fingerprint: key)).raw
    }

    // MARK: - The ordinary stranger is untouched

    func test_anAuthorKeyStrangerIsOfferedExactlyAsBefore() {
        let streams = [samsKey: Set([slug(actor: .author, key: samsKey)])]

        let requests = AdmissionDecision.requests(
            pending: [samsKey: 7], streams: streams,
            registry: rootedRegistry(), memory: [:], myRoot: root)

        XCTAssertEqual(requests.map(\.fingerprint), [samsKey])
        XCTAssertEqual(
            AdmissionDecision.standing(
                ofHolder: samsKey,
                streams: streams[samsKey] ?? [], registry: rootedRegistry()),
            .aStrangerToAskAbout)
    }

    /// **And with nothing said about her streams at all** — a legacy file, an
    /// inbox read from before this milestone, a hand-built map. P2b's answer
    /// stands wherever the new question has no input.
    func test_aStrangerWithNoStreamsNamedIsStillOffered() {
        XCTAssertEqual(
            AdmissionDecision.requests(
                pending: [samsKey: 3], registry: rootedRegistry(),
                memory: [:], myRoot: root).map(\.fingerprint),
            [samsKey])
    }

    // MARK: - Never offered 1: a key that is not a person's

    func test_aNonAuthorActorKeyWaitsForItsDeviceRecordAndIsNeverOffered() {
        let streams = [
            herAssistantKey: Set([slug(actor: .assistant, key: herAssistantKey)]),
        ]

        let requests = AdmissionDecision.requests(
            pending: [herAssistantKey: 4], streams: streams,
            registry: rootedRegistry(), memory: [:], myRoot: root)

        XCTAssertTrue(requests.isEmpty,
                      "there is no person here to let in — only a writer of one")
        XCTAssertEqual(
            AdmissionDecision.standing(
                ofHolder: herAssistantKey, streams: streams[herAssistantKey] ?? [],
                registry: rootedRegistry()),
            .waitingForItsDeviceRecord(actor: .assistant))
    }

    func test_theTranslatorAndTheAppsOwnKeyWaitTheSameWay() {
        for actor in [DeviceActor.translator, .maugham] {
            let streams = Set([slug(actor: actor, key: herAssistantKey)])

            XCTAssertEqual(
                AdmissionDecision.standing(
                    ofHolder: herAssistantKey, streams: streams,
                    registry: rootedRegistry()),
                .waitingForItsDeviceRecord(actor: actor))
        }
    }

    /// **The other direction, and it is the whole reason the first one is
    /// safe**: once the device record arrives and names the key, the walk holds
    /// those lines under the DEVICE's own fingerprint, and the person is
    /// offered by that key with her actor's lines riding in with her.
    func test_onceHerDeviceRecordArrivesSheIsOfferedByHerOwnKey() {
        let registry = rootedRegistry(devices: [
            device(samsKey, name: "Sam’s Mac",
                   actors: [DeviceActor.assistant.rawValue: herAssistantKey]),
        ])
        // Held under the device, in her assistant's own file — which is exactly
        // the shape that must NOT be read as *a key that is not a person's*.
        let streams = [samsKey: Set([slug(actor: .assistant, key: herAssistantKey)])]

        let requests = AdmissionDecision.requests(
            pending: [samsKey: 4], streams: streams,
            registry: registry, memory: [:], myRoot: root)

        XCTAssertEqual(requests.map(\.fingerprint), [samsKey])
        XCTAssertEqual(requests.first?.ownName, "Sam’s Mac")
        XCTAssertEqual(
            AdmissionDecision.standing(
                ofHolder: samsKey, streams: streams[samsKey] ?? [],
                registry: registry),
            .aStrangerToAskAbout,
            "the slug says assistant, but it does not say it about THIS key")
    }

    /// The parse is CHECKED against the key rather than believing the word: a
    /// filename that claims an actor for a key it does not name narrows
    /// nothing, on either side.
    func test_aSlugThatNamesSomebodyElsesKeySaysNothingAboutThisOne() {
        XCTAssertEqual(
            AdmissionDecision.standing(
                ofHolder: samsKey,
                streams: [slug(actor: .assistant, key: otherKey)],
                registry: rootedRegistry()),
            .aStrangerToAskAbout)
    }

    /// A holder in two files — her author tail and her assistant's — is the
    /// key's own person the moment one of them says so.
    func test_anAuthorSlugBesideAnAssistantSlugIsStillAnAuthorKey() {
        XCTAssertEqual(
            AdmissionDecision.standing(
                ofHolder: samsKey,
                streams: [slug(actor: .author, key: samsKey),
                          slug(actor: .assistant, key: otherKey)],
                registry: rootedRegistry()),
            .aStrangerToAskAbout)
    }

    /// **An author slug for this very key outranks a non-author one**, whatever
    /// order they sort in — a key that has written as an author IS a person
    /// under labels-only. Without that precedence anybody with the shared
    /// folder could deny an honest stranger her sheet by writing one filename
    /// beside her tail: `assistant-…` sorts before `author-…`, so a planted
    /// name would win a first-match rule.
    func test_aPlantedActorFilenameCannotCostAnAuthorKeyItsSheet() {
        XCTAssertEqual(
            AdmissionDecision.standing(
                ofHolder: samsKey,
                streams: [slug(actor: .assistant, key: samsKey),
                          slug(actor: .author, key: samsKey)],
                registry: rootedRegistry()),
            .aStrangerToAskAbout)
    }

    // MARK: - Never offered 2: a key two records claim

    func test_aContestedKeyIsNeverARequest() {
        let registry = rootedRegistry(devices: [
            device(samsKey, name: "Sam’s Mac",
                   actors: [DeviceActor.assistant.rawValue: herAssistantKey]),
            device(otherKey, name: "A liar",
                   actors: [DeviceActor.assistant.rawValue: herAssistantKey]),
        ])

        XCTAssertTrue(registry.isContestedActorKey(herAssistantKey),
                      "two verified records claim it, so it is nobody's")
        XCTAssertEqual(
            AdmissionDecision.standing(
                ofHolder: herAssistantKey, streams: [], registry: registry),
            .contested)
        XCTAssertTrue(
            AdmissionDecision.requests(
                pending: [herAssistantKey: 2], registry: registry,
                memory: [:], myRoot: root).isEmpty)
    }

    /// The converse, so the contested rule cannot quietly widen: a key exactly
    /// one record claims belongs to that record's device and says nothing about
    /// whether its OWNER is a stranger.
    func test_aKeyOneRecordClaimsIsNotContested() {
        let registry = rootedRegistry(devices: [
            device(samsKey, name: "Sam’s Mac",
                   actors: [DeviceActor.assistant.rawValue: herAssistantKey]),
        ])

        XCTAssertFalse(registry.isContestedActorKey(herAssistantKey))
        XCTAssertFalse(registry.isContestedActorKey(samsKey),
                       "the author slot is proven, so it is never contested")
    }

    // MARK: - Never offered 3: the holders that are not strangers

    func test_anUnsignedStreamIsNeverOfferedAsADeviceToAdmit() {
        let holder = HeldLines.unsignedHolder(
            forStreamKey: "d-one.ghostmac", deviceSlug: "ghostmac")

        XCTAssertEqual(
            AdmissionDecision.standing(
                ofHolder: holder, streams: [], registry: rootedRegistry()),
            .notAStranger(.unsigned(stream: "ghostmac")))
        XCTAssertTrue(
            AdmissionDecision.requests(
                pending: [holder: 9], registry: rootedRegistry(),
                memory: [:], myRoot: root).isEmpty,
            "there is no device to admit, because there is no key")
    }

    func test_anAdmittedPersonsPermitPendingLinesAreNeverASheet() {
        let registry = rootedRegistry(
            devices: [device(samsKey, name: "Sam’s Mac")],
            people: [person(samsKey, label: "Sam", admittedBy: root)])

        XCTAssertEqual(
            AdmissionDecision.standing(
                ofHolder: samsKey, streams: [], registry: registry),
            .notAStranger(.permitPending(person: samsKey, startedAPiece: false)))
        XCTAssertTrue(
            AdmissionDecision.requests(
                pending: [samsKey: 5], registry: registry,
                memory: [:], myRoot: root).isEmpty)
    }

    // MARK: - The union carries what the decision needs

    func test_theRefreshReadsTheStreamsBesideTheCounts() async {
        let streams = [
            herAssistantKey: Set([slug(actor: .assistant, key: herAssistantKey)]),
        ]
        let registry = rootedRegistry()

        let requests = await AdmissionDecision.refreshedRequests(
            heldLines: { [self.samsKey: 2, self.herAssistantKey: 3] },
            heldStreams: { streams },
            memory: [:],
            admitRemembered: {},
            resolve: { (registry, self.root) })

        XCTAssertEqual(requests?.map(\.fingerprint), [samsKey],
                       "the author key is asked about; the actor key waits")
    }
}
