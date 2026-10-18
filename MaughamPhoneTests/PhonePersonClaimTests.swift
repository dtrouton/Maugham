import XCTest
@testable import MaughamCore
@testable import MaughamPhone

/// **This phone says whose it is** (your devices are you, plan 2 Task 1): the
/// phone's device record carries a person claim signed with the writer's
/// person key, made through the same Core doors the Mac's open uses
/// (tripwire 19), and the phone names itself *"<first name>'s <model>"* only
/// where iOS gave it nothing better (P2-2).
///
/// Every key here is an `InMemoryPersonKeyStore`'s. No test reaches a real
/// keychain — the first section pins the guard that makes that so.
@MainActor
final class PhonePersonClaimTests: XCTestCase {

    private var projectRoot: URL!
    private var phone: LocalIdentities!

    override func setUp() async throws {
        projectRoot = TestTemp.root
            .appendingPathComponent("phone-claim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectRoot, withIntermediateDirectories: true)
        phone = .softwareForTesting()
        PhoneDeviceRecord.forgetDeclarationsForTesting()
        PhonePersonKeyAccess.storeForTesting = nil
    }

    override func tearDown() async throws {
        PhonePersonKeyAccess.storeForTesting = nil
        PhoneDeviceRecord.forgetDeclarationsForTesting()
        try? FileManager.default.removeItem(at: projectRoot)
    }

    /// The person's key item, as the Mac's first open seeds it.
    private func denversStore() throws -> InMemoryPersonKeyStore {
        let store = InMemoryPersonKeyStore()
        _ = try XCTUnwrap(PersonKey.findOrCreate(in: store, seedName: "Denver Trouton"))
        return store
    }

    private func ensure(
        name: String = "iPhone", model: String = "iPhone",
        declare: ((URL, LocalIdentities, String, (intent: PersonClaimIntent, problem: String?)) throws -> String?)? = nil
    ) async {
        if let declare {
            await PhoneDeviceRecord.ensure(
                in: projectRoot, identity: phone.author, identities: phone,
                name: name, model: model, declare: declare)
        } else {
            await PhoneDeviceRecord.ensure(
                in: projectRoot, identity: phone.author, identities: phone,
                name: name, model: model)
        }
    }

    private func registry() throws -> Registry {
        try RegistryReader.load(projectURL: projectRoot)
    }

    // MARK: - The test host never reaches a keychain (Review Focus 2)

    /// The guard itself: this process IS a test host, and with nothing
    /// injected it gets a store that has no item and refuses to create one —
    /// never the keychain, which the simulator may not fence by access group.
    func test_aTestHostWithNothingInjectedGetsAStoreThatCannotCreate() {
        XCTAssertTrue(PhonePersonKeyAccess.isTestHost,
                      "XCTest's own environment names this process a test host")
        let store = PhonePersonKeyAccess.store
        // A guard, not an assertion: if the arm ever breaks, this test must
        // fail WITHOUT then querying the keychain it was handed.
        guard !(store is KeychainPersonKeyStore) else {
            return XCTFail("a test host must never be handed the keychain")
        }
        XCTAssertNil(PersonKey.find(in: store))
        XCTAssertNil(PersonKey.findOrCreate(in: store, seedName: ""),
                     "no key, and none created")
    }

    /// The decision both ways, pure: production is the keychain in the team's
    /// group; an injected store wins over both arms.
    func test_theStoreDecisionBothWays() throws {
        let production = PhonePersonKeyAccess.store(injected: nil, isTestHost: false)
        let keychain = try XCTUnwrap(production as? KeychainPersonKeyStore)
        XCTAssertEqual(keychain.accessGroup, "FF3XH4ZJ45.com.maugham.person")

        let host = PhonePersonKeyAccess.store(injected: nil, isTestHost: true)
        XCTAssertTrue(host is InMemoryPersonKeyStore)

        let injected = InMemoryPersonKeyStore()
        XCTAssertTrue(PhonePersonKeyAccess.store(injected: injected, isTestHost: false)
                      as? InMemoryPersonKeyStore === injected)
        XCTAssertTrue(PhonePersonKeyAccess.store(injected: injected, isTestHost: true)
                      as? InMemoryPersonKeyStore === injected)
    }

    /// And through the writer: a capture in a test host with nothing injected
    /// writes a record with no claim.
    func test_aCaptureInATestHostMakesNoClaim() async throws {
        let writer = InboxCaptureWriter(projectRoot: projectRoot, identity: phone.author)
        _ = try await writer.writeText("On the train")
        XCTAssertTrue(try registry().verifiedPersonClaims.isEmpty)
        XCTAssertEqual(try registry().devices.count, 1)
    }

    // MARK: - The name rule (P2-2, Review Focus 5)

    func test_aGenericSystemNameBecomesTheFirstNamesModel() {
        XCTAssertEqual(PhoneDeviceRecord.deviceName(
            system: "iPhone", model: "iPhone", personName: "Denver Trouton"),
            "Denver’s iPhone")
        XCTAssertEqual(PhoneDeviceRecord.deviceName(
            system: "iPad", model: "iPad", personName: "  Denver\tTrouton "),
            "Denver’s iPad", "the first whitespace-delimited word, trimmed")
    }

    func test_aRealNameIsNeverOverwritten() {
        XCTAssertEqual(PhoneDeviceRecord.deviceName(
            system: "Kitchen phone", model: "iPhone", personName: "Denver Trouton"),
            "Kitchen phone")
        XCTAssertEqual(PhoneDeviceRecord.deviceName(
            system: "Denver's iPhone", model: "iPhone", personName: "Sam"),
            "Denver's iPhone", "a name the writer gave the phone stands")
        XCTAssertEqual(PhoneDeviceRecord.deviceName(
            system: "iphone", model: "iPhone", personName: "Denver"),
            "iphone", "generic means EQUAL to the model — not a near miss")
    }

    func test_withNoPersonNameTheSystemNameStands() {
        XCTAssertEqual(PhoneDeviceRecord.deviceName(
            system: "iPhone", model: "iPhone", personName: ""), "iPhone")
        XCTAssertEqual(PhoneDeviceRecord.deviceName(
            system: "iPhone", model: "iPhone", personName: "   "), "iPhone")
    }

    // MARK: - The claim

    func test_withAKeyTheRecordCarriesAClaimForThisPhoneAndItsName() async throws {
        let store = try denversStore()
        PhonePersonKeyAccess.storeForTesting = store

        await ensure()

        let registry = try registry()
        let claim = try XCTUnwrap(registry.verifiedPersonClaims[phone.author.fingerprint],
                                  "a claim the shared reader verifies for THIS phone")
        let key = try XCTUnwrap(PersonKey.findOrCreate(in: store, seedName: ""))
        XCTAssertEqual(claim.personKey, key.fingerprint)
        XCTAssertEqual(claim.name, "Denver Trouton")
        XCTAssertEqual(registry.devices.first?.name, "Denver’s iPhone")
        XCTAssertEqual(registry.devices.first?.kind, .phone)
        XCTAssertTrue(registry.malformed.isEmpty)
        XCTAssertEqual(store.createCount, 1, "the Mac's one mint; the phone only found it")
    }

    /// **The phone never mints a person key** (controller ruling 5). A phone
    /// whose key has not synced yet finds nothing, creates nothing, names
    /// nothing, and makes no claim — the Mac's sheet asks once, and a later
    /// write claims when the key arrives (`test_aKeyThatAppearsMidRunIsDeclaredOnce`).
    func test_aPhoneWhoseKeyHasNotSyncedCreatesNothingAndClaimsNothing() async throws {
        let store = InMemoryPersonKeyStore()   // absent, and WILLING to create
        PhonePersonKeyAccess.storeForTesting = store

        await ensure()

        XCTAssertEqual(store.createCount, 0, "no item minted on the phone")
        XCTAssertEqual(store.setNameCount, 0, "and none named")
        XCTAssertEqual(store.find(), .absent)
        XCTAssertNil(try registry().verifiedPersonClaims[phone.author.fingerprint])
        XCTAssertEqual(try registry().devices.first?.name, "iPhone",
                       "no person name, so the system name stands")
    }

    /// And an item with an EMPTY name is not named by the phone either.
    func test_thePhoneNeverNamesAnItem() async throws {
        let store = InMemoryPersonKeyStore()
        _ = try XCTUnwrap(PersonKey.findOrCreate(in: store, seedName: ""))
        PhonePersonKeyAccess.storeForTesting = store

        await ensure()

        XCTAssertEqual(store.setNameCount, 0)
        let claim = try XCTUnwrap(try registry().verifiedPersonClaims[phone.author.fingerprint])
        XCTAssertEqual(claim.name, "")
        XCTAssertEqual(try registry().devices.first?.name, "iPhone")
    }

    /// Without a key the intent is `.keep`, never `.remove`: a keychain that
    /// cannot answer this launch is not evidence the writer left.
    func test_losingTheKeyKeepsTheClaimOnDisk() async throws {
        PhonePersonKeyAccess.storeForTesting = try denversStore()
        await ensure()
        let first = try XCTUnwrap(try registry().verifiedPersonClaims[phone.author.fingerprint])

        PhoneDeviceRecord.forgetDeclarationsForTesting()
        let gone = InMemoryPersonKeyStore()
        gone.refusesCreate = true
        PhonePersonKeyAccess.storeForTesting = gone
        var intents: [PersonClaimIntent] = []
        await ensure(name: "Kitchen phone") { url, ids, name, claim in
            intents.append(claim.intent)
            return try RegistryPresence.declareDevice(
                in: url, identities: ids, name: name, kind: .phone, claim: claim)
        }

        XCTAssertEqual(intents, [.keep])
        XCTAssertEqual(try registry().verifiedPersonClaims[phone.author.fingerprint], first,
                       "the rename rewrote the record and carried the claim through")
        XCTAssertEqual(try registry().devices.first?.name, "Kitchen phone")
    }

    /// The memo holds the claim's facts: a key that syncs in mid-run is
    /// declared once, and only once.
    func test_aKeyThatAppearsMidRunIsDeclaredOnce() async throws {
        let store = InMemoryPersonKeyStore()   // not synced yet
        PhonePersonKeyAccess.storeForTesting = store
        var intents: [PersonClaimIntent] = []
        let record: (URL, LocalIdentities, String, (intent: PersonClaimIntent, problem: String?)) throws -> String? = {
            _, _, _, claim in intents.append(claim.intent); return nil
        }

        // A name the writer chose, so the name rule moves nothing when the
        // key arrives: the ONLY new fact is the claim's.
        await ensure(name: "Kitchen phone", declare: record)
        await ensure(name: "Kitchen phone", declare: record)
        XCTAssertEqual(intents, [.keep], "no key: declared once")
        XCTAssertEqual(store.createCount, 0, "and the phone minted none")

        // iCloud Keychain delivers the Mac's item.
        let synced = try denversStore()
        PhonePersonKeyAccess.storeForTesting = synced

        await ensure(name: "Kitchen phone", declare: record)
        await ensure(name: "Kitchen phone", declare: record)
        XCTAssertEqual(intents.count, 2, "the key arrived: declared again, once")
        guard case .set(let claim) = intents.last else { return XCTFail("a claim") }
        XCTAssertEqual(claim.name, "Denver Trouton")
    }

    /// A problem the declaration answers (a refused claim — Core re-writes
    /// the record with `.keep`, `DeclareDeviceTests`) is logged, not thrown,
    /// and the declaration is remembered: it landed.
    func test_aDeclarationThatAnswersAProblemIsRememberedAndNotThrown() async throws {
        PhonePersonKeyAccess.storeForTesting = try denversStore()
        var calls = 0
        let record: (URL, LocalIdentities, String, (intent: PersonClaimIntent, problem: String?)) throws -> String? = { _, _, _, _ in
            calls += 1; return "the person claim was refused"
        }
        await ensure(declare: record)
        await ensure(declare: record)
        XCTAssertEqual(calls, 1)
    }

    /// A phone with no enclave key writes no record, so it has no business
    /// reaching for the person key at all.
    func test_anUnsignedPhoneNeverReachesForTheKey() async throws {
        let store = CountingStore()
        PhonePersonKeyAccess.storeForTesting = store
        let unsigned = DeviceIdentity.unsignedForTesting(token: Data([7, 7, 7]))
        await PhoneDeviceRecord.ensure(in: projectRoot, identity: unsigned, name: "iPhone",
                                       model: "iPhone")
        XCTAssertEqual(store.finds, 0, "never looked")
    }

    // MARK: - The round trip (Review Focus 1; `MaughamPhone/AREA.md`, Rules → iCloud and the folder: phone-written rows are byte-compatible)

    /// The Mac roots the book and links its own person key exactly as its open
    /// does (Core's `ensureDeviceRecord` + `ensureRootIfEmpty` +
    /// `admitRecognised`); the phone then CAPTURES — through the real writer,
    /// the real `PhoneDeviceRecord.ensure`, the real `ensureDeviceRecord` — and
    /// the root's own reader and recognition, run over the bytes on disk,
    /// answer `.ownDevice` and admit it silently as Denver.
    func test_thePhonesClaimIsRecognisedByTheRootsMac() async throws {
        let store = try denversStore()
        let mac = LocalIdentities.softwareForTesting()
        let denver = try XCTUnwrap(PersonKey.findOrCreate(in: store, seedName: "Denver Trouton"))
        try RegistryPresence.ensureDeviceRecord(
            in: projectRoot, identities: mac, name: "Denver's MacBook", kind: .mac,
            personClaim: .set(try RegistryWriter.personClaim(
                forDevice: mac.author.fingerprint, signedBy: denver)))
        try RegistryPresence.ensureRootIfEmpty(
            in: projectRoot, identities: mac, writerName: "Denver")
        let cache = RegistryCache(
            fileURL: TestTemp.root.appendingPathComponent("cache-\(UUID().uuidString).json"),
            identity: mac.author.fingerprint)
        _ = try RegistryPresence.admitRecognised(
            in: projectRoot, identities: mac, cache: cache)
        XCTAssertEqual(try registry().person(mac.author.fingerprint)?.personKey,
                       denver.fingerprint, "premise: the root's key is linked")

        // The phone writes, finding the same item iCloud Keychain synced.
        PhonePersonKeyAccess.storeForTesting = store
        let writer = InboxCaptureWriter(projectRoot: projectRoot, identity: phone.author)
        _ = try await writer.writeText("On the train")

        // The Mac's side, over the bytes on disk.
        let registry = try registry()
        let phoneRecord = try XCTUnwrap(
            registry.devices.first { $0.device == phone.author.fingerprint })
        let claim = try XCTUnwrap(registry.verifiedPersonClaims[phone.author.fingerprint])
        XCTAssertEqual(claim.personKey, denver.fingerprint)
        let root = try XCTUnwrap(registry.person(mac.author.fingerprint))
        XCTAssertEqual(Recognition.recognise(
            device: phoneRecord, verifiedClaim: claim, registry: registry,
            thisRoot: mac.author.fingerprint), .ownDevice(root: root))

        let pass = try RegistryPresence.admitRecognised(
            in: projectRoot, identities: mac, cache: cache)
        XCTAssertEqual(pass.admitted.map(\.person), [phone.author.fingerprint])
        XCTAssertEqual(try self.registry().person(phone.author.fingerprint)?.label, "Denver")
    }
}

/// A store that counts lookups and holds nothing.
private final class CountingStore: PersonKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var _finds = 0
    var finds: Int { lock.withLock { _finds } }
    func find() -> PersonKeyLookup { lock.withLock { _finds += 1 }; return .absent }
    func createIfAbsent(_ item: PersonKeyItem) -> PersonKeyCreation { .unavailable }
    func setName(_ name: String) -> Bool { false }
}
