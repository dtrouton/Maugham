#!/usr/bin/env python3
"""Phase 8: build the regeneration brief for module M2 (TreeNode/TreeWalk).

The brief is EXACTLY the artifact the claims-as-durable-artifact thesis proposes:
public interfaces + the claims ledger + the intent envelope. It must contain no
implementation, no doc comments, no test source and no commit messages.

A guard at the bottom greps the emitted brief for tokens that only appear in the
implementation, so a leak fails loudly rather than silently invalidating the run.
"""
import json, re, sys

LEDGER = "register/01-claims-ledger.json"
OUT = "register/08-regeneration-brief.md"

d = json.load(open(LEDGER))
claims = [c for c in d["claims"] if c["claim_id"].startswith("M2")]
clauses = [c for c in d["_meta"]["intent_clause_verdicts"] if c["module"] == "M2"]

# Clause text is authored in 03-intent-envelope.md; carried here verbatim so the
# brief is self-contained. Verdicts are DELIBERATELY WITHHELD — the ledger has
# not been ruled, and the point is to test the artifact in its unruled state.
CLAUSE_TEXT = {
 "M2-A-01": ("MUST", "be the single implementation of tree walking — no per-type hand-rolled recursion anywhere"),
 "M2-A-02": ("MUST NOT", "be re-implemented on the phone — MaughamCore owns it"),
 "M2-A-03": ("MUST", "visit pre-order (parent before children) everywhere"),
 "M2-A-04": ("MUST", "define leaf-ness by children-EMPTINESS, not node type — a childless branch IS a leaf"),
 "M2-A-05": ("MUST NOT", "move kind-filtering inside `leaves` — callers filter the result"),
 "M2-A-06": ("MUST", "apply the reconciled prefix rule: `p == oldPrefix` -> `newPrefix`; `oldPrefix + \"/\" + r` -> `newPrefix + \"/\" + r`; anything else untouched. No double slash, no eaten character"),
 "M2-A-07": ("MUST NOT", "rewrite a non-boundary prefix match (`oldPrefix + \"ie\"`)"),
 "M2-A-08": ("MUST", "leave nil paths untouched"),
 "M2-A-09": ("MUST", "skip nil-path nodes in `idsByPath`"),
 "M2-A-10": ("MUST", "resolve duplicate paths in `idsByPath` as last-writer-wins in pre-order"),
 "M2-A-11": ("MUST", "return a new tree from `mutate` / `remove` rather than mutating in place"),
 "M2-A-12": ("MUST", "have `mutate`'s body see the matched node with its children ALREADY transformed"),
 "M2-A-13": ("MUST", "reach out-of-protocol fields (`path`) through caller-supplied closures, never by widening the protocol"),
 "M2-A-14": ("MUST", "offer `first`/`collect` as the non-id counterparts to `find`/`collectIds`"),
 "M2-A-15": ("MUST", "key on `String` ids — the protocol constrains `ID == String`"),
 "M2-A-16": ("MUST", "have node ids unique within a forest"),
 "M2-A-17": ("MUST", "tolerate an empty forest without trapping"),
 "M2-A-18": ("MUST NOT", "prune a subtree because its parent failed the predicate"),
 "M2-A-19": ("MUST", "rely on the store's unique-on-disk-path invariant to make the duplicate-path contest moot"),
 "M2-A-20": ("MUST", "stay allocation-simple and recursive — no explicit stack, no iterative rewrite"),
 "M2-B-01": ("MUST", "be treated as the TEST SUITE's trusted oracle as well as production's: 12 of the 13 test files that touch it use its walkers as fixture helpers to locate nodes for assertions about other modules"),
 "M2-B-02": ("MUST", "encode the reconciled `dropFirst(+1)` rule once: two prior store-local implementations were proven equivalent, not merely unified"),
 "M2-B-03": ("MUST", "return the PARENT from `first` when a parent and its descendant both match"),
 "M2-B-04": ("MUST", "have `collect(where: { _ in true })` agree with `collectIds`"),
 "M2-B-05": ("MUST", "handle the exact-match node in `rewritePaths`, which the store copies it replaced did NOT"),
 "M2-B-06": ("MAY", "have `mutate`'s body change the node's id — nothing constrains it to preserve one"),
}

SIGNATURES = """```swift
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
```"""

lines = []
w = lines.append
w("# Regeneration brief — `MaughamCore.TreeNode` / `TreeWalk`")
w("")
w("You are implementing a Swift file from its specification. **You have not seen, and will")
w("not be given, the original implementation, its doc comments, its tests, or its commit")
w("history.** Everything known about the required behaviour is in this document.")
w("")
w("## Your task")
w("")
w("Write the complete contents of `TreeNode.swift` — a file in a Swift package target that")
w("imports only `Foundation`. It must:")
w("")
w("- declare exactly the public surface in §1, with those exact signatures;")
w("- satisfy every claim in §2 and every clause in §3;")
w("- compile under Swift 5.10 language mode, targeting macOS 14 / iOS 17;")
w("- contain no third-party dependencies and no UI framework imports.")
w("")
w("Output the file as a single Swift code block, then a short list of any places where the")
w("specification was **ambiguous, silent, or self-contradictory** and you had to choose. That")
w("list is as valuable as the code — it is the point of the exercise. Do not soften it.")
w("")
w("Write ordinary, idiomatic Swift. Do not optimise for passing a test suite you cannot see.")
w("")
w("## 1. Public interface")
w("")
w(SIGNATURES)
w("")
w("## 2. Behavioural claims")
w("")
w("`POSTCONDITION` / `PRECONDITION` / `INVARIANT` classify the claim. Warrant records how")
w("strongly the claim is evidenced, not how important it is: `HIGH` = a dedicated existing")
w("test asserts it; `MEDIUM` = weakly asserted; `LOW` = observed behaviour with no test")
w("asserting it and no evidence anyone intended it; `CONTRADICTED` = a randomised property")
w("test found a counterexample to the claim as written.")
w("")
w("| id | scope | kind | warrant | claim |")
w("|---|---|---|---|---|")
for c in sorted(claims, key=lambda x: x["claim_id"]):
    stmt = c["statement"].replace("|", "\\|")
    w(f"| {c['claim_id']} | `{c['scope']}` | {c['kind'][:4]} | {c['warrant']} | {stmt} |")
w("")
w("### Claims recorded but deliberately NOT pinned by any test")
w("")
for c in claims:
    if c["evidence"].get("non_deterministic"):
        w(f"- **{c['claim_id']}** — {c['statement']}")
w("")
w("### Property-test evidence")
w("")
w("| property | statement | cases | held |")
w("|---|---|---|---|")
seen = set()
for c in claims:
    pt = c["evidence"].get("property_test")
    for p in ([pt] if isinstance(pt, dict) else (pt or [])):
        if p and p["property"] not in seen:
            seen.add(p["property"])
            cex = f" — counterexample: {p['counterexample']}" if p["counterexample"] else ""
            w(f"| {p['property']} | {p['statement']}{cex} | {p['cases_run']:,} | {p['held']} |")
w("")
w("## 3. Intent envelope")
w("")
w("Musts and must-nots inferred for this module. Some are architectural rather than")
w("behavioural; some may be wrong. They are given unruled.")
w("")
w("| id | clause |")
w("|---|---|")
for c in sorted(clauses, key=lambda x: x["clause"]):
    kind, text = CLAUSE_TEXT[c["clause"]]
    w(f"| {c['clause']} | **{kind}** {text.replace('|', chr(92)+'|')} |")
w("")

brief = "\n".join(lines)

# ---- leak guard: tokens that appear ONLY in the implementation -------------
impl = open("Packages/MaughamCore/Sources/MaughamCore/TreeNode.swift").read()
BANNED = ["compactMap", "append(contentsOf:", "dropFirst(oldPrefix.count)",
          "var out:", "func walk(", "nodes.map {", "hasPrefix(oldPrefix"]
leaks = [t for t in BANNED if t in brief]
if leaks:
    sys.exit(f"LEAK: implementation tokens present in the brief: {leaks}")
for line in impl.splitlines():
    s = line.strip()
    if s.startswith("///") or s.startswith("//"):
        body = s.lstrip("/ ").strip()
        if len(body) > 45 and body in brief:
            sys.exit(f"LEAK: doc-comment line reproduced verbatim in the brief: {body!r}")

open(OUT, "w").write(brief)
print(f"wrote {OUT}: {len(claims)} claims, {len(clauses)} clauses, {len(brief.splitlines())} lines")
print("leak guard: clean")
