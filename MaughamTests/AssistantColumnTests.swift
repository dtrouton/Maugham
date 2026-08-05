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
/// - **Escape is arbitrated, not raced.** The column and the canvas's dim are
///   two overlays reachable on one window, and both want the key. They register
///   as consumers of the window's ONE `WindowEscapeArbiter` — the same
///   *instance*, which is the correction Task 5's review forced: this file used
///   to say "the same monitor the canvas uses" while creating a second one, and
///   `NSEvent` local monitors resolve last-armed-first, so the two silently
///   starved each other in an order nobody chose.
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

    // MARK: - Contract: Escape dismisses, and it ARBITRATES

    /// **Escape is delivered by a window-scoped local monitor, and the column is
    /// the highest-priority consumer of the ONE the window holds** — not by a
    /// `.keyboardShortcut(.cancelAction)`, which is a key equivalent and would
    /// preempt the binder's inline rename (tripwire 16) and the find bar in every
    /// window the column is open in. `CanvasEscapeMonitor.disposition` already
    /// declines a text responder, a foreign window and a non-Escape key; going
    /// through `WindowEscapeArbiter` is what buys those three refusals rather
    /// than re-deriving them.
    ///
    /// **A real `NSWindow`, not `nil`.** The arbiter is keyed by window, and the
    /// version of this suite that passed `{ nil }` could not have caught the
    /// defect the arbiter exists to fix.
    func test_theColumnWatchesOnlyWhileSomethingIsStudied() {
        let window = makeWindow()
        let escape = AssistantColumnEscape()
        let model = AssistantColumnModel()

        escape.sync(model: model, window: window, isNoChromeOn: false)
        XCTAssertFalse(escape.isInstalled,
                       "with nothing studied the column must eat no keys at all")

        model.study(aPin())
        escape.sync(model: model, window: window, isNoChromeOn: false)
        XCTAssertTrue(escape.isInstalled)

        model.dismiss()
        escape.sync(model: model, window: window, isNoChromeOn: false)
        XCTAssertFalse(escape.isInstalled,
                       "a consumer left registered goes on swallowing Escape in a "
                       + "window with no column in it")
        escape.stop()
    }

    /// The action is a dismissal, and it is read through the model at EVENT time
    /// rather than captured at registration — a closure over a value captured
    /// once is how a second study would go on dismissing the first.
    func test_theEscapeActionDismissesWhateverIsStudiedNow() {
        let window = makeWindow()
        let escape = AssistantColumnEscape()
        let model = AssistantColumnModel()
        model.study(aPin())
        escape.sync(model: model, window: window, isNoChromeOn: false)

        model.study(PinnedReference(id: "res-other", kind: .research(itemId: "res-other"),
                                    title: "Another"))
        XCTAssertTrue(escape.performEscape(), "the column claims the key while it exists")
        XCTAssertNil(model.studied)
        escape.stop()
    }

    func test_escapeIsRefusedWhenNothingIsStudied() {
        let window = makeWindow()
        let escape = AssistantColumnEscape()
        let model = AssistantColumnModel()
        escape.sync(model: model, window: window, isNoChromeOn: false)

        XCTAssertFalse(escape.performEscape(),
                       "with no column open the key must travel on — a great many "
                       + "responders above want Escape")
        escape.stop()
    }

    // MARK: - Contract: the claim lives exactly as long as the column does

    /// **Chrome × Escape — the composition the final review found nobody had
    /// crossed** (C1). Both halves were individually tested: `isPresented`
    /// vetoes on `isNoChromeOn` (`test_theColumnGoesWithTheChrome`) and the
    /// consumer registers while something is studied
    /// (`test_theColumnWatchesOnlyWhileSomethingIsStudied`). Neither asked what
    /// happens when the flag flips with a pin still up.
    ///
    /// It happens by a documented keystroke: ⌘\ takes the chrome, and ⌘⇧F sets
    /// the same flag on the way INTO full screen (`ProjectWindow.toggleFullScreen`,
    /// marked intended). Nothing dismisses the studied pin when the flag flips,
    /// deliberately — the column is meant to come back when the chrome does. So a
    /// consumer keyed on `studied != nil` alone is an INVISIBLE column holding the
    /// window's highest-priority Escape claim: in full screen the exit key
    /// silently discarded the reference and left full screen alone, and in Plan
    /// the dimmed board needed two presses, the first spent on nothing the writer
    /// could see.
    func test_anInvisibleColumnHoldsNoClaimOnEscape() {
        let window = makeWindow()
        let arbiter = WindowEscapeArbiter.arbiter(for: window)
        let escape = AssistantColumnEscape()
        let model = AssistantColumnModel()
        var dimLifted = 0

        model.study(aPin())
        escape.sync(model: model, window: window, isNoChromeOn: false)
        XCTAssertTrue(escape.isInstalled)

        // ⌘\ (or ⌘⇧F). The column leaves the screen; its claim must leave with it.
        escape.sync(model: model, window: window, isNoChromeOn: true)
        XCTAssertFalse(escape.isInstalled,
                       "a column nobody can see is holding the window's "
                       + "highest-priority Escape claim")
        XCTAssertFalse(escape.performEscape(),
                       "the offer must be declined so the key passes on")
        XCTAssertNotNil(model.studied,
                        "Escape discarded the studied reference while the column was "
                        + "off screen — the writer sees nothing happen and finds the "
                        + "pin gone when the chrome comes back")

        // And the next consumer down gets it on the FIRST press, not the second.
        arbiter.register(.canvasDim, claim: { dimLifted += 1; return true })
        XCTAssertTrue(arbiter.offerEscape())
        XCTAssertEqual(dimLifted, 1,
                       "the dim needed two Escapes: the first was eaten by a column "
                       + "that was not on screen")
        XCTAssertNotNil(model.studied)
        arbiter.resign(.canvasDim)

        // Chrome back: the column returns, and so does its claim, with the same
        // reference still up.
        escape.sync(model: model, window: window, isNoChromeOn: false)
        XCTAssertTrue(escape.isInstalled,
                      "the column came back with the chrome and its Escape did not")
        XCTAssertNotNil(model.studied)
        XCTAssertTrue(escape.performEscape())
        XCTAssertNil(model.studied)
        escape.stop()
    }

    /// **Registered exactly when there is a column**, asked over the product of
    /// the two inputs and stated against `isPresented` itself rather than a
    /// second copy of the rule — the two conditions diverging is what C1 *was*.
    func test_theConsumerIsRegisteredExactlyWhenThereIsAColumn() {
        for pin in [nil, aPin()] {
            for noChrome in [false, true] {
                let window = makeWindow()
                let escape = AssistantColumnEscape()
                let model = AssistantColumnModel()
                if let pin { model.study(pin) }

                escape.sync(model: model, window: window, isNoChromeOn: noChrome)
                XCTAssertEqual(
                    escape.isInstalled,
                    AssistantColumn.isPresented(studied: model.studied,
                                                isNoChromeOn: noChrome),
                    "the Escape claim and the column disagree about whether there "
                    + "is a column: studied \(pin?.id ?? "nil"), isNoChromeOn "
                    + "\(noChrome)")
                escape.stop()
            }
        }
    }

    // MARK: - Contract: two overlays, one window, a decided order

    /// **The composition the Task 5 review found nobody had tested.**
    ///
    /// In Plan, clicking a chapter in the tree dims the canvas (slice 3) and ⌘⌥E
    /// then clicking a pin opens the assistant column. Before the arbiter each
    /// owned its own `CanvasEscapeMonitor`; local `NSEvent` monitors run
    /// most-recently-installed-first and a consumed key short-circuits the rest,
    /// so whichever armed LAST took Escape and the other never saw it — decided
    /// by the writer's action order rather than by anyone.
    ///
    /// The rule now: **one Escape sends the reference back and leaves the dim
    /// alone; the next lifts the dim.**
    func test_theFirstEscapeTakesTheColumnAndLeavesTheDim() {
        let window = makeWindow()
        let arbiter = WindowEscapeArbiter.arbiter(for: window)
        let escape = AssistantColumnEscape()
        let model = AssistantColumnModel()
        var dimLifted = 0

        model.study(aPin())
        escape.sync(model: model, window: window, isNoChromeOn: false)
        arbiter.register(.canvasDim, claim: { dimLifted += 1; return true })

        XCTAssertTrue(arbiter.offerEscape(), "the key is used by one of the two")
        XCTAssertNil(model.studied, "the first Escape must send the reference back")
        XCTAssertEqual(dimLifted, 0,
                       "the first Escape reached the dim as well — one press resolving "
                       + "both overlays is exactly what the priority order is for")

        XCTAssertTrue(arbiter.offerEscape(), "the second press is the dim's")
        XCTAssertEqual(dimLifted, 1)

        escape.stop()
        arbiter.resign(.canvasDim)
    }

    /// **The same answer in both arming orders**, which is the difference between
    /// a decision and an accident. The pre-arbiter mechanism gave opposite
    /// answers to these two, and nothing said which was intended.
    func test_theOrderTheTwoArmInDoesNotDecideWhoGetsTheKey() {
        for dimFirst in [true, false] {
            let window = makeWindow()
            let arbiter = WindowEscapeArbiter.arbiter(for: window)
            let escape = AssistantColumnEscape()
            let model = AssistantColumnModel()
            var dimLifted = 0

            model.study(aPin())
            if dimFirst {
                arbiter.register(.canvasDim, claim: { dimLifted += 1; return true })
                escape.sync(model: model, window: window, isNoChromeOn: false)
            } else {
                escape.sync(model: model, window: window, isNoChromeOn: false)
                arbiter.register(.canvasDim, claim: { dimLifted += 1; return true })
            }

            arbiter.offerEscape()
            XCTAssertNil(model.studied, "dim armed first: \(dimFirst)")
            XCTAssertEqual(dimLifted, 0, "dim armed first: \(dimFirst)")

            escape.stop()
            arbiter.resign(.canvasDim)
        }
    }

    /// A consumer that declines passes the offer down rather than swallowing the
    /// key — the column with nothing studied must not starve the dim.
    func test_aDecliningConsumerPassesTheOfferOn() {
        let window = makeWindow()
        let arbiter = WindowEscapeArbiter.arbiter(for: window)
        var dimLifted = 0
        arbiter.register(.assistantColumn, claim: { false })
        arbiter.register(.canvasDim, claim: { dimLifted += 1; return true })

        XCTAssertTrue(arbiter.offerEscape())
        XCTAssertEqual(dimLifted, 1)

        arbiter.resign(.assistantColumn)
        arbiter.resign(.canvasDim)
    }

    /// An Escape nobody claims travels on. Without this the arbiter would be a
    /// key-eater wearing an arbiter's name.
    func test_anEscapeNoConsumerClaimsIsDeclined() {
        let window = makeWindow()
        let arbiter = WindowEscapeArbiter.arbiter(for: window)
        arbiter.register(.assistantColumn, claim: { false })
        XCTAssertFalse(arbiter.offerEscape())
        arbiter.resign(.assistantColumn)
    }

    /// **The census over the priority list.** The order is the design statement;
    /// a case appended without deciding where it belongs is the defect this
    /// whole mechanism was introduced to remove, and `allCases` order is what
    /// `offerEscape` walks.
    func test_theEscapePriorityOrderIsTheDeclaredOne() {
        XCTAssertEqual(WindowEscapeArbiter.Consumer.allCases,
                       [.assistantColumn, .canvasDim],
                       "the assistant column precedes the canvas dim: the column is "
                       + "something the writer opened one gesture ago, the dim is a "
                       + "consequence of a selection made earlier. A new consumer needs "
                       + "a position argued at the enum, not appended here.")
    }

    /// The monitor is removed only when the LAST consumer leaves — a window with
    /// one overlay still open must go on watching. Removing on the first resign
    /// would silently un-arm the dim the moment a reference was dismissed.
    func test_theWindowKeepsWatchingUntilTheLastConsumerLeaves() {
        let window = makeWindow()
        let arbiter = WindowEscapeArbiter.arbiter(for: window)
        arbiter.register(.assistantColumn, claim: { false })
        arbiter.register(.canvasDim, claim: { false })
        XCTAssertTrue(arbiter.isArmed)

        arbiter.resign(.assistantColumn)
        XCTAssertTrue(arbiter.isArmed,
                      "the dim is still up and the window stopped watching for Escape")

        arbiter.resign(.canvasDim)
        XCTAssertFalse(arbiter.isArmed,
                       "a monitor left behind goes on running for a window with no "
                       + "overlay in it")
        XCTAssertFalse(WindowEscapeArbiter.arbiter(for: window).isArmed,
                       "the table handed back an arbiter that is still armed — the "
                       + "entry outlived its last consumer")
    }

    /// The shared table must not accumulate. A leaked entry is a monitor block
    /// still running for a window nobody has an overlay in — invisible until it
    /// eats a key, which is the same failure `CanvasEscapeMonitor`'s own token
    /// discipline exists to prevent, one level up.
    func test_theArbiterTableDoesNotAccumulateArmedWindows() {
        let before = WindowEscapeArbiter.armedWindowCount
        let window = makeWindow()
        let arbiter = WindowEscapeArbiter.arbiter(for: window)
        arbiter.register(.assistantColumn, claim: { false })
        XCTAssertEqual(WindowEscapeArbiter.armedWindowCount, before + 1)

        arbiter.resign(.assistantColumn)
        XCTAssertEqual(WindowEscapeArbiter.armedWindowCount, before,
                       "an armed arbiter survived its last consumer")
    }

    /// **A real Escape, through `NSApp.sendEvent`** — the delivery path, because
    /// `NSWindow.sendEvent` bypasses local monitors entirely and a test written
    /// that way cannot see this mechanism at all
    /// (`CanvasEscapeMonitor`'s own doc records the measurement).
    func test_aRealEscapeThroughTheApplicationReachesTheColumnFirst() throws {
        let window = makeWindow()
        window.makeKeyAndOrderFront(nil)
        let arbiter = WindowEscapeArbiter.arbiter(for: window)
        let escape = AssistantColumnEscape()
        let model = AssistantColumnModel()
        var dimLifted = 0

        model.study(aPin())
        escape.sync(model: model, window: window, isNoChromeOn: false)
        arbiter.register(.canvasDim, claim: { dimLifted += 1; return true })

        NSApp.sendEvent(escapeKeyEvent(for: window))
        pump(0.3)

        XCTAssertNil(model.studied,
                     "a real Escape did not reach the column through the monitor")
        XCTAssertEqual(dimLifted, 0, "and it must not have reached the dim as well")

        escape.stop()
        arbiter.resign(.canvasDim)
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

    /// A bare window for the escape tests. Tracked like a mounted one so
    /// `tearDown` empties it — a window outliving its test keeps an arbiter
    /// entry alive in the shared table.
    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSView(frame: .zero)
        windows.append(window)
        return window
    }

    /// A real Escape, built the way AppKit delivers one —
    /// `CanvasViewMountingTests.escapeKeyEvent`'s shape, and the window number is
    /// what lets the local monitor's own-window refusal recognise it.
    private func escapeKeyEvent(for window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil,
                         characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
                         isARepeat: false, keyCode: 53)!
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
