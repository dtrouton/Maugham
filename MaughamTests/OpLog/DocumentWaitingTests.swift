import XCTest
@testable import Maugham
@testable import MaughamCore

/// **The load seam** (signed op log P3a Task 8, spec §4.6, and the controller's
/// ruling on Task 5's census).
///
/// Two halves, and they are separate claims.
///
/// **Attribution.** Five things the load path or a derivation emits on its own
/// account — `Bootstrap`'s opening op, the two pending-recovery folds, the task
/// anchors spliced back into the paragraphs, and a `taskCreate` beside each —
/// used to be signed by whichever actor opened the document. Through MCP that
/// is `assistant`, and every one of those kinds is one the permission table
/// refuses to the assistant: the permit partition would set them aside on the
/// next read, and a document whose `bootstrap` leaves the book derives EMPTY.
/// They are the writer's own words arriving through whichever door was first,
/// so they are the AUTHOR's.
///
/// **Permission.** Where this device's own hand may not write the piece at all
/// — a reviewer's Mac, or an author of some pieces standing in somebody else's
/// — nothing is emitted: no bootstrap (the load waits instead), no pending
/// fold (the file is left byte-for-byte where it is), no anchor mint and no
/// `taskCreate`.
@MainActor
final class DocumentWaitingTests: XCTestCase {

    private var projectURL: URL!
    private var identities: LocalIdentities!
    private var cacheURL: URL!

    override func setUp() async throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("docwait-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("docwait-cache-\(UUID().uuidString).json")
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
        // Process-wide seams: a leak silently changes what every later test's
        // load can vouch for (and where it looks for a registry).
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        try? FileManager.default.removeItem(at: projectURL)
        try? FileManager.default.removeItem(at: cacheURL)
    }

    // MARK: - Fixture

    private static let docId = "doc-wait-test"
    private static let otherDocId = "doc-wait-other"
    private static let docPath = "manuscript/c1.md"
    private static let otherPath = "manuscript/c2.md"

    @discardableResult
    private func makeProject(
        body: String = "First paragraph.\n\nSecond paragraph.\n"
    ) throws -> URL {
        let docURL = projectURL.appendingPathComponent(Self.docPath)
        try body.write(to: docURL, atomically: true, encoding: .utf8)
        try "Another piece.\n".write(
            to: projectURL.appendingPathComponent(Self.otherPath),
            atomically: true, encoding: .utf8)
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [
                StructureItem(
                    id: Self.docId, title: "C1", type: .document, path: Self.docPath),
                StructureItem(
                    id: Self.otherDocId, title: "C2", type: .document,
                    path: Self.otherPath),
            ],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: projectURL.appendingPathComponent(ProjectManifest.fileName))
        return docURL
    }

    private func fileURL(for identity: DeviceIdentity, docId: String = docId) -> URL {
        OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: identity.slug, in: projectURL)
    }

    private func lines(of identity: DeviceIdentity, docId: String = docId) throws -> [Data] {
        try Data(contentsOf: fileURL(for: identity, docId: docId))
            .split(separator: UInt8(0x0A), omittingEmptySubsequences: true)
            .map { Data($0) }
    }

    private func ops(of identity: DeviceIdentity, docId: String = docId) throws -> [Op] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = JSONLAppendStore<Op>.dateDecoding
        return try lines(of: identity, docId: docId).compactMap { line in
            OpLogChain.isSealLine(line) ? nil : try? dec.decode(Op.self, from: line)
        }
    }

    private func opsIfAny(of identity: DeviceIdentity) -> [Op] {
        (try? ops(of: identity)) ?? []
    }

    // MARK: - Registry fixture: this device, admitted by a foreign root

    /// A second Mac's key, standing as the book's root. It must not be one of
    /// this device's keys: `TrustTable.resolve` skips events whose subject is a
    /// root, because a book must not end up with no author.
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
        // This device declares itself, and the root admits it.
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

    /// Narrow this device's permit with a signed event from the root.
    private func narrow(
        by root: DeviceIdentity, role: String, scope: String, pieces: [String] = []
    ) throws {
        try RegistryWriter.write(
            PermitEvent(
                event: PermitEvent.mintID(subject: identities.author.fingerprint),
                kind: role == Permit.reviewerRole ? .roleChanged : .scopeChanged,
                subject: identities.author.fingerprint,
                role: role, scope: scope, pieces: pieces,
                at: Date(timeIntervalSince1970: 3_000), by: root.fingerprint),
            signedBy: root, in: projectURL)
    }

    // MARK: - (1) Attribution

    /// **The census's path A, fixed.** An MCP transient load of an unanchored
    /// manuscript bootstraps — `BootstrapWiringTests` pins that it must — and
    /// the op is the AUTHOR's: in the author's file, sealed by the author's
    /// key, with not one manuscript-text op in the assistant's.
    func test_anAssistantLoadBootstrapsIntoTheAuthorsFile() async throws {
        let docURL = try makeProject()

        let doc = try await Document.load(
            url: docURL, actor: .assistant, session: "mcp-1", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
        await doc.close()

        let authored = try ops(of: identities.author)
        let bootstraps = authored.filter { $0.kind == .bootstrap }
        XCTAssertEqual(bootstraps.count, 1, "one bootstrap, in the author's own file")
        XCTAssertEqual(
            bootstraps[0].device, identities.author.deviceId,
            "the load's own emission is the writer's hand, not the door it came through")

        for op in opsIfAny(of: identities.assistant) {
            XCTAssertNotEqual(
                Permit.group(of: op.kind), .manuscriptText,
                "the assistant may never sign manuscript text: \(op.kind)")
        }

        // Sealed by the author's key — the chained append derives both the file
        // and the signer from `op.device`, so the seal follows the attribution.
        let seal = try XCTUnwrap(
            OpLogChain.Seal.parse(try XCTUnwrap(lines(of: identities.author).last)),
            "the author's tail ends on a seal")
        XCTAssertTrue(seal.verifies())
        XCTAssertEqual(seal.key, identities.author.fingerprint)

        // And the writer's own next load vouches for the whole of it.
        let reopened = try await Document.load(
            url: docURL, actor: .author, session: "s", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
        let provenance = try XCTUnwrap(reopened.provenance)
        XCTAssertEqual(provenance.quarantinedLines, 0)
        XCTAssertGreaterThan(provenance.verifiedLines, 0)
        XCTAssertEqual(reopened.displayText.contains("First paragraph."), true)
        await reopened.close()
    }

    /// **The census's path B.** A pending buffer left behind by a crashed
    /// session is folded back into a real op by the next load. The words are
    /// the writer's; so is the op.
    func test_anAssistantLoadRecoversThePendingBufferAsTheAuthors() async throws {
        let docURL = try makeProject()
        // Bootstrap first, so the recovery arm is what we are watching.
        let first = try await Document.load(
            url: docURL, actor: .assistant, session: "mcp-0", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
        let firstLog = try await first.opLog()
        let pid = try XCTUnwrap(
            firstLog.first { $0.kind == .bootstrap }?.changes.first?.paragraphId)
        await first.close()

        // A crashed session's un-bursted keystrokes, under the slug the NEXT
        // load will look for (the buffer is per device, `PendingBuffer.file`).
        let pending = PendingBuffer(
            projectURL: projectURL, docId: Self.docId,
            device: identities.assistant.deviceId)
        pending.recordChange(
            paragraphId: pid, prior: "First paragraph.",
            next: "First paragraph, and then some more.")
        try await pending.flushToDisk()

        let doc = try await Document.load(
            url: docURL, actor: .assistant, session: "mcp-1", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
        XCTAssertTrue(
            doc.displayText.contains("and then some more"),
            "the recovered words are in the derived document")
        await doc.close()

        let recovered = try XCTUnwrap(
            try ops(of: identities.author).first {
                $0.kind == .typingBurst
                    && $0.changes.contains { $0.next.contains("and then some more") }
            },
            "the recovery fold lands in the author's own file")
        XCTAssertEqual(recovered.device, identities.author.deviceId)
    }

    /// **The census's paths D and E.** `rebuildTasksCache` runs from a plain
    /// `tasks(filter:)` READ; the anchor it splices and the `taskCreate` beside
    /// it are the author's, whichever actor is reading.
    func test_aTaskReadMintsItsAnchorAndBreadcrumbAsTheAuthors() async throws {
        let docURL = try makeProject(body: """
        - [ ] an unanchored task

        Some prose.
        """)
        let doc = try await Document.load(
            url: docURL, actor: .assistant, session: "mcp-tasks", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
        _ = doc.tasks(filter: .init(
            scope: .document(docId: Self.docId),
            statuses: Set(TaskStatus.allCases)))
        await doc.close()

        let authored = try ops(of: identities.author)
        let created = authored.filter { $0.kind == .taskCreate }
        XCTAssertEqual(created.count, 1, "one anchor minted, one breadcrumb")
        XCTAssertEqual(created[0].device, identities.author.deviceId)
        // And the anchored paragraph rode out in the author's burst.
        XCTAssertTrue(
            authored.contains {
                $0.kind == .typingBurst
                    && $0.changes.contains { $0.next.contains("<!--t-") }
            },
            "the anchor splice is manuscript text and is the author's too")
        for op in opsIfAny(of: identities.assistant) {
            XCTAssertNotEqual(Permit.group(of: op.kind), .manuscriptText)
            XCTAssertNotEqual(Permit.group(of: op.kind), .task)
        }
    }

    // MARK: - (2) Permission

    /// **A reviewer's Mac mints nothing.** The load refuses in its own word,
    /// no `.bootstrap` line is written anywhere, and nothing is read from the
    /// `.md` as truth (tripwire 20 — there is no Document to read it into).
    func test_aReviewersLoadOfAPieceWithNoHistoryWaitsAndMintsNothing() async throws {
        let docURL = try makeProject()
        let root = try makeRoot()
        try narrow(by: root, role: Permit.reviewerRole, scope: Permit.bookScope)

        do {
            _ = try await Document.load(
                url: docURL, actor: .author, session: "s", presenter: nil,
                burstIdle: .seconds(3600), burstMax: .seconds(3600))
            XCTFail("a reviewer may not bootstrap a piece")
        } catch let error as DocumentLoadError {
            XCTAssertEqual(
                error, .waitingForPiece(docId: Self.docId, from: "Sam"),
                "typed, and it names the root that would add the piece")
            XCTAssertEqual(
                error.localizedDescription,
                "Waiting for this piece to arrive from Sam.")
        }

        XCTAssertTrue(
            OpLogStore.opLogFileURLs(forDocId: Self.docId, in: projectURL).isEmpty,
            "not one line was written for this document")
        // The `.md` is untouched too: no anchors were minted into it.
        let onDisk = try String(contentsOf: docURL, encoding: .utf8)
        XCTAssertTrue(ParagraphParser.parse(onDisk).allSatisfy { $0.id == nil })
    }

    /// The same device, the same book, under the harsher half of the same
    /// rule: the pending file is not folded, not cleared and not read — its
    /// bytes are exactly what they were — and the writer is told, once, through
    /// the channel the load already has.
    func test_aReviewersLoadLeavesThePendingFileByteForByte() async throws {
        let docURL = try makeProject()
        // History first, so the load itself succeeds and only the FOLD is at
        // stake. Written while this device is still an author.
        let seeded = try await Document.load(
            url: docURL, actor: .author, session: "s0", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
        let seededLog = try await seeded.opLog()
        let pid = try XCTUnwrap(
            seededLog.first { $0.kind == .bootstrap }?.changes.first?.paragraphId)
        await seeded.close()

        let pending = PendingBuffer(
            projectURL: projectURL, docId: Self.docId,
            device: identities.author.deviceId)
        pending.recordChange(
            paragraphId: pid, prior: "First paragraph.",
            next: "First paragraph, crashed mid-sentence")
        try await pending.flushToDisk()
        let pendingURL = projectURL
            .appendingPathComponent(".maugham/pending")
            .appendingPathComponent(
                "\(Self.docId).\(identities.author.slug.raw).pending.jsonl")
        let before = try Data(contentsOf: pendingURL)

        let root = try makeRoot()
        try narrow(by: root, role: Permit.reviewerRole, scope: Permit.bookScope)

        let doc = try await Document.load(
            url: docURL, actor: .author, session: "s1", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
        XCTAssertFalse(
            doc.displayText.contains("crashed mid-sentence"),
            "nothing was folded")
        let failure = try XCTUnwrap(
            doc.consumePendingRecoveryFailure(),
            "and the writer is told, through the channel the load already has")
        XCTAssertEqual(failure.cause, .notPermitted)
        XCTAssertEqual(failure.name, pendingURL.lastPathComponent)
        await doc.close()

        XCTAssertEqual(
            try Data(contentsOf: pendingURL), before,
            "the words stay safe on disk, byte for byte")
    }

    /// A read must not write where this device may not write: no anchor is
    /// minted into the paragraph and no `taskCreate` is filed, while the tasks
    /// themselves still derive and show.
    func test_aReviewersTaskReadMintsNoAnchorAndNoBreadcrumb() async throws {
        let docURL = try makeProject(body: """
        - [ ] an unanchored task

        Some prose.
        """)
        let seeded = try await Document.load(
            url: docURL, actor: .author, session: "s0", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
        await seeded.close()
        // Clear what the writer's own session anchored, so the next read has
        // something to mint: re-write the `.md`'s paragraph un-anchored through
        // the op log is not possible, so assert against a FRESH count instead.
        let createdBefore = try ops(of: identities.author)
            .filter { $0.kind == .taskCreate }.count

        let root = try makeRoot()
        try narrow(by: root, role: Permit.reviewerRole, scope: Permit.bookScope)

        let doc = try await Document.load(
            url: docURL, actor: .author, session: "s1", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
        let tasks = doc.tasks(filter: .init(
            scope: .document(docId: Self.docId),
            statuses: Set(TaskStatus.allCases)))
        XCTAssertFalse(tasks.isEmpty, "the tasks still derive and still show")
        await doc.close()

        XCTAssertEqual(
            try ops(of: identities.author).filter { $0.kind == .taskCreate }.count,
            createdBefore,
            "a reviewer's READ files no creation breadcrumb")
    }

    /// **An author of SOME pieces**: her own piece opens and bootstraps as it
    /// always did; somebody else's waits.
    func test_anAuthorOfSomePiecesBootstrapsHersAndWaitsForTheRest() async throws {
        _ = try makeProject()
        let root = try makeRoot()
        try narrow(
            by: root, role: Permit.authorRole, scope: Permit.piecesScope,
            pieces: [Self.docId])

        let hers = try await Document.load(
            url: projectURL.appendingPathComponent(Self.docPath),
            actor: .author, session: "s", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
        XCTAssertTrue(hers.displayText.contains("First paragraph."))
        await hers.close()
        XCTAssertEqual(
            try ops(of: identities.author).filter { $0.kind == .bootstrap }.count, 1)

        do {
            _ = try await Document.load(
                url: projectURL.appendingPathComponent(Self.otherPath),
                actor: .author, session: "s", presenter: nil,
                burstIdle: .seconds(3600), burstMax: .seconds(3600))
            XCTFail("a piece outside her scope is not hers to open")
        } catch let error as DocumentLoadError {
            XCTAssertEqual(error, .waitingForPiece(docId: Self.otherDocId, from: "Sam"))
        }
        XCTAssertTrue(
            OpLogStore.opLogFileURLs(forDocId: Self.otherDocId, in: projectURL).isEmpty)
    }

    // MARK: - Neutrality

    /// **A keyless / P2-era / registry-less book is exactly what it was.** No
    /// registry at all: the load bootstraps, folds and anchors as it always
    /// did. (`BootstrapWiringTests`' four tests are the other half of this
    /// claim, and they are untouched.)
    func test_aBookWithNoRegistryIsUnchanged() async throws {
        let docURL = try makeProject()
        let doc = try await Document.load(
            url: docURL, actor: .author, session: "s", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
        XCTAssertEqual(doc.localWritePermit, .unrestricted,
                       "nothing was resolved, because nothing could turn on it")
        XCTAssertTrue(doc.displayText.contains("First paragraph."))
        await doc.close()
        XCTAssertEqual(
            try ops(of: identities.author).filter { $0.kind == .bootstrap }.count, 1)
    }

    /// **The root is never refused** (constitution must #1). This device writes
    /// its own root record; a permit event naming it counts for nothing, and
    /// the load behaves as it always did.
    func test_thisMacsOwnRootIsNeverRefused() async throws {
        let docURL = try makeProject()
        try RegistryWriter.write(
            DeviceRecord(
                device: identities.author.fingerprint, name: "This Mac", kind: .mac,
                actors: [DeviceActor.author.rawValue: identities.author.fingerprint],
                madeAt: Date(timeIntervalSince1970: 1_000)),
            signedBy: identities.author, in: projectURL)
        try RegistryWriter.write(
            PersonRecord(
                person: identities.author.fingerprint, label: "Denver",
                ownName: "This Mac", role: Permit.authorRole,
                admittedAt: Date(timeIntervalSince1970: 1_000),
                admittedBy: identities.author.fingerprint),
            signedBy: identities.author, in: projectURL)

        let doc = try await Document.load(
            url: docURL, actor: .author, session: "s", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
        XCTAssertTrue(doc.displayText.contains("First paragraph."))
        await doc.close()
        XCTAssertEqual(
            try ops(of: identities.author).filter { $0.kind == .bootstrap }.count, 1)
    }

    /// **A trust resolution that THROWS must never refuse a load that did not
    /// refuse before** (RULING-54's other side). A registry record that is
    /// present and unreadable makes `TrustResolution.resolve` throw; the permit
    /// question falls back to the keyless table — P1's behaviour exactly — and
    /// the load goes on. The READ's own refusal, if there is one, arrives
    /// through its own door with its own sentence.
    func test_anUnreadableRegistryRecordDoesNotRefuseTheLoad() async throws {
        let docURL = try makeProject()
        let devices = RegistryWriter.directoryURL(.devices, in: projectURL)
        try FileManager.default.createDirectory(
            at: devices, withIntermediateDirectories: true)
        try Data("not a record".utf8).write(
            to: devices.appendingPathComponent("\(String(repeating: "a", count: 64)).json"))

        let doc = try await Document.load(
            url: docURL, actor: .author, session: "s", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
        XCTAssertTrue(doc.displayText.contains("First paragraph."),
                      "the writer's manuscript opens whatever the registry says")
        await doc.close()
    }
}
