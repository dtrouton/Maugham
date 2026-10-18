// MaughamTests/Updates/InstallStatusTests.swift
import XCTest
@testable import Maugham

/// #67 Task 5: the next launch reads the swap helper's `install-status` line,
/// removes it, and the update banner says once what the helper couldn't do.
/// Windowless throughout (tripwire 33): the banner is checked through the pure
/// `UpdateBannerView.notice(for:)` it draws from.
@MainActor
final class InstallStatusTests: XCTestCase {

    // MARK: - parse

    func test_parse_readsBothForms() {
        XCTAssertEqual(InstallStatus.parse("refused 0.43.0"), .refused(version: "0.43.0"))
        XCTAssertEqual(InstallStatus.parse("failed 0.43.0 ditto"), .failed(version: "0.43.0", step: "ditto"))
        XCTAssertEqual(InstallStatus.parse("failed 0.43.0 swap"), .failed(version: "0.43.0", step: "swap"))
        XCTAssertEqual(InstallStatus.parse("failed 0.43.0 python3"), .failed(version: "0.43.0", step: "python3"))
    }

    func test_parse_toleratesTheTrailingNewlineTheHelperWrites() {
        XCTAssertEqual(InstallStatus.parse("refused 0.43.0\n"), .refused(version: "0.43.0"))
        XCTAssertEqual(InstallStatus.parse("failed 1.2.3 swap\n"), .failed(version: "1.2.3", step: "swap"))
    }

    func test_parse_everyStepTheHelperNamesIsReadable() {
        for step in UpdateInstaller.HelperFailureStep.allCases {
            XCTAssertEqual(InstallStatus.parse("failed 0.43.0 \(step.rawValue)"),
                           .failed(version: "0.43.0", step: step.rawValue))
        }
    }

    func test_parse_garbageIsNil() {
        for text in ["", "\n", "refused", "failed 0.43.0", "refused 0.43.0 ditto",
                     "failed 0.43.0 ditto extra", "accepted 0.43.0", "REFUSED 0.43.0",
                     "failed 0.43.0 rm", "refused  0.43.0", "refused 0.43.0\nrefused 0.44.0",
                     "\u{0}\u{1}binary"] {
            XCTAssertNil(InstallStatus.parse(text), "should not parse: \(text.debugDescription)")
        }
    }

    func test_parse_aVersionThatIsNotXYZIsNil() {
        for v in ["0.43", "0.43.0.1", "v0.43.0", "0.43.x", "0.43.0-beta", "-1.0.0", "$(touch PWNED)"] {
            XCTAssertNil(InstallStatus.parse("refused \(v)"), v)
            XCTAssertNil(InstallStatus.parse("failed \(v) ditto"), v)
        }
    }

    // MARK: - sentences

    func test_theRefusedSentenceIsDenversRulingVerbatim() {
        XCTAssertEqual(InstallStatus.refused(version: "0.43.0").sentence,
                       "The update to Maugham 0.43.0 didn't pass its safety check and wasn't installed. Maugham will download it again.")
    }

    func test_theFailedSentenceNamesNoStep() {
        XCTAssertEqual(InstallStatus.failed(version: "0.43.0", step: "ditto").sentence,
                       "The update to Maugham 0.43.0 couldn't be installed. Maugham will try again.")
    }

    // MARK: - read and remove

    private func writeStatus(_ text: String) throws -> URL {
        let file = TestTemp.root.appendingPathComponent(UpdateInstaller.installStatusFileName)
        try Data(text.utf8).write(to: file)
        return file
    }

    func test_consume_readsAndRemovesTheFile() throws {
        let file = try writeStatus("refused 0.43.0\n")
        XCTAssertEqual(InstallStatus.consume(in: TestTemp.root), .refused(version: "0.43.0"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(InstallStatus.consume(in: TestTemp.root), "a second launch reads nothing")
    }

    func test_consume_removesTheFileEvenWhenItIsGarbage() throws {
        let file = try writeStatus("this is not a status line")
        XCTAssertNil(InstallStatus.consume(in: TestTemp.root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func test_consume_withNoFileIsNil() {
        XCTAssertNil(InstallStatus.consume(in: TestTemp.root))
    }

    // MARK: - the checker

    private func makeChecker(currentVersion: String = "0.42.0") -> UpdateChecker {
        UpdateChecker(
            currentVersionString: currentVersion,
            fetchLatest: { throw URLError(.notConnectedToInternet) },
            downloadAsset: { _, _, _ in throw URLError(.notConnectedToInternet) },
            stageAndVerify: { u, _ in u })
    }

    /// The two artifacts a version leaves in the Updates folder, plus a
    /// neighbour that must survive.
    private func makeArtifacts(version: String) throws -> (zip: URL, staged: URL) {
        let fm = FileManager.default
        let zip = TestTemp.root.appendingPathComponent("Maugham-\(version).zip")
        let staged = TestTemp.root.appendingPathComponent("staged-\(version)/Maugham.app", isDirectory: true)
        try Data("zip".utf8).write(to: zip)
        try fm.createDirectory(at: staged, withIntermediateDirectories: true)
        return (zip, staged.deletingLastPathComponent())
    }

    func test_refused_deletesThatVersionsZipAndStageFolderOnly_andShowsTheSentence() throws {
        let fm = FileManager.default
        let refused = try makeArtifacts(version: "0.43.0")
        let other = try makeArtifacts(version: "0.44.0")
        let neighbour = TestTemp.root.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: neighbour)
        _ = try writeStatus("refused 0.43.0\n")

        let checker = makeChecker()
        let status = checker.reportInstallStatus(in: TestTemp.root)

        XCTAssertEqual(status, .refused(version: "0.43.0"))
        XCTAssertFalse(fm.fileExists(atPath: refused.zip.path), "the next check must download it again")
        XCTAssertFalse(fm.fileExists(atPath: refused.staged.path))
        XCTAssertTrue(fm.fileExists(atPath: other.zip.path))
        XCTAssertTrue(fm.fileExists(atPath: other.staged.path))
        XCTAssertTrue(fm.fileExists(atPath: neighbour.path))
        XCTAssertEqual(checker.state, .installDidNotComplete(.refused(version: "0.43.0")))
        XCTAssertEqual(UpdateBannerView.notice(for: checker.state),
                       "The update to Maugham 0.43.0 didn't pass its safety check and wasn't installed. Maugham will download it again.")
    }

    func test_failed_keepsTheStagedFiles_andShowsTheSentence() throws {
        let fm = FileManager.default
        let artifacts = try makeArtifacts(version: "0.43.0")
        _ = try writeStatus("failed 0.43.0 ditto\n")

        let checker = makeChecker()
        checker.reportInstallStatus(in: TestTemp.root)

        XCTAssertTrue(fm.fileExists(atPath: artifacts.zip.path))
        XCTAssertTrue(fm.fileExists(atPath: artifacts.staged.path))
        XCTAssertEqual(checker.state, .installDidNotComplete(.failed(version: "0.43.0", step: "ditto")))
        XCTAssertEqual(UpdateBannerView.notice(for: checker.state),
                       "The update to Maugham 0.43.0 couldn't be installed. Maugham will try again.")
    }

    func test_garbage_leavesTheCheckerIdle_andNoFileBehind() throws {
        let file = try writeStatus("refused banana")
        let checker = makeChecker()
        XCTAssertNil(checker.reportInstallStatus(in: TestTemp.root))
        XCTAssertEqual(checker.state, .idle)
        XCTAssertNil(UpdateBannerView.notice(for: checker.state))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func test_aLineAboutTheRunningVersionOrOlderIsStale_andSaysNothing() throws {
        for line in ["failed 0.43.0 swap", "refused 0.42.0"] {
            let file = try writeStatus(line)
            let checker = makeChecker(currentVersion: "0.43.0")
            XCTAssertNil(checker.reportInstallStatus(in: TestTemp.root), line)
            XCTAssertEqual(checker.state, .idle, line)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), line)
        }
    }

    func test_aDevBuildSaysNothing() throws {
        _ = try writeStatus("refused 0.43.0")
        let checker = makeChecker(currentVersion: "0.0.0-dev")
        XCTAssertNil(checker.reportInstallStatus(in: TestTemp.root))
        XCTAssertEqual(checker.state, .idle)
    }

    func test_dismissMovesTheNoticeToIdle_andTouchesNoOtherState() throws {
        _ = try writeStatus("refused 0.43.0")
        let checker = makeChecker()
        checker.reportInstallStatus(in: TestTemp.root)
        checker.dismissInstallNotice()
        XCTAssertEqual(checker.state, .idle)
        XCTAssertNil(UpdateBannerView.notice(for: checker.state))
    }

    func test_theNextCheckReplacesTheNotice() async throws {
        _ = try writeStatus("refused 0.43.0")
        let checker = makeChecker()
        checker.reportInstallStatus(in: TestTemp.root)
        await checker.performCheck(trigger: .manual)
        XCTAssertNil(UpdateBannerView.notice(for: checker.state))
    }

    // MARK: - the other surfaces' words for the state

    func test_theNoticeIsNotTheReadyBanner_andIsIdleShapedElsewhere() {
        let state = UpdateState.installDidNotComplete(.refused(version: "0.43.0"))
        XCTAssertFalse(UpdateBannerView.shouldShow(state: state, dismissed: []))
        XCTAssertNil(UpdateBannerView.notice(for: .readyToInstall(
            bundleURL: URL(fileURLWithPath: "/x/Maugham.app"), version: "0.43.0", releaseNotes: "")))
        XCTAssertEqual(UpdateMenuCommand.menuTitle(for: state), "Check for Updates…")
        XCTAssertEqual(UpdateSheet.title(for: state), "Maugham 0.43.0 Wasn't Installed")
    }
}
