import XCTest
@testable import MaughamCore
@testable import MaughamPhone

/// **Settings' device-wide person-key line** (your devices are you, plan 2
/// Task 2): every state's sentence, pinned verbatim, and the look it is made
/// from — the claim's own (`PhoneDeviceRecord.findPersonKey`), never a
/// keychain in a test host.
@MainActor
final class PersonKeyLineTests: XCTestCase {

    override func setUp() async throws {
        PhonePersonKeyAccess.storeForTesting = nil
    }

    override func tearDown() async throws {
        PhonePersonKeyAccess.storeForTesting = nil
    }

    // MARK: - Every sentence

    func test_everyStateSaysItsOwnSentence() {
        XCTAssertEqual(PersonKeyLine.recognised(name: "Denver Trouton").sentence,
                       "Recognised as Denver Trouton on your other devices.")
        XCTAssertEqual(PersonKeyLine.recognisedUnnamed.sentence,
                       "Recognised on your other devices. Your name shows here once a Mac has named you.")
        XCTAssertEqual(PersonKeyLine.notYetHere.sentence,
                       "Not recognised yet. Your Mac makes the key, and this phone picks it up through iCloud Keychain. Until then, your Mac asks who this phone is.")
        XCTAssertEqual(PersonKeyLine.keychainUnreachable.sentence,
                       "iCloud Keychain isn\u{2019}t reachable from this phone, so your Mac asks who this phone is instead of recognising it.")
        XCTAssertEqual(PersonKeyLine.unreadableKey.sentence,
                       "The key in iCloud Keychain couldn\u{2019}t be read, so your Mac asks who this phone is instead of recognising it.")
        XCTAssertEqual(PersonKeyLine.cannotSign.sentence,
                       "This phone has no key of its own to sign with, so your Mac asks who this phone is instead of recognising it.")
    }

    /// Only a found key says *Recognised*; nothing without one does — the
    /// rule in both directions.
    func test_onlyAFoundKeySaysRecognised() {
        let all: [PersonKeyLine] = [
            .recognised(name: "D"), .recognisedUnnamed, .notYetHere,
            .keychainUnreachable, .unreadableKey, .cannotSign]
        for line in all {
            let found: Bool
            switch line {
            case .recognised, .recognisedUnnamed: found = true
            default: found = false
            }
            XCTAssertEqual(line.sentence.hasPrefix("Recognised"), found, "\(line)")
        }
    }

    // MARK: - From the finding

    func test_eachFindingMakesItsLine() throws {
        XCTAssertEqual(PersonKeyLine.make(nil), .cannotSign)
        XCTAssertEqual(PersonKeyLine.make(.absent), .notYetHere)
        XCTAssertEqual(PersonKeyLine.make(.unavailable), .keychainUnreachable)
        XCTAssertEqual(PersonKeyLine.make(.notAKey), .unreadableKey)

        let named = InMemoryPersonKeyStore()
        _ = try XCTUnwrap(PersonKey.findOrCreate(in: named, seedName: "  Denver Trouton "))
        XCTAssertEqual(PersonKeyLine.make(PersonKey.finding(in: named)),
                       .recognised(name: "Denver Trouton"))

        let unnamed = InMemoryPersonKeyStore()
        _ = try XCTUnwrap(PersonKey.findOrCreate(in: unnamed, seedName: ""))
        XCTAssertEqual(PersonKeyLine.make(PersonKey.finding(in: unnamed)), .recognisedUnnamed)
    }

    // MARK: - The look is the claim's

    /// Settings reads through the claim's reader: an injected key is found,
    /// and a phone that cannot sign never looks at all.
    func test_theLineReadsThroughTheClaimsOneReader() throws {
        let store = LookCountingStore(item: nil)
        PhonePersonKeyAccess.storeForTesting = store
        XCTAssertNil(PhoneDeviceRecord.findPersonKey(canSign: false))
        XCTAssertEqual(store.finds, 0, "a phone that cannot sign never looks")
        guard case .absent = PhoneDeviceRecord.findPersonKey(canSign: true)
        else { return XCTFail("a signing phone looks, and finds nothing") }
        XCTAssertEqual(store.finds, 1)

        let denver = InMemoryPersonKeyStore()
        _ = try XCTUnwrap(PersonKey.findOrCreate(in: denver, seedName: "Denver Trouton"))
        PhonePersonKeyAccess.storeForTesting = denver
        XCTAssertEqual(PersonKeyLine.make(PhoneDeviceRecord.findPersonKey(canSign: true)),
                       .recognised(name: "Denver Trouton"))
    }

    /// With nothing injected, a test host's look is the empty in-memory
    /// store's — absent, never the keychain's unavailable, and nothing made.
    func test_aTestHostLooksAtNoKeychain() {
        XCTAssertTrue(PhonePersonKeyAccess.isTestHost)
        guard case .absent = PhoneDeviceRecord.findPersonKey(canSign: true)
        else { return XCTFail("the host's store holds no item") }
    }
}

/// A store that counts looks.
private final class LookCountingStore: PersonKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var _finds = 0
    private let item: PersonKeyItem?
    init(item: PersonKeyItem?) { self.item = item }
    var finds: Int { lock.withLock { _finds } }
    func find() -> PersonKeyLookup {
        lock.withLock { _finds += 1 }
        return item.map(PersonKeyLookup.found) ?? .absent
    }
    func createIfAbsent(_ item: PersonKeyItem) -> PersonKeyCreation { .unavailable }
    func setName(_ name: String) -> Bool { false }
}
