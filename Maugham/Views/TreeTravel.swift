import SwiftUI
import AppKit

/// **Denver's travel rule, 2026-08-12: a double-click on any tree row in Plan
/// takes the writer to Author, on that row's subject.**
///
/// Plan's centre column is always the planning canvas (`Persona
/// .centresTheCanvas`) — a chapter, a research note, a palette card double-
/// clicked in the tree has nowhere to open *in* Plan, so the writer has to be
/// taken to where it opens. Elsewhere the tree already sits beside the
/// document it names (Author, Review, Publish all centre the editor), so the
/// same double-click means nothing beyond the click a single click already
/// gave it — no persona to travel TO.
///
/// **Two halves, one file** (the plan's own instruction): `treeTravelOnDoubleClick(_:)`
/// MARKS a row's LABEL LEAF — never the row container — and
/// `TreeTravelModifier` is the receiver. What the mark is made of is the
/// subject of the next paragraph, and it is deliberately **not a SwiftUI
/// gesture**.
///
/// **Why no SwiftUI gesture, measured 2026-08-12.** Stage 3b shipped this as
/// `.onTapGesture(count: 2)` on the label, and it cost the writer the single
/// click: a click anywhere on a row's NAME stopped selecting the row, while
/// the icon and the trailing whitespace still did. Measured directly, one
/// click per fresh mount, against a 30-character title in a 420pt tree so the
/// label spans past the row's own midpoint — with the gesture attached,
/// `NSTableView.selectedRow` stayed `-1` for a click at x=60 and x=210 (both
/// over the text) and became `1` at x=340 (past it); with the one line
/// commented out, all four positions selected. `NSHostingView` hands a
/// mouseDown to SwiftUI's gesture graph first, and a gesture whose hit region
/// covers the point CONSUMES it rather than letting it reach the enclosing
/// `NSTableView` — the double-tap recognizer waits to see whether a second
/// click follows, and when none does the click is simply gone.
/// `.simultaneousGesture(TapGesture(count: 2))` was measured on the same rig
/// and behaves identically (`selectedRow = -1` at x=60): "simultaneous" is
/// simultaneity with other SwiftUI gestures, not with the AppKit responder
/// chain beneath. There is no SwiftUI spelling of this that leaves the click
/// alone, which is why the mechanism is an AppKit one.
///
/// **What it is instead.** The label carries `TreeTravelTarget`, an
/// `NSViewRepresentable` whose view answers `nil` from `hitTest(_:)` — it can
/// never receive an event, so it can never take one from `List(selection:)`
/// or from `.draggable`. It exists only to say *"the row whose subject is X
/// draws its name here"*. The double-click itself is read by
/// `TreeTravelClickWatcher`, one `NSEvent` local monitor per window, which
/// **returns every event unchanged** — dispatch is exactly what it is with no
/// travel rule at all, which is what makes single-click selection and drag
/// initiation safe by construction rather than by measurement.
///
/// **Why not `NSTableView.doubleAction`,** AppKit's own idiom and the obvious
/// candidate: SwiftUI already owns it. Measured on the mounted tree, the
/// `SwiftUIOutlineListView` backing `List(.sidebar)` comes up with `target` =
/// SwiftUI's own `OutlineListCoordinator`, `action` = `onAction:` and
/// `doubleAction` = `onDoubleAction:` already installed. Taking `doubleAction`
/// means overwriting a hook SwiftUI is using (outline disclosure among other
/// things) and `target` with it, which governs the single-click `action` too.
///
/// **Why not an overlay `NSView` that forwards `mouseDown` to `super`** — the
/// third candidate, and the one that reads cleanest: `.draggable`'s SOURCE
/// side is a SwiftUI gesture, not an AppKit dragging source (the row's only
/// platform views are `.dropDestination`'s two `_PlatformDraggingDestinationView`s;
/// a subview walk shows nothing for `.draggable` itself). An AppKit view in
/// front of the label that consumes mouseDown and forwards it up the responder
/// chain therefore routes around the very gesture graph the drag lives in, and
/// re-creates `TaskRow.swift`'s scar — the writer can drag the row from its
/// padding but not from its name. Only a mechanism that touches dispatch not
/// at all is safe here.
///
/// `TaskRow.swift`'s own doc comment records the neighbouring scar and is
/// still the reason the mark goes on the label rather than the row: an earlier
/// `.simultaneousGesture(TapGesture(count: 2))` on the whole row made SwiftUI
/// wait to see whether a press would resolve as a double-click, eating drag
/// initiation across the row's interior.
///
/// **The subject posted is the row's OWN tag, never `state.selection`** (T3's
/// standing rule). It survived the move to AppKit, and the reason got
/// stronger rather than weaker. Under the gesture it was a race: a
/// double-click fired before `List(selection:)`'s write-back was guaranteed to
/// have landed. Under the watcher the second click is a whole event later, so
/// the race is mostly gone — but reading the selection would now be wrong for
/// a reason no timing fixes. The tree selects a `Set<BinderSubject>`
/// (`BinderTreeSelection`), and `-[NSTableView mouseDown:]` deliberately does
/// NOT collapse a multiple selection onto the clicked row until mouseUp, so
/// that the whole group stays draggable. Double-click one row of three and the
/// selection still holds all three; the subject the writer pointed at is only
/// knowable from the row itself. That is what `TreeTravelTargetView` carries.
///
/// `TreeTravelModifier` is the receiver, mounted once on `ProjectWindow.body`.
/// It writes `selectedSubject` directly and moves the persona through
/// `PersonaModifier.applyPersonaChange` — the same call `ManuscriptNavigation
/// .go` makes and for the same reason: a deliberate writer move records the
/// departing position, so ⌘1 brings the writer back to the tree they were
/// arranging. **Not through `ManuscriptNavigation` itself** — that rule reads
/// "does the CURRENT persona already show a manuscript document", which is a
/// different question from "is Plan the departure point", and answering the
/// travel rule by routing it through a navigation meant for a different
/// premise would leave Review's own guard (never eject a reviewer mid-
/// adjudication) silently deciding a case it was never asked about.
///
/// **The set this closes.** "Any tree row" means every row that tags a
/// `BinderSubject` in any of the three trees — `TreeTravelGestureAttachmentTests
/// .test_theGestureAttachesBeforeTheRowWidens`'s own `expectations` array is
/// the count, never a number here, but the KINDS are: a structure row
/// (`BinderRow`/`PieceRow`, a chapter or a loose piece), a project row
/// (`BinderView`/`CollectionPiecesPane`/`SceneNavigatorPane` each carry their
/// own, since only one of the three is ever mounted for a given project type),
/// a research or palette row (`ResearchRow`, the palette card `Label` in
/// `BinderTreeSections.swift`), and the screenplay's own script row
/// (`SceneNavigatorPane.scriptRow` — structurally a structure row in every way
/// that matters, just named for what a screenplay's one document always is).
/// Excluded on purpose: a slugline in `SceneNavigatorPane` needs nothing,
/// because it already navigates Plan → Author on a single click through
/// `ManuscriptNavigation` (`ManuscriptNavigationTests
/// .test_onlyPlanIsMovedToAuthorAndTheOthersStayWhereTheyAre`) — giving it
/// this gesture too would double the trip.
enum TreeTravel {

    /// Where a double-click on a tree row takes the window, or `nil` when it
    /// takes it nowhere.
    ///
    /// **`persona.centresTheCanvas`, not `== .plan`** — the same discriminator
    /// `ManuscriptNavigation` uses and for the same reason
    /// (`ManuscriptNavigationTests.test_theRuleIsAboutTheCentreColumn_notAboutAnyParticularPersona`):
    /// the travel rule is about *"is there a persona to travel to"*, not about
    /// which one is named Plan today.
    static func treeTravelDestination(persona: Persona) -> Persona? {
        guard persona.centresTheCanvas else { return nil }
        return .author
    }

    /// The subject of the tree label drawn under `pointInWindow`, or `nil`
    /// when the point is not over one.
    ///
    /// **Geometry, not hit-testing** — `TreeTravelTargetView` answers `nil`
    /// from `hitTest(_:)` on purpose (see the type's own doc), so it is
    /// unreachable by `NSView.hitTest` by construction and has to be found by
    /// walking. That is the whole point: a view AppKit can find by hit-testing
    /// is a view that can swallow a click.
    ///
    /// The LAST match wins. Two targets should never overlap — each marks one
    /// row's label — but a tree row can be re-used mid-scroll while its
    /// predecessor is still in the hierarchy, and taking the deepest/last
    /// match is the same "nearest wins" rule the rest of the walk uses.
    /// Hidden views and views detached from `window` are skipped: a recycled
    /// `NSTableRowView` keeps its subviews alive off-screen, and a stale one
    /// answering for a live click is exactly the id-vs-path confusion
    /// tripwire 22 is about.
    static func subject(at pointInWindow: NSPoint, in window: NSWindow) -> BinderSubject? {
        guard let root = window.contentView else { return nil }
        var match: BinderSubject?
        walkTargets(root) { view in
            guard let subject = view.subject, view.window === window else { return }
            let frameInWindow = view.convert(view.bounds, to: nil)
            if frameInWindow.contains(pointInWindow) { match = subject }
        }
        return match
    }

    private static func walkTargets(_ view: NSView,
                                    _ visit: (TreeTravelTargetView) -> Void) {
        if view.isHidden { return }
        if let target = view as? TreeTravelTargetView { visit(target) }
        for sub in view.subviews { walkTargets(sub, visit) }
    }
}

/// The mark a tree row's label carries, naming that row's subject.
///
/// **`hitTest(_:)` returns `nil`, and that is the entire safety argument.** An
/// `NSView` that can be hit is an `NSView` that can be sent a `mouseDown:`,
/// and a `mouseDown:` that stops here is a click `List(selection:)` never
/// sees — the stage-3b regression this file's doc comment measures, arrived at
/// from the AppKit side instead of the SwiftUI one. This view is found by
/// geometry alone (`TreeTravel.subject(at:in:)`); nothing ever dispatches to
/// it.
final class TreeTravelTargetView: NSView {
    var subject: BinderSubject?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
}

/// Installs a `TreeTravelTargetView` behind a row's label. Used as a
/// `.background`, so it takes the label's own frame and adds nothing to the
/// row's layout.
struct TreeTravelTarget: NSViewRepresentable {
    let subject: BinderSubject

    func makeNSView(context: Context) -> TreeTravelTargetView {
        let view = TreeTravelTargetView()
        view.subject = subject
        return view
    }

    func updateNSView(_ nsView: TreeTravelTargetView, context: Context) {
        // A row's view is recycled onto a different item as the tree scrolls
        // or re-derives, so the subject is re-read on every update rather than
        // set once at make time — the mark has to name the row it is CURRENTLY
        // drawing, not the one it was born on.
        nsView.subject = subject
    }
}

/// The single `NSEvent` local monitor that turns a double-click over a marked
/// label into the `.maughamTreeTravel` post the receiver below reads.
///
/// **It returns every event unchanged.** A local monitor that returns its
/// event leaves dispatch exactly as it was — the click still reaches
/// `SwiftUIOutlineListView`, still selects, still begins a drag. That is the
/// property the SwiftUI gesture could not have, and it is why this mechanism
/// needs no measurement to be safe for selection and drag: it does not sit in
/// the path at all.
///
/// **`.leftMouseDown`, and it has to be — `.leftMouseUp` never arrives.** The
/// first spelling of this watched `.leftMouseUp`, as the closer match for
/// `TapGesture(count: 2).onEnded`, and no travel ever fired. Measured on the
/// mounted tree: with the click reaching the table (i.e. once the marker half
/// worked), a monitor watching both saw `mouseDown cc=1, mouseDown cc=2` and
/// **no mouseUp at all** — `-[NSTableView mouseDown:]` runs its own
/// drag-vs-click tracking loop and dequeues the matching mouseUp through
/// `nextEventMatchingMask:` directly, so it never passes through the dispatch
/// a local monitor observes. The same measurement taken BEFORE the fix saw all
/// four events, because back then the SwiftUI gesture ate the mouseDown and the
/// table never tracked — the very symptom being fixed was also what made the
/// wrong mechanism look plausible.
///
/// **The post is deferred a runloop turn** for that same reason: the handler
/// runs INSIDE AppKit's mouseDown, before the table has finished tracking, and
/// a travel tears the tree column down and rebuilds the window around it.
/// Changing the view tree under a tracking loop is tripwire 3's shape — heavy
/// work on a synchronous event path — so the post is made once AppKit is done.
/// A double-click that continues into a drag therefore travels, which is what
/// `NSTableView.doubleAction` would do too.
///
/// **One watcher for the app, not one per window** — the sharp edge, and the
/// second thing measured wrong on the way here. `NSEvent` monitors are
/// app-wide, so a per-window watcher has to filter on being *its* window, and
/// the only handle a `ViewModifier` has on that is `WindowAccessor`, which
/// resolves a `DispatchQueue.main.async` hop AFTER first mount. Installed from
/// `.onAppear` the watcher captured `nil` and never learned better: measured
/// `events=2 cc2=1 winMatch=0` — every double-click read, matched against a nil
/// window, dropped. Worse, the shape that fixes THAT is still wrong at two
/// windows: N watchers all match the same click and post N times, and
/// `PersonaModifier.applyPersonaChange` is not idempotent — the second post
/// records Author as the departing position, so ⌘1 stops bringing the writer
/// back to the board. So the watcher takes the window from the EVENT
/// (`event.window`), which is always the right one because a click is what
/// makes a window key in the first place, and there is exactly one of it.
/// Window discrimination stays where ADR 0021 already put it: the post is
/// `.keyWindow`-scoped and `TreeTravelModifier` receives through
/// `onKeyWindowCommand`.
@MainActor
final class TreeTravelClickWatcher {

    /// The app's one watcher. `TreeTravelModifier` starts it; nothing stops it,
    /// because it holds no window and no project — there is no zombie for it to
    /// become, which is the whole reason it is allowed to be shared.
    static let shared = TreeTravelClickWatcher()

    private var monitor: Any?

    private init() {}

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) {
            event in
            MainActor.assumeIsolated { TreeTravelClickWatcher.shared.handle(event) }
            return event
        }
    }

    /// Test-only. Production never stops the watcher — see `shared`.
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        guard event.clickCount == 2,
              let window = event.window,
              let subject = TreeTravel.subject(at: event.locationInWindow, in: window)
        else { return }
        // Off AppKit's tracking loop first — see this type's doc comment.
        Task { @MainActor in
            MaughamEvent.post(.maughamTreeTravel, to: .keyWindow,
                              payload: [MaughamEvent.treeTravelSubjectKey: subject])
        }
    }
}

extension View {
    /// Attach to a row's LABEL LEAF only — see `TreeTravel`'s doc comment for
    /// why the container is never the right place, and why this is a
    /// hit-test-transparent MARK rather than a gesture.
    ///
    /// It names the row's own `subject`, unconditionally: the persona guard
    /// lives on the RECEIVER (`TreeTravel.treeTravelDestination`), so a
    /// double-click in Author is still read and still refused there — one
    /// control point, not a second copy of the guard at every call site.
    ///
    /// **`.background`, never `.overlay`.** Both would work for a view that
    /// cannot be hit, and `.background` says the weaker thing: this mark is
    /// behind the writer's text and has no business in front of it.
    func treeTravelOnDoubleClick(_ subject: BinderSubject) -> some View {
        background(TreeTravelTarget(subject: subject))
    }
}

/// The mounted receiver — one line on `ProjectWindow.body`
/// (`Maugham/Views/AREA.md`'s established shape: window behaviour lives in a
/// `ViewModifier` because that body is at SwiftUI's type-checker ceiling).
/// Deleting the mount line leaves every token in this file present and every
/// pure-function test green while a double-click reaches nobody — the same
/// failure mode `CanvasClaudeArrivalModifier`'s own doc comment warns about.
struct TreeTravelModifier: ViewModifier {
    let window: NSWindow?
    @Binding var persona: Persona
    @Binding var detailSegment: DetailSegment
    @Binding var selectedSubject: BinderSubject?
    let documentStore: DocumentStore?

    func body(content: Content) -> some View {
        content
            // The poster. Idempotent and shared, so every window's mount is
            // the same call and the second one does nothing —
            // `TreeTravelClickWatcher.shared`'s doc says why it is not one per
            // window.
            .onAppear { TreeTravelClickWatcher.shared.start() }
            .onKeyWindowCommand(.maughamTreeTravel, window: window) { note in
                guard let subject = note.userInfo?[MaughamEvent.treeTravelSubjectKey]
                        as? BinderSubject,
                      let destination = TreeTravel.treeTravelDestination(persona: persona)
                else { return }
                selectedSubject = subject
                let change = PersonaModifier.applyPersonaChange(
                    to: destination,
                    from: persona,
                    currentSegment: detailSegment,
                    memory: documentStore?.uiState.personaMemory ?? .empty)
                persona = change.persona
                detailSegment = change.segment
                documentStore?.updateUIState {
                    $0.persona = change.persona
                    $0.personaMemory = change.memory
                }
            }
    }
}
