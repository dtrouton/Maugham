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
}
