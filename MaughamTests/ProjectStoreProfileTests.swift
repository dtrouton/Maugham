import XCTest
import MaughamCore
@testable import Maugham

/// Report plan 4, Task 8 (R-4-7): the one store door the Report profile and
/// its switches are written through — `ProjectStore.setProfile(_:)` and
/// `setSwitch(_:_:)` — and the schema floor it must keep (review focus 3): a
/// book that never touches them is never raised to 10, and one that does is.
@MainActor
final class ProjectStoreProfileTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    // MARK: - helpers

    /// A Novel whose manifest on disk is at schema 9 — the book written before
    /// profiles existed — opened with its window's `DocumentStore`, so every
    /// write goes through the coordinated manifest door.
    private func makeSchema9Novel() async throws -> (URL, ProjectStore, DocumentStore) {
        let url = try await ProjectFactory.createNovelProject(named: "Floor", in: temp.url)
        try Self.lowerToSchema9(url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        return (url, store, ds)
    }

    /// Re-write the manifest at schema 9 through `encodeForDisk` (the content
    /// floor of a plain novel is 0, so 9 is what lands).
    static func lowerToSchema9(_ url: URL) throws {
        let file = url.appendingPathComponent(ProjectManifest.fileName)
        var manifest = try ProjectManifest.makeDecoder()
            .decode(ProjectManifest.self, from: Data(contentsOf: file))
        manifest.schemaVersion = 9
        try ProjectManifest.encodeForDisk(manifest).write(to: file, options: .atomic)
        XCTAssertEqual(ProjectManifest.schemaVersion(ofFileAt: file), 9, "premise: a schema-9 book")
    }

    private func bytes(_ url: URL) throws -> Data {
        try Data(contentsOf: url.appendingPathComponent(ProjectManifest.fileName))
    }

    private func onDisk(_ url: URL) throws -> ProjectManifest {
        try ProjectManifest.makeDecoder().decode(ProjectManifest.self, from: bytes(url))
    }

    private func schema(_ url: URL) -> Int? {
        ProjectManifest.schemaVersion(ofFileAt: url.appendingPathComponent(ProjectManifest.fileName))
    }

    // MARK: - The schema floor (review focus 3)

    func test_aNovelThatNeverTouchesTheDoorStaysAtSchema9() async throws {
        let (url, store, ds) = try await makeSchema9Novel()
        let before = try bytes(url)
        // An ordinary save the writer makes elsewhere in Settings.
        try await store.setCoachVacated(true)
        await ds.close()
        XCTAssertEqual(schema(url), 9, "nothing the Report section owns was written")
        XCTAssertNotEqual(try bytes(url), before, "premise: the other save did land")
        XCTAssertNil(try onDisk(url).profile)
        XCTAssertNil(try onDisk(url).switches)
    }

    /// Asked of the file's modification date, not only its bytes: a save in
    /// the same second as the last one re-encodes identical bytes (`modified`
    /// is whole-second), so equal bytes alone cannot tell a no-op from a write.
    func test_settingWhatIsAlreadyThereWritesNothing() async throws {
        let (url, store, ds) = try await makeSchema9Novel()
        try Self.backdate(url)
        let before = try bytes(url)
        try await store.setProfile(nil)
        for key in ProjectSwitchKey.allCases {
            try await store.setSwitch(key, nil)
        }
        await ds.close()
        XCTAssertEqual(try Self.modificationDate(url), Self.past, "a no-op through the door is no write")
        XCTAssertEqual(try bytes(url), before)
        XCTAssertEqual(schema(url), 9)
    }

    func test_settingAStoredValueAgainWritesNothing() async throws {
        let (url, store, ds) = try await makeSchema9Novel()
        try await store.setProfile(.report)
        try await store.setSwitch(.listOfTables, false)
        try Self.backdate(url)
        try await store.setProfile(.report)
        try await store.setSwitch(.listOfTables, false)
        await ds.close()
        XCTAssertEqual(try Self.modificationDate(url), Self.past)
    }

    static let past = Date(timeIntervalSince1970: 946_684_800)

    /// Set the manifest's modification date to 2000-01-01, so any write after
    /// this moves it.
    static func backdate(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: past],
            ofItemAtPath: url.appendingPathComponent(ProjectManifest.fileName).path)
    }

    static func modificationDate(_ url: URL) throws -> Date? {
        try FileManager.default.attributesOfItem(
            atPath: url.appendingPathComponent(ProjectManifest.fileName).path)[.modificationDate] as? Date
    }

    func test_turningTheProfileOnRaisesTheBookTo10() async throws {
        let (url, store, ds) = try await makeSchema9Novel()
        try await store.setProfile(.report)
        await ds.close()
        XCTAssertEqual(schema(url), 10)
        XCTAssertEqual(try onDisk(url).profile, .report)
        XCTAssertNil(try onDisk(url).switches, "the profile alone; the switches default from it")
    }

    func test_settingASwitchRaisesTheBookTo10() async throws {
        let (url, store, ds) = try await makeSchema9Novel()
        try await store.setSwitch(.numberSections, true)
        await ds.close()
        XCTAssertEqual(schema(url), 10)
        XCTAssertEqual(try onDisk(url).switches, ProjectSwitches(numberSections: true))
        XCTAssertNil(try onDisk(url).profile)
    }

    // MARK: - The profile

    func test_turningTheProfileOffKeepsTheStoredSwitches() async throws {
        let (url, store, ds) = try await makeSchema9Novel()
        try await store.setProfile(.report)
        try await store.setSwitch(.listOfTables, false)
        try await store.setProfile(nil)
        await ds.close()
        let manifest = try onDisk(url)
        XCTAssertNil(manifest.profile)
        XCTAssertEqual(manifest.switches, ProjectSwitches(listOfTables: false))
        XCTAssertEqual(schema(url), 10, "the switches are still v10 content")
    }

    /// M6: a Report is titled by its project only while it is a Report, so
    /// turning its profile off writes the project's title into the publish
    /// config while that config still says the starter's "Untitled" — the
    /// next PDF keeps the book's name. A title the writer chose is kept, and
    /// turning the profile ON writes nothing to the config.
    func test_turningAReportsProfileOff_keepsItsTitleInTheConfig() async throws {
        let url = try await ProjectFactory.createReportProject(named: "Quarterly", in: temp.url, shape: .sections)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        XCTAssertEqual(try PublishConfigStore.read(in: url)?.metadata.title, "Untitled", "premise: the starter's title")

        try await store.setProfile(nil)
        XCTAssertEqual(try PublishConfigStore.read(in: url)?.metadata.title, "Quarterly")
        XCTAssertNil(try onDisk(url).profile)

        let config = PublishConfigStore.fileURL(in: url)
        let before = try Data(contentsOf: config)
        try await store.setProfile(.report)
        try await store.setProfile(nil)
        await ds.close()
        XCTAssertEqual(try Data(contentsOf: config), before, "a named book's config is never rewritten")
    }

    /// The other side of M6: a book that never had the profile keeps its
    /// config's bytes through the door — an old book whose config says
    /// "Untitled" still prints "Untitled".
    func test_turningTheProfileOnWritesNothingToTheConfig() async throws {
        let (url, store, ds) = try await makeSchema9Novel()
        await PublishStarter.installIfMissing(into: url)
        let config = PublishConfigStore.fileURL(in: url)
        let before = try Data(contentsOf: config)
        XCTAssertEqual(try PublishConfigStore.read(in: url)?.metadata.title, "Untitled", "premise")
        try await store.setProfile(.report)
        await ds.close()
        XCTAssertEqual(try Data(contentsOf: config), before)
    }

    func test_aScreenplayIsRefusedAProfileAndNothingIsWritten() async throws {
        let url = try await ProjectFactory.createScreenplayProject(named: "Script", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        let before = try bytes(url)
        do {
            try await store.setProfile(.report)
            XCTFail("a screenplay took a profile")
        } catch let error as ProjectFactoryError {
            XCTAssertEqual(error, .profileNotOffered(.report, on: .screenplay))
        }
        await ds.close()
        XCTAssertNil(store.manifest.profile)
        XCTAssertEqual(try bytes(url), before)
    }

    func test_aCollectionIsRefusedAProfile() async throws {
        let url = try await ProjectFactory.createCollectionProject(named: "Pieces", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        do {
            try await store.setProfile(.report)
            XCTFail("a collection took a profile")
        } catch let error as ProjectFactoryError {
            XCTAssertEqual(error, .profileNotOffered(.report, on: .collection))
        }
        XCTAssertNil(store.manifest.profile)
    }

    func test_aShortStoryTakesTheProfile() async throws {
        let url = try await ProjectFactory.createShortStoryProject(named: "Story", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        try await store.setProfile(.report)
        XCTAssertEqual(try onDisk(url).profile, .report)
    }

    /// A newer build's profile is never overwritten — neither replaced by the
    /// Report nor cleared — and nothing is written.
    func test_aNewerBuildsProfileIsRefusedAtTheDoor() async throws {
        var step = "write"
        do {
            let url = try await ProjectFactory.createNovelProject(named: "Newer", in: temp.url)
            let file = url.appendingPathComponent(ProjectManifest.fileName)
            var written = try ProjectManifest.makeDecoder().decode(ProjectManifest.self, from: Data(contentsOf: file))
            written.profile = .unknown("essay")
            try ProjectManifest.encodeForDisk(written).write(to: file, options: .atomic)
            step = "load"
            let store = try await ProjectStore.load(from: url)
            step = "open"
            let ds = try await DocumentStore.open(url: url)
            store.documentStore = ds
            try Self.backdate(url)
            step = "loop"
            for attempt in [ProjectProfile.report, nil] {
                do {
                    try await store.setProfile(attempt)
                    XCTFail("overwrote a newer build's profile with \(String(describing: attempt))")
                } catch let error as ProjectStoreError {
                    XCTAssertEqual(error, .profileFromNewerBuild("essay"))
                }
            }
            step = "noop"
            try await store.setProfile(.unknown("essay"))
            step = "close"
            await ds.close()
            XCTAssertEqual(store.manifest.profile, .unknown("essay"))
            XCTAssertEqual(try onDisk(url).profile, .unknown("essay"))
            XCTAssertEqual(try Self.modificationDate(url), Self.past)
        } catch {
            XCTFail("at \(step): \(error)")
        }
    }

    // MARK: - The switches and their effective values

    func test_aSwitchOverridesTheProfileDefaultAndNilRestoresIt() async throws {
        let (url, store, ds) = try await makeSchema9Novel()
        try await store.setProfile(.report)
        XCTAssertTrue(store.manifest.effectiveSwitches.listOfFigures, "the Report's default")

        try await store.setSwitch(.listOfFigures, false)
        XCTAssertFalse(store.manifest.effectiveSwitches.listOfFigures)
        XCTAssertEqual(store.manifest.switches, ProjectSwitches(listOfFigures: false))

        try await store.setSwitch(.listOfFigures, nil)
        XCTAssertTrue(store.manifest.effectiveSwitches.listOfFigures, "back to the default")
        XCTAssertNil(store.manifest.switches, "an emptied set is stored as absent, never {}")
        await ds.close()
        XCTAssertNil(try onDisk(url).switches)
        XCTAssertEqual(try onDisk(url).profile, .report)
    }

    func test_eachKeyWritesItsOwnSwitch() async throws {
        let (_, store, _) = try await makeSchema9Novel()
        try await store.setSwitch(.numberSections, true)
        try await store.setSwitch(.listOfFigures, false)
        try await store.setSwitch(.listOfTables, true)
        try await store.setSwitch(.webAccess, false)
        XCTAssertEqual(store.manifest.switches, ProjectSwitches(
            numberSections: true, listOfFigures: false, listOfTables: true, webAccess: false))
        let effective = store.manifest.effectiveSwitches
        XCTAssertEqual([effective.numberSections, effective.listOfFigures,
                        effective.listOfTables, effective.webAccess], [true, false, true, false])
        for key in ProjectSwitchKey.allCases {
            XCTAssertEqual(store.manifest.switches?[key], [true, false, true, false][key.index])
            XCTAssertEqual(store.manifest.effectiveSwitch(key), [true, false, true, false][key.index])
        }
    }

    func test_withoutAProfileAnUnsetSwitchIsOff() async throws {
        let (_, store, _) = try await makeSchema9Novel()
        for key in ProjectSwitchKey.allCases {
            XCTAssertFalse(store.manifest.effectiveSwitch(key), "\(key)")
        }
    }
}

private extension ProjectSwitchKey {
    var index: Int { ProjectSwitchKey.allCases.firstIndex(of: self)! }
}
