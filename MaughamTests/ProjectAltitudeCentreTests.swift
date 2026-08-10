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
    private var defaultsSuites: [String] = []

    override func setUp() async throws { temp = TempDirectory() }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        for ds in documentStores { await ds.close() }
        documentStores.removeAll()
        for suite in defaultsSuites {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        defaultsSuites.removeAll()
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

    /// **A Collection's reference piece keeps its own arm, and the ARM is what
    /// protects it — not the rule underneath.**
    ///
    /// A resolved reference is a document, so the rule would refuse it anyway.
    /// An unresolved one — no `path`, which is the shape a Collection's manifest
    /// carries for a link whose target it cannot reach — is not, and the rule
    /// alone would hand it to altitude. What keeps `ReferencePlaceholderCard` on
    /// screen either way is that its arm sits ABOVE the editor arm in
    /// `editorPane`. Both halves are asserted here so the second is a recorded
    /// dependency on the ordering rather than a surprise; the mounted half
    /// drives the unresolved one through the arms.
    func test_aCollectionReferencePieceKeepsItsOwnArm() {
        let resolved = StructureItem(
            id: "piece-ref", title: "Linked", type: .document,
            path: "pieces/ref/.maugham-link.json", pieceKind: .reference)
        let unresolved = StructureItem(
            id: "piece-lost", title: "Elsewhere", type: .document,
            path: nil, pieceKind: .reference)

        XCTAssertEqual(
            ProjectWindow.editorRoute(persona: .author, projectType: .collection,
                                      selectedPieceIsReference: true),
            .collectionReference,
            "the reference arm is still the route, and it is taken above the "
            + "editor arm altitude lives inside")
        XCTAssertFalse(
            ProjectWindow.subjectShowsAltitude(
                persona: .author, subject: .item(resolved.id),
                structure: [resolved]),
            "a resolved reference is a document, so the rule under the arm "
            + "would not have claimed it either")
        XCTAssertTrue(
            ProjectWindow.subjectShowsAltitude(
                persona: .author, subject: .item(unresolved.id),
                structure: [unresolved]),
            "…but an UNRESOLVED one is not a document by the rule's reckoning, "
            + "which is exactly why the placeholder's protection has to be the "
            + "arm order rather than this predicate")
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
    func test_theFootersFourReadingsAreAboutADocumentSoAltitudeSilencesIt() {
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

    // MARK: - Mounted: the round trip the writer makes

    /// **The gesture this task creates, made twice, with the host counted.**
    ///
    /// Project → chapter → project: altitude, then the editor, then altitude
    /// again — and across the whole trip `EditorHost` appears once and
    /// disappears never. That last number is the point of the layered shape:
    /// `EditorHost.onDisappear` closes the open `Document`, unregisters its path
    /// and abandons any load in flight, so a shape that unmounts it here pays
    /// that on every hop between the project and a chapter.
    ///
    /// The editor's own presence is read as a `MaughamTextView`, which exists
    /// only while a document is actually open — so its ABSENCE at altitude is
    /// also the assertion that the host is sitting in the placeholder arm the
    /// overlay covers, rather than holding a document nobody asked for.
    func test_theProjectChapterProjectRoundTripNeverTearsTheHostDown() async throws {
        let store = try await novel()
        let chapter = try Self.firstDocument(in: store)
        let mount = try await host(store: store, subject: .project)

        await pumpUntil(deadline: 5) { self.altitudeTable(in: mount.window) != nil }
        let table = try XCTUnwrap(altitudeTable(in: mount.window),
                                  "the project's own subject must draw the "
                                  + "altitude view, not 'Select a document.'")
        XCTAssertEqual(table.numberOfRows, Self.documentCount(in: store),
                       "one row per document — the altitude view is about the "
                       + "whole project")
        XCTAssertTrue(textViews(in: mount.window).isEmpty,
                      "and no editor is open underneath: the host is in the "
                      + "placeholder arm, which is what the overlay covers")
        XCTAssertEqual(mount.hostLife.appearances, 1, "premise: the host mounted")
        XCTAssertEqual(mount.hostLife.disappearances, 0, "premise: and is still up")

        mount.probe.subject = .item(chapter.id)
        await pumpUntil(deadline: 5) { !self.textViews(in: mount.window).isEmpty }
        XCTAssertFalse(textViews(in: mount.window).isEmpty,
                       "the chapter opens in the editor")
        XCTAssertNil(altitudeTable(in: mount.window),
                     "…and altitude is gone, not sitting over the writer's text")

        mount.probe.subject = .project
        await pumpUntil(deadline: 5) { self.altitudeTable(in: mount.window) != nil }
        XCTAssertNotNil(altitudeTable(in: mount.window),
                        "and back up to the project")

        XCTAssertEqual(
            mount.hostLife.disappearances, 0,
            "the host was never torn down across the round trip — a teardown "
            + "here is `doc.close()`, `unregister(path:)` and `loads.abandon()` "
            + "on a gesture the writer makes all day")
        XCTAssertEqual(
            mount.hostLife.appearances, 1,
            "…and never re-appeared either, so it is the same host with the "
            + "same Document rather than a fresh one that reloaded from disk")
    }

    /// **The control that makes the zero above mean something.**
    ///
    /// The same round trip through the shape this task rejected — a sixth arm,
    /// altitude and the editor in two branches of one conditional. The counter
    /// is the same counter; if it could not see a teardown, the assertion above
    /// would be green over any shape at all. It sees this one.
    func test_control_theRejectedSixthArmTearsTheHostDownOnTheSameRoundTrip() async throws {
        let store = try await novel()
        let chapter = try Self.firstDocument(in: store)
        let mount = try await host(store: store, subject: .project, shape: .sixthArm)

        await pumpUntil(deadline: 5) { self.altitudeTable(in: mount.window) != nil }
        mount.probe.subject = .item(chapter.id)
        await pumpUntil(deadline: 5) { self.textViews(in: mount.window).isEmpty == false }
        XCTAssertEqual(mount.hostLife.appearances, 1,
                       "premise: the arm shape mounts the host on the way down")

        mount.probe.subject = .project
        await pumpUntil(deadline: 5) { self.altitudeTable(in: mount.window) != nil }

        XCTAssertGreaterThanOrEqual(
            mount.hostLife.disappearances, 1,
            "the arm shape tears the host down on the way back up — which is "
            + "what the layered shape's zero is measured against, and why this "
            + "test exists rather than a comment saying an arm would be worse")
    }

    /// **The overlay is what the centre of the column hit-tests to.** The
    /// placeholder underneath leaves no view and no accessibility element to
    /// look for (see this file's doc comment), so coverage is measured the way
    /// the OS measures it: the topmost view at the middle of the column belongs
    /// to the altitude pane's own scroll view, not to whatever the host is
    /// drawing behind it.
    func test_theAltitudeOverlayIsWhatTheCentreOfTheColumnHitTests() async throws {
        let store = try await novel()
        let mount = try await host(store: store, subject: .project)
        await pumpUntil(deadline: 5) { self.altitudeTable(in: mount.window) != nil }
        let table = try XCTUnwrap(altitudeTable(in: mount.window))
        let scroller = try XCTUnwrap(table.enclosingScrollView,
                                     "premise: the altitude table scrolls")

        let content = try XCTUnwrap(mount.window.contentView)
        // The premise, read off the window this display actually granted rather
        // than the one asked for: `NSWindow` clamps to the screen, and CI's is
        // narrower than this Mac's. A column too small to have a middle worth
        // asking about is a display that cannot afford the question.
        try XCTSkipUnless(
            content.bounds.width >= 300 && content.bounds.height >= 300,
            "this display mounted a \(content.bounds.size) centre column")
        let middle = NSPoint(x: content.bounds.midX, y: content.bounds.midY)
        let hit = try XCTUnwrap(content.hitTest(content.convert(middle, to: nil)),
                                "nothing at all at the middle of the column")

        XCTAssertTrue(
            hit === scroller || hit.isDescendant(of: scroller),
            "the middle of the centre column hit-tests to \(type(of: hit)), "
            + "which is not part of the altitude pane — so the overlay is "
            + "either not covering the column or not absorbing what lands on it")
    }

    /// **A group shows altitude too** — the degrade rule. `EditorHost`'s answer
    /// for a group is its own placeholder ("Select a document inside this group
    /// to edit."), which is exactly as much use as the other one.
    func test_aGroupSubjectShowsAltitudeRatherThanAPlaceholder() async throws {
        let store = try await novel()
        let group = try await store.addStructureItem(
            parentId: nil, title: "Part One", kind: .group)
        let mount = try await host(store: store, subject: .item(group.id))

        await pumpUntil(deadline: 5) { self.altitudeTable(in: mount.window) != nil }
        XCTAssertNotNil(altitudeTable(in: mount.window),
                        "a group names no document, so the centre shows the "
                        + "project at altitude")
        XCTAssertTrue(textViews(in: mount.window).isEmpty,
                      "and no editor is open behind it")
    }

    /// **Review and Publish show the same altitude for the project** — the
    /// recorded decision: Review's overview is M3's and Publish's preview is
    /// 3b's, and until they exist the degrade is what keeps the centre column
    /// from rendering nothing at all.
    func test_reviewAndPublishShowTheSameAltitudeAsAuthor() async throws {
        for persona in Self.manuscriptPersonas where persona != .author {
            let store = try await novel()
            let mount = try await host(store: store, persona: persona,
                                       subject: .project)
            await pumpUntil(deadline: 5) { self.altitudeTable(in: mount.window) != nil }
            let table = try XCTUnwrap(
                altitudeTable(in: mount.window),
                "\(persona): the centre column would otherwise render nothing "
                + "but 'Select a document.' for the project's own subject")
            XCTAssertEqual(table.numberOfRows, Self.documentCount(in: store),
                           "\(persona): and it is the same altitude view, with "
                           + "the same rows, rather than a persona's own")
        }
    }

    /// **Plan is untouched.** `centresTheCanvas` takes the canvas arm above the
    /// editor arm, so the project's own subject in Plan is the board — mounted,
    /// because the pure rule refusing on the persona would be equally green over
    /// a window that put altitude there anyway.
    func test_planStillMountsTheBoardForTheProjectSubject() async throws {
        let store = try await novel()
        let mount = try await host(store: store, persona: .plan, subject: .project)

        await pumpUntil(deadline: 5) { !self.canvasViews(in: mount.window).isEmpty }
        XCTAssertFalse(canvasViews(in: mount.window).isEmpty,
                       "Plan's centre column is the board")
        XCTAssertNil(altitudeTable(in: mount.window),
                     "…and altitude never reaches it")
        XCTAssertEqual(mount.hostLife.appearances, 0,
                       "nor does the editor — the canvas arm is taken above it")
    }

    /// **An unresolved Collection reference still gets its own card.** The rule
    /// alone would claim it (no `path`, so not a document); the arm above the
    /// editor arm is what keeps `ReferencePlaceholderCard` on screen, and this
    /// drives that ordering rather than trusting it.
    func test_anUnresolvedReferencePieceStillTakesItsOwnArm() async throws {
        let store = try await collectionWithAnUnresolvedReference()
        let reference = try XCTUnwrap(
            store.manifest.structure.first { $0.pieceKind == .reference })
        let mount = try await host(store: store, subject: .item(reference.id))

        // A SwiftUI `Button` mounts no discrete `NSButton` on this SDK — what it
        // leaves is one focus-ring container per button, which is the signal
        // `ProjectAltitudePaneTests` already had to reach for. The card carries
        // exactly one button ("Open in New Window").
        await pumpUntil(deadline: 5) { !self.focusRings(in: mount.window).isEmpty }
        XCTAssertFalse(
            focusRings(in: mount.window).isEmpty,
            "the reference card's own button never mounted, so the arm was not "
            + "taken. Views present: \(viewNames(in: mount.window))")
        XCTAssertNil(altitudeTable(in: mount.window),
                     "…and altitude did not swallow the piece on its way past")
        XCTAssertTrue(textViews(in: mount.window).isEmpty,
                      "…nor did the editor open on a piece it cannot resolve")
    }

    // MARK: - Hosting

    private struct Mount {
        let window: NSWindow
        let probe: BinderSubjectProbe
        let hostLife: EditorHostLifeCounter
    }

    /// The centre column alone, wired the way `editorPane` wires it: every
    /// routing decision below the mount comes from production's own statics, and
    /// the subject is held outside the view so a test can move it without a tree.
    ///
    /// **No tree column on purpose.** The tree writes the subject and nothing
    /// else, and `ResearchSubjectRoutingTests` already drives real rows through
    /// it; here the only `NSTableView` in the window is the altitude view's own,
    /// which is what makes "altitude is showing" a one-line reading.
    private func host(store: ProjectStore,
                      persona: Persona = .author,
                      subject: BinderSubject? = nil,
                      shape: AltitudeCentreProbeView.Shape = .layered)
    async throws -> Mount {
        let documentStore = try await DocumentStore.open(url: store.url)
        store.documentStore = documentStore
        documentStores.append(documentStore)

        let probe = BinderSubjectProbe(subject)
        let life = EditorHostLifeCounter()
        // `EditorHost` reads `UserPreferences` out of the environment, and a
        // missing environment value is a trap in SwiftUI's own accessor rather
        // than a nil — the whole test process goes down. Its own defaults suite,
        // so nothing here reads or writes the developer's.
        let suite = "project-altitude-centre-\(UUID().uuidString)"
        defaultsSuites.append(suite)
        let preferences = UserPreferences(defaults: UserDefaults(suiteName: suite)!)
        let root = AltitudeCentreProbeView(
            store: store, documentStore: documentStore, persona: persona,
            probe: probe, shape: shape, hostLife: life,
            canvasModel: CanvasModel())
            .environment(preferences)

        let frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        let hosting = NSHostingView(rootView: AnyView(root))
        hosting.frame = frame
        let window = SilentTestWindow(contentRect: frame, styleMask: [.titled],
                                      backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        pump(0.1)
        return Mount(window: window, probe: probe, hostLife: life)
    }

    // MARK: - Reading the mounted window

    /// The altitude view in its table layout. The probe hosts the centre column
    /// only, so this is the window's one table.
    private func altitudeTable(in window: NSWindow) -> NSTableView? {
        collect(NSTableView.self, in: window).first
    }

    private func textViews(in window: NSWindow) -> [MaughamTextView] {
        collect(MaughamTextView.self, in: window)
    }

    private func canvasViews(in window: NSWindow) -> [CanvasEventNSView] {
        collect(CanvasEventNSView.self, in: window)
    }

    /// One per SwiftUI `Button` in the window — see the reference-arm test for
    /// why the button itself is not what mounts.
    private func focusRings(in window: NSWindow) -> [NSView] {
        collect(NSView.self, in: window)
            .filter { String(describing: type(of: $0)).contains("FocusRingView") }
    }

    /// For a failure message that says what DID mount rather than only what did
    /// not — the difference between a signal that moved and an arm that was
    /// never taken.
    private func viewNames(in window: NSWindow) -> [String] {
        collect(NSView.self, in: window).map { String(describing: type(of: $0)) }
    }

    private func collect<T: NSView>(_ type: T.Type, in window: NSWindow) -> [T] {
        guard let root = window.contentView else { return [] }
        var found: [T] = []
        collect(type, in: root, into: &found)
        return found
    }

    private func collect<T: NSView>(_ type: T.Type, in view: NSView, into out: inout [T]) {
        if let hit = view as? T { out.append(hit) }
        for sub in view.subviews { collect(type, in: sub, into: &out) }
    }

    // MARK: - Fixtures on disk

    private func novel() async throws -> ProjectStore {
        let url = try await ProjectFactory.createNovelProject(
            named: "Altitude-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        _ = try await store.addStructureItem(
            parentId: nil, title: "Chapter Two", kind: .document(extension: "md"))
        await store.wordCountPopulationTask?.value
        return store
    }

    /// A Collection holding one reference piece the project cannot resolve — the
    /// shape a manifest carries for a link whose target has moved, written
    /// straight to disk because minting a real one needs a security-scoped
    /// bookmark to a second project.
    private func collectionWithAnUnresolvedReference() async throws -> ProjectStore {
        let url = temp.url.appendingPathComponent("Collection-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let manifest = ProjectManifest(
            type: .collection, title: "Anthology", author: "A",
            created: Date(), modified: Date(),
            structure: [StructureItem(id: "piece-lost", title: "Elsewhere",
                                      type: .document, path: nil,
                                      pieceKind: .reference)],
            research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: url.appendingPathComponent("project.maugham.json"))
        return try await ProjectStore.load(from: url)
    }

    private static func firstDocument(in store: ProjectStore) throws -> StructureItem {
        try XCTUnwrap(
            TreeWalk.first(in: store.manifest.structure, where: { $0.type == .document }),
            "fixture precondition: a novel opens with a chapter")
    }

    private static func documentCount(in store: ProjectStore) -> Int {
        TreeWalk.collect(in: store.manifest.structure, where: { $0.type == .document }).count
    }

    // MARK: - The shape of the mount

    /// **The mount is a `ZStack` inside the editor arm, and this is what makes
    /// the mounted tests below tests of production.**
    ///
    /// Those tests drive a probe that wires the centre column the way
    /// `editorPane` wires it — the routing decisions come from production's own
    /// statics — but the SHAPE of the last arm is the probe's own spelling, and
    /// a probe cannot vouch for it. This scan is the bridge: it reads the real
    /// `manuscriptEditor` and asserts the five things the shape is made of.
    ///
    /// **What a sixth arm would cost.** Two branches of a ViewBuilder
    /// conditional are two `_ConditionalContent` arms and therefore two view
    /// identities, so flipping between them unmounts the first — and
    /// `EditorHost.onDisappear` is not a cleanup, it is `doc.close()`,
    /// `documentStore.unregister(path:)` and `loads.abandon()`. On a project ↔
    /// chapter hop, which is the gesture this task creates, that is the open
    /// document being torn down and re-loaded from disk each way. Inside the arm
    /// the host stays mounted in the placeholder branch it was already showing
    /// and altitude covers it.
    func test_theMountIsAZStackInsideTheEditorArmAndNotASixthArm() throws {
        let source = try Self.source(of: "Views/ProjectWindow.swift")
        let arm = try XCTUnwrap(
            Self.declaration(named: "private func manuscriptEditor(", in: source),
            "the editor arm must still be a member of its own")

        XCTAssertTrue(arm.contains("ZStack"),
                      "the two are layered, not chosen between")
        XCTAssertTrue(arm.contains("EditorHost("),
                      "…with the host mounted unconditionally underneath")
        XCTAssertTrue(arm.contains("ProjectAltitudePane("),
                      "…and altitude over it")
        XCTAssertTrue(arm.contains("Self.subjectShowsAltitude("),
                      "the overlay is gated on the rule, not on a second "
                      + "spelling of it written out here")
        XCTAssertTrue(arm.contains(".background("),
                      "the overlay must be OPAQUE — it covers `EditorHost`'s "
                      + "'Select a document.' placeholder, which is still "
                      + "mounted underneath and would otherwise read through it")

        XCTAssertEqual(
            Self.occurrences(of: "manuscriptEditor(", in: source), 2,
            "the declaration and exactly ONE call — `editorPane`'s last arm. A "
            + "third occurrence is a second place the editor is built, which is "
            + "the identity split this shape exists to avoid")
    }

    /// The control for the scan above: `declaration(named:)` must BOUND the text
    /// it reads to the one member, or every assertion in it is really about the
    /// whole file and cannot fail. `CanvasView(` is mounted in this same file,
    /// one member down, and must not be visible from inside the editor arm.
    func test_theArmScanReadsTheArmAndNotTheWholeFile() throws {
        let source = try Self.source(of: "Views/ProjectWindow.swift")
        let arm = try XCTUnwrap(
            Self.declaration(named: "private func manuscriptEditor(", in: source))
        XCTAssertTrue(source.contains("CanvasView("),
                      "premise: the file really does mount the canvas")
        XCTAssertFalse(arm.contains("CanvasView("),
                       "…and the scan above cannot see it, so what it asserts "
                       + "is about the editor arm rather than about the file")
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

    // MARK: - Reading the source

    /// This file sits in `MaughamTests/`, so it resolves the app's source
    /// directory itself rather than reaching for `CanvasSourceCensus`, whose own
    /// doc comment reserves it for suites beside it in `MaughamTests/Canvas/`.
    private static func source(of relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamTests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Maugham", isDirectory: true)
        return try String(contentsOf: root.appendingPathComponent(relativePath),
                          encoding: .utf8)
    }

    /// A member declaration, from its opening line to the closing brace at member
    /// indentation — bounded, or a scan over it is really a scan over the rest of
    /// the file (see the control above).
    private static func declaration(named header: String, in source: String) -> String? {
        guard let start = source.range(of: header) else { return nil }
        let rest = source[start.lowerBound...]
        guard let end = rest.range(of: "\n    }\n") else { return String(rest) }
        return String(rest[..<end.upperBound])
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}

// MARK: - Probes

/// How many times `EditorHost` has come and gone.
///
/// The count is taken from the modifiers on the host itself, so it is the host's
/// own lifetime rather than an instrument invented for the test: SwiftUI runs
/// `.onAppear`/`.onDisappear` on the same identity that runs the host's own
/// teardown, which is `doc.close()`, `documentStore.unregister(path:)` and
/// `loads.abandon()`.
@MainActor
final class EditorHostLifeCounter {
    private(set) var appearances = 0
    private(set) var disappearances = 0
    func appeared() { appearances += 1 }
    func disappeared() { disappearances += 1 }
}

/// **The centre column, wired the way `editorPane` wires it** — the research
/// placement, then the canvas route, then the Collection reference arm, then the
/// editor arm — with every decision taken from production's own statics rather
/// than re-spelled here. A probe that decided for itself which arm applies would
/// be testing the probe.
///
/// What it does spell for itself is the SHAPE of the last arm, which is the
/// thing under test and cannot be reached from outside `ProjectWindow`
/// (`manuscriptEditor` is private, and it reads the window's `@State`). That is
/// why the shape carries two cases: `.layered` is what production does, and
/// `.sixthArm` is the alternative this task rejected, driven by the control test
/// so the lifetime counter is proven able to see a teardown.
/// `ProjectAltitudeCentreTests.test_theMountIsAZStackInsideTheEditorArmAndNotASixthArm`
/// is the bridge that says production really is the first of the two.
///
/// The palette wall's arm is deliberately not modelled: nothing here opens the
/// wall, and its own gate and stash belong to `PaletteWallDoorTests`.
@MainActor
private struct AltitudeCentreProbeView: View {
    enum Shape { case layered, sixthArm }

    let store: ProjectStore
    let documentStore: DocumentStore
    let persona: Persona
    let probe: BinderSubjectProbe
    let shape: Shape
    let hostLife: EditorHostLifeCounter
    let canvasModel: CanvasModel

    @State private var layout: OutlineLayout = .table
    @State private var control = EditorControl()

    private var subject: Binding<BinderSubject?> {
        Binding(get: { probe.subject }, set: { probe.subject = $0 })
    }

    private var referencePiece: StructureItem? {
        guard let id = probe.subject?.itemID,
              let piece = store.manifest.structure.first(where: { $0.id == id }),
              piece.pieceKind == .reference
        else { return nil }
        return piece
    }

    private var showsAltitude: Bool {
        ProjectWindow.subjectShowsAltitude(persona: persona,
                                           subject: probe.subject,
                                           structure: store.manifest.structure)
    }

    var body: some View {
        centre.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var centre: some View {
        let route = ProjectWindow.editorRoute(
            persona: persona, projectType: store.manifest.type,
            selectedPieceIsReference: referencePiece != nil)
        if let id = ProjectWindow.researchSubjectPlacement(
            persona: persona, subject: probe.subject).centreItemID {
            ResearchSubjectCentre(store: store, documentStore: documentStore,
                                  itemID: id, previewVisible: false)
        } else if route == .canvas {
            CanvasView(model: canvasModel, projectRoot: store.url,
                       paletteSwatchHexes: { [] })
        } else if route == .collectionReference, let piece = referencePiece {
            ReferencePlaceholderCard(piece: piece, onOpen: {})
        } else {
            manuscriptCentre
        }
    }

    @ViewBuilder
    private var manuscriptCentre: some View {
        switch shape {
        case .layered:
            ZStack {
                editor
                if showsAltitude { altitude }
            }
        case .sixthArm:
            if showsAltitude { altitude } else { editor }
        }
    }

    private var editor: some View {
        EditorHost(store: store, documentStore: documentStore,
                   selectedItemId: probe.subject?.itemID, control: control)
            .onAppear { hostLife.appeared() }
            .onDisappear { hostLife.disappeared() }
    }

    private var altitude: some View {
        ProjectAltitudePane(store: store, layout: $layout,
                            selectedSubject: subject, title: store.manifest.title)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}
