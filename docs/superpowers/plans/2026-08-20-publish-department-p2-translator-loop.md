# Publish Department P2 — The Translator's Loop

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A translation run, inside the app on the compiler model: a confined warm `claude` session briefed on the writer's doctrine translates the stale/missing set for one `(document, language)`, returns entries + queries in a structured report, and Maugham ingests — entries through the ONE shared translation write path, queries as annotations authored by the translator's name.

**Architecture:** Every piece follows a verified precedent: the orchestrator is `CompilerOrchestrator`'s closure-`Environment` shape (`CompilerOrchestrator.swift:193`); the session is `ClaudeCLISession` (a `CompilerRunner`, `CompilerRunner.swift:67`) with the same two-flag confinement and MCP bridge; the report parse follows `DiagnosticIngest`'s wire-shape discipline; ingest writes through a pipeline EXTRACTED from `write_translation`'s handler so tool and ingest cannot drift; queries mint via `Document.addAnnotation` (`Document+Annotations.swift:73`) with `AnnotationAuthor` (`Annotation.swift:49`), the M4 P1 mint pattern (`CompilerEnvironment+Project.swift:251`).

**Tech Stack:** Swift, Mac target + MaughamCore. No new dependencies, no schema change.

**Spec:** `docs/superpowers/specs/2026-08-19-publish-department-design.md` §2 (the translator's loop) + §6 (failure/atomicity). P1 (merged `195afdf5`) provides `ProductionRole`, `ProjectStore.translatorRole(for:)`, the edition brief statement kind, and `read_edition_brief`.

## Global Constraints

- **Confinement is ADR 0028's exactly**: `--tools ""` + `--allowedTools` (read-only) + `--strict-mcp-config`, via the existing `ClaudeCLISession.arguments(model:mcpConfigPath:preamble:)` (`ClaudeCLISession.swift:396`) — the translator adds NOTHING to the spawn shape except its own briefing. No write tool ever enters `CompilerAllowlist.tools`.
- **The spawned session never writes; Maugham writes at ingest** (Approach A, spec decision 6). Ingest is atomic: a dead session has written nothing.
- **One shared translation write implementation.** After Task 1, `TranslationStore.appendBatch` has exactly ONE production caller — the pipeline — and both `write_translation` and ingest go through it. A census test enforces this.
- **Queries anchor against the LIVE paragraph at ingest, never text the model echoed** (M4 P1's anchoring rule).
- **The keystroke/click is the only trigger** — no timer starts a run. Every path that ends a window owns `shutdown()`; a released session is a live billing process.
- **Read paths never mint a role**; the RUN mints (it is a write act) — `ProjectStore.translatorRole(for:)` gains its first production caller here.
- Build flow: `swift test --parallel --package-path Packages/MaughamCore` for Core, `./scripts/test.sh` iterating, `./scripts/test.sh full` before merge. Disable experiment on every negative assertion.

---

### Task 1: Extract the one translation write pipeline

**Files:**
- Create: `Maugham/MCP/Tools/TranslationWritePipeline.swift` (it serves MCP *and* ingest, but it lives beside the code it is extracted from; move nothing else)
- Modify: `Maugham/MCP/Tools/TranslationTools.swift` (the `write_translation` handler body, currently inline at ~lines 86–180: language guard, exactly-one-form check, intra-batch duplicate check, unknown-¶id all-or-nothing, record build with server-stamped `TranslationHash.hash(source)`, verbatim copy, tombstone, `ConstructSkeleton` + equals-source warnings, single `appendBatch`)
- Test: extend the existing write_translation tests (grep `write_translation` under MaughamTests) + new `TripwireGrepTests`-style census

**Interfaces:**
- Produces: `TranslationWritePipeline.Entry` (paragraphId + exactly one of text/verbatim/delete — mirror the tool's `Params.Entry` semantics) and `@MainActor TranslationWritePipeline.perform(entries:language:state:deviceSlug:) throws -> [String]` returning the advisory warnings, where `state` is the same current-paragraph snapshot the tool builds (`currentParagraphState`). ALL validation and the single `appendBatch` live inside. Task 5's ingest consumes this.

**Contract.** Pure refactor: `write_translation`'s observable behavior is byte-identical — every existing test passes UNMODIFIED. The handler keeps only param decode, the language-tag guard (or move it into the pipeline — implementer's choice, stated in the report), the pipeline call, and the notify/response. Census test: `TranslationStore.appendBatch(` appears at exactly one production call site (the pipeline) — planted-offender comment discipline per the repo's census convention.

- [ ] **Step 1: Write the census test** (fails: two call sites would exist if extraction is wrong / none yet named the pipeline).
- [ ] **Step 2: Extract**, run the existing write_translation suite unmodified.
- [ ] **Step 3: Full fast gate.**
- [ ] **Step 4: Commit** — `refactor: one translation write pipeline — the tool and the coming ingest cannot drift`

---

### Task 2: The report contract and its parser

**Files:**
- Create: `Maugham/Compiler/TranslatorReport.swift`
- Test: `MaughamTests/TranslatorReportTests.swift`

**Interfaces:**
- Produces: `TranslatorReport` — `entries: [Entry]` (`paragraphId`, exactly one of `text: String` / `verbatim: true`) and `queries: [Query]` (`paragraphId: String?` — nil = document-level, `text: String`); `static func parse(_ raw: String) -> TranslatorReport?` (nil = unusable, the orchestrator surfaces `unusableOutput`-shaped failure). Wire names in one place, `DiagnosticIngest`/`SectionField`'s discipline (`DiagnosticIngest.swift:80`).

**Contract.** The model returns ONE fenced JSON object: `{"entries": [{"paragraph_id": "...", "text": "..."} | {"paragraph_id": "...", "verbatim": true}], "queries": [{"paragraph_id": "...", "text": "..."}]}`. Parser: tolerant of prose around the fence (take the last complete fenced JSON block — check how the compiler locates its structured tail in `DiagnosticIngest` and reuse that location discipline); refuses an entry with both/neither forms (drops the whole report to nil, not the entry — all-or-nothing starts at parse); empty entries+queries is a VALID report (a fully fresh doc). `delete` is deliberately not in the wire contract — retraction is the writer's/outside path's act, not a run's.

- [ ] Steps: failing tests (round-trip; prose-wrapped fence; both-forms refusal; empty-valid; malformed → nil), implement, gate, commit — `feat: the translator's report has one wire shape`

---

### Task 3: The briefing

**Files:**
- Create: `Maugham/Compiler/TranslatorBriefing.swift`
- Test: `MaughamTests/TranslatorBriefingTests.swift`

**Interfaces:**
- Consumes: `TranslationDeriver.derive(records:sequence:...)` (`TranslationDeriver.swift:48`) for the work-list; P1's `read_edition_brief` semantics for the brief text (via a closure input, not a direct store call — this type is PURE).
- Produces: `TranslatorBriefing.compose(inputs:) -> String` over a plain `Inputs` struct: translator name + language; craft intent text?; edition brief text? (with its `## Rulings` intact — the rulings ARE the doctrine); work-list `[(paragraphId, sourceText, status)]` (stale entries also carry the prior translation text); neighbor context (the paragraph before/after each work item, deduped, clearly marked as context-not-work); open queries + recently answered ones with the writer's answers, capped (follow the cap discipline `CompilerPrompt` uses for dispositions — read it and mirror the constant's shape, own value ok).

**Contract.** The briefing states the role frame (the translator's name, the language, "you translate; you never see your words written back — Maugham ingests"), the report contract from Task 2 verbatim (one source of truth: reference `TranslatorReport`'s own schema-description constant rather than restating the JSON — add such a constant in Task 2), the verbatim-chrome idiom, and the honor-standing-rulings instruction. Pure function, fixture-tested: a briefing with a ruling in it contains the ruling's text; a work-list item's source appears; context paragraphs are marked; caps hold.

- [ ] Steps: failing tests, implement, gate, commit — `feat: the translator's briefing carries the writer's doctrine`

---

### Task 4: `TranslatorOrchestrator`

**Files:**
- Create: `Maugham/Compiler/TranslatorOrchestrator.swift`
- Test: `MaughamTests/TranslatorOrchestratorTests.swift` (closure environment, fake `CompilerRunner` — grep how `CompilerOrchestratorTests` fakes the runner and mirror the harness)

**Interfaces:**
- Consumes: `CompilerRunner` protocol as-is (`send(message:systemPreamble:) async -> CompilerRunEvent`, `cancelCurrentRun()`, `shutdown()`); Tasks 2–3.
- Produces: `@MainActor @Observable final class TranslatorOrchestrator` with `struct Environment` (closures: `briefingInputs: (String, String) async -> TranslatorBriefing.Inputs?` for (docId, language); `makeRunner: (URL, String) -> CompilerRunner`; `writeMCPConfig: () throws -> URL`; `translatorIdentity: (String) async throws -> (name: String, roleId: String)`; `ingest: (TranslatorReport, IngestContext) async -> IngestOutcome`; `onRunEnded: (RunSummary) -> Void`), `runState` (idle/running/failed shapes mirroring `CompilerOrchestrator.RunState` — read it and reuse its vocabulary), `func runTranslation(docId:language:)`, `func cancel()`, `func shutdown()`.

**Contract.** One run at a time (a second `runTranslation` while running is refused, not queued). The session is warm per `(docId, language)` — keep the runner between runs for the same pair, end it on pair change or `shutdown()` (the compiler's warm-session discipline; read how `CompilerOrchestrator` decides warm-vs-fresh and mirror). `failed(...)` runs ingest NOTHING (atomicity is structural: ingest is only called with a parsed report). A `resultText` that fails `TranslatorReport.parse` surfaces as a failure carrying the `unusableOutput` vocabulary. `deinit` cannot reap — the shutdown contract paragraph from `ClaudeCLISession`'s doc comment applies and is restated on this type.

- [ ] Steps: failing tests (refuse-while-running; failure-runs-no-ingest with a spy closure; unusable-output surfaced; warm-session reuse; cancel; shutdown ends the runner — disable experiment on the failure-runs-no-ingest guard), implement, gate, commit — `feat: the translator runs on the compiler's rails`

---

### Task 5: Production wiring — `TranslatorEnvironment+Project.swift`

**Files:**
- Create: `Maugham/Compiler/TranslatorEnvironment+Project.swift` (peer of `CompilerEnvironment+Project.swift` — read it in full first; every capture weak, same discipline)
- Modify: `Maugham/Views/ProjectWindow.swift` (own a `@State private var translator = TranslatorOrchestrator()` beside `compiler` at line ~205; extend the SAME window-ending path that calls the compiler's shutdown — grep where `compiler.shutdown` is called and add the sibling call in every one)
- Test: `MaughamTests/TranslatorEnvironmentTests.swift`

**Interfaces:**
- Consumes: Tasks 1–4; `ProjectStore.translatorRole(for:)` (FIRST production caller — the run is a write act and may mint); `ProjectStore.statementText(of:)` + `statement(kind: .editionBrief(lang), scope: .project)` for the brief input; `TranslationStore.loadMerged` + `TranslationDeriver` for the work-list; `Document.addAnnotation` (`Document+Annotations.swift:73`) via the same open-doc access the mint at `CompilerEnvironment+Project.swift:251` uses (read its `withAnnotationDocument`-or-registry route and take the same one).
- Produces: `TranslatorOrchestrator.Environment.project(...)` factory.

**Contract.**
- `ingest`: entries → `TranslationWritePipeline.perform` (text→text, verbatim→verbatim; the pipeline re-validates ¶ids against the CURRENT state at ingest time — a paragraph deleted mid-run rejects the batch loudly, which is the honest all-or-nothing answer; the failure surfaces on the run summary). Post the same UI notification `write_translation` posts (grep step 7 of its handler) so a live translation-review posture re-derives.
- Queries → annotations: kind `.query`, `language` set, `author: AnnotationAuthor` carrying the translator's `effectiveName` (mirror how M4 mint builds its author), anchored to the LIVE paragraph (a query whose ¶id vanished mid-run mints doc-scoped instead of dropping — the writer must still see the question; note this rule in the file).
- `translatorIdentity` resolves through `translatorRole(for:)` — mint-on-first-run is exactly P1's lazy-retroactive design.
- Construct-parity warnings from the pipeline land on the run summary (surface = Plan 4's desk; for now they ride `RunSummary`).

- [ ] Steps: failing tests (ingest writes through the pipeline — census from Task 1 already guards the path; query minted with author name + language + live anchor; vanished-¶id query goes doc-scoped; role minted on first run, found on second; shutdown called from every window-ending path — census the call sites the compiler uses and assert the sibling), implement, gate, commit — `feat: a translation run mints its words and its questions through the writer's own doors`

---

### Task 6: The allowlist learns to read the brief

**Files:**
- Modify: `Maugham/Compiler/CompilerAllowlist.swift` (`tools`, `CompilerAllowlist.swift:8` — add `mcp__maugham__read_edition_brief`)
- Test: extend `CompilerAllowlistTests` (its census + planted-offender conventions)

**Contract.** The spawned translator reads the brief through the bridge like every other read. The census that matters — no statement-WRITING tool in allowlist or catalogue — is untouched and must still pass with its planted offender. The pinned tool-list test gains the entry.

- [ ] Steps: failing pinned-list test, one-line add, gate, commit — `feat: the spawned session may read the edition brief`

---

### Task 7: Docs

**Files:**
- Modify: `Maugham/Compiler/AREA.md` (the translator is the compiler area's second orchestrator — a section: rails shared, report/briefing/ingest shapes, the shutdown contract's new owner), `docs/roadmap.md` (P2 shipped under the milestone entry; loops still reachable only headless until P4 — say so honestly), `Maugham/MCP/AREA.md` only if Task 1 moved where write_translation's logic lives in a way its prose describes.

- [ ] Steps: grep for falsified claims, edit, fast gate (DocSyncTests), commit — `docs: the translator's loop is on the record`

---

## Self-review notes (applied)

- Spec §2 coverage: work-list=coverage ✓ (T3/T5), briefing contents ✓ (T3), confinement/shutdown ✓ (T4/T5/GC), report→ingest shared path ✓ (T1/T5), queries as authored annotations ✓ (T5), no rounds ring ✓ (structural — nothing built), keystroke-only ✓ (trigger arrives in P4's desk; the verb exists, no timer exists).
- Deliberately absent: any UI (P4), `delete` on the wire (writer's act), translator preset briefs (spec §2's briefing IS the role frame; `ProductionRole.brief` stays writer-editable and rides `Inputs` when set — T3 must include it in `compose` when non-nil. Added to T3's contract here: include `effectiveBrief` when the role carries one).
- Type consistency: `TranslatorReport` / `TranslatorBriefing.Inputs` / `TranslationWritePipeline.perform` spelled once each; consumers point at defining tasks.
