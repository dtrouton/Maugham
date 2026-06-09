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

    private func makeProject(initialMd: String) throws -> (project: URL, docPath: String) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DOCQUAR-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("manuscript"),
            withIntermediateDirectories: true)
        let docPath = "manuscript/c1.md"
        try initialMd.data(using: .utf8)!.write(
            to: tmp.appendingPathComponent(docPath))
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(),
            structure: [StructureItem(
                id: "doc-test", title: "C1", type: .document, path: docPath)],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: tmp.appendingPathComponent("project.maugham.json"))
        return (tmp, docPath)
    }

    /// Plant a torn final line in the doc's per-device op-log file (no trailing
    /// newline, JSON truncated mid-object), reopen the Document, and assert:
    ///   (a) the document still loads its valid ops (manuscript intact), and
    ///   (b) a quarantine file is written under .maugham/conflicts/quarantine/.
    func test_load_tornOpLogLine_writesQuarantineRecord_andStillLoads() async throws {
        let (project, path) = try makeProject(initialMd: "Hello.\n")
        let docURL = project.appendingPathComponent(path)

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
        let (project, path) = try makeProject(initialMd: "Clean.\n")
        let docURL = project.appendingPathComponent(path)

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
}
