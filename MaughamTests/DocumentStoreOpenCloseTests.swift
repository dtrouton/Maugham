import XCTest
@testable import Maugham

@MainActor
final class DocumentStoreOpenCloseTests: XCTestCase {
    var temp: TempDirectory!

    override func setUp() async throws {
        try await super.setUp()
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        temp = nil
        try await super.tearDown()
    }

    func test_open_seedsEmptyUIState_whenStateFileAbsent() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Doc", in: temp.url)
        let store = try await DocumentStore.open(url: url)
        XCTAssertEqual(store.uiState, .empty)
        await store.close()
    }

    func test_open_loadsExistingUIState() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Doc", in: temp.url)
        // Seed a UI state file
        let dotDir = url.appendingPathComponent(".maugham")
        try FileManager.default.createDirectory(
            at: dotDir, withIntermediateDirectories: true)
        let state = UIState(schemaVersion: 1, selectedItemId: "doc-x",
                            isNoChromeOn: true)
        try JSONEncoder().encode(state).write(
            to: dotDir.appendingPathComponent("ui-state.json"))

        let store = try await DocumentStore.open(url: url)
        XCTAssertEqual(store.uiState.selectedItemId, "doc-x")
        XCTAssertTrue(store.uiState.isNoChromeOn)
        await store.close()
    }

    func test_updateUIState_persists_afterDebounce() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Doc", in: temp.url)
        let store = try await DocumentStore.open(url: url)

        store.updateUIState { $0.selectedItemId = "doc-y" }

        // Wait past the 500ms UI state debounce + a buffer
        try await Task.sleep(for: .milliseconds(700))

        let savedURL = url
            .appendingPathComponent(".maugham")
            .appendingPathComponent("ui-state.json")
        let data = try Data(contentsOf: savedURL)
        let decoded = try JSONDecoder().decode(UIState.self, from: data)
        XCTAssertEqual(decoded.selectedItemId, "doc-y")
        await store.close()
    }

    func test_close_flushesPendingUIStateWrite() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Doc", in: temp.url)
        let store = try await DocumentStore.open(url: url)

        store.updateUIState { $0.isNoChromeOn = true }
        await store.close()  // should flush before unregistering

        let savedURL = url
            .appendingPathComponent(".maugham")
            .appendingPathComponent("ui-state.json")
        let data = try Data(contentsOf: savedURL)
        let decoded = try JSONDecoder().decode(UIState.self, from: data)
        XCTAssertTrue(decoded.isNoChromeOn)
    }
}
