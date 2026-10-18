import XCTest
import AppKit
import SwiftUI
import Observation
import MaughamCore
@testable import Maugham

/// **The census: every navigation still goes through `ManuscriptNavigation`, and
/// both binder toggles still gate Exports on a persona that publishes.**
///
/// It lived in `TransientSegmentReturnTests.swift` — a file named after a suite
/// that died in shell-finish stage 2b Task 2, when Trash became a foot
/// disclosure and there was nowhere left for a transient segment to return the
/// writer to. This is the class that outlived that file, moved to one of its own
/// in Task 7.
///
/// **Two families of grep census went with the strip in Task 7, and the reason
/// is worth recording rather than leaving as a gap.** Both were about a segment
/// being FORCED — `binderSegment = .documentHome(…)`, `segment = .manuscript`,
/// and the read-shaped `segment == .manuscript || segment == .scenes` that three
/// sites spelled by hand. None of those is writable any more: `BinderSegment`,
/// `documentHome(for:)` and the window's `binderSegment` state were all deleted
/// together, so the enforcement is the compiler rather than a regex over three
/// files. A census whose offender cannot be spelled is not a guard, it is a
/// pattern nobody can trip — and keeping one is how a suite comes to look
/// better-defended than it is.
///
/// What the two tests below still guard is the half a spelling census never
/// could: that the call is **there at all**. Deleting either one leaves no wrong
/// spelling behind — the navigation simply stops happening, the Exports list
/// simply renders everywhere — and every decision test next door stays green.
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

    /// The window's code, by type: every file under `Maugham/` declaring
    /// `ProjectWindow` or one of its free-standing modifiers
    /// (`SourceTree.windowFamilyTypes`), so the receivers are found wherever a
    /// split moves them (foundations plans 2 and 4). Throws when nothing
    /// declares `ProjectWindow`.
    private static let window = "type:ProjectWindow"

    /// `location` is a repo-relative path or a `type:` key.
    private func text(of location: String, base: URL = SourceTree.repoRoot) throws -> String {
        try texts(of: location, base: base).joined(separator: "\n")
    }

    /// `location`'s files, each its own text: a type key's every declaring
    /// file, or the one path. The receiver census slices 25 lines, and a slice
    /// over a JOIN could run off one file's end into the next file's text.
    private func texts(of location: String, base: URL = SourceTree.repoRoot) throws -> [String] {
        if let type = SourceTree.typeName(ofKey: location) {
            // The window's modifiers moved to files of their own (plan 4): the
            // window's code is the family, by type.
            if type == "ProjectWindow" { return try SourceTree.windowSources(base: base) }
            return try SourceTree.sourcesOfType(type, under: ["Maugham"], base: base).map(\.text)
        }
        return [try SourceTree.read(location, base: base)]
    }

    /// The 25 lines from `receiver`'s RECEIVE site, sliced inside the one file
    /// of `texts` that holds it, or nil when none does. See the loop below for
    /// why `window:` picks the receive site out from a post.
    private static func receiverBody(_ receiver: String, in texts: [String]) -> String? {
        for text in texts {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            guard let start = lines.firstIndex(where: {
                $0.contains("(\(receiver),") && $0.contains("window:")
            }) else { continue }
            return lines[start..<min(start + 25, lines.count)].joined(separator: "\n")
        }
        return nil
    }

    /// **Deleting the Exports condition outright leaves no wrong spelling
    /// behind** — the list simply renders under every left column, including
    /// Plan's. Both toggles are named rather than counted.
    ///
    /// **One conjunct since Task 7.** It asserted two: the persona, and an
    /// interim `segment.interimLeftPaneIsTheTree` that mattered while Author
    /// could be FORCED onto a research segment (`openResearchItem`, the MCP note
    /// banner's Show) or restored onto a palette one, neither of which ever
    /// showed an Exports list. Both of those forces are gone — they write the
    /// window's subject now — and so is the segment they wrote, so the persona
    /// is the whole gate.
    func test_bothTogglesStillGateExportsOnAPersonaThatPublishes() throws {
        for path in ["Maugham/Views/BinderPaneToggle.swift",
                     "Maugham/Views/CollectionBinderPaneToggle.swift"] {
            let text = try source(path)
            XCTAssertTrue(text.contains("if persona != .plan"),
                          "\(path): the Exports footer no longer gates on the "
                          + "persona — a compile-output list under Plan's tree "
                          + "is not what a writer arranging structure is doing")
        }
    }

    /// **The other half, and the one a census of offender spellings cannot
    /// see.** Deleting the call outright leaves no wrong spelling behind — the
    /// navigation simply stops, and every decision test next door still passes
    /// on a `ManuscriptNavigation` nothing reaches. So each receiver is asked
    /// whether it still routes through the mechanism that decides the persona
    /// alongside it.
    ///
    /// The receivers are named, not counted — and the third one, added by the
    /// F2 fix, is why. `.maughamNavigateToScene` existed all along, posted by
    /// `SceneNavigatorPane`'s `onSelect` and received only by
    /// `EditorCoordinator`; slice 2 put that navigator in Plan, where no
    /// coordinator exists, so a slugline click did nothing at all. The prose
    /// next door said "three receivers" over a list of two, and that undercount
    /// is precisely what stopped anyone asking about the third.
    ///
    /// **A fourth joined in shell-finish stage 3b, and it is a different
    /// SHAPE on purpose** — `.maughamTreeTravel`'s receiver lives in its own
    /// file (`TreeTravel.swift`, not inline in `ProjectWindow.swift`) and calls
    /// `PersonaModifier.applyPersonaChange(` directly rather than
    /// `ManuscriptNavigation.go(`. That is not a shortcut: `ManuscriptNavigation`
    /// answers "does the CURRENT persona already show a manuscript document",
    /// and the travel rule answers a different question — "is there a persona
    /// to travel TO at all" (`Persona.centresTheCanvas`, the same discriminator,
    /// asked directly). Routing the tree's double-click through
    /// `ManuscriptNavigation` would let that rule decide a premise it was never
    /// asked about. So the table below carries a (file, call) pair per
    /// receiver rather than assuming both are constant — the moment a second
    /// receiver shape exists, "the census reads one file for one call" is
    /// itself the thing that goes stale silently.
    func test_everyNavigationReceiverStillRoutesThroughTheNavigation() throws {
        struct Expectation {
            let receiver: String
            let file: String
            let call: String
        }
        let expectations = [
            Expectation(receiver: ".maughamNavigateToDocument",
                       file: Self.window,
                       call: "ManuscriptNavigation.go("),
            Expectation(receiver: ".maughamNavigateToParagraph",
                       file: Self.window,
                       call: "ManuscriptNavigation.go("),
            Expectation(receiver: ".maughamNavigateToScene",
                       file: Self.window,
                       call: "ManuscriptNavigation.go("),
            Expectation(receiver: ".maughamTreeTravel",
                       file: "Maugham/Views/TreeTravel.swift",
                       call: "PersonaModifier.applyPersonaChange("),
        ]
        for expectation in expectations {
            let fileTexts = try texts(of: expectation.file)
            // The RECEIVE site, not any POST site in the same file — every
            // `.onKeyWindowCommand`/`.onProjectEvent`/`.onDocumentEvent`
            // registration takes a `window:` argument on the same line and a
            // `MaughamEvent.post(...)` call never does (it takes `to:`
            // instead). `.maughamTreeTravel` is posted AND received in the
            // same file (`TreeTravel.swift`) with the post appearing first,
            // so the bare `(\(receiver),` substring alone found the post —
            // caught by this test itself failing against its own new entry
            // before this line existed.
            let body = try XCTUnwrap(
                Self.receiverBody(expectation.receiver, in: fileTexts),
                "\(expectation.receiver): no receiver for it at all in "
                + "\(expectation.file)")
            XCTAssertTrue(body.contains(expectation.call),
                          "\(expectation.receiver) no longer routes through "
                          + "\(expectation.call), so it moves the window "
                          + "without deciding the persona — or has stopped "
                          + "moving it at all")
        }
    }

    /// The control both tests above need, and the one an absence-shaped
    /// assertion always needs: the files are really being read. A path typo
    /// makes `contains` false and `firstIndex` nil, which is a failure here and
    /// a silent pass for any census written the other way round.
    func test_theCensusIsReadingRealFiles() throws {
        for path in ["Maugham/Views/BinderPaneToggle.swift",
                     "Maugham/Views/CollectionBinderPaneToggle.swift",
                     Self.window,
                     "Maugham/Views/TreeTravel.swift"] {
            XCTAssertFalse(try text(of: path).isEmpty, "\(path): read nothing")
        }
    }

    /// **The planted control for the window's receivers** (foundations plan 2):
    /// a `ProjectWindow` struct in one file and a receiver in an
    /// `extension ProjectWindow` in another. The receiver is found across the
    /// extension, a POST of the same name (no `window:`) is not taken for it,
    /// and a type nothing declares throws rather than reading an empty string.
    func test_theReceiverCensusReadsTheTypeAcrossItsExtensions() throws {
        let base = try SourceTree.plantedTree([
            "Maugham/Views/ProjectWindow.swift": """
            struct ProjectWindow: View {
                var body: some View { EmptyView() }
                func post() { MaughamEvent.post(.maughamNavigateToScene, to: .keyWindow) }
            }
            """,
            "Maugham/Views/ProjectWindow+Navigation.swift": """
            extension ProjectWindow {
                func receivers(_ v: some View) -> some View {
                    v.onKeyWindowCommand(.maughamNavigateToDocument, window: window) { _ in
                        ManuscriptNavigation.go(to: destination)
                    }
                }
            }
            """,
        ])
        let windowText = try texts(of: Self.window, base: base)
        let body = try XCTUnwrap(Self.receiverBody(".maughamNavigateToDocument", in: windowText),
                                 "the receiver in the extension is the window's")
        XCTAssertTrue(body.contains("ManuscriptNavigation.go("))
        XCTAssertNil(Self.receiverBody(".maughamNavigateToScene", in: windowText),
                     "a post is not a receiver")
        XCTAssertThrowsError(try self.text(of: "type:NotAWindow", base: base))
    }

    /// **The 25-line slice stays inside its file** (plan 2 final review, M2):
    /// a receiver near the END of one window file must not borrow the routing
    /// call from the next file's text.
    func test_theReceiverSliceNeverRunsIntoTheNextFile() throws {
        let base = try SourceTree.plantedTree([
            "Maugham/Views/ProjectWindow+A.swift": """
            extension ProjectWindow {
                func receivers(_ v: some View) -> some View {
                    v.onKeyWindowCommand(.maughamNavigateToDocument, window: window) { _ in }
                }
            }
            """,
            "Maugham/Views/ProjectWindow+B.swift": """
            extension ProjectWindow {
                func elsewhere() { ManuscriptNavigation.go(to: destination) }
            }
            """,
        ])
        let body = try XCTUnwrap(Self.receiverBody(".maughamNavigateToDocument",
                                                   in: try texts(of: Self.window, base: base)))
        XCTAssertFalse(body.contains("ManuscriptNavigation.go("),
                       "the next file's call must not answer for this receiver: \(body)")
        XCTAssertTrue(Self.receiverBody(".maughamNavigateToDocument",
                                        in: [try text(of: Self.window, base: base)])?
                        .contains("ManuscriptNavigation.go(") ?? false,
                      "precondition: over the JOIN it would have")
    }
}
