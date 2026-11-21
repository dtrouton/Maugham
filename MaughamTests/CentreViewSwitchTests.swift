import XCTest
import MaughamCore
@testable import Maugham

/// **The centre's view switch** (shell p4 Task 4): what it offers on every
/// kind of subject, what an edition offers, the menu's payload, and that the
/// Book's own header no longer carries a picker. Pure, and censuses.
@MainActor
final class CentreViewSwitchTests: XCTestCase {

    private let structure = SubjectSamples.structure

    private func offer(_ open: BinderSubject, book: BookView = .outline,
                       edition: EditionView = .book) -> CentreViewSwitch.Offer {
        CentreViewSwitch.offer(subject: SubjectSamples.opened(open), bookView: book,
                               editionView: edition, structure: structure)
    }

    /// **Exactly where the centre has views**: the Book, a Part (a small
    /// Book) and an edition — and an id naming nothing, which the sweep
    /// repairs to the Book. A piece, research, a figure, the Inbox, the
    /// canvas and the wall have no views, so the switch is hidden there.
    func test_theSwitchIsOfferedOnlyWhereTheCentreHasViews() {
        for open in SubjectSamples.everyOpen + [.item("gone")] {
            let expected: CentreViewSwitch.Offer
            switch open {
            case .project: expected = .book(.status)
            case .item(let id) where id == SubjectSamples.partID || id == "gone":
                expected = .book(.status)
            case .item: expected = .none
            case .edition: expected = .edition(.status)
            case .research, .figure, .inbox, .canvas, .palette: expected = .none
            }
            XCTAssertEqual(offer(open, book: .status, edition: .status), expected,
                           "\(SubjectSamples.kind(of: open)) (\(open))")
            // Asked of `altitudeView`, never restated: the two agree on every row.
            XCTAssertEqual(
                offer(open) == .none,
                ProjectWindow.altitudeView(subject: SubjectSamples.opened(open),
                                           bookView: .outline, structure: structure) == nil,
                "the switch and the altitude layer disagree at \(open)")
        }
    }

    /// An edition offers its Book and its Status, carrying the edition's own
    /// remembered view — never the Book's Cards or Outline.
    func test_anEditionOffersBookAndStatus() {
        let edition = offer(.edition(language: "es"), book: .cards, edition: .book)
        XCTAssertEqual(edition, .edition(.book))
        XCTAssertEqual(CentreViewSwitch.choices(for: edition),
                       [.edition(.book), .edition(.status)])
        XCTAssertEqual(CentreViewSwitch.choices(for: .book(.cards)),
                       [.book(.cards), .book(.outline), .book(.status)])
        XCTAssertEqual(CentreViewSwitch.choices(for: .none), [])
        XCTAssertEqual(CentreViewSwitch.choices(for: edition).map(CentreViewSwitch.title(of:)),
                       ["Book", "Status"])
    }

    /// The menu's payload round-trips, and a choice the current offer does
    /// not list (a post that raced a subject change) is refused.
    func test_theMenusChoiceRoundTripsAndOnlyAListedChoiceLands() {
        for choice in CentreViewSwitch.choices(for: .book(.cards))
            + CentreViewSwitch.choices(for: .edition(.book)) {
            XCTAssertEqual(CentreViewSwitch.choice(from: CentreViewSwitch.token(of: choice)), choice)
        }
        XCTAssertNil(CentreViewSwitch.choice(from: "book.nonsense"))
        XCTAssertNil(CentreViewSwitch.choice(from: nil))
        XCTAssertTrue(CentreViewSwitch.accepts(.book(.status), under: .book(.cards)))
        XCTAssertFalse(CentreViewSwitch.accepts(.edition(.status), under: .book(.cards)))
        XCTAssertFalse(CentreViewSwitch.accepts(.book(.cards), under: .none))
        // Status is ⌃⌘3 whatever the subject.
        XCTAssertEqual(CentreViewSwitch.keyDigit(of: .book(.status)), "3")
        XCTAssertEqual(CentreViewSwitch.keyDigit(of: .edition(.status)), "3")
    }

    /// **The Book's header is its title alone**: the picker moved to the
    /// toolbar, and a second switch in a header would be two controls that
    /// can disagree about one value.
    func test_theAltitudeHeaderHasNoPicker() throws {
        let code = try SourceScan.codeLines(of: String(
            contentsOf: Self.source("Views/ProjectAltitudePane.swift"), encoding: .utf8))
        XCTAssertFalse(code.contains { $0.contains("Picker(") },
                       "the view switch is the toolbar's (`CentreViewSwitch`)")
        XCTAssertFalse(code.contains { $0.contains("updateUIState") },
                       "the pane writes no view: `ProjectWindow.chooseCentreView` is the writer")
    }

    /// **The toolbar draws the switch only where it is offered, and the
    /// window's one chooser is what it and the menu write through** — the
    /// value and its `UIState` key together.
    func test_theToolbarAndTheMenuWriteThroughTheWindowsOneChooser() throws {
        let window = try String(contentsOf: Self.source("Views/ProjectWindow.swift"), encoding: .utf8)
        XCTAssertTrue(window.contains("if centreViewOffer != .none {"),
                      "hidden, not disabled, where the centre has no views")
        XCTAssertTrue(window.contains("CentreViewSwitchControl(offer: centreViewOffer,"))
        XCTAssertTrue(window.contains(".onKeyWindowCommand(.maughamChooseCentreView, window: window)"),
                      "the menu's keys reach the key window")
        XCTAssertTrue(window.contains("documentStore?.updateUIState { $0.bookView = view }")
                      && window.contains("documentStore?.updateUIState { $0.editionView = view }"),
                      "the chooser persists what it writes")
        let app = try String(contentsOf: Self.source("MaughamApp.swift"), encoding: .utf8)
        XCTAssertTrue(app.contains("FocusedCentreViewItems()"), "View ▸ View as … is in the menu")
    }

    /// **⌃⌘1/2/3 are the switch's and nobody else's** (review, minor 3): the
    /// digits are built from `keyDigit`, so the shortcut census that reads
    /// literal keys never sees them. Cards/Book 1, Outline 2, Status 3, and no
    /// other ⌃⌘ digit binding anywhere in the app.
    func test_controlCommandOneTwoThreeBelongToTheSwitchAlone() throws {
        XCTAssertEqual(CentreViewSwitch.choices(for: .book(.cards)).map(CentreViewSwitch.keyDigit(of:)),
                       ["1", "2", "3"])
        XCTAssertEqual(CentreViewSwitch.choices(for: .edition(.book)).map(CentreViewSwitch.keyDigit(of:)),
                       ["1", "3"])
        let item = try String(contentsOf: Self.source("Views/CentreViewSwitch.swift"), encoding: .utf8)
        XCTAssertTrue(item.contains("modifiers: [.command, .control])"),
                      "the menu items bind ⌃⌘ + the digit")
        var offenders: [String] = []
        for file in try SourceTree.swiftFiles(under: "Maugham") {
            for line in SourceScan.codeLines(of: try SourceTree.read(file))
            where line.contains(".control") && line.contains(".command") {
                for digit in ["\"1\"", "\"2\"", "\"3\""] where line.contains("keyboardShortcut(\(digit)") {
                    offenders.append("\(file): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssertEqual(offenders, [], "a second ⌃⌘1/2/3 binding would collide with View as …")
    }

    private static func source(_ path: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Maugham").appendingPathComponent(path)
    }
}
