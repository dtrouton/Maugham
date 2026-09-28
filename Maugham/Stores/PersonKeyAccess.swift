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
        // The decision is Core's (`PersonKeyStoreChoice`); the construction
        // SITE is this file's, which is what tripwire 53 counts.
        switch PersonKeyStoreChoice.choose(injected: injected, isTestHost: isTestHost) {
        case .injected(let store):
            return store
        case .testHost:
            let none = InMemoryPersonKeyStore()
            none.refusesCreate = true
            return none
        case .keychain(let accessGroup):
            return KeychainPersonKeyStore(accessGroup: accessGroup)
        }
    }
}
