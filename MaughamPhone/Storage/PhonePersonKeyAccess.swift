import Foundation
import MaughamCore

/// **Where this phone finds the writer's person key** (your devices are you,
/// plan 2 Task 1) — the phone's ONE construction of a `PersonKeyStore`, the
/// twin of the Mac's `PersonKeyAccess` (census: `PersonKeyCensusTests`,
/// tripwire 53, under `MaughamPhone/PhonePersonKeyAccess.swift`).
///
/// Production is iCloud Keychain in the team's shared access group — the same
/// group the Mac reads, which is the whole point: the item the Mac seeded with
/// the writer's name is the item this phone finds. A build without the
/// entitlement reads `.unavailable` (-34018) and this phone makes no claim,
/// which is exactly what it did before.
///
/// **A test host never reaches the keychain at all**, and the simulator may
/// not enforce access groups — so an unentitled test host is NOT safe by
/// itself, and this guard is what keeps a test from reading, or creating, a
/// synchronizable item on the developer's own Apple ID. A host with nothing
/// injected gets a store that holds no item and refuses to create one: no
/// key, no claim, every existing phone suite behaviour-neutral.
///
/// The decision is Core's `PersonKeyStoreChoice`, shared with the Mac's
/// `PersonKeyAccess`; the host flag is this file's, because the phone cannot
/// import the Mac's `TestHost` — it reads the same three environment keys.
enum PhonePersonKeyAccess {

    /// Test-only: the store a suite injects. Process-wide, so a suite that
    /// sets it clears it in `tearDown`.
    nonisolated(unsafe) static var storeForTesting: (any PersonKeyStore)?

    /// Whether this process is an XCTest host — MaughamCore's
    /// `TestProcess.isActive`, never a build flag, so the Debug app a developer
    /// runs by hand is not mistaken for one. The same answer as the Mac's
    /// `TestHost`.
    static var isTestHost: Bool { TestProcess.isActive }

    /// The store this process uses.
    static var store: any PersonKeyStore {
        store(injected: storeForTesting, isTestHost: isTestHost)
    }

    /// The decision, pure over its two inputs so the test-host arm is
    /// pinnable from inside a test host.
    static func store(
        injected: (any PersonKeyStore)?, isTestHost: Bool
    ) -> any PersonKeyStore {
        // The decision and the team are Core's (`PersonKeyStoreChoice`); the
        // construction SITE is this file's, which is what tripwire 53 counts.
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
