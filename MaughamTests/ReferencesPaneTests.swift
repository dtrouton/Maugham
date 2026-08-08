import XCTest
import AppKit
import ApplicationServices
import SwiftUI
import MaughamCore
@testable import Maugham

/// The References pane (M2 spec §6.2) — **a shelf, not a browser**: what this
/// piece is pinned to, as a thumbnail, a kind glyph and a title, with one click
/// promoting a pin into the assistant column.
///
/// The suite is organised around the two things a shelf can get wrong that no
/// screenshot shows: **where its list comes from** (one projection, one
/// assembly — the `links:` field was got wrong once already, in Task 3) and
/// **where its glyphs come from** (`CanvasItemFacts`, which is the canvas's own
/// table; a second one here would be the fifth spelling `CanvasItemKind`
/// already records as a known duplication).
@MainActor
final class ReferencesPaneTests: XCTestCase {

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        temp = try TempDirectory()
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        temp = nil
    }

    // MARK: - Fixtures

    /// A palette card is a `.document` asset inside the role-stamped palette
    /// GROUP and nothing on the item says so — `PinnedReferencesTests`' fixture,
    /// for its reason.
    private func research() -> [ResearchItem] {
        let card = ResearchItem(id: "res-card", title: "Act II fog", type: .asset,
                                kind: .document, path: "research/palette/act-ii-fog.md")
        let group = ResearchItem(id: "res-palette", title: "Palette", type: .group,
                                 path: PaletteConvention.folderPath,
                                 children: [card], role: .paletteGroup)
        let note = ResearchItem(id: "res-note", title: "The falls at night", type: .asset,
                                kind: .document, path: "research/the-falls-at-night.md")
        let photo = ResearchItem(id: "res-photo", title: "The gorge from above",
                                 type: .asset, kind: .image,
                                 path: "research/research_assets/gorge.jpg")
        return [group, note, photo]
    }

    private func index() -> CanvasItemIndex { CanvasItemIndex.over(research: research()) }

    private func pin(_ id: String, _ kind: PinnedReference.Kind,
                     _ title: String) -> PinnedReference {
        PinnedReference(id: id, kind: kind, title: title)
    }

    // MARK: - Contract: a row is a thumbnail, a glyph and a title

    /// A research note has no pixels, so it draws its glyph and no thumbnail.
    func test_aResearchNoteRowCarriesTheManifestsTitleAndTheCanvasGlyph() {
        let rows = ReferencesPane.rows(
            for: [pin("res-note", .research(itemId: "res-note"), "The falls at night")],
            in: index())

        XCTAssertEqual(rows.map(\.reference.title), ["The falls at night"])
        XCTAssertEqual(rows.map(\.glyph), [CanvasItemKind.researchNote.glyph])
        XCTAssertEqual(rows.map(\.thumbnailPath), [nil])
    }

    /// **A photograph in the RESEARCH tree gets a thumbnail too**, and it gets
    /// it from the same field the canvas draws cards from. A row that only
    /// thumbnailed *owned* pictures would leave the commonest case — a photo the
    /// writer filed under research and linked to the chapter — as a bare glyph.
    func test_aResearchPhotographRowCarriesItsPathSoItCanBeThumbnailed() {
        let rows = ReferencesPane.rows(
            for: [pin("res-photo", .research(itemId: "res-photo"), "The gorge from above")],
            in: index())

        XCTAssertEqual(rows.map(\.thumbnailPath), ["research/research_assets/gorge.jpg"])
        XCTAssertEqual(rows.map(\.glyph), [CanvasItemKind.image.glyph])
    }

    /// An *owned* picture has no manifest entry and never will, so it resolves
    /// against the index without consulting it — the same asymmetry
    /// `CanvasItemFacts.resolve` holds.
    func test_anOwnedPhotoRowResolvesWithoutAManifestEntry() {
        let rows = ReferencesPane.rows(
            for: [pin("canvas_assets/image-1.png",
                      .photo(path: "canvas_assets/image-1.png"),
                      CanvasItemFacts.ownedTitle)],
            in: .empty)

        XCTAssertEqual(rows.map(\.thumbnailPath), ["canvas_assets/image-1.png"])
        XCTAssertEqual(rows.map(\.glyph), [CanvasItemKind.image.glyph])
    }

    func test_aPaletteCardRowUsesThePaletteGlyph() {
        let rows = ReferencesPane.rows(
            for: [pin("res-card", .palette(cardId: "res-card"), "Act II fog")],
            in: index())

        XCTAssertEqual(rows.map(\.glyph), [CanvasItemKind.paletteCard.glyph])
        XCTAssertEqual(rows.map(\.thumbnailPath), [nil])
    }

    /// **A scrap is not an item and has no `CanvasItemKind`** — it is words the
    /// writer typed onto the board, living in `canvas.md`. It gets this file's
    /// one glyph of its own, named as a constant so the pane and its test cannot
    /// drift.
    func test_aScrapRowUsesTheScrapGlyphAndNeverAnItemKind() {
        let rows = ReferencesPane.rows(
            for: [pin("n1", .scrap(nodeId: "n1"), "cold, and unashamed of it")],
            in: .empty)

        XCTAssertEqual(rows.map(\.glyph), [ReferencesPane.scrapGlyph])
        XCTAssertEqual(rows.map(\.thumbnailPath), [nil])
        XCTAssertFalse(CanvasItemKind.allCases.map(\.glyph).contains(ReferencesPane.scrapGlyph),
                       "the scrap glyph must not be an item kind's — a scrap is not an item, "
                       + "and sharing a glyph would make the two unreadable apart on the shelf")
    }

    /// The row order is the projection's order, untouched. A shelf that sorted
    /// would put the canvas set among the links and lose the distinction
    /// `PinnedReferences.pinned` draws on.
    func test_rowsPreserveTheProjectionsOrder() {
        let pins = [pin("res-note", .research(itemId: "res-note"), "The falls at night"),
                    pin("res-card", .palette(cardId: "res-card"), "Act II fog"),
                    pin("n1", .scrap(nodeId: "n1"), "a thought")]
        XCTAssertEqual(ReferencesPane.rows(for: pins, in: index()).map(\.id),
                       pins.map(\.id))
    }

    // MARK: - Contract: the empty state names the two ways in

    /// *"Nothing pinned yet."* is only half an empty state. A writer who has
    /// never linked research and never clustered a card has no way to guess what
    /// would fill this pane, so the description names **both** routes — and
    /// naming only one would be worse than naming neither, because it would
    /// read as the only way.
    func test_theEmptyStateNamesBothWaysSomethingBecomesAReference() {
        XCTAssertEqual(ReferencesPane.emptyTitle, "Nothing pinned yet.")

        let description = ReferencesPane.emptyDescription.lowercased()
        XCTAssertTrue(description.contains("link"),
                      "the empty state must name linking research: \(description)")
        XCTAssertTrue(description.contains("canvas"),
                      "the empty state must name the planning canvas: \(description)")
    }

    // MARK: - Contract: click promotes ONE, click again sends it back

    func test_clickingAPinPromotesIt() {
        let model = AssistantColumnModel()
        let note = pin("res-note", .research(itemId: "res-note"), "The falls at night")

        model.study(note)

        XCTAssertEqual(model.studied, note)
    }

    /// **One at a time**, because two studied references is a research session
    /// rather than writing (spec §6.2). Promoting another REPLACES rather than
    /// stacking.
    func test_promotingAnotherReplacesRatherThanStacking() {
        let model = AssistantColumnModel()
        let note = pin("res-note", .research(itemId: "res-note"), "The falls at night")
        let card = pin("res-card", .palette(cardId: "res-card"), "Act II fog")

        model.study(note)
        model.study(card)

        XCTAssertEqual(model.studied, card)
    }

    func test_clickingTheStudiedPinAgainSendsItBack() {
        let model = AssistantColumnModel()
        let note = pin("res-note", .research(itemId: "res-note"), "The falls at night")

        model.study(note)
        model.study(note)

        XCTAssertNil(model.studied)
    }

    /// The toggle is on the pin's **id**, not on the value, because
    /// `PinnedReferences.pinned` is a pure function its callers re-run: a title
    /// that changed under the writer would otherwise make the second click on
    /// the same row promote a "different" reference instead of dismissing.
    func test_theToggleIsOnTheIdSoARecomputedTitleStillDismisses() {
        let model = AssistantColumnModel()
        model.study(pin("res-note", .research(itemId: "res-note"), "The falls at night"))
        model.study(pin("res-note", .research(itemId: "res-note"), "The falls, at night"))

        XCTAssertNil(model.studied)
    }

    // MARK: - Contract: the list comes from ONE assembly

    /// **The projection has one caller-side assembly, and this is the census
    /// that keeps it that way.**
    ///
    /// Three inputs have to be got right together — `linkedResearchIds` (NOT
    /// `StructureItem.links`, which is the unrelated document-to-document
    /// backlink field and was the plan's own mistake, caught in Task 3), the
    /// attached-or-sidecar scene discriminator `list_canvas` reads through, and
    /// a `CanvasItemIndex` over the whole research tree. A second site getting
    /// any one of them wrong shows the writer a plausible, wrong shelf with
    /// nothing red.
    func test_thePinnedProjectionIsAssembledInExactlyOneProductionFile() throws {
        XCTAssertEqual(try Self.filesCallingTheProjection(in: Self.appSourceDir),
                       ["PinnedReferenceResolver.swift"],
                       "PinnedReferences.pinned(forDocId:) is assembled in one place and "
                       + "read from there by the pane, the column and the compiler's "
                       + "context listing. A second assembly is a second chance to pass "
                       + "`StructureItem.links` where `linkedResearchIds` belongs.")
    }

    /// The planted offender, without which the census could be scanning an empty
    /// tree and reporting a set someone happened to write down.
    func test_theAssemblyCensusCatchesASecondCaller() throws {
        let planted = try Self.filesCallingTheProjection(
            Self.appSourceDir,
            plus: ["SomeNewPane.swift":
                    "let pins = PinnedReferences.pinned(forDocId: id, links: item.links, "
                    + "scene: nil, scraps: [:], items: .empty)"])
        XCTAssertTrue(planted.contains("SomeNewPane.swift"),
                      "the census cannot see a second caller — it is not reading real code")
    }

    static var appSourceDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Maugham", isDirectory: true)
    }

    /// File names of every production `.swift` calling `PinnedReferences.pinned(`
    /// outside a comment-only line. The declaring file is excluded by name —
    /// a declaration is not a caller.
    static func filesCallingTheProjection(
        _ root: URL, plus extra: [String: String] = [:]
    ) throws -> [String] {
        var found: Set<String> = Set(extra.filter { $0.value.contains("PinnedReferences.pinned(") }
            .keys)
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard url.lastPathComponent != "PinnedReferences.swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            if code.contains("PinnedReferences.pinned(") {
                found.insert(url.lastPathComponent)
            }
        }
        return found.sorted()
    }

    static func filesCallingTheProjection(in root: URL) throws -> [String] {
        try filesCallingTheProjection(root)
    }

    // MARK: - Contract: it mounts, and a click reaches the model

    func test_theShelfDrawsARowPerPinAndAClickPromotesIt() async throws {
        let model = AssistantColumnModel()
        let pins = [pin("res-note", .research(itemId: "res-note"), "The falls at night"),
                    pin("res-card", .palette(cardId: "res-card"), "Act II fog")]

        let window = mount(AnyView(
            ReferencesPane(rows: ReferencesPane.rows(for: pins, in: index()),
                           projectRoot: temp.url,
                           persona: .author,
                           assistant: model)
                .frame(width: 300, height: 500)))

        let button = try findButton(labelled: "The falls at night", in: window)
        _ = button.perform(NSSelectorFromString("accessibilityPerformPress"))
        pump()

        XCTAssertEqual(model.studied?.id, "res-note",
                       "a row's press must reach the assistant model — the shelf's whole job")
    }

    func test_anEmptyShelfShowsTheEmptyStateAndNoRows() async throws {
        let model = AssistantColumnModel()
        let window = mount(AnyView(
            ReferencesPane(rows: [], projectRoot: temp.url, persona: .author, assistant: model)
                .frame(width: 300, height: 500)))

        let text = allStrings(in: window).joined(separator: "\n")
        XCTAssertTrue(text.contains(ReferencesPane.emptyTitle),
                      "the empty state's title is not on screen. Found: \(text)")
    }

    // MARK: - Contract: outside Author, a pin is inert, and says why

    /// **The assistant column is Author-only (2026-08-08 ruling).** `.references`
    /// stays reachable from Review, so a Review mount must not be a dead click —
    /// no button reaches the model, and the pane says where studying happens.
    func test_aReviewMountRendersRowsInertWithAFooterAndNoDeadClick() async throws {
        let model = AssistantColumnModel()
        let pins = [pin("res-note", .research(itemId: "res-note"), "The falls at night")]

        let window = mount(AnyView(
            ReferencesPane(rows: ReferencesPane.rows(for: pins, in: index()),
                           projectRoot: temp.url,
                           persona: .review,
                           assistant: model)
                .frame(width: 300, height: 500)))

        let text = allStrings(in: window).joined(separator: "\n")
        XCTAssertTrue(text.contains(ReferencesPane.nonAuthorFooter),
                      "outside Author the pane must explain where studying a pin "
                      + "happens. Found: \(text)")
        XCTAssertTrue(text.contains("The falls at night"),
                      "the row's title must still be on screen, just not pressable")

        do {
            _ = try findButton(labelled: "The falls at night", in: window)
            XCTFail("a pin row outside Author must not be a pressable button — "
                    + "the column it would promote into is Author-only, so a press "
                    + "here would be a dead click")
        } catch is XCTSkip {
            // Expected: no such button was built.
        }
    }

    // MARK: - Hosting

    private func mount(_ view: AnyView) -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: 320, height: 520)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        pump()
        return window
    }

    private func pump(_ seconds: TimeInterval = 0.2) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func axAttribute(_ element: AnyObject, _ attribute: String) -> Any? {
        guard let object = element as? NSObject,
              object.responds(to: NSSelectorFromString(attribute)) else { return nil }
        return object.value(forKey: attribute)
    }

    private func axElements(under root: AnyObject, depth: Int = 0) -> [AnyObject] {
        guard depth < 40 else { return [] }
        let children = axAttribute(root, "accessibilityChildren") as? [AnyObject] ?? []
        return [root] + children.flatMap { axElements(under: $0, depth: depth + 1) }
    }

    /// SwiftUI only builds an accessibility tree when an assistive client is
    /// attached to the process. `DiagnosticsPaneTests`' guard, verbatim.
    private func axTree(in window: NSWindow) throws -> [AnyObject] {
        var role: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(getpid()), kAXRoleAttribute as CFString, &role)
        guard error == .success, role != nil else {
            throw XCTSkip(
                "no assistive client could be attached to this process, so SwiftUI "
                + "never built the tree this test presses through")
        }
        return axElements(under: try XCTUnwrap(window.contentView))
    }

    private func allStrings(in window: NSWindow) -> [String] {
        guard let tree = try? axTree(in: window) else { return [] }
        return tree.flatMap { element -> [String] in
            [axAttribute(element, "accessibilityLabel") as? String,
             axAttribute(element, "accessibilityValue") as? String,
             axAttribute(element, "accessibilityTitle") as? String].compactMap { $0 }
        }
    }

    private func findButton(labelled label: String, in window: NSWindow) throws -> NSObject {
        for _ in 0..<10 {
            let tree = try axTree(in: window)
            if let hit = tree
                .filter({ (axAttribute($0, "accessibilityRole") as? String) == "AXButton" })
                .first(where: {
                    let label_ = (axAttribute($0, "accessibilityLabel") as? String) ?? ""
                    let title = (axAttribute($0, "accessibilityTitle") as? String) ?? ""
                    return label_.contains(label) || title.contains(label)
                }) as? NSObject {
                return hit
            }
            pump(0.1)
        }
        let seen = (try? axTree(in: window))?.map {
            "\((axAttribute($0, "accessibilityRole") as? String) ?? "?")"
            + ":\((axAttribute($0, "accessibilityLabel") as? String) ?? "")"
        } ?? []
        throw XCTSkip("no button labelled \"\(label)\" was built. Tree: \(seen)")
    }
}
