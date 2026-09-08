import CryptoKit
import XCTest
@testable import MaughamCore
@testable import MaughamPhone

/// The ONE enclave test on the phone: does an iOS process actually get a
/// signing identity out of `DeviceIdentity.load(from:)`?
///
/// Everything else about the chain is tested against the software signer, which
/// proves the sign/verify contract and nothing about the hardware. This proves
/// the hardware — and the §7 spike (2026-09-07) predicted it would RUN rather
/// than skip, because the iOS simulator exposes a Secure Enclave through the
/// host's. The skip is therefore a MEASUREMENT: if it fires, the simulator on
/// this machine has no enclave and the phone writes unsigned ops, which is a
/// state and not a failure (spec §4.1).
///
/// It writes into a temp directory of its own, never `DeviceState.directory`,
/// so it cannot disturb the identity the rest of the suite (or the app on this
/// simulator) is using.
final class PhoneDeviceIdentityTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(
            SecureEnclave.isAvailable,
            "no Secure Enclave in this simulator — the phone writes unsigned ops here")
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("phone-identity-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    /// Mint, then sign, then verify — the whole contract in one pass. A key
    /// that mints but cannot sign, or signs unverifiably, is worse than no key
    /// at all, so all three are asserted together.
    func test_theSimulatorMintsAKeyThatSignsAndVerifies() throws {
        let identity = try DeviceIdentity.load(from: directory, actor: .author)

        XCTAssertTrue(identity.canSign,
                      "an enclave is available, so this device must hold a signing key")
        let publicKey = try XCTUnwrap(identity.publicKey)
        XCTAssertEqual(identity.fingerprint, DeviceIdentity.fingerprint(of: publicKey))
        XCTAssertEqual(identity.actor, .author,
                       "the phone is the writer on its own device and nothing else")
        XCTAssertEqual(identity.deviceId, "author-\(identity.fingerprint.prefix(16))")

        let digest = Data(SHA256.hash(data: Data("the words are safe".utf8)))
        let signature = try P256.Signing.ECDSASignature(
            rawRepresentation: try identity.sign(digest))
        XCTAssertTrue(publicKey.isValidSignature(signature, for: digest))
    }

    /// The key is PERSISTED, not minted per launch: a second load reads the
    /// blob back off disk and answers the same device. If it did not, every
    /// launch would be a new device and the op log would fill with strangers.
    func test_aSecondLoadReusesThePersistedBlob() throws {
        let first = try DeviceIdentity.load(from: directory, actor: .author)
        let blob = directory.appendingPathComponent(DeviceIdentity.blobFilename(for: .author))
        XCTAssertTrue(FileManager.default.fileExists(atPath: blob.path),
                      "the enclave-wrapped blob is written beside the state")

        let second = try DeviceIdentity.load(from: directory, actor: .author)
        XCTAssertTrue(second.canSign)
        XCTAssertEqual(second.fingerprint, first.fingerprint)
        XCTAssertEqual(second.deviceId, first.deviceId)
        XCTAssertEqual(second.publicKey?.x963Representation,
                       first.publicKey?.x963Representation,
                       "the same key, not a fresh one that happens to work")

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names, [DeviceIdentity.blobFilename(for: .author)],
                       "the phone mints ONE key on first launch — the author's. "
                       + "Found: \(names)")
    }
}


/// The phone holds ONE key, and the proof has to be a measurement.
///
/// P1b's constraint 7 says the phone is the `author` and mints only the key it
/// signs with. The branch first guarded that with a grep over phone sources for
/// the spellings that would reach another actor — and the whole-branch review's
/// C1 found the hole a grep cannot see: `OpLogStore`'s `identities:` parameter
/// DEFAULTS, three phone sites take the default, and the default used to mint
/// all four on the main thread the moment the Annotations tab opened. No
/// spelling appeared anywhere; the census stayed green; the container filled up
/// with three keys the phone will never sign with.
///
/// So this asks the container instead. `LocalIdentities` is lazy now
/// (`existingActors` enumerates what is on disk, `subscript` is the only door
/// that mints), which means the question is answerable at runtime: exercise the
/// real read path and look at `DeviceState.directory`.
final class PhoneOneKeyTests: XCTestCase {
    private var tmp: URL!
    private let docId = "doc-1a2b3c4d"

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("phone-one-key-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent(".maugham/ops"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
        tmp = nil
    }

    /// The three actors the phone is not, after the phone has done the thing
    /// that used to mint them.
    private static let notThePhone: [DeviceActor] = [.assistant, .translator, .maugham]

    @MainActor
    func test_openingTheAnnotationsPathMintsNoKeyThePhoneWillNeverSignWith() async throws {
        // Seed one Mac-written annotation so the load has real work to do.
        let opsDir = tmp.appendingPathComponent(".maugham/ops")
        let seeded = JSONLAppendStore<Op>(
            fileURL: opsDir.appendingPathComponent("\(docId).mac.jsonl"))
        try await seeded.append(Op(
            opId: "01HQ8K2M9N4P5R6S8T0V2W3X4Y", docId: docId,
            at: Date(timeIntervalSince1970: 1_000), device: "mac", session: "s",
            kind: .claudeComment,
            changes: [Op.ParagraphChange(
                paragraphId: "k7m3", prior: "The sun set.", next: "")],
            provenance: Op.Provenance(sessionId: "s", annotationBody: "tighten this")))

        // `AnnotationsStore.loadedAnnotations`' own body: the store built with
        // no `identities:` label, the op-log read, the derive. Twice, because
        // `AnnotationDetailView` builds one of its own on accept and another on
        // re-derive, and a mint on the second would be just as wrong.
        for _ in 0..<2 {
            let store = OpLogStore(projectURL: tmp)
            let ops = try await store.load(docId: docId)
            XCTAssertFalse(AnnotationLoading.allAnnotations(ops: ops).isEmpty,
                           "the read path really ran")
        }

        // And the question itself, asked of the container the app writes into.
        let dir = DeviceState.directory
        for actor in Self.notThePhone {
            XCTAssertFalse(
                DeviceIdentity.hasPersistedIdentity(for: actor),
                "The phone minted a \(actor.rawValue) key. It is the author and "
                + "nothing else (P1b constraint 7): every key here is one the "
                + "writer waited for and nothing will ever sign with.")
            for name in [DeviceIdentity.blobFilename(for: actor),
                         DeviceIdentity.tokenFilename(for: actor)] {
                XCTAssertFalse(
                    FileManager.default.fileExists(
                        atPath: dir.appendingPathComponent(name).path),
                    "\(name) is in the phone's device folder")
            }
        }
        XCTAssertTrue(
            LocalIdentities.current.existingActors.allSatisfy { $0 == .author },
            "the only key this device can hold is the author's")
    }
}
