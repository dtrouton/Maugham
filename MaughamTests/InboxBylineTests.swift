import XCTest
@testable import Maugham
@testable import MaughamCore

/// **The inbox says who a capture is from** (P2 spec §6).
///
/// Windowless and pure: a registry built in memory, a table resolved from it,
/// and the composed line. What the pane does with the line is one `Text`; what
/// matters is that the three states a device can be in are three different
/// sentences, because the middle one — a capture waiting on an admission the
/// writer has not given — is invisible otherwise.
@MainActor
final class InboxBylineTests: XCTestCase {

    private var mac: DeviceIdentity!
    private var phone: DeviceIdentity!
    private var stranger: DeviceIdentity!

    override func setUp() async throws {
        mac = .softwareForTesting()
        phone = .softwareForTesting()
        stranger = .softwareForTesting()
    }

    /// The id a capture carries: `<actor>-<first 16 of the fingerprint>`.
    private func deviceId(of identity: DeviceIdentity) -> String { identity.deviceId }

    private func deviceRecord(
        _ identity: DeviceIdentity, name: String, kind: DeviceKind = .phone
    ) -> DeviceRecord {
        DeviceRecord(
            device: identity.fingerprint, name: name, kind: kind,
            actors: [DeviceActor.author.rawValue: identity.fingerprint],
            madeAt: Date(timeIntervalSince1970: 1_000))
    }

    private func person(
        _ identity: DeviceIdentity, label: String, ownName: String,
        admittedBy: DeviceIdentity, revoked: Bool = false
    ) -> PersonRecord {
        PersonRecord(
            person: identity.fingerprint, label: label, ownName: ownName,
            role: "author", admittedAt: Date(timeIntervalSince1970: 2_000),
            admittedBy: admittedBy.fingerprint,
            revokedAt: revoked ? Date(timeIntervalSince1970: 3_000) : nil,
            revokedBy: revoked ? mac.fingerprint : nil)
    }

    /// This Mac is the root; `phone` is admitted; `stranger` has a device
    /// record and no admission.
    private func registry(admittingPhone: Bool = true, revoked: Bool = false) -> Registry {
        var people = [person(mac, label: "Denver", ownName: "Denver's MacBook",
                             admittedBy: mac)]
        if admittingPhone {
            people.append(person(phone, label: "Denver", ownName: "Denver's iPhone",
                                 admittedBy: mac, revoked: revoked))
        }
        return Registry(
            devices: [deviceRecord(mac, name: "Denver's MacBook", kind: .mac),
                      deviceRecord(phone, name: "Denver's iPhone"),
                      deviceRecord(stranger, name: "The old iPhone")],
            people: people)
    }

    private func table(_ registry: Registry) -> TrustTable {
        TrustTable.resolve(
            registry: registry, mine: .forAuthor(mac), joinedRoot: nil)
    }

    private func byline(_ identity: DeviceIdentity, in registry: Registry) -> String? {
        InboxByline.text(
            forDeviceId: deviceId(of: identity), registry: registry,
            table: table(registry))
    }

    // MARK: - The three states

    func test_anAdmittedDeviceIsNamedByItsLabel() {
        XCTAssertEqual(byline(phone, in: registry()), "from Denver")
    }

    func test_astrangerWithARecordIsNamedByItsOwnNameAndSaysItIsWaiting() {
        XCTAssertEqual(byline(stranger, in: registry()),
                       "from The old iPhone (not yet admitted)")
    }

    /// A device that has written captures but has declared itself nowhere: its
    /// code is all this book knows, and it is exactly what the writer will see
    /// on that phone's own Settings screen.
    func test_astrangerWithNoRecordIsNamedByItsCode() {
        let unknown = DeviceIdentity.softwareForTesting()
        let line = byline(unknown, in: registry())

        XCTAssertEqual(line, "from \(DeviceCode.short(unknown.fingerprint)) (not yet admitted)")
    }

    // MARK: - What it says nothing about

    /// This Mac's own capture. A *from* line on every row of one's own inbox
    /// would be noise, and there is no admission question to answer.
    func test_thisMacsOwnCaptureHasNoByline() {
        XCTAssertNil(byline(mac, in: registry()))
    }

    /// **A book with no chain says nothing at all** (B3). Under P1 every
    /// capture is applied as unsigned history and nothing is waiting, so
    /// *not yet admitted* would name a state the project is not in.
    func test_abookWithNoRegistrySaysNothing() {
        let empty = Registry()

        XCTAssertNil(InboxByline.text(
            forDeviceId: deviceId(of: phone), registry: empty, table: table(empty)))
    }

    // MARK: - Revocation

    /// A revoked device must not read as admitted: what it writes from now on
    /// is held, and the row is where the writer meets that fact.
    func test_arevokedDeviceSaysSo() {
        XCTAssertEqual(byline(phone, in: registry(revoked: true)), "from Denver (revoked)")
    }

    // MARK: - A disputed actor key names nobody

    /// **The byline asks the same question the verdict does** (P3a fix rounds
    /// 2–3). A device record's non-author actor fingerprints are unsigned
    /// strings any record may list, so the first record carrying a matching
    /// deviceId prefix is not necessarily whose key it is. Two records listing
    /// one `assistant` key means the key is NOBODY's
    /// (`Registry.actorKeyOwners`), and a row must not then be bylined with
    /// either claimant's name — least of all the one that happens to sort
    /// first. It falls to the code line, which is the honest thing to say
    /// about a key nobody owns, and is exactly what the writer needs in order
    /// to check it against the device's own Settings screen.
    func test_adisputedActorKeyIsNamedByItsCodeAndNotByAClaimant() {
        let assistant = DeviceIdentity.softwareForTesting()
        let claimant = DeviceIdentity.softwareForTesting()
        func claiming(_ identity: DeviceIdentity, name: String) -> DeviceRecord {
            DeviceRecord(
                device: identity.fingerprint, name: name, kind: .phone,
                actors: [DeviceActor.author.rawValue: identity.fingerprint,
                         DeviceActor.assistant.rawValue: assistant.fingerprint],
                madeAt: Date(timeIntervalSince1970: 1_000))
        }
        let registry = Registry(
            devices: [deviceRecord(mac, name: "Denver's MacBook", kind: .mac),
                      claiming(phone, name: "Denver's iPhone"),
                      claiming(claimant, name: "Somebody's iPad")],
            people: [person(mac, label: "Denver", ownName: "Denver's MacBook",
                            admittedBy: mac),
                     person(phone, label: "Denver", ownName: "Denver's iPhone",
                            admittedBy: mac),
                     person(claimant, label: "Sam", ownName: "Sam's iPad",
                            admittedBy: mac)])
        let capture = "\(DeviceActor.assistant.rawValue)-"
            + String(assistant.fingerprint.prefix(16))

        XCTAssertNil(registry.actorKeyOwners[assistant.fingerprint],
                     "two records claim it, so nobody owns it")
        let line = InboxByline.text(
            forDeviceId: capture, registry: registry, table: table(registry))

        XCTAssertEqual(
            line,
            "from \(DeviceCode.short(String(assistant.fingerprint.prefix(16)))) "
                + "(not yet admitted)")
        XCTAssertFalse(line?.contains("Sam") ?? false)
        XCTAssertFalse(line?.contains("iPad") ?? false)
    }

    // MARK: - The wiring

    /// The wiring, on the delivery path: a refresh resolves the byline for
    /// each device that has captured, off the registry it verified for its
    /// trust table — never a second read, and never per row.
    func test_theStoreResolvesEachCapturingDeviceOnceARefresh() async throws {
        let projectURL = TestTemp.root
            .appendingPathComponent("inbox-byline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent(".maugham/inbox"),
            withIntermediateDirectories: true)
        let cacheURL = TestTemp.root
            .appendingPathComponent("inbox-byline-cache-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: projectURL)
            try? FileManager.default.removeItem(at: cacheURL)
        }
        let cache = RegistryCache(fileURL: cacheURL, identity: mac.fingerprint)

        // The folder: this Mac's root record, its own phone, and the phone
        // admitted under it. **The stranger writes NO record of its own**
        // (P3a Task 11): a device this register can name has its unsealed span
        // held like its sealed one, so a row that is still APPLIED under a
        // *not yet admitted* byline is one from a device nothing here has ever
        // heard of — the unsigned door, arm 3 of *the file's key*. A recorded
        // stranger's row is held instead, and the Inbox meets it through the
        // pending banner; `PermitStreamLoadTests
        // .test_aStrangersUnsealedInboxManifestIsHeld` is where that is pinned.
        try RegistryWriter.write(
            deviceRecord(mac, name: "Denver's MacBook", kind: .mac),
            signedBy: mac, in: projectURL)
        try RegistryWriter.write(
            deviceRecord(phone, name: "Denver's iPhone"), signedBy: phone, in: projectURL)
        try RegistryWriter.write(
            person(mac, label: "Denver", ownName: "Denver's MacBook", admittedBy: mac),
            signedBy: mac, in: projectURL)
        try RegistryWriter.write(
            person(phone, label: "Denver", ownName: "Denver's iPhone", admittedBy: mac),
            signedBy: mac, in: projectURL)

        // Two captures from the phone, and one from the device nobody has
        // admitted. The stranger's row is left UNSEALED, because a sealed span
        // from a stranger is held back and never applied (spec §4.1) — the row
        // a writer actually meets under a *not yet admitted* byline is one that
        // arrived as unsigned history, which is what an unsealed run is.
        for (identity, id, seal) in [
            (phone!, "id1", true), (phone!, "id2", true), (stranger!, "id3", false)
        ] {
            let store = JSONLAppendStore<InboxEntry>(
                fileURL: InboxManifest.inboxManifestURL(
                    forDeviceSlug: DeviceSlug.make(from: identity.deviceId), in: projectURL),
                chain: ChainPolicy(
                    identity: identity, state: .shared,
                    docId: InboxManifest.chainDocId, projectURL: projectURL))
            try await store.append(InboxEntry(
                id: id, createdAt: Date(timeIntervalSince1970: 100),
                deviceId: identity.deviceId, kind: .text, inlineText: id))
            if seal { try await store.appendSeal() }
        }

        let inbox = InboxStore(
            projectURL: projectURL, deviceId: mac.deviceId, identity: mac,
            identities: .forAuthor(mac), cache: cache)
        await inbox.refresh()

        XCTAssertNil(inbox.unreadableRegistry)
        XCTAssertEqual(inbox.bylines[phone.deviceId], "from Denver")
        // The code its own Settings screen shows, because no record here names
        // it — which is exactly what the writer needs in order to admit it.
        XCTAssertEqual(
            inbox.bylines[stranger.deviceId],
            "from \(DeviceCode.short(String(stranger.fingerprint.prefix(16)))) "
                + "(not yet admitted)")
        XCTAssertEqual(inbox.bylines.count, 2,
                       "one answer per device that captured, not one per row")
    }

    // MARK: - Shapes that must not crash

    func test_amalformedDeviceIdIsNotNamedAtAll() {
        let registry = self.registry()

        XCTAssertNil(InboxByline.text(
            forDeviceId: "", registry: registry, table: table(registry)))
        XCTAssertNil(InboxByline.text(
            forDeviceId: "author-", registry: registry, table: table(registry)))
        XCTAssertNil(InboxByline.text(
            forDeviceId: "nodash", registry: registry, table: table(registry)))
    }
}
