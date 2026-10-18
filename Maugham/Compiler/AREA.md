# Compiler — area guide

The `claude -p` runs Maugham spawns and everything they read and answer. ⌘R (⌘⇧R for a cold read) sends the piece to a warm session: in Author a **check** over what changed since the last check, in Review a **round** over the whole piece by the pass's named editor (`RunKind`, ADR 0031). Each finding lands where its nature says (ADR 0029): a conformance strain stays a ¶-anchored diagnostic in the Diagnostics pane; a continuity question, reader's report or letter question mints as an annotation; a fact lands in the bible. The same rails carry the translator, the designer and the seven-leg translation pipeline's cold sessions. The one rule from CLAUDE.md: **the compiler reads and never writes; Maugham writes at ingest. A new `claude` service joins `AgentRoster`, the one teardown.** The area carries tripwires 2, 3, 6, 11, 17, 20, 21, 24 and 34. The why behind every rule below, and the history of each, is in `docs/history/compiler.md`.

## Map

Every file in `Maugham/Compiler/` appears once.

### Sessions and their lifetime
- `AgentRoster.swift` — the project session's `claude` services (compiler, translator, designer, `ColdCall`, the pipeline, the translation-run log) and the one teardown order: `shutdownAll()` and `detachAll()`, pipeline first; `updateModel(_:)` reaches every spawner but `ColdCall`.
- `ClaudeCLISession.swift` — the warm subprocess: `arguments`, `Confinement` (`.bridged`/`.sealed`), `writeMCPConfig`, `generation`, the idle, silence and run budgets, the death join.
- `CompilerRunner.swift` — the protocol every orchestrator holds: `send(message:systemPreamble:) -> CompilerRunEvent`, `sessionEpoch`, every way a run fails (`CompilerRunFailure`, `.Stall`).
- `CompilerAllowlist.swift` — the enumerated read-only MCP tools, passed as `--allowedTools`.
- `ColdCall.swift` — the one runner for sealed sessions: one call, one fresh process, one report, process ended.
- `RunTiming.swift` — `RunTiming` (timings, tokens, cost, model, effort; on `CompilerRun.timing`) and `RunProgress` (the live thinking-token estimate).

### The compiler's run
- `CompilerOrchestrator.swift` — **the run**: delta → prompt → session → parse → mint → store. `runRequested`, `beginRun`, `finish`, `record(...)`, `resolveWorld`, `shutdown()`/`detach()`/`retireSession()`. Closure-`Environment`, no store named (tripwires 2, 3, 6).
- `CompilerEnvironment+Project.swift` — the production wiring: one window's stores as the orchestrator's closures, every capture weak. Holds the mint loop (`mintAnnotations`) and `pinnedListing`.
- `RunKind.swift` — `.check`/`.round`, minted from the persona at the keystroke (tripwire 34).
- `DeltaBuilder.swift` — what changed since the check's marker, in `sequence` order; a round is built `since: nil`.
- `CompilerPrompt.swift` — the message: `checkMessage`/`roundMessage` over `runMessageV2`, `briefingHashInput`, the frame sections, `sectionSchema(judgesIntentDrift:)`, the preamble.
- `ProcessSignals.swift` — the writer's process, pure over `(ops, sequence, now)`: sessions, frontier, churn, `daysAway`, `noteworthy`.
- `DraftStage.swift` — `.drafting`/`.revising` derived from `DeltaCounts` plus signals; `LetterDosage` (`.short`, `.full`, `.reader`).
- `ScenePosition.swift` — what form the letter's scene table takes, derived app-side.
- `PinnedReferences.swift` — the pure projection of what a document is pinned to, grouped into a `PinnedShelf`.
- `PinnedReferenceResolver.swift` — gathers the five inputs `PinnedReferences.pinned` takes from a live project.

### The report
- `DiagnosticIngest.swift` — the sectioned answer → notes, clause statuses, facts, the drift verdict and the letter; `parseSection`/`parseAll`, `SectionedOutcome`, `parseLetter`, `readerKinds`.
- `Diagnostic.swift` — `Diagnostic` and `CompilerRun`, the wire and sidecar shapes.
- `DiagnosticsStore.swift` — the per-device, per-document sidecar: the two standing slots, the rings, staleness, `preview`/`replace`/`dismiss`, the ask file, the cold-start refusal file.
- `CompilerNote.swift` — the value crossing from parse to mint; `CompilerMintContext` (lane, round, editor name, cold or warm), minted once at the keystroke.
- `RoundHistory.swift` — `RoundFingerprint` (the one round-over-round join key), `RoundRecord`, `SinceLastRound` (pure, off the writer's queue).
- `RoundNarrative.swift` — the report's own English: the since-line, the Fresh Eyes header, `openInOtherLanes(_:)`, `stallCopy`.
- `DriftDetector.swift` — `DriftFinding`: the same clause straining over `consecutiveRunsThreshold` runs.
- `IntentDrift.swift` — `mayTrailDraft`, the pure decision behind the intent strip's quiet mark.
- `DiagnosticPromotion.swift` — what a kept strain says once it is an op-logged task.
- `Letter.swift` — the letter's shape (`Working`, `Habit`, `Question`, `Scene`, `retired`); `Habit.ledgerHeading`; `isEmpty`.
- `LetterMarkdown.swift` — the letter as prose the writer keeps; a ref is the paragraph's words in italics, never a join key.
- `ReportJSON.swift` — helpers every one-object report parser shares: `lastObject(in:shapedBy:)`, `parseList`, `nonEmptyString`, `enumValue`.

### What the writer declared
- `RulingPerformer.swift` — rule / revoke / edit / restore: the only writes into a statement's `## Rulings` stratum.
- `StatementEssay.swift` — the byte-exact split between essay and strata (`half(of:)`, `recomposed`, `carriesRulings`).
- `StatementProposalGate.swift` — Adopt: the one place a staged proposal's words reach a statement; `StatementProposalCopy`.
- `LessonsLedger.swift` — the lessons ledger's grammar over a ruling's text: lesson, `Choice: `, retired; `matches`.
- `DeclaredWorld.swift` — `DerivedClause`/`DerivedRule`/`DerivedWorld` and `DeclaredWorldStore`, the per-device cache keyed on the source text's hash.
- `DeclaredWorldDeriver.swift` — `WorldDeriver`, `ClaudeWorldDeriver`: the one-shot, no-MCP derivation, with its pipe discipline and deadline.
- `BibleStore.swift` — `BibleFact` and `BibleStore`, the per-device project ledger, graduated keys, `slice(matching:)`.

### The translator and the designer
- `TranslatorOrchestrator.swift` — the second orchestrator: `runTranslation`, `runFix`/`briefFix`, warm per `(docId, language)`.
- `TranslatorBriefing.swift` — the pure translator briefing (`compose(inputs:)`, `FixNote`).
- `TranslatorReport.swift` — one JSON object (`entries`, `queries`), all-or-nothing; `schemaDescription`.
- `TranslatorEnvironment+Project.swift` — production wiring: `briefRound`/`BriefedRound`, `fixBriefing`, `ingest`, `midRunEdits`.
- `DesignerOrchestrator.swift` — the third orchestrator: `runDesign`, `requestChanges`, warm per project, `hasOpenProposalRound`.
- `DesignerBriefing.swift` — the pure designer briefing (a config summary, never the JSON).
- `DesignerReport.swift` — a spec plus files; refuses config.json and path escapes at parse.
- `DesignerEnvironment+Project.swift` — production wiring: `briefRound`, `stage` (`StageOutcome`).

### The translation pipeline and spot-checks
- `TranslationPipeline.swift` — the seven-leg state machine over closures; owns no session.
- `TranslationPipelineEnvironment+Project.swift` — production wiring: cold-leg gathers, `mintDeclined`, `declinedBody`.
- `TranslationRound.swift` — the pipeline's whole product, a plain `Codable` value (`Leg`, `NoteRecord`, `DepartureRecord`).
- `ReaderBriefing.swift` / `ReaderReport.swift` — the blind reader: no source field; `gapMarker(_:)`.
- `CollatorBriefing.swift` / `CollatorReport.swift` — pairs in `sequence` order; every departure carries a gloss.
- `GlossBriefing.swift` / `GlossReport.swift` — the gloss spot-check; no source field.
- `SpotCheck.swift` — Gloss and Ask the Collator: `gloss`, `askTheCollator`, `neighbours(of:in:)`, `narrow(_:to:)`.
- `BriefingDoctrine.swift` — directives and the glossary read off statement markdown (`Directives`, `GlossaryTable`).
- `TranslationPreflight.swift` — the desk's "7 legs · ~N words briefed" figure (`budgets`, `budget`, `wordCount`).

### `Maugham/Models/` files routed here
- `Maugham/Models/AuthorReader.swift` — who reads a CHECK: the coach, a first reader, or nobody (tripwire 34).
- `Maugham/Models/RoundEditor.swift` — which pass runs a ROUND, or a refusal (tripwire 34).
- `Maugham/Models/ActivePassMemory.swift` — which lane a piece is parked in; the round loop's memory only.
- `Maugham/Models/CompilerModelChoice.swift` — the depth menu; `exhaustive` (`fable`) is last in the enum and the menu.
- `Maugham/Models/RunMenuTitles.swift` — the per-persona run menu titles.

### Outside this folder
- Views (`Maugham/Views/AREA.md`): `CompilerRunModifier.swift` (run keys, two teardown arms), `DiagnosticsPane.swift`, `Maugham/Views/Review/ReviewRoundCockpit.swift`, `LetterKeep.swift`, `LetterSection.swift`, `LessonLedgerVerbs.swift` (with `LessonOffer`), `FirstReaderRuling.swift`, `BibleStratum.swift`, `RulingsStratum.swift`; the desk's `Maugham/Views/Publish/DepartmentPaneHost.swift`, `Maugham/Views/Publish/DepartmentRunState.swift` (`DepartmentRunSession`, `TranslationRunLog`) and `Maugham/Views/Publish/DesignGateVerbs.swift`.
- Publish: `Maugham/Publish/ElementCensus.swift`, `Maugham/Publish/SamplePageSelection.swift`, `Maugham/Publish/SampleCompiler.swift`, `Maugham/Publish/ProposalPromotion.swift` (the designer's other four files; documented here).
- Stores: `Maugham/Stores/ProjectSession.swift` (owns the roster; `attachWindow` configures every service), `Maugham/Stores/ProjectSessionRegistry.swift`, `Maugham/Stores/DesignProposalStore.swift`, `Maugham/Stores/TranslationRoundStore.swift`.
- MCP: `Maugham/MCP/Tools/TranslationWritePipeline.swift`, the translator's one word door.

## Rules

### The two sentences, and the membrane
- **The keystroke is the only trigger.** A run on every pause is the background linter the constitution excludes; every timer here ends a session, never starts one. The cold-start offer's Read and the cockpit's buttons call `runRequested` exactly as ⌘R does.
- **The compiler reads and never writes.** The spawned model reads through a read-only allowlist and calls nothing that mutates; Maugham, after the turn, materialises the parsed report into the writer's layers (ADR 0029): annotations (`Environment.mintAnnotations`), bible entries, a kept strain's task. The compiler is an MCP client and adds no tool.
- **The membrane: Claude has no route into a statement**, or it could move the standard it is judged against. The one route is `RulingPerformer`, whose input is always a sentence the writer typed (`RulingPerformerTests.test_nothingDerivedCanWriteItself`).
- **The allowlist census is the membrane in test form**: every entry resolves to a catalog tool, no entry writes, and no statement-writing tool exists in the allowlist or the catalog, each check with a planted offender (`CompilerAllowlistTests`, `CompilerAllowlistTests.statementWriters`). A read may join the allowlist; `test_theCompilerCanReachItsDeclaredContext` pins the minimum set (`read_craft_intent`, `read_visual_language`, `read_edition_brief`).
- **Confinement is TWO flags; the census guards only the stronger half** (ADR 0028 §2). `--allowedTools` removes nothing: built-in Read/Glob/Grep never prompt inside the working directory, so the list alone leaves the model free to read any file. `--tools ""` empties the built-in set. Keep both (`ClaudeCLISessionTests.test_spawnArgumentsMatchTheSpike`, which parses argv with `components` because the value is the empty string).
- **The session never stands in the writer's project**: `currentDirectoryURL` is the session's own config directory.
- **The session is the reader's own, not the writer's.** The preamble rides `--system-prompt`, never `--append-system-prompt` (`TripwireGrepTests.test_noProductionSpawnAppendsToTheCodingAgentPrompt`).
- **`--setting-sources ""` keeps the writer's hooks, plugins, CLAUDE.md and effort out** (`TripwireGrepTests.test_everyProductionSpawnIgnoresTheWritersSettingsFiles`), so `--effort` is explicit (`defaultEffort`). Never `--bare` (it never reads OAuth). `DeclaredWorldDeriver.arguments` passes the same three flags.
- **`Confinement` is an enum on the session, not a setting**: `.bridged(mcpConfigPath:)` (compiler, translator, designer) adds `--mcp-config` and `--allowedTools`; `.sealed` (a cold call) adds neither; both pass `--tools ""` and `--strict-mcp-config` (`ClaudeCLISessionTests.test_aSealedSessionSpawnsWithNoBridgeAndNoAllowlist`).
- **`.sealed` is spelled in production only in `ColdCall.swift` and the session type** (`TripwireGrepTests.test_theOnlySealedSpawnerIsColdCall`), and `ColdCall.swift` never names `writeMCPConfig`, `.bridged(` or `CompilerAllowlist` (`TripwireGrepTests.test_coldCallNeverBridges`).
- **This area holds no view state**: the panes and the run keys live in `Maugham/Views/`.

### Tripwires this area carries
- **The arrival: nothing here holds an editor binding or a `Document` across a turn** (tripwires 3, 6). A run takes a `DocumentReading` value at the keystroke and re-reads paragraph text at ingest through a closure: `EditorIntegrationHarnessTests`.
- **Generations, not booleans** (tripwire 2's shape in a subprocess). Every teardown bumps `ClaudeCLISession.generation`, and a callback carries the generation it was installed with; otherwise a dead process's EOF resolves the new run. Orchestrators carry `runGeneration` the same way. Prose only.
- **No migration** (tripwire 11): legacy sidecar keys are read and never written again. Prose only.
- **Sidecars are per `(document, device)`; the slug lives only in filenames** (tripwires 17, 24). `DeviceSlug.raw` is interpolated only in `DiagnosticsStore.sidecarURL`, `refusedColdStartURL`, `asksURL`, `DeclaredWorldStore.sidecarURL` and `BibleStore.sidecarURL`, and never serialised into content. Enforced by the compiler (builders take `DeviceSlug`); per-device sidecars otherwise prose only.
- **Derive, never read the `.md`** (tripwire 20). The delta comes from ops and live paragraphs; the intent through `ProjectStore.statementText(of:)`. Every raw read here carries `// adr-0018-ok:` naming why it is not manuscript: `TripwireGrepTests.test_noManuscriptFileReadsOutsideReconciler`.
- **Events go through `MaughamEvent`, scoped** (tripwire 21): the pane's Open Intent posts a scoped detail-segment event: `TripwireGrepTests.test_noRawMaughamPostsOrSubscriptionsOutsideWrapper`.
- **No run resolves its reader from the other loop's memory** (tripwire 34). `AuthorReader.swift` never reads `activePassMemory`; the wiring's `roundEditor` closure reads it exactly once (asserted structurally): `TripwireGrepTests.test_theCheckReaderNeverReadsTheBoardsMemory`.
- **`RoundEditor` never reaches for the coach's seat or the first reader** (tripwire 34): no `effectiveCoach` or `firstReaderName` in `RoundEditor.swift` or the wiring, and the `roundEditor` closure does not name `authorReader` either: `TripwireGrepTests.test_theRoundEditorNeverReachesForTheCoachsSeat`, controls in `test_theTwoReaderCensusesFireOnPlantedOffenders`.

### Two loops, two readers
- **`RunKind.of(persona:)` is called in exactly one production file**, `CompilerRunModifier.swift`; every other caller of `runRequested` belongs to one loop and says so literally (`TripwireGrepTests.test_theRunKindIsMintedFromThePersonaInOneFile`).
- **Two closures, two answer types**: `Environment.authorReader(docId)` → `AuthorReader`, `Environment.roundEditor(docId)` → `ActivePass?`, so asking the other loop's question does not type-check. Never collapse them into one closure taking the kind.
- **A check's reader is per project**: `ProjectManifest.authorReader(choice:statementText:)` takes the roster choice (`UIState.authorReaderChoice`) while its subject exists, else the coach while her seat is held, else a first reader, else nobody. *A reader is not a lane.*
- **The first reader's description is read from her statement at the keystroke**, cached nowhere.
- **A check files in no lane**: `beginRun` stamps `passId` only for a round, so a check mints no round number and is briefed on no prior round. Nobody (`nil`) signs "Claude".
- **`CompilerOrchestrator.passlessEditorName` has one production use**, `AuthorReader`'s nobody arm (`TripwireGrepTests.test_thePasslessEditorNameHasExactlyOneProductionUse`).
- **A round's editor is `ProjectManifest.roundEditor(forPiece:memory:)`**, validated by `ActivePassMemory.validatedActivePass` against `effectiveReviewPasses`; never the coach (a stored `workshop` id resolves to nothing).
- **A round with no editor refuses, never falls back**: a `nil` or retired pass flashes `Acknowledgment.noEditor` and starts nothing (no session, marker, record; `runState` stays `.idle`). `beginRun` re-asks after its awaits and refuses the same way.
- **A round is the piece-writer's**: below `noEditor`, `Environment.mayRunRound(docId)` asks `DocumentStore.settledPosture(forDocId:).allows(.runRound)`; `false` flashes `Acknowledgment.notYourPiece` and starts nothing. The press holds the in-flight gate while it asks. A check is never asked.
- **Round verbs are not drawn where the posture refuses**: Run/Fresh Eyes, the chip's Run round and every pass-state ruling ask `PassLadder.offersRulings(under:)`. The chips always draw; `setPassState` stays unguarded at storage (roles guard words, not the binder).
- **Readers resolve through `ReviewPass.effectiveBrief`/`.effectiveEditorName`, never the raw fields** (a preset-id pass may predate both); grep `effectiveEditorName` for them. A custom pass with no brief: attend at the altitude its name suggests.
- **A check's role frame is `CompilerPrompt.readerSection`, a round's `passSection`.** `checkMessage` has no `pass:` parameter. `ActivePass.isCoach` stays gone (`TripwireGrepTests.test_isCoachIsGone`); a coach's check is briefed byte for byte (`CompilerPromptTests.test_aCoachCheckIsBriefedByteForByteAsThePassRouteBriefedHer`).
- **The first reader is dosed and briefed as herself**: `reader.isFirstReader ? .reader : (stage?.dosage(freshEyes:) ?? .full)`, outranking stage and Fresh Eyes. She gets `signals: nil`, `lessons: nil`, `stage: nil`; her stage is still stamped on `Letter.stage`, never told to her.
- **The first reader judges nothing about intent**: `sectionSchema(judgesIntentDrift:)` omits the drift line, stabiliser and paragraph for her, and `LetterDosage.judgesIntentDrift` drops a volunteered verdict. Conformance, continuity and facts are asked under every reader.
- **Her statement is split in the section**: the essay is her description, `## Rulings` is *Standing instructions from the writer:*, then `firstReaderInstruction`. Only rulings reads as `undescribedFirstReader`.
- **`Maugham/Views/FirstReaderRuling.swift` is the one production file naming `.firstReader` to `RulingPerformer`** (`TripwireGrepTests.test_theFirstReadersStatementIsWrittenFromOneFile`).
- **The record remembers who read**: `CompilerRun.readerName` (a check's; `nil` for a round). A standing letter's surfaces read `run.readerName ?? reader.editorName`; the header and empty state stay on the LIVE reader. A pass's resolved name signs its notes (`CompilerMintContext.editorName`).

### The run's order
- **A run's first act is to close the writer's burst, then read**: `Environment.prepareForRun` is awaited at the top of `runRequested`, before `reading` (fresh prose sits in the `PendingBuffer` until a pause). It cannot throw; a failed flush costs the run its newest paragraphs, never the writer's words.
- **The flush hop is covered by `isRunning`** (a double ⌘R is one run) **and abandoned by generation** on `shutdown()`.
- **The derivation is the run's second suspension**, before the send, and carries `runGeneration`: the toggle going off mid-derivation abandons the run.
- **`beginRun` calls `commitPendingAsk(docId:kind:)` with its own kind, then reads `ask(docId:kind:)`**, so an unsubmitted worry reaches the run it was typed for and never the other loop's. `beginRun` is the one line every trigger passes.
- **Round number and pass are minted in `beginRun`'s synchronous prefix**, before the send: from the first preview byte the standing content is this run's own half-report.
- **Whatever a run stamps (round, pass, `scenePosition`, `asked`, `stage`) is derived at the keystroke, rides `StreamingRun` and is stamped in the one `record(...)` spelling**, so a preview and its answer cannot disagree.
- **`finish` mints before it records** (`record`'s `mintedNotes:`) and awaits `mintAnnotations` before checking `runGeneration == generation`. A Cancel inside that await leaves annotations with a `compilerRunId` the sidecar never records; the mint is not transactional, so any future join of the two must expect misses.
- **`finish`'s failure and unusable-output arms ignore a retired run generation**, so a dying session cannot end a newer run. A Cancel does not bump the session generation.
- **The orchestrator names no store; it takes closures, and every hand-off is a value**, so a run drives end to end with no project on disk. Never reach for `ProjectStore` inside `CompilerOrchestrator.swift`; the wiring is a peer file.

### The session's lifetime (ADR 0028 §1, §4)
- **Entering Author never starts a session; only the first run does**: `CompilerOrchestrator.ensureRunner`, called only from `beginRun` (the continuation `runRequested` hands off to).
- **The AI toggle going off kills every service**: `CompilerRunModifier`'s `.onChange(of: mcpEnabled)` calls `roster.shutdownAll()`, and `ClaudeCLISession` re-reads the toggle before every spawn.
- **App quit kills every project's services**: `CompilerRunModifier`'s `.maughamAppWillTerminate` arm and `MaughamApp`'s observer through `ProjectSessionRegistry.shutdownAll()`, which reaches rosters no window holds.
- **A window closing gives its session back, never closes it**: `.onDisappear` calls `sessions.release(`, which hands the attachment to the newest other live window, else runs `ProjectSession.detachWindow` (`roster.detachAll()`), so closing one of two windows ends nothing; the last release closes the session, detaching services BEFORE the `DocumentStore` closes.
- **Idle death after ~10 min** (`idleTimeout`, 600 s; `idleDidExpire` refuses mid-turn). The per-turn budget is a SILENCE budget, `defaultSilenceTimeout` (180 s, reset by every line, thinking included), under `defaultRunTimeout` (1,200 s) for every session type. A stall carries `CompilerRunFailure.Stall`, worded by `RoundNarrative.stallCopy`.
- **Death mid-run fails that run once; the next keystroke starts fresh**: `finish`'s `.failed` arm leaves the marker and the intent hash where they were.
- **The ⌘⇧R lifetime row: Fresh Eyes kills and replaces the session in one act** (`beginRun`'s `if freshEyes { retireSession() }`), BELOW the in-flight refusal, the generation check and the empty-delta guard, so a refused or empty press costs nothing (`CompilerRunCommandTests.test_freshEyesWithNothingToReadKeepsTheWarmSession`).
- **The shutdown contract: every teardown path must reach `shutdown()` explicitly.** `ClaudeCLISession.deinit` is nonisolated, and releasing a `Process` neither signals nor reaps its child, so a released session is a live, billing `claude`.
- **`AgentRoster` is the one list and the one order; a new service joins it.** `TranslatorEnvironmentTests.test_everyWindowEndingPathShutsEverySessionDown` checks that every class holding a `CompilerRunner` or `ClaudeCLISession` is a member, that both verbs reach every member, and every ending path. The pipeline goes first on both verbs, so a leg parked on the translator's summary resolves before the translator goes.
- **The roster census is blind to a COLLECTION of runners** (`[CompilerRunner]`, a pool, a per-language map): its holder is not counted.
- **`shutdown()` keeps the orchestrator usable** (Claude toggled back on still runs ⌘R); **`detach()` also drops the environment and the stores.** They are not interchangeable.
- **The roster belongs to the project's `ProjectSession`**, shared by its windows; `ProjectSession.attachWindow` configures every service and `open` configures none (a reader's borrow must not hold a billing session).
- **The shutdown contract owns a FILE too**: a bridged session's `compiler-mcp-<UUID>.json` in `sessionConfigDirectory` is removed only by `retireSession()` (from `shutdown()`/`detach()` and a model or pair change).
- **`writeMCPConfig` sweeps configs older than a day** (`StaleFileSweep`); never shorter, or it deletes a warm session's live config.
- **A test fixture over a `production` environment inherits every closure it does not replace**, machine-global ones included; replace `writeMCPConfig` too (`test_theFixtureWritesItsBridgeConfigInsideItsOwnProject`). Never count the shared directory.
- **The death verdict is a JOIN of stdout's EOF and the process's exit**, bounded by `defaultDeathReapGrace` (2 s), in either order. A verdict for a retired generation is ignored, so a send inside the grace spawns fresh.
- **`--resume` is pre-authorized and not built** (ADR 0028 §4; check `ClaudeCLISession.arguments`): a second `CompilerRunner` conformer that must still answer `sessionEpoch`.

### The delta, the stage and the process
- **The delta marker is the CHECK's; a round neither reads nor moves it.** A round is built `since: nil`; the empty-delta arm advances the marker for a `.check` only (`test_anEmptyDeltaStillAdvancesTheMarker`, `test_anEmptyPieceMovesNoMarkerForARound`).
- **`lastOpId` is `kind == .check ? (delta.newestOpId ?? marker) : marker`**: a round files the position it found, so a check's next delta begins where its own last run left it (`test_aCheckAfterARoundStillReadsWhatTheRoundDidNotConsume`).
- **`ProcessSignals` is pure over `(ops, sequence, now)`**, no store or clock, so `beginRun` and Statistics' `ProjectPractice` cannot disagree.
- **A session is a run of manuscript ops** (filtered through `Deriver.appliesToManuscript`, never a local re-switch), split where `Op.session` changes or ops are at least `SessionTracker.idleThreshold` apart, the one constant shared with Statistics.
- **The frontier is the latest `.typingBurst` mint still in `sequence`**, ties within one op by position (not change order). Churn counts `.typingBurst` OR `.claudeAccept` over the last `churnWindowSessions` sessions.
- **The draft stage is derived, never set** (`DraftStage.derive(counts:signals:)`): `counts.new <= counts.revised` is `.revising`; no signals is `.drafting`; otherwise `.drafting` needs `sessionsSinceFrontierMoved == 0`, and no frontier reads `.revising`.
- **The stage and the signals are a CHECK's alone**: `stage` is `nil` for a round, and `stageSection` and the dose both fall back to `.full` off that `nil`. Only `Letter.stage` persists it.
- **Dosage is enforced at both ends**: `LetterDosage.short` caps questions at 1, drops the exercise and reads `scenes` as `nil` at ingest whatever the model wrote, and `stageSection` states it. A cold read and a round are `.full`; the ask's answer is never dosed.
- **`LetterDosage.reader` keeps `answer`, `about`, `working` and one question**, and drops `one_thing`, habits, the exercise, scenes, `retired` and `process` at ingest (`allowsOneThing`/`allowsHabits`/`allowsProcess`).
- **The first reader's four kinds are `DiagnosticIngest.readerKinds`** (`dream_break`, `belief`, `drag`, `lost`), named in that order by `firstReaderInstruction` (`test_theReaderInstructionNamesTheFourKindsInTheSchemasOrder`); `CompilerNote.readerKindLabel` is the other half.
- **The lane word has one source, `DraftStage.laneWord`, read by exactly `LetterKeep.swift` and `LetterSection.swift`** (`TripwireGrepTests.test_theStageWordIsReadFromTwoViewFilesOnly`). Review's lane line does not show a stage.
- **`LetterKeep.stageWord` appends the stage only beside a NAMED round; `LetterSection.signature` whenever one was derived** (`LetterSectionTests.test_theSignatureCarriesTheStageTheRunDerived`). `LetterKeep.laneLine` reads the letter's own stamp; `QueueLedgerVerbs.provenance` passes `stage: nil`.
- **Nothing about the signals reaches the footer, the tree or the editor**: Statistics' Practice section and the letter's `process` line are the only surfaces (`TripwireGrepTests.test_theProcessSignalsNameThemselvesOnTwoSurfacesOnly`).

### The briefing
- **What the writer DECLARED is inside the hashed unit** (essay, derived clauses, bible slice, lessons ledger: `briefingHash`, elided when unchanged per `sessionEpoch`); **what belongs to one run is outside it.**
- **The per-run frame never folds into `briefingHashInput`** (`readerSection`, `passSection`, `scenePositionSection`, `stageSection`, `processSection`, `dispositionsSection`, `askSection`): hashing one re-embeds the essay, world and bible on an ordinary run. Count the appends in `runMessageV2`.
- **The kind changes what is briefed, never the hashed unit.** `checkMessage` has no `previousRound`; `roundMessage` has no `stage`, `freshEyes` or `signals`.
- **A check reads `deltaSection`; a round reads `wholePieceSection`** (`The piece, whole:`, one `[¶id]` line per paragraph in `DeltaBuilder`'s order, no new/revised labels).
- **`readerSection`, `stageSection` and `processSection` sit in the `.check` arm only**; `askSection` is last of the frame, closest to the prose.
- **The ledger folds in as the RENDERED `lessonsSection`, never its markdown**, so a retirement does not re-embed everything; a retired entry is briefed to nobody.
- **Standing instruction text is budgeted**: `letterInstruction`'s `process` sentence rides every run and counts toward the 715-word budget (`CompilerPromptTests.test_theStandingPerRunInstructionAdditionsStayUnderAWordBudget`); `stageSection`/`processSection` themselves do not.
- **`pinnedListing` carries the `PinnedShelf`'s grouping**: one `pinnedListingLine` per pin, `## <title>` over each titled section only; an empty section is omitted.
- **`PinnedReferences.pinned` is one pure function with two production callers**, the run's context and the Author surfaces; neither may re-derive it. `linkedResearchIds`, never `StructureItem.links`, is the field a caller names (`PinnedReferencesTests`). The assistant column studies the shelf in Author and Review only (`Persona.studiesPinnedReferences`); Plan and Publish keep it inert.
- **The scene position is derived app-side and stated, never inferred**: `ScenePosition.derive` reads the project type, the WHOLE intent statement (not `StatementEssay.half(of:)`: Add-to-intent files under `## Rulings`) and the verb's brief (`CompilerRunCommandTests.test_theDerivationReadsTheRulingsHalfAndNotJustTheEssay`).
- **For a check only `AuthorReader.brief` (the coach's) is a form brief**, never a first reader's statement. The writer's explicit scene-table opt-out beats everything, even a turn clause in the same statement.
- **`strongDeclared` vs `strongDefault`**: a turn-less scene is a strain ONLY when the writer's own words carry the clause (conformance keys on a `clause_quote`, never synthesised); otherwise an observation. `ScenePosition` raw values are a disk format.
- **The dispositions section is the warm path's duplicate guard**, two asymmetric lists (`dispositionsSection`, `CompilerAnnotationDisposition.gather`). *Standing* is uncapped and unsorted (`gather`'s order): truncating it mints duplicates.
- ***Settled* is capped at `settledDispositionLimit` (12)** with the elided count spelled out, sorted by `resolvedAt` DESCENDING. Ties and the undated (a `.declined` has no `resolvedAt`) fall back to arrival index, because `sorted(by:)` is not stable.
- **A standing fingerprint silences its settled twin** in `dispositionsSection`. A fingerprintless note is listed on its own, neither deduped nor counted cross-lane.
- **Fresh Eyes briefs NO dispositions** (`let dispositions = freshEyes ? [] : …`): cold means cold, and on ⌘⇧R the ingest fingerprint dedupe is the only guard.
- **The ask lives beside the sidecar, keyed per document PER TEMPO** (`.maugham/diagnostics/asks.<slug>.json`, private `askKey(docId:kind:)`); one kind's ask never touches the other's. Never a `FileContent` field: an ask precedes any run. A legacy bare key reads as `.check` and the next `persistAsks()` rewrites new keys only.
- **The ask commits on submit and focus loss, never per keystroke** (`AskField`); keystrokes go to the in-memory `pendingAsks`.
- **`setAsk` refuses over `askLimit` by answering `false`, not throwing**: nothing failed. The ask is outside `briefingHashInput` and stamped onto `Letter.asked`.

### Ingest, the sidecar and the mint
- **Notes are anchored at ingest against the LIVE paragraph**, never echoed text, so exact-match staleness is right and a mid-run edit a non-case. The anchor is the FIRST resolving ref; `refs` are display-only.
- **One section is one unit**: `parseAll` is `parseSection` folded over the turn. A bad note never fails a run (`DiagnosticIngestTests`).
- **`SectionedOutcome.sidecarDiagnostics` keeps conformance strains only; `.mintable` is the other half**, built from the same accepted diagnostics, never re-parsed.
- **The letter is asked LAST**, and is the one section of prose parts; each question that resolves a ref also mints a `.letterQuestion` diagnostic, reaching the queue as a `.query` and never the sidecar.
- **A dangling ref costs a letter entry its jump links, not its prose** (`letterRefs`; `resolveRefs` drops such an entry in every other section). Neither a dangling ref, a cap nor a scrub moves `droppedDangling`: the letter is not a note.
- **Every letter prose field is scrubbed for a leaked paragraph id** (`letterProseLeaksAnId`): the entry drops, or `about`/`one_thing` empty. The fix-shape scrub stops at `questions`, the one part that becomes a `.query`; `exercise` is exempt.
- **`parseLetter` caps habits FIRST and takes citable names off the capped list**; a question's `habit` key matches through `LessonsLedger.matches`, and a near-miss stamps nothing.
- **A question is matched on the habit's `name` and stamped with its `ledgerHeading`**: stamping the name put one habit in the ledger under two identities. `Habit.ledgerHeading` is the one rule; the parse and `LessonOffer.lessonHeading(for:)` read it.
- **The heading rides `Letter.Question.lessonHeading` → `Diagnostic.lessonHeading` → `Op.Provenance.compilerLessonHeading` → `Annotation.lessonHeading`**, never the sidecar.
- **`Letter` decodes every part but `about` as optional; ask `isEmpty`, never `letter != nil`.** `scenes == nil` (does not move by scenes) differs from `[]` (a table with no rows).
- **`LetterMarkdown.scrubbed` is the one gate every emitted string passes**, so a leaked anchor cannot ride into a research note. Where a kept letter lands is `LetterKeep` and `ResearchScope.route`, not this area's.
- **`intent_drift` is a verdict, not a `Diagnostic`**: `holds`/`drifted` and nothing else; an unrecognised word reads as no verdict, never an `unknown` case. Its one sentence is read and DROPPED (ADR 0027): the mark is app-authored.
- **"Drift" names two things that must never merge**: `DriftDetector` is the clause-strain PATTERN across runs (`DiagnosticsPane.driftNote`, not a `Diagnostic`, gone when the pattern breaks); `intent_drift` is the per-run judgement on `CompilerRun.intentDriftVerdict`.
- **The sidecar holds TWO standing runs, one per `RunKind`**: `FileContent.check` and `FileContent.round`, each replaced only by its own kind (`CompilerRun.effectiveKind`). `lastCheck` is Author's, `lastRound` the cockpit's.
- **`lastOpId`, `live`, `dismiss` and the unread badge (`unreadCount`, `markRead(docId:kind:)`) are the check's; `standingRound`/`latestRound` and the round ring are the round's.** `lastRun` (the newer) answers only `IntentDrift.mayTrailDraft`.
- **`effectiveKind` is a two-clause rule**: a legacy top-level `run`/`diagnostics` pair loads into the slot its kind names, and a legacy `passId: "workshop"` record loads as a CHECK (`RunKindTests`, `DiagnosticsStoreTests`' fixtures under `MaughamTests/Fixtures/`).
- **A round's conformance strains are stored in the round slot and drawn nowhere**; its findings reach the writer as annotations.
- **The round ring is the DOCUMENT's and ROUNDS only**: `FileContent.rounds`, capped at `roundHistoryDepth` (5), every pass filing into it; a check contributes nothing. The document remembers six finished rounds: the ring plus the standing round, filed in only when superseded.
- **The ring is written only by `replace`, for the run being SUPERSEDED**: `RoundRecord(run:)` is built from `finishedStanding(docId:kind:)`, which reads the shadow `finishedBeforePreview` while a preview stands in. That shadow is keyed by `SlotKey` in `previewing`, never by its nil-ness.
- **`latestRound(forPass:docId:)` reads the round slot directly, never the shadow** (its readers want the round in flight), then walks the ring newest-first. A lane aged out of the ring answers `nil` and mints round 1.
- **`RoundFingerprint` is the one round-over-round join key** (section + clause quote + anchor + reader category, never prose); its `stringValue` is the dedupe key and a synced format. `RoundRecord.fingerprints` is written empty.
- **The mint refuses a finding already open in ANY lane** (one finding is one note), keyed on `compilerFingerprint`. A re-punctuated continuity cite can slip past; it gets no machinery.
- **The mint answers `MintOutcome` (`minted`, `openInOtherLanes`)**: distinct findings refused where NO lane holding them is the round's own. The mint loop's `taken` map is fingerprint → SET of lanes, because one fingerprint can be held by two open notes. The count is taken there and nowhere else (a second scan could disagree with what the mint refused), because `SinceLastRound.compute` is lane-local by design. It rides `CompilerRun` as an optional field.
- **`reopenAnnotation` has no fingerprint-collision guard and must not grow one**: reopening takes a note back; it claims nothing about any other note.
- **The cross-lane wording lives only in `RoundNarrative.openInOtherLanes(_:)`**, PAST tense (a snapshot at the mint), for `sinceLastRoundLine`, `freshEyesHeader` and the pane. An own-lane match is persisting, never counted twice; it counts NOTES only.
- **Neither round sentence draws in Author's pane**: `sinceLastRoundLine` refuses a check, and both sentences live in the cockpit (`AnnotationsPane.cockpitReportLine`) (`DiagnosticsPaneTests.test_neitherRoundSentenceIsDrawnOverAColdCheck`).
- **`DiagnosticsPane.content` forks on `hasReport`; anything an intentless run must show renders in BOTH arms**, as `thisCheckSection` does (`test_theLetterLeadsBothArmsAndPrecedesThisCheck`).
- **`CompilerRun.mintedNotes` stops the pane claiming a clean check over queued notes.** `headerState` is fed `strains.count`, never `rows.count`: legacy rows the pane refuses to draw would call a legacy sidecar clean.
- **`headerCopy`'s `.clean` arm opens with `queuedNotesSentence` only when `wetInk == .none`**; the "Notes in your queue" empty state is ordered above the discarded-notes arm.
- **The sidecar is derived state**: a missing or corrupt file reads as empty, there is no repair path, and the next run repopulates it.
- **The cold-start offer is refusable once per document, forever**: "Not now" writes `refuseColdStart` into one per-device project file (`refusedColdStartURL`), since a refusal can precede any `FileContent`; Read is not a run kind, it calls `runRequested` as ⌘R does.

### Streaming and the preview
- **Only `text_delta` is the answer**: `classify`'s `.partialText` keys on `stream_event → event.content_block_delta → delta.text_delta`; `thinking_delta`/`signature_delta` must never feed the report (`ClaudeCLISessionTests`' `captured…` lines).
- **Deltas ride `receive` behind the same two guards as the result** (live generation, turn in flight) (`test_aRetiredProcessesDeltasNeverReachTheHandler`).
- **A chunk is not a line**: `receivePartial` reads only what a newline closed.
- **The result REPLACES the preview, never folds into it**: `finish` runs `parseAll` and calls `replace` (`test_theFinalResultReconcilesTheStream`).
- **`DiagnosticsStore.preview` never persists, never touches the drift ring, never raises the badge.** Every run ending without an answer calls `discardPreview` (a re-read of the sidecar): `finish`'s failure and unusable-output arms, `cancel()` and `shutdown()`.
- **A preview's rows carry no fates**: `DiagnosticsPane.offersDurableActions(state:)` withholds Answer and Promote while this document's check is `.running`.
- **`DiagnosticsStore.dismiss` refuses while `previewing.contains(docId)`**, in memory and on disk, so a future per-note mutator inherits it (`test_aDismissalCannotReachAPreview_soTheSidecarSurvivesACancelByteIdentical`).
- **`RunState`'s run cases carry a `RunKind`**: `headerState` matches `.check`, `ReviewRoundCockpit.phase` `.round`; each names the other loop's run window-wide (`otherLoopLine`), refusing its Run and offering Cancel.
- **A check note is answerable mid-round only because `persist` writes each previewing slot's FINISHED answer** (`finishedBeforePreview`), never a half-report.

### A strain's four fates
- **Superseded**: the next run replaces the strains and `clauseStatuses` wholly; un-promoted strains drop.
- **Stale**: its paragraph's text changed, so `DiagnosticsStore.live` drops it (an anchorless strain never goes stale).
- **Promoted**: kept as an op-logged task (`DiagnosticPromotion`, strains only; `sectionLabel` keeps old tasks' labels).
- **Answered**: a ruling on the PIECE's intent statement (never the project's, minted if absent) via `RulingPerformer.rule` from `DiagnosticsPane.commitAnswer`, carrying the strain's `clauseQuote` trimmed to `driftQuoteMaxLength` (`answeredNoteProvenance`); the note dismisses.
- **Continuity questions, reader reports and letter questions have no fates here**: they are annotations from the moment they mint and follow that layer's verbs and undo (ADR 0023). `RulingPerformer` never sees one.

### The writer-owned layer
- **`RulingPerformer` is the one door into a statement's `## Rulings`**: rule, revoke, edit, `restore`, taking the writer's words or a `Ruling` those verbs produced, never a reading.
- **Every verb takes an undefaulted `kind: Statement.Kind`**, or an edition's decision could land in the book's intent silently (`RulingPerformerTests.test_everyVerbTakesTheDestinationKindExplicitly`). Today: intent, edition brief, lessons, first reader; visual language has none (no caller names it).
- **`Maugham/Views/LessonLedgerVerbs.swift` is the only production file naming `.lessons` to `RulingPerformer`** (`TripwireGrepTests.test_theLessonsLedgerIsWrittenFromOneFile`, whose companion catches `revoke(` too).
- **`restore` exists for ⌘Z alone**: `rule` cannot invert revoke (it re-dates and appends). An undo that rewrites the record is worse than none.
- **Every verb asks WHO before it writes**: `refuseUnlessTheStatementIsYours` throws `RulingRefusal.notYours(statement:)` unless the device may `.editStatement` (`settledPosture` at `StatementEditorHost.postureDocId`, or Core's `PostureDoor` when no window holds the store) (`RulingPerformerTests.test_everyVerbAsksTheDoorBeforeItWrites`). A project statement is the book author's; a piece statement follows its piece. Surfaces ask `DocumentStore.posture(ofStatement:scope:statements:)`.
- **`RulingPerformer` has no autosave flush and no project-scope fallback**, both argued in its doc comment; read it before adding either.
- **Every verb invalidates the declared-world cache** (`world` explicit, undefaulted), so a revoked ruling stops being checked immediately. Brief-side callers pass `world: nil`.
- **`StatementProposalGate.adopt` is the second and last door into a statement's ESSAY** (`mutateStatementText`), and asks the door FIRST because its essay write precedes its glossary rulings, which go through `RulingPerformer.rule`.
- **`LessonsLedger` reads a ruling's TEXT, never the whole line** (never require the `— ruled …` suffix). Retirement beats the choice prefix; an unparseable retired date is still retired; dates go through `RulingsSection.formatted`/`date(from:)`.
- **A ledger entry is addressed by index-at-the-moment (`RulingsStratum.currentRows`) or by heading through `matches`** (exact after trimming, case-sensitive), never a remembered id. `LessonOffer.retirable` narrows the letter's `retired` list to live lessons the same way.

### The derivation trigger and the bible
- **The derivation trigger is lazy, on demand**: the first consumer finding `DeclaredWorldStore.cached(forScopeKey:sourceHash:) == nil` calls `WorldDeriver.derive(statementText:)`. No background derivation, no derive-on-save (ADR 0027 §3).
- **`CompilerOrchestrator.resolveWorld` is the only production call site**: `cachedWorld` first, `deriveWorld` on a miss. A success is cached (`CompilerRunCommandTests.test_productionCachesWhatItDerives`); a failure caches nothing.
- **No derivation is ever drawn**: the Rulings and Bible strata never read `DeclaredWorldStore.cached` or draw a clause (`StatementPaneStrataTests`).
- **The cache key stays the scope alone**: nothing derives a world from a brief, and a second key shape is the two-spellings defect `scopeKey` prevents.
- **The statement is derived WHOLE and briefed by halves**: the essay as prose, the rest as clauses. The ruled sentence appears exactly once (`CompilerRunCommandTests.test_rulingsAreBriefedAsClausesNotProse` counts occurrences; `test_aRulingBetweenRunsReachesTheNextBriefing`).
- **An essay-sourced clause quote is a known open door** (`derivationSchemaDescription` quotes from the whole statement, so that sentence is briefed twice). Do not close it by accident: re-read the history file's atomic switch before widening the derivation schema or embedding clause quotes elsewhere.
- **`ClaudeWorldDeriver` drains stdout WHILE the process runs** (reading it in `terminationHandler` deadlocks past ~64 KB).
- **`ClaudeWorldDeriver` has a 120 s deadline**: an overrun is `terminate()`d and answers `nil`, by force (`OneShotOutput.deadlineExpired`, after `terminationGrace`) if EOF is withheld.
- **The third door: bless converges.** `BibleStore` remembers GRADUATED `(subject, fact)` keys and `record` drops a matching candidate, or a blessed fact would come back and be briefed twice (as fact and as clause).
- **`BibleStratum.graduate` marks the key after `RulingPerformer.rule` succeeds and before `bible.dismiss`**, so a refused ruling changes nothing. Keys ride the same sidecar envelope as the ledger.
- **Graduated is not dismissed**: a plain dismiss keeps no memory, so a re-established fact returns (`BibleStoreTests.test_dismissedFactCanReturn_thisIsIntended` beside `test_aBlessedFactDoesNotComeBack`).
- **A correction graduates two keys**, Claude's reading and the writer's ruling; a bless marks one (`StatementPaneStrataTests.test_correctingGraduatesClaudesReading`, `test_correctingAlsoGraduatesTheWritersOwnRuling`).
- **Revoking a ruling does not reopen the door** (reasoning on `BibleStore.markGraduated`).
- **Only the writer's bless / correct / dismiss (`BibleStratum`) promotes or discards a fact**; nothing in `BibleStore` is truth.
- **The ledger is read at a run's start (`bibleSlice`) and written at its end (`recordFacts`)**, so the bible loop needs three runs to test (`CompilerRunCommandTests.test_theBibleLoopConvergesAcrossRunsWithABlessInTheMiddle`).

### The translator
- **The translator rides the compiler's rails** (closure `Environment`, lazy warm session, `runGeneration`, a like-shaped `RunState`), **warm per `(docId, language)`**: `ensureRunner` retires the session on a pair or model change, so no edition's register leaks.
- **A failure writes nothing, structurally**: `Environment.ingest` is reachable only from `finish`'s parsed-report arm (`TranslatorOrchestratorTests.test_aFailedRunIngestsNothing`).
- **The report is all-or-nothing from parse**: an entry with both `text` and `verbatim`, or neither (an empty `text` is neither), refuses the whole report. Text is stored trimmed; `delete` is absent from the contract.
- **`TranslatorBriefing.compose(inputs:)` is pure**, output shape last; a translator with no brief gets no fallback sentence. An empty work-list is `nothingToTranslate` and spends no session. Bible facts come from `BibleStore.slice(matching:)`, the compiler's rule. Answered queries cap at `answeredQueryLimit` (12), newest settled first; open ones are uncapped.
- **Every capture in `TranslatorEnvironment+Project.swift` is weak**: a closed window's view graph is never dismantled.
- **The edition brief is briefed whole, `## Rulings` included, with an instruction to honour each standing ruling exactly**; neighbour paragraphs are context only, deduped against the work-list.
- **The words go through `TranslationWritePipeline.perform`**, `write_translation`'s door, re-validating every `¶id` at ingest.
- **A paragraph EDITED mid-round rejects the batch**: `BriefedRound` hashes the RAW source, `IngestContext.briefedSourceHashes` (undefaulted) carries them to `midRunEdits`, checked BEFORE the pipeline.
- **Words first; a rejected batch mints no queries** (queries have no fingerprint to dedupe).
- **Queries mint through `Document.addAnnotation`, signed by the translator and language-tagged in `toolArgs`**; an anchorless one is a doc-scoped `.craftNote` with a `Translation query (<lang>) — ` prefix. The tag, not the kind, re-briefs and counts it.
- **The translator identity is resolved before the briefing** (`ProjectStore.translatorRole(for:)`, find-or-create; read paths never mint a role), so the role frame and the signature name the same row.
- **The translator has no run keys** (⌘R and ⌘⇧R are the compiler's) and starts on the desk's Run alone.
- **Translation runs only on the OPEN document** (`DepartmentRunTarget.resolve`; `test_theBriefingAbandonIsClosedByTheOpenDocumentGate`). One round runs at a time across every language (`DepartmentRunSession.busy`).
- **A translator is named only through the cast sheet** (`DepartmentCastSheet.swift`: Name & Run, Add Language…, Rename …): `translatorRole(for:)` + `renameProductionRole`.

### The designer
- **The designer is a third conformer, warm per PROJECT** (retired only by a model change or `shutdown()`); `requestChanges` iterates on that session. A round stays OPEN (`hasOpenProposalRound`) until a fresh `runDesign` send (closed before the answer), `retireSession`, or `sessionEpoch` moving.
- **`stage` stages the proposal and compiles a sample, both awaited** (`StageOutcome`): a staging refusal fails the run (`.stagingRejected`); a sample failure is advisory and the run ends clean.
- **The census and page selection are recomputed at staging, never carried from the briefing**: the writer keeps writing through the turn.
- **A language round samples its prose against BASE templates** (`SampleCompiler` takes no `language:`); the caveat is unreachable while `runDesign` is called with `language: nil`.
- **config.json is refused at parse by `DesignerReport.parse`**; the briefing embeds a trim/format summary only, and `SampleCompiler` builds its own `PublishConfigStore` on scratch. `EMISSION.md` is not refused; a guard belongs at parse.
- **`ProposalPromotion` writes the live tree only on the writer's three verbs.** `approve` refuses during a compile, with no live tree, or over a STANDING backup held by any proposal (`proposalHoldingTheBackupSlot`, one slot project-wide).
- **`approve`'s order**: resolve every staged path (escape check), back up every replaced file, write, mark `approved` LAST. It does not gate on status beyond its three guards (a superseded proposal may be promoted).
- **`revert` reads the BACKUP MANIFEST, not the status**, so it also recovers a half-done promotion: restore, delete introduced files (pruning only directories the round made), mark `rejected`, discard the backup.
- **`finalize` discards the backup and keeps `approved`**, separate because it is the destructive half; it refuses with no backup or a non-`approved` STORE status, ungated by a compile.
- **Never register a promotion verb with `NSUndoManager`**: a ⌘Z at any depth must never un-ship a book's templates.
- **A verb's result is re-read from the store** (`DesignGatePromotion.perform` → `PublishCentreModel.adoptVerbAnswer(_:)`); only a successful verb posts `.maughamDesignProposalsChanged`.
- **A `stage` supersedes every pending proposal project-wide.** Everything under `.maugham/design/` is derived and deletable (`Maugham/Stores/AREA.md`).

### Cold calls, spot-checks and the pipeline
- **A cold call is one fresh process per call** (`ColdCall`): no warm reader orchestrator, because warmth would cost blindness. One call at a time (`runInFlight`), no queue.
- **A blind briefing has no source field** (`ReaderBriefing.Inputs`, `GlossBriefing.Inputs`): the property is the type's. An untranslated paragraph reaches the reader as `gapMarker(_:)`, never source.
- **Gloss reads its paragraph off the badge entries the pane holds, never the disk.** Ask the Collator narrows the pairs (`SpotCheck.narrow`) but keeps intent, brief, glossary and directives whole.
- **Spot-checks are buttons, no shortcut bound, and mint nothing**; *Keep mine* / *Make it a rule* are separate verbs (`TripwireGrepTests.test_aSpotCheckMintsNothing`, so `SpotCheck.swift`'s prose never names a write door).
- **Every one-object report is all-or-nothing on `ReportJSON`**, with closed enums and zero notes valid; a `paragraph_id` outside the briefed set fails the whole report. `DiagnosticIngest` keeps its own helpers. A collator departure without a gloss is refused.
- **Only `drifted` departures are briefed to leg 7**; both verdicts reach the round report. The collator is not briefed reader notes, translator queries or the bible.
- **Directives count by UTC calendar day** (a same-day directive counts; an undated one never directs).
- **`TranslationPipeline` is a state machine over closures**: it owns no session, and it (not `ColdCall`) parses cold text into reports.
- **Skips are recorded with one static reason each**, never silent. Leg 4 skips on `nothingChangedReason` whenever leg 3 wrote nothing.
- **A failing, rejected or cancelled leg ends the round; earlier legs' writes stand** (`round.stoppedAt`).
- **Cancel reaches whichever leg is live** (`cancelTranslator()` / `cancelColdCall()`, by `live`). **A cancel between legs is caught by the loop's `guard generation == gen`**, recording the next leg `.cancelled`; deliberately no check after `mintDeclinedQueries`. `runToken` moves only on `start`, and `setLive` no-ops for a stale one (`TranslationPipelineCancelTests`).
- **Note ids are minted before the fix leg is briefed**, and `fixBriefing` builds the work-list from notes still `.fresh` with a translation.
- **`onRunAbandoned` is not a summary**: the briefing answered `nil`, so the leg fails with `unbriefableSentence(role:)`, never `nothingToTranslate`.
- **A declined note's reply lives in the query BODY** (`declinedBody`), authored by the reader or collator who raised it. No reply `OpKind` or `AnnotationKind`.
- **The book queue stops on a failed round**; it never skips a chapter.
- **The desk's busy gate reads `TranslationPipeline.Status` first** (`DepartmentRunSession.read(runState:isRunning:pipeline:)`), on the body path, never through `ReloadKey` (language only).
- **`TranslationRoundStore` keeps the newest `ringSize` (10) rounds per language**, numbered per language across documents by a `nextNumber` that outlives the ring. `append` is this area's only write; `update(_:)` belongs to the round report.
- **`TranslationPreflight.budgets` opens each document ONCE** for every language; an empty answer means nothing could be read, distinct from a zero.

## Recipes

### Add a compiler role (a new `claude` service)
1. Put the orchestrator in `Maugham/Compiler/<Name>Orchestrator.swift` on the rails: a closure `Environment`, a runner minted through `Environment.makeRunner` (a `CompilerRunner`), `runGeneration` checked after every suspension, `shutdown()` (ends the session, stays usable), `detach()` (also drops the environment), `updateModel(_:)` if it spawns on the depth menu's model (lazily: `ensureRunner` compares at the next spawn; never kill a turn in flight).
2. Pick confinement, and spawn through `ClaudeCLISession`. Bridged: `writeMCPConfig` + `CompilerAllowlist`, and add any read it needs to `CompilerAllowlist.swift` (the allowlist census still finds no writer). Sealed: go through `ColdCall`, never your own `.sealed` session (`test_theOnlySealedSpawnerIsColdCall`). A raw one-shot `Process` (the `ClaudeWorldDeriver` precedent) copies its argv whole (`--tools ""`, `--setting-sources ""`, `--system-prompt`, an explicit `--effort`, never `--bare`) and drains stdout while it runs. The censuses catch only a missing `--setting-sources` and an `--append-system-prompt`, so a dropped `--tools ""` lets the model read any file without anything turning red.
3. Write the production factory as a peer, `Maugham/Compiler/<Name>Environment+Project.swift`, every capture weak. If it writes, write through the writer's existing doors, from one arm reachable only with a parsed report.
4. Join the roster in `Maugham/Compiler/AgentRoster.swift`: a stored property and an `init` parameter; its `shutdown()` in `shutdownAll()` and `detach()` in `detachAll()`, after the pipeline; `updateModel` if step 1 added it.
5. A member holding no runner gets a `nonHoldingMembers` entry (and `noTeardownMembers` if it has no teardown) in `MaughamTests/TranslatorEnvironmentTests.swift`. Hold the runner directly: a collection of runners is invisible to the census.
6. Wire it in `Maugham/Stores/ProjectSession.swift`'s `attachWindow` (never `open`), and add its `configure(` token to the list in `test_everyWindowEndingPathShutsEverySessionDown`.
7. If a pane needs it, read it in `Maugham/Views/DetailPaneToggle.swift` through `@Environment(AgentRoster.self)`, and add its tokens to that test's `DetailPaneToggle` list.
8. Test fixtures over `.production` replace `writeMCPConfig` too.

Checks: `TranslatorEnvironmentTests`, `AgentRosterTests`, `ClaudeCLISessionTests`, the spawn-flag censuses in `TripwireGrepTests`.

### Add a per-run briefing section
1. Write the section in `Maugham/Compiler/CompilerPrompt.swift` and append it in `runMessageV2`, between the listings and the prose. Keep it OUT of `briefingHashInput` unless it is something the writer declared.
2. Scope it by kind through `checkMessage` or `roundMessage`, not a flag; if the first reader must not hear it, pass `nil` for her in `CompilerOrchestrator.beginRun`.
3. Derive its input at the keystroke in `beginRun`, carry it on `StreamingRun`, and stamp anything recorded in the one `record(...)` spelling.
4. Standing instruction text counts toward the 715-word budget; per-run frame does not.

Checks: `CompilerPromptTests` (hash stability across kinds, the budget), `CompilerRunCommandTests`.

### Add a report section to the compiler's wire
1. Ask for it in `CompilerPrompt.sectionSchemaDescription` (via `sectionSchema(judgesIntentDrift:)`), keeping the output-shape instruction last.
2. Read it in `DiagnosticIngest.parseSection`; a bad entry drops, never fails the run.
3. Route it: a conformance strain stays in `sidecarDiagnostics`; a note-natured finding joins `mintable` and mints in `CompilerEnvironment+Project.swift`'s mint loop with a `RoundFingerprint`; a whole-reading verdict is a `CompilerRun` field, never a `Diagnostic`.
4. Add new `CompilerRun`/`Letter` fields as optional (`decodeIfPresent`), so older sidecars decode.
5. If the first reader's dose drops it, extend `LetterDosage` in `Maugham/Compiler/DraftStage.swift` and enforce it at ingest as well as in the briefing.

Checks: `DiagnosticIngestTests`, `CompilerPromptTests`, `DiagnosticsStoreTests`.

### Add a statement kind as a ruling destination
Follow Core's recipe, "Add a Statement.Kind" in `Packages/MaughamCore/Sources/MaughamCore/AREA.md`. In this area: `RulingPerformer`'s `noun` switch, and one production file naming the kind to `RulingPerformer` with its own census. If nothing derives a world from it, its callers pass `world: nil`.

## Pointers
- ADRs: 0027 (the compiler and the editor boundary), 0028 (Maugham goes outbound: the toggle, two-flag confinement, the read-only allowlist, the warm session and `--resume`, billing), 0029 (the report is materialised), 0030 (three people, seven legs, directives as rulings), 0031 (the persona is an input to the run), 0018/0019 (derived reads), 0021 (scoped events), 0023 (undo conventions).
- Specs (`docs/superpowers/specs/`): `2026-08-04-m2-author-compiler-design.md`, `2026-08-07-compiler-second-draft-design.md`, `2026-08-17-one-loop-two-tempos-design.md`, `2026-09-05-two-loops-two-readers-design.md`, `2026-08-19-publish-department-design.md`.
- `docs/tripwires.md` rows 2, 3, 6, 11, 17, 20, 21, 24 and 34.
- Tests worth knowing (the suites are the specification): `CompilerRunCommandTests` (⌘R's real path), `CompilerAllowlistTests`, `ClaudeCLISessionTests`, `CompilerPromptTests`, `DiagnosticIngestTests`, `DiagnosticsStoreTests`, `DiagnosticsPaneTests`, `RulingPerformerTests`, `StatementPaneStrataTests`, `DeclaredWorldDeriverTests`, `BibleStoreTests`, `LetterMarkdownTests`, `TranslatorEnvironmentTests`, `TranslationPipelineTests`, `AgentRosterTests`.
- Known gap: the reply field's commit-on-Return and Escape are asserted at the source (`DiagnosticsPaneTests.test_theReplyFieldCommitsOnReturnAndCancelsOnEscape`); `DiagnosticsPane.commitAnswer` is a `static` so the rest runs for real.
- Neighbouring guides: `Maugham/Views/AREA.md` (the panes, the cockpit, the desk; its Rules → "Publish and translation" covers the department desk), `Maugham/Stores/AREA.md` (project sessions, `DesignProposalStore`, `TranslationRoundStore`), `Maugham/MCP/AREA.md` (`write_translation`), `Maugham/Publish/AREA.md`.
- `docs/history/compiler.md` — the whole previous guide: why each rule exists, the smoke finds and reviews behind them, the walk of the third door, the atomic switch.
