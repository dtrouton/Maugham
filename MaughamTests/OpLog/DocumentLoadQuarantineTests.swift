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
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        enc.outputFormatting = [.sortedKeys]
        let tornOp = Op(
            opId: ULID.generate(), docId: docId, at: Date(),
            device: "m", session: "s", kind: .typingBurst,
            changes: [.init(paragraphId: ParagraphID.mint(), prior: nil, next: "torn")])
        let full = try enc.encode(tornOp)
        let torn = full.prefix(full.count - 10)
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
