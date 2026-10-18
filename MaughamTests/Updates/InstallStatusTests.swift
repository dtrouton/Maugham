// MaughamTests/Updates/InstallStatusTests.swift
import XCTest
@testable import Maugham

/// #67 Task 5: the next launch reads the swap helper's `install-status` line,
/// removes it, and the update banner says once what the helper couldn't do.
/// Windowless throughout (tripwire 33): the banner is checked through the pure
/// `UpdateBannerView.notice(for:)` it draws from.
@MainActor
final class InstallStatusTests: XCTestCase {

    /// A private preferences domain per test: a `refused` line is remembered
    /// (#67 final review), and the test host's `.standard` is shared.
    private var defaultsSuite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaultsSuite = "InstallStatusTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuite)
        defaults = nil
        super.tearDown()
    }

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
            stageAndVerify: { u, _ in u },
            refusalDefaults: defaults)
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
        XCTAssertEqual(checker.installNotice, .refused(version: "0.43.0"))
        XCTAssertEqual(checker.state, .idle, "the notice is not a check state")
        XCTAssertEqual(UpdateBannerView.notice(for: checker.installNotice),
                       "The update to Maugham 0.43.0 didn't pass its safety check and wasn't installed. Maugham will download it again.")
    }

    func test_aSecondRefusalSaysToCheckByHand_becauseTheBackgroundPollWillNotRetry() throws {
        _ = try writeStatus("refused 0.43.0\n")
        let first = makeChecker()
        first.reportInstallStatus(in: TestTemp.root)
        XCTAssertFalse(first.installNoticeWaitsForManualCheck)

        _ = try writeStatus("refused 0.43.0\n")
        let second = makeChecker()
        second.reportInstallStatus(in: TestTemp.root)
        XCTAssertTrue(second.installNoticeWaitsForManualCheck)
        XCTAssertEqual(UpdateBannerView.notice(for: second.installNotice,
                                               waitsForManualCheck: second.installNoticeWaitsForManualCheck),
                       "The update to Maugham 0.43.0 didn't pass its safety check again and wasn't installed. Choose Check for Updates… to try once more.")
        second.dismissInstallNotice()
        XCTAssertFalse(second.installNoticeWaitsForManualCheck)
    }

    func test_failed_keepsTheStagedFiles_andShowsTheSentence() throws {
        let fm = FileManager.default
        let artifacts = try makeArtifacts(version: "0.43.0")
        _ = try writeStatus("failed 0.43.0 ditto\n")

        let checker = makeChecker()
        checker.reportInstallStatus(in: TestTemp.root)

        XCTAssertTrue(fm.fileExists(atPath: artifacts.zip.path))
        XCTAssertTrue(fm.fileExists(atPath: artifacts.staged.path))
        XCTAssertEqual(checker.installNotice, .failed(version: "0.43.0", step: "ditto"))
        XCTAssertEqual(UpdateBannerView.notice(for: checker.installNotice),
                       "The update to Maugham 0.43.0 couldn't be installed. Maugham will try again.")
    }

    func test_garbage_leavesTheCheckerIdle_andNoFileBehind() throws {
        let file = try writeStatus("refused banana")
        let checker = makeChecker()
        XCTAssertNil(checker.reportInstallStatus(in: TestTemp.root))
        XCTAssertNil(checker.installNotice)
        XCTAssertNil(UpdateBannerView.notice(for: checker.installNotice))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func test_aLineAboutTheRunningVersionOrOlderIsStale_andSaysNothing() throws {
        for line in ["failed 0.43.0 swap", "refused 0.42.0"] {
            let file = try writeStatus(line)
            let checker = makeChecker(currentVersion: "0.43.0")
            XCTAssertNil(checker.reportInstallStatus(in: TestTemp.root), line)
            XCTAssertNil(checker.installNotice, line)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), line)
        }
    }

    func test_aDevBuildSaysNothing() throws {
        _ = try writeStatus("refused 0.43.0")
        let checker = makeChecker(currentVersion: "0.0.0-dev")
        XCTAssertNil(checker.reportInstallStatus(in: TestTemp.root))
        XCTAssertNil(checker.installNotice)
    }

    func test_dismissClearsTheNotice_andTouchesNoCheckState() throws {
        _ = try writeStatus("refused 0.43.0")
        let checker = makeChecker()
        checker.reportInstallStatus(in: TestTemp.root)
        checker.dismissInstallNotice()
        XCTAssertNil(checker.installNotice)
        XCTAssertNil(UpdateBannerView.notice(for: checker.installNotice))
        XCTAssertEqual(checker.state, .idle)
    }

    /// Denver chose "tell me next launch": the sentence must be SEEN, so no
    /// check result replaces it — not a failed check, not a fresh "ready".
    func test_theNoticeSurvivesEveryLaterCheckResult() async throws {
        _ = try writeStatus("refused 0.43.0")
        let failing = makeChecker()
        failing.reportInstallStatus(in: TestTemp.root)
        await failing.performCheck(trigger: .manual)
        await failing.performCheck(trigger: .background)
        XCTAssertEqual(failing.installNotice, .refused(version: "0.43.0"))

        // A separate scenario: a FIRST refusal, which the background poll still
        // re-stages. (Two keep it idle — `UpdateCheckerTests.test_twoRefusals*`.)
        InstallRefusalMemory.clear(defaults: defaults)
        _ = try writeStatus("refused 0.43.0")
        let ready = UpdateChecker(
            currentVersionString: "0.42.0",
            fetchLatest: {
                try GitHubRelease.decode(from: Data("""
                {"tag_name":"v0.43.0","name":"x","body":"notes","draft":false,"prerelease":false,
                 "assets":[{"name":"Maugham-0.43.0.zip",
                            "browser_download_url":"https://github.com/dtrouton/Maugham/releases/download/v0.43.0/Maugham-0.43.0.zip",
                            "size":100}]}
                """.utf8))
            },
            downloadAsset: { _, _, _ in TestTemp.root.appendingPathComponent("Maugham-0.43.0.zip") },
            stageAndVerify: { _, _ in TestTemp.root.appendingPathComponent("staged-0.43.0/Maugham.app") },
            systemVersion: MinimumSystemVersion(major: 27),
            refusalDefaults: defaults)
        ready.reportInstallStatus(in: TestTemp.root)
        await ready.performCheck(trigger: .background)
        // Both draw: the refusal, and beneath it the fresh "0.43.0 is ready".
        XCTAssertEqual(UpdateBannerView.notice(for: ready.installNotice),
                       InstallStatus.refused(version: "0.43.0").sentence)
        XCTAssertTrue(UpdateBannerView.shouldShow(state: ready.state, dismissed: []))
    }

    func test_noNoticeWithoutAStatusLine() {
        XCTAssertNil(UpdateBannerView.notice(for: nil))
        XCTAssertNil(makeChecker().installNotice)
    }
}
