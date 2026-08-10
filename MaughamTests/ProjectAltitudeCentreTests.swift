import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **The centre column shows the project at altitude** (shell-finish stage 3a
/// Task 2) — and it does so from INSIDE the editor arm rather than as an arm of
/// its own.
///
/// Two things are under test and they need different instruments:
///
/// - **The rule.** `ProjectWindow.subjectShowsAltitude` is a static over
///   `(persona, subject, structure)`, so every shape of subject is assertable
///   with no window at all. It is written as the complement of
///   `selectionIsDocument`, which is why the tests below check the two agree
///   rather than re-spelling what a document is.
/// - **The shape.** A sixth `editorPane` arm would be a distinct SwiftUI view
///   identity, and flipping to it runs `EditorHost`'s `.onDisappear` teardown —
///   `doc.close()`, `documentStore.unregister`, `loads.abandon()` — on a
///   project ↔ chapter hop the writer makes constantly. The mount is therefore
///   a `ZStack` inside `manuscriptEditor`: the host stays mounted underneath in
///   its placeholder arm and altitude covers it. The mounted tests drive that
///   shape and count the host's lifetimes, and the control below drives the
///   REJECTED shape through the same round trip so the counter is proven able
///   to see the failure it is asserting the absence of.
///
/// **What a mounted test in this host cannot see**, recorded so the next reader
/// does not go looking: `EditorHost`'s placeholder is a bare `Text`, and a bare
/// `Text` outside a `List` row materializes no `NSView` and no accessibility
/// element in the `xcodebuild` test host (measured for this SDK in
/// `ProjectAltitudePaneTests` and `BinderProjectRowTests`). So "the *Select a
/// document.* placeholder is not visible" is not observable as a string. What
/// IS observable is that the altitude pane's own real AppKit view is what the
/// centre of the column hit-tests to — z-order and hit absorption, measured on
/// the delivery path — with the opaqueness of its background pinned by the
/// source census at the foot of this file.
@MainActor
final class ProjectAltitudeCentreTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        // This suite mounts `EditorHost`, which styles text through production
        // typography (the fontd cold-start window, CLAUDE.md).
        FontWarmup.ensure()
    }

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []
    private var documentStores: [DocumentStore] = []

    override func setUp() async throws { temp = TempDirectory() }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        for ds in documentStores { await ds.close() }
        documentStores.removeAll()
        temp.cleanup()
        temp = nil
    }

    // MARK: - The rule

    /// **The four subject shapes that resolve to no single document.** Every one
    /// of them left the centre column showing `EditorHost`'s "Select a
    /// document." placeholder before this task, which is the degrade the
    /// altitude view replaces.
    func test_everySubjectThatIsNotADocumentShowsAltitude() {
        for persona in Self.manuscriptPersonas {
            for (subject, shape) in Self.notADocument {
                XCTAssertTrue(
                    ProjectWindow.subjectShowsAltitude(
                        persona: persona, subject: subject,
                        structure: Self.structure),
                    "\(persona) with \(shape): the centre column has no document "
                    + "to put in it, so it shows the project at altitude")
            }
        }
    }

    /// The other side of the same rule, and the one the writer is in for most of
    /// their hours: a document subject is the editor and nothing else.
    func test_aDocumentSubjectIsTheEditorAndNeverAltitude() {
        for persona in Self.manuscriptPersonas {
            XCTAssertFalse(
                ProjectWindow.subjectShowsAltitude(
                    persona: persona, subject: .item("chapter-1"),
                    structure: Self.structure),
                "\(persona): a chapter is a document, and the editor is what "
                + "opens on it")
        }
    }

    /// **The rule is the complement of `selectionIsDocument`, not a second
    /// opinion about what a document is.** A `.item` whose `path` is nil is the
    /// case that makes this more than a tautology: `selectionIsDocument` refuses
    /// it, so altitude takes it — the centre shows the project rather than an
    /// editor bound to a document with nowhere to save.
    func test_theRuleIsTheComplementOfTheWindowsOwnDocumentQuestion() {
        let subjects: [BinderSubject?] = [
            nil, .project, .item("chapter-1"), .item("part-one"),
            .item("pathless"), .item("no-such-id"), .research("res-1")
        ]
        for subject in subjects {
            XCTAssertEqual(
                ProjectWindow.subjectShowsAltitude(
                    persona: .author, subject: subject, structure: Self.structure),
                !ProjectWindow.selectionIsDocument(subject, in: Self.structure),
                "\(String(describing: subject)): altitude is exactly 'the "
                + "subject is not a manuscript document', so the two must not "
                + "be able to disagree")
        }
    }

    /// **Plan's centre is the board.** `centresTheCanvas` decides that above
    /// everything, and altitude is what the manuscript personas show INSTEAD of
    /// a document — not a fifth centre-column surface that could reach Plan.
    func test_planNeverShowsAltitudeWhateverTheSubject() {
        for (subject, shape) in Self.notADocument {
            XCTAssertFalse(
                ProjectWindow.subjectShowsAltitude(
                    persona: .plan, subject: subject, structure: Self.structure),
                "Plan with \(shape): the centre column is the canvas")
        }
    }

    /// **A research subject never reaches this question, and the proof is a pair
    /// rather than a guard.** `editorPane` asks `researchSubjectPlacement`
    /// first: in any persona that reaches the editor arm the research item has
    /// already taken the centre, and in the one that does not (Plan) altitude
    /// has already refused on the persona. Written over `Persona.allCases` so a
    /// fifth persona has to answer it too.
    func test_aResearchSubjectIsTakenByTheArmAboveInEveryPersona() {
        for persona in Persona.allCases {
            let takenAbove = ProjectWindow.researchSubjectPlacement(
                persona: persona, subject: .research("res-1")).centreItemID != nil
            XCTAssertTrue(
                takenAbove || !persona.showsManuscriptDocuments,
                "\(persona): a research subject must be answered before the "
                + "editor arm — either the research placement takes the centre, "
                + "or the persona's centre is not a document at all. Neither "
                + "holding means `subjectShowsAltitude` has become reachable "
                + "with a research subject, and it would answer TRUE")
        }
    }

    /// **A Collection's reference piece is a document, and altitude does not
    /// swallow it.** Its own arm sits between the canvas and the editor in
    /// `editorPane`; this pins both halves — the route still names that arm, and
    /// the rule underneath would not have claimed the subject anyway.
    func test_aCollectionReferencePieceKeepsItsOwnArm() {
        let reference = StructureItem(
            id: "piece-ref", title: "Linked", type: .document,
            path: "pieces/ref/manuscript.md", pieceKind: .reference)

        XCTAssertEqual(
            ProjectWindow.editorRoute(persona: .author, projectType: .collection,
                                      selectedPieceIsReference: true),
            .collectionReference,
            "the reference arm is still the route")
        XCTAssertFalse(
            ProjectWindow.subjectShowsAltitude(
                persona: .author, subject: .item(reference.id),
                structure: [reference]),
            "and the rule under it does not claim the subject either — a "
            + "reference piece is a document, so even with the arms reordered "
            + "altitude could not swallow it")
    }

    // MARK: - The status footer

    /// **The footer refuses while altitude shows** — and the argument is the doc
    /// comment's own: all four of its readings are about a manuscript document
    /// (a goal capsule, the live session words, the `¶id` under the cursor, the
    /// current element). Over the corkboard the first is about something else
    /// and the last two are blank, so the strip would be a row of claims the
    /// centre column cannot support.
    ///
    /// The clause that already stood here answered TRUE for `.project` — it asks
    /// only whether a RESEARCH item took the centre — so without this the word
    /// count floated over the altitude view.
    func test_theStatusFooterRefusesWhileTheCentreShowsAltitude() {
        for persona in Self.manuscriptPersonas {
            XCTAssertTrue(
                ProjectWindow.showsStatusFooter(
                    persona: persona, subject: .item("chapter-1"),
                    showsPaletteWall: false, structure: Self.structure),
                "control: \(persona) over a document still reports")
            for (subject, shape) in Self.notADocument {
                XCTAssertFalse(
                    ProjectWindow.showsStatusFooter(
                        persona: persona, subject: subject,
                        showsPaletteWall: false, structure: Self.structure),
                    "\(persona) with \(shape): the centre shows altitude, and "
                    + "the footer's four readings are all about a document")
            }
        }
    }

    // MARK: - Fixtures for the rule

    /// A structure with one document, one group, and a document whose `path` is
    /// nil — the three cases `selectionIsDocument` distinguishes.
    static let structure: [StructureItem] = [
        StructureItem(id: "chapter-1", title: "Chapter One", type: .document,
                      path: "manuscript/chapter-1.md"),
        StructureItem(id: "part-one", title: "Part One", type: .group,
                      children: []),
        StructureItem(id: "pathless", title: "Broken", type: .document, path: nil)
    ]

    /// Every subject shape that resolves to no single document, with the name to
    /// put in the failure message.
    static let notADocument: [(BinderSubject?, String)] = [
        (nil, "no subject at all"),
        (.project, "the project itself"),
        (.item("part-one"), "a group"),
        (.item("no-such-id"), "a dangling id"),
        (.item("pathless"), "a document with no path")
    ]

    /// The personas whose centre column holds a document — derived from the rule
    /// rather than named, so a fifth persona joins without an edit here.
    static let manuscriptPersonas: [Persona] =
        Persona.allCases.filter(\.showsManuscriptDocuments)
}
