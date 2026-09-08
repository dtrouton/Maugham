import CryptoKit
import XCTest
@testable import MaughamCore

/// `DeviceIdentity` — the device's own signing key, persisted by the app as a
/// plain file under Application Support (never a keychain item, never an
/// entitlement). The enclave path is exercised only where an enclave exists;
/// everywhere else (CI's VM runner) the token path is the whole story.
final class DeviceIdentityTests: XCTestCase {

    private var directories: [URL] = []

    override func tearDown() async throws {
        for url in directories { try? FileManager.default.removeItem(at: url) }
        directories = []
    }

    /// A fresh, empty directory that tearDown will remove.
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("device-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url)
        return url
    }

    private func entries(of directory: URL) throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .sorted()
    }

    // MARK: - (a) A second load reuses what the first one minted

    func test_aSecondLoadAnswersTheSameIdentityAndMintsNothing() throws {
        let dir = try makeDirectory()

        let first = try DeviceIdentity.load(from: dir, actor: .author)
        let afterFirst = try entries(of: dir)
        XCTAssertEqual(afterFirst.count, 1,
            "One load should leave exactly one file behind — the key blob or the "
            + "token. Found: \(afterFirst)")
        let mintedAt = try FileManager.default
            .attributesOfItem(atPath: dir.appendingPathComponent(afterFirst[0]).path)[.modificationDate] as? Date

        let second = try DeviceIdentity.load(from: dir, actor: .author)

        XCTAssertEqual(first.deviceId, second.deviceId)
        XCTAssertEqual(first.fingerprint, second.fingerprint)
        XCTAssertEqual(first.publicKey?.rawRepresentation, second.publicKey?.rawRepresentation)
        XCTAssertEqual(try entries(of: dir), afterFirst,
            "The second load minted something. It must read what the first one wrote.")
        let mtimeNow = try FileManager.default
            .attributesOfItem(atPath: dir.appendingPathComponent(afterFirst[0]).path)[.modificationDate] as? Date
        XCTAssertEqual(mintedAt, mtimeNow,
            "The second load rewrote the key material — it must not touch it.")
    }

    /// The id is the actor's name and 16 hex characters off a 64-hex
    /// fingerprint, whichever path minted it — the author's included, so a
    /// per-device file reads as itself (`<doc>.author-<16hex>-<8hex>.jsonl`).
    func test_theIdIsTheActorsNameAndSixteenHexOffTheSixtyFourHexFingerprint() throws {
        let identity = try DeviceIdentity.load(from: try makeDirectory(), actor: .author)
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        XCTAssertEqual(identity.fingerprint.count, 64)
        XCTAssertEqual(identity.deviceId, "author-\(identity.fingerprint.prefix(16))")
        XCTAssertTrue(identity.fingerprint.unicodeScalars.allSatisfy(hex.contains),
            "Fingerprint is lowercase hex: \(identity.fingerprint)")
        XCTAssertEqual(identity.actor, .author)
    }

    // MARK: - (b) Two directories are two devices

    func test_twoDirectoriesAnswerDifferentIdentities() throws {
        let one = try DeviceIdentity.load(from: try makeDirectory(), actor: .author)
        let two = try DeviceIdentity.load(from: try makeDirectory(), actor: .author)
        XCTAssertNotEqual(one.deviceId, two.deviceId)
        XCTAssertNotEqual(one.fingerprint, two.fingerprint)
    }

    // MARK: - (c) The software signer's signature verifies

    func test_theSoftwareSignersSignatureVerifiesUnderItsPublicKey() throws {
        let identity = DeviceIdentity.softwareForTesting()
        XCTAssertTrue(identity.canSign)
        let publicKey = try XCTUnwrap(identity.publicKey)

        let digest = Data(SHA256.hash(data: Data("the words are safe".utf8)))
        let raw = try identity.sign(digest)

        XCTAssertEqual(raw.count, 64, "A P256 signature's raw representation is 64 bytes.")
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: raw)
        XCTAssertTrue(publicKey.isValidSignature(signature, for: digest))

        var tampered = digest
        tampered[0] ^= 0xFF
        XCTAssertFalse(publicKey.isValidSignature(signature, for: tampered),
            "The signature must not verify over different bytes.")
    }

    func test_theSoftwareSignersFingerprintIsItsOwnPublicKeysFingerprint() throws {
        let identity = DeviceIdentity.softwareForTesting()
        let publicKey = try XCTUnwrap(identity.publicKey)
        XCTAssertEqual(identity.fingerprint, DeviceIdentity.fingerprint(of: publicKey))
    }

    // MARK: - (d) The unsigned twin refuses to sign

    func test_anUnsignedIdentityThrowsRatherThanSigning() throws {
        let identity = DeviceIdentity.unsignedForTesting(token: Data(repeating: 7, count: 32))
        XCTAssertFalse(identity.canSign)
        XCTAssertNil(identity.publicKey)
        XCTAssertThrowsError(try identity.sign(Data(repeating: 1, count: 32))) { error in
            XCTAssertEqual(error as? DeviceIdentityError, .unsigned)
        }
    }

    func test_anUnsignedIdentitysFingerprintIsTheHashOfItsToken() throws {
        let token = Data(repeating: 7, count: 32)
        let identity = DeviceIdentity.unsignedForTesting(token: token)
        let expected = Data(SHA256.hash(data: token)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(identity.fingerprint, expected)
    }

    // MARK: - (e) The one enclave test

    func test_onAnEnclaveMachineTheKeyIsMintedOnceAndSigns() throws {
        try XCTSkipUnless(SecureEnclave.isAvailable,
            "No Secure Enclave on this machine — the token path covers the rest.")
        let dir = try makeDirectory()

        let first = try DeviceIdentity.load(from: dir, actor: .author)
        XCTAssertTrue(first.canSign, "With an enclave present, load must mint an enclave key.")
        XCTAssertEqual(try entries(of: dir), ["device-key.blob"],
            "The enclave path persists the key's dataRepresentation, and nothing else.")

        let digest = Data(SHA256.hash(data: Data("sealed".utf8)))
        let raw = try first.sign(digest)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: raw)
        XCTAssertTrue(try XCTUnwrap(first.publicKey).isValidSignature(signature, for: digest))

        let second = try DeviceIdentity.load(from: dir, actor: .author)
        XCTAssertEqual(first.publicKey?.rawRepresentation, second.publicKey?.rawRepresentation,
            "The second load must reuse the persisted blob, not mint a second key.")
        XCTAssertEqual(first.deviceId, second.deviceId)
    }

    /// A blob that will not load on THIS enclave (a restored Mac) is renamed
    /// aside — never deleted — and then a NEW key is minted where there is an
    /// enclave to mint one in (the review's M1: both paths give this Mac a new
    /// device id, so falling to the token would cost it signing for good, for
    /// nothing). Where there is no enclave, the token path is still the answer.
    func test_anUnloadableBlobIsSetAsideAndSigningSurvivesWhereItCan() throws {
        let dir = try makeDirectory()
        let blob = dir.appendingPathComponent("device-key.blob")
        try Data("not a key".utf8).write(to: blob)

        let identity = try DeviceIdentity.load(from: dir, actor: .author)

        XCTAssertNotEqual(
            try? Data(contentsOf: blob), Data("not a key".utf8),
            "The unloadable blob must be moved out of the way, not read again.")
        let names = try entries(of: dir)
        XCTAssertTrue(names.contains(where: { $0.hasPrefix("device-key.blob.unloadable-") }),
            "The old blob is history, not rubbish. Found: \(names)")

        // Decided by MEASUREMENT, never by platform guess (constraint 2).
        if SecureEnclave.isAvailable {
            XCTAssertTrue(identity.canSign,
                "A restored Mac keeps signing: a new key is minted, not skipped.")
            XCTAssertTrue(names.contains("device-key.blob"),
                "and the fresh key is persisted under the ordinary name. "
                + "Found: \(names)")
        } else {
            XCTAssertFalse(identity.canSign)
            XCTAssertFalse(names.contains("device-key.blob"),
                "no enclave, no key file. Found: \(names)")
            XCTAssertTrue(names.contains("device-token"), "Found: \(names)")
        }
    }

    // MARK: - (f) The slug

    func test_theSlugIsFilenameSafeAndStable() throws {
        let dir = try makeDirectory()
        let identity = try DeviceIdentity.load(from: dir, actor: .author)
        let slug = identity.slug

        XCTAssertEqual(slug, DeviceSlug.make(from: identity.deviceId))
        XCTAssertEqual(slug, try DeviceIdentity.load(from: dir, actor: .author).slug,
            "The slug must survive a relaunch.")
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        XCTAssertTrue(slug.raw.unicodeScalars.allSatisfy(safe.contains),
            "A slug goes into a filename: \(slug.raw)")
        XCTAssertFalse(slug.raw.isEmpty)
    }

    // MARK: - DeviceState

    /// The per-process leaf is the `TestWorkspace.root` idiom verbatim: present
    /// under XCTest (where the Mac suite runs classes across worker PROCESSES,
    /// so a shared directory would have one worker's mint answer another's
    /// `current`) and absent everywhere else. `swift test` does not set
    /// `XCTestConfigurationFilePath`, so this test sees both shapes depending on
    /// which gate is running it — and asserts the one it is actually in.
    func test_theDeviceDirectoryIsPerWorkerUnderXCTestAndBareOtherwise() throws {
        var directory = DeviceState.directory

        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            XCTAssertEqual(directory.lastPathComponent,
                           "xctest-worker-\(ProcessInfo.processInfo.processIdentifier)",
                "Under XCTest the device directory takes a per-process leaf, exactly "
                + "as TestWorkspace.root does — parallel workers must not share key "
                + "material.")
            directory = directory.deletingLastPathComponent()
        }

        XCTAssertEqual(directory.lastPathComponent, "device")
        XCTAssertEqual(directory.deletingLastPathComponent().lastPathComponent,
                       BuildVariant.current.supportFolderName)
        XCTAssertEqual(
            directory.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent,
            "Application Support")
    }

    /// The two shapes agree on everything but the leaf — pinned by rebuilding
    /// `TestWorkspace.root`'s own rule and comparing, so a divergence in one
    /// idiom cannot pass unnoticed.
    func test_theDeviceDirectorySitsBesideTheTestWorkspaceUnderTheSameSupportFolder() throws {
        let deviceSupport = DeviceState.directory
            .pathComponents
            .prefix(while: { $0 != "device" })
        let workspaceSupport = TestWorkspace.root
            .pathComponents
            .prefix(while: { $0 != "TestWorkspace" })
        XCTAssertEqual(Array(deviceSupport), Array(workspaceSupport))
    }

    func test_ensureDirectoryCreatesTheWholeChainAndIsIdempotent() throws {
        let root = try makeDirectory()
        let nested = root.appendingPathComponent("a/b/c")
        try DeviceState.ensureDirectory(nested)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
        try DeviceState.ensureDirectory(nested)
    }

    // MARK: - The memoized per-actor identities

    /// Each actor is its own key in its own file. The author keeps the names
    /// P1 shipped (`device-key.blob` / `device-token`); the other three suffix
    /// theirs, so one `device/` folder holds four keys that cannot be confused.
    func test_eachActorMintsItsOwnFileUnderItsOwnName() throws {
        let dir = try makeDirectory()

        for actor in DeviceActor.allCases {
            _ = try DeviceIdentity.load(from: dir, actor: actor)
        }

        let names = Set(try entries(of: dir))
        let expected: Set<String> = SecureEnclave.isAvailable
            ? ["device-key.blob", "device-key.assistant.blob",
               "device-key.translator.blob", "device-key.maugham.blob"]
            : ["device-token", "device-token.assistant",
               "device-token.translator", "device-token.maugham"]
        XCTAssertEqual(names, expected,
            "Four actors, four files, each named for its actor. Found: \(names.sorted())")
    }

    /// Four ids carrying four prefixes over four DISTINCT fingerprints — the
    /// point of the whole slice: the role is in the key, not in a label beside
    /// it, so an op's signature says which actor wrote it.
    func test_theFourIdsCarryTheirPrefixesOverFourDistinctFingerprints() throws {
        let dir = try makeDirectory()

        let identities = try DeviceActor.allCases.map {
            try DeviceIdentity.load(from: dir, actor: $0)
        }

        for identity in identities {
            XCTAssertTrue(identity.deviceId.hasPrefix("\(identity.actor.rawValue)-"),
                "\(identity.deviceId) does not name its own actor.")
            XCTAssertEqual(identity.deviceId,
                           "\(identity.actor.rawValue)-\(identity.fingerprint.prefix(16))")
        }
        XCTAssertEqual(Set(identities.map(\.fingerprint)).count, DeviceActor.allCases.count,
            "Two actors share key material — then a signature proves nothing about "
            + "which of them wrote the op.")
        XCTAssertEqual(Set(identities.map(\.slug)).count, DeviceActor.allCases.count,
            "Two actors share a filename partition (tripwire 17).")
    }

    /// The phone mints ONE key on first launch: it is the `author` on its own
    /// device and nothing else. Minting four enclave keys where three would
    /// never be used is work the writer waits for, for nothing.
    func test_loadingTheAuthorAloneMintsNothingForTheOtherActors() throws {
        let dir = try makeDirectory()

        _ = try DeviceIdentity.load(from: dir, actor: .author)

        let names = try entries(of: dir)
        XCTAssertEqual(names.count, 1,
            "Asking for the author minted more than the author. Found: \(names)")
        for actor in DeviceActor.allCases where actor != .author {
            XCTAssertFalse(names.contains(where: { $0.contains(actor.rawValue) }),
                "\(actor.rawValue) has a file and nobody asked for it. Found: \(names)")
        }
    }

    func test_theAuthorAnswersAStableIdentity() throws {
        XCTAssertEqual(DeviceIdentity.author.deviceId, DeviceIdentity.author.deviceId)
        XCTAssertEqual(DeviceIdentity.author.fingerprint.count, 64)
        XCTAssertEqual(DeviceIdentity.author.actor, .author)
    }
}

/// The per-process test leaf is swept (the whole-branch review's M2).
///
/// `DeviceState.directory` mints an `xctest-worker-<pid>` leaf under XCTest, and
/// nothing ever removed one: seven workers a gate, dozens of gates a day, a key
/// blob and a state file each, under Application Support forever. The isolation
/// is right and stays; the housekeeping was missing.
final class DeviceStateSweepTests: XCTestCase {

    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("device-sweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func makeLeaf(_ name: String) throws -> URL {
        let url = base.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("blob".utf8).write(to: url.appendingPathComponent("device-key.blob"))
        return url
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func test_aDeadWorkersLeafIsRemovedAndALiveOnesIsKept() throws {
        let dead = try makeLeaf("xctest-worker-424242")
        let alive = try makeLeaf(
            "xctest-worker-\(ProcessInfo.processInfo.processIdentifier)")

        DeviceState.sweepDeadWorkerLeaves(in: base)

        XCTAssertFalse(exists(dead), "a leaf whose process is gone is rubbish")
        XCTAssertTrue(exists(alive),
            "and this process's own leaf is in use — as is any other worker's "
            + "in the same gate")
    }

    /// Never the bare production path, and never anything else that happens to
    /// live beside the leaves.
    func test_theSweepTouchesNothingButAWorkerLeaf() throws {
        let blob = base.appendingPathComponent("device-key.blob")
        try Data("the real one".utf8).write(to: blob)
        let state = base.appendingPathComponent("op-log-state.json")
        try Data("{}".utf8).write(to: state)
        let stranger = try makeLeaf("some-other-directory")
        let malformed = try makeLeaf("xctest-worker-not-a-number")

        DeviceState.sweepDeadWorkerLeaves(in: base, isAlive: { _ in false })

        XCTAssertTrue(exists(blob))
        XCTAssertTrue(exists(state))
        XCTAssertTrue(exists(stranger))
        XCTAssertTrue(exists(malformed), "a leaf with no readable pid is left alone")
    }
}


/// `LocalIdentities` — this device's four actors in one value, so a reader can
/// ask "is this device string one of mine?" without knowing which actor it is.
final class LocalIdentitiesTests: XCTestCase {

    func test_theSubscriptAnswersTheMemberNamedByTheActor() {
        let local = LocalIdentities.softwareForTesting()
        XCTAssertEqual(local[.author].fingerprint, local.author.fingerprint)
        XCTAssertEqual(local[.assistant].fingerprint, local.assistant.fingerprint)
        XCTAssertEqual(local[.translator].fingerprint, local.translator.fingerprint)
        XCTAssertEqual(local[.maugham].fingerprint, local.maugham.fingerprint)
    }

    /// The census that keeps the enum and the struct from drifting: a fifth
    /// `DeviceActor` case with no member here fails HERE rather than silently
    /// leaving one actor's ops unrecognised as local (constraint 1).
    func test_everyDeviceActorCaseHasAMemberAndAllIsInThatOrder() {
        let local = LocalIdentities.softwareForTesting()
        XCTAssertEqual(local.all.count, DeviceActor.allCases.count,
            "A DeviceActor case has no member on LocalIdentities.")
        XCTAssertEqual(local.all.map(\.actor), DeviceActor.allCases,
            "`all` is `DeviceActor.allCases` order, so a caller iterating either "
            + "one sees the same sequence.")
        XCTAssertEqual(local.fingerprints, Set(local.all.map(\.fingerprint)))
        XCTAssertEqual(local.fingerprints.count, DeviceActor.allCases.count)
    }

    func test_identityForDeviceIdRoundTripsEveryActorAndRefusesAStranger() {
        let local = LocalIdentities.softwareForTesting()

        for actor in DeviceActor.allCases {
            let mine = local[actor]
            let found = local.identity(forDeviceId: mine.deviceId)
            XCTAssertEqual(found?.fingerprint, mine.fingerprint)
            XCTAssertEqual(found?.actor, actor)
        }

        XCTAssertNil(local.identity(forDeviceId: "author-0123456789abcdef"),
            "Another device's author is not this device's author — an id that "
            + "merely LOOKS local must not be adopted, or this device would sign "
            + "and seal a file it does not own (tripwire 17).")
        XCTAssertNil(local.identity(forDeviceId: local.author.fingerprint),
            "A fingerprint is not a device id.")
        XCTAssertNil(local.identity(forDeviceId: ""))
    }

    /// The four software identities are four distinct keys, so a test that
    /// signs as the translator and verifies as the author fails.
    func test_theTestingMintGivesFourDistinctKeys() {
        let local = LocalIdentities.softwareForTesting()
        XCTAssertEqual(Set(local.all.map(\.deviceId)).count, DeviceActor.allCases.count)
        XCTAssertTrue(local.all.allSatisfy(\.canSign))
    }
}
