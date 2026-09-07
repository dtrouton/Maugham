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

        let first = try DeviceIdentity.load(from: dir)
        let afterFirst = try entries(of: dir)
        XCTAssertEqual(afterFirst.count, 1,
            "One load should leave exactly one file behind — the key blob or the "
            + "token. Found: \(afterFirst)")
        let mintedAt = try FileManager.default
            .attributesOfItem(atPath: dir.appendingPathComponent(afterFirst[0]).path)[.modificationDate] as? Date

        let second = try DeviceIdentity.load(from: dir)

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

    /// The id is 16 hex characters off a 64-hex fingerprint, whichever path
    /// minted it.
    func test_theIdIsSixteenHexOffTheSixtyFourHexFingerprint() throws {
        let identity = try DeviceIdentity.load(from: try makeDirectory())
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        XCTAssertEqual(identity.fingerprint.count, 64)
        XCTAssertEqual(identity.deviceId.count, 16)
        XCTAssertTrue(identity.fingerprint.unicodeScalars.allSatisfy(hex.contains),
            "Fingerprint is lowercase hex: \(identity.fingerprint)")
        XCTAssertTrue(identity.deviceId.unicodeScalars.allSatisfy(hex.contains),
            "Device id is lowercase hex: \(identity.deviceId)")
        XCTAssertTrue(identity.fingerprint.hasPrefix(identity.deviceId))
    }

    // MARK: - (b) Two directories are two devices

    func test_twoDirectoriesAnswerDifferentIdentities() throws {
        let one = try DeviceIdentity.load(from: try makeDirectory())
        let two = try DeviceIdentity.load(from: try makeDirectory())
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

        let first = try DeviceIdentity.load(from: dir)
        XCTAssertTrue(first.canSign, "With an enclave present, load must mint an enclave key.")
        XCTAssertEqual(try entries(of: dir), ["device-key.blob"],
            "The enclave path persists the key's dataRepresentation, and nothing else.")

        let digest = Data(SHA256.hash(data: Data("sealed".utf8)))
        let raw = try first.sign(digest)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: raw)
        XCTAssertTrue(try XCTUnwrap(first.publicKey).isValidSignature(signature, for: digest))

        let second = try DeviceIdentity.load(from: dir)
        XCTAssertEqual(first.publicKey?.rawRepresentation, second.publicKey?.rawRepresentation,
            "The second load must reuse the persisted blob, not mint a second key.")
        XCTAssertEqual(first.deviceId, second.deviceId)
    }

    /// A blob that will not load on THIS enclave (a restored Mac) is renamed
    /// aside — never deleted — and the token path is taken.
    func test_anUnloadableBlobIsSetAsideAndTheTokenPathIsTaken() throws {
        let dir = try makeDirectory()
        let blob = dir.appendingPathComponent("device-key.blob")
        try Data("not a key".utf8).write(to: blob)

        let identity = try DeviceIdentity.load(from: dir)

        XCTAssertFalse(identity.canSign, "An unloadable blob falls to the unsigned token.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: blob.path),
            "The unloadable blob must be renamed aside, not left in place.")
        let names = try entries(of: dir)
        XCTAssertTrue(names.contains("device-token"), "Found: \(names)")
        XCTAssertTrue(names.contains(where: { $0.hasPrefix("device-key.blob.unloadable-") }),
            "The old blob is history, not rubbish. Found: \(names)")
    }

    // MARK: - (f) The slug

    func test_theSlugIsFilenameSafeAndStable() throws {
        let dir = try makeDirectory()
        let identity = try DeviceIdentity.load(from: dir)
        let slug = identity.slug

        XCTAssertEqual(slug, DeviceSlug.make(from: identity.deviceId))
        XCTAssertEqual(slug, try DeviceIdentity.load(from: dir).slug,
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

    // MARK: - current

    func test_currentAnswersAStableIdentity() throws {
        XCTAssertEqual(DeviceIdentity.current.deviceId, DeviceIdentity.current.deviceId)
        XCTAssertEqual(DeviceIdentity.current.fingerprint.count, 64)
    }
}
