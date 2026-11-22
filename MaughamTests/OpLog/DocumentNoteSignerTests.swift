import XCTest
@testable import Maugham
@testable import MaughamCore

/// **Whose note this is, as the editor's `Document` answers it** (shell p5
/// Task 1 and its fix round 1): `Document.noteOwner(_:)` is the writer whose
/// key sealed the note's creation line, read off the seal through the trust
/// table at load and at every re-read — or, for a note this `Document`
/// appended itself, the writer whose stream (and key) it went to, known
/// before the seal lands. Where no seal covers the line, the note's own
/// stamp, unverified; where a seal this device does not stand behind does,
/// nobody.
@MainActor
final class DocumentNoteSignerTests: XCTestCase {

    private var projectURL: URL!
    private var identities: LocalIdentities!

    override func setUp() async throws {
        projectURL = TestTemp.root
            .appendingPathComponent("notesigner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        // Four software signers, so a seal is assertable on CI's enclave-less
        // runner, and this project's own chain and registry memories.
        identities = LocalIdentities.softwareForTesting()
        Document.localIdentitiesForTesting = identities
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("op-log-state.json"))
        Document.registryCacheForTesting = RegistryCache(
            fileURL: projectURL.appendingPathComponent("registry-cache.json"),
            identity: identities.author.fingerprint)
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
    }

    // MARK: - Fixture

    private static let docId = "doc-signer"
    private static let docPath = "manuscript/c1.md"

    private var docURL: URL { projectURL.appendingPathComponent(Self.docPath) }

    private func makeProject() throws {
        try "First paragraph.\n\nSecond paragraph.\n".write(
            to: docURL, atomically: true, encoding: .utf8)
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
    }

    private func load(as actor: DeviceActor) async throws -> Document {
        try await Document.load(
            url: docURL, actor: actor, session: "s", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
    }

    /// What a fresh read of the files says, beside any open Document.
    private func signersOnDisk() async throws -> LineSigners {
        let signers = LineSigners()
        let store = OpLogStore(
            projectURL: projectURL, identities: identities,
            state: try XCTUnwrap(Document.deviceStateForTesting))
        _ = try await store.loadDiagnosed(docId: Self.docId, lineSigners: signers)
        return signers
    }

    private func allNotes(_ doc: Document) -> [Annotation] {
        doc.annotations(filter: AnnotationFilter(statuses: nil))
    }

    private func owner(_ doc: Document, _ id: String) throws -> NoteOwner {
        doc.noteOwner(try XCTUnwrap(allNotes(doc).first { $0.id == id }, "note \(id)"))
    }

    // MARK: - A note made here

    /// The writer's own note: hers before the seal that will say so, and hers
    /// after it, read off that seal.
    func test_aNoteMadeHereIsTheAuthorsBeforeItsSeal() async throws {
        try makeProject()
        let doc = try await load(as: .author)
        let pid = try XCTUnwrap(doc.sequence.first)
        let id = try await doc.addReviewerAnnotation(
            kind: .comment, paragraphId: pid, span: nil,
            body: "tighten this", authorName: "Denver")

        let onDisk = try await signersOnDisk()
        XCTAssertEqual(onDisk.reading(ofOp: id), .uncovered,
                       "the premise: no seal covers the new line yet")
        XCTAssertEqual(try owner(doc, id), .verified(.author, ofThisWriter: true),
                       "known first-hand, before its seal")

        await doc.close()
        let reopened = try await load(as: .author)
        XCTAssertEqual(try owner(reopened, id), .verified(.author, ofThisWriter: true),
                       "and read off the seal after it")
        XCTAssertTrue(reopened.noteSealReadingsAppendedHere.isEmpty,
                      "the reopened answer is the seal's, not a memory")
        await reopened.close()
    }

    /// Claude's note through the writer's own open Document goes to the
    /// assistant's stream (`deviceFor(author:)`), so it is the assistant's
    /// from its append.
    func test_aClaudeNoteMadeHereIsTheAssistantsFromItsAppend() async throws {
        try makeProject()
        let doc = try await load(as: .author)
        let pid = try XCTUnwrap(doc.sequence.first)
        let id = try await doc.addAnnotation(
            kind: .comment, paragraphId: pid, body: "consider",
            author: AnnotationAuthor(sourceKind: .claude, displayName: "Claude"))
        XCTAssertEqual(try owner(doc, id), .verified(.assistant, ofThisWriter: true))
        await doc.close()
    }

    /// A device whose keys cannot sign (no enclave): nothing it writes is ever
    /// sealed, so its own note is the stamp's — unverified, never hidden —
    /// from the append, and the same after a reload.
    func test_aKeylessDevicesOwnNoteIsStampedNotHidden() async throws {
        let token = Data(UUID().uuidString.utf8)
        identities = LocalIdentities(
            author: .unsignedForTesting(token: token, actor: .author),
            assistant: .unsignedForTesting(token: token + Data([1]), actor: .assistant),
            translator: .unsignedForTesting(token: token + Data([2]), actor: .translator),
            maugham: .unsignedForTesting(token: token + Data([3]), actor: .maugham))
        Document.localIdentitiesForTesting = identities
        try makeProject()
        let doc = try await load(as: .author)
        let pid = try XCTUnwrap(doc.sequence.first)
        let id = try await doc.addReviewerAnnotation(
            kind: .comment, paragraphId: pid, span: nil, body: "mine", authorName: "Denver")
        XCTAssertEqual(try owner(doc, id), .stamped(.human))
        await doc.close()
        let reopened = try await load(as: .author)
        XCTAssertEqual(try owner(reopened, id), .stamped(.human))
        await reopened.close()
    }

    // MARK: - Read off the seal; the stamp only where none covers

    /// A note whose provenance says HUMAN, written through a Document loaded as
    /// the assistant — so its line is in the assistant's file and sealed by
    /// the assistant's key. The seal wins over the stamp.
    func test_aClaudeNoteStampedHumanIsStillTheAssistants() async throws {
        try makeProject()
        let opened = try await load(as: .author)
        let pid = try XCTUnwrap(opened.sequence.first)
        await opened.close()

        let asAssistant = try await load(as: .assistant)
        let id = try await asAssistant.addReviewerAnnotation(
            kind: .comment, paragraphId: pid, span: nil,
            body: "looks human, is not", authorName: "Denver")
        await asAssistant.close()

        let doc = try await load(as: .author)
        let note = try XCTUnwrap(allNotes(doc).first { $0.id == id })
        XCTAssertEqual(note.author?.sourceKind, .human, "the premise: the stamp says human")
        XCTAssertEqual(doc.noteOwner(note), .verified(.assistant, ofThisWriter: true))
        await doc.close()
    }

    /// Another Mac, admitted: its sealed note — stamped as Claude's, to show
    /// the stamp is not what is read — is its AUTHOR's, and not this writer's.
    /// Its unsealed note is the stamp's, unverified. When its seal arrives
    /// the open Document's re-read reads it, and — though no op arrived —
    /// the marks are told (fix round 1, I-2).
    func test_aPeersNoteIsReadOffItsSeal() async throws {
        try makeProject()
        let store = try await DocumentStore.open(url: projectURL)
        let bootstrapped = try await load(as: .author)
        await bootstrapped.close()
        let other = LocalIdentities.softwareForTesting()
        _ = try await store.admit(
            device: other.author.fingerprint, label: "Ada", ownName: "Ada’s Mac",
            permit: .author(.book))
        await store.postureSettled()

        let theirs = OpLogStore(
            projectURL: projectURL, identities: other,
            state: OpLogDeviceState(
                fileURL: projectURL.appendingPathComponent("other-state.json")))
        func theirNote(_ id: String) -> Op {
            Op(opId: id, docId: Self.docId, at: Date(), device: other.author.deviceId,
               session: "x", kind: .claudeCraftNote, changes: [],
               provenance: .init(
                   annotationBody: "a note of Ada’s",
                   authorSourceKind: AnnotationAuthor.SourceKind.claude.rawValue,
                   authorDisplayName: "Claude"))
        }
        let sealedId = ULID.generate()
        try await theirs.append(theirNote(sealedId))
        _ = try await theirs.sealChain(docId: Self.docId)
        let unsealedId = ULID.generate()
        try await theirs.append(theirNote(unsealedId))

        let doc = try await load(as: .author)
        XCTAssertEqual(try owner(doc, sealedId), .verified(.author, ofThisWriter: false))
        XCTAssertEqual(try owner(doc, unsealedId), .stamped(.claude),
                       "applied, no seal says whose: the stamp, unverified")

        // Her seal arrives while the chapter is open: no new op, a new owner.
        let version = doc.annotationsVersion
        _ = try await theirs.sealChain(docId: Self.docId)
        try await doc.handleExternalLogChange()
        XCTAssertEqual(try owner(doc, unsealedId), .verified(.author, ofThisWriter: false))
        XCTAssertGreaterThan(doc.annotationsVersion, version,
                             "a seal-only arrival redraws what is keyed on the notes")

        // And a re-read that changes nobody's owner tells nobody.
        let settled = doc.annotationsVersion
        try await doc.handleExternalLogChange()
        XCTAssertEqual(doc.annotationsVersion, settled)
        await doc.close()
    }

    /// **The first-hand answer does not outlive a seal that disagrees** (fix
    /// round 1, M-6): it stands only while the read has no covering seal.
    func test_aFirstHandAnswerYieldsToTheSealRead() async throws {
        try makeProject()
        let doc = try await load(as: .author)
        doc.noteSealReadingsAppendedHere["01NOTE"] = .sealed(.author, ofThisWriter: true)

        XCTAssertFalse(doc.adoptSealReadings(["01NOTE": .uncovered]),
                       "no covering seal yet: the first-hand answer still stands")
        XCTAssertEqual(doc.sealReading("01NOTE"), .sealed(.author, ofThisWriter: true))

        XCTAssertTrue(doc.adoptSealReadings(["01NOTE": .notOurs]))
        XCTAssertEqual(doc.sealReading("01NOTE"), .notOurs)
        XCTAssertNil(doc.noteSealReadingsAppendedHere["01NOTE"])
        await doc.close()
    }

    // MARK: - The stamp is read for ownership in one place

    /// The stamp is read for ownership in exactly ONE function — `NoteOwner.of`
    /// — and only on its no-covering-seal arm: in that file the one code line
    /// naming `sourceKind` is the `.uncovered` arm; nothing else in production
    /// builds a `.stamped` answer; and every Mac file that asks `noteOwner(`
    /// (the margin, and whatever else comes to decide *whose note*) names no
    /// `sourceKind` of its own.
    func test_theStampIsReadForOwnershipOnlyWhereNoSealCovers() throws {
        let home = "Packages/MaughamCore/Sources/MaughamCore/OpLogPermitContext.swift"
        let homeCode = String(decoding: try SourceTree.checkedMask(
            SourceTree.read(home), path: home), as: UTF8.self)
        XCTAssertEqual(Self.stampReadings(homeCode).count, 1, "one line reads the stamp")
        XCTAssertEqual(Self.offendingStampReadings(homeCode), [])

        var builders: [String] = []
        for root in SourceTree.productionRoots {
            for file in try SourceTree.maskedSources(under: root)
            where String(decoding: file.masked, as: UTF8.self).contains(".stamped(")
                && file.path != home {
                builders.append(file.path)
            }
        }
        XCTAssertEqual(builders, [], "only `NoteOwner.of` answers `.stamped`")

        let sources = try SourceTree.maskedSources(under: "Maugham")
        let askers = sources.filter { Self.asksTheOwner($0.masked) }
        XCTAssertTrue(askers.contains { $0.path.hasSuffix("OpLog/Document.swift") },
                      "the control: the definition is in the population")
        let offenders = askers.filter { Self.namesTheStamp($0.masked) }.map(\.path)
        XCTAssertEqual(offenders, [], "a file that asks whose a note is must not read its stamp")

        // The census's own directions, on planted text.
        let plantedArm = String(decoding: SourceTree.mask("""
            case let .sealed(actor, mine)?: return author?.sourceKind == .human ? .stamped(.human) : .verified(actor, ofThisWriter: mine)
            case .uncovered?: return author.map { .stamped($0.sourceKind) } ?? .unknown
            """), as: UTF8.self)
        XCTAssertEqual(Self.offendingStampReadings(plantedArm).count, 1,
                       "a stamp read on the sealed arm is caught; the uncovered arm is the control")
        let plantedAsker = SourceTree.mask("""
            let mine = doc.noteOwner(note) == .unknown && note.author?.sourceKind == .human
            """)
        XCTAssertTrue(Self.asksTheOwner(plantedAsker) && Self.namesTheStamp(plantedAsker),
                      "the planted asker is caught")
        let control = SourceTree.mask("""
            // a sourceKind in a comment is not code
            let mine = doc.noteOwner(note) == .verified(.author, ofThisWriter: true)
            """)
        XCTAssertTrue(Self.asksTheOwner(control))
        XCTAssertFalse(Self.namesTheStamp(control), "the control passes")
    }

    private static func stampReadings(_ code: String) -> [Substring] {
        code.split(separator: "\n").filter { $0.contains("sourceKind") }
    }

    private static func offendingStampReadings(_ code: String) -> [Substring] {
        stampReadings(code).filter { !$0.contains("case .uncovered") }
    }

    private static func asksTheOwner(_ masked: [UInt8]) -> Bool {
        String(decoding: masked, as: UTF8.self).contains("noteOwner(")
    }

    private static func namesTheStamp(_ masked: [UInt8]) -> Bool {
        String(decoding: masked, as: UTF8.self).contains("sourceKind")
    }
}
