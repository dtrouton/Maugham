import XCTest
import AppKit
import ApplicationServices
import SwiftUI
import MaughamCore
@testable import Maugham

/// The two inspector arms that used to mint a craft-intent research note
/// (M1A Task 8).
///
/// **The button is pressed, not the closure called.** `InspectorView` and
/// `PieceInspector` are hosted for real and the control SwiftUI published is
/// pressed, because the thing this task removes is an affordance and the thing
/// it puts back is an affordance — a test that calls a function the button
/// happens to name proves the function, not the button. (The previous milestone
/// shipped 22 green undo tests against a ⌘Z that could not reach the stack.)
@MainActor
final class InspectorIntentAffordanceTests: XCTestCase {

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)  // fixed: teardown settle, nothing observable to wait on
        windows.removeAll()
        temp = nil
    }

    // MARK: - Hosting

    private func mount(_ view: AnyView) -> NSWindow {
        let window = TestWindow.mount(view, size: CGSize(width: 420, height: 700))
        windows.append(window)
        // Fixed. The condition worth waiting on is "SwiftUI has published its
        // accessibility tree", but the only way to read that is `axTree(in:)`,
        // which throws `XCTSkip` when no assistive client could attach — and a
        // condition wait would then burn its whole deadline before that skip.
        pump()
        return window
    }

    // MARK: - Reaching the button

    /// Every button in the hosted hierarchy, **through the accessibility tree**.
    ///
    /// Measured here, 2026-08-01: SwiftUI on macOS 26 backs a `Button` with no
    /// `NSView` at all — a subview walk of the hosted inspector finds a
    /// `TextField`, a segmented control and a stepper, and zero buttons. The
    /// accessibility tree is where the control actually is, `accessibilityPerformPress`
    /// runs the same action a click does, and this doubles as proof VoiceOver can
    /// reach the affordance.
    ///
    /// Read through the ObjC selectors by KVC rather than `NSAccessibilityProtocol`
    /// — `CanvasViewMountingCase`' rule, for its reason: SwiftUI's synthetic
    /// elements are `SwiftUI.AccessibilityNode`, which does not satisfy that
    /// protocol, so a walk written against it drops exactly the elements this
    /// test is about.
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

    /// The tree an assistive client walks, or a skip naming why there is none.
    /// A tree that was never built is not evidence about this view.
    private func axTree(in window: NSWindow) throws -> [AnyObject] {
        var role: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(getpid()), kAXRoleAttribute as CFString, &role)
        guard error == .success, role != nil else {
            throw XCTSkip(
                "no assistive client could be attached to this process "
                + "(AXUIElementCopyAttributeValue -> \(error.rawValue)), so SwiftUI "
                + "never builds the tree this test presses through")
        }
        return axElements(under: try XCTUnwrap(window.contentView))
    }

    private func button(labelled label: String, in window: NSWindow) throws -> NSObject {
        let all = try axTree(in: window)
            .filter { (axAttribute($0, "accessibilityRole") as? String) == "AXButton" }
        let labels = all.map { axAttribute($0, "accessibilityLabel") as? String ?? "nil" }
        XCTAssertFalse(all.isEmpty,
                       "the hosted inspector published no buttons at all, so this "
                       + "test could not fail for the reason it exists")
        return try XCTUnwrap(
            all.first { (axAttribute($0, "accessibilityLabel") as? String) == label }
                as? NSObject,
            "no button labelled \u{201C}\(label)\u{201D} reached the hosted inspector. "
            + "Buttons found: \(labels)")
    }

    /// Press `button` and return the `.maughamSetDetailSegment` notes it posted.
    private func notesPosted(pressing button: NSObject) async -> [Notification] {
        var received: [Notification] = []
        // Whether the post would be DELIVERED is asserted separately, through
        // the real `MaughamEvent.shouldDeliver`.
        let token = NotificationCenter.default.addObserver( // adr-0021-ok: capture-only observer inspecting the exact scoped Notification the button posts
            forName: .maughamSetDetailSegment, object: nil, queue: nil
        ) { received.append($0) }
        defer { NotificationCenter.default.removeObserver(token) }
        _ = button.perform(NSSelectorFromString("accessibilityPerformPress"))
        // The press dispatches through SwiftUI, so the FIRST note is a
        // condition worth waiting on rather than a fixed window.
        await pumpUntil(deadline: 5) { !received.isEmpty }
        // …but `assertAsksForTheIntentPane` also pins `notes.count == 1`, which
        // is a NEGATIVE assertion (no second, duplicate post). Keep a fixed
        // window after the first delivery for a duplicate to show up in.
        await waitOut(0.3)
        return received
    }

    /// The one assertion both arms make: the press asked the key window's right
    /// column for the Intent pane, in the spelling `MaughamEvent.shouldDeliver`
    /// actually delivers.
    private func assertAsksForTheIntentPane(
        _ notes: [Notification], file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(notes.count, 1,
                       "the press should post exactly one segment request",
                       file: file, line: line)
        guard let note = notes.first else { return }
        XCTAssertEqual(note.userInfo?[MaughamEvent.detailSegmentKey] as? String,
                       DetailSegment.intent.rawValue,
                       "the request named the wrong pane", file: file, line: line)
        XCTAssertTrue(
            MaughamEvent.shouldDeliver(note, to: EventReceiverContext(
                kind: .keyWindow, isWindowLive: true, isWindowKey: true)),
            "the post is scoped so that the key window's receiver "
            + "(`ProjectWindow`'s `.onKeyWindowCommand(.maughamSetDetailSegment)`) "
            + "drops it — it reaches nothing",
            file: file, line: line)
        XCTAssertFalse(
            MaughamEvent.shouldDeliver(note, to: EventReceiverContext(
                kind: .keyWindow, isWindowLive: true, isWindowKey: false)),
            "control: a non-key window must not act on it, or the assertion "
            + "above is not about scoping at all",
            file: file, line: line)
    }

    // MARK: - The project inspector

    func test_theProjectInspectorSendsTheWriterToTheIntentPane() async throws {
        let url = try await ProjectFactory.createNovelProject(
            named: "InspectorIntent", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let documentStore = try await DocumentStore.open(url: url)
        store.documentStore = documentStore
        defer { Task { await documentStore.close() } }

        let window = mount(AnyView(InspectorView(
            store: store,
            selectedItemId: nil,
            metrics: EditorMetrics(wordCount: 0, characterCount: 0, readingMinutes: 0),
            onOpenProjectSettings: {})))

        let notes = await notesPosted(pressing: try button(labelled: IntentAffordanceRow.openTitle, in: window))
        assertAsksForTheIntentPane(notes)

        XCTAssertTrue(store.manifest.statements.isEmpty,
                      "pressing the inspector's affordance minted a statement. "
                      + "Absence is valid and the pane's empty editor is what "
                      + "mints — the inspector must create nothing (spec §4.3)")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: url.appendingPathComponent("research/craft-intent.md").path),
            "the old seam's research note was created")
    }

    /// The inspector must describe the scope the pane will actually show, or the
    /// row is a lie the moment a document is selected: the pane's scope follows
    /// the binder selection (§4.3), so with a chapter selected "Open Intent"
    /// lands on the chapter's, not the project's.
    func test_theProjectInspectorDescribesTheScopeThePaneWillShow() async throws {
        let url = try await ProjectFactory.createNovelProject(
            named: "InspectorScope", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let documentStore = try await DocumentStore.open(url: url)
        store.documentStore = documentStore
        defer { Task { await documentStore.close() } }

        let chapter = try XCTUnwrap(
            store.manifest.structure.first(where: { $0.type == .document }))
        _ = try await store.createStatement(kind: .intent, scope: .document(chapter.id))

        XCTAssertEqual(
            IntentAffordanceRow.scope(
                selectedItemId: chapter.id, in: store.manifest.structure),
            .document(chapter.id),
            "the inspector resolved a different scope than `StatementPane` will, "
            + "so its caption describes an intent the writer is not about to see")
        XCTAssertEqual(
            IntentAffordanceRow.scope(
                selectedItemId: nil, in: store.manifest.structure),
            .project)

        // **A third assertion stood here and it has been deleted rather than
        // updated** (persona shell, slice 1, task 7). It compared
        // `IntentAffordanceRow.scope` against `StatementPane.effectiveScope`
        // with the same arguments, to catch the two "drifting apart". It could
        // catch that while the row passed `prefersProjectScope: false` and the
        // pane passed its own `@State` — a real second answer. With the switch
        // gone the row's call is `effectiveScope`'s arguments verbatim, so the
        // assertion was `f(x) == f(x)`: it cannot go red, and a test that
        // cannot go red is worse than no test because it reads like cover. What
        // it was protecting is now protected by construction — there is one
        // resolution and the row calls it. The two above still say something:
        // they pin this row's OWN mapping, `String?` to `BinderSubject?`, which
        // is a line of code that can be wrong.
    }

    // MARK: - The Collection piece inspector (contract 3)

    /// **A loose piece's selection does reach the pane's scope.** `ProjectWindow`
    /// passes `selectedItemId` as both the piece inspector's `pieceId` and the
    /// right pane's `activeDocId` (`ProjectWindow.swift:1222`/`:1226`), and a
    /// loose piece is a `type: .document` structure item — so
    /// `StatementPane.effectiveScope` resolves it rather than falling to the
    /// project. That is what makes the button under a piece's heading honest.
    func test_aCollectionPieceInspectorLandsOnThatPiecesIntent() async throws {
        let url = try await ProjectFactory.createCollectionProject(
            named: "PieceIntent", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let documentStore = try await DocumentStore.open(url: url)
        store.documentStore = documentStore
        defer { Task { await documentStore.close() } }
        let piece = try await store.addLoosePiece(title: "Story A", mode: .prose)

        XCTAssertEqual(
            StatementPane.effectiveScope(
                kind: .intent, subject: .item(piece.id),
                structure: store.manifest.structure),
            .document(piece.id),
            "the Intent pane would show the PROJECT's intent while the button "
            + "sat under this piece's heading")

        let window = mount(AnyView(PieceInspector(
            store: store, pieceId: piece.id, kind: .prose)))

        assertAsksForTheIntentPane(
            await notesPosted(pressing: try button(labelled: IntentAffordanceRow.openTitle, in: window)))

        XCTAssertTrue(store.manifest.statements.isEmpty,
                      "the piece inspector minted a statement")
    }
}
