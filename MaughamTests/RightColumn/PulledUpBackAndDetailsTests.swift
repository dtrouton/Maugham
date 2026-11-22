import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// The fold-and-pulled-up appraisal wave (2026-11-21), asked of the pure
/// rules the views call — never by pressing a row (tripwire 33):
/// a fold's figure pulls up; a pull-up row's double-click opens in the
/// centre; Back's history; the canvas refresh key; the centre's details
/// above what is pulled up; the row sheets presented by the window.
@MainActor
final class PulledUpBackAndDetailsTests: XCTestCase {

    private let structure: [StructureItem] = [
        StructureItem(id: "ch-1", title: "One", type: .document, path: "one.md"),
        StructureItem(id: "ch-2", title: "Two", type: .document, path: "two.md"),
        StructureItem(id: "ref-1", title: "Elsewhere", type: .document, path: "ref.md",
                      pieceKind: .reference),
    ]

    private let chapter = WindowSubject(open: .item("ch-1"), faces: .item("ch-1"))

    private func card(_ kind: PinnedReference.Kind) -> PieceFoldEntry {
        .card(PinnedReference(id: "c", kind: kind, title: "C"))
    }

    // MARK: - A fold's figure (appraisal 8)

    /// A click on a fold's figure pulls it up beside the chapter, a second
    /// click puts it away, and a double-click opens it in the centre.
    func test_aFoldsFigurePullsUpBesideAndADoubleClickOpensIt() {
        let figure = PieceFoldEntry.figure(id: "f-1", name: "Rainfall")
        let up = BinderPieceFold.clicked(figure, subject: chapter, structure: structure,
                                         projectType: .novel)
        XCTAssertEqual(up.beside, .figure("f-1"), "pulled up beside")
        XCTAssertEqual(up.open, .item("ch-1"), "the chapter keeps the centre")
        XCTAssertEqual(up.faces, .item("ch-1"), "and the right column")
        XCTAssertNil(BinderPieceFold.clicked(figure, subject: up, structure: structure,
                                             projectType: .novel).beside,
                     "a second click puts it away")
        let opened = BinderPieceFold.doubleClicked(figure, subject: up, structure: structure,
                                                   projectType: .novel, photoNode: { _ in nil })
        XCTAssertEqual(opened, .subject(WindowSubject(open: .figure("f-1"), faces: .figure("f-1"))),
                       "a double-click opens it in the centre, nothing left beside")
        // The Figures SECTION is not a fold: its row still takes the centre.
        XCTAssertEqual(ClickRule.resolve(.figure("f-1"), gesture: .click, current: chapter,
                                         structure: structure, projectType: .novel).open,
                       .figure("f-1"))
    }

    // MARK: - A pull-up row's double-click (appraisal 9)

    /// The second press on the same row within the interval is a
    /// double-click; anything else is a single press.
    func test_aDoubleClickIsTheSecondPressOnTheSameRowInTime() {
        let last = BinderPieceFold.LastPress(entryId: "card:n1", at: 100)
        XCTAssertEqual(BinderPieceFold.press("card:n1", at: 100.3, last: last, interval: 0.5), .double)
        XCTAssertEqual(BinderPieceFold.press("card:n1", at: 100.5, last: last, interval: 0.5), .double,
                       "the interval's own edge counts")
        XCTAssertEqual(BinderPieceFold.press("card:n1", at: 100.6, last: last, interval: 0.5), .single,
                       "too late")
        XCTAssertEqual(BinderPieceFold.press("card:n2", at: 100.1, last: last, interval: 0.5), .single,
                       "another row")
        XCTAssertEqual(BinderPieceFold.press("card:n1", at: 100.1, last: nil, interval: 0.5), .single,
                       "no press before")
        XCTAssertEqual(BinderPieceFold.press("card:n1", at: 99, last: last, interval: 0.5), .single,
                       "a clock that went backwards is no pair")
    }

    /// A double-click on a scrap, a picture or a region opens the canvas with
    /// it selected — the row's menu's Open in Centre — and leaves nothing
    /// beside, whether the first click pulled it up or put it away.
    func test_aScrapPictureOrRegionDoubleClickOpensTheCanvasWithItSelected() {
        let cases: [(PieceFoldEntry, CanvasRevealTarget?)] = [
            (card(.scrap(nodeId: "n-1")), .node(CanvasNodeID("n-1"))),
            (card(.photo(path: "canvas_assets/a.png")), .node(CanvasNodeID("n-9"))),
            (.region(id: "rg-1", title: "Fog", cards: []), .region(CanvasRegionID("rg-1"))),
        ]
        let canvas = WindowSubject(open: .canvas, faces: .canvas)
        for (entry, target) in cases {
            let up = BinderPieceFold.clicked(entry, subject: chapter, structure: structure,
                                             projectType: .novel)
            for before in [up, chapter] {
                let opened = BinderPieceFold.doubleClicked(
                    entry, subject: before, structure: structure, projectType: .novel,
                    photoNode: { $0 == "canvas_assets/a.png" ? CanvasNodeID("n-9") : nil })
                XCTAssertEqual(opened, .canvas(canvas, select: target), entry.id)
            }
        }
    }

    // MARK: - Back

    func test_theHistoryRemembersWhatWasPulledUpBefore() {
        var history = PulledUpHistory()
        XCTAssertFalse(history.offersBack(from: nil, resolves: { _ in true }), "empty: no Back")
        history = history.recording(from: nil, to: .research("a"), byBack: false)
        XCTAssertEqual(history.entries, [], "a first pull-up leaves nothing to go back to")
        XCTAssertFalse(history.offersBack(from: .research("a"), resolves: { _ in true }))
        history = history.recording(from: .research("a"), to: .canvasRegion(id: "rg"), byBack: false)
        XCTAssertEqual(history.entries, [.research("a")], "what was replaced is remembered")
        history = history.recording(from: .canvasRegion(id: "rg"), to: .research("b"), byBack: false)
        XCTAssertEqual(history.entries, [.research("a"), .canvasRegion(id: "rg")])
        // Back brings the newest, and the arrival by Back records nothing.
        let (target, rest) = history.back(from: .research("b"), resolves: { _ in true })
        XCTAssertEqual(target, .canvasRegion(id: "rg"))
        history = rest.recording(from: .research("b"), to: .canvasRegion(id: "rg"), byBack: true)
        XCTAssertEqual(history.entries, [.research("a")], "Back walks back, never round in a pair")
        // What is up now is never an entry, and a thing pulled up again moves up.
        history = history.recording(from: .canvasRegion(id: "rg"), to: .research("a"), byBack: false)
        XCTAssertEqual(history.entries, [.canvasRegion(id: "rg")])
        // Close remembers too: Back with nothing up brings the last one back.
        history = PulledUpHistory().recording(from: .lessons, to: nil, byBack: false)
        XCTAssertEqual(history.back(from: nil, resolves: { _ in true }).target, .lessons)
    }

    func test_backSkipsWhatNoLongerResolvesAndIsBounded() {
        let history = PulledUpHistory(entries: [.research("a"), .figure("gone"), .research("b")])
        let (target, rest) = history.back(from: .research("b"),
                                          resolves: { $0 != .figure("gone") })
        XCTAssertEqual(target, .research("a"), "the current one and the gone one are passed over")
        XCTAssertEqual(rest.entries, [], "and dropped")
        XCTAssertFalse(PulledUpHistory(entries: [.figure("gone")])
                        .offersBack(from: nil, resolves: { _ in false }),
                       "Back is hidden when nothing would resolve")
        let none = history.back(from: nil, resolves: { _ in false })
        XCTAssertNil(none.target)
        XCTAssertEqual(none.rest.entries, [])
        // Bounded: the oldest goes first.
        var long = PulledUpHistory()
        for i in 0...PulledUpHistory.limit + 2 {
            long = long.recording(from: .research("r\(i)"), to: .research("r\(i + 1)"), byBack: false)
        }
        XCTAssertEqual(long.entries.count, PulledUpHistory.limit)
        XCTAssertEqual(long.entries.last, .research("r\(PulledUpHistory.limit + 2)"))
        XCTAssertFalse(long.entries.contains(.research("r0")), "the oldest went")
    }

    /// The memory's one writer is the window's observer, and an arrival by
    /// Back is recognised once.
    func test_theMemoryRecordsAnArrivalByBackOnce() {
        let memory = PulledUpMemory()
        memory.record(from: nil, to: .research("a"))
        memory.record(from: .research("a"), to: .research("b"))
        XCTAssertEqual(memory.history.entries, [.research("a")])
        memory.arrivingByBack = .research("a")
        memory.history = PulledUpHistory()
        memory.record(from: .research("b"), to: .research("a"))
        XCTAssertEqual(memory.history.entries, [], "Back's arrival records nothing")
        XCTAssertNil(memory.arrivingByBack, "and the mark is spent")
        memory.record(from: .research("a"), to: .research("c"))
        XCTAssertEqual(memory.history.entries, [.research("a")])
    }

    /// The history has one writer (the window's observer of `beside`), Back
    /// pulls up through the ordinary pull-up act, and the window mounts the
    /// wiring once. The planted control proves the census reads lines.
    func test_theHistoryIsWrittenByOneObserverMountedOnTheWindow() throws {
        let wiring = try SourceTree.read("Maugham/Views/PulledUpHistory.swift")
        XCTAssertTrue(wiring.contains(".onChange(of: subject.beside) { old, new in\n"
                                      + "                memory.record(from: old, to: new)"))
        let window = try SourceTree.read("Maugham/Views/ProjectWindow.swift")
        XCTAssertEqual(window.components(separatedBy: ".modifier(PulledUpHistoryWiring(").count - 1, 1)
        XCTAssertEqual(window.components(separatedBy: ".modifier(TreeWindowWiring(").count - 1, 1)
        var writers: [String] = []
        for file in try SourceTree.swiftFiles(under: "Maugham") {
            let code = SourceScan.codeLines(of: try SourceTree.read(file)).joined(separator: "\n")
            if code.contains(".record(from:") { writers.append((file as NSString).lastPathComponent) }
        }
        XCTAssertEqual(writers, ["PulledUpHistory.swift"])
        XCTAssertNotNil("x.record(from: a, to: b)".range(of: ".record(from:"), "the planted control")
    }

    // MARK: - The refresh key

    /// Each half of the canvas signal moves it, and every pulled-up canvas
    /// read keys on the fold's own type.
    func test_aPulledUpCanvasReadKeysOnTheFoldsSignal() throws {
        let base = CanvasCardsRevision(sceneRevision: 3, closedCanvasWrites: 0)
        XCTAssertEqual(base, CanvasCardsRevision(sceneRevision: 3, closedCanvasWrites: 0))
        XCTAssertNotEqual(base, CanvasCardsRevision(sceneRevision: 4, closedCanvasWrites: 0))
        XCTAssertNotEqual(base, CanvasCardsRevision(sceneRevision: 3, closedCanvasWrites: 1),
                          "Claude's write into a closed canvas moves it")
        for file in ["Maugham/Views/PulledUpView.swift", "Maugham/Views/PulledUpRegionView.swift",
                     "Maugham/Views/RightColumnControl.swift", "Maugham/Views/PieceFoldContents.swift"] {
            let code = SourceScan.codeLines(of: try SourceTree.read(file)).joined(separator: "\n")
            XCTAssertTrue(code.contains("CanvasCardsRevision(sceneRevision:"),
                          "\(file) keys its canvas read on the fold's signal")
        }
        let view = try SourceTree.read("Maugham/Views/PulledUpView.swift")
        XCTAssertTrue(view.contains("closedCanvasWrites: figureTree?.closedCanvasWrites ?? 0)"))
        XCTAssertFalse(view.contains("revision: canvasModel.sceneRevision)"),
                       "a key on the scene revision alone is back")
    }

    // MARK: - The centre's details above what is pulled up

    /// Every centre kind × something pulled up or not: the details stand
    /// above a pulled-up thing only for a figure, a research item or a
    /// reference piece, never for the canvas, never for the item itself, and
    /// never with nothing pulled up.
    func test_theCentresDetailsStandAboveWhatIsPulledUp() {
        let centres: [(BinderSubject, CentreDetails?)] = [
            (.figure("f-1"), .figure("f-1")),
            (.research("r-1"), .research("r-1")),
            (.item("ref-1"), .referencePiece("ref-1")),
            (.canvas, nil),
            (.item("ch-1"), nil),
            (.project, nil),
            (.inbox, nil),
            (.palette, nil),
        ]
        let pulls: [PulledUp?] = [nil, .research("note"), .figure("other"), .lessons,
                                  .canvasRegion(id: "rg"), .history(docId: "ch-2")]
        for (open, expected) in centres {
            for pulled in pulls {
                let subject = WindowSubject(open: open, faces: open, beside: pulled)
                let above = RightColumnContent.centreDetailsAbovePulledUp(
                    subject, structure: structure, projectType: .novel)
                XCTAssertEqual(above, pulled == nil ? nil : expected, "\(open) with \(String(describing: pulled))")
                if above == nil, pulled == nil {
                    // Nothing pulled up: the details are the whole position, as before.
                    XCTAssertEqual(RightColumnContent.of(position: .pulledUp, subject: subject,
                                                         structure: structure,
                                                         projectType: .novel),
                                   expected.map(RightColumnContent.centreDetails)
                                    ?? (open == .canvas ? .centreDetails(.canvas) : .nothingPulledUp))
                }
            }
        }
        // The item pulled up IS the centre's: its own view draws its details.
        XCTAssertNil(RightColumnContent.centreDetailsAbovePulledUp(
            WindowSubject(open: .figure("f-1"), faces: .figure("f-1"), beside: .figure("f-1")),
            structure: structure, projectType: .novel))
        XCTAssertNil(RightColumnContent.centreDetailsAbovePulledUp(
            WindowSubject(open: .research("r-1"), faces: .research("r-1"), beside: .research("r-1")),
            structure: structure, projectType: .novel))
        XCTAssertEqual(CentreDetailsSection<EmptyView>.line("Rainfall"), "Details of Rainfall")
        XCTAssertEqual(CentreDetailsSection<EmptyView>.line(""), "Details of what the centre shows")
    }

    /// Back's help names what it brings up.
    func test_backSaysWhatItBringsUp() {
        XCTAssertEqual(BesideHeader.backHelp("Notes on Rome"), "Back to Notes on Rome")
        XCTAssertEqual(BesideHeader.backHelp(""), "Back to what was pulled up before")
    }
}
