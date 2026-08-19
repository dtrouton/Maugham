# Publish Department P1 — The Cast and the Brief

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The foundations of the publish department: `ProductionRole` (translator-per-language + designer) on the manifest, the edition brief as the third statement kind with `RulingPerformer` able to write rulings into it, and the MCP reads — so Plan 2 (translator loop) and Plan 3 (designer loop) build against real types.

**Architecture:** Everything follows an existing pattern with a verified precedent: `ProductionRole` is `ReviewPass`'s shape stored the way `reviewPasses` is (manifest section, schema bump, `effective*` fallbacks); the edition brief is one more `Statement.Kind` case riding M1A's statement machinery end to end (convention row → `createStatement` → `statementText(of:)` → a kind-specific MCP reader); `RulingPerformer`'s four verbs widen from hardcoded `.intent` to an explicit kind.

**Tech Stack:** Swift / MaughamCore SPM + Mac target. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-08-19-publish-department-design.md` (§1 the cast, §4 the edition brief, §5's MCP rows). Plans 2+ (translator loop, designer loop, department desk) are deliberately **unwritten** — workflow rule 11: re-derive them against this plan's built code.

## Global Constraints

- **Schema: 7 → 8, and the milestone becomes a paired Mac+phone release.** Two independent causes, one bump: the `productionRoles` manifest section (an older build re-saving the manifest would silently drop it — the 5→6 `reviewPasses` precedent, `ProjectManifest.swift:43`), and the new `Statement.Kind` case. The bump lands ONCE, in Task 3, with a contract comment in `currentSchemaVersion`'s ledger. The pairing binds at the milestone's release, not this plan's merge (ship-whole-milestones).
- **Never read `name`/`brief`/`editorName` raw** — every reader goes through `effective*` (the `ReviewPass` lesson, `ReviewPass.swift:20-61`).
- **Statement text derives, never the `.md`** (tripwire 20): every reader goes through `ProjectStore.statementText(of:)` (`ProjectStore+Statements.swift:79`).
- **Statement minting has ONE path**: `ProjectStore.createStatement(kind:scope:)` (`ProjectStore+Statements.swift:205`). No second spelling.
- **MCP tool counts derive from `MCPToolCatalog.all`**, never prose (this plan moves 55 → 56).
- **Disable experiment on every negative assertion**: remove the guard, watch the test fail, restore, report the output in the commit or task report.
- Build flow: `./gen.sh` after `Package.swift`/`project.yml` changes; iterate with `swift test --parallel --package-path Packages/MaughamCore` for Core tasks and `./scripts/test.sh` for Mac tasks; `./scripts/test.sh full` before merge.

---

### Task 1: `Statement.Kind.editionBrief` (MaughamCore)

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/Statement.swift` (the `Kind` enum, lines 33–66)
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/StatementTests.swift` (find the existing Kind round-trip tests and extend beside them)

**Interfaces:**
- Consumes: nothing new.
- Produces: `Statement.Kind.editionBrief(String)` — associated value is the lowercase language tag; `rawValue` is `"edition_brief:<lang>"`. Tasks 2, 4, 5, 6, 7 all consume this case.

**Contract.** Mirror `Scope.document`'s parameterized pattern (`Statement.swift:85-120`), inside `Kind`'s hand-written Codable:

- raw form `edition_brief:<lang>`, split on the **first** colon;
- `"edition_brief:"` with an empty language decodes to `.unknown(raw)` — a kind that matches nothing while looking valid must not mint (the exact reasoning `Scope`'s doc comment gives at `Statement.swift:74-77`);
- any unrecognised raw still round-trips **losslessly** through `.unknown(raw)` — this enum is the lossless `ResearchRole` variety, keep it that way.

The case itself is mechanical enough for literal code:

```swift
case editionBrief(String)   // language tag, e.g. "es"
private static let editionBriefPrefix = "edition_brief:"
```

- [ ] **Step 1: Write the failing tests** — in the Core test file: (a) `.editionBrief("es")` encodes to `"edition_brief:es"` and decodes back equal; (b) `"edition_brief:"` decodes to `.unknown("edition_brief:")` and re-encodes verbatim; (c) `"edition_brief:pt-br"` survives whole (a tag containing a hyphen, and — separate assertion — a raw containing a second colon splits on the first only); (d) an old-style unknown raw is untouched.
- [ ] **Step 2: Run to verify they fail** — `swift test --parallel --package-path Packages/MaughamCore --filter StatementTests`. Expected: compile failure on the missing case, then assertion failures.
- [ ] **Step 3: Implement** the case + decoder/encoder arms against the real file.
- [ ] **Step 4: Run to verify pass**, plus the whole Core suite (`swift test --parallel --package-path Packages/MaughamCore`) — the exhaustive switches elsewhere (`Promotion.kindTitle` is Mac-side, Task 5) will surface every Core site the compiler wants updated; update them minimally (preserve-and-ignore semantics, no behavior).
- [ ] **Step 5: Commit** — `feat(core): Statement.Kind.editionBrief — the third statement kind`

---

### Task 2: The convention row and lookup (MaughamCore)

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/StatementLookup.swift` (`StatementConvention.newPath`, lines 38–52, and the storage table doc comment at the top)
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/StatementLookupTests.swift` (or wherever `newPath` is currently pinned — grep `newPath` under `Packages/MaughamCore/Tests` and extend that file)

**Interfaces:**
- Consumes: `Statement.Kind.editionBrief` (Task 1).
- Produces: `StatementConvention.newPath(kind: .editionBrief(lang), scope: .project, documentSlug: nil)` → `"editions/<lang>.md"`; plus `StatementConvention.editionsFolder = "editions"` for the table. Task 5's creation path consumes this.

**Contract.** New table row: `(.editionBrief(lang), .project)` → `editions/<lang>.md` — content in the open at the project root, like every statement. Any other scope for the kind returns nil (edition briefs are project-scope only, same posture as visual language). An empty language cannot arrive from decode (Task 1) but can be constructed in memory: return nil for it, matching the empty-slug guard one arm up. `StatementLookup.statement(in:kind:scope:)` needs **no change** — kind equality already discriminates languages — but pin that with a test anyway (two briefs, `es` and `fr`, each found by its own kind; this is the assertion that fails if someone later "simplifies" Kind equality).

- [ ] **Step 1: Write the failing tests** — the path row for `es`; nil for `.document` scope; nil for empty language; the two-brief lookup discrimination test.
- [ ] **Step 2: Run to verify fail** (Core filter as Task 1).
- [ ] **Step 3: Implement** the row + folder constant; update the doc-comment table.
- [ ] **Step 4: Run to verify pass** (full Core suite).
- [ ] **Step 5: Commit** — `feat(core): edition briefs live at editions/<lang>.md`

---

### Task 3: `ProductionRole` + the manifest section + schema 8 (MaughamCore)

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/ProductionRole.swift`
- Modify: `Packages/MaughamCore/Sources/MaughamCore/ProjectManifest.swift` (`currentSchemaVersion` ledger comment ~line 30ff; stored properties ~line 126ff; `init`, `init(from:)`, `encode` — follow `reviewPasses` at lines 138, 208, 223, 253 exactly)
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/ProductionRoleTests.swift` (create); extend the existing manifest schema/round-trip tests (grep `reviewPasses` under `Packages/MaughamCore/Tests` and sit beside them)

**Interfaces:**
- Consumes: nothing new.
- Produces (consumed by Tasks 4, 8 and by Plans 2/3):
  - `struct ProductionRole: Codable, Equatable, Identifiable, Sendable` with `id: String`, `role: Role`, `name: String?`, `brief: String?`
  - `enum Role: Codable, Equatable, Sendable { case translator(language: String); case designer; case unknown(String) }` — single-string on-disk form: `"translator:<lang>"` / `"designer"`, lossless `.unknown`, the `Statement.Scope` pattern
  - `var effectiveName: String` and `var effectiveBrief: String?` — never-read-raw fallbacks
  - `static func defaultTranslatorName(language: String) -> String?` — the preset table: `es` → `"Cortázar"`, `fr` → `"Baudelaire"`, `de` → `"Tieck"`, `ja` → `"Motoyuki"`; nil for an unlisted language (the caller asks the writer)
  - `static let presetDesigner: ProductionRole` — `role: .designer`, name `"Tschichold"`, and a designer brief (see below)
  - `ProjectManifest.productionRoles: [ProductionRole]` (decodeIfPresent ?? [])
  - `ProjectManifest.effectiveProductionRoles: [ProductionRole]` — the stored list, **with `presetDesigner` prepended when no stored role is a designer** (the designer exists from the start; `effectiveReviewPasses` at `ProjectManifest.swift:146` is the precedent, but here the preset *merges* rather than replaces, because minted translators must survive alongside the preset designer)

**Contract.**

- `effectiveName`: `name`, else — for `.designer` — `presetDesigner`'s name, else — for `.translator` — `defaultTranslatorName(language:)`, else the raw language tag uppercased as last resort (never empty). `effectiveBrief`: `brief`, else the matching preset brief (designer only in this plan; translator preset briefs arrive with Plan 2's briefing work — leave nil, spec §2 owns their content).
- Designer preset brief (spec §1, verbatim intent): reads the visual language statement before proposing anything; designs the page, not the decoration; one spec, demonstrated in sample pages, accounting for every element the manuscript actually contains. Write it as writer-facing prose, 3–5 sentences, stored as the preset's `brief`.
- Schema ledger entry, in `currentSchemaVersion`'s doc comment, stating BOTH causes (new section that an old build's re-save would silently drop; new `Statement.Kind` case) and that it makes the milestone a paired release — the 5→6 entry at `ProjectManifest.swift:43` is the template.
- `decodeGuardingSchema` needs no code change — it compares against `currentSchemaVersion` — but the refusal must be pinned for 8: find the existing refusal test (grep `decodeGuardingSchema` in Core tests) and confirm it's version-relative, not hardcoded to 7; fix if hardcoded.

- [ ] **Step 1: Write the failing tests** — Role raw round-trips (`translator:es`, `designer`, unknown lossless, empty-language → unknown); `effectiveName` fallback chain including the unlisted-language last resort; `effectiveProductionRoles` prepends the preset designer only when absent; manifest round-trip with two roles; a schema-7 manifest (no key) decodes to `[]`.
- [ ] **Step 2: Run to verify fail.**
- [ ] **Step 3: Implement** — the new file, the manifest section, the schema bump + ledger comment.
- [ ] **Step 4: Run the full Core suite AND the phone suite** (`xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone -destination 'platform=iOS Simulator,name=iPhone 17' test CODE_SIGNING_ALLOWED=NO`) — the phone shares `ProjectManifest`; a hardcoded schema expectation in its tests fails here, and this step is where we find it, not at release.
- [ ] **Step 5: Commit** — `feat(core): ProductionRole on the manifest — schema 8, pairs at milestone release`

---

### Task 4: The translator mint and the designer accessor (Mac store)

**Files:**
- Create: `Maugham/Stores/ProjectStore+ProductionRoles.swift`
- Test: `MaughamTests/ProductionRoleStoreTests.swift` (create; model harness setup on a small existing `ProjectStore` test — grep `saveManifest` under `MaughamTests` for one that builds a temp project)

**Interfaces:**
- Consumes: Task 3's types.
- Produces (consumed by Task 8 and Plans 2/3):
  - `func translatorRole(for language: String) async throws -> ProductionRole` — find-or-create against `manifest.productionRoles`, minting with `defaultTranslatorName` (or, when the table has no row, name nil — `effectiveName`'s last resort covers display until the writer names them; the mint *sheet* is desk-plan work, not this plan's); persists via `saveManifest()`; idempotent
  - `func designerRole() -> ProductionRole` — the stored designer, else `ProductionRole.presetDesigner` (read-only: never writes the preset back; `effectiveReviewPasses`' posture)
  - `func renameProductionRole(id: String, to name: String) async throws` — writer's rename, trimmed, empty refused

**Contract.** The retroactive mint (spec §1 — Volumen Uno's `es`) is **lazy**: nothing scans at load. The first caller asking for `es`'s translator mints it. That makes "retroactive" free and keeps project load untouched. Read paths (Task 8's `translation_status`) must NOT mint — they use `manifest.productionRoles` lookup + `defaultTranslatorName` for display, never `translatorRole(for:)`. State this in the file's doc comment; it is the difference between a read tool and a write tool.

- [ ] **Step 1: Write the failing tests** — mint once / find second time (same id); preset name lands for `es`; unlisted language mints with nil name and non-empty `effectiveName`; `designerRole()` answers preset without touching the manifest (assert manifest file bytes unchanged — the disable experiment target: make it write the preset back, watch this fail); rename round-trips, empty rename throws.
- [ ] **Step 2: Run to verify fail** — `./scripts/test.sh` (or `-only-testing:MaughamTests/ProductionRoleStoreTests` while iterating).
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to verify pass.**
- [ ] **Step 5: Commit** — `feat: translator roles mint lazily; the designer is always there`

---

### Task 5: The brief exists — creation, title, text (Mac)

**Files:**
- Modify: `Maugham/Canvas/Promotion.swift` (`kindTitle`, line ~416 — the exhaustive switch the compiler flagged in Task 1's Mac build)
- Test: `MaughamTests/EditionBriefStatementTests.swift` (create)

**Interfaces:**
- Consumes: Tasks 1–2; `ProjectStore.createStatement(kind:scope:)` (`ProjectStore+Statements.swift:205`, verified find-or-create, the ONLY minting path); `statementText(of:)` (`:79`).
- Produces: nothing new in code — this task proves the existing machinery carries the new kind end to end, and gives the kind its writer-facing name: `kindTitle(.editionBrief(lang))` → `"Edition Brief · <lang>"` (`.unknown` keeps its raw-string arm untouched).

**Contract.** No new store code should be needed: `createStatement` walks `StatementConvention.newPath` (Task 2's row), `documentSlug(for: .project)` is the visual-language path already. If implementation reveals otherwise, that's a finding to report, not silently patch around.

- [ ] **Step 1: Write the failing tests** — (a) `createStatement(kind: .editionBrief("es"), scope: .project)` creates `editions/es.md`, registers in `manifest.statements`, and a second call returns the same statement (find-or-create); (b) `statementText(of:)` on the fresh brief answers empty without throwing; (c) `kindTitle` spells `"Edition Brief · es"`; (d) `statementTitlePairs()` (`ProjectStore+Statements.swift:93`) includes the brief under that title.
- [ ] **Step 2: Run to verify fail** (the `kindTitle` arm won't exist / the switch won't compile).
- [ ] **Step 3: Implement** the `kindTitle` arm (and ONLY that; see contract).
- [ ] **Step 4: Run to verify pass.**
- [ ] **Step 5: Commit** — `feat: the edition brief is mintable and has a name`

---

### Task 6: `RulingPerformer` learns a second destination (Mac)

**Files:**
- Modify: `Maugham/Compiler/RulingPerformer.swift` (all four verbs: `rule` at line 130, `revoke` 162, `edit` 197, `restore` 244, plus private `mutate` 264 and the `statement(kind:scope:)` resolutions inside)
- Modify: every production caller of the four verbs (census first: `grep -rn "RulingPerformer\." Maugham --include="*.swift"` — update each to pass `.intent` explicitly)
- Test: extend the existing `RulingPerformer` tests (grep for them) + new cases in the same file

**Interfaces:**
- Consumes: Tasks 1–2, 5.
- Produces (consumed by Plan 2's query-answer disposition): all four verbs gain `kind: Statement.Kind` as the parameter **before** `forScope`, undefaulted — the file's own philosophy (`world` is "explicit and undefaulted... a defaulted parameter would let a new call site skip it in silence") applies verbatim to the destination kind.

**Contract.**

- Every internal `statement(kind: .intent, scope:)` / `createStatement(kind: .intent, ...)` resolution threads the parameter instead.
- `invalidate(_:in:)` (line 288) drops the `DeclaredWorldStore` cache by scope: an edition-brief ruling passes `world: nil` today (no derived world reads briefs yet); leave `invalidate`'s signature alone.
- The doc comment's "no project-scope fallback" reasoning is about SCOPE and is untouched — an edition brief is project-scope by nature, which is not a fallback, it's the address.
- Behavior for `.intent` is bit-for-bit unchanged — the existing test suite passing UNMODIFIED (except call-site signatures) is the assertion.

- [ ] **Step 1: Write the failing tests** — `rule(_:provenance:kind: .editionBrief("es"), forScope: .project, ...)` mints `editions/es.md` when absent and appends under `## Rulings` with the dated shape (assert via `RulingsSection.parse`); `revoke`/`edit`/`restore` round-trip on the brief; an unreadable existing brief refuses before minting (`refuseIfTheWordsCannotBeRead`, line 313 — **disable experiment**: comment the guard call out, watch the refusal test fail, restore, report).
- [ ] **Step 2: Run to verify fail** (won't compile — the parameter doesn't exist).
- [ ] **Step 3: Implement** — widen the verbs, thread the kind, update the caller census to `.intent`.
- [ ] **Step 4: Run to verify pass** — the full existing RulingPerformer suite + new cases, then `./scripts/test.sh`.
- [ ] **Step 5: Commit** — `feat: rulings can land in an edition brief — one performer, two destinations`

---

### Task 7: `read_edition_brief` (MCP, 55 → 56)

**Files:**
- Create: `Maugham/MCP/Tools/EditionBriefTools.swift` (mirror `Maugham/MCP/Tools/VisualLanguageTools.swift` — verified reader shape at its lines 60–64: resolve project entry, `StatementLookup` via `entry.store`, `statementText(of:)`, absence is a valid non-error answer)
- Modify: `MCPToolCatalog.all` (one entry; both list handler and registration derive from it)
- Modify: `Maugham/MCP/AREA.md` (tool list + count), `CLAUDE.md`'s MCP row (55 → 56 with the same "count the catalogue" hedge it already carries)
- Modify: `docs/skills/maugham-bootstrap/SKILL.md` — the outside-translator protection: a section telling a Claude about to run a translation to call `read_edition_brief` first, the exact shape of the visual-language section already there (spec §5)
- Test: `MaughamTests/` beside the existing `VisualLanguageTools` tests (grep and sit next to them); the tools-list count test should already derive from the catalog (publish-pipeline lesson) — verify, don't add a literal

**Interfaces:**
- Consumes: Tasks 1–2, 5.
- Produces: MCP tool `read_edition_brief` — params `project_id`, `language`; response carries `markdown` (the brief's derived text), `exists: Bool`, and the language echoed back. No document scope (edition briefs are project-scope only). Fails loudly on unknown project id, like every tool.

**Contract.** Absence is deliberate and valid — `exists: false` with empty markdown and a sentence saying a brief can be created in Maugham, NOT an error (the `read_craft_intent` posture quoted at `StatementLookup.swift:70-73`). The reader never mints. Tool description tells Claude what an edition brief IS (register, idiom policy, rulings) and that answers to translation queries may already be rulings inside it.

- [ ] **Step 1: Write the failing tests** — reads a seeded brief's text through the derived path; `exists: false` on absence (no file created as a side effect — assert the `editions/` folder is untouched); unknown project fails loudly; tools-list includes it (via catalog derivation).
- [ ] **Step 2: Run to verify fail.**
- [ ] **Step 3: Implement** tool + catalog entry + doc/skill edits (docs in the same commit — rule: when a capability flips, sweep sibling docs).
- [ ] **Step 4: Run to verify pass** — `./scripts/test.sh` (MCP tests live in the Mac scheme).
- [ ] **Step 5: Commit** — `feat(mcp): read_edition_brief — the department's doctrine is readable from outside (56 tools)`

---

### Task 8: `translation_status` names the translator (MCP widening)

**Files:**
- Modify: `Maugham/MCP/Tools/TranslationTools.swift` (the status handler's per-language row assembly — the language union at its line ~346–362)
- Test: extend the existing `translation_status` tests (grep the tool name under `MaughamTests`)

**Interfaces:**
- Consumes: Task 3's `defaultTranslatorName` + Task 4's lookup discipline.
- Produces: each per-language row gains `"translator": <name>` — the stored role's `effectiveName` when one exists, else `ProductionRole.defaultTranslatorName(language:)`, else omitted (an unlisted, unminted language has no honest name to report; omission tells Claude to expect the writer to name them).

**Contract.** **A read tool must not mint** (Task 4's doc-comment rule): this is a pure lookup over `manifest.productionRoles` + the preset table — never `translatorRole(for:)`. Disable experiment: swap the lookup for the minting call in a scratch build, watch the bytes-unchanged assertion fail, restore. Widening an existing read — the tool count does not move (the established pattern: `list_canvas` provenance, `piece_references`).

- [ ] **Step 1: Write the failing tests** — a project with a stored renamed `es` role reports the rename; an unminted `es` with translation files reports `"Cortázar"` without writing the manifest (assert manifest unchanged on disk); an unlisted unminted language omits the field.
- [ ] **Step 2: Run to verify fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to verify pass**, then `./scripts/test.sh full` (this is the plan's last code task — the pre-merge gate).
- [ ] **Step 5: Commit** — `feat(mcp): translation_status says who the translator is`

---

### Task 9: Docs close the loop

**Files:**
- Modify: `CLAUDE.md` (MCP row count done in Task 7 — verify; add the schema-8/paired-release note to wherever the standing schema-7 pairing note lives), `Maugham/Compiler/AREA.md` (RulingPerformer's widened signature — its cell describes the one-door membrane), `Maugham/Stores/AREA.md` (the new peer extension file), `docs/roadmap.md` (the milestone's entry, P1 status)
- No guide topic yet — the writer-facing department guide ships with the desk plan (docs describe what ships; nothing writer-visible shipped here except the brief's name in link/title surfaces).

**Interfaces:** none — prose only, and every count stated as "count the source" with the source named.

- [ ] **Step 1: Sweep** — grep each doc for claims this plan falsified (`grep -rn "55 tools" docs CLAUDE.md`; `grep -rn "forScope" docs */AREA.md`).
- [ ] **Step 2: Edit** the four files.
- [ ] **Step 3: Run** `./scripts/test.sh` once more (DocSyncTests and TripwireGrepTests read docs).
- [ ] **Step 4: Commit** — `docs: the department's foundations are on the record`

---

## Self-review notes (already applied)

- **Spec coverage for P1's slice:** §1 cast → Tasks 3–4; §4 brief/rulings/reader → Tasks 1–2, 5–7; §5's `translation_status` row → Task 8; §4's schema plan-time gate → answered (schema 8, paired, Task 3). §2/§3/§5-desk are Plans 2+, deliberately.
- **Volumen Uno seeding** (spec §4) is a writer act post-milestone, not a task.
- **Type consistency:** `editionBrief(String)` / `translator(language: String)` / `defaultTranslatorName(language:)` spelled identically in every task that names them; later tasks point at defining tasks rather than restating signatures.
- **No placeholder scan:** every step names its assertions or the exact file/pattern to extend; literal code only for the two mechanical enum cases.
