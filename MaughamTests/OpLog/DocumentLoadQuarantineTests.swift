// MaughamTests/OpLog/DocumentLoadQuarantineTests.swift
import XCTest
@testable import MaughamCore
@testable import Maugham

/// Wiring regression for audit finding 0.6 / Sweep 6: `IntegrityQuarantine` was
/// built + unit-tested but only invoked from `ProjectIntegrity.check` (the
/// backup gate) — NOT the everyday `Document.load` path. So a torn/corrupt
/// op-log line (crash mid-`append` → truncated final line) was silently dropped
/// on every normal open, with no forensic record.
///
/// After the fix, `Document.load` reads via `OpLogStore.loadDiagnosed` and, when
/// any line failed to decode, writes a forensic record to
/// `.maugham/conflicts/quarantine/<docId>.<stamp>.jsonl` — while still loading
/// the valid ops. Quarantining is best-effort forensics, never a load gate.
@MainActor
final class DocumentLoadQuarantineTests: XCTestCase {

    /// Plant a torn final line in the doc's per-device op-log file (no trailing
    /// newline, JSON truncated mid-object), reopen the Document, and assert:
    ///   (a) the document still loads its valid ops (manuscript intact), and
    ///   (b) a quarantine file is written under .maugham/conflicts/quarantine/.
    func test_load_tornOpLogLine_writesQuarantineRecord_andStillLoads() async throws {
        let (project, docURL) = try makeTestProject(prefix: "DOCQUAR", initialMd: "Hello.\n")

        // First open: bootstraps anchors and creates the per-device op-log file.
        let doc1 = try await Document.load(
            url: docURL, device: "m", session: "s", presenter: nil)
        XCTAssertTrue(doc1.displayText.contains("Hello."))
        await doc1.close()

        let docId = doc1.docId
        let slug = DeviceSlug.make(from: "m")
        let opLogURL = OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: slug, in: project)
        XCTAssertTrue(FileManager.default.fileExists(atPath: opLogURL.path),
                      "precondition: per-device op-log file exists after first open")

        // Append a torn final line: a real op JSON with its tail chopped and no
        // trailing newline — exactly a crash mid-append.
        //
        // "Exactly" now has to include the chain (signed op log P1). A crash
        // mid-`append` leaves a line that is already CHAINED — `prev` is the
        // first key the format writes, so a truncated line still names its
        // head — and leaves the head that line would have hashed to already
        // REMEMBERED, because `chainedAppend` remembers before it writes,
        // which is what makes this crash recoverable. A torn line that skipped
        // either step is a line this device did not write, and the reader sets
        // it aside instead: a different event, with a `.lines` record under
        // `quarantined-ops/` rather than this one.
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        enc.outputFormatting = [.sortedKeys]
        let tornOp = Op(
            opId: ULID.generate(), docId: docId, at: Date(),
            device: "m", session: "s", kind: .typingBurst,
            changes: [.init(paragraphId: ParagraphID.mint(), prior: nil, next: "torn")])
        let head = OpLogChain.lineHash(Data(
            try Data(contentsOf: opLogURL)
                .split(separator: 0x0A, omittingEmptySubsequences: true).last!))
        let full = OpLogChain.chainedLine(
            elementJSON: try enc.encode(tornOp), prev: head)
        let torn = full.prefix(full.count - 10)
        OpLogDeviceState.shared.remember(
            head: OpLogChain.lineHash(full),
            for: OpLogDeviceState.fileKey(opLogURL))
        let handle = try FileHandle(forWritingTo: opLogURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(torn))
        try handle.close()

        // Reopen: the torn line must be quarantined, not silently dropped.
        let doc2 = try await Document.load(
            url: docURL, device: "m", session: "s", presenter: nil)

        // (a) Valid manuscript still loads.
        XCTAssertTrue(doc2.displayText.contains("Hello."),
                      "valid ops must still load despite the torn line")
        await doc2.close()

        // (b) A quarantine file was written for the dropped line.
        let quarantineDir = project
            .appendingPathComponent(".maugham/conflicts/quarantine", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            atPath: quarantineDir.path)) ?? []
        let matching = entries.filter {
            $0.hasPrefix("\(docId).") && $0.hasSuffix(".jsonl")
        }
        XCTAssertFalse(
            matching.isEmpty,
            "load() must write a forensic quarantine record for the torn op-log "
            + "line under .maugham/conflicts/quarantine/<docId>.<stamp>.jsonl — "
            + "it was silently dropped before the fix.")

        // The quarantine file body should carry the docId + the raw torn line.
        if let first = matching.first {
            let body = (try? String(
                contentsOf: quarantineDir.appendingPathComponent(first),
                encoding: .utf8)) ?? ""
            XCTAssertTrue(body.contains(docId),
                          "quarantine record should reference the docId")
        }
    }

    /// A clean op-log must NOT produce any quarantine file on load.
    func test_load_cleanOpLog_writesNoQuarantine() async throws {
        let (project, docURL) = try makeTestProject(prefix: "DOCQUAR", initialMd: "Clean.\n")

        let doc = try await Document.load(
            url: docURL, device: "m", session: "s", presenter: nil)
        await doc.close()

        let quarantineDir = project
            .appendingPathComponent(".maugham/conflicts/quarantine", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            atPath: quarantineDir.path)) ?? []
        XCTAssertTrue(entries.isEmpty,
                      "a clean load must not write any quarantine record")
    }
    // MARK: - RULING-54: the document REFUSES rather than opening shorter

    /// An unreadable-yet-present device op-log file refuses the whole load:
    /// before this fix the file read as EMPTY with no diagnostics, the doc
    /// opened SHORTER, and the writer's next autosave truncated the `.md` to
    /// match — with the file's paragraphs superseded by the new sequence
    /// keyframe when it came back. Pinned: the load throws, and the error
    /// names the file.
    func test_load_unreadableDeviceFile_refusesWithTheFileNamed() async throws {
        let (project, docURL) = try makeTestProject(prefix: "DOCUNRD", initialMd: "Hello.\n")
        let doc1 = try await Document.load(
            url: docURL, device: "m", session: "s", presenter: nil)
        let docId = doc1.docId
        await doc1.close()

        // A second device's file, present but unreadable (a directory squats
        // on its path — the permissions/iCloud-stub failure shape).
        let other = OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: DeviceSlug.unsafeForTesting("phone"), in: project)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

        do {
            let doc = try await Document.load(
                url: docURL, device: "m", session: "s", presenter: nil)
            await doc.close()
            XCTFail("the load must refuse — opening shorter is the forbidden shape")
        } catch {
            XCTAssertTrue(String(describing: error.localizedDescription)
                            .contains(other.lastPathComponent),
                          "the refusal names the file — found: \(error.localizedDescription)")
        }
    }

    /// The directory half: an ops directory that exists but cannot be listed
    /// refuses the load — falling through read as "no log yet" and sent
    /// Bootstrap minting FRESH paragraph ids, a second parallel history over
    /// the writer's intact one.
    func test_load_unlistableOpsDirectory_refusesRatherThanRebootstrapping() async throws {
        let (project, docURL) = try makeTestProject(prefix: "DOCDIR", initialMd: "Hello.\n")
        let doc1 = try await Document.load(
            url: docURL, device: "m", session: "s", presenter: nil)
        await doc1.close()

        let opsDir = project.appendingPathComponent(".maugham/ops")
        let saved = try FileManager.default.attributesOfItem(atPath: opsDir.path)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: opsDir.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: saved[.posixPermissions] ?? 0o755],
                ofItemAtPath: opsDir.path)
        }

        do {
            let doc = try await Document.load(
                url: docURL, device: "m", session: "s", presenter: nil)
            await doc.close()
            XCTFail("the load must refuse — re-bootstrapping mints a parallel history")
        } catch {
            XCTAssertTrue(error.localizedDescription.lowercased().contains("history folder")
                            || error.localizedDescription.contains(".maugham/ops"),
                          "the refusal names the folder — found: \(error.localizedDescription)")
        }
    }

    /// RULING-54's pending-buffer half: a pending file that exists but can't
    /// be decoded holds un-bursted keystrokes from a crashed session. The doc
    /// still loads (every SAVED word is intact — a notice, not a refusal),
    /// the bytes are quarantined BEFORE the next autosave overwrites the only
    /// copy, and the failure is STAMPED on the Document for the first
    /// window-bound surface to post — load itself must not post, because a
    /// windowless post is dropped by the receive helpers' liveness guard
    /// (isLive(nil) == false) and a clean close then deletes the trigger.
    /// EditorHost's consume-and-post wiring is pinned by the census below.
    func test_load_unrecoverablePendingFile_quarantinesAndStampsTheDoc_stillLoads() async throws {
        let (project, docURL) = try makeTestProject(prefix: "DOCPEND", initialMd: "Hello.\n")
        let doc1 = try await Document.load(
            url: docURL, device: "m", session: "s", presenter: nil)
        let docId = doc1.docId
        await doc1.close()

        // A crashed session's torn pending state: present, undecodable.
        let pendingURL = project
            .appendingPathComponent(".maugham/pending")
            .appendingPathComponent("\(docId).\(DeviceSlug.make(from: "m").raw).pending.jsonl")
        try FileManager.default.createDirectory(
            at: pendingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "NOT JSON — torn pending state".write(
            to: pendingURL, atomically: true, encoding: .utf8)

        let doc = try await Document.load(
            url: docURL, device: "m", session: "s", presenter: nil)
        XCTAssertTrue(doc.displayText.contains("Hello."), "the manuscript still opens")

        let quarantineDir = project
            .appendingPathComponent(".maugham/conflicts/quarantine", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            atPath: quarantineDir.path)) ?? []
        XCTAssertFalse(entries.isEmpty, "the torn pending bytes are preserved")
        let recorded = try String(
            contentsOf: quarantineDir.appendingPathComponent(entries.sorted()[0]),
            encoding: .utf8)
        XCTAssertTrue(recorded.contains("NOT JSON"),
                      "the record carries the raw bytes, the only copy that survives the next autosave")

        let failure = try XCTUnwrap(doc.unrecoveredPendingFailure,
                                    "the failure is stamped for the window-bound surface")
        XCTAssertEqual(failure.name, pendingURL.lastPathComponent, "the file is named")
        XCTAssertFalse(failure.reason.isEmpty)

        // Consume-once: the first surface takes it, a second cannot re-post.
        XCTAssertNotNil(doc.consumePendingRecoveryFailure())
        XCTAssertNil(doc.consumePendingRecoveryFailure())
        XCTAssertNil(doc.unrecoveredPendingFailure)
        await doc.close()
    }

    // MARK: - Signed op log P1: a correctly-chained line this Mac did not write

    /// The milestone's own scenario, end to end, through the real doors.
    ///
    /// The agent here is the STRONGEST one P1 defends against: not a torn line
    /// and not a clumsy edit, but something that read the file, computed the
    /// next `prev` correctly, and appended a well-formed `typing_burst` for a
    /// paragraph of its own. The chain alone cannot refuse it — it chains. What
    /// refuses it is the head this Mac REMEMBERS: the last line it wrote is in
    /// the file, so everything after that line arrived from somewhere else.
    ///
    /// What must be true afterwards, and each is a different failure if it is
    /// not: the paragraph is not in the document (it was never applied), the
    /// `.md` never carries its words (a derived render of ops that exclude it),
    /// the bytes are kept (`.lines` record, in the writer's own words), the
    /// document can SAY what happened (`provenance.quarantinedLines`), and the
    /// next real burst rewrites the tail without it and chains on — one record
    /// still, because the same bytes are already on file.
    func test_load_correctlyChainedForeignLine_isNeverApplied_andIsKept() async throws {
        let (project, docURL) = try makeTestProject(
            prefix: "DOCFOREIGN", initialMd: "Hello.\n")

        // Type through the real path, so the tail is this Mac's own chained
        // history rather than a fixture: bootstrap line, burst, close seal.
        let doc1 = try await Document.load(
            url: docURL, device: "m", session: "s", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
        let docId = doc1.docId
        doc1.setParagraph(id: doc1.sequence[0], text: "Hello, and then some.")
        try await doc1.flushBurstNow()
        let realSequence = doc1.sequence
        await doc1.close()

        let opLogURL = OpLogStore.opLogFileURL(
            forDocId: docId, deviceSlug: DeviceSlug.make(from: "m"), in: project)
        let before = try Data(contentsOf: opLogURL)
            .split(separator: 0x0A, omittingEmptySubsequences: true)
        XCTAssertGreaterThanOrEqual(before.count, 2,
                                    "precondition: at least two chained lines")

        // The stranger's line: a new paragraph, chained onto the real head.
        let foreignText = "A sentence this Mac never wrote."
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        enc.outputFormatting = [.sortedKeys]
        let foreignOp = Op(
            opId: ULID.generate(), docId: docId, at: Date(),
            device: "m", session: "s", kind: .typingBurst,
            changes: [.init(paragraphId: "ab2c", prior: nil, next: foreignText)],
            // The strongest form: an explicit sequence PLACING the paragraph,
            // so nothing downstream can drop it as an orphan. With the
            // classification removed this line is applied and its words are in
            // the writer's draft — which is what the first two assertions
            // below are for.
            sequence: realSequence + ["ab2c"])
        let head = OpLogChain.lineHash(Data(before.last!))
        let foreignLine = OpLogChain.chainedLine(
            elementJSON: try enc.encode(foreignOp), prev: head)
        let handle = try FileHandle(forWritingTo: opLogURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: foreignLine + Data([0x0A]))
        try handle.close()

        // The load.
        let doc2 = try await Document.load(
            url: docURL, device: "m", session: "s", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))

        XCTAssertFalse(doc2.sequence.contains("ab2c"),
                       "a line this Mac did not write is never APPLIED")
        XCTAssertFalse(doc2.displayText.contains(foreignText),
                       "and its words never reach the writer's draft")
        XCTAssertTrue(doc2.displayText.contains("Hello, and then some."),
                      "the writer's own history still loads whole")

        let provenance = try XCTUnwrap(
            doc2.provenance, "the load stamps what it found on the Document")
        XCTAssertEqual(provenance.quarantinedLines, 1,
                       "one line refused — the surfaces read this, not the files")

        let records = OpLogQuarantine.records(forDocId: docId, in: project)
            .filter { $0.kind == .lines }
        XCTAssertEqual(records.count, 1, "the bytes are kept, once")
        XCTAssertEqual(records[0].reason, "written by something that is not Maugham",
                       "the record says why in the writer's own words")
        let keptURL = OpLogQuarantine.quarantinedFileURL(
            for: records[0], in: project)
        XCTAssertTrue(
            (try String(contentsOf: keptURL, encoding: .utf8)).contains(foreignText),
            "the archive holds the refused line verbatim")

        // The next real burst: the tail is rewritten without the stranger's
        // line, and this Mac's new line chains onto its own head again.
        doc2.setParagraph(id: doc2.sequence[0], text: "Hello, and then more.")
        try await doc2.flushBurstNow()
        try await doc2.performAutosave()

        let tail = try String(contentsOf: opLogURL, encoding: .utf8)
        XCTAssertFalse(tail.contains(foreignText),
                       "the append rewrote the tail without the refused line")
        XCTAssertTrue(tail.contains("Hello, and then more."),
                      "and carried on chaining this Mac's own history")
        XCTAssertEqual(
            OpLogQuarantine.records(forDocId: docId, in: project)
                .filter { $0.kind == .lines }.count, 1,
            "still one record — the same bytes are already on file")

        let onDisk = try String(contentsOf: docURL, encoding: .utf8)
        XCTAssertFalse(onDisk.contains(foreignText),
                       "the .md is derived from the ops that were applied")
        await doc2.close()
    }

    /// The other half of the same rule, and the reason it is safe to ship: a
    /// project written before any of this existed — an unsuffixed file whose
    /// lines carry no `prev` — loads WHOLE, with nothing set aside and nothing
    /// to apologise for. `hasLegacyHistory` is how the writer is told, and it
    /// stays true forever: the past cannot be signed retroactively.
    ///
    /// And the first burst after it chains onto the last legacy line's hash,
    /// so the history is continuous across the milestone rather than restarted.
    func test_load_legacyProject_loadsWhole_andTheFirstBurstChainsOntoIt() async throws {
        let (project, docURL) = try makeTestProject(
            prefix: "DOCLEGACY", initialMd: "Legacy.\n")

        // A pre-milestone log: the unsuffixed filename, unchained lines.
        let docId = try resolveDocId(for: docURL)
        let legacyURL = project
            .appendingPathComponent(".maugham/ops/\(docId).jsonl")
        try FileManager.default.createDirectory(
            at: legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        enc.outputFormatting = [.sortedKeys]
        let legacyOps = [
            Op(opId: "01AAAAAAAAAAAAAAAAAAAAAAAA", docId: docId,
               at: Date(timeIntervalSince1970: 100), device: "old", session: "s",
               kind: .typingBurst,
               changes: [.init(paragraphId: "aa2c", prior: nil, next: "Legacy.")],
               sequence: ["aa2c"]),
            Op(opId: "01BAAAAAAAAAAAAAAAAAAAAAAA", docId: docId,
               at: Date(timeIntervalSince1970: 200), device: "old", session: "s",
               kind: .typingBurst,
               changes: [.init(paragraphId: "aa2c", prior: "Legacy.", next: "Legacy history.")]),
        ]
        var body = Data()
        for op in legacyOps { body.append(try enc.encode(op)); body.append(0x0A) }
        try body.write(to: legacyURL)

        let doc = try await Document.load(
            url: docURL, device: "m", session: "s", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
        XCTAssertTrue(doc.displayText.contains("Legacy history."),
                      "a pre-milestone history loads whole")

        let provenance = try XCTUnwrap(doc.provenance)
        XCTAssertTrue(provenance.hasLegacyHistory,
                      "the writer is told their history predates the signature")
        XCTAssertEqual(provenance.quarantinedLines, 0, "nothing is refused")
        XCTAssertFalse(provenance.hasUnsignedForeignHistory,
                       "legacy is legacy — never reported as another device's")
        XCTAssertEqual(
            OpLogQuarantine.records(forDocId: docId, in: project)
                .filter { $0.kind == .lines }.count, 0)

        // The first burst goes into THIS device's own file, whose chain starts
        // at genesis; the legacy file is frozen (ADR 0012) and is never
        // appended to or rewritten.
        doc.setParagraph(id: doc.sequence[0], text: "Legacy history, continued.")
        try await doc.flushBurstNow()
        await doc.close()

        XCTAssertEqual(
            try Data(contentsOf: legacyURL), body,
            "the legacy file is frozen — never rewritten, never sealed")
        let reloaded = try await Document.load(
            url: docURL, device: "m", session: "s", presenter: nil,
            burstIdle: .seconds(3600), burstMax: .seconds(3600))
        XCTAssertTrue(reloaded.displayText.contains("Legacy history, continued."))
        XCTAssertEqual(try XCTUnwrap(reloaded.provenance).quarantinedLines, 0,
                       "the chained continuation is not mistaken for a stranger")
        await reloaded.close()
    }

    /// The delivery wiring census: EditorHost must consume the stamp and must
    /// carry BOTH triggers — after the load completes AND when the window
    /// resolves — because either can happen first (the BinderRow.claimFocus
    /// double-trigger shape). A mounted pin would need a full window fixture;
    /// the census catches the two regressions that matter: the consume call
    /// disappearing, and the window trigger disappearing.
    func test_editorHostDeliversTheStampedNotice_census() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Maugham/Views/EditorHost.swift"),
            encoding: .utf8)
        XCTAssertTrue(source.contains("consumePendingRecoveryFailure()"),
                      "EditorHost consumes the stamped failure")
        XCTAssertTrue(source.contains(".onChange(of: window) { _, _ in deliverPendingRecoveryNoticeIfPossible() }"),
                      "the window-resolution trigger exists — a load can finish before WindowAccessor resolves")
        XCTAssertTrue(source.contains("deliverPendingRecoveryNoticeIfPossible()\n"),
                      "the load-completion trigger exists")
    }

}
