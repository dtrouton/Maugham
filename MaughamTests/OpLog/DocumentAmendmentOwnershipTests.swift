import XCTest
@testable import Maugham
@testable import MaughamCore

/// **Whose annotation it is, through a real `Document.load`** (P3a Task 6,
/// spec §4.2's last paragraph).
///
/// `AnnotationOwnershipTests` (Core) pins the rule; this pins that the editor's
/// own projection is built with it, and that the device that made a note can
/// always amend its own — which is what keeps `⌘Z` honest on the signer's own
/// machine (ADR 0023: undo is compensating ops, and a compensating op nobody
/// honours would leave the writer pressing ⌘Z at nothing).
@MainActor
final class DocumentAmendmentOwnershipTests: XCTestCase {

    private var projectURL: URL!
    private var identities: LocalIdentities!
    private var cacheURL: URL!

    override func setUp() async throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("docamend-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("docamend-cache-\(UUID().uuidString).json")
        identities = LocalIdentities.softwareForTesting()
        Document.localIdentitiesForTesting = identities
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("op-log-state.json"))
        Document.registryCacheForTesting = RegistryCache(
            fileURL: cacheURL, identity: identities.author.fingerprint)
        Document.admissionMemoryForTesting = AdmissionMemory(
            fileURL: projectURL.appendingPathComponent("admission-memory.json"),
            identity: identities.author.fingerprint)
    }

    override func tearDown() async throws {
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        try? FileManager.default.removeItem(at: projectURL)
        try? FileManager.default.removeItem(at: cacheURL)
    }

    // MARK: - Fixture

    private static let docId = "doc-amend-test"
    private static let docPath = "manuscript/c1.md"

    @discardableResult
    private func makeProject() throws -> URL {
        let docURL = projectURL.appendingPathComponent(Self.docPath)
        try "First paragraph.\n\nSecond paragraph.\n"
            .write(to: docURL, atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [StructureItem(
                id: Self.docId, title: "C1", type: .document, path: Self.docPath)],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: projectURL.appendingPathComponent(ProjectManifest.fileName))
        return docURL
    }

    /// The book's root — a second Mac, because `TrustTable.resolve` skips
    /// events whose subject is a root.
    private func makeRoot() throws -> DeviceIdentity {
        let root = DeviceIdentity.softwareForTesting()
        try RegistryWriter.write(
            DeviceRecord(
                device: root.fingerprint, name: "The other Mac", kind: .mac,
                actors: [DeviceActor.author.rawValue: root.fingerprint],
                madeAt: Date(timeIntervalSince1970: 1_000)),
            signedBy: root, in: projectURL)
        try RegistryWriter.write(
            PersonRecord(
                person: root.fingerprint, label: "Sam", ownName: "The other Mac",
                role: Permit.authorRole,
                admittedAt: Date(timeIntervalSince1970: 1_000),
                admittedBy: root.fingerprint),
            signedBy: root, in: projectURL)
        try RegistryWriter.write(
            DeviceRecord(
                device: identities.author.fingerprint, name: "This Mac", kind: .mac,
                actors: Dictionary(uniqueKeysWithValues: DeviceActor.allCases.map {
                    ($0.rawValue, identities[$0].fingerprint)
                }),
                madeAt: Date(timeIntervalSince1970: 2_000)),
            signedBy: identities.author, in: projectURL)
        try RegistryWriter.write(
            PersonRecord(
                person: identities.author.fingerprint, label: "Denver",
                ownName: "This Mac", role: Permit.authorRole,
                admittedAt: Date(timeIntervalSince1970: 2_000),
                admittedBy: root.fingerprint),
            signedBy: root, in: projectURL)
        return root
    }

    /// A third machine, admitted by the root at whichever rung.
    private func makeReviewer(
        label: String, admittedBy root: DeviceIdentity,
        role: String = Permit.reviewerRole
    ) throws -> DeviceIdentity {
        let who = DeviceIdentity.softwareForTesting()
        try RegistryWriter.write(
            DeviceRecord(
                device: who.fingerprint, name: label, kind: .mac,
                actors: [DeviceActor.author.rawValue: who.fingerprint],
                madeAt: Date(timeIntervalSince1970: 2_500)),
            signedBy: who, in: projectURL)
        try RegistryWriter.write(
            PersonRecord(
                person: who.fingerprint, label: label, ownName: label,
                role: role,
                admittedAt: Date(timeIntervalSince1970: 2_500),
                admittedBy: root.fingerprint),
            signedBy: root, in: projectURL)
        try RegistryWriter.write(
            PermitEvent(
                event: PermitEvent.mintID(subject: who.fingerprint),
                kind: .admitted, subject: who.fingerprint,
                role: role, scope: Permit.bookScope,
                pieces: [], mark: [:],
                at: Date(timeIntervalSince1970: 2_500), by: root.fingerprint),
            signedBy: root, in: projectURL)
        return who
    }

    /// The root changing somebody's rung, with a mark taken through the
    /// production door — `seenPositions`, which is what
    /// `RegistryAdmission.changePermit` will compute (Task 7).
    private func changeRole(
        of who: DeviceIdentity, to role: String, by root: DeviceIdentity
    ) throws {
        let mark = try OpLogStore.seenPositions(
            ofDeviceIds: [who.deviceId], in: projectURL,
            trust: try TrustResolution.resolve(
                projectURL: projectURL, identities: identities)).streams
        XCTAssertFalse(mark.isEmpty, "the mark names the file she wrote in")
        try RegistryWriter.write(
            PermitEvent(
                event: PermitEvent.mintID(subject: who.fingerprint),
                kind: .roleChanged, subject: who.fingerprint,
                role: role, scope: Permit.bookScope, pieces: [], mark: mark,
                at: Date(timeIntervalSince1970: 4_000), by: root.fingerprint),
            signedBy: root, in: projectURL)
    }

    private func edit(
        _ opId: String, of target: String, by identity: DeviceIdentity, body: String
    ) -> Op {
        Op(opId: opId, docId: Self.docId, at: Date(timeIntervalSince1970: 1_600),
           device: identity.deviceId, session: "s", kind: .annotationEdit,
           changes: [],
           provenance: .init(annotationBody: body, sourceAnnotationId: target))
    }

    /// One device's own op-log file: chained from genesis and sealed by the key
    /// that wrote it — the same bytes `OpLogStore.append` would leave.
    private func writeFile(by identity: DeviceIdentity, ops: [Op]) throws {
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
            at: Date(timeIntervalSince1970: 3_000))
        bytes.append(seal)
        bytes.append(0x0A)
        let url = OpLogStore.opLogFileURL(
            forDocId: Self.docId, deviceSlug: identity.slug, in: projectURL)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, options: .atomic)
    }

    private func note(_ opId: String, by identity: DeviceIdentity) -> Op {
        Op(opId: opId, docId: Self.docId, at: Date(timeIntervalSince1970: 1_500),
           device: identity.deviceId, session: "s", kind: .claudeComment,
           changes: [.init(paragraphId: "aaaa", prior: nil, next: "")],
           provenance: .init(
            annotationBody: "a note", authorSourceKind: "human",
            authorDisplayName: "x"))
    }

    private func withdrawal(
        _ opId: String, of target: String, by identity: DeviceIdentity
    ) -> Op {
        Op(opId: opId, docId: Self.docId, at: Date(timeIntervalSince1970: 1_600),
           device: identity.deviceId, session: "s", kind: .annotationWithdraw,
           changes: [], provenance: .init(sourceAnnotationId: target))
    }

    private func openDoc(_ url: URL) async throws -> Document {
        try await Document.load(
            url: url, actor: .author, session: "s", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
    }

    // MARK: - The tests

    /// **A reviewer's withdrawal of ANOTHER reviewer's note is ignored by the
    /// editor's own projection.** The note stands; the op stays in the log.
    func test_aReviewerWithdrawingAnotherReviewersNoteIsIgnoredOnLoad() async throws {
        let docURL = try makeProject()
        let root = try makeRoot()
        let kim = try makeReviewer(label: "Kim", admittedBy: root)
        let sam = try makeReviewer(label: "Sid", admittedBy: root)

        try writeFile(by: kim, ops: [note("01AAA", by: kim)])
        try writeFile(by: sam, ops: [withdrawal("01BBB", of: "01AAA", by: sam)])

        let doc = try await openDoc(docURL)
        XCTAssertEqual(
            doc.annotations(filter: AnnotationFilter(statuses: nil)).map(\.id),
            ["01AAA"],
            "Kim's note is not Sid's to withdraw")
        XCTAssertTrue(
            doc.withdrawnAnnotations().isEmpty,
            "and it is not in the Deleted view either")
        await doc.close()
    }

    /// Its converse through the same door: a BOOK AUTHOR's withdrawal of a
    /// reviewer's note is honoured, because settling a note and amending one
    /// are the same authority.
    func test_aBookAuthorWithdrawingAReviewersNoteIsHonouredOnLoad() async throws {
        let docURL = try makeProject()
        let root = try makeRoot()
        let kim = try makeReviewer(label: "Kim", admittedBy: root)

        try writeFile(by: kim, ops: [note("01AAA", by: kim)])
        try writeFile(by: root, ops: [withdrawal("01BBB", of: "01AAA", by: root)])

        let doc = try await openDoc(docURL)
        XCTAssertTrue(
            doc.annotations(filter: AnnotationFilter(statuses: nil)).isEmpty)
        await doc.close()
    }

    /// **The signer's own device always honours its own withdrawal** — the
    /// undo-interplay pin. A reviewer's Mac withdrawing the note it made must
    /// see it go, or `⌘Z`'s compensating reopen would be undoing something the
    /// writer can still see.
    func test_thisMacWithdrawsItsOwnNoteAndSeesItGo() async throws {
        let docURL = try makeProject()
        let root = try makeRoot()
        // This Mac is narrowed to a reviewer, from the moment it was admitted —
        // so nothing it does here is riding on a book author's permit.
        try RegistryWriter.write(
            PermitEvent(
                event: PermitEvent.mintID(subject: identities.author.fingerprint),
                kind: .admitted, subject: identities.author.fingerprint,
                role: Permit.reviewerRole, scope: Permit.bookScope,
                pieces: [], mark: [:],
                at: Date(timeIntervalSince1970: 2_100), by: root.fingerprint),
            signedBy: root, in: projectURL)
        // The piece already has history, so nothing here asks for a bootstrap.
        try writeFile(by: root, ops: [
            Op(opId: "01AAA", docId: Self.docId,
               at: Date(timeIntervalSince1970: 1_400),
               device: root.deviceId, session: "s", kind: .typingBurst,
               changes: [.init(paragraphId: "aaaa", prior: nil, next: "First paragraph.")],
               sequence: ["aaaa"]),
        ])

        let doc = try await openDoc(docURL)
        let id = try await doc.addReviewerAnnotation(
            kind: .comment, paragraphId: "aaaa", span: nil,
            body: "mine", authorName: "Denver")
        XCTAssertEqual(
            doc.annotations(filter: AnnotationFilter(statuses: nil)).map(\.id), [id])

        try await doc.withdrawReviewerAnnotation(id: id, authorName: "Denver")
        XCTAssertTrue(
            doc.annotations(filter: AnnotationFilter(statuses: nil)).isEmpty,
            "her own note is hers to withdraw whatever her rung")
        XCTAssertEqual(doc.withdrawnAnnotations().map(\.id), [id])
        await doc.close()

        // And on the next load, off disk, through the partition and the rule.
        let reopened = try await openDoc(docURL)
        XCTAssertTrue(
            reopened.annotations(filter: AnnotationFilter(statuses: nil)).isEmpty)
        XCTAssertEqual(reopened.withdrawnAnnotations().map(\.id), [id])
        await reopened.close()
    }

    // MARK: - As of the line, not as of today (fix round 1)

    /// **A demotion does not reach back.** Sid edits Kim's note while he is an
    /// author of the whole book — which he may — and is demoted afterwards,
    /// with a mark past the edit. The edit stands.
    ///
    /// Judged by today's permit instead, Sid is now a reviewer with no author
    /// rights over Kim's note, the edit is dropped, and the note's body
    /// silently reverts on every device that reads it. That is spec §5's
    /// forbidden direction one act over.
    func test_anEditMadeAsAnAuthorSurvivesItsWritersLaterDemotion() async throws {
        let docURL = try makeProject()
        let root = try makeRoot()
        let kim = try makeReviewer(label: "Kim", admittedBy: root)
        let sid = try makeReviewer(
            label: "Sid", admittedBy: root, role: Permit.authorRole)

        try writeFile(by: kim, ops: [note("01AAA", by: kim)])
        try writeFile(by: sid, ops: [
            edit("01BBB", of: "01AAA", by: sid, body: "as edited"),
        ])
        try changeRole(of: sid, to: Permit.reviewerRole, by: root)

        let doc = try await openDoc(docURL)
        XCTAssertEqual(
            doc.annotations(filter: AnnotationFilter(statuses: nil)).first?.body,
            "as edited",
            "what he wrote while he could write it stays in the book")
        await doc.close()
    }

    /// **And a promotion is not a pardon.** Sid withdraws Kim's note while he
    /// is a reviewer — which he may not — and is promoted afterwards, with a
    /// mark past the withdrawal. It stays ignored.
    ///
    /// Judged by today's permit instead, the withdrawal he was refused becomes
    /// honoured the day he is promoted, which makes the refusal worth nothing:
    /// do it anyway, ask later.
    func test_aWithdrawalRefusedToAReviewerIsNotPardonedByHisPromotion() async throws {
        let docURL = try makeProject()
        let root = try makeRoot()
        let kim = try makeReviewer(label: "Kim", admittedBy: root)
        let sid = try makeReviewer(label: "Sid", admittedBy: root)

        try writeFile(by: kim, ops: [note("01AAA", by: kim)])
        try writeFile(by: sid, ops: [withdrawal("01BBB", of: "01AAA", by: sid)])
        try changeRole(of: sid, to: Permit.authorRole, by: root)

        let doc = try await openDoc(docURL)
        XCTAssertEqual(
            doc.annotations(filter: AnnotationFilter(statuses: nil)).map(\.id),
            ["01AAA"],
            "a promotion is not a pardon")
        XCTAssertTrue(doc.withdrawnAnnotations().isEmpty)
        await doc.close()
    }

    /// **Neutrality**: with no permit events in the book, every amendment
    /// stands exactly as it did before P3a.
    func test_aBookWithNoEventsHonoursAForeignWithdrawalAsItAlwaysDid() async throws {
        let docURL = try makeProject()
        let root = try makeRoot()
        let kim = DeviceIdentity.softwareForTesting()
        try RegistryWriter.write(
            DeviceRecord(
                device: kim.fingerprint, name: "Kim", kind: .mac,
                actors: [DeviceActor.author.rawValue: kim.fingerprint],
                madeAt: Date(timeIntervalSince1970: 2_500)),
            signedBy: kim, in: projectURL)
        try RegistryWriter.write(
            PersonRecord(
                person: kim.fingerprint, label: "Kim", ownName: "Kim",
                role: Permit.authorRole,
                admittedAt: Date(timeIntervalSince1970: 2_500),
                admittedBy: root.fingerprint),
            signedBy: root, in: projectURL)

        try writeFile(by: root, ops: [note("01AAA", by: root)])
        try writeFile(by: kim, ops: [withdrawal("01BBB", of: "01AAA", by: kim)])

        let doc = try await openDoc(docURL)
        XCTAssertTrue(
            doc.annotations(filter: AnnotationFilter(statuses: nil)).isEmpty,
            "everybody is an author of the whole book until an event says otherwise")
        await doc.close()
    }

    // MARK: - Ruling P: a reopen is judged per pass (P3c plan 2, Task 2)

    private func reopen(
        _ opId: String, of target: String, by identity: DeviceIdentity
    ) -> Op {
        Op(opId: opId, docId: Self.docId, at: Date(timeIntervalSince1970: 1_800),
           device: identity.deviceId, session: "s", kind: .annotationReopen,
           changes: [], provenance: .init(sourceAnnotationId: target))
    }

    private func archive(
        _ opId: String, of target: String, by identity: DeviceIdentity
    ) -> Op {
        Op(opId: opId, docId: Self.docId, at: Date(timeIntervalSince1970: 1_700),
           device: identity.deviceId, session: "s", kind: .claudeArchive,
           changes: [], provenance: .init(sourceAnnotationId: target))
    }

    private func all(_ doc: Document) -> [Annotation] {
        doc.annotations(filter: AnnotationFilter(statuses: nil))
    }

    /// **Her own delete, undone on her own Mac, comes back on every Mac.** The
    /// partition lets her reopen through on the reviewer row and the withdraw
    /// pass honours it by ownership.
    func test_aReviewerRestoringHerOwnDeletedNoteIsHonouredOnLoad() async throws {
        let docURL = try makeProject()
        let root = try makeRoot()
        let kim = try makeReviewer(label: "Kim", admittedBy: root)

        try writeFile(by: kim, ops: [
            note("01AAA", by: kim),
            withdrawal("01BBB", of: "01AAA", by: kim),
            reopen("01CCC", of: "01AAA", by: kim),
        ])

        let doc = try await openDoc(docURL)
        XCTAssertEqual(all(doc).map(\.id), ["01AAA"], "her own note is hers to restore")
        XCTAssertEqual(all(doc).first?.status, .open)
        XCTAssertTrue(doc.withdrawnAnnotations().isEmpty)
        await doc.close()
    }

    /// **Her own note the ROOT archived stays archived.** The same reopen, in
    /// the lifecycle fold, is a disposition — and being the note's author is
    /// not author rights.
    func test_herReopenOfHerOwnNoteTheRootArchivedIsNotHonoured() async throws {
        let docURL = try makeProject()
        let root = try makeRoot()
        let kim = try makeReviewer(label: "Kim", admittedBy: root)

        try writeFile(by: kim, ops: [
            note("01AAA", by: kim), reopen("01CCC", of: "01AAA", by: kim),
        ])
        try writeFile(by: root, ops: [archive("01BBB", of: "01AAA", by: root)])

        let doc = try await openDoc(docURL)
        XCTAssertEqual(all(doc).first?.status, .archived,
                       "the root's disposition stays the root's")
        await doc.close()
    }

    /// Somebody else's archive, and somebody else's delete: a reviewer's
    /// reopen of either passes the partition and changes nothing (RP-1).
    func test_aReviewersReopenOfSomebodyElsesNoteIsNotHonouredOnLoad() async throws {
        let docURL = try makeProject()
        let root = try makeRoot()
        let kim = try makeReviewer(label: "Kim", admittedBy: root)
        let sid = try makeReviewer(label: "Sid", admittedBy: root)

        try writeFile(by: sid, ops: [
            note("01AAA", by: sid),
            note("01DDD", by: sid),
            withdrawal("01EEE", of: "01DDD", by: sid),
        ])
        try writeFile(by: root, ops: [archive("01BBB", of: "01AAA", by: root)])
        try writeFile(by: kim, ops: [
            reopen("01CCC", of: "01AAA", by: kim),
            reopen("01FFF", of: "01DDD", by: kim),
        ])

        let doc = try await openDoc(docURL)
        XCTAssertEqual(all(doc).map(\.id), ["01AAA"], "Sid's deleted note stays deleted")
        XCTAssertEqual(all(doc).first?.status, .archived, "the root's archive stands")
        XCTAssertEqual(doc.withdrawnAnnotations().map(\.id), ["01DDD"])
        await doc.close()
    }

    /// The other direction: the book author's reopen is honoured in both
    /// passes — an archive undone, and a reviewer's delete undone.
    func test_theBookAuthorsReopenIsHonouredOnLoad() async throws {
        let docURL = try makeProject()
        let root = try makeRoot()
        let kim = try makeReviewer(label: "Kim", admittedBy: root)

        try writeFile(by: kim, ops: [
            note("01AAA", by: kim),
            note("01DDD", by: kim),
            withdrawal("01EEE", of: "01DDD", by: kim),
        ])
        try writeFile(by: root, ops: [
            archive("01BBB", of: "01AAA", by: root),
            reopen("01CCC", of: "01AAA", by: root),
            reopen("01FFF", of: "01DDD", by: root),
        ])

        let doc = try await openDoc(docURL)
        XCTAssertEqual(Set(all(doc).map(\.id)), ["01AAA", "01DDD"])
        XCTAssertTrue(all(doc).allSatisfy { $0.status == .open })
        await doc.close()
    }

    /// **Neutrality**: with no permit events, a reopen of anybody's archive
    /// stands exactly as it did.
    func test_aBookWithNoEventsHonoursAForeignReopenAsItAlwaysDid() async throws {
        let docURL = try makeProject()
        let root = try makeRoot()
        let kim = DeviceIdentity.softwareForTesting()
        try RegistryWriter.write(
            DeviceRecord(
                device: kim.fingerprint, name: "Kim", kind: .mac,
                actors: [DeviceActor.author.rawValue: kim.fingerprint],
                madeAt: Date(timeIntervalSince1970: 2_500)),
            signedBy: kim, in: projectURL)
        try RegistryWriter.write(
            PersonRecord(
                person: kim.fingerprint, label: "Kim", ownName: "Kim",
                role: Permit.authorRole,
                admittedAt: Date(timeIntervalSince1970: 2_500),
                admittedBy: root.fingerprint),
            signedBy: root, in: projectURL)

        try writeFile(by: root, ops: [
            note("01AAA", by: root), archive("01BBB", of: "01AAA", by: root),
        ])
        try writeFile(by: kim, ops: [reopen("01CCC", of: "01AAA", by: kim)])

        let doc = try await openDoc(docURL)
        XCTAssertEqual(all(doc).first?.status, .open)
        await doc.close()
    }

    // MARK: - Ruling P at this Mac's own door

    /// This Mac, a reviewer, with the piece's history already on disk.
    private func beAReviewerHere(root: DeviceIdentity) throws {
        try RegistryWriter.write(
            PermitEvent(
                event: PermitEvent.mintID(subject: identities.author.fingerprint),
                kind: .admitted, subject: identities.author.fingerprint,
                role: Permit.reviewerRole, scope: Permit.bookScope,
                pieces: [], mark: [:],
                at: Date(timeIntervalSince1970: 2_100), by: root.fingerprint),
            signedBy: root, in: projectURL)
    }

    private func opening(by root: DeviceIdentity) -> Op {
        Op(opId: "01AAA", docId: Self.docId,
           at: Date(timeIntervalSince1970: 1_400),
           device: root.deviceId, session: "s", kind: .typingBurst,
           changes: [.init(paragraphId: "aaaa", prior: nil, next: "First paragraph.")],
           sequence: ["aaaa"])
    }

    /// **⌘Z of her own Delete is hers** — no longer refused and said; the note
    /// comes back, and stays back off disk.
    func test_aReviewersUndoOfHerOwnDeleteRestoresTheNote() async throws {
        let docURL = try makeProject()
        let root = try makeRoot()
        try beAReviewerHere(root: root)
        try writeFile(by: root, ops: [opening(by: root)])

        let doc = try await openDoc(docURL)
        let id = try await doc.addReviewerAnnotation(
            kind: .comment, paragraphId: "aaaa", span: nil,
            body: "mine", authorName: "Denver")
        let um = UndoManager()
        try await doc.withdrawReviewerAnnotation(
            id: id, authorName: "Denver", undoManager: um)
        XCTAssertTrue(all(doc).isEmpty)

        um.undo()
        await doc.awaitPendingUndoWork()
        XCTAssertEqual(all(doc).map(\.id), [id], "her own Delete, undone")
        XCTAssertEqual(all(doc).first?.status, .open)
        await doc.close()

        let again = try await openDoc(docURL)
        XCTAssertEqual(all(again).map(\.id), [id], "and off disk, through the partition")
        XCTAssertTrue(again.withdrawnAnnotations().isEmpty)
        await again.close()
    }

    /// **The door refuses what the deriver would not honour**: a reviewer's
    /// Restore of a note somebody ELSE deleted, and her reopen of her own note
    /// the root archived. Nothing is appended either time.
    func test_theReopenDoorRefusesWhatTheDeriverWouldNotHonour() async throws {
        let docURL = try makeProject()
        let root = try makeRoot()
        let kim = try makeReviewer(label: "Kim", admittedBy: root)
        try beAReviewerHere(root: root)
        try writeFile(by: root, ops: [opening(by: root)])
        try writeFile(by: kim, ops: [
            note("01KKK", by: kim), withdrawal("01KKL", of: "01KKK", by: kim),
        ])

        let doc = try await openDoc(docURL)
        XCTAssertEqual(doc.withdrawnAnnotations().map(\.id), ["01KKK"])
        let mine = try await doc.addReviewerAnnotation(
            kind: .comment, paragraphId: "aaaa", span: nil,
            body: "mine", authorName: "Denver")
        let before = doc._opLogMirror.count
        do {
            try await doc.reopenAnnotation(id: "01KKK")
            XCTFail("Kim's deleted note is not this reviewer's to restore")
        } catch is Document.PostureRefusal {}
        XCTAssertEqual(doc._opLogMirror.count, before, "the door appended nothing")
        await doc.close()

        // The root archives her note, on its own Mac.
        try writeFile(by: root, ops: [
            opening(by: root), archive("09ZZZ", of: mine, by: root),
        ])
        let again = try await openDoc(docURL)
        XCTAssertEqual(all(again).first { $0.id == mine }?.status, .archived)
        let count = again._opLogMirror.count
        do {
            try await again.reopenAnnotation(id: mine)
            XCTFail("the root's archive of her note is not hers to undo")
        } catch is Document.PostureRefusal {}
        XCTAssertEqual(again._opLogMirror.count, count)
        XCTAssertEqual(all(again).first { $0.id == mine }?.status, .archived)
        await again.close()
    }
}
