import Foundation

/// Every `maugham.*` name below posts and is received exclusively via
/// `MaughamEvent` (`Maugham/Events/MaughamEvent.swift`, ADR 0021) — no raw
/// `NotificationCenter.default.post`/`addObserver`/`.onReceive` outside the
/// wrapper (enforced by `TripwireGrepTests`). Two more `maugham.*` names live
/// outside this file (`ExportsListView.maughamPublicationCompleted`, `.project`;
/// `TestOpenBridge.maughamTestOpenProject`, dev-only, `.allWindows`) — they
/// follow the same rule but aren't declared here. Names below are
/// grouped/annotated by their delivery scope class:
///
/// - **`.keyWindow`** (the majority — menu-command class; unannotated names
///   below are this class unless noted otherwise): delivered only to the key
///   window.
/// - **`.project(id:)`** (data events for windows on one project —
///   `maughamScriptDidUpdate`, `maughamOpenRewind`, `maughamMCPNoteAdded`,
///   `maughamCheckpointAdded`, `maughamSessionLogChanged`,
///   `maughamNavigateToDocument`): delivered to live windows on the matching
///   project only.
/// - **`.allWindows`** (genuinely global fan-out, no liveness guard — see the
///   per-name zombie-harm audit note where present): `maughamNewProject`,
///   `maughamOpenProject`, `maughamAppWillTerminate`, `maughamShowHelp`.
///
/// `.document(docId:)` exists in `EventScope` and is tested, but no shipped
/// name currently posts at that scope.
extension Notification.Name {
    /// Scope: .allWindows (no liveness guard — must reach everything; ADR 0021).
    /// Zombie-harm audit: sole receiver is `WelcomeHost`
    /// (`MaughamApp.swift`), which sets `showingNewProject = true` to drive a
    /// `.sheet`. A retained closed-Welcome zombie just flips that `@State`;
    /// the sheet can't actually present on an invisible/closed window, so
    /// there is no downstream `openWindow` call and no visible effect.
    /// Harmless. OK.
    public static let maughamNewProject = Notification.Name("maugham.newProject")
    /// Scope: .allWindows (no liveness guard — must reach everything; ADR 0021).
    /// Zombie-harm audit: sole receiver is `WelcomeHost`
    /// (`MaughamApp.swift`), which calls `open(url)` →
    /// `recents.record(url); openWindow(id: "project", value: url)`. A
    /// retained closed-Welcome zombie still runs this: `recents.record`
    /// is idempotent (Recents is a plain most-recently-used list, re-adding
    /// just re-promotes the entry), and `openWindow(id:value:)` on a
    /// `WindowGroup(for: URL.self)` brings the existing window for that URL
    /// forward rather than opening a duplicate (SwiftUI scene identity by
    /// value) — or opens exactly one window if none is open yet. Harmless
    /// duplication at worst. OK.
    public static let maughamOpenProject = Notification.Name("maugham.openProject")
    public static let maughamToggleNoChrome = Notification.Name("maugham.toggleNoChrome")
    public static let maughamToggleReviewMode = Notification.Name("maugham.toggleReviewMode")
    /// Posted by the Translation Review menu command (`.keyWindow`, menu-command
    /// class). The app-global menu can't reach the focused window's active-doc
    /// selection or project URL, so it just asks the key window to resolve the
    /// active doc's available translation languages and present the picker.
    public static let maughamShowTranslationPicker = Notification.Name("maugham.showTranslationPicker")
    /// Posted when the writer picks a translation to review — the key
    /// ProjectWindow enters read-only translation-review posture for the active
    /// doc (EditorHost swaps in the derived translated surface; the coordinator
    /// flips its membrane synchronously). `userInfo["language"]` carries the
    /// BCP-47 language tag. Scope: .keyWindow.
    public static let maughamEnterTranslationReview = Notification.Name("maugham.enterTranslationReview")
    /// Posted to leave translation review and show the source manuscript again.
    /// Scope: .keyWindow.
    public static let maughamExitTranslationReview = Notification.Name("maugham.exitTranslationReview")
    public static let maughamToggleFullScreen = Notification.Name("maugham.toggleFullScreen")
    public static let maughamDummySave = Notification.Name("maugham.dummySave")
    public static let maughamShowProjectSettings = Notification.Name("maugham.showProjectSettings")
    public static let maughamShowClaudeDesktopHelp = Notification.Name("maugham.showClaudeDesktopHelp")
    /// Posted when the owner picks "Share for Review…" — the key ProjectWindow
    /// presents the iCloud Collaborate share sheet for its folder URL, or the
    /// move-to-iCloud explanation when the folder isn't in iCloud Drive.
    public static let maughamShareForReview = Notification.Name("maugham.shareForReview")
    public static let maughamToggleInspector = Notification.Name("maugham.toggleInspector")
    public static let maughamTidyAllFilenames = Notification.Name("maugham.tidyAllFilenames")
    /// Scope: .allWindows (no liveness guard — must reach everything; ADR 0021).
    /// Zombie-harm audit: receivers are `WelcomeHost` (`MaughamApp.swift`,
    /// `Task { await mcpServer?.stop() }` — stopping an already-stopped
    /// server is inert) and `ProjectWindow` (`ProjectWindow.swift`,
    /// `documentStore?.close()`). A closed `ProjectWindow`'s `.onDisappear`
    /// already called `documentStore.close()`; `DocumentStore.close()`
    /// (`DocumentStore.swift`) is idempotent on a second call —
    /// `flushSessionOnQuit()` guards on `activeSession` (nil after the first
    /// close, so `endSessionImmediately` no-ops), `flushPendingSave()` flushes
    /// an already-empty debounce scheduler, the registry drain iterates an
    /// already-empty `_openDocuments` (drained on the first close), and the
    /// file-presenter removal is guarded by `if let presenter = _presenter`
    /// (nilled after the first removal). Harmless double-close. OK.
    public static let maughamAppWillTerminate = Notification.Name("maugham.appWillTerminate")
    public static let maughamAddResearchFile = Notification.Name("maugham.addResearchFile")
    public static let maughamNavigateToDocument = Notification.Name("maugham.navigateToDocument")
    public static let maughamSessionLogChanged = Notification.Name("maugham.sessionLogChanged")
    public static let maughamShowProjectStatistics = Notification.Name("maugham.showProjectStatistics")
    public static let maughamScriptDidUpdate = Notification.Name("maugham.script.did.update")
    public static let maughamNavigateToScene = Notification.Name("maugham.navigate.to.scene")
    public static let maughamShowSyntaxHelp = Notification.Name("maugham.show.syntax.help")
    /// Scope: .allWindows (no liveness guard — must reach everything; ADR
    /// 0021) — this is also why this name stays .allWindows rather than
    /// .keyWindow: Help must work when NO project window exists (Welcome-only
    /// state). Zombie-harm audit: receivers in `WelcomeHost`
    /// (`MaughamApp.swift`) and `ParagraphNavModifier`
    /// (`ProjectWindow.swift`) both call `openWindow(id: "help")` against the
    /// singleton `Window("Maugham Help", id: "help")` — idempotent (brings
    /// the one Help window forward / opens it once). OK.
    public static let maughamShowHelp = Notification.Name("maugham.show.help")
    public static let maughamRestoreLastDeleted = Notification.Name("maugham.restore.last.deleted")
    public static let maughamToggleResearchPreview = Notification.Name("maugham.toggle.research.preview")
    public static let maughamFindMatchSelected = Notification.Name("maugham.find.match.selected")
    public static let maughamFindInProject = Notification.Name("maugham.find.in.project")
    public static let maughamCloseFind = Notification.Name("maugham.close.find")
    public static let maughamSetDetailSegment = Notification.Name("maugham.set.detail.segment")
    public static let maughamMCPNoteAdded = Notification.Name("maugham.mcp.note.added")
    public static let maughamAddLoosePiece = Notification.Name("maugham.add.loose.piece")
    public static let maughamAddScreenplayPiece = Notification.Name("maugham.add.screenplay.piece")
    public static let maughamLinkProject = Notification.Name("maugham.link.project")
    public static let maughamPromotePiece = Notification.Name("maugham.promote.piece")
    public static let maughamOpenRewind = Notification.Name("maugham.open.rewind")
    /// Posted when ⌘S is pressed — triggers a checkpoint capture with an auto-label.
    public static let maughamSaveCheckpoint = Notification.Name("maugham.save.checkpoint")
    /// Posted when Shift-⌘S is pressed — triggers the checkpoint label prompt sheet.
    public static let maughamNamedCheckpoint = Notification.Name("maugham.named.checkpoint")
    /// Posted when `.maugham/checkpoints.jsonl` is added or changed.
    public static let maughamCheckpointAdded = Notification.Name("maughamCheckpointAdded")
    /// Posted when the AnnotationsPane wants the editor to scroll to/select a paragraph.
    /// userInfo["paragraph_id"] contains the paragraph id string.
    public static let maughamNavigateToParagraph = Notification.Name(
        "maughamNavigateToParagraph")
    /// Posted when an annotation should be selected with span precision — the
    /// editor selects the exact resolved span (not just the paragraph) and
    /// scrolls it into view. Carries `userInfo["annotation_id"]` (String) and,
    /// for the paragraph-only fallback, `userInfo["paragraph_id"]` (String?).
    /// The key-window `EditorCoordinator` looks the id up in its
    /// `resolvedReviewMarks`: an `absoluteRange` selects the span; otherwise it
    /// falls back to scrolling to the paragraph (the legacy behaviour). Posted
    /// by `AnnotationsPane.jump(_:)` and by clicking an interactive margin card.
    public static let maughamNavigateToAnnotation = Notification.Name(
        "maughamNavigateToAnnotation")
}
