import XCTest
@testable import Maugham

final class FileNamingTests: XCTestCase {

    func test_documentInEmptyFolder_getsNN01() {
        let name = FileNaming.nextDocumentFilename(
            title: "Chapter 1", extension: "md", siblingFilenames: [])
        XCTAssertEqual(name, "01-chapter-1.md")
    }

    func test_documentAfterTwoSiblings_getsNN03() {
        let name = FileNaming.nextDocumentFilename(
            title: "Chapter 3", extension: "md",
            siblingFilenames: ["01-chapter-1.md", "02-chapter-2.md"])
        XCTAssertEqual(name, "03-chapter-3.md")
    }

    func test_documentWithGapInNN_skipsToMaxPlusOne() {
        // After deletes, NN sequence may have gaps. Always use max+1.
        let name = FileNaming.nextDocumentFilename(
            title: "Chapter 4", extension: "md",
            siblingFilenames: ["01-chapter-1.md", "04-chapter-4.md"])
        XCTAssertEqual(name, "05-chapter-4.md")
    }

    func test_documentWithSlugCollision_getsSuffix() {
        // Same title twice: second gets "-2" before extension
        let name = FileNaming.nextDocumentFilename(
            title: "Chapter 1", extension: "md",
            siblingFilenames: ["01-chapter-1.md"])
        XCTAssertEqual(name, "02-chapter-1-2.md")
    }

    func test_documentWithMultipleSlugCollisions_getsSequentialSuffix() {
        let name = FileNaming.nextDocumentFilename(
            title: "Chapter 1", extension: "md",
            siblingFilenames: ["01-chapter-1.md", "02-chapter-1-2.md"])
        XCTAssertEqual(name, "03-chapter-1-3.md")
    }

    func test_groupFolderName_followsSamePattern() {
        let name = FileNaming.nextGroupFolderName(
            title: "Act One", siblingFilenames: ["01-prologue.md"])
        XCTAssertEqual(name, "02-act-one")
    }

    func test_groupFolderName_emptyFolder_getsNN01() {
        let name = FileNaming.nextGroupFolderName(
            title: "Act One", siblingFilenames: [])
        XCTAssertEqual(name, "01-act-one")
    }

    func test_fountainExtension_supportedForScreenplay() {
        let name = FileNaming.nextDocumentFilename(
            title: "Scene 1", extension: "fountain", siblingFilenames: [])
        XCTAssertEqual(name, "01-scene-1.fountain")
    }

    func test_unrelatedFiles_areIgnoredForNNComputation() {
        // .DS_Store, .gitkeep, anything not matching NN-slug pattern
        let name = FileNaming.nextDocumentFilename(
            title: "Chapter 1", extension: "md",
            siblingFilenames: [".DS_Store", "01-chapter-1.md", "notes.txt"])
        XCTAssertEqual(name, "02-chapter-1-2.md")
    }
}
