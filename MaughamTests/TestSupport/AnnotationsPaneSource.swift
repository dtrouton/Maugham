import Foundation

/// **The files that hold To resolve's note surface** (#116 F11; re-pointed
/// from the deleted Annotations pane in shell plan 2 Task 7): the list, its
/// head, and the note verbs, dialogs and rows it mounts.
///
/// A census that BANS or COUNTS a token over the pane reads all of them
/// (`surfaceSource()`), so a token that moves into a child is still seen. A
/// census about one declaration reads the file that declares it
/// (`source(of:)`). The list is checked, not trusted:
/// `AnnotationScopeTests.test_thePaneSurfaceListIsEveryFileThePaneIsSplitInto`
/// classifies every `Annotation*.swift` in `Maugham/Views/` as the pane's or
/// as `notThePane`.
enum AnnotationsPaneSource {

    /// Every name here is a path under `Maugham/Views/`. The verbs, dialogs
    /// and row host moved to `Resolve/` (shell plan 2 Task 4) and are still
    /// the pane's until it is deleted.
    static let surfaceFiles: [String] = [
        "Resolve/ResolvePane.swift",
        "Resolve/ResolveListDecisions.swift",
        "Resolve/ResolveHead.swift",
        "Resolve/ResolveHeadStatics.swift",
        "Resolve/ResolveNoteVerbs.swift",
        "Resolve/ResolveNoteStatics.swift",
        "Resolve/ResolveDialogs.swift",
        "Resolve/AnnotationsBulkBar.swift",
        "Resolve/AnnotationRowWiring.swift",
        "Resolve/AnnotationRowHost.swift",
        "AnnotationRow.swift",
    ]

    /// The `Annotation*.swift` files in `Maugham/Views/` that are NOT the pane:
    /// pure helpers it calls, each with its own tests.
    static let notThePane: [String] = [
        "AnnotationAuthorPresentation.swift",
        "AnnotationBulkActions.swift",
        "AnnotationQueueOrder.swift",
    ]

    static var viewsDir: URL {
        SourceTree.repoRoot.appendingPathComponent("Maugham/Views", isDirectory: true)
    }

    /// One of the pane's files, by name.
    static func source(of file: String) throws -> String {
        try String(contentsOf: viewsDir.appendingPathComponent(file), encoding: .utf8)
    }

    /// The whole pane, every file joined.
    static func surfaceSource() throws -> String {
        try surfaceFiles.map(source(of:)).joined(separator: "\n")
    }
}
