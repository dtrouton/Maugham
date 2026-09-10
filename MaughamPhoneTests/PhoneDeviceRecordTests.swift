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
        // The memo is process-wide state; a suite must not inherit what
        // another one declared.
        PhoneDeviceRecord.forgetDeclarationsForTesting()
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

    // MARK: - The memo (P2b §4.11)

    /// The second write into a book this run has already declared itself in
    /// reads NOTHING. `ensureDeviceRecord` verifies the whole registry folder
    /// before deciding it has nothing to add, and it runs on every capture and
    /// every annotation — so *idempotent* is not the same as *free*.
    func test_aSecondWriteIntoTheSameBookDeclaresNothingAndReadsNothing() throws {
        var reads = 0
        func ensure() {
            PhoneDeviceRecord.ensure(
                in: projectRoot, identity: identity, name: "Denver's iPhone",
                declare: { _, _, _ in reads += 1; return nil })
        }

        ensure()
        XCTAssertEqual(reads, 1, "the first write declares this phone")

        ensure()
        ensure()
        XCTAssertEqual(reads, 1, "and nothing after it reads the folder again")
    }

    /// Two books are two declarations: the record lives in the project, so a
    /// memory of one says nothing about the other.
    func test_asecondBookIsDeclaredInItsOwnRight() throws {
        let other = projectRoot.appendingPathComponent("elsewhere", isDirectory: true)
        var roots: [URL] = []
        func ensure(_ root: URL) {
            PhoneDeviceRecord.ensure(
                in: root, identity: identity, name: "Denver's iPhone",
                declare: { url, _, _ in roots.append(url); return nil })
        }

        ensure(projectRoot)
        ensure(other)
        ensure(projectRoot)

        XCTAssertEqual(roots, [projectRoot, other])
    }

    /// An actor key minted since the last declaration invalidates it: a device
    /// record that does not list the new actor has every reader treating this
    /// phone's next writer as a stranger (spec §4.4).
    func test_anActorMintedSinceTheLastDeclarationDeclaresAgain() throws {
        let lazy = LocalIdentities.lazySoftwareForTesting()
        _ = lazy.author  // the phone's own writer, named by its first write
        var declaredActors: [[String]] = []
        func ensure() {
            PhoneDeviceRecord.ensure(
                in: projectRoot, identity: lazy.author, identities: lazy,
                name: "Denver's iPhone",
                declare: { _, identities, _ in
                    declaredActors.append(identities.existingActors.map(\.rawValue))
                    return nil
                })
        }

        ensure()
        ensure()
        XCTAssertEqual(declaredActors.count, 1)

        _ = lazy.assistant  // a second key, minted by naming it

        ensure()
        XCTAssertEqual(declaredActors.count, 2,
                       "the actor set moved, so the record is re-signed")
        XCTAssertEqual(declaredActors.last, ["author", "assistant"])
    }

    /// A name the writer changed in iOS Settings is the other thing
    /// `RegistryPresence` re-signs for, so the memo must not hold over it.
    func test_arenamedPhoneDeclaresItselfAgain() throws {
        var names: [String] = []
        func ensure(_ name: String) {
            PhoneDeviceRecord.ensure(
                in: projectRoot, identity: identity, name: name,
                declare: { _, _, declared in names.append(declared); return nil })
        }

        ensure("Denver's iPhone")
        ensure("Denver's iPhone")
        ensure("The new iPhone")

        XCTAssertEqual(names, ["Denver's iPhone", "The new iPhone"])
    }

    /// A declaration that THREW is not remembered: a transient iCloud fault
    /// would otherwise leave this phone undeclared for the rest of the run,
    /// and the Mac with nothing to admit.
    func test_afailedDeclarationIsTriedAgain() throws {
        struct Refused: Error {}
        var attempts = 0
        func ensure(throwing: Bool) {
            PhoneDeviceRecord.ensure(
                in: projectRoot, identity: identity, name: "Denver's iPhone",
                declare: { _, _, _ in
                    attempts += 1
                    if throwing { throw Refused() }
                    return nil
                })
        }

        ensure(throwing: true)
        ensure(throwing: false)
        XCTAssertEqual(attempts, 2)

        ensure(throwing: false)
        XCTAssertEqual(attempts, 2, "and the one that landed is remembered")
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
