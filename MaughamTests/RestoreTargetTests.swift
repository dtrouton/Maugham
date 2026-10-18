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

    func test_anEmptyPlaceholderFileIsCleared() throws {
        let target = TestTemp.root.appendingPathComponent("Novel (restored)")
        XCTAssertTrue(fm.createFile(atPath: target.path, contents: Data()))
        try RestoreTarget.clearPlaceholder(at: target)
        XCTAssertFalse(fm.fileExists(atPath: target.path))
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
}
