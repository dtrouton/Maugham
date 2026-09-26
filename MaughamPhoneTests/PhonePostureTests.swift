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
        // Ruling W: a book author in a piece somebody else started that nobody
        // has claimed — a lock on the phone, which has no Edit Anyway.
        Row(name: "a book author, yielding to a piece's starter",
            posture: yieldingToItsStarter, offers: []),
    ]

    private static let yieldingToItsStarter = PostureDoor.posture(
        permit: LocalWritePermit(
            permit: .bookAuthor, actor: .author, documentClass: .piece("doc-sams"),
            unsettledStarter: .init(deviceId: "sams-mac", name: "Sam")),
        yieldingTo: "Sam")

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

    /// Ruling W: the starter's yield names her, says nothing was written, and
    /// says where the piece is settled — the phone has no *Edit Anyway*.
    func test_aRefusalInAPieceSomebodyElseStartedSaysToSettleItFromTheMac() {
        XCTAssertEqual(Self.yieldingToItsStarter.reason, .yieldingToItsStarter("Sam"))
        XCTAssertEqual(
            PhonePosture.refusal(.reject, under: Self.yieldingToItsStarter),
            "Sam started this piece and it isn\u{2019}t settled whose it is yet, "
                + "so nothing was written \u{2014} settle it from your Mac.")
    }

    // MARK: - The cache is per load, and a perform re-asks

    func test_theLoadAsksTheDoorOncePerPieceAndAPerformAsksAgain() async {
        var asked: [String] = []
        var answer = Self.posture(.bookAuthor, nil)
        let cache = PhonePosture(
            prepare: { _ in },
            ask: { docId, _, _ in
                asked.append(docId)
                return answer
            })
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

    private struct WriteFailed: Error {}

    /// **The fresh answer reaches the view even when the write throws** (P3
    /// plan 3 Task 7). The re-ask before the write is what the view must draw
    /// from next; a write that throws must not leave the old answer drawn.
    /// Here the load drew every verb, the Mac made her a piece's starter since
    /// (her words move, a disposition waits), she pressed Reject and the write
    /// threw: Archive — which the fresh answer refuses — is no longer drawn.
    func test_aWriteThatThrowsStillHandsBackTheFreshAnswer() async {
        var answer = Self.posture(.bookAuthor, nil)
        let cache = PhonePosture(prepare: { _ in }, ask: { _, _, _ in answer })
        let url = URL(fileURLWithPath: "/tmp/book")
        var drawn = await cache.posture(forDocId: "doc-new", in: url)
        XCTAssertTrue(PhonePosture.openNoteVerbs(under: drawn).contains(.archive))

        answer = Self.posture(
            .author(.pieces([])), .piece("doc-new"), writesAsItsStarter: true)
        var wrote = false
        do {
            _ = try await cache.perform(
                .reject, forDocId: "doc-new", in: url,
                onAnswer: { drawn = $0 }
            ) {
                wrote = true
                throw WriteFailed()
            }
            XCTFail("the write threw")
        } catch {
            XCTAssertTrue(error is WriteFailed)
        }
        XCTAssertTrue(wrote, "the fresh answer offers Reject, so the write ran")
        XCTAssertEqual(PhonePosture.openNoteVerbs(under: drawn), [.accept, .reject],
                       "the verb the fresh answer refuses is no longer drawn")
    }

    /// **One warm-up in flight per project** (P3 plan 3 Task 7): two asks that
    /// arrive together await the same preparation rather than each resolving
    /// the register.
    func test_twoConcurrentAsksPrepareOnce() async {
        var prepares = 0
        let cache = PhonePosture(
            prepare: { _ in
                prepares += 1
                for _ in 0..<20 { await Task.yield() }
            },
            ask: { _, _, _ in Self.posture(.bookAuthor, nil) })
        let url = URL(fileURLWithPath: "/tmp/book")
        async let a = cache.askAgain(forDocId: "doc-a", in: url)
        async let b = cache.askAgain(forDocId: "doc-b", in: url)
        _ = await (a, b)
        XCTAssertEqual(prepares, 1, "two concurrent asks, one preparation")

        // Once it has landed, the next ask prepares again — the STORE decides
        // whether that costs anything (`prepareTrust` compares the signature).
        _ = await cache.askAgain(forDocId: "doc-a", in: url)
        XCTAssertEqual(prepares, 2)
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

    // MARK: - Ruling W: a piece somebody else started is locked on the phone

    /// The Mac-written narrowed book of Ruling U: Sam (both devices) an author
    /// of the second piece alone, and the first piece STARTED on Sam's Mac —
    /// her opening its only text, nobody's claim on it — holding Kim's note.
    private func samsUnclaimedPieceWithANote() throws -> Annotation {
        try book.writeRegister()
        for who in [book.samMac, book.samPhone] {
            try RegistryWriter.write(
                PermitEvent(
                    event: "\(who.fingerprint).01", kind: .admitted,
                    subject: who.fingerprint, role: Permit.authorRole,
                    scope: Permit.piecesScope, pieces: [Self.secondDoc], mark: [:],
                    at: Date(timeIntervalSince1970: 40), by: book.root.author.fingerprint),
                signedBy: book.root.author, in: book.projectURL)
        }
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(timeIntervalSince1970: 1), modified: Date(timeIntervalSince1970: 1),
            structure: [
                StructureItem(id: PhoneNarrowedBook.docId, title: "C1",
                              type: .document, path: "manuscript/c1.md",
                              startedBy: book.samMac.deviceId),
                StructureItem(id: Self.secondDoc, title: "C2",
                              type: .document, path: "manuscript/c2.md"),
            ],
            research: [])
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(
            to: book.projectURL.appendingPathComponent(ProjectManifest.fileName))

        let opening = Op(
            opId: "01SAMOPENING00000000000000", docId: PhoneNarrowedBook.docId,
            at: Date(timeIntervalSince1970: 90), device: book.samMac.deviceId,
            session: "s", kind: .typingBurst,
            changes: [.init(paragraphId: PhoneNarrowedBook.paragraphId, prior: nil,
                            next: PhoneNarrowedBook.paragraphText)],
            sequence: [PhoneNarrowedBook.paragraphId])
        let note = book.note("01KIMA", by: book.kim, kind: .claudeSuggestion,
                             next: "The sun sank over the harbour.")
        try book.writeFile(by: book.samMac, ops: [opening])
        try book.writeFile(by: book.kim, ops: [note])
        return try XCTUnwrap(AnnotationLoading.allAnnotations(
            ops: [opening, note], amendments: .honourEverything).first)
    }

    private var denversPhoneFile: URL {
        OpLogStore.opLogFileURL(
            forDocId: PhoneNarrowedBook.docId, deviceSlug: book.denverPhone.slug,
            in: book.projectURL)
    }

    /// **The root's phone in a piece Sam started that nobody has claimed**
    /// (Ruling W). Accept, Reject and Reopen & Revert write manuscript-text
    /// lines, and one from a book author there claims the piece and sets
    /// Sam's words aside on every Mac — so the phone draws none of them, a
    /// forced press writes nothing and says why, and the note can still be
    /// settled once the root answers *Theirs* on a Mac.
    func test_aBookAuthorsPhoneOffersNoDispositionInAPieceSomebodyElseStarted()
        async throws
    {
        let note = try samsUnclaimedPieceWithANote()
        let url = book.projectURL
        let load = countingLoad(book.denverPhone, Counts())

        let locked = await load.posture(forDocId: PhoneNarrowedBook.docId, in: url)
        XCTAssertEqual(locked.reason, .yieldingToItsStarter("Sam"))
        XCTAssertEqual(PhonePosture.openNoteVerbs(under: locked), [])
        XCTAssertNil(PhonePosture.reopenVerb(for: .accepted, under: locked),
                     "no Reopen & Revert")
        XCTAssertTrue(PhonePosture.offersCapture(under: locked))
        XCTAssertTrue(locked.allows(.annotate), "notes are everybody's")
        // Her other piece — not started by anybody else — is the book's as today.
        let unstarted = await load.posture(forDocId: Self.secondDoc, in: url)
        XCTAssertEqual(verbs(unstarted), Set(PhonePosture.Verb.allCases))

        // A press that got past the drawn verbs (drawn before the manifest
        // synced): refused, said, and nothing written.
        let writer = AnnotationWriter(
            projectRoot: url, docId: PhoneNarrowedBook.docId,
            identity: book.denverPhone, appVersion: "0.1.0", osVersion: "iOS 27")
        for verb in [PhonePosture.Verb.reject, .accept] {
            var wrote = false
            let outcome = try await load.perform(
                verb, forDocId: PhoneNarrowedBook.docId, in: url
            ) {
                wrote = true
                try await writer.reject(note, reason: "Not this one.")
            }
            XCTAssertFalse(wrote, "\(verb)")
            XCTAssertEqual(outcome.posture.reason, .yieldingToItsStarter("Sam"))
            XCTAssertTrue(
                outcome.refusal?.contains("settle it from your Mac") == true,
                outcome.refusal ?? "no refusal")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: denversPhoneFile.path),
                       "the phone wrote no line")

        // The root answers Theirs on a Mac: the piece joins Sam's scope, and
        // the phone offers the note's verbs again.
        for who in [book.samMac, book.samPhone] {
            try RegistryWriter.write(
                PermitEvent(
                    event: "\(who.fingerprint).02", kind: .scopeChanged,
                    subject: who.fingerprint, role: Permit.authorRole,
                    scope: Permit.piecesScope,
                    pieces: [Self.secondDoc, PhoneNarrowedBook.docId], mark: [:],
                    at: Date(timeIntervalSince1970: 60), by: book.root.author.fingerprint),
                signedBy: book.root.author, in: url)
        }
        load.refresh()
        let settled = await load.posture(forDocId: PhoneNarrowedBook.docId, in: url)
        XCTAssertNil(settled.reason)
        XCTAssertEqual(verbs(settled), Set(PhonePosture.Verb.allCases))
        let outcome = try await load.perform(
            .reject, forDocId: PhoneNarrowedBook.docId, in: url
        ) {
            try await writer.reject(note, reason: "Not this one.")
        }
        XCTAssertNil(outcome.refusal)
        XCTAssertTrue(FileManager.default.fileExists(atPath: denversPhoneFile.path),
                      "after Theirs the reject is written")
    }

    /// A counting load over one device's own store: how many stores it made
    /// and how many times it prepared a table.
    private final class Counts {
        var stores = 0
        var prepares = 0
    }

    private func countingLoad(_ who: DeviceIdentity, _ counts: Counts) -> PhonePosture {
        let book = self.book!
        return PhonePosture(
            makeStore: { _ in
                counts.stores += 1
                return book.store(for: .forAuthor(who), "phone-\(who.fingerprint.prefix(8))")
            },
            prepare: { store in
                // What the store actually RESOLVED, not how often it was asked:
                // `prepareTrust` compares the registry signature itself, so an
                // ask over an unchanged register resolves nothing.
                let before = store.trustResolutionCount
                await store.prepareTrust()
                counts.prepares += store.trustResolutionCount - before
            })
    }

    /// **One table per load** (fix round 1): N asks across M documents in one
    /// project make one store and prepare its table once; a re-ask over an
    /// unchanged register prepares nothing; a permit change that landed since
    /// the load moves the registry signature, so the re-ask before a write
    /// prepares again and SEES it; and a foreground refresh prepares again
    /// whatever the signature says.
    func test_oneLoadPreparesTheTableOnceAndAgainOnlyWhenTheRegisterMoves() async throws {
        try book.writeRegister()
        let counts = Counts()
        let load = countingLoad(book.samPhone, counts)
        let url = book.projectURL

        for _ in 0..<3 {
            for docId in [PhoneNarrowedBook.docId, Self.secondDoc] {
                let answer = await load.posture(forDocId: docId, in: url)
                XCTAssertEqual(verbs(answer), Set(PhonePosture.Verb.allCases))
            }
        }
        _ = await load.askAgain(forDocId: PhoneNarrowedBook.docId, in: url)
        _ = await load.askAgain(forDocId: Self.secondDoc, in: url)
        XCTAssertEqual(counts.stores, 1, "one store per project for the load")
        XCTAssertEqual(counts.prepares, 1, "six asks and two re-asks, one table")

        // The root narrows Sam while the note sits open. The re-ask before a
        // write sees it.
        try book.narrow()
        let now = await load.askAgain(forDocId: PhoneNarrowedBook.docId, in: url)
        XCTAssertEqual(verbs(now), [], "the narrowing that landed since the load is seen")
        XCTAssertEqual(counts.prepares, 2, "the signature moved, so the table was prepared again")
        XCTAssertEqual(counts.stores, 1)

        // A foreground return refreshes: prepared again, still one store.
        load.refresh()
        _ = await load.posture(forDocId: Self.secondDoc, in: url)
        _ = await load.posture(forDocId: PhoneNarrowedBook.docId, in: url)
        XCTAssertEqual(counts.prepares, 3)
        XCTAssertEqual(counts.stores, 1)
    }

    /// **A promotion shows on the next ask** after a foreground refresh (or a
    /// new load), on the same load's one store.
    func test_aPromotionMadeOnTheMacShowsAfterARefresh() async throws {
        try book.writeRegister()
        try book.narrow()
        let url = book.projectURL
        let load = countingLoad(book.samPhone, Counts())
        let before = await load.posture(forDocId: PhoneNarrowedBook.docId, in: url)
        XCTAssertEqual(verbs(before), [])

        // The root promotes Sam to an author of the whole book.
        try RegistryWriter.write(
            PermitEvent(
                event: "\(book.samPhone.fingerprint).02", kind: .roleChanged,
                subject: book.samPhone.fingerprint, role: Permit.authorRole,
                scope: Permit.bookScope, pieces: [], mark: [:],
                at: Date(timeIntervalSince1970: 60), by: book.root.author.fingerprint),
            signedBy: book.root.author, in: url)

        load.refresh()
        let after = await load.posture(forDocId: PhoneNarrowedBook.docId, in: url)
        XCTAssertEqual(verbs(after), Set(PhonePosture.Verb.allCases))
    }
}
