import Foundation

extension Notification.Name {
    public static let maughamNewProject = Notification.Name("maugham.newProject")
    public static let maughamOpenProject = Notification.Name("maugham.openProject")
    public static let maughamToggleNoChrome = Notification.Name("maugham.toggleNoChrome")
    public static let maughamToggleReviewMode = Notification.Name("maugham.toggleReviewMode")
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
    public static let maughamAppWillTerminate = Notification.Name("maugham.appWillTerminate")
    public static let maughamAddResearchFile = Notification.Name("maugham.addResearchFile")
    public static let maughamNavigateToDocument = Notification.Name("maugham.navigateToDocument")
    public static let maughamSessionLogChanged = Notification.Name("maugham.sessionLogChanged")
    public static let maughamShowProjectStatistics = Notification.Name("maugham.showProjectStatistics")
    public static let maughamScriptDidUpdate = Notification.Name("maugham.script.did.update")
    public static let maughamNavigateToScene = Notification.Name("maugham.navigate.to.scene")
    public static let maughamShowSyntaxHelp = Notification.Name("maugham.show.syntax.help")
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
    public static let maughamEffectiveAppearanceChanged = Notification.Name("maugham.effective.appearance.changed")
    public static let maughamOpenRewind = Notification.Name("maugham.open.rewind")
    /// Posted when ⌘S is pressed — triggers a checkpoint capture with an auto-label.
    public static let maughamSaveCheckpoint = Notification.Name("maugham.save.checkpoint")
    /// Posted when Shift-⌘S is pressed — triggers the checkpoint label prompt sheet.
    public static let maughamNamedCheckpoint = Notification.Name("maugham.named.checkpoint")
    /// Posted when a `.maugham/ops/<docId>.jsonl` file is added or changed.
    /// userInfo["path"] contains the relative path string.
    public static let maughamOpLogChanged = Notification.Name("maughamOpLogChanged")
    /// Posted when `.maugham/checkpoints.jsonl` is added or changed.
    public static let maughamCheckpointAdded = Notification.Name("maughamCheckpointAdded")
    /// Posted when any file under `.maugham/inbox/` is added or changed (a phone
    /// capture or a Mac-side status transition). `object` is the owning
    /// DocumentStore (window-scoped); userInfo["kind"] is the InboxFileKind raw
    /// value. InboxStore refreshes on any kind; the transcription worker filters
    /// to "audio".
    public static let maughamInboxChanged = Notification.Name("maughamInboxChanged")
    /// Posted when the AnnotationsPane wants the editor to scroll to/select a paragraph.
    /// userInfo["paragraph_id"] contains the paragraph id string.
    public static let maughamNavigateToParagraph = Notification.Name(
        "maughamNavigateToParagraph")
    /// Posted when the review annotation set is mutated from the AnnotationsPane
    /// (an author edits or withdraws their own annotation). The key-window
    /// EditorCoordinator observes this to re-pull + recompute its crafted review
    /// marks so an edited/withdrawn annotation's inline mark + rail card update
    /// immediately, without toggling review off/on. Same class of fix as the
    /// create-case provider re-pull. `object` is nil (broadcast); the observer
    /// guards on `textView?.window?.isKeyWindow`.
    public static let maughamReviewAnnotationsChanged = Notification.Name(
        "maughamReviewAnnotationsChanged")
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
