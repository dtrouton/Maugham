import XCTest
@testable import Maugham
@testable import MaughamCore

/// **The inbox answers to the permit too** (P3a Task 6, spec §4.3's first
/// bullet and §9's first line).
///
/// A capture is a signed line another person's device wrote and this one
/// applies, so `InboxStore.refresh` runs the same partition the op log's
/// readers do. The class it runs under is `.inbox`, which is the one class
/// whose whole content is the reviewer row — so every RUNG's captures are
/// applied, and the only thing that can be refused here is a narrowed ACTOR:
/// the pipeline's key and the app's own housekeeping key write translations and
/// task order, never captures.
///
/// That asymmetry is what makes this suite's two tests a pair: one proves the
/// door is open to everybody it should be, the other proves it is a door.
@MainActor
final class InboxPermitTests: XCTestCase {

    private var projectURL: URL!
    private var mine: LocalIdentities!
    private var theirs: LocalIdentities!
    private var cacheURL: URL!
    private var cache: RegistryCache!

    override func setUp() async throws {
        projectURL = TestTemp.root
            .appendingPathComponent("inbox-permit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent(".maugham/inbox"),
            withIntermediateDirectories: true)
        mine = .softwareForTesting()
        theirs = .softwareForTesting()
        cacheURL = TestTemp.root
            .appendingPathComponent("inbox-permit-cache-\(UUID().uuidString).json")
        cache = RegistryCache(fileURL: cacheURL, identity: mine.author.fingerprint)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: projectURL)
        try? FileManager.default.removeItem(at: cacheURL)
    }

    // MARK: - Fixture

    private func makeInbox() -> InboxStore {
        InboxStore(projectURL: projectURL, deviceId: mine.author.deviceId,
                   identity: mine.author, identities: mine, cache: cache)
    }

    /// This Mac's root, plus a device record so its own keys are named.
    private func plantMyRoot() throws {
        try RegistryWriter.write(
            PersonRecord(
                person: mine.author.fingerprint, label: "Denver",
                ownName: "Denver’s MacBook",
                admittedAt: Date(timeIntervalSince1970: 10),
                admittedBy: mine.author.fingerprint),
            signedBy: mine.author, in: projectURL)
        try RegistryWriter.write(
            DeviceRecord(
                device: mine.author.fingerprint, name: "Denver’s MacBook",
                kind: .mac,
                actors: [DeviceActor.author.rawValue: mine.author.fingerprint],
                madeAt: Date(timeIntervalSince1970: 1)),
            signedBy: mine.author, in: projectURL)
    }

    /// Sam's Mac, admitted as a reviewer, with its four keys on record.
    private func admitSamAsAReviewer() throws {
        try RegistryWriter.write(
            PersonRecord(
                person: theirs.author.fingerprint, label: "Sam", ownName: "Sam’s Mac",
                role: Permit.reviewerRole,
                admittedAt: Date(timeIntervalSince1970: 20),
                admittedBy: mine.author.fingerprint),
            signedBy: mine.author, in: projectURL)
        try RegistryWriter.write(
            DeviceRecord(
                device: theirs.author.fingerprint, name: "Sam’s Mac", kind: .mac,
                actors: Dictionary(uniqueKeysWithValues: DeviceActor.allCases.map {
                    ($0.rawValue, theirs[$0].fingerprint)
                }),
                madeAt: Date(timeIntervalSince1970: 5)),
            signedBy: theirs.author, in: projectURL)
        try RegistryWriter.write(
            PermitEvent(
                event: PermitEvent.mintID(subject: theirs.author.fingerprint),
                kind: .admitted, subject: theirs.author.fingerprint,
                role: Permit.reviewerRole, scope: Permit.bookScope,
                pieces: [], mark: [:],
                at: Date(timeIntervalSince1970: 20),
                by: mine.author.fingerprint),
            signedBy: mine.author, in: projectURL)
    }

    /// Sam's device, writing its own manifest on the far side of iCloud under
    /// whichever of its keys.
    private func write(
        _ entries: [InboxEntry], by identity: DeviceIdentity
    ) async throws {
        let store = JSONLAppendStore<InboxEntry>(
            fileURL: InboxManifest.inboxManifestURL(
                forDeviceSlug: identity.slug, in: projectURL),
            chain: ChainPolicy(
                identity: identity, state: .shared,
                docId: InboxManifest.chainDocId, projectURL: projectURL))
        for entry in entries { try await store.append(entry) }
        try await store.appendSeal()
    }

    private func entry(_ id: String, by identity: DeviceIdentity) -> InboxEntry {
        InboxEntry(
            id: id, createdAt: Date(timeIntervalSince1970: 100),
            writtenAt: Date(timeIntervalSince1970: 100),
            deviceId: identity.deviceId, kind: .text, inlineText: id)
    }

    /// Sam's Mac admitted as a PERSON with no device record yet — the real
    /// window between her first manifest syncing and her `DeviceRecord`
    /// syncing, which are separate files on separate schedules.
    private func admitSamWithNoDeviceRecord() throws {
        try RegistryWriter.write(
            PersonRecord(
                person: theirs.author.fingerprint, label: "Sam", ownName: "Sam’s Mac",
                role: Permit.reviewerRole,
                admittedAt: Date(timeIntervalSince1970: 20),
                admittedBy: mine.author.fingerprint),
            signedBy: mine.author, in: projectURL)
        try RegistryWriter.write(
            PermitEvent(
                event: PermitEvent.mintID(subject: theirs.author.fingerprint),
                kind: .admitted, subject: theirs.author.fingerprint,
                role: Permit.reviewerRole, scope: Permit.bookScope,
                pieces: [], mark: [:],
                at: Date(timeIntervalSince1970: 20),
                by: mine.author.fingerprint),
            signedBy: mine.author, in: projectURL)
    }

    // MARK: - The window between a manifest and its device record

    /// **An admitted device whose record has not arrived is read off its own
    /// filename, and its captures apply** (P3a Task 6, fix round 1; Task 5's
    /// I5 rule one stream over).
    ///
    /// A person record and a device record are two files that sync separately,
    /// and `RegistryAdmission.admit` writes only the first — so there is a real
    /// window in which this book knows WHO Sam is and not what her keys are
    /// for. The permit narrows by actor, so without a second source that window
    /// would hold every capture she made in it.
    ///
    /// The second source is the stream's own name. Every P1b-or-later writer
    /// names its manifest off `identity.slug`, which carries `<actor>-<hex…>`,
    /// and the claim is believed only where the hex really is the sealing key's
    /// — so it can narrow and never widen. **The window does not exist for a
    /// real slug**, which is what this pins.
    func test_anAdmittedDeviceWithNoRecordYetIsNamedByItsOwnFilename() async throws {
        try plantMyRoot()
        try admitSamWithNoDeviceRecord()
        try await write([entry("a", by: theirs.author)], by: theirs.author)

        let table = try TrustResolution.resolve(
            projectURL: projectURL, identities: mine, cache: cache)
        XCTAssertNil(
            table.actor(forSealKey: theirs.author.fingerprint),
            "no record says what this key is for")
        XCTAssertFalse(
            table.aDeviceRecordNames(theirs.author.fingerprint),
            "and none names it at all, so the filename may")

        let inbox = makeInbox()
        await inbox.refresh()
        XCTAssertEqual(inbox.entries.map(\.id), ["a"],
                       "her captures arrive while her device record is in flight")
        XCTAssertTrue(inbox.setAsideRecords.isEmpty)
    }

    // MARK: - The pair

    /// **A reviewer's captures arrive.** Capture is always offered — it is the
    /// first rung's own row, and the inbox is the class that grants it to
    /// everybody.
    func test_aReviewersCapturesAreApplied() async throws {
        try plantMyRoot()
        try admitSamAsAReviewer()
        try await write([entry("a", by: theirs.author)], by: theirs.author)

        let inbox = makeInbox()
        await inbox.refresh()
        XCTAssertEqual(inbox.entries.map(\.id), ["a"])
        XCTAssertTrue(inbox.setAsideRecords.isEmpty, "nothing was refused")
    }

    /// **And a row signed by the translation pipeline's key is not.** That key
    /// writes translations and nothing else, anywhere — which is the one thing
    /// that can be refused in this class, and therefore the only way to show
    /// that the inbox read is judging at all.
    func test_aRowSignedByTheTranslationPipelinesKeyIsRefused() async throws {
        try plantMyRoot()
        try admitSamAsAReviewer()
        try await write([entry("a", by: theirs.translator)], by: theirs.translator)

        let inbox = makeInbox()
        await inbox.refresh()
        XCTAssertTrue(inbox.entries.isEmpty, "not a capture this key may make")
        XCTAssertFalse(
            inbox.setAsideRecords.isEmpty,
            "and the row is kept in backup rather than dropped")
    }
}
