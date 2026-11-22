import XCTest
@testable import Maugham
@testable import MaughamCore

/// **Who sealed a note, as the editor's `Document` answers it** (shell p5
/// Task 1): `Document.noteSigner(_:)` is the actor whose key sealed the note's
/// creation line, read off the seal through the trust table at load and at
/// every re-read, or — for a note this `Document` appended itself — the actor
/// whose stream (and key) it went to, known before the seal lands. Never the
/// note's stamped author, which any writer of a line may set.
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

    // MARK: - A note made here

    /// The writer's own note: the author's before the seal that will say so,
    /// and the author's after it, read off that seal.
    func test_aNoteMadeHereIsTheAuthorsBeforeItsSeal() async throws {
        try makeProject()
        let doc = try await load(as: .author)
        let pid = try XCTUnwrap(doc.sequence.first)
        let id = try await doc.addReviewerAnnotation(
            kind: .comment, paragraphId: pid, span: nil,
            body: "tighten this", authorName: "Denver")

        let onDisk = try await signersOnDisk()
        XCTAssertNil(onDisk.actor(ofOp: id),
                     "the premise: no seal covers the new line yet")
        XCTAssertEqual(doc.noteSigner(id), .author,
                       "known first-hand, before its seal")

        await doc.close()
        let reopened = try await load(as: .author)
        XCTAssertEqual(reopened.noteSigner(id), .author, "and read off the seal after it")
        XCTAssertTrue(reopened.noteSignersAppendedHere.isEmpty,
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
        XCTAssertEqual(doc.noteSigner(id), .assistant)
        await doc.close()
    }

    // MARK: - Read off the seal, never the stamp

    /// A note whose provenance says HUMAN, written through a Document loaded as
    /// the assistant — so its line is in the assistant's file and sealed by
    /// the assistant's key. The stamp is not consulted: it is the assistant's.
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
        XCTAssertEqual(doc.noteSigner(id), .assistant)
        await doc.close()
    }

    /// Another Mac, admitted: its note — stamped as Claude's, to show the
    /// stamp is not what is read — is its AUTHOR's, because its author key
    /// sealed it. Its unsealed note names nobody; and when its seal arrives,
    /// the open Document's re-read reads it.
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
        let ids = Set(allNotes(doc).map(\.id))
        XCTAssertTrue(ids.isSuperset(of: [sealedId, unsealedId]),
                      "the premise: both of Ada's notes are applied")
        XCTAssertEqual(doc.noteSigner(sealedId), .author)
        XCTAssertNil(doc.noteSigner(unsealedId), "applied, and no seal says whose")

        // Her seal arrives while the chapter is open.
        _ = try await theirs.sealChain(docId: Self.docId)
        try await doc.handleExternalLogChange()
        XCTAssertEqual(doc.noteSigner(unsealedId), .author)
        await doc.close()
    }

    // MARK: - The margin never reads the stamp

    /// Every production file that asks `noteSigner(` — the margin, and
    /// whatever else comes to decide *whose note* by it — names no
    /// `sourceKind`: a file holding both is one fallback away from guessing a
    /// person off a field any writer may set.
    func test_theMarginNeverReadsTheStamp() throws {
        let sources = try SourceTree.maskedSources(under: "Maugham")
        let readers = sources.filter { Self.readsTheSigner($0.masked) }
        XCTAssertFalse(readers.isEmpty, "the census reads nothing: `noteSigner(` moved?")
        XCTAssertTrue(readers.contains { $0.path.hasSuffix("OpLog/Document.swift") },
                      "the control: the definition is in the population")
        let offenders = readers.filter { Self.namesTheStamp($0.masked) }.map(\.path)
        XCTAssertEqual(offenders, [],
                       "a file that reads a note's signer must not name its stamp")

        // The census's own two directions, on planted text.
        let planted = SourceTree.mask("""
            let mine = doc.noteSigner(note.id) ?? (note.author?.sourceKind == .human ? .author : nil)
            """)
        XCTAssertTrue(Self.readsTheSigner(planted) && Self.namesTheStamp(planted),
                      "the planted offender is caught")
        let control = SourceTree.mask("""
            // a sourceKind in a comment is not code
            let mine = doc.noteSigner(note.id) == .author
            """)
        XCTAssertTrue(Self.readsTheSigner(control))
        XCTAssertFalse(Self.namesTheStamp(control), "the control passes")
    }

    private static func readsTheSigner(_ masked: [UInt8]) -> Bool {
        String(decoding: masked, as: UTF8.self).contains("noteSigner(")
    }

    private static func namesTheStamp(_ masked: [UInt8]) -> Bool {
        String(decoding: masked, as: UTF8.self).contains("sourceKind")
    }
}
