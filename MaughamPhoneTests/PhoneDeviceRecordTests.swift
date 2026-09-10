import XCTest
@testable import MaughamCore
@testable import MaughamPhone

/// **This phone declaring itself in a book it writes into** (P2a, spec §2.1),
/// through the writer that actually writes — not through the Core helper on its
/// own, because what this task added to the phone is the CALL.
///
/// The phone never writes a root: the first root record is the Mac's (spec §3).
@MainActor
final class PhoneDeviceRecordTests: XCTestCase {

    private var projectRoot: URL!
    /// A software signing key: the simulator has no enclave of its own, and an
    /// unsigned device writes no record at all — which is the state the last
    /// test here pins.
    private var identity: DeviceIdentity!

    override func setUp() async throws {
        projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("phone-presence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectRoot, withIntermediateDirectories: true)
        identity = .softwareForTesting()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: projectRoot)
    }

    private func capture() async throws {
        let writer = InboxCaptureWriter(projectRoot: projectRoot, identity: identity)
        _ = try await writer.writeText("A line I thought of on the train")
    }

    // MARK: - The record

    func test_theFirstCaptureDeclaresThisPhone() async throws {
        try await capture()

        let registry = try RegistryReader.load(projectURL: projectRoot)
        let device = try XCTUnwrap(registry.devices.first)
        XCTAssertEqual(device.device, identity.fingerprint,
                       "the record names the key that signs this phone's seals")
        XCTAssertEqual(device.kind, .phone)
        XCTAssertFalse(device.name.isEmpty)
        XCTAssertEqual(
            device.actors[DeviceActor.author.rawValue], identity.fingerprint,
            "and its author entry IS the device, which is what the reader checks")
        XCTAssertTrue(registry.malformed.isEmpty,
                      "a record the shared reader can vouch for")
    }

    /// The phone waits to be admitted. A phone that made itself a root would be
    /// a second claimant on a book it can only see through the share.
    func test_thePhoneWritesNoRoot() async throws {
        try await capture()

        let registry = try RegistryReader.load(projectURL: projectRoot)
        XCTAssertTrue(registry.people.isEmpty)
        XCTAssertTrue(registry.roots.isEmpty)
    }

    /// Idempotent, because this runs on every write rather than at an open the
    /// phone does not have.
    func test_asecondCaptureTouchesTheRecordAgainNotAtAll() async throws {
        try await capture()
        let file = RegistryWriter.url(
            .devices, fingerprint: identity.fingerprint, in: projectRoot)
        let written = (try FileManager.default.attributesOfItem(atPath: file.path))[.modificationDate] as? Date
        XCTAssertNotNil(written)

        try await capture()

        let now = (try FileManager.default.attributesOfItem(atPath: file.path))[.modificationDate] as? Date
        XCTAssertEqual(now, written)
    }

    /// An annotation write is the other writer, and it declares the phone the
    /// same way — one helper, one answer (tripwire 19).
    func test_anAnnotationWriteDeclaresThisPhoneToo() async throws {
        let docId = "doc-abc123"
        let writer = AnnotationWriter(
            projectRoot: projectRoot, docId: docId, identity: identity,
            appVersion: "1.0", osVersion: "iOS 17.4")
        let annotation = Annotation(
            id: "01CREATIONCOMMENT", kind: .comment, paragraphId: "k7m3",
            body: "nice line", suggestedText: nil, priorText: "The sun was setting.",
            createdAt: Date(timeIntervalSince1970: 1_699_000_000), createdBySession: "s",
            status: .open, userResponse: nil, resolvedAt: nil, isStale: false)
        _ = try await writer.archive(annotation)

        let registry = try RegistryReader.load(projectURL: projectRoot)
        XCTAssertEqual(registry.devices.map(\.device), [identity.fingerprint])
    }

    /// A phone with no key writes its ops — chained, unsealed — and no record
    /// at all: an unsigned record is one every reader lists as malformed, so
    /// writing one would lose this phone's history to a state nobody chose.
    func test_aPhoneWithNoKeyDeclaresNothingAndStillCaptures() async throws {
        identity = .unsignedForTesting(token: Data([9, 9, 9]))

        try await capture()

        XCTAssertFalse(
            TrustResolution.hasRegistry(in: projectRoot),
            "not even an empty registry folder is left behind")
    }
}
