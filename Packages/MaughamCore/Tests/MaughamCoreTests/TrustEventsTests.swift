import Foundation
import XCTest
@testable import MaughamCore

/// Trust's second shape (spec §6, Denver's ruling C, 2026-09-10): the EVENTS.
///
/// A banner says what holds now; an event says what happened and when. These
/// pin the derivation — registry records plus this device's own memory of the
/// project, in, dated events out — with no view anywhere near it.
///
/// Every fixture builds a `Registry` value directly, `TrustTableTests`' rule and
/// for its reason: the reader has already decided which records are records,
/// and this function is asked only what those facts amount to as a history.
final class TrustEventsTests: XCTestCase {

    private var mine: LocalIdentities!
    private var project: URL!
    private var cacheFile: URL!

    override func setUp() {
        super.setUp()
        mine = .softwareForTesting()
        project = FileManager.default.temporaryDirectory
            .appendingPathComponent("trust-events-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: project, withIntermediateDirectories: true)
        cacheFile = project.appendingPathComponent("registry-cache.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: project)
        super.tearDown()
    }

    // MARK: - Fixtures

    private func foreignKey() -> String { DeviceIdentity.softwareForTesting().fingerprint }

    private func cache() -> RegistryCache {
        RegistryCache(fileURL: cacheFile, identity: mine.author.fingerprint)
    }

    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    private func rootRecord(
        _ fingerprint: String, label: String = "Denver",
        ownName: String = "Denver’s MacBook", at seconds: TimeInterval = 10
    ) -> PersonRecord {
        PersonRecord(
            person: fingerprint, label: label, ownName: ownName,
            admittedAt: at(seconds), admittedBy: fingerprint)
    }

    private func admittedRecord(
        _ fingerprint: String, under root: String, at seconds: TimeInterval = 20,
        label: String = "iPhone", ownName: String = "Denver’s iPhone",
        revokedAt: Date? = nil, revokedBy: String? = nil
    ) -> PersonRecord {
        PersonRecord(
            person: fingerprint, label: label, ownName: ownName,
            admittedAt: at(seconds), admittedBy: root,
            revokedAt: revokedAt, revokedBy: revokedBy)
    }

    private func deviceRecord(
        _ fingerprint: String, name: String = "Denver’s iPhone",
        kind: DeviceKind = .phone, retiredAt: Date? = nil
    ) -> DeviceRecord {
        DeviceRecord(
            device: fingerprint, name: name, kind: kind,
            actors: [DeviceActor.author.rawValue: fingerprint],
            madeAt: at(5), retiredAt: retiredAt)
    }

    // MARK: - Admission

    func test_anAdmittedPersonIsADatedEventCarryingBothItsNames() {
        let root = foreignKey()
        let phone = foreignKey()
        let registry = Registry(people: [
            rootRecord(root), admittedRecord(phone, under: root, at: 20),
        ])

        let events = TrustEvents.derive(
            registry: registry, cache: cache(), mine: mine, for: project)

        let admitted = events.filter { $0.kind == .admitted }
        XCTAssertEqual(admitted.count, 1)
        XCTAssertEqual(admitted[0].subject, phone)
        XCTAssertEqual(admitted[0].date, at(20))
        XCTAssertEqual(admitted[0].label, "iPhone")
        XCTAssertEqual(admitted[0].ownName, "Denver’s iPhone")
        XCTAssertEqual(admitted[0].by, root, "who admitted them is the event's other half")
    }

    /// A root admitted itself, which is not an admission anybody granted. The
    /// event would otherwise read *Denver admitted by Denver* on every project
    /// that has ever had a registry — a line that says nothing happened.
    func test_theRootsSelfSignedRecordIsNotAnAdmission() {
        let root = foreignKey()
        let events = TrustEvents.derive(
            registry: Registry(people: [rootRecord(root)]),
            cache: cache(), mine: mine, for: project)

        XCTAssertTrue(events.filter { $0.kind == .admitted }.isEmpty)
    }

    /// The record holds both stamps, so both events are drawn: a person let in
    /// and later shown out leaves a trace of each, which is the whole reason
    /// ruling C refused banners-only.
    func test_aPersonAdmittedAndThenRevokedShowsBothEvents() {
        let root = foreignKey()
        let sam = foreignKey()
        let registry = Registry(people: [
            rootRecord(root),
            admittedRecord(sam, under: root, at: 20, label: "Sam", ownName: "Sam’s Mac",
                           revokedAt: at(60), revokedBy: root),
        ])

        let events = TrustEvents.derive(
            registry: registry, cache: cache(), mine: mine, for: project)
            .filter { $0.subject == sam }

        XCTAssertEqual(events.map(\.kind), [.revoked, .admitted],
                       "newest first: the revocation, then the admission it ended")
        XCTAssertEqual(events[0].date, at(60))
        XCTAssertEqual(events[0].by, root)
        XCTAssertEqual(events[1].date, at(20))
    }

    /// The absent-`revokedBy` case: a record can carry the date and not the
    /// hand. The event is still drawn — a revocation nobody is named for is
    /// still a revocation.
    func test_aRevocationWithNoNamedHandIsStillAnEvent() {
        let root = foreignKey()
        let sam = foreignKey()
        let registry = Registry(people: [
            rootRecord(root),
            admittedRecord(sam, under: root, revokedAt: at(60), revokedBy: nil),
        ])

        let revoked = TrustEvents.derive(
            registry: registry, cache: cache(), mine: mine, for: project)
            .filter { $0.kind == .revoked }
        XCTAssertEqual(revoked.count, 1)
        XCTAssertNil(revoked[0].by)
    }

    // MARK: - Retirement

    func test_aRetiredDeviceIsADatedEventNamedByItsRecord() {
        let phone = foreignKey()
        let registry = Registry(devices: [
            deviceRecord(phone, name: "iPhone", retiredAt: at(80)),
        ])

        let events = TrustEvents.derive(
            registry: registry, cache: cache(), mine: mine, for: project)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .retired)
        XCTAssertEqual(events[0].subject, phone)
        XCTAssertEqual(events[0].date, at(80))
        XCTAssertEqual(events[0].label, "iPhone")
        XCTAssertNil(events[0].ownName, "a device record carries one name, not two")
    }

    func test_aLiveDeviceIsNoEventAtAll() {
        let events = TrustEvents.derive(
            registry: Registry(devices: [deviceRecord(foreignKey())]),
            cache: cache(), mine: mine, for: project)
        XCTAssertTrue(events.isEmpty, "a device that is still in service is not news")
    }

    // MARK: - Claims

    func test_aClaimIsOneClaimedEventAndOneAdoptedEventPerRootItTookIn() {
        let newRoot = foreignKey()
        let old = foreignKey()
        let older = foreignKey()
        let registry = Registry(
            people: [rootRecord(newRoot, label: "Denver’s MacBook",
                                ownName: "Denver’s MacBook")],
            claims: [ClaimRecord(newRoot: newRoot, adopted: [old, older],
                                 claimedAt: at(100))])

        let events = TrustEvents.derive(
            registry: registry, cache: cache(), mine: mine, for: project)

        XCTAssertEqual(events.filter { $0.kind == .claimed }.map(\.subject), [newRoot])
        let adopted = events.filter { $0.kind == .adopted }
        XCTAssertEqual(Set(adopted.map(\.subject)), [old, older])
        XCTAssertEqual(Set(adopted.map(\.by)), [newRoot])
        XCTAssertEqual(Set(adopted.map(\.date)), [at(100)],
                       "an adoption happened when the claim that carried it was written")
    }

    // MARK: - The join (Task 2's stamp)

    func test_theJoinIsADatedEventNamingTheRootThisMacIsOn() {
        let root = foreignKey()
        let store = cache()
        store.join(root: root, for: project, at: at(50))

        let events = TrustEvents.derive(
            registry: Registry(people: [rootRecord(root)]),
            cache: store, mine: mine, for: project)

        let joined = events.filter { $0.kind == .joined }
        XCTAssertEqual(joined.count, 1)
        XCTAssertEqual(joined[0].subject, root)
        XCTAssertEqual(joined[0].date, at(50))
        XCTAssertEqual(joined[0].label, "Denver")
    }

    /// Task 2's carry, arriving here: a memory written before the join carried
    /// a stamp has the root and no date. The event is still derived — losing
    /// the fact because the day is unknown would be the one wrong answer.
    func test_aJoinFromBeforeTheStampExistedIsStillAnUndatedEvent() throws {
        let root = foreignKey()
        // Written as a P2a-era memory would have been: the root it joined, and
        // no `joinedAt` field at all.
        let legacy: [String: Any] = [
            "identity": mine.author.fingerprint as Any,
            "projects": [
                RegistryCache.projectKey(project): [
                    "root": project.standardizedFileURL.path,
                    "records": [],
                    "joinedRoot": root,
                    "claimants": [],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: legacy).write(to: cacheFile)
        let store = cache()
        XCTAssertEqual(store.joinedRoot(for: project), root, "the memory loaded")
        XCTAssertNil(store.joinedAt(for: project))

        let joined = TrustEvents.derive(
            registry: Registry(people: [rootRecord(root)]),
            cache: store, mine: mine, for: project)
            .filter { $0.kind == .joined }

        XCTAssertEqual(joined.count, 1)
        XCTAssertNil(joined[0].date)
        XCTAssertEqual(joined[0].subject, root)
    }

    func test_aDeviceThatJoinedNobodyHasNoJoinEvent() {
        let events = TrustEvents.derive(
            registry: Registry(), cache: cache(), mine: mine, for: project)
        XCTAssertTrue(events.isEmpty)
    }

    /// B1's loud half. Each is undated because nothing stamps a claimant — the
    /// cache records that it happened, not when — and inventing a date here
    /// would be this surface making one up.
    func test_everyOtherClaimantIsAnUndatedEvent() {
        let root = foreignKey()
        let other = foreignKey()
        let store = cache()
        store.join(root: root, for: project, at: at(50))
        store.recordClaimant(root: other, for: project)

        let claimants = TrustEvents.derive(
            registry: Registry(people: [rootRecord(root)]),
            cache: store, mine: mine, for: project)
            .filter { $0.kind == .anotherClaimant }

        XCTAssertEqual(claimants.map(\.subject), [other])
        XCTAssertNil(claimants[0].date)
    }

    func test_theJoinAndTheClaimantsArePerProject() {
        let root = foreignKey()
        let store = cache()
        store.join(root: root, for: project, at: at(50))

        let elsewhere = project.appendingPathComponent("another-book")
        try? FileManager.default.createDirectory(
            at: elsewhere, withIntermediateDirectories: true)

        XCTAssertTrue(TrustEvents.derive(
            registry: Registry(people: [rootRecord(root)]),
            cache: store, mine: mine, for: elsewhere).isEmpty)
    }

    /// **A root my root has ADOPTED is merged, and History stops warning about
    /// it** (whole-branch review H1).
    ///
    /// `RegistryCache.claimants` is an append-only memory — recording that a
    /// second root was once seen here is a fact, and the merge does not unsay
    /// it. So the filter belongs at the derivation, and it has to be the SAME
    /// adopted set People & Devices reads, or the pane says *merged* on one
    /// screen while History warns forever on the other.
    func test_arootThisDeviceHasAdoptedIsNoLongerAnotherClaimant() {
        let mineRoot = foreignKey()
        let theirs = foreignKey()
        let store = cache()
        store.join(root: mineRoot, for: project, at: at(50))
        store.recordClaimant(root: theirs, for: project)

        let before = TrustEvents.derive(
            registry: Registry(people: [rootRecord(mineRoot), rootRecord(theirs)]),
            cache: store, mine: mine, for: project)
            .filter { $0.kind == .anotherClaimant }
        XCTAssertEqual(before.map(\.subject), [theirs],
                       "premise: unmerged, it is a claimant and History says so")

        let after = TrustEvents.derive(
            registry: Registry(
                people: [rootRecord(mineRoot), rootRecord(theirs)],
                claims: [ClaimRecord(
                    newRoot: mineRoot, adopted: [theirs], claimedAt: at(60))]),
            cache: store, mine: mine, for: project)
            .filter { $0.kind == .anotherClaimant }
        XCTAssertTrue(after.isEmpty,
                      "the merge is this device's own answer to the question the "
                          + "warning asks: \(after.map(\.subject))")
    }

    /// The converse, and the one that keeps the filter honest: adoption is
    /// one-way (B1), so a root that adopted MINE without my reciprocating is
    /// still a claimant and still offered.
    func test_arootThatAdoptedMineWithoutMyAnswerIsStillAClaimant() {
        let mineRoot = foreignKey()
        let theirs = foreignKey()
        let store = cache()
        store.join(root: mineRoot, for: project, at: at(50))
        store.recordClaimant(root: theirs, for: project)

        let events = TrustEvents.derive(
            registry: Registry(
                people: [rootRecord(mineRoot), rootRecord(theirs)],
                claims: [ClaimRecord(
                    newRoot: theirs, adopted: [mineRoot], claimedAt: at(60))]),
            cache: store, mine: mine, for: project)
            .filter { $0.kind == .anotherClaimant }

        XCTAssertEqual(events.map(\.subject), [theirs],
                       "nothing widens on somebody else's claim")
    }

    // MARK: - This device

    func test_anEventAboutOneOfThisDevicesOwnKeysKnowsItIsThisMac() {
        let root = foreignKey()
        let registry = Registry(people: [
            rootRecord(root), admittedRecord(mine.author.fingerprint, under: root),
        ])

        let admitted = TrustEvents.derive(
            registry: registry, cache: cache(), mine: mine, for: project)
            .filter { $0.kind == .admitted }

        XCTAssertEqual(admitted.count, 1)
        XCTAssertTrue(admitted[0].isMine)
    }

    func test_anEventAboutSomebodyElseIsNotThisMac() {
        let root = foreignKey()
        let registry = Registry(people: [
            rootRecord(root), admittedRecord(foreignKey(), under: root),
        ])

        let admitted = TrustEvents.derive(
            registry: registry, cache: cache(), mine: mine, for: project)
            .filter { $0.kind == .admitted }
        XCTAssertFalse(admitted[0].isMine)
    }

    // MARK: - Order

    func test_eventsAreNewestFirstAndTheUndatedComeLast() {
        let root = foreignKey()
        let phone = foreignKey()
        let laptop = foreignKey()
        let claimant = foreignKey()
        let store = cache()
        store.join(root: root, for: project, at: at(50))
        store.recordClaimant(root: claimant, for: project)

        let registry = Registry(
            devices: [deviceRecord(laptop, retiredAt: at(90))],
            people: [
                rootRecord(root),
                admittedRecord(phone, under: root, at: 20),
                admittedRecord(laptop, under: root, at: 30),
            ])

        let events = TrustEvents.derive(
            registry: registry, cache: store, mine: mine, for: project)

        XCTAssertEqual(
            events.map(\.kind),
            [.retired, .joined, .admitted, .admitted, .anotherClaimant])
        XCTAssertEqual(events.map(\.date),
                       [at(90), at(50), at(30), at(20), nil])
    }

    /// Two events on the same instant must not swap between runs — a registry
    /// that arrives in a different order has to read the same way.
    func test_eventsOnTheSameInstantAreOrderedDeterministically() {
        let root = foreignKey()
        let a = foreignKey()
        let b = foreignKey()
        let forward = Registry(people: [
            rootRecord(root), admittedRecord(a, under: root, at: 20),
            admittedRecord(b, under: root, at: 20),
        ])
        let backward = Registry(people: [
            rootRecord(root), admittedRecord(b, under: root, at: 20),
            admittedRecord(a, under: root, at: 20),
        ])

        XCTAssertEqual(
            TrustEvents.derive(registry: forward, cache: cache(),
                               mine: mine, for: project).map(\.subject),
            TrustEvents.derive(registry: backward, cache: cache(),
                               mine: mine, for: project).map(\.subject))
    }

    func test_everyEventHasAnIdentityOfItsOwn() {
        let root = foreignKey()
        let sam = foreignKey()
        let registry = Registry(people: [
            rootRecord(root),
            admittedRecord(sam, under: root, at: 20, revokedAt: at(60), revokedBy: root),
        ])

        let ids = TrustEvents.derive(
            registry: registry, cache: cache(), mine: mine, for: project).map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    // MARK: - The carry

    /// **A restoration is a dated event** (P2b Task 10). `RegistryCache.reconcile`
    /// writes what it put back into a small bounded list, and this is the one
    /// place that reads it: a restoration leaves no trace in the folder — the
    /// file is back and looks untouched — so the memory that noticed it is the
    /// only thing that can say it happened, or when.
    func test_aRestoredRecordIsADatedEvent() throws {
        let rootIdentity = DeviceIdentity.softwareForTesting()
        let phone = DeviceIdentity.softwareForTesting()
        try RegistryWriter.write(
            rootRecord(rootIdentity.fingerprint), signedBy: rootIdentity, in: project)
        try RegistryWriter.write(
            admittedRecord(phone.fingerprint, under: rootIdentity.fingerprint),
            signedBy: rootIdentity, in: project)

        let store = cache()
        let folder = try RegistryReader.load(projectURL: project)
        store.remember(folder, for: project)

        // Somebody deletes the phone's admission.
        try FileManager.default.removeItem(
            at: RegistryWriter.url(.people, fingerprint: phone.fingerprint, in: project))
        let reconciled = try store.reconcile(
            folder: try RegistryReader.load(projectURL: project),
            cached: store.cached(for: project), in: project,
            at: at(900)).registry

        let events = TrustEvents.derive(
            registry: reconciled, cache: store, mine: mine, for: project)
            .filter { $0.kind == .recordRestored }

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].subject, phone.fingerprint)
        XCTAssertEqual(events[0].date, at(900),
                       "dated by the day it was put back, not by the day the "
                       + "pane was opened")
        XCTAssertEqual(events[0].label, "iPhone",
                       "named from the record that came back")
    }

    /// A project where nothing has been restored derives no such event.
    func test_aProjectThatLostNothingHasNoRestoredEvent() {
        let root = foreignKey()
        let store = cache()
        store.remember(Registry(people: [rootRecord(root)]), for: project)

        let events = TrustEvents.derive(
            registry: Registry(people: [rootRecord(root)]),
            cache: store, mine: mine, for: project)
        XCTAssertTrue(events.filter { $0.kind == .recordRestored }.isEmpty)
    }
}
