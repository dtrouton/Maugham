import XCTest
@testable import Maugham

final class UpdateInstallerTests: XCTestCase {
    private func goodVerdict(team: String = "ABC123") -> VerificationVerdict {
        VerificationVerdict(codesignValid: true, notarized: true, teamID: team)
    }

    func test_accepts_whenSignedNotarizedAndTeamMatches() {
        let v = goodVerdict(team: "ABC123")
        XCTAssertEqual(UpdateInstaller.decide(verdict: v, expectedTeamID: "ABC123"), .accept)
    }

    func test_rejects_whenTeamMismatch() {
        let v = goodVerdict(team: "EVIL99")
        XCTAssertEqual(UpdateInstaller.decide(verdict: v, expectedTeamID: "ABC123"),
                       .reject(reason: "Team ID mismatch"))
    }

    func test_rejects_whenNotNotarized() {
        let v = VerificationVerdict(codesignValid: true, notarized: false, teamID: "ABC123")
        XCTAssertEqual(UpdateInstaller.decide(verdict: v, expectedTeamID: "ABC123"),
                       .reject(reason: "Not notarized"))
    }

    func test_rejects_whenCodesignInvalid() {
        let v = VerificationVerdict(codesignValid: false, notarized: true, teamID: "ABC123")
        XCTAssertEqual(UpdateInstaller.decide(verdict: v, expectedTeamID: "ABC123"),
                       .reject(reason: "Invalid code signature"))
    }

    func test_helperScript_relaunch_containsWaitSwapAndOpen() {
        let script = UpdateInstaller.helperScript(
            pid: 4242, stagedBundle: "/staged/Maugham.app",
            installedBundle: "/Applications/Maugham.app", relaunch: true)
        XCTAssertTrue(script.contains("kill -0 4242"))
        XCTAssertTrue(script.contains("ditto"))
        XCTAssertTrue(script.contains("/staged/Maugham.app"))
        XCTAssertTrue(script.contains("/Applications/Maugham.app"))
        XCTAssertTrue(script.contains("open \"/Applications/Maugham.app\""))
    }

    func test_helperScript_noRelaunch_omitsOpen() {
        let script = UpdateInstaller.helperScript(
            pid: 4242, stagedBundle: "/staged/Maugham.app",
            installedBundle: "/Applications/Maugham.app", relaunch: false)
        XCTAssertFalse(script.contains("open \""))
        XCTAssertTrue(script.contains("ditto"))
    }

    func test_installMode_inPlaceWhenWritable() {
        XCTAssertEqual(UpdateInstaller.installMode(installedBundlePath: "/Applications/Maugham.app",
                                                   isWritable: { _ in true }), .inPlace)
    }

    func test_installMode_finderFallbackWhenNotWritable() {
        XCTAssertEqual(UpdateInstaller.installMode(installedBundlePath: "/Applications/Maugham.app",
                                                   isWritable: { _ in false }), .finderFallback)
    }
}
