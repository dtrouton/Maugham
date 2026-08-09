# Phase 3 — Intent envelope inference (two arms)

**HEAD:** `db1bea2c`

---

## 0. A methodological warning you should read before the results

**Arm A is contaminated, and I cannot fully decontaminate it.** By the time I reached this phase
I had already read every test in both modules (Phase 1) and written 79 characterization tests
(Phase 2). A true clean-room Arm A would require an inferrer who has never seen the suite.

I considered dispatching a subagent for a genuinely blind Arm A. I did not, for the reason I gave
in Phase 0: this session's operating instructions bar the Agent tool absent an explicit request.
So Arm A here is a **disciplined reconstruction**, not a clean room, and I have imposed one
control to make it as honest as I can:

> **Every Arm A clause must cite a specific line of production source, a doc comment, or a commit
> message. If I cannot point at production evidence, the clause does not go in Arm A — no matter
> how confident I am that it is true.**

That control is mechanical and checkable: every Arm A row below carries its citation, and you can
verify none of them points at a test. What it *cannot* do is stop me from having been *steered*
toward the right places to look. **Treat the Arm B lift number as a lower bound on the tests'
real contribution, and treat this as the single biggest methodological weakness in the
experiment.** It is recorded again in `07-summary.md`.

Confidence scale: **HIGH** = stated near-verbatim in production source or a commit; **MEDIUM** =
a direct reading of the code's structure; **LOW** = an inference from naming or context that could
plausibly be wrong.

---

## 1. Module M1 — `MaughamCore.PaletteCard`

### Arm A (production source, comments, git history only)

| # | Clause | Conf. | Evidence (production only) |
|---|---|---|---|
| M1-A-01 | **MUST** satisfy `parse(render(card)) == card` for any editor-reachable model | HIGH | `PaletteCard.swift:57` header: "so that `parse(render(card)) == card` for any editor-reachable model"; restated on `PaletteCardRenderer` |
| M1-A-02 | **MUST NOT** let a body line spelling a KNOWN section heading survive as body — this residual is accepted, and the round trip converges from the second render | HIGH | Same header, "WITH ONE documented residual"; "Residual we accept" paragraph |
| M1-A-03 | **MUST** treat the model as owner of the file: re-rendering normalises hand edits rather than preserving them | HIGH | Header: "The MODEL owns the file"; "External hand-edits are unsupported; re-rendering normalizes them" |
| M1-A-04 | **MUST** preserve body bytes verbatim — indentation, trailing whitespace, interior blank-line runs — stripping only the renderer's single structural blank-line pad | HIGH | Header paragraph on `body`; inline comment at the `bodyLines` peel; commit `27b179ad` "body round-trip is byte-preserving (A6)" |
| M1-A-05 | **MUST NOT** let an inline `![]()` in BODY prose enter `imagePaths` | HIGH | Inline comment: "body prose keeps its `![]()` text verbatim rather than being harvested"; commit `84c18871` gives the failure it fixes (un-removable bouncing thumbnail) |
| M1-A-06 | **MUST NOT** let a remote URL (`://`) enter `imagePaths`, regardless of section | HIGH | Two `!path.contains("://")` guards; commit `84c18871` "never let a remote URL (`://`) enter imagePaths regardless of section" |
| M1-A-07 | **MUST** capture `kind:` at most once, before any real section; a later `kind:`-looking line is ordinary body prose | HIGH | Header; inline comment "must never overwrite `kind`"; the `kindCaptured` / `seenSectionHeading` guards |
| M1-A-08 | **MUST** degrade unknown/missing `kind` to `.other` rather than failing | HIGH | Header: "(unknown/missing → `.other`)"; `Kind(rawValue:) ?? .other` |
| M1-A-09 | **MUST NOT** emit an untagged note whose text is empty/whitespace-only — it cannot round-trip | HIGH | `PaletteCardRenderer` header; the 6-line inline comment at the skip |
| M1-A-10 | **MUST** keep a TAGGED note with empty text — `- smell: ` round-trips | HIGH | Same inline comment: "Tagged-empty notes (`- smell: `) still round-trip and are kept" |
| M1-A-11 | **MUST** validate swatches as `#RGB`/`#RRGGBB` and silently ignore others | HIGH | Header: "must be `#RGB`/`#RRGGBB` (others ignored)"; the `color(fromHex:) != nil` gate |
| M1-A-12 | **MUST** normalise to canonical form on render: uppercase swatches, `./`-relative image paths, all three sections always present | HIGH | `PaletteCardRenderer` header, verbatim |
| M1-A-13 | **MUST** treat an unknown `##` heading before any real section as body, and after real structure as a dropped section | HIGH | Header; the `if seenSectionHeading { section = .unknown; continue }` branch and its comment |
| M1-A-14 | **MUST** resolve card-relative image paths to project-relative on the way in and invert exactly on the way out | HIGH | `resolve` / `relativize` doc comments ("The exact inverse of `PaletteCardParser`") |
| M1-A-15 | **MUST NOT** hold a second copy of the inline-image scanner — the shared `MarkdownBlockParser.findInlineImages` is the one matcher | HIGH | `inlineImagePaths` doc comment; commit `9c9c5526` "permissive palette duplicate deleted" |
| M1-A-16 | **MUST** derive every downstream sense vocabulary from `Sense.allCases`, never a re-typed literal | HIGH | Commit `61386ce9` S3: "phone aim senses derive from PaletteCard.Sense.allCases — no re-typed literal" |
| M1-A-17 | **MUST** be usable from both Mac and phone as one shared implementation | HIGH | Commit `afa38f6b` "PaletteCard family → MaughamCore (tripwire 19; registry row)" |
| M1-A-18 | **MUST NOT** let structure detection see indentation — the trimmed probe is for structure, the raw line for storage | MEDIUM | The `line` vs `raw` split and its 4-line comment. *That this makes an indented heading a section is a consequence I inferred, not one stated.* |
| M1-A-19 | **MUST** accept the writer's title verbatim from the first `# ` heading, falling back only when absent | MEDIUM | Header: "Title is the first `# ` heading (else the fallback)" |
| M1-A-20 | **MUST NOT** admit a swatch that is not valid hex into a rendered file | **LOW** | *Inference from M1-A-11's parse-side gate plus M1-A-12's "normalizes". Nothing in production says the RENDERER validates. I flag this as my most likely Arm A hallucination.* |
| M1-A-21 | **MUST** be robust to arbitrary text, never trapping or throwing — parse is total | MEDIUM | `parse` returns a non-optional `PaletteCard`, has no `throws`, and every branch has a fallback |
| M1-A-22 | **MUST** keep ids out of the file: `researchItemId` is supplied by the caller | MEDIUM | The `itemId` parameter; nothing in the canonical markdown carries an id |

### Arm B (production source **and** the test suite)

Every Arm A clause survives. The suite adds these:

| # | Clause | Conf. | Status | Evidence |
|---|---|---|---|---|
| M1-B-01 | **MUST** round-trip a body containing an unknown `## ` heading (the parser must not truncate body at a heading-like line) | HIGH | **NEW** | `PaletteCardRendererTests` header comment: "Regression: Task C's freeform body TextEditor makes these ordinary typed input." Arm A's M1-A-02 covers only *known* headings and reads as a general caution; the tests establish the *unknown*-heading case as a hard MUST arising from a shipped UI feature. |
| M1-B-02 | **MUST** round-trip a body line beginning `- ` as prose, not a list item | HIGH | **NEW** | `test_roundTrip_bodyWithDashLine`. Nothing in production names this case. |
| M1-B-03 | **MUST** have `parse(template(t, k))` recover exactly `t` and `k` | HIGH | **NEW** | `test_template_parsesBackToItsOwnFields`. `template` has no doc comment at all; Arm A could not tell whether it was meant to be a parseable document or just a UI seed. |
| M1-B-04 | The `Sense` DECLARATION ORDER is load-bearing for downstream display grouping | HIGH | **UPGRADED** | `PaletteLoadingTests.test_groupedNotes_ordersBySenseAllCases_untaggedLast_skippingEmpty`. Arm A (M1-A-16, from the commit) established the *vocabulary* must be derived; only the test reveals the *order* is a contract. Reordering the enum is a behaviour change. |
| M1-B-05 | The empty-untagged-note skip exists to stop the **inbox promote** path stranding an entry and double-appending | HIGH | **NEW (provenance)** | `test_render_skipsUntaggedEmptyNote…` "S5" marker + `InboxPalettePromoteRoundTripTests`. Arm A knew the *rule* (M1-A-09) but not that it is load-bearing for a cross-module workflow — which changes how dangerous it is to "simplify". |
| M1-B-06 | The four body-byte-preservation cases are separately guaranteed: indentation, trailing spaces, leading extra blank, trailing extra blank | HIGH | **REFINED** | Four dedicated tests. Arm A's M1-A-04 states the principle; the tests fix the *boundary* — exactly one structural blank each side, everything beyond it is content. |
| M1-B-07 | The round-trip law is enforced at **model** granularity, never at **byte** granularity | HIGH | **NEW (negative)** | Every round-trip test compares `PaletteCard` values; none compares rendered bytes to expected bytes. This is why `M1-C-041` (template/render byte divergence) is invisible to the suite. Arm A could not have known which granularity was chosen. |

**Arm B lift for M1: 7 clauses (5 new, 1 upgraded, 1 refined) on top of 22 — a 32% lift.**

---

## 2. Module M2 — `MaughamCore.TreeNode` / `TreeWalk`

### Arm A (production source, comments, git history only)

| # | Clause | Conf. | Evidence (production only) |
|---|---|---|---|
| M2-A-01 | **MUST** be the single implementation of tree walking — no per-type hand-rolled recursion anywhere | HIGH | `TreeNode` doc comment: "the generic walkers in `TreeWalk` replace the per-type hand-rolled recursion that had drifted"; commits `d3029ca9` ("delete copies"), `4604b328` ("Closes the last hand-rolled tree walk") |
| M2-A-02 | **MUST NOT** be re-implemented on the phone — MaughamCore owns it | HIGH | `TreeNode` doc comment: "Cross-surface contract: MaughamCore owns this; the phone shares it (do not re-implement — see cross-surface-contracts.md)" |
| M2-A-03 | **MUST** visit pre-order (parent before children) everywhere | HIGH | Stated on `find`, `first`, `collect`, `collectIds`, `leaves`, `idsByPath` |
| M2-A-04 | **MUST** define leaf-ness by children-EMPTINESS, not node type — a childless branch IS a leaf | HIGH | `leaves` doc comment, 6 lines on exactly this; commit `4604b328` "Leaf-ness is by children-emptiness (not type), matching the prior behavior" |
| M2-A-05 | **MUST NOT** move kind-filtering inside `leaves` — callers filter the result | HIGH | `leaves` doc comment: "Don't swap a type predicate in — it changes where that filtering decision lives" |
| M2-A-06 | **MUST** apply the reconciled prefix rule: `p == oldPrefix → newPrefix`; `oldPrefix + "/" + r → newPrefix + "/" + r`; anything else untouched. No double slash, no eaten character | HIGH | `rewritePaths` doc comment, 18 lines; commit `9de7c38c` "reconciled prefix rule" |
| M2-A-07 | **MUST NOT** rewrite a non-boundary prefix match (`oldPrefix + "ie"`) | HIGH | Same doc comment, named explicitly |
| M2-A-08 | **MUST** leave nil paths untouched | HIGH | Same doc comment: "(incl. `oldPrefix` as a non-boundary prefix … and nil paths) → left untouched" |
| M2-A-09 | **MUST** skip nil-path nodes in `idsByPath` | HIGH | `idsByPath` doc comment: "Nodes with a nil path are skipped" |
| M2-A-10 | On duplicate paths, `idsByPath` is **last-writer-wins in pre-order** | HIGH | `idsByPath` doc comment, verbatim |
| M2-A-11 | **MUST** return a new tree from `mutate` / `remove` rather than mutating in place | HIGH | Both doc comments say "Returns a new tree"; `[N]` value semantics |
| M2-A-12 | `mutate`'s body **MUST** see the matched node with its children ALREADY transformed | HIGH | `mutate` doc comment: "`body` sees the matched node (with its already-transformed children)" |
| M2-A-13 | **MUST** reach out-of-protocol fields (`path`) through caller-supplied closures, never by widening the protocol | HIGH | `rewritePaths` doc comment: "`path` is not part of the `TreeNode` protocol … so access is supplied via closures" |
| M2-A-14 | **MUST** offer `first`/`collect` as the non-id counterparts to `find`/`collectIds` | HIGH | Both doc comments say "The generic counterpart to…" |
| M2-A-15 | **MUST** key on `String` ids — the protocol constrains `ID == String` | HIGH | `protocol TreeNode: Identifiable where ID == String` |
| M2-A-16 | Node ids **MUST** be unique within a forest | **LOW** | *Inference from `find` returning a single `N?` and `contains` being a membership predicate. Nothing in production states it — and see the contradiction below. My most likely M2 hallucination.* |
| M2-A-17 | **MUST** tolerate an empty forest without trapping | MEDIUM | Every walker's loop is `for node in nodes`, which is vacuous on `[]` |
| M2-A-18 | **MUST NOT** prune a subtree because its parent failed the predicate | MEDIUM | Read off `collect`'s structure — the `if let kids` descent is outside the `if predicate` branch. Not stated in any comment. |
| M2-A-19 | The store's unique-on-disk-path invariant makes the duplicate-path contest moot | MEDIUM | `idsByPath` doc comment: "which the store invariant — unique on-disk paths — makes moot" |
| M2-A-20 | **MUST** stay allocation-simple and recursive — no explicit stack, no iterative rewrite | LOW | *Inference from uniform style. No comment supports it; included precisely because it is the kind of clause a machine will confidently invent.* |

### Arm B (production source **and** the test suite)

| # | Clause | Conf. | Status | Evidence |
|---|---|---|---|---|
| M2-B-01 | `TreeWalk` is the suite's **trusted oracle**, not just production's: 12 of the 13 test files that touch it use `TreeWalk.find`/`collect` as a *fixture helper* to locate nodes for assertions about other modules | HIGH | **NEW — and the most important clause in either arm** | File census. Arm A cannot see this at all. It means a `TreeWalk` regression does not merely break `TreeNodeTests`; it silently corrupts assertions across `ProjectStore`, `Canvas`, `Inbox` and `MCP` tests, which would then be *reporting on a lie*. That raises the bar on any change here far above what its 12 tests suggest. |
| M2-B-02 | The `dropFirst(+1)` divergence between `ProjectStore+Structure.rewriteChildPaths` and `ProjectStore+Research.researchRewriteChildPaths` was **proven equivalent, not merely unified** | HIGH | **NEW (provenance)** | `TreeNodeTests` carries a 39-line derivation comment. Commit `9de7c38c` says "reconciled"; only the test explains that neither was buggy and the "+1" was a second spelling, not a compensation. This is the difference between "don't touch, it's subtle" and "the subtlety is resolved". |
| M2-B-03 | `first` **MUST** return the PARENT when a parent and its descendant both match | HIGH | **UPGRADED** | `test_first_byPredicate_returnsDeepNode_preorder`'s third assertion. Arm A had "pre-order" (M2-A-03) as a traversal-shape statement; the test makes the tie-breaking a contract. |
| M2-B-04 | `collect(where: { _ in true })` **MUST** agree with `collectIds` | MEDIUM | **NEW** | `test_collect_byPredicate_preorder_filtered`. A cross-function consistency law nothing in production states. |
| M2-B-05 | The generic `rewritePaths` additionally handles the exact-match node, which the store copies it replaced did NOT | HIGH | **NEW** | `TreeNodeTests` comment: "The existing store copies only handle the descendant case … the generic additionally handles the exact-match node for completeness." Arm A reads M2-A-06's first bullet as an original requirement; it is in fact a *widening* introduced by the unification. |
| M2-B-06 | Nothing anywhere constrains `mutate`'s body to preserve the node's id | LOW | **NEW (negative)** | `test_mutate_returnsNewTree_leavesOthersUntouched` renames the node it mutates, so id-rewriting through `mutate` is sanctioned by example. Arm A would likely have assumed the opposite. |

**Arm B lift for M2: 6 clauses (4 new, 1 upgraded, 1 negative) on top of 20 — a 30% lift.**

---

## 3. What the tests provided that the code did not

Aggregating: **42 Arm A clauses, 13 Arm B additions — a 31% lift, consistent across both modules
despite one being twice as well-tested as the other.** That consistency is itself a result: the
lift did not track test density.

The additions fall into four kinds, and the kinds matter more than the count:

1. **Provenance (4 clauses: M1-B-01, M1-B-05, M2-B-02, M2-B-05).** *Why* a rule exists and what
   broke without it. Production comments state rules; test comments state the incidents. This is
   the class I would least want to lose, because it is what tells you whether a rule is safe to
   simplify.
2. **Cross-module contracts (2: M1-B-04, M2-B-01).** Facts about how *other* code depends on this
   code, which are structurally invisible from inside the module.
3. **Boundary sharpening (3: M1-B-06, M2-B-03, M2-B-05).** Turning a principle into an exact
   tie-break or edge rule.
4. **Negative space (4: M1-B-02, M1-B-03, M1-B-07, M2-B-06).** What is deliberately *not*
   constrained, and at what granularity the constraint is enforced. `M1-B-07` — that the round-trip
   law is checked at model granularity and never at byte granularity — is the single most useful
   line in this document for predicting which defects the suite cannot see.

## 4. Clauses I expect to be contradicted (carried to Phase 5)

Stated here before computing the agreement map, so the contradiction rate is a prediction and not
a post-hoc rationalisation:

| Clause | Why I expect trouble |
|---|---|
| **M2-A-16** ("ids MUST be unique") | `M2-C-012`/`M2-C-013` show `mutate` and `remove` apply to *every* match. That is not the code of someone assuming uniqueness. I think this clause is a hallucination and the honest statement is "uniqueness is held elsewhere and `TreeWalk` is deliberately agnostic". |
| **M1-A-01** ("round trip for any editor-reachable model") | `M1-C-043`–`M1-C-046` shatter it for four model shapes. Whether those are "editor-reachable" is exactly the human judgement this experiment cannot make — the clause's escape hatch is doing real work and I cannot tell if it is doing honest work. |
| **M1-A-04** ("body bytes verbatim") | `M1-C-023`: a writer-typed blank line before `kind:` is eaten. Narrower than the clause claims. |
| **M1-A-06** ("no remote URL in imagePaths") | Holds on the parse side; `M1-C-046` shows the *renderer* will happily write one out and mangle it. The clause is true of one half of a documented inverse pair. |
| **M1-A-11** ("swatches validated") | `M1-C-003`: `#+FFFFF` passes the validator. |
| **M1-A-20** ("no invalid swatch in a rendered file") | `M1-C-043` falsifies it outright. Flagged LOW in Arm A as my likely hallucination; recording the prediction. |
| **M2-A-20** ("stays recursive") | Not falsifiable by behaviour at all — it is a style preference I dressed as an intent clause. It should be killed on the ruling sheet, and I include it as a deliberate specimen of the failure mode. |
