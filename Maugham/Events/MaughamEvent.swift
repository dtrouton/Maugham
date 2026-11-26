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

    /// Payload key for `.maughamSetRightColumn`: a
    /// `RightColumnPosition.rawValue`. One spelling shared by every post and
    /// `ProjectWindow`'s receiver, so a rename cannot silently make the post
    /// a no-op.
    static let positionKey = "position"

    /// Payload key for `.maughamSetRightColumn`'s filter half (shell plan 2
    /// Task 7): a `ResolveKeyFilter.rawValue` riding beside the position when
    /// a key that used to open the Annotations, Diagnostics or Tasks pane
    /// opens To resolve on its filter. Absent for every other post.
    static let resolveFilterKey = "resolve_filter"

    /// Payload key for `.maughamAddLanguage`: the language a proposed brief
    /// names, which the Add Language sheet opens on. Absent for the Editions
    /// `+`.
    static let proposedLanguageKey = "proposed_language"

    /// Payload key for `.maughamSetRightColumn`: a `BriefField.rawValue` on
    /// ⌘⌥I's and ⌘⌥N's posts — Brief, with the keys in that field.
    static let briefFieldKey = "brief_field"

    /// Payload key for `.maughamPullUp`: a `PullUpRequest.rawValue`.
    static let pullUpKey = "pull_up"

    /// Payload key for `.maughamPullUp`: the piece a History is of, on a tree
    /// row's History (`postPullUpHistory(ofPiece:)`). Absent on the keys'.
    static let pullUpPieceKey = "pull_up_piece"

    /// Payload key for `.maughamChooseCentreView`: `CentreViewSwitch.token`.
    static let centreViewKey = "centre_view"

    /// Payload keys for `.maughamCanvasNodesAdded`. Constants for the reason
    /// `positionKey` is one: the post site (`AddCanvasScrapsTool`) and whatever
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
    /// to end. Same reason as `positionKey`: the post sites are five row views
    /// and the receiver is `TreeTravel.swift`, so a rename on either side must
    /// not silently make the post reach nobody.
    static let treeTravelSubjectKey = "subject"

    /// Payload keys for `.maughamTreeTravel`'s gesture (shell p1 Task 3): the
    /// click count (`Int`, 1 or 2), and whether the row was already the tree's
    /// selected row when the click arrived (`Bool`) — a click on the row
    /// already selected writes nothing through the `List`, so the receiver is
    /// the only place it is heard.
    static let treeTravelClickCountKey = "clickCount"
    static let treeTravelRowWasSelectedKey = "rowWasSelected"

    /// Payload key for `.maughamDocumentNotice` — the finished sentence the
    /// window puts in front of the writer. Same reason as `positionKey`: the
    /// post sites live in `Maugham/OpLog/` and the receiver in
    /// `ProjectWindow.swift`, so a rename must not quietly make the toast read
    /// nil and show nothing, which is the very failure these notices exist to
    /// end.
    static let noticeMessageKey = "notice_message"

    /// Payload key for `.maughamAnnotationsChanged` — the document whose notes
    /// changed. Same reason as `positionKey`: the post sites are in
    /// `Maugham/OpLog/` and `Maugham/Stores/`, the readers are two panes and a
    /// window's count column, and a rename on one side must not silently make
    /// the other read nil.
    static let annotationDocIdKey = "doc_id"

    /// Payload key for `.maughamNavigateToParagraph`'s optional caret offset
    /// into the paragraph (UTF-16, display text) — posted by
    /// `TranslationReveal`, read by `EditorCoordinator` (report plan 8a Task 7).
    static let paragraphOffsetKey = "paragraph_offset"

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

    /// **The one spelling of the statement-proposals-changed post** (P5).
    /// Posted by the two propose tools after staging and by
    /// `StatementProposalGate` after Adopt or Discard. `projectURL` is the
    /// project ROOT, matching what `.onProjectEvent` subscribes with.
    static func postStatementProposalsChanged(projectURL: URL) {
        post(.maughamStatementProposalsChanged, to: .project(for: projectURL))
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

    /// **The one spelling of the round-record post** (shell p4 Task 6 fix
    /// round): a verb rewrote a round's record (`TranslationRoundStore.mutate`
    /// through `TranslationRoundActions.production`). `projectURL` is the
    /// project ROOT, as for `postTranslationRoundEnded`.
    static func postTranslationRoundChanged(projectURL: URL) {
        post(.maughamTranslationRoundChanged, to: .project(for: projectURL))
    }

    /// Whether an admission request is the WRITER asking (History's *Admit…*)
    /// rather than the book reporting a stranger it has just noticed.
    static let admissionForcedKey = "maugham.admission.forced"

    /// **The one spelling of the admission-requested post** (signed op log
    /// P2b). Three callers: a document registering with held lines, a
    /// stranger's file arriving through the presenter, and History's *Admit…*.
    ///
    /// `forced` is the writer's own ask, which reopens a sheet dismissed with
    /// *Not now* earlier in this window; the other two leave that dismissal
    /// standing (spec §4.1: *Not now* dismisses until the next open).
    /// `projectURL` is the project ROOT, matching what the `.onProjectEvent`
    /// receivers subscribe with.
    static func postAdmissionRequested(projectURL: URL, forced: Bool = false) {
        post(.maughamAdmissionRequested, to: .project(for: projectURL),
             payload: [admissionForcedKey: forced])
    }

    /// **The one spelling of the admission-settled post** (signed op log P2b) —
    /// a person record was written, so every surface reporting on trust in this
    /// book re-derives. Posted by `DocumentStore.admit` and by the silent
    /// admission at open.
    static func postAdmissionSettled(projectURL: URL) {
        post(.maughamAdmissionSettled, to: .project(for: projectURL))
    }

    /// Ask the key window's right column to show `position` (⌘1, ⌘2, ⌘3; the
    /// old pane keys that land on a position; the drift line).
    ///
    /// **The one spelling of this post.** Scoped `.keyWindow` because it is a
    /// command, not a data event — only the focused project window moves.
    static func postPosition(_ position: RightColumnPosition) {
        post(.maughamSetRightColumn, to: .keyWindow,
             payload: [positionKey: position.rawValue])
    }

    /// Ask the key window's right column to show To resolve on `filter`
    /// (shell plan 2 Task 7) — ⌘⌥A, ⌘⌥D and ⌘⌥T, and the translation round's
    /// Open queue. The same event as `postPosition`, so the receiver's one
    /// selection act (`ProjectWindow.selectPosition`) still reveals the
    /// column; the filter key is what it reads next.
    static func postResolve(_ filter: ResolveKeyFilter) {
        post(.maughamSetRightColumn, to: .keyWindow,
             payload: [positionKey: RightColumnPosition.resolve.rawValue,
                       resolveFilterKey: filter.rawValue])
    }

    /// Ask the key window to show the Brief of the piece open in its centre
    /// (the line above the prose, `IntentStrip`): the faces go to the open
    /// piece, then Brief shows.
    static func postBriefOfTheOpenPiece() {
        post(.maughamShowOpenPieceBrief, to: .keyWindow)
    }

    /// Payload keys for `.maughamShowParagraphInResolve`: the piece (beside
    /// `annotationDocIdKey`'s spelling) and its paragraph.
    static let marginParagraphIdKey = "paragraph_id"
    /// Payload key for `.maughamSetMargin`: a `MarginSetting.rawValue`.
    static let marginSettingKey = "margin_setting"

    /// **A margin mark was clicked** (shell p5 Task 2): the key window's To
    /// resolve shows `paragraphId`'s group, revealing a hidden right column —
    /// a click is a deliberate act. The editor receives nothing.
    static func postShowParagraphInResolve(docId: String, paragraphId: String, annotationId: String? = nil) {
        var payload: [AnyHashable: Any] = [annotationDocIdKey: docId, marginParagraphIdKey: paragraphId]
        if let annotationId { payload[marginAnnotationIdKey] = annotationId }
        post(.maughamShowParagraphInResolve, to: .keyWindow, payload: payload)
    }

    /// Payload key for `.maughamShowParagraphInResolve`: the note whose dot
    /// was clicked, when the mark is one note's.
    static let marginAnnotationIdKey = "annotation_id"

    /// The note a margin click names, or nil (a tick, or several notes' dot).
    static func marginAnnotationId(of userInfo: [AnyHashable: Any]?) -> String? {
        userInfo?[marginAnnotationIdKey] as? String
    }

    /// What a `.maughamShowParagraphInResolve` asks, or nil.
    static func paragraphInResolve(of userInfo: [AnyHashable: Any]?) -> (docId: String, paragraphId: String)? {
        guard let docId = userInfo?[annotationDocIdKey] as? String,
              let paragraphId = userInfo?[marginParagraphIdKey] as? String else { return nil }
        return (docId, paragraphId)
    }

    /// View ▸ Margin's items: the key window's setting.
    static func postMarginSetting(_ setting: MarginSetting) {
        post(.maughamSetMargin, to: .keyWindow, payload: [marginSettingKey: setting.rawValue])
    }

    /// What a `.maughamSetMargin` asks, or nil.
    static func marginSetting(of userInfo: [AnyHashable: Any]?) -> MarginSetting? {
        (userInfo?[marginSettingKey] as? String).flatMap(MarginSetting.init(rawValue:))
    }

    /// ⌘⌥K: the To resolve of the edition the window is reading in, else
    /// the Source edition's (shell p4 Task 7) — the faces move to that
    /// edition (`EditionWiring.editionForTheKey`).
    static func postShowEditionResolve() {
        post(.maughamShowEditionResolve, to: .keyWindow)
    }

    /// Start an edition (shell p4 Task 7): the key window presents the Add
    /// Language sheet — from the Editions `+`, the Source row's menu, or a
    /// proposed brief's Add (`proposing` its language).
    static func postAddLanguage(proposing language: String? = nil) {
        var payload: [AnyHashable: Any] = [:]
        if let language { payload[proposedLanguageKey] = language }
        post(.maughamAddLanguage, to: .keyWindow, payload: payload)
    }

    /// A translated edition's row menu and File ▸ Remove Edition…: the
    /// window asks, then hides `language`'s edition (`EditionWiring`).
    static func postRemoveEdition(_ language: String) {
        post(.maughamRemoveEdition, to: .keyWindow, payload: [removeEditionLanguageKey: language])
    }

    static let removeEditionLanguageKey = "language"

    /// ⌘⌥I and ⌘⌥N: Brief, with the keys in its line or in Going for's editor
    /// (`BriefField`). The field takes them only where the faces' Brief has
    /// it (`BriefField.isOffered(in:)`).
    static func postBriefField(_ field: BriefField) {
        post(.maughamSetRightColumn, to: .keyWindow,
             payload: [positionKey: RightColumnPosition.brief.rawValue,
                       briefFieldKey: field.rawValue])
    }

    /// Ask the key window to pull `request` up beside its centre (⌘⌥G, ⌘⌥Y,
    /// ⌘⌥V, ⌃⌘H; the standing line's History).
    static func postPullUp(_ request: PullUpRequest) {
        post(.maughamPullUp, to: .keyWindow,
             payload: [pullUpKey: request.rawValue])
    }

    /// Ask the key window to pull up `docId`'s History — a tree row's
    /// History, which is of that row's piece, not of the faces (appraisal 6).
    static func postPullUpHistory(ofPiece docId: String) {
        post(.maughamPullUp, to: .keyWindow,
             payload: [pullUpKey: PullUpRequest.historyOfTheFaces.rawValue,
                       pullUpPieceKey: docId])
    }

    /// Ask the key window to pull up again what was pulled up before (⌘[,
    /// View ▸ Back; `PulledUpHistory`).
    static func postPullUpPrevious() {
        post(.maughamPullUpPrevious, to: .keyWindow)
    }

    /// Ask the key window to add a piece or a group at its binder's root
    /// (File ▸ New Chapter / New Part; the binder's own root verbs).
    static func postAddBinderItem(_ request: BinderItemRequest) {
        post(.maughamAddBinderItem, to: .keyWindow, payload: [BinderItemRequest.key: request.rawValue])
    }

    /// Ask the key window's tree to open the faces' piece's fold (⌘⌥E).
    static func postShowPieceFold() {
        post(.maughamShowPieceFold, to: .keyWindow)
    }

    /// Ask the key window to run `command` (`RunCommand`: Check Writing,
    /// Reread, Run Round, Fresh Eyes) — each its own event, so the command
    /// names its kind and no receiver infers one.
    ///
    /// No payload: which piece is read is the receiving window's own answer
    /// (its subject, `CompilerRunModifier.request`), not the menu's — the menu
    /// has no idea what any window is looking at.
    static func postRun(_ command: RunCommand) {
        post(command.event, to: .keyWindow)
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
