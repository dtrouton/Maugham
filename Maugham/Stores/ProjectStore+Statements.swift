import Foundation
import MaughamCore

/// Statement store seam (M1A). A statement — the writer's intent, or the book's
/// visual language — is found by **scope, in the manifest**, and its content is
/// an ordinary `Document` living in the open at the project root.
///
/// This is the seam that replaces `ProjectStore+CraftIntent.swift`, and the
/// replacement is what kills that seam's defect rather than fixing it: craft
/// intent was located by the piece's research PATH PREFIX
/// (`ResearchScope.pieceResearchPrefix`, `guard piece.pieceKind == .loose`), so
/// a novel chapter's intent was created into shared `research/` where the lookup
/// never looked, and the next create minted a second copy of the writer's prose.
/// There is no prefix here, so there is nothing to be nil.
extension ProjectStore {

    // MARK: - The one live Document per statement

    /// Record that a pane has this statement's `Document` open.
    ///
    /// Called by `StatementEditorHost` the moment it binds one. Everything else
    /// that writes into a statement asks `openStatementDocument(id:)` FIRST and
    /// only loads its own when the answer is nil — see that property's storage
    /// on `ProjectStore` for what two live `Document`s on one path cost.
    func noteStatementDocumentOpened(_ document: Document, id: String) {
        openStatementDocuments[id] = OpenStatementDocument(document)
    }

    /// Drop a pane's registration. Hygiene rather than correctness — the entry
    /// is weak and the read below refuses a closed `Document` — but a registry
    /// that is only ever added to is one nobody can reason about.
    func forgetStatementDocument(id: String) {
        openStatementDocuments[id] = nil
    }

    /// The live `Document` for a statement, or nil.
    ///
    /// **Nil for a CLOSED one, and that is the load-bearing half.** A pane that
    /// has gone away closes its `Document` and may still hold the reference
    /// (`.onDisappear` closes but does not release), so a registry that answered
    /// with a husk would send an append into `setFullText`'s closed-doc no-op.
    /// Nil sends the caller down its own transient-load path, which is correct
    /// because there is no longer a second live `Document` to collide with.
    func openStatementDocument(id: String) -> Document? {
        guard let document = openStatementDocuments[id]?.document else {
            openStatementDocuments[id] = nil
            return nil
        }
        guard !document.isClosed else { return nil }
        return document
    }

    /// What a statement currently SAYS, **derived rather than read off the
    /// `.md`** (tripwire 20). A statement is a `Document` with an op log, so the
    /// file beside it is derived output and lags whenever an op lands out of
    /// band — a peer syncing `.maugham/ops/` before the render leaves exactly
    /// those bytes.
    ///
    /// ADR 0018's two branches, with the open one reached by a seam of its own:
    /// a statement is deliberately in no `DocumentStore` registry (spec §8 — it
    /// would join `allOpenDocuments()` and pollute the project Tasks
    /// aggregation), so `documentStore.document(forDocId:)` answers nil for one
    /// and the branch `read_document` and `find_references` take is unavailable
    /// here. `openStatementDocument(id:)` — built for promotion's own collision
    /// on this path — is what finds the pane's live `Document`, and it is the
    /// fresher answer by up to one debounce window: a burst the writer is still
    /// typing has not reached `.maugham/ops/` yet, and the derived branch cannot
    /// see it.
    ///
    /// **One spelling, for every statement reader.** `read_craft_intent` and
    /// `read_visual_language` both answer through here; a second copy of this
    /// choice is two readers that can come to different conclusions about which
    /// text is real, which is the drift `CanvasClaudeWrite.readScene` is shared
    /// to prevent on the canvas.
    ///
    /// Display form, not the materialised one: a statement carries no
    /// annotations, so nothing on these surfaces anchors to a `¶id`, and what
    /// the writer sees in the pane is what Claude should read.
    func statementText(of statement: Statement) throws -> String {
        if let live = openStatementDocument(id: statement.id) {
            return live.displayText
        }
        // RULING-54: an unreadable statement log throws — a pane or tool
        // showing the writer's INTENT as empty over a file it could not read
        // is the M1-C-055 shape one surface over.
        return try derivedCache.displayText(forDocId: statement.id, in: url)
    }

    /// `(id, composed title)` for every statement — the resolution-side spelling
    /// of "what a statement is called". `ArtifactIndex.statementTitle` is the ONE
    /// composer (its doc comment says why); this walks `structure` once, as
    /// `ArtifactIndex.over` does, rather than per statement.
    func statementTitlePairs() -> [(id: String, title: String)] {
        let titlesByDocument = Dictionary(
            TreeWalk.collect(in: manifest.structure, where: { _ in true })
                .map { ($0.id, $0.title) },
            uniquingKeysWith: { _, later in later })
        return manifest.statements.map {
            ($0.id, ArtifactIndex.statementTitle($0, documentTitle: { titlesByDocument[$0] }))
        }
    }

    // MARK: - Opening one, which is not the same as holding one

    /// Take exclusive right to OPEN a `Document` on this statement's path, and
    /// wait if somebody else already has it.
    ///
    /// **The registry above is not enough on its own, and the gap is a
    /// suspension rather than a race that can be avoided by ordering.**
    /// `openStatementDocument(id:)` answers for a `Document` that is already
    /// open; `Document.load` is `async` and constructs a fresh instance per call
    /// (there is no instance sharing), so between "the registry says nobody has
    /// this" and "I have registered mine" there is a window in which a second
    /// opener asks the same question and gets the same answer. Both then hold a
    /// live `Document` on one path, each with its own `PendingBuffer`, and the
    /// one that loaded first has content the other never saw — which is the
    /// paragraph-loss `StatementEditorHost.reconcile` calls unreachable for the
    /// case IT controls.
    ///
    /// **Who takes it is a census, not a count** —
    /// `TripwireGrepTests.statementOpenGateTakers`, which names every member and
    /// goes red when the set changes. Read it rather than a sentence here: this
    /// comment said "Both openers take it" for a whole slice, over three openers,
    /// one of which took nothing, while naming `PromotionPerformer` — which is
    /// not an opener at all and reaches the gate through `appendToStatement` —
    /// and omitting `promotePieceToProject`, which takes the gate while opening
    /// nothing because it MOVES the file the gate is over.
    ///
    /// **The lock is only over the OPENING** — the pane releases as soon as it
    /// has registered, so a writer that queues behind it finds the registry
    /// populated and takes the live-`Document` path instead of loading at all.
    /// That is why everyone who waits re-asks once it is inside, each its own
    /// question: the transient arm re-asks the REGISTRY
    /// (`withStatementDocument`),
    /// and the pane re-asks its own text box (`StatementEditorHost.gateArrival`,
    /// which is what keeps its mint and its `reconcile` from binding one
    /// statement twice). Waiting alone is a delay; the re-ask is the fix.
    ///
    /// `defer { unlockStatementOpen(id) }` at every call site. There is no
    /// suspension between the check and the claim below, so two callers arriving
    /// in one main-actor turn cannot both claim it.
    func lockStatementOpen(_ id: String) async {
        while statementOpensInFlight.contains(id) {
            await withCheckedContinuation { continuation in
                statementOpenWaiters[id, default: []].append(continuation)
            }
        }
        statementOpensInFlight.insert(id)
    }

    /// Release the open lock and wake everyone queued behind it. Each waiter
    /// re-checks, so waking them all is correct rather than merely convenient.
    func unlockStatementOpen(_ id: String) {
        statementOpensInFlight.remove(id)
        let waiters = statementOpenWaiters.removeValue(forKey: id) ?? []
        for waiter in waiters { waiter.resume() }
    }

    /// The statement for a scope, or nil. **Absence is valid**: this mints
    /// nothing, stamps nothing and logs nothing — unlike `craftIntentItem`,
    /// which lazily healed a legacy identity on read, a statement's identity is
    /// its manifest entry and there is nothing to heal.
    public func statement(kind: Statement.Kind, scope: Statement.Scope) -> Statement? {
        StatementLookup.statement(in: manifest.statements, kind: kind, scope: scope)
    }

    /// The intent that **applies to** a document: the document's own if it has
    /// one, else the project's, else none.
    ///
    /// **One spelling, because two readers of "which intent applies here" can
    /// disagree and nothing on screen would say so.** The compiler briefs a run
    /// with this resolution (`CompilerEnvironment+Project`'s `intent` closure)
    /// and the intent strip shows the writer the line it produces
    /// (`IntentStrip.line(store:docId:…)`); a strip reading the chapter's while
    /// the run was briefed on the book's is a lie about what Claude was told.
    /// The scope that resolved rides back on `Statement.scope`, which is what
    /// the compiler's prompt label is derived from.
    ///
    /// **Not `StatementPane.effectiveScope`, and not a rival to it.** That one
    /// answers "which scope is this window's subject *about*" from the binder
    /// selection alone, and never falls back — a chapter with no intent yet
    /// resolves to `.document(id)` there, because the pane's empty editor is
    /// what mints one. This one answers "which intent should be *read*", where
    /// absence is the whole reason the project's exists. A reader wanting the
    /// pane's answer must not use this, and vice versa.
    ///
    /// Absence is valid and mints nothing (M1A's rule).
    func effectiveIntent(forDocId docId: String) -> Statement? {
        statement(kind: .intent, scope: .document(docId))
            ?? statement(kind: .intent, scope: .project)
    }

    /// Find-or-create the statement for a scope. **Idempotent**: called twice
    /// for the same `(kind, scope)` it returns the same statement and creates no
    /// second file.
    ///
    /// Throws — never silently falls back to project scope — when the scope
    /// names something that is not a manuscript document in this project
    /// (`.structureMissing`), and when the `(kind, scope)` pair has no row in
    /// the §2.2 storage table (`.statementHasNoStorage`). The old seam kept the
    /// same discipline (`ProjectStore+CraftIntent.swift`) and it is worth
    /// keeping: a chapter's intent quietly written into the book's file is the
    /// same class of loss as writing it into a second file nobody reads.
    @discardableResult
    public func createStatement(
        kind: Statement.Kind, scope: Statement.Scope
    ) async throws -> Statement {
        if let existing = statement(kind: kind, scope: scope) { return existing }

        let slug = try documentSlug(for: scope)
        guard let candidate = StatementConvention.newPath(
            kind: kind, scope: scope, documentSlug: slug) else {
            throw ProjectStoreError.statementHasNoStorage(
                kind: kind.rawValue, scope: scope.rawValue)
        }
        let relativePath = vacantStatementPath(basedOn: candidate)

        let fileURL = url.appendingPathComponent(relativePath)
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Empty scaffolding, as every other creator in this store writes it
            // (`addStructureItem`, `addResearchTextNote`): a brand-new file with
            // no second writer for NSFileCoordinator to arbitrate. Content
            // arrives through the op log from here on.
            try Data().write(to: fileURL)
        } catch {
            throw ProjectStoreError.fileSystemError(error.localizedDescription)
        }

        let created = Statement(
            id: Self.newId(prefix: "stmt"), kind: kind, scope: scope, path: relativePath)
        manifest.statements.append(created)
        manifest.modified = Date()
        try await saveManifest()
        return created
    }

    /// Undo one `createStatement` whose purpose failed before anything reached
    /// it (issue #29: an image save that threw, a superseded mint nothing was
    /// deposited into). `createStatement` commits exactly two things — an empty
    /// file and a manifest row — and this removes exactly those two, **manifest
    /// FIRST**: a row pointing at a missing file is a dangle every reader hits,
    /// while a stray empty file with no row is inert, and `vacantStatementPath`
    /// steers the next mint around it.
    ///
    /// **REFUSES — returning false**, because a refusal is a normal answer on a
    /// failure path and not a second failure for the caller to handle:
    ///
    /// - when a pane has the statement **open**, whatever its text says: a
    ///   `Document` whose file was deleted under it is a writer typing into
    ///   nothing;
    /// - when its op-log **derivation has words**. That question is asked of the
    ///   derivation and never of the `.md` (tripwire 20) — the op log is the
    ///   record of whether any deposit ever landed, and an unreadable log
    ///   (RULING-54 throws) cannot prove emptiness, so it refuses too;
    /// - when the **file has bytes** even though the derivation is empty. Not
    ///   belt-and-braces: a freshly promoted Collection piece carries its
    ///   intent's prose in the `.md` with no `.maugham/` at all
    ///   (`stagePromotedIntent`), so the derive says `""` over a file full of
    ///   paragraphs. A `stat` and never a read — the same non-zero-size question
    ///   `propagateWikiLinkRename` asks for the same state, which is why it is
    ///   not the manuscript-as-truth read ADR 0018 forbids;
    /// - when the manifest **no longer knows** it. Identity is the manifest `id`
    ///   (tripwire 22), so a stale handle naming a path a *later* statement now
    ///   lives at removes nothing.
    ///
    /// The removal is a direct `removeItem` rather than the typed mover
    /// (tripwire 14) because it is the exact inverse of `createStatement`'s own
    /// direct `Data().write(to:)`, and the mover's discipline is
    /// close-before-surgery for a path with a live autosave on it — which the
    /// open refusal above has already established there is not.
    ///
    /// **The caller must NOT already hold `lockStatementOpen` for this id — the
    /// gate is not reentrant.** This takes it unconditionally at entry, and
    /// `lockStatementOpen` parks a caller that finds the id in flight on a
    /// continuation resumed only by `unlockStatementOpen`, so a re-entrant call
    /// waits on a lock it is itself holding: a **hang**, with no error and
    /// nothing red to explain it. The rollback callers are failure paths inside
    /// `createStatement`'s own callers, which hold nothing — but a future one
    /// reaching for this from inside `withStatementDocument`'s gate, or from a
    /// pane that has taken it to load, is the shape to refuse at review.
    @discardableResult
    public func rollbackUnusedStatement(_ statement: Statement) async -> Bool {
        // Under the open gate, so a pane cannot bind this statement between the
        // check below and the file going away.
        await lockStatementOpen(statement.id)
        defer { unlockStatementOpen(statement.id) }
        guard openStatementDocument(id: statement.id) == nil else { return false }

        guard let derived = try? statementText(of: statement),
              derived.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }

        let fileURL = url.appendingPathComponent(statement.path)
        let size = (try? FileManager.default.attributesOfItem(
            atPath: fileURL.path))?[.size] as? Int ?? 0
        guard size == 0 else { return false }

        guard let row = manifest.statements.firstIndex(where: { $0.id == statement.id })
        else { return false }
        let previouslyModified = manifest.modified
        manifest.statements.remove(at: row)
        manifest.modified = Date()
        do {
            try await saveManifest()
        } catch {
            // The row could not be dropped, so put it back — including the
            // stamp, since nothing was modified — and refuse. Deleting the file
            // under a live row is the dangle this order exists to avoid.
            manifest.statements.insert(statement, at: row)
            manifest.modified = previouslyModified
            return false
        }
        try? FileManager.default.removeItem(at: fileURL)
        return true
    }

    // MARK: - Writing into one

    /// Run `mutate` against a statement's `Document` — the one somebody already
    /// has open when there is one, else one opened and closed for the purpose.
    /// **The ONE statement open-and-mutate dance**, so that a second writer of
    /// statements cannot ship a subtly different copy of it.
    ///
    /// **The live `Document` FIRST, and never a second one on the same path.**
    /// A statement's `Document` is deliberately in no `DocumentStore` registry
    /// (spec §8, `StatementEditorHost`), so `document(forDocId:)` cannot find an
    /// open statement — and `.intent` is a pane of the Plan persona, the persona
    /// the canvas lives in, so the writer really can have this statement open in
    /// the right column while promoting a card in the centre, or rename a
    /// chapter in the binder beside it. Two `Document`s on one path each hold
    /// their own paragraph state and their own `PendingBuffer`; whichever writes
    /// last decides the sequence, so the paragraph this call just wrote is
    /// written back out of the statement by the pane's next burst.
    /// `ProjectStore.openStatementDocument(id:)` is the seam both sides go
    /// through, and the lookup-plus-mutate below does not suspend, so the pane
    /// cannot close its `Document` between them.
    ///
    /// **The open pane redraws off the shared `Document` with no push from
    /// here, and that is measured rather than assumed** (2026-08-01). It is not
    /// obvious: `StatementEditorHost.body` deliberately reads no text, so the
    /// expectation was that nothing would invalidate it — the first cut of this
    /// added an out-of-band-change event for the pane to service. Instrumented,
    /// SwiftUI's observation reaches the binding's own `get` inside
    /// `EditorSurface.updateNSView`, so writing `displayText` re-renders the host
    /// and the buffer swaps through the one sanctioned `applyExternalText` site.
    /// The event was deleted as machinery nothing needed;
    /// `test_promotingWhileTheIntentPaneIsOpenDoesNotOpenASecondDocument` is what
    /// holds the OUTCOME — the writer's next keystroke does not write the
    /// promotion back out — so if that ever stops being true it goes red rather
    /// than the loss being silent.
    ///
    /// `session` is the caller's, so the ops carry who wrote them, and
    /// `Document.load` stays the only construction path (hard invariant;
    /// `BootstrapWiringTests`).
    /// **"The end" means the end of the ESSAY, not the end of the file**
    /// (declared-world Task 6). Once the intent statement has a `## Rulings`
    /// section, appending to the whole text puts the arriving paragraph *below*
    /// the list — where `RulingsSection.parse` does not read it and the Intent
    /// pane's essay editor therefore cannot show it. The words are safe on disk
    /// and invisible in the one surface that owns them, which is its own kind of
    /// loss and the one this seam is closest to.
    ///
    /// Byte-identical for every statement without a rulings section
    /// (`StatementEssay.recomposed` is the identity there), and for visual
    /// language always — `carriesRulings` says intent alone has strata, so a
    /// `## Rulings` heading a writer typed in their visual language is ordinary
    /// prose and stays that way.
    ///
    /// (Merge 2026-08-09: origin's thin `appendToStatement` — a pre-rulings
    /// wrapper over `withStatementDocument` — is superseded by this one, which
    /// its callers get unchanged; without the essay split their append would
    /// land below `## Rulings`, invisible.)
    func appendToStatement(_ text: String, to statement: Statement,
                           session: String) async throws {
        let splits = StatementEssay.carriesRulings(statement.kind)
        try await mutateStatementText(of: statement, session: session) { existing in
            guard splits else { return Self.statementAppending(text, to: existing) }
            let essay = StatementEssay.half(of: existing)
            return StatementEssay.recomposed(
                essay: Self.statementAppending(text, to: essay), into: existing)
        }
    }

    /// Rewrite a statement's WHOLE text through `transform`, on the same
    /// `Document` and under the same gate `appendToStatement` uses.
    ///
    /// **Why both this and `appendToStatement` exist**, rather than one of them
    /// (declared-world Task 4). An append is a *paragraph* verb: it puts a blank
    /// line and then the arriving words at the end, which is the whole of what
    /// promotion and the picture ingest need and is worth keeping as its own
    /// named act — a call site that wants that shape should not have to spell a
    /// closure to get it, and a closure at each of those sites is three chances
    /// to disagree about the blank line. A **ruling**, by contrast, is a line
    /// *inside a section*: `RulingsSection.appending`/`removing` take the
    /// statement's whole markdown and hand back the whole markdown, so there is
    /// no suffix to append and nothing an append verb can express. So the append
    /// stays, expressed as one call of this, and there is exactly one copy of
    /// the discipline — the live-first lookup, the open gate, the re-ask inside
    /// it, and the awaited close — in `withStatementDocument` below, which this
    /// wraps.
    ///
    /// **`transform` may throw, and a throw writes nothing.** It is called with
    /// the text the write is about to be made from, so a caller whose act
    /// depends on what is currently there (revoking a ruling that must still be
    /// present) decides against the same string it edits, with no window between
    /// the check and the write for a peer's op or the writer's own keystroke to
    /// arrive in.
    func mutateStatementText(
        of statement: Statement, session: String,
        transform: (String) throws -> String
    ) async throws {
        try await withStatementDocument(statement, session: session) { document in
            document.setFullText(try transform(document.displayText))
        }
    }

    /// The ONE open/gate/transient dance for statement writes: the live
    /// `Document` first, the gate over the opening, the second ask inside it,
    /// and the awaited close. Origin's spelling (a `Document` closure, for
    /// callers like the rename path that act on the document rather than its
    /// text), upgraded in the 2026-08-09 merge to a THROWING closure carrying
    /// the second draft's discipline: **a throw writes nothing**, and on the
    /// transient arm the just-loaded `Document` is closed on the refusing path
    /// too — left open it would outlive the gate the `defer` releases, and the
    /// next opener would load a second one against it.
    func withStatementDocument(_ statement: Statement, session: String,
                               _ mutate: (Document) throws -> Void) async throws {
        if let live = openStatementDocument(id: statement.id) {
            try mutate(live)
            // Durable now rather than on the pane's own debounce: a write
            // through here is an act the writer has committed to — a promotion
            // they confirmed, a picture they dropped, a rename they typed — and
            // the surface says it landed.
            try? await live.flushBurstNow()
            return
        }
        // **The registry alone leaves a window and this closes it.** Nobody has
        // this statement open *yet* — but `Document.load` suspends, and a pane
        // arriving on this scope mid-load asks the same registry, gets the same
        // answer, and loads a second `Document` on the same path. The gate is
        // over the OPENING, so the pane simply queues behind us; see
        // `ProjectStore.lockStatementOpen(_:)`.
        await lockStatementOpen(statement.id)
        defer { unlockStatementOpen(statement.id) }
        // Asked AGAIN inside the gate: a pane can have bound while we queued,
        // and its `Document` is the one that will still be live in a moment.
        if let live = openStatementDocument(id: statement.id) {
            try mutate(live)
            try? await live.flushBurstNow()
            return
        }
        let document = try await Document.load(
            url: url.appendingPathComponent(statement.path),
            device: MacDeviceID.current,
            session: session,
            presenter: documentStore?.presenter)
        // Closed on the refusing path too: a `Document` left open on this path
        // outlives the gate released by the `defer` above, so the next opener
        // would load a second one against it.
        do {
            try mutate(document)
        } catch {
            await document.close()
            throw error
        }
        // Awaited, unlike `withAnnotationDocument`'s fire-and-forget close: that
        // path has already appended its ops itself, and this one's words are
        // still in the pending buffer until the close flushes it. Inside the
        // gate, so nothing else opens this path until the ops are on disk.
        await document.close()
    }

    /// A blank line between what is there and what is arriving, and nothing at
    /// all in front of the first thing to reach an empty statement.
    private static func statementAppending(_ text: String, to existing: String) -> String {
        existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? text
            : existing + "\n\n" + text
    }

    // MARK: - Path minting

    /// The slug a new document-scoped statement's filename is built from, or nil
    /// for a scope that needs none. Derived from the document's title **once, at
    /// creation** — identity is the manifest `id` (tripwire 22), so a later
    /// rename moves the title and leaves the path where it is.
    ///
    /// Throws for a scope that names anything other than a manuscript document
    /// in this project: an unknown id, or a group. A statement is about a
    /// document the writer writes in.
    private func documentSlug(for scope: Statement.Scope) throws -> String? {
        guard case .document(let docId) = scope else { return nil }
        guard let item = findItem(id: docId, in: manifest.structure),
              item.type == .document else {
            throw ProjectStoreError.structureMissing
        }
        return Slugifier.slug(from: item.title)
    }

    /// `candidate` if nothing holds it, else the same name with a `-2`, `-3`, …
    /// inserted before the extension.
    ///
    /// **Two things can hold a path, and both matter.** Another statement can
    /// (two documents may share a title, so their slugs collide) — and so can an
    /// **untracked file the project knows nothing about**. The manifest is the
    /// only authority on a statement's identity, so registering one at an
    /// occupied path would point `resolveDocId` at that file, bootstrap the
    /// statement from its bytes, and then own it: a file the writer put there
    /// eaten by a registry entry they never made. Steering around is
    /// non-destructive and recoverable; taking the path is neither.
    private func vacantStatementPath(basedOn candidate: String) -> String {
        let ns = candidate as NSString
        let ext = ns.pathExtension
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        let claimed = Set(manifest.statements.map(\.path))
        let root = url
        let free = Self.dedupedName(ns.deletingPathExtension) { stem in
            let relative = stem + suffix
            return claimed.contains(relative)
                || FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(relative).path)
        }
        return free + suffix
    }
}

/// A **weak** handle to the `Document` a statement pane has open.
///
/// Weak because the PANE owns it: `StatementEditorHost` holds the strong
/// reference for as long as it is showing that scope, closes it on the way out,
/// and an entry outliving that would hand a writer's promotion a husk to write
/// into — `Document.setFullText` no-ops on a closed doc, so the words would go
/// nowhere and nothing would be red.
@MainActor
final class OpenStatementDocument {
    weak var document: Document?
    init(_ document: Document) { self.document = document }
}
