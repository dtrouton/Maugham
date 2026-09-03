# Translation Pipeline — Plan 5: Proposals into Statements — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a Claude Desktop session draft an edition brief or a visual-language statement as a **proposal** the writer adopts or discards at a gate with a diff — never as a write — with the two tools, the derived store, the gate in `StatementPane`, the "proposed" marks, the two interview skills, and the docs that say it ships.

**Architecture:** Spec §10 exactly. `propose_edition_brief` / `propose_visual_language` join `MCPToolCatalog.all` (56 → 58) mirroring the two read tools' shape; each validates and **stages** a `StatementProposalStore.Proposal` under `.maugham/statements/proposals/<key>.json` (one pending slot per key — a new proposal supersedes) and posts `.maughamStatementProposalsChanged` (project scope, tripwire 21). Nothing here writes a statement: the only write is **Adopt**, a writer's click in `StatementPane`, performed by `StatementProposalGate.adopt` through `ProjectStore.mutateStatementText` (one op, undoable via `OpUndoRegistrar`) with `StatementEssay.recomposed` so the `## Rulings` tail is byte-identical, then one `RulingPerformer.rule` per glossary line the proposal carries (the same door every other ruling uses). `ProposableStatement` is a two-case enum, so craft intent is unrepresentable. The desk's language row and the Visual Language picker segment carry a "proposed" mark read off the same store. No new `AnnotationKind`, no new session owner, no change to `CompilerAllowlist`.

**Tech Stack:** Swift 6 / SwiftUI / AppKit (macOS 26), XCTest, the Mac scheme (`./scripts/test.sh`), `MaughamCore` for `Ruling`/`RulingsSection`/`Statement`.

**Spec:** `docs/superpowers/specs/2026-08-28-translation-pipeline-design.md` — §10 (the whole of this plan), §3.1 (glossary lines are what Adopt appends), §12's "Proposals" and "Census and pins" bullets, §13 item 5, §14. Read the P4 handoff first: `docs/superpowers/notes/2026-08-29-translation-pipeline-p4-handoff.md`, "The seams Plan 5 wires to". ADR 0030 §7 records this plan as designed and NOT built — Task 8 amends it in the commit that makes it true.

## Global Constraints

- **Point at P1–P4's API by file; never restate it.** `Statement.Kind`/`.Scope` (`Packages/MaughamCore/Sources/MaughamCore/Statement.swift`), `RulingsSection.parse/render/appending` and `Ruling` (`.../RulingsSection.swift`), `Ruling.glossary`/`.glossaryText(term:rendering:note:)`/`Ruling.Provenance.glossary` (`.../RulingShapes.swift`), `StatementEssay.half(of:)`/`.recomposed(essay:into:)`/`.carriesRulings(_:)` (`Maugham/Compiler/StatementEssay.swift`), `ProjectStore.statement(kind:scope:)`/`createStatement(kind:scope:)`/`statementText(of:)`/`mutateStatementText(of:session:transform:)` (`Maugham/Stores/ProjectStore+Statements.swift`), `RulingPerformer.rule(_:provenance:kind:forScope:store:world:)` (`Maugham/Compiler/RulingPerformer.swift`), `OpUndoRegistrar.register(_:actionName:target:workTaskSink:undo:redo:)` (`Maugham/OpLog/OpUndoRegistrar.swift`), `MaughamEvent.post(_:to:payload:)` + `.onProjectEvent(_:url:window:perform:)` (`Maugham/Events/`), `MCPTool`/`decodeParams`/`resolveProject`/`MCPError.invalidArgument` (`Maugham/MCP/`), `TranslationRecord.isValidLanguageTag(_:)`, `TranslationReviewIndicator.displayLabel(forLanguageTag:)`, `DesignProposalStore` (`Maugham/Stores/DesignProposalStore.swift` — the derived-JSON-under-`.maugham/` precedent this plan's store copies), `StatementMountFixture` (`MaughamTests/StatementMountFixture.swift`).
- **A proposal never writes a statement** (ADR 0030 §7/§8). The two tools stage and post; the ONLY statement write in this plan is `StatementProposalGate.adopt`, reached from a button in `StatementPane`. `CompilerAllowlist.tools` is untouched; `CompilerAllowlistTests.test_noStatementWritingToolExistsAnywhereClaudeCanReach` stays green and gets stronger (Task 2).
- **`ProposableStatement` has exactly two cases** — `.editionBrief(String)` and `.visualLanguage`. No `.intent`, no `.unknown`. Craft intent is unrepresentable, not refused.
- **Adopt preserves the `## Rulings` stratum byte-for-byte** for the essay replacement (`StatementEssay.recomposed`'s identity on the tail), and appends glossary lines only through `RulingPerformer.rule` — which renders the section canonically, exactly as every other ruling write does. A proposal's `## Rulings` section may hold **only glossary-shaped lines** (`Ruling.glossary != nil`, term and rendering non-empty after trimming); anything else refuses at the tool AND at Adopt with the same sentence. A visual-language proposal may not carry a `## Rulings` section at all (visual language has no strata).
- **Everything under `.maugham/statements/` is derived.** Deleting it costs a proposal Claude would have to make again and never a word the writer wrote. Every disk read of a proposal carries `// adr-0018-ok: statement proposal, derived sidecar` (the tripwire that bit P3). `MaughamSidecarPath` needs no new case: `.maugham/statements/…` falls to `.unknownSidecar`, as `.maugham/design/` and `.maugham/translations/` already do — do NOT add a route.
- **Tripwire 4:** no disk read on a `body` path. `StatementPane`, `DepartmentPaneHost` and `DetailPaneToggle` read the store in a `.task` and re-read on `.maughamStatementProposalsChanged`; `DepartmentPane` takes values (its `test_theSourceReadsNoStoreAtAll` census forbids a store name on its path — `StatementProposalStore` joins that forbidden list in Task 6).
- **Tripwire 21:** the new notification is posted only through `MaughamEvent.postStatementProposalsChanged(projectURL:)` and received only through `.onProjectEvent`.
- **Tripwire 15:** every `ContentUnavailableView` chains `.frame(maxWidth: .infinity, maxHeight: .infinity)`. **Tripwire 9:** `Button`, never `.onTapGesture`.
- **Global Constraint 2 of the publish-department spec:** a verb that cannot act says why, in words, in the surface's notice line — never a silent no-op.
- **No `keyboardShortcut` on Adopt or Discard.**
- **Copy lives in statics** (`StatementProposalCopy`, `DepartmentDesk`), so every sentence is assertable with nothing mounted.
- **Every implementer's pre-commit list**, beyond the task's own suites: `-only-testing:MaughamTests/TripwireGrepTests` and `-only-testing:MaughamTests/AnnotationChangeEventTests`; plus `-only-testing:MaughamTests/DocSyncTests` and `-only-testing:MaughamTests/CompilerAllowlistTests` for any task touching the catalogue or docs (Tasks 2, 7, 8). A task that adds a source or test file runs `./gen.sh` before any `xcodebuild`. Run tests in the **foreground** only.
- **Worktree guard:** one command per Bash call, absolute paths, no `git -C`, no compound commands.
- **Reviews:** opus for Tasks 3, 4, 5 (the write path, `StatementPane`, the catalogue); a local Release build after any `ProjectWindow.body` change (none is planned — if one becomes necessary, say so in the report). Reviewer reports under ~80 lines, Issues first.
- **Count `MCPToolCatalog.all` for the new total; never trust a number in prose.** The expected total is 58; `DocSyncTests.test_toolCountSyncedAcrossDocsAndCatalog` reads CLAUDE.md's `**NN tools**` and `Maugham/MCP/AREA.md`'s `## Tool catalogue (NN)`.

## File structure

| File | Responsibility |
|---|---|
| `Maugham/Stores/StatementProposalStore.swift` (create) | `ProposableStatement`, `Proposal`, `ProposalRefusal`, validation, the one-slot-per-key store over `.maugham/statements/proposals/` |
| `Maugham/Models/MaughamNotifications.swift`, `Maugham/Events/MaughamEvent.swift` (modify) | `.maughamStatementProposalsChanged` (project scope) + its one post helper |
| `Maugham/MCP/Tools/StatementProposalTools.swift` (create) | `ProposeEditionBriefTool`, `ProposeVisualLanguageTool` |
| `Maugham/MCP/MCPTool.swift` (modify) | Two catalogue entries |
| `Maugham/Compiler/StatementProposalGate.swift` (create) | `adopt` (the one write) + `discard`, the undo registration, the copy |
| `Maugham/Views/StatementProposalDiff.swift` (create) | Pure line diff of proposal vs current |
| `Maugham/Views/StatementProposalBanner.swift` (create) | The value-taking gate view: banner, diff, Adopt / Discard, notice |
| `Maugham/Views/StatementPane.swift` (modify) | Reads the slot in a `.task`, re-reads on the event, mounts the banner above the editor |
| `Maugham/Views/Publish/DepartmentPane.swift`, `DepartmentPaneHost.swift` (modify) | The "proposed" mark on a language row; a proposal for a language with no row |
| `Maugham/Views/DetailPaneToggle.swift` (modify) | The "proposed" badge over the Visual Language segment |
| `docs/skills/edition-brief/SKILL.md`, `docs/skills/visual-language/SKILL.md` (create); `docs/skills/maugham-bootstrap/SKILL.md`, `docs/skills/translation-pass/SKILL.md` (modify) | The two interview skills and the two pointers |
| `MaughamTests/CompilerAllowlistTests.swift`, `SkillIndexTests.swift`, `DocSyncTests`-checked docs | Census widening, the served-skills list, the counts |
| `docs/guide/right-pane.md`, `publish-department.md`, `claude-desktop.md`, `docs/roadmap.md`, `docs/adr/0030-…md`, `Maugham/{MCP,Views,Stores,Compiler}/AREA.md`, `CLAUDE.md`, `docs/superpowers/notes/2026-09-02-translation-pipeline-p5-handoff.md` | Docs |

---

### Task 1: `StatementProposalStore` — the two-case kind, validation, one slot per key, the event

**Files:**
- Create: `Maugham/Stores/StatementProposalStore.swift`
- Modify: `Maugham/Models/MaughamNotifications.swift` (append after `maughamDesignProposalsChanged`, the last member), `Maugham/Events/MaughamEvent.swift` (after `postDesignProposalsChanged`, ~line 132)
- Test: create `MaughamTests/StatementProposalStoreTests.swift`

**Interfaces:**
- Consumes: `Statement.Kind`, `RulingsSection.parse`, `Ruling.glossary`, `TranslationRecord.isValidLanguageTag`, `MaughamEvent.post`, `EventScope.project(for:)`.
- Produces (later tasks rely on these exact names):
  - `enum ProposableStatement: Equatable, Hashable, Codable, Sendable { case editionBrief(String); case visualLanguage }` with `var statementKind: Statement.Kind`, `var key: String` (`"visual-language"` / `"edition-brief-<lowercased tag>"`), `var displayName: String` (`"visual language"` / `"<Language> edition brief"` via `TranslationReviewIndicator.displayLabel`), `init?(kind: Statement.Kind)` (nil for `.intent`/`.unknown`).
  - `struct StatementProposalStore.Proposal: Codable, Equatable, Sendable { let kind: ProposableStatement; let markdown: String; let rationale: String?; let proposedAt: Date; let author: String }` — `author` is always `"Claude"` today; stored so the banner never hard-codes a byline.
  - `enum StatementProposalStore.ProposalRefusal: Error, Equatable, CustomStringConvertible { case emptyMarkdown; case rulingsNotGlossary(line: String); case emptyGlossaryTerm(line: String); case visualLanguageCarriesRulings; case invalidLanguageTag(String) }`
  - `static func StatementProposalStore.glossaryLines(in markdown: String) throws(ProposalRefusal) -> [(term: String, rendering: String, note: String?)]` — parses the proposal's `## Rulings` section and refuses anything not glossary-shaped or with an empty term/rendering.
  - `static func StatementProposalStore.validate(kind: ProposableStatement, markdown: String) throws(ProposalRefusal)`
  - `struct StatementProposalStore { let projectURL: URL; init(projectURL:); static func directoryURL(in:) -> URL; static func fileURL(key:in:) -> URL; func pending(for: ProposableStatement) -> Proposal?; func pendingAll() -> [Proposal]; func stage(_:) throws -> Proposal (validates, overwrites the slot); func discard(_ kind: ProposableStatement) throws }` — `@MainActor`, a struct over `projectURL` like `DesignProposalStore`.
  - `Notification.Name.maughamStatementProposalsChanged` (`"maugham.statement.proposals.changed"`, scope `.project`, no payload); `MaughamEvent.postStatementProposalsChanged(projectURL: URL)`.

- [ ] **Step 1: Write the failing tests**

Create `MaughamTests/StatementProposalStoreTests.swift`:

```swift
import XCTest
@testable import Maugham
import MaughamCore

/// The derived slot a Claude Desktop draft waits in until the writer adopts or
/// discards it (translation pipeline spec §10). One pending proposal per key;
/// craft intent is UNREPRESENTABLE here rather than refused at runtime.
@MainActor
final class StatementProposalStoreTests: XCTestCase {
    private var temp: TempDirectory!
    override func setUp() async throws { temp = try TempDirectory() }
    override func tearDown() async throws { temp = nil }

    private var store: StatementProposalStore { StatementProposalStore(projectURL: temp.url) }

    // MARK: - The kind

    func test_theKindHasExactlyTwoCasesAndCraftIntentIsUnrepresentable() {
        XCTAssertNil(ProposableStatement(kind: .intent))
        XCTAssertNil(ProposableStatement(kind: .unknown("later")))
        XCTAssertEqual(ProposableStatement(kind: .visualLanguage), .visualLanguage)
        XCTAssertEqual(ProposableStatement(kind: .editionBrief("es")), .editionBrief("es"))
        XCTAssertEqual(ProposableStatement.visualLanguage.statementKind, .visualLanguage)
        XCTAssertEqual(ProposableStatement.editionBrief("es").statementKind, .editionBrief("es"))
    }

    func test_theKeyIsAFilenameNotARawValue() {
        XCTAssertEqual(ProposableStatement.visualLanguage.key, "visual-language")
        XCTAssertEqual(ProposableStatement.editionBrief("pt-br").key, "edition-brief-pt-br")
        XCTAssertEqual(ProposableStatement.editionBrief("ES").key, "edition-brief-es",
                       "the tag is lowercased so a badly-cased proposal lands in the same slot")
        XCTAssertFalse(ProposableStatement.editionBrief("es").key.contains(":"),
                       "a colon in a filename is hostile on every filesystem the writer syncs to")
    }

    // MARK: - Validation

    func test_aProposalWithOnlyGlossaryLinesUnderRulingsIsAccepted() throws {
        let markdown = """
        Register: informal, warm.

        ## Rulings

        - «October» → «Octubre» (the month, never a name)
        - «Kelly» → «Kelly»
        """
        try StatementProposalStore.validate(kind: .editionBrief("es"), markdown: markdown)
        let lines = try StatementProposalStore.glossaryLines(in: markdown)
        XCTAssertEqual(lines.map(\.term), ["October", "Kelly"])
        XCTAssertEqual(lines.map(\.rendering), ["Octubre", "Kelly"])
        XCTAssertEqual(lines.map(\.note), ["the month, never a name", nil])
    }

    func test_aRulingsLineThatIsNotGlossaryShapedIsRefusedByName() {
        let markdown = "Prose.\n\n## Rulings\n\n- «October» → «Octubre»\n- ¶k7mq: keep the three ands\n"
        XCTAssertThrowsError(try StatementProposalStore.validate(kind: .editionBrief("es"), markdown: markdown)) {
            XCTAssertEqual($0 as? StatementProposalStore.ProposalRefusal,
                           .rulingsNotGlossary(line: "¶k7mq: keep the three ands"))
        }
    }

    /// The P1 carry: an empty term is refused, not written.
    func test_anEmptyGlossaryTermIsRefused() {
        let markdown = "Prose.\n\n## Rulings\n\n- « » → «Octubre»\n"
        XCTAssertThrowsError(try StatementProposalStore.validate(kind: .editionBrief("es"), markdown: markdown)) {
            XCTAssertEqual($0 as? StatementProposalStore.ProposalRefusal,
                           .emptyGlossaryTerm(line: "« » → «Octubre»"))
        }
    }

    func test_aVisualLanguageProposalMayNotCarryRulings() {
        let markdown = "Serif, generous leading.\n\n## Rulings\n\n- «a» → «b»\n"
        XCTAssertThrowsError(try StatementProposalStore.validate(kind: .visualLanguage, markdown: markdown)) {
            XCTAssertEqual($0 as? StatementProposalStore.ProposalRefusal, .visualLanguageCarriesRulings)
        }
        XCTAssertNoThrow(try StatementProposalStore.validate(kind: .visualLanguage, markdown: "Serif."))
    }

    func test_emptyMarkdownAndABadTagAreRefused() {
        XCTAssertThrowsError(try StatementProposalStore.validate(kind: .visualLanguage, markdown: "  \n")) {
            XCTAssertEqual($0 as? StatementProposalStore.ProposalRefusal, .emptyMarkdown)
        }
        XCTAssertThrowsError(try StatementProposalStore.validate(kind: .editionBrief("Español"), markdown: "x")) {
            XCTAssertEqual($0 as? StatementProposalStore.ProposalRefusal, .invalidLanguageTag("Español"))
        }
    }

    // MARK: - The slot

    func test_stageWritesOneJSONFileUnderMaughamStatementsProposals() throws {
        let proposal = try store.stage(.init(kind: .editionBrief("es"), markdown: "Register: tú.",
                                             rationale: "the sample chapter is intimate",
                                             proposedAt: Date(), author: "Claude"))
        let file = StatementProposalStore.fileURL(key: "edition-brief-es", in: temp.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(file.path.contains("/.maugham/statements/proposals/"))
        XCTAssertEqual(store.pending(for: .editionBrief("es")), proposal)
        XCTAssertNil(store.pending(for: .visualLanguage))
    }

    func test_aNewProposalSupersedesThePendingOneForTheSameKey() throws {
        _ = try store.stage(.init(kind: .visualLanguage, markdown: "first", rationale: nil,
                                  proposedAt: Date(timeIntervalSinceNow: -60), author: "Claude"))
        let second = try store.stage(.init(kind: .visualLanguage, markdown: "second", rationale: nil,
                                           proposedAt: Date(), author: "Claude"))
        XCTAssertEqual(store.pending(for: .visualLanguage), second)
        XCTAssertEqual(store.pendingAll().count, 1, "one slot per key — nothing accumulates")
    }

    func test_twoLanguagesAreTwoSlots() throws {
        _ = try store.stage(.init(kind: .editionBrief("es"), markdown: "es", rationale: nil, proposedAt: Date(), author: "Claude"))
        _ = try store.stage(.init(kind: .editionBrief("fr"), markdown: "fr", rationale: nil, proposedAt: Date(), author: "Claude"))
        XCTAssertEqual(Set(store.pendingAll().map(\.kind)), [.editionBrief("es"), .editionBrief("fr")])
    }

    func test_discardClearsTheSlotAndAnEmptySlotIsNotAnError() throws {
        _ = try store.stage(.init(kind: .visualLanguage, markdown: "x", rationale: nil, proposedAt: Date(), author: "Claude"))
        try store.discard(.visualLanguage)
        XCTAssertNil(store.pending(for: .visualLanguage))
        XCTAssertNoThrow(try store.discard(.visualLanguage))
    }

    func test_stageRefusesWhatValidateRefusesAndWritesNothing() {
        XCTAssertThrowsError(try store.stage(.init(kind: .visualLanguage, markdown: "", rationale: nil,
                                                   proposedAt: Date(), author: "Claude")))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: StatementProposalStore.directoryURL(in: temp.url).path))
    }

    func test_anUnreadableSlotReadsAsNoProposalRatherThanCrashing() throws {
        let dir = StatementProposalStore.directoryURL(in: temp.url)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: StatementProposalStore.fileURL(key: "visual-language", in: temp.url))
        XCTAssertNil(store.pending(for: .visualLanguage))
        XCTAssertTrue(store.pendingAll().isEmpty)
    }

    // MARK: - The event

    func test_theProposalsChangedEventIsProjectScopedWithNoPayload() {
        var received: Notification?
        let token = NotificationCenter.default.addObserver(
            forName: .maughamStatementProposalsChanged, object: nil, queue: nil) { received = $0 }
        defer { NotificationCenter.default.removeObserver(token) }
        MaughamEvent.postStatementProposalsChanged(projectURL: temp.url)
        XCTAssertEqual(received?.userInfo?[MaughamEvent.scopeKindKey] as? String, "project")
        XCTAssertEqual(received?.userInfo?[MaughamEvent.scopeIdKey] as? String,
                       ProjectIdentifier.id(for: temp.url))
    }
}
```

(If `MaughamEvent.scopeKindKey`/`scopeIdKey` are not accessible from tests, use whatever `MaughamEventTests.test_post_encodesProjectScopeWithId` reads — copy that test's assertion shape.)

- [ ] **Step 2: `./gen.sh`, then run the suite to see it fail to compile**

Run: `./gen.sh` then `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/StatementProposalStoreTests`
Expected: build failure — `ProposableStatement` undefined.

- [ ] **Step 3: Implement the store**

Create `Maugham/Stores/StatementProposalStore.swift`:

```swift
import Foundation
import MaughamCore

/// Which statements Claude may PROPOSE a draft of (translation pipeline spec
/// §10). Two cases, on purpose: craft intent is the writer's own yardstick
/// (ADR 0028 §3) and is unrepresentable here rather than refused at runtime —
/// there is no case to reach it with.
enum ProposableStatement: Equatable, Hashable, Codable, Sendable {
    case editionBrief(String)
    case visualLanguage

    /// The statement this proposal is about. Total: both cases have a kind.
    var statementKind: Statement.Kind {
        switch self {
        case .editionBrief(let language): return .editionBrief(language.lowercased())
        case .visualLanguage: return .visualLanguage
        }
    }

    /// The reverse map. `nil` for a kind nothing may propose — intent, and a
    /// newer build's `.unknown`.
    init?(kind: Statement.Kind) {
        switch kind {
        case .editionBrief(let language): self = .editionBrief(language.lowercased())
        case .visualLanguage: self = .visualLanguage
        case .intent, .unknown: return nil
        }
    }

    /// The slot's filename stem. Lowercased so `ES` and `es` are one slot;
    /// hyphenated so no `:` reaches a filename.
    var key: String {
        switch self {
        case .editionBrief(let language): return "edition-brief-" + language.lowercased()
        case .visualLanguage: return "visual-language"
        }
    }

    /// What the banner calls it: "Spanish edition brief", "visual language".
    var displayName: String {
        switch self {
        case .editionBrief(let language):
            return TranslationReviewIndicator.displayLabel(forLanguageTag: language) + " edition brief"
        case .visualLanguage: return "visual language"
        }
    }
}

/// Where a proposed brief or visual language waits for the writer's verdict:
/// `.maugham/statements/proposals/<key>.json`, one pending slot per key.
///
/// **Everything here is DERIVED.** A proposal is a draft Claude can make
/// again; deleting `.maugham/statements/` costs that and never a word the
/// writer wrote. Standalone over a bare `projectURL`, `DesignProposalStore`'s
/// shape. It never writes a statement — `StatementProposalGate.adopt` is the
/// one place a proposal's words reach one, and it is a writer's click.
@MainActor
struct StatementProposalStore {

    struct Proposal: Codable, Equatable, Sendable {
        let kind: ProposableStatement
        let markdown: String
        let rationale: String?
        let proposedAt: Date
        let author: String
    }

    enum ProposalRefusal: Error, Equatable, CustomStringConvertible {
        case emptyMarkdown
        case rulingsNotGlossary(line: String)
        case emptyGlossaryTerm(line: String)
        case visualLanguageCarriesRulings
        case invalidLanguageTag(String)

        var description: String {
            switch self {
            case .emptyMarkdown:
                return "A proposal needs some text."
            case .rulingsNotGlossary(let line):
                return "Under ## Rulings a proposal may carry only glossary entries — "
                    + "«term» → «rendering» (optional note). A directive or any other ruling "
                    + "is the writer's to make. Refused: “\(line)”."
            case .emptyGlossaryTerm(let line):
                return "A glossary entry needs both a term and a rendering. Refused: “\(line)”."
            case .visualLanguageCarriesRulings:
                return "A visual language has no rulings section; put everything in the prose."
            case .invalidLanguageTag(let tag):
                return "invalid language tag: \(tag)"
            }
        }
    }

    let projectURL: URL
    init(projectURL: URL) { self.projectURL = projectURL }

    static func directoryURL(in projectURL: URL) -> URL {
        projectURL.appendingPathComponent(".maugham/statements/proposals", isDirectory: true)
    }
    static func fileURL(key: String, in projectURL: URL) -> URL {
        directoryURL(in: projectURL).appendingPathComponent(key + ".json")
    }

    // MARK: - Validation

    /// The glossary rows a proposal carries under `## Rulings`, or a refusal
    /// naming the first line that is not one. Parsed with the SAME parser the
    /// brief is read back with (`RulingsSection.parse` + `Ruling.glossary`),
    /// so what is accepted here is exactly what the table will draw.
    static func glossaryLines(in markdown: String) throws(ProposalRefusal)
        -> [(term: String, rendering: String, note: String?)] {
        var rows: [(term: String, rendering: String, note: String?)] = []
        for ruling in RulingsSection.parse(markdown).rulings {
            guard let entry = ruling.glossary else {
                throw .rulingsNotGlossary(line: ruling.text)
            }
            let term = entry.term.trimmingCharacters(in: .whitespaces)
            let rendering = entry.rendering.trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty, !rendering.isEmpty else {
                throw .emptyGlossaryTerm(line: ruling.text)
            }
            rows.append((term, rendering, entry.note))
        }
        return rows
    }

    static func validate(kind: ProposableStatement, markdown: String) throws(ProposalRefusal) {
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .emptyMarkdown
        }
        switch kind {
        case .editionBrief(let language):
            guard TranslationRecord.isValidLanguageTag(language) else {
                throw .invalidLanguageTag(language)
            }
            _ = try glossaryLines(in: markdown)
        case .visualLanguage:
            guard RulingsSection.parse(markdown).rulings.isEmpty else {
                throw .visualLanguageCarriesRulings
            }
        }
    }

    // MARK: - The slot

    func pending(for kind: ProposableStatement) -> Proposal? {
        read(key: kind.key)
    }

    /// Every pending proposal, oldest first. Tolerant: an unreadable slot is
    /// skipped, never a crash and never a thrown listing.
    func pendingAll() -> [Proposal] {
        let dir = Self.directoryURL(in: projectURL)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [])) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { read(key: $0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.proposedAt < $1.proposedAt }
    }

    /// Validate, then overwrite the slot: a new proposal supersedes.
    @discardableResult
    func stage(_ proposal: Proposal) throws -> Proposal {
        try Self.validate(kind: proposal.kind, markdown: proposal.markdown)
        let dir = Self.directoryURL(in: projectURL)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(proposal).write(
            to: Self.fileURL(key: proposal.kind.key, in: projectURL), options: .atomic)
        return proposal
    }

    /// Clear the slot. An empty slot is not an error — Discard after a
    /// supersede that already emptied it must not go red.
    func discard(_ kind: ProposableStatement) throws {
        let url = Self.fileURL(key: kind.key, in: projectURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - private

    private func read(key: String) -> Proposal? {
        let url = Self.fileURL(key: key, in: projectURL)
        guard let data = try? Data(contentsOf: url) else { return nil }  // adr-0018-ok: statement proposal, derived sidecar
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Proposal.self, from: data)
    }
}
```

If the toolchain rejects typed throws (`throws(ProposalRefusal)`) anywhere it is used from a `Codable` context, drop to plain `throws` and keep the `as? ProposalRefusal` casts in the tests.

Append to `Maugham/Models/MaughamNotifications.swift` (inside the extension, after `maughamDesignProposalsChanged`):

```swift
    /// **A statement proposal was staged or cleared** (translation pipeline
    /// P5) — `propose_edition_brief`/`propose_visual_language` wrote a slot
    /// under `.maugham/statements/proposals/`, or the writer's Adopt/Discard
    /// emptied one. `StatementPane` draws its gate from that slot, the desk
    /// marks its language row and `DetailPaneToggle` badges the Visual
    /// Language segment; none of them can otherwise see a file an MCP tool
    /// wrote behind them.
    ///
    /// No payload: which slots a surface cares about is its own answer (it
    /// re-reads them). Post via `MaughamEvent.postStatementProposalsChanged`,
    /// never by hand. Scope: .project(id:) — a data event, like
    /// `maughamDesignProposalsChanged`; a closed window reads nothing.
    public static let maughamStatementProposalsChanged = Notification.Name(
        "maugham.statement.proposals.changed")
```

Append to `Maugham/Events/MaughamEvent.swift` after `postDesignProposalsChanged`:

```swift
    /// **The one spelling of the statement-proposals-changed post** (P5).
    /// Posted by the two propose tools after staging and by
    /// `StatementProposalGate` after Adopt or Discard. `projectURL` is the
    /// project ROOT, matching what `.onProjectEvent` subscribes with.
    static func postStatementProposalsChanged(projectURL: URL) {
        post(.maughamStatementProposalsChanged, to: .project(for: projectURL))
    }
```

- [ ] **Step 4: Run the suite and the tripwires**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/StatementProposalStoreTests -only-testing:MaughamTests/TripwireGrepTests -only-testing:MaughamTests/AnnotationChangeEventTests`
Expected: all pass. (`test_noManuscriptFileReadsOutsideReconciler` is the one that goes red if the `adr-0018-ok` annotation is missing from `read(key:)`.)

- [ ] **Step 5: Commit**

```bash
git add Maugham/Stores/StatementProposalStore.swift Maugham/Models/MaughamNotifications.swift Maugham/Events/MaughamEvent.swift MaughamTests/StatementProposalStoreTests.swift
git commit -m "feat(translation-pipeline): StatementProposalStore — two-case kind, one slot per key, the changed event"
```

---

### Task 2: The two tools, the catalogue at 58, and the census widening

**Files:**
- Create: `Maugham/MCP/Tools/StatementProposalTools.swift`
- Modify: `Maugham/MCP/MCPTool.swift` (append two entries to `MCPToolCatalog.all` after `ReadEditionBriefTool.self`)
- Modify: `MaughamTests/CompilerAllowlistTests.swift` (`statementWriters`, the two write-tool lists, the planted-offender test)
- Modify: `CLAUDE.md` (`**56 tools**` → `**58 tools**` in the `Maugham/MCP/` row), `Maugham/MCP/AREA.md` (`## Tool catalogue (56)` → `(58)`; two list entries after `read_edition_brief`; the "production 56-tool count" sentence in the test-tools section)
- Test: create `MaughamTests/MCP/Tools/StatementProposalToolTests.swift`

**Interfaces:**
- Consumes: `StatementProposalStore` (Task 1), `MaughamEvent.postStatementProposalsChanged`, `MCPTool`, `decodeParams`, `resolveProject`, `MCPError.invalidArgument`.
- Produces: `ProposeEditionBriefTool` (`method = "propose_edition_brief"`, params `project_id`, `language`, `markdown`, `rationale?`), `ProposeVisualLanguageTool` (`method = "propose_visual_language"`, params `project_id`, `markdown`, `rationale?`). Both return `Result { staged: Bool; key: String; supersededPending: Bool; glossaryEntries: Int; adoptWhere: String }` — `adoptWhere` is a sentence telling Claude where the writer will find the gate.

- [ ] **Step 1: Write the failing tool tests**

Create `MaughamTests/MCP/Tools/StatementProposalToolTests.swift`:

```swift
import XCTest
@testable import Maugham
import MaughamCore

/// `propose_edition_brief` / `propose_visual_language` STAGE a draft and write
/// nothing to a statement (spec §10; ADR 0030 §7). The write is the writer's
/// Adopt, one column away.
@MainActor
final class StatementProposalToolTests: XCTestCase {
    private var temp: TempDirectory!
    override func setUp() async throws { temp = try TempDirectory() }
    override func tearDown() async throws { temp = nil }

    private func makeRegisteredNovel() async throws -> (URL, ProjectStore, DocumentStore, ProjectRegistry) {
        let url = try await ProjectFactory.createNovelProject(named: "ProposeMCP", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        let reg = ProjectRegistry()
        reg.register(url: url, store: store)
        return (url, store, ds, reg)
    }

    private func proposeBrief(_ reg: ProjectRegistry, projectURL: URL, language: String,
                              markdown: String, rationale: String? = nil) async throws
        -> ProposeEditionBriefTool.Result {
        let id = ProjectIdentifier.id(for: projectURL)
        var params: [String: Any] = ["project_id": id, "language": language, "markdown": markdown]
        if let rationale { params["rationale"] = rationale }
        let json = try await ProposeEditionBriefTool.handle(
            paramsJSON: try JSONSerialization.data(withJSONObject: params), registry: reg)
        return try JSONDecoder().decode(ProposeEditionBriefTool.Result.self, from: json)
    }

    private func proposeLook(_ reg: ProjectRegistry, projectURL: URL, markdown: String) async throws
        -> ProposeVisualLanguageTool.Result {
        let id = ProjectIdentifier.id(for: projectURL)
        let json = try await ProposeVisualLanguageTool.handle(
            paramsJSON: try JSONSerialization.data(withJSONObject: ["project_id": id, "markdown": markdown]),
            registry: reg)
        return try JSONDecoder().decode(ProposeVisualLanguageTool.Result.self, from: json)
    }

    func test_proposingABriefStagesASlotAndCreatesNoStatement() async throws {
        let (url, store, ds, reg) = try await makeRegisteredNovel()
        defer { Task { await ds.close() } }
        let result = try await proposeBrief(reg, projectURL: url, language: "es",
                                            markdown: "Register: tú.\n\n## Rulings\n\n- «October» → «Octubre»\n",
                                            rationale: "the sample chapter is intimate")
        XCTAssertTrue(result.staged)
        XCTAssertEqual(result.key, "edition-brief-es")
        XCTAssertEqual(result.glossaryEntries, 1)
        XCTAssertFalse(result.supersededPending)
        XCTAssertNil(store.statement(kind: .editionBrief("es"), scope: .project),
                     "a proposal is not a write — no statement may exist until the writer adopts")
        let pending = StatementProposalStore(projectURL: url).pending(for: .editionBrief("es"))
        XCTAssertEqual(pending?.rationale, "the sample chapter is intimate")
        XCTAssertEqual(pending?.author, "Claude")
    }

    func test_aSecondProposalReportsThatItSuperseded() async throws {
        let (url, _, ds, reg) = try await makeRegisteredNovel()
        defer { Task { await ds.close() } }
        _ = try await proposeLook(reg, projectURL: url, markdown: "Serif.")
        let second = try await proposeLook(reg, projectURL: url, markdown: "Sans.")
        XCTAssertTrue(second.supersededPending)
        XCTAssertEqual(StatementProposalStore(projectURL: url).pending(for: .visualLanguage)?.markdown, "Sans.")
    }

    func test_theToolPostsTheProjectScopedChangedEvent() async throws {
        let (url, _, ds, reg) = try await makeRegisteredNovel()
        defer { Task { await ds.close() } }
        var received = 0
        let token = NotificationCenter.default.addObserver(
            forName: .maughamStatementProposalsChanged, object: nil, queue: nil) { _ in received += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        _ = try await proposeLook(reg, projectURL: url, markdown: "Serif.")
        XCTAssertEqual(received, 1)
    }

    func test_aRefusedProposalIsAnInvalidArgumentAndStagesNothing() async throws {
        let (url, _, ds, reg) = try await makeRegisteredNovel()
        defer { Task { await ds.close() } }
        do {
            _ = try await proposeBrief(reg, projectURL: url, language: "es",
                                       markdown: "x\n\n## Rulings\n\n- ¶k7mq: a directive\n")
            XCTFail("a directive under a proposal's rulings must be refused")
        } catch let error as MCPError {
            guard case .invalidArgument(let message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("glossary"), message)
        }
        XCTAssertNil(StatementProposalStore(projectURL: url).pending(for: .editionBrief("es")))
        do {
            _ = try await proposeBrief(reg, projectURL: url, language: "ES-MX!", markdown: "x")
            XCTFail("a malformed tag must be refused")
        } catch let error as MCPError {
            guard case .invalidArgument = error else { return XCTFail("\(error)") }
        }
    }

    func test_bothToolsAreInTheCatalogueAndTheCountIs58() {
        let methods = MCPToolCatalog.all.map { $0.method }
        XCTAssertTrue(methods.contains("propose_edition_brief"))
        XCTAssertTrue(methods.contains("propose_visual_language"))
        XCTAssertEqual(MCPToolCatalog.all.count, 58)
    }

    func test_neitherToolIsInTheCompilerAllowlist() {
        let allowed = Set(CompilerAllowlist.tools.map { String($0.dropFirst("mcp__maugham__".count)) })
        XCTAssertFalse(allowed.contains("propose_edition_brief"))
        XCTAssertFalse(allowed.contains("propose_visual_language"))
    }
}
```

- [ ] **Step 2: Widen the census in `CompilerAllowlistTests`**

Replace `statementWriters` and the planted-offender test, and add the two names to BOTH `writeTools` sets in `test_noWriteToolIsAllowed` and `test_theCensusWouldCatchAWrite`:

```swift
    /// The control. Without it the census above passes for a predicate that
    /// matches nothing at all, and a real statement writer would ship green.
    ///
    /// **Widened in P5**: `edition_brief` and `visual_language` are subjects
    /// too (a hypothetical `write_edition_brief` was NOT caught before), and a
    /// `propose_` prefix on any statement subject other than the two
    /// proposable ones is caught — `propose_craft_intent` is a write wearing
    /// a proposal's name, while `propose_edition_brief` ships and stages only.
    func test_theStatementCensusWouldCatchAWriteToIntent() {
        let planted = ["read_craft_intent", "write_craft_intent", "list_projects",
                       "write_edition_brief", "set_visual_language",
                       "propose_craft_intent", "propose_edition_brief", "propose_visual_language",
                       "propose_statement"]
        XCTAssertEqual(
            Self.statementWriters(in: planted),
            ["write_craft_intent", "write_edition_brief", "set_visual_language",
             "propose_craft_intent", "propose_statement"],
            "the predicate must catch a hypothetical statement writer \u{2014} and must "
            + "NOT catch the READERS beside it, nor the two proposal tools, which stage "
            + "a draft the writer adopts")
    }

    /// A tool name that would put words into a statement.
    ///
    /// Names rather than a list of known-bad spellings: the risk is a tool that
    /// does not exist yet. The subjects are the statement kinds
    /// (`Statement.Kind`) plus `statement` itself; the verbs are the write
    /// verbs. A `propose_` tool is a write unless its subject is one of the
    /// two `ProposableStatement` cases — the proposal is staged, never written.
    static func statementWriters(in names: [String]) -> Set<String> {
        let subjects = ["craft_intent", "visual_language", "edition_brief", "statement", "intent"]
        let verbs = ["write_", "add_", "set_", "append_", "update_", "edit_", "delete_"]
        let proposable = ["propose_edition_brief", "propose_visual_language"]
        var found: Set<String> = []
        for name in names {
            let namesAStatement = subjects.contains { name.contains($0) }
            let isAWrite = verbs.contains { name.hasPrefix($0) }
            let isAForeignProposal = name.hasPrefix("propose_") && !proposable.contains(name)
            if namesAStatement && (isAWrite || isAForeignProposal) { found.insert(name) }
        }
        return found
    }
```

(`statementWriters` becomes `static`, not `private static`, so `StatementProposalToolTests` could call it — it does not today; keep it `private static` if the reviewer prefers, nothing else depends on it.)

- [ ] **Step 3: `./gen.sh`, run, see the failures**

Run: `./gen.sh` then `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/StatementProposalToolTests -only-testing:MaughamTests/CompilerAllowlistTests`
Expected: compile failure (`ProposeEditionBriefTool` undefined); the census control fails on `write_edition_brief` until Step 2's predicate lands.

- [ ] **Step 4: Implement the two tools**

Create `Maugham/MCP/Tools/StatementProposalTools.swift`:

```swift
import Foundation
import MaughamCore

/// The staging half of "proposals into statements" (translation pipeline
/// spec §10; ADR 0030 §7). **Neither tool writes a statement.** Each validates
/// the draft, writes ONE slot under `.maugham/statements/proposals/` (a new
/// proposal supersedes the pending one for the same key), posts the
/// project-scoped changed event so the gate can draw, and returns where the
/// writer will find it. The write — if it ever happens — is the writer's
/// Adopt in `StatementPane`, through `StatementProposalGate`.
///
/// Mirrors `ReadEditionBriefTool` / `ReadVisualLanguageTool`'s shape: resolve
/// the project, project scope only, a language tag that is part of the slot's
/// identity is validated the way the read tool validates it.
enum StatementProposalTools {
    static let author = "Claude"

    /// Where the writer adopts it — one sentence the tool returns so a session
    /// can tell the writer, rather than guessing at a menu.
    static func adoptWhere(_ kind: ProposableStatement) -> String {
        switch kind {
        case .editionBrief(let language):
            return "In Maugham: Publish (⌘4) → Department desk (⌘⌥K) → the "
                + TranslationReviewIndicator.displayLabel(forLanguageTag: language)
                + " row's Edition Brief. A banner offers Adopt / Discard with a diff."
        case .visualLanguage:
            return "In Maugham: the Visual Language pane (⌘⌥V). A banner offers "
                + "Adopt / Discard with a diff against the current statement."
        }
    }

    @MainActor
    static func stage(kind: ProposableStatement, markdown: String, rationale: String?,
                      in store: ProjectStore) throws -> (StatementProposalStore.Proposal, superseded: Bool, glossary: Int) {
        let proposals = StatementProposalStore(projectURL: store.url)
        let superseded = proposals.pending(for: kind) != nil
        let proposal: StatementProposalStore.Proposal
        do {
            proposal = try proposals.stage(.init(
                kind: kind, markdown: markdown, rationale: rationale,
                proposedAt: Date(), author: author))
        } catch let refusal as StatementProposalStore.ProposalRefusal {
            throw MCPError.invalidArgument(refusal.description)
        }
        let glossary: Int
        if case .editionBrief = kind {
            glossary = (try? StatementProposalStore.glossaryLines(in: markdown).count) ?? 0
        } else {
            glossary = 0
        }
        MaughamEvent.postStatementProposalsChanged(projectURL: store.url)
        return (proposal, superseded, glossary)
    }
}

public enum ProposeEditionBriefTool: MCPTool {
    public static let method = "propose_edition_brief"
    public static let description =
        "Propose a draft edition brief for one language — the writer's doctrine for that "
        + "translated edition (register, forms of address, what a translator must not smooth, "
        + "typographic conventions) — as MARKDOWN the writer adopts or discards in Maugham. "
        + "This writes nothing: the draft is staged, and the writer sees it as a diff against "
        + "their current brief with Adopt / Discard. A `## Rulings` section may carry ONLY "
        + "glossary entries of the shape `- «term» → «rendering» (optional note)`; Adopt appends "
        + "them as rulings. Anything else under that heading is refused — directives and other "
        + "rulings are the writer's to make. A new proposal for the same language replaces the "
        + "pending one. Interview first (the `edition-brief` skill via get_help topic \"skills\"); "
        + "read read_craft_intent and read_edition_brief before drafting."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"language":{"type":"string","description":"lowercase tag, e.g. es, pt-br"},"markdown":{"type":"string","description":"the proposed brief, whole; optional ## Rulings section of glossary lines only"},"rationale":{"type":"string","description":"one or two sentences on why — shown to the writer beside the diff"}},"required":["project_id","language","markdown"]}"#

    public struct Params: Codable {
        public let project_id: String
        public let language: String
        public let markdown: String
        public let rationale: String?
    }
    public struct Result: Codable, Equatable {
        public let staged: Bool
        public let key: String
        public let supersededPending: Bool
        public let glossaryEntries: Int
        public let adoptWhere: String
    }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        guard TranslationRecord.isValidLanguageTag(params.language) else {
            throw MCPError.invalidArgument("invalid language tag: \(params.language)")
        }
        let entry = try resolveProject(params.project_id, in: registry)
        let kind = ProposableStatement.editionBrief(params.language)
        let (proposal, superseded, glossary) = try StatementProposalTools.stage(
            kind: kind, markdown: params.markdown, rationale: params.rationale, in: entry.store)
        return try JSONEncoder().encode(Result(
            staged: true, key: proposal.kind.key, supersededPending: superseded,
            glossaryEntries: glossary, adoptWhere: StatementProposalTools.adoptWhere(kind)))
    }
}

public enum ProposeVisualLanguageTool: MCPTool {
    public static let method = "propose_visual_language"
    public static let description =
        "Propose a draft visual language — the writer's freeform statement of how the book "
        + "should LOOK (trim, typeface feel, scale, rule weights, ornament, the idea behind "
        + "per-piece variation) — as MARKDOWN the writer adopts or discards in Maugham. This "
        + "writes nothing: the draft is staged, and the writer sees it as a diff against their "
        + "current statement in the Visual Language pane with Adopt / Discard. No `## Rulings` "
        + "section — a visual language has none. A new proposal replaces the pending one. "
        + "Interview first (the `visual-language` skill via get_help topic \"skills\"); read "
        + "read_visual_language and the sensory palette before drafting."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"markdown":{"type":"string","description":"the proposed statement, whole"},"rationale":{"type":"string","description":"one or two sentences on why — shown to the writer beside the diff"}},"required":["project_id","markdown"]}"#

    public struct Params: Codable {
        public let project_id: String
        public let markdown: String
        public let rationale: String?
    }
    public struct Result: Codable, Equatable {
        public let staged: Bool
        public let key: String
        public let supersededPending: Bool
        public let glossaryEntries: Int
        public let adoptWhere: String
    }

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(params.project_id, in: registry)
        let (proposal, superseded, _) = try StatementProposalTools.stage(
            kind: .visualLanguage, markdown: params.markdown, rationale: params.rationale, in: entry.store)
        return try JSONEncoder().encode(Result(
            staged: true, key: proposal.kind.key, supersededPending: superseded,
            glossaryEntries: 0, adoptWhere: StatementProposalTools.adoptWhere(.visualLanguage)))
    }
}
```

Add `ProposeEditionBriefTool.self, ProposeVisualLanguageTool.self` to `MCPToolCatalog.all` after `ReadEditionBriefTool.self`.

- [ ] **Step 5: Move the counts in the two docs**

In `CLAUDE.md`'s `Maugham/MCP/` row change `**56 tools**` to `**58 tools**` and, in the same cell, after the sentence beginning "**Two of them write, and both write into the planning plane**", add: *"**Two more STAGE, and neither writes anywhere Claude is judged by** (translation pipeline P5): `propose_edition_brief` and `propose_visual_language` put a draft under `.maugham/statements/proposals/` for the writer's Adopt/Discard gate in `StatementPane`; `CompilerAllowlistTests.statementWriters` catches `write_edition_brief` and `propose_craft_intent` and passes exactly these two."* In `Maugham/MCP/AREA.md` change `## Tool catalogue (56)` to `(58)`, change "production 56-tool count" to "production 58-tool count", and add after the `read_edition_brief` entry:

```
- `propose_edition_brief` — STAGE a draft brief for one language (`language`, `markdown`, `rationale?`), mirroring `read_edition_brief`'s shape. Writes nothing to a statement: validates (project, tag, and a `## Rulings` section that may hold only glossary-shaped lines — `StatementProposalStore.validate`), overwrites the one slot at `.maugham/statements/proposals/edition-brief-<tag>.json`, posts `.maughamStatementProposalsChanged` (project scope). The writer adopts it at `StatementPane`'s gate (`StatementProposalGate.adopt` — the only write, a click) or discards it. Neither propose tool is in `CompilerAllowlist`; `CompilerAllowlistTests.statementWriters` catches `write_edition_brief` and `propose_craft_intent` and passes these two by name. Translation pipeline spec §10; ADR 0030 §7.
- `propose_visual_language` — the same, for the book's look (`markdown`, `rationale?`), slot `visual-language.json`; a `## Rulings` section is refused because visual language has no strata. Adopted in the Visual Language pane (⌘⌥V), whose picker segment carries a "proposed" badge while a slot stands.
```

- [ ] **Step 6: Run the task's suites, the tripwires and the doc-sync**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/StatementProposalToolTests -only-testing:MaughamTests/CompilerAllowlistTests -only-testing:MaughamTests/DocSyncTests -only-testing:MaughamTests/TripwireGrepTests -only-testing:MaughamTests/AnnotationChangeEventTests -only-testing:MaughamTests/MCPCatalogConsistencyTests`
Expected: all pass (`MCPCatalogConsistencyTests` parses every schema; if the class name differs, run whatever suite asserts every catalogue entry's schema parses — `grep -rn inputSchemaJSON MaughamTests | head` names it).

- [ ] **Step 7: Commit**

```bash
git add Maugham/MCP/Tools/StatementProposalTools.swift Maugham/MCP/MCPTool.swift MaughamTests/MCP/Tools/StatementProposalToolTests.swift MaughamTests/CompilerAllowlistTests.swift CLAUDE.md Maugham/MCP/AREA.md
git commit -m "feat(mcp): propose_edition_brief + propose_visual_language stage a draft (56→58); statement census widened"
```

---

### Task 3: `StatementProposalGate` — Adopt (the one write) and Discard, undoable

**Files:**
- Create: `Maugham/Compiler/StatementProposalGate.swift`
- Test: create `MaughamTests/StatementProposalGateTests.swift`

**Interfaces:**
- Consumes: `StatementProposalStore` (Task 1), `ProjectStore.createStatement/statement/statementText/mutateStatementText`, `StatementEssay.recomposed/half/carriesRulings`, `RulingsSection.parse`, `RulingPerformer.rule`, `Ruling.glossaryText`, `Ruling.Provenance.glossary`, `OpUndoRegistrar.register`, `MaughamEvent.postStatementProposalsChanged`.
- Produces:
  - `enum StatementProposalGate` (`@MainActor`) with
    - `static func adopt(_ proposal: StatementProposalStore.Proposal, store: ProjectStore, world: DeclaredWorldStore?, undoManager: UndoManager?, workTaskSink: @escaping (Task<Void, Never>) -> Void) async throws -> Adoption`
    - `struct Adoption: Equatable { let statement: Statement; let created: Bool; let glossaryAppended: Int; let before: String; let after: String }`
    - `static func discard(_ kind: ProposableStatement, store: ProjectStore) throws`
    - `static func adoptedEssay(proposalMarkdown: String, kind: ProposableStatement) -> String` — pure: the essay half of the proposal for a brief, the whole markdown for visual language.
    - `enum Failure: Error, Equatable, CustomStringConvertible { case proposalGone; case refused(StatementProposalStore.ProposalRefusal); case unreadable(String) }`
  - `enum StatementProposalCopy` (statics): `bannerTitle(_ proposal: Proposal) -> String` (*"Claude proposed a Spanish edition brief"* / *"Claude proposed a visual language"* — built from `proposal.author` and `kind.displayName`), `bannerWhen(_ date: Date, now: Date) -> String` (*"just now"* / *"12 minutes ago"* / *"2 days ago"*), `adoptTitle = "Adopt"`, `discardTitle = "Discard"`, `adoptHelp(_ kind:) -> String`, `discardHelp`, `adoptAccessibilityLabel(_ kind:)`, `discardAccessibilityLabel(_ kind:)`, `adoptedLine(glossary: Int) -> String` (*"Adopted."* / *"Adopted, with 3 glossary entries."*), `discardedLine = "Proposal discarded."`, `firstAdoptCreatesLine(_ kind:) -> String` (*"There is no Spanish edition brief yet — Adopt creates it."*), `glossaryLine(count: Int) -> String?` (nil at 0; *"Carries 3 glossary entries, appended as rulings on Adopt."*), `rationaleHeading = "Why"`, `diffHeading = "Against your current text"`, `noCurrentTextLine = "Nothing to compare — this statement is empty."`, `undoActionName = "Adopt Proposal"`.

- [ ] **Step 1: Write the failing tests**

Create `MaughamTests/StatementProposalGateTests.swift`:

```swift
import XCTest
@testable import Maugham
import MaughamCore

/// Adopt is the ONE place a proposal's words reach a statement (spec §10;
/// ADR 0030 §7). It replaces the essay through the ordinary statement write
/// path, keeps the `## Rulings` tail byte-for-byte, appends glossary lines
/// through `RulingPerformer.rule`, creates a missing brief, and is undoable.
@MainActor
final class StatementProposalGateTests: XCTestCase {
    private var temp: TempDirectory!
    override func setUp() async throws { temp = try TempDirectory() }
    override func tearDown() async throws { temp = nil }

    private func loadedNovel() async throws -> (URL, ProjectStore) {
        let url = try await ProjectFactory.createNovelProject(named: "Gate", in: temp.url)
        let store = try await ProjectStore.load(from: url)
        await store.wordCountPopulationTask?.value
        return (url, store)
    }

    private func write(_ text: String, into statement: Statement, at projectURL: URL) async throws {
        let document = try await Document.load(
            url: projectURL.appendingPathComponent(statement.path),
            device: "gate-test", session: "s", presenter: nil)
        document.setFullText(text)
        try await document.flushBurstNow()
        await document.close()
    }

    private func proposal(_ kind: ProposableStatement, _ markdown: String,
                          rationale: String? = nil) -> StatementProposalStore.Proposal {
        .init(kind: kind, markdown: markdown, rationale: rationale, proposedAt: Date(), author: "Claude")
    }

    private func stage(_ p: StatementProposalStore.Proposal, at url: URL) throws {
        _ = try StatementProposalStore(projectURL: url).stage(p)
    }

    // MARK: - The essay is replaced, the rulings tail is untouched

    func test_adoptReplacesTheEssayAndKeepsTheRulingsTailByteForByte() async throws {
        let (url, store) = try await loadedNovel()
        let brief = try await store.createStatement(kind: .editionBrief("es"), scope: .project)
        let tail = "## Rulings\n\n- ¶k7mq: keep the three ands — ruled 28 Aug 2026, translator's note\n- odd  spacing   kept\n"
        try await write("Old prose.\n\n" + tail, into: brief, at: url)

        let p = proposal(.editionBrief("es"), "New prose, two paragraphs.\n\nSecond.")
        try stage(p, at: url)
        let adoption = try await StatementProposalGate.adopt(
            p, store: store, world: nil, undoManager: nil, workTaskSink: { _ in })

        let text = try store.statementText(of: brief)
        XCTAssertEqual(text, "New prose, two paragraphs.\n\nSecond.\n\n" + tail)
        XCTAssertFalse(adoption.created)
        XCTAssertEqual(adoption.glossaryAppended, 0)
        XCTAssertEqual(adoption.before, "Old prose.\n\n" + tail)
        XCTAssertEqual(adoption.after, text)
        XCTAssertNil(StatementProposalStore(projectURL: url).pending(for: .editionBrief("es")),
                     "Adopt clears the slot")
    }

    func test_adoptAppendsTheProposalsGlossaryLinesAsRulingsThroughTheOneDoor() async throws {
        let (url, store) = try await loadedNovel()
        let brief = try await store.createStatement(kind: .editionBrief("es"), scope: .project)
        try await write("Prose.\n\n## Rulings\n\n- existing ruling — ruled 1 Sep 2026, by hand\n", into: brief, at: url)

        let p = proposal(.editionBrief("es"),
                         "Better prose.\n\n## Rulings\n\n- «October» → «Octubre» (the month, never a name)\n- «Kelly» → «Kelly»\n")
        try stage(p, at: url)
        let adoption = try await StatementProposalGate.adopt(
            p, store: store, world: nil, undoManager: nil, workTaskSink: { _ in })
        XCTAssertEqual(adoption.glossaryAppended, 2)

        let parsed = RulingsSection.parse(try store.statementText(of: brief))
        XCTAssertEqual(parsed.essay, "Better prose.")
        XCTAssertEqual(parsed.rulings.map(\.text),
                       ["existing ruling", "«October» → «Octubre» (the month, never a name)", "«Kelly» → «Kelly»"])
        XCTAssertEqual(parsed.rulings[0].provenance, "by hand", "the existing ruling keeps its provenance")
        XCTAssertEqual(parsed.rulings[1].provenance, Ruling.Provenance.glossary)
        XCTAssertEqual(parsed.rulings[1].glossary?.note, "the month, never a name")
    }

    func test_aFirstAdoptOnALanguageWithNoBriefCreatesIt() async throws {
        let (url, store) = try await loadedNovel()
        XCTAssertNil(store.statement(kind: .editionBrief("fr"), scope: .project))
        let p = proposal(.editionBrief("fr"), "Vous throughout.\n\n## Rulings\n\n- «Kelly» → «Kelly»\n")
        try stage(p, at: url)
        let adoption = try await StatementProposalGate.adopt(
            p, store: store, world: nil, undoManager: nil, workTaskSink: { _ in })
        XCTAssertTrue(adoption.created)
        let brief = try XCTUnwrap(store.statement(kind: .editionBrief("fr"), scope: .project))
        let parsed = RulingsSection.parse(try store.statementText(of: brief))
        XCTAssertEqual(parsed.essay, "Vous throughout.")
        XCTAssertEqual(parsed.rulings.map(\.text), ["«Kelly» → «Kelly»"])
    }

    func test_adoptingAVisualLanguageReplacesTheWholeText() async throws {
        let (url, store) = try await loadedNovel()
        let look = try await store.createStatement(kind: .visualLanguage, scope: .project)
        try await write("Old look.\n\n## Rulings\n\n- a heading the writer typed is prose here\n", into: look, at: url)
        let p = proposal(.visualLanguage, "Serif, generous leading.")
        try stage(p, at: url)
        _ = try await StatementProposalGate.adopt(p, store: store, world: nil, undoManager: nil, workTaskSink: { _ in })
        XCTAssertEqual(try store.statementText(of: look), "Serif, generous leading.",
                       "visual language has no strata (StatementEssay.carriesRulings), so the whole text is the essay")
    }

    // MARK: - Refusals

    func test_adoptRefusesAnEmptyGlossaryTermEvenIfTheSlotWasHandEdited() async throws {
        let (url, store) = try await loadedNovel()
        // Bypass validation the way a hand-edited slot would.
        let dir = StatementProposalStore.directoryURL(in: url)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = proposal(.editionBrief("es"), "x\n\n## Rulings\n\n- « » → «y»\n")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(p).write(to: StatementProposalStore.fileURL(key: "edition-brief-es", in: url))
        do {
            _ = try await StatementProposalGate.adopt(p, store: store, world: nil, undoManager: nil, workTaskSink: { _ in })
            XCTFail("an empty term must refuse")
        } catch let failure as StatementProposalGate.Failure {
            XCTAssertEqual(failure, .refused(.emptyGlossaryTerm(line: "« » → «y»")))
        }
        XCTAssertNil(store.statement(kind: .editionBrief("es"), scope: .project), "a refused Adopt mints nothing")
    }

    func test_adoptRefusesWhenTheSlotIsGone() async throws {
        let (_, store) = try await loadedNovel()
        let p = proposal(.visualLanguage, "x")
        do {
            _ = try await StatementProposalGate.adopt(p, store: store, world: nil, undoManager: nil, workTaskSink: { _ in })
            XCTFail()
        } catch let failure as StatementProposalGate.Failure {
            XCTAssertEqual(failure, .proposalGone)
        }
    }

    func test_discardClearsTheSlotAndPostsTheEvent() async throws {
        let (url, store) = try await loadedNovel()
        try stage(proposal(.visualLanguage, "x"), at: url)
        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: .maughamStatementProposalsChanged, object: nil, queue: nil) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        try StatementProposalGate.discard(.visualLanguage, store: store)
        XCTAssertNil(StatementProposalStore(projectURL: url).pending(for: .visualLanguage))
        XCTAssertEqual(posts, 1)
        XCTAssertNil(store.statement(kind: .visualLanguage, scope: .project), "Discard writes nothing")
    }

    // MARK: - Undo

    func test_adoptIsOneUndoStepThatPutsTheOldTextBack() async throws {
        let (url, store) = try await loadedNovel()
        let look = try await store.createStatement(kind: .visualLanguage, scope: .project)
        try await write("Old look.", into: look, at: url)
        let p = proposal(.visualLanguage, "New look.")
        try stage(p, at: url)
        let um = UndoManager()
        var tasks: [Task<Void, Never>] = []
        _ = try await StatementProposalGate.adopt(p, store: store, world: nil, undoManager: um,
                                                  workTaskSink: { tasks.append($0) })
        XCTAssertTrue(um.canUndo)
        XCTAssertEqual(um.undoActionName, StatementProposalCopy.undoActionName)
        um.undo()
        for task in tasks { await task.value }
        XCTAssertEqual(try store.statementText(of: look), "Old look.")
        XCTAssertTrue(um.canRedo)
        tasks.removeAll()
        um.redo()
        for task in tasks { await task.value }
        XCTAssertEqual(try store.statementText(of: look), "New look.")
    }

    // MARK: - Copy

    func test_theCopyNamesTheAuthorAndTheStatement() {
        let p = proposal(.editionBrief("es"), "x", rationale: "because")
        XCTAssertEqual(StatementProposalCopy.bannerTitle(p), "Claude proposed a Spanish edition brief")
        XCTAssertEqual(StatementProposalCopy.bannerTitle(proposal(.visualLanguage, "x")),
                       "Claude proposed a visual language")
        XCTAssertEqual(StatementProposalCopy.adoptedLine(glossary: 0), "Adopted.")
        XCTAssertEqual(StatementProposalCopy.adoptedLine(glossary: 1), "Adopted, with 1 glossary entry.")
        XCTAssertEqual(StatementProposalCopy.adoptedLine(glossary: 3), "Adopted, with 3 glossary entries.")
        XCTAssertNil(StatementProposalCopy.glossaryLine(count: 0))
        XCTAssertEqual(StatementProposalCopy.glossaryLine(count: 2),
                       "Carries 2 glossary entries, appended as rulings on Adopt.")
        XCTAssertEqual(StatementProposalCopy.firstAdoptCreatesLine(.editionBrief("es")),
                       "There is no Spanish edition brief yet — Adopt creates it.")
        let now = Date()
        XCTAssertEqual(StatementProposalCopy.bannerWhen(now.addingTimeInterval(-10), now: now), "just now")
        XCTAssertEqual(StatementProposalCopy.bannerWhen(now.addingTimeInterval(-720), now: now), "12 minutes ago")
        XCTAssertEqual(StatementProposalCopy.bannerWhen(now.addingTimeInterval(-2 * 86_400 - 5), now: now), "2 days ago")
    }
}
```

(`TranslationReviewIndicator.displayLabel(forLanguageTag: "es")` is `"Spanish"` — confirm by reading it; if it renders differently, use the function in the expected string rather than the literal.)

- [ ] **Step 2: `./gen.sh`, run to see the compile failure**

Run: `./gen.sh` then `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/StatementProposalGateTests`
Expected: `StatementProposalGate` undefined.

- [ ] **Step 3: Implement the gate**

Create `Maugham/Compiler/StatementProposalGate.swift`:

```swift
import Foundation
import MaughamCore

/// **The one place a proposal's words reach a statement** (translation
/// pipeline spec §10; ADR 0030 §7). A proposal is staged by an MCP tool and
/// waits in `StatementProposalStore`; this runs when the WRITER presses Adopt
/// in `StatementPane`. It is a writer's act, which is why it may write.
///
/// Adopt does three things, in order, and each is an existing verb:
/// 1. find-or-create the statement (`ProjectStore.createStatement`, the only
///    minting path — a first Adopt on a language with no brief creates it);
/// 2. replace the ESSAY through `ProjectStore.mutateStatementText` with
///    `StatementEssay.recomposed`, so the `## Rulings` tail is byte-identical
///    (for visual language, which has no strata, the whole text is the essay);
/// 3. append each glossary line through `RulingPerformer.rule` with
///    `Ruling.Provenance.glossary` — the same door every ruling uses, so the
///    section renders canonically exactly as a Make-it-a-rule would.
///
/// The essay write is ONE op, and the undo registered here is one step over
/// the whole adoption (essay + glossary): ⌘Z puts `before` back whole. A
/// first Adopt that created the statement undoes to an EMPTY statement, not
/// to no statement — `rollbackUnusedStatement`'s job, and a statement with a
/// manifest row and no words is the same state a pane visit leaves.
///
/// **A refusal writes nothing and mints nothing**: the proposal is re-validated
/// BEFORE `createStatement`, because the slot is a plain JSON file anyone can
/// hand-edit, and the P1 carry (an empty glossary term must never be written)
/// is enforced here as well as at the tool.
@MainActor
enum StatementProposalGate {

    struct Adoption: Equatable {
        let statement: Statement
        let created: Bool
        let glossaryAppended: Int
        let before: String
        let after: String
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case proposalGone
        case refused(StatementProposalStore.ProposalRefusal)
        case unreadable(String)

        var description: String {
            switch self {
            case .proposalGone: return "That proposal is no longer pending — it was superseded or discarded."
            case .refused(let refusal): return refusal.description
            case .unreadable(let why): return "Couldn’t read the statement: \(why)"
            }
        }
    }

    /// The essay Adopt writes: a brief's prose above its (proposed) rulings;
    /// a visual language whole.
    static func adoptedEssay(proposalMarkdown: String, kind: ProposableStatement) -> String {
        guard StatementEssay.carriesRulings(kind.statementKind) else { return proposalMarkdown }
        return StatementEssay.half(of: proposalMarkdown)
    }

    static func adopt(_ proposal: StatementProposalStore.Proposal, store: ProjectStore,
                      world: DeclaredWorldStore?, undoManager: UndoManager?,
                      workTaskSink: @escaping (Task<Void, Never>) -> Void) async throws -> Adoption {
        let proposals = StatementProposalStore(projectURL: store.url)
        guard proposals.pending(for: proposal.kind) == proposal else { throw Failure.proposalGone }
        do {
            try StatementProposalStore.validate(kind: proposal.kind, markdown: proposal.markdown)
        } catch let refusal as StatementProposalStore.ProposalRefusal {
            throw Failure.refused(refusal)
        }
        let kind = proposal.kind.statementKind
        let glossary: [(term: String, rendering: String, note: String?)]
        if case .editionBrief = proposal.kind {
            glossary = (try? StatementProposalStore.glossaryLines(in: proposal.markdown)) ?? []
        } else {
            glossary = []
        }

        let created = store.statement(kind: kind, scope: .project) == nil
        let statement = try await store.createStatement(kind: kind, scope: .project)
        let before: String
        do { before = try store.statementText(of: statement) }
        catch { throw Failure.unreadable(error.localizedDescription) }

        let essay = adoptedEssay(proposalMarkdown: proposal.markdown, kind: proposal.kind)
        try await store.mutateStatementText(of: statement, session: session) { existing in
            StatementEssay.recomposed(essay: essay, into: existing)
        }
        for entry in glossary {
            try await RulingPerformer.rule(
                Ruling.glossaryText(term: entry.term, rendering: entry.rendering, note: entry.note),
                provenance: Ruling.Provenance.glossary,
                kind: kind, forScope: .project, store: store, world: world)
        }
        let after = (try? store.statementText(of: statement)) ?? ""
        try proposals.discard(proposal.kind)
        MaughamEvent.postStatementProposalsChanged(projectURL: store.url)

        OpUndoRegistrar.register(
            undoManager, actionName: StatementProposalCopy.undoActionName, target: store,
            workTaskSink: workTaskSink,
            undo: { s in
                try? await s.mutateStatementText(of: statement, session: session) { _ in before }
            },
            redo: { s in
                try? await s.mutateStatementText(of: statement, session: session) { _ in after }
            })
        return Adoption(statement: statement, created: created, glossaryAppended: glossary.count,
                        before: before, after: after)
    }

    static func discard(_ kind: ProposableStatement, store: ProjectStore) throws {
        try StatementProposalStore(projectURL: store.url).discard(kind)
        MaughamEvent.postStatementProposalsChanged(projectURL: store.url)
    }

    private static let session = "proposal-\(UUID().uuidString)"
}

/// Every sentence the gate says, as statics — assertable with nothing mounted.
enum StatementProposalCopy {
    static let adoptTitle = "Adopt"
    static let discardTitle = "Discard"
    static let rationaleHeading = "Why"
    static let diffHeading = "Against your current text"
    static let noCurrentTextLine = "Nothing to compare — this statement is empty."
    static let discardedLine = "Proposal discarded."
    static let undoActionName = "Adopt Proposal"
    static let discardHelp = "Clear this proposal. Nothing you wrote changes."

    static func bannerTitle(_ proposal: StatementProposalStore.Proposal) -> String {
        "\(proposal.author) proposed a \(proposal.kind.displayName)"
    }

    static func bannerWhen(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) minute\(minutes == 1 ? "" : "s") ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) hour\(hours == 1 ? "" : "s") ago" }
        let days = hours / 24
        return "\(days) day\(days == 1 ? "" : "s") ago"
    }

    static func adoptHelp(_ kind: ProposableStatement) -> String {
        switch kind {
        case .editionBrief:
            return "Replace the prose of this brief with the proposal. Your rulings stay exactly "
                + "as they are; the proposal's glossary entries are added below them. One ⌘Z takes it back."
        case .visualLanguage:
            return "Replace this statement with the proposal. One ⌘Z takes it back."
        }
    }
    static func adoptAccessibilityLabel(_ kind: ProposableStatement) -> String {
        "Adopt the proposed \(kind.displayName)"
    }
    static func discardAccessibilityLabel(_ kind: ProposableStatement) -> String {
        "Discard the proposed \(kind.displayName)"
    }
    static func adoptedLine(glossary: Int) -> String {
        guard glossary > 0 else { return "Adopted." }
        return "Adopted, with \(glossary) glossary entr\(glossary == 1 ? "y" : "ies")."
    }
    static func firstAdoptCreatesLine(_ kind: ProposableStatement) -> String {
        "There is no \(kind.displayName) yet — Adopt creates it."
    }
    static func glossaryLine(count: Int) -> String? {
        guard count > 0 else { return nil }
        return "Carries \(count) glossary entr\(count == 1 ? "y" : "ies"), appended as rulings on Adopt."
    }
}
```

- [ ] **Step 4: Run the suites and the tripwires**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/StatementProposalGateTests -only-testing:MaughamTests/TripwireGrepTests -only-testing:MaughamTests/AnnotationChangeEventTests -only-testing:MaughamTests/StatementOpenGateTests`
Expected: all pass. `TripwireGrepTests.test_theStatementOpenGateIsTakenByExactlyTheseMembers` must be unchanged — this file takes no gate itself (it reaches it through `mutateStatementText`).

- [ ] **Step 5: Commit**

```bash
git add Maugham/Compiler/StatementProposalGate.swift MaughamTests/StatementProposalGateTests.swift
git commit -m "feat(translation-pipeline): StatementProposalGate — Adopt (essay replaced, rulings tail byte-identical, glossary through the one door, undoable) and Discard"
```

---

### Task 4: The diff and the banner — pure and value-taking

**Files:**
- Create: `Maugham/Views/StatementProposalDiff.swift`, `Maugham/Views/StatementProposalBanner.swift`
- Test: create `MaughamTests/StatementProposalBannerTests.swift`

**Interfaces:**
- Consumes: `StatementProposalStore.Proposal`, `StatementProposalCopy` (Task 3), `StatementEssay.half`, `StatementEssay.carriesRulings`.
- Produces:
  - `enum StatementProposalDiff { struct Line: Equatable { enum Kind { case same, added, removed }; let kind: Kind; let text: String }; static func lines(current: String, proposed: String) -> [Line]; static func compared(current: String, proposal: Proposal) -> (current: String, proposed: String) }` — `compared` takes the ESSAY half of both for a brief (the rulings tail is not on the table; a proposal's glossary lines are announced by `glossaryLine(count:)` instead) and the whole text for visual language.
  - `struct StatementProposalBanner: View { let proposal: Proposal; let current: String?; let statementExists: Bool; let glossaryCount: Int; let now: Date; let notice: String?; let busy: Bool; let onAdopt: () -> Void; let onDiscard: () -> Void }` — `current == nil` draws `noCurrentTextLine`; every string is `StatementProposalCopy`'s; buttons disabled while `busy`.
  - `StatementProposalBanner.Model` — `static func model(proposal:current:statementExists:now:) -> Model` with `title`, `when`, `rationale: String?`, `glossaryLine: String?`, `createsLine: String?`, `diff: [StatementProposalDiff.Line]`, so the whole banner's content is assertable unmounted.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Maugham
import MaughamCore

@MainActor
final class StatementProposalBannerTests: XCTestCase {

    private func proposal(_ kind: ProposableStatement, _ markdown: String,
                          rationale: String? = nil, at: Date = Date()) -> StatementProposalStore.Proposal {
        .init(kind: kind, markdown: markdown, rationale: rationale, proposedAt: at, author: "Claude")
    }

    func test_theDiffIsLineLevelAndKeepsOrder() {
        let lines = StatementProposalDiff.lines(current: "a\nb\nc", proposed: "a\nB\nc\nd")
        XCTAssertEqual(lines.map(\.kind), [.same, .removed, .added, .same, .added])
        XCTAssertEqual(lines.map(\.text), ["a", "b", "B", "c", "d"])
    }

    func test_anIdenticalTextIsAllSameAndAnEmptyCurrentIsAllAdded() {
        XCTAssertTrue(StatementProposalDiff.lines(current: "x\ny", proposed: "x\ny").allSatisfy { $0.kind == .same })
        XCTAssertTrue(StatementProposalDiff.lines(current: "", proposed: "x\ny").allSatisfy { $0.kind == .added })
    }

    /// The rulings tail is not on the table: Adopt never touches it, so the
    /// diff must not show it as removed.
    func test_aBriefIsComparedEssayToEssayAndVisualLanguageWhole() {
        let p = proposal(.editionBrief("es"), "New.\n\n## Rulings\n\n- «a» → «b»\n")
        let compared = StatementProposalDiff.compared(current: "Old.\n\n## Rulings\n\n- kept — ruled 1 Sep 2026, by hand\n", proposal: p)
        XCTAssertEqual(compared.current, "Old.")
        XCTAssertEqual(compared.proposed, "New.")
        let look = proposal(.visualLanguage, "New look.\n\n## Rulings\n\n- prose here\n")
        let whole = StatementProposalDiff.compared(current: "Old look.", proposal: look)
        XCTAssertEqual(whole.proposed, "New look.\n\n## Rulings\n\n- prose here\n")
    }

    func test_theModelCarriesEverySentenceTheBannerDraws() {
        let now = Date()
        let p = proposal(.editionBrief("es"), "New.\n\n## Rulings\n\n- «a» → «b»\n- «c» → «d»\n",
                         rationale: "the chapter is intimate", at: now.addingTimeInterval(-120))
        let model = StatementProposalBanner.model(proposal: p, current: nil, statementExists: false, now: now)
        XCTAssertEqual(model.title, StatementProposalCopy.bannerTitle(p))
        XCTAssertEqual(model.when, "2 minutes ago")
        XCTAssertEqual(model.rationale, "the chapter is intimate")
        XCTAssertEqual(model.glossaryLine, StatementProposalCopy.glossaryLine(count: 2))
        XCTAssertEqual(model.createsLine, StatementProposalCopy.firstAdoptCreatesLine(.editionBrief("es")))
        XCTAssertTrue(model.diff.allSatisfy { $0.kind == .added })

        let existing = StatementProposalBanner.model(proposal: p, current: "Old.", statementExists: true, now: now)
        XCTAssertNil(existing.createsLine)
        XCTAssertEqual(existing.diff.map(\.kind), [.removed, .added])
    }

    func test_aVisualLanguageProposalNeverAnnouncesGlossary() {
        let p = proposal(.visualLanguage, "Serif.")
        let model = StatementProposalBanner.model(proposal: p, current: "Sans.", statementExists: true, now: Date())
        XCTAssertNil(model.glossaryLine)
    }
}
```

- [ ] **Step 2: `./gen.sh`, run, see it fail**

Run: `./gen.sh` then `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/StatementProposalBannerTests`
Expected: compile failure.

- [ ] **Step 3: Implement the diff and the banner**

`Maugham/Views/StatementProposalDiff.swift`:

```swift
import Foundation
import MaughamCore

/// A line diff of the proposal against what the statement says now (spec §10:
/// "a hand-tuned brief must not be clobbered blind"). Line-level on purpose —
/// a statement is short prose, and a word-level diff of two paragraphs that
/// share a topic and nothing else is noise.
enum StatementProposalDiff {
    struct Line: Equatable {
        enum Kind: Equatable { case same, added, removed }
        let kind: Kind
        let text: String
    }

    /// Swift's `CollectionDifference` over lines, replayed in order so a
    /// removal is drawn where it was and an insertion where it lands.
    static func lines(current: String, proposed: String) -> [Line] {
        let old = current.isEmpty ? [] : current.components(separatedBy: "\n")
        let new = proposed.isEmpty ? [] : proposed.components(separatedBy: "\n")
        let diff = new.difference(from: old)
        let removed = Set(diff.removals.compactMap { change -> Int? in
            if case .remove(let offset, _, _) = change { return offset } else { return nil }
        })
        let inserted = Dictionary(uniqueKeysWithValues: diff.insertions.compactMap { change -> (Int, String)? in
            if case .insert(let offset, let element, _) = change { return (offset, element) } else { return nil }
        })
        var out: [Line] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count || newIndex < new.count {
            if let text = inserted[newIndex] {
                out.append(Line(kind: .added, text: text)); newIndex += 1; continue
            }
            if oldIndex < old.count, removed.contains(oldIndex) {
                out.append(Line(kind: .removed, text: old[oldIndex])); oldIndex += 1; continue
            }
            if oldIndex < old.count, newIndex < new.count {
                out.append(Line(kind: .same, text: new[newIndex])); oldIndex += 1; newIndex += 1; continue
            }
            break
        }
        return out
    }

    /// What is compared: the essay halves for a brief (Adopt never touches
    /// the rulings tail, so it is not on the table), the whole text for a
    /// visual language.
    static func compared(current: String, proposal: StatementProposalStore.Proposal)
        -> (current: String, proposed: String) {
        guard StatementEssay.carriesRulings(proposal.kind.statementKind) else {
            return (current, proposal.markdown)
        }
        return (StatementEssay.half(of: current), StatementEssay.half(of: proposal.markdown))
    }
}
```

`Maugham/Views/StatementProposalBanner.swift`:

```swift
import SwiftUI
import MaughamCore

/// The gate, drawn above a statement's editor while a proposal stands for it
/// (spec §10): who proposed what and when, why, the diff against the current
/// text, and Adopt / Discard. Value-taking; the pane owns the reads and the
/// verbs. Every sentence is `StatementProposalCopy`'s.
struct StatementProposalBanner: View {
    struct Model: Equatable {
        let title: String
        let when: String
        let rationale: String?
        let glossaryLine: String?
        let createsLine: String?
        let diff: [StatementProposalDiff.Line]
    }

    static func model(proposal: StatementProposalStore.Proposal, current: String?,
                      statementExists: Bool, now: Date) -> Model {
        let glossary: Int
        if case .editionBrief = proposal.kind {
            glossary = (try? StatementProposalStore.glossaryLines(in: proposal.markdown).count) ?? 0
        } else { glossary = 0 }
        let compared = StatementProposalDiff.compared(current: current ?? "", proposal: proposal)
        return Model(
            title: StatementProposalCopy.bannerTitle(proposal),
            when: StatementProposalCopy.bannerWhen(proposal.proposedAt, now: now),
            rationale: proposal.rationale?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? proposal.rationale : nil,
            glossaryLine: StatementProposalCopy.glossaryLine(count: glossary),
            createsLine: statementExists ? nil : StatementProposalCopy.firstAdoptCreatesLine(proposal.kind),
            diff: StatementProposalDiff.lines(current: compared.current, proposed: compared.proposed))
    }

    let proposal: StatementProposalStore.Proposal
    let current: String?
    let statementExists: Bool
    let now: Date
    let notice: String?
    let busy: Bool
    let onAdopt: () -> Void
    let onDiscard: () -> Void

    private var model: Model {
        Self.model(proposal: proposal, current: current, statementExists: statementExists, now: now)
    }

    var body: some View {
        let model = model
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(model.title).font(.callout.weight(.medium))
                Text(model.when).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Button(StatementProposalCopy.discardTitle, action: onDiscard)
                    .controlSize(.small)
                    .disabled(busy)
                    .help(StatementProposalCopy.discardHelp)
                    .accessibilityLabel(StatementProposalCopy.discardAccessibilityLabel(proposal.kind))
                Button(StatementProposalCopy.adoptTitle, action: onAdopt)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
                    .help(StatementProposalCopy.adoptHelp(proposal.kind))
                    .accessibilityLabel(StatementProposalCopy.adoptAccessibilityLabel(proposal.kind))
            }
            if let rationale = model.rationale {
                Text(StatementProposalCopy.rationaleHeading).font(.caption).foregroundStyle(.secondary)
                Text(rationale).font(.callout)
            }
            if let line = model.createsLine { Text(line).font(.caption).foregroundStyle(.secondary) }
            if let line = model.glossaryLine { Text(line).font(.caption).foregroundStyle(.secondary) }
            Text(StatementProposalCopy.diffHeading).font(.caption).foregroundStyle(.secondary)
            if current == nil {
                Text(StatementProposalCopy.noCurrentTextLine).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.diff.enumerated()), id: \.offset) { _, line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(.body, design: .serif))
                            .strikethrough(line.kind == .removed)
                            .underline(line.kind == .added)
                            .foregroundStyle(line.kind == .removed ? Color.red
                                             : line.kind == .added ? Color.green : Color.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxHeight: Self.diffCeiling)
            if let notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.title)
    }

    /// The diff scrolls past this rather than pushing the editor off the pane.
    static let diffCeiling: CGFloat = 220
}
```

- [ ] **Step 4: Run, pass, commit**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/StatementProposalBannerTests -only-testing:MaughamTests/TripwireGrepTests -only-testing:MaughamTests/AnnotationChangeEventTests`
Expected: pass.

```bash
git add Maugham/Views/StatementProposalDiff.swift Maugham/Views/StatementProposalBanner.swift MaughamTests/StatementProposalBannerTests.swift
git commit -m "feat(views): StatementProposalDiff + StatementProposalBanner — the gate's diff and verbs, value-taking"
```

---

### Task 5: The gate in `StatementPane`

**Files:**
- Modify: `Maugham/Views/StatementPane.swift` (`body` ~line 170, the `.task` block, a new MARK section after `resolveLiveParagraphIds`)
- Test: `MaughamTests/StatementPaneStrataTests.swift` (add a mounted case beside `test_aRulingReachesTheMountedPane`, ~line 1336) and `MaughamTests/StatementPaneTests.swift` (add the pure `proposalSlot(kind:scope:)` case)

**Interfaces:**
- Consumes: `StatementProposalStore.pending(for:)`, `ProposableStatement(kind:)`, `StatementProposalGate.adopt/discard`, `StatementProposalBanner`, `.onProjectEvent`, `WindowAccessor` (as `DepartmentPaneHost` uses it: `@State private var window: NSWindow?` + `.background(WindowAccessor(window: $window))`).
- Produces: `static func StatementPane.proposalSlot(kind: Statement.Kind, scope: Statement.Scope) -> ProposableStatement?` — pure: nil for `.intent`, nil for any `.document` scope, else the proposable kind. New `@State` on the pane: `pendingProposal: StatementProposalStore.Proposal?`, `proposalReloads: Int`, `proposalNotice: String?`, `proposalBusy: Bool`, `window: NSWindow?`.

- [ ] **Step 1: Write the failing tests**

In `MaughamTests/StatementPaneTests.swift` add:

```swift
    /// **Only a brief or the visual language can carry a proposal**, and only
    /// at project scope — craft intent is unrepresentable (`ProposableStatement`
    /// has no case for it), and a document-scoped statement is intent by
    /// construction.
    func test_theProposalSlotIsNilForIntentAndForAnyDocumentScope() {
        XCTAssertNil(StatementPane.proposalSlot(kind: .intent, scope: .project))
        XCTAssertNil(StatementPane.proposalSlot(kind: .intent, scope: .document("d1")))
        XCTAssertNil(StatementPane.proposalSlot(kind: .editionBrief("es"), scope: .document("d1")))
        XCTAssertEqual(StatementPane.proposalSlot(kind: .editionBrief("es"), scope: .project), .editionBrief("es"))
        XCTAssertEqual(StatementPane.proposalSlot(kind: .visualLanguage, scope: .project), .visualLanguage)
        XCTAssertNil(StatementPane.proposalSlot(kind: .unknown("later"), scope: .project))
    }
```

In `MaughamTests/StatementPaneStrataTests.swift`, beside `test_aRulingReachesTheMountedPane`:

```swift
    // MARK: - The proposal gate (translation pipeline P5)

    /// **A proposal staged behind the pane draws the gate without a remount**,
    /// and Adopt puts the words in the editor and clears the banner.
    func test_aStagedProposalReachesTheMountedPaneAndAdoptWritesTheEssay() async throws {
        let fixture = try await StatementMountFixture.novel(named: "mounted-proposal")
        defer { fixture.tearDown() }
        let window = await fixture.host(kind: .visualLanguage, subject: .project, bible: nil, world: nil)
        let title = StatementProposalCopy.bannerTitle(.init(
            kind: .visualLanguage, markdown: "x", rationale: nil, proposedAt: Date(), author: "Claude"))
        XCTAssertTrue(try fixture.staticTexts(in: window, containing: title).isEmpty)

        _ = try StatementProposalStore(projectURL: fixture.projectURL).stage(.init(
            kind: .visualLanguage, markdown: "Serif, generous leading.",
            rationale: "the sample pages are dense", proposedAt: Date(), author: "Claude"))
        MaughamEvent.postStatementProposalsChanged(projectURL: fixture.projectURL)
        await fixture.pumpUntil(deadline: 5) { fixture.shows(title, in: window) }
        XCTAssertFalse(try fixture.staticTexts(in: window, containing: title).isEmpty,
                       "a proposal that landed while the pane was open never reached the gate")
        XCTAssertFalse(try fixture.staticTexts(in: window, containing: "the sample pages are dense").isEmpty)

        let proposal = try XCTUnwrap(StatementProposalStore(projectURL: fixture.projectURL).pending(for: .visualLanguage))
        _ = try await StatementProposalGate.adopt(proposal, store: fixture.store, world: nil,
                                                  undoManager: nil, workTaskSink: { _ in })
        await fixture.pumpUntil(deadline: 5) { !fixture.shows(title, in: window) }
        XCTAssertTrue(try fixture.staticTexts(in: window, containing: title).isEmpty, "Adopt clears the gate")
        await fixture.pumpUntil(deadline: 5) {
            (try? fixture.textView(in: window).string.contains("Serif, generous leading.")) == true
        }
        XCTAssertTrue(try fixture.textView(in: window).string.contains("Serif, generous leading."),
                      "the adopted words did not reach the mounted editor")
    }
```

(Use the fixture's real signatures — `host(kind:subject:bible:world:)`, `shows(_:in:)`, `staticTexts(in:containing:)`, `textView(in:)`, `pumpUntil(deadline:_:)` — as `test_aRulingReachesTheMountedPane` spells them; if `bible:`/`world:` are non-optional there, pass the same `BibleStore`/`DeclaredWorldStore` that test constructs.)

- [ ] **Step 2: Run to see them fail**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/StatementPaneTests -only-testing:MaughamTests/StatementPaneStrataTests/test_aStagedProposalReachesTheMountedPaneAndAdoptWritesTheEssay`
Expected: compile failure on `proposalSlot`.

- [ ] **Step 3: Wire the pane**

In `StatementPane`:

```swift
    // MARK: - The proposal gate (translation pipeline P5, spec §10)

    /// Which proposal slot this pane's statement can have, or nil. Pure, so
    /// `StatementPaneTests` asks it over the product of its inputs: intent has
    /// no slot (unrepresentable), and a document scope is intent by
    /// construction — a brief and the visual language are project-scope only.
    static func proposalSlot(kind: Statement.Kind, scope: Statement.Scope) -> ProposableStatement? {
        guard case .project = scope else { return nil }
        return ProposableStatement(kind: kind)
    }

    @State private var pendingProposal: StatementProposalStore.Proposal?
    @State private var proposalReloads = 0
    @State private var proposalNotice: String?
    @State private var proposalBusy = false
    @State private var window: NSWindow?
    @Environment(\.undoManager) private var undoManager

    private struct ProposalTaskKey: Equatable { let slot: ProposableStatement?; let reloads: Int }

    /// Reads the slot. A `.task`, never `body` (tripwire 4) — it is a JSON
    /// read under `.maugham/`. Re-keyed by the event so a tool staging a
    /// proposal behind the pane draws the gate without a remount.
    private func reloadProposal() {
        guard let slot = Self.proposalSlot(kind: kind, scope: scope) else {
            pendingProposal = nil
            return
        }
        pendingProposal = StatementProposalStore(projectURL: store.url).pending(for: slot)
    }

    @ViewBuilder
    private var proposalGate: some View {
        if let proposal = pendingProposal {
            let statement = store.statement(kind: kind, scope: scope)
            StatementProposalBanner(
                proposal: proposal,
                current: statement.flatMap { try? store.statementText(of: $0) },
                statementExists: statement != nil,
                now: Date(),
                notice: proposalNotice,
                busy: proposalBusy,
                onAdopt: { adopt(proposal) },
                onDiscard: { discard(proposal) })
            Divider()
        }
    }

    private func adopt(_ proposal: StatementProposalStore.Proposal) {
        proposalBusy = true
        let um = undoManager
        Task { @MainActor in
            defer { proposalBusy = false }
            do {
                let adoption = try await StatementProposalGate.adopt(
                    proposal, store: store, world: world, undoManager: um, workTaskSink: { _ in })
                proposalNotice = StatementProposalCopy.adoptedLine(glossary: adoption.glossaryAppended)
            } catch {
                proposalNotice = "\(error)"
            }
            reloadProposal()
        }
    }

    private func discard(_ proposal: StatementProposalStore.Proposal) {
        do {
            try StatementProposalGate.discard(proposal.kind, store: store)
            proposalNotice = nil
        } catch {
            proposalNotice = "\(error)"
        }
        reloadProposal()
    }
```

In `body`, between `Divider()` and `StatementEditorHost(...)`, insert `proposalGate`. Add to the view's modifier chain (after the existing `.task(id: liveParagraphTaskKey)`):

```swift
        .task(id: ProposalTaskKey(slot: Self.proposalSlot(kind: kind, scope: scope), reloads: proposalReloads)) {
            reloadProposal()
        }
        .onProjectEvent(.maughamStatementProposalsChanged, url: store.url, window: window) { _ in
            proposalReloads += 1
        }
        .background(WindowAccessor(window: $window))
```

The `current:` read in `proposalGate` is `store.statementText(of:)` — the same fringe reader `rulings` already calls synchronously in `body` (the doc comment on `rulings` says why that is tripwire-4-safe: the live `Document` when the pane has it open, else the derivation cache). Keep the `try?` shape `rulings` uses.

**Adopt while the pane's editor is bound:** `mutateStatementText` finds the pane's live `Document` through `openStatementDocument(id:)` and writes into it, so the editor's binding shows the new essay on the next frame with no reload — the same path a ruling landing from a run takes (`test_aRulingReachesTheMountedPane`). **A first Adopt on a scope with no statement** creates it under the gate; the pane's host has `resolvedScope` set for an empty scope and no `Document` bound, so after Adopt the host must reconcile — bump nothing: `StatementEditorHost` re-runs `reconcile` on its `.task(id: scopeKey)` only on a scope change. **So after a `created == true` Adopt, force the host to re-resolve** by giving `StatementEditorHost` an `.id(hostGeneration)` where `hostGeneration` is a pane `@State` incremented only in that arm — this is a REMOUNT, which `StatementPane.body`'s comment forbids for scope changes because it splits close from load; here there is no `Document` to close (the host bound none — the scope had no statement), so the hazard the comment describes cannot arise. Say so in a comment at the increment. (If the reviewer finds a cheaper hook already on the host, use it.)

- [ ] **Step 4: Run the pane suites, the tripwires, and the strata suite whole**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/StatementPaneTests -only-testing:MaughamTests/StatementPaneStrataTests -only-testing:MaughamTests/StatementDraftHandoffTests -only-testing:MaughamTests/StatementEditorMountTests -only-testing:MaughamTests/StatementPaneSelectionDeliveryTests -only-testing:MaughamTests/TripwireGrepTests -only-testing:MaughamTests/AnnotationChangeEventTests`
Expected: all pass. If a mounted click test is red, check `ioreg -n Root -d1 | grep ScreenIsLocked` before blaming the change.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Views/StatementPane.swift MaughamTests/StatementPaneTests.swift MaughamTests/StatementPaneStrataTests.swift
git commit -m "feat(views): the proposal gate in StatementPane — banner, diff, Adopt/Discard, re-read on the changed event"
```

---

### Task 6: The "proposed" marks — the desk's language row and the Visual Language segment

**Files:**
- Modify: `Maugham/Views/Publish/DepartmentPane.swift` (a `var proposedBriefs: Set<String> = []` and `var proposedWithoutRow: [String] = []` beside `unreadable`; `languageRow` ~line 630; a line at the foot of the Languages section; `DepartmentDesk` statics ~line 868)
- Modify: `Maugham/Views/Publish/DepartmentPaneHost.swift` (a `@State private var proposals: [StatementProposalStore.Proposal] = []` read beside the design `proposals` in the same `.task`; an `.onProjectEvent(.maughamStatementProposalsChanged, …)` beside the design one at ~line 265; the two values passed to `DepartmentPane`)
- Modify: `Maugham/Views/DetailPaneToggle.swift` (a third `badge(over: .visualLanguage, …)` overlay; `@State private var visualLanguageProposed = false` read in a `.task(id: projectURL)` and re-read on the event)
- Test: `MaughamTests/DepartmentPaneTests.swift` (copy + the forbidden-name census), `MaughamTests/DetailPaneToggleTests.swift` or wherever `badgeOffset` is tested (`grep -rn badgeOffset MaughamTests`)

**Interfaces:**
- Consumes: `StatementProposalStore.pendingAll()`, `ProposableStatement`, `DetailPaneToggle.badge(over:count:tint:help:)`.
- Produces: `DepartmentDesk.proposedBadge = "Proposed"`, `DepartmentDesk.proposedHelp(language:) -> String`, `DepartmentDesk.proposedWithoutRowLine(language:) -> String` (*"Claude proposed a brief for Italian — open it to adopt or discard."*), `DepartmentPaneHost.proposedLanguages(_ proposals: [Proposal]) -> Set<String>` (static, pure), `DepartmentPaneHost.proposedWithoutRow(_ proposals:, rows: [EditionStatus.LanguageRow]) -> [String]` (static, pure), `DetailPaneToggle.visualLanguageBadgeHelp`.

- [ ] **Step 1: Write the failing tests**

In `DepartmentPaneTests` add:

```swift
    // MARK: - The "proposed" mark (translation pipeline P5)

    func test_aPendingBriefProposalMarksItsRowAndOnlyItsRow() throws {
        let proposals: [StatementProposalStore.Proposal] = [
            .init(kind: .editionBrief("es"), markdown: "x", rationale: nil, proposedAt: Date(), author: "Claude"),
            .init(kind: .visualLanguage, markdown: "x", rationale: nil, proposedAt: Date(), author: "Claude"),
        ]
        XCTAssertEqual(DepartmentPaneHost.proposedLanguages(proposals), ["es"])
        let rows = [EditionStatus.LanguageRow(language: "es", translator: nil, fresh: 0, stale: 0, missing: 0, openQueries: 0)]
        XCTAssertEqual(DepartmentPaneHost.proposedWithoutRow(proposals, rows: rows), [])
        XCTAssertEqual(DepartmentPaneHost.proposedWithoutRow(proposals, rows: []), ["es"],
                       "a proposal for a language the desk has no row for still needs a door")
        XCTAssertEqual(DepartmentDesk.proposedBadge, "Proposed")
        XCTAssertEqual(DepartmentDesk.proposedWithoutRowLine(language: "it"),
                       "Claude proposed a brief for Italian — open it to adopt or discard.")
        XCTAssertTrue(DepartmentDesk.proposedHelp(language: "es").contains("Edition Brief"))
    }
```

And add `"StatementProposalStore"` to the forbidden list in `test_theSourceReadsNoStoreAtAll`.

Where `badgeOffset` is tested, add:

```swift
    func test_theVisualLanguageSegmentBadgesWhenAProposalStands() {
        XCTAssertEqual(DetailPaneToggle.badgeOffset(of: .visualLanguage, in: [.diagnostics, .intent, .visualLanguage, .inspector]), 1)
        XCTAssertTrue(DetailPaneToggle.visualLanguageBadgeHelp.contains("⌘⌥V"))
    }
```

- [ ] **Step 2: Run to see them fail**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/DepartmentPaneTests`
Expected: compile failure on `proposedLanguages`.

- [ ] **Step 3: Implement**

`DepartmentPane`: add the two `var`s (defaulted, so every existing call site compiles); in `languageRow`, after the language name `Text`, draw the badge exactly as `designRow` draws `design.pendingBadge` (`.font(.caption2)`, `.padding`, accent capsule) when `proposedBriefs.contains(row.language)`, with `.help(DepartmentDesk.proposedHelp(language: row.language))`; at the foot of the Languages section, `ForEach(proposedWithoutRow, id: \.self) { language in HStack { Text(DepartmentDesk.proposedWithoutRowLine(language: language)).font(.caption).foregroundStyle(.secondary); Spacer(); Button(DepartmentDesk.editionBriefTitle) { openEditionBrief(language) }.controlSize(.small) } }`. Statics:

```swift
    static let proposedBadge = "Proposed"
    static func proposedHelp(language: String) -> String {
        "Claude proposed a brief for "
            + TranslationReviewIndicator.displayLabel(forLanguageTag: language)
            + ". Open Edition Brief to adopt or discard it."
    }
    static func proposedWithoutRowLine(language: String) -> String {
        "Claude proposed a brief for "
            + TranslationReviewIndicator.displayLabel(forLanguageTag: language)
            + " — open it to adopt or discard."
    }
```

`DepartmentPaneHost`: in the same `.task` that lists design proposals (~line 973), also `proposals = StatementProposalStore(projectURL: projectURL).pendingAll()` into a `statementProposals` state; add `.onProjectEvent(.maughamStatementProposalsChanged, url: projectURL, window: window) { _ in refreshes += 1 }`; pass `proposedBriefs: Self.proposedLanguages(statementProposals)` and `proposedWithoutRow: Self.proposedWithoutRow(statementProposals, rows: languages)`:

```swift
    static func proposedLanguages(_ proposals: [StatementProposalStore.Proposal]) -> Set<String> {
        Set(proposals.compactMap { if case .editionBrief(let l) = $0.kind { return l.lowercased() } else { return nil } })
    }
    static func proposedWithoutRow(_ proposals: [StatementProposalStore.Proposal],
                                   rows: [EditionStatus.LanguageRow]) -> [String] {
        let present = Set(rows.map { $0.language.lowercased() })
        return proposedLanguages(proposals).filter { !present.contains($0) }.sorted()
    }
```

The Edition Brief door already find-or-creates the statement (`DepartmentPaneHost.openBrief`), and the pane it presents is `StatementPane` at `.project` scope — Task 5's gate draws there with no further wiring, and `created` is false for it (the door minted the statement), which is the honest reading: the door made the file, Adopt fills it.

`DetailPaneToggle`: 

```swift
    @State private var visualLanguageProposed = false
    @State private var proposalReloads = 0
    static let visualLanguageBadgeHelp = "Claude proposed a visual language — open it to adopt or discard (\u{2318}\u{2325}V)"
```

a third overlay on the picker: `badge(over: .visualLanguage, count: visualLanguageProposed ? 1 : 0, tint: .accentColor, help: Self.visualLanguageBadgeHelp)`; a `.task(id: "\(projectURL?.path ?? "")|\(proposalReloads)") { guard let projectURL else { visualLanguageProposed = false; return }; visualLanguageProposed = StatementProposalStore(projectURL: projectURL).pending(for: .visualLanguage) != nil }`; and, if `DetailPaneToggle` has no `window` state, add `@State private var window: NSWindow?` + `.background(WindowAccessor(window: $window))` and `.onProjectEvent(.maughamStatementProposalsChanged, url: projectURL ?? URL(fileURLWithPath: "/"), window: window) { _ in proposalReloads += 1 }` guarded so it is only attached when `projectURL` is non-nil (wrap in `if let projectURL` via a small `ViewModifier`, the file's own idiom for conditional modifiers — extract one rather than growing `body`).

- [ ] **Step 4: Run the suites, the tripwires, and a Release build if `ProjectWindow.body` was touched (it should not be)**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/DepartmentPaneTests -only-testing:MaughamTests/DepartmentRunTests -only-testing:MaughamTests/DetailPaneToggleTests -only-testing:MaughamTests/TripwireGrepTests -only-testing:MaughamTests/AnnotationChangeEventTests`
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Views/Publish/DepartmentPane.swift Maugham/Views/Publish/DepartmentPaneHost.swift Maugham/Views/DetailPaneToggle.swift MaughamTests/DepartmentPaneTests.swift
git commit -m "feat(views): the proposed mark on the desk's language row and the Visual Language segment"
```

(Add the badge test file to the `git add` line under whatever name it lives in.)

---

### Task 7: The two skills and the two pointers

**Files:**
- Create: `docs/skills/edition-brief/SKILL.md`, `docs/skills/visual-language/SKILL.md`
- Modify: `docs/skills/maugham-bootstrap/SKILL.md` (the `read_visual_language` paragraph, ~lines 50–69, and its "Absence is an answer" paragraph), `docs/skills/translation-pass/SKILL.md` (the "in-app pipeline" section's first bullet, ~line 34), `Maugham/MCP/AREA.md` ("Three skills are served today" → five, naming them), `docs/guide/claude-desktop.md` (the "Load Maugham's own task procedures" bullet names the two interviews; a Write bullet: *"Propose an edition brief or a visual language for you to adopt or discard — never written for you"*)
- Test: `MaughamTests/SkillIndexTests.swift` line 101's list

**Interfaces:** none — content. The skills are served by the existing `SkillIndex` (folder glob in `project.yml`, alphabetical), so the served list becomes `["edition-brief", "editing-pass", "transcribing-notebooks", "translation-pass", "visual-language"]`.

- [ ] **Step 1: Update the served-skills assertion**

In `SkillIndexTests.test_bundledSkills_loadAndAreNonEmpty` change the expected array to `["edition-brief", "editing-pass", "transcribing-notebooks", "translation-pass", "visual-language"]`. Run `-only-testing:MaughamTests/SkillIndexTests` and see it fail.

- [ ] **Step 2: Write `docs/skills/edition-brief/SKILL.md`**

Voice: `editing-pass`'s — second person, the writer's professional, numbered "what matters". Frontmatter `name: edition-brief`, `description: Interview the writer and draft an edition brief for one language of a Maugham project, then propose it for their Adopt/Discard. Use when asked to set up, draft, or revise how a translated edition should read.` Body, in this order, ≥200 characters (the test's floor) and in the shape spec §10 names:

1. **What this is** — a brief is the writer's doctrine for one edition; you draft it, they adopt it; you never write it. The tool is `propose_edition_brief`; the writer sees a diff and Adopt/Discard in Maugham.
2. **Read first, in this order:** `read_craft_intent` (project), `read_edition_brief` for the language (a prior session's rulings may already answer what you are about to ask; an existing brief means you are REVISING and the diff will show every change), one sample chapter via `read_document`, the palette via `list_palette_cards`.
3. **Interview, one question at a time**, naming the target culture's default before each: texture and content (spec §1.1 — what the prose does that a translator must keep), **what you won't let a translator smooth** (repetitions, fragments, the deliberately plain word), variety (es-ES / es-419, pt-BR / pt-PT, fr-FR / fr-CA), forms of address (tú/usted, tu/vous, keigo level), typographic conventions (quotation marks, dashes, numerals, capitalisation of titles), the first glossary entries — every proper name in the sample chapter with a proposed rendering, and any term the book uses as a term.
4. **Draft** — prose sections for register, address, what stays untranslated, typography; then a `## Rulings` section holding ONLY glossary lines of the shape `- «term» → «rendering» (note)`. Nothing else goes under that heading (a directive is the writer's, made in Maugham with Translator's note…). No em-dashes, no guillemets inside a term or rendering, one line per entry.
5. **End by calling `propose_edition_brief`** with `language`, the whole `markdown`, and a one-or-two-sentence `rationale`. Never paste the brief into chat as the deliverable. Tell the writer where the gate is (the tool's `adoptWhere`). A second call for the same language replaces the pending proposal.

- [ ] **Step 3: Write `docs/skills/visual-language/SKILL.md`**

Frontmatter `name: visual-language`, `description: Interview the writer and draft a visual language — how the book should look — for a Maugham project, then propose it for their Adopt/Discard. Use when asked to design, set up, or describe a book's typography, trim, or look before authoring a template.` Body:

1. **What this is** — the visual language is the writer's statement of how the book looks; a template-authoring session reads it (`read_visual_language`) and must not decide taste on their behalf. You draft; they adopt.
2. **Read first:** `read_visual_language` (an existing one means you are revising), `get_outline` (what kinds of piece the book has — verse, letters, sluglines — because the look has to afford them), the palette (`list_palette_cards`, the story's world, an input but NOT the look), `get_publish_config` for the trim and formats already declared.
3. **Interview, one question at a time:** trim and margins (the physical object — pocket, trade, large-format), type (serif or sans, old-style or modern, the feel in three words, a face they love), scale and leading (dense or airy), ornament (section breaks, drop caps, running heads, none), what varies per piece and what never does, the sample-page questions the designer is briefed on — the chapter opener, a page of dialogue, a page of verse or letters if the book has them, the title page.
4. **Draft** — freeform prose, the writer's voice, no `## Rulings` section (visual language has none; the tool refuses one). Reference images by project-relative path only if the writer named them.
5. **End by calling `propose_visual_language`** with the whole `markdown` and a short `rationale`. Never paste it as the deliverable; tell the writer the gate is the Visual Language pane (⌘⌥V).

- [ ] **Step 4: Repoint the two existing skills and the two docs**

`maugham-bootstrap/SKILL.md`: after "Read it before writing a template and before revising one …" add one sentence: *"If it does not exist, do not invent one: run the `visual-language` skill (get_help topic `"skills"`, then `"visual-language"`) — it interviews the writer and proposes a statement they adopt in Maugham, and only then author the template against what they adopted."* Change the "Absence is an answer" paragraph's last clause to say the same skill is the way the writer's answer reaches the pane.

`translation-pass/SKILL.md`: in the first bullet under "Two consequences", after "Read `read_edition_brief` … before you translate a word.", add: *"No brief for the language yet? Run the `edition-brief` skill first — it interviews the writer and proposes one they adopt in Maugham — rather than deciding register on your own."*

`Maugham/MCP/AREA.md`: "Three skills are served today: `transcribing-notebooks`, `editing-pass`, `translation-pass`." → "Five skills are served today: `edition-brief`, `editing-pass`, `transcribing-notebooks`, `translation-pass`, `visual-language` (the first and last are the translation pipeline P5 interviews; each ends by calling its propose tool)."

`docs/guide/claude-desktop.md`: extend the "Load Maugham's own task procedures" bullet: *"… or an editing pass, or an interview that drafts an edition brief or a visual language for you to adopt"*; add under Write: *"- Propose an edition brief or a visual language — a draft staged for you, shown as a diff against your own text with Adopt / Discard; Claude never writes a statement for you"*.

- [ ] **Step 5: Run the suites**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/SkillIndexTests -only-testing:MaughamTests/ClaudeCodeSkillInstallTests -only-testing:MaughamTests/DocSyncTests -only-testing:MaughamTests/GuideDocsDriftTests -only-testing:MaughamTests/TripwireGrepTests -only-testing:MaughamTests/AnnotationChangeEventTests`
Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add docs/skills/edition-brief/SKILL.md docs/skills/visual-language/SKILL.md docs/skills/maugham-bootstrap/SKILL.md docs/skills/translation-pass/SKILL.md Maugham/MCP/AREA.md docs/guide/claude-desktop.md MaughamTests/SkillIndexTests.swift
git commit -m "docs(skills): edition-brief and visual-language interviews; bootstrap and translation-pass point at them"
```

---

### Task 8: Docs, ADR 0030 §7 amended, roadmap flipped, AREA entries, the P5 handoff

**Files:**
- Modify: `docs/guide/right-pane.md` (the "designed but not yet shipped" paragraph, ~line 85, and a short paragraph in "Visual Language mode (⌘⌥V)" ~line 103), `docs/guide/publish-department.md` ("The brief and rulings", ~line 326), `docs/roadmap.md` (the translation-pipeline entry at ~line 243: title `P1–P4 shipped; P5 proposals pending` → `P1–P5 shipped — COMPLETE (2026-09-02)`, and its *Not built:* sentence becomes a **P5 —** paragraph), `docs/adr/0030-three-people-seven-legs-directives-as-rulings.md` §7, `docs/adr/README.md` (the 0030 row's title gains "and proposals into statements"), `Maugham/Views/AREA.md` (the `StatementPane.swift` bullet gains item (4): the gate; a line for `StatementProposalBanner.swift`/`StatementProposalDiff.swift`), `Maugham/Stores/AREA.md` (a `.maugham/statements/proposals/<key>.json` row in the layout table + a short `StatementProposalStore` section after `DesignProposalStore`'s), `Maugham/Compiler/AREA.md` (one line naming `StatementProposalGate` as the one write beside `RulingPerformer`), `CLAUDE.md` (the `Maugham/Publish/` row's "**Plan 5 … is NOT built**" sentence → what shipped; the `Maugham/Views/` row unchanged), README if it lists tool counts (`grep -n tools README.md` — it does not today)
- Create: `docs/superpowers/notes/2026-09-02-translation-pipeline-p5-handoff.md`

- [ ] **Step 1: `right-pane.md`**

Replace the paragraph beginning "Letting Claude Desktop draft an edition brief or a visual language statement" with:

> **Claude can propose a brief or a visual language, and you adopt it — or don't.** From Claude Desktop or Claude Code, the `edition-brief` and `visual-language` skills interview you and end by staging a draft (nothing is written). When one is waiting, the statement's pane shows a banner — *Claude proposed a Spanish edition brief · 12 minutes ago* — with its reasons, a line-by-line diff against your current text, and **Adopt** / **Discard**. Adopt replaces the prose through the same path as your own typing (one ⌘Z takes it back), leaves your Rulings exactly as they were, and appends any glossary entries the proposal carried as rulings; a first Adopt on a language with no brief creates it. Discard clears it. A newer proposal replaces a pending one. Craft intent can't be proposed at all — there is no tool for it, on purpose.

Under "Visual Language mode (⌘⌥V)" add one sentence: *"A dot on the ⌘⌥V segment means a proposal is waiting here."*

- [ ] **Step 2: `publish-department.md`**

After "…not treat as a suggestion." in "The brief and rulings", add:

> A **Proposed** mark on a language row means Claude has drafted a brief for that edition (through the `edition-brief` skill); open Edition Brief to see the diff and Adopt or Discard it. A proposal for a language the desk has no row for yet is listed beneath the rows with its own Edition Brief door — adopting it is how that edition gets its first brief.

- [ ] **Step 3: ADR 0030 §7**

Retitle §7 *"Proposals into statements stop at the door — built in Plan 5 (2026-09-02)"* and replace its second paragraph ("**None of that exists on any branch as of this ADR.** …") with: *"**Built in Plan 5.** `StatementProposalStore` (`.maugham/statements/proposals/<key>.json`, derived, one pending slot per key, kind `ProposableStatement.editionBrief(String) | .visualLanguage`), the two tools in the catalogue (56 → 58; neither in `CompilerAllowlist`; `CompilerAllowlistTests.statementWriters` widened to `edition_brief`/`visual_language` and a `propose_` predicate that catches `propose_craft_intent` and passes exactly the two), the gate in `StatementPane` (`StatementProposalBanner` over `StatementProposalDiff`; Adopt = `StatementProposalGate.adopt`, the one write — a writer's click — through `mutateStatementText` + `StatementEssay.recomposed` so the `## Rulings` tail is byte-identical, then one `RulingPerformer.rule` per glossary line; Discard clears the slot), the "proposed" marks, and the `edition-brief`/`visual-language` skills. The decision stands as written: a proposal that arrived as anything but a staged draft the writer adopts would be `write_edition_brief` wearing a new name — grep the catalogue for what ships."* Keep §8's clause unchanged. Add the ADR README title suffix.

- [ ] **Step 4: Roadmap, CLAUDE.md, AREA files**

Roadmap: flip the heading and replace the *Not built:* sentence with a **P5 — proposals into statements** paragraph (2026-09-02, branch `translation-pipeline-p5`) naming the store, the two tools (count 56→58), the gate and its three guarantees (essay replaced through the ordinary write path and undoable; rulings tail byte-identical; glossary lines through `RulingPerformer.rule`), the two marks, the two skills, and the census. Docs links unchanged.

CLAUDE.md `Maugham/Publish/` row: replace "**Plan 5 (proposals into statements: … ) is NOT built** — ADR 0030 §7 records the decision, not a shipped feature." with "**Plan 5 (2026-09-02) built proposals into statements**: `propose_edition_brief`/`propose_visual_language` stage a draft under `.maugham/statements/proposals/` and the writer adopts or discards it at `StatementPane`'s gate with a diff (`StatementProposalGate.adopt` is the one write, a click; ADR 0030 §7 amended)."

`Maugham/Views/AREA.md` `StatementPane.swift` bullet — append item (4): *"**(4) The proposal gate (P5).** `StatementPane.proposalSlot(kind:scope:)` says whether this statement can have one (a brief or the visual language, project scope; intent never — `ProposableStatement` has no case for it); the slot is read in a `.task` and re-read on `.maughamStatementProposalsChanged`; `StatementProposalBanner` (value-taking) draws it over `StatementProposalDiff`'s line diff of the ESSAY halves; Adopt runs `StatementProposalGate.adopt`, which writes into the pane's own live `Document` when it has one bound, so the editor shows the words with no reload; a first Adopt that created the statement remounts the host once, and that remount is safe because there was no `Document` to close."* Add a line: `StatementProposalBanner.swift` / `StatementProposalDiff.swift` — the gate's view and diff.

`Maugham/Stores/AREA.md`: table row `| .maugham/statements/proposals/<key>.json | StatementProposalStore | A staged proposal for a brief (edition-brief-<tag>) or the visual language; derived; one pending slot per key |` and a short section mirroring `DesignProposalStore`'s (what it stores, that it never writes a statement, that reads carry `adr-0018-ok`, that `MaughamSidecarPath` routes it to `.unknownSidecar` deliberately).

`Maugham/Compiler/AREA.md`: one sentence beside `RulingPerformer`'s: *"`StatementProposalGate` (P5) is the second and last writer-facing door into a statement's ESSAY: Adopt, a click on a staged proposal, through `mutateStatementText`; its glossary lines still go through `RulingPerformer.rule`."*

- [ ] **Step 5: The P5 handoff**

Create `docs/superpowers/notes/2026-09-02-translation-pipeline-p5-handoff.md` in the P4 handoff's shape: where things stand (branch, base, merge commit — fill the merge commit after the merge, as P4's `aa028ca6` did), what P5 built by file, carried-forward items (from the ledger's minor-deferred list), rulings made during execution, the gate record (both xcresults, screen lock state, skip list), and process lessons. **It must carry the owed smokes, not silently drop them:**

> ## Smokes owed to Denver
> - **P2:** the ⌘⌥C Translator's note manual smoke; the P3 unlocked re-gate.
> - **P4:** click-through end to end in a real window (a report row → the paragraph in Translation Review); Run Whole Book over a real imprint; the Help topic's first table (the glossary table in the statement pane); ⌘⌥C Translator's note (still owed).
> - **P5:** from Claude Desktop, run the `edition-brief` skill against a real project, see the Proposed mark on the desk row, open Edition Brief, read the diff, Adopt, ⌘Z; the same for `visual-language` and the ⌘⌥V badge.

- [ ] **Step 6: Run the doc suites and commit**

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/DocSyncTests -only-testing:MaughamTests/GuideDocsDriftTests -only-testing:MaughamTests/TripwireGrepTests -only-testing:MaughamTests/AnnotationChangeEventTests`
Expected: pass (`test_detailSegmentCasesDocumentedInRightPaneMd` and the tool-count test both read the files this task edits).

```bash
git add docs/guide/right-pane.md docs/guide/publish-department.md docs/roadmap.md docs/adr/0030-three-people-seven-legs-directives-as-rulings.md docs/adr/README.md Maugham/Views/AREA.md Maugham/Stores/AREA.md Maugham/Compiler/AREA.md CLAUDE.md docs/superpowers/notes/2026-09-02-translation-pipeline-p5-handoff.md
git commit -m "docs(translation-pipeline): P5 ships — guide, roadmap flip, ADR 0030 §7 amended, AREA entries, handoff with owed smokes"
```

---

## After the tasks

1. Whole-branch review (opus) over `main..translation-pipeline-p5`, run **concurrently with gate 1** (`./scripts/test.sh full`); both are read-only.
2. Fix wave for the review's findings; gate 2 after it. Read the kept xcresult, never the pipe's exit code; before blaming a red mounted-click test, `ioreg -n Root -d1 | grep ScreenIsLocked`.
3. Fill the handoff's gate record and merge commit; exit the worktree with keep; `git merge --no-ff translation-pipeline-p5` on main; do not push.
