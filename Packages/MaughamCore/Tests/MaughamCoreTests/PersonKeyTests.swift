import CryptoKit
import Foundation
import Security
import XCTest
@testable import MaughamCore

/// The person key (your devices are you, plan 1 Task 2): a P256 key kept in
/// iCloud Keychain that names a PERSON across their devices. Every test here
/// runs against `InMemoryPersonKeyStore` or a stub — never a real keychain
/// item (the gate is ad-hoc signed, and a synchronizable item created from a
/// test would land on the developer's own Apple ID). The keychain store is
/// exercised here only through its pure query and status-mapping functions.
final class PersonKeyTests: XCTestCase {

    // MARK: - Create, find

    func test_anEmptyStoreGetsOneKeyNamedFromTheSeed() throws {
        let store = InMemoryPersonKeyStore()

        let key = try XCTUnwrap(PersonKey.findOrCreate(in: store, seedName: "Denver Trouton"))

        XCTAssertEqual(key.name, "Denver Trouton")
        guard case .found(let item) = store.find() else {
            return XCTFail("findOrCreate over an empty store must leave an item behind")
        }
        XCTAssertEqual(item.name, "Denver Trouton")
        XCTAssertEqual(item.publicKey, key.publicKey.x963Representation)
        XCTAssertEqual(store.createCount, 1)
    }

    func test_aSecondCallFindsTheSameKeyAndCreatesNothing() throws {
        let store = InMemoryPersonKeyStore()
        let first = try XCTUnwrap(PersonKey.findOrCreate(in: store, seedName: "Denver"))
        let second = try XCTUnwrap(PersonKey.findOrCreate(in: store, seedName: "Someone Else"))

        XCTAssertEqual(first.fingerprint, second.fingerprint)
        XCTAssertEqual(second.name, "Denver",
            "A found item's non-empty name must never be replaced by the seed.")
        XCTAssertEqual(store.createCount, 1, "The second call must find, not create.")
    }

    /// Two devices racing to create: the store answers *already present* with
    /// the winner's item, and the loser adopts it rather than forking the person.
    func test_aLostCreateRaceAdoptsTheWinnersKey() throws {
        let winnerItem = Self.freshItem(name: "Denver")
        let winnerPublic = try P256.Signing.PublicKey(x963Representation: winnerItem.publicKey)
        let store = RacingStore(winner: winnerItem)

        let key = try XCTUnwrap(PersonKey.findOrCreate(in: store, seedName: "Loser"))

        XCTAssertEqual(key.fingerprint, DeviceIdentity.fingerprint(of: winnerPublic))
        XCTAssertEqual(key.name, "Denver")
    }

    // MARK: - The seed fills an empty name and nothing else

    func test_anEmptyNameIsFilledFromTheSeed() throws {
        let store = InMemoryPersonKeyStore(item: Self.freshItem(name: ""))

        let key = try XCTUnwrap(PersonKey.findOrCreate(in: store, seedName: "Denver Trouton"))

        XCTAssertEqual(key.name, "Denver Trouton")
        XCTAssertEqual(try Self.item(of: store).name, "Denver Trouton")
        XCTAssertEqual(store.setNameCount, 1)
    }

    func test_aNonEmptyNameIsNeverOverwritten() throws {
        let store = InMemoryPersonKeyStore(item: Self.freshItem(name: "Sam"))

        let key = try XCTUnwrap(PersonKey.findOrCreate(in: store, seedName: "Denver Trouton"))

        XCTAssertEqual(key.name, "Sam")
        XCTAssertEqual(try Self.item(of: store).name, "Sam")
        XCTAssertEqual(store.setNameCount, 0)
    }

    func test_anEmptySeedWritesNothingIntoAnEmptyName() throws {
        let store = InMemoryPersonKeyStore(item: Self.freshItem(name: ""))

        let key = try XCTUnwrap(PersonKey.findOrCreate(in: store, seedName: "   "))

        XCTAssertEqual(key.name, "")
        XCTAssertEqual(store.setNameCount, 0)
    }

    /// A store that cannot write the name still yields the key — the name is a
    /// courtesy, the key is the identity — under the SEED, since that is what
    /// this device would have written.
    func test_aFailedNameWriteStillYieldsTheKey() throws {
        let store = InMemoryPersonKeyStore(item: Self.freshItem(name: ""))
        store.refusesSetName = true

        let key = try XCTUnwrap(PersonKey.findOrCreate(in: store, seedName: "Denver"))

        XCTAssertEqual(key.name, "Denver")
        XCTAssertEqual(try Self.item(of: store).name, "")
    }

    // MARK: - Fingerprint and signature

    /// The person key's fingerprint is the SAME derivation a device key's is,
    /// so a claim and a seal name keys in one vocabulary.
    func test_theFingerprintIsDeviceIdentitysDerivation() throws {
        let key = try XCTUnwrap(PersonKey.findOrCreate(
            in: InMemoryPersonKeyStore(), seedName: "Denver"))
        XCTAssertEqual(key.fingerprint, DeviceIdentity.fingerprint(of: key.publicKey))
        XCTAssertEqual(key.fingerprint.count, 64)
    }

    func test_aSignatureVerifiesThroughTheOneCredentialsVerifier() throws {
        let key = try XCTUnwrap(PersonKey.findOrCreate(
            in: InMemoryPersonKeyStore(), seedName: "Denver"))
        let digest = Self.digestHex(Data("a claim".utf8))
        let other = Self.digestHex(Data("another claim".utf8))

        let credentials = try key.sign(digest)

        XCTAssertEqual(credentials.key, key.fingerprint)
        XCTAssertTrue(OpLogChain.credentialsVerify(credentials, over: digest))
        XCTAssertFalse(OpLogChain.credentialsVerify(credentials, over: other),
            "A signature must not verify over a digest it did not sign.")
    }

    /// The found key signs as the created one did: the item's private bytes
    /// round-trip, so a claim a device made yesterday still verifies today.
    func test_aFoundKeySignsVerifiablyUnderTheSameFingerprint() throws {
        let store = InMemoryPersonKeyStore()
        let created = try XCTUnwrap(PersonKey.findOrCreate(in: store, seedName: "Denver"))
        let found = try XCTUnwrap(PersonKey.findOrCreate(in: store, seedName: "Denver"))
        let digest = Self.digestHex(Data("x".utf8))

        let credentials = try found.sign(digest)
        XCTAssertEqual(credentials.key, created.fingerprint)
        XCTAssertTrue(OpLogChain.credentialsVerify(credentials, over: digest))
    }

    // MARK: - Unavailable reports, never throws

    func test_anUnavailableStoreYieldsNoKeyAndNoThrow() {
        let store = UnavailableStore()
        XCTAssertNil(PersonKey.findOrCreate(in: store, seedName: "Denver"))
    }

    func test_aStoreThatCannotCreateYieldsNoKey() {
        let store = InMemoryPersonKeyStore()
        store.refusesCreate = true
        XCTAssertNil(PersonKey.findOrCreate(in: store, seedName: "Denver"))
    }

    /// An item whose private bytes do not parse is a KEY WE CANNOT USE, not an
    /// absent one: minting over it would fork the person's identity on every
    /// device that syncs the replacement.
    func test_anUnreadableItemIsUnavailableAndIsNeverReplaced() throws {
        let bad = PersonKeyItem(privateKey: Data([1, 2, 3]), publicKey: Data([4]), name: "Denver")
        let store = InMemoryPersonKeyStore(item: bad)

        XCTAssertNil(PersonKey.findOrCreate(in: store, seedName: "Denver"))
        XCTAssertEqual(try Self.item(of: store), bad)
        XCTAssertEqual(store.createCount, 0)
        XCTAssertEqual(store.setNameCount, 0)
    }

    /// An item whose stored public key is not its private key's is damaged too.
    func test_anItemWhosePublicKeyDisagreesIsUnavailable() throws {
        var item = Self.freshItem(name: "Denver")
        item.publicKey = Self.freshItem(name: "").publicKey
        XCTAssertNil(PersonKey.findOrCreate(in: InMemoryPersonKeyStore(item: item), seedName: ""))
    }

    // MARK: - The keychain store's pure halves

    func test_theKeychainQueryIsASynchronizableDataProtectionGenericPassword() {
        let store = KeychainPersonKeyStore(accessGroup: "TEAMID.com.example.person")
        let query = store.baseQuery()

        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, true)
        XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
        XCTAssertEqual(query[kSecAttrAccessGroup as String] as? String, "TEAMID.com.example.person")
        XCTAssertEqual(query[kSecAttrService as String] as? String, KeychainPersonKeyStore.service)
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, KeychainPersonKeyStore.account)

        let find = store.findQuery()
        XCTAssertEqual(find[kSecReturnData as String] as? Bool, true)
        XCTAssertEqual(find[kSecMatchLimit as String] as? String, kSecMatchLimitOne as String)
        XCTAssertEqual(find[kSecAttrSynchronizable as String] as? Bool, true)

        let data = Data("{}".utf8)
        let add = store.addQuery(data: data)
        XCTAssertEqual(add[kSecValueData as String] as? Data, data)
        XCTAssertEqual(add[kSecAttrSynchronizable as String] as? Bool, true)
        XCTAssertEqual(add[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlock as String,
            "A synchronizable item cannot be ThisDeviceOnly.")
        XCTAssertNil(add[kSecReturnData as String])
    }

    func test_theProductionAccessGroupIsTeamPrefixed() {
        XCTAssertEqual(KeychainPersonKeyStore.accessGroup(teamID: "FF3XH4ZJ45"),
                       "FF3XH4ZJ45." + KeychainPersonKeyStore.accessGroupSuffix)
    }

    func test_everyKeychainFailureMapsToUnavailable() throws {
        let item = Self.freshItem(name: "Denver")
        let data = try JSONEncoder().encode(item)

        XCTAssertEqual(KeychainPersonKeyStore.lookup(status: errSecSuccess, data: data), .found(item))
        XCTAssertEqual(KeychainPersonKeyStore.lookup(status: errSecItemNotFound, data: nil), .absent)
        XCTAssertEqual(KeychainPersonKeyStore.lookup(status: -34018, data: nil), .unavailable,
            "errSecMissingEntitlement is what an ad-hoc build gets (spike §3).")
        XCTAssertEqual(KeychainPersonKeyStore.lookup(status: errSecInteractionNotAllowed, data: nil),
                       .unavailable)
        XCTAssertEqual(KeychainPersonKeyStore.lookup(status: errSecSuccess, data: Data("junk".utf8)),
                       .unavailable)
        XCTAssertEqual(KeychainPersonKeyStore.lookup(status: errSecSuccess, data: nil), .unavailable)
    }

    // MARK: - Helpers

    static func digestHex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func freshItem(name: String) -> PersonKeyItem {
        PersonKey.mintItem(name: name)
    }

    static func item(of store: InMemoryPersonKeyStore) throws -> PersonKeyItem {
        guard case .found(let item) = store.find() else {
            throw XCTSkip("store holds no item")
        }
        return item
    }
}

/// A store whose keychain refuses everything, as an ad-hoc build's does.
private struct UnavailableStore: PersonKeyStore {
    func find() -> PersonKeyLookup { .unavailable }
    func createIfAbsent(_ item: PersonKeyItem) -> PersonKeyCreation { .unavailable }
    func setName(_ name: String) -> Bool { false }
}

/// Reports absent on the first find, then loses the create to `winner`.
private final class RacingStore: PersonKeyStore, @unchecked Sendable {
    let winner: PersonKeyItem
    init(winner: PersonKeyItem) { self.winner = winner }
    func find() -> PersonKeyLookup { .absent }
    func createIfAbsent(_ item: PersonKeyItem) -> PersonKeyCreation { .alreadyPresent(winner) }
    func setName(_ name: String) -> Bool { false }
}
