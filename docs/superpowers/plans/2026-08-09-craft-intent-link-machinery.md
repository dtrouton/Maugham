# The Link Machinery Learns Statements — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a `Statement` a first-class `[[…]]` endpoint everywhere the link machinery writes, resolves, or maintains one — fixing audit findings F1 (High), F10, and S2 (issue #24).

**Architecture:** `PromotionPerformer` gets a two-case `writableDestination` resolver so its two write sites can append into a statement's op log via the existing `appendToStatement` seam; the two graph tools resolve statement composed titles via a new shared `ProjectStore.statementTitlePairs()`; `propagateWikiLinkRename` grows statement and research-note loops plus composed-title rewrite pairs, with the statement open/gate dance extracted into one `withStatementDocument` helper shared with `appendToStatement`.

**Tech Stack:** Swift / XCTest, Mac scheme only (statements are Mac-only; no MaughamCore or phone changes).

**Spec:** `docs/superpowers/specs/2026-08-09-craft-intent-link-machinery-design.md` — read it first.

## Global Constraints

- **Read the AREA.md before editing a directory:** `Maugham/Canvas/AREA.md`, `Maugham/MCP/AREA.md`, `Maugham/Stores/AREA.md`. Non-negotiable (CLAUDE.md).
- **Op log is the source of truth** (hard invariant #1): statement and manuscript bodies change ONLY through a `Document` (`setFullText` / the append seam) — never a raw `.md` write. A raw *read* of a research note (not op-logged) needs an `// adr-0018-ok: research note, not manuscript` comment or `TripwireGrepTests` goes red.
- **The MCP tool count must not move.** All read-tool changes are widenings of `list_all_links` / `find_references`. `DocSyncTests` pins 55.
- **No new `CanvasUndo` bracket call sites** (tripwire 32's census) and no new promotion arms (`PromotionCommandTests` census). This plan adds neither — if you find yourself editing either census, stop.
- **Paragraph-id literals in tests** crossing the `.md` ↔ op log boundary must be 4-char `[0-9a-hjkmnp-tv-z]` or `ParagraphID.mint()` (tripwire 8). Doc ids / statement ids are NOT paragraph ids and are unrestricted.
- **Fast loop:** `./scripts/test.sh` (~65s). Single-class iteration: `xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO -only-testing:MaughamTests/<ClassName>` (concrete class names only). **Full gate before merge:** `./scripts/test.sh full`.
- No new files are created, so `./gen.sh` is not needed.
- Commit after every task (message style: `feat(promotion): …` / `fix(stores): …` — match `git log` voice).

---

### Task 1: `WikiLinkRewriter.rewriteAll` — one body, many pairs

**Files:**
- Modify: `Maugham/Stores/WikiLinkRewriter.swift` (enum ends ~line 60)
- Test: `MaughamTests/WikiLinkRewriterTests.swift`

**Interfaces:**
- Consumes: `WikiLinkRewriter.rewrite(body:oldTitle:newTitle:) -> String?` (existing; nil = nothing replaced).
- Produces: `public static func rewriteAll(body: String, pairs: [(old: String, new: String)]) -> String?` — nil when NO pair replaced anything. Tasks 7–8 call this.

- [ ] **Step 1: Write the failing tests** (append to `WikiLinkRewriterTests`):

```swift
func test_rewriteAll_appliesEveryPair() {
    let out = WikiLinkRewriter.rewriteAll(
        body: "See [[Alpha]] and [[Craft Intent · Alpha]].",
        pairs: [("Alpha", "Omega"), ("Craft Intent · Alpha", "Craft Intent · Omega")])
    XCTAssertEqual(out, "See [[Omega]] and [[Craft Intent · Omega]].")
}

func test_rewriteAll_nilWhenNoPairMatches() {
    XCTAssertNil(WikiLinkRewriter.rewriteAll(
        body: "No links to [[Beta]] here.",
        pairs: [("Alpha", "Omega")]))
}

func test_rewriteAll_partialMatchStillReturnsRewrite() {
    let out = WikiLinkRewriter.rewriteAll(
        body: "[[Alpha]] only.",
        pairs: [("Alpha", "Omega"), ("Gamma", "Delta")])
    XCTAssertEqual(out, "[[Omega]] only.")
}
```

- [ ] **Step 2: Run to verify they fail** — `-only-testing:MaughamTests/WikiLinkRewriterTests`. Expected: does not compile (`rewriteAll` undefined) → add a stub returning nil, see 2 of 3 fail.
- [ ] **Step 3: Implement** (in the enum, below `rewrite`):

```swift
/// Every pair applied in order; nil when none replaced anything — the same
/// skip-the-write signal `rewrite` gives for one pair.
public static func rewriteAll(
    body: String, pairs: [(old: String, new: String)]
) -> String? {
    var out = body
    var changed = false
    for pair in pairs {
        if let r = rewrite(body: out, oldTitle: pair.old, newTitle: pair.new) {
            out = r
            changed = true
        }
    }
    return changed ? out : nil
}
```

- [ ] **Step 4: Run to verify pass**, then **Step 5: Commit** (`feat(stores): WikiLinkRewriter learns to apply a set of rename pairs`).

---

### Task 2: `ProjectStore.statementTitlePairs()` — the one spelling of statement titles for resolution

**Files:**
- Modify: `Maugham/Stores/ProjectStore+Statements.swift`
- Test: `MaughamTests/Canvas/PromotionStatementMarkTests.swift` (it already exercises `ArtifactIndex.statementTitle`; keep statement-title tests together — read its header first and follow its harness)

**Interfaces:**
- Consumes: `ArtifactIndex.statementTitle(_:documentTitle:)` (`Maugham/Canvas/Promotion.swift:397`), `manifest.statements`, `manifest.structure`, `TreeWalk.collect`.
- Produces: `func statementTitlePairs() -> [(id: String, title: String)]` on `ProjectStore` — composed title per statement (e.g. `"Craft Intent · Chapter 1"`, project-scope `"Craft Intent"`). Tasks 5, 6, 8 call this.

- [ ] **Step 1: Write the failing test** (use the file's existing store-building helper; if it has none, mirror `PromotionPerformerTests.makeProject` + `makeNovelWithAChapter` as a per-file helper — the house pattern is per-file, no shared fixture):

```swift
func test_statementTitlePairs_composeTheOneTitlePerStatement() async throws {
    let (_, store) = try await makeNovelWithAChapter()   // chapter id "ch-1", title "Chapter 1"
    let projectIntent = try await store.createStatement(kind: .intent, scope: .project)
    let chapterIntent = try await store.createStatement(kind: .intent, scope: .document("ch-1"))
    let pairs = store.statementTitlePairs()
    XCTAssertEqual(Set(pairs.map(\.id)), [projectIntent.id, chapterIntent.id])
    XCTAssertEqual(pairs.first { $0.id == projectIntent.id }?.title, "Craft Intent")
    XCTAssertEqual(pairs.first { $0.id == chapterIntent.id }?.title, "Craft Intent · Chapter 1")
}
```

- [ ] **Step 2: Run to verify it fails** (does not compile). **Step 3: Implement** (in `ProjectStore+Statements.swift`, near `statementText`):

```swift
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
```

- [ ] **Step 4: Run to verify pass.** **Step 5: Commit** (`feat(stores): one spelling of statement titles for link resolution`).

---

### Task 3: `performWikiLink` learns statements (F1 — the High)

**Files:**
- Modify: `Maugham/Canvas/PromotionPerformer.swift:557-572` (`performWikiLink`) + add the resolver beside it
- Test: `MaughamTests/Canvas/PromotionPerformerTests.swift`

**Interfaces:**
- Consumes: `store.appendToStatement(_:to:session:)`, `store.statementText(of:)`, `ArtifactIndex.statementTitle`, `documentTitle` (performer's existing private helper — used by `performCraftIntent`), the test file's `plan(_:_:store:model:)` / `intent(_:in:)` / `statementText(_:in:)` helpers.
- Produces: `private enum WritableDestination { case researchFile(item: ResearchItem, path: String); case statement(Statement) }` and `private func writableDestination(of itemID: String) -> WritableDestination?` on `PromotionPerformer`. Task 4 uses both.

- [ ] **Step 1: Write the failing regression test** (this is the F1 repro, end to end — append to `PromotionPerformerTests`):

```swift
/// F1 (2026-08-09 audit, High): a line drawn FROM a craft-intent card passed
/// preview and threw a false `artifactMissing` at commit, because
/// `performWikiLink` looked the mark up in `manifest.research` only. The link
/// must land in the statement, through its op log.
func test_aLineFromAnIntentCardWritesItsLinkIntoTheStatement() async throws {
    let (root, store) = try await makeProject()
    let model = makeModel(at: root)
    let performer = PromotionPerformer(store: store, model: model)
    _ = try await performer.perform(
        plan(.scrap(a), .intentStatement, store: store, model: model))
    _ = try await performer.perform(
        plan(.scrap(b), .researchNote, store: store, model: model))

    let result = try await performer.perform(
        plan(.line(l1), .wikiLink, store: store, model: model))

    let statement = try intent(.project, in: store)
    XCTAssertEqual(result.createdItemID, statement.id)
    XCTAssertTrue(statementText(statement, in: root).contains("[[October's doctor]]"),
                  "the link must be in the statement's OP LOG, not lost or on disk only")
}

/// The statement arm's dedupe must match the file arm's: same link twice is
/// `linkAlreadyPresent`, read off the freshest text (`statementText(of:)`).
func test_aRepeatedLineIntoTheStatementRefusesAsAlreadyPresent() async throws {
    let (root, store) = try await makeProject()
    let model = makeModel(at: root)
    let performer = PromotionPerformer(store: store, model: model)
    _ = try await performer.perform(
        plan(.scrap(a), .intentStatement, store: store, model: model))
    _ = try await performer.perform(
        plan(.scrap(b), .researchNote, store: store, model: model))
    _ = try await performer.perform(plan(.line(l1), .wikiLink, store: store, model: model))
    do {
        _ = try await performer.perform(plan(.line(l1), .wikiLink, store: store, model: model))
        XCTFail("second identical link must refuse")
    } catch PromotionFailure.linkAlreadyPresent {
        // expected
    }
}
```

Also add the spec §4.3 interleaving case: find `test_promotingWhileTheIntentPaneIsOpenDoesNotOpenASecondDocument` (grep the test tree; it pins the intent arm's outcome — the writer's next keystroke does not write the promotion back out) and write its sibling with the LINE promotion as the mid-visit write: hold the statement's `Document` open the way that test does, perform `plan(.line(l1), .wikiLink, …)`, and assert the live document's `displayText` gained the link and no second `Document` was opened on the path. Same harness, different verb.

- [ ] **Step 2: Run to verify the first fails with `artifactMissing`** — `-only-testing:MaughamTests/PromotionPerformerTests`. (Note the class is addressed as `MaughamTests/PromotionPerformerTests` even though the file sits in `Canvas/`.)
- [ ] **Step 3: Implement.** Add the resolver + rewrite `performWikiLink`:

```swift
/// The two places a mark's artifact can be WRITTEN — `manifest.research`
/// first (every pre-M1A case, unchanged), else `manifest.statements`.
/// One spelling, because `performWikiLink` and `writeOfferedLinks` must
/// agree about what "writable" means (the file's own preview/commit rule,
/// applied to the pair of write sites).
private enum WritableDestination {
    case researchFile(item: ResearchItem, path: String)
    case statement(Statement)
}

private func writableDestination(of itemID: String) -> WritableDestination? {
    if let item = TreeWalk.find(id: itemID, in: store.manifest.research),
       let path = item.path {
        return .researchFile(item: item, path: path)
    }
    if let statement = store.manifest.statements.first(where: { $0.id == itemID }) {
        return .statement(statement)
    }
    return nil
}

private func performWikiLink(_ plan: PromotionPlan) async throws -> PromotionResult {
    guard let link = plan.wikiLinkWrite else { throw PromotionFailure.missingWikiLinkWrite }
    switch writableDestination(of: link.intoItemID) {
    case nil:
        throw PromotionFailure.artifactMissing(link.intoItemID)
    case .researchFile(let item, let path):
        try? await store.documentStore?.flushPendingSave()
        let body = try readBody(atPath: path)
        // The plan's own check was against a SNAPSHOT taken when the sheet
        // opened. This one is against the file.
        guard !body.contains(link.linkText) else { throw PromotionFailure.linkAlreadyPresent }
        try await write(body + link.appendedText, toPath: path)
        return PromotionResult(createdItemID: item.id, title: item.title, writtenLinks: [])
    case .statement(let statement):
        // Freshest text, not the file: `statementText`'s live arm leads the
        // op log by a burst window. No flush dance — an op-log append cannot
        // be raced by the 750 ms save (`appendToStatement`'s own rule).
        guard !store.statementText(of: statement).contains(link.linkText) else {
            throw PromotionFailure.linkAlreadyPresent
        }
        try await store.appendToStatement(link.linkText, to: statement,
                                          session: Self.promotionSession)
        return PromotionResult(
            createdItemID: statement.id,
            title: ArtifactIndex.statementTitle(statement, documentTitle: documentTitle),
            writtenLinks: [])
    }
}
```

Pass `link.linkText` (not `link.appendedText`) to the statement arm: `appendToStatement`'s `statementAppending` already owns the blank-line separation rule, and passing pre-padded text would double it. Keep the existing `// No mark:` comment where the method's return is built if it survives your edit — the rule it states still holds.

- [ ] **Step 4: Run both new tests + the whole class to verify green** (the existing `test_aCardPromotedToIntentStillResolvesItsMark` and neighbors must stay green).
- [ ] **Step 5: Commit** (`fix(promotion): a line from an intent card lands its link in the statement (F1)`).

---

### Task 4: `writeOfferedLinks` learns statements (F10)

**Files:**
- Modify: `Maugham/Canvas/PromotionPerformer.swift:697-712` (`writeOfferedLinks`)
- Test: `MaughamTests/Canvas/PromotionPerformerTests.swift`

**Interfaces:**
- Consumes: Task 3's `writableDestination(of:)`, the test file's helpers, `plan.linksAccepted` (settable `var` on `PromotionPlan`).
- Produces: nothing new — behavior change only.

- [ ] **Step 1: Write the failing test** (the existing offered-links tests around line 690–732 show the shape — a region promotion with `p.linksAccepted = true`):

```swift
/// F10 (2026-08-09 audit): the offer counted intent-marked members that the
/// writer half then silently skipped — "Also link 2 cards" linking 1. Now it
/// writes into the statement, so the counts agree by writing.
func test_anOfferedLinkToAnIntentMarkedMemberLandsInTheStatement() async throws {
    let (root, store) = try await makeProject()
    let model = makeModel(at: root)
    let performer = PromotionPerformer(store: store, model: model)
    _ = try await performer.perform(
        plan(.scrap(a), .intentStatement, store: store, model: model))
    _ = try await performer.perform(
        plan(.scrap(b), .researchNote, store: store, model: model))

    var p = plan(.region(r1), .researchNote, store: store, model: model)
    p.linksAccepted = true
    let result = try await performer.perform(p)

    XCTAssertEqual(Set(result.writtenLinks), [a, b],
                   "both marked members must be written, the intent one included")
    let statement = try intent(.project, in: store)
    XCTAssertTrue(statementText(statement, in: root).contains("[[\(result.title)]]"),
                  "the intent member's own artifact must gain the region link")
}
```

- [ ] **Step 2: Run to verify it fails** (`writtenLinks` == `[b]` today — the silent skip).
- [ ] **Step 3: Implement** — replace the loop body's research-only lookup with the resolver:

```swift
for offer in plan.offeredLinks {
    switch writableDestination(of: offer.itemID) {
    case nil:
        continue   // genuinely gone since the sheet opened — the honest skip
    case .researchFile(_, let path):
        let body = try readBody(atPath: path)
        guard !body.contains(link) else { continue }
        try await write(body + "\n\n" + link + "\n", toPath: path)
        written.append(offer.node)
    case .statement(let statement):
        guard !store.statementText(of: statement).contains(link) else { continue }
        try await store.appendToStatement(link, to: statement,
                                          session: Self.promotionSession)
        written.append(offer.node)
    }
}
```

Update the method's doc comment: "Two members are skipped" now means already-linked and genuinely-gone — the intent-marked member is no longer one of them.

- [ ] **Step 4: Run the class green** (the "counts what it wrote, not what was offered" test at ~:715 must stay green). **Step 5: Commit** (`fix(promotion): offered links reach intent-marked members instead of skipping them (F10)`).

---

### Task 5: `list_all_links` resolves statement titles

**Files:**
- Modify: `Maugham/MCP/Tools/ListAllLinksTool.swift:44-56` (titleIndex build) and `:169-183` (statement-source loop)
- Test: `MaughamTests/MCP/Tools/ListAllLinksToolTests.swift`

**Interfaces:**
- Consumes: Task 2's `store.statementTitlePairs()`.
- Produces: nothing new — `[[<composed statement title>]]` edges now resolve (`kind: "wiki"`, `to_id: stmt-…`) instead of `wiki_unresolved`.

- [ ] **Step 1: Write the failing tests** (follow the file's existing harness — it builds a project, writes bodies, decodes `[Edge]`):

```swift
/// Statement composed titles are resolvable targets: a line drawn TO a
/// craft-intent card writes `[[Craft Intent · Chapter 1]]`, and before this
/// widening every such link was `wiki_unresolved` forever (issue #24).
func test_aLinkToAStatementComposedTitleResolves() async throws { /* build a
    project with chapter "ch-1"/"Chapter 1"; create a document-scoped intent
    statement; write "[[Craft Intent · Chapter 1]]" into a research note body;
    call the tool; assert one edge with kind == "wiki" and to_id == the
    statement's id. */ }

/// Docs and research keep beating a statement on a title collision — the
/// writer-named artifact wins over the composed name.
func test_titleCollisionPrefersResearchAndDocsOverStatements() async throws { /*
    create a research note literally titled "Craft Intent"; also create a
    project-scope intent statement (composed title "Craft Intent"); a body
    containing "[[Craft Intent]]" must resolve to the research note's id. */ }

/// A statement whose body contains its own composed title is not a self-link
/// (the research-note rule, applied to the third source loop).
func test_aStatementNamingItselfEmitsNoSelfEdge() async throws { /* append
    "[[Craft Intent]]" into the project intent statement via
    store.appendToStatement; assert no edge with from_id == to_id == its id. */ }
```

Write these as REAL tests, not comments — the sketches above name the exact setup; expand each using the file's own helpers (read the file top-to-bottom first; it has project-builder and tool-invocation helpers).

- [ ] **Step 2: Run to verify they fail** (`wiki_unresolved` today).
- [ ] **Step 3: Implement.** In the titleIndex build, insert statements FIRST so research then docs overwrite on collision (later insert wins in this dictionary):

```swift
// Statements lowest: a composed title contains a kind word and ` · `, so a
// collision is near-impossible — and if one occurs, the writer-named
// artifact (research, then docs) should win.
for pair in store.statementTitlePairs() {
    titleIndex[pair.title.lowercased()] = (pair.id, pair.title)
}
// (existing research + docs insertion follows, unchanged)
```

In the statements-as-source loop (`:174` area), add the self-link skip before appending:

```swift
if let hit, hit.id == statement.id { continue }
```

- [ ] **Step 4: Run the class green** (existing unresolved-link tests must still pass — none of them use composed statement titles; if one asserts a total edge count, update it consciously and say so in the commit).
- [ ] **Step 5: Commit** (`feat(mcp): list_all_links resolves statement titles — a widening, count unchanged`).

---

### Task 6: `find_references` resolves statement targets

**Files:**
- Modify: `Maugham/MCP/Tools/ReferenceTools.swift:261-293` (`resolveTargetId`) and `:295-318` (`titlesToScan`)
- Test: `MaughamTests/MCP/Tools/ReferenceToolsTests.swift`

**Interfaces:**
- Consumes: Task 2's `store.statementTitlePairs()`.
- Produces: nothing new — `find_references(target: <stmt id or composed title>)` now finds referrers.

- [ ] **Step 1: Write the failing test** (follow the file's harness):

```swift
/// `find_references` must answer for a statement the way it answers for any
/// artifact: by id or by (composed) title. Before this widening the target
/// never resolved, so a chapter whose manuscript says
/// `[[Craft Intent · Chapter 1]]` was invisible to "what points at this".
func test_findReferences_resolvesAStatementTargetByIdAndComposedTitle() async throws { /*
    project with chapter "ch-1"/"Chapter 1" whose body contains
    "[[Craft Intent · Chapter 1]]"; create the document-scoped intent
    statement; call the tool twice — target = the stmt id, then target =
    "craft intent · chapter 1" (case-insensitive) — and assert both return a
    reference from "ch-1" with kind == "wiki". */ }
```

Expand to a real test using the file's helpers.

- [ ] **Step 2: Run to verify it fails** (empty refs today — target unresolvable and the literal-title scan misses the case difference only when ids are used; assert on the id form to be sure of a failure).
- [ ] **Step 3: Implement.** In `resolveTargetId`, after the research-tree checks and before the path checks:

```swift
// Statements: by id, then by composed title — after research/docs (the
// writer-named artifact wins a collision, as in list_all_links).
let statementPairs = store.statementTitlePairs()
if statementPairs.contains(where: { $0.id == target }) { return target }
if let s = statementPairs.first(where: {
    $0.title.compare(target, options: .caseInsensitive) == .orderedSame
}) { return s.id }
```

In `titlesToScan`, inside the `if let id = resolvedId` branch:

```swift
for pair in store.statementTitlePairs() where pair.id == id {
    titles.append(pair.title)
}
```

- [ ] **Step 4: Run the class green.** The existing statement-source loop (`:238`) already guards `statement.id != resolvedId`, so a statement target does not report itself. **Step 5: Commit** (`feat(mcp): find_references resolves statement targets — a widening, count unchanged`).

---

### Task 7: rename propagation reaches statements (S2, statement half)

**Files:**
- Modify: `Maugham/Stores/ProjectStore+Statements.swift` (extract `withStatementDocument` from `appendToStatement:241-278`), `Maugham/Stores/ProjectStore+Structure.swift:396-464` (`propagateWikiLinkRename`)
- Test: `MaughamTests/WikiLinkRenameOpLogTests.swift`

**Interfaces:**
- Consumes: `openStatementDocument(id:)`, `lockStatementOpen`/`unlockStatementOpen`, `Document.load`, `Document.setFullText`, `derivedCache.displayText(forDocId:in:)`, Task 1's `rewriteAll`.
- Produces: `func withStatementDocument(_ statement: Statement, session: String, _ mutate: (Document) -> Void) async throws` on `ProjectStore` — the ONE statement open/gate dance, called by `appendToStatement` and the rename loop. Task 8 reuses the rename loop's pair plumbing.

- [ ] **Step 1: Write the failing tests** (extend `WikiLinkRenameOpLogTests`; its `makeProject(docs:)` helper builds the on-disk shape — wire a `DocumentStore` the way `PromotionPerformerTests.makeProject` does when a live-pane case needs one):

```swift
/// S2 (2026-08-02 sweep): renaming a document silently flipped a statement's
/// `[[chapter]]` to unresolved while the graph tools kept listing it. The
/// statement is a `Document`; the rewrite must arrive as ops.
func test_renameRewritesLinksInsideAClosedStatement() async throws {
    let root = try makeProject(docs: [
        (id: "a", title: "Alpha", body: "The chapter."),
        (id: "b", title: "Beta", body: "Another.")])
    let store = try await ProjectStore.load(from: root)
    let statement = try await store.createStatement(kind: .intent, scope: .project)
    try await store.appendToStatement("Open with [[Alpha]].", to: statement,
                                      session: "test")

    try await store.renameStructureItem(id: "a", newTitle: "Omega")

    XCTAssertTrue(store.statementText(of: statement).contains("[[Omega]]"))
    XCTAssertFalse(store.statementText(of: statement).contains("[[Alpha]]"))
    let ops = OpLogStore.loadSyncMerged(forDocId: statement.id, in: root)
    XCTAssertTrue(ops.contains { op in
        op.changes.contains { ($0.next ?? "").contains("[[Omega]]") }
    }, "the rewrite must be IN the op log, not a raw file write")
}

/// The live-pane arm: a statement open in the Plan persona's right column
/// while the writer renames in the binder. The open `Document` must reflect
/// the rewrite without a second `Document` on the same path.
func test_renameRewritesLinksInsideAnOpenStatement() async throws { /* same
    setup; before renaming, hold the statement's Document open the way
    ProjectStore's own statement seam does (see appendToStatement's live arm
    and StatementEditorHost's binding — open via the store's statement-open
    seam, not a bare Document.load); rename; assert the LIVE document's
    displayText contains "[[Omega]]". */ }
```

Expand the second sketch into a real test — `ProjectStore+Statements.swift`'s open-gate doc comments name the seam to use.

- [ ] **Step 2: Run to verify the first fails** (statement text still `[[Alpha]]`).
- [ ] **Step 3: Extract the helper.** In `ProjectStore+Statements.swift`, refactor `appendToStatement`'s live/gate/transient dance into:

```swift
/// The ONE statement open-and-mutate dance: live `Document` first, else the
/// open gate, a re-ask inside it, a transient load, and an awaited close.
/// `appendToStatement`'s doc comment owns the full rationale — this exists so
/// the rename loop cannot ship a second, subtly different copy of it.
func withStatementDocument(_ statement: Statement, session: String,
                           _ mutate: (Document) -> Void) async throws {
    if let live = openStatementDocument(id: statement.id) {
        mutate(live)
        try? await live.flushBurstNow()
        return
    }
    await lockStatementOpen(statement.id)
    defer { unlockStatementOpen(statement.id) }
    if let live = openStatementDocument(id: statement.id) {
        mutate(live)
        try? await live.flushBurstNow()
        return
    }
    let document = try await Document.load(
        url: url.appendingPathComponent(statement.path),
        device: MacDeviceID.current, session: session,
        presenter: documentStore?.presenter)
    mutate(document)
    await document.close()
}
```

`appendToStatement` becomes a caller: `try await withStatementDocument(statement, session: session) { self.writeStatementText($0, text) }`. **Move, don't duplicate, the comments** — the doc comments on the dance stay with the helper.

- [ ] **Step 4: Add the statement loop** to `propagateWikiLinkRename` (after the manuscript loop). Structure the method around a pairs array so Task 8 can extend it — for this task, `let pairs = [(old: oldTitle, new: newTitle)]`:

```swift
// Statements are Documents too (M1A) — same op-log discipline, and the
// pre-check mirrors the manuscript loop's (an empty statement derives to ""
// and is safely skipped: unlike a manuscript there is no bootstrap owed).
for statement in manifest.statements {
    let derived = derivedCache.displayText(forDocId: statement.id, in: url)
    let liveText = openStatementDocument(id: statement.id)?.displayText
    let preview = liveText ?? derived
    guard !preview.isEmpty,
          WikiLinkRewriter.rewriteAll(body: preview, pairs: pairs) != nil else { continue }
    do {
        try await withStatementDocument(
            statement, session: "wiki-rename-\(UUID().uuidString.prefix(8))") { doc in
            if let rewritten = WikiLinkRewriter.rewriteAll(
                body: doc.displayText, pairs: pairs) {
                doc.setFullText(rewritten)
            }
        }
    } catch {
        projectStoreLog.error(
            "Wiki-rename: statement \(statement.id, privacy: .public) skipped: \(error.localizedDescription, privacy: .public)")
    }
}
```

Also switch the existing manuscript loop's two `WikiLinkRewriter.rewrite(body:oldTitle:newTitle:)` calls to `rewriteAll(body:pairs:)` — same behavior with one pair, and Task 8 needs it.

- [ ] **Step 5: Run the class green** (both new tests + the two existing manuscript cases). Also run `-only-testing:MaughamTests/PromotionPerformerTests` — the `appendToStatement` refactor must not move its behavior.
- [ ] **Step 6: Commit** (`fix(stores): rename propagation reaches statements, through one shared open dance (S2)`).

---

### Task 8: rename propagation reaches research notes + composed titles (S2, both remaining halves)

**Files:**
- Modify: `Maugham/Stores/ProjectStore+Structure.swift` (`propagateWikiLinkRename` + its call site at `:374-378`)
- Test: `MaughamTests/WikiLinkRenameOpLogTests.swift`

**Interfaces:**
- Consumes: Task 1's `rewriteAll`, Task 2's `statementTitlePairs()` (for before/after composed titles use `ArtifactIndex.statementTitle` directly with old/new closures), Task 7's pairs plumbing, `documentStore?.performFileSave(path:text:)` and `flushPendingSave()`.
- Produces: nothing new — behavior completes S2.

- [ ] **Step 1: Write the failing tests:**

```swift
/// The research-note half — pre-existing since 1C-c2, ADR 0026 recorded it
/// "recorded, not fixed". A research note is not op-logged: the rewrite is a
/// coordinated file write behind a flush.
func test_renameRewritesLinksInsideAResearchNoteBody() async throws { /* build
    the project; create a research note whose body contains "[[Alpha]]" (use
    the store's research-note creation API + a DocumentStore-wired store, as
    PromotionPerformerTests.makeProject does); rename "a" to "Omega"; read the
    note's file and assert "[[Omega]]" in, "[[Alpha]]" out. */ }

/// The composed-title rule: a statement's NAME embeds its document's, so the
/// rename must also rewrite links TO the statement, everywhere.
func test_renameRewritesComposedStatementTitleLinks() async throws {
    let root = try makeProject(docs: [
        (id: "a", title: "Alpha", body: "See [[Craft Intent · Alpha]]."),
        (id: "b", title: "Beta", body: "Nothing here.")])
    let store = try await ProjectStore.load(from: root)
    _ = try await store.createStatement(kind: .intent, scope: .document("a"))

    try await store.renameStructureItem(id: "a", newTitle: "Omega")

    let rewritten = store.derivedCache.materialize(forDocId: "a", in: root)
    XCTAssertTrue(rewritten.contains("[[Craft Intent · Omega]]"))
    XCTAssertFalse(rewritten.contains("[[Craft Intent · Alpha]]"))
}
```

Note the second test plants the link in the RENAMED doc's own body — decide deliberately: the manuscript loop excludes `excludeId` for self-reference reasons that do not apply to composed-title pairs. If honoring that exclusion, plant the link in "b" instead and assert there; either way, write one sentence in the commit message saying which you chose and why. Expand the first sketch into a real test.

- [ ] **Step 2: Run to verify both fail.**
- [ ] **Step 3: Implement.** In `propagateWikiLinkRename`, build the full pairs list at the top:

```swift
// The document's own title, plus the composed title of every statement
// scoped to it — a statement's name embeds its document's (M1A), so the
// rename moves both. The manifest has ALREADY been renamed when this runs,
// so compose the old title with a closure answering the OLD name.
var pairs: [(old: String, new: String)] = [(oldTitle, newTitle)]
for statement in manifest.statements {
    if case .document(let docId) = statement.scope, docId == excludeId {
        pairs.append((
            old: ArtifactIndex.statementTitle(statement, documentTitle: { _ in oldTitle }),
            new: ArtifactIndex.statementTitle(statement, documentTitle: { _ in newTitle })))
    }
}
```

Then add the research-note loop (after the statement loop):

```swift
// Research notes hold `[[…]]` too (canvas promotion writes there and never
// into a manuscript) and are NOT op-logged — the rewrite is a plain
// coordinated write behind a flush, so a queued 750 ms save cannot
// resurrect the stale body.
try? await documentStore?.flushPendingSave()
for item in TreeWalk.collect(in: manifest.research, where: { $0.kind == .document }) {
    guard let path = item.path,
          let text = try? String(contentsOf: url.appendingPathComponent(path), encoding: .utf8),  // adr-0018-ok: research note, not manuscript
          let rewritten = WikiLinkRewriter.rewriteAll(body: text, pairs: pairs)
    else { continue }
    do {
        if let ds = documentStore {
            try await ds.performFileSave(path: path, text: rewritten)
        } else {
            try rewritten.write(to: url.appendingPathComponent(path),
                                atomically: true, encoding: .utf8)
        }
    } catch {
        projectStoreLog.error(
            "Wiki-rename: research note \(path, privacy: .public) skipped: \(error.localizedDescription, privacy: .public)")
    }
}
```

(The no-`DocumentStore` fallback mirrors `PromotionPerformer.write(_:toPath:)` — load-only contexts.)

- [ ] **Step 4: Run the class green, then `./scripts/test.sh`** — the fast loop, because this task's reach (rename) crosses stores, canvas, and MCP tests.
- [ ] **Step 5: Commit** (`fix(stores): rename propagation reaches research notes and composed statement titles (S2 complete)`).

---

### Task 9: docs — the ADR amendment, the AREA sentence, and the full gate

**Files:**
- Modify: `docs/adr/0026-planning-canvas-rendering.md` (Consequences), `Maugham/MCP/AREA.md`, `docs/roadmap.md` (only if it has an open line this closes — check, don't assume)
- No test file — the deliverable is doc truth plus the pre-merge gate.

**Interfaces:** none — prose only.

- [ ] **Step 1: ADR 0026 dated amendment.** Find the Consequences line recording the research-note rename gap as "recorded, not fixed". Do NOT rewrite it — append beneath it, house style (see `8c854460`'s amendment shape):

```markdown
**Amendment (2026-08-09):** `propagateWikiLinkRename` now rewrites `[[…]]`
inside research-note bodies and statements, and rewrites composed statement
titles (`[[Craft Intent · Old]]` → `[[Craft Intent · New]]`) when their
document renames — the gap this consequence recorded is closed (issue #24,
spec `2026-08-09-craft-intent-link-machinery-design.md`).
```

- [ ] **Step 2: `Maugham/MCP/AREA.md`** — one sentence where the M1A link-tool widenings are described: `list_all_links` and `find_references` now also RESOLVE statement composed titles as targets (2026-08-09, issue #24); count unchanged.
- [ ] **Step 3: Sweep for now-false claims** (default-workflow rule 10): `grep -rn "wiki_unresolved\|recorded, not fixed\|only know manifest.research\|manifest.research only" docs/ Maugham/*/AREA.md CLAUDE.md` — fix any sentence this branch made false, in this commit.
- [ ] **Step 4: Full gate.** `./scripts/test.sh full` — no skips. All 4,300+ green before merge.
- [ ] **Step 5: Commit** (`docs: the link machinery's statement widening, recorded where the gaps were`).

---

## Post-plan (not tasks — the standing workflow)

- Whole-branch review before merge (default workflow #9), then merge and close issue #24 with a comment naming the spec, the plan, and the F1/F10/S2 finding ids.
- Smoke test (user-run, Mac): promote a card to Craft Intent, draw a line from it to a promoted note card, ⌘⇧↩ → Commit — the sheet must confirm rather than alert; then rename the chapter and confirm the statement's link followed.
