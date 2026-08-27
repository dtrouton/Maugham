import XCTest
import AppKit
import ApplicationServices
import SwiftUI
import Observation
import MaughamCore
@testable import Maugham

/// The assistant column (M2 spec §6.2, reshaped by the 2026-08-25 spec §3.2) —
/// **one** studied reference, in the window's RIGHT column, in place of the pane
/// picker and the pane.
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
/// - **It has no width of its own.** It takes the right column's, which is why
///   nothing here measures one any more — see the fourth-column section below,
///   and `StudyColumnMountTests` for the measurement that the prose beside it
///   does not move.
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
    //
    // The predicate below is what `ProjectWindow.detailColumn`'s FIRST arm asks
    // (spec §3.2) — it used to be what `AssistantColumnModifier`'s `HStack`
    // asked, and the rule did not change when the column moved. What these
    // pin is the decision; `StudyColumnMountTests` is what pins that the arm
    // reading it is wired to a column.

    func test_nothingStudiedIsNoColumn() {
        XCTAssertFalse(AssistantColumn.isPresented(studied: nil, persona: .author,
                                                   isNoChromeOn: false,
                                                   showInspector: true))
    }

    func test_aStudiedReferenceMountsTheColumn() {
        XCTAssertTrue(AssistantColumn.isPresented(studied: aPin(), persona: .author,
                                                  isNoChromeOn: false,
                                                  showInspector: true))
    }

    /// **The same flag the intent strip rides** (`isNoChromeOn`, Task 4). ⌘\
    /// takes the chrome, and a studied reference is chrome — the writer asked
    /// for their prose and nothing else. With the column in the RIGHT column
    /// this is what hands the pane picker back rather than what removes a
    /// fourth column: `detailColumn`'s arm falls through to `inspectorPane`.
    func test_theColumnGoesWithTheChrome() {
        XCTAssertFalse(AssistantColumn.isPresented(studied: aPin(), persona: .author,
                                                   isNoChromeOn: true,
                                                   showInspector: true))
    }

    /// **Author and Review both study, Denver's 2026-08-14 ruling (spec §9,
    /// closing the M2-era held decision).** Plan and Publish still veto even
    /// with a pin studied and the chrome on — the column would take
    /// 260–620pt from the canvas §8A.3 protects in Plan, and Publish's
    /// registry never offered a study column at all.
    func test_theColumnPresentsForAuthorAndReviewOnly() {
        for persona: Persona in [.author, .review] {
            XCTAssertTrue(
                AssistantColumn.isPresented(studied: aPin(), persona: persona,
                                            isNoChromeOn: false, showInspector: true),
                "\(persona) studies pins and must present the column")
        }
        for persona: Persona in [.plan, .publish] {
            XCTAssertFalse(
                AssistantColumn.isPresented(studied: aPin(), persona: persona,
                                            isNoChromeOn: false, showInspector: true),
                "\(persona) must not present the column")
        }
    }

    /// Asked over the product rather than down the one path the plan named:
    /// the rule is a conjunction and all FOUR inputs must be able to veto.
    ///
    /// `showInspector` is the fourth (2026-08-25). The column is
    /// `ProjectWindow.detailColumn`'s first arm, which is behind that flag, so
    /// ⌘⌥I is a way of taking the column off screen that the predicate could
    /// not see — see `test_aColumnHiddenByTheRightColumnHoldsNoClaimOnEscape`
    /// for what an unseeing predicate cost.
    func test_thePresentationRuleIsAskedOverAllFourInputs() {
        let expected: [(PinnedReference?, Persona, Bool, Bool, Bool)] = [
            (nil, .author, false, true, false), (nil, .author, true, true, false),
            (aPin(), .author, false, true, true), (aPin(), .author, true, true, false),
            (aPin(), .review, false, true, true), (aPin(), .review, true, true, false),
            (aPin(), .plan, false, true, false), (aPin(), .publish, false, true, false),
            // The fourth input's own column: the same rows that present above,
            // with the right column hidden.
            (aPin(), .author, false, false, false),
            (aPin(), .review, false, false, false),
            (nil, .author, false, false, false),
        ]
        for (studied, persona, noChrome, inspector, wanted) in expected {
            XCTAssertEqual(
                AssistantColumn.isPresented(studied: studied, persona: persona,
                                            isNoChromeOn: noChrome,
                                            showInspector: inspector), wanted,
                "studied: \(studied?.id ?? "nil"), persona: \(persona), "
                + "isNoChromeOn: \(noChrome), showInspector: \(inspector)")
        }
    }

    /// **The census** — `Persona.studiesPinnedReferences` named against all
    /// four personas rather than through the loops above, so a fifth
    /// persona's default answer (the predicate's exhaustive switch has no
    /// `default:`, so it must say "no" explicitly) is asserted here rather
    /// than merely implied by the loops never mentioning it.
    func test_studiesPinnedReferencesCensus() {
        XCTAssertEqual(Persona.allCases.filter(\.studiesPinnedReferences), [.author, .review])
    }

    // MARK: - Contract: the fourth column is gone, and so is its width

    /// **The right column's own width, and no second one.** `UIState`'s
    /// `assistantColumnWidth` / `defaultAssistantColumnWidth` /
    /// `assistantColumnWidthRange` / `clampedAssistantColumnWidth` and
    /// `AssistantColumnModel.width` all died on 2026-08-25 with the fourth
    /// column (spec §3.2) — the compiler is the census on that, since a reader
    /// of any of them will not build.
    ///
    /// What is left to assert is the on-disk half: a `ui-state.json` written by
    /// every build up to v0.31.0 still carries the key, and it must still open.
    /// `CodingKeys` has no case for it any more, and a keyed container never
    /// asks for a key it has no case for — so the value decodes away and is
    /// dropped on the next write, which is what "no migration" (tripwire 11)
    /// means here.
    func test_aFileStillCarryingTheDeadWidthKeyDecodes() throws {
        let json = """
        {"schemaVersion": \(UIState.currentSchemaVersion), \
        "assistantColumnWidth": 400, "detailColumnWidth": 320, \
        "isNoChromeOn": true}
        """
        let decoded = try JSONDecoder().decode(UIState.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.detailColumnWidth, 320,
                       "the dead key must not derail the keys either side of it")
        XCTAssertTrue(decoded.isNoChromeOn)
        XCTAssertEqual(decoded.schemaVersion, UIState.currentSchemaVersion,
                       "and the field's death cost no schema bump — there was "
                       + "nothing to migrate")
    }

    /// The write half of the same fact: what this build encodes carries no
    /// `assistantColumnWidth` at all, so the key really is gone from disk on the
    /// next save rather than merely ignored on load.
    func test_theDeadKeyIsNotWrittenBack() throws {
        let data = try JSONEncoder().encode(UIState(detailColumnWidth: 320))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("assistantColumnWidth"), text)
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

        escape.sync(model: model, window: window, persona: .author,
                    isNoChromeOn: false, showInspector: true)
        XCTAssertFalse(escape.isInstalled,
                       "with nothing studied the column must eat no keys at all")

        model.study(aPin())
        escape.sync(model: model, window: window, persona: .author,
                    isNoChromeOn: false, showInspector: true)
        XCTAssertTrue(escape.isInstalled)

        model.dismiss()
        escape.sync(model: model, window: window, persona: .author,
                    isNoChromeOn: false, showInspector: true)
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
        escape.sync(model: model, window: window, persona: .author,
                    isNoChromeOn: false, showInspector: true)

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
        escape.sync(model: model, window: window, persona: .author,
                    isNoChromeOn: false, showInspector: true)

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
        escape.sync(model: model, window: window, persona: .author,
                    isNoChromeOn: false, showInspector: true)
        XCTAssertTrue(escape.isInstalled)

        // ⌘\ (or ⌘⇧F). The column leaves the screen; its claim must leave with it.
        escape.sync(model: model, window: window, persona: .author,
                    isNoChromeOn: true, showInspector: true)
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
        escape.sync(model: model, window: window, persona: .author,
                    isNoChromeOn: false, showInspector: true)
        XCTAssertTrue(escape.isInstalled,
                      "the column came back with the chrome and its Escape did not")
        XCTAssertNotNil(model.studied)
        XCTAssertTrue(escape.performEscape())
        XCTAssertNil(model.studied)
        escape.stop()
    }

    /// **C1 arriving through a different key** — ⌘⌥I rather than ⌘\.
    ///
    /// The study column is `ProjectWindow.detailColumn`'s FIRST arm since spec
    /// §3.2, so the right column's own visibility is now one of the things that
    /// puts it on screen. `isPresented` did not read it: hiding the right column
    /// with a pin studied left an invisible column holding the window's
    /// highest-priority Escape claim — exactly the shape the final review found
    /// for `isNoChromeOn`, one input later, and it fails the same way. The first
    /// Escape does nothing the writer can see, discards the reference they were
    /// studying, and the consumer below it (the canvas dim, the find bar, a
    /// binder rename) needs a second press.
    ///
    /// **Not a stash.** The study survives the hide; ⌘⌥I back restores it,
    /// which is the same clean cut the persona input made (tripwire 2).
    func test_aColumnHiddenByTheRightColumnHoldsNoClaimOnEscape() {
        let window = makeWindow()
        let arbiter = WindowEscapeArbiter.arbiter(for: window)
        let escape = AssistantColumnEscape()
        let model = AssistantColumnModel()
        var dimLifted = 0

        model.study(aPin())
        escape.sync(model: model, window: window, persona: .author,
                    isNoChromeOn: false, showInspector: true)
        XCTAssertTrue(escape.isInstalled)

        // ⌘⌥I. The right column goes, and the study column goes with it.
        escape.sync(model: model, window: window, persona: .author,
                    isNoChromeOn: false, showInspector: false)
        XCTAssertFalse(escape.isInstalled,
                       "a column the right column took away is holding the "
                       + "window's highest-priority Escape claim")
        XCTAssertFalse(escape.performEscape(),
                       "the offer must be declined so the key passes on")
        XCTAssertNotNil(model.studied,
                        "Escape discarded the studied reference while the "
                        + "column was off screen — the writer sees nothing "
                        + "happen and finds the pin gone when ⌘⌥I brings the "
                        + "column back")

        arbiter.register(.canvasDim, claim: { dimLifted += 1; return true })
        XCTAssertTrue(arbiter.offerEscape())
        XCTAssertEqual(dimLifted, 1,
                       "the consumer below needed two Escapes: the first was "
                       + "eaten by a column that was not on screen")
        arbiter.resign(.canvasDim)

        // ⌘⌥I back: the column returns, the same reference still studied, and
        // Escape is its own again.
        escape.sync(model: model, window: window, persona: .author,
                    isNoChromeOn: false, showInspector: true)
        XCTAssertTrue(escape.isInstalled,
                      "the column came back with the right column and its "
                      + "Escape did not")
        XCTAssertNotNil(model.studied)
        XCTAssertTrue(escape.performEscape())
        XCTAssertNil(model.studied)
        escape.stop()
    }

    /// **The same veto, over persona rather than chrome — now over the two
    /// personas `studiesPinnedReferences` names false.** A writer in Plan or
    /// Publish with a pin studied must not go on holding the window's
    /// highest-priority Escape claim for a column nobody can see — C1's exact
    /// shape, one input later (2026-08-08, widened 2026-08-14 to track the
    /// named predicate rather than a bare `== .author`).
    func test_aNonStudyingPersonaHoldsNoClaimOnEscapeEvenWithTheChromeOn() {
        let window = makeWindow()
        let escape = AssistantColumnEscape()
        let model = AssistantColumnModel()
        model.study(aPin())

        for persona: Persona in [.plan, .publish] {
            escape.sync(model: model, window: window, persona: persona,
                        isNoChromeOn: false, showInspector: true)
            XCTAssertFalse(escape.isInstalled,
                           "\(persona) does not study pins; a claim held there is a "
                           + "claim nobody can see")
            XCTAssertFalse(escape.performEscape(),
                           "the offer must be declined so the key passes on")
            XCTAssertNotNil(model.studied,
                            "the studied pin must survive being invisible in \(persona)")
        }
        escape.stop()
    }

    /// **The mirror of the test above** — Review holds the claim exactly like
    /// Author does, over the two personas `studiesPinnedReferences` names
    /// true.
    func test_aStudyingPersonaHoldsTheEscapeClaim() {
        let window = makeWindow()
        let model = AssistantColumnModel()
        model.study(aPin())

        for persona: Persona in [.author, .review] {
            let escape = AssistantColumnEscape()
            escape.sync(model: model, window: window, persona: persona,
                        isNoChromeOn: false, showInspector: true)
            XCTAssertTrue(escape.isInstalled,
                          "\(persona) studies pins and must hold the Escape claim")
            escape.stop()
        }
    }

    /// **Not dismiss-on-switch.** Leaving Author for a non-studying persona
    /// drops the Escape claim, same as ⌘\, and switching back to Author
    /// restores it with the same reference — the recorded clean cut for the
    /// 2026-08-08 ruling.
    func test_switchingAwayFromAuthorAndBackRestoresTheColumn() {
        let window = makeWindow()
        let escape = AssistantColumnEscape()
        let model = AssistantColumnModel()
        model.study(aPin())

        escape.sync(model: model, window: window, persona: .author,
                    isNoChromeOn: false, showInspector: true)
        XCTAssertTrue(escape.isInstalled)

        escape.sync(model: model, window: window, persona: .plan,
                    isNoChromeOn: false, showInspector: true)
        XCTAssertFalse(escape.isInstalled, "leaving Author must drop the Escape claim")
        XCTAssertNotNil(model.studied,
                        "the studied pin must survive a persona switch away from Author")

        escape.sync(model: model, window: window, persona: .author,
                    isNoChromeOn: false, showInspector: true)
        XCTAssertTrue(escape.isInstalled,
                      "returning to Author must restore the column's claim")
        XCTAssertEqual(model.studied?.id, aPin().id)
        escape.stop()
    }

    /// **Switching between the two studying personas never drops the claim**
    /// — unlike switching to Plan or Publish, which does (test above). Same
    /// function (`isColumnPresented`, asked fresh at every `sync`), a
    /// different fact about it: widening the predicate to Review must not
    /// cost the writer their Escape claim on the way between the two
    /// personas that both study.
    func test_switchingBetweenAuthorAndReviewNeverDropsTheColumn() {
        let window = makeWindow()
        let escape = AssistantColumnEscape()
        let model = AssistantColumnModel()
        model.study(aPin())

        escape.sync(model: model, window: window, persona: .author,
                    isNoChromeOn: false, showInspector: true)
        XCTAssertTrue(escape.isInstalled)

        escape.sync(model: model, window: window, persona: .review,
                    isNoChromeOn: false, showInspector: true)
        XCTAssertTrue(escape.isInstalled,
                      "Review studies pins too; switching to it must not drop the claim")
        XCTAssertNotNil(model.studied)

        escape.sync(model: model, window: window, persona: .author,
                    isNoChromeOn: false, showInspector: true)
        XCTAssertTrue(escape.isInstalled)
        escape.stop()
    }

    /// **Registered exactly when there is a column**, asked over the product of
    /// all FOUR inputs and stated against `isPresented` itself rather than a
    /// second copy of the rule — the conditions diverging is what C1 *was*,
    /// persona is the input the 2026-08-08 ruling added to the same product, and
    /// `showInspector` is the one ⌘⌥I added (2026-08-25).
    ///
    /// The fourth was nailed to `true` on both sides until the whole-branch
    /// review's M4 (2026-08-26), which made this census unable to see the exact
    /// defect class it exists for: a `sync` that stopped reading `showInspector`
    /// while `isPresented` still did would have passed it. Nothing was
    /// unguarded — `test_aColumnHiddenByTheRightColumnHoldsNoClaimOnEscape`
    /// covers that case directly — but a census that pins one of its inputs to a
    /// constant is not asking the question its own comment claims.
    func test_theConsumerIsRegisteredExactlyWhenThereIsAColumn() {
        for pin in [nil, aPin()] {
            for persona in Persona.allCases {
                for noChrome in [false, true] {
                    for inspector in [false, true] {
                        let window = makeWindow()
                        let escape = AssistantColumnEscape()
                        let model = AssistantColumnModel()
                        if let pin { model.study(pin) }

                        escape.sync(model: model, window: window, persona: persona,
                                    isNoChromeOn: noChrome, showInspector: inspector)
                        XCTAssertEqual(
                            escape.isInstalled,
                            AssistantColumn.isPresented(studied: model.studied,
                                                        persona: persona,
                                                        isNoChromeOn: noChrome,
                                                        showInspector: inspector),
                            "the Escape claim and the column disagree about whether "
                            + "there is a column: studied \(pin?.id ?? "nil"), "
                            + "persona \(persona), isNoChromeOn \(noChrome), "
                            + "showInspector \(inspector)")
                        escape.stop()
                    }
                }
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
        escape.sync(model: model, window: window, persona: .author,
                    isNoChromeOn: false, showInspector: true)
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
                escape.sync(model: model, window: window, persona: .author,
                            isNoChromeOn: false, showInspector: true)
            } else {
                escape.sync(model: model, window: window, persona: .author,
                            isNoChromeOn: false, showInspector: true)
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
        TestWindow.present(window, as: .key)
        let arbiter = WindowEscapeArbiter.arbiter(for: window)
        let escape = AssistantColumnEscape()
        let model = AssistantColumnModel()
        var dimLifted = 0

        model.study(aPin())
        escape.sync(model: model, window: window, persona: .author,
                    isNoChromeOn: false, showInspector: true)
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

    // MARK: - Contract: studying reveals the column, and the newest act wins

    /// **Studying a pin while the right column is hidden opens it** (spec §3.2).
    /// The write lives in the window's `.onChange`, never in
    /// `AssistantColumnModel` — the model is window-free, which is the whole
    /// reason it can be handed to a References pane in one column and read by
    /// the column that replaces it.
    ///
    /// **Not a stash/restore pair**, which is tripwire 2's shape: closing the
    /// study leaves the column up showing whatever `detailSegment` still holds,
    /// and ⌘⌥I is one keystroke.
    func test_studyingAPinRevealsTheRightColumn() async throws {
        let probe = StudyChainProbe(showInspector: false)
        mountChain(probe)

        probe.assistant.study(aPin())
        await settleChain()

        XCTAssertTrue(probe.showInspector,
                      "studying a pin with the column hidden must open it — "
                      + "otherwise the click puts the reference nowhere at all")
    }

    /// The converse, and the reason the reveal is keyed on `nil → non-nil`
    /// rather than on any change: dismissing must not re-open a column the
    /// writer closed, and swapping one studied pin for another must not fight
    /// a hidden column back open either.
    func test_dismissingDoesNotTouchTheColumnsVisibility() async throws {
        let probe = StudyChainProbe(showInspector: false)
        mountChain(probe)
        probe.assistant.study(aPin())
        await settleChain()
        XCTAssertTrue(probe.showInspector, "premise: the study opened it")

        probe.showInspector = false
        probe.assistant.dismiss()
        await settleChain()

        XCTAssertFalse(probe.showInspector,
                       "closing a study must not re-open a column the writer "
                       + "has since hidden")
    }

    /// **The newest act wins, over all three of its inputs.** A ⌘⌥-letter is
    /// the writer asking for a pane; a tree click is the writer asking about
    /// something else; a document change makes the shelf's whole premise stale.
    /// `selectedSubject` is the one that is NOT covered by `activeDocId`:
    /// clicking a research row moves the subject and leaves the active document
    /// exactly where it was.
    func test_aNewerActEndsTheStudy() async throws {
        let acts: [(String, (StudyChainProbe) -> Void)] = [
            ("a pane shortcut", { $0.detailSegment = .history }),
            ("a tree click", { $0.selectedSubject = .research("res-other") }),
            ("a document change", { $0.activeDocId = "ch-2" }),
        ]
        for (what, act) in acts {
            let probe = StudyChainProbe(showInspector: true)
            mountChain(probe)
            probe.assistant.study(aPin())
            await settleChain()
            XCTAssertNotNil(probe.assistant.studied, "premise: \(what) begins studied")

            act(probe)
            await settleChain()

            XCTAssertNil(probe.assistant.studied,
                         "\(what) must end the study — the right column cannot "
                         + "show a reference and the thing the writer just asked "
                         + "for at once")
        }
    }

    /// **The picker's own no-op snap keeps the study.**
    ///
    /// Narrowed by Denver's fix-round-1 ruling, which split what used to be one
    /// case in two: a **keystroke** naming the pane already selected is an act
    /// and ends the study (⌘⌥E is precisely what a writer presses to get the
    /// shelf back, and it was inert) — that half is
    /// `AltitudeKeyspaceTests`-shaped and lives at the handler, asserted by
    /// `test_theKeystrokeEndsAStudyEvenWhenItNamesThePaneAlreadyShowing`.
    /// `DetailPaneToggle`'s snap is NOT a keystroke: it writes `segment` only
    /// when it actually snaps, so the no-op case never reaches the chain at
    /// all, and this pins that the chain does not dismiss on a WRITE of an
    /// equal value.
    func test_theNoOpSnapKeepsTheStudy() async throws {
        let probe = StudyChainProbe(showInspector: true)
        probe.detailSegment = .references
        mountChain(probe)
        probe.assistant.study(aPin())
        await settleChain()

        probe.detailSegment = .references
        await settleChain()

        XCTAssertNotNil(probe.assistant.studied,
                        "a write of the value already there is not a newer act")
    }

    /// **A persona change is the recorded exception, driven the way ⌘1–⌘4
    /// actually drives it.**
    ///
    /// The first version of this test moved `probe.persona` alone and was green
    /// while the app was broken — the recorded "one test must model the real
    /// delivery path" defect, found by review. `PersonaModifier` writes
    /// `persona`, `detailSegment` and `showInspector` in ONE pass
    /// (`ProjectWindow.swift`), and `change.segment` is the destination
    /// persona's remembered pane — a different segment on essentially every
    /// switch, since Plan's registry does not contain `.references` at all. So
    /// the pane write is what the study has to survive, and this test makes it.
    func test_aPersonaSwitchHidesTheColumnWithoutEndingTheStudy() async throws {
        let probe = StudyChainProbe(showInspector: true)
        probe.detailSegment = .references
        mountChain(probe)
        probe.assistant.study(aPin())
        await settleChain()

        // ⌘1 — Plan, and Plan's own pane, together.
        probe.persona = .plan
        probe.detailSegment = .inbox
        await settleChain()

        XCTAssertNotNil(probe.assistant.studied,
                        "leaving Author must HIDE the column and keep what is "
                        + "up (spec §3.2) — the pane moved because the persona "
                        + "moved it, which is not the writer asking for a pane")
        XCTAssertFalse(
            AssistantColumn.isPresented(studied: probe.assistant.studied,
                                        persona: probe.persona,
                                        isNoChromeOn: false,
                                        showInspector: true),
            "and it is off screen while they are in Plan")

        // ⌘2 — back, and Author's remembered pane with it. The RETURN leg is
        // the one a presented-ness guard would have got wrong.
        probe.persona = .author
        probe.detailSegment = .references
        await settleChain()

        XCTAssertNotNil(probe.assistant.studied,
                        "switching back restores exactly what was up — "
                        + "`AssistantColumn.isPresented`'s own promise")
        XCTAssertTrue(
            AssistantColumn.isPresented(studied: probe.assistant.studied,
                                        persona: probe.persona,
                                        isNoChromeOn: false,
                                        showInspector: true))
    }

    /// The rule itself, asked over the product of its inputs rather than only
    /// down the two paths the mounted tests drive.
    ///
    /// The fourth row is the one that separates this rule from a presented-ness
    /// guard: a persona change that lands BACK on a studying persona moves the
    /// pane too, and a guard reading `isPresented` with the new persona would
    /// say "present, so dismiss" and take the study away on the return leg.
    func test_thePaneRuleIsAskedOverTheProductOfItsInputs() {
        typealias Pair = AssistantColumnModifier.PersonaPane
        let cases: [(String, Pair, Pair, Bool)] = [
            ("the writer asked for another pane",
             Pair(persona: .author, pane: .references),
             Pair(persona: .author, pane: .diagnostics), true),
            ("the picker wrote the pane already showing",
             Pair(persona: .author, pane: .references),
             Pair(persona: .author, pane: .references), false),
            ("⌘1 out of Author, taking the pane with it",
             Pair(persona: .author, pane: .references),
             Pair(persona: .plan, pane: .inbox), false),
            ("⌘2 back into Author, taking the pane with it",
             Pair(persona: .plan, pane: .inbox),
             Pair(persona: .author, pane: .references), false),
            ("a persona change that happened to keep the pane",
             Pair(persona: .author, pane: .inspector),
             Pair(persona: .review, pane: .inspector), false),
        ]
        for (what, old, new, wanted) in cases {
            XCTAssertEqual(
                AssistantColumnModifier.paneChangeEndsTheStudy(from: old, to: new),
                wanted, what)
        }
    }

    // MARK: - Contract: what the study column costs the pane it replaces

    /// **A pane the writer asked for while studying still reaches
    /// `ui-state.json`** — fix-round 1, review Important 2.
    ///
    /// `DetailPaneToggle`'s `.onChange(of: segment)` is the only writer of
    /// `UIState.detailSegment`, and it cannot fire for a change that predates
    /// its own mount. The study column unmounts that view, so ⌘⌥D while
    /// studying went: segment written → the study dismissed → the toggle
    /// mounted FRESH on `.diagnostics` with nothing left to observe, and the
    /// project reopened on the pane before the one the writer chose. The mount
    /// now persists what it mounted with.
    ///
    /// Driven at the seam rather than through the window: what the defect is
    /// about is a CONDITIONAL mount arriving with the change already applied,
    /// which is exactly what mounting the view on a segment nobody has
    /// persisted reproduces.
    func test_aFreshlyMountedPanePersistsThePaneItMountedWith() async throws {
        let (url, store) = try await makeProject()
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        defer { withExtendedLifetime(ds) {} }
        ds.updateUIState { $0.detailSegment = .inspector }
        await settleChain()
        XCTAssertEqual(ds.uiState.detailSegment, .inspector, "premise")

        // The writer's ⌘⌥D landed while a reference was up: the segment is
        // already `.diagnostics` when this view first appears.
        var segment: DetailSegment = .diagnostics
        var subject: BinderSubject? = .item("ch-1")
        mount(AnyView(DetailPaneToggle(
            store: store,
            segment: Binding(get: { segment }, set: { segment = $0 }),
            selectedSubject: Binding(get: { subject }, set: { subject = $0 }),
            activeManuscriptItemId: "ch-1",
            persona: .author,
            projectURL: url,
            activeDocId: "ch-1",
            documentStore: ds) { Color.clear }
            .frame(width: 320, height: 480)))
        await settleChain()

        XCTAssertEqual(ds.uiState.detailSegment, .diagnostics,
                       "the pane the writer asked for never reached ui-state, "
                       + "so the project would reopen on the previous one")
    }

    /// **A ⌘⌥-letter naming the pane already selected still ends the study** —
    /// Denver's fix-round-1 ruling. The study stands IN PLACE OF the References
    /// pane, so ⌘⌥E is the keystroke a writer presses to get the shelf back,
    /// and leaving it to `detailSegment`'s `.onChange` made it inert: the value
    /// the handler writes is the one already there.
    ///
    /// A source census rather than a mounted assertion, because the handler
    /// lives inside `SessionAndNavigationModifier` on a `ProjectWindow` no test
    /// can reach — the same reason `ReferencesPaneTests`' assembly census is a
    /// census. The planted offender below is what keeps it honest.
    func test_theKeystrokeEndsAStudyEvenWhenItNamesThePaneAlreadyShowing() throws {
        XCTAssertTrue(
            Self.setDetailSegmentHandlerDismissesTheStudy(in: try Self.projectWindowSource()),
            "the `.maughamSetDetailSegment` handler must call `assistant.dismiss()`: "
            + "it writes a segment that is often the one already selected, so "
            + "`.onChange` cannot see it, and ⌘⌥E over a studied reference does "
            + "nothing at all")
    }

    /// The planted offender: without it the census could be reading nothing.
    func test_theKeystrokeCensusCanSeeTheHandlerLoseItsDismiss() throws {
        let stripped = try Self.projectWindowSource()
            .replacingOccurrences(of: "assistant.dismiss()", with: "// removed")
        XCTAssertFalse(Self.setDetailSegmentHandlerDismissesTheStudy(in: stripped),
                       "the census cannot see the dismiss go — it is not reading "
                       + "the handler")
    }

    private static func projectWindowSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Maugham/Views/ProjectWindow.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Does the `.maughamSetDetailSegment` handler dismiss? Read as the body
    /// between that handler's opening line and the next `.onKeyWindowCommand`,
    /// so a `dismiss()` somewhere else in a 4,000-line file cannot answer for
    /// it.
    private static func setDetailSegmentHandlerDismissesTheStudy(in source: String) -> Bool {
        guard let start = source.range(of: ".onKeyWindowCommand(.maughamSetDetailSegment") else {
            return false
        }
        let rest = source[start.upperBound...]
        let end = rest.range(of: ".onKeyWindowCommand(")?.lowerBound ?? rest.endIndex
        return rest[..<end].contains("assistant.dismiss()")
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
        let window = TestWindow.mount(view, size: CGSize(width: 360, height: 520))
        windows.append(window)
        pump()
        return window
    }

    /// A bare window for the escape tests. Tracked like a mounted one so
    /// `tearDown` empties it — a window outliving its test keeps an arbiter
    /// entry alive in the shared table.
    private func makeWindow() -> NSWindow {
        let window = TestWindow.make(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 200),
            contentView: NSView(frame: .zero), present: .unshown)
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

    // MARK: - The chain, mounted

    /// The window state `AssistantColumnModifier` watches, outside the view so a
    /// test can drive it and read the writes back. `@Observable` for the reason
    /// `DetailColumnProbe` is: a `@State` the test cannot reach measures
    /// nothing.
    @Observable
    @MainActor
    final class StudyChainProbe {
        var showInspector: Bool
        var persona: Persona = .author
        var isNoChromeOn = false
        var activeDocId = "ch-1"
        var detailSegment: DetailSegment = .inspector
        var selectedSubject: BinderSubject? = .item("ch-1")
        let assistant = AssistantColumnModel()

        init(showInspector: Bool) { self.showInspector = showInspector }
    }

    /// The modifier applied to a view that draws nothing — which is the whole
    /// point of it since spec §3.2: what it contributes is Escape, the reveal
    /// and the dismisses, and no pixels at all.
    private struct StudyChainHost: View {
        let probe: StudyChainProbe

        var body: some View {
            Color.clear.modifier(AssistantColumnModifier(
                window: nil, isNoChromeOn: probe.isNoChromeOn,
                persona: probe.persona, activeDocId: probe.activeDocId,
                detailSegment: probe.detailSegment,
                selectedSubject: probe.selectedSubject,
                showInspector: Binding(get: { probe.showInspector },
                                       set: { probe.showInspector = $0 }),
                assistant: probe.assistant))
        }
    }

    @discardableResult
    private func mountChain(_ probe: StudyChainProbe) -> NSWindow {
        mount(AnyView(StudyChainHost(probe: probe).frame(width: 200, height: 200)))
    }

    /// `.onChange` runs on the next update pass, not on the write, so every
    /// assertion about the chain waits one out.
    private func settleChain() async {
        for _ in 0..<20 {
            pump(0.02)
            try? await Task.sleep(for: .milliseconds(20))
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
