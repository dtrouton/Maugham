# Implementer notes — regenerating `TreeNode.swift` from the brief

Written from `experiment/08-regeneration-brief.md` alone. No other file in the repository
was read, grepped, listed or otherwise inspected; no build or test was run.

Throughout, "the rule" means M2-A-06's reconciled prefix rule.

---

## (a) AMBIGUITIES — where the spec was silent, vague, or underdetermined

**A1. The function count is wrong.** The task says "each of the 11 public functions".
§1 declares **ten** static functions on `TreeWalk`, plus a protocol with two requirements.
I assumed ten statics and treated the protocol as the eleventh item. If there is an
eleventh function in the original that §1 omitted, I have no way to know it exists, and
nothing in §2 or §3 references a behaviour I could not place on one of the ten.

**A2. `find`'s tie-break gloss is self-undermining.** M2-C-010 says "the first in pre-order
(**shallowest, then leftmost**)". Those are two different orders. Pre-order returns a
depth-4 node under root 1 in preference to root 2 itself; "shallowest first" is breadth-first
and would return root 2. M2-C-020 and M2-A-03 both say pre-order/depth-first. I implemented
pre-order and treated the parenthetical as a sloppy gloss. See also (b).

**A3. Whether `contains` is its own walk.** Nothing says. I implemented it as
`find(id:in:) != nil`, which satisfies M2-C-002 and M2-T-003/004 and short-circuits. A
separate `Bool`-returning recursion would be observationally identical but would allocate
nothing on the return path for large nodes. If the original returns `Bool` directly, no
test in §2 could tell the difference.

**A4. Whether `find` should be `first(where: { $0.id == id })`.** M2-A-14 calls `first`/`collect`
the "non-id counterparts" of `find`/`collectIds`, and M2-A-01 wants a single implementation
of tree walking. That argues for `find` delegating to `first`. I wrote it as its own loop
because I judged "single implementation" to mean "one module", not "one recursion". This is
a coin-flip and I could easily be on the wrong side of it. The observable behaviour is identical.

**A5. `mutate`: does a matched node's children still get transformed?** M2-C-015/M2-T-019 say
children are transformed before the body runs, which implies yes — but only for the matched
node's own children, and only as a *precondition of the body call*. An alternative reading is
that a match stops the descent. I transform children of **every** node uniformly, then test
the id. With unique ids the two readings coincide; with a duplicated id nested under itself
they differ, and §2 does not cover that case.

**A6. `mutate`: is the id tested before or after the children rewrite?** I test `node.id`
(the pre-rewrite node). The children rewrite cannot change the node's own id, so this is
the same value either way — unless a caller's type derives `id` from `children`, which the
protocol permits (`id` is a computed `{ get }`). Undefined for such a type.

**A7. `mutate`: is a body-changed id re-matched?** M2-B-06 says the body **may** change the
id. If it changes it *to* the target id, is the body applied again? I chose no — the body is
applied exactly once per originally-matching node, on the way out. Non-termination would be
the alternative for the pathological case, so this seems forced, but it is not stated.

**A8. `mutate`/`remove`: is `nil` children preserved as `nil`?** Never stated. I preserve it:
a node with `children == nil` comes out with `children == nil`, never `[]`. This matters
because `leaves` treats both as leaves but a caller distinguishing "cannot have children"
from "has none" would notice.

**A9. `remove`: does an emptied child array become `[]` or `nil`?** I leave `[]`. Removing a
parent's only child therefore turns that parent into a leaf per M2-T-009. Nothing in §2 says
whether that is intended or an accident, and it is user-visible in any binder UI that draws
disclosure triangles from `children.isEmpty`.

**A10. `remove`: filter-then-recurse or recurse-then-filter?** Observationally identical.
I filter first, so I never walk inside a doomed subtree. Only a cost difference — but if the
original recurses first, a `path`-style closure with side effects would fire on doomed nodes.
`remove` takes no closure, so this is unobservable here.

**A11. `leaves`: is a `nil`-children node a leaf?** M2-T-009 covers only the *empty non-nil*
case; M2-C-022 covers "terminating in an empty children array". Neither states the `nil` case,
which is presumably the common one. M2-A-04's "childless branch IS a leaf" points at yes.
I made both `nil` and `[]` leaves. If the original special-cased `nil` differently, every
claim in §2 would still pass.

**A12. `collect`: are returned nodes the originals or copies with filtered children?**
M2-C-019 answers this (entire original subtree). Implemented as stated. Worth flagging that
this makes `collect(where:)` return overlapping values — a matching parent and its matching
child both appear, and the child appears twice (once standalone, once inside the parent).
Nothing in the spec acknowledges that.

**A13. `rewritePaths`: node before children, or children before node?** Unspecified. I do the
node first (pre-order, per M2-A-03), then recurse. This is observable through side effects in
`setPath` and through `path`'s invocation order.

**A14. `rewritePaths`: is `path` read from the original node or from the partially-rewritten
copy?** Unspecified. I read from the original, before `setPath` runs. Since `setPath` runs
after `path` on the same node, and no node's closure is documented as reading a *different*
node, this is unobservable for well-behaved closures and undefined for others.

**A15. `rewritePaths` with `oldPrefix == newPrefix`: "identity" in what sense?** M2-C-025 says
identity. I produce value-identity but **still invoke `setPath`** with the unchanged string.
If `setPath` sets a dirty flag, bumps a modification date, or appends to an op log, this is
*not* an identity in the way a caller would care about. A pre-check (`guard old != new`) would
be trivial and I deliberately did not add it, because the spec describes the rule and not
the elision, and adding it would change closure-invocation counts that §2 never pins.

**A16. Empty `oldPrefix`.** M2-C-024 says an empty `oldPrefix` "rewrites ONLY empty paths".
Under the rule, `""` also matches the second arm for any absolute path: `"/q"` is
`"" + "/" + "q"` and becomes `newPrefix + "/q"`. So C-024 is false as written. See (b).

**A17. Trailing slash on `oldPrefix`.** M2-C-027 says it "silently makes the whole rewrite a
no-op". Under the rule it makes the *descendant* arm a no-op (nothing starts with `"research//"`)
but the exact-match arm still fires for a path of exactly `"research/"`. See (b).

**A18. Trailing slash on `newPrefix`.** Not mentioned anywhere. `newPrefix == "new/"` yields
`"new//rest"`. I do not normalise. M2-A-06's "no double slash" is scoped to the join, not to
a caller-supplied trailing slash, and I read it that way.

**A19. Whether `rewritePaths` should normalise `oldPrefix` at all.** P13's counterexample says
the *semantic* self-or-descendant rule would rewrite `"research"` under `oldPrefix "research/"`.
Stripping a trailing slash from `oldPrefix` would make that true. I did **not** do it, because
M2-A-06 states the rule with no normalisation clause and M2-A-06 is a MUST. This is the single
largest judgement call in the file.

**A20. `idsByPath` key/value direction.** The signature `[String: String]` disambiguates
nothing. The name and M2-T-027 ("maps every non-nil path to its node's id") say path → id.
Implemented that way. If the original is id → path, every claim about "last visited wins"
would read differently and the parent/child contest (M2-C-032) would not arise at all —
which is weak evidence that path → id is right.

**A21. Closure invocation counts.** Never stated for any of `predicate`, `path`, `setPath`.
I invoke `predicate` at most once per visited node (`first` stops early; `collect` visits all),
`path` exactly once per node, `setPath` at most once per node. A caller with an expensive or
side-effecting closure has no contract to rely on.

**A22. Escaping.** No closure is marked `@escaping`, so all are non-escaping. That is the
right default and permits the recursive pass-through, but it forecloses any future
memoisation or deferred evaluation inside the walkers. Not stated either way.

**A23. Protocol conformances.** `TreeNode` is not declared `Sendable`, `Equatable` or
`Hashable`. §1 is stated to be the *complete* surface, so I added none — but note this means
the walkers cannot compare nodes, only ids, which is why M2-T-018 ("returns a NEW tree and
leaves the input untouched") can only be tested by a caller that adds `Equatable` itself.

**A24. No public extensions on `TreeNode`.** §1 shows none, and "declare exactly the public
surface" forbids them. So there is no `node.find(id:)` spelling and no convenience for the
single-root case. Callers must wrap a root in `[root]` at every call site.

**A25. File organisation, `MARK:` comments, helper naming.** Entirely unspecified. My private
helpers are `collect(in:where:into:)`, `leaves(in:into:)`, `collectIds(in:into:)`,
`idsByPath(in:path:into:)` and `rerooting(_:from:to:)`. Any of these names could differ.

**A26. Empty-forest handling (M2-C-001 … M2-C-009).** All nine fall out of the loops and
`map`/`compactMap` naturally; I wrote no explicit guards. If the original has explicit early
returns, no test could distinguish them.

**A27. Doc comments.** The brief says to write them "as you normally would" and specifies no
content. Mine encode the behaviour I chose, including the choices flagged above — so the doc
comments are *my* claims, not the spec's, and should not be read back as evidence.

---

## (b) CONTRADICTIONS — quoted by id, and how I resolved them

**C1. M2-C-010 vs M2-C-020 / M2-A-03.**
M2-C-010: "find returns the first in pre-order (**shallowest, then leftmost**)".
M2-C-020: "first is depth-first, not breadth-first: a deep match under an earlier sibling
beats a shallow match at a later one".
M2-A-03: "MUST visit pre-order (parent before children) everywhere".
"Shallowest then leftmost" is breadth-first ordering and is incompatible with the other two
for any forest with more than one root. **Resolved for pre-order**, on a 2-to-1 vote and
because M2-A-03 is a MUST.

**C2. M2-C-024 vs M2-A-06.**
M2-C-024: "an empty oldPrefix rewrites **ONLY** empty paths, not every path".
M2-A-06's second arm: `oldPrefix + "/" + r -> newPrefix + "/" + r`.
With `oldPrefix == ""` the second arm matches every path beginning with `/`. C-024 is
therefore false under the mandated rule. **Resolved for M2-A-06** (a MUST beats a LOW-warrant
observation). Consequence: with an empty `oldPrefix`, `"/q"` becomes `newPrefix + "/q"`.
The load-bearing half of C-024 — "not every path" — still holds.

**C3. M2-C-027 vs M2-A-06 / M2-T-024 / M2-B-05.**
M2-C-027: "a trailing slash on oldPrefix silently makes the **whole** rewrite a no-op".
M2-T-024: "a path exactly EQUAL to oldPrefix becomes exactly newPrefix".
M2-B-05: "MUST handle the exact-match node in rewritePaths".
With `oldPrefix == "research/"`, a node whose path is literally `"research/"` hits the
exact-match arm and *is* rewritten, so the rewrite is not a whole no-op. **Resolved for
M2-A-06/M2-T-024**: C-027 is true of the descendant arm only. I suspect C-027 was written
against a code shape that had no exact-match arm — which is exactly what M2-B-05 says the
prior store-local implementations lacked. So C-027 may be a stale observation of superseded code.

**C4. The `CONTRADICTED` warrant on M2-T-023 / M2-T-024 vs M2-A-06 / M2-B-05.**
M2-T-023 and M2-T-024 state precisely the two arms of M2-A-06, and are marked `CONTRADICTED`
— defined as "a randomised property test found a counterexample to the claim as written".
But M2-A-06 mandates those exact arms and M2-B-05 mandates the exact-match one specifically.
Reading P13's counterexample, what was actually falsified is the *semantic* self-or-descendant
interpretation, not the syntactic rule; the warrant column and the intent envelope are
recording two different rules under overlapping ids. **Resolved for M2-A-06**, implemented
literally. If the intent was that a trailing-slash `oldPrefix` should be normalised, my
implementation is wrong and no other clause in the brief would have told me.

**C5. P13 vs M2-A-06.**
P13 (held **False**): "rewritePaths matches the SEMANTIC self-or-descendant rule … forest
[XPathNode(path: "research")], oldPrefix "research/", newPrefix "NEW" -> path unchanged; the
semantic rule says it denotes the node itself".
This says the code disagrees with the semantic rule and does not say which one is correct.
M2-A-06 is a MUST and describes the syntactic rule. **Resolved for the syntactic rule** —
i.e. I reproduced the behaviour P13 flagged as a failure. Deliberate, and the thing I am
least happy about. A single sentence in §3 saying whether P13 is a bug report or a
documentation of accepted behaviour would have settled it.

**C6. M2-A-16 vs M2-C-010 / 011 / 012 / 013 / 014 and P14.**
M2-A-16: "MUST have node ids unique within a forest".
P14: "every walker contract holds on forests **WITH duplicate ids**", 20,000 cases, held.
The envelope states uniqueness as an invariant while five claims and a property test
carefully specify duplicate-id semantics. **Resolved as**: uniqueness is a caller-side
expectation the walkers do not enforce and do not rely on; the duplicate semantics are the
real contract. My implementation never assumes uniqueness.

**C7. M2-A-19 vs M2-A-10 / M2-C-031 / M2-C-032.**
M2-A-19: "MUST rely on the store's unique-on-disk-path invariant to make the duplicate-path
contest **moot**".
M2-A-10: "MUST resolve duplicate paths in idsByPath as last-writer-wins in pre-order".
Same shape as C6: one clause says the case cannot arise, three specify what happens when it
does. **Resolved for the specified behaviour** (plain `map[key] = id` in pre-order).

**C8. M2-A-11 / M2-T-018 vs the protocol's own type constraints.**
M2-A-11: "MUST return a new tree from mutate / remove rather than mutating in place".
`TreeNode` has no `AnyObject` bound, so a **class** may conform. For a class conformer,
`var copy = node; copy.children = …` mutates the caller's node in place and M2-T-018/P12
("mutate and remove never disturb the input forest") is violated with no diagnostic. The
spec never says nodes must be value types. **Resolved by** assuming value semantics and not
adding an `AnyObject`-excluding constraint (which Swift cannot express anyway). This is a
real, silent hazard in the delivered file.

No other contradictions found. In particular §2's `HIGH`-warrant rows are mutually consistent.

---

## (c) UNSPECIFIED PROPERTIES — things the spec does not mention in any form

**Complexity and cost**

1. Time complexity of every walker. I deliver O(n) for `find`/`contains`/`first` (worst case),
   `collect`, `leaves`, `collectIds`, `idsByPath`; O(n) node copies for `mutate`, `remove`,
   `rewritePaths`. Nothing is stated, so nothing stops a future O(n²).
2. `collect`/`leaves`/`collectIds`/`idsByPath` use an `inout` accumulator rather than array
   concatenation at each level. Concatenation would be O(n·depth) and would satisfy every
   claim in §2 identically. This is a pure implementer's choice.
3. `mutate`/`remove`/`rewritePaths` allocate a **fresh array at every level**, even for
   subtrees in which nothing matched. Structure sharing (returning the input array untouched
   when no descendant matched) is a legitimate optimisation that §2 neither requires nor
   forbids, and it would be observable through `CFGetRetainCount`-style probes and through
   allocation counts, but not through any behavioural test.
4. No `@inlinable` / `@usableFromInline`. Across a module boundary the generics are not
   specialised, so every call goes through the generic witness path. Unspecified, and a real
   performance property for a package target.
5. `contains` materialises and returns a full node value from `find` before discarding it.
   For a large node struct that is a wasted copy. Unspecified.

**Recursion and stack**

6. M2-A-20 mandates recursion, and M2-C-034/M2-C-036 acknowledge there is no depth guard, so
   this much *is* specified — but the **frame size** is not, and it is what determines the
   depth at which it dies. My `rewritePaths` frame holds five parameters including two
   closures; it is the fattest of the ten and will overflow first. Nothing says this matters.
7. Tail calls: none of these are tail-recursive and Swift does not guarantee TCO anyway.
8. Cyclic input: unreachable for value types, infinite recursion for a class conformer (see C8).
   Unspecified.
9. Recursion is per-**depth**, not per-node, so a forest of 10 million siblings at depth 1 is
   fine. Never stated, and worth stating.

**Closures**

10. Invocation counts and ordering for `predicate`, `path`, `setPath` — see A21. Additionally:
    `path` is invoked on nodes whose path will not be rewritten (necessarily), and on nodes
    inside subtrees that no rewrite touches. A closure that hits the filesystem would be
    catastrophic here and nothing warns against it.
11. Re-entrancy: a closure that calls back into `TreeWalk` on the same forest is fine (no
    shared state), but a closure that mutates a captured copy of the forest sees undefined
    interleaving. Unspecified.
12. No `throws` or `async` variants. A caller whose predicate can fail must smuggle the error
    out through a captured `var`. Unspecified.
13. `setPath` takes `inout N` and could legally rewrite the node's `children` too, mid-walk —
    my implementation then **overwrites** those children with the recursive rewrite result, so
    such a write is silently discarded. Genuinely undefined territory.

**Strings**

14. All matching uses Swift `String` equality and `hasPrefix`, which are Unicode
    **canonical-equivalence** comparisons, not byte comparisons. So a path stored in NFD
    matches an `oldPrefix` in NFC. On macOS, where the filesystem hands back decomposed
    forms, this is arguably desirable and definitely unspecified.
15. `dropFirst(boundary.count)` counts **Characters** (grapheme clusters), consistently with
    `hasPrefix`'s grapheme-based matching, so the two agree — but only because both are
    grapheme-based. A future `utf8`/`unicodeScalars` optimisation would silently break the
    "no eaten character" guarantee on combining sequences. Unspecified.
16. Case sensitivity: matching is case-**sensitive**. On a case-insensitive volume,
    `"Research/x"` is not rewritten by `oldPrefix "research"`. Never mentioned.
17. Empty `newPrefix` with the exact-match arm yields `""` — a node whose path becomes the
    empty string, which M2-C-033 says is a valid distinct key in `idsByPath`. The interaction
    is not mentioned.

**Ordering and determinism**

18. `idsByPath` returns a `Dictionary`; M2-C-035 names the instability but the spec does not
    say whether any caller depends on order. I documented "subscript, don't iterate".
19. `collect`'s output may contain a node and, separately, its descendants — the ordering of
    that overlap is pre-order but the *duplication* is never acknowledged (A12).
20. `leaves` order across sibling subtrees is pinned (M2-C-023/M2-T-008) but the interaction
    with an empty children array in the middle of a chain is only pinned by example.

**Concurrency**

21. Nothing is `Sendable`, nothing is isolated, nothing is documented as thread-safe. The
    walkers are pure and therefore safe under concurrent reads of an immutable forest, but
    that is my inference and not a stated contract. Under Swift 6 strict concurrency these
    signatures would need `sending`/`Sendable` work; under 5.10 they compile silently.

**Pathological input**

22. A forest containing the same node value at two positions: fine, handled as duplicates.
23. `mutate` where `body` returns a node with `children` set to something unrelated: accepted
    verbatim, and the already-rewritten children are discarded. Unspecified whether that is
    intended.
24. `remove` on an id that matches every root: returns `[]`. M2-C-013 covers it.
25. Enormous single strings in `rewritePaths`: `hasPrefix` is O(prefix length), fine.
26. `oldPrefix == "/"`: boundary becomes `"//"`, so `"/a"` is untouched and only a path of
    exactly `"/"` rewrites. Almost certainly not what anyone wants; entirely unspecified.

**API shape**

27. No single-root convenience overloads, no `Sequence`-based overloads, no
    `ArraySlice` acceptance. Callers must pass `[N]`.
28. No `depth` or `parent` information is surfaced by any walker, so a caller needing a path
    from root must hand-roll — directly against M2-A-01's "no per-type hand-rolled recursion
    anywhere". The surface in §1 makes that clause impossible to honour for any caller that
    needs ancestry. Worth flagging as a gap in the *interface*, not just the spec.

---

## (d) CONFIDENCE — per public function

| function | confident? | what I'd need to know |
|---|---|---|
| `TreeNode` (protocol) | **High** | Signatures given verbatim in §1. Only open question is whether it should carry `Sendable`/`Equatable` — §1 says the surface is complete, so I added nothing. |
| `find(id:in:)` | **High** on behaviour, **low** on implementation shape | Behaviour is pinned by M2-T-001/002 and the pre-order MUST. Unsure whether it should delegate to `first(where:)` (A4) — unobservable either way. |
| `contains(id:in:)` | **High** | M2-T-003/004 + M2-C-002 fully determine it. Only cost differs between implementations (A3). |
| `first(in:where:)` | **High** | M2-T-010/011/012, M2-C-020, M2-B-03 and P15 (`first == collect.first`) between them leave nothing open. |
| `collect(in:where:)` | **High** | M2-T-013/014/015, M2-C-018/019, P10 and P11 pin order, descent, and subtree carriage. |
| `leaves(in:)` | **Medium-high** | Everything is pinned except the `nil`-children case (A11), which no claim states directly. If `nil` children means "not a leaf" in the original, I am wrong for the most common node shape in the system. I'd need one sentence about `children == nil`. |
| `collectIds(in:)` | **High** | M2-T-005, M2-C-011, P11's explicit-stack oracle. Nothing open. |
| `mutate(id:in:_:)` | **Medium** | The identity/order claims are clear, but three things are not: whether a matched node's children are still descended into (A5), whether a body-changed id is re-matched (A7), and whether `nil` children survive as `nil` (A8). I'd need the duplicate-id-nested-under-itself case spelled out, and a statement about id-changing bodies beyond "MAY". |
| `remove(id:in:)` | **Medium-high** | M2-T-020/021/022 and M2-C-013/017 pin the observable behaviour. Open: whether an emptied `[]` should collapse to `nil` (A9), which changes leaf-ness downstream. |
| `rewritePaths(in:replacingPrefix:with:path:setPath:)` | **Low** | This is where the spec fails. M2-A-06 and M2-T-023/024 mandate a rule that P13 records as *falsified*, and M2-C-024/C-027 describe behaviour the mandated rule does not produce. I implemented M2-A-06 literally, which means I deliberately reproduced P13's counterexample. I'd need: (i) is a trailing slash on `oldPrefix` normalised, yes or no; (ii) is P13 a bug report or a description of accepted behaviour; (iii) is `setPath` elided when the value is unchanged (A15). Any of the three could flip my implementation. |
| `idsByPath(in:path:)` | **High** on behaviour, **medium** on direction | M2-T-027 and M2-C-031/032/033 fully pin the semantics *given* that the map is path → id (A20). The `[String: String]` signature cannot confirm the direction; the claims strongly imply it. |

---

## The single biggest gap

`rewritePaths` is specified three times and the three specifications do not agree. M2-A-06
mandates a syntactic rule; M2-T-023/024 restate that rule and are stamped `CONTRADICTED`;
P13 records the semantic rule and reports the code failing it, without saying which side is
the defect. The brief never says whether a trailing slash on `oldPrefix` is a caller error,
a normalised input, or the bug P13 is complaining about — and every one of those readings
produces a different, silently divergent implementation of the one function in this file that
renames files on a writer's disk.
