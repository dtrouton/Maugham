#if MAUGHAM_DEV_BUILD
import AppKit
import os

/// Dev-build-only weak registry of every `EditorCoordinator` ever created,
/// used to answer one question by hand: **does a CLOSED project window's
/// coordinator get released without quitting the app?** (ADR 0021 scene-storage
/// spike, `docs/superpowers/notes/2026-07-02-scene-storage-spike.md`.)
///
/// It holds each coordinator *weakly*, so a box whose `ref` has gone `nil` means
/// ARC released that coordinator. The success metric for the spike is literally
/// "a weak ref to a closed window's coordinator goes nil" — this probe is the
/// instrument that reads that metric. It cannot be observed headlessly (the
/// SwiftUI `WindowGroup` scene lifecycle isn't drivable from an XCTest host), so
/// the verification is manual: open a project, close its window, then invoke
/// **View → Dump Coordinator Leak Probe (dev)** and read the log line.
///
/// `live` = boxes whose coordinator is still alive; `total` = every coordinator
/// created this launch (alive or freed). After closing the only project window
/// and letting the run loop turn, `live` dropping to 0 means SwiftUI released
/// the scene graph; `live` staying at 1 means the documented framework
/// retention is in effect (the liveness guard makes that residual inert + deaf).
///
/// Whole file is `#if MAUGHAM_DEV_BUILD` — absent from stable, so it can never
/// hold a coordinator alive in a shipping build.
@MainActor
enum CoordinatorLeakProbe {
    private final class WeakBox {
        weak var ref: EditorCoordinator?
        let createdAt = Date()
        init(_ ref: EditorCoordinator) { self.ref = ref }
    }

    private static var boxes: [WeakBox] = []

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.Maugham.dev",
        category: "CoordinatorLeakProbe")

    /// Record a newly created coordinator. Called from `EditorCoordinator.init`.
    static func register(_ coordinator: EditorCoordinator) {
        boxes.append(WeakBox(coordinator))
    }

    /// (live, total) — live = boxes whose coordinator is still alive.
    static func snapshot() -> (live: Int, total: Int) {
        let live = boxes.reduce(0) { $0 + ($1.ref == nil ? 0 : 1) }
        return (live, boxes.count)
    }

    /// Log the current snapshot to the unified log AND stdout so it is visible
    /// in Console.app and in an Xcode run. Invoked by the dev menu item.
    static func dump() {
        let s = snapshot()
        let line = "CoordinatorLeakProbe: live=\(s.live) total=\(s.total) "
            + "(released=\(s.total - s.live))"
        log.notice("\(line, privacy: .public)")
        print("[spike] \(line)")
    }
}
#endif
