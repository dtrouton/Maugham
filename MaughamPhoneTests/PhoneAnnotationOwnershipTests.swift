import XCTest
@testable import MaughamCore
@testable import MaughamPhone

/// **A narrowed book, as the phone finds it on disk** (signed op log P3c plan 2,
/// Task 5): a root Mac (Denver), Denver's own phone admitted as an author of
/// the whole book, Sam — a reviewer, on a Mac and a phone under the same label
/// — and Kim, a second reviewer. Every file is chained and sealed by the key
/// that wrote it, the bytes `OpLogStore.append` would leave; every record is a
/// real signed registry record under a software key (tripwire 36).
///
/// Shared by `PhoneAnnotationOwnershipTests` (the phone's read) and
/// `PhoneAnnotationIntegrationTests` (the phone's writes, read back by the
/// Mac's own Core calls). The caller removes `projectURL` and `scratchURL` in
/// `tearDown`.
@MainActor
struct PhoneNarrowedBook {
    static let docId = "doc-7e1b0f6a"
    static let paragraphId = "k7m3"
    static let paragraphText = "The sun set over the harbour."

    let projectURL: URL
    let scratchURL: URL
    let root = LocalIdentities.softwareForTesting()   // Denver's Mac — the root
    let denverPhone = DeviceIdentity.softwareForTesting()
    let samMac = DeviceIdentity.softwareForTesting()
    let samPhone = DeviceIdentity.softwareForTesting()
    let kim = DeviceIdentity.softwareForTesting()

    init() throws {
        projectURL = TestTemp.root
            .appendingPathComponent("phone-narrowed-\(UUID().uuidString)", isDirectory: true)
        scratchURL = TestTemp.root
            .appendingPathComponent("phone-narrowed-scratch-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(
            at: projectURL.appendingPathComponent(".maugham/ops"),
            withIntermediateDirectories: true)
        try fm.createDirectory(at: scratchURL, withIntermediateDirectories: true)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(timeIntervalSince1970: 1), modified: Date(timeIntervalSince1970: 1),
            structure: [StructureItem(
                id: Self.docId, title: "C1", type: .document, path: "manuscript/c1.md")],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: projectURL.appendingPathComponent(ProjectManifest.fileName))
    }

    func remove() {
        try? FileManager.default.removeItem(at: projectURL)
        try? FileManager.default.removeItem(at: scratchURL)
    }

    // MARK: - The register

    /// The root, both of Denver's devices, Sam's two and Kim's — everybody
    /// admitted, nobody narrowed yet.
    func writeRegister() throws {
        let rootKey = root.author
        try RegistryWriter.write(
            DeviceRecord(
                device: rootKey.fingerprint, name: "Denver’s MacBook", kind: .mac,
                actors: [DeviceActor.author.rawValue: rootKey.fingerprint],
                madeAt: Date(timeIntervalSince1970: 1)),
            signedBy: rootKey, in: projectURL)
        try RegistryWriter.write(
            PersonRecord(
                person: rootKey.fingerprint, label: "Denver", ownName: "Denver’s MacBook",
                admittedAt: Date(timeIntervalSince1970: 10), admittedBy: rootKey.fingerprint),
            signedBy: rootKey, in: projectURL)
        try admit(denverPhone, label: "Denver", kind: .phone)
        try admit(samMac, label: "Sam", kind: .mac)
        try admit(samPhone, label: "Sam", kind: .phone)
        try admit(kim, label: "Kim", kind: .mac)
    }

    /// Sam (both devices) and Kim narrowed to reviewers — the book's first
    /// narrowing.
    func narrow() throws {
        for who in [samMac, samPhone, kim] {
            try RegistryWriter.write(
                PermitEvent(
                    event: "\(who.fingerprint).01", kind: .admitted,
                    subject: who.fingerprint, role: Permit.reviewerRole,
                    scope: Permit.bookScope, pieces: [], mark: [:],
                    at: Date(timeIntervalSince1970: 40), by: root.author.fingerprint),
                signedBy: root.author, in: projectURL)
        }
    }

    private func admit(_ who: DeviceIdentity, label: String, kind: DeviceKind) throws {
        try RegistryWriter.write(
            DeviceRecord(
                device: who.fingerprint, name: label, kind: kind,
                actors: [DeviceActor.author.rawValue: who.fingerprint],
                madeAt: Date(timeIntervalSince1970: 5)),
            signedBy: who, in: projectURL)
        try RegistryWriter.write(
            PersonRecord(
                person: who.fingerprint, label: label, ownName: label,
                admittedAt: Date(timeIntervalSince1970: 20),
                admittedBy: root.author.fingerprint),
            signedBy: root.author, in: projectURL)
    }

    // MARK: - Stores

    /// An `OpLogStore` as a given device holds it: its own keys, its own
    /// memory of heads and of the register, nothing shared with the process.
    func store(for identities: LocalIdentities, _ name: String) -> OpLogStore {
        OpLogStore(
            projectURL: projectURL, identities: identities,
            state: OpLogDeviceState(
                fileURL: scratchURL.appendingPathComponent("\(name)-state.json")),
            cache: RegistryCache(
                fileURL: scratchURL.appendingPathComponent("\(name)-registry.json"),
                identity: identities.author.fingerprint))
    }

    /// The phone's read — the production `AnnotationLoading.loadJudged`, over a
    /// store holding `reader`'s one key.
    func phoneRead(as reader: DeviceIdentity) async throws -> AnnotationLoading.JudgedOps {
        try await AnnotationLoading.loadJudged(
            docId: Self.docId,
            from: store(for: .forAuthor(reader), "phone-\(reader.fingerprint.prefix(8))"))
    }

    /// The Mac's read of the same document, in `Document+Load`'s own two Core
    /// calls — spelled here rather than through the phone's helper so the two
    /// surfaces are compared, not one surface with itself.
    func macRead() async throws -> [Annotation] {
        let mac = store(for: root, "mac")
        let permits = AmendmentPermits()
        let loaded = try await mac.loadDiagnosed(docId: Self.docId, amendmentPermits: permits)
        let projectURL = self.projectURL
        let amendments = mac.annotationAmendments(from: permits) {
            OpLogStore.documentClass(forDocId: Self.docId, in: projectURL)
        }
        return AnnotationAggregation.allAnnotations(ops: loaded.ops, amendments: amendments)
    }

    // MARK: - Ops

    /// The root's opening of the piece, so the notes anchor to real text.
    func opening() -> Op {
        Op(opId: "01A0OPENING0000000000000000", docId: Self.docId,
           at: Date(timeIntervalSince1970: 90), device: root.author.deviceId,
           session: "s", kind: .typingBurst,
           changes: [.init(paragraphId: Self.paragraphId, prior: nil,
                           next: Self.paragraphText)],
           sequence: [Self.paragraphId])
    }

    func note(
        _ opId: String, by who: DeviceIdentity, kind: OpKind = .claudeComment,
        next: String = ""
    ) -> Op {
        Op(opId: opId, docId: Self.docId, at: Date(timeIntervalSince1970: 100),
           device: who.deviceId, session: "s", kind: kind,
           changes: [.init(paragraphId: Self.paragraphId,
                           prior: Self.paragraphText, next: next)],
           provenance: .init(annotationBody: "a note",
                             authorSourceKind: "human", authorDisplayName: "x"))
    }

    func amend(
        _ opId: String, _ kind: OpKind, of target: String, by who: DeviceIdentity,
        body: String? = nil, at seconds: TimeInterval = 200
    ) -> Op {
        Op(opId: opId, docId: Self.docId, at: Date(timeIntervalSince1970: seconds),
           device: who.deviceId, session: "s", kind: kind, changes: [],
           provenance: .init(annotationBody: body, sourceAnnotationId: target))
    }

    /// One device's own op-log file: chained from genesis and sealed by the key
    /// that wrote it.
    func writeFile(by identity: DeviceIdentity, ops: [Op]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        var bytes = Data()
        var head: String?
        for element in try ops.map({ try encoder.encode($0) }) {
            let line = OpLogChain.chainedLine(
                elementJSON: element, prev: head ?? OpLogChain.genesis)
            bytes.append(line)
            bytes.append(0x0A)
            head = OpLogChain.lineHash(line)
        }
        let seal = try OpLogChain.Seal.line(
            head: try XCTUnwrap(head), identity: identity,
            at: Date(timeIntervalSince1970: 300))
        bytes.append(seal)
        bytes.append(0x0A)
        let url = OpLogStore.opLogFileURL(
            forDocId: Self.docId, deviceSlug: identity.slug, in: projectURL)
        try bytes.write(to: url, options: .atomic)
    }
}

/// **The phone judges annotations as the Mac does** (signed op log P3c plan 2,
/// Task 5; spec §12's round trips).
///
/// Before this the phone derived with `.honourEverything`: in a narrowed book a
/// reviewer's edit or withdrawal of somebody else's note — refused on every
/// Mac — stood on the phone. Now `AnnotationLoading.loadJudged` threads the
/// load's `AmendmentPermits` into `OpLogStore.annotationAmendments`, the Mac's
/// own pair, and every derive takes the judgement. The reader here is Sam's
/// phone, a reviewer; each case also asks the Mac's read, so the two surfaces
/// are held to one answer.
@MainActor
final class PhoneAnnotationOwnershipTests: XCTestCase {
    private var book: PhoneNarrowedBook!

    override func setUp() async throws {
        book = try PhoneNarrowedBook()
        try book.writeRegister()
    }

    override func tearDown() async throws {
        book?.remove()
        book = nil
    }

    private var docId: String { PhoneNarrowedBook.docId }

    private func phone() async throws -> [Annotation] {
        AnnotationLoading.allAnnotations(try await book.phoneRead(as: book.samPhone))
    }

    // MARK: - Edits

    /// **A reviewer's edit of somebody else's note is judged away on the
    /// phone**, as it is on the Mac. Sam edits Kim's note on his Mac; his phone
    /// shows Kim's words.
    func test_aReviewersEditOfSomebodyElsesNoteIsJudgedAwayOnThePhone() async throws {
        try book.narrow()
        try book.writeFile(by: book.root.author, ops: [book.opening()])
        try book.writeFile(by: book.kim, ops: [book.note("01KIMA", by: book.kim)])
        try book.writeFile(by: book.samMac, ops: [
            book.amend("01SAMEDIT", .annotationEdit, of: "01KIMA",
                       by: book.samMac, body: "Sam's words"),
        ])

        let onPhone = try await phone()
        XCTAssertEqual(onPhone.first { $0.id == "01KIMA" }?.body, "a note",
                       "Kim's note is not Sam's to edit — on the phone either")
        let onMac = try await book.macRead()
        XCTAssertEqual(onMac.first { $0.id == "01KIMA" }?.body, "a note")

        // And the detail view's re-derive spelling (paragraphs already derived)
        // answers the same.
        let judged = try await book.phoneRead(as: book.samPhone)
        let paragraphs = Deriver.derive(ops: judged.ops).paragraphs
        XCTAssertEqual(
            AnnotationLoading.allAnnotations(judged, paragraphs: paragraphs)
                .first { $0.id == "01KIMA" }?.body,
            "a note")
    }

    /// Its converse: her own edit is hers, on both surfaces — across her two
    /// devices. The note is written on Sam's Mac and edited on Sam's phone;
    /// two keys, two person records, one label, so one writer.
    func test_herOwnEditIsHonouredOnBothSurfaces() async throws {
        try book.narrow()
        try book.writeFile(by: book.root.author, ops: [book.opening()])
        try book.writeFile(by: book.samMac, ops: [book.note("01SAMA", by: book.samMac)])
        try book.writeFile(by: book.samPhone, ops: [
            book.amend("01SAMEDIT", .annotationEdit, of: "01SAMA",
                       by: book.samPhone, body: "Sam's second thoughts"),
        ])

        let onPhone = try await phone()
        let onMac = try await book.macRead()
        XCTAssertEqual(onPhone.first { $0.id == "01SAMA" }?.body, "Sam's second thoughts")
        XCTAssertEqual(onMac.first { $0.id == "01SAMA" }?.body, "Sam's second thoughts")
    }

    // MARK: - Withdrawals and restores

    /// A reviewer's Delete of somebody else's note deletes nothing, on either
    /// surface.
    func test_aReviewersDeleteOfSomebodyElsesNoteDeletesNothingOnThePhone() async throws {
        try book.narrow()
        try book.writeFile(by: book.root.author, ops: [book.opening()])
        try book.writeFile(by: book.kim, ops: [book.note("01KIMA", by: book.kim)])
        try book.writeFile(by: book.samMac, ops: [
            book.amend("01SAMB", .annotationWithdraw, of: "01KIMA", by: book.samMac),
        ])

        let onPhone = try await phone()
        let onMac = try await book.macRead()
        XCTAssertEqual(onPhone.map(\.id), ["01KIMA"])
        XCTAssertEqual(onMac.map(\.id), ["01KIMA"])
    }

    /// **Review Focus 5, as Ruling A re-reads it**: her own-note restore made
    /// on the Mac is honoured when the phone reads it (Ruling P via Task 2's
    /// Core change, and Ruling D: she undoes her own Delete).
    func test_herOwnRestoreMadeOnTheMacIsHonouredOnThePhone() async throws {
        try book.narrow()
        try book.writeFile(by: book.root.author, ops: [book.opening()])
        try book.writeFile(by: book.samMac, ops: [
            book.note("01SAMA", by: book.samMac),
            book.amend("01SAMB", .annotationWithdraw, of: "01SAMA",
                       by: book.samMac, at: 200),
            book.amend("01SAMC", .annotationReopen, of: "01SAMA",
                       by: book.samMac, at: 250),
        ])

        let onPhone = try await phone()
        XCTAssertEqual(onPhone.map(\.id), ["01SAMA"], "her restore stands")
        XCTAssertEqual(onPhone.first?.status, .open)
        let onMac = try await book.macRead()
        XCTAssertEqual(onMac.first?.status, .open)
    }

    /// And the other half of it: somebody else's archive stays archived when
    /// she reopens it — the root's disposition is the root's (RP-1).
    func test_somebodyElsesArchiveStaysArchivedOnThePhone() async throws {
        try book.narrow()
        try book.writeFile(by: book.root.author, ops: [
            book.opening(),
            book.amend("01ROOTARCH", .claudeArchive, of: "01KIMA",
                       by: book.root.author, at: 200),
        ])
        try book.writeFile(by: book.kim, ops: [book.note("01KIMA", by: book.kim)])
        try book.writeFile(by: book.samMac, ops: [
            book.amend("01SAMC", .annotationReopen, of: "01KIMA",
                       by: book.samMac, at: 250),
        ])

        let onPhone = try await phone()
        let onMac = try await book.macRead()
        XCTAssertEqual(onPhone.first?.status, .archived,
                       "her reopen of somebody else's archive is not honoured")
        XCTAssertEqual(onMac.first?.status, .archived)
    }

    // MARK: - Neutrality

    /// **An un-narrowed book reads exactly as it did.** The same edit, with no
    /// permit event anywhere: everybody is an author of the whole book, so the
    /// edit stands — and the judged read derives what `.honourEverything` did.
    func test_anUnnarrowedBookIsIdenticalToToday() async throws {
        try book.writeFile(by: book.root.author, ops: [book.opening()])
        try book.writeFile(by: book.kim, ops: [book.note("01KIMA", by: book.kim)])
        try book.writeFile(by: book.samMac, ops: [
            book.amend("01SAMEDIT", .annotationEdit, of: "01KIMA",
                       by: book.samMac, body: "Sam's words"),
        ])

        let judged = try await book.phoneRead(as: book.samPhone)
        let onPhone = AnnotationLoading.allAnnotations(judged)
        XCTAssertEqual(onPhone.first?.body, "Sam's words")
        XCTAssertEqual(onPhone, AnnotationLoading.allAnnotations(ops: judged.ops, amendments: .honourEverything),
                       "no narrowing, no difference from the pre-P3a rule")
    }
}

/// **C7: the phone's two `ChainPolicy` sites are write-only, and single-signer
/// is the table's answer for a write.** `AnnotationWriter` and
/// `InboxCaptureWriter` take `ChainPolicy`'s default trust closure. The chained
/// WRITE asks that closure exactly one thing — *is this key `.mine`* — and the
/// phone holds one key, so the default and the verified table (the one a READ
/// would need) agree on every key in a narrowed book. That agreement is why
/// the default stays; `TripwirePhoneGrepTest.test_thePhonesChainedStoresOnlyWrite`
/// keeps a read from appearing through either store.
@MainActor
final class PhoneChainPolicyTests: XCTestCase {
    private var book: PhoneNarrowedBook!

    override func setUp() async throws {
        book = try PhoneNarrowedBook()
        try book.writeRegister()
        try book.narrow()
    }

    override func tearDown() async throws {
        book?.remove()
        book = nil
    }

    func test_theDefaultSingleSignerTrustIsTheTablesAnswerForAWrite() throws {
        let phone = book.denverPhone
        let policy = ChainPolicy(
            identity: phone, state: .shared,
            docId: PhoneNarrowedBook.docId, projectURL: book.projectURL)
        let table = try TrustResolution.resolve(
            projectURL: book.projectURL, identities: .forAuthor(phone),
            cache: RegistryCache(
                fileURL: book.scratchURL.appendingPathComponent("c7-registry.json"),
                identity: phone.fingerprint))
        let keyless = TrustResolution.keyless(mine: .forAuthor(phone))
        let stranger = DeviceIdentity.softwareForTesting()

        let keys = [phone, book.root.author, book.samMac, book.samPhone,
                    book.kim, stranger].map(\.fingerprint)
        for key in keys {
            let byDefault = policy.trust(key) == .mine
            XCTAssertEqual(byDefault, table.verdict(forSealKey: key) == .mine,
                           "the write's one question, answered by the table")
            XCTAssertEqual(byDefault, keyless.verdict(forSealKey: key) == .mine,
                           "and by the keyless table")
        }
        XCTAssertEqual(policy.trust(phone.fingerprint), .mine)
        XCTAssertNotEqual(policy.trust(book.root.author.fingerprint), .mine,
                          "the root's key is admitted, never this phone's own")
    }
}
