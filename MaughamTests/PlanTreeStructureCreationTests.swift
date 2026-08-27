import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **Can the writer make structure from Plan's tree?**
///
/// §2 says Plan is where structure is produced, and slice 2 put the manuscript
/// tree in Plan's left column. `BinderView` carries its root context menu, its
/// per-row menu and its empty-state buttons **attached to the view rather than
/// gated on persona**, so mounting it in Plan ought to bring creation with
/// it — which makes task 7 a verification task, and the verification is the
/// deliverable. `TreePaneTests` and
/// `ProjectSubjectReachabilityTests` prove the right PANE is mounted; neither
/// presses anything, and "the pane is there" is not "the writer can make a
/// chapter".
///
/// **Driven through the accessibility tree**, for the reason
/// `InspectorIntentAffordanceTests` records: SwiftUI on macOS 26 backs a
/// `Button` with no `NSView` at all, so a subview walk finds nothing to click.
/// `accessibilityPerformPress` runs the same action a click does and doubles as
/// proof VoiceOver can reach the affordance. The empty-state buttons are the
/// pressable route; the two `.contextMenu`s are the same `addItem` call one
/// level down and are not reachable from here (an `NSMenu` is built on
/// right-click, not published into the tree), which is recorded rather than
/// asserted.
///
/// **A screenplay has no structure creation here and must not gain one** — a
/// screenplay is one `.fountain` (the Phase 3d invariant) and its structure is
/// sluglines, typed in the editor, which is not on screen in Plan.
/// `SceneNavigatorPane`'s empty state already points at the script row for
/// exactly this reason. That is asserted below rather than left to prose.
@MainActor
final class PlanTreeStructureCreationTests: XCTestCase {

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

    // MARK: - The novel and the short story

    /// The whole round trip: Plan, the Structure segment, an empty binder, a
    /// press on **New Document**, and a document in the manifest that was not
    /// there before.
    func test_aChapterCanBeMadeFromPlansTree() async throws {
        for type in [ProjectType.novel, .shortStory] {
            let store = try await emptyProject(of: type)
            XCTAssertTrue(store.manifest.structure.isEmpty, "\(type): fixture")

            let window = host(store: store, persona: .plan)
            try await press("New Document", in: window,
                            until: { store.manifest.structure.count == 1 })

            XCTAssertEqual(store.manifest.structure.count, 1,
                           "\(type): pressing New Document in Plan's tree must "
                           + "add a document — Plan is where §2 says structure "
                           + "is produced")
            XCTAssertEqual(store.manifest.structure.first?.type, .document)
        }
    }

    /// And a group, because the two buttons are two different `addItem` kinds
    /// and a pane that could only make documents would still pass the test
    /// above.
    func test_aGroupCanBeMadeFromPlansTree() async throws {
        let store = try await emptyProject(of: .novel)
        let window = host(store: store, persona: .plan)
        try await press("New Group", in: window,
                        until: { store.manifest.structure.first?.type == .group })

        XCTAssertEqual(store.manifest.structure.first?.type, .group)
    }

    /// **The control: the same affordances, in the persona that always had
    /// them.** If Author's tree could not create either, the test above would be
    /// measuring the harness rather than Plan.
    func test_theSameAffordancesAreThereInAuthorsBinder() async throws {
        let store = try await emptyProject(of: .novel)
        let window = host(store: store, persona: .author)
        try await press("New Document", in: window,
                        until: { store.manifest.structure.count == 1 })
        XCTAssertEqual(store.manifest.structure.count, 1)
    }

    // MARK: - The Collection

    /// A Collection's tree is `CollectionPiecesPane`, whose `+` menu is attached
    /// to its header the same way — so it comes to Plan with the pane.
    ///
    /// **Its items are asserted differently and deliberately.** The `+` is a
    /// SwiftUI `Menu`; its three `Button`s do not exist until the menu is opened,
    /// and its items post key-window events that `ProjectWindow` handles rather
    /// than calling the store. So what is asserted here is that the control
    /// itself reaches Plan's tree — the piece-creation actions behind it are
    /// `CollectionPieceModifier`'s and are tested there.
    func test_theCollectionsAddControlReachesPlansTree() async throws {
        let store = try await emptyProject(of: .collection)
        let window = host(store: store, persona: .plan)

        let found = try axDescriptors(in: window)
        XCTAssertTrue(found.contains("Add a piece"),
                      "the Pieces pane's + control did not reach Plan's tree. "
                      + "Found: \(found)")
    }

    // MARK: - The screenplay refuses, and that is the design

    /// **The stop, asserted.** No creation affordance in a screenplay's tree, in
    /// Plan or anywhere else: one `.fountain` per screenplay is the Phase 3d
    /// invariant, and its structure is sluglines typed into an editor that Plan
    /// does not show. A future slice that adds a "New Scene" button here has to
    /// delete this test, which is the point.
    func test_aScreenplaysTreeOffersNoStructureCreationAndMustNotGainOne() async throws {
        let store = try await emptyProject(of: .screenplay)
        let window = host(store: store, persona: .plan)

        let found = try axDescriptors(in: window)
        // The control: an empty tree would make every refusal below vacuous.
        // The same walk finds "New Document" in a novel's tree one test up.
        XCTAssertFalse(found.isEmpty,
                       "the screenplay's tree published nothing at all, so this "
                       + "test could not have failed for its own reason")
        for creation in ["New Document", "New Group", "New Scene", "Add a piece"] {
            XCTAssertFalse(found.contains(creation),
                           "a screenplay's tree published \u{201C}\(creation)\u{201D}. "
                           + "A screenplay is ONE .fountain and its structure is "
                           + "sluglines typed in the editor — see "
                           + "SceneNavigatorPane's empty state, which points at "
                           + "the script row for exactly this reason. Found: "
                           + "\(found)")
        }
    }

    // MARK: - One production caller

    /// `addStructureItem` has exactly one production call site and must keep
    /// having one — the binder's `addItem`, which every affordance above funnels
    /// through. A second caller is a second set of defaults for a new chapter's
    /// title, filename and parent.
    func test_addStructureItemStillHasOneProductionCaller() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Maugham", isDirectory: true)
        var callers: [String] = []
        let files = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            // The declaration itself is in ProjectStore; callers say `.addStructureItem(`.
            for line in text.split(separator: "\n")
            where line.contains(".addStructureItem(")
                && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                callers.append("\(file.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertEqual(callers, callers.filter { $0.hasPrefix("BinderView.swift:") },
                       "structure creation grew a second production caller: \(callers)")
        XCTAssertFalse(callers.isEmpty,
                       "the control: no caller found at all means this scan is "
                       + "reading nothing and asserts nothing")
    }

    // MARK: - Fixtures

    /// A project of `type` with **no structure at all** — the state the empty
    /// state is drawn for, reached by deleting whatever the factory seeds rather
    /// than by hand-building a manifest.
    private func emptyProject(of type: ProjectType) async throws -> ProjectStore {
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
        for item in store.manifest.structure {
            try? await store.deleteStructureItem(id: item.id)
        }
        return store
    }

    // MARK: - Hosting and pressing

    private func host(store: ProjectStore, persona: Persona) -> NSWindow {
        let window = TestWindow.mount(
            AnyView(StructureCreationProbeView(store: store, persona: persona)),
            size: CGSize(width: 320, height: 600))
        windows.append(window)
        pump(0.25)
        return window
    }

    private func axAttribute(_ element: AnyObject, _ attribute: String) -> Any? {
        guard let object = element as? NSObject,
              object.responds(to: NSSelectorFromString(attribute)) else { return nil }
        return object.value(forKey: attribute)
    }

    private func axElements(under root: AnyObject, depth: Int = 0) -> [AnyObject] {
        guard depth < 40 else { return [] }
        let children = axAttribute(root, "accessibilityChildren") as? [AnyObject] ?? []
        return [root] + children.flatMap { axElements(under: $0, depth: depth + 1) }
    }

    /// The tree an assistive client walks, or a skip naming why there is none —
    /// a tree that was never built is not evidence about this view.
    private func axTree(in window: NSWindow) throws -> [AnyObject] {
        var role: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(getpid()), kAXRoleAttribute as CFString, &role)
        guard error == .success, role != nil else {
            throw XCTSkip(
                "no assistive client could be attached to this process "
                + "(AXUIElementCopyAttributeValue -> \(error.rawValue)), so "
                + "SwiftUI never builds the tree this test presses through")
        }
        return axElements(under: try XCTUnwrap(window.contentView))
    }

    /// Every piece of text the hosted column publishes about its controls —
    /// **label AND help**, whatever the element's role.
    ///
    /// Both, because the two creation surfaces name themselves differently and a
    /// labels-only walk finds one and misses the other: `BinderView`'s
    /// empty-state buttons carry `Label(…)`, which becomes an
    /// `accessibilityLabel`, while `CollectionPiecesPane`'s `+` is an
    /// `Image(systemName:)` with `.help("Add a piece")` — measured 2026-08-02 to
    /// publish an EMPTY label and the help string instead. A test written
    /// against labels alone reports a Collection has no creation affordance at
    /// all, which is how a false stop gets recorded as a finding.
    private func axDescriptors(in window: NSWindow) throws -> [String] {
        try axTree(in: window).flatMap { element -> [String] in
            [axAttribute(element, "accessibilityLabel") as? String,
             axAttribute(element, "accessibilityHelp") as? String]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
        }
    }

    /// - Parameter settled: what the caller is about to assert of the store.
    ///   Given a condition, the wait ends the moment the press's `addItem` has
    ///   landed in the manifest rather than burning its worst case; the caller's
    ///   own assertion still reports the failure in its own words. Given none,
    ///   the wait is a fixed window — what a caller asserting that a press
    ///   created NOTHING would need.
    private func press(_ label: String, in window: NSWindow,
                       until settled: (() -> Bool)? = nil) async throws {
        let all = try axTree(in: window)
            .filter { (axAttribute($0, "accessibilityRole") as? String) == "AXButton" }
        let labels = all.map { axAttribute($0, "accessibilityLabel") as? String ?? "nil" }
        let button = try XCTUnwrap(
            all.first { (axAttribute($0, "accessibilityLabel") as? String) == label }
                as? NSObject,
            "no button labelled \u{201C}\(label)\u{201D} reached the hosted "
            + "column. Buttons found: \(labels)")
        _ = button.perform(NSSelectorFromString("accessibilityPerformPress"))
        if let settled {
            await pumpUntil(deadline: 5, settled)
        } else {
            await waitOut(0.6)
        }
    }

}

/// The left column as `ProjectWindow.binderColumn` builds it — same shell rule,
/// and a persona the test chooses.
@MainActor
private struct StructureCreationProbeView: View {
    let store: ProjectStore
    let persona: Persona
    @State private var subject: BinderSubject?
    @State private var renamingItemId: String?
    @State private var treeFindActive = false
    let treeState = BinderTreeSectionsState()

    var body: some View {
        Group {
            switch ProjectWindow.BinderShell.shell(for: store.manifest.type) {
            case .standard:
                BinderPaneToggle(
                    store: store,
                    selectedSubject: $subject,
                    projectType: store.manifest.type,
                    lastParsedScript: nil,
                    treeState: treeState,
                    treeFindActive: $treeFindActive,
                    persona: persona)
            case .collection:
                CollectionBinderPaneToggle(
                    store: store,
                    selectedSubject: $subject,
                    treeFindActive: $treeFindActive,
                    renamingItemId: $renamingItemId,
                    treeState: treeState,
                    persona: persona)
            }
        }
    }
}
