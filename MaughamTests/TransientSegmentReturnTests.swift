import XCTest
import AppKit
import SwiftUI
import Observation
import MaughamCore
@testable import Maugham

/// The binder's segment and the find flag, outside the view, so a test can flip
/// the one production flips and watch what the toggle writes back through the
/// other. At file scope because `@Observable` cannot expand inside a `private`
/// nested type.
@Observable
@MainActor
final class TransientExitBox {
    var segment: BinderSegment
    var findActive: Bool
    init(segment: BinderSegment, findActive: Bool) {
        self.segment = segment
        self.findActive = findActive
    }
}

/// **Where does the writer land when a transient segment ends?**
///
/// Find and Trash are states, not surfaces (`BinderSegment.isTransient`), and
/// both toggles put the binder somewhere else the moment the state ends — find
/// closed, or the trash emptied under the writer. Until slice 2 task 5 that
/// somewhere was `BinderSegment.documentHome(for:)`, which is the same value as
/// the binder home in Author, Review and Publish and is **the manuscript editor
/// in Plan** — Denver's 2026-08-02 ruling arrived at from the other side:
/// `⌘⌥F`, escape, and the writer is writing the manuscript in Plan.
///
/// **This is a return, not a navigation**, which is why it is not
/// `ManuscriptNavigation`: closing find names no document (it fires with no
/// match ever clicked), so nobody is moved to Author for it. The answer is the
/// persona's own home.
///
/// **Driven through the flag production flips, on the real mounted toggle.** The
/// `.onChange` under test cannot be reached from the view's data — it is a
/// modifier on a `body` — and the ✕ button and `.maughamCloseFind` are two routes
/// out of one state, so the toggle is where both of them land.
@MainActor
final class TransientSegmentReturnTests: XCTestCase {

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        temp = TempDirectory()
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        temp.cleanup()
        temp = nil
    }

    // MARK: - Closing find

    /// **The defect, in the persona it was in.** Plan's binder home is the
    /// canvas; the manuscript segment is not even in Plan's registry.
    func test_closingFindInPlanReturnsToPlansHomeAndNotToTheManuscript() async throws {
        for type in ProjectType.allCases where type != .unknown {
            let box = try await closeFind(persona: .plan, type: type)
            XCTAssertEqual(box.segment, Persona.plan.binderHome(for: type),
                           "\(type): closing find in Plan must return to Plan's "
                           + "own home")
            XCTAssertNotEqual(box.segment, .documentHome(for: type),
                              "\(type): landing on the document home puts a text "
                              + "editor in the centre of the persona that does "
                              + "not draft")
        }
    }

    /// **The control: nothing moved for anybody else.** Author, Review and
    /// Publish each offer exactly their document home, so the persona's home and
    /// the document home are the same segment and this change is invisible to
    /// them. If this ever goes red the fix has moved a writer who was already in
    /// the right place.
    func test_closingFindEverywhereElseLandsExactlyWhereItAlwaysDid() async throws {
        for persona in [Persona.author, .review, .publish] {
            for type in ProjectType.allCases where type != .unknown {
                let box = try await closeFind(persona: persona, type: type)
                XCTAssertEqual(box.segment, .documentHome(for: type),
                               "\(persona)/\(type): unchanged behaviour")
            }
        }
    }

    // MARK: - Driving it

    /// Mounts the binder shell production mounts for this type, sitting in Find,
    /// then clears the flag the ✕ button clears.
    private func closeFind(persona: Persona,
                           type: ProjectType) async throws -> TransientExitBox {
        let store = try await project(of: type)
        let box = TransientExitBox(segment: .find, findActive: true)
        let window = host(TransientExitProbeView(store: store, box: box,
                                                 persona: persona))
        XCTAssertEqual(box.segment, .find, "premise: the binder is in find")

        box.findActive = false
        await waitOut(0.4)
        _ = window
        return box
    }

    private func project(of type: ProjectType) async throws -> ProjectStore {
        let name = "\(type.rawValue)-\(UUID().uuidString.prefix(6))"
        let url: URL
        switch type {
        case .shortStory:
            url = try await ProjectFactory.createShortStoryProject(named: name, in: temp.url)
        case .novel:
            url = try await ProjectFactory.createNovelProject(named: name, in: temp.url)
        case .screenplay:
            url = try await ProjectFactory.createScreenplayProject(named: name, in: temp.url)
        case .collection:
            url = try await ProjectFactory.createCollectionProject(named: name, in: temp.url)
        case .unknown:
            throw XCTSkip("`.unknown` is excluded from allCases and cannot be created")
        }
        let store = try await ProjectStore.load(from: url)
        await store.wordCountPopulationTask?.value
        return store
    }

    private func host(_ view: some View) -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        pump(0.15)
        return window
    }

    private func waitOut(_ seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            pump(0.02)
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func pump(_ seconds: TimeInterval = 0.15) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}

/// The left column as `ProjectWindow.binderColumn` builds it, with the find flag
/// hoisted out so a test can clear it.
@MainActor
private struct TransientExitProbeView: View {
    let store: ProjectStore
    let box: TransientExitBox
    let persona: Persona
    @State private var subject: BinderSubject?
    @State private var researchId: String?
    @State private var paletteCardId: String?
    @State private var renamingItemId: String?

    private var segment: Binding<BinderSegment> {
        Binding(get: { box.segment }, set: { box.segment = $0 })
    }

    private var findActive: Binding<Bool> {
        Binding(get: { box.findActive }, set: { box.findActive = $0 })
    }

    var body: some View {
        Group {
            switch ProjectWindow.BinderShell.shell(for: store.manifest.type) {
            case .standard:
                BinderPaneToggle(
                    store: store,
                    segment: segment,
                    selectedSubject: $subject,
                    selectedResearchId: $researchId,
                    selectedPaletteCardId: $paletteCardId,
                    projectType: store.manifest.type,
                    lastParsedScript: nil,
                    findActive: findActive,
                    persona: persona)
            case .collection:
                CollectionBinderPaneToggle(
                    store: store,
                    segment: segment,
                    selectedSubject: $subject,
                    selectedResearchId: $researchId,
                    selectedPaletteCardId: $paletteCardId,
                    findActive: findActive,
                    renamingItemId: $renamingItemId,
                    activePiece: nil,
                    onAddSharedNote: {},
                    onAddPieceNote: {},
                    persona: persona)
            }
        }
    }
}

/// **The census: no site forces the binder onto the manuscript on its own.**
///
/// Five sites force the binder home and the brief named three of them; the two
/// that were missed are the toggles' own `.onChange`s, which no persona write
/// could ever have reached because they are inside a view with no `persona`
/// binding — and one of them (`findActive`) fires on the SAME writer action as
/// `.maughamCloseFind`, so a fix applied to one and not the other is two routes
/// out of one state disagreeing.
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
    /// The footer now asks `BinderSegment.showsManuscriptStatusFooter` (a
    /// switch, because a future segment centring the editor has to be asked)
    /// and both Exports gates ask `documentHome(for:)` (a derivation, because
    /// "not the manuscript tree, so no Exports list" needs no asking). Neither
    /// spelling is writable in these three files any more.
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
    func test_bothTogglesStillGateExportsOnTheDocumentHome() throws {
        for path in ["Maugham/Views/BinderPaneToggle.swift",
                     "Maugham/Views/CollectionBinderPaneToggle.swift"] {
            let text = try source(path)
            XCTAssertTrue(text.contains("segment == .documentHome(for:"),
                          "\(path): the Exports footer no longer gates on the "
                          + "project's document home")
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
