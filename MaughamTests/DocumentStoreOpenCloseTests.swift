import XCTest
import MaughamCore
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

    /// `close()` drains the document registry: it closes every open Document and
    /// removes all entries, releasing the last strong reference to each. This is
    /// the load-bearing half of the zombie-window teardown — the registry (a
    /// strong `[path: Document]` map) rides ProjectWindow's retained scene @State,
    /// so a Document left registered survives window close even after the @State
    /// scorch. The single `close()` ProjectWindow.onDisappear makes must empty it.
    func test_close_drainsRegistry_releasingRegisteredDocuments() async throws {
        let url = try await ProjectFactory.createShortStoryProject(
            named: "Doc", in: temp.url)
        let store = try await DocumentStore.open(url: url)
        let storyURL = url.appendingPathComponent("story.md")
        try "A registered paragraph.".write(
            to: storyURL, atomically: true, encoding: .utf8)

        // Register a Document holding only a weak ref locally, so after this
        // closure returns the registry is the ONLY strong owner. (A nested
        // closure keeps the strong `doc` local out of the test's own scope.)
        weak var weakDoc: Document?
        let registerFreshDoc: () async throws -> Void = {
            let doc = try await Document.load(
                url: storyURL, device: "t", session: "s",
                presenter: store.presenter)
            weakDoc = doc
            store.register(document: doc, for: "story.md")
        }
        try await registerFreshDoc()

        XCTAssertNotNil(weakDoc, "sanity: the registry holds the doc before close")
        XCTAssertEqual(store.allOpenDocuments().count, 1,
            "sanity: exactly one doc registered")

        await store.close()

        XCTAssertTrue(store.allOpenDocuments().isEmpty,
            "close() must empty the document registry")
        XCTAssertNil(weakDoc,
            "draining the registry must release the last strong ref to the doc — "
            + "otherwise a closed window's DocumentStore strands it (the observed "
            + "per-open/close Document accumulation)")
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
