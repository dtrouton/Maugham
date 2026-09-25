import XCTest
import SwiftUI
@testable import MaughamCore
@testable import MaughamPhone

/// **What the phone offers, decided on a value** (signed op log P3c plan 2,
/// Task 6). Every verb the detail view can draw is asked of
/// `PhonePosture.offers`, a pure function over a `Posture`, so the whole
/// decision is pinned here without a window (tripwire 33); the view only
/// draws what these answer.
///
/// Both directions in one table: a row names the phone verbs a posture
/// offers, and every verb not named is asserted refused — a disposition
/// wrongly shown and one wrongly hidden fail the same cell.
@MainActor
final class PhonePostureTests: XCTestCase {

    private typealias V = PhonePosture.Verb

    private static func posture(
        _ permit: Permit, _ cls: DocumentClass?, actor: DeviceActor = .author,
        writesAsItsStarter: Bool = false
    ) -> Posture {
        Posture(LocalWritePermit(
            permit: permit, actor: actor, documentClass: cls,
            writesAsItsStarter: writesAsItsStarter))
    }

    private struct Row {
        let name: String
        let posture: Posture
        let offers: Set<V>
    }

    private static let every = Set(V.allCases)

    private static let rows: [Row] = [
        Row(name: "the writer's own hand, every book before P3",
            posture: posture(.bookAuthor, nil), offers: every),
        Row(name: "a reviewer",
            posture: posture(.reviewer, .piece("doc-a")), offers: []),
        Row(name: "an author of some pieces, in hers",
            posture: posture(.author(.pieces(["doc-a"])), .piece("doc-a")),
            offers: every),
        Row(name: "an author of some pieces, in somebody else's",
            posture: posture(.author(.pieces(["doc-a"])), .piece("doc-b")),
            offers: []),
        Row(name: "a permit this build cannot read",
            posture: posture(.unjudgeable(raw: "editor"), .piece("doc-a")),
            offers: []),
        // Option A: her started piece nobody has claimed — her words move, but
        // a disposition waits for the root (controller ruling F).
        Row(name: "an author of some pieces, in a piece she started",
            posture: posture(
                .author(.pieces([])), .piece("doc-new"), writesAsItsStarter: true),
            offers: [.accept, .reject, .reopenAndRevert]),
        Row(name: "not yet answered",
            posture: PhonePosture.unanswered, offers: []),
    ]

    // MARK: - Verbs

    func test_everyVerbIsOfferedExactlyWhereThePostureAllowsIt() {
        for row in Self.rows {
            for verb in V.allCases {
                XCTAssertEqual(
                    PhonePosture.offers(verb, under: row.posture),
                    row.offers.contains(verb),
                    "\(row.name): \(verb)")
            }
        }
    }

    /// The verb → surface-verb map, spelled out: Accept, Reject and Reopen &
    /// Revert move the words; Archive and Reopen settle a note (Ruling A: the
    /// phone's Reopen is `.dispose` alone).
    func test_eachPhoneVerbIsAskedAsTheLineItWouldWrite() {
        XCTAssertEqual(PhonePosture.postureVerb(.accept), .acceptOrReject)
        XCTAssertEqual(PhonePosture.postureVerb(.reject), .acceptOrReject)
        XCTAssertEqual(PhonePosture.postureVerb(.reopenAndRevert), .acceptOrReject)
        XCTAssertEqual(PhonePosture.postureVerb(.archive), .dispose)
        XCTAssertEqual(PhonePosture.postureVerb(.reopen), .dispose)
    }

    /// **A reviewer sees no disposition and can still capture** — the brief's
    /// first direction, and the one the disable experiment reddens.
    func test_aReviewerSeesNoDispositionAndCanStillCapture() {
        let reviewer = Self.posture(.reviewer, .piece("doc-a"))
        XCTAssertEqual(PhonePosture.openNoteVerbs(under: reviewer), [])
        for status in AnnotationStatus.allCases {
            XCTAssertNil(PhonePosture.reopenVerb(for: status, under: reviewer),
                "a reviewer's phone offers no reopen of a \(status) note")
        }
        XCTAssertTrue(PhonePosture.offersCapture(under: reviewer))
    }

    /// Capture is on every rung, whatever the posture — including one the
    /// door has not answered yet.
    func test_captureIsOfferedUnderEveryPosture() {
        for row in Self.rows {
            XCTAssertTrue(PhonePosture.offersCapture(under: row.posture), row.name)
        }
    }

    func test_theOpenNoteVerbsKeepTheirOrderAndDropOnlyWhatIsRefused() {
        let author = Self.posture(.bookAuthor, nil)
        XCTAssertEqual(PhonePosture.openNoteVerbs(under: author),
                       [.accept, .reject, .archive])
        let started = Self.posture(
            .author(.pieces([])), .piece("doc-new"), writesAsItsStarter: true)
        XCTAssertEqual(PhonePosture.openNoteVerbs(under: started),
                       [.accept, .reject])
    }

    func test_theReopenFollowsTheStatusAndThePosture() {
        let author = Self.posture(.bookAuthor, nil)
        XCTAssertEqual(PhonePosture.reopenVerb(for: .rejected, under: author), .reopen)
        XCTAssertEqual(PhonePosture.reopenVerb(for: .archived, under: author), .reopen)
        XCTAssertEqual(PhonePosture.reopenVerb(for: .stetted, under: author), .reopen)
        XCTAssertEqual(PhonePosture.reopenVerb(for: .accepted, under: author),
                       .reopenAndRevert)
        XCTAssertNil(PhonePosture.reopenVerb(for: .open, under: author))

        // Her started piece: the words are hers (Reopen & Revert), a
        // disposition is not yet (Reopen).
        let started = Self.posture(
            .author(.pieces([])), .piece("doc-new"), writesAsItsStarter: true)
        XCTAssertNil(PhonePosture.reopenVerb(for: .archived, under: started))
        XCTAssertEqual(PhonePosture.reopenVerb(for: .accepted, under: started),
                       .reopenAndRevert)
    }

    // MARK: - A refusal is said

    func test_aRefusalNamesWhyAndSaysNothingWasWritten() {
        let cases: [(Posture, String)] = [
            (Self.posture(.reviewer, .piece("doc-a")), "leave notes"),
            (Self.posture(.author(.pieces(["doc-a"])), .piece("doc-b")),
             "isn\u{2019}t one of yours"),
            (Self.posture(.unjudgeable(raw: "editor"), .piece("doc-a")),
             "doesn\u{2019}t recognise"),
            (PhonePosture.unanswered, "still being read"),
        ]
        for (posture, why) in cases {
            let sentence = PhonePosture.refusal(.archive, under: posture)
            XCTAssertTrue(sentence.contains(why), sentence)
            XCTAssertTrue(sentence.hasSuffix("so nothing was written."), sentence)
        }
    }

    // MARK: - The cache is per load, and a perform re-asks

    func test_theLoadAsksTheDoorOncePerPieceAndAPerformAsksAgain() async {
        var asked: [String] = []
        var answer = Self.posture(.bookAuthor, nil)
        let cache = PhonePosture { docId, _ in
            asked.append(docId)
            return answer
        }
        let url = URL(fileURLWithPath: "/tmp/book")

        let first = await cache.posture(forDocId: "doc-a", in: url)
        _ = await cache.posture(forDocId: "doc-a", in: url)
        _ = await cache.posture(forDocId: "doc-b", in: url)
        XCTAssertEqual(asked, ["doc-a", "doc-b"], "one ask per piece per load")
        XCTAssertTrue(PhonePosture.offers(.archive, under: first))

        // The Mac narrows her while the note sits open: the re-ask sees it,
        // and the cache takes the new answer.
        answer = Self.posture(.reviewer, .piece("doc-a"))
        let now = await cache.askAgain(forDocId: "doc-a", in: url)
        XCTAssertEqual(asked, ["doc-a", "doc-b", "doc-a"], "a perform always asks")
        XCTAssertFalse(PhonePosture.offers(.archive, under: now))
        let cached = await cache.posture(forDocId: "doc-a", in: url)
        XCTAssertFalse(PhonePosture.offers(.archive, under: cached))
    }
}

/// **The phone's posture off a real book, held against the Mac's** (spec §12's
/// round trips; P3c plan 2, Task 6). A book the root Mac narrowed, read by the
/// production `PhonePosture.settled` over each device's own store — and the
/// same question asked on a Mac through Core's `PostureDoor`, so the two
/// surfaces are held to one answer.
@MainActor
final class PhonePostureRoundTripTests: XCTestCase {

    private var book: PhoneNarrowedBook!
    private static let secondDoc = "doc-5c2d9e1b"

    override func setUp() async throws {
        book = try PhoneNarrowedBook()
        // A second piece, so an author of some pieces has one that is not hers.
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(timeIntervalSince1970: 1), modified: Date(timeIntervalSince1970: 1),
            structure: [
                StructureItem(id: PhoneNarrowedBook.docId, title: "C1",
                              type: .document, path: "manuscript/c1.md"),
                StructureItem(id: Self.secondDoc, title: "C2",
                              type: .document, path: "manuscript/c2.md"),
            ],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: book.projectURL.appendingPathComponent(ProjectManifest.fileName))
    }

    override func tearDown() async throws {
        book?.remove()
        book = nil
    }

    /// Kim narrowed to an author of C1 alone (in place of `narrow()`'s
    /// reviewer), and Sam to a reviewer.
    private func narrowKimToC1() throws {
        try RegistryWriter.write(
            PermitEvent(
                event: "\(book.kim.fingerprint).01", kind: .admitted,
                subject: book.kim.fingerprint, role: Permit.authorRole,
                scope: Permit.piecesScope, pieces: [PhoneNarrowedBook.docId], mark: [:],
                at: Date(timeIntervalSince1970: 40), by: book.root.author.fingerprint),
            signedBy: book.root.author, in: book.projectURL)
        for who in [book.samMac, book.samPhone] {
            try RegistryWriter.write(
                PermitEvent(
                    event: "\(who.fingerprint).01", kind: .admitted,
                    subject: who.fingerprint, role: Permit.reviewerRole,
                    scope: Permit.bookScope, pieces: [], mark: [:],
                    at: Date(timeIntervalSince1970: 40), by: book.root.author.fingerprint),
                signedBy: book.root.author, in: book.projectURL)
        }
    }

    private func phone(_ who: DeviceIdentity, _ docId: String) async -> Posture {
        await PhonePosture.settled(
            forDocId: docId, in: book.projectURL,
            using: book.store(for: .forAuthor(who), "phone-\(who.fingerprint.prefix(8))"))
    }

    private func mac(_ who: DeviceIdentity, _ docId: String) async -> Posture {
        let store = book.store(for: .forAuthor(who), "mac-\(who.fingerprint.prefix(8))")
        await store.prepareTrust()
        return PostureDoor.posture(forDocId: docId, in: book.projectURL, using: store)
    }

    private func verbs(_ posture: Posture) -> Set<PhonePosture.Verb> {
        Set(PhonePosture.Verb.allCases.filter { PhonePosture.offers($0, under: posture) })
    }

    /// **A Mac-narrowed reviewer book read on the phone shows no dispositions**
    /// — and the Mac, asked the same question for the same person, agrees.
    func test_aReviewerPhoneInAMacNarrowedBookOffersNoDisposition() async throws {
        try book.writeRegister()
        try book.narrow()

        let samsPhone = await phone(book.samPhone, PhoneNarrowedBook.docId)
        XCTAssertEqual(verbs(samsPhone), [])
        XCTAssertTrue(PhonePosture.offersCapture(under: samsPhone))
        XCTAssertEqual(samsPhone.reason, .reviewer)

        let samsMac = await mac(book.samMac, PhoneNarrowedBook.docId)
        XCTAssertEqual(verbs(samsMac), verbs(samsPhone), "the two surfaces agree")

        // Denver's own phone, an author of the whole book, is untouched.
        let denversPhone = await phone(book.denverPhone, PhoneNarrowedBook.docId)
        XCTAssertEqual(verbs(denversPhone), Set(PhonePosture.Verb.allCases))
    }

    /// **A pieces-author book shows dispositions on her pieces only**, on the
    /// phone as on the Mac.
    func test_anAuthorOfSomePiecesSeesVerbsOnHerPiecesOnly() async throws {
        try book.writeRegister()
        try narrowKimToC1()

        let hers = await phone(book.kim, PhoneNarrowedBook.docId)
        XCTAssertEqual(verbs(hers), Set(PhonePosture.Verb.allCases))
        let notHers = await phone(book.kim, Self.secondDoc)
        XCTAssertEqual(verbs(notHers), [])
        XCTAssertEqual(notHers.reason, .notYourPiece)
        XCTAssertTrue(PhonePosture.offersCapture(under: notHers))

        let macHers = await mac(book.kim, PhoneNarrowedBook.docId)
        let macNotHers = await mac(book.kim, Self.secondDoc)
        XCTAssertEqual(verbs(macHers), verbs(hers))
        XCTAssertEqual(verbs(macNotHers), verbs(notHers))
    }

    /// **Behaviour-neutral**: a register that narrows nobody, and a book with
    /// no register at all, offer every verb exactly as today.
    func test_aBookThatNarrowsNobodyOffersEveryVerbAsToday() async throws {
        let bare = await phone(book.samPhone, PhoneNarrowedBook.docId)
        XCTAssertEqual(verbs(bare), Set(PhonePosture.Verb.allCases), "no register")

        try book.writeRegister()
        let registered = await phone(book.samPhone, PhoneNarrowedBook.docId)
        XCTAssertEqual(verbs(registered), Set(PhonePosture.Verb.allCases),
                       "a register nobody is narrowed in")
    }

    /// **A promotion shows on the next ask** — the cache is per load, and a
    /// new load (a pull, a foreground) asks the door again.
    func test_aPromotionMadeOnTheMacShowsOnTheNextLoad() async throws {
        try book.writeRegister()
        try book.narrow()
        let store = book.store(for: .forAuthor(book.samPhone), "phone-sam")
        let url = book.projectURL
        let load1 = PhonePosture { docId, projectURL in
            await PhonePosture.settled(forDocId: docId, in: projectURL, using: store)
        }
        let before = await load1.posture(forDocId: PhoneNarrowedBook.docId, in: url)
        XCTAssertEqual(verbs(before), [])

        // The root promotes Sam to an author of the whole book.
        try RegistryWriter.write(
            PermitEvent(
                event: "\(book.samPhone.fingerprint).02", kind: .roleChanged,
                subject: book.samPhone.fingerprint, role: Permit.authorRole,
                scope: Permit.bookScope, pieces: [], mark: [:],
                at: Date(timeIntervalSince1970: 60), by: book.root.author.fingerprint),
            signedBy: book.root.author, in: url)
        store.invalidateTrust()

        let load2 = PhonePosture { docId, projectURL in
            await PhonePosture.settled(forDocId: docId, in: projectURL, using: store)
        }
        let after = await load2.posture(forDocId: PhoneNarrowedBook.docId, in: url)
        XCTAssertEqual(verbs(after), Set(PhonePosture.Verb.allCases))
    }
}
