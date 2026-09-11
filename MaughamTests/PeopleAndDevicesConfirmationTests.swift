import XCTest
@testable import Maugham
@testable import MaughamCore

/// **What the writer is asked before an act there is no way back from**
/// (signed op log P2b Task 7, fix round 1, Important 3a).
///
/// The whole of the alert is a value, so what it SAYS is asserted here with
/// nothing mounted — no dialog is presented, nothing is pressed, and no effect
/// is waited on (tripwire 33). The host's job is to draw it and to call the
/// verb on confirm, and that switch is the one thing a third act cannot be
/// added without.
final class PeopleAndDevicesConfirmationTests: XCTestCase {

    private let phone = "cccc3333dddd4444"

    // MARK: - Revoke

    /// The consequence, not the verb. *Are you sure* tells a writer nothing
    /// they did not know when they pressed; spec §5's sentence tells them what
    /// Maugham will stop doing and the thing it cannot do.
    func test_revokeAsksWithTheConsequenceAndNamesWhoItIsAbout() {
        let confirmation = PeopleAndDevicesConfirmation.revoke(
            person: phone, named: "Amelia (Denver’s iPhone)")

        XCTAssertEqual(confirmation.verb, .revoke)
        XCTAssertEqual(confirmation.fingerprint, phone)
        XCTAssertTrue(confirmation.title.contains("Amelia"), confirmation.title)
        XCTAssertTrue(
            confirmation.message.contains(
                "stops Maugham applying what this device writes"),
            confirmation.message)
        XCTAssertTrue(
            confirmation.message.contains("remove it from the iCloud share"),
            "the half the writer would otherwise get wrong: \(confirmation.message)")
        XCTAssertEqual(confirmation.confirmTitle, "Revoke")
    }

    /// A revocation HAS an inverse as of this round, and the alert says so —
    /// the writer deciding whether to press is deciding how reversible it is.
    func test_revokeSaysThereIsAWayBack() {
        let confirmation = PeopleAndDevicesConfirmation.revoke(
            person: phone, named: "Amelia")

        XCTAssertTrue(confirmation.message.contains("let them back in"),
                      confirmation.message)
    }

    // MARK: - Retire

    /// Retirement has no inverse, and the sentence says that rather than
    /// leaving the writer to find out.
    func test_retireAsksWithTheSameConsequenceItWillStateAfterwards() {
        let confirmation = PeopleAndDevicesConfirmation.retire(
            device: phone, named: "Denver’s MacBook", kind: "Mac")

        XCTAssertEqual(confirmation.verb, .retire)
        XCTAssertTrue(confirmation.title.contains("Denver’s MacBook"), confirmation.title)
        XCTAssertTrue(
            confirmation.message.contains(
                DeviceStanding.retirementTail(device: "Mac")),
            "the same clause the standing notice uses: \(confirmation.message)")
        XCTAssertTrue(confirmation.message.contains("can’t be un-retired"),
                      confirmation.message)
        XCTAssertEqual(confirmation.confirmTitle, "Retire")
    }

    /// The noun is the machine's own, in both halves — a phone confirming its
    /// own retirement must not be told about a Mac (tripwire 19).
    func test_retireSpeaksOfTheMachineItIsAbout() {
        let confirmation = PeopleAndDevicesConfirmation.retire(
            device: phone, named: "Denver’s iPhone", kind: "iPhone")

        XCTAssertTrue(confirmation.message.contains("this iPhone"), confirmation.message)
        XCTAssertFalse(confirmation.message.contains("Mac"), confirmation.message)
    }

    // MARK: - Merge (Task 8)

    /// Not destructive and confirmed anyway: a merge starts applying a whole
    /// chain of somebody's devices in this book at once, and there is no
    /// un-adopt verb anywhere in this milestone.
    func test_mergeAsksWhetherThatRootIsAlsoTheWriter() {
        let confirmation = PeopleAndDevicesConfirmation.merge(
            root: phone, named: "Denver’s old MacBook")

        XCTAssertEqual(confirmation.verb, .merge)
        XCTAssertEqual(confirmation.fingerprint, phone)
        XCTAssertTrue(confirmation.title.contains("Denver’s old MacBook"),
                      confirmation.title)
        XCTAssertTrue(
            confirmation.message.contains("apply everything that root’s devices wrote"),
            confirmation.message)
        XCTAssertTrue(
            confirmation.message.contains("keep their own root"),
            "and the half a writer would otherwise get wrong — neither root "
            + "gives way (B1): \(confirmation.message)")
        XCTAssertEqual(confirmation.confirmTitle, "Merge")
    }

    // MARK: - Identity

    /// Keyed on the verb AND the subject: a writer who dismisses one alert and
    /// opens another must get the new question, not the old one's identity.
    func test_twoActsAboutOneDeviceAreTwoQuestions() {
        let revoke = PeopleAndDevicesConfirmation.revoke(person: phone, named: "Amelia")
        let retire = PeopleAndDevicesConfirmation.retire(
            device: phone, named: "Amelia", kind: "iPhone")

        XCTAssertNotEqual(revoke.id, retire.id)
        XCTAssertNotEqual(revoke, retire)
    }
}
