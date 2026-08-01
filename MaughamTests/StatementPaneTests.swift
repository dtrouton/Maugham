import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// The Intent and Visual Language panes (M1A Task 5): where they appear, which
/// scope they show, and one pinned harmless behaviour.
@MainActor
final class StatementPaneTests: XCTestCase {

    private var fixtures: [StatementMountFixture] = []

    override func tearDown() async throws {
        for fixture in fixtures { fixture.tearDown() }
        fixtures.removeAll()
        try await super.tearDown()
    }

    private func fixture(named name: String) async throws -> StatementMountFixture {
        let made = try await StatementMountFixture.novel(named: name)
        fixtures.append(made)
        return made
    }

    // MARK: - The registry (spec §4.1, umbrella spec §6.3)

    /// §6.3 gives Intent a cell in every persona and Visual language a cell in
    /// Plan, Review and Publish — the shape `Persona.swift` reserved. The whole
    /// matrix is checked by `PersonaPaneRegistryTests`; this pins the two rows
    /// this task consumes, so a sweep that drops one names the milestone that
    /// added it.
    func test_intentIsOfferedByEveryPersona() {
        for persona in Persona.allCases {
            XCTAssertTrue(persona.panes.contains(.intent),
                          "\(persona) does not offer Intent, which §6.3 marks ● or ○ "
                          + "for all four personas")
        }
    }

    func test_visualLanguageIsOfferedByPlanReviewAndPublishOnly() {
        XCTAssertEqual(
            Set(Persona.allCases.filter { $0.panes.contains(.visualLanguage) }),
            [.plan, .review, .publish],
            "§6.3 marks Visual language — for Author (the book has one look, and "
            + "authoring is not where it is decided)")
    }

    /// Each pane needs a `⌘⌥` letter of its own. The letters themselves are
    /// checked against `docs/guide/reference.md` by `DocSyncTests`; what this
    /// pins is that the two new segments did not take one already in use.
    func test_theTwoNewPanesDoNotCollideWithAnExistingShortcut() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Maugham/MaughamApp.swift"),
            encoding: .utf8)
        let tokens = DocSyncTests.extractCommandOptionShortcutTokens(from: source)
        XCTAssertGreaterThanOrEqual(tokens.count, DetailSegment.allCases.count,
                                    "the extractor found \(tokens.count) ⌘⌥ shortcuts, "
                                    + "fewer than there are panes — it is reading nothing")
        XCTAssertEqual(Set(tokens).count, tokens.count,
                       "two View-menu commands share a ⌘⌥ letter: "
                       + "\(tokens.sorted())")
    }

    // MARK: - Scope follows selection (spec §4.3)

    private var structure: [StructureItem] {
        [
            StructureItem(id: "doc-1", title: "Chapter One", type: .document,
                          path: "manuscript/01.md"),
            StructureItem(id: "grp-1", title: "Act One", type: .group, path: nil),
        ]
    }

    func test_intentFollowsTheSelectedDocument() {
        XCTAssertEqual(
            StatementPane.effectiveScope(
                kind: .intent, activeDocumentId: "doc-1",
                structure: structure, prefersProjectScope: false),
            .document("doc-1"))
    }

    func test_intentFallsBackToTheProjectWhenNothingIsSelected() {
        XCTAssertEqual(
            StatementPane.effectiveScope(
                kind: .intent, activeDocumentId: nil,
                structure: structure, prefersProjectScope: false),
            .project)
    }

    /// The right pane's "no selection" sentinel is a real value that flows in
    /// here, not a hypothetical: `ProjectWindow` passes `"__no-selection__"`.
    func test_intentTreatsTheNoSelectionSentinelAsTheProject() {
        XCTAssertEqual(
            StatementPane.effectiveScope(
                kind: .intent, activeDocumentId: "__no-selection__",
                structure: structure, prefersProjectScope: false),
            .project)
    }

    /// A group is not something a writer writes in, so it holds no intent of its
    /// own — `createStatement` throws `.structureMissing` for one, and the pane
    /// must never ask.
    func test_intentFallsBackToTheProjectForAGroup() {
        XCTAssertEqual(
            StatementPane.effectiveScope(
                kind: .intent, activeDocumentId: "grp-1",
                structure: structure, prefersProjectScope: false),
            .project)
    }

    func test_intentFallsBackToTheProjectForAnIdThatIsNotInThisProject() {
        XCTAssertEqual(
            StatementPane.effectiveScope(
                kind: .intent, activeDocumentId: "doc-from-another-project",
                structure: structure, prefersProjectScope: false),
            .project)
    }

    /// The other one is a click away: asking for the project's intent while a
    /// document is selected gives the project's.
    func test_theProjectsIntentIsOneClickAwayFromADocuments() {
        XCTAssertEqual(
            StatementPane.effectiveScope(
                kind: .intent, activeDocumentId: "doc-1",
                structure: structure, prefersProjectScope: true),
            .project)
    }

    /// Visual language is project-scope only — the book has one look (§2.1). It
    /// ignores the selection and the switch alike, over every input.
    func test_visualLanguageIsAlwaysProjectScope() {
        for activeId in [nil, "doc-1", "grp-1", "__no-selection__"] as [String?] {
            for prefersProject in [true, false] {
                XCTAssertEqual(
                    StatementPane.effectiveScope(
                        kind: .visualLanguage, activeDocumentId: activeId,
                        structure: structure, prefersProjectScope: prefersProject),
                    .project,
                    "visual language resolved off the project for "
                    + "(\(activeId ?? "nil"), prefersProject: \(prefersProject))")
            }
        }
    }

    // MARK: - A requested scope (M1A Task 7: Open on a promoted card)

    /// **Open** on a card promoted to a chapter's intent takes the pane to THAT
    /// chapter's, whatever the binder has selected. Without it the writer is
    /// shown an intent that is not the one the card produced — frequently an
    /// empty one — and either concludes the promotion did nothing or types into
    /// the wrong scope believing it is the one they just added to.
    func test_aRequestedScopeWinsOverTheSelection() {
        XCTAssertEqual(
            StatementPane.effectiveScope(
                kind: .intent, activeDocumentId: "doc-1",
                structure: structure, prefersProjectScope: false,
                requested: .project),
            .project)
        XCTAssertEqual(
            StatementPane.effectiveScope(
                kind: .intent, activeDocumentId: nil,
                structure: structure, prefersProjectScope: false,
                requested: .document("doc-1")),
            .document("doc-1"))
    }

    /// **The switch is asked first, and that is what keeps it a live control**
    /// (fix round 2). With the request outranking it, the writer pressed Project
    /// on a pane pinned by Open and nothing happened — the dead control this
    /// codebase refuses elsewhere (`PromotionTarget.namesItsArtifact`).
    func test_theProjectSwitchOutranksARequest() {
        XCTAssertEqual(
            StatementPane.effectiveScope(
                kind: .intent, activeDocumentId: "doc-1",
                structure: structure, prefersProjectScope: true,
                requested: .document("doc-1")),
            .project)
    }

    /// The other half of "the later act wins", and it is why the rule above is
    /// not simply "the switch beats Open": a request arriving after a switch
    /// press resets the switch (`.onChange(of: scopeRequest)`), so an Open is
    /// never swallowed either.
    func test_aFreshRequestIsNotSwallowedByAnEarlierSwitchPress() {
        XCTAssertEqual(
            StatementPane.effectiveScope(
                kind: .intent, activeDocumentId: "doc-1",
                structure: structure, prefersProjectScope: false,
                requested: .document("doc-1")),
            .document("doc-1"),
            "with the switch reset, the request is what answers")
    }

    // MARK: - The switch's highlight (fix round 3, N2)

    /// **The highlighted segment agrees with what the pane is SHOWING, over the
    /// whole product of the inputs.** Nothing asserted this, and it was false in
    /// the commonest case an Open produces: a `.project` request with a document
    /// selected highlighted the DOCUMENT segment over the project's intent —
    /// and pressing that highlighted segment wrote the `prefersProjectScope` it
    /// already held, so nothing happened and the chapter's intent was
    /// unreachable for the life of the request.
    ///
    /// Falsified by binding the highlight to `prefersProjectScope` again: the
    /// `.project`-request rows go red.
    func test_theHighlightedSegmentAgreesWithWhatThePaneIsShowing() {
        let requests: [Statement.Scope?] = [
            nil, .project, .document("doc-1"), .document("grp-1"), .unknown("?")]
        for activeId in [nil, "doc-1", "grp-1", "__no-selection__"] as [String?] {
            for prefers in [true, false] {
                for requested in requests {
                    let scope = StatementPane.effectiveScope(
                        kind: .intent, activeDocumentId: activeId,
                        structure: structure, prefersProjectScope: prefers,
                        requested: requested)
                    let highlight = StatementPane.switchShowsProject(
                        kind: .intent, activeDocumentId: activeId,
                        structure: structure, prefersProjectScope: prefers,
                        requested: requested)
                    XCTAssertEqual(
                        highlight, scope == .project,
                        "the switch highlights \(highlight ? "Project" : "the document") "
                        + "while the pane shows \(scope.rawValue) — for "
                        + "(\(activeId ?? "nil"), prefers: \(prefers), "
                        + "requested: \(requested?.rawValue ?? "nil"))")
                }
            }
        }
    }

    /// And the press does something in the case the highlight was lying about.
    /// With a `.project` request live, `prefersProjectScope` cannot contradict
    /// it — no value of a Bool can — so the **revocation** is what moves the
    /// scope. This asserts the state the revocation produces; that the setter
    /// calls it is the census in `PromotionStatementMarkTests`.
    func test_revokingAProjectRequestIsWhatReachesTheDocumentsIntent() {
        XCTAssertEqual(
            StatementPane.effectiveScope(
                kind: .intent, activeDocumentId: "doc-1", structure: structure,
                prefersProjectScope: false, requested: .project),
            .project,
            "the control: while the request stands, no press of the document "
            + "segment can answer anything else")
        XCTAssertEqual(
            StatementPane.effectiveScope(
                kind: .intent, activeDocumentId: "doc-1", structure: structure,
                prefersProjectScope: false, requested: nil),
            .document("doc-1"),
            "and once it is revoked the pane reaches the chapter's intent — the "
            + "escape N2 is about, without moving the writer's open document")
    }

    /// **A request naming something this project cannot hold a statement for is
    /// IGNORED, not obeyed.** `createStatement` throws `.structureMissing` for a
    /// group or an unknown id, so honouring one would leave the pane on a scope
    /// whose first keystroke fails. Reachable: a statement outlives the document
    /// it is about if that document is deleted, and its mark still resolves.
    func test_aRequestNamingSomethingThatCannotHoldAStatementIsIgnored() {
        for requested: Statement.Scope in [
            .document("grp-1"), .document("gone-1"), .unknown("who knows")] {
            XCTAssertEqual(
                StatementPane.effectiveScope(
                    kind: .intent, activeDocumentId: "doc-1",
                    structure: structure, prefersProjectScope: false,
                    requested: requested),
                .document("doc-1"),
                "expected the pane's own rule for \(requested.rawValue)")
        }
    }

    /// Visual language ignores a request as it ignores everything else: the book
    /// has one look. The `guard` that says so runs first, over every input.
    func test_visualLanguageIgnoresARequestToo() {
        for requested: Statement.Scope in [.project, .document("doc-1")] {
            XCTAssertEqual(
                StatementPane.effectiveScope(
                    kind: .visualLanguage, activeDocumentId: "doc-1",
                    structure: structure, prefersProjectScope: false,
                    requested: requested),
                .project)
        }
    }

    /// The control: with no request the pane behaves exactly as it did, so the
    /// parameter cannot be quietly deciding the ordinary case.
    func test_noRequestLeavesTheSelectionInCharge() {
        XCTAssertEqual(
            StatementPane.effectiveScope(
                kind: .intent, activeDocumentId: "doc-1",
                structure: structure, prefersProjectScope: false, requested: nil),
            .document("doc-1"))
    }

    /// The switch names the document the pane is actually showing, not the one
    /// the binder has selected — or a pane pinned to Chapter B by **Open** would
    /// offer a segment reading "Chapter A" above Chapter B's intent.
    func test_theScopeSwitchNamesTheDocumentThePaneIsShowing() {
        XCTAssertEqual(
            StatementPane.pickerDocumentId(
                kind: .intent, activeDocumentId: "doc-1",
                structure: structure, requested: nil),
            "doc-1")
        XCTAssertEqual(
            StatementPane.pickerDocumentId(
                kind: .intent, activeDocumentId: nil,
                structure: structure, requested: .document("doc-1")),
            "doc-1",
            "a request with nothing selected still needs a switch to get back "
            + "to the project by")
        XCTAssertNil(
            StatementPane.pickerDocumentId(
                kind: .intent, activeDocumentId: nil,
                structure: structure, requested: .project),
            "nothing to switch between: the caption is what shows")
        // **The case fix round 2 was missing.** A project-scoped Open is the
        // common one — `intentScope` routes every unroutable piece there — and
        // asking `effectiveScope` once made it answer `.project`, hid the
        // switch, and left the writer on the project's intent with no control
        // to reach the chapter's. Re-clicking the same binder row fires no
        // change, so the only escape left moved their open manuscript.
        XCTAssertEqual(
            StatementPane.pickerDocumentId(
                kind: .intent, activeDocumentId: "doc-1",
                structure: structure, requested: .project),
            "doc-1",
            "a project-scoped request must not take the writer's way back with it")
        XCTAssertNil(
            StatementPane.pickerDocumentId(
                kind: .visualLanguage, activeDocumentId: "doc-1",
                structure: structure, requested: .document("doc-1")),
            "the book has one look, so its pane offers no scope switch")
    }

    /// **The rule above, through the real pane.** `effectiveScope` is pure and
    /// says what SHOULD happen; this says the request reaches it — the wiring a
    /// pure test cannot see, and the half that was missing when this branch
    /// shipped 22 green undo tests on a ⌘Z that could not reach the stack.
    ///
    /// The observable is where the first keystroke MINTS: the pane is mounted
    /// with no document selected, so without the request it would create the
    /// project's intent.
    func test_thePaneReallyHonoursARequestedScope() async throws {
        let made = try await fixture(named: "requested-scope")
        let window = await made.host(
            kind: .intent, activeDocumentId: nil,
            requesting: .document(made.documentItemId))
        let textView = try made.textView(in: window)
        await made.type("Intent for the chapter.", into: textView)
        await made.pumpUntil(deadline: 5) {
            made.store.statement(kind: .intent,
                                 scope: .document(made.documentItemId)) != nil
        }

        XCTAssertNotNil(
            made.store.statement(kind: .intent,
                                 scope: .document(made.documentItemId)),
            "the request never reached the pane: it minted somewhere else")
        XCTAssertNil(made.store.statement(kind: .intent, scope: .project),
                     "and it is not ALSO the project's — the control that says "
                     + "the request replaced the selection's answer rather than "
                     + "being added to it")
    }

    /// **The first keystroke into a newly-selected scope mints THAT scope's
    /// statement, not the one the pane first appeared on.**
    ///
    /// Found by the test above and general to the pane: `onUnboundWrite` is a
    /// closure over `StatementEditorHost`, which is a struct, so it captures the
    /// `scope` of the body pass that created it. Wired once in `.onAppear`, it
    /// went on naming that first scope for the pane's whole life — switch from
    /// the project to a chapter, type into the empty chapter, and the words are
    /// created (and, since this milestone's append fix, appended) into the
    /// PROJECT's intent. Nothing about it is a race; it is the state outliving
    /// the thing it described.
    ///
    /// Falsified by moving the wiring back into `.onAppear`.
    func test_typingIntoANewlySelectedScopeMintsThatScopesStatement() async throws {
        let made = try await fixture(named: "scope-switch-mint")
        let window = await made.hostWithASettableSelection(
            kind: .intent, activeDocumentId: nil)
        _ = try made.textView(in: window)

        // Move to the chapter, whose intent does not exist yet, and type.
        await made.selectDocument(made.documentItemId)
        let onChapter = try made.textView(in: window)
        await made.type("The chapter's own aim.", into: onChapter)
        await made.pumpUntil(deadline: 5) {
            made.store.statement(kind: .intent,
                                 scope: .document(made.documentItemId)) != nil
        }

        XCTAssertNotNil(
            made.store.statement(kind: .intent,
                                 scope: .document(made.documentItemId)),
            "the chapter's first sentence was minted into the scope the pane "
            + "appeared on, not the one it is showing")
        XCTAssertNil(made.store.statement(kind: .intent, scope: .project),
                     "and the project's intent was not created behind the "
                     + "writer's back")
    }

    // MARK: - The mount condition (fix round 1, C1)

    /// The mount is held for a resolved scope and for nothing else.
    ///
    /// The state that matters is the middle of the mint: `createStatement` has
    /// appended the statement to the manifest and is suspended at
    /// `await saveManifest()`, and no `Document` is bound yet. The first cut
    /// derived the mount from exactly those two facts (`isBound || statement ==
    /// nil`), which is FALSE right there — so a body pass landing in the window
    /// unmounts the editor on the first character of every new statement, taking
    /// the caret, the first responder and the pane's undo stack with it.
    ///
    /// **This is asserted here, as a predicate, rather than only through the
    /// view**, because whether SwiftUI happens to render that window is timing:
    /// `test_theMintDoesNotTearDownTheEditorMidWord` did not reproduce a remount
    /// on an empty project with a fast disk, and a test that can only fail when
    /// the machine is slow is not a guard. What is invariant is the predicate.
    func test_theMountIsHeldAcrossTheMintAndNothingElse() {
        let key = "intent|project"

        XCTAssertTrue(
            StatementEditorHost.shouldMount(resolvedScope: key, scopeKey: key),
            "a resolved scope must stay mounted — including in the middle of the "
            + "mint, when the statement exists and its Document does not yet")

        XCTAssertFalse(
            StatementEditorHost.shouldMount(resolvedScope: nil, scopeKey: key),
            "nothing may be mounted before the scope has been resolved: an "
            + "editable surface over content that has not loaded is how an empty "
            + "draft overwrites a statement")

        XCTAssertFalse(
            StatementEditorHost.shouldMount(
                resolvedScope: "intent|document:doc-1", scopeKey: key),
            "the previous scope's resolution must not hold the mount open for a "
            + "new one — the editor would show, and accept typing into, the "
            + "Document the pane has just navigated away from")
    }

    // MARK: - Absence is valid, and it renders an editor

    /// An undeclared scope shows an **empty editor** — not a "create intent"
    /// button and not a nag — and writes nothing until the writer types. The
    /// minting half is
    /// `StatementEditorMountTests.test_anUndeclaredScopeMintsNothingUntilAKeystroke`;
    /// this is the half that says what the writer sees.
    func test_anUndeclaredScopeRendersAnEmptyEditor() async throws {
        let fixture = try await fixture(named: "AbsenceRendersAnEditor")
        XCTAssertNil(fixture.store.statement(kind: .visualLanguage, scope: .project))

        let window = await fixture.host(kind: .visualLanguage, activeDocumentId: nil)
        let textView = try fixture.textView(in: window)

        XCTAssertEqual(textView.string, "",
                       "the editor for an undeclared scope is not empty")
        XCTAssertTrue(textView.isEditable,
                      "the editor for an undeclared scope is not editable, so the "
                      + "first keystroke has nowhere to land")
        XCTAssertTrue(fixture.store.manifest.statements.isEmpty,
                      "showing the pane registered a statement")
    }

    // MARK: - Pinned: the checkbox that displays nowhere (spec §8)

    /// A `Document` derives `- [ ]` checkboxes into tasks, but every surface
    /// that lists them enumerates the manifest's **structure** documents (plus
    /// the open registry, which a statement deliberately stays out of) — so a
    /// checkbox typed into an intent produces a task nothing shows.
    ///
    /// Spec §8 names this out of scope to change and in scope to **pin**, so the
    /// next person to find it reads a test instead of filing a bug. If a later
    /// milestone gives statements a Tasks surface, this test fails and should be
    /// deleted deliberately rather than repaired.
    func test_aCheckboxInAStatementDerivesAnAnchorNothingDisplays() async throws {
        let fixture = try await fixture(named: "CheckboxDisplaysNowhere")
        let statement = try await fixture.store.createStatement(kind: .intent, scope: .project)

        let window = await fixture.host(kind: .intent, activeDocumentId: nil)
        let textView = try fixture.textView(in: window)
        await fixture.type("- [ ] find the ending", into: textView)
        try await fixture.settle(window, expectingOpsFor: statement.id)

        // The task IS derived — the statement is an ordinary Document.
        let reloaded = try await Document.load(
            url: fixture.projectURL.appendingPathComponent(statement.path),
            device: "pin-test", session: "pin-test", presenter: nil)
        let derived = reloaded.tasks(filter: TaskFilter(
            scope: .document(docId: statement.id), statuses: [.open]))
        XCTAssertTrue(derived.contains { $0.body.contains("find the ending") },
                      "the statement's own Document derived no task from `- [ ]`, so "
                      + "this test is pinning nothing. Derived: \(derived.map(\.body))")
        await reloaded.close()

        // …and no surface enumerates it.
        let acrossTheProject = fixture.store.listTasksAcrossProject(
            filter: TaskFilter(scope: .project, statuses: [.open]))
        XCTAssertFalse(acrossTheProject.contains { $0.body.contains("find the ending") },
                       "a checkbox typed into a statement now reaches the Tasks pane. "
                       + "That is a behaviour change, not a bug fix — spec §8 records "
                       + "the anchor as harmless and unshown. Delete this pin "
                       + "deliberately if the change is intended.")
    }
}
