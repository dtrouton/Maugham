import XCTest
import AppKit
import SwiftUI
import Observation
import MaughamCore
@testable import Maugham

/// Holds the window's subject and its store outside the view, so a test can
/// mount the real modifier, mutate a real `ProjectStore`, and read what the real
/// `.onChange` wrote.
///
/// The store is `var` and optional because one of the cases under test is the
/// store ARRIVING — `load()`'s own window, where a sweep would clobber the
/// `ui-state.json` the load has not read yet.
@Observable
@MainActor
final class SubjectValidationHarness {
    var store: ProjectStore?
    var subject: BinderSubject?
    init(store: ProjectStore? = nil, subject: BinderSubject? = nil) {
        self.store = store
        self.subject = subject
    }
}

/// The modifier as `ProjectWindow` attaches it, over nothing else at all — so a
/// pass or a fail is about this rule and no other.
@MainActor
private struct SubjectValidationProbeView: View {
    let harness: SubjectValidationHarness

    var body: some View {
        Color.clear
            .modifier(SubjectValidationModifier(
                store: harness.store,
                selectedSubject: Binding(get: { harness.subject },
                                         set: { harness.subject = $0 })))
    }
}

/// The window's subject must never name a row that is not there
/// (`SubjectValidationModifier` + `ProjectWindow.validSubject`).
///
/// **What made this worth a rule of its own.** The repair used to live in
/// `BinderView.deleteItem` as `subject == .item(deletedId) ? nil : subject`,
/// which asks *"is the subject the row I deleted?"*. That is the same question
/// as *"is the subject still in the structure?"* for a document and a different
/// one for a group: `TreeWalk.remove` takes a group's children with it, the
/// selected child's id is not the group's id, and the subject survived naming a
/// row that was gone. It was also only one of three callers of
/// `deleteStructureItem` — `CollectionPiecesPane` and `ReferencePieceInspector`
/// repaired nothing, so on a Collection even the direct case dangled.
///
/// The exposure is not the canvas. `CanvasSubject.resolve` already answers
/// `.wholeProject` for an id it cannot find, so the board looks right;
/// `activeItemID` and `activeDocId` are what carry the dangling id, and through
/// them the editor, History, Tasks and the annotation arms.
@MainActor
final class SubjectValidationTests: XCTestCase {

    private var temp: TempDirectory!
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        temp = TempDirectory()
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = NSView(frame: .zero) }
        pump(0.05)
        windows.removeAll()
        temp.cleanup()
        temp = nil
    }

    // MARK: - The rule, over the shapes that broke

    /// **The defect, stated as a value.** A group is deleted; the subject named
    /// one of its children. The child's id is not the group's, so the rule that
    /// compared ids left it standing.
    func test_deletingAGroupInvalidatesTheChildSubjectItTookWithIt() {
        let before = groupedStructure()
        let after = TreeWalk.remove(id: "grp", in: before)
        XCTAssertFalse(TreeWalk.contains(id: "doc-1", in: after),
                       "fixture assumption: removing the group removes its child")

        XCTAssertEqual(ProjectWindow.validSubject(.item("doc-1"), in: after),
                       .project,
                       "the subject named a row that left with its group")
    }

    /// **Plant: the id-equality rule this replaces.** It is written out here
    /// rather than described, and it must get the case above wrong — a plant
    /// that does not fire is the finding.
    func test_plantedIdEqualityRuleSurvivesTheGroupDeleteAndIsWrong() {
        // `BinderView.subject(_:afterDeleting:)`, verbatim as it shipped.
        func planted(_ subject: BinderSubject?,
                     afterDeleting deletedId: String) -> BinderSubject? {
            subject == .item(deletedId) ? nil : subject
        }
        let after = TreeWalk.remove(id: "grp", in: groupedStructure())

        let plantedAnswer = planted(.item("doc-1"), afterDeleting: "grp")
        XCTAssertEqual(plantedAnswer, .item("doc-1"),
                       "the plant did not fire: it was supposed to leave the "
                       + "child subject standing after its group was deleted")
        XCTAssertFalse(TreeWalk.contains(id: "doc-1", in: after),
                       "…and that subject names nothing")

        XCTAssertEqual(ProjectWindow.validSubject(.item("doc-1"), in: after),
                       .project,
                       "the rule under test must not agree with the plant here")
    }

    /// **The control for that plant.** The two rules agree on the direct case —
    /// delete the document that IS the subject and both move the window off it.
    /// Without this, a plant that differed from the real rule everywhere would
    /// prove nothing about the group.
    func test_thePlantAndTheRuleAgreeOnTheDirectDelete() {
        func planted(_ subject: BinderSubject?,
                     afterDeleting deletedId: String) -> BinderSubject? {
            subject == .item(deletedId) ? nil : subject
        }
        let after = TreeWalk.remove(id: "doc-1", in: groupedStructure())

        XCTAssertNil(planted(.item("doc-1"), afterDeleting: "doc-1"),
                     "the plant moves the window off the deleted document")
        XCTAssertEqual(ProjectWindow.validSubject(.item("doc-1"), in: after),
                       .project,
                       "and so does the rule — to a subject rather than to none")
    }

    /// The other survivor: a sibling's delete moves nothing.
    func test_somebodyElsesDeleteLeavesTheSubjectAlone() {
        let after = TreeWalk.remove(id: "doc-2", in: groupedStructure())
        XCTAssertEqual(ProjectWindow.validSubject(.item("doc-1"), in: after),
                       .item("doc-1"))
    }

    // MARK: - `.project` is never invalidated

    /// `.project` names nothing in the structure, which is exactly why a
    /// containment check written the obvious way clears it.
    func test_theProjectSubjectSurvivesADeleteAndAnEmptyStructure() {
        XCTAssertEqual(
            ProjectWindow.validSubject(.project,
                                       in: TreeWalk.remove(id: "grp",
                                                           in: groupedStructure())),
            .project)
        XCTAssertEqual(ProjectWindow.validSubject(.project, in: []), .project)
    }

    /// **Plant: containment over the extracted id.** *"Take the subject's item
    /// id; if the structure does not hold it, there is no subject."* It is the
    /// shape somebody writes when the question is *"is this still in the tree?"*
    /// and it is correct about every item — but `.project` has no item id, so it
    /// falls through the same door a deleted chapter does and the window is
    /// moved off a subject the writer chose while tidying up elsewhere.
    ///
    /// This is not hypothetical: `restoredSubject` was a bare `TreeWalk.contains`
    /// over the item id before the project row existed, and the project subject
    /// failed that check silently.
    func test_plantedContainmentOverTheExtractedIdClearsTheProjectSubject() {
        func planted(_ subject: BinderSubject?,
                     in structure: [StructureItem]) -> BinderSubject? {
            guard let id = subject?.itemID,
                  TreeWalk.contains(id: id, in: structure) else { return nil }
            return .item(id)
        }
        let structure = groupedStructure()

        XCTAssertNil(planted(.project, in: structure),
                     "the plant did not fire: it was supposed to lose the "
                     + "project subject, which is in no structure")
        // The control — it is right about a live item, so it is not a rule that
        // is simply wrong about everything it is shown.
        XCTAssertEqual(planted(.item("doc-1"), in: structure), .item("doc-1"))

        // The rule under test asks about the SUBJECT, not about an id extracted
        // from one, which is the whole reason `.project` survives it.
        XCTAssertEqual(ProjectWindow.validSubject(.project, in: structure),
                       .project)
    }

    /// **Plant: the historical fallback.** The same containment check, falling
    /// to the first document rather than to nothing — the rule that shipped
    /// before slice 3's Critical. It loses the project subject too, and it is
    /// the more dangerous of the two on the canvas: a document subject FILTERS
    /// the board, so the window enters the dim with no click.
    func test_plantedFirstDocumentFallbackLosesTheProjectSubjectIntoTheDim() throws {
        func planted(_ subject: BinderSubject?,
                     in structure: [StructureItem]) -> BinderSubject? {
            if let id = subject?.itemID, TreeWalk.contains(id: id, in: structure) {
                return .item(id)
            }
            return TreeWalk.first(in: structure, where: { $0.type == .document })
                .map { BinderSubject.item($0.id) }
        }
        let structure = groupedStructure()

        let plantedAnswer = try XCTUnwrap(planted(.project, in: structure))
        XCTAssertEqual(plantedAnswer, .item("doc-1"),
                       "the plant did not fire: it was supposed to move the "
                       + "project subject onto a chapter nobody chose")
        XCTAssertTrue(
            CanvasSubject.resolve(plantedAnswer, in: structure).dimsTheBoard,
            "…and that is what puts the canvas into the dim without a click")

        let real = ProjectWindow.validSubject(.project, in: structure)
        XCTAssertEqual(real, .project)
        XCTAssertFalse(CanvasSubject.resolve(real, in: structure).dimsTheBoard)
    }

    // MARK: - The trigger

    /// **A rename cannot fire the sweep, and not because of timing.** The
    /// trigger is the set of ids; `renameStructureItem` preserves every id, so
    /// the value is byte-identical and there is no change to deliver.
    func test_theTriggerIsBlindToTitlesOrderAndNesting() {
        let base = groupedStructure()
        let fingerprint = SubjectValidationModifier.fingerprint(of: base)

        var renamed = TreeWalk.mutate(id: "doc-1", in: base) { item in
            var item = item
            item.title = "Chapter One, Revised"
            item.path = "manuscript/01-part-one/01-chapter-one-revised.md"
            return item
        }
        XCTAssertEqual(SubjectValidationModifier.fingerprint(of: renamed), fingerprint,
                       "a rename must be invisible to the trigger")

        // Reorder within the group.
        renamed = TreeWalk.mutate(id: "grp", in: renamed) { group in
            var group = group
            group.children = group.children.map { Array($0.reversed()) }
            return group
        }
        XCTAssertEqual(SubjectValidationModifier.fingerprint(of: renamed), fingerprint,
                       "a reorder moves no id in or out")

        // Reparent everything to the root — the drop case.
        let flattened = TreeWalk.collect(in: base, where: { _ in true })
            .map { item -> StructureItem in
                var item = item
                item.children = nil
                return item
            }
        XCTAssertEqual(SubjectValidationModifier.fingerprint(of: flattened), fingerprint,
                       "a reparent moves no id in or out")
    }

    /// …and it does fire on the two changes that can invalidate a subject. The
    /// control for the test above: a trigger that never changed would pass that
    /// one perfectly.
    func test_theTriggerMovesWhenAnIdLeavesOrArrives() {
        let base = groupedStructure()
        let fingerprint = SubjectValidationModifier.fingerprint(of: base)

        XCTAssertNotEqual(
            SubjectValidationModifier.fingerprint(of: TreeWalk.remove(id: "doc-1", in: base)),
            fingerprint)
        XCTAssertNotEqual(
            SubjectValidationModifier.fingerprint(of: TreeWalk.remove(id: "grp", in: base)),
            fingerprint,
            "removing the group removes three ids, not one")
        XCTAssertNotEqual(
            SubjectValidationModifier.fingerprint(
                of: base + [StructureItem(id: "doc-3", title: "Chapter 3",
                                          type: .document, path: "manuscript/03.md")]),
            fingerprint)
    }

    /// An empty structure has a fingerprint like any other. *"No store"* is
    /// carried by the optional around it, never by an empty value — otherwise a
    /// window whose last document is deleted and a window with no store yet look
    /// identical to the trigger.
    func test_anEmptyStructureIsNotTheAbsenceOfAStructure() {
        XCTAssertNotEqual(SubjectValidationModifier.fingerprint(of: []),
                          SubjectValidationModifier.fingerprint(of: groupedStructure()))
    }

    // MARK: - Through the mounted modifier, on the real delivery path

    /// The headline case, driven: a real group deleted through the real store,
    /// with the child selected.
    func test_mounted_deletingTheGroupMovesTheWindowOffItsChild() async throws {
        let store = try await novel(named: "GroupDelete")
        let group = try await store.addStructureItem(
            parentId: nil, title: "Part One", kind: .group)
        let child = try await store.addStructureItem(
            parentId: group.id, title: "Chapter A", kind: .document(extension: "md"))
        let harness = SubjectValidationHarness(store: store, subject: .item(child.id))
        try await host(harness)

        try await store.deleteStructureItem(id: group.id)
        await settle()

        XCTAssertFalse(TreeWalk.contains(id: child.id, in: store.manifest.structure),
                       "fixture assumption: the child went with the group")
        XCTAssertEqual(harness.subject, .project,
                       "the window was left naming a chapter that no longer exists")
    }

    /// The direct case, driven — and driven from a site that has no repair of
    /// its own. `CollectionPiecesPane` and `ReferencePieceInspector` both delete
    /// exactly like this, which is why keying the rule on the STRUCTURE rather
    /// than on the deletion is what fixes them.
    func test_mounted_deletingTheSelectedPieceOfACollectionMovesTheWindowOff() async throws {
        let url = try await ProjectFactory.createCollectionProject(
            named: "Coll-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let piece = try await store.addLoosePiece(title: "A Piece", mode: .prose)
        let harness = SubjectValidationHarness(store: store, subject: .item(piece.id))
        try await host(harness)

        try await store.deleteStructureItem(id: piece.id)
        await settle()

        XCTAssertEqual(harness.subject, .project)
    }

    /// **The transient probe.** A rename of the SELECTED item is the mutation
    /// most likely to clear a selection by accident: it rewrites the item's
    /// title and its path, and it moves the file on disk across an `await`. The
    /// subject must come out the other side untouched.
    func test_mounted_renamingTheSelectedItemDoesNotDisturbTheSubject() async throws {
        let store = try await novel(named: "Rename")
        let doc = try XCTUnwrap(store.manifest.structure.first)
        let harness = SubjectValidationHarness(store: store, subject: .item(doc.id))
        try await host(harness)

        try await store.renameStructureItem(id: doc.id, newTitle: "A New Name")
        await settle()

        XCTAssertEqual(harness.subject, .item(doc.id),
                       "a rename must not move the window off what it renamed")
    }

    /// The same for a move, which removes the item from the structure and puts
    /// it back inside one synchronous stretch.
    func test_mounted_movingTheSelectedItemDoesNotDisturbTheSubject() async throws {
        let store = try await novel(named: "Move")
        // `moveStructureItem` relocates through the typed mover and refuses
        // without one (tripwire 14), so this is the fixture the real path needs.
        let ds = try await DocumentStore.open(url: store.url)
        store.documentStore = ds
        defer { store.documentStore = nil }

        let doc = try XCTUnwrap(store.manifest.structure.first)
        let group = try await store.addStructureItem(
            parentId: nil, title: "Part One", kind: .group)
        let harness = SubjectValidationHarness(store: store, subject: .item(doc.id))
        try await host(harness)

        try await store.moveStructureItem(id: doc.id, toParentId: group.id, atIndex: 0)
        await settle()

        XCTAssertEqual(harness.subject, .item(doc.id))
        XCTAssertTrue(TreeWalk.contains(id: doc.id, in: store.manifest.structure),
                      "fixture assumption: the move actually happened")
        await ds.close()
    }

    /// A delete elsewhere must not take the project subject with it — the value
    /// the old rule was careful about, kept here now that the rule moved.
    func test_mounted_theProjectSubjectSurvivesADeleteElsewhere() async throws {
        let store = try await novel(named: "ProjectSurvives")
        let doc = try XCTUnwrap(store.manifest.structure.first)
        let harness = SubjectValidationHarness(store: store, subject: .project)
        try await host(harness)

        try await store.deleteStructureItem(id: doc.id)
        await settle()

        XCTAssertEqual(harness.subject, .project,
                       "the writer chose the project while tidying up elsewhere")
    }

    /// A window with no subject is not given one. The sweep repairs a subject;
    /// choosing one is the restore's job and the writer's.
    func test_mounted_aWindowWithNoSubjectIsNotGivenOne() async throws {
        let store = try await novel(named: "NoSubject")
        let doc = try XCTUnwrap(store.manifest.structure.first)
        let harness = SubjectValidationHarness(store: store, subject: nil)
        try await host(harness)

        try await store.deleteStructureItem(id: doc.id)
        await settle()

        XCTAssertNil(harness.subject)
    }

    /// **The structure APPEARING is not the structure changing.** `load()` sets
    /// `store`, then awaits, then reads `ui-state.json` — a sweep in that gap
    /// would write `.project` back through `updateUIState` into the very value
    /// the load is about to read, and every reopen would land on the project
    /// row. The subject here is deliberately one the structure does not contain:
    /// if the guard were missing, this is where it would be repaired.
    func test_mounted_theStoreArrivingDoesNotSweep() async throws {
        let store = try await novel(named: "Arriving")
        let harness = SubjectValidationHarness(store: nil, subject: .item("not-here"))
        try await host(harness)

        harness.store = store
        await settle()

        XCTAssertEqual(harness.subject, .item("not-here"),
                       "the sweep ran inside load()'s window and would have "
                       + "clobbered the saved subject before load() read it")
    }

    // MARK: - The sweep is reachable from the window

    /// **The half a mounted test cannot see.** Every mounted case above attaches
    /// `SubjectValidationModifier` itself, so they stay green with the window
    /// not attaching it at all — measured, by deleting the line from
    /// `ProjectWindow.body` and watching all sixteen pass. This codebase has
    /// found three unreachable halves by counting callers rather than by any
    /// test going red, so the attachment is asserted where it is made.
    ///
    /// A source scan rather than a mounted `ProjectWindow`: the window needs a
    /// project on disk, an MCP registry and a load, and none of that is what is
    /// in doubt — whether one line is present is.
    func test_theWindowAttachesTheSweep() throws {
        let source = try String(contentsOf: projectWindowSource, encoding: .utf8)
        XCTAssertTrue(source.contains("SubjectValidationModifier(store: store,"),
                      "ProjectWindow does not attach the sweep, so nothing in "
                      + "production validates the subject on a structure change")

        // The control: the same scan over a copy with the attachment removed
        // must fail, so a rename of the modifier cannot leave this passing on a
        // doc-comment mention.
        let planted = source.replacingOccurrences(
            of: "SubjectValidationModifier(store: store,", with: "// removed")
        XCTAssertFalse(planted.contains("SubjectValidationModifier(store: store,"),
                       "the planted offender did not fire")
    }

    private var projectWindowSource: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamTests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Maugham/Views/ProjectWindow.swift")
    }

    // MARK: - Fixtures

    private func groupedStructure() -> [StructureItem] {
        [
            StructureItem(
                id: "grp", title: "Part One", type: .group,
                path: "manuscript/01-part-one",
                children: [
                    StructureItem(id: "doc-1", title: "Chapter 1", type: .document,
                                  path: "manuscript/01-part-one/01-chapter-1.md"),
                    StructureItem(id: "doc-2", title: "Chapter 2", type: .document,
                                  path: "manuscript/01-part-one/02-chapter-2.md")
                ])
        ]
    }

    private func novel(named name: String) async throws -> ProjectStore {
        let url = try await ProjectFactory.createNovelProject(
            named: "\(name)-\(UUID().uuidString.prefix(6))", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        await store.wordCountPopulationTask?.value
        return store
    }

    // MARK: - Hosting and driving

    private func host(_ harness: SubjectValidationHarness) async throws {
        let frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        let hosting = NSHostingView(
            rootView: AnyView(SubjectValidationProbeView(harness: harness)))
        hosting.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        // Let the first body pass run, so `.onChange` has an old value to
        // compare against rather than an arrival.
        await settle()
    }

    private func settle() async {
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            pump(0.02)
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func pump(_ seconds: TimeInterval = 0.15) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
