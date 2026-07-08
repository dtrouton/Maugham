import XCTest
import MaughamCore
@testable import Maugham

final class ProjectFactoryTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() {
        super.setUp()
        temp = TempDirectory()
    }

    override func tearDown() {
        temp = nil
        super.tearDown()
    }

    func test_createShortStory_writesExpectedFolderLayout() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "My Story", in: temp.url)

        let fm = FileManager.default
        XCTAssertEqual(url.lastPathComponent, "My Story")
        XCTAssertTrue(fm.fileExists(atPath: url.appendingPathComponent("project.maugham.json").path))
        XCTAssertTrue(fm.fileExists(atPath: url.appendingPathComponent("story.md").path))

        var isDir: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: url.appendingPathComponent("research").path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertTrue(fm.fileExists(atPath: url.appendingPathComponent("notes").path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func test_createShortStory_writesValidManifest() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "My Story", in: temp.url)
        let manifestURL = url.appendingPathComponent("project.maugham.json")
        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ProjectManifest.self, from: data)

        XCTAssertEqual(manifest.schemaVersion, ProjectManifest.currentSchemaVersion)
        XCTAssertEqual(manifest.type, .shortStory)
        XCTAssertEqual(manifest.title, "My Story")
        XCTAssertEqual(manifest.structure.count, 1)
        XCTAssertEqual(manifest.structure[0].type, .document)
        XCTAssertEqual(manifest.structure[0].path, "story.md")
        XCTAssertEqual(manifest.structure[0].id, "manuscript")
        XCTAssertTrue(manifest.research.isEmpty)
    }

    func test_createShortStory_emptyManuscriptIsEmptyString() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "X", in: temp.url)
        let storyText = try String(contentsOf: url.appendingPathComponent("story.md"), encoding: .utf8)
        XCTAssertEqual(storyText, "")
    }

    func test_createShortStory_intoExistingFolder_throws() async throws {
        let path = temp.url.appendingPathComponent("Already Exists")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)

        do {
            _ = try await ProjectFactory.createShortStoryProject(
                named: "Already Exists", in: temp.url)
            XCTFail("expected throw for existing folder")
        } catch ProjectFactoryError.projectAlreadyExists {
            // ok
        }
    }

    func test_createShortStory_blankName_throws() async throws {
        do {
            _ = try await ProjectFactory.createShortStoryProject(
                named: "   ", in: temp.url)
            XCTFail("expected throw for blank name")
        } catch ProjectFactoryError.invalidName {
            // ok
        }
    }

    func test_createNovel_seedsManifestAndChapter1() async throws {
        let temp = try TempDirectory()
        let url = try await ProjectFactory.createNovelProject(
            named: "Razor", in: temp.url)

        let manifestURL = url.appendingPathComponent("project.maugham.json")
        let data = try Data(contentsOf: manifestURL)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let manifest = try dec.decode(ProjectManifest.self, from: data)

        XCTAssertEqual(manifest.type, .novel)
        XCTAssertEqual(manifest.structure.count, 1)
        XCTAssertEqual(manifest.structure[0].title, "Chapter 1")
        XCTAssertEqual(manifest.structure[0].type, .document)

        let chapterURL = url.appendingPathComponent(manifest.structure[0].path!)
        XCTAssertTrue(FileManager.default.fileExists(atPath: chapterURL.path))
    }

    func test_createScreenplay_seedsManifestAndScene1Fountain() async throws {
        let temp = try TempDirectory()
        let url = try await ProjectFactory.createScreenplayProject(
            named: "TheTrip", in: temp.url)

        let manifestURL = url.appendingPathComponent("project.maugham.json")
        let data = try Data(contentsOf: manifestURL)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let manifest = try dec.decode(ProjectManifest.self, from: data)

        XCTAssertEqual(manifest.type, .screenplay)
        XCTAssertEqual(manifest.structure.count, 1)
        XCTAssertEqual(manifest.structure[0].title, "Scene 1")
        XCTAssertTrue(manifest.structure[0].path?.hasSuffix(".fountain") ?? false,
                      "scene path \(manifest.structure[0].path ?? "(nil)") should end .fountain")

        let sceneURL = url.appendingPathComponent(manifest.structure[0].path!)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sceneURL.path))
    }

    func test_createCollection_seedsEmptyManifest() async throws {
        let temp = try TempDirectory()
        let url = try await ProjectFactory.createCollectionProject(
            named: "MyShorts", in: temp.url)

        let manifestURL = url.appendingPathComponent("project.maugham.json")
        let data = try Data(contentsOf: manifestURL)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let manifest = try dec.decode(ProjectManifest.self, from: data)

        XCTAssertEqual(manifest.type, .collection)
        XCTAssertTrue(manifest.structure.isEmpty)

        // Collection has research and notes folders but no manuscript
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("research").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("notes").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("manuscript").path))
    }
}
