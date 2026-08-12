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
///   `maughamCheckpointAdded`, `maughamQuarantineRecordsChanged`,
///   `maughamSessionLogChanged`, `maughamNavigateToDocument`,
///   `maughamTranslationDidUpdate`, `maughamCanvasNodesAdded`,
///   `maughamDocumentNotice`): delivered to live windows on the matching
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
    /// Scope: .keyWindow — "Check Writing" (⌘R). The compiler's one trigger:
    /// the key window asks its `CompilerOrchestrator` to check the active
    /// document. A command, not a data event — a background window running
    /// against its own document would spend a real API call on prose nobody is
    /// looking at.
    public static let maughamRunCompiler = Notification.Name("maugham.run.compiler")
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
    /// Posted by `write_translation` after it appends new translation records —
    /// a data event, so its scope is `.project(for: projectURL)` (mirrors
    /// `maughamMCPNoteAdded`, delivered to live windows on the project only).
    /// `userInfo["document_id"]` and `userInfo["language"]` name the affected
    /// (doc, language). A window already inside translation review for that
    /// pair re-derives its read-only surface so a retranslation lands live
    /// rather than staying frozen until the writer exits and re-enters. Scope:
    /// .project(id:).
    public static let maughamTranslationDidUpdate = Notification.Name("maugham.translation.did.update")
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
    /// Posted by ⌘⌥O (shell-finish stage-3a Task 5). The outline is no longer
    /// a right-pane segment — it is the project row's altitude view (Tasks
    /// 1–3), so the shortcut's new job is to land the writer on that row: the
    /// same `selectedSubject = .project` write Escape and the canvas's own
    /// `selectTheProjectRow` closure already make (spec §4.1), not a second
    /// write invented for the key. Scope: .keyWindow.
    public static let maughamSelectProjectRow = Notification.Name("maugham.select.project.row")
    /// Posted by ⌘⌥R (shell-finish stage-3a Task 5). Research stopped being a
    /// right-pane segment when shell-finish stage 2a gave every persona's tree
    /// its own Research section — so the shortcut's new job is opening that
    /// section if the writer had closed it, not showing a pane. Refused while
    /// `treeFindActive` covers the column: the overlay is the tree's
    /// replacement, not its sibling. Scope: .keyWindow.
    public static let maughamRevealResearchSection = Notification.Name("maugham.reveal.research.section")
    /// ⌘⌥P's twin, for the tree's Palette section. Same task, same refusal.
    /// Scope: .keyWindow.
    public static let maughamRevealPaletteSection = Notification.Name("maugham.reveal.palette.section")
    public static let maughamSetDetailSegment = Notification.Name("maugham.set.detail.segment")
    /// Scope: .keyWindow — payload ["persona": Persona.rawValue].
    /// Only the focused project window switches; other windows keep their own
    /// persona, which is the point of per-window modes.
    static let maughamSetPersona = Notification.Name("maugham.set.persona")
    public static let maughamMCPNoteAdded = Notification.Name("maugham.mcp.note.added")
    public static let maughamAddLoosePiece = Notification.Name("maugham.add.loose.piece")
    public static let maughamAddScreenplayPiece = Notification.Name("maugham.add.screenplay.piece")
    public static let maughamLinkProject = Notification.Name("maugham.link.project")
    public static let maughamPromotePiece = Notification.Name("maugham.promote.piece")
    /// Scope: .keyWindow — "Promote…" (⌘⇧↩) acting on the canvas's current
    /// selection. **Distinct from `maughamPromotePiece`**, which promotes a
    /// collection piece to its own project: two different verbs that happen to
    /// share a word.
    public static let maughamPromoteCanvasSelection =
        Notification.Name("maugham.promote.canvas")
    /// Posted by `add_canvas_scraps` once Claude's batch has reached whichever
    /// canvas is real. A data event, so it is scoped like `maughamMCPNoteAdded`:
    /// a window on another project must not announce cards it did not receive,
    /// and a closed window must not announce anything at all (the receive
    /// helper's liveness guard, ADR 0021).
    ///
    /// `userInfo[MaughamEvent.canvasScrapCountKey]` (Int) is how many cards
    /// arrived; `[MaughamEvent.canvasRegionIDKey]` (String) is the region they
    /// landed in, so a receiver can take the writer to them without re-reading
    /// the canvas. Scope: .project(id:).
    public static let maughamCanvasNodesAdded =
        Notification.Name("maugham.canvas.nodes.added")
    public static let maughamOpenRewind = Notification.Name("maugham.open.rewind")
    /// The one channel a `Document` has for saying something to the writer.
    ///
    /// `Document` is model code with no view of its own, and three things it
    /// does are only honest if the writer hears about them: a ⌘Z it declines
    /// because the document drifted (RULING-7 / M4-RW-026), an annotation-edit
    /// ⌘Z it declines for the same reason (RULING-22 / M5-AN-019), and the
    /// batch of notes the typing sweep archived while the writer was deleting
    /// paragraphs (RULING-32 / M5-AN-041). All three previously reached
    /// `documentLog` and nobody else. Rather than mint a name per occasion,
    /// the Document posts a finished sentence and the window renders it in the
    /// toast `RewindModifier` already owns.
    ///
    /// `userInfo[MaughamEvent.noticeMessageKey]` (String) is that sentence —
    /// written at the post site, because only the caller knows what happened.
    /// Post via `MaughamEvent.postNotice`, never by hand.
    ///
    /// Scope: .project(id:) — a data event, like `maughamMCPNoteAdded`. Windows
    /// on another project must not report a decline that was not theirs, and a
    /// closed window must report nothing at all (the receive helper's liveness
    /// guard, ADR 0021).
    public static let maughamDocumentNotice = Notification.Name("maugham.document.notice")
    /// Posted when ⌘S is pressed — triggers a checkpoint capture with an auto-label.
    public static let maughamSaveCheckpoint = Notification.Name("maugham.save.checkpoint")
    /// Posted when Shift-⌘S is pressed — triggers the checkpoint label prompt sheet.
    public static let maughamNamedCheckpoint = Notification.Name("maugham.named.checkpoint")
    /// Posted when `.maugham/checkpoints.jsonl` is added or changed.
    public static let maughamCheckpointAdded = Notification.Name("maughamCheckpointAdded")
    /// Posted when a document's SET-ASIDE (Plan B quarantine) records change
    /// behind another surface's back: `EditorHost`'s auto-return sweep runs on
    /// every normal document open and can return or supersede a record without
    /// anyone asking. `HistoryPane` shows those records and offers a Retry per
    /// pane load, so without this its standing notice went stale and its button
    /// re-attempted history that had already come back.
    ///
    /// No payload: which records are held is the receiving pane's own answer
    /// (it re-reads them for its `activeDocId`), not the sweep's.
    ///
    /// Scope: .project(id:) — a data event, like `maughamCheckpointAdded`. The
    /// sweep is scoped to a project's files, every window on that project shows
    /// the same records, and a closed window must reload nothing (the receive
    /// helper's liveness guard, ADR 0021).
    public static let maughamQuarantineRecordsChanged = Notification.Name(
        "maugham.quarantine.recordsChanged")
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
