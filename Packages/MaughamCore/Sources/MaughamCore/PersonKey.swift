import CryptoKit
import Foundation

/// The person key (your devices are you, plan 1 Task 2): one P256 signing key
/// per PERSON, kept in iCloud Keychain so every device signed into their Apple
/// ID holds the same one.
///
/// **This is the ONE production software key, by name** (tripwire 36's
/// allow-list entry `PersonKey.swift`). A device key must be the enclave's
/// because it proves which MACHINE wrote a line; the person key proves the
/// opposite — that several machines are one person — so it must leave the
/// machine, and a key that leaves the machine is a software key. It never
/// signs a line of manuscript: only a claim that a device belongs to a person.
///
/// Its fingerprint and its signatures are a device key's exactly
/// (`DeviceIdentity.fingerprint(of:)`, `OpLogChain.Credentials`), so a claim
/// verifies through the one `OpLogChain.credentialsVerify`.
public struct PersonKey: Sendable {
    /// SHA-256 hex over the public key's X9.63 bytes — `DeviceIdentity`'s derivation.
    public let fingerprint: String
    /// The person's name as the item carries it. May be empty.
    public let name: String
    public let publicKey: P256.Signing.PublicKey
    private let privateKey: P256.Signing.PrivateKey

    private init(privateKey: P256.Signing.PrivateKey, name: String) {
        self.privateKey = privateKey
        self.publicKey = privateKey.publicKey
        self.fingerprint = DeviceIdentity.fingerprint(of: privateKey.publicKey)
        self.name = name
    }

    /// The same key under another name — the seed a Mac just wrote.
    fileprivate func renamed(_ name: String) -> PersonKey {
        PersonKey(privateKey: privateKey, name: name)
    }

    /// Sign `digestHex`'s 32 bytes. Same three fields as a device's seal.
    public func sign(_ digestHex: String) throws -> OpLogChain.Credentials {
        let key = privateKey
        return try OpLogChain.credentials(
            signing: digestHex, publicKey: publicKey
        ) { bytes in
            try key.signature(for: bytes).rawRepresentation
        }
    }

    /// The person key in `store`, creating it when there is none.
    ///
    /// - No item: mint one named `seedName` (trimmed) and store it; if another
    ///   device won the race, adopt ITS key.
    /// - An item with an empty name and a non-empty seed: fill the name in.
    /// - A non-empty name is never overwritten.
    /// - `nil` when the store is unavailable, or the item it holds cannot be
    ///   read as a key — never a reason to mint over it, which would fork the
    ///   person on every device that syncs the replacement. `nil` means "no
    ///   claim": today's behaviour.
    public static func findOrCreate(in store: any PersonKeyStore, seedName: String) -> PersonKey? {
        let seed = seedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let item: PersonKeyItem
        switch store.find() {
        case .unavailable:
            return nil
        case .found(let found):
            item = found
        case .absent:
            let minted = mintItem(name: seed)
            switch store.createIfAbsent(minted) {
            case .created: item = minted
            case .alreadyPresent(let winner): item = winner
            case .unavailable: return nil
            }
        }

        guard let found = key(from: item) else { return nil }

        let stored = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if stored.isEmpty && !seed.isEmpty {
            // The name is a courtesy; the key is the identity. A failed write
            // still yields the key, under the name this device tried to give it.
            _ = store.setName(seed)
            return found.renamed(seed)
        }
        return found
    }

    /// **The person key in `store`, if there is one — never creating it and
    /// never naming it** (your devices are you, plan 2 Task 1, controller
    /// ruling 5). The phone's entry: iOS gives an app no owner name, and a
    /// phone that minted would fork the person the moment its item and a
    /// Mac's crossed in iCloud Keychain. So the phone only FINDS; a phone whose
    /// key has not synced yet makes no claim, and claims on a later write once
    /// the Mac's item arrives. `findOrCreate` is the Mac's.
    ///
    /// Nil for no item, an unavailable store, or an item that is not a key.
    public static func find(in store: any PersonKeyStore) -> PersonKey? {
        finding(in: store).key
    }

    /// **`find`, saying WHY there is no key** (plan 2 Task 2) — the phone's
    /// Settings line tells the writer which of the three it is, because on a
    /// phone that never mints, *no key* is not *iCloud Keychain is off*: the
    /// Mac may simply not have made one yet, or it has not synced. Never
    /// creates and never names, exactly as `find`.
    public static func finding(in store: any PersonKeyStore) -> PersonKeyFinding {
        switch store.find() {
        case .absent: return .absent
        case .unavailable: return .unavailable
        case .found(let item):
            guard let found = key(from: item) else { return .notAKey }
            return .found(found)
        }
    }

    /// An item's key, when its bytes are one — the private key parses and its
    /// public key is the one the item names. Shared by both entries.
    private static func key(from item: PersonKeyItem) -> PersonKey? {
        guard let key = try? P256.Signing.PrivateKey(rawRepresentation: item.privateKey),
              key.publicKey.x963Representation == item.publicKey
        else { return nil }
        return PersonKey(privateKey: key, name: item.name)
    }

    /// A fresh item: a new software key and `name`. The one mint site.
    static func mintItem(name: String) -> PersonKeyItem {
        let key = P256.Signing.PrivateKey()
        return PersonKeyItem(
            privateKey: key.rawRepresentation,
            publicKey: key.publicKey.x963Representation,
            name: name)
    }
}

/// What looking for the person key found (`PersonKey.finding(in:)`).
public enum PersonKeyFinding: Sendable {
    /// The key, under the name its item carries (which may be empty).
    case found(PersonKey)
    /// The store answered, and holds no item.
    case absent
    /// The store could not answer — no entitlement, iCloud Keychain off or
    /// locked, an item that would not decode (`PersonKeyLookup.unavailable`).
    case unavailable
    /// An item is there, but its bytes are not a key.
    case notAKey

    /// The key, where there is one.
    public var key: PersonKey? {
        if case .found(let key) = self { return key }
        return nil
    }
}
