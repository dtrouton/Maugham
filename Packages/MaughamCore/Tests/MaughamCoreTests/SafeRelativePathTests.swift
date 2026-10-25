import XCTest
@testable import MaughamCore

/// `SafeRelativePath` is the containment gate for sidecar-supplied relative
/// paths (trash `meta.json`, manifest research `path`, inbox
/// `sourceFilename`) — a hostile or corrupted sidecar value must not be able
/// to read or move files outside the project root (A5).
final class SafeRelativePathTests: XCTestCase {
    private func tempRoot() -> URL {
        let url = TestTemp.root
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

    // MARK: - isPlainFileName (report plan 6b Task 1)

    private static let badNames = [
        "", ".", "..", ".hidden", "a/b", "../x", "/abs", "a\\b", "a\0b", "a/../..",
    ]

    func test_isPlainFileName_acceptsOneOrdinaryName() {
        for good in ["map.png", "figure 1.csv", "a..b.csv", "x"] {
            XCTAssertTrue(SafeRelativePath.isPlainFileName(good), good)
        }
    }

    func test_isPlainFileName_refusesAnythingThatCouldLeaveItsFolder() {
        for bad in Self.badNames {
            XCTAssertFalse(SafeRelativePath.isPlainFileName(bad), bad.debugDescription)
        }
    }

    // MARK: - resolveFile(named:in:under:)

    func test_resolveFile_joinsOneNameUnderTheFolder() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try SafeRelativePath.resolveFile(named: "map.png", in: "figures", under: root)
        XCTAssertEqual(url, root.appendingPathComponent("figures/map.png"))
    }

    func test_resolveFile_worksForANestedFolderThatDoesNotExistYet() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try SafeRelativePath.resolveFile(
            named: "res-1.json", in: ".maugham/research-tables", under: root)
        XCTAssertEqual(url, root.appendingPathComponent(".maugham/research-tables/res-1.json"))
    }

    func test_resolveFile_refusesEveryBadName() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for bad in Self.badNames {
            XCTAssertThrowsError(
                try SafeRelativePath.resolveFile(named: bad, in: "figures", under: root),
                bad.debugDescription
            ) { error in
                guard case SafeRelativePath.PathError.notAPlainFileName = error else {
                    return XCTFail("expected .notAPlainFileName for \(bad.debugDescription), got \(error)")
                }
            }
        }
    }

    func test_resolveFile_refusesAFolderThatEscapesTheRoot() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in ["..", "../elsewhere", "/etc", "a/../..", "", "a\0b"] {
            XCTAssertThrowsError(
                try SafeRelativePath.resolveFile(named: "x.csv", in: folder, under: root),
                folder.debugDescription)
        }
    }

    /// A folder that is, on disk, a symlink pointing outside the root: the
    /// file would land outside, so it is refused even though the spelling
    /// is clean.
    func test_resolveFile_refusesASymlinkedFolderThatEscapesTheRoot() throws {
        let base = tempRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("project")
        let outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("figures"), withDestinationURL: outside)

        XCTAssertThrowsError(
            try SafeRelativePath.resolveFile(named: "map.png", in: "figures", under: root)
        ) { error in
            guard case SafeRelativePath.PathError.escapesRoot = error else {
                return XCTFail("expected .escapesRoot, got \(error)")
            }
        }
    }

    /// A symlink one level ABOVE a folder that does not exist yet:
    /// `figures` → outside, `figures/sub` absent. The file would still land
    /// outside, so it is refused.
    func test_resolveFile_refusesASymlinkAboveAFolderThatDoesNotExistYet() throws {
        let base = tempRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("project")
        let outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("figures"), withDestinationURL: outside)

        XCTAssertThrowsError(
            try SafeRelativePath.resolveFile(named: "map.png", in: "figures/sub", under: root)
        ) { error in
            guard case SafeRelativePath.PathError.escapesRoot = error else {
                return XCTFail("expected .escapesRoot, got \(error)")
            }
        }
    }

    /// A symlinked folder that stays inside the root is fine.
    func test_resolveFile_acceptsASymlinkedFolderInsideTheRoot() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("figures"), withDestinationURL: real)

        let url = try SafeRelativePath.resolveFile(named: "map.png", in: "figures", under: root)
        XCTAssertEqual(url, root.appendingPathComponent("figures/map.png"))
    }

    /// A symlinked ROOT (`/var` → `/private/var`) is not an escape.
    func test_resolveFile_underASymlinkedRoot_resolves() throws {
        let base = tempRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appendingPathComponent("real")
        try FileManager.default.createDirectory(
            at: real.appendingPathComponent("figures"), withIntermediateDirectories: true)
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let url = try SafeRelativePath.resolveFile(named: "map.png", in: "figures", under: link)
        XCTAssertEqual(url, link.appendingPathComponent("figures/map.png"))
    }

    // MARK: - resolveForChange checks the folder chain on disk (report plan 6b Task 2)

    private func linkedProject() throws -> (base: URL, root: URL, outside: URL) {
        let base = tempRoot()
        let root = base.appendingPathComponent("project")
        let outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("research"), withDestinationURL: outside)
        return (base, root, outside)
    }

    /// Reads stay lexical: a writer's own link to a folder elsewhere reads.
    func test_resolve_staysLexical_soALinkedFolderReads() throws {
        let (base, root, _) = try linkedProject()
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertEqual(try SafeRelativePath.resolve("research/note.md", under: root),
                       root.appendingPathComponent("research/note.md"))
    }

    /// A change through a folder linked out of the root is refused, whether
    /// the file under it exists or not.
    func test_resolveForChange_refusesAPathThroughAFolderLinkedOutside() throws {
        let (base, root, _) = try linkedProject()
        defer { try? FileManager.default.removeItem(at: base) }
        for relative in ["research/note.md", "research/new/deeper.md"] {
            XCTAssertThrowsError(try SafeRelativePath.resolveForChange(relative, under: root),
                                 relative) { error in
                guard case SafeRelativePath.PathError.escapesRoot = error else {
                    return XCTFail("expected .escapesRoot, got \(error)")
                }
            }
        }
    }

    /// The link entry itself is not followed: renaming or trashing it moves
    /// the link, so it is a change inside the root.
    func test_resolveForChange_acceptsTheLinkEntryItself() throws {
        let (base, root, _) = try linkedProject()
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertEqual(try SafeRelativePath.resolveForChange("research", under: root),
                       root.appendingPathComponent("research"))
    }

    /// A link that stays inside the root is not an escape, and the lexical
    /// rules still hold.
    func test_resolveForChange_acceptsALinkInsideTheRoot_andRefusesAClimb() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("research"), withDestinationURL: real)
        XCTAssertEqual(try SafeRelativePath.resolveForChange("research/note.md", under: root),
                       root.appendingPathComponent("research/note.md"))
        XCTAssertThrowsError(try SafeRelativePath.resolveForChange("../x.md", under: root))
    }

    // MARK: - requireDocId

    /// Every doc-id shape the apps mint passes: the legacy `d_` ids,
    /// `doc-`/`scene-` hashes, figure ids, statement ids, research ids and
    /// the synthetic project stream.
    func test_requireDocId_passesEveryMintedShape() throws {
        for id in ["d_01HZX3", "doc-3f2a9c1e00aa11bb", "scene-0123abcd", "fig-1a2b3c4d",
                   "stmt-9f8e7d6c", "res-12345678", "prop-abcdef01", "__project__"] {
            XCTAssertEqual(try SafeRelativePath.requireDocId(id), id)
        }
    }

    func test_requireDocId_refusesAnIdThatCouldLeaveItsFolder() {
        for bad in Self.badNames + ["a.b", "doc-1.macA"] {
            XCTAssertThrowsError(try SafeRelativePath.requireDocId(bad), bad.debugDescription) { error in
                guard case SafeRelativePath.PathError.notADocId = error else {
                    return XCTFail("expected .notADocId for \(bad.debugDescription), got \(error)")
                }
            }
        }
    }

    // MARK: - A doc id becoming a file name

    func test_opLogFileURL_refusesADocIdThatClimbs() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try OpLogFiles.opLogFileURL(
            forDocId: "../x", deviceSlug: .unsafeForTesting("macA-1234"), in: root))
        XCTAssertThrowsError(try OpLogStore.opLogFileURL(
            forDocId: "../x", deviceSlug: .unsafeForTesting("macA-1234"), in: root))
    }

    func test_segmentFileURL_refusesADocIdThatClimbs() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try OpLogFiles.segmentFileURL(
            forDocId: "../x", deviceSlug: .unsafeForTesting("macA-1234"), index: 1, in: root))
    }

    func test_quarantineRecord_refusesADocIdThatClimbs_andWritesNothing() throws {
        let base = tempRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertThrowsError(try IntegrityQuarantine.record(
            skipped: [.init(byteOffset: 0, raw: "torn")],
            forDocId: "../../../../escaped", in: root, stamp: "20261025-000000"))
        let written = FileManager.default.enumerator(atPath: base.path)?
            .compactMap { $0 as? String }
            .filter { $0.contains("escaped") } ?? []
        XCTAssertEqual(written, [], "nothing is written for a refused doc id")
    }
}
