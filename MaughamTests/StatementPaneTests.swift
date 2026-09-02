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

    /// §6.3 gave Intent a cell in every persona and Visual language a cell in
    /// Plan, Review and Publish — the shape `Persona.swift` reserved. The whole
    /// matrix is checked by `PersonaPaneRegistryTests`; this pins the two rows
    /// M1A consumes, so a sweep that drops one names the milestone that added
    /// it.
    ///
    /// **The milestones doing the dropping, as that comment asked for.**
    ///
    /// **The persona shell, slice 1** (§5 of
    /// `docs/superpowers/specs/2026-08-01-persona-shell-workflow-design.md`, an
    /// amendment in force to §6.3): intent left **Publish**. Publish is where a
    /// finished book is made to look right; what the writing is going for is
    /// read where the writing happens.
    ///
    /// **The right-column re-cut, 2026-08-03** (§5.0 of the same document,
    /// which supersedes §5's per-persona lists here): intent leaves **Plan**
    /// too, leaving Author and Review. The reason is not that Plan stopped
    /// caring about intent — it is that **Plan AUTHORS intent**, and the thing
    /// a persona authors belongs in its left column, while the right column is
    /// what you glance at while authoring something else. Author and Review
    /// consult it; Plan writes it.
    ///
    /// **The cost, recorded because it is real and temporary.** Intent's
    /// left-column home in Plan is a build §5.0 deliberately parks (a
    /// `BinderSegment` case, a centre route, and a decision about what the left
    /// pane shows while you edit), so **until it ships intent is reachable in
    /// Plan by ⌘⌥N only** — the pane opens, renders and stays selected, but
    /// Plan's picker does not lead you to it and `PersonaMemory` will not keep
    /// it across a persona switch. Denver accepted that trade explicitly.
    ///
    /// The assertion is not weakened to "at least one" — it names the two, so
    /// re-adding a third is as loud as losing one.
    func test_intentIsOfferedByAuthorAndReviewOnly() {
        XCTAssertEqual(
            Set(Persona.allCases.filter { $0.panes.contains(.intent) }),
            [.author, .review])
    }

    /// §6.3 marked Visual language ● for Plan, Review and Publish and — for
    /// Author. §5.0's re-cut leaves **Publish alone**: Plan authors the visual
    /// language (same parked left-column build as intent above, same ⌘⌥V
    /// escape hatch until it lands), and Review adjudicates prose rather than
    /// how the book looks. Publish is where "how the book looks" is read, and
    /// it is Publish's default pane.
    func test_visualLanguageIsOfferedByPublishOnly() {
        XCTAssertEqual(
            Set(Persona.allCases.filter { $0.panes.contains(.visualLanguage) }),
            [.publish],
            "visual language is Publish's column now (§5.0); Plan authors it "
            + "and reaches it with ⌘⌥V until its left-column home is built")
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

    // MARK: - Scope follows the window's subject (spec §4.3)

    /// **`test_theProjectsIntentIsOneClickAwayFromADocuments` was deleted here**
    /// (persona shell, slice 1, task 7), and deliberately rather than as tidying
    /// after a signature change.
    ///
    /// It pinned the pane's promise that *"the other one click away"* — the
    /// `[<chapter> | Project]` switch — put the book's intent within one press of
    /// a chapter's. That promise was a workaround for a hole in the tree: there
    /// was no way to select the project, so the pane had to offer the one subject
    /// nothing else could reach. The project row closes the hole at the cause
    /// (§3.3), and the project's intent is now one click away in the tree, beside
    /// every other subject, with one control saying what the window is about
    /// instead of two that can disagree. Keeping the test would have pinned the
    /// workaround against the fix.
    ///
    /// What replaced it here: `test_theProjectSubjectResolvesToTheProjectsIntent`
    /// for the resolution, and `StatementPaneSelectionDeliveryTests` for the
    /// click itself, on the real tree.
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
                kind: .intent, subject: .item("doc-1"), structure: structure),
            .document("doc-1"))
    }

    func test_intentFallsBackToTheProjectWhenNothingIsSelected() {
        XCTAssertEqual(
            StatementPane.effectiveScope(
                kind: .intent, subject: nil, structure: structure),
            .project)
    }

    /// **The subject the tree can now name.** `.project` is its own arm in
    /// `effectiveScope` rather than a fall-through, and this is what says so: an
    /// implicit `.project` and a decided one give the same answer here today and
    /// would part company the moment the project row carried an id that IS in
    /// the structure.
    func test_theProjectSubjectResolvesToTheProjectsIntent() {
        XCTAssertEqual(
            StatementPane.effectiveScope(
                kind: .intent, subject: .project, structure: structure),
            .project)
    }

    /// The right pane's "no selection" sentinel is refused as an id.
    ///
    /// **No longer a value that arrives here**, and the claim that it was is
    /// what this comment used to make. The pane took a `String?` that
    /// `ProjectWindow` had already `??`-substituted; it takes the typed subject
    /// now, and nothing constructs `.item("__no-selection__")`. Kept as the
    /// control on the guard, not as a description of production.
    func test_intentTreatsTheNoSelectionSentinelAsTheProject() {
        XCTAssertEqual(
            StatementPane.effectiveScope(
                kind: .intent, subject: .item(BinderSubject.noDocumentSubject),
                structure: structure),
            .project)
    }

    /// A group is not something a writer writes in, so it holds no intent of its
    /// own — `createStatement` throws `.structureMissing` for one, and the pane
    /// must never ask.
    func test_intentFallsBackToTheProjectForAGroup() {
        XCTAssertEqual(
            StatementPane.effectiveScope(
                kind: .intent, subject: .item("grp-1"), structure: structure),
            .project)
    }

    func test_intentFallsBackToTheProjectForAnIdThatIsNotInThisProject() {
        XCTAssertEqual(
            StatementPane.effectiveScope(
                kind: .intent, subject: .item("doc-from-another-project"),
                structure: structure),
            .project)
    }

    /// A research item carries no craft intent of its own — intent is a
    /// document/group affair, and a research subject is neither
    /// (stage-2a Task 1).
    func test_intentFallsBackToTheProjectForAResearchSubject() {
        XCTAssertEqual(
            StatementPane.effectiveScope(
                kind: .intent, subject: .research("r-1"), structure: structure),
            .project)
    }

    /// Visual language is project-scope only — the book has one look (§2.1). It
    /// ignores the subject entirely, over every input.
    func test_visualLanguageIsAlwaysProjectScope() {
        let subjects: [BinderSubject?] = [
            nil, .project, .item("doc-1"), .item("grp-1"),
            .item(BinderSubject.noDocumentSubject), .research("r-1"),
        ]
        for subject in subjects {
            XCTAssertEqual(
                StatementPane.effectiveScope(
                    kind: .visualLanguage, subject: subject, structure: structure),
                .project,
                "visual language resolved off the project for "
                + "\(String(describing: subject))")
        }
    }

    // MARK: - The header, now that it is the only thing naming the scope

    /// **The header names the scope that RESOLVED, not the subject the tree
    /// names**, and the two differ exactly where the resolution coerces: a group
    /// selected in the tree shows the project's intent, and the header is the
    /// only thing on screen that says so.
    func test_theHeaderNamesTheDocumentWhenTheScopeIsADocuments() {
        XCTAssertEqual(
            StatementPane.headerCaption(
                kind: .intent, scope: .document("doc-1"), structure: structure),
            "What “Chapter One” is going for")
    }

    func test_theHeaderNamesTheProjectWhenTheScopeCoercedToIt() {
        let coerced = StatementPane.effectiveScope(
            kind: .intent, subject: .item("grp-1"), structure: structure)
        XCTAssertEqual(
            StatementPane.headerCaption(
                kind: .intent, scope: coerced, structure: structure),
            "What this project is going for")
    }

    /// Visual language's header ignores the scope, exactly as its resolution
    /// ignores the subject.
    func test_theVisualLanguageHeaderIsTheSameSentenceOnEveryScope() {
        for scope in [Statement.Scope.project, .document("doc-1")] {
            XCTAssertEqual(
                StatementPane.headerCaption(
                    kind: .visualLanguage, scope: scope, structure: structure),
                "How this book looks")
        }
    }

    /// The header is never empty — the failure mode the picker's deletion could
    /// have left behind is a selected document with no header at all.
    /// **An edition brief names its edition** (publish-department P4 Task 2).
    /// The pane is the same one, so without an arm of its own the Spanish
    /// brief's header read "What this project is going for" — the craft
    /// intent's sentence, over a different document entirely. Like visual
    /// language's, it ignores the scope, because `effectiveScope` coerces every
    /// subject to `.project` for any kind but `.intent`.
    func test_theEditionBriefHeaderNamesTheEdition() {
        let caption = StatementPane.headerCaption(
            kind: .editionBrief("es"), scope: .project, structure: structure)
        XCTAssertTrue(
            caption.contains(TranslationReviewIndicator.displayLabel(forLanguageTag: "es")),
            "the header must name the edition: \(caption)")
        XCTAssertNotEqual(caption, "What this project is going for")
        XCTAssertEqual(
            StatementPane.headerCaption(
                kind: .editionBrief("es"), scope: .document("doc-1"), structure: structure),
            caption,
            "an edition brief is project-scope, and its header says the same "
            + "thing whatever the tree names")
    }

    func test_theHeaderSaysSomethingForEveryKindAndScope() {
        for kind in [Statement.Kind.intent, .visualLanguage,
                     .editionBrief("es"), .lessons, .unknown("future")] {
            for scope in [Statement.Scope.project, .document("doc-1"), .document("gone")] {
                XCTAssertFalse(
                    StatementPane.headerCaption(
                        kind: kind, scope: scope, structure: structure).isEmpty,
                    "no header for (\(kind), \(scope))")
            }
        }
    }

    // MARK: - The scope the first keystroke mints into (fix round 1, F1)

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
            kind: .intent, subject: nil)
        _ = try made.textView(in: window)

        // Move to the chapter, whose intent does not exist yet, and type.
        //
        // Fixed window, and it has to be: BOTH scopes here are undeclared, so the
        // pane looks identical before and after the change — an empty editor over
        // no statement — and every condition available reads true the instant it
        // is asked. Waiting on one would type into whichever scope the pane
        // happened to still be on, which is the exact thing this test is about.
        await made.selectDocument(made.documentItemId)
        let onChapter = try made.textView(in: window)
        await made.type("The chapter's own aim.", into: onChapter, until: {
            made.store.statement(kind: .intent,
                                 scope: .document(made.documentItemId)) != nil
        })

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

        let window = await fixture.host(kind: .visualLanguage, subject: nil)
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

        let window = await fixture.host(kind: .intent, subject: nil)
        let textView = try fixture.textView(in: window)
        await fixture.type("- [ ] find the ending", into: textView)
        try await fixture.settle(window, expectingOpsFor: statement.id, until: {
            fixture.derivedText(forDocId: statement.id).contains("find the ending")
        })

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

    // MARK: - The lessons ledger (editorial letter P2, Task 1)

    /// The ledger's header names what it is, and — like visual language's and
    /// the brief's — it says the same thing whatever the tree names, because
    /// `effectiveScope` coerces every subject to `.project` for any kind but
    /// `.intent`. Without an arm of its own the ledger wore the craft intent's
    /// sentence over a different document entirely.
    func test_theLessonsHeaderSaysWhatTheLedgerIs() {
        XCTAssertEqual(
            StatementPane.headerCaption(
                kind: .lessons, scope: .project, structure: structure),
            "What I've learned")
        XCTAssertEqual(
            StatementPane.headerCaption(
                kind: .lessons, scope: .document("doc-1"), structure: structure),
            "What I've learned",
            "the ledger is project-scope, and its header says so whatever the "
            + "tree names")
    }

    /// The ledger is one per project. Selecting a chapter and opening it must
    /// resolve to the project rather than offering a keystroke that throws
    /// `.statementHasNoStorage`.
    func test_theLedgerResolvesToTheProjectFromEverySubject() {
        for subject in [BinderSubject.project, .item("doc-1"), .item("grp-1"),
                        .item("gone"), .research("res-1")] {
            XCTAssertEqual(
                StatementPane.effectiveScope(
                    kind: .lessons, subject: subject, structure: structure),
                .project,
                "a lessons subject of \(subject) must coerce to the project")
        }
    }

    /// CONTROL for the coercion above: the same sweep over `.intent` DOES
    /// follow the selected document, so a green run cannot mean `effectiveScope`
    /// answers `.project` for everything.
    func test_control_theSameSubjectFollowsTheDocumentForIntent() {
        XCTAssertEqual(
            StatementPane.effectiveScope(
                kind: .intent, subject: .item("doc-1"), structure: structure),
            .document("doc-1"))
    }

    /// The three predicates a new kind has to answer, in one place: the ledger
    /// carries rulings (they are its entire content), establishes nothing about
    /// the book's world, and takes no pictures.
    func test_theLedgerAnswersTheThreeKindPredicates() {
        XCTAssertTrue(StatementEssay.carriesRulings(.lessons),
                      "the ledger's entries ARE rulings")
        XCTAssertFalse(BibleStratum.belongsTo(.lessons),
                       "the ledger is about the writer, not about Kelly")
        XCTAssertFalse(StatementEditorHost.takesPictures(.lessons),
                       "only visual language takes pictures")
    }

    /// CONTROL for the three above: each predicate answers the other way for
    /// some kind, so a green run cannot mean they are constants.
    func test_control_theThreeKindPredicatesDiscriminate() {
        XCTAssertFalse(StatementEssay.carriesRulings(.visualLanguage))
        XCTAssertTrue(BibleStratum.belongsTo(.intent))
        XCTAssertTrue(StatementEditorHost.takesPictures(.visualLanguage))
    }

    // MARK: - The pane on screen (editorial letter P2, Task 5)

    /// **The mounted pane, because everything above this is a pure function and
    /// a pane can be wired to none of them.** `DetailSegment.lessons` reaches
    /// `StatementPane` through `DetailPaneToggle.statementPane(kind:)`, and what
    /// this asserts is that the two sentences the ledger owns — the header
    /// caption and the strata's own heading — are drawn by the view the writer
    /// meets rather than only answered by the statics that compose them.
    ///
    /// Read off production's own accessibility tree (`staticTexts`), which is
    /// the only reading of a rendered `Text` available from outside.
    ///
    /// The seeded row is what makes the second half assertable at all: the
    /// strata render only when there is something in them
    /// (`StatementPane.strata`), so a ledger with no entries draws no heading
    /// and a test over an empty one would pass on the wrong reason.
    func test_theMountedLedgerDrawsItsCaptionAndItsLedgerHeading() async throws {
        let made = try await fixture(named: "lessons-pane")
        let statement = try await made.store.createStatement(kind: .lessons, scope: .project)
        try await made.store.mutateStatementText(of: statement, session: "test") { _ in
            """
            What I keep learning.

            ## Rulings

            - Cut the throat-clearing paragraph — ruled 2 Sep 2026, Le Guin
            """
        }

        // The subject is a CHAPTER, not the project: the ledger is project-wide
        // whatever the tree names, so mounting it on the project row would let a
        // pane that silently follows the selection pass this test.
        let window = await made.host(kind: .lessons, subject: .item(made.documentItemId))
        _ = await made.pumpUntil(deadline: 5) { made.shows("Ledger", in: window) }

        let everything = try made.staticTexts(in: window, containing: "")
        XCTAssertFalse(
            try made.staticTexts(in: window, containing: "What I've learned").isEmpty,
            "the mounted ledger does not draw its own caption. Every text the "
            + "window drew: \(everything)")
        XCTAssertFalse(
            try made.staticTexts(in: window, containing: "Ledger").isEmpty,
            "the strata over the ledger are still headed Rulings, or drew nothing")
        XCTAssertTrue(
            try made.staticTexts(in: window, containing: "going for").isEmpty,
            "the ledger wore the craft intent's sentence — the chapter subject "
            + "reached the header instead of coercing to the project")
    }

    /// The stratum's own heading is the writer's word for what these rows are.
    /// In the ledger they are the artifact, not decisions itemized under an
    /// essay, so the heading says **Ledger**.
    func test_theStratumTitlesTheLedgerAndKeepsRulingsForEverythingElse() {
        XCTAssertEqual(RulingsStratumView.title(for: .lessons), "Ledger")
        for kind in [Statement.Kind.intent, .visualLanguage,
                     .editionBrief("es"), .unknown("future")] {
            XCTAssertEqual(RulingsStratumView.title(for: kind), "Rulings",
                           "\(kind) keeps the original heading")
        }
    }
}
