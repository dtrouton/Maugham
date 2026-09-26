import Foundation
import XCTest
@testable import MaughamCore

/// **The one classification of a held line, and the sentence each holder gets**
/// (P3b Task 2, widened by Task 7's finding B).
///
/// `HeldLines` had no test file of its own while its only exercise was through
/// the unsigned door; Task 7 gives `.permitPending` a second arm and every
/// surface in the app a sentence off this type, so the vocabulary is pinned
/// here rather than in whichever surface happens to draw it.
final class HeldLinesTests: XCTestCase {

    private var root: LocalIdentities!
    private var sam: LocalIdentities!
    private var projectURL: URL!

    override func setUp() async throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("held-lines-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectURL, withIntermediateDirectories: true)
        root = .softwareForTesting()
        sam = .softwareForTesting()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: projectURL)
    }

    /// A registry in which `sam` is admitted and `stranger` is not.
    private func registry() throws -> Registry {
        try RegistryWriter.write(
            PersonRecord(
                person: root.author.fingerprint, label: "Denver",
                ownName: "Denver’s MacBook",
                admittedAt: Date(timeIntervalSince1970: 10),
                admittedBy: root.author.fingerprint),
            signedBy: root.author, in: projectURL)
        try RegistryWriter.write(
            PersonRecord(
                person: sam.author.fingerprint, label: "Sam", ownName: "Sam’s Mac",
                admittedAt: Date(timeIntervalSince1970: 20),
                admittedBy: root.author.fingerprint),
            signedBy: root.author, in: projectURL)
        return try RegistryReader.load(projectURL: projectURL)
    }

    // MARK: - The classifier

    /// The flag never turns one holder into another. It is carried BESIDE the
    /// classification, for the sentence, and the three arms are still decided
    /// by the string and the registry alone.
    func test_theStartedAPieceFlagNeverChangesWhoAHolderIs() throws {
        let book = try registry()
        let stranger = String(repeating: "a", count: 64)
        let unsigned = HeldLines.unsignedHolder(
            forStreamKey: "ops/doc-1", deviceSlug: "author-beef")

        XCTAssertEqual(
            HeldLines.holder(of: stranger, registry: book, startedAPiece: true),
            .stranger(fingerprint: stranger))
        XCTAssertEqual(
            HeldLines.holder(of: unsigned, registry: book, startedAPiece: true),
            .unsigned(stream: "author-beef"))
    }

    /// The one arm it does change, and both of its values.
    func test_anAdmittedPersonsHolderCarriesWhetherSheStartedAPiece() throws {
        let book = try registry()
        XCTAssertEqual(
            HeldLines.holder(of: sam.author.fingerprint, registry: book),
            .permitPending(person: sam.author.fingerprint, startedAPiece: false),
            "the default is the P3a answer")
        XCTAssertEqual(
            HeldLines.holder(
                of: sam.author.fingerprint, registry: book, startedAPiece: true),
            .permitPending(person: sam.author.fingerprint, startedAPiece: true))
    }

    // MARK: - The sentences

    /// **Neither permit-pending sentence is an admission sentence**, and that
    /// is the whole reason this type exists: she is already in the book, and
    /// telling the writer to admit her would offer a control that changes
    /// nothing.
    func test_noPermitPendingSentenceAsksForAnAdmission() {
        for started in [true, false] {
            let sentence = HeldLines.sentence(
                .permitPending(person: "who", startedAPiece: started),
                notes: 3, named: "Sam")
            XCTAssertNotNil(sentence)
            XCTAssertFalse(
                sentence!.localizedCaseInsensitiveContains("admission"),
                "startedAPiece: \(started) — \(sentence!)")
            XCTAssertFalse(
                sentence!.localizedCaseInsensitiveContains("admit"),
                "startedAPiece: \(started) — \(sentence!)")
        }
    }

    /// A piece start says what is actually true — nobody has claimed the piece
    /// — and points at the one surface that can answer it. It must NOT say
    /// what the other arm says, because a newer build would not help: this
    /// build understands the line perfectly well.
    func test_aPieceStartSaysNobodyHasClaimedItAndNotThatABuildIsTooOld() throws {
        let sentence = try XCTUnwrap(HeldLines.sentence(
            .permitPending(person: "who", startedAPiece: true),
            notes: 2, named: "Sam"))
        XCTAssertTrue(sentence.contains("Sam"))
        XCTAssertTrue(sentence.contains("2 notes"))
        XCTAssertTrue(sentence.localizedCaseInsensitiveContains("nobody has claimed"))
        XCTAssertTrue(sentence.localizedCaseInsensitiveContains("People & Devices"))
        XCTAssertFalse(
            sentence.localizedCaseInsensitiveContains("newer"),
            "this build reads the line fine — it is the PIECE that is unclaimed")
    }

    /// And the P3a arm keeps its own words, unchanged.
    func test_anUnjudgeableLineStillSaysANewerBuildWillKnow() throws {
        let sentence = try XCTUnwrap(HeldLines.sentence(
            .permitPending(person: "who", startedAPiece: false),
            notes: 1, named: "Sam"))
        XCTAssertTrue(sentence.localizedCaseInsensitiveContains("newer"))
        XCTAssertFalse(sentence.localizedCaseInsensitiveContains("nobody has claimed"))
        XCTAssertTrue(sentence.contains("1 note "), sentence)
    }

    /// The unsigned arm points at the Inbox and names nobody, because there is
    /// nobody to name.
    func test_theUnsignedSentencePointsAtTheInboxAndNamesNobody() throws {
        let sentence = try XCTUnwrap(HeldLines.sentence(
            .unsigned(stream: "author-beef"), notes: 4))
        XCTAssertTrue(sentence.localizedCaseInsensitiveContains("Inbox"))
        // What it must never be is the admission SENTENCE.
        XCTAssertFalse(
            sentence.localizedCaseInsensitiveContains("waiting for admission"))
    }

    /// **The pre-first-seal stranger** (P3c Task 7, carry M2). An unsigned
    /// stream is two cases this Mac cannot tell apart — a Mac that signs
    /// nothing it will ever write, and a signing Mac whose first seal has not
    /// synced here yet — so neither the held sentence nor History's dated
    /// entry may say *there is no device to admit* or *signs nothing it
    /// writes* as a fact. Both say what the two cases share and what each is
    /// waiting for, as People & Devices' unsigned row already does.
    func test_theUnsignedWordsAreTrueOfAMacWhoseFirstSealHasNotSynced() throws {
        let entry = TrustEventSentence.sentence(
            for: TrustEvent(
                date: Date(timeIntervalSince1970: 0), kind: .unsigned,
                subject: HeldLines.unsignedHolder(
                    forStreamKey: "d.ghost", deviceSlug: "ghost")),
            labels: [:])
        let held = [
            HeldLines.sentence(.unsigned(stream: "ghost"), notes: 2),
            HeldLines.sentence(.unsigned(stream: "ghost"), notes: 1,
                               wayBackIn: .historysHeldRows),
        ].compactMap { $0 }
        XCTAssertEqual(held.count, 2)
        for sentence in held + [entry, HeldLines.unsignedWriter] {
            XCTAssertFalse(
                sentence.localizedCaseInsensitiveContains("no device to admit"),
                sentence)
            XCTAssertFalse(
                sentence.localizedCaseInsensitiveContains("signs nothing it writes"),
                sentence)
        }
        for sentence in held + [entry] {
            XCTAssertTrue(sentence.contains("sync"),
                          "the signing Mac's case is named: \(sentence)")
            XCTAssertTrue(sentence.contains("if it signs nothing"),
                          "…and so is the other one: \(sentence)")
        }
    }

    /// **Only paragraphs come back from a Mac that signs nothing** (Denver's
    /// I2 ruling, 2026-09-23; delivered in P3c plan 2's fix wave). §7.4's
    /// door captures a held span's paragraphs and nothing else, so a note
    /// from such a Mac is said to stay held with no way back — never counted
    /// into the Inbox's promise. Every shape, both surfaces.
    func test_theUnsignedSentencePromisesTheInboxForParagraphsOnly() {
        let prefix = "is waiting from \(HeldLines.unsignedWriter). If that Mac’s "
            + "first signed change just hasn’t synced here, this changes when it "
            + "does; if it signs nothing, "
        func say(
            _ what: HeldLines.Waiting?, notes: Int = 1,
            _ way: HeldLines.WayBackIn = .theInboxDoor
        ) -> String? {
            HeldLines.sentence(.unsigned(stream: "s"), notes: notes, what: what,
                               wayBackIn: way)
        }
        let oneParagraph = HeldLines.Waiting(paragraphIds: ["aaaa"], prose: 1)
        XCTAssertEqual(
            say(oneParagraph),
            "1 paragraph " + prefix + "its paragraph can be brought back through the Inbox.")
        let mixed = HeldLines.Waiting(paragraphIds: ["aaaa", "bbbb"], prose: 2, notes: 1)
        XCTAssertEqual(
            say(mixed, notes: 3),
            "2 paragraphs and 1 note are waiting from \(HeldLines.unsignedWriter). "
                + "If that Mac’s first signed change just hasn’t synced here, this "
                + "changes when it does; if it signs nothing, its paragraphs can be "
                + "brought back through the Inbox; its note stays held, with no way back.")
        XCTAssertEqual(
            say(HeldLines.Waiting(notes: 2), notes: 2),
            "2 notes are waiting from \(HeldLines.unsignedWriter). If that Mac’s "
                + "first signed change just hasn’t synced here, this changes when it "
                + "does; if it signs nothing, its notes stay held, with no way back "
                + "— only paragraphs come back, through the Inbox.")
        XCTAssertEqual(
            say(HeldLines.Waiting(paragraphIds: ["aaaa"], prose: 1, notes: 1, other: 1),
                notes: 3, .historysHeldRows),
            "1 paragraph, 1 note and 1 change are waiting from "
                + "\(HeldLines.unsignedWriter). If that Mac’s first signed change "
                + "just hasn’t synced here, this changes when it does; if it signs "
                + "nothing, its paragraph is brought back from History; its notes "
                + "and other changes stay held, with no way back.")
        // Changes alone — a task, or prose naming no paragraph — say no
        // *other* (N4), and a paragraph beside them does.
        XCTAssertEqual(
            say(HeldLines.Waiting(prose: 1, anonymousProse: 1, other: 1), notes: 2),
            "2 changes are waiting from \(HeldLines.unsignedWriter). If that Mac’s "
                + "first signed change just hasn’t synced here, this changes when it "
                + "does; if it signs nothing, its changes stay held, with no way back "
                + "— only paragraphs come back, through the Inbox.")
        XCTAssertEqual(
            say(HeldLines.Waiting(paragraphIds: ["aaaa"], prose: 1, other: 1), notes: 2),
            "1 paragraph and 1 change are waiting from \(HeldLines.unsignedWriter). "
                + "If that Mac’s first signed change just hasn’t synced here, this "
                + "changes when it does; if it signs nothing, its paragraph can be "
                + "brought back through the Inbox; its other change stays held, "
                + "with no way back.")
        // The capture stream holds no ops: the kinds are unknown, so both
        // halves are said.
        XCTAssertEqual(
            say(nil, notes: 2, .historysHeldRows),
            "2 notes are waiting from \(HeldLines.unsignedWriter). If that Mac’s "
                + "first signed change just hasn’t synced here, this changes when it "
                + "does; if it signs nothing, any paragraphs it wrote are brought "
                + "back from History; its notes stay held, with no way back.")
    }

    /// Nothing waiting is no sentence at all, in every arm — so no surface has
    /// to decide whether zero is worth saying.
    func test_nothingWaitingIsNoSentence() {
        XCTAssertNil(HeldLines.sentence(.stranger(fingerprint: "k"), notes: 0))
        XCTAssertNil(HeldLines.sentence(
            .permitPending(person: "p", startedAPiece: true), notes: 0))
        XCTAssertNil(HeldLines.sentence(
            .permitPending(person: "p", startedAPiece: false), notes: 0))
        XCTAssertNil(HeldLines.sentence(.unsigned(stream: "s"), notes: 0))
    }

    /// **A piece TAKEN from them is not a piece nobody has claimed** (Q1,
    /// ruled 2026-09-24): the sentence says she kept writing in it, and the
    /// flag reaches the piece-start arm alone.
    func test_aPieceTakenFromThemSaysSoAndNotThatNobodyClaimedIt() throws {
        let taken = try XCTUnwrap(HeldLines.sentence(
            .permitPending(person: "who", startedAPiece: true), notes: 1,
            named: "Sam", pieceWasTakenFromThem: true))
        XCTAssertTrue(taken.contains("taken from them"))
        XCTAssertFalse(taken.localizedCaseInsensitiveContains("nobody has claimed"))
        let unjudgeable = try XCTUnwrap(HeldLines.sentence(
            .permitPending(person: "who", startedAPiece: false), notes: 1,
            named: "Sam", pieceWasTakenFromThem: true))
        XCTAssertFalse(unjudgeable.contains("taken"), "not §4.5's line at all")
    }
}
