import XCTest
@testable import Maugham

/// Report foundations plan 2, Task 3: a figure's image path, written relative
/// to its piece's own file, resolves only to a regular file of an allowed
/// format inside a research folder of the REAL project — the project's
/// `research/`, or a Collection piece's own `pieces/<x>/research/`. Anything
/// absolute, schemed, escaping, or outside research is refused before the disk
/// is touched; a symlink out of research is refused after resolving it.
final class FigureImageResolverTests: XCTestCase {

    private var project: URL!
    private let png: Set<String> = ["png", "jpg", "jpeg", "pdf"]

    override func setUpWithError() throws {
        project = TestTemp.root.appendingPathComponent("FigureImage-\(UUID().uuidString)")
        for dir in ["research", "manuscript", "pieces/01-a/research", "pieces/02-b/research", "elsewhere"] {
            try FileManager.default.createDirectory(
                at: project.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        for file in ["research/x.png", "research/notes.txt", "research/x.bmp",
                     "pieces/01-a/research/a.png", "pieces/02-b/research/b.png",
                     "elsewhere/secret.png", "manuscript/inline.png"] {
            try Data([0x89]).write(to: project.appendingPathComponent(file))
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: project)
    }

    private func resolve(_ path: String, from piece: String) -> FigureImageResolver.Outcome {
        FigureImageResolver.resolve(path, piecePath: piece, projectURL: project, allowed: png)
    }

    private func expectFile(_ outcome: FigureImageResolver.Outcome, _ relative: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        let expected = project.appendingPathComponent(relative).resolvingSymlinksInPath()
        XCTAssertEqual(outcome, .file(expected), file: file, line: line)
    }

    private func expectUnreadable(_ outcome: FigureImageResolver.Outcome,
                                  file: StaticString = #filePath, line: UInt = #line) {
        guard case .unreadable(let reason) = outcome else {
            return XCTFail("expected .unreadable, got \(outcome)", file: file, line: line)
        }
        XCTAssertFalse(reason.isEmpty, file: file, line: line)
    }

    // MARK: - relative to the piece

    func test_aNovelChapter_reachesTheProjectsResearchThroughDotDot() {
        expectFile(resolve("../research/x.png", from: "manuscript/ch1.md"), "research/x.png")
    }

    func test_aRootLevelStory_cannotUseDotDot_itEscapesTheProject() {
        XCTAssertEqual(resolve("../research/x.png", from: "story.md"), .notLocal)
        expectFile(resolve("research/x.png", from: "story.md"), "research/x.png")
    }

    func test_dotSegmentsInsideResearchAreStandardised() {
        expectFile(resolve("./research/./sub/../x.png", from: "story.md"), "research/x.png")
    }

    // MARK: - Collections

    func test_aCollectionPiece_reachesItsOwnResearchFolder() {
        expectFile(resolve("research/a.png", from: "pieces/01-a/a.md"), "pieces/01-a/research/a.png")
        expectFile(resolve("../../research/x.png", from: "pieces/01-a/a.md"), "research/x.png")
    }

    func test_aCollectionPiece_isRefusedAnotherPiecesResearchFolder() {
        XCTAssertEqual(resolve("../02-b/research/b.png", from: "pieces/01-a/a.md"), .notLocal)
    }

    // MARK: - refused before the disk

    func test_absolutePathsSchemesAndEscapesAreNotLocal() {
        for path in ["/Users/x.png", "~/x.png", "http://example.com/x.png",
                     "https://example.com/x.png", "file:///etc/x.png", "data:image/png;base64,AA",
                     "../../etc/x.png", "../../../etc/x.png", "", "research"] {
            XCTAssertEqual(resolve(path, from: "manuscript/ch1.md"), .notLocal, path)
        }
    }

    func test_aFileInsideTheProjectButOutsideResearch_isNotLocal() {
        XCTAssertEqual(resolve("inline.png", from: "manuscript/ch1.md"), .notLocal)
        XCTAssertEqual(resolve("../elsewhere/secret.png", from: "manuscript/ch1.md"), .notLocal)
        XCTAssertEqual(resolve("research/x.png", from: "manuscript/ch1.md"), .notLocal,
                       "manuscript/research is not a research folder")
    }

    /// A path whose lexical walk escapes and comes back in is still refused:
    /// the project's own folder name must not be a way back in.
    func test_anEscapeThatComesBackIn_isNotLocal() {
        let name = project.lastPathComponent
        XCTAssertEqual(resolve("../../\(name)/research/x.png", from: "manuscript/ch1.md"), .notLocal)
    }

    // MARK: - after the disk

    func test_aSymlinkOutOfResearch_isRefused() throws {
        let outside = TestTemp.root.appendingPathComponent("FigureImageOutside-\(UUID().uuidString).png")
        try Data([0x89]).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: project.appendingPathComponent("research/link.png"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(
            at: project.appendingPathComponent("research/dirlink"),
            withDestinationURL: project.appendingPathComponent("elsewhere"))

        XCTAssertEqual(resolve("../research/link.png", from: "manuscript/ch1.md"), .notLocal)
        XCTAssertEqual(resolve("../research/dirlink/secret.png", from: "manuscript/ch1.md"), .notLocal)
    }

    func test_aSymlinkThatStaysInsideResearch_resolvesToItsTarget() throws {
        try FileManager.default.createSymbolicLink(
            at: project.appendingPathComponent("research/alias.png"),
            withDestinationURL: project.appendingPathComponent("research/x.png"))
        expectFile(resolve("../research/alias.png", from: "manuscript/ch1.md"), "research/x.png")
    }

    func test_aMissingFile_isUnreadable() {
        expectUnreadable(resolve("../research/absent.png", from: "manuscript/ch1.md"))
    }

    /// The project spelled through `/private` (as `TestTemp` / `$TMPDIR` can
    /// be): `resolvingSymlinksInPath` maps existing folders to `/var/…` but
    /// leaves a missing file's `/private` spelling alone, so a missing file
    /// must be caught before the containment check, not misreported as
    /// outside research.
    func test_aMissingFile_underAPrivatePrefixedProjectURL_isUnreadableNotNotLocal() {
        let path = project.standardizedFileURL.path
        let privateSpelling = path.hasPrefix("/private/") ? path : "/private" + path
        let privateProject = URL(fileURLWithPath: privateSpelling)
        XCTAssertTrue(FileManager.default.fileExists(atPath: privateProject.appendingPathComponent("research").path),
                      "premise: the /private spelling names the same project")
        expectUnreadable(FigureImageResolver.resolve(
            "../research/absent.png", piecePath: "manuscript/ch1.md",
            projectURL: privateProject, allowed: png))
        XCTAssertEqual(
            FigureImageResolver.resolve("../research/x.png", piecePath: "manuscript/ch1.md",
                                        projectURL: privateProject, allowed: png),
            .file(privateProject.appendingPathComponent("research/x.png").resolvingSymlinksInPath()))
    }

    /// A sibling whose name merely starts with `research` is not research.
    func test_aResearchOldFolder_isNotLocal() throws {
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("research-old"), withIntermediateDirectories: true)
        try Data([0x89]).write(to: project.appendingPathComponent("research-old/x.png"))
        XCTAssertEqual(resolve("../research-old/x.png", from: "manuscript/ch1.md"), .notLocal)
    }

    func test_aDirectory_isUnreadable() throws {
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("research/folder.png"), withIntermediateDirectories: true)
        expectUnreadable(resolve("../research/folder.png", from: "manuscript/ch1.md"))
    }

    func test_aDisallowedExtension_isUnreadable() {
        expectUnreadable(resolve("../research/x.bmp", from: "manuscript/ch1.md"))
        expectUnreadable(resolve("../research/notes.txt", from: "manuscript/ch1.md"))
        // Each target names its own formats (R-P2-7): GIF is EPUB's, not PDF's.
        XCTAssertEqual(
            FigureImageResolver.resolve("../research/x.bmp", piecePath: "manuscript/ch1.md",
                                        projectURL: project, allowed: ["bmp"]),
            .file(project.appendingPathComponent("research/x.bmp").resolvingSymlinksInPath()))
    }

    func test_theExtensionIsMatchedCaseInsensitively() throws {
        try Data([0x89]).write(to: project.appendingPathComponent("research/Photo.PNG"))
        expectFile(resolve("../research/Photo.PNG", from: "manuscript/ch1.md"), "research/Photo.PNG")
    }
}
