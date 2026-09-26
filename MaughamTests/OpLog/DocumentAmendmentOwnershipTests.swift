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
        projectURL = TestTemp.root
            .appendingPathComponent("docamend-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        cacheURL = TestTemp.root
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

        // The root archives her note, on its own Mac. `writeFile` writes a
        // device's WHOLE file, chained from genesis and sealed at its head, so
        // "append the archive" is spelled as the root's file rewritten with
        // its opening op followed by the archive — the same bytes the root's
        // `OpLogStore.append` would have left, and a stream this Mac saw
        // shorter, never a second history. The archive's id is minted NOW, so
        // it sorts after her note and before the reopen she presses below —
        // the order the two Macs' clocks would give it, and the order that
        // makes the refusal the RULE's rather than the op ids'.
        try writeFile(by: root, ops: [
            opening(by: root), archive(ULID.generate(), of: mine, by: root),
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

    // MARK: - Fix round 1: Ruling D, the raw-mirror readers, Ruling C

    /// **Ruling D: the root's Delete of her note stays the root's.** Her
    /// reopen is the note's creator but not its deleter.
    func test_herReopenDoesNotUndoTheRootsDeleteOfHerNoteOnLoad() async throws {
        let docURL = try makeProject()
        let root = try makeRoot()
        let kim = try makeReviewer(label: "Kim", admittedBy: root)

        try writeFile(by: kim, ops: [
            note("01AAA", by: kim), reopen("01CCC", of: "01AAA", by: kim),
        ])
        try writeFile(by: root, ops: [withdrawal("01BBB", of: "01AAA", by: root)])

        let doc = try await openDoc(docURL)
        XCTAssertTrue(all(doc).isEmpty, "the root deleted it; it stays deleted")
        XCTAssertEqual(doc.withdrawnAnnotations().map(\.id), ["01AAA"])
        await doc.close()
    }

    /// **I1(a): a stray reopen the deriver does not honour does not make her
    /// Restore a silent no-op.** Sid's reopen of her deleted note lands in the
    /// mirror later than her withdrawal; read raw it would say "not
    /// withdrawn", and her `reopenAnnotation` would log and return.
    func test_aStrayReopenDoesNotBlockHerOwnRestore() async throws {
        let docURL = try makeProject()
        let root = try makeRoot()
        let sid = try makeReviewer(label: "Sid", admittedBy: root)
        try beAReviewerHere(root: root)
        try writeFile(by: root, ops: [opening(by: root)])

        let doc = try await openDoc(docURL)
        let id = try await doc.addReviewerAnnotation(
            kind: .comment, paragraphId: "aaaa", span: nil,
            body: "mine", authorName: "Denver")
        try await doc.withdrawReviewerAnnotation(id: id, authorName: "Denver")
        await doc.close()

        // Sid's reopen of it, after her withdrawal (`09ZZZ` sorts after every
        // ULID this run mints) — a line the partition passes and the deriver
        // does not honour.
        try writeFile(by: sid, ops: [reopen("09ZZZ", of: id, by: sid)])

        let again = try await openDoc(docURL)
        XCTAssertTrue(all(again).isEmpty, "Sid's reopen restores nothing")
        XCTAssertEqual(again.withdrawnAnnotations().map(\.id), [id])
        XCTAssertEqual(again.withdrawnAnnotations().first?.withdrawnBy?.displayName,
                       "Denver", "she deleted it, so Restore is hers to press")

        try await again.reopenAnnotation(id: id)
        XCTAssertEqual(all(again).map(\.id), [id], "her Restore restores")
        XCTAssertEqual(all(again).first?.status, .open)
        await again.close()
    }

    /// **Ruling D at the door**: the root's Delete of her note is not hers to
    /// undo, so the door refuses and appends nothing.
    func test_theRestoreDoorRefusesTheRootsDeleteOfHerNote() async throws {
        let docURL = try makeProject()
        let root = try makeRoot()
        try beAReviewerHere(root: root)
        try writeFile(by: root, ops: [opening(by: root)])

        let doc = try await openDoc(docURL)
        let mine = try await doc.addReviewerAnnotation(
            kind: .comment, paragraphId: "aaaa", span: nil,
            body: "mine", authorName: "Denver")
        await doc.close()
        // The root deletes it, on its own Mac (the whole file, as above; the
        // id minted now, so it sorts before the reopen she presses below).
        try writeFile(by: root, ops: [
            opening(by: root), withdrawal(ULID.generate(), of: mine, by: root),
        ])

        let again = try await openDoc(docURL)
        XCTAssertEqual(again.withdrawnAnnotations().map(\.id), [mine])
        // What the pane draws Restore from is the door's own standing (P3c
        // plan 2 Task 8). This fixture's `withdrawal` stamps no author, so a
        // nil `withdrawnBy` proves nothing about the drawing — the standing
        // does, and the same-name case below proves it by key.
        XCTAssertEqual(again.restoreStanding(annotationId: mine), .refused,
                       "the door would refuse her Restore, so the pane draws none")
        let count = again._opLogMirror.count
        do {
            try await again.reopenAnnotation(id: mine)
            XCTFail("the root's Delete of her note is the root's")
        } catch is Document.PostureRefusal {}
        XCTAssertEqual(again._opLogMirror.count, count, "the door appended nothing")
        await again.close()
    }

    /// **Restore is drawn by KEY, never by display name** (P3c plan 2 Task
    /// 8, carried from Task 2's re-review). The root's Delete of her note,
    /// stamped as production stamps it — with a display name that happens to
    /// be HERS. Asked by name (`isOwn(author: withdrawnBy)`, the old drawing)
    /// this reads as her own Delete and draws Restore; the door, which judges
    /// by key, refuses it. The standing is the door's, so it refuses too, and
    /// her own Delete in the same book stands `.asTheDeleter` — both
    /// directions.
    func test_restoreIsDrawnByKeyNotByTheDeletersDisplayName() async throws {
        let docURL = try makeProject()
        let root = try makeRoot()
        try beAReviewerHere(root: root)
        try writeFile(by: root, ops: [opening(by: root)])

        let doc = try await openDoc(docURL)
        let rootDeletes = try await doc.addReviewerAnnotation(
            kind: .comment, paragraphId: "aaaa", span: nil,
            body: "the root deletes this", authorName: "Denver")
        let sheDeletes = try await doc.addReviewerAnnotation(
            kind: .comment, paragraphId: "aaaa", span: nil,
            body: "she deletes this", authorName: "Denver")
        try await doc.withdrawReviewerAnnotation(id: sheDeletes, authorName: "Denver")
        await doc.close()

        var namedWithdraw = withdrawal(ULID.generate(), of: rootDeletes, by: root)
        namedWithdraw = Op(
            opId: namedWithdraw.opId, docId: namedWithdraw.docId, at: namedWithdraw.at,
            device: namedWithdraw.device, session: namedWithdraw.session,
            kind: .annotationWithdraw, changes: [],
            provenance: .init(
                sourceAnnotationId: rootDeletes,
                authorSourceKind: AnnotationAuthor.SourceKind.human.rawValue,
                authorDisplayName: "Denver"))
        try writeFile(by: root, ops: [opening(by: root), namedWithdraw])

        let again = try await openDoc(docURL)
        let byId = Dictionary(uniqueKeysWithValues:
            again.withdrawnAnnotations().map { ($0.id, $0) })
        XCTAssertTrue(AnnotationOwnership.isOwn(
            author: byId[rootDeletes]?.withdrawnBy, localName: "Denver"),
            "premise: by NAME the root's Delete reads as hers")
        XCTAssertEqual(again.restoreStanding(annotationId: rootDeletes), .refused,
                       "by KEY it is the root's, and Restore is not drawn")
        XCTAssertFalse(AnnotationRowVerbs.restoresDeleted(
            posture: Posture(.unrestricted),
            standing: again.restoreStanding(annotationId: rootDeletes)),
            "hidden whatever the posture")
        XCTAssertEqual(again.restoreStanding(annotationId: sheDeletes), .asTheDeleter,
                       "her own Delete is hers to restore as a reviewer")
        XCTAssertTrue(AnnotationRowVerbs.restoresDeleted(
            posture: .settling,
            standing: again.restoreStanding(annotationId: sheDeletes)),
            "drawn even before the posture has settled — the reviewer row")

        // The press agrees with the drawing, both ways — and a refusal is
        // said through the house notice path.
        var said: [String] = []
        let token = NotificationCenter.default.addObserver( // adr-0021-ok: a test observing the production post, not a production subscription
            forName: .maughamDocumentNotice, object: nil, queue: nil
        ) { note in
            if let m = note.userInfo?[MaughamEvent.noticeMessageKey] as? String { said.append(m) }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        do {
            try await again.reopenAnnotation(id: rootDeletes, undoManager: nil)
            XCTFail("the door refuses the root's Delete")
        } catch {
            let sentence = AnnotationsPane.sayRefused(error, in: again)
            XCTAssertEqual(said, [sentence], "a refused Restore is SAID, not swallowed")
        }
        XCTAssertEqual(again.withdrawnAnnotations().map(\.id).sorted(),
                       [rootDeletes, sheDeletes].sorted())
        try await again.reopenAnnotation(id: sheDeletes, undoManager: nil)
        XCTAssertEqual(again.withdrawnAnnotations().map(\.id), [rootDeletes],
                       "her own Restore lands")

        // The pane's Restore hands a refusal to `sayRefused`, never to `try?`.
        let pane = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Maugham/Views/AnnotationsPane.swift"), encoding: .utf8)
        let start = try XCTUnwrap(pane.range(of: "private func reopen(_ document: Document"))
        let body = pane[start.lowerBound...].prefix(400)
        XCTAssertTrue(body.contains("Self.sayRefused(error, in: document)"),
                      "the pane says the refusal")
        XCTAssertFalse(body.contains("try? await document.reopenAnnotation"),
                       "and swallows nothing")
        await again.close()
    }

    /// **I1(c): the rewind's return journey reads honoured ops only.** An
    /// accepted suggestion the rewind archived returns to ACCEPTED on a
    /// forward travel past the accept (RULING-26) — and a reviewer's stray
    /// reopen sitting between the accept and the rewind's archive must not be
    /// read as the status before the archive. Read raw, it says "was open",
    /// and the travel reopens a suggestion whose text it has just restored.
    /// The preview (`RewindImpact`) is pinned to the same answer.
    func test_aStrayReopenIsNotReadAsTheStatusBeforeARewindArchive() async throws {
        let docURL = try makeProject()
        let root = try makeRoot()
        let kim = try makeReviewer(label: "Kim", admittedBy: root)
        try writeFile(by: root, ops: [opening(by: root)])

        // This Mac is an author of the whole book (makeRoot admits it so).
        let doc = try await openDoc(docURL)
        try await doc.flushBurstNow()
        let early = try await doc.opLog().last!.opId
        doc.setFullText("First paragraph.\n\nSecond.\n")
        try await doc.flushBurstNow()
        let log = try await doc.opLog()
        let p2 = try XCTUnwrap(
            log.last { $0.kind == .typingBurst }?
                .changes.first { $0.next.contains("Second") }?.paragraphId)
        let annId = try await doc.addAnnotation(
            kind: .suggestedChange, paragraphId: p2, body: "b",
            suggestedText: "Second, improved.")
        try await doc.acceptAnnotation(id: annId)
        try await doc.flushBurstNow()
        let later = try await doc.opLog().last!.opId
        await doc.close()

        // Kim's reopen of the accepted suggestion: after the accept, before
        // anything the rewind below will mint.
        try writeFile(by: kim, ops: [reopen(ULID.generate(), of: annId, by: kim)])

        let again = try await openDoc(docURL)
        XCTAssertEqual(all(again).first { $0.id == annId }?.status, .accepted,
                       "Kim's reopen is not honoured — the suggestion stays accepted")
        _ = try await again.restoreToOp(opId: early)
        XCTAssertEqual(all(again).first { $0.id == annId }?.status, .archived)

        let opsNow = try await again.opLog()
        let preview = RewindImpact.preview(
            ops: opsNow, cursorOpId: later,
            amendments: again.annotationAmendments)
        XCTAssertEqual(preview.acceptsToRestore, 1, "the preview promises a re-accept")
        XCTAssertEqual(preview.annotationsToReopen, 0, "and no reopen")

        let forward = try await again.restoreToOp(opId: later)
        XCTAssertEqual(all(again).first { $0.id == annId }?.status, .accepted,
                       "the status it had at the travelled-to moment (RULING-26)")
        XCTAssertEqual(forward.travelReacceptedAnnotationIds, [annId])
        XCTAssertTrue(forward.travelReopenedAnnotationIds.isEmpty)
        await again.close()
    }

    /// **Ruling C**: an assistant-signed reopen in a rooted, UN-narrowed book
    /// passes the partition — it is in the mirror, not set aside — and is not
    /// honoured as a disposition.
    func test_anAssistantReopenPassesThePartitionAndIsNotADisposition() async throws {
        let docURL = try makeProject()
        let root = try makeRoot()
        try writeFile(by: root, ops: [
            note("01AAA", by: root), archive("01BBB", of: "01AAA", by: root),
        ])
        try writeFile(by: identities.assistant, ops: [
            reopen("01CCC", of: "01AAA", by: identities.assistant),
        ])

        let doc = try await openDoc(docURL)
        XCTAssertTrue(doc._opLogMirror.contains { $0.opId == "01CCC" },
                      "the reviewer row: the partition passes it")
        XCTAssertEqual(all(doc).first?.status, .archived,
                       "the assistant is never the author of a disposition")
        await doc.close()
    }

    // MARK: - P3 plan 3 Task 5: the skew sentence, the memo, the closed preview

    private static let skewSentence =
        "Another device deleted this note after you restored it. Restore it again to keep it."

    /// **Her Restore, beaten by a clock-ahead Delete, is told so.** She
    /// deleted her own note; the root, whose clock runs ahead, deleted it too
    /// — a withdrawal that sorts after any reopen this run mints. Her Restore
    /// is hers to make, and only the order stands in the way, so the door says
    /// another device deleted it, not that this Mac may not. Nothing appended.
    func test_herRestoreBeatenByAClockAheadDeleteSaysAnotherDeviceDeletedIt() async throws {
        let docURL = try makeProject()
        let root = try makeRoot()
        try beAReviewerHere(root: root)
        try writeFile(by: root, ops: [opening(by: root)])

        let doc = try await openDoc(docURL)
        let mine = try await doc.addReviewerAnnotation(
            kind: .comment, paragraphId: "aaaa", span: nil,
            body: "mine", authorName: "Denver")
        try await doc.withdrawReviewerAnnotation(id: mine, authorName: "Denver")
        await doc.close()
        try writeFile(by: root, ops: [
            opening(by: root), withdrawal("09ZZZ", of: mine, by: root),
        ])

        let again = try await openDoc(docURL)
        XCTAssertEqual(again.withdrawnAnnotations().map(\.id), [mine])
        XCTAssertEqual(again.restoreStanding(annotationId: mine), .asTheDeleter,
                       "hers to restore, so Restore is drawn — the sentence asks her to press it")
        let count = again._opLogMirror.count
        do {
            try await again.reopenAnnotation(id: mine)
            XCTFail("a Delete sorting after her reopen keeps the note deleted")
        } catch let refusal as Document.PostureRefusal {
            XCTAssertEqual(refusal.cause, .deletedAgainElsewhere)
            XCTAssertEqual(refusal.localizedDescription, Self.skewSentence)
        }
        XCTAssertEqual(again._opLogMirror.count, count, "the door appended nothing")
        await again.close()
    }

    /// **Never for somebody else's note — the ordinary sentence stands.**
    /// Kim's note, deleted by Kim, and deleted again by the clock-ahead root;
    /// and Sid's note, made and deleted on a Mac whose clock runs ahead of
    /// this one, so every op about it sorts after her reopen. Neither Delete
    /// was hers to undo, so neither refusal may blame the order.
    func test_theSkewSentenceIsNeverSaidAboutSomebodyElsesNote() async throws {
        let docURL = try makeProject()
        let root = try makeRoot()
        let kim = try makeReviewer(label: "Kim", admittedBy: root)
        let sid = try makeReviewer(label: "Sid", admittedBy: root)
        try beAReviewerHere(root: root)
        try writeFile(by: kim, ops: [
            note("01KKK", by: kim), withdrawal("01KKL", of: "01KKK", by: kim),
        ])
        try writeFile(by: root, ops: [
            opening(by: root), withdrawal("09ZZZ", of: "01KKK", by: root),
        ])
        try writeFile(by: sid, ops: [
            note("09SSS", by: sid), withdrawal("09SST", of: "09SSS", by: sid),
        ])

        let doc = try await openDoc(docURL)
        XCTAssertEqual(Set(doc.withdrawnAnnotations().map(\.id)), ["01KKK", "09SSS"])
        let ordinary = Document.PostureRefusal(kind: .annotationReopen).localizedDescription
        XCTAssertNotEqual(ordinary, Self.skewSentence)
        for id in ["01KKK", "09SSS"] {
            XCTAssertEqual(doc.restoreStanding(annotationId: id), .refused, id)
            let count = doc._opLogMirror.count
            do {
                try await doc.reopenAnnotation(id: id)
                XCTFail("\(id) is not this reviewer's to restore")
            } catch let refusal as Document.PostureRefusal {
                XCTAssertEqual(refusal.cause, .notPermitted, id)
                XCTAssertEqual(refusal.localizedDescription, ordinary, id)
            }
            XCTAssertEqual(doc._opLogMirror.count, count, id)
        }
        await doc.close()
    }

    /// **`restoreStanding` walks once per derive** — two asks, one walk — and
    /// an append clears it, so the next ask walks again and the answer
    /// follows the note (a Restore makes it `.refused`: nothing to restore).
    func test_restoreStandingIsMemoisedAndAnAppendClearsIt() async throws {
        let docURL = try makeProject()
        let doc = try await openDoc(docURL)
        let id = try await doc.addReviewerAnnotation(
            kind: .comment, paragraphId: try XCTUnwrap(doc.sequence.first), span: nil,
            body: "mine", authorName: "Denver")
        try await doc.withdrawReviewerAnnotation(id: id, authorName: "Denver")

        let walks = doc.restoreStandingWalksForTesting
        let first = doc.restoreStanding(annotationId: id)
        XCTAssertNotEqual(first, .refused, "premise: her own Delete is hers to restore")
        XCTAssertEqual(doc.restoreStanding(annotationId: id), first)
        XCTAssertEqual(doc.restoreStandingWalksForTesting - walks, 1, "two asks, one walk")

        try await doc.reopenAnnotation(id: id)
        XCTAssertEqual(doc.restoreStanding(annotationId: id), .refused,
                       "the append cleared the memo: restored, so nothing to restore")
        XCTAssertEqual(doc.restoreStandingWalksForTesting - walks, 2, "and it walked again")
        await doc.close()
    }

    /// **Every site that changes what `restoreStanding` reads clears its
    /// memo** — derived from the code, not listed: every assignment or append
    /// to `_opLogMirror` and every assignment of `annotationAmendments` in
    /// `Maugham/` is followed within a few lines by
    /// `invalidateRestoreStandingMemo()`. A site that skips it is a stale
    /// Restore drawn on the Deleted row.
    func test_everyMirrorOrAmendmentWriteClearsTheRestoreMemo() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Maugham")
        var sites: [String] = []
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for site in Self.memoWriteSites(in: text) {
                sites.append("\(url.lastPathComponent):\(site.line)")
                if !site.cleared { offenders.append("\(url.lastPathComponent):\(site.line)") }
            }
        }
        XCTAssertGreaterThanOrEqual(sites.count, 8, "the census found the sites: \(sites)")
        XCTAssertEqual(offenders, [], "a mirror/amendment write that leaves the memo stale")

        // The control: a planted offender is caught, and its fix is not.
        let planted = """
            func f() {
                _opLogMirror = []
                doSomethingElse()
            }
            func g() {
                self.annotationAmendments = .honourEverything
                invalidateRestoreStandingMemo()
            }
            """
        let found = Self.memoWriteSites(in: planted)
        XCTAssertEqual(found.map(\.cleared), [false, true])
    }

    private static func memoWriteSites(in text: String) -> [(line: Int, cleared: Bool)] {
        let lines = text.components(separatedBy: "\n")
        let write = try! NSRegularExpression(pattern:
            #"_opLogMirror\s*=[^=]|_opLogMirror\.(append|sort|remove|insert|replace)|annotationAmendments\s*=[^=]"#)
        var out: [(Int, Bool)] = []
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.contains("internal var ") { continue }
            let range = NSRange(line.startIndex..., in: line)
            guard write.firstMatch(in: line, range: range) != nil else { continue }
            // The next few lines of the SAME function: a window stops at the
            // next `func`, so a clear in the function below cannot vouch for it.
            var end = i + 1
            while end < min(lines.count, i + 8), !lines[end].contains("func ") { end += 1 }
            let window = lines[i..<end].joined(separator: "\n")
            out.append((i + 1, window.contains("invalidateRestoreStandingMemo()")))
        }
        return out
    }

    /// **A closed piece previews as it does open** — the rewind window's
    /// closed branch builds the table a load builds. The root's note on the
    /// second paragraph, archived by the root, and a reviewer's reopen of it
    /// the deriver does not honour: rewinding to before that paragraph
    /// archives nothing, open or closed. Under the old `.honourEverything`
    /// the closed preview honoured her reopen and counted a note to archive.
    func test_aClosedPiecePreviewsTheSameAsTheOpenPiece() async throws {
        let docURL = try makeProject()
        let root = try makeRoot()
        let kim = try makeReviewer(label: "Kim", admittedBy: root)
        let second = Op(
            opId: "01CCC", docId: Self.docId, at: Date(timeIntervalSince1970: 1_450),
            device: root.deviceId, session: "s", kind: .typingBurst,
            changes: [.init(paragraphId: "bbbb", prior: nil, next: "Second paragraph.")],
            sequence: ["aaaa", "bbbb"])
        let noteOnSecond = Op(
            opId: "01DDD", docId: Self.docId, at: Date(timeIntervalSince1970: 1_500),
            device: root.deviceId, session: "s", kind: .claudeComment,
            changes: [.init(paragraphId: "bbbb", prior: nil, next: "")],
            provenance: .init(
                annotationBody: "the root's note", authorSourceKind: "human",
                authorDisplayName: "Sam"))
        try writeFile(by: root, ops: [
            opening(by: root), second, noteOnSecond,
            archive("01EEE", of: "01DDD", by: root),
        ])
        try writeFile(by: kim, ops: [reopen("01FFF", of: "01DDD", by: kim)])

        let doc = try await openDoc(docURL)
        let openOps = try await doc.opLog()
        let open = RewindImpact.preview(
            ops: openOps, cursorOpId: "01AAA", amendments: doc.annotationAmendments)
        await doc.close()
        XCTAssertEqual(open.annotationsToArchive, 0, "premise: open, her reopen is not honoured")

        let closed = await Document.closedPieceHistory(
            docId: Self.docId, projectURL: projectURL)
        XCTAssertTrue(closed.ops.contains { $0.opId == "01FFF" },
                      "premise: her reopen passes the partition and is in the history")
        XCTAssertNotEqual(
            RewindImpact.preview(ops: closed.ops, cursorOpId: "01AAA"), open,
            "premise: honouring everything would preview differently")
        XCTAssertEqual(
            RewindImpact.preview(
                ops: closed.ops, cursorOpId: "01AAA", amendments: closed.amendments),
            open, "closed, it previews as it does open")

        // And the window's closed branch is the one that asks for it.
        let window = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Maugham/Views/RewindWindow.swift"), encoding: .utf8)
        XCTAssertTrue(window.contains("Document.closedPieceHistory("))
        XCTAssertFalse(window.contains("OpLogStore(projectURL: projectURL)\n            ops ="),
                       "the unjudged closed read is gone")
    }
}
