import XCTest
import AppKit
import SwiftUI
@testable import Maugham

/// The command that reaches the sheet. **The delivery path is the subject**:
/// this area has shipped a whole feature nothing could reach (1C-a's ⌘Z, built
/// and twenty-two tests deep, greyed out in the Edit menu), and the lesson from
/// the mode-UX milestone is that anything with a menu item or a key equivalent
/// needs one test that models the real path.
@MainActor
final class PromotionCommandTests: XCTestCase {

    private let a = CanvasNodeID("a")

    // MARK: - Enablement

    func test_theCommandIsOfferedOnlyOnTheCanvasWithSomethingSelected() {
        let model = CanvasModel()
        XCTAssertFalse(CanvasPromotionModifier.isPromotable(binderSegment: .canvas,
                                                            selection: model.selection,
                                                            nodeKind: nil))
        XCTAssertTrue(CanvasPromotionModifier.isPromotable(binderSegment: .canvas,
                                                           selection: .node(a),
                                                           nodeKind: .scrap))
        XCTAssertFalse(CanvasPromotionModifier.isPromotable(binderSegment: .manuscript,
                                                            selection: .node(a),
                                                            nodeKind: .scrap),
                       "the manuscript editor has no canvas selection to promote")
        XCTAssertFalse(CanvasPromotionModifier.isPromotable(
            binderSegment: .research, selection: .region(CanvasRegionID("r")), nodeKind: nil))
    }

    /// A REFERENCED item node already exists as itself, so `Promotion.targets`
    /// offers it nothing — but this said yes for every `.node`, so `Promote…` was
    /// enabled and ⌘⇧↩ opened a sheet that could never commit and (until finding
    /// 4) said nothing about why.
    ///
    /// The control is the line above the refusal: the same selection with a
    /// scrap's kind is promotable, so this is about the KIND and not about the
    /// selection case.
    func test_aReferencedItemNodeIsNotPromotableBecauseItAlreadyExistsAsItself() {
        XCTAssertTrue(CanvasPromotionModifier.isPromotable(
            binderSegment: .canvas, selection: .node(a), nodeKind: .scrap))
        XCTAssertFalse(CanvasPromotionModifier.isPromotable(
            binderSegment: .canvas, selection: .node(a),
            nodeKind: .item(.project(id: "r-9"))))
        XCTAssertFalse(CanvasPromotionModifier.isPromotable(
            binderSegment: .canvas, selection: .node(a), nodeKind: nil),
            "a selection naming a node the scene no longer holds resolves to no "
            + "kind, and an enabled command with nothing behind it is the "
            + "condition the flag exists to prevent")
    }

    /// **And an OWNED one is** (spec §6's 2026-07-30 amendment, Task 8): it
    /// exists nowhere but the canvas, so the refusal above was never about it,
    /// and a greyed-out `Promote…` strands the photograph the writer just sent
    /// there. The kind is what carries the provenance, which is why this reads
    /// the same argument the refusal above does.
    func test_anOwnedItemNodeIsPromotable() {
        XCTAssertTrue(CanvasPromotionModifier.isPromotable(
            binderSegment: .canvas, selection: .node(a),
            nodeKind: .item(.owned(path: "canvas_assets/image-20260730-121314.png"))))
        XCTAssertFalse(CanvasPromotionModifier.isPromotable(
            binderSegment: .research, selection: .node(a),
            nodeKind: .item(.owned(path: "canvas_assets/image-20260730-121314.png"))),
            "the control: the segment guard still runs first — this is not an "
            + "escape hatch past it")
    }

    /// A region and a line carry no node kind, so the kind term must not reach
    /// them — passing nil for a region is the ordinary case, not a defect.
    func test_theNodeKindTermDoesNotReachARegionOrALine() {
        XCTAssertTrue(CanvasPromotionModifier.isPromotable(
            binderSegment: .canvas, selection: .region(CanvasRegionID("r")), nodeKind: nil))
        XCTAssertTrue(CanvasPromotionModifier.isPromotable(
            binderSegment: .canvas, selection: .line(CanvasLineID("l")), nodeKind: nil))
    }

    func test_everySelectionKindIsPromotable() {
        // **The compiler is the enforcer, and it is not this loop.** Adding a
        // `CanvasSelection` case breaks `CanvasPromotionModifier.isPromotable`'s
        // `switch`, which is exhaustive and has no `default`; this array literal
        // would happily go on omitting a fourth case and stay green. So this is
        // the behavioural companion to that switch — it says what the three
        // present cases must ANSWER — and not the thing that catches a new one.
        //
        // Written out because the guarantee is real and the obvious place to
        // look for it is wrong: a rule whose stated reason is false gets
        // deleted by the next author who checks the reason.
        for selection: CanvasSelection in [.node(a), .region(CanvasRegionID("r")),
                                           .line(CanvasLineID("l"))] {
            XCTAssertTrue(CanvasPromotionModifier.isPromotable(binderSegment: .canvas,
                                                               selection: selection,
                                                               nodeKind: .scrap),
                          "\(selection)")
        }
    }

    // MARK: - The real delivery path

    /// A real `NSWindow` that reports itself key.
    ///
    /// **The OS will not grant key status in this test host, and that is
    /// measured rather than assumed.** `MaughamEventLivenessTests` already
    /// records it ("Key-window STATUS is not reliably grantable in a headless
    /// test host"); re-measured 2026-07-28 for this test —
    /// `NSApp.setActivationPolicy(.regular)` + `activate(ignoringOtherApps:)` +
    /// `makeKeyAndOrderFront` + `makeKey`, then three seconds of run loop, and
    /// `NSApp.isActive` was still false and `isKeyWindow` still false while
    /// `canBecomeKey` was true. The host app is never frontmost under
    /// `xcodebuild`.
    ///
    /// So the ONE fact the host cannot supply is substituted, and nothing else
    /// is: this is a real `NSWindow`, `EventReceiverContext.forWindow` reads
    /// `isKeyWindow` off it through the real property, and `shouldDeliver` makes
    /// the real decision. **Do not replace it with a hand-built
    /// `EventReceiverContext`** — that skips `forWindow` and its liveness read,
    /// which are half of what the drop rule is made of.
    private final class KeyStubWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    /// A `.keyWindow` post is delivered to the key window's receivers and to no
    /// others. Driven through REAL `NSWindow`s because the drop rule is about
    /// key status — the v0.24.0 bug was a post made while a dialog held it.
    ///
    /// The `other` window is genuinely not key (nothing is, here), so its arm is
    /// the unsubstituted half: a real window that does not hold key status drops
    /// the command, which is precisely the v0.24.0 shape.
    func test_theCommandReachesTheKeyWindowAndOnlyTheKeyWindow() {
        let key = KeyStubWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                                styleMask: [.titled], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                             styleMask: [.titled], backing: .buffered, defer: false)
        // Test-owned windows. Without this, `close()` over-releases under ARC and
        // takes the whole test process down — measured: the runner reported
        // "Restarting after unexpected exit, crash, or test timeout".
        key.isReleasedWhenClosed = false
        other.isReleasedWhenClosed = false
        key.makeKeyAndOrderFront(nil)
        other.orderFront(nil)
        defer { key.close(); other.close() }
        XCTAssertFalse(other.isKeyWindow, "the control arm must really not be key")

        var keyGot = 0, otherGot = 0
        let token = NotificationCenter.default.addObserver(   // adr-0021-ok: test observer
            forName: .maughamPromoteCanvasSelection, object: nil, queue: nil) { note in
            if MaughamEvent.shouldDeliver(note, to: .forWindow(key, kind: .keyWindow)) {
                keyGot += 1
            }
            if MaughamEvent.shouldDeliver(note, to: .forWindow(other, kind: .keyWindow)) {
                otherGot += 1
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        MaughamEvent.post(.maughamPromoteCanvasSelection, to: .keyWindow)
        XCTAssertEqual(keyGot, 1)
        XCTAssertEqual(otherGot, 0)
    }

    /// The receive half through the PRODUCTION helper rather than through
    /// `shouldDeliver` directly: a SwiftUI view carrying the real
    /// `.onKeyWindowCommand(.maughamPromoteCanvasSelection, window:)` — the same
    /// call `CanvasPromotionModifier.body` makes — hosted in a real window, fires
    /// on the real post, and stays silent for a window that is not key.
    ///
    /// This is the arm that models 1C-a's ⌘Z defect: everything either side of
    /// the receiver can be green while nothing reaches it.
    func test_theProductionReceiverFiresOnTheRealPostAndOnlyForTheKeyWindow() {
        var keyFired = 0, otherFired = 0
        let key = KeyStubWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                                styleMask: [.titled], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                             styleMask: [.titled], backing: .buffered, defer: false)
        key.isReleasedWhenClosed = false
        other.isReleasedWhenClosed = false
        defer { key.close(); other.close() }

        let keyHost = NSHostingView(rootView: AnyView(
            Color.clear.onKeyWindowCommand(.maughamPromoteCanvasSelection,
                                           window: key) { _ in keyFired += 1 }))
        let otherHost = NSHostingView(rootView: AnyView(
            Color.clear.onKeyWindowCommand(.maughamPromoteCanvasSelection,
                                           window: other) { _ in otherFired += 1 }))
        keyHost.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        otherHost.frame = keyHost.frame
        key.contentView?.addSubview(keyHost)
        other.contentView?.addSubview(otherHost)
        key.makeKeyAndOrderFront(nil)
        other.orderFront(nil)
        // Let SwiftUI mount both hosts so their `.onReceive` subscriptions exist
        // before the post — an unmounted view is subscribed to nothing, and that
        // false negative would look exactly like a broken command.
        pump()

        MaughamEvent.post(.maughamPromoteCanvasSelection, to: .keyWindow)
        pump()

        XCTAssertEqual(keyFired, 1,
                       "the production onKeyWindowCommand receiver must fire for the key window")
        XCTAssertEqual(otherFired, 0,
                       "a window that is not key must receive nothing (the v0.24.0 shape)")
    }

    private func pump() {
        for _ in 0..<20 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    // MARK: - The wiring census

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Canvas
            .deletingLastPathComponent()   // MaughamTests
            .deletingLastPathComponent()   // repo root
    }

    /// Which of `required` are absent from the **code** of the file at `path`.
    /// Shared by the census and by its planted-offender companion, so there is
    /// exactly one implementation to get wrong.
    ///
    /// **Comments do not count, and that is 1C-d Task 11's fix rather than
    /// tidiness.** This was a raw `text.contains` over the whole file for seven
    /// entries and sixteen tokens, and the realistic way it goes blind is not
    /// somebody commenting a call out — it is this repo's house style. Several
    /// of these files quote call shapes verbatim in their doc comments, and
    /// `ProjectWindow.swift` grew a five-line comment block directly above a
    /// censused call in the very task that added the seventh token to it. One
    /// comment naming a token while the real call goes away leaves every
    /// assertion here green and the feature unreachable from the writer's
    /// window — which is the single failure this census exists to catch.
    /// Measured on the old implementation: block-commenting the `assetIngest:`
    /// argument out left the census green; deleting it turns it red.
    private func missingTokens(in path: String, required: [String]) throws -> [String] {
        let url = Self.repoRoot.appendingPathComponent(path)
        let text = try String(contentsOf: url, encoding: .utf8)
        return required.filter { !SourceScan.namesInCode($0, in: text) }
    }

    /// The inspector buttons post the SAME command the menu posts, so a writer
    /// who clicks and a writer who presses ⌘⇧↩ take the same path — **and both
    /// halves of the wiring outside this directory are named here too.**
    ///
    /// **Why the census reaches past `Maugham/Canvas/`.** Every other test in
    /// this file exercises an *equivalent* of the production wiring rather than
    /// the wiring itself: `isPromotable` is a pure function, and the
    /// real-delivery test hosts its own `Color.clear.onKeyWindowCommand(...)`.
    /// So with a census confined to the two inspectors, `CanvasPromotionModifier`
    /// could subscribe to `.maughamPromotePiece`, or `FocusedPromoteButton()`
    /// could be left out of the `CommandGroup` entirely, and **all six tests
    /// stay green** while `Promote…` is greyed out or deaf. That is this
    /// directory's signature defect — 1C-a's ⌘Z was built, twenty-two tests
    /// deep, and unreachable from the Edit menu — and all four instances of it
    /// were found by counting production sites, never by a test. This is the
    /// count, written down.
    func test_theCanvasWiringCensusNamesEveryProductionSite() throws {
        let census: [(path: String, required: [String], why: String)] = [
            ("Maugham/Canvas/RegionInspector.swift", [".maughamPromoteCanvasSelection"],
             "the region inspector's Promote… button must post the ONE command; a "
             + "closure of its own would be a second path that can drift from the keystroke"),
            ("Maugham/Canvas/LineInspector.swift", [".maughamPromoteCanvasSelection"],
             "the line inspector's Promote… button must post the ONE command; a "
             + "closure of its own would be a second path that can drift from the keystroke"),
            ("Maugham/Canvas/ScrapInspector.swift", [".maughamPromoteCanvasSelection",
                                                     "CanvasAuthorLine.forCard("],
             "the scrap inspector's Promote… button must post the ONE command; a "
             + "closure of its own would be a second path that can drift from the "
             + "keystroke. `CanvasAuthorLine.forCard(` is 1C-c3's provenance line: "
             + "`CanvasAuthorLine` and every sentence on it can be fully tested "
             + "with nothing in `body` reading it, and a card that is Claude's "
             + "would then say so on the canvas, in VoiceOver and nowhere the "
             + "writer can inspect — which is CLAUDE.md rule 8 and the previous "
             + "slice's Critical exactly. `RegionInspector`'s half of the same "
             + "line is censused in `RegionBindingTests`, beside that arm's own "
             + "source scans"),
            ("Maugham/Canvas/ItemInspector.swift", [".maughamPromoteCanvasSelection",
                                                    "PromotedArtifactSection("],
             "the item inspector's Promote… button must post the ONE command; a "
             + "closure of its own would be a second path that can drift from the "
             + "keystroke. `PromotedArtifactSection(` is 1C-d Task 8's provenance section: "
             + "an owned picture's mark and its contribution record are written by "
             + "`PromotionPerformer` and can be fully tested with nothing in this "
             + "`body` reading them, and the writer would then have no way to "
             + "learn what a picture produced, no way to open it, and no way to "
             + "discover the artifact had been deleted — which is CLAUDE.md rule "
             + "8 and the region arm's own 1C-c2 omission, one arm over"),
            ("Maugham/Canvas/CanvasView.swift", [".dropDestination(for: String.self)",
                                                 "CanvasDrop.apply(",
                                                 "CanvasExternalDrop.ingest(",
                                                 "CanvasExternalDrop.apply(",
                                                 "CanvasDrop.payload(",
                                                 "captureDrop.send("],
             "1C-d Task 10's drop target. `CanvasDrop` is a pure decision plus a "
             + "model verb, both fully testable with nothing mounting them — and "
             + "SwiftUI's drop delivery has no seam a test can post a drag session "
             + "into, so no runtime test in this repo can see whether the modifier "
             + "is on `CanvasView.body` at all. Delete this one line and every "
             + "`CanvasDropTests` assertion stays green while dragging a research "
             + "item onto the canvas does nothing whatever. That is this "
             + "directory's signature defect — a built-and-unreachable half — and "
             + "all four historical ones were found by counting production sites. "
             + "**`CanvasDrop.apply(` is that route's LANDING verb, and it was the "
             + "one drop layer nothing censused until the whole-branch review "
             + "found it** — the fourth instance of the layer-below-a-mount shape "
             + "on this branch, and the only one added by the task that invented "
             + "the shape's own lesson two tasks later. Delete it from "
             + "`handleDrop`'s `.create` arm and the build succeeds with NO "
             + "warning (`node` is still read by the `model.selection` line under "
             + "it), all twenty-one `CanvasDropTests` stay green because nothing "
             + "in the repo drives `handleDrop` at all, both drop-route tripwires "
             + "stay green — and a research row dragged onto the canvas makes no "
             + "card while the selection points at a node that does not exist, so "
             + "the right-hand column goes blank over a drag that looked like it "
             + "worked. Measured 2026-07-31, not argued. **`CanvasDrop.decide(` is "
             + "deliberately NOT here**: the switch needs its value, so removing "
             + "it cannot compile, and a token whose absence is a build error is a "
             + "token this census cannot earn anything by holding. "
             + "`CanvasExternalDrop.ingest(` and `.apply(` are 1C-d Task 11's "
             + "external half, and they guard the layer BELOW the mount: the "
             + "modifier can be on `body` with a closure that reaches nothing. "
             + "`CanvasExternalDrop` is exhaustively tested through its own "
             + "seam, so deleting the two calls in `handleExternalDrop` leaves "
             + "all seventeen `CanvasDropTests` and both drop-route tripwires "
             + "green while a photograph dragged from the Finder lands nowhere "
             + "at all. **`CanvasDrop.payload(` and `captureDrop.send(` are 1C-d "
             + "Task 12's, and they are that same layer a third time** — the one "
             + "this file had already named and which the task that added them "
             + "nearly skipped. `CanvasDrop.payload(` is "
             + "the dispatch that tells the canvas's TWO id spaces apart, and "
             + "`captureDrop.send(` is the only thing that reaches the inbox at "
             + "all: delete either and the build succeeds (an unused stored "
             + "property warns nothing), every `InboxToCanvasTests` case, every "
             + "payload assertion and the window's own `captureDrop:` token stay "
             + "green — while every inbox row dragged onto the canvas springs "
             + "back in silence, because `decide` answers `.ignored` for a "
             + "prefixed payload, which `test_aCapturePayloadIsNeverRoutedTo"
             + "TheItemDecision` pins on purpose. The drag is the route with no "
             + "runtime coverage available to it, so this is the only instrument "
             + "that holds it"),
            ("Maugham/Views/ProjectWindow.swift",
             [".onKeyWindowCommand(.maughamPromoteCanvasSelection",
              ".modifier(CanvasPromotionModifier(",
              "result.confirmation(for: plan)",
              "PromotionPiece.resolve(",
              "items: ProjectWindow.canvasItemIndex(in: store)",
              ".modifier(CanvasClaudeArrivalModifier(",
              "itemIndex: Self.canvasItemIndex(in: store)",
              "subject: CanvasSubject.resolve(",
              "assetIngest: CanvasAssetIngest(",
              "captureDrop: CanvasCaptureDrop(",
              ".modifier(CanvasCollapseModifier(",
              "NavigationSplitView(columnVisibility: $columnVisibility)",
              "Self.releasesCanvasCollapse(",
              "Self.clearsPaletteStash(",
              "ProjectWindow.applyPaletteSegmentChange("],
             // **Numbered by what each token IS, never by its position in the
             // array above** (1C-d Task 12a, review Important 1). This read
             // "The FIFTH is…", "The SIXTH is…" and so on; Task 12a inserted a
             // token in the middle and five of nine ordinals silently came to
             // name the wrong entry, with nothing red — `missingTokens` is a set
             // difference and does not care about order. That is the seventh
             // prose count to drift in this slice, two of them inside the fixes
             // for others. A name cannot drift when a neighbour is inserted.
             "`.onKeyWindowCommand(.maughamPromoteCanvasSelection` — nothing in "
             + "the window RECEIVES the command, so every button and the "
             + "keystroke post into nothing, and no test that hosts its own "
             + "onKeyWindowCommand can see it. "
             + "`.modifier(CanvasPromotionModifier(` is the MOUNT LINE, and it "
             + "is a separate token because the receiver above lives inside "
             + "`CanvasPromotionModifier`'s own struct body in the SAME file — "
             + "so deleting the line that mounts the modifier on "
             + "`ProjectWindow.body` leaves the receiver present and every test "
             + "green while `Promote…` is unreachable from the real window. "
             + "`result.confirmation(for: plan)` is the RESULT: `PromotionResult` "
             + "was built and discarded here (`_ = try await …perform(plan)`) for "
             + "a whole slice while its own doc comment said the link count "
             + "\"reaches the writer\", and it can be fully tested with nothing "
             + "calling it — this directory's signature defect. "
             + "`PromotionPiece.resolve(` is the PIECE (spec §6.2): "
             + "`PromotionSheetModel.init` has no default for it, so the compiler "
             + "demands a value — but `piece: .none` compiles, and every "
             + "destination in the sheet then quietly reverts to the pre-§6.2 "
             + "wording with nothing red. "
             + "`items: ProjectWindow.canvasItemIndex(in: store)` is 1C-d Task "
             + "12a's index on the SHEET, and it is the piece token's shape: "
             + "undefaulted on the initialiser too, and `items: .empty` compiles "
             + "and runs — `.empty` is a real state (a canvas hosted without a "
             + "window) — so every REFERENCED picture in a promoted region would "
             + "be silently uncopied and unrecorded while every owned one still "
             + "worked, which is the half-right failure no assertion in "
             + "`PromotionRegionPictureTests` can see from inside. "
             + "`.modifier(CanvasClaudeArrivalModifier(` is 1C-c3's arrival "
             + "banner, and it is the mount-line shape again one slice on: that "
             + "modifier is a whole file of its own, so every token in it stays "
             + "present and its own census stays green while the writer is never "
             + "told that Claude added anything. "
             + "`itemIndex: Self.canvasItemIndex(in: store)` is 1C-d's item "
             + "index on the CANVAS, and it is the first token here that guards "
             + "a DEFAULT rather than a call: `CanvasView.itemIndex` and "
             + "`RegionInspectorPane.itemIndex` both default to `.empty`, which "
             + "is a real state and therefore compiles and runs — so deleting "
             + "either argument leaves every canvas test green while every item "
             + "node on the writer's canvas reads \"No longer in the project.\" "
             + "over research notes sitting in their binder. The default earns "
             + "its keep against ~70 test hosts; this token is what pays for it. "
             + "`assetIngest: CanvasAssetIngest(` is 1C-d Task 11's ingestion "
             + "pair and the same defaulted-argument shape: `CanvasView"
             + ".assetIngest` defaults to `.unavailable`, whose two closures "
             + "throw, so dropping this argument compiles, runs, keeps every "
             + "drop test green, and turns every photograph the writer drags "
             + "onto their canvas into \"Couldn't add …\". "
             + "`captureDrop: CanvasCaptureDrop(` is 1C-d Task 12's capture "
             + "seam, that shape a third time: it defaults to `.unavailable` "
             + "too, so dropping it keeps all of `InboxToCanvasTests` green and "
             + "turns every inbox row dragged onto the canvas into a refusal "
             + "alert. It is also the only place the window hands the canvas an "
             + "`InboxStore` at all. "
             + "`subject: CanvasSubject.resolve(` is slice 3's dim, and it is "
             + "the defaulted-argument shape a fourth time: `CanvasView.subject` "
             + "defaults to `.wholeProject`, which is a real state — the project "
             + "row — so dropping this argument compiles, runs, and leaves every "
             + "`CanvasHighlightTests` assertion green over a pure function "
             + "while clicking a chapter in Plan's tree changes nothing at all "
             + "on the canvas. It is also the only place the manifest reaches "
             + "the resolution: the canvas cannot tell a chapter from a group "
             + "without it, and a group resolved as a chapter lights nothing. "
             + "`.modifier(CanvasCollapseModifier(` is 1C-d Task 13's mount "
             + "line, and it is the mount-line shape a third time: the modifier "
             + "is a struct in THIS file, so deleting the one line that puts it "
             + "on `ProjectWindow.body` leaves every token in it present, every "
             + "`CanvasCollapseTests` assertion green — they are all over a pure "
             + "function — and `⌘\\` on the canvas moving no column at all. "
             + "`NavigationSplitView(columnVisibility: $columnVisibility)` is "
             + "the layer BELOW that mount, and it is the one this window has no "
             + "other instrument for: with the argument dropped the split view "
             + "manages its own visibility, the modifier still runs, still folds "
             + "the decision and still writes `.doubleColumn` into a `@State` "
             + "nothing reads — it compiles, `showInspector` still goes false so "
             + "HALF the collapse still happens, and the binder never leaves. A "
             + "half-working focus key is the failure no assertion over the "
             + "decision can see from inside. "
             + "`Self.releasesCanvasCollapse(` is the persona handler's CALL "
             + "SITE, and it is the site the whole ordering hazard turns on. "
             + "The predicate is tested as a pure function and the sequence "
             + "test hand-drives it — nothing in the tree posts "
             + "`.maughamSetPersona`, so no test drives the emitter. Delete the "
             + "`if` block in `PersonaModifier`'s handler and every "
             + "`CanvasCollapseTests` assertion stays green while a writer who "
             + "closed the inspector before collapsing lands in the next "
             + "persona with it closed, which is the exact defect the predicate "
             + "exists to prevent. **`Self.clearsPaletteStash(` is its "
             + "NEIGHBOUR three lines up, and it had the identical gap "
             + "until the 1C-d whole-branch review (M3)** — Task 13 measured "
             + "the hazard on its own predicate and censused that one, and "
             + "the sibling it was copied from was left uncovered. Delete "
             + "those three lines and every test stays green while a writer "
             + "switching persona out of the Palette lands with the inspector "
             + "CLOSED: `PaletteSegmentModifier`'s exit arm restores the "
             + "stashed visibility over the persona switch's unconditional "
             + "`showInspector = true`, which is the exact ordering hazard the "
             + "canvas takeover was built to remove, on the surface it was "
             + "built from. "
             + "`ProjectWindow.applyPaletteSegmentChange(` is the wall's own "
             + "fold, and it is that shape one surface over: the fold is a "
             + "static with its own tests, so deleting the single line that "
             + "calls it from `PaletteSegmentModifier` compiles, warns nothing, "
             + "keeps every assertion over the fold green — and the palette "
             + "wall silently stops taking the width it was given, while the "
             + "canvas collapse's takeover starts reading a stash nobody sets"),
            ("Maugham/Views/InboxPane.swift",
             [".draggable(CanvasDrop.inboxPayload(", "Button(\"Send to Canvas\")"],
             "1C-d Task 12's two routes out of the inbox (spec §8A.4), and both "
             + "are pure wiring with everything they reach tested elsewhere. "
             + "`InboxStore.sendToCanvas` is covered over three capture kinds "
             + "and two placements — count `InboxToCanvasTests`, not this "
             + "sentence — and every one of those cases stays green with this "
             + "row carrying no `.draggable` at all and no command in its menu — which is a capture that can reach the canvas from nowhere "
             + "the writer can click. The DRAG token names the builder rather "
             + "than the string: an inbox ULID and a research id are not tellable "
             + "apart, so the payload must arrive PREFIXED or `CanvasDrop.decide` "
             + "looks it up in `CanvasItemIndex`, misses, and refuses the drag "
             + "silently — and a hand-spelled `\"inbox:\" + entry.id` here would "
             + "be a second spelling of a prefix the router destructures"),
            ("Maugham/MaughamApp.swift",
             ["FocusedPromoteButton()", ".maughamPromoteCanvasSelection"],
             "the File-menu item is not IN the menu (or does not post this command), "
             + "so ⌘⇧↩ reaches nothing — the 1C-a shape exactly: built, tested, greyed out"),
        ]
        for entry in census {
            let missing = try missingTokens(in: entry.path, required: entry.required)
            XCTAssertTrue(missing.isEmpty,
                          "\(entry.path) is missing \(missing) — \(entry.why).")
        }
    }

    /// Self-check: prove the census can FAIL. A census over a REQUIRED token is
    /// exactly the shape that passes while blind — a typo'd path, a token that
    /// matches something else, or a predicate inverted by a tidy-up all read as
    /// green — so the repo's convention is to pair one with a planted offender.
    ///
    /// **Every plant is deliberately unspellable in production** — count the
    /// assertions below rather than trusting a number in this sentence; it said
    /// "three" over five once already, and "five" over seven after 1C-c3. An
    /// earlier draft planted `.onKeyWindowCommand(.maughamPromotePiece` — a
    /// *plausible* defect — and that made this self-check go red under the very
    /// mutation it was written to survive: breaking the receiver's name made the
    /// "absent" token present. A self-check whose plant a real bug can satisfy is
    /// a false alarm waiting to happen, so every plant names a symbol that cannot
    /// exist.
    func test_theCensusFailsWhenPointedAtWiringThatIsNotThere() throws {
        XCTAssertEqual(
            try missingTokens(in: "Maugham/Views/ProjectWindow.swift",
                              required: [".onKeyWindowCommand(.maughamNotARealCommand"]).count, 1,
            "the census reports a token that is genuinely absent")
        XCTAssertEqual(
            try missingTokens(in: "Maugham/MaughamApp.swift",
                              required: ["FocusedNotAButton()",
                                         ".maughamPromoteCanvasSelection"]),
            ["FocusedNotAButton()"],
            "the census reports the ABSENT token and not the present one — a "
            + "census that reported both, or neither, would be blind in the "
            + "direction that matters")
        // The mount-line token: falsify it the same way, with a plant that
        // cannot be a real production spelling. If a future tidy-up deletes
        // `.modifier(CanvasPromotionModifier(` from `ProjectWindow.body`, this
        // is the shape that must go red — the receiver token alone
        // (`.onKeyWindowCommand(.maughamPromoteCanvasSelection`) stays present
        // because it lives inside the modifier's own struct body, in the same
        // file, so a census that named only that token would stay green while
        // `Promote…` is unreachable from the real window.
        XCTAssertEqual(
            try missingTokens(in: "Maugham/Views/ProjectWindow.swift",
                              required: [".onKeyWindowCommand(.maughamPromoteCanvasSelection",
                                         ".modifier(CanvasNotAPromotionModifier("]),
            [".modifier(CanvasNotAPromotionModifier("],
            "the census reports the ABSENT mount-line token and not the present "
            + "receiver token — a census that reported both, or neither, would "
            + "be blind in the direction that matters")
        // And the result token, falsified the same way. `_ = try await …perform(plan)`
        // compiles, passes every performer test, and tells the writer nothing.
        XCTAssertEqual(
            try missingTokens(in: "Maugham/Views/ProjectWindow.swift",
                              required: ["result.confirmation(for: plan)",
                                         "result.notARealConfirmation(for: plan)"]),
            ["result.notARealConfirmation(for: plan)"],
            "the census reports the ABSENT result token and not the present one")
        // And 1C-d's item index, falsified with a builder that cannot exist. This
        // is the plant that matters most of the set, because the token it guards
        // protects a DEFAULT: dropping `itemIndex:` at either call site compiles,
        // runs, and is invisible to every other test.
        XCTAssertEqual(
            try missingTokens(in: "Maugham/Views/ProjectWindow.swift",
                              required: ["itemIndex: Self.canvasItemIndex(in: store)",
                                         "itemIndex: Self.canvasNotAnItemIndex(in: store)"]),
            ["itemIndex: Self.canvasNotAnItemIndex(in: store)"],
            "the census reports the ABSENT item-index token and not the present one")
        // And the piece token. `piece: .none` at the call site compiles and every
        // performer test still passes, while the sheet's whole destination half
        // is back to what shipped before §6.2.
        XCTAssertEqual(
            try missingTokens(in: "Maugham/Views/ProjectWindow.swift",
                              required: ["PromotionPiece.resolve(",
                                         "PromotionPiece.notARealResolver("]),
            ["PromotionPiece.notARealResolver("],
            "the census reports the ABSENT piece token and not the present one")
        // And 1C-d Task 12a's sheet index, falsified with a builder that cannot
        // exist. It is the piece token's shape: undefaulted on the initialiser,
        // so `items: .empty` is what a forgetful call site would leave — and a
        // referenced picture in a promoted region would then be uncopied while
        // every owned one still worked.
        XCTAssertEqual(
            try missingTokens(in: "Maugham/Views/ProjectWindow.swift",
                              required: ["items: ProjectWindow.canvasItemIndex(in: store)",
                                         "items: ProjectWindow.canvasNotAnIndex(in: store)"]),
            ["items: ProjectWindow.canvasNotAnIndex(in: store)"],
            "the census reports the ABSENT sheet-index token and not the present one")
        // And 1C-d Task 11's ingestion pair, falsified with a type that cannot
        // exist. Same shape as the item index and the same reason it matters:
        // `assetIngest` defaults to `.unavailable`, so dropping the argument
        // compiles, runs, and refuses every photograph the writer drags in.
        XCTAssertEqual(
            try missingTokens(in: "Maugham/Views/ProjectWindow.swift",
                              required: ["assetIngest: CanvasAssetIngest(",
                                         "assetIngest: CanvasNotAnAssetIngest("]),
            ["assetIngest: CanvasNotAnAssetIngest("],
            "the census reports the ABSENT ingest token and not the present one")
        // And Task 11's two closure tokens: the modifier can be mounted on
        // `body` with a closure that reaches nothing, which no drop test and no
        // drop-route tripwire can see.
        XCTAssertEqual(
            try missingTokens(in: "Maugham/Canvas/CanvasView.swift",
                              required: ["CanvasExternalDrop.ingest(",
                                         "CanvasNotAnExternalDrop.ingest("]),
            ["CanvasNotAnExternalDrop.ingest("],
            "the census reports the ABSENT external-drop token and not the present one")
        // And Task 12's two below-the-mount tokens, falsified the same way. This
        // is the arm that matters most of the new set: the drag has no runtime
        // coverage available to it at all, so a census that could not see these
        // two lines go missing would be the only instrument holding the route,
        // holding nothing.
        XCTAssertEqual(
            try missingTokens(in: "Maugham/Canvas/CanvasView.swift",
                              required: ["CanvasDrop.payload(",
                                         "CanvasDrop.notARealClassifier(",
                                         "captureDrop.send(",
                                         "captureDrop.notARealSend("]),
            ["CanvasDrop.notARealClassifier(", "captureDrop.notARealSend("],
            "the census reports the two ABSENT capture-dispatch tokens and "
            + "neither of the present ones")
        // And 1C-d Task 12's two, falsified the same way. The seam token guards a
        // default that throws; the row tokens guard the only two places a capture
        // can be reached from at all, and both are pure wiring over a store verb
        // that is exhaustively tested without them.
        XCTAssertEqual(
            try missingTokens(in: "Maugham/Views/ProjectWindow.swift",
                              required: ["captureDrop: CanvasCaptureDrop(",
                                         "captureDrop: CanvasNotACaptureDrop("]),
            ["captureDrop: CanvasNotACaptureDrop("],
            "the census reports the ABSENT capture-seam token and not the present one")
        XCTAssertEqual(
            try missingTokens(in: "Maugham/Views/InboxPane.swift",
                              required: [".draggable(CanvasDrop.inboxPayload(",
                                         ".draggable(CanvasDrop.notARealPayload("]),
            [".draggable(CanvasDrop.notARealPayload("],
            "the census reports the ABSENT drag token and not the present one")

        // **A token surviving in a COMMENT must not satisfy the census**, which
        // is the blindness this census carried for seven entries and sixteen
        // tokens. `canvas_assets/` is the perfect probe: `ProjectWindow.swift`
        // names it in the comment block above the censused ingest argument, and
        // `TripwireGrepTests.test_theCanvasAssetWellIsDerivedAndNeverSpelledInCode`
        // guarantees it can never appear in production CODE — so this can only
        // ever be answered by the comment filter.
        XCTAssertEqual(
            try missingTokens(in: "Maugham/Views/ProjectWindow.swift",
                              required: ["canvas_assets/"]),
            ["canvas_assets/"],
            "a token present only in a comment satisfied the census. The house "
            + "style here quotes call shapes verbatim in doc comments, so this "
            + "is how the instrument goes quiet: one comment naming a token "
            + "while the real call goes away")
        XCTAssertTrue(
            try String(contentsOf: Self.repoRoot
                .appendingPathComponent("Maugham/Views/ProjectWindow.swift"),
                       encoding: .utf8).contains("canvas_assets/"),
            "control: the probe token really IS in that file — otherwise the "
            + "assertion above is satisfied by a string that appears nowhere at "
            + "all, and proves nothing about comments")
        // 1C-c3's arrival-banner mount line, falsified the same way. The
        // subscription, the banner and the Show action all live in
        // `CanvasClaudeArrivalModifier.swift`, so its own census stays green with
        // this line deleted and the writer is simply never told.
        XCTAssertEqual(
            try missingTokens(in: "Maugham/Views/ProjectWindow.swift",
                              required: [".modifier(CanvasClaudeArrivalModifier(",
                                         ".modifier(CanvasNotAnArrivalModifier("]),
            [".modifier(CanvasNotAnArrivalModifier("],
            "the census reports the ABSENT arrival-mount token and not the present one")
        // And 1C-d Task 13's collapse mount, falsified the same way. Everything
        // it reaches is a pure function on `ProjectWindow`, so its whole suite
        // stays green with this line deleted and ⌘\ on the canvas moves nothing.
        XCTAssertEqual(
            try missingTokens(in: "Maugham/Views/ProjectWindow.swift",
                              required: [".modifier(CanvasCollapseModifier(",
                                         ".modifier(CanvasNotACollapseModifier("]),
            [".modifier(CanvasNotACollapseModifier("],
            "the census reports the ABSENT collapse-mount token and not the present one")
        // And the layer below it: the split view's own binding, which is what
        // turns a `@State` the modifier writes into a column that actually
        // moves. Falsified with a binding name that cannot exist.
        XCTAssertEqual(
            try missingTokens(in: "Maugham/Views/ProjectWindow.swift",
                              required: ["NavigationSplitView(columnVisibility: $columnVisibility)",
                                         "NavigationSplitView(columnVisibility: $notARealVisibility)"]),
            ["NavigationSplitView(columnVisibility: $notARealVisibility)"],
            "the census reports the ABSENT split-view-binding token and not the "
            + "present one — with the argument gone the modifier still runs and "
            + "the binder never moves")
        // And the persona handler's call site, falsified with a predicate that
        // cannot exist. This is the one production site Task 13 added that has
        // no other instrument at all: the predicate is pure and its sequence
        // test hand-drives it, and nothing in the tree posts `.maughamSetPersona`.
        XCTAssertEqual(
            try missingTokens(in: "Maugham/Views/ProjectWindow.swift",
                              required: ["Self.releasesCanvasCollapse(",
                                         "Self.releasesNotARealCollapse("]),
            ["Self.releasesNotARealCollapse("],
            "the census reports the ABSENT persona-call-site token and not the "
            + "present one")
        // And its NEIGHBOUR three lines up, which had the identical gap until the
        // 1C-d whole-branch review: Task 13 measured the hazard on its own
        // predicate and censused that one, and left uncovered the sibling it was
        // copied from.
        XCTAssertEqual(
            try missingTokens(in: "Maugham/Views/ProjectWindow.swift",
                              required: ["Self.clearsPaletteStash(",
                                         "Self.clearsNotARealStash("]),
            ["Self.clearsNotARealStash("],
            "the census reports the ABSENT palette-stash-call-site token and not "
            + "the present one")
        // And the wall's fold, the same shape one surface over: a static with
        // its own tests, called from exactly one line.
        XCTAssertEqual(
            try missingTokens(in: "Maugham/Views/ProjectWindow.swift",
                              required: ["ProjectWindow.applyPaletteSegmentChange(",
                                         "ProjectWindow.applyNotARealSegmentChange("]),
            ["ProjectWindow.applyNotARealSegmentChange("],
            "the census reports the ABSENT palette-fold token and not the present one")
        // And 1C-c3's provenance line in the card arm: `Origin` and its sentences
        // are fully testable with nothing in `body` reading them.
        XCTAssertEqual(
            try missingTokens(in: "Maugham/Canvas/ScrapInspector.swift",
                              required: ["CanvasAuthorLine.forCard(",
                                         "CanvasAuthorLine.forNotARealSubject("]),
            ["CanvasAuthorLine.forNotARealSubject("],
            "the census reports the ABSENT provenance token and not the present one")
        // And 1C-d Task 8's promotion section in the item arm, falsified the same
        // way: the section is a whole file of its own, so its own tests stay
        // green with this line deleted and an owned picture simply never says
        // what it produced.
        XCTAssertEqual(
            try missingTokens(in: "Maugham/Canvas/ItemInspector.swift",
                              required: ["PromotedArtifactSection(",
                                         "NotARealArtifactSection("]),
            ["NotARealArtifactSection("],
            "the census reports the ABSENT item-arm section token and not the "
            + "present one")
        // And 1C-d Task 10's drop mount, falsified with a payload type that
        // cannot be the production spelling. This plant is the closest of the set
        // to something real — `.dropDestination(for: URL.self)` is a genuine
        // modifier — so it names a type that does not exist rather than one a
        // mistaken implementer might reach for, which is the rule the earlier
        // `.maughamPromotePiece` plant broke.
        XCTAssertEqual(
            try missingTokens(in: "Maugham/Canvas/CanvasView.swift",
                              required: [".dropDestination(for: String.self)",
                                         ".dropDestination(for: NotARealPayload.self)"]),
            [".dropDestination(for: NotARealPayload.self)"],
            "the census reports the ABSENT drop-mount token and not the present one")
    }

    /// The name must not collide with the collection-piece promotion that
    /// already exists (`MaughamNotifications.swift:126`).
    func test_theCanvasCommandIsNotThePiecePromotionCommand() {
        XCTAssertNotEqual(Notification.Name.maughamPromoteCanvasSelection,
                          Notification.Name.maughamPromotePiece)
    }
}
