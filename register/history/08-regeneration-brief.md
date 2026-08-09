# Regeneration brief — `MaughamCore.TreeNode` / `TreeWalk`

You are implementing a Swift file from its specification. **You have not seen, and will
not be given, the original implementation, its doc comments, its tests, or its commit
history.** Everything known about the required behaviour is in this document.

## Your task

Write the complete contents of `TreeNode.swift` — a file in a Swift package target that
imports only `Foundation`. It must:

- declare exactly the public surface in §1, with those exact signatures;
- satisfy every claim in §2 and every clause in §3;
- compile under Swift 5.10 language mode, targeting macOS 14 / iOS 17;
- contain no third-party dependencies and no UI framework imports.

Output the file as a single Swift code block, then a short list of any places where the
specification was **ambiguous, silent, or self-contradictory** and you had to choose. That
list is as valuable as the code — it is the point of the exercise. Do not soften it.

Write ordinary, idiomatic Swift. Do not optimise for passing a test suite you cannot see.

## 1. Public interface

```swift
// The complete public surface. Bodies, doc comments and internal helpers removed.

public protocol TreeNode: Identifiable where ID == String {
    var id: String { get }
    var children: [Self]? { get set }
}

public enum TreeWalk {

    public static func find<N: TreeNode>(id: String, in nodes: [N]) -> N?

    public static func contains<N: TreeNode>(id: String, in nodes: [N]) -> Bool

    public static func first<N: TreeNode>(
        in nodes: [N], where predicate: (N) -> Bool
    ) -> N?

    public static func collect<N: TreeNode>(
        in nodes: [N], where predicate: (N) -> Bool
    ) -> [N]

    public static func leaves<N: TreeNode>(in nodes: [N]) -> [N]

    public static func collectIds<N: TreeNode>(in nodes: [N]) -> [String]

    public static func mutate<N: TreeNode>(
        id: String, in nodes: [N], _ body: (N) -> N
    ) -> [N]

    public static func remove<N: TreeNode>(id: String, in nodes: [N]) -> [N]

    public static func rewritePaths<N: TreeNode>(
        in nodes: [N],
        replacingPrefix oldPrefix: String,
        with newPrefix: String,
        path: (N) -> String?,
        setPath: (inout N, String) -> Void
    ) -> [N]

    public static func idsByPath<N: TreeNode>(
        in nodes: [N],
        path: (N) -> String?
    ) -> [String: String]
}
```

## 2. Behavioural claims

`POSTCONDITION` / `PRECONDITION` / `INVARIANT` classify the claim. Warrant records how
strongly the claim is evidenced, not how important it is: `HIGH` = a dedicated existing
test asserts it; `MEDIUM` = weakly asserted; `LOW` = observed behaviour with no test
asserting it and no evidence anyone intended it; `CONTRADICTED` = a randomised property
test found a counterexample to the claim as written.

| id | scope | kind | warrant | claim |
|---|---|---|---|---|
| M2-C-001 | `TreeWalk.find` | POST | LOW | find on an empty forest returns nil rather than trapping |
| M2-C-002 | `TreeWalk.contains` | POST | LOW | contains on an empty forest is false |
| M2-C-003 | `TreeWalk.collectIds` | POST | LOW | collectIds on an empty forest returns an empty array |
| M2-C-004 | `TreeWalk.leaves` | POST | LOW | leaves on an empty forest returns an empty array |
| M2-C-005 | `TreeWalk.collect` | POST | LOW | collect on an empty forest returns an empty array without invoking the predicate |
| M2-C-006 | `TreeWalk.first` | POST | LOW | first on an empty forest returns nil without invoking the predicate |
| M2-C-007 | `TreeWalk.mutate` | POST | LOW | mutate on an empty forest returns an empty forest |
| M2-C-008 | `TreeWalk.remove` | POST | LOW | remove on an empty forest returns an empty forest |
| M2-C-009 | `TreeWalk.idsByPath` | POST | LOW | idsByPath on an empty forest returns an empty map |
| M2-C-010 | `TreeWalk.find` | POST | LOW | when several nodes share an id, find returns the first in pre-order (shallowest, then leftmost) |
| M2-C-011 | `TreeWalk.collectIds` | POST | LOW | collectIds emits duplicate ids once per occurrence; it does not deduplicate |
| M2-C-012 | `TreeWalk.mutate` | POST | LOW | mutate applies the body to EVERY node whose id matches, not just the first |
| M2-C-013 | `TreeWalk.remove` | POST | LOW | remove drops EVERY node whose id matches; with duplicated root ids the forest can empty entirely |
| M2-C-014 | `TreeWalk.contains` | POST | LOW | contains is true when any duplicate matches |
| M2-C-015 | `TreeWalk.mutate` | INVA | LOW | children are transformed before the parent's body closure runs, so the body observes already-rewritten children |
| M2-C-016 | `TreeWalk.mutate` | POST | LOW | mutate with an absent id is the identity and never invokes the body closure |
| M2-C-017 | `TreeWalk.remove` | POST | LOW | remove with an absent id is the identity |
| M2-C-018 | `TreeWalk.collect` | INVA | LOW | collect descends into a node that FAILS the predicate; a filtered-out parent does not prune its matching children |
| M2-C-019 | `TreeWalk.collect` | POST | LOW | a collected node carries its ENTIRE original subtree, including descendants that failed the predicate |
| M2-C-020 | `TreeWalk.first` | INVA | LOW | first is depth-first, not breadth-first: a deep match under an earlier sibling beats a shallow match at a later one |
| M2-C-021 | `TreeWalk.collect` | INVA | LOW | collect with an always-true predicate agrees with collectIds even in the presence of duplicate ids |
| M2-C-022 | `TreeWalk.leaves` | POST | LOW | a chain terminating in an empty children array yields exactly that terminal node as the single leaf |
| M2-C-023 | `TreeWalk.leaves` | POST | LOW | leaves preserves pre-order across sibling subtrees |
| M2-C-024 | `TreeWalk.rewritePaths` | POST | LOW | an empty oldPrefix rewrites ONLY empty paths, not every path |
| M2-C-025 | `TreeWalk.rewritePaths` | POST | LOW | oldPrefix == newPrefix is the identity |
| M2-C-026 | `TreeWalk.rewritePaths` | INVA | LOW | a node with a nil path is never assigned one |
| M2-C-027 | `TreeWalk.rewritePaths` | POST | LOW | a trailing slash on oldPrefix silently makes the whole rewrite a no-op, with no diagnostic |
| M2-C-028 | `TreeWalk.rewritePaths` | POST | LOW | the walk descends into the children of a node whose own path did not match |
| M2-C-029 | `TreeWalk.rewritePaths` | POST | LOW | an empty newPrefix produces paths with a leading slash (e.g. 'p/q' -> '/q') |
| M2-C-030 | `TreeWalk.rewritePaths` | POST | LOW | the exact-match node and its descendants are both rewritten in a single pass |
| M2-C-031 | `TreeWalk.idsByPath` | POST | LOW | when two nodes share a path, the LAST visited in pre-order wins |
| M2-C-032 | `TreeWalk.idsByPath` | POST | LOW | when a parent and child share a path, the CHILD wins |
| M2-C-033 | `TreeWalk.idsByPath` | POST | LOW | an empty-string path is a valid key, distinct from an absent (nil) path |
| M2-C-034 | `TreeWalk` | POST | LOW | every walker is unbounded recursion with no depth guard, and survives a 1,000-deep chain |
| M2-C-035 | `TreeWalk.idsByPath` | POST | LOW | the ITERATION ORDER of the returned Dictionary is not stable across processes (Swift seeds its hasher per process); any caller that iterates rather than subscripts gets a run-varying order |
| M2-C-036 | `TreeWalk` | PREC | LOW | the recursion depth at which the walkers overflow the stack is environment-dependent (thread stack size, optimisation level) and has no guard in the code |
| M2-T-001 | `TreeWalk.find` | POST | HIGH | find returns the node whose id matches, at any depth |
| M2-T-002 | `TreeWalk.find` | POST | HIGH | find returns nil when no node in the forest carries that id |
| M2-T-003 | `TreeWalk.contains` | POST | HIGH | contains is true when a node with that id exists at any depth |
| M2-T-004 | `TreeWalk.contains` | POST | HIGH | contains is false for an id present nowhere in the forest |
| M2-T-005 | `TreeWalk.collectIds` | POST | HIGH | collectIds returns every id in pre-order: a parent before its children, siblings in array order |
| M2-T-006 | `TreeWalk.leaves` | POST | HIGH | leaves omits every node with a non-empty children array |
| M2-T-007 | `TreeWalk.leaves` | POST | HIGH | descendants of an omitted branch still surface in the result |
| M2-T-008 | `TreeWalk.leaves` | POST | MEDIUM | returned leaves are in pre-order (document order of the flattened tree) |
| M2-T-009 | `TreeWalk.leaves` | INVA | HIGH | leaf-ness is by children-EMPTINESS, not node type: a node with an empty (non-nil) children array IS returned as a leaf |
| M2-T-010 | `TreeWalk.first` | POST | HIGH | first returns the first node satisfying the predicate, searching at any depth |
| M2-T-011 | `TreeWalk.first` | POST | HIGH | first returns nil when the predicate matches nothing |
| M2-T-012 | `TreeWalk.first` | INVA | HIGH | first is pre-order: when both a parent and its descendant match, the PARENT is returned |
| M2-T-013 | `TreeWalk.collect` | POST | HIGH | collect returns every node satisfying the predicate, in pre-order |
| M2-T-014 | `TreeWalk.collect` | INVA | HIGH | collect with an always-true predicate flattens the whole forest, producing the same order as collectIds |
| M2-T-015 | `TreeWalk.collect` | INVA | MEDIUM | a node failing the predicate is still DESCENDED INTO — filtering a parent out does not prune its matching children |
| M2-T-016 | `TreeWalk.mutate` | POST | HIGH | mutate applies the body closure to the node whose id matches |
| M2-T-017 | `TreeWalk.mutate` | POST | HIGH | nodes not matching the id are returned unchanged |
| M2-T-018 | `TreeWalk.mutate` | POST | MEDIUM | mutate returns a NEW tree and leaves the input forest untouched |
| M2-T-019 | `TreeWalk.mutate` | INVA | MEDIUM | children are transformed BEFORE the parent match is tested, so the body closure sees a node whose children have already been rewritten |
| M2-T-020 | `TreeWalk.remove` | POST | HIGH | remove drops the node whose id matches |
| M2-T-021 | `TreeWalk.remove` | POST | HIGH | remove drops the removed node's entire subtree with it |
| M2-T-022 | `TreeWalk.remove` | POST | HIGH | nodes outside the removed subtree survive |
| M2-T-023 | `TreeWalk.rewritePaths` | POST | CONTRADICTED | a descendant path of form oldPrefix + "/" + rest becomes newPrefix + "/" + rest — no double slash, no eaten character |
| M2-T-024 | `TreeWalk.rewritePaths` | POST | CONTRADICTED | a path exactly EQUAL to oldPrefix becomes exactly newPrefix |
| M2-T-025 | `TreeWalk.rewritePaths` | INVA | HIGH | a non-boundary prefix match (`old/groupie` against prefix `old/group`) must NOT be rewritten |
| M2-T-026 | `TreeWalk.rewritePaths` | POST | HIGH | an unrelated path is left untouched |
| M2-T-027 | `TreeWalk.idsByPath` | POST | HIGH | idsByPath maps every non-nil path to its node's id at all depths, and nodes with a nil path are excluded from the map entirely |

### Claims recorded but deliberately NOT pinned by any test

- **M2-C-035** — the ITERATION ORDER of the returned Dictionary is not stable across processes (Swift seeds its hasher per process); any caller that iterates rather than subscripts gets a run-varying order
- **M2-C-036** — the recursion depth at which the walkers overflow the stack is environment-dependent (thread stack size, optimisation level) and has no guard in the code

### Property-test evidence

| property | statement | cases | held |
|---|---|---|---|
| P14 | every walker contract holds on forests WITH duplicate ids | 20,000 | True |
| P11 | collectIds / collect(true) / leaves agree with an independent explicit-stack pre-order oracle | 20,000 | True |
| P15 | first(where:) == collect(where:).first | 20,000 | True |
| P10 | collect(where: p) == collect(where: true).filter(p) | 20,000 | True |
| P12 | mutate and remove never disturb the input forest | 20,000 | True |
| P13 | rewritePaths matches the SEMANTIC self-or-descendant rule, not a transcription of the code — counterexample: forest [XPathNode(path: "research")], oldPrefix "research/", newPrefix "NEW" -> path unchanged; the semantic rule says it denotes the node itself | 90 | False |

## 3. Intent envelope

Musts and must-nots inferred for this module. Some are architectural rather than
behavioural; some may be wrong. They are given unruled.

| id | clause |
|---|---|
| M2-A-01 | **MUST** be the single implementation of tree walking — no per-type hand-rolled recursion anywhere |
| M2-A-02 | **MUST NOT** be re-implemented on the phone — MaughamCore owns it |
| M2-A-03 | **MUST** visit pre-order (parent before children) everywhere |
| M2-A-04 | **MUST** define leaf-ness by children-EMPTINESS, not node type — a childless branch IS a leaf |
| M2-A-05 | **MUST NOT** move kind-filtering inside `leaves` — callers filter the result |
| M2-A-06 | **MUST** apply the reconciled prefix rule: `p == oldPrefix` -> `newPrefix`; `oldPrefix + "/" + r` -> `newPrefix + "/" + r`; anything else untouched. No double slash, no eaten character |
| M2-A-07 | **MUST NOT** rewrite a non-boundary prefix match (`oldPrefix + "ie"`) |
| M2-A-08 | **MUST** leave nil paths untouched |
| M2-A-09 | **MUST** skip nil-path nodes in `idsByPath` |
| M2-A-10 | **MUST** resolve duplicate paths in `idsByPath` as last-writer-wins in pre-order |
| M2-A-11 | **MUST** return a new tree from `mutate` / `remove` rather than mutating in place |
| M2-A-12 | **MUST** have `mutate`'s body see the matched node with its children ALREADY transformed |
| M2-A-13 | **MUST** reach out-of-protocol fields (`path`) through caller-supplied closures, never by widening the protocol |
| M2-A-14 | **MUST** offer `first`/`collect` as the non-id counterparts to `find`/`collectIds` |
| M2-A-15 | **MUST** key on `String` ids — the protocol constrains `ID == String` |
| M2-A-16 | **MUST** have node ids unique within a forest |
| M2-A-17 | **MUST** tolerate an empty forest without trapping |
| M2-A-18 | **MUST NOT** prune a subtree because its parent failed the predicate |
| M2-A-19 | **MUST** rely on the store's unique-on-disk-path invariant to make the duplicate-path contest moot |
| M2-A-20 | **MUST** stay allocation-simple and recursive — no explicit stack, no iterative rewrite |
| M2-B-01 | **MUST** be treated as the TEST SUITE's trusted oracle as well as production's: 12 of the 13 test files that touch it use its walkers as fixture helpers to locate nodes for assertions about other modules |
| M2-B-02 | **MUST** encode the reconciled `dropFirst(+1)` rule once: two prior store-local implementations were proven equivalent, not merely unified |
| M2-B-03 | **MUST** return the PARENT from `first` when a parent and its descendant both match |
| M2-B-04 | **MUST** have `collect(where: { _ in true })` agree with `collectIds` |
| M2-B-05 | **MUST** handle the exact-match node in `rewritePaths`, which the store copies it replaced did NOT |
| M2-B-06 | **MAY** have `mutate`'s body change the node's id — nothing constrains it to preserve one |
