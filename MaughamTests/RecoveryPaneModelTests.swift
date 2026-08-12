import XCTest
@testable import Maugham

/// Recovery spec §3: the pane's behaviour per cause — stub waits/downloads/
/// auto-opens and NEVER offers read-only; unreadable offers the ladder;
/// the directory case offers restore only.
@MainActor
final class RecoveryPaneModelTests: XCTestCase {
    private let proj = URL(fileURLWithPath: "/tmp/rpm-fixture")
    private let fileURL = URL(fileURLWithPath: "/tmp/rpm-fixture/.maugham/ops/doc-1.phone.jsonl")

    func test_stubCause_downloadsWaitsAndAutoOpens_neverOffersReadOnly() async {
        var downloads = 0
        var openedEditable = 0
        var readable = false
        let model = RecoveryPaneModel(
            cause: .icloudNotDownloaded(fileName: "doc-1.phone.jsonl", fileURL: fileURL),
            projectURL: proj,
            probeInterval: .milliseconds(5),
            blockageCleared: { _ in readable },
            startDownload: { _ in downloads += 1 },
            onOpenEditable: { openedEditable += 1 },
            onOpenReadOnly: { XCTFail("stub path must never open read-only") },
            onSetAside: { XCTFail("stub path must never set the file aside") })

        XCTAssertFalse(model.offersReadOnly, "spec §3: the stub path never offers the partial view")
        XCTAssertFalse(
            model.offersSetAside,
            "the stub rule (spec §5): a not-yet-downloaded file is not broken, "
            + "it is in transit — moving it out from under the download this "
            + "very pane started is how you turn a wait into a loss. "
            + "`OpLogQuarantine.quarantine` refuses it too; this is the offer "
            + "never appearing in the first place")
        XCTAssertTrue(model.offersRestore)
        XCTAssertTrue(model.headline.localizedCaseInsensitiveContains("icloud"))

        model.beginWatching()
        XCTAssertEqual(downloads, 1, "the download is triggered once, up front")
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(openedEditable, 0, "still waiting — not readable yet")
        readable = true
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(openedEditable, 1, "auto-open the moment it reads (ruling: auto from the refusal pane)")
        model.stopWatching()
    }

    func test_unreadableCause_offersTheLadder_andAutoOpensOnReadable() async {
        var openedEditable = 0
        var readable = false
        let model = RecoveryPaneModel(
            cause: .unreadableFile(fileName: "doc-1.phone.jsonl", fileURL: fileURL, reason: "permission denied"),
            projectURL: proj,
            probeInterval: .milliseconds(5),
            blockageCleared: { _ in readable },
            startDownload: { _ in XCTFail("no download for a non-stub cause") },
            onOpenEditable: { openedEditable += 1 },
            onOpenReadOnly: {},
            onSetAside: {})

        XCTAssertTrue(model.offersReadOnly)
        XCTAssertTrue(
            model.offersSetAside,
            "the one cause with a named, broken, downloaded file — the only "
            + "shape there is anything honest to move (spec §5)")
        XCTAssertTrue(model.offersRestore)
        XCTAssertTrue(model.detail.contains("permission denied"), "the reason reaches the writer")
        model.beginWatching()
        readable = true
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(openedEditable, 1, "a fixed permissions break auto-opens from the refusal pane too")
        model.stopWatching()
    }

    /// The production probe, on a real filesystem. Both watchers ask it one
    /// question — *does this path still block the strict load?* — and the two
    /// likeliest MANUAL fixes are the ones an earlier "is it readable"
    /// spelling got backwards: deleting the squatting entry, and the file
    /// being gone. Either left the writer waiting forever on a document that
    /// opens perfectly well.
    func test_theProbeAnswersBlockageCleared_notReadability() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let probe = RecoveryPaneModel.defaultBlockageClearedProbe

        // 1. Absent — the strict load globs the ops directory, so a file that
        //    is gone is one it never sees. CLEARED.
        let absent = dir.appendingPathComponent("gone.jsonl")
        XCTAssertTrue(probe(absent),
                      "an absent file blocks nothing — the glob won't see it")

        // 2. Present and empty — opens, reads EOF. A truthful empty log.
        let empty = dir.appendingPathComponent("empty.jsonl")
        XCTAssertTrue(FileManager.default.createFile(atPath: empty.path, contents: Data()))
        XCTAssertTrue(probe(empty), "zero-length is readable, not a failure")

        // 3. Present with content — the ordinary readable case.
        let full = dir.appendingPathComponent("full.jsonl")
        try Data("{}\n".utf8).write(to: full)
        XCTAssertTrue(probe(full))

        // 4. A DIRECTORY where a file belongs — the squat that refuses the
        //    strict load in the first place. Still blocking.
        let squat = dir.appendingPathComponent("squat.jsonl")
        try FileManager.default.createDirectory(at: squat, withIntermediateDirectories: true)
        XCTAssertFalse(probe(squat), "a directory is exactly what refused the load")

        // 5. Unreadable — the permissions break. Still blocking.
        let locked = dir.appendingPathComponent("locked.jsonl")
        try Data("{}\n".utf8).write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        XCTAssertFalse(probe(locked), "a permissions break is still in the way")
        try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                               ofItemAtPath: locked.path)
    }

    func test_directoryCause_offersRestoreOnly() {
        let model = RecoveryPaneModel(
            cause: .unlistableOpsDirectory(reason: "perm"),
            projectURL: proj, probeInterval: .seconds(1),
            blockageCleared: { _ in false }, startDownload: { _ in },
            onOpenEditable: {}, onOpenReadOnly: {},
            onSetAside: { XCTFail("there is no file named to set aside") })
        XCTAssertFalse(model.offersReadOnly, "nothing enumerable — no partial view (spec §3)")
        XCTAssertFalse(
            model.offersSetAside,
            "the nothing-enumerable rule: the cause names no file, because the "
            + "directory holding them all is what refused. There is no single "
            + "thing to move, and moving the directory would be moving the "
            + "history itself")
        XCTAssertTrue(model.offersRestore)
    }

    /// The set-aside offer is the writer's, so it is said in the writer's
    /// words. "Quarantine" is what the code calls it and what the folder on
    /// disk is named; the button says what the writer gets — their document,
    /// back, with the broken history kept rather than thrown away.
    func test_thePaneSaysSetAside_neverQuarantine() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()      // MaughamTests
                .deletingLastPathComponent()      // repo root
                .appendingPathComponent("Maugham/Views/DocumentRecoveryPane.swift"),
            encoding: .utf8)
        XCTAssertTrue(source.contains("\"Set the File Aside and Keep Writing\""),
                      "the pane's third rung, in the writer's words")
        for line in source.split(separator: "\n") where line.contains("Button(\"") {
            XCTAssertFalse(line.localizedCaseInsensitiveContains("quarantine"),
                           "no button says 'quarantine' at the writer: \(line)")
        }
    }
}
