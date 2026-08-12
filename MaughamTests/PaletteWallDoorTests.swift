import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **The palette wall keeps a door** (shell-finish stage-2b Task 5).
///
/// `.palette` dies with the strip in Task 7, and the wall — the centre-column
/// card-arrangement surface `PaletteWallView` draws — would go dark with it
/// unless something else opens it. This suite is that something: the Palette
/// tree section's own "Open Wall" affordance, `ProjectWindow.showsPaletteWall`,
/// and the routing/stash/close rules built on it.
@MainActor
final class PaletteWallDoorTests: XCTestCase {

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []
    private var documentStores: [DocumentStore] = []

    override func setUp() async throws {
        temp = TempDirectory()
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        for ds in documentStores { await ds.close() }
        documentStores.removeAll()
        temp.cleanup()
        temp = nil
    }

    // MARK: - showsPaletteWallCentre: the routing guard

    func test_showsPaletteWallCentre_trueOutsidePlanWhenOpen() {
        for persona in Persona.allCases where persona != .plan {
            XCTAssertTrue(
                ProjectWindow.showsPaletteWallCentre(showsPaletteWall: true, persona: persona),
                "\(persona)")
        }
    }

    func test_showsPaletteWallCentre_falseInPlanEvenWhenOpen() {
        XCTAssertFalse(
            ProjectWindow.showsPaletteWallCentre(showsPaletteWall: true, persona: .plan),
            "Plan's centre is the canvas — the wall taking it over is stage 3's call")
    }

    func test_showsPaletteWallCentre_falseWhenClosed() {
        for persona in Persona.allCases {
            XCTAssertFalse(
                ProjectWindow.showsPaletteWallCentre(showsPaletteWall: false, persona: persona),
                "\(persona)")
        }
    }

    // MARK: - applyPaletteWallChange: the door's own fold

    func test_applyPaletteWallChange_opensStashesAndHidesTheInspector() {
        var showInspector = true
        var stash: Bool?
        var card: String? = "card-1"
        ProjectWindow.applyPaletteWallChange(
            from: false, to: true, showInspector: &showInspector,
            stash: &stash, selectedPaletteCardId: &card)
        XCTAssertFalse(showInspector)
        XCTAssertEqual(stash, true)
        XCTAssertEqual(card, "card-1", "opening does not disturb a card already selected")
    }

    func test_applyPaletteWallChange_closesRestoresAndForgetsTheCard() {
        var showInspector = false
        var stash: Bool? = true
        var card: String? = "card-1"
        ProjectWindow.applyPaletteWallChange(
            from: true, to: false, showInspector: &showInspector,
            stash: &stash, selectedPaletteCardId: &card)
        XCTAssertTrue(showInspector)
        XCTAssertNil(stash)
        XCTAssertNil(card, "the wall forgets which card it had open")
    }

    /// The takeover case: something else (the canvas collapse) already took the
    /// stash. A `nil` stash on the way out is a real state, not "nothing to
    /// restore" — see `applyPaletteWallChange`'s own doc comment.
    func test_applyPaletteWallChange_aTakenOverStashIsNotResurrected() {
        var showInspector = false
        var stash: Bool?   // already taken over
        var card: String? = "card-1"
        ProjectWindow.applyPaletteWallChange(
            from: true, to: false, showInspector: &showInspector,
            stash: &stash, selectedPaletteCardId: &card)
        XCTAssertFalse(showInspector, "nothing restores over a takeover")
        XCTAssertNil(stash)
        XCTAssertNil(card)
    }

    func test_applyPaletteWallChange_isANoOpWhenNothingChanged() {
        for value in [true, false] {
            var showInspector = true
            var stash: Bool?
            var card: String? = "card-1"
            ProjectWindow.applyPaletteWallChange(
                from: value, to: value, showInspector: &showInspector,
                stash: &stash, selectedPaletteCardId: &card)
            XCTAssertTrue(showInspector, "\(value)")
            XCTAssertNil(stash, "\(value)")
            XCTAssertEqual(card, "card-1", "\(value)")
        }
    }

    // MARK: - The header's door — mounted

    /// **The control for the travel case below**: outside Plan the door is
    /// unchanged — enabled, and its press opens the wall where the writer
    /// already is.
    func test_theHeadersOpenWallButtonFiresTheClosureWhenEnabled() async throws {
        let store = try await novel()
        var opened = false
        let window = try await hostTree(store: store, paletteWallTravels: false) {
            opened = true
        }

        let button = try openWallButton(in: window)
        XCTAssertTrue(
            (axAttribute(button, "accessibilityEnabled") as? Bool) ?? false,
            "premise: the door is enabled outside Plan")
        _ = button.perform(NSSelectorFromString("accessibilityPerformPress"))
        await pumpUntil(deadline: 5) { opened }

        XCTAssertTrue(opened, "the header's door did not reach the closure")
    }

    /// **The door in Plan is LIVE and it travels** (Denver, 2026-08-12) — this
    /// test replaces `test_theHeadersOpenWallButtonIsDisabledInPlan`, which
    /// pinned stage 2b Task 5's placeholder answer: the wall is refused in
    /// Plan (`showsPaletteWallCentre`), so the door was disabled there with a
    /// tooltip saying why. The refusal stands; what changed is what the writer
    /// gets instead of nothing — the door now takes them to Author with the
    /// wall open, so this asserts the button is pressable and reaches its
    /// closure in exactly the persona where it used to refuse to.
    func test_theHeadersOpenWallButtonInPlanIsLiveAndReachesTheDoor() async throws {
        let store = try await novel()
        var opened = false
        let window = try await hostTree(store: store, paletteWallTravels: true) {
            opened = true
        }

        let button = try openWallButton(in: window)
        XCTAssertTrue(
            (axAttribute(button, "accessibilityEnabled") as? Bool) ?? false,
            "the door in Plan must be pressable — it travels rather than "
            + "refusing (a disabled door is what this task removed)")
        _ = button.perform(NSSelectorFromString("accessibilityPerformPress"))
        await pumpUntil(deadline: 5) { opened }

        XCTAssertTrue(opened, "the door in Plan did not reach its closure")
    }

    // MARK: - The door's own press: travel, or open in place

    /// The rule the door's tooltip and its action both read, in ONE spelling —
    /// `TreeTravel.treeTravelDestination`, taken from production rather than
    /// named here. The wall's door is a tree affordance and this is the same
    /// question Denver's tree-travel rule asks: Plan's centre column is the
    /// board, so there is somewhere to travel TO; everywhere else the centre is
    /// already the wall's own column.
    func test_paletteWallDoorTravels_agreesWithTheOneTravelRule() {
        for persona in Persona.allCases {
            XCTAssertEqual(
                ProjectWindow.paletteWallDoorTravels(persona: persona),
                TreeTravel.treeTravelDestination(persona: persona) != nil,
                "\(persona): the door's tooltip and the tree's travel rule must "
                + "not be two spellings of one question")
        }
        XCTAssertTrue(ProjectWindow.paletteWallDoorTravels(persona: .plan),
                      "anti-vacuity: somebody travels")
        XCTAssertFalse(ProjectWindow.paletteWallDoorTravels(persona: .author),
                       "anti-vacuity: somebody does not")
    }

    /// **In Plan the press opens NOTHING yet** — it arms the token and moves the
    /// persona. Opening the wall here would be the bug the ordering exists to
    /// prevent: `PaletteWallModifier`'s persona observer closes the wall on any
    /// persona change, so a wall opened before the switch is a wall the switch
    /// itself shuts.
    func test_pressPaletteWallDoor_inPlanArmsTheTravelAndOpensNothingYet() {
        var persona = Persona.plan
        var segment = DetailSegment.inspector
        var shows = false
        var pending = false

        let change = ProjectWindow.pressPaletteWallDoor(
            persona: &persona, detailSegment: &segment,
            showsPaletteWall: &shows, wallTravelPending: &pending,
            memory: .empty)

        XCTAssertEqual(persona, .author, "the door travels to Author")
        XCTAssertTrue(pending, "the wall's arrival is a token, not an open flag")
        XCTAssertFalse(shows,
                       "the wall must not be opened before the switch — the "
                       + "persona observer would close it again on the way")
        XCTAssertEqual(change?.persona, .author,
                       "the caller needs the change to persist the memory")
    }

    func test_pressPaletteWallDoor_outsidePlanOpensInPlaceAndMovesNobody() {
        for persona in Persona.allCases where !persona.centresTheCanvas {
            var current = persona
            var segment = DetailSegment.inspector
            var shows = false
            var pending = false

            let change = ProjectWindow.pressPaletteWallDoor(
                persona: &current, detailSegment: &segment,
                showsPaletteWall: &shows, wallTravelPending: &pending,
                memory: .empty)

            XCTAssertEqual(current, persona, "\(persona): nobody travels from here")
            XCTAssertTrue(shows, "\(persona): the wall opens where the writer is")
            XCTAssertFalse(pending, "\(persona): no token, nothing to consume")
            XCTAssertNil(change, "\(persona): no persona change to persist")
        }
    }

    // MARK: - applyWallTravelOnPersonaChange: the token's consumption

    func test_applyWallTravelOnPersonaChange_opensTheWallAndConsumesTheToken() {
        var pending = true
        var shows = false
        ProjectWindow.applyWallTravelOnPersonaChange(pending: &pending,
                                                     showsPaletteWall: &shows)
        XCTAssertTrue(shows, "the travelled-to wall opens once the switch landed")
        XCTAssertFalse(pending, "consumed exactly once — a token, not a mode")
    }

    func test_applyWallTravelOnPersonaChange_isANoOpWithNoToken() {
        for open in [true, false] {
            var pending = false
            var shows = open
            ProjectWindow.applyWallTravelOnPersonaChange(pending: &pending,
                                                         showsPaletteWall: &shows)
            XCTAssertEqual(shows, open,
                           "an ordinary persona change must not open the wall")
            XCTAssertFalse(pending)
        }
    }

    // MARK: - Esc closes the wall — a REAL Escape, at the wall's own claim

    /// **The mechanism is `.onExitCommand`, reused from Task 1** — see
    /// `PaletteWallCentre`'s own doc comment for why it needs a focus claim of
    /// its own (nothing here is a text responder, unlike `ProjectSearchView`'s
    /// query field). Driven with a real `.keyDown`, the way AppKit delivers
    /// one, because a test that called `onClose()` directly could not see
    /// whether the key reaches it at all.
    func test_aRealEscapeAtTheWallClosesIt() async throws {
        let store = try await novel()
        var closed = false
        let window = hostKeyWindow(PaletteWallCentre(
            store: store, selectedPaletteCardId: .constant(nil),
            onClose: { closed = true }))
        await waitOut(0.2)   // outlast the 30ms deferred focus claim

        window.sendEvent(Self.escapeKeyEvent(for: window))
        await pumpUntil(deadline: 5) { closed }

        XCTAssertTrue(closed, "a real Escape at the wall did not reach onClose")
    }

    /// **Precedence with the find overlay, measured rather than assumed.**
    /// Both can be open together (find replaces the LEFT column, the wall
    /// takes the CENTRE), and a single Escape has to go somewhere. Find's
    /// query field autofocuses via `DispatchQueue.main.async`; the wall's own
    /// claim is deferred 30ms (tripwire 16's shape) — the slower claim reads
    /// as though it should lose, but measured on a real window (macOS 26.5,
    /// 2026-08-09) it is the WALL that closes: the key window's first
    /// responder lands on the `.focusable()` claim, and find's field, though
    /// present, does not intercept `cancelOperation:` ahead of it. **Pinned
    /// rather than designed**: this is the record of that order, not a
    /// requirement that it stay this way round — if a future SwiftUI changes
    /// it, update the doc comment here alongside the assertions, not just the
    /// assertions. Either way the writer is not trapped: the wall closes,
    /// find is still there for a second Escape.
    func test_aRealEscapeWithBothOpenClosesTheWallFirst() async throws {
        let store = try await novel()
        let ds = try await DocumentStore.open(url: store.url)
        store.documentStore = ds
        documentStores.append(ds)
        var wallClosed = false
        let window = hostKeyWindow(BothOpenProbeView(
            store: store,
            onCloseWall: { wallClosed = true }))
        await pumpUntil(deadline: 5) { self.queryField(in: window) != nil }
        await waitOut(0.2)   // outlast the wall's own deferred claim too

        window.sendEvent(Self.escapeKeyEvent(for: window))
        await pumpUntil(deadline: 5) { wallClosed }

        XCTAssertTrue(wallClosed, "the wall did not close on the shared Escape")
        XCTAssertNotNil(queryField(in: window),
                        "find closed too — the writer is not trapped either way, "
                        + "but this pins the wall going first; if this ever flips, "
                        + "update the doc comment above rather than just the assert")
    }

    // **The census that stood here died with the strip it guarded** (stage
    // 2b Task 7). It asked, by name and with a planted offender, that nothing
    // in the window wrote `binderSegment = .palette` — the segment path the
    // wall's door replaced. `BinderSegment` and the window's `binderSegment`
    // state were deleted together, so the offender cannot be spelled and the
    // compiler is the enforcement; a regex over three files that can no longer
    // match anything is a guard in name only. What survives is everything
    // above: the door is the one way in, and it is mounted, pressed and asked
    // about its enablement rather than grepped for.

    /// The OLD wall mechanism compared segments against `.palette` directly
    /// (`applyPaletteSegmentChange`, `clearsPaletteStash`); both are re-keyed
    /// off `showsPaletteWall`/`Persona` now, so no such comparison should
    /// survive in the window.
    func test_noComparisonAgainstDotPaletteSurvivesInProjectWindow() throws {
        let text = try source("Maugham/Views/ProjectWindow.swift")
        let hits = text.split(separator: "\n").filter {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("///")
                && ($0.contains("== .palette") || $0.contains("!= .palette"))
        }
        XCTAssertTrue(hits.isEmpty,
                      "something still compares a segment against `.palette` — "
                      + "\(hits). `showsPaletteWall` replaced every one of these.")
    }

    /// The subject-change close, wired rather than merely described — a
    /// planted-offender-style existence check, not a behavioural drive: SwiftUI
    /// `.onChange` handlers inside a `private` `ViewModifier` are not reachable
    /// from a test any other way (the same reason the ORIGINAL palette↔canvas
    /// race had no direct mounted test, only the pure-function halves and this
    /// suite's `PromotionCommandTests` sibling's token census).
    func test_theWallModifierClosesOnASubjectChange() throws {
        let text = try source("Maugham/Views/ProjectWindow.swift")
        XCTAssertTrue(
            text.contains(".onChange(of: selectedSubject) { _, _ in")
            && text.contains("if showsPaletteWall { showsPaletteWall = false }"),
            "PaletteWallModifier must close the wall on any subject change — "
            + "the door's own contract")
    }

    // MARK: - A persona change closes the wall, whoever wrote the persona (I3)

    /// **The rule, folded.** Dropping the stash rather than restoring it is what
    /// keeps the exit arm from fighting `PersonaModifier`'s `showInspector =
    /// true` a pass later — see `closePaletteWallOnPersonaChange`'s doc comment.
    func test_closePaletteWallOnPersonaChange_closesAndDropsTheStash() {
        var open = true
        var stash: Bool? = false
        ProjectWindow.closePaletteWallOnPersonaChange(showsPaletteWall: &open,
                                                      stash: &stash)
        XCTAssertFalse(open)
        XCTAssertNil(stash,
                     "a live stash would restore the pre-wall visibility over "
                     + "the switch's own force-open, one pass later")
    }

    func test_closePaletteWallOnPersonaChange_isANoOpWhenTheWallIsShut() {
        var open = false
        var stash: Bool? = true
        ProjectWindow.closePaletteWallOnPersonaChange(showsPaletteWall: &open,
                                                      stash: &stash)
        XCTAssertFalse(open)
        XCTAssertEqual(stash, true,
                       "a closed wall's memory belongs to whoever armed it — "
                       + "this rule only ever cleans up after itself")
    }

    /// **Mounted, on the real modifier**: an `onChange` that does not fire is
    /// indistinguishable from a rule that decided not to act, and only a mount
    /// can tell them apart.
    ///
    /// Both destinations, because the rule this replaced fired for Plan alone —
    /// so a wall opened in Author followed the writer into Review.
    func test_theMountedModifierClosesTheWallOnAnyPersonaChange() async throws {
        for destination in [Persona.plan, .review] {
            let box = WallPersonaBox()
            box.showsPaletteWall = true
            box.stash = true
            let window = hostWallModifier(box: box)
            XCTAssertTrue(box.showsPaletteWall, "premise: the wall is open in Author")

            box.persona = destination
            await pumpUntil(deadline: 5) { !box.showsPaletteWall }

            XCTAssertFalse(box.showsPaletteWall,
                           "→\(destination): the wall belongs to the persona it "
                           + "was opened in")
            XCTAssertNil(box.stash, "→\(destination): and its stash went with it")
            _ = window
        }
    }

    // MARK: - The travel: Plan's door opens the wall in Author (Task 4)

    /// **Mounted, on the real modifier**: the token is consumed INSIDE the same
    /// `.onChange(of: persona)` handler that closes the wall, and AFTER it. Both
    /// halves are load-bearing and this test can tell them apart:
    ///
    /// - a token consumed in a modifier of its own would rest on cross-modifier
    ///   delivery order (tripwire 2's shape);
    /// - a token consumed BEFORE `closePaletteWallOnPersonaChange` would open
    ///   the wall and have the close shut it in the same pass — the wall would
    ///   never appear, and this assertion would be red.
    func test_theMountedModifierOpensTheTravelledWallAfterTheCloseHasRun() async throws {
        let box = WallPersonaBox()
        box.persona = .plan
        box.showInspector = true
        box.wallTravelPending = true            // the door in Plan armed it
        _ = hostWallModifier(box: box)
        XCTAssertFalse(box.showsPaletteWall, "premise: no wall in Plan")

        box.persona = .author                   // the switch lands
        await pumpUntil(deadline: 5) { box.showsPaletteWall }

        XCTAssertTrue(box.showsPaletteWall,
                      "the travelled-to wall never opened — the token is "
                      + "consumed after the close, in the same handler")
        XCTAssertFalse(box.wallTravelPending, "the token is consumed")
        // …and the wall's own open arm ran over it, exactly as a door pressed
        // in Author would have made it run.
        await pumpUntil(deadline: 5) { !box.showInspector }
        XCTAssertFalse(box.showInspector,
                       "the open arm hides the right column so the wall gets width")
        XCTAssertEqual(box.stash, true, "…and remembers what it hid")
    }

    /// **Consumed exactly once.** The contract's own case: travel to Author,
    /// then ⌘1 back to Plan and ⌘2 out again — the wall must not reappear. A
    /// token left armed would make every later persona change open the wall.
    func test_theTravelTokenIsConsumedOnceAndDoesNotFollowTheWriterAround() async throws {
        let box = WallPersonaBox()
        box.persona = .plan
        box.wallTravelPending = true
        _ = hostWallModifier(box: box)

        box.persona = .author
        await pumpUntil(deadline: 5) { box.showsPaletteWall }
        XCTAssertTrue(box.showsPaletteWall, "premise: the travel landed")

        box.persona = .plan                     // ⌘1 — the wall closes with it
        await pumpUntil(deadline: 5) { !box.showsPaletteWall }
        XCTAssertFalse(box.showsPaletteWall, "premise: a persona change closes it")

        box.persona = .author                   // ⌘2 — and it stays closed
        await waitOut(0.3)
        XCTAssertFalse(box.showsPaletteWall,
                       "the wall came back on a later persona change — the "
                       + "travel token is a one-shot, not a mode")
    }

    /// **The whole door, end to end, through production's own two halves**: the
    /// real "Open Wall" button in a tree mounted in Plan, whose closure is
    /// `ProjectWindow.pressPaletteWallDoor` (the same function
    /// `ProjectWindow.openPaletteWall` calls), over the real
    /// `PaletteWallModifier`. Nothing here re-states a rule: the press decides,
    /// the observer consumes.
    ///
    /// The two routing consequences are then read off the pure functions that
    /// own them rather than re-derived — `showsPaletteWallCentre` (the wall
    /// covers the centre) and `showsStatusFooter` (the manuscript footer goes
    /// silent under it, `ResearchSubjectRoutingTests`' rule).
    func test_pressingTheDoorInPlanLandsTheWriterInAuthorWithTheWallOpen() async throws {
        let store = try await novel()
        let box = WallPersonaBox()
        box.persona = .plan
        let window = try await hostTravelProbe(store: store, box: box)

        try clickTheDoor(in: window)
        await pumpUntil(deadline: 5) { box.persona == .author && box.showsPaletteWall }

        XCTAssertEqual(box.persona, .author, "the door did not travel")
        XCTAssertTrue(box.showsPaletteWall, "the writer arrived without the wall")
        XCTAssertTrue(
            ProjectWindow.showsPaletteWallCentre(showsPaletteWall: box.showsPaletteWall,
                                                 persona: box.persona),
            "the wall must actually cover the centre where it landed")
        XCTAssertFalse(
            ProjectWindow.showsStatusFooter(persona: box.persona,
                                            subject: .item("doc1"),
                                            showsPaletteWall: box.showsPaletteWall,
                                            publishPreview: .nothingCompiled,
                                            structure: [StructureItem(
                                                id: "doc1", title: "One",
                                                type: .document,
                                                path: "manuscript/one.md")]),
            "the manuscript footer must be silent under the travelled-to wall")
        XCTAssertNil(box.subject,
                     "the travel writes NO subject — a subject change is the "
                     + "modifier's own second observer and would close the wall "
                     + "it just opened")
        await pumpUntil(deadline: 5) { !box.showInspector }
        XCTAssertFalse(box.showInspector,
                       "the open arm did not run over the arrival")
    }

    /// The door's control, one layer up from the button's own: pressed OUTSIDE
    /// Plan it opens the wall in place and writes no persona at all.
    func test_pressingTheDoorInAuthorOpensInPlaceAndTravelsNowhere() async throws {
        let store = try await novel()
        let box = WallPersonaBox()
        box.persona = .author
        let window = try await hostTravelProbe(store: store, box: box)

        try clickTheDoor(in: window)
        await pumpUntil(deadline: 5) { box.showsPaletteWall }

        XCTAssertTrue(box.showsPaletteWall, "the door in Author opens in place")
        XCTAssertEqual(box.persona, .author, "and moves nobody")
        XCTAssertFalse(box.wallTravelPending, "and arms nothing")
    }

    /// **The window's own wiring**, which no assertion above can see: both
    /// tree shells' `onOpenPaletteWall` closures must reach the door's decision
    /// rather than writing `showsPaletteWall = true` themselves. Reverting
    /// either one leaves every test above green and the door in Plan silently
    /// opening a wall that `showsPaletteWallCentre` refuses to draw.
    func test_bothTreeShellsReachTheDoorRatherThanTheFlag() throws {
        let text = Self.codeOnly(try source("Maugham/Views/ProjectWindow.swift"))
        let presses = text.split(separator: "\n").filter {
            $0.contains("onOpenPaletteWall:")
        }
        XCTAssertEqual(presses.count, 2,
                       "the two tree shells (standard + Collection) are the "
                       + "door's only mount sites — found \(presses)")
        for line in presses {
            XCTAssertTrue(line.contains("openPaletteWall()"),
                          "a tree shell writes the wall flag directly: \(line)")
        }
    }

    /// **Bypass 2, through the real writer.** `ManuscriptNavigation.go` moves the
    /// persona for a wiki-link click and never touches `PersonaModifier`, where
    /// the old wall rule lived — so this drives production's own function against
    /// the mounted observer.
    func test_aNavigationJumpClosesTheWallItWouldOtherwiseCarryAcross() async throws {
        let box = WallPersonaBox()
        // Plan with the wall armed — the very state the old rule let a bypass
        // produce, and the only one a jump can move the persona OUT of (a jump
        // from a persona that already centres a document moves nobody).
        box.persona = .plan
        box.showsPaletteWall = true
        box.stash = true
        _ = hostWallModifier(box: box)

        let destination = ManuscriptNavigation.destination(
            from: box.persona, currentDetailSegment: .inspector, memory: .empty)
        XCTAssertTrue(destination.movesPersona, "premise: this jump moves the persona")
        ManuscriptNavigation.go(
            to: destination,
            persona: Binding(get: { box.persona }, set: { box.persona = $0 }),
            detailSegment: Binding(get: { box.detailSegment },
                                   set: { box.detailSegment = $0 }),
            documentStore: nil)
        await pumpUntil(deadline: 5) { !box.showsPaletteWall }

        XCTAssertFalse(box.showsPaletteWall,
                       "a wiki-link jump moved the writer to Author with the wall "
                       + "still over the centre column")
        XCTAssertNil(box.stash)
    }

    /// **Bypass 1**, as close as its private `show` allows: the persona it
    /// writes is `CanvasClaudeArrivalModifier.destination(forRegion:)`'s, taken
    /// from production rather than named here, and driven into the same mounted
    /// observer. The census below is the other half — that Show writes the
    /// persona directly and closes nothing itself.
    func test_aClaudeArrivalClosesTheWallItWouldOtherwiseCarryAcross() async throws {
        let box = WallPersonaBox()
        box.showsPaletteWall = true
        box.stash = true
        _ = hostWallModifier(box: box)

        box.persona = CanvasClaudeArrivalModifier
            .destination(forRegion: CanvasRegionID("r1")).persona
        await pumpUntil(deadline: 5) { !box.showsPaletteWall }

        XCTAssertFalse(box.showsPaletteWall,
                       "Show took the writer to Plan with the wall still armed — "
                       + "it hides itself there and is back over Author's centre "
                       + "the moment they press ⌘2")
        XCTAssertNil(box.stash)
    }

    /// **The falsifier for the two above**: neither bypass closes the wall
    /// itself, and neither goes through the persona handler that used to. If one
    /// of them grows its own close, this assertion says so — two rules about one
    /// piece of state is the drift the observer exists to prevent.
    func test_neitherBypassWriterClosesTheWallItself() throws {
        for path in ["Maugham/Views/CanvasClaudeArrivalModifier.swift",
                     "Maugham/Views/ManuscriptNavigation.swift",
                     "Maugham/Views/TreeTravel.swift"] {
            let text = Self.codeOnly(try source(path))
            XCTAssertTrue(text.contains("persona"),
                          "\(path): premise — this file writes the window's persona")
            XCTAssertFalse(text.contains("showsPaletteWall"),
                           "\(path): a second wall rule has appeared beside "
                           + "`closePaletteWallOnPersonaChange` — one observer of "
                           + "the persona covers every writer, and a census of "
                           + "writers is what this fix removed")
        }
        // Comment-stripped, because the replaced predicate is NAMED in the
        // comment that records its removal — a census over prose would fail on
        // its own explanation.
        let window = Self.codeOnly(try source("Maugham/Views/ProjectWindow.swift"))
        XCTAssertFalse(window.contains("clearsPaletteWallStash"),
                       "the Plan-only predicate is back in the persona handler, "
                       + "which two of the three persona writers never reach")
    }

    /// Source with `//` and `///` lines dropped — the shape
    /// `test_noComparisonAgainstDotPaletteSurvivesInProjectWindow` already uses
    /// inline, lifted out because two censuses here need it.
    private static func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    // MARK: - Fixtures

    private func novel() async throws -> ProjectStore {
        let url = try await ProjectFactory.createNovelProject(
            named: "Novel-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        documentStores.append(ds)
        await store.wordCountPopulationTask?.value
        return store
    }

    // MARK: - Hosting and driving

    /// **A window that reports itself key**, `TreeFindOverlayTests.KeyTestWindow`'s
    /// reason verbatim: `.maughamCloseFind` is key-window scoped and this suite
    /// sends real key events, which beep against a window that never becomes key.
    private final class KeyTestWindow: SilentTestWindow {
        override var isKeyWindow: Bool { true }
    }

    private func hostTree(
        store: ProjectStore, paletteWallTravels: Bool, onOpenPaletteWall: @escaping () -> Void
    ) async throws -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: 320, height: 800)
        let hosting = NSHostingView(rootView: AnyView(DoorProbeView(
            store: store, paletteWallTravels: paletteWallTravels,
            onOpenPaletteWall: onOpenPaletteWall)))
        hosting.frame = frame
        let window = SilentTestWindow(contentRect: frame, styleMask: [.titled],
                                      backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        await pumpUntil(deadline: 5) { self.firstTableView(in: window) != nil }
        pump(0.2)
        return window
    }

    /// The real door and the real `PaletteWallModifier` over one box — the two
    /// production halves of the travel, and nothing standing in for either.
    private func hostTravelProbe(
        store: ProjectStore, box: WallPersonaBox
    ) async throws -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: 320, height: 800)
        let hosting = NSHostingView(rootView: AnyView(
            TravelProbeView(store: store, box: box)))
        hosting.frame = frame
        let window = SilentTestWindow(contentRect: frame, styleMask: [.titled],
                                      backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        await pumpUntil(deadline: 5) { self.firstTableView(in: window) != nil }
        pump(0.2)
        return window
    }

    /// The real `PaletteWallModifier` over a box the test drives, on a view with
    /// nothing else in it — the observer is the whole subject, so anything else
    /// mounted here could only supply another explanation for a closed wall.
    @discardableResult
    private func hostWallModifier(box: WallPersonaBox) -> NSWindow {
        let window = hostKeyWindow(WallPersonaProbeView(box: box))
        pump(0.1)
        return window
    }

    private func hostKeyWindow(_ view: some View) -> NSWindow {
        let frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = frame
        let window = KeyTestWindow(contentRect: frame, styleMask: [.titled],
                                   backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        pump(0.15)
        return window
    }

    /// A real Escape, built the way AppKit delivers one —
    /// `TreeFindOverlayTests.escapeKeyEvent`'s shape.
    private static func escapeKeyEvent(for window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil,
                         characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
                         isARepeat: false, keyCode: 53)!
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: - Reading the hierarchy

    private func firstTableView(in window: NSWindow) -> NSTableView? {
        guard let root = window.contentView else { return nil }
        var found: [NSTableView] = []
        collect(NSTableView.self, in: root, into: &found)
        return found.first
    }

    private func queryField(in window: NSWindow) -> NSTextField? {
        guard let root = window.contentView else { return nil }
        var found: [NSTextField] = []
        collect(NSTextField.self, in: root, into: &found)
        return found.first { $0.placeholderString == "Find in project" }
    }

    private func collect<T: NSView>(_ type: T.Type, in view: NSView, into out: inout [T]) {
        if let hit = view as? T { out.append(hit) }
        for sub in view.subviews { collect(type, in: sub, into: &out) }
    }

    /// The "Open Wall" button, found by the accessibility label
    /// `BinderTreeSections.openWallButton` carries. `TreeFindOverlayTests
    /// .closeButton`'s shape verbatim: the retry loop is because SwiftUI builds
    /// the tree lazily, and the skip is because it builds no tree at all unless
    /// an assistive client is attached.
    private func openWallButton(in window: NSWindow) throws -> NSObject {
        for _ in 0..<10 {
            let tree = try axTree(in: window)
            if let hit = tree.first(where: {
                (axAttribute($0, "accessibilityRole") as? String) == "AXButton"
                    && ((axAttribute($0, "accessibilityLabel") as? String) ?? "")
                        == "Open Wall"
            }) as? NSObject {
                return hit
            }
            pump(0.1)
        }
        throw XCTSkip("no button labelled \"Open Wall\" was built in this process")
    }

    /// **A real mouse click on the door**, because the accessibility route
    /// above skips in any process no assistive client attaches to — which is
    /// every process this suite has ever run in. The travel is the load-bearing
    /// behaviour of stage 3b Task 4 and it cannot be pinned by a test that
    /// skips, so the two end-to-end cases drive the door the way a writer does.
    ///
    /// It also subsumes the enablement claim the AX assertions make: a disabled
    /// `Button` swallows a click, so a press that reaches its action proves the
    /// door is live in the persona it was pressed in.
    ///
    /// **Finding the door**: `PaletteWallDoorHitAreaTests.doorGeometry`'s
    /// structural discriminator, in miniature — the Palette header is the one
    /// carrying TWO buttons (the door and its chevron) where Research carries a
    /// chevron alone, and within it the door is the leftmost. Identifying it by
    /// position in the window instead is what silently measured the Research
    /// chevron when the chevrons landed.
    private func clickTheDoor(in window: NSWindow) throws {
        let content = try XCTUnwrap(window.contentView)
        let headers = allViews(in: content).filter {
            String(describing: type(of: $0)).contains("ListTableHeaderView")
        }
        let ringsByHeader = headers.map { header in
            allViews(in: header)
                .filter { String(describing: type(of: $0)).contains("FocusRing") }
                .sorted { $0.convert($0.bounds, to: content).minX
                          < $1.convert($1.bounds, to: content).minX }
        }
        guard let palette = ringsByHeader.filter({ $0.count >= 2 })
                .max(by: { $0.count < $1.count }),
              let ring = palette.first
        else {
            throw XCTSkip(
                "this display mounted \(headers.count) section headers carrying "
                + "\(ringsByHeader.map(\.count)) buttons — no Palette header "
                + "with a door beside its chevron to click")
        }
        let icon = ring.convert(ring.bounds, to: content)
        try XCTSkipUnless(icon.height > 1 && icon.width > 1,
                          "this display mounted a door of \(icon.size)")
        let inWindow = content.convert(CGPoint(x: icon.midX, y: icon.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: type, location: inWindow, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0) {
                window.sendEvent(event)
            }
        }
        pump(0.05)
    }

    private func allViews(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { allViews(in: $0) }
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
    /// attached to the process. `TreeFindOverlayTests`' guard, verbatim.
    private func axTree(in window: NSWindow) throws -> [AnyObject] {
        var role: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(getpid()), kAXRoleAttribute as CFString, &role)
        guard error == .success, role != nil else {
            throw XCTSkip(
                "no assistive client could be attached to this process, so "
                + "SwiftUI builds no accessibility tree to press a button in")
        }
        guard let root = window.contentView else { return [] }
        return axElements(under: root)
    }
}

// MARK: - Probes

/// Mounts `BinderView` with the door's two new parameters wired to a probe —
/// the minimal shape that puts the Palette section's header on screen.
@MainActor
private struct DoorProbeView: View {
    let store: ProjectStore
    let paletteWallTravels: Bool
    let onOpenPaletteWall: () -> Void
    @State private var subject: BinderSubject?
    let treeState = BinderTreeSectionsState()

    var body: some View {
        BinderView(store: store, selectedSubject: $subject,
                   treeState: treeState,
                   paletteWallTravels: paletteWallTravels,
                   onOpenPaletteWall: onOpenPaletteWall)
    }
}

/// The door and the wall's observer over one box, wired the way `ProjectWindow`
/// wires them: the tree's `paletteWallTravels` and the press both come from
/// production (`ProjectWindow.paletteWallDoorTravels` /
/// `ProjectWindow.pressPaletteWallDoor`), and the modifier is the real one.
/// The only thing this probe supplies is the window state, which lives in
/// `ProjectWindow`'s `@State` and is not reachable any other way.
@MainActor
private struct TravelProbeView: View {
    let store: ProjectStore
    let box: WallPersonaBox
    let treeState = BinderTreeSectionsState()

    var body: some View {
        BinderView(
            store: store,
            selectedSubject: Binding(get: { box.subject },
                                     set: { box.subject = $0 }),
            treeState: treeState,
            paletteWallTravels: ProjectWindow.paletteWallDoorTravels(
                persona: box.persona),
            onOpenPaletteWall: {
                _ = ProjectWindow.pressPaletteWallDoor(
                    persona: &box.persona,
                    detailSegment: &box.detailSegment,
                    showsPaletteWall: &box.showsPaletteWall,
                    wallTravelPending: &box.wallTravelPending,
                    memory: .empty)
            })
        .modifier(ProjectWindow.PaletteWallModifier(
            showsPaletteWall: Binding(get: { box.showsPaletteWall },
                                      set: { box.showsPaletteWall = $0 }),
            showInspector: Binding(get: { box.showInspector },
                                   set: { box.showInspector = $0 }),
            inspectorWasVisibleBeforePalette: Binding(get: { box.stash },
                                                      set: { box.stash = $0 }),
            selectedPaletteCardId: Binding(get: { box.selectedCardId },
                                           set: { box.selectedCardId = $0 }),
            selectedSubject: Binding(get: { box.subject },
                                     set: { box.subject = $0 }),
            wallTravelPending: Binding(get: { box.wallTravelPending },
                                       set: { box.wallTravelPending = $0 }),
            persona: box.persona))
    }
}

/// Find's overlay in the left column and the wall in the centre, together —
/// `test_aRealEscapeWithBothOpenClosesFindFirst`'s fixture. `treeFindActive`
/// is `@State` here rather than threaded through `BinderPaneToggle`'s whole
/// production wiring: the test is about which `.onExitCommand` a shared
/// Escape reaches, not about how `⌘⌥F` sets the flag.
@MainActor
private struct BothOpenProbeView: View {
    @Bindable var store: ProjectStore
    let onCloseWall: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ProjectSearchView(store: store)
                .frame(width: 160)
            PaletteWallCentre(store: store, selectedPaletteCardId: .constant(nil),
                              onClose: onCloseWall)
        }
    }
}

/// The window state the wall's persona rule reads and writes, held outside the
/// view so a test can drive the persona the way any of its three production
/// writers does. At file scope because `@Observable` cannot expand inside a
/// `private` nested type.
@Observable
@MainActor
final class WallPersonaBox {
    var persona: Persona = .author
    var detailSegment: DetailSegment = .inspector
    var showsPaletteWall = false
    /// The travel token (Task 4): armed by the door pressed in Plan, consumed
    /// by `PaletteWallModifier`'s persona observer once the switch has landed.
    var wallTravelPending = false
    var showInspector = true
    var stash: Bool?
    var selectedCardId: String?
    var subject: BinderSubject?
    init() {}
}

/// The REAL `ProjectWindow.PaletteWallModifier`, applied to nothing — the
/// observer is the subject, and a view with content in it could close the wall
/// for some other reason and read the same from outside.
@MainActor
private struct WallPersonaProbeView: View {
    let box: WallPersonaBox

    var body: some View {
        Color.clear
            .modifier(ProjectWindow.PaletteWallModifier(
                showsPaletteWall: Binding(get: { box.showsPaletteWall },
                                          set: { box.showsPaletteWall = $0 }),
                showInspector: Binding(get: { box.showInspector },
                                       set: { box.showInspector = $0 }),
                inspectorWasVisibleBeforePalette: Binding(get: { box.stash },
                                                          set: { box.stash = $0 }),
                selectedPaletteCardId: Binding(get: { box.selectedCardId },
                                               set: { box.selectedCardId = $0 }),
                selectedSubject: Binding(get: { box.subject },
                                         set: { box.subject = $0 }),
                wallTravelPending: Binding(get: { box.wallTravelPending },
                                           set: { box.wallTravelPending = $0 }),
                persona: box.persona))
    }
}
