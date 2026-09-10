import XCTest
@testable import MaughamCore
@testable import Maugham

/// **Opening a project is how this Mac declares itself in it** (P2a, spec §2.1
/// and §3).
///
/// `RegistryPresence` decides what a record says; this suite is about the one
/// production path that calls it — `DocumentStore.open`, ahead of the seal
/// sweep, so that a seal a reader later meets already has the record naming the
/// key that made it.
@MainActor
final class RegistryPresenceTests: XCTestCase {

    override func tearDown() async throws {
        // Process-wide seams: a leak would change who every later test's load
        // thinks this device is.
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
    }

    // MARK: - Fixtures

    private func makeProject() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PRESENCE-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"), withIntermediateDirectories: true)
        try Data("Hello.".utf8).write(to: tmp.appendingPathComponent("manuscript/c1.md"))
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [StructureItem(
                id: "doc-test", title: "C1", type: .document, path: "manuscript/c1.md")],
            research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        return tmp
    }

    /// This Mac, with a software key so the records it writes actually sign on
    /// a machine — or a CI runner — whose enclave this suite must not touch.
    @discardableResult
    private func beThisMac(_ url: URL) -> LocalIdentities {
        let identities = LocalIdentities.forTesting(author: .softwareForTesting())
        Document.localIdentitiesForTesting = identities
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: url.appendingPathComponent("op-log-state.json"))
        return identities
    }

    private func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func deviceURL(_ fingerprint: String, in url: URL) -> URL {
        RegistryWriter.url(.devices, fingerprint: fingerprint, in: url)
    }

    private func personURL(_ fingerprint: String, in url: URL) -> URL {
        RegistryWriter.url(.people, fingerprint: fingerprint, in: url)
    }

    // MARK: - A fresh book

    func test_openingAFreshProjectWritesThisMacsRecordAndItsRoot() async throws {
        let url = try makeProject()
        let identities = beThisMac(url)

        _ = try await DocumentStore.open(url: url)

        let registry = try RegistryReader.load(projectURL: url)
        let device = try XCTUnwrap(registry.devices.first)
        XCTAssertEqual(device.device, identities.author.fingerprint)
        XCTAssertEqual(device.kind, .mac)
        XCTAssertFalse(device.name.isEmpty, "and it says what this Mac is called")
        XCTAssertEqual(
            device.actors[DeviceActor.author.rawValue], identities.author.fingerprint)

        let root = try XCTUnwrap(registry.roots.first)
        XCTAssertEqual(root.person, identities.author.fingerprint,
                       "a Mac in a book with nobody in it is its root")
        XCTAssertEqual(root.label, device.name)
        XCTAssertTrue(registry.malformed.isEmpty,
                      "and both are records its own reader can vouch for")
    }

    /// The idempotence that makes this safe on a path every open takes.
    func test_asecondOpenTouchesNeitherFile() async throws {
        let url = try makeProject()
        let identities = beThisMac(url)
        _ = try await DocumentStore.open(url: url)
        let deviceFile = deviceURL(identities.author.fingerprint, in: url)
        let personFile = personURL(identities.author.fingerprint, in: url)
        let written = (modified(deviceFile), modified(personFile))
        XCTAssertNotNil(written.0)
        XCTAssertNotNil(written.1)

        _ = try await DocumentStore.open(url: url)

        XCTAssertEqual(modified(deviceFile), written.0,
                       "an open with nothing new to say writes no device record")
        XCTAssertEqual(modified(personFile), written.1,
                       "and no second root")
    }

    /// The lazy-key case through the production path: a record written when
    /// this Mac held one key is re-signed, on the next open, with every key it
    /// holds now — which is how the assistant's seals stop reading as a
    /// stranger's the day MCP first writes (spec §4.4).
    func test_anOpenReSignsARecordThatIsMissingAnActorThisMacHolds() async throws {
        let url = try makeProject()
        let identities = beThisMac(url)
        let author = identities.author
        let earlier = DeviceRecord(
            device: author.fingerprint, name: "Denver's MacBook", kind: .mac,
            actors: [DeviceActor.author.rawValue: author.fingerprint],
            madeAt: Date(timeIntervalSince1970: 10))
        try RegistryWriter.write(earlier, signedBy: author, in: url)

        _ = try await DocumentStore.open(url: url)

        let registry = try RegistryReader.load(projectURL: url)
        let device = try XCTUnwrap(registry.devices.first)
        XCTAssertEqual(
            Set(device.actors.keys), Set(DeviceActor.allCases.map(\.rawValue)),
            "every actor key this Mac holds is now listed")
        XCTAssertEqual(device.madeAt, Date(timeIntervalSince1970: 10),
                       "and it is still the same device")
        XCTAssertTrue(registry.malformed.isEmpty)
    }

    // MARK: - Somebody else's book

    /// Opening a book that already has a root says who this Mac is and stops.
    /// Adopting somebody's history is a claim, and a claim is the writer's
    /// decision — never one an open makes for them (spec §3).
    func test_openingABookThatAlreadyHasARootWritesNoSecondRoot() async throws {
        let url = try makeProject()
        let identities = beThisMac(url)
        let stranger = DeviceIdentity.softwareForTesting()
        let theirs = PersonRecord(
            person: stranger.fingerprint, label: "Sam", ownName: "Sam's iMac",
            admittedAt: Date(timeIntervalSince1970: 1), admittedBy: stranger.fingerprint)
        try RegistryWriter.write(theirs, signedBy: stranger, in: url)

        _ = try await DocumentStore.open(url: url)

        let registry = try RegistryReader.load(projectURL: url)
        XCTAssertEqual(registry.roots.map(\.person), [stranger.fingerprint],
                       "the book still has exactly one root, and it is not this Mac")
        XCTAssertEqual(registry.devices.map(\.device), [identities.author.fingerprint],
                       "but this Mac did say who it is")
    }

    // MARK: - The name

    /// A display string, and a real one. The identity is the key's fingerprint
    /// (tripwire 35); this is only what a human reads.
    func test_thisMacHasANameToShow() {
        XCTAssertFalse(DocumentStore.thisMacsName.isEmpty)
    }
}
