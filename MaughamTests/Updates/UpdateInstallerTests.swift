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
}
