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
