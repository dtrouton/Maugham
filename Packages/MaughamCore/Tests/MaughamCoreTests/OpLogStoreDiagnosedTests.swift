import XCTest
@testable import MaughamCore

/// Covers `OpLogStore.loadDiagnosed(docId:)` — the glob+merge variant that
/// surfaces per-file `ParseDiagnostics` so a torn/corrupt op-log line gets a
/// forensic record instead of vanishing. Tripwire 8: any id crossing the
/// `.md`↔op-log boundary uses the 4-char alphabet / `ParagraphID.mint()`.
@MainActor
final class OpLogStoreDiagnosedTests: XCTestCase {
    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("OLD-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeOp(opId: String) -> Op {
        Op(opId: opId, docId: "doc-1", at: Date(timeIntervalSince1970: 0),
           device: "m", session: "s", kind: .typingBurst,
           changes: [.init(paragraphId: ParagraphID.mint(), prior: nil, next: "x")])
    }

    /// Plant N valid op lines, then a TRUNCATED final line (a valid op JSON with
    /// its tail chopped, no trailing newline — exactly a crash mid-`append`).
    /// `loadDiagnosed` must (a) return exactly the N valid ops, never the torn
    /// one, and (b) report the torn line in `diagnostics.skipped`.
    func test_loadDiagnosed_tornFinalLine_quarantinedAndExcludedFromStream() async throws {
        let store = OpLogStore(projectURL: tmp)
        try await store.append(makeOp(opId: "01HZK01"))
        try await store.append(makeOp(opId: "01HZK02"))

        // Manually append a truncated final line to the per-device file.
        let slug = DeviceSlug.make(from: "m")
        let fileURL = OpLogStore.opLogFileURL(
            forDocId: "doc-1", deviceSlug: slug, in: tmp)
        // Encode a full op line, then chop its last 10 bytes so the JSON is
        // unterminated and cannot decode.
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
        enc.outputFormatting = [.sortedKeys]
        let full = try enc.encode(makeOp(opId: "01HZK03"))
        let torn = full.prefix(full.count - 10)   // no trailing newline either
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(torn))
        try handle.close()

        // Sanity: the torn bytes really don't decode as an Op.
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = JSONLAppendStore<Op>.dateDecoding
        XCTAssertNil(try? dec.decode(Op.self, from: Data(torn)),
                     "test precondition: the truncated line must be undecodable")

        let result = try await store.loadDiagnosed(docId: "doc-1")
        XCTAssertEqual(result.ops.map(\.opId), ["01HZK01", "01HZK02"],
                       "torn line must never enter the op stream")
        XCTAssertEqual(result.diagnostics.skipped.count, 1,
                       "torn line must be reported in diagnostics")

        // And `load` still returns the valid ops (drops diagnostics).
        let loaded = try await store.load(docId: "doc-1")
        XCTAssertEqual(loaded.map(\.opId), ["01HZK01", "01HZK02"])
    }

    /// Diagnostics from MULTIPLE per-device files must merge into one
    /// `ParseDiagnostics`.
    func test_loadDiagnosed_mergesSkippedAcrossPerDeviceFiles() async throws {
        let store = OpLogStore(projectURL: tmp)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent(".maugham/ops"),
            withIntermediateDirectories: true)
        // Two device files, each with one valid op + one garbage line.
        for (device, opId) in [("m", "01HZK01"), ("p", "01HZK02")] {
            let slug = DeviceSlug.make(from: device)
            let fileURL = OpLogStore.opLogFileURL(
                forDocId: "doc-1", deviceSlug: slug, in: tmp)
            let op = Op(opId: opId, docId: "doc-1", at: Date(timeIntervalSince1970: 0),
                        device: device, session: "s", kind: .typingBurst,
                        changes: [.init(paragraphId: ParagraphID.mint(), prior: nil, next: "x")])
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = JSONLAppendStore<Op>.dateEncoding
            enc.outputFormatting = [.sortedKeys]
            let line = String(data: try enc.encode(op), encoding: .utf8)!
            try (line + "\nGARBAGE-\(device)\n").write(to: fileURL, atomically: true, encoding: .utf8)
        }

        let result = try await store.loadDiagnosed(docId: "doc-1")
        XCTAssertEqual(result.ops.map(\.opId), ["01HZK01", "01HZK02"])
        XCTAssertEqual(result.diagnostics.skipped.count, 2,
                       "skipped lines from both device files must merge")
    }

    /// Clean files report no diagnostics.
    func test_loadDiagnosed_cleanFile_reportsNothing() async throws {
        let store = OpLogStore(projectURL: tmp)
        try await store.append(makeOp(opId: "01HZK01"))
        let result = try await store.loadDiagnosed(docId: "doc-1")
        XCTAssertEqual(result.ops.count, 1)
        XCTAssertTrue(result.diagnostics.isClean)
    }
    // MARK: - RULING-54: unreadable is never presented as empty

    /// An UNREADABLE-yet-present device file (a directory squatting on its
    /// path — the same failure shape as a permissions break or an iCloud
    /// dataless stub) must THROW from `loadDiagnosed`, never contribute zero
    /// ops with empty diagnostics: the empty read is how a document opened
    /// SHORTER with no trace, and the writer's next autosave truncated the
    /// `.md` to match.
    func test_loadDiagnosed_unreadableDeviceFile_throws() async throws {
        let store = OpLogStore(projectURL: tmp)
        try await store.append(makeOp(opId: "01AAAAAAAAAAAAAAAAAAAAAAAA"))

        let bad = DeviceSlug.unsafeForTesting("bad")
        let badURL = OpLogStore.opLogFileURL(forDocId: "doc-1", deviceSlug: bad, in: tmp)
        try FileManager.default.createDirectory(at: badURL, withIntermediateDirectories: true)

        do {
            _ = try await store.loadDiagnosed(docId: "doc-1")
            XCTFail("an unreadable device file must throw, not read as empty")
        } catch {}
    }

    /// The same strictness on the sync-merge path — the closed-document read
    /// (`DerivedManuscript`, MCP `read_document`) must not silently derive a
    /// shorter manuscript from an unreadable file.
    func test_loadSyncMerged_unreadableDeviceFile_throws() async throws {
        let store = OpLogStore(projectURL: tmp)
        try await store.append(makeOp(opId: "01AAAAAAAAAAAAAAAAAAAAAAAA"))
        let bad = DeviceSlug.unsafeForTesting("bad")
        let badURL = OpLogStore.opLogFileURL(forDocId: "doc-1", deviceSlug: bad, in: tmp)
        try FileManager.default.createDirectory(at: badURL, withIntermediateDirectories: true)

        do {
            _ = try OpLogStore.loadSyncMerged(forDocId: "doc-1", in: tmp)
            XCTFail("loadSyncMerged must throw on an unreadable file")
        } catch {}
    }

    /// ABSENT stays fine — a document with no op-log files at all is the
    /// legitimate new-document state, not an error.
    func test_loadDiagnosed_absentFiles_returnsEmptyWithoutThrowing() async throws {
        let store = OpLogStore(projectURL: tmp)
        let result = try await store.loadDiagnosed(docId: "doc-none")
        XCTAssertTrue(result.ops.isEmpty)
    }

    // MARK: - the PARTIAL read (recovery spec §4): readable files load,
    // unreadable ones are NAMED — never thrown, never silently dropped.

    /// The read-only rung's substrate: one unreadable device file must not
    /// cost the readable devices' ops, and must be named for the banner.
    func test_loadDiagnosedPartial_unreadableFileIsNamed_readableOpsStillLoad() async throws {
        let store = OpLogStore(projectURL: tmp)
        try await store.append(makeOp(opId: "01AAAAAAAAAAAAAAAAAAAAAAAA"))
        let bad = DeviceSlug.unsafeForTesting("bad")
        let badURL = OpLogStore.opLogFileURL(forDocId: "doc-1", deviceSlug: bad, in: tmp)
        try FileManager.default.createDirectory(at: badURL, withIntermediateDirectories: true)

        let result = await store.loadDiagnosedPartial(docId: "doc-1")

        XCTAssertEqual(result.ops.map(\.opId), ["01AAAAAAAAAAAAAAAAAAAAAAAA"],
                       "the readable device's ops still load")
        XCTAssertEqual(result.unreadableFiles.map(\.name), [badURL.lastPathComponent],
                       "the unreadable file is named for the banner")
        XCTAssertFalse(result.unreadableFiles[0].reason.isEmpty)
    }

    /// With every file readable, partial == diagnosed (same ops, no names).
    func test_loadDiagnosedPartial_cleanFiles_matchesLoadDiagnosed() async throws {
        let store = OpLogStore(projectURL: tmp)
        try await store.append(makeOp(opId: "01AAAAAAAAAAAAAAAAAAAAAAAA"))
        let partial = await store.loadDiagnosedPartial(docId: "doc-1")
        let strict = try await store.loadDiagnosed(docId: "doc-1")
        XCTAssertEqual(partial.ops.map(\.opId), strict.ops.map(\.opId))
        XCTAssertTrue(partial.unreadableFiles.isEmpty)
    }

}
