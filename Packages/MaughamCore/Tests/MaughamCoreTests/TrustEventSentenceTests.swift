import Foundation
import XCTest
@testable import MaughamCore

/// One sentence per trust event, in the writer's words.
///
/// In MaughamCore rather than in the pane (tripwire 19) because the phone draws
/// the same events on the same day the Mac does, and two spellings of *Sam was
/// revoked* would be two answers to one question.
///
/// The naming rule under test throughout is spec §3's: a person is
/// `<label> (<ownName>)` **only where the two differ**, a device is its record's
/// name, and anybody with no record at all is their four-character code — the
/// code being what that device shows for itself, so the writer can compare two
/// screens.
final class TrustEventSentenceTests: XCTestCase {

    private let phone = "9c8b1d2e3f405162"
    private let root = "4f2ka1b2c3d4e5f6"

    private func event(
        _ kind: TrustEvent.Kind, subject: String, label: String? = nil,
        ownName: String? = nil, by: String? = nil, isMine: Bool = false,
        at seconds: TimeInterval? = 20
    ) -> TrustEvent {
        TrustEvent(
            date: seconds.map { Date(timeIntervalSince1970: $0) }, kind: kind,
            subject: subject, label: label, ownName: ownName, by: by, isMine: isMine)
    }

    // MARK: - Naming

    func test_aPersonWhoseLabelAndOwnNameDifferIsNamedByBoth() {
        XCTAssertEqual(
            TrustEventSentence.sentence(
                for: event(.admitted, subject: phone, label: "iPhone",
                           ownName: "Denver’s iPhone", by: root),
                labels: [root: "Denver"]),
            "iPhone (Denver’s iPhone) admitted by Denver.")
    }

    func test_aPersonWhoseTwoNamesAgreeIsNamedOnce() {
        XCTAssertEqual(
            TrustEventSentence.sentence(
                for: event(.admitted, subject: phone, label: "iPhone",
                           ownName: "iPhone", by: root),
                labels: [root: "Denver"]),
            "iPhone admitted by Denver.")
    }

    func test_aSubjectWithNoRecordIsNamedByItsCode() {
        XCTAssertEqual(
            TrustEventSentence.sentence(
                for: event(.admitted, subject: phone, by: root), labels: [:]),
            "9C8B admitted by 4F2K.")
    }

    /// The label map is the second chance, for a subject whose own event
    /// carries no names — the `by` half is only ever resolved this way.
    func test_aSubjectWithNoNamesOfItsOwnFallsBackToTheLabelMap() {
        XCTAssertEqual(
            TrustEventSentence.sentence(
                for: event(.retired, subject: phone), labels: [phone: "iPhone"]),
            "iPhone retired.")
    }

    func test_anEventAboutThisDeviceSaysSoRatherThanNamingIt() {
        XCTAssertEqual(
            TrustEventSentence.sentence(
                for: event(.retired, subject: phone, label: "iPhone", isMine: true),
                labels: [:]),
            "This Mac retired.")
    }

    // MARK: - One sentence per kind

    func test_anAdmissionWithNobodyNamedSaysOnlyThatItHappened() {
        XCTAssertEqual(
            TrustEventSentence.sentence(
                for: event(.admitted, subject: phone, label: "iPhone"), labels: [:]),
            "iPhone admitted.")
    }

    /// A device let in under a label this Mac had already granted, with no
    /// sheet shown.
    ///
    /// **C11, closed in the copy** (P3b Task 10). The kind gained its writer in
    /// P3a; the sentence still said *admitted automatically*, which names a
    /// mechanism and leaves the writer's actual question open — it reads as
    /// easily as *the app did the paperwork* as it does as *nobody asked me*.
    /// This test's own NAME says what the row has to say, and until now the
    /// string under it did not.
    func test_aSilentAdmissionSaysItWasNotAsked() {
        XCTAssertEqual(
            TrustEventSentence.sentence(
                for: event(.silentlyAdmitted, subject: phone, label: "iPhone", by: root),
                labels: [root: "Denver"]),
            "iPhone admitted by Denver without asking.")
    }

    /// …and with nobody to name, the fact survives on its own.
    func test_aSilentAdmissionWithNoNamedHandStillSaysItWasNotAsked() {
        XCTAssertEqual(
            TrustEventSentence.sentence(
                for: event(.silentlyAdmitted, subject: phone, label: "iPhone"),
                labels: [:]),
            "iPhone admitted without asking.")
    }

    func test_aRevocationNamesTheHandThatMadeIt() {
        XCTAssertEqual(
            TrustEventSentence.sentence(
                for: event(.revoked, subject: phone, label: "Sam", by: root),
                labels: [root: "Denver"]),
            "Sam revoked by Denver.")
    }

    func test_aRevocationWithNoHandNamedStillReads() {
        XCTAssertEqual(
            TrustEventSentence.sentence(
                for: event(.revoked, subject: phone, label: "Sam"), labels: [:]),
            "Sam revoked.")
    }

    func test_aRetirement() {
        XCTAssertEqual(
            TrustEventSentence.sentence(
                for: event(.retired, subject: phone, label: "iPhone"), labels: [:]),
            "iPhone retired.")
    }

    func test_aClaimSaysWhoClaimedTheBook() {
        XCTAssertEqual(
            TrustEventSentence.sentence(
                for: event(.claimed, subject: root, label: "Denver’s MacBook"),
                labels: [:]),
            "Denver’s MacBook claimed this book.")
    }

    func test_anAdoptionSaysWhoseHistoryWasTakenIn() {
        XCTAssertEqual(
            TrustEventSentence.sentence(
                for: event(.adopted, subject: phone, by: root),
                labels: [root: "Denver’s MacBook"]),
            "Denver’s MacBook adopted 9C8B’s history.")
    }

    /// **The keyless claim, as the Mac that made it reads it back** (P2b Task
    /// 8). This is the whole of what the writer sees after answering *yes, it
    /// is mine*: a book that says so.
    func test_aClaimByThisMacSaysThisMac() {
        XCTAssertEqual(
            TrustEventSentence.sentence(
                for: event(.claimed, subject: root, label: "Denver’s new MacBook",
                           isMine: true),
                labels: [:]),
            "This Mac claimed this book.")
    }

    /// **The merge, from the Mac that pressed it**: two roots, each adopting
    /// the other, and this is the half this device wrote.
    func test_aMergeReadsAsThisMacsRootTakingTheOtherChainIn() {
        XCTAssertEqual(
            TrustEventSentence.sentence(
                for: event(.adopted, subject: phone, label: "The studio Mac",
                           by: root),
                labels: [root: "Denver’s MacBook"]),
            "Denver’s MacBook adopted The studio Mac’s history.")
    }

    /// **And from the other Mac**, where the adopted chain is this device's
    /// own. The subject is not sentence-initial in this arm — the claimant
    /// leads — so *This Mac* is said in the middle of a sentence, and the one
    /// place that reads wrong is fixed here rather than in every caller.
    func test_anAdoptionOfThisMacsOwnHistoryReadsInTheMiddleOfTheSentence() {
        XCTAssertEqual(
            TrustEventSentence.sentence(
                for: event(.adopted, subject: phone, by: root, isMine: true),
                labels: [root: "Denver’s MacBook"]),
            "Denver’s MacBook adopted this Mac’s history.")
    }

    func test_anAdoptionWithNoClaimantNamedStillReads() {
        XCTAssertEqual(
            TrustEventSentence.sentence(
                for: event(.adopted, subject: phone, label: "Sam"), labels: [:]),
            "Sam’s history was adopted.")
    }

    func test_theJoinNamesTheChainThisMacIsOn() {
        XCTAssertEqual(
            TrustEventSentence.sentence(
                for: event(.joined, subject: root, label: "Denver’s MacBook"),
                labels: [:]),
            "This Mac joined Denver’s MacBook’s chain.")
    }

    /// The dateless form (Task 2's carry): a memory written before the join
    /// carried a stamp. The sentence is complete without one — the date is the
    /// row's to draw, never the sentence's, so nothing here changes.
    func test_theJoinReadsTheSameWithNoDate() {
        XCTAssertEqual(
            TrustEventSentence.sentence(
                for: event(.joined, subject: root, label: "Denver’s MacBook", at: nil),
                labels: [:]),
            "This Mac joined Denver’s MacBook’s chain.")
    }

    func test_aNamedClaimantIsNamed() {
        XCTAssertEqual(
            TrustEventSentence.sentence(
                for: event(.anotherClaimant, subject: root, label: "Sam", at: nil),
                labels: [:]),
            "Sam also claims this book.")
    }

    /// B1's sentence for the case that actually happens: another Mac nobody
    /// here has a record for. The code is what that Mac shows for itself.
    func test_anUnknownClaimantIsAnotherMacAndItsCode() {
        XCTAssertEqual(
            TrustEventSentence.sentence(
                for: event(.anotherClaimant, subject: root, at: nil), labels: [:]),
            "Another Mac (4F2K) also claims this book.")
    }

    func test_aRestoredRecordSaysItWasMissingAndIsBack() {
        XCTAssertEqual(
            TrustEventSentence.sentence(
                for: event(.recordRestored, subject: phone, label: "iPhone"), labels: [:]),
            "iPhone’s record was missing and has been put back.")
    }

    // MARK: - The unsigned entry (#8's History half, P3b Task 10)

    /// **Named by its stream, never by a code.** There is no key here — that is
    /// the whole fact — so four characters of a filename prefix would be a
    /// name two unsigned streams share.
    func test_anUnsignedEntryNamesTheStreamAndNotACode() {
        let holder = HeldLines.unsignedHolder(
            forStreamKey: "author-9f3c", deviceSlug: nil)
        XCTAssertEqual(
            TrustEventSentence.sentence(
                for: event(.unsigned, subject: holder, label: "author-9f3c"),
                labels: [:]),
            "This book was narrowed while nothing in it said who signs for "
            + "\u{201C}author-9f3c\u{201D}. Anything that stream has written "
            + "since is waiting: there is no device to admit, and its way back "
            + "in is the Inbox.")
    }

    /// **Nothing is coming.** A stream with no key can never have a record, so
    /// the *their record hasn't arrived yet* clause — true of every other
    /// unnamed subject — would be telling the writer to wait for the one thing
    /// this row exists to say is not there.
    func test_anUnsignedEntryIsNeverToldToWaitForARecord() {
        let holder = HeldLines.unsignedHolder(
            forStreamKey: "author-9f3c", deviceSlug: nil)
        XCTAssertNil(TrustEventSentence.unknownSubject(
            for: event(.unsigned, subject: holder), labels: [:]))
    }

    // MARK: - Vocabulary

    /// The pane's standing rule, applied to every kind at once: the internal
    /// words never reach the writer. *Chain* is the one exception and it is
    /// deliberate — it is the word the P2a banner already uses, and the writer
    /// has to be told which book's line of devices this Mac is on.
    func test_noSentenceUsesTheInternalVocabulary() {
        for kind in TrustEvent.Kind.allCases {
            let sentence = TrustEventSentence.sentence(
                for: event(kind, subject: phone, label: "iPhone", by: root),
                labels: [root: "Denver"])
            for word in ["quarantine", "provenance", "seal", "hash", "fingerprint",
                         "signature", "registry", "verdict", "trust", "pending"] {
                XCTAssertFalse(
                    sentence.localizedCaseInsensitiveContains(word),
                    "internal term ‘\(word)’ reached the writer — \(sentence)")
            }
            XCTAssertFalse(sentence.isEmpty, "\(kind) has no sentence")
        }
    }

    func test_everyKindEndsItsSentence() {
        for kind in TrustEvent.Kind.allCases {
            let sentence = TrustEventSentence.sentence(
                for: event(kind, subject: phone, label: "iPhone", by: root),
                labels: [root: "Denver"])
            XCTAssertTrue(sentence.hasSuffix("."), "\(kind): \(sentence)")
        }
    }

    // MARK: - The permit, in words (P3a Task 7)

    private func change(
        _ kind: TrustEvent.Kind, to permit: Permit, from previous: Permit?
    ) -> TrustEvent {
        TrustEvent(
            date: Date(timeIntervalSince1970: 30), kind: kind, subject: phone,
            label: "Sam", by: root, permit: permit, previousPermit: previous,
            event: "\(phone).a")
    }

    /// **A demotion states both directions**: what she became, and what did not
    /// move because of it.
    func test_aDemotionSaysWhatStaysInTheBook() {
        XCTAssertEqual(
            TrustEventSentence.sentence(
                for: change(.roleChanged, to: .reviewer, from: .bookAuthor),
                labels: [root: "Denver"]),
            "Sam became a reviewer. What they wrote before then stays in the book.")
    }

    /// And a promotion states the OTHER direction, because a promotion is not a
    /// pardon — the half that would be wrong if one sentence served both.
    func test_aPromotionSaysWhatStaysSetAside() {
        XCTAssertEqual(
            TrustEventSentence.sentence(
                for: change(.roleChanged, to: .bookAuthor, from: .reviewer),
                labels: [root: "Denver"]),
            "Sam became an author of the whole book. Anything set aside before "
                + "then stays set aside.")
    }

    /// A scope change counts, because *an author of some pieces* means nothing
    /// without a number.
    func test_aScopeChangeCountsThePieces() {
        XCTAssertEqual(
            TrustEventSentence.sentence(
                for: change(
                    .scopeChanged, to: .author(.pieces(["d-one", "d-two"])),
                    from: .bookAuthor),
                labels: [root: "Denver"]),
            "Sam became an author of 2 pieces. What they wrote before then "
                + "stays in the book.")
        XCTAssertTrue(
            TrustEventSentence.sentence(
                for: change(.scopeChanged, to: .author(.pieces([])), from: .bookAuthor),
                labels: [root: "Denver"])
                .contains("an author of no pieces yet"),
            "*she may write what she starts* is a real state")
        XCTAssertTrue(
            TrustEventSentence.sentence(
                for: change(.scopeChanged, to: .author(.pieces(["d-one"])), from: .bookAuthor),
                labels: [root: "Denver"])
                .contains("an author of one piece"))
    }

    /// **An answer to §4.5's question says what it did** (P3b smoke find F9,
    /// Denver's ruling of 2026-09-23). It widens, and the widening sentence —
    /// *anything set aside before then stays set aside* — is the opposite of
    /// what *Theirs* is for. It says *counts as theirs*, never *came in*: the
    /// same event is written on every record under the label, and a machine
    /// that never wrote in the piece had nothing to bring (review finding 3).
    func test_answeringThePieceQuestionSaysHerWordsCountAsTheirs() {
        let answer = TrustEvent(
            date: Date(timeIntervalSince1970: 30), kind: .scopeChanged,
            subject: phone, label: "Sam", by: root,
            permit: .author(.pieces(["d-one", "d-two"])),
            previousPermit: .author(.pieces(["d-one"])),
            settledPieces: ["d-two"], event: "\(phone).a")
        XCTAssertEqual(
            TrustEventSentence.sentence(for: answer, labels: [root: "Denver"]),
            "Sam became an author of 2 pieces. What they had already written "
                + "in the piece they started counts as theirs. Anything set "
                + "aside for any other reason stays set aside.")
        // The other direction: the same widening, not an answer, keeps the
        // widening sentence.
        XCTAssertEqual(
            TrustEventSentence.sentence(
                for: change(
                    .scopeChanged, to: .author(.pieces(["d-one", "d-two"])),
                    from: .author(.pieces(["d-one"]))),
                labels: [root: "Denver"]),
            "Sam became an author of 2 pieces. Anything set aside before then "
                + "stays set aside.")
    }

    /// A change that is neither wider nor narrower — two disjoint lists — gets
    /// the conservative half, because the one thing true of every such change
    /// is that the mark does not reach backwards.
    func test_aSidewaysChangeTakesTheConservativeHalf() {
        XCTAssertEqual(
            TrustEventSentence.sentence(
                for: change(
                    .scopeChanged, to: .author(.pieces(["d-two"])),
                    from: .author(.pieces(["d-one"]))),
                labels: [root: "Denver"]),
            "Sam became an author of one piece. What they wrote before then "
                + "stays in the book.")
    }

    /// A rung is said only where it is not the one every P2 admission meant, so
    /// every sentence an existing book draws is unchanged to the character.
    func test_anOrdinaryAdmissionSaysNoRungAndAReviewersSaysOne() {
        XCTAssertEqual(
            TrustEventSentence.sentence(
                for: TrustEvent(
                    date: nil, kind: .admitted, subject: phone, label: "Sam",
                    by: root, permit: .bookAuthor, event: "\(phone).a"),
                labels: [root: "Denver"]),
            "Sam admitted by Denver.")
        XCTAssertEqual(
            TrustEventSentence.sentence(
                for: TrustEvent(
                    date: nil, kind: .admitted, subject: phone, label: "Sam",
                    by: root, permit: .reviewer, event: "\(phone).a"),
                labels: [root: "Denver"]),
            "Sam admitted by Denver, as a reviewer.")
    }

    func test_aReadmissionSaysSoAndSaysAtWhat() {
        XCTAssertEqual(
            TrustEventSentence.sentence(
                for: TrustEvent(
                    date: nil, kind: .readmitted, subject: phone, label: "Sam",
                    by: root, permit: .reviewer, event: "\(phone).c"),
                labels: [root: "Denver"]),
            "Sam let back in by Denver, as a reviewer.")
    }

    /// A word a LATER build wrote is said as one this version cannot read —
    /// never guessed at a rung, because the guess would be read as a fact about
    /// somebody's access.
    func test_anUnreadablePermitIsNotGuessedAtARung() {
        let sentence = TrustEventSentence.sentence(
            for: change(.roleChanged, to: .unjudgeable(raw: "curator"), from: .bookAuthor),
            labels: [root: "Denver"])
        XCTAssertTrue(sentence.contains("doesn’t recognise"), sentence)
        XCTAssertFalse(sentence.contains("reviewer"), sentence)
        XCTAssertFalse(sentence.contains("author"), sentence)
    }

    // MARK: - A subject whose record has not arrived (P3b Task 7)

    /// **A code with no explanation is a row that says nothing.** An event
    /// about somebody this book holds no record for draws as four characters,
    /// which is honest and useless: the writer cannot tell *a Mac I have never
    /// heard of* from *a record that is still syncing*, and the second is the
    /// ordinary case — a root admits somebody and their person record lands a
    /// minute after the event does.
    ///
    /// It is a clause BESIDE the sentence rather than inside it, because the
    /// sentence is shared with the phone and is pinned to the byte above; the
    /// row composes the two.
    func test_anEventAboutSomebodyWithNoRecordSaysTheRecordHasNotArrived() {
        let clause = TrustEventSentence.unknownSubject(
            for: event(.admitted, subject: phone, by: root), labels: [:])
        XCTAssertEqual(
            clause, "This Mac hasn\u{2019}t received their record yet.")
    }

    /// Both directions. A subject the event NAMES, or one the registry names,
    /// has arrived — there is nothing to explain.
    func test_aNamedSubjectGetsNoSuchClause() {
        XCTAssertNil(TrustEventSentence.unknownSubject(
            for: event(.admitted, subject: phone, label: "iPhone", by: root),
            labels: [:]))
        XCTAssertNil(TrustEventSentence.unknownSubject(
            for: event(.admitted, subject: phone, by: root),
            labels: [phone: "Sam"]))
        XCTAssertNil(TrustEventSentence.unknownSubject(
            for: event(.admitted, subject: phone, by: root, isMine: true),
            labels: [:]))
    }

    /// And the kinds that are ABOUT a book this device has no record for say
    /// nothing either: a claimant is another Mac's root by definition, and a
    /// join and an adoption are already about somebody outside this chain.
    /// Telling the writer their record has not arrived would be telling them
    /// to wait for something that is not coming.
    func test_aClaimantAJoinAndAnAdoptionExplainNothing() {
        for kind in [TrustEvent.Kind.anotherClaimant, .claimed, .adopted, .joined] {
            XCTAssertNil(
                TrustEventSentence.unknownSubject(
                    for: event(kind, subject: phone), labels: [:]),
                "\(kind)")
        }
    }

    /// The sentence itself is untouched by any of this.
    func test_theSentenceIsUnchangedForAnUnnamedSubject() {
        XCTAssertEqual(
            TrustEventSentence.sentence(
                for: event(.admitted, subject: phone, by: root), labels: [:]),
            "9C8B admitted by 4F2K.")
    }
}
