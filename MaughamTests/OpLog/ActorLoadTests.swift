import XCTest
@testable import Maugham
@testable import MaughamCore

/// Signed op log P1b Task 3 — `Document.load` names its actor.
///
/// A device is four writers (`DeviceActor`), and until this task three of them
/// wrote under a hand-built sentinel: `"mcp"` for everything arriving through
/// MCP, `"rebalance"` for the app's own task-priority pass. A sentinel names no
/// key, so `OpLogStore.append` took the plain unchained path for all of it —
/// Claude's annotations and Maugham's own maintenance were the two things in
/// the log that nothing could vouch for.
///
/// These tests pin the two ends of that: an MCP write lands in the ASSISTANT's
/// own file under the ASSISTANT's key, and the rebalance lands in MAUGHAM's,
/// while the archive-undo guard that used to recognise the rebalance by its
/// device string still recognises it by its SESSION marker.
@MainActor
final class ActorLoadTests: XCTestCase {

    private var projectURL: URL!
    private var identities: LocalIdentities!

    override func setUp() async throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("actorload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        // Four software signers, so a seal is assertable on a machine with no
        // Secure Enclave (CI's VM), and a chain memory of this project's own so
        // one test's remembered heads never reach another's.
        identities = LocalIdentities.softwareForTesting()
        Document.localIdentitiesForTesting = identities
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: projectURL.appendingPathComponent("op-log-state.json"))
    }

    override func tearDown() async throws {
        // Process-wide: a leak would silently change what every later test's
        // load can vouch for.
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        try? FileManager.default.removeItem(at: projectURL)
    }

    // MARK: - Fixture

    private static let docId = "doc-actor-test"
    private static let docPath = "manuscript/c1.md"

    @discardableResult
    private func makeProject(body: String = "First paragraph.\n\nSecond paragraph.\n") throws -> URL {
        let docURL = projectURL.appendingPathComponent(Self.docPath)
        try body.write(to: docURL, atomically: true, encoding: .utf8)
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

    private func fileURL(for identity: DeviceIdentity) -> URL {
        OpLogStore.opLogFileURL(
            forDocId: Self.docId, deviceSlug: identity.slug, in: projectURL)
    }

    private func lines(of identity: DeviceIdentity) throws -> [Data] {
        try Data(contentsOf: fileURL(for: identity))
            .split(separator: UInt8(0x0A), omittingEmptySubsequences: true)
            .map { Data($0) }
    }

    private func ops(of identity: DeviceIdentity) throws -> [Op] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = JSONLAppendStore<Op>.dateDecoding
        return try lines(of: identity).compactMap { line in
            OpLogChain.isSealLine(line) ? nil : try? dec.decode(Op.self, from: line)
        }
    }

    // MARK: - The assistant signs what arrives through MCP

    /// An `add_comment` on a CLOSED document takes `withAnnotationDocument`'s
    /// transient-load branch, which is the load this task renamed. Its op must
    /// land in the assistant's own per-device file, chained, and seal under the
    /// assistant's key — not the author's, and not in a sentinel file nobody
    /// can sign.
    func test_anMCPCommentLandsInTheAssistantsFileAndSealsUnderTheAssistantsKey() async throws {
        let docURL = try makeProject()

        // The writer's own load bootstraps the anchors, then closes: the doc is
        // NOT registered anywhere, so the MCP tool must transient-load it.
        let authored = try await Document.load(
            url: docURL, actor: .author, session: "s", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
        let log = try await authored.opLog()
        let pid = try XCTUnwrap(
            log.first(where: { $0.kind == .bootstrap })?.changes.first?.paragraphId)
        await authored.close()

        let store = try await ProjectStore.load(from: projectURL)
        let registry = ProjectRegistry()
        registry.register(url: projectURL, store: store)

        let params: [String: Any] = [
            "project_id": ProjectIdentifier.id(for: projectURL),
            "document_id": Self.docId,
            "paragraph_id": pid,
            "body": "consider showing not telling",
        ]
        let resultData = try await AddCommentTool.handle(
            paramsJSON: try JSONSerialization.data(withJSONObject: params),
            registry: registry)
        let result = try JSONDecoder().decode(
            AddCommentTool.Result.self, from: resultData)

        // The op is in the ASSISTANT's file, carrying the assistant's id.
        let assistantOps = try ops(of: identities.assistant)
        let comment = try XCTUnwrap(
            assistantOps.first { $0.opId == result.annotation_id },
            "the MCP comment must land in the assistant's own per-device file")
        XCTAssertEqual(comment.kind, .claudeComment)
        XCTAssertEqual(comment.device, identities.assistant.deviceId,
                       "an op signs as the actor that wrote it")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: OpLogStore.opLogFileURL(
                    forDocId: Self.docId,
                    deviceSlug: DeviceSlug.make(from: "mcp"),
                    in: projectURL).path),
            "no sentinel file: 'mcp' names no key and must not be a device any more")

        // The open-time sweep is production's seal trigger, and it seals every
        // local actor's file — including the one only Claude has written to.
        let documentStore = try await DocumentStore.open(url: projectURL)
        let seal = try XCTUnwrap(
            OpLogChain.Seal.parse(try XCTUnwrap(lines(of: identities.assistant).last)),
            "the assistant's tail ends on a seal")
        XCTAssertTrue(seal.verifies())
        XCTAssertEqual(seal.key, identities.assistant.fingerprint,
                       "signed by the assistant, which is the whole claim")

        // And the writer's next load reads it as this device's own history.
        let reopened = try await Document.load(
            url: docURL, actor: .author, session: "s2", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
        let provenance = try XCTUnwrap(reopened.provenance)
        XCTAssertEqual(provenance.unsignedHistoryLines, 0,
                       "the assistant is this device, not 'another device'")
        XCTAssertGreaterThan(provenance.verifiedLines, 0)
        XCTAssertNil(HistoryPane.unsignedHistoryNotice(provenance: provenance),
                     "and the writer is told nothing, because nothing is wrong")
        await reopened.close()
        await documentStore.close()
    }

    // MARK: - Maugham signs its own maintenance

    /// The task-priority rebalance is the app acting on nobody's instruction.
    /// It used to carry `device: "rebalance"`; it now carries Maugham's own id
    /// and lands, chained and sealed, in Maugham's file — while `session` keeps
    /// the sentinel, which is what every reader of the rebalance now matches on.
    func test_theRebalanceLandsInMaughamsFileSealedUnderMaughamsKey() async throws {
        let docURL = try makeProject(body: """
        - [ ] first task <!--t-aaaaaa-->

        - [ ] second task <!--t-bbbbbb-->
        """)
        let doc = try await Document.load(
            url: docURL, actor: .author, session: "s", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))

        // Converge two siblings' priorities to under the 1e-9 floor: the next
        // derive rewrites the whole group and emits the rebalance ops.
        let first = "inline:\(doc.docId):aaaaaa"
        let second = "inline:\(doc.docId):bbbbbb"
        doc.setTaskPriority(id: first, priority: 1.0)
        doc.setTaskPriority(id: second, priority: 1.0 + 1e-12)
        _ = doc.tasks(filter: .init(
            scope: .document(docId: doc.docId),
            statuses: Set(TaskStatus.allCases)))
        await doc.close()   // drains the detached appends, then seals

        let maughamOps = try ops(of: identities.maugham)
        let rebalance = maughamOps.filter { $0.kind == .taskPriorityChange }
        XCTAssertFalse(rebalance.isEmpty,
                       "the rebalance is Maugham's own act and lands in its file")
        for op in rebalance {
            XCTAssertEqual(op.device, identities.maugham.deviceId)
            XCTAssertEqual(op.session, TaskDeriver.rebalanceSentinel,
                           "the sentinel survives as the SESSION marker")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: OpLogStore.opLogFileURL(
                    forDocId: Self.docId,
                    deviceSlug: DeviceSlug.make(from: TaskDeriver.rebalanceSentinel),
                    in: projectURL).path),
            "and no `rebalance` sentinel file is written any more")

        let seal = try XCTUnwrap(
            OpLogChain.Seal.parse(try XCTUnwrap(lines(of: identities.maugham).last)))
        XCTAssertTrue(seal.verifies())
        XCTAssertEqual(seal.key, identities.maugham.fingerprint)
    }

    // MARK: - The archive undo still recognises the rebalance

    /// The compound archive undo declines when a FOREIGN op advanced the doc
    /// past its capture, and exempts a changes-free rebalance because a text
    /// restore cannot clobber one. That exemption used to be spelled on
    /// `device == rebalanceSentinel`; the rebalance now carries Maugham's real
    /// device id, so an exemption still reading `device` would decline the
    /// writer's own ⌘Z.
    func test_theArchiveUndoStillExemptsTheRebalance() async throws {
        let docURL = try makeProject(body: """
        - [ ] foo <!--t-aaaaaa-->

        Some other prose.
        """)
        let doc = try await Document.load(
            url: docURL, actor: .author, session: "s", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
        let log = try await doc.opLog()
        let pids = try XCTUnwrap(
            log.first(where: { $0.kind == .bootstrap })?.changes.map(\.paragraphId))
        let taskPid = pids[0]
        let inlineId = "inline:\(doc.docId):aaaaaa"

        let um = UndoManager()
        doc.archiveTask(id: inlineId, undoManager: um)
        XCTAssertNil(doc.paragraph(id: taskPid))

        // A rebalance lands in the undo window, wearing Maugham's device id.
        doc._opLogMirror.append(Op(
            opId: ULID.generate(),
            docId: doc.docId, at: Date(),
            device: identities.maugham.deviceId,
            session: TaskDeriver.rebalanceSentinel,
            kind: .taskPriorityChange,
            changes: [], sequence: nil,
            provenance: Op.Provenance(taskId: inlineId, taskPriority: 2.0)))

        um.undo()
        await doc.awaitPendingUndoWork()
        XCTAssertNotNil(doc.paragraph(id: taskPid),
            "the rebalance is exempt: the paragraph comes back")
        XCTAssertEqual(
            doc.tasks(filter: .init(
                scope: .document(docId: doc.docId),
                statuses: Set(TaskStatus.allCases))).first { $0.id == inlineId }?.status,
            .open,
            "and so does the open status — the whole compound undo ran")
        await doc.close()
    }
}
