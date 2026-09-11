import XCTest
import SwiftUI
import AppKit
@testable import Maugham
@testable import MaughamCore

/// **A held capture is not an absent one** (signed op log P2, spec §3 and §6).
///
/// A stranger's manifest lines are neither applied nor refused: they wait on an
/// admission. Without the count and the banner, the writer sees an inbox with
/// nothing in it and no reason given — a phone syncing captures into a book
/// that shows none of them, silently. This suite pins the count (the store) and
/// the sentence (the pane), and never presses the button.
@MainActor
final class InboxPendingTests: XCTestCase {

    private var projectURL: URL!
    private var identity: DeviceIdentity!
    private var cacheURL: URL!
    private var cache: RegistryCache!

    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    override func setUp() async throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox-pending-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent(".maugham/inbox"),
            withIntermediateDirectories: true)
        identity = .softwareForTesting()
        cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox-pending-cache-\(UUID().uuidString).json")
        cache = RegistryCache(fileURL: cacheURL, identity: identity.fingerprint)
    }

    override func tearDown() async throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        try? FileManager.default.removeItem(at: projectURL)
        try? FileManager.default.removeItem(at: cacheURL)
    }

    private var windows: [NSWindow] = []

    // MARK: - Fixture (InboxChainTests' shape)

    private func makeInbox() -> InboxStore {
        InboxStore(projectURL: projectURL, deviceId: "mac", identity: identity,
                   identities: .forTesting(author: identity), cache: cache)
    }

    private func manifestURL(_ deviceId: String) -> URL {
        InboxManifest.inboxManifestURL(
            forDeviceSlug: DeviceSlug.make(from: deviceId), in: projectURL)
    }

    private func entry(_ id: String, at seconds: TimeInterval = 100) -> InboxEntry {
        InboxEntry(id: id, createdAt: Date(timeIntervalSince1970: seconds),
                   deviceId: "phone", kind: .text, inlineText: id)
    }

    /// Another device writing its own manifest, on the far side of iCloud.
    private func farSideStore(
        _ deviceId: String, identity: DeviceIdentity
    ) -> JSONLAppendStore<InboxEntry> {
        JSONLAppendStore<InboxEntry>(
            fileURL: manifestURL(deviceId),
            chain: ChainPolicy(
                identity: identity, state: .shared,
                docId: InboxManifest.chainDocId, projectURL: projectURL))
    }

    /// This Mac's own root, so the store has a chain to judge strangers by. With
    /// no chain at all every key answers `.noChain` and nothing is ever held —
    /// P1's behaviour, and the reason this fixture must plant a root.
    private func plantMyRoot() throws {
        try RegistryWriter.write(
            PersonRecord(person: identity.fingerprint, label: "Denver",
                         ownName: "Denver's MacBook",
                         admittedAt: Date(timeIntervalSince1970: 10),
                         admittedBy: identity.fingerprint),
            signedBy: identity, in: projectURL)
    }

    // MARK: - The store counts what it held

    func test_astrangersSealedManifestIsHeldAndCountedAgainstThatDevice() async throws {
        try plantMyRoot()
        let stranger = DeviceIdentity.softwareForTesting()
        let store = farSideStore("stranger", identity: stranger)
        try await store.append(entry("s1", at: 100))
        try await store.append(entry("s2", at: 200))
        try await store.appendSeal()

        let inbox = makeInbox()
        await inbox.refresh()

        XCTAssertTrue(inbox.entries.isEmpty,
                      "held is not applied: \(inbox.entries.map(\.id))")
        XCTAssertEqual(inbox.pendingByDevice[stranger.fingerprint], 2,
                       """
                       TWO captures are waiting, not three: the seal is held \
                       with the rows it closes and is counted nowhere, because \
                       the banner puts the word "captures" after this number \
                       and a seal is not one (P2b Task 10). Got \
                       \(inbox.pendingByDevice)
                       """)
        XCTAssertEqual(inbox.pendingDeviceNames[stranger.fingerprint],
                       DeviceCode.short(stranger.fingerprint),
                       "with nothing on disk naming it, its code is what it is called")
    }

    /// The device's own record is what names it, when the book has one.
    func test_aheldDeviceWithARecordIsNamedByIt() async throws {
        try plantMyRoot()
        let stranger = DeviceIdentity.softwareForTesting()
        try RegistryWriter.write(
            DeviceRecord(device: stranger.fingerprint, name: "The old iPhone",
                         kind: .phone,
                         actors: [DeviceActor.author.rawValue: stranger.fingerprint],
                         madeAt: Date(timeIntervalSince1970: 20)),
            signedBy: stranger, in: projectURL)

        let store = farSideStore("stranger", identity: stranger)
        try await store.append(entry("s1"))
        try await store.appendSeal()

        let inbox = makeInbox()
        await inbox.refresh()

        XCTAssertEqual(inbox.pendingDeviceNames[stranger.fingerprint], "The old iPhone")
    }

    /// This Mac's own captures are never pending: it holds the key that sealed
    /// them.
    func test_thisMacsOwnManifestIsNeverHeld() async throws {
        try plantMyRoot()
        let store = farSideStore("mac", identity: identity)
        try await store.append(entry("m1"))
        try await store.appendSeal()

        let inbox = makeInbox()
        await inbox.refresh()

        XCTAssertEqual(inbox.entries.map(\.id), ["m1"])
        XCTAssertTrue(inbox.pendingByDevice.isEmpty, "\(inbox.pendingByDevice)")
    }

    /// **B3.** A book with no chain judges nobody, so nothing is held and the
    /// banner must not appear — under P1 every capture is applied as unsigned
    /// history, and *waiting for admission* would name a state the project is
    /// not in.
    func test_abookWithNoChainHoldsNothing() async throws {
        let stranger = DeviceIdentity.softwareForTesting()
        let store = farSideStore("stranger", identity: stranger)
        try await store.append(entry("s1"))
        try await store.appendSeal()

        let inbox = makeInbox()
        await inbox.refresh()

        XCTAssertEqual(inbox.entries.map(\.id), ["s1"])
        XCTAssertTrue(inbox.pendingByDevice.isEmpty, "\(inbox.pendingByDevice)")
    }

    // MARK: - The sentence

    func test_theNoticeNamesTheDeviceAndCountsWhatIsWaiting() {
        let notice = InboxPane.pendingNotice(
            counts: ["abcd1234": 14], names: ["abcd1234": "Denver's iPhone"])

        XCTAssertEqual(notice,
                       "14 captures from Denver's iPhone are waiting for admission.")
    }

    func test_oneCaptureIsSaidInTheSingular() {
        let notice = InboxPane.pendingNotice(
            counts: ["abcd1234": 1], names: ["abcd1234": "Denver's iPhone"])

        XCTAssertEqual(notice,
                       "1 capture from Denver's iPhone is waiting for admission.")
    }

    /// Two devices are counted together and named by number: naming both in one
    /// sentence is a sentence that grows without limit, and the section in
    /// Project Settings is where each of them gets a row of its own.
    func test_severalDevicesAreCountedTogether() {
        let notice = InboxPane.pendingNotice(
            counts: ["abcd1234": 3, "beef5678": 4], names: [:])

        XCTAssertEqual(notice, "7 captures from 2 devices are waiting for admission.")
    }

    func test_nothingHeldIsNoNoticeAtAll() {
        XCTAssertNil(InboxPane.pendingNotice(counts: [:], names: [:]))
        XCTAssertNil(InboxPane.pendingNotice(counts: ["abcd1234": 0], names: [:]))
    }

    // MARK: - The banner

    func test_thePaneDrawsTheBannerAndAnAdmitControl() async throws {
        // A real project, because the pane's Admit… names the book it posts
        // about. The inbox and the registry are this suite's own temp folder's.
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox-pending-project-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let bookURL = try await ProjectFactory.createNovelProject(
            named: "Pending", in: parent)
        let projectStore = try await ProjectStore.load(from: bookURL)

        try RegistryWriter.write(
            PersonRecord(person: identity.fingerprint, label: "Denver",
                         ownName: "Denver's MacBook",
                         admittedAt: Date(timeIntervalSince1970: 10),
                         admittedBy: identity.fingerprint),
            signedBy: identity, in: bookURL)
        let stranger = DeviceIdentity.softwareForTesting()
        let store = JSONLAppendStore<InboxEntry>(
            fileURL: InboxManifest.inboxManifestURL(
                forDeviceSlug: DeviceSlug.make(from: "stranger"), in: bookURL),
            chain: ChainPolicy(
                identity: stranger, state: .shared,
                docId: InboxManifest.chainDocId, projectURL: bookURL))
        try await store.append(entry("s1"))
        try await store.appendSeal()

        let inbox = InboxStore(
            projectURL: bookURL, deviceId: "mac", identity: identity,
            identities: .forTesting(author: identity), cache: cache)
        await inbox.refresh()
        XCTAssertFalse(inbox.pendingByDevice.isEmpty, "the fixture really does hold lines")

        let window = TestWindow.mount(
            AnyView(InboxPane(store: inbox, projectStore: projectStore,
                              activeDocumentId: nil, canTranscribe: false,
                              retranscribe: { _ in })
                .frame(maxWidth: .infinity, maxHeight: .infinity)),
            size: CGSize(width: 420, height: 600))
        windows.append(window)
        pump(0.2)

        let texts = try axTexts(in: window)
        XCTAssertTrue(texts.contains { $0.contains("waiting for admission") },
                      "the pane says what it is holding: \(texts)")
        let labels = try axButtonLabels(in: window)
        XCTAssertTrue(labels.contains { $0.hasPrefix("Admit") },
                      "and offers the one control that asks: \(labels)")
    }
}
