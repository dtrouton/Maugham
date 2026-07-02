// Maugham/Events/MaughamEvent+Receive.swift
import SwiftUI
import AppKit

/// Receive-side helpers (ADR 0021). Every `maugham.*` subscription goes
/// through one of these — the scope filter and the closed-window liveness
/// guard live in `MaughamEvent.shouldDeliver`, written exactly once. Receiver
/// bodies contain action logic only; hand-written `isKeyWindow` /
/// userInfo-comparison guards are deleted by the migration.
///
/// `window` is the receiving view's hosting NSWindow (the `WindowAccessor`
/// idiom — `ProjectWindow` already resolves it; panes that need one add
/// `@State private var window: NSWindow?` + `.background(WindowAccessor(window: $window))`).
extension View {

    /// Menu-command class: delivered only when this view's window is key.
    /// Key status implies liveness, so this also excludes closed windows.
    func onKeyWindowCommand(
        _ name: Notification.Name,
        window: NSWindow?,
        perform action: @escaping (Notification) -> Void
    ) -> some View {
        onReceive(NotificationCenter.default.publisher(for: name)) { note in
            guard MaughamEvent.shouldDeliver(
                note, to: .forWindow(window, kind: .keyWindow)) else { return }
            action(note)
        }
    }

    /// Data event for windows presenting `docId`. Also drops delivery when
    /// this view's window is closed (liveness guard).
    func onDocumentEvent(
        _ name: Notification.Name,
        docId: String,
        window: NSWindow?,
        perform action: @escaping (Notification) -> Void
    ) -> some View {
        onReceive(NotificationCenter.default.publisher(for: name)) { note in
            guard MaughamEvent.shouldDeliver(
                note, to: .forWindow(window, kind: .document(docId: docId))) else { return }
            action(note)
        }
    }

    /// Data event for windows on this project. Also drops delivery when this
    /// view's window is closed (liveness guard).
    func onProjectEvent(
        _ name: Notification.Name,
        url: URL,
        window: NSWindow?,
        perform action: @escaping (Notification) -> Void
    ) -> some View {
        onReceive(NotificationCenter.default.publisher(for: name)) { note in
            guard MaughamEvent.shouldDeliver(
                note,
                to: .forWindow(window, kind: .project(id: ProjectIdentifier.id(for: url)))
            ) else { return }
            action(note)
        }
    }

    /// Global fan-out. Passthrough by design — NO liveness guard
    /// (`appWillTerminate` must reach everything); exists so the tripwire's
    /// "every receiver goes through a helper" rule has no exceptions. Each
    /// global name's zombie-harm audit note lives in MaughamNotifications.swift.
    func onGlobalEvent(
        _ name: Notification.Name,
        perform action: @escaping (Notification) -> Void
    ) -> some View {
        onReceive(NotificationCenter.default.publisher(for: name)) { note in
            guard MaughamEvent.shouldDeliver(
                note,
                to: EventReceiverContext(kind: .global, isWindowLive: true, isWindowKey: false)
            ) else { return }
            action(note)
        }
    }
}

extension MaughamEvent {
    /// Non-View subscription (AppKit coordinators, workers). `context` is
    /// evaluated at EACH delivery on the main actor; return `nil` when the
    /// owner is no longer live — a `nil` context drops the delivery. This is
    /// the explicit liveness contract the spec requires: an
    /// `EditorCoordinator` past `detach()` must not act on deliveries, so its
    /// context closure returns nil once `isDetached` (and `detach()` also
    /// removes the token). Remove the returned token in detach()/deinit via
    /// `NotificationCenter.default.removeObserver(token)`.
    @MainActor
    static func observe(
        _ name: Notification.Name,
        context: @escaping @MainActor () -> EventReceiverContext?,
        handler: @escaping @MainActor (Notification) -> Void
    ) -> NSObjectProtocol {
        // adr-0021-ok: the wrapper itself — the ONE sanctioned raw subscription site
        NotificationCenter.default.addObserver(
            forName: name, object: nil, queue: .main
        ) { note in
            // NC posts these on .main (queue: .main), so we're on the main
            // thread; assumeIsolated bridges without a Task hop and asserts
            // in debug if that ever stops holding (the EditorCoordinator idiom).
            MainActor.assumeIsolated {
                guard let ctx = context(),
                      MaughamEvent.shouldDeliver(note, to: ctx) else { return }
                handler(note)
            }
        }
    }
}
