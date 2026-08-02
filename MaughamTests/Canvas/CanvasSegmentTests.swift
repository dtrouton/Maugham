import XCTest
@testable import Maugham
import MaughamCore

@MainActor
final class CanvasSegmentTests: XCTestCase {

    /// The picker renders uniform `Image` children only. A segment with no
    /// symbol is smoke defect C (2026-07-25) waiting to happen again.
    func test_canvasHasAPickerSymbolAndADisplayName() {
        XCTAssertFalse(BinderSegment.canvas.pickerSymbolName.isEmpty)
        XCTAssertEqual(BinderSegment.canvas.displayName(for: .novel), "Canvas")
        XCTAssertEqual(BinderSegment.canvas.displayName(for: .collection), "Canvas")
    }

    /// `CaseIterable` exists so the four hardcoded segment arrays in the persona
    /// tests can never again miss a new case.
    ///
    /// **The members, not the count.** This asserted
    /// `BinderSegment.allCases.count == 7` — a literal count over a list, the
    /// shape `memory/feedback_prose_counts_are_unmaintainable.md` is about — and
    /// slice 2 replaced it rather than bumping it to 8. A count fails with
    /// "8 is not equal to 7" and tells the next reader nothing about which case
    /// arrived or whether it was meant to; a set difference names it. This is
    /// still the assertion that stops a new segment being added without anyone
    /// looking at the four hardcoded arrays next door.
    func test_allCasesCoversEverySegmentAndSymbolsStayDistinct() {
        XCTAssertEqual(Set(BinderSegment.allCases),
                       [.manuscript, .tree, .research, .palette,
                        .scenes, .canvas, .trash, .find])
        XCTAssertTrue(BinderSegment.allCases.contains(.canvas))
        let symbols = BinderSegment.allCases.map(\.pickerSymbolName)
        XCTAssertEqual(Set(symbols).count, symbols.count,
                       "an icon-only picker cannot show two segments the same glyph")
    }

    /// The canvas is a persona surface, not a transient state — it must not be
    /// carried across a persona switch the way Find and Trash are.
    func test_canvasIsNotTransient() {
        XCTAssertFalse(BinderSegment.canvas.isTransient)
    }

    func test_canvasSurvivesAUIStateRoundTrip() throws {
        var state = UIState.empty
        state.binderSegment = .canvas
        let data = try JSONEncoder().encode(state)
        let back = try JSONDecoder().decode(UIState.self, from: data)
        XCTAssertEqual(back.binderSegment, .canvas)
    }

    /// Spec §10's answer: the binder shows the research tree under the canvas
    /// segment, because §8A.1's drag-in route (1C-d) needs the tree beside the
    /// canvas. Pinned at the source because a SwiftUI switch arm has no runtime
    /// handle — the same technique `CanvasCompositionTests` uses.
    func test_bothBinderTogglesRouteTheCanvasSegmentToTheResearchTree() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // MaughamTests/Canvas
            .deletingLastPathComponent()    // MaughamTests
            .deletingLastPathComponent()    // repo root

        let novel = try String(contentsOf: repoRoot
            .appendingPathComponent("Maugham/Views/BinderPaneToggle.swift"), encoding: .utf8)
        XCTAssertTrue(novel.contains("case .research, .canvas:"),
                      "BinderPaneToggle must render ResearchView for .canvas")

        let collection = try String(contentsOf: repoRoot
            .appendingPathComponent("Maugham/Views/CollectionBinderPaneToggle.swift"),
                                    encoding: .utf8)
        XCTAssertTrue(collection.contains("case .research, .canvas:"),
                      "CollectionBinderPaneToggle must render CollectionResearchPane for .canvas")
    }

    /// The seam between the store and the ground: the store vends hex strings
    /// off REAL project data (one palette card, two swatches), and
    /// `CanvasGroundPalette` — the one parser — accepts every one of them
    /// unchanged. Task 8 built the wash seam and Task 10 wired it;
    /// `paletteSwatchHexes()` is the last link, so this is the one test in the
    /// slice that actually calls it.
    func test_theGroundAcceptsTheHexesTheStoreVends() async throws {
        let temp = TempDirectory()
        let projectURL = try await ProjectFactory.createNovelProject(
            named: "CanvasPaletteSeam", in: temp.url)
        let store = try await ProjectStore.load(from: projectURL)
        let documentStore = try await DocumentStore.open(url: projectURL)
        store.documentStore = documentStore

        _ = try await store.addPaletteCard(title: "The Flat", kind: .location)
        var card = store.loadPaletteCards()[0]
        card = PaletteCard(
            researchItemId: card.researchItemId, title: card.title, kind: card.kind,
            swatches: ["#8A6F4D", "#2F3B4C"], notes: card.notes,
            imagePaths: card.imagePaths, body: card.body)
        try await store.updatePaletteCard(card)

        let hexes = store.paletteSwatchHexes()
        XCTAssertEqual(hexes, ["#8A6F4D", "#2F3B4C"])
        XCTAssertEqual(CanvasGroundPalette.validHexes(hexes), hexes,
                       "every hex the store vends must be one the ground can consume")

        await documentStore.close()
    }
}
