import XCTest
import SwiftUI
@testable import MaughamCore
@testable import MaughamPhone

/// **Settings says who this phone is in each book, and what it may write
/// there** (signed op log P3c plan 2, Task 6). The row's sentences are
/// `DeviceStanding`'s and `PermitWords`' (the words People & Devices draws on
/// the Mac, tripwire 19), resolved off the reconciled register
/// (`TrustResolution.resolveVerified`) from a real book on disk.
@MainActor
final class BookStandingRowTests: XCTestCase {

    private var book: PhoneNarrowedBook!

    override func setUp() async throws {
        book = try PhoneNarrowedBook()
    }

    override func tearDown() async throws {
        book?.remove()
        book = nil
    }

    private var structure: [StructureItem] {
        [StructureItem(id: PhoneNarrowedBook.docId, title: "C1",
                       type: .document, path: "manuscript/c1.md")]
    }

    private func cache(for who: DeviceIdentity) -> RegistryCache {
        RegistryCache(
            fileURL: book.scratchURL.appendingPathComponent(
                "settings-\(who.fingerprint.prefix(8)).json"),
            identity: who.fingerprint)
    }

    private func row(_ who: DeviceIdentity, cache: RegistryCache? = nil) -> BookStandingRow {
        let standing = BookStandingRow.standing(
            in: book.projectURL, mine: .forAuthor(who), cache: cache ?? self.cache(for: who))
        return BookStandingRow.make(title: "T", structure: structure, standing: standing)
    }

    private func event(
        _ who: DeviceIdentity, _ n: String, kind: PermitEvent.Kind = .admitted,
        role: String, scope: String, pieces: [String] = [], at: TimeInterval = 40
    ) throws {
        try RegistryWriter.write(
            PermitEvent(
                event: "\(who.fingerprint).\(n)", kind: kind,
                subject: who.fingerprint, role: role, scope: scope, pieces: pieces,
                mark: [:], at: Date(timeIntervalSince1970: at),
                by: book.root.author.fingerprint),
            signedBy: book.root.author, in: book.projectURL)
    }

    // MARK: - No register: exactly as today

    func test_aBookWithNoRegisterShowsNoRoleLine() {
        let row = row(book.samPhone)
        XCTAssertNil(row.permitLine)
        XCTAssertEqual(row.sentence, "Not yet admitted — the Mac will ask")
    }

    // MARK: - The role line

    func test_anAdmittedPhoneInABookNobodyIsNarrowedInIsAnAuthorOfTheWholeBook() throws {
        try book.writeRegister()
        let row = row(book.denverPhone)
        XCTAssertEqual(row.permitLine, Permit.Rung.wholeBook.title)
        XCTAssertTrue(row.sentence.hasPrefix("In this book as Denver"), row.sentence)
    }

    func test_aReviewerIsToldSoInThePeopleAndDevicesWords() throws {
        try book.writeRegister()
        try book.narrow()
        XCTAssertEqual(row(book.samPhone).permitLine,
                       PermitWords.sentence(rung: .reviewer, pieceTitles: []))
    }

    func test_anAuthorOfSomePiecesIsToldWhichByTitle() throws {
        try book.writeRegister()
        try event(book.kim, "01", role: Permit.authorRole, scope: Permit.piecesScope,
                  pieces: [PhoneNarrowedBook.docId, "doc-00000000"])
        XCTAssertEqual(
            row(book.kim).permitLine,
            PermitWords.sentence(
                rung: .somePieces,
                pieceTitles: ["C1", BookStandingRow.unknownPiece]),
            "binder titles, and a piece this manifest does not carry named as such")
    }

    /// **A promotion shows on the next read** — the role line is resolved
    /// fresh, not remembered.
    func test_aPromotionMadeOnTheMacShowsOnTheNextRead() throws {
        try book.writeRegister()
        try book.narrow()
        let samCache = cache(for: book.samPhone)
        XCTAssertEqual(row(book.samPhone, cache: samCache).permitLine,
                       Permit.Rung.reviewer.title)

        try event(book.samPhone, "02", kind: .roleChanged,
                  role: Permit.authorRole, scope: Permit.bookScope, at: 60)
        XCTAssertEqual(row(book.samPhone, cache: samCache).permitLine,
                       Permit.Rung.wholeBook.title)
    }

    // MARK: - Resolved off the reconciled register

    /// **Why `resolveVerified` and not a raw folder read.** A register
    /// something deleted is restored from this phone's memory rather than
    /// read as *never was* — so a phone admitted yesterday is not told today
    /// that it is waiting to be admitted.
    func test_aDeletedRegisterIsReadFromThisPhonesMemoryNotAsNeverWas() throws {
        try book.writeRegister()
        let denverCache = cache(for: book.denverPhone)
        XCTAssertNotNil(row(book.denverPhone, cache: denverCache).permitLine)

        for dir in [RegistryDirectory.devices, .people] {
            try FileManager.default.removeItem(
                at: RegistryWriter.directoryURL(dir, in: book.projectURL))
        }
        let after = row(book.denverPhone, cache: denverCache)
        XCTAssertTrue(after.sentence.hasPrefix("In this book as Denver"), after.sentence)
        XCTAssertEqual(after.permitLine, Permit.Rung.wholeBook.title)
    }

    // MARK: - When Settings reads again (C5)

    func test_settingsRereadsWhenTheAppComesBackToTheFront() {
        XCTAssertTrue(BookStandingRow.rereads(on: .active))
        XCTAssertFalse(BookStandingRow.rereads(on: .inactive))
        XCTAssertFalse(BookStandingRow.rereads(on: .background))
    }
}
