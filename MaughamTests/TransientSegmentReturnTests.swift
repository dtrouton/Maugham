import XCTest
import AppKit
import SwiftUI
import Observation
import MaughamCore
@testable import Maugham

/// **Where does the writer land when a transient segment ends?**
///
/// Nowhere any more, for either of the two segments that used to answer this
/// question. Trash's `.onChange(of: store.trashEntries.count)` — return to
/// `persona.binderHome(for:)` when the writer's last deleted item leaves —
/// died in shell-finish stage 2b Task 2, along with the `TransientExitBox`
/// suite that drove it: Trash is a foot disclosure now, not a segment, so
/// emptying it removes the disclosure rather than moving anyone. Find's twin
/// of the arm went the same way one task earlier, for the same reason —
/// `TreeFindOverlayTests` owns what is left of that contract, and
/// `TreeTrashDisclosureTests` owns this one: "emptying the trash leaves no
/// dead surface" now means the disclosure itself disappears, asserted on the
/// real mounted toggle rather than on a `segment` nothing writes any more.
///
/// **The census: no site forces the binder onto the manuscript on its own.**
///
/// Five sites forced the binder home and the brief named three of them; the two
/// that were missed are the toggles' own `.onChange`s, which no persona write
/// could ever have reached because they are inside a view with no `persona`
/// binding. Two of the five went with stage 2b Task 1 — find's `.onChange` in
/// each toggle — because closing find no longer moves the binder at all.
///
/// Both spellings are now unwritable in those files: a navigation goes through
/// `ManuscriptNavigation`, which decides the persona too, and a transient exit
/// goes to `Persona.binderHome(for:)`.
@MainActor
final class ManuscriptForceCensusTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path),
                   encoding: .utf8)
    }

    /// The offender shapes, as regexes — asked of a planted string first, so a
    /// census that can no longer match anything fails here rather than passing
    /// silently everywhere.
    private static let offenders: [(name: String, pattern: String, plant: String)] = [
        ("a bare navigation to the document home",
         #"binderSegment = \.documentHome\("#,
         "        binderSegment = .documentHome(for: projectType)"),
        ("a transient exit forced onto the document home",
         #"segment = \.documentHome\("#,
         "                segment = .documentHome(for: projectType)"),
        ("a transient exit forced onto the manuscript segment",
         #"segment = \.manuscript\b"#,
         "                segment = .manuscript"),
    ]

    /// **A second family, added by slice 2 task 9: the document home written
    /// out by hand instead of asked for.**
    ///
    /// This is a READ rather than a force, which is why it is its own array —
    /// nobody was moving the binder, they were asking where it was. Three sites
    /// spelled it, in the two shapes below: the manuscript status footer
    /// (`ProjectWindow.shouldShowStatusFooter`) and the Exports footer in both
    /// toggles. Each is the union of `documentHome(for:)`'s answers over two
    /// project types, so each accepted a segment its own project type never
    /// offers and each would have needed editing by hand for a fifth type.
    ///
    /// The footer asks `ProjectWindow.showsStatusFooter`, and since shell-finish
    /// stage 2b Task 6 that reads the PERSONA (`Persona.showsManuscriptDocuments`)
    /// — a question about the centre column, which is what the footer follows.
    /// Both Exports gates read the persona too (`persona != .plan`), because
    /// after Task 7 all four personas have the same left column and nothing
    /// about the tree can tell them apart; what is left is what the writer is
    /// doing. Neither hand-spelling is writable in these three files any more.
    private static let handSpelledHomes: [(name: String, pattern: String, plant: String)] = [
        ("the document home hand-spelled as a segment equality",
         #"(?:binderSegment|segment) == \.(?:manuscript|scenes)\b"#,
         "        guard binderSegment == .manuscript || binderSegment == .scenes else {"),
    ]

    /// The control. A regex that matches nothing would make every assertion
    /// below vacuous, which is how an unfalsifiable census ships.
    func test_theCensusCanStillRecogniseAnOffender() throws {
        for offender in Self.offenders + Self.handSpelledHomes {
            XCTAssertNotNil(
                offender.plant.range(of: offender.pattern, options: .regularExpression),
                "\(offender.name): the pattern no longer matches its own "
                + "planted offender, so every assertion using it is vacuous")
        }
        // The other half of the control, and the reason this pattern is spelled
        // with two named prefixes rather than a bare `== \.manuscript`:
        // `loadProject` legitimately asks whether the RESTORED segment was
        // `.manuscript` before coercing it through `documentHome(for:)` on a
        // screenplay. A pattern wide enough to flag that would make the census
        // permanently red and get itself deleted.
        for offender in Self.handSpelledHomes {
            XCTAssertNil(
                "self.binderSegment = savedSegment == .manuscript"
                    .range(of: offender.pattern, options: .regularExpression),
                "\(offender.name): the pattern flags `loadProject`'s legitimate "
                + "restore check, which is not an offender")
        }
    }

    /// **The read half.** `test_noSiteForcesTheBinderOntoTheManuscript…` below
    /// walks the same three files for the write shapes; this walks them for the
    /// hand-spelled home.
    func test_noSiteHandSpellsTheDocumentHomeInsteadOfAskingForIt() throws {
        for path in ["Maugham/Views/ProjectWindow.swift",
                     "Maugham/Views/BinderPaneToggle.swift",
                     "Maugham/Views/CollectionBinderPaneToggle.swift"] {
            let text = try source(path)
            XCTAssertFalse(text.isEmpty, "\(path): read nothing")
            for offender in Self.handSpelledHomes {
                let hits = text.split(separator: "\n").filter {
                    !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                        && $0.range(of: offender.pattern,
                                    options: .regularExpression) != nil
                }
                XCTAssertTrue(hits.isEmpty,
                              "\(path): \(offender.name) — \(hits). Ask "
                              + "`BinderSegment.documentHome(for:)` for the left "
                              + "column's question and "
                              + "`showsManuscriptStatusFooter` for the centre's.")
            }
        }
    }

    /// **And the other half a spelling census cannot see: that the gate is still
    /// there at all.** Deleting the Exports condition outright leaves no wrong
    /// spelling behind — the list simply renders under every segment, including
    /// Plan's canvas. Both toggles are named rather than counted.
    func test_bothTogglesStillGateExportsOnAPersonaThatPublishes() throws {
        for path in ["Maugham/Views/BinderPaneToggle.swift",
                     "Maugham/Views/CollectionBinderPaneToggle.swift"] {
            let text = try source(path)
            XCTAssertTrue(text.contains("if persona != .plan"),
                          "\(path): the Exports footer no longer gates on the "
                          + "persona — a compile-output list under Plan's tree "
                          + "is not what a writer arranging structure is doing")
            // **The interim half, and it is load-bearing until Task 7 deletes
            // it.** Author can be FORCED onto `.research` (`openResearchItem`,
            // the MCP note banner's Show) and can restore onto `.palette`, and
            // the Exports list has never rendered under either of those lists.
            // Dropping this conjunct with the persona one in place is not a
            // simplification; it is a visibility change.
            XCTAssertTrue(text.contains("segment.interimLeftPaneIsTheTree"),
                          "\(path): the Exports footer no longer asks whether "
                          + "the left column is the tree, so it now renders "
                          + "under a forced Research or a restored Palette")
        }
    }

    /// **The other half, and the one a census of offender spellings cannot
    /// see.** Deleting the call outright leaves no wrong spelling behind — the
    /// binder simply stops moving, and every decision test above still passes on
    /// a `ManuscriptNavigation` nothing reaches. So each receiver is asked
    /// whether it still routes through it.
    ///
    /// The receivers are named, not counted — and the third one, added by the
    /// F2 fix, is why. `.maughamNavigateToScene` existed all along, posted by
    /// `SceneNavigatorPane`'s `onSelect` and received only by
    /// `EditorCoordinator`; slice 2 put that navigator on Plan's Structure tab,
    /// where no coordinator exists, so a slugline click did nothing at all. The
    /// prose next door said "three receivers" over a list of two, and that
    /// undercount is precisely what stopped anyone asking about the third.
    func test_everyNavigationReceiverStillRoutesThroughTheNavigation() throws {
        let text = try source("Maugham/Views/ProjectWindow.swift")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for receiver in [".maughamNavigateToDocument", ".maughamNavigateToParagraph",
                         ".maughamNavigateToScene"] {
            let start = try XCTUnwrap(
                lines.firstIndex(where: { $0.contains("(\(receiver),") }),
                "\(receiver): no receiver for it at all in ProjectWindow")
            let body = lines[start..<min(start + 25, lines.count)].joined(separator: "\n")
            XCTAssertTrue(body.contains("ManuscriptNavigation.go("),
                          "\(receiver) no longer routes through "
                          + "ManuscriptNavigation, so it moves the binder "
                          + "without deciding the persona — or has stopped "
                          + "moving it at all")
        }
    }

    func test_noSiteForcesTheBinderOntoTheManuscriptOutsideTheNavigation() throws {
        for path in ["Maugham/Views/ProjectWindow.swift",
                     "Maugham/Views/BinderPaneToggle.swift",
                     "Maugham/Views/CollectionBinderPaneToggle.swift"] {
            let text = try source(path)
            XCTAssertFalse(text.isEmpty, "\(path): read nothing")
            for offender in Self.offenders {
                let hits = text.split(separator: "\n").filter {
                    // Comments explain the rule and must stay writable.
                    !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                        && $0.range(of: offender.pattern,
                                    options: .regularExpression) != nil
                }
                XCTAssertTrue(hits.isEmpty,
                              "\(path): \(offender.name) — \(hits). A navigation "
                              + "goes through ManuscriptNavigation (which decides "
                              + "the persona too) and a transient exit goes to "
                              + "Persona.binderHome(for:).")
            }
        }
    }
}
