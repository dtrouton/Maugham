// Maugham/Events/MaughamEvent.swift
import AppKit
import Foundation

/// Delivery scope for an internal `maugham.*` event, declared at the POST
/// site (ADR 0021). There is no unscoped post: NotificationCenter's
/// broadcast-by-default made the wrong thing frictionless and shipped the
/// same cross-window defect 3+ times (rewind retrofit, script.did.update,
/// toggleInspector). The scope kinds:
///
/// - `.keyWindow` — menu-command class; only the key window acts.
/// - `.document(docId:)` — data event for windows presenting this document.
/// - `.project(id:)` — data event for windows on this project. `id` is
///   `ProjectIdentifier.id(for:)`, NOT a raw URL (symlink-stable; matches the
///   pre-existing scriptDidUpdate / mcpNoteAdded idiom).
/// - `.allWindows` — genuinely global fan-out (app lifecycle, welcome window).
enum EventScope: Equatable {
    case keyWindow
    case document(docId: String)
    case project(id: String)
    case allWindows

    static func project(for url: URL) -> EventScope {
        .project(id: ProjectIdentifier.id(for: url))
    }

    var kindString: String {
        switch self {
        case .keyWindow: return "key-window"
        case .document: return "document"
        case .project: return "project"
        case .allWindows: return "all-windows"
        }
    }

    var idString: String? {
        switch self {
        case .document(let docId): return docId
        case .project(let id): return id
        case .keyWindow, .allWindows: return nil
        }
    }
}

/// The typed post/receive layer over NotificationCenter (ADR 0021). Underneath
/// it is plain NC — same delivery timing, `object:` passthrough — with the
/// scope riding `userInfo` under reserved keys. All `maugham.*` posts and
/// subscriptions go through here; TripwireGrepTests enforces it.
enum MaughamEvent {

    /// Reserved userInfo keys carrying the scope. Payload keys must not
    /// collide with these.
    static let scopeKindKey = "maugham.scope.kind"
    static let scopeIdKey = "maugham.scope.id"

    /// Payload key for `.maughamSetPersona`. One spelling shared by both post
    /// sites (the View menu's ⌘1–⌘4 and the persona bar) and the receiver in
    /// `PersonaModifier`, so a rename cannot silently make the post a no-op.
    static let personaKey = "persona"

    /// Post `name` to the given scope. `object` and `payload` pass through to
    /// NotificationCenter unchanged (payload keys must not shadow the
    /// reserved scope keys).
    static func post(
        _ name: Notification.Name,
        to scope: EventScope,
        object: Any? = nil,
        payload: [AnyHashable: Any] = [:]
    ) {
        assert(payload[scopeKindKey] == nil && payload[scopeIdKey] == nil,
               "payload must not shadow the reserved maugham.scope.* keys")
        var userInfo = payload
        userInfo[scopeKindKey] = scope.kindString
        if let id = scope.idString {
            userInfo[scopeIdKey] = id
        }
        // adr-0021-ok: the wrapper itself — the ONE sanctioned raw post site
        NotificationCenter.default.post(name: name, object: object, userInfo: userInfo)
    }

    /// Window liveness. A closed window is neither visible nor miniaturized;
    /// a miniaturized (Dock) window is still open and must keep receiving its
    /// data events. NOTE: `WindowAccessor` caches the NSWindow and never
    /// re-nils it, so `window == nil` is NOT a close check — this predicate
    /// is the liveness guard the ADR 0021 addendum requires (SwiftUI scene
    /// storage retains closed-window view graphs; a zombie receiver otherwise
    /// matches its own project's events and does real work).
    @MainActor
    static func isLive(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window.isVisible || window.isMiniaturized
    }

    /// THE scope filter — the single implementation of every drop rule.
    /// Receive helpers (View modifiers + `observe`) all funnel through here;
    /// receiver bodies never re-implement a guard.
    ///
    /// Drop rules:
    /// - unscoped note (no scope kind): dropped. Legacy/raw posts don't reach
    ///   scoped receivers; the tripwire (Task 9) makes such posts unwritable.
    /// - scope-kind mismatch (posted `.project`, subscribed `.onKeyWindowCommand`):
    ///   dropped — a wiring bug, not a delivery.
    /// - `.keyWindow`: delivered iff the receiver's window is key (key ⇒ live,
    ///   so the key check subsumes the liveness guard).
    /// - `.document`/`.project`: delivered iff the scope id matches AND the
    ///   receiver's window is live (closed windows receive NOTHING).
    /// - `.allWindows`: delivered unconditionally — deliberately NO liveness
    ///   guard (`appWillTerminate` must reach everything, including view
    ///   graphs SwiftUI has already detached). Each global name carries a
    ///   zombie-harm audit note in MaughamNotifications.swift.
    static func shouldDeliver(_ note: Notification, to context: EventReceiverContext) -> Bool {
        let kind = note.userInfo?[scopeKindKey] as? String
        let scopeId = note.userInfo?[scopeIdKey] as? String
        switch context.kind {
        case .keyWindow:
            guard kind == "key-window" else { return false }
            return context.isWindowKey
        case .document(let docId):
            guard kind == "document" else { return false }
            return context.isWindowLive && scopeId == docId
        case .project(let id):
            guard kind == "project" else { return false }
            return context.isWindowLive && scopeId == id
        case .global:
            return kind == "all-windows"
        }
    }
}

/// The receiver's side of the contract: what it subscribes as, plus the
/// window facts the filter needs. A plain value so `shouldDeliver` is
/// unit-testable without real windows; production receivers build it from
/// their hosting NSWindow via `forWindow`.
struct EventReceiverContext {
    enum Kind: Equatable {
        case keyWindow
        case document(docId: String)
        case project(id: String)
        case global
    }
    let kind: Kind
    let isWindowLive: Bool
    let isWindowKey: Bool

    @MainActor
    static func forWindow(_ window: NSWindow?, kind: Kind) -> EventReceiverContext {
        EventReceiverContext(
            kind: kind,
            isWindowLive: MaughamEvent.isLive(window),
            isWindowKey: window?.isKeyWindow == true)
    }
}
