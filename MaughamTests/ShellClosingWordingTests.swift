import XCTest
import MaughamCore
@testable import Maugham

/// **The closing round's wording leftovers and small removals** (shell
/// closing A7, A9, A10): each sentence the writer reads, pinned as built, and
/// each removed or re-routed seam pinned at its source so it cannot quietly
/// come back.
@MainActor
final class ShellClosingWordingTests: XCTestCase {

    private func flat(_ path: String) throws -> String {
        SourceScan.codeLines(of: try SourceTree.read(path))
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    }

    // MARK: - A9: nouns through PieceNoun

    /// A promotion refusal names the piece by its own noun: a script in a
    /// Collection is a script; with no project, a piece.
    func test_aPromotionRefusalNamesThePieceByItsOwnNoun() {
        let manifest = ProjectManifest(
            type: .collection, title: "T", author: "A", created: Date(), modified: Date(),
            structure: [StructureItem(id: "pc-1", title: "Scene", type: .document,
                                      path: "pieces/scene/scene.fountain")],
            research: [])
        XCTAssertEqual(ManuscriptBeingPromoted(title: nil, path: "pieces/scene/scene.fountain",
                                               manifest: manifest).errorDescription,
                       "This script is being promoted to its own project \u{2014} try again in a moment.")
        XCTAssertEqual(ManuscriptBeingPromoted(title: nil).errorDescription,
                       "This piece is being promoted to its own project \u{2014} try again in a moment.")
    }

    /// No store sentence hard-codes the generic piece noun any more.
    func test_noStoreSentenceAsksTheGenericPieceNoun() throws {
        for path in ["Maugham/Stores/DocumentStore.swift", "Maugham/Stores/ProjectStore+Figures.swift"] {
            XCTAssertFalse(try flat(path).contains("PieceNoun.piece.singular"), path)
        }
    }

    func test_theBriefLinkAndTheElsewhereLinesReadPlainly() {
        XCTAssertEqual(RulingOrigin(title: "Arrival", open: nil).openHelp,
                       "Open the Brief of \u{201C}Arrival\u{201D}")
        XCTAssertEqual(BriefPane.elsewhereLine, "It belongs to another project. Its brief is that project's.")
    }

    /// Format ▸ Table ▸ Send to Research with no grid in front is titled in
    /// the front window's project noun.
    func test_sendToResearchWithNoGridUsesTheWindowsNoun() throws {
        let app = try flat("Maugham/MaughamApp.swift")
        XCTAssertTrue(app.contains("Button(command.title(menu?.noun ?? chrome?.pieceNoun ?? .piece))"))
        let window = SourceScan.codeLines(of: try SourceTree.sourceOfType("ProjectWindow", under: ["Maugham"]))
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        XCTAssertTrue(window.contains("pieceNoun: PieceNoun.of(nil, in: store.manifest))"))
        XCTAssertEqual(FigureResearchDestination.piece.title(.chapter),
                       "This Chapter\u{2019}s Research")
    }

    /// A Collection's script row links to "Another Piece": the link may go
    /// to any piece, so the title names the project's noun, not the row's.
    func test_aCollectionsRowLinksToAnotherPiece() throws {
        XCTAssertTrue(try flat("Maugham/Views/CollectionPiecesPane.swift")
            .contains("noun: PieceNoun.of(nil, in: store.manifest))"))
        XCTAssertEqual(PieceRowMenus.Item.addLink.title(PieceNoun.of(nil, in: PieceNoun.Book(type: .collection))),
                       "Link to Another Piece\u{2026}")
    }

    // MARK: - A7: the Inbox's fast promote is gone

    func test_theInboxOffersNoFastPromoteToAGlancedAtPiece() throws {
        let inbox = try flat("Maugham/Views/InboxPane.swift")
        XCTAssertFalse(inbox.contains("Promote to Research for \u{201C}"), "the fast target is deleted")
        XCTAssertFalse(inbox.contains("activeDocumentId"))
        XCTAssertTrue(inbox.contains("Promote to \\(FigureResearchDestination.wholeBookTitle)"),
                      "control: Promote to Whole-Book Research stays")
        XCTAssertTrue(inbox.contains("Button(\"Promote to Research for…\")"), "control: the picker stays")
    }

    // MARK: - A10: the sample and the ui-state path

    func test_aSampleSeedsItsSubjectBestEffortAndTheUIStatePathIsSpelledOnce() throws {
        XCTAssertTrue(try flat("Maugham/Stores/SampleProjectBuilder.swift").contains("try? openOnFirstPiece(dest)"))
        XCTAssertTrue(try SourceTree.read("Maugham/Stores/MaughamSidecarPath.swift")
            .contains("if relativePath == UIState.relativePath"))
        XCTAssertEqual(UIState.fileURL(inProject: URL(fileURLWithPath: "/p")).path, "/p/.maugham/ui-state.json")
    }
}
