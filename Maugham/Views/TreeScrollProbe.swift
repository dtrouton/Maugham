import AppKit
import SwiftUI
import MaughamCore
import os

/// **A dev-build-only diagnostic for "the tree scrolls on a pass swap"**
/// (`docs/superpowers/notes/2026-08-18-tree-scroll-on-pass-swap.md`).
///
/// The bug has never been reproduced under test: the two gestures that trigger
/// it (the round cockpit's lane picker, a board chip) both reduce to one
/// `documentStore.updateUIState { $0.activePassMemory.record(…) }`, and driving
/// that write against a mounted tree — probe host and real `ProjectWindow`
/// alike — moves the binder's scroll offset by exactly zero. Eight hypotheses
/// are falsified in that note; what is left needs the REAL window, which this
/// session could not have (screen locked ⇒ no key window ⇒ no faithful
/// `List(selection:)` push).
///
/// So this is the instrument rather than the fix. It watches the tree's own
/// `NSClipView` and, the moment its bounds origin moves, writes the stack that
/// moved it. **One stack decides the whole question**: either
/// `BinderTreeSectionsState.consumePendingScroll` is in it (a `scrollRequest`
/// written by something the note's census says cannot write one) or it is not
/// (AppKit/SwiftUI moved the offset on its own — selection reveal, focus
/// restoration, relayout), and those two answers want fixes in different files.
///
/// **What it is NOT.** It never reads, writes or touches the scene: no gesture,
/// no hit-testing (`hitTest` returns `nil`, `TreeTravelTargetView`'s argument),
/// no state, and nothing downstream of it. Removing this file and its four call
/// sites leaves the app byte-identical in behaviour.
///
/// **Where its output lands** — both, deliberately, because Console is where a
/// live reproduction is watched and a file is what gets handed back:
///
/// - `os.Logger`, subsystem = the running bundle id, **category
///   `TreeScrollProbe`**, every line prefixed `TREESCROLL`. Watch it live with
///   `log stream --predicate 'category == "TreeScrollProbe"' --info`, or read
///   it back with `log show --last 10m --predicate 'category ==
///   "TreeScrollProbe"' --info`.
/// - `~/Library/Application Support/Maugham Dev/tree-scroll-probe.log` (the
///   support folder is `BuildVariant.current.supportFolderName`, so a stable
///   build would write beside it — except a stable build never installs).
///   Appended, never truncated; the full call stack goes here, where `os_log`'s
///   per-message ceiling cannot clip it.
///
/// Grep either for `TREESCROLL move`.
enum TreeScrollProbeGate {

    /// **Dev builds only, and never inside a test host.**
    ///
    /// `BuildVariant.dev` is the Debug configuration (`project.yml`), which is
    /// also what the xctest hosts build — so the variant alone would install
    /// this in all 4,600 of them. `XCTestCase` being loadable is the
    /// discriminator, and it is checked ONCE at first touch rather than per
    /// body pass.
    ///
    /// `MAUGHAM_TREE_SCROLL_PROBE=0` in the environment turns it off in a dev
    /// build too, for a session that wants a quiet Console.
    static let isEnabled: Bool = {
        guard BuildVariant.current == .dev else { return false }
        guard NSClassFromString("XCTestCase") == nil else { return false }
        guard ProcessInfo.processInfo.environment["MAUGHAM_TREE_SCROLL_PROBE"] != "0"
        else { return false }
        return true
    }()
}

extension View {
    /// Attach to a tree host's `List`, immediately after
    /// `consumingTreeScrollRequests` — the three hosts are `BinderView`,
    /// `CollectionPiecesPane` and `SceneNavigatorPane`, the same three that
    /// pair `binderTreeSections` with the scroll consumer.
    ///
    /// A no-op view modifier in a release build and in every test host: the
    /// `else` arm returns `self` unchanged, so nothing is mounted, nothing is
    /// observed, and no notification is registered.
    @ViewBuilder
    func treeScrollProbe() -> some View {
        if TreeScrollProbeGate.isEnabled {
            background(TreeScrollProbeAnchor())
        } else {
            self
        }
    }
}

/// The mark that finds the tree's scroll view. Behind the `List`, hit-test
/// transparent, carrying no state of its own — `TreeTravelTarget`'s shape, and
/// for `TreeTravelTargetView`'s reason: a view that can be hit is a view that
/// can eat a click the table needed.
private struct TreeScrollProbeAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> TreeScrollProbeAnchorView {
        TreeScrollProbeAnchorView()
    }

    func updateNSView(_ nsView: TreeScrollProbeAnchorView, context: Context) {}
}

final class TreeScrollProbeAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // The `List`'s `NSScrollView` is a sibling built by SwiftUI's own
        // update pass, which has not necessarily run when this view lands in
        // the window. Retry on a short ladder rather than assuming — a probe
        // that installs on the second attempt is still a probe; one that gives
        // up silently on the first is a probe that reports nothing and looks
        // like a clean bill of health.
        retryInstall(attemptsLeft: 6, delay: 0.15)
    }

    private func retryInstall(attemptsLeft: Int, delay: TimeInterval) {
        guard attemptsLeft > 0, window != nil else { return }
        if TreeScrollProbe.shared.install(from: self) { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.retryInstall(attemptsLeft: attemptsLeft - 1, delay: delay * 2)
        }
    }
}

/// The observer itself. One per app; it holds clip views weakly and registers
/// each one exactly once, so a row recycling or a tree remount cannot
/// double-subscribe or leave a zombie behind.
@MainActor
final class TreeScrollProbe {

    static let shared = TreeScrollProbe()

    /// Two changes closer together than this are the same burst — a drag, a
    /// momentum scroll, an animated reveal. Only the FIRST of a burst gets a
    /// stack, because the first is the one that names the caller; the rest are
    /// counted and reported on the next line.
    private static let burstGap: TimeInterval = 0.4

    private struct Watch {
        weak var clip: NSClipView?
        var lastOffset: CGPoint
        var lastLoggedAt: Date
        var suppressed: Int
    }

    private let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.Maugham",
        category: "TreeScrollProbe")

    private var watches: [ObjectIdentifier: Watch] = [:]
    private var tokens: [ObjectIdentifier: NSObjectProtocol] = [:]

    private init() {}

    /// Find the tree's scroll view from `anchor` and start watching it.
    /// Returns whether a scroll view was found (so the caller can retry).
    @discardableResult
    func install(from anchor: NSView) -> Bool {
        guard let scrollView = Self.treeScrollView(from: anchor) else { return false }
        let clip = scrollView.contentView
        let key = ObjectIdentifier(clip)
        guard watches[key] == nil else { return true }

        clip.postsBoundsChangedNotifications = true
        watches[key] = Watch(clip: clip,
                             lastOffset: clip.bounds.origin,
                             lastLoggedAt: .distantPast,
                             suppressed: 0)
        tokens[key] = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clip, queue: nil
        ) { _ in
            MainActor.assumeIsolated { TreeScrollProbe.shared.boundsChanged(key: key) }
        }

        let frame = scrollView.convert(scrollView.bounds, to: nil)
        let docHeight = scrollView.documentView?.frame.height ?? 0
        write("TREESCROLL installed clip=\(key.debugDescription) "
              + "scrollFrameInWindow=\(Self.rect(frame)) "
              + "viewportH=\(Self.n(clip.bounds.height)) contentH=\(Self.n(docHeight)) "
              + "docView=\(String(describing: type(of: scrollView.documentView))) "
              + "window=\(scrollView.window?.title ?? "—")")
        return true
    }

    private func boundsChanged(key: ObjectIdentifier) {
        guard var watch = watches[key], let clip = watch.clip else { return }
        let new = clip.bounds.origin
        let old = watch.lastOffset
        // Width-only changes (a column drag) are not what this is about, and a
        // sub-point wobble is rounding.
        guard abs(new.y - old.y) > 0.5 else {
            watch.lastOffset = new
            watches[key] = watch
            return
        }

        let now = Date()
        guard now.timeIntervalSince(watch.lastLoggedAt) >= Self.burstGap else {
            watch.suppressed += 1
            watch.lastOffset = new
            watches[key] = watch
            return
        }

        let suppressed = watch.suppressed
        watch.suppressed = 0
        watch.lastLoggedAt = now
        watch.lastOffset = new
        watches[key] = watch

        let window = clip.window
        let responder = window?.firstResponder
        write("TREESCROLL move y \(Self.n(old.y)) -> \(Self.n(new.y)) "
              + "(delta \(Self.n(new.y - old.y))) "
              + "viewportH=\(Self.n(clip.bounds.height)) "
              + "contentH=\(Self.n(clip.documentView?.frame.height ?? 0)) "
              + "appActive=\(NSApp?.isActive == true) "
              + "keyWindow=\(window?.isKeyWindow == true) "
              + "firstResponder=\(responder.map { String(describing: type(of: $0)) } ?? "—") "
              + "priorBurstSuppressed=\(suppressed)")
        writeStack()
    }

    // MARK: - Where the scroll view is

    /// The `NSScrollView` the tree's rows live in, found from a mark placed
    /// BEHIND the `List`.
    ///
    /// `enclosingScrollView` first, for the case where SwiftUI puts the
    /// background inside the scroll view; otherwise walk the ancestors one
    /// level at a time and take the first level whose subtree holds a scroll
    /// view with a table in it. Level-at-a-time is what keeps this local: from
    /// far enough up, a depth-first search would happily return the annotations
    /// queue's scroll view in the other column.
    private static func treeScrollView(from anchor: NSView) -> NSScrollView? {
        if let enclosing = anchor.enclosingScrollView,
           enclosing.documentView is NSTableView {
            return enclosing
        }
        var ancestor = anchor.superview
        while let current = ancestor {
            if let found = firstTableScrollView(in: current) { return found }
            ancestor = current.superview
        }
        return nil
    }

    private static func firstTableScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.documentView is NSTableView {
            return scroll
        }
        for sub in view.subviews {
            if let found = firstTableScrollView(in: sub) { return found }
        }
        return nil
    }

    // MARK: - Output

    private func writeStack() {
        // `prefix` because the interesting frames are the near ones — the
        // AppKit/SwiftUI call that moved the clip view — and the tail is the
        // runloop every stack shares.
        for (index, symbol) in Thread.callStackSymbols.prefix(48).enumerated() {
            write("TREESCROLL   #\(index) \(symbol)")
        }
    }

    private func write(_ line: String) {
        log.info("\(line, privacy: .public)")
        Self.appendToFile(line)
    }

    /// The file sink. Best-effort by construction: a probe that throws, blocks
    /// or crashes on a disk problem would be worse than the bug it is looking
    /// for.
    private static func appendToFile(_ line: String) {
        guard let url = fileURL else { return }
        let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        guard let data = stamped.data(using: .utf8) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    private static let fileURL: URL? = {
        guard let library = FileManager.default.urls(
            for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        return library
            .appendingPathComponent("Application Support")
            .appendingPathComponent(BuildVariant.current.supportFolderName)
            .appendingPathComponent("tree-scroll-probe.log")
    }()

    private static func n(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }

    private static func rect(_ r: CGRect) -> String {
        "(\(n(r.origin.x)),\(n(r.origin.y)) \(n(r.width))x\(n(r.height)))"
    }
}
