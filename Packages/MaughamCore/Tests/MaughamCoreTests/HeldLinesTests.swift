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
        // It DOES say the word *admit*, and only to rule it out — *there is no
        // device to admit*. What it must never be is the admission SENTENCE.
        XCTAssertFalse(
            sentence.localizedCaseInsensitiveContains("waiting for admission"))
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
}
