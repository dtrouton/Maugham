import Foundation

/// **The files that hold `AnnotationsPane`'s code** (#116 F11): the root and
/// the children it builds and mounts.
///
/// A census that BANS or COUNTS a token over the pane reads all of them
/// (`surfaceSource()`), so a token that moves into a child is still seen. A
/// census about one declaration reads the file that declares it
/// (`source(of:)`). The list is checked, not trusted:
/// `AnnotationScopeTests.test_thePaneSurfaceListIsEveryFileThePaneIsSplitInto`
/// classifies every `Annotation*.swift` in `Maugham/Views/` as the pane's or
/// as `notThePane`.
enum AnnotationsPaneSource {

    /// Every name here is a file in `Maugham/Views/`.
    static let surfaceFiles: [String] = [
        "AnnotationsPane.swift",
        "AnnotationsPaneStatics.swift",
        "AnnotationsPaneVerbs.swift",
        "AnnotationsPaneDialogs.swift",
        "AnnotationsPaneStrips.swift",
        "AnnotationsPaneQueues.swift",
        "AnnotationListView.swift",
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
