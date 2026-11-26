import XCTest
@testable import Maugham

/// **Who may read the faces** (shell closing A4; ADR 0040).
///
/// `WindowSubject.faces` is what the RIGHT COLUMN is about; `open` is what the
/// centre shows and the writer types in. After a Brief link or ⌘⌥K the two
/// differ, and three times a piece of editor chrome or an editor act read the
/// faces when it meant the open piece: the status line (p3 Task 8), Rewind
/// (p3 C1), and then ⌘S/⇧⌘S/⌘⌥C, the line above the prose and ⌘/ (the
/// milestone review's I1/I2/M1). A warning in prose did not stop the third
/// (`feedback_census_over_warning`), so the readers are a counted list.
///
/// A READ is a `.faces` that is not an assignment (`next.faces = …` is a
/// route setting the faces, and every route is free to). Comments are not
/// code. `WindowSubject.swift` is the type itself (its codec and `didSet`).
///
/// Every reader, classified — each is about the right column, the binder's
/// drawing of the faces, or a route deciding where the faces go next:
/// - `ClickRule.swift` × 1 — the click rule's own switch over where the faces
///   are (a route).
/// - `BinderTreeSections.swift` × 1 — the rows drawn outlined: the faces, when
///   the tree draws them unselected.
/// - `CentreColumn.swift` × 4 — the centre's navigate binding (a route); the
///   Book's preview scrolling to the faces' piece (the Book is what is open);
///   the two Status boards' keep-your-place fallback (the board is open, the
///   faces are the row it returns to).
/// - `CompilerRunModifier.swift` × 1 — ⌘R's FALLBACK when no piece is open
///   (the Canvas, an edition, the Inbox in the centre); the open piece wins.
/// - `ManuscriptNavigation.swift` × 1 — a right-column pane's paragraph jump
///   that names no document is about the faces' document.
/// - `ProjectWindow.swift` × 5 — ⌘⌥A/⌘⌥D/⌘⌥T's To resolve scope (right
///   column), the faces' setter guard and binding (routes), restore's
///   validation of both parts, the column's `ResolveScope`.
/// - `EditionWiring.swift` × 3 — ⌘⌥K's edition row and the removal landing
///   (routes over both parts).
/// - `ReadingLanguage.swift` × 1 — a piece is read in a language only while
///   it is both open and faced.
/// - `ResolvePane.swift` × 2 — To resolve's scope and a filed line's target.
/// - `RightColumn.swift` × 1 — the Brief scope.
/// - `RightColumnContent.swift` × 4 — which face the column shows, and the
///   strip-click that brings the faces back to the open piece.
/// - `RightColumnControl.swift` × 2 — the column's scope and its Brief.
/// - `SubjectValidationModifier.swift` × 1 — validation of every part.
///
/// **The faces behind a helper** are counted the same way, in
/// `facesHelperReaders`: `WindowSubject.lastClicked` (the faces unless a
/// pulled-up tree row was clicked after them; it lives in the excluded type
/// file) and `RightColumnContent.facesPiece` (the faces' piece, else the
/// open one). Their callers today:
/// - `ClickRule.swift` × 1 — a click on the row already last clicked (route).
/// - `BinderTreeSections.swift` × 2 — Paste's target row; the rows a key acts on.
/// - `CentreColumn.swift` × 1 — the canvas lights the region of the row last
///   clicked.
/// - `RightColumnContent.swift` × 1 — the pulled-up History's piece.
/// - `ProjectWindow.swift` × 1 — ⌘⌥E's fold piece (`foldPiece`).
///
/// **What neither list sees**: a line is counted, not each read on it; files
/// are keyed by basename; and a read through any OTHER helper (a new one, or
/// `ResolveScope.shown(faces:)`'s callers, which pass the faces explicitly and
/// are counted at the call) — name a new helper here when one is written.
///
/// A NEW reader is either right-column work (name it here, with its reason)
/// or editor work reading the wrong part (read `subject.open` —
/// `WindowSubject.openPiece(in:)` / `openDocId` — instead).
final class FacesReaderCensusTests: XCTestCase {

    static let facesReaders: [String: Int] = [
        "ClickRule.swift": 1,
        "BinderTreeSections.swift": 1,
        "CentreColumn.swift": 4,
        "CompilerRunModifier.swift": 1,
        "ManuscriptNavigation.swift": 1,
        "ProjectWindow.swift": 5,
        "EditionWiring.swift": 3,
        "ReadingLanguage.swift": 1,
        "ResolvePane.swift": 2,
        "RightColumn.swift": 1,
        "RightColumnContent.swift": 4,
        "RightColumnControl.swift": 2,
        "SubjectValidationModifier.swift": 1,
    ]

    static let facesHelperReaders: [String: Int] = [
        "ClickRule.swift": 1,
        "BinderTreeSections.swift": 2,
        "CentreColumn.swift": 1,
        "RightColumnContent.swift": 1,
        "ProjectWindow.swift": 1,
    ]

    /// The type's own file: its stored property, codec and `didSet`.
    static let theTypeItself: Set<String> = ["WindowSubject.swift"]

    private static let read = try! NSRegularExpression(pattern: #"\.faces\b(?!\s*=[^=])"#)
    /// A call of a helper that returns the faces; a declaration is not one.
    private static let helperRead = try! NSRegularExpression(
        pattern: #"(?<!func )\b(?:lastClicked\b|facesPiece\()"#)

    static func facesHelperReads(under root: URL) throws -> [String: Int] {
        try reads(under: root, matching: helperRead, marker: ["lastClicked", "facesPiece"])
    }

    static func facesReads(under root: URL) throws -> [String: Int] {
        try reads(under: root, matching: read, marker: [".faces"])
    }

    /// Lines matching `regex` per file under `root`, comments excluded.
    private static func reads(under root: URL, matching regex: NSRegularExpression,
                              marker: [String]) throws -> [String: Int] {
        var found: [String: Int] = [:]
        guard let walker = SourceTreeCache.enumerator(at: root) else { return found }
        for case let url as URL in walker where url.pathExtension == "swift" {
            let name = url.lastPathComponent
            if theTypeItself.contains(name) { continue }
            let text = try SourceTreeCache.text(url)
            guard marker.contains(where: text.contains) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let code = String(line)
                if code.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                let range = NSRange(code.startIndex..., in: code)
                if regex.firstMatch(in: code, range: range) != nil { found[name, default: 0] += 1 }
            }
        }
        return found
    }

    private var sourceDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Maugham", isDirectory: true)
    }

    func test_theFacesAreReadOnlyByTheirNamedConsumers() throws {
        let found = try Self.facesReads(under: sourceDir)
        XCTAssertEqual(found, Self.facesReaders,
            "The readers of `WindowSubject.faces` moved. The faces are the RIGHT "
            + "COLUMN's subject; anything about the text being typed (a checkpoint, "
            + "the line above the prose, ⌘⌥C, ⌘/, ⌘R) reads `subject.open`. A new "
            + "right-column reader: name it in `facesReaders` with its reason in "
            + "the same commit. Found: \(found.sorted(by: { $0.key < $1.key }))")
    }

    func test_theFacesBehindAHelperAreReadOnlyByTheirNamedCallers() throws {
        let found = try Self.facesHelperReads(under: sourceDir)
        XCTAssertEqual(found, Self.facesHelperReaders,
            "The callers of `lastClicked` / `facesPiece` moved. Each returns the "
            + "faces (or the faces first): a centre or editor reader through one is "
            + "the open/faces defect again. Name a right-column, binder or route "
            + "caller in `facesHelperReaders` with its reason. Found: "
            + "\(found.sorted(by: { $0.key < $1.key }))")
    }

    func test_theHelperCensusFindsACallAndNotTheDeclaration() throws {
        let dir = TestTemp.root.appendingPathComponent("faces-helper-census-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
            enum Planted {
                static func facesPiece(_ s: WindowSubject) -> String? { nil }
                // subject.lastClicked in a comment
                func centre() -> BinderSubject { subject.lastClicked }
                func piece() -> String? { Planted.facesPiece(subject) }
            }
            """.write(to: dir.appendingPathComponent("Planted.swift"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try Self.facesHelperReads(under: dir), ["Planted.swift": 2])
    }

    /// **The planted offender and the control**: the third defect's shape — a
    /// window property keying the editor's document on the faces — is found;
    /// a route writing the faces, a comment naming them and a `facesFor…`
    /// helper are not.
    func test_theCensusFindsAPlantedEditorReaderAndNotARouteOrAComment() throws {
        let dir = TestTemp.root.appendingPathComponent("faces-census-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
            extension ProjectWindow {
                // The checkpoint used to read subject.faces.itemID here.
                private var activeItemID: String? { subject.faces.itemID }
                func land() { next.faces = .project; let b = facesForABrief(.project) }
                func same() -> Bool { subject.faces == subject.open }
            }
            """.write(to: dir.appendingPathComponent("ProjectWindow+Planted.swift"),
                      atomically: true, encoding: .utf8)
        XCTAssertEqual(try Self.facesReads(under: dir), ["ProjectWindow+Planted.swift": 2],
                       "the property and the comparison are reads; the write, the helper and the comment are not")
    }
}
