import Foundation

/// **The files that hold the check's surface** (#116 F11; re-pointed from the
/// deleted Diagnostics pane in shell plan 2 Task 7): `CheckNarrative`, the
/// header and sections To resolve mounts, and the head that draws them.
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
        "Resolve/CheckNarrative.swift",
        "Resolve/CheckNarrativeCopy.swift",
        "Resolve/CheckNarrativeVerbs.swift",
        "Resolve/ResolveHead.swift",
        "DiagnosticsPaneHeader.swift",
        "DiagnosticsPaneSections.swift",
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
