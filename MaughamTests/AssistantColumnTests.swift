import XCTest
import AppKit
import ApplicationServices
import SwiftUI
import MaughamCore
@testable import Maugham

/// The assistant column (M2 spec §6.2) — **one** studied reference, between the
/// binder and the prose, at a width you can read at.
///
/// Two contracts here are structural rather than visual, and both are the kind
/// that a screenshot passes and a writer meets a week later:
///
/// - **It renders nothing of its own.** Every arm hands off to a renderer this
///   app already ships. A second markdown renderer here is precisely the defect
///   `MarkdownBlockParser` was extracted to end, and it would diverge from the
///   research preview the writer sees two panes away.
/// - **It goes with the chrome.** ⌘\ means "nothing but my prose", and a
///   reference column that survived it would be the loudest thing left on
///   screen.
@MainActor
final class AssistantColumnTests: XCTestCase {

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

    // MARK: - Contract: the column exists only while something is studied

    func test_nothingStudiedIsNoColumn() {
        XCTAssertFalse(AssistantColumn.isPresented(studied: nil, isNoChromeOn: false))
    }

    func test_aStudiedReferenceMountsTheColumn() {
        XCTAssertTrue(AssistantColumn.isPresented(studied: aPin(), isNoChromeOn: false))
    }

    /// **The same flag the intent strip rides** (`isNoChromeOn`, Task 4). ⌘\
    /// takes the chrome, and a studied reference is chrome — the writer asked
    /// for their prose and nothing else.
    func test_theColumnGoesWithTheChrome() {
        XCTAssertFalse(AssistantColumn.isPresented(studied: aPin(), isNoChromeOn: true))
    }

    /// Asked over the product rather than down the one path the plan named:
    /// the rule is a conjunction and both halves must be able to veto.
    func test_thePresentationRuleIsAskedOverBothInputs() {
        let expected: [(PinnedReference?, Bool, Bool)] = [
            (nil, false, false), (nil, true, false),
            (aPin(), false, true), (aPin(), true, false),
        ]
        for (studied, noChrome, wanted) in expected {
            XCTAssertEqual(
                AssistantColumn.isPresented(studied: studied, isNoChromeOn: noChrome), wanted,
                "studied: \(studied?.id ?? "nil"), isNoChromeOn: \(noChrome)")
        }
    }

    // MARK: - Contract: the width persists, clamped

    func test_theDefaultWidthIsInsideItsOwnRange() {
        XCTAssertTrue(
            UIState.assistantColumnWidthRange.contains(UIState.defaultAssistantColumnWidth),
            "the default width sits outside the range every write is clamped to, so a "
            + "fresh project would be corrected on its first drag")
    }

    /// A hand-edited `ui-state.json` must not be able to hand the writer a
    /// column wider than the window — the clamp lives with the persisted value
    /// so both the drag and the decode go through it.
    func test_theWidthIsClampedOnBothSides() {
        let range = UIState.assistantColumnWidthRange
        XCTAssertEqual(UIState.clampedAssistantColumnWidth(-40), range.lowerBound)
        XCTAssertEqual(UIState.clampedAssistantColumnWidth(9_000), range.upperBound)
        XCTAssertEqual(UIState.clampedAssistantColumnWidth(range.lowerBound + 20),
                       range.lowerBound + 20)
    }

    func test_aWidthOutsideTheRangeOnDiskDecodesInsideIt() throws {
        let json = """
        {"schemaVersion": \(UIState.currentSchemaVersion), "assistantColumnWidth": 4000}
        """
        let decoded = try JSONDecoder().decode(UIState.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.assistantColumnWidth,
                       UIState.assistantColumnWidthRange.upperBound)
    }

    /// The additive-key discipline (`compilerModel`'s, `selectedSubject`'s):
    /// a file written without the key reads as the default rather than failing.
    func test_aFileWithoutTheKeyDecodesToTheDefault() throws {
        let json = #"{"schemaVersion": 5, "isNoChromeOn": false}"#
        let decoded = try JSONDecoder().decode(UIState.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.assistantColumnWidth, UIState.defaultAssistantColumnWidth)
    }

    func test_theNewFieldDidNotCostASchemaBump() {
        XCTAssertEqual(UIState.currentSchemaVersion, 5)
    }

    // MARK: - Contract: what the column renders, resolved against a project

    func test_aResearchPinResolvesToTheResearchItemItself() async throws {
        let (url, store) = try await makeProject()
        let subject = AssistantColumn.subject(
            for: PinnedReference(id: "res-note", kind: .research(itemId: "res-note"),
                                 title: "The falls at night"),
            store: store, projectRoot: url)

        guard case .research(let item) = subject else {
            return XCTFail("expected a research subject, got \(subject)")
        }
        XCTAssertEqual(item.id, "res-note")
        XCTAssertEqual(item.title, "The falls at night")
    }

    func test_aPalettePinResolvesToTheParsedCard() async throws {
        let (url, store) = try await makeProject()
        let subject = AssistantColumn.subject(
            for: PinnedReference(id: "res-card", kind: .palette(cardId: "res-card"),
                                 title: "Act II fog"),
            store: store, projectRoot: url)

        guard case .palette(let card) = subject else {
            return XCTFail("expected a palette subject, got \(subject)")
        }
        XCTAssertEqual(card.researchItemId, "res-card")
        XCTAssertEqual(card.title, "Act II fog")
    }

    /// An owned photograph needs no manifest at all — it exists nowhere else in
    /// the project — so it resolves in full against a project that has never
    /// heard of it.
    func test_anOwnedPhotoResolvesWithoutAManifestEntry() async throws {
        let (url, store) = try await makeProject()
        let subject = AssistantColumn.subject(
            for: PinnedReference(id: "canvas_assets/x.png",
                                 kind: .photo(path: "canvas_assets/x.png"),
                                 title: CanvasItemFacts.ownedTitle),
            store: store, projectRoot: url)

        guard case .photo(let path) = subject else {
            return XCTFail("expected a photo subject, got \(subject)")
        }
        XCTAssertEqual(path, "canvas_assets/x.png")
    }

    /// **A pin can go stale while it is being studied** — the writer deletes the
    /// note in the binder with the column open. The column says so rather than
    /// drawing an empty pane that looks like a rendering failure.
    func test_aReferenceThatLeftTheProjectResolvesToMissing() async throws {
        let (url, store) = try await makeProject()
        let subject = AssistantColumn.subject(
            for: PinnedReference(id: "res-gone", kind: .research(itemId: "res-gone"),
                                 title: "Deleted"),
            store: store, projectRoot: url)

        XCTAssertEqual(subject, .missing)
    }

    /// A scrap's words live in `canvas.md`, never in the manifest — so the
    /// subject carries the TEXT and the column draws it at reading size. The
    /// pin's own title is the truncated first line and would be the wrong thing
    /// to study.
    func test_aScrapResolvesToItsWholeText() async throws {
        let (url, store) = try await makeProject()
        let node = CanvasNodeID("aaaa")
        var scene = CanvasScene()
        scene.insert(CanvasNode(id: node, kind: .scrap, origin: .zero,
                                width: 240, cachedHeight: 80))
        CanvasStore(projectRoot: url).save(
            scene: scene, scraps: [node: "cold, and unashamed of it\n\nand then the falls"])

        let subject = AssistantColumn.subject(
            for: PinnedReference(id: node.raw, kind: .scrap(nodeId: node.raw),
                                 title: "cold, and unashamed of it"),
            store: store, projectRoot: url)

        guard case .scrap(let text) = subject else {
            return XCTFail("expected a scrap subject, got \(subject)")
        }
        XCTAssertTrue(text.contains("and then the falls"),
                      "the column must study the whole scrap, not the pin's first line: \(text)")
    }

    // MARK: - Contract: it renders through what already ships

    /// **The census behind "REUSE existing renderers".** A markdown renderer
    /// here would compile, look right, and disagree with the research preview
    /// two panes away the first time a writer used a table or a fence — which is
    /// the exact drift `MarkdownBlockParser` was extracted to end (five hand-
    /// rolled splitters, 2026-07-07).
    func test_theColumnCarriesNoRendererOfItsOwn() throws {
        let source = try String(contentsOf: Self.columnSource, encoding: .utf8)
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        for banned in ["MarkdownBlockParser", "AttributedString(markdown:"] {
            XCTAssertFalse(code.contains(banned),
                           "AssistantColumn.swift parses markdown itself (`\(banned)`). "
                           + "Hand off to ResearchPreview / PaletteCardReadView instead — "
                           + "a second renderer is the defect MarkdownBlockParser exists "
                           + "to prevent.")
        }
    }

    /// The control: the census must be reading the real file, or the assertions
    /// above pass over an empty string.
    func test_theRendererCensusIsReadingTheRealFile() throws {
        let source = try String(contentsOf: Self.columnSource, encoding: .utf8)
        XCTAssertTrue(source.contains("struct AssistantColumn"),
                      "the census is not reading AssistantColumn.swift")
        XCTAssertTrue(source.contains("ResearchPreview"),
                      "the column no longer hands its research arm to ResearchPreview — "
                      + "if that is deliberate, this census needs re-making, not deleting")
    }

    static var columnSource: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Maugham/Views/AssistantColumn.swift")
    }

    // MARK: - Contract: Escape dismisses

    /// **Escape is delivered by the window-scoped local monitor, and by the same
    /// one the canvas uses** — not by a `.keyboardShortcut(.cancelAction)`,
    /// which is a key equivalent and would preempt the binder's inline rename
    /// (tripwire 16) and the find bar in every window the column is open in.
    /// `CanvasEscapeMonitor.disposition` already declines a text responder, a
    /// foreign window and a non-Escape key; reusing it is what buys those three
    /// refusals rather than re-deriving them.
    func test_theMonitorIsInstalledOnlyWhileSomethingIsStudied() {
        let escape = AssistantColumnEscape()
        let model = AssistantColumnModel()

        escape.sync(model: model, window: { nil })
        XCTAssertFalse(escape.isInstalled,
                       "with nothing studied the column must eat no keys at all")

        model.study(aPin())
        escape.sync(model: model, window: { nil })
        XCTAssertTrue(escape.isInstalled)

        model.dismiss()
        escape.sync(model: model, window: { nil })
        XCTAssertFalse(escape.isInstalled,
                       "a monitor left installed goes on swallowing Escape in a window "
                       + "with no column in it")
    }

    /// The monitor's action is a dismissal, and it is read through the model at
    /// EVENT time rather than captured at install time — a closure over a value
    /// captured once is how a second study would go on dismissing the first.
    func test_theMonitorsActionDismissesWhateverIsStudiedNow() {
        let escape = AssistantColumnEscape()
        let model = AssistantColumnModel()
        model.study(aPin())
        escape.sync(model: model, window: { nil })

        model.study(PinnedReference(id: "res-other", kind: .research(itemId: "res-other"),
                                    title: "Another"))
        XCTAssertTrue(escape.performEscape(), "the column claims the key while it exists")
        XCTAssertNil(model.studied)
    }

    func test_escapeIsRefusedWhenNothingIsStudied() {
        let escape = AssistantColumnEscape()
        let model = AssistantColumnModel()
        escape.sync(model: model, window: { nil })

        XCTAssertFalse(escape.performEscape(),
                       "with no column open the key must travel on — a great many "
                       + "responders above want Escape")
    }

    // MARK: - Contract: it mounts, and the close button dismisses

    func test_theColumnNamesWhatIsBeingStudiedAndCanBeClosed() async throws {
        let (url, store) = try await makeProject()
        let model = AssistantColumnModel()
        model.study(PinnedReference(id: "res-note", kind: .research(itemId: "res-note"),
                                    title: "The falls at night"))

        let window = mount(AnyView(
            AssistantColumn(store: store, projectRoot: url, assistant: model)
                .frame(width: 340, height: 500)))

        let strings = allStrings(in: window).joined(separator: "\n")
        XCTAssertTrue(strings.contains("The falls at night"),
                      "the column does not name its subject. Found: \(strings)")

        let close = try findButton(labelled: AssistantColumn.closeLabel, in: window)
        _ = close.perform(NSSelectorFromString("accessibilityPerformPress"))
        pump()
        XCTAssertNil(model.studied)
    }

    // MARK: - Fixtures

    private func aPin() -> PinnedReference {
        PinnedReference(id: "res-note", kind: .research(itemId: "res-note"),
                        title: "The falls at night")
    }

    private func makeProject() async throws -> (URL, ProjectStore) {
        let root = temp.url.appendingPathComponent("Proj-\(UUID().uuidString.prefix(6))")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("manuscript"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("research/palette"),
                               withIntermediateDirectories: true)
        try "Chapter one.".write(to: root.appendingPathComponent("manuscript/c1.md"),
                                 atomically: true, encoding: .utf8)
        try "The water is loud all night.".write(
            to: root.appendingPathComponent("research/the-falls-at-night.md"),
            atomically: true, encoding: .utf8)
        try "Grey, and low over the water.".write(
            to: root.appendingPathComponent("research/palette/act-ii-fog.md"),
            atomically: true, encoding: .utf8)

        let card = ResearchItem(id: "res-card", title: "Act II fog", type: .asset,
                                kind: .document, path: "research/palette/act-ii-fog.md")
        let group = ResearchItem(id: "res-palette", title: "Palette", type: .group,
                                 path: PaletteConvention.folderPath,
                                 children: [card], role: .paletteGroup)
        let note = ResearchItem(id: "res-note", title: "The falls at night", type: .asset,
                                kind: .document, path: "research/the-falls-at-night.md")
        let manifest = ProjectManifest(
            type: .novel, title: "Assistant", author: "A",
            created: Date(), modified: Date(),
            structure: [StructureItem(id: "ch-1", title: "Ch 1", type: .document,
                                      path: "manuscript/c1.md")],
            research: [group, note])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: root.appendingPathComponent("project.maugham.json"))

        return (root, try await ProjectStore.load(from: root))
    }

    // MARK: - Hosting

    private func mount(_ view: AnyView) -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: 360, height: 520)
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
        throw XCTSkip("no button labelled \"\(label)\" was built in this process")
    }
}
