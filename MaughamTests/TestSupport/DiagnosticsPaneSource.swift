import Foundation

/// **The files that hold `DiagnosticsPane`'s code** (#116 F11): the root and
/// the children Task 2's split gave it — `AnnotationsPaneSource`'s twin.
///
/// A census that BANS or COUNTS a token over the pane reads all of them
/// (`surfaceSource()`); a census about one declaration reads the file that
/// declares it (`source(of:)`). The list is checked, not trusted:
/// `DiagnosticsPaneTests.test_thePaneSurfaceListIsEveryFileThePaneIsSplitInto`
/// classifies every `Diagnostic*.swift` in `Maugham/Views/` as the pane's or
/// as `notThePane`.
enum DiagnosticsPaneSource {

    /// Every name here is a file in `Maugham/Views/`.
    static let surfaceFiles: [String] = [
        "DiagnosticsPane.swift",
        "DiagnosticsPaneHeader.swift",
        "DiagnosticsPaneSections.swift",
        "DiagnosticsPaneCopy.swift",
        "DiagnosticsPaneVerbs.swift",
    ]

    /// The `Diagnostic*.swift` files in `Maugham/Views/` that are NOT the pane.
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
}
