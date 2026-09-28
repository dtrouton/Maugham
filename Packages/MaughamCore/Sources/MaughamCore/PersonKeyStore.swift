import Foundation
import Security

/// Where the person key lives (your devices are you, plan 1 Task 2).
///
/// The production store is iCloud Keychain (`KeychainPersonKeyStore`), which
/// hands the same item to every device signed into one Apple ID. The gate's
/// store is `InMemoryPersonKeyStore`: an ad-hoc-signed build gets `-34018`
/// from the keychain (spike note 2026-09-27 §3), and a test must never create
/// a synchronizable item on the developer's own account anyway.
///
/// Nothing here THROWS. A store that cannot answer says `.unavailable`, and
/// the caller carries on exactly as a build with no person key does — no
/// claim, today's admission sheet — because the person key is an optional
/// convenience and a keychain hiccup must never block opening a book.
public protocol PersonKeyStore: Sendable {
    /// The one item, if there is one.
    func find() -> PersonKeyLookup
    /// Store `item` only if no item exists. A store that finds one already
    /// there answers `.alreadyPresent` with IT, so two devices racing to
    /// create adopt one key rather than forking the person.
    func createIfAbsent(_ item: PersonKeyItem) -> PersonKeyCreation
    /// Rewrite the existing item's name, keeping its key. `false` when there
    /// is no item or the store could not write.
    func setName(_ name: String) -> Bool
}

/// The item's shape: the private key's raw bytes, its public key's X9.63
/// bytes, and the person's name. Encoded as JSON into the keychain item's data.
public struct PersonKeyItem: Codable, Equatable, Sendable {
    public var privateKey: Data
    public var publicKey: Data
    public var name: String

    public init(privateKey: Data, publicKey: Data, name: String) {
        self.privateKey = privateKey
        self.publicKey = publicKey
        self.name = name
    }
}

public enum PersonKeyLookup: Equatable, Sendable {
    case found(PersonKeyItem)
    case absent
    /// The store could not answer — no entitlement, no iCloud Keychain, a
    /// locked keychain, an item we cannot decode. Never a reason to create.
    case unavailable
}

public enum PersonKeyCreation: Equatable, Sendable {
    case created
    case alreadyPresent(PersonKeyItem)
    case unavailable
}

// MARK: - In memory

/// The gate's store. Counts its writes so a test can say "found, not created".
public final class InMemoryPersonKeyStore: PersonKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var item: PersonKeyItem?
    private var _createCount = 0
    private var _setNameCount = 0
    private var _refusesCreate = false
    private var _refusesSetName = false

    public init(item: PersonKeyItem? = nil) {
        self.item = item
    }

    public var createCount: Int { lock.withLock { _createCount } }
    public var setNameCount: Int { lock.withLock { _setNameCount } }
    /// Answer `.unavailable` to every create, as a keychain that will not write does.
    public var refusesCreate: Bool {
        get { lock.withLock { _refusesCreate } }
        set { lock.withLock { _refusesCreate = newValue } }
    }
    /// Answer `false` to every name write.
    public var refusesSetName: Bool {
        get { lock.withLock { _refusesSetName } }
        set { lock.withLock { _refusesSetName = newValue } }
    }

    public func find() -> PersonKeyLookup {
        lock.withLock { item.map(PersonKeyLookup.found) ?? .absent }
    }

    public func createIfAbsent(_ newItem: PersonKeyItem) -> PersonKeyCreation {
        lock.withLock {
            if _refusesCreate { return .unavailable }
            if let item { return .alreadyPresent(item) }
            item = newItem
            _createCount += 1
            return .created
        }
    }

    public func setName(_ name: String) -> Bool {
        lock.withLock {
            guard !_refusesSetName, item != nil else { return false }
            item?.name = name
            _setNameCount += 1
            return true
        }
    }
}

// MARK: - iCloud Keychain

/// The person key as one synchronizable generic-password item in a shared,
/// team-prefixed access group — the exact shape the spike proved moves between
/// the Mac and the phone (spike note 2026-09-27 §1). The access group is
/// INJECTED: which group a build is entitled to is the app's decision
/// (`accessGroup(teamID:)` is the production spelling), not Core's.
///
/// Every `OSStatus` other than success or not-found maps to `.unavailable` —
/// `-34018` (an ad-hoc build, no entitlement), a locked keychain, iCloud
/// Keychain off, anything. The `SecItem*` calls are exercised only by plan 2's
/// signed dry run; the gate tests the pure query and status-mapping halves.
public struct KeychainPersonKeyStore: PersonKeyStore {
    /// One fixed service and account: there is one person key per Apple ID.
    public static let service = "com.maugham.person-key"
    public static let account = "person-key"
    /// The group's suffix after the team id. Both apps' RELEASE builds are
    /// entitled to it (plan 2 Task 5, ruling P2-4: `keychain-access-groups`
    /// naming it — the literal `FF3XH4ZJ45.` prefix on the Mac, whose
    /// Developer ID profile grants it; `$(AppIdentifierPrefix)` on the
    /// phone). Debug and ad-hoc builds stay unentitled and read
    /// `.unavailable` (`-34018`), as does a Mac build whose profile has
    /// expired.
    public static let accessGroupSuffix = "com.maugham.person"

    /// `<TEAMID>.com.maugham.person` — the production access group.
    public static func accessGroup(teamID: String) -> String {
        "\(teamID).\(accessGroupSuffix)"
    }

    public let accessGroup: String

    public init(accessGroup: String) {
        self.accessGroup = accessGroup
    }

    // MARK: Queries (pure)

    func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: true,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    func findQuery() -> [String: Any] {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }

    func addQuery(data: Data) -> [String: Any] {
        var query = baseQuery()
        query[kSecValueData as String] = data
        // A synchronizable item cannot be `…ThisDeviceOnly`.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return query
    }

    /// The one reading of a lookup's status. Anything but a decodable success
    /// or a plain not-found is `.unavailable`.
    static func lookup(status: OSStatus, data: Data?) -> PersonKeyLookup {
        switch status {
        case errSecSuccess:
            guard let data, let item = try? JSONDecoder().decode(PersonKeyItem.self, from: data)
            else { return .unavailable }
            return .found(item)
        case errSecItemNotFound:
            return .absent
        default:
            return .unavailable
        }
    }

    // MARK: PersonKeyStore

    public func find() -> PersonKeyLookup {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(findQuery() as CFDictionary, &result)
        return Self.lookup(status: status, data: result as? Data)
    }

    public func createIfAbsent(_ item: PersonKeyItem) -> PersonKeyCreation {
        guard let data = try? JSONEncoder().encode(item) else { return .unavailable }
        let status = SecItemAdd(addQuery(data: data) as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return .created
        case errSecDuplicateItem:
            if case .found(let existing) = find() { return .alreadyPresent(existing) }
            return .unavailable
        default:
            return .unavailable
        }
    }

    public func setName(_ name: String) -> Bool {
        guard case .found(var item) = find() else { return false }
        item.name = name
        guard let data = try? JSONEncoder().encode(item) else { return false }
        let status = SecItemUpdate(
            baseQuery() as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)
        return status == errSecSuccess
    }
}

// MARK: - Which store a process uses

/// **Which person-key store a process gets** (your devices are you, plan 2
/// Task 1 fix round) — the decision and the team id, once, for the Mac's
/// `PersonKeyAccess` and the phone's `PhonePersonKeyAccess` alike.
///
/// It answers an ARM, not a store: each surface keeps its own construction
/// site (tripwire 53 counts them per file) and passes its own test-host flag,
/// because neither can import the other's detection.
public enum PersonKeyStoreChoice: Sendable {
    /// A suite's injected store — it wins over both arms below.
    case injected(any PersonKeyStore)
    /// An XCTest host with nothing injected: build a store that holds no item
    /// and refuses to create one. A test host must never reach a keychain —
    /// the simulator may not fence one by access group, and a host signed with
    /// the team would CREATE an item on the developer's own Apple ID.
    case testHost
    /// Production: iCloud Keychain in this access group.
    case keychain(accessGroup: String)

    /// The team whose access group holds the item. Not a variant fact
    /// (tripwire 13): both apps and both variants are signed by one team, and
    /// the item is the PERSON's, shared by every Maugham on the Apple ID.
    public static let teamID = "FF3XH4ZJ45"

    public static func choose(
        injected: (any PersonKeyStore)?, isTestHost: Bool
    ) -> PersonKeyStoreChoice {
        if let injected { return .injected(injected) }
        if isTestHost { return .testHost }
        return .keychain(accessGroup: KeychainPersonKeyStore.accessGroup(teamID: teamID))
    }
}
