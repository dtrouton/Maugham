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

/// **Both directions, for every transition on the ladder** (signed op log P3b
/// Task 5, spec §5 and §7.2).
///
/// A permit change has two halves and a writer is owed both before they press:
/// a demotion does not reach back through what is already in the book, and a
/// promotion is not a pardon for what was set aside. Spec §5 states each as its
/// own row; every transition the control can produce is one of them or both at
/// once, so the table below walks all of them and asserts the halves that
/// happened and the absence of the halves that did not.
///
/// Nothing here mounts anything or presses anything (tripwire 33): the sentence
/// is a pure function of (old permit, new permit, the book's pieces).
final class PermitChangeConfirmationTests: XCTestCase {

    private let sam = "cccc3333dddd4444"

    private let pieces = [
        PermitControl.Piece(id: "ch1", title: "Chapter 1"),
        PermitControl.Piece(id: "ch4", title: "Chapter 4"),
        PermitControl.Piece(id: "ch9", title: "Chapter 9"),
    ]

    private func message(from: Permit, to: Permit, notice: String? = nil) -> String {
        PeopleAndDevicesConfirmation.changePermit(
            forPerson: sam, named: "Sam",
            change: .init(pieces: pieces, from: from, to: to),
            notice: notice
        ).message
    }

    /// The demotion half's own words, and the promotion half's, so each
    /// assertion below is about one half rather than about a substring somebody
    /// could move.
    private let staysInTheBook = "stays in this book"
    private let setAsideFromNowOn = "from now on is set aside"
    private let notAPardon = "stays set aside"

    // MARK: - The whole ladder, both directions

    /// **Author of the whole book → reviewer.** Everything leaves; nothing
    /// joins. The row a writer is most likely to press, and the one they are
    /// most likely to be afraid of.
    func test_demotingToAReviewerSaysWhatStaysAndWhatIsSetAsideFromNowOn() {
        let said = message(from: .author(.book), to: .reviewer)

        XCTAssertTrue(said.contains("has already written in this book stays in it"), said)
        XCTAssertTrue(said.contains(setAsideFromNowOn), said)
        XCTAssertFalse(said.contains("can write"), "nothing joins: \(said)")
    }

    /// **Reviewer → author of the whole book.** Everything joins, and the half
    /// nobody assumes is stated: it is not a pardon.
    func test_promotingToTheWholeBookSaysItIsNotAPardon() {
        let said = message(from: .reviewer, to: .author(.book))

        XCTAssertTrue(said.contains("can write anywhere in this book from now on"), said)
        XCTAssertTrue(said.contains(notAPardon), said)
        XCTAssertFalse(said.contains(setAsideFromNowOn), "nothing leaves: \(said)")
    }

    /// **Author of the whole book → author of some pieces.** The transition
    /// spec §5's table does not spell out by name, and which decomposes into
    /// its demotion row: the pieces she keeps are unchanged, the rest leave.
    func test_narrowingTheWholeBookToSomePiecesNamesWhatLeaves() {
        let said = message(
            from: .author(.book), to: .author(.pieces(["ch4"])))

        XCTAssertTrue(said.contains("\u{201C}Chapter 1\u{201D}"), said)
        XCTAssertTrue(said.contains("\u{201C}Chapter 9\u{201D}"), said)
        XCTAssertFalse(said.contains("\u{201C}Chapter 4\u{201D}"),
                       "the piece she keeps is not a place anything moved: \(said)")
        XCTAssertTrue(said.contains(staysInTheBook), said)
        XCTAssertTrue(said.contains(setAsideFromNowOn), said)
    }

    /// **Author of some pieces → author of the whole book.** The rest join; the
    /// pieces she already had say nothing.
    func test_wideningSomePiecesToTheWholeBookNamesWhatJoins() {
        let said = message(
            from: .author(.pieces(["ch4"])), to: .author(.book))

        XCTAssertTrue(said.contains("\u{201C}Chapter 1\u{201D}"), said)
        XCTAssertTrue(said.contains("\u{201C}Chapter 9\u{201D}"), said)
        XCTAssertTrue(said.contains(notAPardon), said)
        XCTAssertFalse(said.contains(setAsideFromNowOn), said)
    }

    /// **Reviewer → author of some pieces.** Only the chosen pieces join.
    func test_aReviewerGivenSomePiecesJoinsOnlyThose() {
        let said = message(
            from: .reviewer, to: .author(.pieces(["ch9"])))

        XCTAssertTrue(said.contains("can write in \u{201C}Chapter 9\u{201D} from now on"), said)
        XCTAssertFalse(said.contains("\u{201C}Chapter 1\u{201D}"), said)
        XCTAssertTrue(said.contains(notAPardon), said)
    }

    /// **Author of some pieces → reviewer.** Only the pieces she had leave.
    func test_anAuthorOfSomePiecesDemotedToReviewerLosesOnlyThose() {
        let said = message(
            from: .author(.pieces(["ch1", "ch4"])), to: .reviewer)

        XCTAssertTrue(said.contains("\u{201C}Chapter 1\u{201D}"), said)
        XCTAssertTrue(said.contains("\u{201C}Chapter 4\u{201D}"), said)
        XCTAssertFalse(said.contains("\u{201C}Chapter 9\u{201D}"), said)
        XCTAssertTrue(said.contains(setAsideFromNowOn), said)
    }

    /// **One piece list becoming another** — the transition where both
    /// directions happen at once, which is the one a single-row sentence would
    /// get half right. Both halves are stated, each naming its own pieces.
    func test_apieceListThatBothGainsAndLosesStatesBothHalves() {
        let said = message(
            from: .author(.pieces(["ch1"])), to: .author(.pieces(["ch9"])))

        XCTAssertTrue(
            said.contains("already wrote in \u{201C}Chapter 1\u{201D} stays in this book"),
            said)
        XCTAssertTrue(said.contains(setAsideFromNowOn), said)
        XCTAssertTrue(
            said.contains("can write in \u{201C}Chapter 9\u{201D} from now on"), said)
        XCTAssertTrue(said.contains(notAPardon), said)
    }

    /// A change that moves no place at all — a book with no pieces, or a list
    /// that moved only among documents this permit already covered — says so
    /// rather than saying one of the two halves about nothing.
    func test_achangeThatMovesNoPieceSaysThat() {
        let said = PeopleAndDevicesConfirmation.changePermit(
            forPerson: sam, named: "Sam",
            change: .init(pieces: [], from: .reviewer, to: .author(.book))
        ).message

        XCTAssertTrue(said.contains("Nothing Sam has written moves"), said)
        XCTAssertFalse(said.contains(setAsideFromNowOn), said)
    }

    /// **An empty piece list is a real state** (`PermitPicker.noPiecesChosen`):
    /// an author of no pieces yet may still start one, and this book asks whose
    /// it is when they do. The rule is the permit layer's
    /// (`Permit.mayStartAPieceOfTheirOwn`), so a reviewer never gets the clause.
    func test_anAuthorOfNoPiecesYetIsToldWhatThatMeans() {
        let asAuthor = message(from: .reviewer, to: .author(.pieces([])))
        let asReviewer = message(from: .author(.book), to: .reviewer)

        XCTAssertTrue(asAuthor.contains("can still start a piece of their own"), asAuthor)
        XCTAssertTrue(asAuthor.contains("will ask you whether it\u{2019}s theirs"), asAuthor)
        XCTAssertFalse(asReviewer.contains("start a piece of their own"), asReviewer)
    }

    // MARK: - Pieces this Mac cannot find

    /// A scope naming a document this Mac has not synced is still a place the
    /// change moves, so it is counted — and drawn as what it is, never as a
    /// document id, which is not a thing a writer has ever seen.
    func test_apieceThisMacCannotFindIsCountedAndNamedAsSuch() {
        let said = message(
            from: .author(.pieces(["not-here"])), to: .reviewer)

        XCTAssertTrue(said.contains("a piece this Mac can\u{2019}t find"), said)
        XCTAssertFalse(said.contains("not-here"), "never the raw id: \(said)")
    }

    // MARK: - More pieces than a writer can hold in their head

    /// Four or more are counted rather than listed: a sentence naming six
    /// chapters is a paragraph, and the writer can check a count against the
    /// tree as well as a list.
    func test_manyPiecesAreCountedRatherThanListed() {
        let many = (1...6).map {
            PermitControl.Piece(id: "ch\($0)", title: "Chapter \($0)")
        }
        let said = PeopleAndDevicesConfirmation.changePermit(
            forPerson: sam, named: "Sam",
            change: .init(pieces: many, from: .author(.book),
                          to: .author(.pieces(["ch1"])))
        ).message

        XCTAssertTrue(said.contains("5 pieces"), said)
        XCTAssertFalse(said.contains("Chapter 6"), said)
    }

    // MARK: - The first narrowing (one sentence, two callers)

    /// The sentence about what a book's FIRST narrowing costs is
    /// `PermitControl.firstNarrowingNotice`'s — the admission sheet's too — and
    /// it is appended rather than restated here.
    func test_thefirstNarrowingSentenceIsTheSharedOneAndIsAppended() throws {
        let notice = try XCTUnwrap(PermitControl.notice(
            forGranting: .reviewer,
            in: PermitControl.BookNarrowing(
                alreadyNarrowed: false, holdsAnUnsignedStream: true)))
        let said = message(from: .author(.book), to: .reviewer, notice: notice)

        XCTAssertTrue(said.hasSuffix(notice),
                      "the shared sentence, last and whole: \(said)")
        XCTAssertTrue(said.contains("Older versions of Maugham will no longer open"), said)
        XCTAssertTrue(said.contains("waits on the other Macs"), said)
    }

    /// And a book already narrowed is told nothing again — the guard is
    /// `PermitControl`'s and this only proves the pane honours nil.
    func test_abookAlreadyNarrowedGetsNoSecondNotice() {
        let notice = PermitControl.notice(
            forGranting: .reviewer,
            in: PermitControl.BookNarrowing(alreadyNarrowed: true))
        XCTAssertNil(notice)

        let said = message(from: .author(.book), to: .reviewer, notice: notice)
        XCTAssertFalse(said.contains("Older versions of Maugham"), said)
    }

    // MARK: - Deciding over history the writer has put down (P3b Task 6)

    /// **A book that has lost nothing is told nothing** — which is nearly
    /// every book, and the clause must not become a permanent paragraph on a
    /// confirmation about something else.
    func test_abookMissingNothingCarriesNoLostHistoryClause() {
        XCTAssertNil(PeopleAndDevicesConfirmation.lostHistoryClause(count: 0))
        let said = message(from: .author(.book), to: .reviewer)
        XCTAssertFalse(said.contains("is missing"), said)
    }

    /// **And a book deciding over an acknowledged loss is told the cost**: the
    /// act goes through with a mark that cannot name the missing stream, so
    /// anything that comes back afterwards falls on the far side of it.
    func test_anAcknowledgedLossIsStatedWithItsCostOnEveryMarkingVerb() {
        let changed = PeopleAndDevicesConfirmation.changePermit(
            forPerson: sam, named: "Sam",
            change: .init(pieces: pieces, from: .author(.book), to: .reviewer),
            lostHistory: 1
        ).message
        let readmitted = PeopleAndDevicesConfirmation.readmit(
            person: sam, named: "Sam",
            change: .init(pieces: pieces, from: .reviewer, to: .reviewer),
            lostHistory: 2
        ).message
        let revoked = PeopleAndDevicesConfirmation.revoke(
            person: sam, named: "Sam", lostHistory: 1).message

        for said in [changed, readmitted, revoked] {
            XCTAssertTrue(said.contains("you\u{2019}ve said you know it is gone"), said)
            XCTAssertTrue(
                said.contains("judges it as written after this change"),
                "the cost, which is the whole of what the writer takes on: \(said)")
        }
        XCTAssertTrue(changed.contains("One piece"), changed)
        XCTAssertTrue(readmitted.contains("2 pieces"), readmitted)
    }

    /// It comes LAST, because it is a condition of the act rather than part of
    /// what the act does.
    func test_thelostHistoryClauseIsAppendedAfterEverythingElse() throws {
        let clause = try XCTUnwrap(
            PeopleAndDevicesConfirmation.lostHistoryClause(count: 1))
        let notice = try XCTUnwrap(PermitControl.notice(
            forGranting: .reviewer,
            in: PermitControl.BookNarrowing(
                alreadyNarrowed: false, holdsAnUnsignedStream: true)))
        let said = PeopleAndDevicesConfirmation.changePermit(
            forPerson: sam, named: "Sam",
            change: .init(pieces: pieces, from: .author(.book), to: .reviewer),
            notice: notice, lostHistory: 1
        ).message

        XCTAssertTrue(said.hasSuffix(clause), said)
        XCTAssertTrue(said.contains(notice), "and the first-narrowing sentence survives")
    }

    // MARK: - Re-admission (Task 4's review, the Critical)

    /// **A re-admission names the permit it installs.** `RegistryAdmission
    /// .admit` over a revoked record installs what the caller gives it, and the
    /// caller's default is the whole book — so an author of two chapters came
    /// back an author of the novel with nothing on screen saying so.
    func test_areadmissionSaysWhatItInstallsAndThatItIsNotAPardon() {
        let said = PeopleAndDevicesConfirmation.readmit(
            person: sam, named: "Sam",
            change: .init(pieces: pieces, from: .author(.pieces(["ch4"])),
                          to: .author(.pieces(["ch4"])))
        ).message

        XCTAssertTrue(said.contains("can write in this book again"), said)
        XCTAssertTrue(said.contains("an author of some pieces"), said)
        XCTAssertTrue(said.contains("\u{201C}Chapter 4\u{201D}"), said)
        XCTAssertTrue(said.contains("stays set aside"),
                      "letting them back in is not a pardon: \(said)")
    }

    /// The whole-book re-admission says so in as many words, which is exactly
    /// what was happening silently before.
    func test_areadmissionToTheWholeBookSaysTheWholeBook() {
        let said = PeopleAndDevicesConfirmation.readmit(
            person: sam, named: "Sam",
            change: .init(pieces: pieces, from: .author(.book), to: .author(.book))
        ).message

        XCTAssertTrue(said.contains("an author of the whole book"), said)
        XCTAssertTrue(said.contains("can write anywhere in the book"), said)
    }

    /// And a permit no control can draw is said to be exactly that, rather than
    /// guessed at — a role word a later Maugham wrote is not *author*.
    func test_apermitThisBuildCannotDrawIsNeverGuessedAt() {
        let said = PeopleAndDevicesConfirmation.saying(
            .unjudgeable(raw: "editor-in-chief"), among: pieces)

        XCTAssertTrue(said.contains("doesn\u{2019}t recognise"), said)
        XCTAssertFalse(said.contains("author"), said)
    }
}
