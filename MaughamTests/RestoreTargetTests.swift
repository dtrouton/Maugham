import XCTest
@testable import Maugham

/// "Restore a Copy…" must never delete what the writer named in the save
/// panel (issue #56 finding): only an empty placeholder the panel left is
/// cleared; anything with content refuses and survives.
final class RestoreTargetTests: XCTestCase {
    private let fm = FileManager.default

    func test_aNameThatIsFreeIsLeftFree() throws {
        let target = TestTemp.root.appendingPathComponent("Novel (restored)")
        XCTAssertNoThrow(try RestoreTarget.clearPlaceholder(at: target))
        XCTAssertFalse(fm.fileExists(atPath: target.path))
    }

    func test_anEmptyPlaceholderFolderIsCleared() throws {
        let target = TestTemp.root.appendingPathComponent("Novel (restored)")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try RestoreTarget.clearPlaceholder(at: target)
        XCTAssertFalse(fm.fileExists(atPath: target.path))
    }

    func test_aFolderHoldingOnlyFinderMetadataIsCleared() throws {
        let target = TestTemp.root.appendingPathComponent("Novel (restored)")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try Data([0, 0, 0, 1]).write(to: target.appendingPathComponent(".DS_Store"))
        try RestoreTarget.clearPlaceholder(at: target)
        XCTAssertFalse(fm.fileExists(atPath: target.path))
    }

    func test_anEmptyFileIsTheWritersAndIsRefused() throws {
        let target = TestTemp.root.appendingPathComponent("Novel (restored)")
        XCTAssertTrue(fm.createFile(atPath: target.path, contents: Data()))
        XCTAssertThrowsError(try RestoreTarget.clearPlaceholder(at: target))
        XCTAssertTrue(fm.fileExists(atPath: target.path))
    }

    func test_aFolderWithContentIsRefusedAndSurvives() throws {
        let project = TestTemp.root.appendingPathComponent("Novel")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        let chapter = project.appendingPathComponent("Chapter 1.md")
        try Data("It was a dark night.".utf8).write(to: chapter)

        XCTAssertThrowsError(try RestoreTarget.clearPlaceholder(at: project)) { error in
            XCTAssertEqual(error.localizedDescription,
                           "Something named “Novel” is already there, so nothing was restored. Choose a new name — a restore never replaces anything.")
        }
        XCTAssertEqual(try String(contentsOf: chapter, encoding: .utf8), "It was a dark night.")
    }

    func test_aFileWithContentIsRefusedAndSurvives() throws {
        let target = TestTemp.root.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: target)
        XCTAssertThrowsError(try RestoreTarget.clearPlaceholder(at: target))
        XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8))
    }

    // MARK: - #92.3: a folder is chosen and Maugham names the copy

    func test_theCopyIsNamedRestoredThenNumberedNeverATakenName() {
        XCTAssertEqual(RestoreCopyName.name(for: "Novel") { _ in false }, "Novel (restored)")
        let taken: Set<String> = ["Novel (restored)", "Novel (restored 2)"]
        XCTAssertEqual(RestoreCopyName.name(for: "Novel") { taken.contains($0) }, "Novel (restored 3)")
        let gap: Set<String> = ["Novel (restored)", "Novel (restored 3)"]
        XCTAssertEqual(RestoreCopyName.name(for: "Novel") { gap.contains($0) }, "Novel (restored 2)")
    }

    func test_aTitleCannotNameAPath() {
        XCTAssertEqual(RestoreCopyName.name(for: "A/B: C") { _ in false }, "A-B- C (restored)")
    }

    func test_theNameIsFreeInARealFolder() throws {
        let folder = TestTemp.root.appendingPathComponent("into-\(UUID().uuidString)")
        try fm.createDirectory(at: folder.appendingPathComponent("Novel (restored)"), withIntermediateDirectories: true)
        let name = RestoreCopyName.name(for: "Novel") {
            self.fm.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
        XCTAssertEqual(name, "Novel (restored 2)")
    }

    func test_thePanelChoosesAFolderAndNothingElse() {
        let c = RestoreFolderPanel.configuration
        XCTAssertFalse(c.canChooseFiles)
        XCTAssertTrue(c.canChooseDirectories)
        XCTAssertFalse(c.allowsMultipleSelection)
        XCTAssertEqual(c.prompt, "Restore Here")
    }
}
