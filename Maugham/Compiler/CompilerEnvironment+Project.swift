import Foundation
import MaughamCore
import os

// Subsystem from the running bundle id so dev/stable logs separate without
// hardcoding "com.maugham" (tripwire 13 spirit); mirrors `documentLog`.
private let compilerLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.Maugham",
    category: "Compiler")

/// **The production wiring: one project window's stores, as the closures the
/// orchestrator runs on.**
///
/// Separate from `CompilerOrchestrator.swift` so that file names no store. The
/// `Environment` seam exists to keep the run logic testable without a project
/// on disk, and a factory sitting beside it that reaches for `ProjectStore`
/// would quietly re-couple the two.
///
/// **Every capture is weak.** `ProjectWindow.onDisappear` calls `detach()`,
/// which drops these closures — but SwiftUI never dismantles a closed window's
/// view graph, and an orchestrator that outlived one teardown path while
/// holding a strong `ProjectStore` would keep the whole project in memory with
/// nothing on screen. The weak captures make that impossible rather than
/// merely unlikely; `detach()` is still what stops the *session*, which no
/// capture policy can do.
extension CompilerOrchestrator.Environment {

    /// - Parameters:
    ///   - declaredWorld: the per-device cache of Claude's readings. Held
    ///     weakly like every other store here, and consulted before anything is
    ///     derived — the whole point of the lazy trigger.
    ///   - bible: the per-device ledger of facts the manuscript has
    ///     established. Read before a run (sliced by subject) and written after
    ///     one.
    ///   - makeDeriver: how a derivation is spawned, given the model to spawn
    ///     it on. `nil` — every production caller — means the real one-shot
    ///     `claude -p`. A test that let that through would spawn a real,
    ///     billing process, so the seam exists for the suite that proves a
    ///     derived reading is CACHED
    ///     (`CompilerRunCommandTests.test_productionCachesWhatItDerives`) and
    ///     for nothing else.
    @MainActor
    static func production(
        store: ProjectStore,
        documentStore: DocumentStore,
        projectURL: URL,
        declaredWorld: DeclaredWorldStore,
        bible: BibleStore,
        preferences: UserPreferences,
        model: String = CompilerOrchestrator.defaultModel,
        makeDeriver: (@MainActor (String) -> WorldDeriver)? = nil,
        onRunAcknowledged: @escaping @MainActor (CompilerOrchestrator.Acknowledgment) -> Void
    ) -> CompilerOrchestrator.Environment {
        // Built here rather than as a default argument, which cannot see
        // `preferences`. One deriver per derivation, deliberately: the model is
        // a spawn-time argument (as it is for the session), and a derivation
        // holds nothing between calls worth keeping warm — its one cached
        // value, the CLI's path, is re-found from well-known locations without
        // a subprocess in the ordinary case.
        let deriverFactory: @MainActor (String) -> WorldDeriver = makeDeriver ?? { model in
            ClaudeWorldDeriver(
                model: model, cliOverride: nil,
                // Read at every spawn, never captured as a value — the toggle
                // governs derivation exactly as it governs the run (ADR 0028's
                // one toggle), and `nil` preferences means refuse.
                isEnabled: { [weak preferences] in preferences?.mcpEnabled ?? false })
        }
        return CompilerOrchestrator.Environment(
            projectId: ProjectIdentifier.id(for: projectURL),
            // The Diagnostics pane's gear menu (Task 8) — read once here at
            // `configure()` and kept current afterward by
            // `CompilerOrchestrator.updateModel(_:)`, which the gear menu calls
            // directly rather than re-running `production`.
            model: model,
            prepareForRun: { [weak documentStore] docId in
                // **Close the writer's burst before anything reads the log.**
                // ⌘S does the same thing for the same reason
                // (`ProjectWindow`'s checkpoint path): a keystroke that acts on
                // the manuscript has to act on the manuscript as it is, and
                // until the burst closes the last sentences exist only in the
                // `PendingBuffer`. A document that is not open has no burst.
                guard let document = documentStore?.document(forDocId: docId) else { return }
                do {
                    try await document.flushBurstNow()
                } catch {
                    // **Proceed.** Unlike `Document.close()`, which is the last
                    // chance those words have and therefore re-persists them
                    // itself, this failure costs nothing: the pending buffer is
                    // still intact (`flushBurstNow` clears it only after a
                    // successful append), so the next burst or the close still
                    // carries the prose. All this run loses is the newest
                    // paragraphs, and a delta one burst stale is worth more to
                    // the writer than a refused ⌘R. Logged rather than counted
                    // — `closeBurstFlushFailures` is close's own counter and
                    // means something narrower than "a flush failed".
                    compilerLog.error(
                        "burst flush before a compiler run failed for doc \(docId, privacy: .public); running on the un-flushed snapshot: \(error.localizedDescription, privacy: .public)")
                }
            },
            reading: { [weak documentStore] docId in
                // The OPEN document, by id — the live paragraphs, which lead
                // the derived `.md` by up to one debounce window (ADR 0018/0019,
                // tripwire 20). A doc that is not open has no unsaved delta to
                // check and no `Document` to read.
                guard let document = documentStore?.document(forDocId: docId) else {
                    return nil
                }
                return CompilerOrchestrator.DocumentReading(
                    ops: document.opLogSnapshot,
                    paragraphs: document.paragraphs,
                    sequence: document.sequence)
            },
            liveParagraphText: { [weak documentStore] docId, paragraphId in
                documentStore?.document(forDocId: docId)?.paragraph(id: paragraphId)
            },
            intent: { [weak store] docId in
                // `ProjectStore.effectiveIntent(forDocId:)` — the piece-first,
                // project-fallback resolution, shared with the intent strip
                // (M2 §6.1) rather than spelled twice. A strip showing the
                // chapter's intent while the run was briefed on the book's is
                // a lie about what Claude was told.
                guard let store,
                      let resolved = store.effectiveIntent(forDocId: docId) else {
                    // Absence is valid and mints nothing (M1A's rule). The
                    // prompt simply carries nothing declared.
                    return nil
                }
                // The statement WHOLE: the briefing takes its essay half, and
                // the derivation reads all of it — the rulings are half of what
                // there is to derive, and a reading made from the essay alone
                // would drop every decision the writer has ruled.
                // RULING-54: `statementText` throws on an unreadable file.
                // For the briefing that maps to the absence arm above — the
                // run carries nothing declared — and the Intent pane's editor
                // owns surfacing the refusal. RESIDUAL, recorded: a statement
                // the writer DID declare that has become unreadable briefs as
                // undeclared without a run-side signal; if that silence ever
                // matters in practice, this closure wants a throwing
                // signature so the run can refuse instead (register queue).
                guard let text = try? store.statementText(of: resolved) else {
                    return nil
                }
                return CompilerOrchestrator.IntentBriefing(
                    statementText: text,
                    // `DeclaredWorldStore`'s own spelling, asked for rather
                    // than rebuilt (that type's own doc: two spellings are two
                    // caches, and one of them is never hit).
                    scopeKey: DeclaredWorldStore.scopeKey(for: resolved.scope))
            },
            activePass: { [weak store, weak documentStore] docId in
                // **`validatedActivePass` — the one spelling of the read rule**
                // (`ActivePassMemory`'s own doc), off `uiState` rather than any
                // window's `@State` mirror, for the margin stamp's reason
                // (`ProjectWindow`, the `activeReviewPassId` closure): the
                // mirror is per WINDOW, and a second window on the same project
                // recording a pass would leave this one filing rounds into a
                // lane the writer left. A run record is a durable write, so it
                // reads the shared value.
                //
                // Keyed `forPiece:` with a document id, as both existing
                // readers are: the piece IS the document here.
                guard let store, let documentStore else { return nil }
                let passes = store.manifest.effectiveReviewPasses
                guard let id = documentStore.uiState.activePassMemory.validatedActivePass(
                        forPiece: docId, in: passes),
                      let pass = passes.first(where: { $0.id == id })
                else { return nil }
                // **`effectiveEditorName`/`effectiveBrief`, never the raw
                // fields** (M4 P1 Task 1's rule): a customized manifest can
                // store a preset-id pass that predates both, and reading
                // `pass.editorName` here would sign a Copyedit round's notes
                // with nothing at all.
                return CompilerOrchestrator.ActivePass(
                    id: pass.id, name: pass.name,
                    editorName: pass.effectiveEditorName,
                    brief: pass.effectiveBrief)
            },
            cachedWorld: { [weak declaredWorld] briefing in
                // The hash gate is the whole cache: a reading is served only
                // against the exact text it was made from, so the writer
                // editing their statement retires it without anyone
                // remembering to invalidate. `sourceHash` is asked of
                // `DerivedWorld` — the one place it is computed.
                declaredWorld?.cached(
                    forScopeKey: briefing.scopeKey,
                    sourceHash: DerivedWorld.sourceHash(of: briefing.statementText))
            },
            deriveWorld: { [weak declaredWorld] briefing, model in
                guard let world = await deriverFactory(model)
                    .derive(statementText: briefing.statementText) else {
                    // A failure caches nothing. There is no such thing as a
                    // cached "could not read this" — the next run retries, and
                    // by then the CLI may be installed or the toggle back on.
                    return nil
                }
                declaredWorld?.store(world, forScopeKey: briefing.scopeKey)
                return world
            },
            bibleSlice: { [weak bible] deltaProse in
                // **The slice rule lives on the store** (`BibleStore
                // .slice(matching:)`), not here, because the translator's
                // briefing now slices the same ledger — and two copies of the
                // rule is how the two runs would come to disagree about which
                // facts a run is entitled to. What stays here is the
                // compiler's own answer to WHAT prose to slice against: this
                // run's delta.
                bible?.slice(matching: deltaProse) ?? []
            },
            annotationContext: { [weak documentStore] docId in
                // **⌘R requires an open document**, so this resolves in every
                // real run; a document that is not open has nothing to read
                // and briefs nothing rather than reopening it behind the
                // writer (`mintAnnotations`' rule, one direction earlier).
                guard let document = documentStore?.document(forDocId: docId) else {
                    return []
                }
                // **Unfiltered** — `statuses: nil` rather than the `[.open]`
                // default. Half of what this briefing is for is the notes the
                // writer has SETTLED, and every one of those is invisible to
                // the default filter (M5-AN-002's documented footgun, and the
                // reason `stetAnnotation`'s own drift guard spells the same
                // thing out).
                //
                // Every pass's notes, not this run's lane: the writer's answer
                // is a fact about the note, and a finding they rejected in the
                // Line pass is one Gould must not raise either. The lane
                // decides what a round is FOR; it does not decide what has
                // already been said about the piece.
                //
                // **The projection and the order are `gather`'s**, not this
                // closure's — including the settled half's `resolvedAt` sort,
                // which is what makes the briefing's cap spend its words on
                // the notes the writer settled most recently rather than on
                // the ones the model raised most recently. Written there so it
                // is testable without a project on disk.
                return CompilerAnnotationDisposition.gather(
                    from: document.annotations(filter: AnnotationFilter(statuses: nil)))
            },
            mintAnnotations: { [weak documentStore] notes, context in
                // **⌘R requires an open document** (`runRequested`'s
                // `reading(docId) != nil` guard), so this resolves in every
                // real run. A document closed between the send and the answer
                // mints nothing rather than reopening it behind the writer:
                // the words are still on disk, and the next run over the same
                // prose raises the same findings.
                guard let document = documentStore?.document(forDocId: context.docId) else {
                    compilerLog.error(
                        "the compiler's notes had nowhere to land: doc \(context.docId, privacy: .public) is no longer open")
                    return 0
                }
                // **The dedupe backstop, and it is THE guard on the fresh-eyes
                // path.** A warm round is briefed on what the last one raised
                // and can be asked to leave it alone; ⌘⇧R is briefed on
                // nothing by design, so it re-raises everything it still finds
                // true — and without this, every cold reread would mint the
                // writer a second copy of every question they have not yet
                // answered.
                //
                // Only OPEN notes block. A resolved one is a finding the
                // writer dealt with, and prose that still reads the same way
                // afterwards is news again rather than an echo.
                var taken = Set(
                    document.annotations(filter: AnnotationFilter(statuses: [.open]))
                        .compactMap { $0.isCompilerAuthored ? $0.compilerFingerprint : nil })
                var minted = 0
                for note in notes {
                    if let fingerprint = note.fingerprint, taken.contains(fingerprint) {
                        continue
                    }
                    do {
                        _ = try await document.addAnnotation(
                            kind: note.kind,
                            paragraphId: note.paragraphId,
                            body: note.body,
                            // **The exact label IS the filter bucket**
                            // (`AnnotationAuthorFilter.distinctLabels`), which
                            // is the feature: a Copyedit round's notes gather
                            // under "Gould" and the writer can read one
                            // editor at a time. `.claude` keeps `isClaude`
                            // true, so every existing Claude affordance still
                            // applies to them.
                            author: AnnotationAuthor(
                                sourceKind: .claude, displayName: context.editorName),
                            reviewPassId: context.passId,
                            compilerRunId: context.runId,
                            compilerRound: context.round,
                            // Absent rather than `false` on a warm round, on
                            // `CompilerRun.freshEyes`'s own rule: every reader
                            // asks `== true`, so an ordinary run's op stays
                            // byte-for-byte what it was.
                            compilerFreshEyes: context.freshEyes ? true : nil,
                            compilerFingerprint: note.fingerprint,
                            // One round is ONE event to every surface counting
                            // this project's notes, and each of them walks the
                            // whole project to answer it. Paid back once below.
                            announcing: false)
                        minted += 1
                        // A model that raises the same finding twice in one
                        // turn mints it once. The ingest dedupes refs, not
                        // findings, and the writer would have no way to tell
                        // the copies apart.
                        if let fingerprint = note.fingerprint { taken.insert(fingerprint) }
                    } catch {
                        // **The mint never fails the run.** The commonest
                        // cause is the writer deleting the paragraph between
                        // the parse and this append, which
                        // `addAnnotation` refuses outright — one note lost, the
                        // rest written, and a check that still says it
                        // finished.
                        compilerLog.error(
                            "a compiler note could not be minted on doc \(context.docId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
                // Owed exactly once, and only if something really landed —
                // `sweepOrphanedAnnotations`' rule, for its reason.
                if minted > 0 { document.announceAnnotationsChanged() }
                return minted
            },
            recordFacts: { [weak bible] candidates in
                // `record` dedupes on `(subject, fact)` itself, so a second run
                // over the same delta lands nothing new.
                bible?.record(candidates)
            },
            pinnedListing: { [weak store] docId in
                guard let store else { return [] }
                // `PinnedReferenceResolver`, which the References pane and the
                // assistant column also call (M2 Plan 2 Task 5). A run must not
                // be briefed on a different set from the one the writer is
                // looking at, and the assembly is where that could diverge —
                // the attached-or-sidecar scene discriminator, the manifest
                // index, and `linkedResearchIds` rather than
                // `StructureItem.links`. See that file for what each costs.
                return PinnedReferenceResolver.pins(
                    forDocId: docId, store: store, projectRoot: projectURL
                ).map(Self.pinnedListingLine)
            },
            paletteListing: { [weak store] in
                guard let store else { return [] }
                // `PaletteLookup.paletteCards(in:)` reads the manifest only —
                // no file parse — which is what makes this cheap enough to
                // resolve on every run rather than `ProjectStore.loadPalette
                // Cards()` (`list_palette_cards`'s own path), which parses
                // each card's markdown file for fields this listing does not
                // need (kind, swatches, notes).
                return PaletteLookup.paletteCards(in: store.manifest.research)
                    .map { "\($0.title) (\($0.id))" }
            },
            writeMCPConfig: {
                try ClaudeCLISession.writeMCPConfig(
                    bridgeBinary: ClaudeCLISession.bridgeBinary,
                    socketPath: BuildVariant.current.mcpSocketPath,
                    to: ClaudeCLISession.sessionConfigDirectory)
            },
            makeRunner: { configURL, model in
                ClaudeCLISession(
                    model: model,
                    mcpConfigPath: configURL,
                    cliOverride: nil,
                    // Read at every spawn, never captured as a value: a session
                    // already warm when the writer turns Claude off must not
                    // answer one more run. `nil` preferences means refuse,
                    // which is the safe direction.
                    isEnabled: { [weak preferences] in preferences?.mcpEnabled ?? false })
            },
            onRunAcknowledged: onRunAcknowledged)
    }

    // MARK: - Pinned-reference formatting

    /// One pinned reference as the run's context listing shows it — title,
    /// id, and the tool that fetches its full contents.
    ///
    /// `CompilerPrompt`'s section header already says "fetch full contents
    /// with read_document" for the whole pinned section, which predates the
    /// palette/photo/scrap kinds landing in the same union (Task 2). A kind
    /// whose real tool differs from the header's blanket claim says so on its
    /// own line rather than leave the header's claim uncorrected — a
    /// `.photo` pin has no read tool at all yet (Task 2's noted gap: Claude
    /// cannot see an owned picture's pixels), and a `.scrap`'s words are
    /// already inside `list_canvas`'s own response, not `read_document`'s.
    private static func pinnedListingLine(_ pin: PinnedReference) -> String {
        let base = "\(pin.title) (\(pin.id))"
        switch pin.kind {
        case .research: return "\(base) — read_document"
        case .palette: return "\(base) — read_palette_card"
        case .scrap: return "\(base) — list_canvas"
        case .photo: return "\(base) — no read tool yet, title only"
        }
    }

    // The session's bridge config — the binary and the directory — lives on
    // `ClaudeCLISession` itself now that the translator spawns sessions too
    // (`ClaudeCLISession.bridgeBinary` / `.sessionConfigDirectory`).
}
