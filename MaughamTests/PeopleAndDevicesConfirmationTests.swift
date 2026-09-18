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

    /// **The writer chooses how much a revocation takes back** (find 5, ruled
    /// 2026-09-18). The default leaves the draft as they have read it; the
    /// alternate is the whole history, which is what a revocation did before
    /// the ruling. Two buttons rather than a toggle: a writer who mis-set a
    /// checkbox would find out by reading their chapters.
    func test_revokeOffersBothScopesWithTheDefaultKeepingTheDraft() throws {
        let confirmation = PeopleAndDevicesConfirmation.revoke(
            person: phone, named: "Amelia")

        XCTAssertTrue(
            confirmation.message.contains("already written stays in this book"),
            "the default's cost, said before the press: \(confirmation.message)")

        let alternate = try XCTUnwrap(confirmation.alternate)
        XCTAssertEqual(alternate.scope, .nothing)
        XCTAssertTrue(alternate.title.contains("Set Aside Everything"), alternate.title)
        XCTAssertTrue(alternate.message.contains("Every paragraph and note from Amelia"),
                      alternate.message)
        XCTAssertTrue(alternate.message.contains("Nothing is deleted"),
                      "and what it does NOT cost: \(alternate.message)")
    }

    /// The alert has one message and the choice is between two consequences, so
    /// both are in it — a writer shown only the default's would be choosing in
    /// the dark.
    func test_thealertMessageCarriesBothConsequencesWhereThereAreTwo() {
        let revoke = PeopleAndDevicesConfirmation.revoke(person: phone, named: "Amelia")
        let merge = PeopleAndDevicesConfirmation.merge(root: phone, named: "Amelia")

        let message = PeopleAndDevicesConfirmation.alertMessage(for: revoke)
        XCTAssertTrue(message.contains(revoke.message))
        XCTAssertTrue(message.contains(revoke.alternate?.message ?? "—"))
        XCTAssertEqual(PeopleAndDevicesConfirmation.alertMessage(for: merge), merge.message,
                       "an act with one way to do it says one thing")
    }

    /// Every other act has one honest shape, so no other alert grows a second
    /// destructive button.
    func test_noOtherActOffersASecondWayToDoIt() {
        XCTAssertNil(PeopleAndDevicesConfirmation.merge(root: phone, named: "A").alternate)
        XCTAssertNil(PeopleAndDevicesConfirmation.retire(
            device: phone, named: "A", kind: "Mac").alternate)
        XCTAssertNil(PeopleAndDevicesConfirmation.rename(
            person: phone, named: "A", currently: "A").alternate)
        XCTAssertNil(PeopleAndDevicesConfirmation.restore(
            record: RecordRef(directory: .people, fingerprint: phone),
            named: "A", kind: "person").alternate)
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
    func test_mergeAsksWhetherThatMacIsAlsoTheWriter() {
        let confirmation = PeopleAndDevicesConfirmation.merge(
            root: phone, named: "Denver’s old MacBook")

        XCTAssertEqual(confirmation.verb, .merge)
        XCTAssertEqual(confirmation.fingerprint, phone)
        XCTAssertTrue(confirmation.title.contains("Denver’s old MacBook"),
                      confirmation.title)
        XCTAssertTrue(
            confirmation.message.contains("apply everything that Mac wrote"),
            confirmation.message)
        XCTAssertTrue(
            confirmation.message.contains("keeps the book you started"),
            "and the half a writer would otherwise get wrong — neither Mac "
            + "gives way (B1): \(confirmation.message)")
        XCTAssertEqual(confirmation.confirmTitle, "Merge")
    }

    // MARK: - Rename (P2 smoke find 3)

    /// The one act here that asks for a word rather than a yes — and the one
    /// whose message exists to say what a label IS, because a writer about to
    /// change one has no other way of knowing whether it moves anything.
    func test_renameAsksForAWordAndSaysWhatALabelIsNot() {
        let confirmation = PeopleAndDevicesConfirmation.rename(
            person: phone, named: "Denvre (Denver’s iPhone)", currently: "Denvre")

        XCTAssertEqual(confirmation.verb, .rename)
        XCTAssertEqual(confirmation.fingerprint, phone)
        XCTAssertTrue(confirmation.title.contains("Denvre"), confirmation.title)
        XCTAssertTrue(confirmation.message.contains("admits nobody"),
                      confirmation.message)
        XCTAssertTrue(confirmation.message.contains("shuts nobody"),
                      confirmation.message)
        XCTAssertEqual(confirmation.confirmTitle, "Rename")
    }

    /// The field starts at the name that stands, so the ordinary edit is a
    /// correction and an untouched field comes to the same thing as Cancel.
    func test_therenameFieldStartsAtTheNameThatStands() throws {
        let confirmation = PeopleAndDevicesConfirmation.rename(
            person: phone, named: "Denvre", currently: "Denvre")

        let field = try XCTUnwrap(confirmation.field)
        XCTAssertEqual(field.initialValue, "Denvre")
        XCTAssertFalse(field.prompt.isEmpty)
    }

    /// And the three acts that need only a yes carry no field, so a host that
    /// draws one cannot draw it for them.
    func test_theactsThatNeedOnlyAYesCarryNoField() {
        XCTAssertNil(PeopleAndDevicesConfirmation.revoke(
            person: phone, named: "Amelia").field)
        XCTAssertNil(PeopleAndDevicesConfirmation.retire(
            device: phone, named: "Amelia", kind: "iPhone").field)
        XCTAssertNil(PeopleAndDevicesConfirmation.merge(
            root: phone, named: "Amelia").field)
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
