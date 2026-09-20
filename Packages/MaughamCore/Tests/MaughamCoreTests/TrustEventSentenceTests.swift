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

    /// The kind Task 4's admission path may later distinguish: a device let in
    /// under a label this Mac had already granted, with no sheet shown. The
    /// sentence exists so that when the heuristic lands it has words waiting.
    func test_aSilentAdmissionSaysItWasNotAsked() {
        XCTAssertEqual(
            TrustEventSentence.sentence(
                for: event(.silentlyAdmitted, subject: phone, label: "iPhone", by: root),
                labels: [root: "Denver"]),
            "iPhone admitted automatically by Denver.")
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
}
