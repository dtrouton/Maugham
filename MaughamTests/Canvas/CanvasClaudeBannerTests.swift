import XCTest
import AppKit
@testable import Maugham

/// **What tells the WRITER that Claude added something, and lets them go and
/// look.** Tasks 1–8 made a Claude card visible on the canvas and audible to
/// VoiceOver; every one of those signals requires the writer to already be
/// looking at the canvas. This is the arrival itself.
///
/// The shape of every assertion here is forced by the same two facts the rest of
/// this directory's tests are: which arm of a SwiftUI `_ConditionalContent`
/// renders cannot be asserted, and a `body` cannot be driven from a test host.
/// So the banner's sentence and the Show action's destination are **values on the
/// modifier** rather than expressions inside its `body`, and those values are
/// what is pinned.
@MainActor
final class CanvasClaudeBannerTests: XCTestCase {

    private let r1 = CanvasRegionID("r1")
    private let r2 = CanvasRegionID("r2")

    private func scene(label: String = CanvasClaudePlacement.defaultRegionLabel,
                       id: CanvasRegionID? = nil) -> CanvasScene {
        var s = CanvasScene()
        s.insertRegion(CanvasRegion(id: id ?? r1, label: label,
                                    frame: CGRect(x: 0, y: 0, width: 300, height: 200),
                                    author: .claude))
        return s
    }

    /// The real post, built by the real wrapper — so the payload keys on the
    /// asserted path are the ones `AddCanvasScrapsTool` writes.
    private func note(count: Int, region: CanvasRegionID) -> Notification {
        Notification(name: .maughamCanvasNodesAdded,
                     object: nil,
                     userInfo: [MaughamEvent.canvasScrapCountKey: count,
                                MaughamEvent.canvasRegionIDKey: region.raw,
                                MaughamEvent.scopeKindKey: "project",
                                MaughamEvent.scopeIdKey: "p-1"])
    }

    // MARK: - What the banner says

    /// The count and the region's own name, because those are the two things the
    /// writer needs before deciding whether to go and look.
    func test_theBannerNamesWhatClaudeAdded() throws {
        let arrival = try XCTUnwrap(
            CanvasClaudeArrivalModifier.arrival(from: note(count: 6, region: r1),
                                                in: scene()),
            "the post the tool makes must resolve to an arrival, or the banner "
            + "never appears and the writer's only notice is noticing")
        XCTAssertEqual(arrival.count, 6)
        XCTAssertEqual(arrival.region, r1)
        XCTAssertEqual(arrival.regionLabel, "From Claude")
        XCTAssertEqual(arrival.message,
                       "Claude added 6 cards to “From Claude” on the canvas.")
    }

    /// One card is one card. Written out rather than left to `\(count) card(s)`
    /// because a banner reading "1 cards" is the kind of thing a writer reads as
    /// a broken tool.
    func test_aSingleCardIsNotAnnouncedInThePlural() throws {
        let arrival = try XCTUnwrap(
            CanvasClaudeArrivalModifier.arrival(from: note(count: 1, region: r1),
                                                in: scene(label: "Fog notes")))
        XCTAssertEqual(arrival.message,
                       "Claude added 1 card to “Fog notes” on the canvas.")
    }

    /// **"Added to the canvas", never "saved".** `CanvasStore.writeNow` swallows
    /// every I/O error with `try?` — area-wide and pre-existing — so nothing on
    /// this path can promise the disk. The tool's own return comment says the same
    /// thing about its response; this is the writer-facing half of it.
    func test_theBannerPromisesTheCanvasAndNotTheDisk() throws {
        let arrival = try XCTUnwrap(
            CanvasClaudeArrivalModifier.arrival(from: note(count: 2, region: r1),
                                                in: scene()))
        let message = arrival.message.lowercased()
        XCTAssertTrue(message.contains("the canvas"),
                      "the banner names the surface the cards are on — found: "
                      + "\(arrival.message)")
        for promise in ["saved", "stored", "written to disk"] {
            XCTAssertFalse(message.contains(promise),
                           "the banner must not promise \(promise) — "
                           + "`CanvasStore.writeNow` swallows every write error with "
                           + "`try?`. Found: \(arrival.message)")
        }
    }

    /// A region the window's own scene does not hold — the arrival is still
    /// announced, because the count is the fact the writer needs and a banner
    /// that appears only when a label resolves is a banner that vanishes in
    /// exactly the confusing case.
    func test_anUnresolvableRegionStillAnnouncesTheCount() throws {
        let arrival = try XCTUnwrap(
            CanvasClaudeArrivalModifier.arrival(from: note(count: 3, region: r2),
                                                in: scene()),
            "an unnameable region must not swallow the announcement")
        XCTAssertNil(arrival.regionLabel)
        XCTAssertEqual(arrival.message, "Claude added 3 cards to the canvas.")
    }

    /// A region left on the writer's own untitled default is named by
    /// `displayLabel`, not by an empty pair of quotes.
    func test_anUnnamedRegionIsNamedTheWayTheCanvasNamesIt() throws {
        let arrival = try XCTUnwrap(
            CanvasClaudeArrivalModifier.arrival(from: note(count: 1, region: r1),
                                                in: scene(label: "")))
        XCTAssertEqual(arrival.regionLabel, CanvasRegion.untitledLabel)
        XCTAssertFalse(arrival.message.contains("“”"), "found: \(arrival.message)")
    }

    /// The two ways a post can carry nothing to announce. A banner reading
    /// "Claude added 0 cards" is chrome reporting that nothing happened.
    func test_aPostWithNothingToAnnounceIsNotAnArrival() {
        XCTAssertNil(CanvasClaudeArrivalModifier.arrival(
            from: note(count: 0, region: r1), in: scene()),
            "zero cards is not an arrival")
        XCTAssertNil(CanvasClaudeArrivalModifier.arrival(
            from: Notification(name: .maughamCanvasNodesAdded, object: nil,
                               userInfo: [MaughamEvent.canvasScrapCountKey: 3]),
            in: scene()),
            "a post naming no region cannot be shown to the writer, so it is not "
            + "an arrival either")
        XCTAssertNil(CanvasClaudeArrivalModifier.arrival(
            from: Notification(name: .maughamCanvasNodesAdded, object: nil,
                               userInfo: [MaughamEvent.canvasRegionIDKey: r1.raw]),
            in: scene()),
            "a post with no count has nothing to say")
    }

    // MARK: - The real delivery path

    /// **The post the tool actually makes, through the real receive filter.** The
    /// payload keys are constants shared by both sides, which is what makes a
    /// rename a compile error rather than a silent nil — but the SCOPE is not:
    /// this window's receiver is `.project`, and a key-window post or an unscoped
    /// one is dropped by `shouldDeliver` with nothing red anywhere.
    func test_theArrivalIsBuiltFromTheRealPostAndNotAHandBuiltPayload() {
        var received: [Notification] = []
        let arrived = expectation(description: "the project receiver got the post")
        let token = MaughamEvent.observe(
            .maughamCanvasNodesAdded,
            context: { EventReceiverContext(kind: .project(id: "p-1"),
                                            isWindowLive: true, isWindowKey: false) },
            handler: { note in
                received.append(note)
                arrived.fulfill()
            })
        defer { NotificationCenter.default.removeObserver(token) }

        MaughamEvent.post(.maughamCanvasNodesAdded,
                          to: .project(id: "p-1"),
                          payload: [MaughamEvent.canvasScrapCountKey: 4,
                                    MaughamEvent.canvasRegionIDKey: r1.raw])
        wait(for: [arrived], timeout: 2)

        XCTAssertEqual(received.count, 1, "exactly one delivery, or the arity below "
                       + "is being read off a list this test does not control")
        let arrival = CanvasClaudeArrivalModifier.arrival(from: received[0], in: scene())
        XCTAssertEqual(arrival?.count, 4)
        XCTAssertEqual(arrival?.region, r1)
        XCTAssertEqual(arrival?.message,
                       "Claude added 4 cards to “From Claude” on the canvas.")
    }

    /// The other half of the delivery rule: a window on ANOTHER project must not
    /// announce cards it did not receive. The drop happens in `shouldDeliver`, so
    /// nothing in this file can enforce it — this is the assertion that the scope
    /// the tool posts to is the scope this receiver subscribes as.
    func test_aWindowOnAnotherProjectIsNotToldAboutTheseCards() {
        var deliveries = 0
        let token = MaughamEvent.observe(
            .maughamCanvasNodesAdded,
            context: { EventReceiverContext(kind: .project(id: "somebody-else"),
                                            isWindowLive: true, isWindowKey: false) },
            handler: { _ in deliveries += 1 })
        defer { NotificationCenter.default.removeObserver(token) }

        MaughamEvent.post(.maughamCanvasNodesAdded,
                          to: .project(id: "p-1"),
                          payload: [MaughamEvent.canvasScrapCountKey: 4,
                                    MaughamEvent.canvasRegionIDKey: r1.raw])
        // The observer queue is `.main`; give it a pass to be wrong on.
        let settled = expectation(description: "the run loop ran")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(deliveries, 0)
    }

    // MARK: - Show

    /// **Where the writer is taken, as a value.** The canvas segment is offered by
    /// the Plan persona and by no other (`Persona.binderSegments(for:)`), so
    /// setting the segment without the persona would put the binder on a surface
    /// the picker does not offer — and selecting the region without either would
    /// change something the writer cannot see.
    ///
    /// `handleShowLatestMCPNote` is the precedent for the shape: set the segment,
    /// set the selection, dismiss.
    func test_showTakesTheWriterToTheRegion() {
        let to = CanvasClaudeArrivalModifier.destination(
            forRegion: r1)
        XCTAssertEqual(to.persona, .plan,
                       "the canvas segment is Plan's and nobody else's")
        XCTAssertEqual(to.binderSegment, .canvas)
        XCTAssertEqual(to.selection, .region(r1),
                       "the region, so the inspector's region arm names what "
                       + "arrived and ⌫/Promote… act on it")
    }

    /// Two batches into the SAME region add up rather than replacing, which is
    /// `MCPBannerModel.bump`'s behaviour for research notes and the same reason:
    /// the writer wants to know how much is waiting, not how much the last call
    /// brought.
    func test_aSecondBatchIntoTheSameRegionAddsUp() throws {
        let first = try XCTUnwrap(CanvasClaudeArrivalModifier.arrival(
            from: note(count: 3, region: r1), in: scene()))
        let second = try XCTUnwrap(CanvasClaudeArrivalModifier.arrival(
            from: note(count: 2, region: r1), in: scene()))
        let combined = CanvasClaudeArrivalModifier.accumulating(second, onto: first)
        XCTAssertEqual(combined.count, 5)
        XCTAssertEqual(combined.region, r1)
        XCTAssertEqual(combined.message,
                       "Claude added 5 cards to “From Claude” on the canvas.")
    }

    /// A batch into a DIFFERENT region replaces rather than adding: the banner
    /// names one region and Show goes to one region, so a total across two would
    /// be a count the writer cannot reach.
    func test_aBatchIntoADifferentRegionReplacesRatherThanAddingUp() throws {
        var s = scene()
        s.insertRegion(CanvasRegion(id: r2, label: "Second reading",
                                    frame: CGRect(x: 400, y: 0, width: 300, height: 200),
                                    author: .claude))
        let first = try XCTUnwrap(CanvasClaudeArrivalModifier.arrival(
            from: note(count: 3, region: r1), in: s))
        let second = try XCTUnwrap(CanvasClaudeArrivalModifier.arrival(
            from: note(count: 2, region: r2), in: s))
        let combined = CanvasClaudeArrivalModifier.accumulating(second, onto: first)
        XCTAssertEqual(combined.count, 2)
        XCTAssertEqual(combined.region, r2)
        XCTAssertEqual(combined.regionLabel, "Second reading")
        XCTAssertEqual(CanvasClaudeArrivalModifier.destination(forRegion: combined.region)
            .selection, .region(r2),
            "and Show goes where the banner says")
    }

    /// The first arrival on an empty banner is itself.
    func test_theFirstArrivalIsShownAsItArrived() throws {
        let only = try XCTUnwrap(CanvasClaudeArrivalModifier.arrival(
            from: note(count: 2, region: r1), in: scene()))
        XCTAssertEqual(CanvasClaudeArrivalModifier.accumulating(only, onto: nil), only)
    }

    // MARK: - The wiring census

    /// **The mount line, and the modifier's own two halves.**
    ///
    /// This directory's signature defect is a feature that is built, tested and
    /// unreachable — four instances, every one found by counting production sites
    /// rather than by a test. The specific shape here is the one 1C-c2 recorded:
    /// deleting the line that mounts a modifier on `ProjectWindow.body` leaves the
    /// subscription's own text present and every test green while nothing reaches
    /// the writer. `PromotionCommandTests.test_theInspectorButtonsPostTheSameCommandAsTheMenu`
    /// is the instrument for the promotion wiring and now carries this slice's
    /// mount token too; what is censused HERE is the modifier's own file, which
    /// that test has no entry for.
    func test_theModifierSubscribesToTheEventAndRendersTheHouseBanner() throws {
        let text = try CanvasSourceCensus.source(
            at: "Maugham/Views/CanvasClaudeArrivalModifier.swift")
        for token in [".onProjectEvent(.maughamCanvasNodesAdded",
                      "MCPNoteBanner(",
                      "Self.destination(forRegion:"] {
            XCTAssertTrue(text.contains(token),
                          "the modifier is missing \(token) — without the first it "
                          + "receives nothing, without the second there is no banner "
                          + "on screen, and without the third Show does not navigate")
        }
        // The companion: prove the scan reports an absence rather than always
        // answering true. The plant names a spelling that cannot exist in
        // production — a *plausible* plant goes red under the very mutation it is
        // written to survive.
        XCTAssertFalse(text.contains(".onProjectEvent(.maughamNotARealEvent"),
                       "the scan reads the file rather than always answering true")
    }
}
