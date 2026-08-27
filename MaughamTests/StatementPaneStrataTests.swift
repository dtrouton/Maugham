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

    /// Windows this suite hosted itself (the id census's planted offender), as
    /// opposed to the ones `StatementMountFixture` owns and tears down.
    private var bareWindows: [NSWindow] = []

    override func tearDown() async throws {
        for window in bareWindows { window.contentView = NSView(frame: .zero) }
        bareWindows.removeAll()
    }

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
            RulingsStratum.rows(in: try fixture.store.statementText(of: statement)).isEmpty,
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
            StatementEssay.half(of: try fixture.store.statementText(of: statement))
                .contains(underTheHeading))

        try await RulingPerformer.rule(
            "Kelly never lies", provenance: "from an answered note",
            kind: .intent, forScope: scope, store: fixture.store, world: nil)

        let after = try fixture.store.statementText(of: statement)
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

    /// The stratum belongs to the kinds a verb writes one into — intent, and
    /// (publish department, Task 6) an edition brief, `RulingPerformer`'s two
    /// destinations.
    ///
    /// Visual language has no rulings and no verb that writes one, so its editor
    /// binds its whole text — otherwise a writer who typed `## Rulings` as an
    /// ordinary heading in their visual language would watch the rest of the
    /// document leave the editor, with rows underneath whose Revoke button
    /// refuses (`RulingFailure.noStatement`, because the performer would look
    /// for an INTENT statement).
    func test_theRulingDestinationsCarryTheStratumAndNothingElseDoes() {
        XCTAssertTrue(StatementEssay.carriesRulings(.intent))
        XCTAssertTrue(
            StatementEssay.carriesRulings(.editionBrief("es")),
            "a brief carries rulings by construction \u{2014} answering no would not stop "
            + "the section existing, only stop everything downstream from seeing where "
            + "the essay ends")
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
            kind: .intent, forScope: scope, store: fixture.store, world: nil)

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
                                       kind: .intent, forScope: scope, store: fixture.store, world: nil)
        try await fixture.store.appendToStatement(
            "A promoted card.", to: statement, session: "s")

        let text = try fixture.store.statementText(of: statement)
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
                                       kind: .intent, forScope: scope, store: fixture.store, world: nil)

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
        let rows = RulingsStratum.rows(in: try fixture.store.statementText(of: statement))
        await RulingsStratum.revoke(
            rows[0], at: 0, kind: .intent, forScope: scope, store: fixture.store,
            world: nil, undoManager: undoManager, workTaskSink: { work.append($0) })

        XCTAssertEqual(
            RulingsStratum.rows(in: try fixture.store.statementText(of: statement)).map(\.text),
            ["Second"])

        undoManager.undo()
        for task in work { await task.value }
        work.removeAll()

        let restored = RulingsStratum.rows(in: try fixture.store.statementText(of: statement))
        XCTAssertEqual(restored.map(\.text), ["First", "Second"],
                       "one ⌘Z did not put the ruling back where it was")
        XCTAssertEqual(restored[0].ruledOn, ruled,
                       "the restored ruling was re-dated — a ⌘Z must not rewrite the record")
        XCTAssertEqual(restored[0].provenance, "from a run")
        XCTAssertEqual(StatementEssay.half(of: try fixture.store.statementText(of: statement)),
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
            at: 0, to: "First, corrected", kind: .intent, forScope: scope,
            store: fixture.store, world: nil, undoManager: undoManager,
            workTaskSink: { work.append($0) })

        let edited = RulingsStratum.rows(in: try fixture.store.statementText(of: statement))
        XCTAssertEqual(edited.map(\.text), ["First, corrected", "Second"],
                       "an edit moved the ruling out of its place")
        XCTAssertEqual(edited[0].ruledOn, ruled,
                       "a correction is a fix to a decision already made — it keeps its date")

        undoManager.undo()
        for task in work { await task.value }
        XCTAssertEqual(
            RulingsStratum.rows(in: try fixture.store.statementText(of: statement)).map(\.text),
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
            RulingsStratum.currentRows(kind: .intent, forScope: scope, store: fixture.store).count == 1
        }
        XCTAssertEqual(
            RulingsStratum.currentRows(kind: .intent, forScope: scope, store: fixture.store).map(\.text),
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
            RulingsStratum.currentRows(kind: .intent, forScope: scope, store: fixture.store).count == 2
        }
        let restored = RulingsStratum.currentRows(kind: .intent, forScope: scope, store: fixture.store)
        XCTAssertEqual(restored.map(\.text), ["First", "Second"],
                       "the window's ⌘Z did not put the revoked ruling back in place")
        XCTAssertEqual(restored[0].ruledOn, ruled)
        XCTAssertEqual(restored[0].provenance, "from a run")
        XCTAssertEqual(StatementEssay.half(of: try fixture.store.statementText(of: statement)),
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
        let before = RulingsStratum.rows(in: try fixture.store.statementText(of: statement))[0].id

        await RulingsStratum.edit(
            at: 0, to: "After", kind: .intent, forScope: scope, store: fixture.store,
            world: nil, undoManager: nil, workTaskSink: { _ in })

        let after = RulingsStratum.rows(in: try fixture.store.statementText(of: statement))[0]
        XCTAssertNotEqual(after.id, before,
                          "the ruling id must move with the text — if it did not, the "
                          + "row's stale id would still address the line and this suite "
                          + "would be proving nothing")
        // The second edit is the real assertion: it succeeds only because the
        // verb re-derived the id from the current text rather than reusing the
        // one the row was built with.
        await RulingsStratum.edit(
            at: 0, to: "After again", kind: .intent, forScope: scope,
            store: fixture.store, world: nil, undoManager: nil, workTaskSink: { _ in })
        XCTAssertEqual(
            RulingsStratum.rows(in: try fixture.store.statementText(of: statement)).map(\.text),
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
        let text = try fixture.store.statementText(of: statement)
        let hash = DerivedWorld.sourceHash(of: text)
        world.store(DerivedWorld(sourceHash: hash, clauses: [], rules: [], derivedAt: Date()),
                    forScopeKey: key)
        XCTAssertNotNil(world.cached(forScopeKey: key, sourceHash: hash))

        await RulingsStratum.edit(
            at: 0, to: "One, corrected", kind: .intent, forScope: scope,
            store: fixture.store, world: world, undoManager: nil, workTaskSink: { _ in })
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

    /// **The establishing paragraph is quoted, never named** (requirement 3:
    /// no bare ¶ids anywhere the writer reads). The caption is the subject and
    /// the paragraph's own words; the id rides along as `establishedAt` and is
    /// not what the writer is shown.
    func test_theEstablishingParagraphIsQuotedNotNamed() {
        let caption = BibleStratum.caption(
            for: makeFact(id: "1", subject: "Kelly", fact: "F", docId: "doc-a",
                          establishedAt: "wnse",
                          excerpt: "The fog came in off the water and\u{2026}"))
        XCTAssertEqual(
            caption, "Kelly · \u{201C}The fog came in off the water and\u{2026}\u{201D}")
        XCTAssertFalse(caption.contains("wnse"),
                       "the caption printed the paragraph id: \(caption)")
        XCTAssertFalse(caption.contains("\u{00b6}"),
                       "the caption printed a ¶ marker: \(caption)")
    }

    /// A fact the run could not anchor is captioned by its subject alone —
    /// **and so is a row from a sidecar written before excerpts existed**. The
    /// bible sidecar is derived state, so an old row decodes with a nil
    /// excerpt, and the tempting fallback (show the id, we have one) is the
    /// exact thing requirement 3 forbids.
    func test_aFactWithNoExcerptIsCaptionedBySubjectAloneAndNeverByItsId() {
        XCTAssertEqual(
            BibleStratum.caption(for: makeFact(id: "1", subject: "Kelly",
                                               fact: "F", docId: "doc-a")),
            "Kelly")
        // The pre-fix row: an id in hand, no excerpt.
        let legacy = makeFact(id: "1", subject: "Kelly", fact: "F", docId: "doc-a",
                              establishedAt: "wnse")
        XCTAssertEqual(BibleStratum.caption(for: legacy), "Kelly")
        XCTAssertFalse(BibleStratum.accessibilityLabel(for: legacy).contains("wnse"),
                       "VoiceOver read the paragraph id aloud: "
                       + BibleStratum.accessibilityLabel(for: legacy))
    }

    /// **No paragraph id reaches the mounted stratum** — the diagnostics pane's
    /// own census (`DiagnosticsPaneTests.test_noParagraphIdIsEverRendered`),
    /// pointed at the surface every run now feeds. Through the real pane, not
    /// the pure caption: the caption rule can be right while a row prints the
    /// id somewhere else.
    ///
    /// Proved against a **planted offender**: the same accessibility walk over
    /// a view that does print an id must find it, or an empty result here means
    /// only that the walk read nothing at all.
    func test_noParagraphIdIsRenderedOnTheBibleStratum() async throws {
        let fixture = try await StatementMountFixture.novel(named: "bible-ids")
        defer { fixture.tearDown() }
        let anchored = "wnse"
        let unexcerpted = "a1b2"
        let bible = BibleStore(projectRoot: fixture.projectURL,
                               device: DeviceSlug.make(from: "test-mac"))
        let window = await fixture.host(
            kind: .intent, subject: .item(fixture.documentItemId), bible: bible)

        bible.record([
            makeFact(id: "f1", subject: "Kelly", fact: "Kelly is a nurse.",
                     docId: fixture.documentItemId, establishedAt: anchored,
                     excerpt: "She had come off a double shift and\u{2026}"),
            // The pre-fix row beside it: an id in hand and no excerpt is
            // exactly the case a fallback would leak through.
            makeFact(id: "f2", subject: "Ray", fact: "Ray drives a van.",
                     docId: fixture.documentItemId, establishedAt: unexcerpted),
        ])
        await fixture.pumpUntil(deadline: 3) {
            fixture.shows("She had come off a double shift and", in: window)
        }

        XCTAssertFalse(
            try fixture.staticTexts(
                in: window, containing: "She had come off a double shift and").isEmpty,
            "control: the excerpt itself did not render, so the assertions below prove "
            + "nothing about ids")
        for id in [anchored, unexcerpted] {
            let leaked = try fixture.staticTexts(in: window, containing: id)
            XCTAssertTrue(leaked.isEmpty,
                          "the pane rendered the paragraph id \u{201C}\(id)\u{201D}: \(leaked)")
        }

        // The planted offender: the same walk over a view that DOES print an
        // id must find it.
        let offender = mountBare(AnyView(Text("\u{00b6}\(anchored)")))
        await fixture.waitOut(0.2)
        XCTAssertFalse(try fixture.staticTexts(in: offender, containing: anchored).isEmpty,
                       "the accessibility walk cannot see a rendered id at all, so the "
                       + "assertions above prove nothing")
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
        let rulings = RulingsStratum.rows(in: try fixture.store.statementText(of: statement))
        XCTAssertEqual(rulings.map(\.text), ["Kelly is a nurse."])
        XCTAssertEqual(rulings[0].provenance, BibleStratum.blessedProvenance)
        XCTAssertNotNil(rulings[0].ruledOn,
                        "a ruling is dated when it is made — the line must carry the day "
                        + "it was blessed")
        XCTAssertTrue(bible.allFacts().isEmpty,
                      "the blessed fact stayed in the provisional register")
        XCTAssertTrue(
            bible.isGraduated(subject: "Kelly", fact: "Kelly is a nurse."),
            "the graduation was not recorded, so the next run that re-reads the "
            + "establishing scene puts the blessed fact back on the pane")
    }

    /// **The door the graduation closes, through the real bless.** A run that
    /// re-reads the establishing prose re-emits the same candidate; `record`
    /// drops it, because the claim is the writer's now
    /// (`Maugham/Compiler/AREA.md`, "the third door"). The store's own pair of
    /// tests (`BibleStoreTests.test_aBlessedFactDoesNotComeBack` and its
    /// opposite) fixes the rule; this one says `bless` is what reaches it.
    func test_aFactBlessedHereIsNotRecordedAgainByALaterRun() async throws {
        let fixture = try await StatementMountFixture.novel(named: "bless-converges")
        defer { fixture.tearDown() }
        let scope = Statement.Scope.document(fixture.documentItemId)
        let bible = BibleStore(projectRoot: fixture.projectURL,
                               device: DeviceSlug.make(from: "test-mac"))
        let fact = makeFact(id: "f1", subject: "Kelly", fact: "Kelly is a nurse.",
                            docId: fixture.documentItemId)
        bible.record([fact])

        await BibleStratum.bless(fact, forScope: scope, store: fixture.store,
                                 bible: bible, world: nil)

        // The next run's candidate: a fresh id, the same reading.
        bible.record([makeFact(id: "f2", subject: "Kelly", fact: "Kelly is a nurse.",
                               docId: fixture.documentItemId)])

        XCTAssertTrue(bible.allFacts().isEmpty,
                      "a blessed fact came back as a new reading")
    }

    /// **Correcting closes the door on CLAUDE's reading.** What the model
    /// re-emits is what it read — "Kelly is a nurse." — so that is the first of
    /// the two keys a correction has to hold.
    ///
    /// Its other half is the test below it,
    /// `test_correctingAlsoGraduatesTheWritersOwnRuling`. Neither is the whole
    /// rule and a reader who finds one alone will think it is.
    func test_correctingGraduatesClaudesReading() async throws {
        let fixture = try await StatementMountFixture.novel(named: "correct-converges")
        defer { fixture.tearDown() }
        let scope = Statement.Scope.document(fixture.documentItemId)
        let bible = BibleStore(projectRoot: fixture.projectURL,
                               device: DeviceSlug.make(from: "test-mac"))
        let fact = makeFact(id: "f1", subject: "Kelly", fact: "Kelly is a nurse.",
                            docId: fixture.documentItemId)
        bible.record([fact])

        await BibleStratum.correct(fact, to: "Kelly is a paramedic.", forScope: scope,
                                   store: fixture.store, bible: bible, world: nil)

        XCTAssertTrue(bible.isGraduated(subject: "Kelly", fact: "Kelly is a nurse."),
                      "the reading the writer amended is exactly what the next run "
                      + "re-emits, and it was left free to return")
        bible.record([makeFact(id: "f2", subject: "Kelly", fact: "Kelly is a nurse.",
                               docId: fixture.documentItemId)])
        XCTAssertTrue(bible.allFacts().isEmpty,
                      "the amended reading came back as a fresh candidate")
    }

    /// **…and on the writer's own ruling, which is the half that reopened the
    /// door** (fix round 1's finding, demonstrated against the shipped code:
    /// the corrected sentence came back as a new, unsuppressed fact).
    ///
    /// A correction leaves TWO sentences that are no longer news — the reading
    /// Claude made and the ruling the writer made from it — and the manuscript
    /// can establish either. A run that reads the amended prose and phrases the
    /// candidate the way the writer already ruled it would invite them to bless
    /// their own decision a second time, and `RulingsSection.appending` does
    /// not dedupe: that is door 3's duplicate ruling row (AREA.md), reached
    /// through correction instead of bless.
    ///
    /// Its other half is the test above it,
    /// `test_correctingGraduatesClaudesReading`. Falsify by removing the second
    /// `markGraduated` from `BibleStratum.graduate`.
    func test_correctingAlsoGraduatesTheWritersOwnRuling() async throws {
        let fixture = try await StatementMountFixture.novel(named: "correct-both")
        defer { fixture.tearDown() }
        let scope = Statement.Scope.document(fixture.documentItemId)
        let bible = BibleStore(projectRoot: fixture.projectURL,
                               device: DeviceSlug.make(from: "test-mac"))
        let fact = makeFact(id: "f1", subject: "Kelly", fact: "Kelly is a nurse.",
                            docId: fixture.documentItemId)
        bible.record([fact])

        await BibleStratum.correct(fact, to: "Kelly is a paramedic.", forScope: scope,
                                   store: fixture.store, bible: bible, world: nil)

        XCTAssertTrue(
            bible.isGraduated(subject: "Kelly", fact: "Kelly is a paramedic."),
            "the writer's own ruled sentence is not graduated, so a run that reads "
            + "it off the prose offers it back to them as a reading to bless")
        bible.record([makeFact(id: "f2", subject: "Kelly", fact: "Kelly is a paramedic.",
                               docId: fixture.documentItemId)])
        XCTAssertTrue(
            bible.allFacts().isEmpty,
            "the writer's already-ruled sentence returned to the provisional "
            + "register: \(bible.allFacts().map(\.fact))")
    }

    /// A plain bless has one sentence, not two, and marks it once — the second
    /// `markGraduated` is the same key and must not cost a second write or a
    /// second `version` bump, which every observer of this store reads as the
    /// ledger having moved.
    func test_blessingMarksOneKeyAndWritesOnce() async throws {
        let fixture = try await StatementMountFixture.novel(named: "bless-one-key")
        defer { fixture.tearDown() }
        let scope = Statement.Scope.document(fixture.documentItemId)
        let bible = BibleStore(projectRoot: fixture.projectURL,
                               device: DeviceSlug.make(from: "test-mac"))
        let fact = makeFact(id: "f1", subject: "Kelly", fact: "Kelly is a nurse.",
                            docId: fixture.documentItemId)
        bible.record([fact])
        let versionBefore = bible.version

        await BibleStratum.bless(fact, forScope: scope, store: fixture.store,
                                 bible: bible, world: nil)

        XCTAssertEqual(bible.version, versionBefore + 2,
                       "a bless is one graduation and one dismissal \u{2014} a third "
                       + "bump means the reading was marked twice under two keys")
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
        let rulings = RulingsStratum.rows(in: try fixture.store.statementText(of: statement))
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
        XCTAssertFalse(
            bible.isGraduated(subject: "Kelly", fact: "Kelly is a nurse."),
            "a refused bless closed the door anyway: nothing graduated, so the "
            + "fact standing there is a reading the writer can still press \u{2014} "
            + "and a run that re-establishes it must be able to")
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
                                       kind: .intent, forScope: scope, store: fixture.store, world: nil)
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
                                       kind: .intent, forScope: scope, store: fixture.store, world: world)
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

    // MARK: - The edition brief is a first-class statement surface (P4 Task 7)

    /// **The bible belongs to the craft intent alone, and it is asked its own
    /// question** — the first of the two traps `StatementEssay.carriesRulings`
    /// recorded against itself, sprung.
    ///
    /// `bibleFacts` gated on `carriesRulings`, which answers a question about
    /// the FILE — does a `## Rulings` section live in this one — standing in for
    /// a question about the SUBJECT: is this the craft intent. The two agreed
    /// for exactly as long as intent was the only kind with strata. The moment
    /// the edition brief joined it, the proxy put the project's whole bible —
    /// Claude's readings of what the manuscript establishes — under a brief
    /// about how the book reads in Spanish.
    ///
    /// **What is pinned here is the PREDICATE, not a nil.** Task 2's door hands
    /// `StatementPane` no bible at all, so a test that mounted the brief the way
    /// the department does would pass over a pane with nothing to draw and would
    /// say nothing whatever about the rule. Both panes below are handed the SAME
    /// live store holding the SAME fact; the only difference between them is the
    /// kind.
    ///
    /// Falsify by putting `StatementEssay.carriesRulings` back into
    /// `StatementPane.bibleFacts`: the brief's assertion goes red.
    func test_aBriefRefusesTheBibleEvenWithAStoreThreadedThroughIt() async throws {
        let fixture = try await StatementMountFixture.novel(named: "brief-no-bible")
        defer { fixture.tearDown() }
        let bible = BibleStore(projectRoot: fixture.projectURL,
                               device: DeviceSlug.make(from: "test-mac"))
        bible.record([makeFact(id: "f1", subject: "Kelly", fact: "Kelly is a nurse.",
                               docId: fixture.documentItemId)])

        let briefWindow = await fixture.host(
            kind: .editionBrief("es"), subject: .project, bible: bible)
        // An absence needs a span of wall clock to mean anything.
        await fixture.waitOut(0.4)
        XCTAssertTrue(
            fixture.shows(
                TranslationReviewIndicator.displayLabel(forLanguageTag: "es"), in: briefWindow),
            "control: the brief pane's own header never rendered, so the assertion "
            + "below proves nothing about what it refused to draw")
        XCTAssertTrue(
            try fixture.staticTexts(in: briefWindow, containing: "Kelly is a nurse.").isEmpty,
            "the project's bible — Claude's readings of the English manuscript — is "
            + "on screen under a brief about how the book reads in Spanish")

        // The same store, the same fact, the kind it does belong to.
        let intentWindow = await fixture.host(
            kind: .intent, subject: .project, bible: bible)
        await fixture.pumpUntil(deadline: 5) {
            fixture.shows("Kelly is a nurse.", in: intentWindow)
        }
        XCTAssertFalse(
            try fixture.staticTexts(in: intentWindow, containing: "Kelly is a nurse.").isEmpty,
            "the new predicate refuses the bible under INTENT too — the trap was "
            + "sprung by taking the stratum away from everybody")
    }

    /// The bible's question, beside the rulings' question, on the one kind where
    /// they differ. Two predicates that agree everywhere are one predicate with
    /// a spare name, and the inequality below is what stops this becoming that
    /// again.
    func test_theBibleBelongsToTheCraftIntentAloneAndAsksItsOwnQuestion() {
        XCTAssertTrue(BibleStratum.belongsTo(.intent))
        XCTAssertFalse(BibleStratum.belongsTo(.editionBrief("es")))
        XCTAssertFalse(BibleStratum.belongsTo(.visualLanguage))
        XCTAssertFalse(BibleStratum.belongsTo(.unknown("newer-build")))
        XCTAssertNotEqual(
            BibleStratum.belongsTo(.editionBrief("es")),
            StatementEssay.carriesRulings(.editionBrief("es")),
            "the bible's predicate is the rulings' predicate again — an edition "
            + "brief carries rulings and does not carry a bible, and one answer "
            + "cannot say both")
    }

    /// **The rulings verbs act on the statement they are given, and never on
    /// intent** — the second recorded trap, sprung.
    ///
    /// They named `.intent` at all six calls into `RulingPerformer` and again in
    /// `currentRows`' lookup. The failure that would have caused is worse than
    /// the refusal the trap's own note predicted: an edition brief is
    /// project-scope, the craft intent for a book is project-scope too, so a
    /// Revoke pressed on the Spanish brief's row would have found the BOOK's
    /// intent statement at the same scope, matched nothing there and refused —
    /// or, with a ruling of the same words in both, revoked the wrong one.
    ///
    /// So both statements exist here with different rulings, and every assertion
    /// checks the one that was not addressed as well as the one that was.
    func test_theRulingsVerbsActOnTheStatementTheyAreGivenAndNotOnIntent() async throws {
        let fixture = try await StatementMountFixture.novel(named: "brief-verbs")
        defer { fixture.tearDown() }
        let brief = Statement.Kind.editionBrief("es")
        let ruled = Date(timeIntervalSince1970: 1_786_060_800)
        let (intentStatement, briefStatement) = try await seedBothStatements(
            in: fixture, ruled: ruled)

        // Reading is keyed on the kind, not on the scope alone.
        XCTAssertEqual(
            RulingsStratum.currentRows(kind: brief, forScope: .project,
                                       store: fixture.store).map(\.text),
            ["Usted throughout", "Keep the songs in English"])
        XCTAssertEqual(
            RulingsStratum.currentRows(kind: .intent, forScope: .project,
                                       store: fixture.store).map(\.text),
            ["Kelly never lies"])

        let undoManager = UndoManager()
        var work: [Task<Void, Never>] = []
        let rows = RulingsStratum.currentRows(kind: brief, forScope: .project,
                                              store: fixture.store)
        await RulingsStratum.revoke(
            rows[0], at: 0, kind: brief, forScope: .project, store: fixture.store,
            world: nil, undoManager: undoManager, workTaskSink: { work.append($0) })

        XCTAssertEqual(
            RulingsStratum.currentRows(kind: brief, forScope: .project,
                                       store: fixture.store).map(\.text),
            ["Keep the songs in English"],
            "the brief's Revoke did not reach the brief")
        XCTAssertEqual(
            RulingsStratum.rows(in: try fixture.store.statementText(of: intentStatement))
                .map(\.text),
            ["Kelly never lies"],
            "a Revoke pressed on the Spanish brief reached the book's craft intent")

        undoManager.undo()
        for task in work { await task.value }
        work.removeAll()
        let restored = RulingsStratum.currentRows(kind: brief, forScope: .project,
                                                  store: fixture.store)
        XCTAssertEqual(restored.map(\.text), ["Usted throughout", "Keep the songs in English"],
                       "one ⌘Z did not put the brief's ruling back where it was")
        XCTAssertEqual(restored[0].ruledOn, ruled,
                       "the restored ruling was re-dated — a ⌘Z must not rewrite the record")
        XCTAssertEqual(restored[0].provenance, "from an answered query")

        await RulingsStratum.edit(
            at: 0, to: "Usted throughout, except in the songs", kind: brief,
            forScope: .project, store: fixture.store, world: nil,
            undoManager: undoManager, workTaskSink: { work.append($0) })

        XCTAssertEqual(
            RulingsStratum.currentRows(kind: brief, forScope: .project,
                                       store: fixture.store).map(\.text),
            ["Usted throughout, except in the songs", "Keep the songs in English"],
            "an edit moved the brief's ruling out of its place")
        XCTAssertEqual(
            RulingsStratum.rows(in: try fixture.store.statementText(of: intentStatement))
                .map(\.text),
            ["Kelly never lies"], "the brief's Edit reached the book's craft intent")
        XCTAssertEqual(
            StatementEssay.half(of: try fixture.store.statementText(of: briefStatement)),
            "The Spanish edition.", "the edit disturbed the brief's essay")

        undoManager.undo()
        for task in work { await task.value }
        XCTAssertEqual(
            RulingsStratum.currentRows(kind: brief, forScope: .project,
                                       store: fixture.store).map(\.text),
            ["Usted throughout", "Keep the songs in English"],
            "one ⌘Z did not restore the brief ruling's old words")
    }

    /// **The delivery path**: the brief's rows are on screen, and the Revoke the
    /// writer presses there acts on the brief.
    ///
    /// The verbs taking a kind is enforced by the compiler; that
    /// `StatementPane` hands them **its own** kind rather than a literal
    /// `.intent` is not, and this project's recorded lesson is that a stratum
    /// suite can be green over a control that reaches the wrong file
    /// (`memory/project_milestone_mode_ux_redesign.md`). Production the whole
    /// way: the real pane, the real mounted stratum, the real `Button` pressed
    /// through the accessibility tree.
    func test_pressingRevokeOnTheMountedBriefTakesTheBriefsRulingAndNotTheBooks() async throws {
        let fixture = try await StatementMountFixture.novel(named: "brief-revoke")
        defer { fixture.tearDown() }
        let brief = Statement.Kind.editionBrief("es")
        let ruled = Date(timeIntervalSince1970: 1_786_060_800)
        let (intentStatement, _) = try await seedBothStatements(in: fixture, ruled: ruled)

        let window = await fixture.host(kind: brief, subject: .project)
        await fixture.pumpUntil(deadline: 5) { fixture.shows("Usted throughout", in: window) }
        XCTAssertTrue(
            fixture.shows("Usted throughout", in: window),
            "the brief's rulings never reached the mounted stratum, so there is no "
            + "control to press")
        XCTAssertFalse(
            fixture.shows("Kelly never lies", in: window),
            "the book's craft intent is itemized under the Spanish edition brief")

        try fixture.pressButton(labelled: "Revoke", in: window)
        await fixture.pumpUntil(deadline: 5) {
            RulingsStratum.currentRows(kind: brief, forScope: .project,
                                       store: fixture.store).count == 1
        }
        XCTAssertEqual(
            RulingsStratum.currentRows(kind: brief, forScope: .project,
                                       store: fixture.store).map(\.text),
            ["Keep the songs in English"],
            "pressing Revoke on the mounted brief row did not revoke it")
        XCTAssertEqual(
            RulingsStratum.rows(in: try fixture.store.statementText(of: intentStatement))
                .map(\.text),
            ["Kelly never lies"],
            "the mounted pane passed a literal `.intent` to its stratum — the writer's "
            + "press on a brief row reached the book's craft intent")
    }

    // MARK: - Helpers

    /// The book's craft intent and its Spanish edition brief, both project-scope,
    /// each carrying its own rulings — the arrangement every brief-side assertion
    /// needs, because a verb that reaches the wrong one is invisible unless the
    /// other one is there to be reached.
    private func seedBothStatements(
        in fixture: StatementMountFixture, ruled: Date
    ) async throws -> (intent: Statement, brief: Statement) {
        _ = try await fixture.store.createStatement(kind: .intent, scope: .project)
        _ = try await fixture.store.createStatement(kind: .editionBrief("es"), scope: .project)
        let intentStatement = try XCTUnwrap(
            fixture.store.statement(kind: .intent, scope: .project))
        let briefStatement = try XCTUnwrap(
            fixture.store.statement(kind: .editionBrief("es"), scope: .project))
        try await fixture.store.mutateStatementText(of: intentStatement, session: "s") { _ in
            RulingsSection.render(essay: "The book.", rulings: [
                Ruling(id: "", text: "Kelly never lies", ruledOn: ruled,
                       provenance: "from a run"),
            ])
        }
        try await fixture.store.mutateStatementText(of: briefStatement, session: "s") { _ in
            RulingsSection.render(essay: "The Spanish edition.", rulings: [
                Ruling(id: "", text: "Usted throughout", ruledOn: ruled,
                       provenance: "from an answered query"),
                Ruling(id: "", text: "Keep the songs in English", ruledOn: ruled,
                       provenance: "by hand"),
            ])
        }
        return (intentStatement, briefStatement)
    }

    private func makeFact(id: String, subject: String, fact: String, docId: String,
                          establishedAt: String? = nil,
                          excerpt: String? = nil) -> BibleFact {
        BibleFact(id: id, subject: subject, fact: fact, establishedAt: establishedAt,
                  excerpt: excerpt, docId: docId, recordedAt: Date())
    }

    /// A window around a bare view, for the planted offender alone — the
    /// fixture's own hosting is private and is about the pane. Torn down with
    /// the test class rather than the fixture.
    private func mountBare(_ view: AnyView) -> NSWindow {
        let window = TestWindow.mount(view, size: CGSize(width: 320, height: 120))
        bareWindows.append(window)
        return window
    }
}
