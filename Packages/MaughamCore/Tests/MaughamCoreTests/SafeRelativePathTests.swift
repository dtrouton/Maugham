import XCTest
@testable import MaughamCore

/// `SafeRelativePath` is the containment gate for sidecar-supplied relative
/// paths (trash `meta.json`, manifest research `path`, inbox
/// `sourceFilename`) — a hostile or corrupted sidecar value must not be able
/// to read or move files outside the project root (A5).
final class SafeRelativePathTests: XCTestCase {
    private func tempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("srp-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Escapes rejected

    func test_dotDotEscape_throws() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try SafeRelativePath.resolve("../../../etc/passwd", under: root))
    }

    func test_absolutePath_throws() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try SafeRelativePath.resolve("/etc/passwd", under: root)) { error in
            guard case SafeRelativePath.PathError.absolutePath = error else {
                return XCTFail("expected .absolutePath, got \(error)")
            }
        }
    }

    func test_emptyPath_throws() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try SafeRelativePath.resolve("", under: root)) { error in
            guard case SafeRelativePath.PathError.emptyPath = error else {
                return XCTFail("expected .emptyPath, got \(error)")
            }
        }
    }

    func test_emptyComponent_throws() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try SafeRelativePath.resolve("a//b.md", under: root)) { error in
            guard case SafeRelativePath.PathError.emptyComponent = error else {
                return XCTFail("expected .emptyComponent, got \(error)")
            }
        }
    }

    /// A sibling directory that merely shares a string prefix with the root
    /// must not pass containment — this is the bug a missing trailing-slash
    /// guard on the prefix comparison would produce.
    func test_prefixSiblingAttack_throws() {
        let root = tempRoot().appendingPathComponent("project")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        XCTAssertThrowsError(
            try SafeRelativePath.resolve("../project-evil/secret.md", under: root))
    }

    // MARK: - Legitimate paths resolve

    func test_netInsidePath_withDotDotSegment_resolves() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolved = try SafeRelativePath.resolve("a/../b.md", under: root)
        XCTAssertEqual(
            resolved.standardizedFileURL.path,
            root.appendingPathComponent("b.md").standardizedFileURL.path)
    }

    func test_plainNestedPath_resolves() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolved = try SafeRelativePath.resolve("manuscript/chapter1.md", under: root)
        XCTAssertEqual(resolved, root.appendingPathComponent("manuscript/chapter1.md"))
    }

    func test_dotSlashPrefixedPath_resolves() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolved = try SafeRelativePath.resolve("./notes.md", under: root)
        XCTAssertEqual(
            resolved.standardizedFileURL.path,
            root.appendingPathComponent("notes.md").standardizedFileURL.path)
    }

    // MARK: - Symlinked root

    /// macOS temp directories (what every test in this suite uses) are
    /// themselves reached through a symlink (`/var` → `/private/var`). A
    /// legitimate nested path under a symlinked root must still resolve —
    /// this is the scenario `resolvingSymlinksInPath()` on `root` exists for.
    func test_symlinkedRoot_legitimatePath_stillResolves() throws {
        let base = tempRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let resolved = try SafeRelativePath.resolve("sub/note.md", under: link)
        XCTAssertEqual(resolved, link.appendingPathComponent("sub/note.md"),
            "resolve should return the original (unresolved) root's shape")
    }

    /// The escape check itself must hold under a symlinked root too — an
    /// attacker can't use the symlink hop to dodge containment.
    func test_symlinkedRoot_escape_stillThrows() throws {
        let base = tempRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertThrowsError(
            try SafeRelativePath.resolve("../../../etc/passwd", under: link))
    }
}
