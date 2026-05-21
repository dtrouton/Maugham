import Foundation

extension Notification.Name {
    public static let maughamNewProject = Notification.Name("maugham.newProject")
    public static let maughamOpenProject = Notification.Name("maugham.openProject")
    public static let maughamToggleNoChrome = Notification.Name("maugham.toggleNoChrome")
    public static let maughamToggleFullScreen = Notification.Name("maugham.toggleFullScreen")
    public static let maughamDummySave = Notification.Name("maugham.dummySave")
    public static let maughamShowProjectSettings = Notification.Name("maugham.showProjectSettings")
    public static let maughamShowClaudeDesktopHelp = Notification.Name("maugham.showClaudeDesktopHelp")
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
    /// Posted when the AnnotationsPane wants the editor to scroll to/select a paragraph.
    /// userInfo["paragraph_id"] contains the paragraph id string.
    public static let maughamNavigateToParagraph = Notification.Name(
        "maughamNavigateToParagraph")
}
