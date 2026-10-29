import Foundation

/// **The files that hold `HistoryPane`'s code** (#116 F11): the root and the
/// children Task 4's split gave it — `AnnotationsPaneSource`'s twin.
///
/// A census that BANS or COUNTS a token over the pane reads all of them
/// (`surfaceSource()`, or `surfaceCode()` with comments stripped); a census
/// about one declaration reads the file that declares it (`source(of:)`). The
/// list is checked, not trusted:
/// `HistoryPaneQuarantineNoticeTests.test_thePaneSurfaceListIsEveryFileThePaneIsSplitInto`
/// classifies every `History*.swift` in `Maugham/Views/` as the pane's or as
/// `notThePane`.
enum HistoryPaneSource {

    /// Every name here is a file in `Maugham/Views/`.
    static let surfaceFiles: [String] = [
        "HistoryPane.swift",
        "HistoryPaneStatics.swift",
        "HistoryPaneVerbs.swift",
        "HistoryPaneNotices.swift",
        "HistoryPaneTimeline.swift",
        "HistoryRow.swift",
    ]

    /// The `History*.swift` files in `Maugham/Views/` that are NOT the pane.
    /// None today; a new one must be named here or in `surfaceFiles`.
    static let notThePane: [String] = []

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

    /// The whole pane's CODE, comments stripped — a doc comment naming a
    /// symbol is documentation, not a reader of it.
    static func surfaceCode() throws -> String {
        try surfaceFiles.map {
            SourceScan.codeLines(of: try source(of: $0)).joined(separator: "\n")
        }.joined(separator: "\n")
    }
}
