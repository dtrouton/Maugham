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
            isReadable: { _ in readable },
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
            isReadable: { _ in readable },
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

    func test_directoryCause_offersRestoreOnly() {
        let model = RecoveryPaneModel(
            cause: .unlistableOpsDirectory(reason: "perm"),
            projectURL: proj, probeInterval: .seconds(1),
            isReadable: { _ in false }, startDownload: { _ in },
            onOpenEditable: {}, onOpenReadOnly: {})
        XCTAssertFalse(model.offersReadOnly, "nothing enumerable — no partial view (spec §3)")
        XCTAssertTrue(model.offersRestore)
    }
}
