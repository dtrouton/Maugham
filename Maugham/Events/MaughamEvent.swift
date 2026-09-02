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

    /// Payload key for `.maughamSetDetailSegment`. One spelling shared by every
    /// `postSegment(_:)` call in `MaughamApp`'s View menu, the inspector's Intent
    /// affordance (M1A) and `ProjectWindow`'s receiver — same reason as
    /// `personaKey`. (`PersonaKeyspaceTests` is what holds the menu to one item
    /// per `DetailSegment`; a number written here would be a count over a list,
    /// and the comment this replaced said "nine".)
    static let detailSegmentKey = "segment"

    /// Payload keys for `.maughamCanvasNodesAdded`. Constants for the reason
    /// `personaKey` is one: the post site (`AddCanvasScrapsTool`) and whatever
    /// announces the arrival are written by different hands at different times,
    /// and a rename on one side must not quietly make the other read nil.
    static let canvasScrapCountKey = "scrap_count"
    static let canvasRegionIDKey = "region_id"

    /// Payload key for `.maughamTreeTravel` — the row's own `BinderSubject`,
    /// carried as the value itself rather than a re-encoded string. In-process
    /// `NotificationCenter` delivery needs no wire encoding, and a subject has
    /// no `rawValue` by design (`BinderSubject`'s own doc comment: a site that
    /// wants a bare id has to say what the project means to it) — string-
    /// encoding it here would be inventing the very sentinel that type exists
    /// to end. Same reason as `personaKey`: the post sites are five row views
    /// and the receiver is `TreeTravel.swift`, so a rename on either side must
    /// not silently make the post reach nobody.
    static let treeTravelSubjectKey = "subject"

    /// Payload key for `.maughamDocumentNotice` — the finished sentence the
    /// window puts in front of the writer. Same reason as `personaKey`: the
    /// post sites live in `Maugham/OpLog/` and the receiver in
    /// `ProjectWindow.swift`, so a rename must not quietly make the toast read
    /// nil and show nothing, which is the very failure these notices exist to
    /// end.
    static let noticeMessageKey = "notice_message"

    /// Payload key for `.maughamAnnotationsChanged` — the document whose notes
    /// changed. Same reason as `personaKey`: the post sites are in
    /// `Maugham/OpLog/` and `Maugham/Stores/`, the readers are two panes and a
    /// window's count column, and a rename on one side must not silently make
    /// the other read nil.
    static let annotationDocIdKey = "doc_id"

    /// **The one spelling of the annotations-changed post** (M3 P2 Task 9).
    ///
    /// Six callers — four append sites on `Document`, the merge that brought
    /// foreign annotation ops in, and `DocumentStore`'s presenter arm for a
    /// document that is not open — so the scope and the payload key are decided
    /// here rather than six times. `projectURL` is the project ROOT (the
    /// `Document` reaches it through `opStore.projectURL`), matching what the
    /// `.onProjectEvent` receivers subscribe with.
    static func postAnnotationsChanged(docId: String, projectURL: URL) {
        post(.maughamAnnotationsChanged, to: .project(for: projectURL),
             payload: [annotationDocIdKey: docId])
    }

    /// **The one spelling of the document-notice post.** `message` is a
    /// finished sentence in the writer's language — the caller composes it,
    /// because only the caller knows what it declined or swept.
    static func postNotice(_ message: String, projectURL: URL) {
        post(.maughamDocumentNotice, to: .project(for: projectURL),
             payload: [noticeMessageKey: message])
    }

    /// **The one spelling of the design-proposals-changed post** (P4 Task 6).
    ///
    /// Posted by `DesignGatePromotion` after Approve, Revert or Finalize has
    /// rewritten a `proposal.json`. `projectURL` is the project ROOT, matching
    /// what the `.onProjectEvent` receivers subscribe with. One spelling for the
    /// three verbs, because a scope spelled three times is a scope spelled wrong
    /// once.
    static func postDesignProposalsChanged(projectURL: URL) {
        post(.maughamDesignProposalsChanged, to: .project(for: projectURL))
    }

    /// **The one spelling of the round-ended post.** Posted by the window's
    /// pipeline wiring (`TranslationPipeline.Environment.onRoundEnded`) after a
    /// round is written to `TranslationRoundStore`. `projectURL` is the project
    /// ROOT, matching what the `.onProjectEvent` receivers subscribe with — the
    /// same idiom as `postAnnotationsChanged`/`postDesignProposalsChanged`.
    static func postTranslationRoundEnded(projectURL: URL, round: TranslationRound) {
        post(.maughamTranslationRoundEnded, to: .project(for: projectURL),
             payload: ["language": round.language, "document_id": round.docId,
                       "round": round.number])
    }

    /// Ask the key window's right column to show `segment`.
    ///
    /// **The one spelling of this post**, because there are now two kinds of
    /// caller: the View menu's items, and an inspector arm handing the writer to
    /// a different segment of the column it is itself in (M1A Task 8). Scoped
    /// `.keyWindow` because it is a command, not a data event — only the focused
    /// project window switches.
    static func postDetailSegment(_ segment: DetailSegment) {
        post(.maughamSetDetailSegment, to: .keyWindow,
             payload: [detailSegmentKey: segment.rawValue])
    }

    /// Ask the key window to check what has been written since its last run.
    ///
    /// No payload: which document is checked is the receiving window's own
    /// answer (its `activeDocId`), not the menu's — the menu has no idea what
    /// any window is looking at.
    static func postCompilerRun() {
        post(.maughamRunCompiler, to: .keyWindow)
    }

    /// Ask the key window to read its piece **whole**, on a session that has
    /// read nothing (⌘⇧R).
    ///
    /// A second event rather than a payload on the first: the two keystrokes
    /// are different promises — one costs a delta, the other costs the piece —
    /// and a receiver that had to read a flag out of a `userInfo` dictionary
    /// could deliver the expensive one by accident. No payload here either,
    /// for `postCompilerRun`'s reason: which document is read is the receiving
    /// window's own answer.
    static func postCompilerFreshEyes() {
        post(.maughamFreshEyesCompiler, to: .keyWindow)
    }

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
