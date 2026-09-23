// MaughamTests/AdmissionWaitingTests.swift
import XCTest
@testable import MaughamCore
@testable import Maugham

/// **The admission sheet says who and what** (P3b smoke find F2), decided with
/// no window (tripwire 33).
///
/// On the smoke the sheet said *1 note waiting* about Kit's paragraph of prose,
/// with only a four-character code to go on.
final class AdmissionWaitingTests: XCTestCase {

    private let kit = "kitkey"
    private let order = [
        (id: "doc-1", title: "Chapter 1"), (id: "doc-2", title: "Chapter 2"),
        (id: "doc-3", title: "Chapter 3"), (id: "doc-4", title: "Chapter 4"),
        (id: "doc-5", title: "Chapter 5"),
    ]

    private func prose(_ paragraphs: Int, peek: String? = nil) -> HeldLines.Waiting {
        HeldLines.Waiting(
            paragraphIds: Set((0..<paragraphs).map { "p\($0)" }),
            prose: paragraphs, peek: peek)
    }

    private func describe(
        _ byDoc: [String: HeldLines.Waiting], captures: Int = 0
    ) -> AdmissionWaiting? {
        AdmissionWaiting.describe(
            holder: kit, waiting: [kit: byDoc], captures: [kit: captures], order: order)
    }

    // MARK: - The smoke's own case

    func test_kitsParagraphIsAParagraphInItsPieceWithAPeek() throws {
        let described = try XCTUnwrap(describe(
            ["doc-3": prose(1, peek: "The rain came in sideways.")]))

        XCTAssertEqual(described.line, "1 paragraph waiting in “Chapter 3”")
        XCTAssertEqual(described.peek, "“The rain came in sideways.”")
    }

    func test_notesAreNotesAndPiecesComeInBinderOrder() throws {
        let described = try XCTUnwrap(describe([
            "doc-2": HeldLines.Waiting(notes: 2),
            "doc-1": prose(1),
        ]))

        XCTAssertEqual(described.line,
                       "1 paragraph and 2 notes waiting in “Chapter 1” and “Chapter 2”")
        XCTAssertNil(described.peek, "no prose peek where the prose had no words")
    }

    func test_manyPiecesAreNamedThenCounted() throws {
        let described = try XCTUnwrap(describe([
            "doc-1": prose(1), "doc-2": prose(1), "doc-3": prose(1),
            "doc-4": prose(1), "doc-5": prose(1),
        ]))

        XCTAssertEqual(
            described.line,
            "5 paragraphs waiting in “Chapter 1”, “Chapter 2”, “Chapter 3” and 2 other pieces")
    }

    func test_aPieceTheBinderDoesNotNameIsUntitledAndComesLast() throws {
        let described = try XCTUnwrap(describe([
            "doc-zz": prose(1), "doc-1": prose(1),
        ]))
        XCTAssertEqual(described.line,
                       "2 paragraphs waiting in “Chapter 1” and an untitled piece")
    }

    func test_capturesAreCapturesInTheInbox() throws {
        XCTAssertEqual(describe([:], captures: 3)?.line, "3 captures waiting in the Inbox")
        XCTAssertEqual(
            describe(["doc-1": prose(2)], captures: 1)?.line,
            "2 paragraphs waiting in “Chapter 1”, and 1 capture in the Inbox")
    }

    func test_nothingDescribedIsNil_andTheSheetFallsBackToTheCount() {
        XCTAssertNil(describe([:]))
        let request = AdmissionRequest(
            fingerprint: kit, ownName: nil, code: "KIT1", waitingCount: 4,
            proposedLabel: "", knownLabels: [])
        XCTAssertEqual(AdmissionSheet.waitingLine(for: request), "4 notes waiting")
    }

    func test_theSheetSaysTheDescriptionWhereItHasOne() {
        var request = AdmissionRequest(
            fingerprint: kit, ownName: nil, code: "KIT1", waitingCount: 1,
            proposedLabel: "", knownLabels: [])
        request.described = describe(["doc-3": prose(1, peek: "Words.")])

        XCTAssertEqual(AdmissionSheet.waitingLine(for: request),
                       "1 paragraph waiting in “Chapter 3”")
        XCTAssertFalse(AdmissionSheet.waitingLine(for: request).contains("note"))
    }

    // MARK: - The peek

    func test_aLongParagraphIsCutAtAWord() {
        let long = String(repeating: "word ", count: 60)
        let cut = AdmissionWaiting.shortened(long)
        XCTAssertLessThanOrEqual(cut.count, AdmissionWaiting.peekLength + 1)
        XCTAssertTrue(cut.hasSuffix("word…"), cut)
    }

    func test_aPeekIsOneLine() {
        XCTAssertEqual(AdmissionWaiting.shortened("First line\nsecond line"),
                       "First line second line")
    }
}
