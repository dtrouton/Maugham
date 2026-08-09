import XCTest
import MaughamCore
@testable import Maugham

/// Spec §6.3, performed: a region's promotion stamps every card whose words
/// went into the artifact, **in the same undo bracket as the region's own
/// mark**.
///
/// `PromotionContributionTests` pins the record's shape and the guard that
/// keeps it from being read as an Update. This file is the other half — the
/// performer actually writing it, against a real `ProjectStore` on a real temp
/// project, because the stamping and the region's mark have to arrive as ONE
/// undo step and only a real `CanvasModel` with `CanvasUndo` attached can show
/// that.
///
/// The house pattern is `PromotionPerformerTests`': a per-file helper, not a
/// shared fixture. There is no `TestProjectFixture` in this codebase.
@MainActor
final class PromotionContributionPerformerTests: XCTestCase {

    /// `a` above `b` above `c` above `d`, so reading order is alphabetical here
    /// and the assertions read as the writer's own arrangement.
    private let a = CanvasNodeID("a")
    private let b = CanvasNodeID("b")
    private let c = CanvasNodeID("c")
    private let d = CanvasNodeID("d")
    private let r1 = CanvasRegionID("r1")

    /// `ProjectStore.documentStore` is a WEAK var, so the test has to hold the
    /// stores it wires. Closed in `tearDown`.
    private var documentStores: [DocumentStore] = []
    private var temp: TempDirectory!

    override func setUp() async throws { temp = TempDirectory() }

    override func tearDown() async throws {
        for ds in documentStores { await ds.close() }
        documentStores = []
        temp = nil
    }

    private func makeProject() async throws -> (URL, ProjectStore) {
        let tmp = temp.url.appendingPathComponent("PC-\(UUID())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        for sub in ["manuscript", "research"] {
            try FileManager.default.createDirectory(
                at: tmp.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let manifest = ProjectManifest(
            type: .novel, title: "T", author: "A",
            created: Date(), modified: Date(), structure: [], research: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: tmp.appendingPathComponent("project.maugham.json"))
        let store = try await ProjectStore.load(from: tmp)
        let ds = try await DocumentStore.open(url: tmp)
        store.documentStore = ds
        documentStores.append(ds)
        return (tmp, store)
    }

    /// Four cards and one region:
    ///
    /// - `a`, `b` — home members with text. The contributors.
    /// - `c` — an APPEARANCE, cited in the region and resident nowhere in it.
    ///   Its words are not what the promotion joins.
    /// - `d` — a home member whose card is EMPTY. Its words never reached the
    ///   note either.
    ///
    /// **`attach` before the inserts**, and it is not decoration: `CanvasUndo`'s
    /// snapshot closures are wired there, so a bare `CanvasModel` registers no
    /// undo step at all and the one-⌘Z test would pass on an empty stack.
    private func makeModel(at root: URL) -> CanvasModel {
        let model = CanvasModel()
        model.attach(projectRoot: root)
        model.withScene { s in
            for (id, y) in [(a, 0.0), (b, 200.0), (c, 400.0), (d, 600.0)] {
                s.insert(CanvasNode(id: id, kind: .scrap, origin: CGPoint(x: 0, y: y),
                                    width: 240, cachedHeight: 80))
            }
            s.insertRegion(CanvasRegion(id: r1, label: "Act II fog",
                                        frame: CGRect(x: 0, y: 0, width: 600, height: 800),
                                        homeMembers: [a, b, d], appearances: [c]))
        }
        model.setScrapText("The falls at night", for: a)
        model.setScrapText("October's doctor", for: b)
        model.setScrapText("Cited, not resident", for: c)
        model.setScrapText("   \n  ", for: d)
        return model
    }

    private func index(_ store: ProjectStore) -> ArtifactIndex {
        ArtifactIndex.over(research: store.manifest.research,
                           statements: store.manifest.statements,
                           structure: store.manifest.structure)
    }

    private func plan(_ source: PromotionSource, _ target: PromotionTarget,
                      store: ProjectStore, model: CanvasModel,
                      mode: PromotionMode = .new,
                      kind: PaletteCard.Kind = .other) -> PromotionPlan {
        Promotion.plan(
            PromotionRequest(source: source, target: target, mode: mode,
                             scraps: model.scraps, paletteKind: kind,
                             artifacts: index(store)),
            in: model.scene)!
    }

    private func contribution(_ id: CanvasNodeID, in model: CanvasModel) -> String? {
        model.scene.node(id)?.contributedToItemID
    }

    // MARK: - A region → research note records its contributors

    /// The writer's own report, fixed: *"not all the scraps know they were
    /// promoted, some think they weren't — all did turn up in the research note
    /// though."*
    func test_everyContributingMemberCarriesTheProducedNotesID() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let result = try await PromotionPerformer(store: store, model: model)
            .perform(plan(.region(r1), .researchNote, store: store, model: model))
        let itemID = try XCTUnwrap(result.createdItemID)

        XCTAssertEqual(contribution(a, in: model), itemID)
        XCTAssertEqual(contribution(b, in: model), itemID,
                       "every card whose words are in the note says so, not only the "
                       + "ones promoted individually earlier")
        XCTAssertEqual(model.scene.region(r1)?.promotedItemID, itemID,
                       "and the region still carries the mark it always did")
    }

    /// §6.3: exactly the members whose text went in. A card with nothing in it
    /// contributed nothing.
    func test_anEmptyMemberCarriesNoRecord() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let result = try await PromotionPerformer(store: store, model: model)
            .perform(plan(.region(r1), .researchNote, store: store, model: model))
        XCTAssertNil(contribution(d, in: model),
                     "an empty member's words never reached the note")
        XCTAssertEqual(contribution(a, in: model), result.createdItemID,
                       "the control: this promotion did record somebody, so the "
                       + "assertion above is not passing on a field nothing writes")
    }

    /// An appearance is a citation, not luggage — `regionBodies` reads home
    /// members only, so the record follows the body.
    func test_aCitedButNonResidentCardCarriesNoRecord() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let result = try await PromotionPerformer(store: store, model: model)
            .perform(plan(.region(r1), .researchNote, store: store, model: model))
        XCTAssertNil(contribution(c, in: model))
        XCTAssertEqual(contribution(a, in: model), result.createdItemID,
                       "the control, as above")
        let note = try XCTUnwrap(TreeWalk.first(in: store.manifest.research,
                                                where: { $0.title == "Act II fog" }))
        let text = try String(contentsOf: root.appendingPathComponent(note.path ?? ""),
                             encoding: .utf8)
        XCTAssertFalse(text.contains("Cited, not resident"),
                       "the control: the record and the body name the same set, so a "
                       + "test asserting one is asserting the other")
    }

    /// **One gesture, one undo step** (§6.3). The region's mark and every
    /// contribution record are written in a single bracket, or a ⌘Z leaves cards
    /// claiming a note the region no longer names.
    ///
    /// **A scene-only assertion cannot see the defect this pins.** A second
    /// bracket for the stamping registers a second step, and undoing once takes
    /// back only the records — so the discriminator is the STEP: its name at the
    /// top of the stack, and the name UNDERNEATH it after one ⌘Z. An unrelated
    /// step is put on first so that "exactly one was consumed" is observable.
    func test_oneUndoTakesBackTheMarkAndEveryRecordInOneStep() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        model.undoManager.groupsByEvent = false
        // A genuinely DIFFERENT label: `CanvasUndo.endGesture` registers only when
        // the state moved, so renaming to the name it already has puts no step on
        // the stack and "exactly one was consumed" would have nothing to land on.
        model.mutate("Rename Region") { $0.updateRegion(r1) { $0.label = "Fog, act II" } }

        let result = try await PromotionPerformer(store: store, model: model)
            .perform(plan(.region(r1), .researchNote, store: store, model: model))
        XCTAssertEqual(contribution(a, in: model), result.createdItemID,
                       "the control: there are records to take back at all, or the "
                       + "nil assertions below hold on a field nothing writes")
        XCTAssertTrue(model.undoManager.undoMenuItemTitle.contains("Promotion Mark"),
                      "found: \(model.undoManager.undoMenuItemTitle)")

        model.undo.undo()
        XCTAssertNil(try XCTUnwrap(model.scene.region(r1)).promotedItemID)
        XCTAssertNil(contribution(a, in: model),
                     "one ⌘Z takes the whole promotion's canvas-side effect back")
        XCTAssertNil(contribution(b, in: model))
        XCTAssertTrue(model.undoManager.undoMenuItemTitle.contains("Rename Region"),
                      "exactly ONE step was consumed — a second bracket for the "
                      + "stamping would leave a second \"Promote Region\" on top. "
                      + "found: \(model.undoManager.undoMenuItemTitle)")
    }

    /// The other column can be mutating while the canvas holds "Edit Scrap"
    /// open (tripwire 32), and the records ride the same verb as the mark — so
    /// they must not fold into the writer's sentence either.
    func test_theRecordsAreTheirOwnStepEvenWithAScrapGestureOpen() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        model.undoManager.groupsByEvent = false
        model.beginGesture("Edit Scrap")
        let result = try await PromotionPerformer(store: store, model: model)
            .perform(plan(.region(r1), .researchNote, store: store, model: model))

        XCTAssertEqual(contribution(a, in: model), result.createdItemID,
                       "the control: the records were written at all, so the undo "
                       + "assertions below are not passing vacuously")
        XCTAssertTrue(model.undoManager.undoMenuItemTitle.contains("Promotion Mark"),
                      "found: \(model.undoManager.undoMenuItemTitle)")
        model.endGesture()
        model.undo.undo()
        XCTAssertNil(contribution(a, in: model))
        XCTAssertNil(contribution(b, in: model))
    }

    // MARK: - An update re-records (§6.3)

    /// The note is rewritten from the CURRENT members, so the record follows the
    /// same set: a card that has left stops claiming it, a card that joined
    /// starts.
    func test_anUpdateClearsADepartedMemberAndStampsANewlyJoinedOne() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let performer = PromotionPerformer(store: store, model: model)
        let first = try await performer.perform(
            plan(.region(r1), .researchNote, store: store, model: model))
        let itemID = try XCTUnwrap(first.createdItemID)
        XCTAssertEqual(contribution(b, in: model), itemID, "b was in the first note")

        // `b` leaves; `d` gains words and is already home.
        model.mutate("Move Card") { $0.updateRegion(r1) { $0.forget(self.b) } }
        model.setScrapText("The ponchos", for: d)

        let existing = try XCTUnwrap(
            Promotion.existingArtifact(for: .region(r1), target: .researchNote,
                                       in: model.scene, artifacts: index(store)))
        let second = try await performer.perform(
            plan(.region(r1), .researchNote, store: store, model: model, mode: existing))
        XCTAssertEqual(second.createdItemID, itemID, "the same note, rewritten")

        XCTAssertEqual(contribution(a, in: model), itemID)
        XCTAssertEqual(contribution(d, in: model), itemID,
                       "a card that joined the region's text must start claiming it")
        XCTAssertNil(contribution(b, in: model),
                     "a card whose words are no longer in the note must stop "
                     + "claiming it — the note was rewritten without them")
    }

    /// The rebuild clears records naming THIS artifact and nothing else. A card
    /// contributing to another region's note keeps its own record.
    func test_anUpdateLeavesAnotherArtifactsRecordAlone() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let performer = PromotionPerformer(store: store, model: model)
        let first = try await performer.perform(
            plan(.region(r1), .researchNote, store: store, model: model))
        let itemID = try XCTUnwrap(first.createdItemID)
        // `c` is not a contributor here; give it a record from somewhere else.
        model.mutateFromInspector("Other") { $0.setContributedItem("res-elsewhere", for: self.c) }

        let existing = try XCTUnwrap(
            Promotion.existingArtifact(for: .region(r1), target: .researchNote,
                                       in: model.scene, artifacts: index(store)))
        _ = try await performer.perform(
            plan(.region(r1), .researchNote, store: store, model: model, mode: existing))

        XCTAssertEqual(contribution(c, in: model), "res-elsewhere",
                       "the rebuild is scoped to the artifact being rewritten")
        XCTAssertEqual(contribution(a, in: model), itemID)
    }

    // MARK: - The palette card records the same way

    func test_aRegionPromotedToAPaletteCardRecordsItsContributorsToo() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let result = try await PromotionPerformer(store: store, model: model)
            .perform(plan(.region(r1), .paletteCard, store: store, model: model,
                          kind: .location))
        let itemID = try XCTUnwrap(result.createdItemID)

        XCTAssertEqual(contribution(a, in: model), itemID)
        XCTAssertEqual(contribution(b, in: model), itemID,
                       "a palette card made of six cards' words is the same shape of "
                       + "artifact; §6.3 does not distinguish them")
        XCTAssertNil(contribution(d, in: model))
    }

    // MARK: - The record is single-valued, and that is intended

    /// **A card's words can genuinely be in two notes, and the record names only
    /// the later one.** Reachable and deliberate, pinned here so the next author
    /// meets a decision rather than what looks like a lost record: card `a`
    /// lives in `r1`, `r1` is promoted so `a` records that note; `a` is dragged
    /// into `r2` (`join` moves the home — there is only ever one), `r2` is
    /// promoted, and the stamp OVERWRITES `a`'s record. The first note was never
    /// rewritten, so `a`'s words really are in both.
    ///
    /// The scoped clear is what protects `b` — a promotion cannot wipe a record
    /// naming somebody else's note. It does not, and is not meant to, stop a
    /// card's own record moving on. Recording a *set* instead would put a
    /// growing, never-collected list of danglable ids on every node to describe
    /// a snapshot the writer took once.
    func test_aSecondRegionsPromotionOverwritesTheRecordRatherThanAddingToIt() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let performer = PromotionPerformer(store: store, model: model)

        let first = try await performer
            .perform(plan(.region(r1), .researchNote, store: store, model: model))
        XCTAssertEqual(contribution(a, in: model), first.createdItemID)
        XCTAssertEqual(contribution(b, in: model), first.createdItemID)

        // The drag: `a` moves house. `b` stays in `r1`.
        let r2 = CanvasRegionID("r2")
        model.withScene { s in
            s.insertRegion(CanvasRegion(id: r2, label: "The falls",
                                        frame: CGRect(x: 800, y: 0, width: 400, height: 400)))
            CanvasMembership.join(self.a, home: r2, in: &s)
        }

        let second = try await performer
            .perform(plan(.region(r2), .researchNote, store: store, model: model))
        XCTAssertNotEqual(second.createdItemID, first.createdItemID, "a second note")
        XCTAssertEqual(contribution(a, in: model), second.createdItemID,
                       "single-valued: the most recent contribution wins")
        XCTAssertEqual(contribution(b, in: model), first.createdItemID,
                       "the clear is scoped to the artifact, so this promotion "
                       + "could not touch a record naming another note")
        // And the words really are in both — the first note was never rewritten,
        // which is what makes the overwrite a cost rather than a correction.
        XCTAssertNotNil(TreeWalk.find(id: first.createdItemID!,
                                      in: store.manifest.research),
                        "the first note is still in the project")
    }

    // MARK: - A scrap records nothing

    /// `contributors` is empty for a scrap source, so the stamping is a no-op —
    /// and the promoted card carries its own mark, not a contribution record.
    /// The two fields say different things and this is where they must not be
    /// confused.
    func test_aScrapPromotionRecordsNoContribution() async throws {
        let (root, store) = try await makeProject()
        let model = makeModel(at: root)
        let result = try await PromotionPerformer(store: store, model: model)
            .perform(plan(.scrap(a), .researchNote, store: store, model: model))

        XCTAssertEqual(model.scene.node(a)?.promotedItemID, result.createdItemID)
        XCTAssertNil(contribution(a, in: model),
                     "a card that produced its own note is the artifact, not a "
                     + "contributor to somebody else's")
        for id in [b, c, d] { XCTAssertNil(contribution(id, in: model)) }
    }
}
