import XCTest
@testable import Maugham
@testable import MaughamCore

/// **This book is mine** (signed op log P2b Task 8, spec §5; a verb in People &
/// Devices since P3b smoke find F3).
///
/// Whether People & Devices offers the claim at all, and what it names, decided
/// as a value. Nothing here reads a folder or mounts a window, so every
/// condition is pinned with the sheet nowhere near it — and, since F3, that no
/// surface puts the question to a Mac unprompted.
///
/// The four conditions are each a refusal in their own right. A Mac already on
/// a chain has nothing to claim — it is IN this book. A folder with no root in
/// it is not somebody else's book, it is a book with no registry yet, and
/// `RegistryPresence.ensureRootIfEmpty` roots it at the next open without
/// asking anybody anything. And a folder this Mac cannot write is a copy it is
/// reading — a book on a locked volume, somebody else's share — where the only
/// thing a Claim could do is fail after the writer had answered.
@MainActor
final class ClaimDecisionTests: XCTestCase {

    private var mac: DeviceIdentity!
    private var oldMac: DeviceIdentity!
    private var oldPhone: DeviceIdentity!

    override func setUp() async throws {
        mac = .softwareForTesting()
        oldMac = .softwareForTesting()
        oldPhone = .softwareForTesting()
    }

    // MARK: - Fixtures

    private let made = Date(timeIntervalSince1970: 1_756_000_000)
    private let admitted = Date(timeIntervalSince1970: 1_757_000_000)

    private func deviceRecord(
        _ identity: DeviceIdentity, name: String, kind: DeviceKind
    ) -> DeviceRecord {
        DeviceRecord(
            device: identity.fingerprint, name: name, kind: kind,
            actors: [DeviceActor.author.rawValue: identity.fingerprint], madeAt: made)
    }

    private func person(
        _ identity: DeviceIdentity, label: String, ownName: String,
        admittedBy: DeviceIdentity
    ) -> PersonRecord {
        PersonRecord(
            person: identity.fingerprint, label: label, ownName: ownName,
            role: "author", admittedAt: admitted, admittedBy: admittedBy.fingerprint)
    }

    /// A book somebody else wrote: their Mac is the root, their phone is on its
    /// chain, and this Mac is named nowhere.
    private func somebodyElsesBook() -> Registry {
        Registry(
            devices: [
                deviceRecord(oldMac, name: "Denver's old MacBook", kind: .mac),
                deviceRecord(oldPhone, name: "Denver's iPhone", kind: .phone),
            ],
            people: [
                person(oldMac, label: "Denver", ownName: "Denver's old MacBook",
                       admittedBy: oldMac),
                person(oldPhone, label: "Denver", ownName: "Denver's iPhone",
                       admittedBy: oldMac),
            ])
    }

    private func table(_ registry: Registry, joinedRoot: String? = nil) -> TrustTable {
        TrustTable.resolve(
            registry: registry, mine: .forAuthor(mac), joinedRoot: joinedRoot)
    }

    // MARK: - When it is offered

    func test_aMacWithNoChainInABookThatHasARootIsOfferedTheClaim() throws {
        let registry = somebodyElsesBook()
        let offer = try XCTUnwrap(ClaimDecision.offer(
            registry: registry, table: table(registry), canWriteRegistry: true, canSign: true))

        XCTAssertEqual(offer.roots, [oldMac.fingerprint],
                       "the roots it would adopt are the ones it found")
    }

    /// The sentence spec §5 writes, with the devices this Mac is holding
    /// history for named in it — the whole of how a writer recognises their own
    /// book.
    func test_theQuestionNamesTheDevicesThisMacDoesNotKnow() throws {
        let registry = somebodyElsesBook()
        let offer = try XCTUnwrap(ClaimDecision.offer(
            registry: registry, table: table(registry), canWriteRegistry: true, canSign: true))

        XCTAssertEqual(offer.names, ["Denver's old MacBook", "Denver's iPhone"])
        XCTAssertTrue(offer.question.contains("Denver's old MacBook"), offer.question)
        XCTAssertTrue(offer.question.contains("Denver's iPhone"), offer.question)
        XCTAssertTrue(offer.question.hasSuffix("Is it yours?"), offer.question)
    }

    /// A root with no record naming it is still a root, and the writer is owed
    /// something they can compare against another screen.
    func test_aRootWithNoRecordNamingItIsAskedAboutByItsCode() throws {
        let registry = Registry(people: [
            person(oldMac, label: "", ownName: "", admittedBy: oldMac),
        ])
        let offer = try XCTUnwrap(ClaimDecision.offer(
            registry: registry, table: table(registry), canWriteRegistry: true, canSign: true))

        XCTAssertEqual(offer.names, [DeviceCode.short(oldMac.fingerprint)])
    }

    // MARK: - When it is not

    func test_aMacAlreadyOnAChainIsNotOfferedTheClaim() {
        let registry = Registry(
            devices: [deviceRecord(mac, name: "Denver's MacBook", kind: .mac)],
            people: [
                person(oldMac, label: "Denver", ownName: "Denver's old MacBook",
                       admittedBy: oldMac),
                person(mac, label: "Denver", ownName: "Denver's MacBook",
                       admittedBy: oldMac),
            ])

        XCTAssertNil(ClaimDecision.offer(
            registry: registry, table: table(registry), canWriteRegistry: true, canSign: true),
            "it is IN this book; there is nothing to claim")
    }

    func test_aBookWithNoRootAtAllIsNotClaimed() {
        let registry = Registry(
            devices: [deviceRecord(oldPhone, name: "Denver's iPhone", kind: .phone)])

        XCTAssertNil(ClaimDecision.offer(
            registry: registry, table: table(registry), canWriteRegistry: true, canSign: true),
            "a book with no registry yet is rooted at the next open, not claimed")
    }

    /// A claim is two signed records, and a Mac with no key is refused by the
    /// writer before anything is written — so the control is not offered.
    func test_aMacThatCannotSignIsNotOfferedAClaimItCouldNotPerform() {
        let registry = somebodyElsesBook()

        XCTAssertNil(ClaimDecision.offer(
            registry: registry, table: table(registry),
            canWriteRegistry: true, canSign: false))
    }

    func test_aFolderThisMacCannotWriteIsNotOfferedAClaimItCouldNotPerform() {
        let registry = somebodyElsesBook()

        XCTAssertNil(ClaimDecision.offer(
            registry: registry, table: table(registry), canWriteRegistry: false, canSign: true))
    }

    // MARK: - Cancel

    /// *Cancel* is the absence of an act, and this is what that leaves: the
    /// table the writer already had, in which every foreign key is `.noChain`
    /// and its history applies as P1's unsigned history (decision B3). Nothing
    /// is written, so there is nothing to assert about the folder — which is
    /// the point.
    func test_cancelLeavesTheBookExactlyAsB3Reads() {
        let registry = somebodyElsesBook()
        let table = table(registry)

        XCTAssertNil(table.myRoot)
        XCTAssertEqual(table.verdict(forSealKey: oldPhone.fingerprint), .noChain)
        XCTAssertEqual(table.verdict(forSealKey: oldMac.fingerprint), .noChain)
    }

    // MARK: - Can this Mac write the folder at all

    /// The probe, against a real directory. `isWritableFile` is an `access`
    /// check: it answers the ordinary cases — a book on a read-only volume, a
    /// share mounted for reading — and it is not a promise, which is why the
    /// claim itself still throws rather than trusting this.
    func test_theProbeSaysYesOfAFolderThisMacCanWrite() throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent(".maugham/people", isDirectory: true),
            withIntermediateDirectories: true)

        XCTAssertTrue(ClaimDecision.canWriteRegistry(in: project))
    }

    func test_theProbeSaysNoOfARegistryFolderThisMacMayOnlyRead() throws {
        let project = try makeProject()
        let people = project.appendingPathComponent(".maugham/people", isDirectory: true)
        try FileManager.default.createDirectory(
            at: people, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: people.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: people.path)
            try? FileManager.default.removeItem(at: project)
        }

        XCTAssertFalse(ClaimDecision.canWriteRegistry(in: project))
    }

    /// A registry this device holds only in its own memory — the folder
    /// something deleted — still has an answer, and it is about the nearest
    /// directory that does exist.
    func test_theProbeFallsBackToTheNearestFolderThatIsThere() throws {
        let project = try makeProject()
        defer { try? FileManager.default.removeItem(at: project) }

        XCTAssertTrue(ClaimDecision.canWriteRegistry(in: project),
                      "nothing under .maugham exists yet, and the project folder is writable")
    }

    private func makeProject() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claim-decision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Nobody is asked (P3b smoke find F3, Denver's ruling C)

    /// **Opening a rooted book as an unadmitted Mac presents nothing.** The
    /// smoke's collaborator was asked *Is it yours?* at open, and *Claim* would
    /// have made her a second root; nothing in the folder tells her Mac from the
    /// writer's restored one, so no Mac is asked at all. The claim's sheet is
    /// reached from People & Devices' control alone — this pins that no other
    /// production file builds it, and that the open-time modifier is gone.
    func test_theClaimSheetIsPresentedFromPeopleAndDevicesAlone() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Maugham")
        var files: [(name: String, text: String)] = []
        let walk = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil)
        while let url = walk?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            files.append((url.lastPathComponent,
                          try String(contentsOf: url, encoding: .utf8)))
        }
        XCTAssertGreaterThan(files.count, 100, "the walk found the app's sources")

        XCTAssertEqual(Self.claimSheetBuilders(in: files), ["ProjectSettingsSheet.swift"],
                       "the claim is confirmed only from the People & Devices verb")
    }

    /// The census, fed a planted offender under a name it would otherwise
    /// accept nothing from — a window presenting the sheet at open, which is
    /// exactly the shape F3 removed.
    func test_theClaimSheetCensusCatchesAPlantedOffender() {
        let files = [
            ("ProjectSettingsSheet.swift", ".sheet(item: $claiming) { ClaimSheet(offer: $0) }"),
            ("ProjectWindow.swift", ".sheet(item: $offer) { ClaimSheet(offer: $0) }"),
            ("ClaimSheet.swift", "struct ClaimSheet: View { init() { _ = ClaimSheet(" ),
        ]
        XCTAssertEqual(Self.claimSheetBuilders(in: files),
                       ["ProjectSettingsSheet.swift", "ProjectWindow.swift"])
    }

    /// Every production file that builds the claim's sheet, sorted — the
    /// sheet's own file excepted.
    private static func claimSheetBuilders(
        in files: [(name: String, text: String)]
    ) -> [String] {
        files.filter { $0.name != "ClaimSheet.swift" && $0.text.contains("ClaimSheet(") }
            .map(\.name).sorted()
    }
}
