import XCTest
import AppKit
import MaughamCore
@testable import Maugham

/// The seam that keeps ONE live `Document` on a statement's path (M1A Task 7,
/// contract 7) — specifically the half the registry cannot cover.
///
/// `ProjectStore.openStatementDocument(id:)` answers for a `Document` that is
/// already open. `Document.load` is `async` and constructs a fresh instance per
/// call, so between "the registry says nobody has this" and "I have registered
/// mine" there is a suspension in which a second opener asks the same question
/// and gets the same answer. Both then hold a live `Document` on one path, each
/// with its own `PendingBuffer`, and the one that loaded first never saw what the
/// other wrote — the writer's promoted paragraph is written back out by the next
/// burst.
///
/// **There are exactly two openers and this file holds each of them to the gate**,
/// because a gate one side ignores is not a gate. Both tests drive the real
/// production path and take the lock by hand, so the interleaving is a fact of
/// the test rather than a race it hopes to win.
@MainActor
final class StatementOpenGateTests: XCTestCase {

    private let a = CanvasNodeID("a")

    private var fixture: StatementMountFixture!

    override func setUp() async throws {
        fixture = try await StatementMountFixture.novel(named: "open-gate")
    }

    override func tearDown() async throws {
        fixture.tearDown()
        fixture = nil
    }

    private func makeModel() -> CanvasModel {
        let model = CanvasModel()
        model.attach(projectRoot: fixture.projectURL)
        model.withScene {
            $0.insert(CanvasNode(id: a, kind: .scrap, origin: .zero,
                                 width: 240, cachedHeight: 80))
        }
        model.setScrapText("The falls at night\n\nSodium light on the spray.", for: a)
        return model
    }

    private func promotionPlan(_ model: CanvasModel) -> PromotionPlan {
        Promotion.plan(
            PromotionRequest(
                source: .scrap(a), target: .intentStatement, mode: .new,
                scraps: model.scraps, paletteKind: .other,
                artifacts: ArtifactIndex.over(research: fixture.store.manifest.research,
                                              statements: fixture.store.manifest.statements,
                                              structure: fixture.store.manifest.structure)),
            in: model.scene)!
    }

    // MARK: - The transient writer

    /// A promotion whose statement nobody has open must still queue behind
    /// whoever is opening it, or its `Document.load` is the second one.
    ///
    /// Falsified by removing the lock from `PromotionPerformer.append`: the
    /// promotion writes while the gate is held, so the first assertion goes red.
    func test_aPromotionWaitsWhileSomebodyElseIsOpeningTheStatement() async throws {
        let statement = try await fixture.store.createStatement(kind: .intent,
                                                                scope: .project)
        let model = makeModel()
        let performer = PromotionPerformer(store: fixture.store, model: model)
        let plan = promotionPlan(model)

        await fixture.store.lockStatementOpen(statement.id)
        let promotion = Task { @MainActor in try await performer.perform(plan) }
        await fixture.waitOut(0.5)

        XCTAssertTrue(fixture.ops(forDocId: statement.id).isEmpty,
                      "the promotion opened its own Document while another opener "
                      + "held the path — that is the second live Document")

        fixture.store.unlockStatementOpen(statement.id)
        _ = try await promotion.value
        await fixture.waitOut(0.3)

        XCTAssertTrue(fixture.derivedText(forDocId: statement.id)
                        .contains("Sodium light on the spray."),
                      "and releasing the gate lets it through — a gate that never "
                      + "opens would pass the assertion above for the wrong reason")
    }

    /// The other direction, which is what makes the re-check inside the gate
    /// load-bearing: while the promotion is queued, the pane binds. It must then
    /// find the live `Document` and write into THAT rather than loading its own.
    func test_aQueuedPromotionUsesThePaneSDocumentWhenOneAppearedMeanwhile() async throws {
        let statement = try await fixture.store.createStatement(kind: .intent,
                                                                scope: .project)
        let model = makeModel()
        let performer = PromotionPerformer(store: fixture.store, model: model)
        let plan = promotionPlan(model)

        await fixture.store.lockStatementOpen(statement.id)
        let promotion = Task { @MainActor in try await performer.perform(plan) }
        await fixture.waitOut(0.4)

        // A pane binds while the promotion is parked. Registered by hand rather
        // than by mounting one, so the ordering is the test's rather than the
        // runloop's; `StatementEditorHost.load` does exactly this pair.
        let paneDocument = try await Document.load(
            url: fixture.projectURL.appendingPathComponent(statement.path),
            device: MacDeviceID.current, session: "pane-test",
            presenter: fixture.documentStore.presenter)
        fixture.store.noteStatementDocumentOpened(paneDocument, id: statement.id)
        fixture.store.unlockStatementOpen(statement.id)
        _ = try await promotion.value

        XCTAssertTrue(paneDocument.displayText.contains("Sodium light on the spray."),
                      "the promotion loaded its own Document instead of the one "
                      + "that had appeared — found: \(paneDocument.displayText)")
        await paneDocument.close()
    }

    // MARK: - The pane

    /// And the pane queues too. Held to the same gate, and observed through the
    /// registry: a pane that opened its own `Document` while a transient writer
    /// held the path would have registered one.
    ///
    /// Falsified by removing the lock from `StatementEditorHost.load`.
    func test_theStatementPaneWaitsWhileATransientWriterHoldsThePath() async throws {
        let statement = try await fixture.store.createStatement(kind: .intent,
                                                                scope: .project)
        await fixture.store.lockStatementOpen(statement.id)

        // Fire-and-forget: with the gate held the pane's `reconcile` parks before
        // `Document.load`, so `host` would sit out its own deadline.
        Task { @MainActor in await self.fixture.host(kind: .intent, activeDocumentId: nil) }
        await fixture.waitOut(0.6)

        XCTAssertNil(fixture.store.openStatementDocument(id: statement.id),
                     "the pane opened a second Document on a path somebody else "
                     + "was already opening")

        fixture.store.unlockStatementOpen(statement.id)
        await fixture.pumpUntil(deadline: 5) {
            self.fixture.store.openStatementDocument(id: statement.id) != nil
        }
        XCTAssertNotNil(fixture.store.openStatementDocument(id: statement.id),
                        "and it binds once the path is free — the control, without "
                        + "which a pane that never mounted would pass the assertion "
                        + "above")
    }

    // MARK: - The gate itself

    /// Waiters are woken in a state they can act on: each re-checks, so releasing
    /// to several at once hands the path to exactly one of them.
    func test_releasingWakesEveryWaiterAndExactlyOneTakesThePath() async throws {
        let store = fixture.store
        await store.lockStatementOpen("stmt-1")

        var order: [Int] = []
        let waiters = (1...3).map { n in
            Task { @MainActor in
                await store.lockStatementOpen("stmt-1")
                order.append(n)
                XCTAssertTrue(store.statementOpensInFlight.contains("stmt-1"))
                store.unlockStatementOpen("stmt-1")
            }
        }
        await fixture.waitOut(0.3)
        XCTAssertTrue(order.isEmpty, "nobody may pass while it is held")

        store.unlockStatementOpen("stmt-1")
        for waiter in waiters { await waiter.value }
        XCTAssertEqual(order.count, 3, "every waiter was woken")
        XCTAssertFalse(store.statementOpensInFlight.contains("stmt-1"),
                       "and the last one out left the path free")
    }

    /// A different statement is not blocked by this one. Without this, the gate
    /// would be a project-wide lock wearing a per-statement name.
    func test_theGateIsPerStatement() async throws {
        let store = fixture.store
        await store.lockStatementOpen("stmt-1")
        await store.lockStatementOpen("stmt-2")   // would hang if it were shared
        store.unlockStatementOpen("stmt-1")
        store.unlockStatementOpen("stmt-2")
    }
}
