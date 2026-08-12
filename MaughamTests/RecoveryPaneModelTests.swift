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
            onOpenReadOnly: { XCTFail("stub path must never open read-only") })

        XCTAssertFalse(model.offersReadOnly, "spec §3: the stub path never offers the partial view")
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
            onOpenReadOnly: {})

        XCTAssertTrue(model.offersReadOnly)
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
            onOpenEditable: {}, onOpenReadOnly: {})
        XCTAssertFalse(model.offersReadOnly, "nothing enumerable — no partial view (spec §3)")
        XCTAssertTrue(model.offersRestore)
    }
}
