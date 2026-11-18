import SwiftUI
import XCTest
@testable import Maugham

/// **The right column's one order, and what the subject leaves out of it**
/// (shell p1 Task 6). `DetailPaneToggle` is generic over its inspector content,
/// so a static member reference binds that parameter — `<AnyView>` is an
/// arbitrary witness; the helpers are pure and ignore it.
final class DetailSegmentOrderTests: XCTestCase {
    private typealias Toggle = DetailPaneToggle<AnyView>

    /// The order, transcribed once. Expressed as one literal because this is
    /// where the order is asserted; every picker below is checked as this
    /// order filtered, never as a literal of its own.
    static let expectedOrder: [DetailSegment] = [
        .resolve, .department, .intent, .lessons,
        .firstReader, .references, .visualLanguage, .translation,
        .history, .inspector
    ]

    private static let chapter = WindowSubject(open: .item("ch-1"), faces: .item("ch-1"))
    private static let edition = WindowSubject(open: .edition(language: "es"),
                                               faces: .item("ch-1"))
    private static let canvas = WindowSubject(open: .canvas, faces: .project)

    /// Every subject shape the picker is asked about.
    private static let subjects: [WindowSubject] = [
        .book, chapter, edition, canvas,
        WindowSubject(open: .inbox, faces: .project),
        WindowSubject(open: .research("r-1"), faces: .research("r-1")),
        WindowSubject(open: .figure("f-1"), faces: .figure("f-1")),
        WindowSubject(open: .canvas, faces: .item("ch-1")),
        WindowSubject(open: .edition(language: "es"), faces: .project),
    ]

    // MARK: - The order

    func test_thePickerOrderIsTheOneOrder() {
        XCTAssertEqual(DetailSegment.pickerOrder, Self.expectedOrder)
    }

    /// A new `DetailSegment` must be given a place, or no picker can show it
    /// in order.
    func test_thePickerOrderPlacesEveryCaseOnce() {
        XCTAssertEqual(Set(DetailSegment.pickerOrder).count, DetailSegment.pickerOrder.count,
                       "pickerOrder lists a segment twice")
        XCTAssertEqual(Set(DetailSegment.pickerOrder), Set(DetailSegment.allCases),
                       "a DetailSegment has no place in pickerOrder")
    }

    /// Whatever the subject, the picker is `pickerOrder` with members left out
    /// — never a reorder.
    func test_everyPickerIsTheOrderFiltered() {
        for subject in Self.subjects {
            let shown = Toggle.visibleSegments(subject: subject)
            XCTAssertEqual(shown, DetailSegment.pickerOrder.filter(Set(shown).contains),
                           "\(subject)'s picker is not pickerOrder filtered")
            XCTAssertTrue(shown.contains(.inspector), "\(subject) lost the Inspector")
        }
    }

    /// **The planted offender**: the chapter's real panes with History and
    /// Translation swapped — same members, same first element. Only the order
    /// guard sees it.
    func test_theOrderGuardCatchesAReorderThatKeepsTheFirstElement() throws {
        var offender = Toggle.visibleSegments(subject: Self.chapter)
        let translation = try XCTUnwrap(offender.firstIndex(of: .translation))
        let history = try XCTUnwrap(offender.firstIndex(of: .history))
        offender.swapAt(translation, history)
        XCTAssertEqual(offender.first, Toggle.visibleSegments(subject: Self.chapter).first)
        XCTAssertNotEqual(offender, DetailSegment.pickerOrder.filter(Set(offender).contains),
                          "the guard accepted a permutation — it is asserting "
                          + "membership, not order")
    }

    // MARK: - What the subject leaves out

    func test_theDepartmentDeskIsOfferedOnlyWithAnEditionOpen() {
        for subject in Self.subjects {
            let opensAnEdition: Bool
            if case .edition = subject.open { opensAnEdition = true } else { opensAnEdition = false }
            XCTAssertEqual(Toggle.visibleSegments(subject: subject).contains(.department),
                           opensAnEdition, "\(subject)")
        }
    }

    func test_thePanesAboutOneDocumentLeaveWhenTheFacesNameNone() {
        for subject in Self.subjects {
            let facesADocument: Bool
            if case .item = subject.faces, subject.faces == subject.open {
                facesADocument = true
            } else { facesADocument = false }
            let shown = Set(Toggle.visibleSegments(subject: subject))
            for segment in DetailSegment.needsADocument {
                XCTAssertEqual(shown.contains(segment), facesADocument,
                               "\(segment) under \(subject)")
            }
        }
        // The control: the panes that do not need a document stay with the Book.
        let book = Set(Toggle.visibleSegments(subject: .book))
        for segment in [DetailSegment.resolve, .intent, .lessons, .firstReader,
                        .visualLanguage, .inspector] {
            XCTAssertTrue(book.contains(segment), "the Book lost \(segment)")
        }
    }

    /// **A pane about one document is not offered for a faces' piece that is
    /// not open** (shell p1 final fix, I2): with the canvas or an edition in
    /// the centre, a piece clicked moves only the faces, and no editor has
    /// that piece — the panes would show "Select a document". The same piece
    /// open in the centre offers them all. To resolve is not among them (shell
    /// plan 2 Task 7): it reads the piece without loading it.
    func test_aDocumentPaneIsNotOfferedForAFacesPieceThatIsNotOpen() {
        for open in [BinderSubject.canvas, .edition(language: "es")] {
            let subject = WindowSubject(open: open, faces: .item("ch-1"))
            let shown = Set(Toggle.visibleSegments(subject: subject))
            for segment in DetailSegment.needsADocument {
                XCTAssertFalse(shown.contains(segment), "\(segment) offered over \(open)")
            }
            XCTAssertFalse(Toggle.facesPieceIsOpen(subject), "\(open)")
            XCTAssertTrue(shown.contains(.resolve), "To resolve is offered over \(open)")
        }
        let shown = Set(Toggle.visibleSegments(subject: Self.chapter))
        XCTAssertTrue(DetailSegment.needsADocument.isSubset(of: shown),
                      "control: the piece open in the centre offers them")
        XCTAssertTrue(Toggle.facesPieceIsOpen(Self.chapter))
    }

    /// Every subject's picker leads with To resolve (shell plan 2 Task 7).
    func test_everyPickerLeadsWithToResolve() {
        for subject in Self.subjects {
            XCTAssertEqual(Toggle.visibleSegments(subject: subject).first, .resolve, "\(subject)")
        }
    }

    // MARK: - A selected segment is carried

    /// Every ⌘⌥-letter fires whatever the subject; the pane it lands on is
    /// appended, so the picker never renders with nothing selected.
    func test_aSelectionTheSubjectDoesNotOfferIsAppended() {
        let shown = Toggle.visibleSegments(subject: .book, including: .translation)
        XCTAssertEqual(shown.last, .translation)
        XCTAssertEqual(Array(shown.dropLast()), Toggle.visibleSegments(subject: .book))
    }

    func test_aSelectionAlreadyOfferedIsNotDuplicated() {
        let shown = Toggle.visibleSegments(subject: Self.chapter, including: .history)
        XCTAssertEqual(shown, Toggle.visibleSegments(subject: Self.chapter))
    }

    /// The mount-time snap keeps the pane the writer asked for — a `⌘⌥` key
    /// that reveals a hidden column mounts the picker fresh with the segment
    /// already in place (whole-branch review, Critical 1, of an earlier
    /// milestone). Snapping against the bare offered list instead eats it.
    func test_mountSelection_keepsAPaneTheSubjectDoesNotOffer() {
        let selected = DetailSegment.department
        XCTAssertFalse(Toggle.visibleSegments(subject: .book).contains(selected))
        XCTAssertEqual(Toggle.mountSelection(selected, subject: .book), selected)
        XCTAssertEqual(
            Toggle.snappedSelection(selected, in: Toggle.visibleSegments(subject: .book),
                                    fallback: .inspector),
            Toggle.visibleSegments(subject: .book).first,
            "control: the bare offered list is the one that eats the selection")
    }

    func test_everyRequestedPaneLandsUnderEverySubject() {
        for subject in Self.subjects {
            for requested in DetailSegment.allCases {
                XCTAssertEqual(Toggle.mountSelection(requested, subject: subject), requested,
                               "\(subject) dropped \(requested) on reveal")
            }
        }
    }

    // MARK: - Leaving an edition

    /// **Leaving an edition while the desk is selected lands on the first
    /// segment the new subject offers** (controller ruling, shell p1 Task 6
    /// fix); staying on an edition, or any other selection, is carried.
    func test_leavingAnEditionTakesTheDeskWithIt() {
        let es = WindowSubject(open: .edition(language: "es"), faces: .project)
        let fr = WindowSubject(open: .edition(language: "fr"), faces: .project)
        for to in [WindowSubject.book, Self.chapter, Self.canvas] {
            let landed = Toggle.segmentAfterSubjectChange(.department, from: es, to: to)
            XCTAssertEqual(landed, Toggle.visibleSegments(subject: to).first, "\(to)")
            XCTAssertNotEqual(landed, .department)
        }
        XCTAssertEqual(Toggle.segmentAfterSubjectChange(.department, from: es, to: fr),
                       .department, "edition to edition keeps the desk")
        XCTAssertEqual(Toggle.segmentAfterSubjectChange(.history, from: es, to: .book),
                       .history, "any other selection is carried")
        XCTAssertEqual(Toggle.segmentAfterSubjectChange(.department, from: .book, to: Self.chapter),
                       .department,
                       "a desk reached by ⌘⌥K off an edition is the writer's own ask")
    }

    /// The menu form's names are the help text up to the dash.
    func test_theMenuFormNamesEachSegment() {
        XCTAssertEqual(Toggle.title(of: .resolve), "To resolve")
        XCTAssertEqual(Toggle.title(of: .lessons), "What I've learned")
        for segment in DetailSegment.allCases {
            XCTAssertFalse(Toggle.title(of: segment).contains("\u{2014}"), "\(segment)")
        }
    }

    // MARK: - Badges

    /// The unread dot is drawn `shift` segment-widths left of the trailing
    /// edge, so the assertion is where it LANDS, under every picker shape.
    func test_theUnreadDotLandsOnToResolve() {
        for subject in Self.subjects {
            for selected in [nil] + DetailSegment.allCases.map({ Optional($0) }) {
                let shown = Toggle.visibleSegments(subject: subject, including: selected)
                guard let shift = Toggle.badgeOffset(of: Toggle.unreadDotSegment, in: shown) else {
                    XCTFail("To resolve is offered under every subject: \(shown)")
                    continue
                }
                XCTAssertEqual(shown[shown.count - 1 - shift], .resolve,
                               "the dot lands on the wrong segment of \(shown)")
            }
        }
    }

    // MARK: - Every pane has a key

    /// Every case is reachable by a View-menu item through `postSegment`,
    /// whatever the subject offers (moved here from the retired keyspace
    /// suite, shell p1 Task 6). To resolve's is ⌘1; ⌘⌥A/D/T reach it on a
    /// filter (`ResolveMountingTests`).
    func test_everyDetailSegmentHasAMenuShortcut() throws {
        let app = try SourceTree.read("Maugham/MaughamApp.swift")
        for segment in DetailSegment.allCases {
            XCTAssertTrue(app.contains("postSegment(.\(segment.rawValue))"),
                          "no View-menu item posts \(segment.rawValue)")
        }
    }
}
