import SwiftUI
import AppKit

/// **Who holds the keys while something covers the manuscript editor** (shell
/// plan 3 Task 5 fix, review C1).
///
/// `EditorHost` stays mounted under every cover (tripwire 6), and its
/// `MaughamTextView` stays bound to the open piece under the centre item's
/// cover. A covered text view is not a hidden one: left first responder, it
/// takes every keystroke and ⌘Z in text the writer cannot see. So, at the one
/// place the centre decides a cover is up (`CentreColumn.manuscriptEditor`):
///
/// - **While the editor is covered, the manuscript text view is never first
///   responder.** Whenever it becomes so — it was when the cover arrived, or a
///   load or a navigation under the cover re-asserted it — the keys move to the
///   cover's own editor, else to this view, which takes keys and does nothing
///   with them.
/// - **A cover may ask for the keys when it appears** (`Claim`): the centre
///   item's statement editor once its host has bound (the host loads
///   asynchronously, so the claim is retried on a 30 ms step — the deferral
///   tripwires 16 and 27 use), History's cover for itself. A claim never takes
///   the keys from a field the writer is typing in elsewhere.
/// - **Closing a cover hands the keys back** to the manuscript text view when
///   it is what the centre now shows (`returnKeysToTheManuscript`).
///
/// "Covered" is read LIVE (`isCovered`, the column's own `centreRoute`), never
/// a value captured at the last render: a navigation clears the centre item
/// and lands its caret in the same turn, before SwiftUI redraws.
///
/// Nothing here is state on `EditorHost` (tripwire 6), and nothing syncs back
/// into SwiftUI (tripwire 2): it reads the window's first responder and moves
/// it, one way.
struct CentreKeys: NSViewRepresentable {
    /// Whether an opaque surface covers `EditorHost` now. Read at focus time.
    let isCovered: () -> Bool
    /// The cover that asks for the keys when it appears, or nil.
    let claim: Claim?

    /// A cover's request for the keys. A new `id` is a new request.
    struct Claim: Equatable {
        let id: String
        /// The cover's own text editor (a statement); else the cover itself.
        let prefersEditor: Bool
    }

    func makeNSView(context: Context) -> CentreKeysView { CentreKeysView() }

    func updateNSView(_ view: CentreKeysView, context: Context) {
        view.update(isCovered: isCovered, claim: claim)
    }

    static func dismantleNSView(_ view: CentreKeysView, coordinator: ()) {
        view.stop()
    }

    // MARK: - Pure

    /// The window's manuscript editor: the one text view that answers the
    /// window's commands (`EditorCoordinator.respondsToWindowCommands`; a
    /// statement pane's, Brief's and the cover's do not).
    static func isManuscriptEditor(_ responder: NSResponder?) -> Bool {
        (responder as? MaughamTextView)?.coordinator?.respondsToWindowCommands == true
    }

    /// **Whether `responder` is the manuscript's, by ANCESTRY** (review N3):
    /// the manuscript text view itself, or any view inside it or its scroll
    /// view — the expanded figure grid and its cell editor, the review
    /// composer's field, the find bar (whose Replace edits the text). A field
    /// editor answers for the field it is editing (its delegate). A walk up
    /// the responder's own superviews: no window search, cheap per focus change.
    static func isInsideTheManuscript(_ responder: NSResponder?) -> Bool {
        var view: NSView?
        if let text = responder as? NSText, text.isFieldEditor, let field = text.delegate as? NSView {
            view = field
        } else {
            view = responder as? NSView
        }
        while let current = view {
            if isManuscriptEditor(current) { return true }
            if let scroll = current as? NSScrollView, isManuscriptEditor(scroll.documentView) { return true }
            view = current.superview
        }
        return false
    }

    /// Whether a cover's claim may take the keys from `responder`: from
    /// nothing, from anything inside the covered manuscript, from this view,
    /// and from anything that is not a field being typed in. Never from the
    /// writer's own typing elsewhere — the find field, a rename, a
    /// right-column editor.
    static func mayClaim(from responder: NSResponder?) -> Bool {
        if responder == nil || responder is NSWindow || responder is CentreKeysView { return true }
        if isInsideTheManuscript(responder) { return true }
        return !CanvasEscapeMonitor.isEditingText(responder)
    }

    /// **Whether the manuscript editor holding `textView` is the editor the
    /// writer can see** — the editor-side door to
    /// `ProjectWindow.manuscriptIsVisible(route:)`, asked by every
    /// manuscript-writing command that does not come through the text view's
    /// own keys (`EditorCoordinator.manuscriptCommandContext`). Asks the
    /// window's live `CentreKeysView` behind the centre column the text view
    /// sits in; with none (a window that mounts no centre column, a test
    /// harness), nothing covers it.
    @MainActor
    static func manuscriptIsVisible(holding textView: NSView) -> Bool {
        guard let window = textView.window, let root = window.contentView else { return true }
        let shown = CentreKeysView.visibleFrame(of: textView)
        let centre = NSPoint(x: shown.midX, y: shown.midY)
        let guards = CentreKeysView.all(CentreKeysView.self, in: root)
            .filter { $0.convert($0.bounds, to: nil).contains(centre) }
        return !guards.contains { $0.covered }
    }

    /// Whether `editorFrame` (window coordinates) belongs to the surface over
    /// `coverFrame`: its centre lies inside. Pure.
    static func lies(_ editorFrame: NSRect, within coverFrame: NSRect) -> Bool {
        coverFrame.contains(NSPoint(x: editorFrame.midX, y: editorFrame.midY))
    }

    /// **Closing a cover**: on the next turn, once the cover is gone, the keys
    /// go back to the manuscript text view — when there is one and nothing
    /// covers it any longer (the centre now shows it).
    @MainActor
    static func returnKeysToTheManuscript(in window: NSWindow?) {
        DispatchQueue.main.async { [weak window] in
            // Never from a field the writer is typing in elsewhere (review N4):
            // a click on the borderless Close takes no focus.
            guard let window, mayClaim(from: window.firstResponder),
                  let root = window.contentView else { return }
            let guards: [CentreKeysView] = CentreKeysView.all(CentreKeysView.self, in: root)
            guard !guards.contains(where: { $0.covered }),
                  let manuscript = CentreKeysView.all(MaughamTextView.self, in: root)
                    .first(where: { isManuscriptEditor($0) })
            else { return }
            window.makeFirstResponder(manuscript)
        }
    }
}

/// The AppKit half of `CentreKeys`: a zero-content view behind the centre's
/// stack that watches the window's first responder.
final class CentreKeysView: NSView, NSUserInterfaceValidations {

    override var acceptsFirstResponder: Bool { true }

    // MARK: - ⌘Z under a cover (review N1)

    /// **This view owns undo while it holds the keys.** Without these two,
    /// `undo:` walks past it to `NSWindow`, whose own `undo:` runs the
    /// window's shared manager — where the covered manuscript keeps its
    /// typing undo — and rewrites text nobody can see (`CanvasEventView`'s
    /// measured walk). Nothing under a cover is undone; both validate off.
    @objc func undo(_ sender: Any?) {}
    @objc func redo(_ sender: Any?) {}

    private var isCovered: () -> Bool = { false }
    private var claim: CentreKeys.Claim?
    private var wasCovered = false
    private var observation: NSKeyValueObservation?
    private var observedWindow: NSWindow?
    /// Bumped by every new claim and by teardown: a retry from an older claim
    /// stops when it sees a newer generation.
    private var generation = 0

    /// How many 30 ms steps a claim waits for the cover's editor to bind.
    static let claimSteps = 70
    static let step: TimeInterval = 0.03

    /// Whether the editor is covered, asked now.
    var covered: Bool { isCovered() }

    func update(isCovered: @escaping () -> Bool, claim: CentreKeys.Claim?) {
        self.isCovered = isCovered
        let covered = isCovered()
        if covered, !wasCovered { enforceSoon() }
        wasCovered = covered
        if claim != self.claim {
            self.claim = claim
            generation += 1
            if let claim { attemptClaim(claim, generation: generation, remaining: Self.claimSteps) }
        }
    }

    func stop() {
        generation += 1
        observation = nil
        observedWindow = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window !== observedWindow else { return }
        observedWindow = window
        observation = window?.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.enforceSoon() }
        }
        enforceSoon()
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)), #selector(redo(_:)): return false
        default: return true
        }
    }

    /// On the next turn, if anything inside the manuscript has the keys and
    /// the editor is still covered, move them to the cover's editor or to this
    /// view. The cheap ancestry test first; the route only when it says yes
    /// (review N5).
    private func enforceSoon() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window,
                  CentreKeys.isInsideTheManuscript(window.firstResponder),
                  self.isCovered() else { return }
            window.makeFirstResponder(self.coverEditor(in: window) ?? self)
        }
    }

    private func attemptClaim(_ claim: CentreKeys.Claim, generation: Int, remaining: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.step) { [weak self] in
            guard let self, generation == self.generation else { return }
            guard let window = self.window, self.isCovered() else {
                if remaining > 0 { self.attemptClaim(claim, generation: generation, remaining: remaining - 1) }
                return
            }
            guard CentreKeys.mayClaim(from: window.firstResponder) else { return }
            if claim.prefersEditor {
                if let editor = self.coverEditor(in: window) {
                    window.makeFirstResponder(editor)
                    return
                }
                // Not bound yet: hold the keys here meanwhile, and look again.
                if !(window.firstResponder === self) { window.makeFirstResponder(self) }
                if remaining > 0 {
                    self.attemptClaim(claim, generation: generation, remaining: remaining - 1)
                }
                return
            }
            window.makeFirstResponder(self)
        }
    }

    /// The cover's own text editor: a `MaughamTextView` over this view's frame
    /// that is not the manuscript's.
    private func coverEditor(in window: NSWindow) -> MaughamTextView? {
        guard let root = window.contentView else { return nil }
        let mine = convert(bounds, to: nil)
        return Self.all(MaughamTextView.self, in: root).first { editor in
            !CentreKeys.isManuscriptEditor(editor)
                && CentreKeys.lies(Self.visibleFrame(of: editor), within: mine)
        }
    }

    /// Where an editor shows, in window coordinates: its scroll view's frame
    /// (a text view's own bounds run the length of its text).
    static func visibleFrame(of editor: NSView) -> NSRect {
        let shown: NSView = editor.enclosingScrollView ?? editor
        return shown.convert(shown.bounds, to: nil)
    }

    static func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var found: [T] = []
        func walk(_ view: NSView) {
            if let hit = view as? T { found.append(hit) }
            view.subviews.forEach(walk)
        }
        walk(view)
        return found
    }
}
