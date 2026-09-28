import Foundation
import MaughamCore

/// **Where this Mac finds the writer's person key** (your devices are you,
/// plan 1 Task 6) — the ONE production construction of a `PersonKeyStore`.
///
/// Production is iCloud Keychain in the team's shared access group, the shape
/// the spike proved moves between the Mac and the phone (spike note
/// 2026-09-27 §1). An ad-hoc-signed build — the dev app, CI — has no
/// entitlement, the store answers `.unavailable` (-34018), and this Mac makes
/// no claim: today's behaviour, which is the correct answer for a build that
/// cannot reach the item.
///
/// **A test host never reaches the keychain at all.** Every suite that opens a
/// `DocumentStore` would otherwise query the developer's keychain from seven
/// parallel workers, and a host that happened to be signed with the team would
/// CREATE a synchronizable item on the developer's own Apple ID. So a host
/// with nothing injected gets a store that has no item and refuses to create
/// one — no key, no claim, every existing suite behaviour-neutral — and a
/// suite that wants a key injects an `InMemoryPersonKeyStore`.
enum PersonKeyAccess {

    /// The team whose access group holds the item. Not a variant fact
    /// (tripwire 13): both variants are signed by one team, and the item is
    /// the PERSON's, shared by every Maugham on the Apple ID.
    static let teamID = "FF3XH4ZJ45"

    /// Test-only: the store a suite injects. Process-wide, so a suite that
    /// sets it clears it in `tearDown`, like `Document`'s other seams.
    nonisolated(unsafe) static var storeForTesting: (any PersonKeyStore)?

    /// The store this process uses.
    static var store: any PersonKeyStore {
        store(injected: storeForTesting, isTestHost: TestHost.isActive)
    }

    /// The decision, pure over its two inputs so the test-host arm is
    /// pinnable from inside a test host.
    static func store(
        injected: (any PersonKeyStore)?, isTestHost: Bool
    ) -> any PersonKeyStore {
        if let injected { return injected }
        if isTestHost {
            let none = InMemoryPersonKeyStore()
            none.refusesCreate = true
            return none
        }
        return KeychainPersonKeyStore(
            accessGroup: KeychainPersonKeyStore.accessGroup(teamID: teamID))
    }
}
