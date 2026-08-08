import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// The Intent pane's three strata (declared-world Task 6, spec §3.2/§3.3): the
/// writer's essay in the editor, their rulings itemized under it, and Claude's
/// bible entries in a visibly provisional register below that.
///
/// The suite is deliberately weighted toward the SPLIT rather than the rows:
/// splitting the bound text is the change that touches `StatementEditorHost`'s
/// orbit, and every defect that orbit has produced has been a value trusted
/// after the thing it described moved.
@MainActor
final class StatementPaneStrataTests: XCTestCase {

    // MARK: - The essay half is a byte-exact split

    /// **The property the whole task rests on**: taking the essay out and
    /// putting it back unchanged is the identity, for every shape of statement.
    ///
    /// `RulingsSection.render` cannot promise this — it *converges* (its own
    /// doc says so), and what it converges by is discarding anything under the
    /// heading that is not a list item. A recomposition built on `render` would
    /// therefore delete a writer's hand-typed prose under their own Rulings
    /// heading on the next keystroke. `StatementEssay.recomposed` preserves the
    /// tail byte for byte, so this is an equality rather than a fixpoint.
    func test_puttingTheEssayBackUnchangedIsTheIdentity() {
        let shapes = [
            "",
            "Just an essay.",
            "Essay.\n\nMore essay.\n",
            "Essay.\n\n## Rulings\n\n- Kelly never lies — ruled 7 Aug 2026, from a run\n",
            "## Rulings\n\n- Heading at the very top\n",
            "\n\n## Rulings\n\n- A blank line or two first\n",
            // Hand-edited: prose under the heading that `RulingsSection.parse`
            // drops and `render` would therefore delete.
            "Essay.\n\n## Rulings\n\n- One\n\nA note I typed under my own list.\n",
            // A heading spelled mid-paragraph is not a section boundary (the
            // parser's F-A avoidance) — the whole thing is essay.
            "I wrote\n## Rulings\nin the middle of a paragraph.",
        ]
        for markdown in shapes {
            let essay = StatementEssay.half(of: markdown)
            XCTAssertEqual(
                StatementEssay.recomposed(essay: essay, into: markdown), markdown,
                "the split is not byte-exact for: \(markdown.debugDescription)")
        }
    }

    /// The tail below the essay survives a rewrite of the essay itself — which
    /// is the same property from the other side, and the one that keeps a
    /// ruling on screen while the writer types above it.
    func test_rewritingTheEssayLeavesEverythingBelowItAlone() {
        let markdown = "Old essay.\n\n## Rulings\n\n- Kelly never lies — ruled 7 Aug 2026, from a run\n"
        let rewritten = StatementEssay.recomposed(essay: "New essay.", into: markdown)
        XCTAssertTrue(rewritten.hasPrefix("New essay."), rewritten)
        XCTAssertTrue(rewritten.contains("- Kelly never lies — ruled 7 Aug 2026, from a run"),
                      "the rulings stratum was not preserved verbatim: \(rewritten)")
        XCTAssertEqual(StatementEssay.half(of: rewritten), "New essay.")
        XCTAssertEqual(RulingsSection.parse(rewritten).rulings.count, 1)
    }

    /// A statement whose Rulings section starts at line 0 has an empty essay,
    /// and the first thing typed into it must not run into the heading.
    func test_typingIntoAnEmptyEssayAboveASectionKeepsTheHeadingOnItsOwnLine() {
        let markdown = "## Rulings\n\n- One\n"
        let out = StatementEssay.recomposed(essay: "First words.", into: markdown)
        XCTAssertEqual(out, "First words.\n\n## Rulings\n\n- One\n")
        XCTAssertEqual(StatementEssay.half(of: out), "First words.")
    }

    /// Emptying the essay leaves the rulings — deleting every word of intent is
    /// not a revocation of the decisions made under it.
    func test_emptyingTheEssayLeavesTheRulings() {
        let markdown = "Essay.\n\n## Rulings\n\n- One\n"
        let out = StatementEssay.recomposed(essay: "", into: markdown)
        XCTAssertEqual(RulingsSection.parse(out).rulings.map(\.text), ["One"])
        XCTAssertEqual(StatementEssay.half(of: out), "")
    }

    /// **Two shapes the reviewer falsified by hand, pinned so they stay
    /// falsified** (fix round 1).
    ///
    /// A delimiter line of spaces still qualifies as blank
    /// (`RulingsSection.findHeadingIndex` trims with `.whitespaces`), and the
    /// splice must give those exact bytes back — which it does *because* the
    /// tail is `dropFirst` on the raw string rather than a rejoin of parsed
    /// lines. A rejoining implementation would pass every other test in this
    /// file and silently normalize this one.
    func test_aWhitespaceOnlyDelimiterLineSurvivesTheSpliceByteForByte() {
        let markdown = "Essay.\n   \n## Rulings\n\n- One\n"
        XCTAssertEqual(StatementEssay.half(of: markdown), "Essay.")
        XCTAssertEqual(StatementEssay.recomposed(essay: "Essay.", into: markdown), markdown)
        XCTAssertEqual(StatementEssay.recomposed(essay: "New.", into: markdown),
                       "New.\n   \n## Rulings\n\n- One\n",
                       "the three spaces the writer left on the delimiter line were "
                       + "normalized away")
    }

    /// **CRLF: the splice is safe, and it is safe by accident — record which.**
    ///
    /// `RulingsSection.findHeadingIndex` trims with `.whitespaces`, which does
    /// not include `\r`, so `"## Rulings\r"` never equals the heading and the
    /// boundary is never found. `parse` hands back the whole document as essay,
    /// which makes the splice a trivial identity and the pane a plain
    /// whole-text editor: nothing is lost and no ruling is ever *itemized*.
    ///
    /// So this test pins the observed behaviour rather than a desired one. The
    /// latent gap is `RulingsSection.parse`'s (Task 1, MaughamCore) and nothing
    /// in the app produces CRLF today; if that ever changes, this test is where
    /// the assumption is written down.
    func test_aCRLFDocumentIsAllEssayAndTheSpliceIsTheIdentity() {
        let markdown = "Essay.\r\n\r\n## Rulings\r\n\r\n- One\r\n"
        XCTAssertTrue(RulingsSection.parse(markdown).rulings.isEmpty,
                      "CRLF now parses as a rulings section — the pane would itemize "
                      + "these lines and this test's reasoning no longer holds")
        XCTAssertEqual(StatementEssay.half(of: markdown), markdown)
        XCTAssertEqual(StatementEssay.recomposed(essay: markdown, into: markdown), markdown)
    }

    // MARK: - The heading the writer types (whole-branch review, C1)

    /// **Typing `## Rulings` into the pane's own editor leaves it where the
    /// writer put it** — the flow the guide sold, keystroke by keystroke,
    /// through the mounted editor.
    ///
    /// The defect this pins had three symptoms in one frame, and only the first
    /// is visible to a test that checks the file. A heading-only section used to
    /// qualify as the boundary, so on the keystroke that finished `Rulings` the
    /// binding's get (`StatementEssay.half`) stopped returning it,
    /// `EditorSurface.reconcileTextBuffer` saw view ≠ binding and called
    /// `applyExternalText(preserveUndoStack: false)`, and the heading **vanished
    /// from under the caret**, taking the writer's typing undo stack with it —
    /// while no stratum appeared in its place, because the stratum mounts only
    /// once a ruling exists. The next line they typed then spliced ABOVE a
    /// heading they could no longer see.
    ///
    /// So all three are asserted: the bytes, the undo stack, and the absence of
    /// a stratum. The undo assertion is the one that would otherwise be missed —
    /// a fix that kept the text but still replaced the buffer passes the first.
    func test_typingTheRulingsHeadingIntoTheEssayEditorLeavesItWhereTheWriterPutIt() async throws {
        let fixture = try await StatementMountFixture.novel(named: "typed-heading")
        defer { fixture.tearDown() }
        let scope = Statement.Scope.document(fixture.documentItemId)
        let statement = try await fixture.store.createStatement(kind: .intent, scope: scope)

        let window = await fixture.host(
            kind: .intent, subject: .item(fixture.documentItemId))
        let textView = try fixture.textView(in: window)

        let typed = "A ghost story told in weather.\n\n## Rulings\n\n"
        await fixture.type(typed, into: textView)

        XCTAssertEqual(
            textView.string, typed,
            "the heading the writer typed was pulled out from under the caret — the "
            + "binding's essay half and the mounted buffer disagreed, so "
            + "`applyExternalText` replaced what they were typing into")
        let undoManager = try XCTUnwrap(
            textView.undoManager,
            "the mounted editor has no undo manager, so this test could never fail")
        XCTAssertTrue(
            undoManager.canUndo,
            "the writer's typing undo stack was cleared — a buffer replacement ran "
            + "under their hands (`applyExternalText(preserveUndoStack: false)`)")

        XCTAssertTrue(
            RulingsStratum.rows(in: fixture.store.statementText(of: statement)).isEmpty,
            "a heading with nothing under it itemized something")
        XCTAssertFalse(
            fixture.shows("Revoke", in: window),
            "a stratum mounted over a heading with no rulings in it — its rows' "
            + "verbs are on screen")

        // And the words are durable: the heading is in the op log, not only in
        // a buffer that happened to survive.
        try await fixture.settle(window, expectingOpsFor: statement.id)
        XCTAssertTrue(
            fixture.derivedText(forDocId: statement.id).contains(RulingsSection.heading),
            "the typed heading never reached the statement's op log: "
            + fixture.derivedText(forDocId: statement.id))
    }

    /// **A ruling verb must not delete prose the writer put under their own
    /// heading** — C1's second loss mode, at the seam it actually arrives
    /// through.
    ///
    /// The verb here is the one an **answered compiler note** runs
    /// (`DiagnosticsPane.commitAnswer` → `RulingPerformer.rule`), which is the whole
    /// sharpness of it: the writer pressed Answer on a note and does not
    /// experience that as asking for their intent to be rewritten. While a
    /// heading-only section qualified, `render` kept the parsed items and
    /// nothing else, so the paragraph under the heading went with it — writer
    /// bytes deleted with nothing red, which is constitution must #1's shape.
    func test_aRulingDoesNotDeleteProseTheWriterTypedUnderTheirOwnHeading() async throws {
        let fixture = try await StatementMountFixture.novel(named: "prose-under-heading")
        defer { fixture.tearDown() }
        let scope = Statement.Scope.document(fixture.documentItemId)
        _ = try await fixture.store.createStatement(kind: .intent, scope: scope)
        let statement = try XCTUnwrap(fixture.store.statement(kind: .intent, scope: scope))

        let underTheHeading = "A paragraph I typed under my own heading."
        try await fixture.store.mutateStatementText(of: statement, session: "s") { _ in
            "A ghost story told in weather.\n\n## Rulings\n\n\(underTheHeading)\n"
        }
        // Precondition: those bytes are in the ESSAY, i.e. on screen in the
        // pane's editor. Without this the test passes over a heading that was
        // never a boundary for some other reason.
        XCTAssertTrue(
            StatementEssay.half(of: fixture.store.statementText(of: statement))
                .contains(underTheHeading))

        try await RulingPerformer.rule(
            "Kelly never lies", provenance: "from an answered note",
            forScope: scope, store: fixture.store, world: nil)

        let after = fixture.store.statementText(of: statement)
        XCTAssertTrue(after.contains(underTheHeading),
                      "the ruling deleted the writer's paragraph: \(after)")
        XCTAssertTrue(
            StatementEssay.half(of: after).contains(underTheHeading),
            "the paragraph survived on disk but below the section boundary, where "
            + "the essay editor cannot show it and the next verb deletes it: \(after)")
        XCTAssertEqual(RulingsStratum.rows(in: after).map(\.text), ["Kelly never lies"],
                       "the ruling did not land as a ruling: \(after)")
        XCTAssertEqual(
            after.components(separatedBy: "\n")
                .filter { $0.trimmingCharacters(in: .whitespaces) == RulingsSection.heading }
                .count,
            1, "the verb wrote a second heading beside the writer's: \(after)")
    }

    // MARK: - Which statements have the stratum at all

    /// Visual language has no rulings (`RulingPerformer`'s kind is always
    /// `.intent`), so its editor binds its whole text — otherwise a writer who
    /// typed `## Rulings` as an ordinary heading in their visual language would
    /// watch the rest of the document leave the editor, with rows underneath
    /// whose Revoke button refuses (`RulingFailure.noStatement`, because the
    /// performer would look for an INTENT statement).
    func test_onlyIntentCarriesTheRulingsStratum() {
        XCTAssertTrue(StatementEssay.carriesRulings(.intent))
        XCTAssertFalse(StatementEssay.carriesRulings(.visualLanguage))
        XCTAssertFalse(StatementEssay.carriesRulings(.unknown("newer-build")))
    }

    /// The target of a kind with no stratum is byte-transparent: what the
    /// editor shows is the document's whole text and what it writes is the
    /// writer's whole text, exactly as before this task.
    func test_aTargetWithoutTheStratumIsTransparent() {
        let target = StatementTextTarget(splitsStrata: false)
        let markdown = "Look.\n\n## Rulings\n\n- Not a ruling here\n"
        XCTAssertEqual(target.shown(of: markdown), markdown)
        XCTAssertEqual(target.recomposed("Anything at all", into: markdown),
                       "Anything at all")
    }

    // MARK: - The hardest one

    /// **A ruling that lands while the writer is mid-essay survives their next
    /// keystroke** — Stage 2's flow, where an answered note becomes a ruling
    /// while the Intent pane is open and the writer is still typing above it.
    ///
    /// The failure this pins is not hypothetical: a pane that parsed once into
    /// view state and recomposed against that snapshot writes the rulings it
    /// saw at parse time, and the one that landed in between is gone with no
    /// error anywhere. Verified by disable experiment — see the task report.
    ///
    /// Drives the REAL objects: a real `ProjectStore`, a real minted statement,
    /// a real `Document`, `RulingPerformer` for the ruling and the pane's own
    /// text target for the keystroke.
    func test_aRulingLandedMidEditSurvivesTheEssaySave() async throws {
        let fixture = try await StatementMountFixture.novel(named: "mid-edit")
        defer { fixture.tearDown() }
        let scope = Statement.Scope.document(fixture.documentItemId)
        let statement = try await fixture.store.createStatement(kind: .intent, scope: scope)

        let document = try await Document.load(
            url: fixture.store.url.appendingPathComponent(statement.path),
            device: "test-device", session: "test-session",
            presenter: fixture.documentStore.presenter)
        defer { Task { await document.close() } }
        fixture.store.noteStatementDocumentOpened(document, id: statement.id)

        let target = StatementTextTarget(splitsStrata: true)
        target.wantedScope = "intent|\(scope.rawValue)"
        target.bind(document, id: statement.id, for: target.wantedScope!)

        // The writer types their intent.
        target.write("Kelly is the one who notices.")
        XCTAssertEqual(target.text, "Kelly is the one who notices.")

        // A ruling lands from the run, into the same live Document.
        try await RulingPerformer.rule(
            "Kelly only acts on what she has actually heard",
            provenance: "from a run on ¶wnse",
            forScope: scope, store: fixture.store, world: nil)

        // The editor is unchanged by it — that is the point of the split.
        XCTAssertEqual(target.text, "Kelly is the one who notices.",
                       "the ruling reached the essay editor's bound text")

        // The writer types on.
        target.write("Kelly is the one who notices. She is not the one who acts.")

        let after = document.displayText
        XCTAssertTrue(after.contains("She is not the one who acts."),
                      "the writer's keystroke did not land: \(after)")
        XCTAssertEqual(
            RulingsSection.parse(after).rulings.map(\.text),
            ["Kelly only acts on what she has actually heard"],
            "the essay save wrote over a ruling that landed mid-edit: \(after)")
    }

    /// The same guarantee at the seam a promotion arrives through. A card
    /// promoted into a statement that already has rulings must land in the
    /// ESSAY, above the heading — appended to the whole text it would sit under
    /// the list, where `RulingsSection.parse` does not read it and the pane's
    /// editor therefore cannot show it. The words would be safe and invisible,
    /// which is its own kind of loss.
    func test_anAppendLandsInTheEssayRatherThanUnderTheRulings() async throws {
        let fixture = try await StatementMountFixture.novel(named: "append-essay")
        defer { fixture.tearDown() }
        let scope = Statement.Scope.document(fixture.documentItemId)
        let statement = try await fixture.store.createStatement(kind: .intent, scope: scope)

        try await fixture.store.appendToStatement(
            "The essay.", to: statement, session: "s")
        try await RulingPerformer.rule("A ruling", provenance: "by hand",
                                       forScope: scope, store: fixture.store, world: nil)
        try await fixture.store.appendToStatement(
            "A promoted card.", to: statement, session: "s")

        let text = fixture.store.statementText(of: statement)
        let essay = StatementEssay.half(of: text)
        XCTAssertTrue(essay.contains("A promoted card."),
                      "the append landed where the essay editor cannot show it: \(text)")
        XCTAssertEqual(RulingsSection.parse(text).rulings.map(\.text), ["A ruling"],
                       "the append disturbed the rulings stratum: \(text)")
    }

    /// Words typed before the file existed are deposited into the ESSAY too,
    /// for the same reason — the draft is intent prose, and a statement minted
    /// by a promotion (`createStatement` is idempotent) can already carry a
    /// rulings section by the time the mint's load gets there.
    func test_aDraftIsDepositedIntoTheEssayNotUnderTheRulings() async throws {
        let fixture = try await StatementMountFixture.novel(named: "deposit-essay")
        defer { fixture.tearDown() }
        let scope = Statement.Scope.document(fixture.documentItemId)
        let statement = try await fixture.store.createStatement(kind: .intent, scope: scope)
        try await fixture.store.appendToStatement("Existing essay.", to: statement, session: "s")
        try await RulingPerformer.rule("A ruling", provenance: "by hand",
                                       forScope: scope, store: fixture.store, world: nil)

        let document = try await Document.load(
            url: fixture.store.url.appendingPathComponent(statement.path),
            device: "test-device", session: "test-session",
            presenter: fixture.documentStore.presenter)
        defer { Task { await document.close() } }

        let target = StatementTextTarget(splitsStrata: true)
        let key = "intent|\(scope.rawValue)"
        target.wantedScope = key
        target.write("Typed before the bind.")
        target.bind(document, id: statement.id, for: key)

        let essay = StatementEssay.half(of: document.displayText)
        XCTAssertTrue(essay.contains("Existing essay."), essay)
        XCTAssertTrue(essay.contains("Typed before the bind."),
                      "the draft was deposited below the rulings: \(document.displayText)")
        XCTAssertEqual(RulingsSection.parse(document.displayText).rulings.count, 1)
    }

    // MARK: - Rulings stratum: rows, and no empty state

    func test_noSectionMeansNoStratumAtAll() {
        XCTAssertTrue(RulingsStratum.rows(in: "Just an essay, no rulings.").isEmpty)
        XCTAssertTrue(RulingsStratum.rows(in: "").isEmpty)
        XCTAssertEqual(
            RulingsStratum.rows(in: "E.\n\n## Rulings\n\n- One — ruled 7 Aug 2026, from a run\n")
                .map(\.text),
            ["One"])
    }

    /// The row shows the writer's own three facts and nothing derived from
    /// them. A ruling with neither date nor provenance (hand-typed) says so by
    /// showing nothing rather than by inventing "unknown".
    func test_theRowSaysWhenAndWhereFromWhenItKnows() {
        let dated = Ruling(id: "r", text: "One",
                           ruledOn: Date(timeIntervalSince1970: 1_786_060_800),
                           provenance: "from a run on ¶wnse")
        XCTAssertEqual(RulingsStratum.caption(for: dated),
                       "Ruled 7 Aug 2026 · from a run on ¶wnse")
        XCTAssertEqual(
            RulingsStratum.caption(for: Ruling(id: "r", text: "One", ruledOn: nil,
                                               provenance: "from a run")),
            "from a run")
        XCTAssertNil(RulingsStratum.caption(
            for: Ruling(id: "r", text: "One", ruledOn: nil, provenance: nil)))
    }

    // MARK: - Rulings stratum: the verbs, and one undo step each

    func test_revokingARowTakesExactlyThatLineAndOneUndoPutsItBack() async throws {
        let fixture = try await StatementMountFixture.novel(named: "revoke-undo")
        defer { fixture.tearDown() }
        let scope = Statement.Scope.document(fixture.documentItemId)
        let ruled = Date(timeIntervalSince1970: 1_786_060_800)
        _ = try await fixture.store.createStatement(kind: .intent, scope: scope)
        let statement = try XCTUnwrap(fixture.store.statement(kind: .intent, scope: scope))
        try await fixture.store.mutateStatementText(of: statement, session: "s") { _ in
            RulingsSection.render(essay: "Essay.", rulings: [
                Ruling(id: "", text: "First", ruledOn: ruled, provenance: "from a run"),
                Ruling(id: "", text: "Second", ruledOn: ruled, provenance: "by hand"),
            ])
        }

        let undoManager = UndoManager()
        var work: [Task<Void, Never>] = []
        let rows = RulingsStratum.rows(in: fixture.store.statementText(of: statement))
        await RulingsStratum.revoke(
            rows[0], at: 0, forScope: scope, store: fixture.store, world: nil,
            undoManager: undoManager, workTaskSink: { work.append($0) })

        XCTAssertEqual(
            RulingsStratum.rows(in: fixture.store.statementText(of: statement)).map(\.text),
            ["Second"])

        undoManager.undo()
        for task in work { await task.value }
        work.removeAll()

        let restored = RulingsStratum.rows(in: fixture.store.statementText(of: statement))
        XCTAssertEqual(restored.map(\.text), ["First", "Second"],
                       "one ⌘Z did not put the ruling back where it was")
        XCTAssertEqual(restored[0].ruledOn, ruled,
                       "the restored ruling was re-dated — a ⌘Z must not rewrite the record")
        XCTAssertEqual(restored[0].provenance, "from a run")
        XCTAssertEqual(StatementEssay.half(of: fixture.store.statementText(of: statement)),
                       "Essay.", "the undo disturbed the essay")
    }

    func test_editingARowKeepsItsPlaceAndOneUndoRestoresTheOldWords() async throws {
        let fixture = try await StatementMountFixture.novel(named: "edit-undo")
        defer { fixture.tearDown() }
        let scope = Statement.Scope.document(fixture.documentItemId)
        let ruled = Date(timeIntervalSince1970: 1_786_060_800)
        _ = try await fixture.store.createStatement(kind: .intent, scope: scope)
        let statement = try XCTUnwrap(fixture.store.statement(kind: .intent, scope: scope))
        try await fixture.store.mutateStatementText(of: statement, session: "s") { _ in
            RulingsSection.render(essay: "Essay.", rulings: [
                Ruling(id: "", text: "First", ruledOn: ruled, provenance: "from a run"),
                Ruling(id: "", text: "Second", ruledOn: ruled, provenance: "by hand"),
            ])
        }

        let undoManager = UndoManager()
        var work: [Task<Void, Never>] = []
        await RulingsStratum.edit(
            at: 0, to: "First, corrected", forScope: scope, store: fixture.store,
            world: nil, undoManager: undoManager, workTaskSink: { work.append($0) })

        let edited = RulingsStratum.rows(in: fixture.store.statementText(of: statement))
        XCTAssertEqual(edited.map(\.text), ["First, corrected", "Second"],
                       "an edit moved the ruling out of its place")
        XCTAssertEqual(edited[0].ruledOn, ruled,
                       "a correction is a fix to a decision already made — it keeps its date")

        undoManager.undo()
        for task in work { await task.value }
        XCTAssertEqual(
            RulingsStratum.rows(in: fixture.store.statementText(of: statement)).map(\.text),
            ["First", "Second"], "one ⌘Z did not restore the ruling's old words")
    }

    /// **The real ⌘Z, through the control the writer presses** (fix round 1).
    ///
    /// Every other undo assertion here builds an `UndoManager()` of its own and
    /// calls the static verb — which proves the verb and `OpUndoRegistrar`, and
    /// assumes the two hops between them and a writer's keystroke: that
    /// `@Environment(\.undoManager)` inside a mounted `RulingsStratumView`
    /// resolves to the WINDOW's manager, and that the row's `Button` carries
    /// that environment into its closure. This project's own recorded lesson is
    /// that an undo suite can be green over a ⌘Z that reaches nothing
    /// (`memory/project_milestone_mode_ux_redesign.md`), so the assumption is
    /// worth one test that does not make it.
    ///
    /// Production the whole way: the real `StatementPane`, the real stratum
    /// mounted inside it, the real `Button` pressed through the accessibility
    /// tree, and `window.undoManager` — the object AppKit hands the writer's
    /// ⌘Z — driven directly.
    ///
    /// **`canUndo` is asserted before `undo()` on purpose.** Without it a
    /// no-op manager and a working one look identical: nothing happens, the
    /// ruling is still gone, and the failure reads as "the undo did not
    /// restore" rather than "nothing was ever registered here".
    func test_pressingRevokeOnTheMountedRowIsUndoneByTheWindowsOwnUndoManager() async throws {
        let fixture = try await StatementMountFixture.novel(named: "revoke-delivery")
        defer { fixture.tearDown() }
        let scope = Statement.Scope.document(fixture.documentItemId)
        let ruled = Date(timeIntervalSince1970: 1_786_060_800)
        _ = try await fixture.store.createStatement(kind: .intent, scope: scope)
        let statement = try XCTUnwrap(fixture.store.statement(kind: .intent, scope: scope))
        try await fixture.store.mutateStatementText(of: statement, session: "s") { _ in
            RulingsSection.render(essay: "Essay.", rulings: [
                Ruling(id: "", text: "First", ruledOn: ruled, provenance: "from a run"),
                Ruling(id: "", text: "Second", ruledOn: ruled, provenance: "by hand"),
            ])
        }

        let window = await fixture.host(
            kind: .intent, subject: .item(fixture.documentItemId))
        await fixture.pumpUntil(deadline: 5) { fixture.shows("First", in: window) }
        XCTAssertTrue(fixture.shows("First", in: window),
                      "the ruling never reached the mounted stratum, so there is no "
                      + "control to press")

        // The first row's Revoke — the rows are drawn in file order, so this is
        // "First". Asserted below rather than assumed: if the tree ever hands
        // them back in another order this fails loudly instead of passing over
        // whichever row it found.
        try fixture.pressButton(labelled: "Revoke", in: window)
        await fixture.pumpUntil(deadline: 5) {
            RulingsStratum.currentRows(forScope: scope, store: fixture.store).count == 1
        }
        XCTAssertEqual(
            RulingsStratum.currentRows(forScope: scope, store: fixture.store).map(\.text),
            ["Second"], "pressing Revoke on the mounted row did not revoke it")

        let undoManager = try XCTUnwrap(
            window.undoManager,
            "the window has no undo manager at all, so nothing a pane registers "
            + "can ever be reached by ⌘Z")
        XCTAssertTrue(
            undoManager.canUndo,
            "the mounted row's Revoke registered nothing on the WINDOW's undo "
            + "manager — `@Environment(\\.undoManager)` in this pane is not the "
            + "manager AppKit hands ⌘Z, and every ⌘Z assertion in this suite is "
            + "proving a path the writer cannot reach")

        undoManager.undo()
        await fixture.pumpUntil(deadline: 5) {
            RulingsStratum.currentRows(forScope: scope, store: fixture.store).count == 2
        }
        let restored = RulingsStratum.currentRows(forScope: scope, store: fixture.store)
        XCTAssertEqual(restored.map(\.text), ["First", "Second"],
                       "the window's ⌘Z did not put the revoked ruling back in place")
        XCTAssertEqual(restored[0].ruledOn, ruled)
        XCTAssertEqual(restored[0].provenance, "from a run")
        XCTAssertEqual(StatementEssay.half(of: fixture.store.statementText(of: statement)),
                       "Essay.")
    }

    /// A row's id is derived from its own text, so it goes stale the instant
    /// the text changes. Every verb here therefore addresses a ruling by its
    /// INDEX — which `edit` and `restore` both preserve — and re-derives the id
    /// at the moment it writes.
    func test_aRowsIdenityIsReDerivedAfterAnEdit() async throws {
        let fixture = try await StatementMountFixture.novel(named: "id-redirve")
        defer { fixture.tearDown() }
        let scope = Statement.Scope.document(fixture.documentItemId)
        _ = try await fixture.store.createStatement(kind: .intent, scope: scope)
        let statement = try XCTUnwrap(fixture.store.statement(kind: .intent, scope: scope))
        try await fixture.store.mutateStatementText(of: statement, session: "s") { _ in
            RulingsSection.render(essay: "E.", rulings: [
                Ruling(id: "", text: "Before", ruledOn: nil, provenance: nil)])
        }
        let before = RulingsStratum.rows(in: fixture.store.statementText(of: statement))[0].id

        await RulingsStratum.edit(
            at: 0, to: "After", forScope: scope, store: fixture.store, world: nil,
            undoManager: nil, workTaskSink: { _ in })

        let after = RulingsStratum.rows(in: fixture.store.statementText(of: statement))[0]
        XCTAssertNotEqual(after.id, before,
                          "the ruling id must move with the text — if it did not, the "
                          + "row's stale id would still address the line and this suite "
                          + "would be proving nothing")
        // The second edit is the real assertion: it succeeds only because the
        // verb re-derived the id from the current text rather than reusing the
        // one the row was built with.
        await RulingsStratum.edit(
            at: 0, to: "After again", forScope: scope, store: fixture.store, world: nil,
            undoManager: nil, workTaskSink: { _ in })
        XCTAssertEqual(
            RulingsStratum.rows(in: fixture.store.statementText(of: statement)).map(\.text),
            ["After again"])
    }

    /// Every mutation drops the scope's cached reading — a writer checked
    /// against a ruling they have just revoked is the whole reason the cache is
    /// keyed and invalidated at all.
    func test_theVerbsInvalidateTheDerivationForTheirOwnScope() async throws {
        let fixture = try await StatementMountFixture.novel(named: "invalidate")
        defer { fixture.tearDown() }
        let scope = Statement.Scope.document(fixture.documentItemId)
        let world = DeclaredWorldStore(projectRoot: fixture.projectURL,
                                       device: DeviceSlug.make(from: "test-mac"))
        _ = try await fixture.store.createStatement(kind: .intent, scope: scope)
        let statement = try XCTUnwrap(fixture.store.statement(kind: .intent, scope: scope))
        try await fixture.store.mutateStatementText(of: statement, session: "s") { _ in
            RulingsSection.render(essay: "E.", rulings: [
                Ruling(id: "", text: "One", ruledOn: nil, provenance: nil)])
        }

        let key = DeclaredWorldStore.scopeKey(for: scope)
        let text = fixture.store.statementText(of: statement)
        let hash = DerivedWorld.sourceHash(of: text)
        world.store(DerivedWorld(sourceHash: hash, clauses: [], rules: [], derivedAt: Date()),
                    forScopeKey: key)
        XCTAssertNotNil(world.cached(forScopeKey: key, sourceHash: hash))

        await RulingsStratum.edit(
            at: 0, to: "One, corrected", forScope: scope, store: fixture.store,
            world: world, undoManager: nil, workTaskSink: { _ in })
        XCTAssertNil(world.cached(forScopeKey: key, sourceHash: hash),
                     "an edited ruling left the scope's reading standing")
    }

    // MARK: - Bible stratum

    /// Which facts a scope shows. A document scope shows that document's; the
    /// project scope shows the book's whole ledger (`BibleStore.allFacts`'s own
    /// doc: "the Bible pane shows one piece's facts; a project-wide view shows
    /// all of them").
    func test_theBibleStratumIsSlicedByTheScopeOnScreen() {
        let facts = [
            makeFact(id: "1", subject: "Kelly", fact: "Kelly is a nurse.", docId: "doc-a"),
            makeFact(id: "2", subject: "Ray", fact: "Ray drives a van.", docId: "doc-b"),
        ]
        XCTAssertEqual(
            BibleStratum.facts(for: .document("doc-a"), in: facts).map(\.id), ["1"])
        XCTAssertEqual(
            BibleStratum.facts(for: .project, in: facts).map(\.id).sorted(), ["1", "2"])
        XCTAssertTrue(
            BibleStratum.facts(for: .document("doc-none"), in: facts).isEmpty,
            "a piece with no facts shows no stratum — there is no empty state to design")
    }

    /// The register is derived, and it says so in three channels because two of
    /// them are unavailable to somebody: the paper is the canvas's Claude tint
    /// (`CanvasMaterial.lightClaudeCardPaper` / `darkClaudeCardPaper`), the ink
    /// is `.secondary` rather than writer-ink, and the label speaks
    /// `CanvasAccessibility.claudeTerm`, because a colour is inaudible.
    func test_theBibleRegisterIsProvisionalInEveryChannel() {
        XCTAssertEqual(BibleStratum.paper, CanvasRenderer.claudeCardPaper,
                       "the provisional register must be the canvas's Claude tint, not a "
                       + "second answer to the same question")
        let fact = makeFact(id: "1", subject: "Kelly", fact: "Kelly is a nurse.",
                            docId: "doc-a", establishedAt: "wnse")
        XCTAssertTrue(
            BibleStratum.accessibilityLabel(for: fact).contains(CanvasAccessibility.claudeTerm),
            BibleStratum.accessibilityLabel(for: fact))
        XCTAssertTrue(BibleStratum.accessibilityLabel(for: fact).contains("Kelly is a nurse."))
    }

    /// The establishing ¶ is shown when the run could anchor the fact, and
    /// nothing is claimed when it could not.
    func test_theEstablishingParagraphIsShownWhenThereIsOne() {
        XCTAssertEqual(
            BibleStratum.caption(for: makeFact(id: "1", subject: "Kelly",
                                               fact: "F", docId: "doc-a",
                                               establishedAt: "wnse")),
            "Kelly · ¶wnse")
        XCTAssertEqual(
            BibleStratum.caption(for: makeFact(id: "1", subject: "Kelly",
                                               fact: "F", docId: "doc-a")),
            "Kelly")
    }

    /// **Bless graduates**: the fact becomes a ruling in the writer's own
    /// layer, with provenance saying where it came from, and it leaves the
    /// provisional register in the same act. Both halves, because either alone
    /// is a bug — a ruling with the fact still listed says the writer has to
    /// bless it twice, and a departed fact with no ruling loses it.
    func test_blessingLandsARulingAndTheFactLeavesTheBible() async throws {
        let fixture = try await StatementMountFixture.novel(named: "bless")
        defer { fixture.tearDown() }
        let scope = Statement.Scope.document(fixture.documentItemId)
        let bible = BibleStore(projectRoot: fixture.projectURL,
                               device: DeviceSlug.make(from: "test-mac"))
        let fact = makeFact(id: "f1", subject: "Kelly", fact: "Kelly is a nurse.",
                            docId: fixture.documentItemId, establishedAt: "wnse")
        bible.record([fact])

        await BibleStratum.bless(fact, forScope: scope, store: fixture.store,
                                 bible: bible, world: nil)

        let statement = try XCTUnwrap(fixture.store.statement(kind: .intent, scope: scope))
        let rulings = RulingsStratum.rows(in: fixture.store.statementText(of: statement))
        XCTAssertEqual(rulings.map(\.text), ["Kelly is a nurse."])
        XCTAssertEqual(rulings[0].provenance, BibleStratum.blessedProvenance)
        XCTAssertNotNil(rulings[0].ruledOn,
                        "a ruling is dated when it is made — the line must carry the day "
                        + "it was blessed")
        XCTAssertTrue(bible.allFacts().isEmpty,
                      "the blessed fact stayed in the provisional register")
    }

    /// Correcting is blessing the writer's own words instead of Claude's — the
    /// membrane is that a `String` the writer has approved is what crosses it,
    /// never a `BibleFact`.
    func test_correctingLandsTheWritersWordsAndTheFactLeaves() async throws {
        let fixture = try await StatementMountFixture.novel(named: "correct")
        defer { fixture.tearDown() }
        let scope = Statement.Scope.document(fixture.documentItemId)
        let bible = BibleStore(projectRoot: fixture.projectURL,
                               device: DeviceSlug.make(from: "test-mac"))
        let fact = makeFact(id: "f1", subject: "Kelly", fact: "Kelly is a nurse.",
                            docId: fixture.documentItemId)
        bible.record([fact])

        await BibleStratum.correct(fact, to: "Kelly is a paramedic.", forScope: scope,
                                   store: fixture.store, bible: bible, world: nil)

        let statement = try XCTUnwrap(fixture.store.statement(kind: .intent, scope: scope))
        let rulings = RulingsStratum.rows(in: fixture.store.statementText(of: statement))
        XCTAssertEqual(rulings.map(\.text), ["Kelly is a paramedic."])
        XCTAssertEqual(rulings[0].provenance, BibleStratum.correctedProvenance)
        XCTAssertTrue(bible.allFacts().isEmpty)
    }

    /// A refused graduation leaves the fact where it is. The order is the
    /// contract: dismissed first, a refusal would cost both the ruling and the
    /// reading, and the writer would have nothing left to press.
    func test_aRefusedBlessLeavesTheFactInTheRegister() async throws {
        let fixture = try await StatementMountFixture.novel(named: "bless-refused")
        defer { fixture.tearDown() }
        let bible = BibleStore(projectRoot: fixture.projectURL,
                               device: DeviceSlug.make(from: "test-mac"))
        let fact = makeFact(id: "f1", subject: "Kelly", fact: "Kelly is a nurse.",
                            docId: "doc-nowhere")
        bible.record([fact])

        // A scope naming no document in this project: `createStatement` throws
        // `.structureMissing`, so nothing is minted and nothing is written.
        await BibleStratum.bless(fact, forScope: .document("doc-nowhere"),
                                 store: fixture.store, bible: bible, world: nil)

        XCTAssertEqual(bible.allFacts().map(\.id), ["f1"],
                       "a refused bless dismissed the fact anyway")
    }

    /// Dismiss is the third action and is not undoable, on `DiagnosticsPane`'s
    /// stated reasoning: the bible is per-device derived state with no undo of
    /// its own, and a fact the manuscript still establishes comes back on the
    /// next run.
    func test_dismissingTakesTheFactOffThePane() throws {
        let bible = BibleStore(projectRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString),
                               device: DeviceSlug.make(from: "test-mac"))
        bible.record([makeFact(id: "f1", subject: "Kelly", fact: "F", docId: "d")])
        BibleStratum.dismiss(bible.allFacts()[0], bible: bible)
        XCTAssertTrue(bible.allFacts().isEmpty)
    }

    // MARK: - The strip above the prose quotes the essay

    /// **A ruling must never become the running head** (Task 4's carry, its
    /// report's concern 1).
    ///
    /// `IntentStrip.line(from:)` walks blocks and takes the first paragraph,
    /// list item or quoted line. A heading is skipped *as a heading* — so a
    /// piece whose intent is still only rulings has `## Rulings` skipped and its
    /// first list item answered, and the writer gets an itemized decision set
    /// over their prose in a slot that means "what this piece is going for".
    /// Two assertions, because the first alone passes for a strip that shows
    /// nothing at all.
    func test_theStripQuotesTheEssayAndNeverARuling() async throws {
        let fixture = try await StatementMountFixture.novel(named: "strip-essay")
        defer { fixture.tearDown() }
        let scope = Statement.Scope.document(fixture.documentItemId)
        _ = try await fixture.store.createStatement(kind: .intent, scope: scope)
        let statement = try XCTUnwrap(fixture.store.statement(kind: .intent, scope: scope))

        // Rulings and no essay yet: the strip has nothing to say and must say
        // nothing, rather than borrowing a ruling.
        try await RulingPerformer.rule("Kelly never lies", provenance: "from a run",
                                       forScope: scope, store: fixture.store, world: nil)
        XCTAssertNil(
            IntentStrip.line(store: fixture.store, docId: fixture.documentItemId,
                             persona: .author, isNoChromeOn: false),
            "the running head quoted a ruling")

        // The writer's own first sentence, and now there is a line.
        try await fixture.store.mutateStatementText(of: statement, session: "s") { markdown in
            StatementEssay.recomposed(essay: "A woman who hears everything.",
                                      into: markdown)
        }
        XCTAssertEqual(
            IntentStrip.line(store: fixture.store, docId: fixture.documentItemId,
                             persona: .author, isNoChromeOn: false),
            "A woman who hears everything.")
    }

    // MARK: - Nothing derived is drawn

    /// **The pane shows the writer's words and Claude's FACTS, and never
    /// Claude's mechanics** (spec §3.1: a derivation is "never shown as
    /// mechanics").
    ///
    /// This is also why there is no version-counter re-render test for
    /// `DeclaredWorldStore` beside the bible's: the pane renders nothing out of
    /// it, so it observes nothing out of it, and a test asserting a re-render
    /// would have to make the pane draw a derivation to have something to
    /// assert. The store's counter is load-bearing at the INVALIDATION
    /// (`test_theVerbsInvalidateTheDerivationForTheirOwnScope`), which is where
    /// it is pinned. A census rather than a comment, because this is exactly the
    /// claim a later convenience would quietly falsify.
    func test_theDerivationIsNeverDrawn() throws {
        let readings = ["DerivedClause", "DerivedRule", "DerivedWorld"]
        for file in ["Maugham/Views/StatementPane.swift",
                     "Maugham/Views/RulingsStratum.swift",
                     "Maugham/Views/BibleStratum.swift"] {
            let source = try readSource(file)
            // Non-vacuity: the census must actually be reading these files.
            XCTAssertTrue(source.contains("struct") || source.contains("enum"), file)
            for reading in readings {
                XCTAssertFalse(
                    source.contains(reading),
                    "\(file) names \(reading) — the pane draws the writer's words and "
                    + "Claude's facts, never the checkable reading behind them")
            }
        }
    }

    private func readSource(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - Version-counter re-render, both stores

    /// **Mount, mutate, assert the pane moved** — `DiagnosticsPaneTests`'
    /// version-counter idiom, for both new stores. A read that forgets to touch
    /// `version` renders once and then never again, which no unit test of the
    /// store itself can see.
    func test_thePaneRerendersWhenEitherStoreBumpsItsVersion() async throws {
        let fixture = try await StatementMountFixture.novel(named: "rerender")
        defer { fixture.tearDown() }
        let bible = BibleStore(projectRoot: fixture.projectURL,
                               device: DeviceSlug.make(from: "test-mac"))
        let world = DeclaredWorldStore(projectRoot: fixture.projectURL,
                                       device: DeviceSlug.make(from: "test-mac"))
        let window = await fixture.host(
            kind: .intent, subject: .item(fixture.documentItemId),
            bible: bible, world: world)

        XCTAssertTrue(try fixture.staticTexts(in: window, containing: "Kelly is a nurse.").isEmpty)

        bible.record([makeFact(id: "f1", subject: "Kelly", fact: "Kelly is a nurse.",
                               docId: fixture.documentItemId)])
        await fixture.pumpUntil(deadline: 3) { fixture.shows("Kelly is a nurse.", in: window) }
        XCTAssertFalse(try fixture.staticTexts(in: window, containing: "Kelly is a nurse.").isEmpty,
                       "the bible stratum did not pick up the store's version bump")

        bible.record([makeFact(id: "f2", subject: "Ray", fact: "Ray drives a van.",
                               docId: fixture.documentItemId)])
        await fixture.pumpUntil(deadline: 3) { fixture.shows("Ray drives a van.", in: window) }
        XCTAssertFalse(try fixture.staticTexts(in: window, containing: "Ray drives a van.").isEmpty,
                       "a second version bump did not re-render either")

        // The derivation store's counter is observed by the same body, so a
        // bump there must not crash or blank the pane — and the facts stay up.
        world.invalidate(forScopeKey: DeclaredWorldStore.scopeKey(
            for: .document(fixture.documentItemId)))
        await fixture.waitOut(0.3)
        XCTAssertFalse(try fixture.staticTexts(in: window, containing: "Ray drives a van.").isEmpty)
    }

    /// The rulings stratum appears beneath the writer's own editor once a
    /// ruling exists, through the real mounted pane — the delivery path, not
    /// the pure rule (`memory/project_milestone_mode_ux_redesign.md`'s lesson).
    func test_aRulingReachesTheMountedPane() async throws {
        let fixture = try await StatementMountFixture.novel(named: "mounted-ruling")
        defer { fixture.tearDown() }
        let scope = Statement.Scope.document(fixture.documentItemId)
        let bible = BibleStore(projectRoot: fixture.projectURL,
                               device: DeviceSlug.make(from: "test-mac"))
        let world = DeclaredWorldStore(projectRoot: fixture.projectURL,
                                       device: DeviceSlug.make(from: "test-mac"))
        let window = await fixture.host(
            kind: .intent, subject: .item(fixture.documentItemId),
            bible: bible, world: world)

        XCTAssertTrue(try fixture.staticTexts(in: window, containing: "Kelly never lies").isEmpty)

        try await RulingPerformer.rule("Kelly never lies", provenance: "from a run",
                                       forScope: scope, store: fixture.store, world: world)
        await fixture.pumpUntil(deadline: 5) { fixture.shows("Kelly never lies", in: window) }
        XCTAssertFalse(
            try fixture.staticTexts(in: window, containing: "Kelly never lies").isEmpty,
            "a ruling that landed while the pane was open never reached the stratum")

        // And it is NOT in the essay editor: the split is what keeps the
        // writer's own surface theirs.
        let textView = try fixture.textView(in: window)
        XCTAssertFalse(textView.string.contains("Kelly never lies"),
                       "the ruling was written into the essay editor's buffer: "
                       + textView.string)
    }

    // MARK: - Helpers

    private func makeFact(id: String, subject: String, fact: String, docId: String,
                          establishedAt: String? = nil) -> BibleFact {
        BibleFact(id: id, subject: subject, fact: fact, establishedAt: establishedAt,
                  docId: docId, recordedAt: Date())
    }
}
