// MaughamTests/Stores/DerivedRenderFollowsReReadTests.swift
import XCTest
@testable import MaughamCore
@testable import Maugham

/// **The derived `.md` follows a re-read** (signed op log P3 plan 3, carry C12;
/// the plan's ruling C12-1).
///
/// The `.md` is a derived render of the op log (ADR 0019). A re-read that
/// APPLIES somebody else's change — an op syncing in, an admission letting a
/// held span through — used to leave the render on disk stale until the
/// writer's next keystroke; a load that found the `.md` diverged snapshotted it
/// and left it diverged. Both now schedule the ordinary autosave, the same
/// debounce a keystroke uses, and `performAutosave`'s own guards decide.
///
/// **And neither re-renders a view that is HOLDING lines** (the hazard this
/// task was handed: never write an EMPTY `.md` over the real one). A Mac
/// holding a stranger's or a piece-starter's lines renders a book the Mac that
/// wrote them does not, so its render is a view waiting for a decision, not a
/// staler copy of the same bytes — writing it would blank the words the other
/// Mac can read, in the one human-readable copy iCloud carries. A keystroke on
/// such a Mac still writes, exactly as before this task.
///
/// Real disk, real registry, real signing keys (software, tripwire 36): this
/// Mac is the book's root; a second Mac is a stranger until it is admitted.
@MainActor
final class DerivedRenderFollowsReReadTests: XCTestCase {

    private var projectURL: URL!
    private var docURL: URL!
    private var identities: LocalIdentities!
    private var stranger: DeviceIdentity!
    private var strangerState: OpLogDeviceState!

    override func setUp() async throws {
        let (dir, doc) = try makeTestProject(prefix: "C12RENDER", initialMd: "Hello.\n")
        projectURL = dir
        docURL = doc
        identities = LocalIdentities.forTesting(author: .softwareForTesting())
        Document.localIdentitiesForTesting = identities
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: dir.appendingPathComponent("op-log-state.json"))
        Document.registryCacheForTesting = RegistryCache(
            fileURL: dir.appendingPathComponent("registry-cache.json"),
            identity: identities.author.fingerprint)
        Document.admissionMemoryForTesting = AdmissionMemory(
            fileURL: dir.appendingPathComponent("admission-memory.json"),
            identity: identities.author.fingerprint)
        stranger = DeviceIdentity.softwareForTesting()
        strangerState = OpLogDeviceState(
            fileURL: dir.appendingPathComponent("stranger-state.json"))
    }

    override func tearDown() async throws {
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
        if let projectURL { try? FileManager.default.removeItem(at: projectURL) }
        projectURL = nil
    }

    // MARK: - Fixtures

    private static let docPath = "manuscript/c1.md"

    private func load() async throws -> Document {
        try await Document.load(
            url: docURL, actor: .author, session: "s", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
    }

    /// The root's window, and the piece open in it — bootstrapped by this Mac
    /// from the `.md` it was made with, so its render and the `.md` agree.
    private func openTheRootsWindow() async throws -> (DocumentStore, Document) {
        let store = try await DocumentStore.open(url: projectURL)
        let doc = try await load()
        store.register(document: doc, for: Self.docPath)
        await store.postureSettled()
        await doc.autosaveScheduler.flush()
        return (store, doc)
    }

    /// `identity`'s Mac writes a sentence into the piece — sealed, signed, a
    /// file another Mac wrote, as iCloud would deliver it.
    private func writes(
        _ sentence: String, as identity: DeviceIdentity, state: OpLogDeviceState,
        after sequence: [String]
    ) async throws {
        let store = OpLogStore(projectURL: projectURL, identity: identity, state: state)
        let added = ParagraphID.mintUnique(excluding: Set(sequence))
        try await store.append(Op(
            opId: ULID.generate(), docId: "doc-test", at: Date(),
            device: identity.deviceId, session: "other-mac", kind: .typingBurst,
            changes: [.init(paragraphId: added, prior: nil, next: sentence)],
            sequence: sequence + [added]))
        _ = try await store.sealChain(docId: "doc-test")
    }

    /// An op that changes no text — applied, but nobody's words.
    private func checkpoints(
        as identity: DeviceIdentity, state: OpLogDeviceState
    ) async throws {
        let store = OpLogStore(projectURL: projectURL, identity: identity, state: state)
        try await store.append(Op(
            opId: ULID.generate(), docId: "doc-test", at: Date(),
            device: identity.deviceId, session: "other-mac", kind: .checkpoint,
            changes: []))
        _ = try await store.sealChain(docId: "doc-test")
    }

    private func md() throws -> String {
        try String(contentsOf: docURL, encoding: .utf8)  // adr-0018-ok: test reads the derived render to assert what was written
    }

    /// The file's identity on disk: an atomic write replaces the inode, and
    /// the modification date moves with any write at all.
    private func stamp() throws -> [String] {
        let attrs = try FileManager.default.attributesOfItem(atPath: docURL.path)
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.stringValue ?? "?"
        let date = (attrs[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        return [inode, String(date)]
    }

    private func render(of doc: Document) -> String {
        MarkdownDisplayFilter.stripAnchors(doc.materialize())
    }

    private func conflictBackups() -> [URL] {
        let dir = projectURL.appendingPathComponent(".maugham/conflicts")
        return (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
    }

    // MARK: - An open document

    /// **An admission that re-derives an open document puts the admitted text
    /// in the `.md` within the debounce** — through the scheduler a keystroke
    /// uses (the flush fires what the re-read scheduled; had it scheduled
    /// nothing, the flush would write nothing).
    func test_anAdmissionRendersTheAdmittedTextIntoTheMd() async throws {
        let (store, doc) = try await openTheRootsWindow()
        let sentence = "The stranger’s admitted sentence."
        try await writes(sentence, as: stranger, state: strangerState, after: doc.sequence)
        try await store.reReadAfterExternalChange(doc)
        XCTAssertFalse(doc.displayText.contains(sentence), "premise: a stranger's lines are held")
        await doc.autosaveScheduler.flush()
        XCTAssertFalse(try md().contains(sentence), "premise: nothing applied, nothing rendered")

        _ = try await store.admit(
            device: stranger.fingerprint, label: "Sam", ownName: "Sam’s Mac")
        XCTAssertTrue(doc.displayText.contains(sentence), "the admission applied her lines")

        await doc.autosaveScheduler.flush()
        XCTAssertTrue(try md().contains(sentence), "and the render on disk follows")
        XCTAssertEqual(try md(), render(of: doc))
        await doc.close()
    }

    /// **The converse: a re-read the echo guard absorbs writes nothing.**
    /// This Mac's own append reaches the same re-read (the presenter fires on
    /// our own writes); nothing is applied, so nothing is scheduled.
    func test_anEchoedReReadWritesNothing() async throws {
        let (store, doc) = try await openTheRootsWindow()
        let before = try stamp()
        let appliedBefore = doc.externalChangesApplied

        try await store.reReadAfterExternalChange(doc)
        XCTAssertEqual(doc.externalChangesApplied, appliedBefore, "premise: an echo")
        await doc.autosaveScheduler.flush()

        XCTAssertEqual(try stamp(), before, "the .md was not written")
        await doc.close()
    }

    /// **The re-render's own write is not a loop** (hazard b). The `.md`
    /// write comes back to this window as the presenter's `.otherProjectFile`
    /// callback — `handleExternalDiskChange`, which itself schedules and
    /// flushes an autosave when it does not recognise the bytes. The echo
    /// guard (`lastDiskEcho = .afterWrite(bytes:)`) absorbs it: over a settle
    /// window twice the debounce, the file is written no more.
    func test_theReRendersOwnWriteDoesNotComeBackAsAnotherWrite() async throws {
        let (store, doc) = try await openTheRootsWindow()
        let sentence = "A sentence that arrives and is rendered once."
        try await writes(sentence, as: stranger, state: strangerState, after: doc.sequence)
        _ = try await store.admit(
            device: stranger.fingerprint, label: "Sam", ownName: "Sam’s Mac")
        await doc.autosaveScheduler.flush()
        XCTAssertTrue(try md().contains(sentence), "premise: the re-render wrote")
        let written = try stamp()
        let backups = conflictBackups().count

        // What the presenter delivers for that write, both arms of it.
        store.presenterDidChangeSubitem(at: docURL)
        store.presenterDidChangeSubitem(
            at: OpLogStore.opLogFileURLs(forDocId: "doc-test", in: projectURL)[0])
        var samples: [[String]] = []
        let deadline = Date().addingTimeInterval(1.6)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
            samples.append(try stamp())
        }
        await doc.autosaveScheduler.flush()
        samples.append(try stamp())

        XCTAssertTrue(samples.allSatisfy { $0 == written },
                      "the .md was written again during the settle window: \(samples)")
        XCTAssertEqual(conflictBackups().count, backups,
                       "and no 'discarded' backup was taken of our own render")
        await doc.close()
    }

    /// **A view that is holding lines does not re-render on its own
    /// account.** Another admitted Mac's applied checkpoint is a re-read past
    /// the echo guard, but a stranger's sentence is still held here — so this
    /// Mac's render lacks words the `.md` (written by the Mac that owns them)
    /// carries, and writing it would blank them.
    func test_anAppliedReReadOverHeldLinesLeavesTheMdAlone() async throws {
        let (store, doc) = try await openTheRootsWindow()
        let colleague = DeviceIdentity.softwareForTesting()
        let colleagueState = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("colleague-state.json"))
        _ = try await store.admit(
            device: colleague.fingerprint, label: "Kit", ownName: "Kit’s Mac")
        let sentence = "Words only the stranger’s Mac can render."
        try await writes(sentence, as: stranger, state: strangerState, after: doc.sequence)
        // The stranger's Mac rendered them — the `.md` iCloud carries.
        try Data((doc.displayText + "\n\n" + sentence + "\n").utf8).write(to: docURL)
        let carried = try md()
        try await checkpoints(as: colleague, state: colleagueState)
        let appliedBefore = doc.externalChangesApplied

        try await store.reReadAfterExternalChange(doc)
        XCTAssertGreaterThan(doc.externalChangesApplied, appliedBefore,
                             "premise: the checkpoint was applied")
        XCTAssertEqual(doc.provenance?.hasPendingHistory, true, "premise: her lines are held")
        await doc.autosaveScheduler.flush()

        XCTAssertEqual(try md(), carried, "the held words stay in the .md")
        await doc.close()
    }

    // MARK: - Review Focus 3: a reviewer's Mac and a narrowed author's

    /// After an admission elsewhere, a reviewer's Mac — and an author of the
    /// piece narrowed to it — re-render without an error, a refusal, or a new
    /// op in any stream. The render is not a text write (`performAutosave`'s
    /// own comment), so a Mac that may not write the piece's words still
    /// renders the words the book holds.
    func test_aReviewersMacReRendersAfterAnAdmissionWithoutAnOp() async throws {
        try await reRendersAfterAnAdmissionElsewhere(as: .reviewer)
    }

    func test_aNarrowedAuthorsMacReRendersAfterAnAdmissionWithoutAnOp() async throws {
        try await reRendersAfterAnAdmissionElsewhere(
            as: .author(.pieces([PostureFixture.docId])))
    }

    private func reRendersAfterAnAdmissionElsewhere(as permit: Permit) async throws {
        let fixture = try PostureFixture()
        defer { fixture.tearDown() }
        fixture.beASigningMac()
        try fixture.makeForeignRoot()
        // Bootstrapped while this Mac was still a book author, then narrowed.
        let first = try await Document.load(
            url: fixture.docURL, actor: .author, session: "s", presenter: nil)
        await first.close()
        try await fixture.changeMyPermit(to: permit, store: nil)
        let store = try await DocumentStore.open(url: fixture.projectURL)
        let doc = try await Document.load(
            url: fixture.docURL, actor: .author, session: "s2", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
        store.register(document: doc, for: PostureFixture.docPath)
        await store.postureSettled()

        // A third Mac writes; the root has not admitted it yet.
        let kit = DeviceIdentity.softwareForTesting()
        let sentence = "Kit’s sentence, admitted on the root’s Mac."
        let kitStore = OpLogStore(
            projectURL: fixture.projectURL, identity: kit,
            state: OpLogDeviceState(
                fileURL: fixture.projectURL.appendingPathComponent("kit-state.json")))
        let added = ParagraphID.mintUnique(excluding: Set(doc.sequence))
        try await kitStore.append(Op(
            opId: ULID.generate(), docId: PostureFixture.docId, at: Date(),
            device: kit.deviceId, session: "kit", kind: .typingBurst,
            changes: [.init(paragraphId: added, prior: nil, next: sentence)],
            sequence: doc.sequence + [added]))
        _ = try await kitStore.sealChain(docId: PostureFixture.docId)
        try await store.reReadAfterExternalChange(doc)
        await doc.autosaveScheduler.flush()
        XCTAssertFalse(try String(contentsOf: fixture.docURL, encoding: .utf8)  // adr-0018-ok: test reads the derived render
            .contains(sentence), "premise: held until the root admits Kit")
        let opsBefore = try fixture.opLineCount()

        // The root admits Kit on its own Mac; the record syncs in.
        let root = try XCTUnwrap(fixture.root)
        _ = try RegistryAdmission.admit(
            device: kit.fingerprint, label: "Kit", ownName: "Kit’s Mac",
            in: fixture.projectURL, by: root,
            cache: RegistryCache(
                fileURL: fixture.projectURL.appendingPathComponent("root-cache.json"),
                identity: root.fingerprint),
            memory: AdmissionMemory(
                fileURL: fixture.projectURL.appendingPathComponent("root-memory.json"),
                identity: root.fingerprint))
        store.presenterDidChangeSubitem(at: RegistryWriter.url(
            .people, fingerprint: kit.fingerprint, in: fixture.projectURL))
        await store.flushRegistryChangeForTesting()
        await store.postureSettled()
        XCTAssertTrue(doc.displayText.contains(sentence), "premise: the admission applied it here")

        await doc.autosaveScheduler.flush()
        let written = try String(contentsOf: fixture.docURL, encoding: .utf8)  // adr-0018-ok: test reads the derived render
        XCTAssertTrue(written.contains(sentence), "the render follows on \(permit)")
        XCTAssertEqual(written, MarkdownDisplayFilter.stripAnchors(doc.materialize()))
        // No error: the render path itself, asked directly, does not throw.
        try await doc.performAutosave()
        XCTAssertEqual(try fixture.opLineCount(), opsBefore, "no new op in any stream")
        await doc.close()
    }

    // MARK: - A closed document

    /// **A trust change over a closed piece, then open: the `.md` equals the
    /// render after the debounce** — and the "diverged" backup it already took
    /// is still taken, as evidence.
    func test_aClosedPieceReRendersAtItsNextOpen() async throws {
        let (store, doc) = try await openTheRootsWindow()
        await doc.close()
        store.unregister(path: Self.docPath)
        let sentence = "Admitted while the piece was closed."
        try await writes(sentence, as: stranger, state: strangerState, after: doc.sequence)
        _ = try await store.admit(
            device: stranger.fingerprint, label: "Sam", ownName: "Sam’s Mac")
        XCTAssertFalse(try md().contains(sentence), "premise: nothing was open to render it")
        let backups = conflictBackups().count

        let reopened = try await load()
        XCTAssertTrue(reopened.displayText.contains(sentence))
        XCTAssertEqual(conflictBackups().count, backups + 1, "the diverged backup stays")
        await reopened.autosaveScheduler.flush()

        XCTAssertEqual(try md(), render(of: reopened), "the .md is the render")
        await reopened.close()
    }

    /// **The converse: a load whose `.md` already equals the render schedules
    /// nothing.**
    func test_aLoadWithAnEqualMdSchedulesNothing() async throws {
        let (store, doc) = try await openTheRootsWindow()
        await doc.close()
        store.unregister(path: Self.docPath)
        let before = try stamp()

        let reopened = try await load()
        await reopened.autosaveScheduler.flush()

        XCTAssertEqual(try stamp(), before, "the .md was not written")
        await reopened.close()
    }

    /// **And a load that is HOLDING lines schedules nothing, diverged or
    /// not** — the backup is still taken, and the words the other Mac
    /// rendered stay in the `.md`.
    func test_aLoadHoldingLinesKeepsTheCarriedMd() async throws {
        let (store, doc) = try await openTheRootsWindow()
        await doc.close()
        store.unregister(path: Self.docPath)
        let sentence = "The stranger’s words, rendered on the stranger’s Mac."
        try await writes(sentence, as: stranger, state: strangerState, after: doc.sequence)
        try Data((doc.displayText + "\n\n" + sentence + "\n").utf8).write(to: docURL)
        let carried = try md()
        let backups = conflictBackups().count

        let reopened = try await load()
        XCTAssertFalse(reopened.displayText.contains(sentence), "premise: held here")
        XCTAssertEqual(conflictBackups().count, backups + 1, "the backup is still taken")
        await reopened.autosaveScheduler.flush()

        XCTAssertEqual(try md(), carried, "the carried words stay in the .md")
        await reopened.close()
    }
}
