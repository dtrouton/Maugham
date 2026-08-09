import XCTest
import MaughamCore

/// CHARACTERIZATION for `MaughamCore.TreeWalk` (module M2).
///
/// Every assertion here pins behaviour OBSERVED at HEAD `db1bea2c` via
/// `ObservationProbe`, not behaviour I expected. Nothing here is a judgement
/// that the behaviour is correct — warrant LOW, intent UNKNOWN. Claim ids
/// (M2-C-xxx) match `experiment/01-claims-ledger.json`.
final class TreeWalkCharacterization: XCTestCase {

    private func sample() -> [XNode] {
        [XNode("a", [XNode("a1"), XNode("a2", [XNode("a2x")])]), XNode("b")]
    }

    // MARK: - Empty forest (M2-C-001 … M2-C-008)

    func test_C001_to_C008_everyWalkerToleratesAnEmptyForest() {
        let empty: [XNode] = []
        XCTAssertNil(TreeWalk.find(id: "a", in: empty))                       // M2-C-001
        XCTAssertFalse(TreeWalk.contains(id: "a", in: empty))                 // M2-C-002
        XCTAssertEqual(TreeWalk.collectIds(in: empty), [])                    // M2-C-003
        XCTAssertEqual(TreeWalk.leaves(in: empty).map(\.id), [])              // M2-C-004
        XCTAssertEqual(TreeWalk.collect(in: empty) { _ in true }.map(\.id), []) // M2-C-005
        XCTAssertNil(TreeWalk.first(in: empty) { _ in true })                 // M2-C-006
        XCTAssertEqual(TreeWalk.mutate(id: "a", in: empty) { $0 }, [])        // M2-C-007
        XCTAssertEqual(TreeWalk.remove(id: "a", in: empty), [])               // M2-C-008
    }

    func test_C009_idsByPathOnAnEmptyForestIsAnEmptyMap() {
        XCTAssertEqual(TreeWalk.idsByPath(in: [XPathNode](), path: XPathNode.readPath), [:])
    }

    // MARK: - Duplicate ids (M2-C-010 … M2-C-014)
    //
    // Nothing in the type system or the API forbids two nodes sharing an id.
    // These pin what each walker does when that happens.

    private func duplicated() -> [XNode] {
        [XNode("d", [XNode("d"), XNode("x")]), XNode("d")]
    }

    func test_C010_findReturnsTheFirstMatchInPreOrder_theShallowestLeftmost() {
        // The root "d" (2 children) wins over its own child "d" and the second root "d".
        XCTAssertEqual(TreeWalk.find(id: "d", in: duplicated())?.children?.count, 2)
    }

    func test_C011_collectIdsEmitsDuplicateIdsWithoutDeduplication() {
        XCTAssertEqual(TreeWalk.collectIds(in: duplicated()), ["d", "d", "x", "d"])
    }

    func test_C012_mutateAppliesToEVERYNodeMatchingTheId_notJustTheFirst() {
        let out = TreeWalk.mutate(id: "d", in: duplicated()) { node in
            var n = node; n.id = "R"; return n
        }
        XCTAssertEqual(out.map(\.id), ["R", "R"])
        XCTAssertEqual(out[0].children?.map(\.id), ["R", "x"],
                       "the nested duplicate is rewritten too")
    }

    func test_C013_removeDropsEVERYNodeMatchingTheId_hereEmptyingTheForest() {
        XCTAssertEqual(TreeWalk.remove(id: "d", in: duplicated()), [])
    }

    func test_C014_containsIsTrueWhenAnyDuplicateMatches() {
        XCTAssertTrue(TreeWalk.contains(id: "d", in: duplicated()))
    }

    // MARK: - mutate ordering and identity (M2-C-015 … M2-C-017)

    func test_C015_childrenAreTransformedBeforeTheParentsBodyRuns() {
        // The doc comment asserts this ("body sees the matched node with its
        // already-transformed children"); no existing test observes it.
        let nested = [XNode("p", [XNode("p")])]
        var childrenSeenByParentBody: [String]?
        _ = TreeWalk.mutate(id: "p", in: nested) { node in
            if childrenSeenByParentBody == nil { childrenSeenByParentBody = node.children?.map(\.id) }
            var n = node; n.id = "P"; return n
        }
        XCTAssertEqual(childrenSeenByParentBody, ["P"],
                       "the parent's body sees the ALREADY-renamed child")
    }

    func test_C016_mutateWithAnAbsentIdIsTheIdentityAndNeverRunsTheBody() {
        var ran = false
        let out = TreeWalk.mutate(id: "absent", in: sample()) { n in ran = true; return n }
        XCTAssertEqual(out, sample())
        XCTAssertFalse(ran)
    }

    func test_C017_removeWithAnAbsentIdIsTheIdentity() {
        XCTAssertEqual(TreeWalk.remove(id: "absent", in: sample()), sample())
    }

    // MARK: - collect / first traversal shape (M2-C-018 … M2-C-021)

    func test_C018_collectDescendsThroughANodeThatFAILSThePredicate() {
        // The single most load-bearing property of the 36 call sites that pass a
        // predicate: filtering a parent out must NOT prune its matching children.
        let tree = [XNode("parent-no", [XNode("yes-1"), XNode("no-2", [XNode("yes-3")])])]
        XCTAssertEqual(TreeWalk.collect(in: tree) { $0.id.hasPrefix("yes") }.map(\.id),
                       ["yes-1", "yes-3"])
    }

    func test_C019_aCollectedNodeCarriesItsWHOLESubtree_notAFilteredOne() {
        // collect(where: id == "a") returns "a" with a1 and a2 still attached, even
        // though neither satisfies the predicate. Callers that then walk the result
        // see nodes the predicate rejected.
        let hits = TreeWalk.collect(in: sample()) { $0.id == "a" }
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.children?.map(\.id), ["a1", "a2"])
    }

    func test_C020_firstIsDepthFirstNotBreadthFirst() {
        // A deep match under sibling 1 beats a shallow match at sibling 2.
        let tree = [XNode("s1", [XNode("m-deep")]), XNode("m-shallow")]
        XCTAssertEqual(TreeWalk.first(in: tree) { $0.id.hasPrefix("m") }?.id, "m-deep")
    }

    func test_C021_collectWithAnAlwaysTruePredicateAgreesWithCollectIdsOnDuplicates() {
        XCTAssertEqual(TreeWalk.collect(in: duplicated()) { _ in true }.map(\.id),
                       TreeWalk.collectIds(in: duplicated()))
    }

    // MARK: - leaves (M2-C-022 … M2-C-023)

    func test_C022_aChainTerminatingInAnEmptyChildrenArrayYieldsThatNodeAsTheOnlyLeaf() {
        let chain = [XNode("c1", [XNode("c2", [XNode("c3", [])])])]
        XCTAssertEqual(TreeWalk.leaves(in: chain).map(\.id), ["c3"])
    }

    func test_C023_leavesPreservesPreOrderAcrossSiblingSubtrees() {
        XCTAssertEqual(TreeWalk.leaves(in: sample()).map(\.id), ["a1", "a2x", "b"])
    }

    // MARK: - rewritePaths edges (M2-C-024 … M2-C-030)

    private func rewrite(_ tree: [XPathNode], _ old: String, _ new: String) -> [XPathNode] {
        TreeWalk.rewritePaths(in: tree, replacingPrefix: old, with: new,
                              path: XPathNode.readPath, setPath: XPathNode.writePath)
    }

    func test_C024_anEmptyOldPrefixRewritesONLYEmptyPaths_notEveryPath() {
        let out = rewrite([XPathNode("a", path: "x/y"), XPathNode("b", path: "")], "", "NEW")
        XCTAssertEqual(out.map(\.path), ["x/y", "NEW"])
    }

    func test_C025_oldPrefixEqualToNewPrefixIsTheIdentity() {
        XCTAssertEqual(rewrite([XPathNode("a", path: "p/q")], "p", "p").map(\.path), ["p/q"])
    }

    func test_C026_aNilPathIsNeverAssignedOne() {
        XCTAssertEqual(rewrite([XPathNode("a", path: nil)], "p", "NEW").map(\.path), [nil])
    }

    func test_C027_aTrailingSlashOnOldPrefixSilentlyMakesTheRewriteANoOp() {
        // "p/" matches neither `p == "p/"` nor `p.hasPrefix("p//")`. A caller that
        // passes a directory path with a trailing separator gets no rewrite and no
        // diagnostic.
        XCTAssertEqual(rewrite([XPathNode("a", path: "p/q")], "p/", "NEW").map(\.path), ["p/q"])
    }

    func test_C028_theWalkDescendsIntoChildrenOfANodeWhosePathDidNotMatch() {
        let out = rewrite([XPathNode("a", path: "unrelated",
                                     children: [XPathNode("b", path: "p/q")])], "p", "NEW")
        XCTAssertEqual(out.first?.path, "unrelated")
        XCTAssertEqual(out.first?.children?.first?.path, "NEW/q")
    }

    func test_C029_anEmptyNewPrefixProducesAPathWithALeadingSlash() {
        // "p/q" -> "/q". Nothing rejects an empty newPrefix, and the result reads
        // as an absolute path to anything that later joins it against a root.
        XCTAssertEqual(rewrite([XPathNode("a", path: "p/q")], "p", "").map(\.path), ["/q"])
    }

    func test_C030_bothTheExactNodeAndItsDescendantsAreRewrittenInOnePass() {
        let out = rewrite([XPathNode("a", path: "p",
                                     children: [XPathNode("b", path: "p/q")])], "p", "NEW")
        XCTAssertEqual(out.first?.path, "NEW")
        XCTAssertEqual(out.first?.children?.first?.path, "NEW/q")
    }

    // MARK: - idsByPath edges (M2-C-031 … M2-C-033)

    func test_C031_duplicatePathsResolveToTheLASTNodeVisitedInPreOrder() {
        let tree = [XPathNode("first", path: "same"), XPathNode("second", path: "same")]
        XCTAssertEqual(TreeWalk.idsByPath(in: tree, path: XPathNode.readPath)["same"], "second")
    }

    func test_C032_whenAParentAndChildSharePathTheCHILDWins() {
        let tree = [XPathNode("parent", path: "same",
                              children: [XPathNode("child", path: "same")])]
        XCTAssertEqual(TreeWalk.idsByPath(in: tree, path: XPathNode.readPath)["same"], "child")
    }

    func test_C033_anEmptyStringPathIsAValidKey_notTreatedAsAbsent() {
        XCTAssertEqual(TreeWalk.idsByPath(in: [XPathNode("e", path: "")],
                                          path: XPathNode.readPath), ["": "e"])
    }

    // MARK: - Corrections found by the Phase 10 regeneration (M2-C-024a … M2-C-037)
    //
    // These three were found by a blind implementer reading the CLAIMS LEDGER
    // against itself — not by any test, and not by 240,160 property cases. Two of
    // them falsify claims I wrote in Phase 2; the third is a latent defect in
    // production code. See experiment/10-regeneration-results.md.

    func test_C024a_anEmptyOldPrefixALSORewritesEveryABSOLUTEPath() {
        // FALSIFIES the original M2-C-024 ("rewrites ONLY empty paths"). With an
        // empty oldPrefix the descendant arm reads `"" + "/"`, so every path
        // beginning with "/" matches. My Phase 2 probe only tried "x/y" and "",
        // neither of which is absolute — so the test confirmed my own wording
        // rather than testing it.
        let out = rewrite([XPathNode("abs", path: "/q"),
                           XPathNode("rel", path: "x/y"),
                           XPathNode("empty", path: "")], "", "NEW")
        XCTAssertEqual(out.map(\.path), ["NEW/q", "x/y", "NEW"])
    }

    func test_C027a_aTrailingSlashStillRewritesAPathEqualToThePrefixItself() {
        // FALSIFIES the original M2-C-027 ("makes the WHOLE rewrite a no-op").
        // The exact-match arm is unaffected by the trailing separator; only the
        // descendant arm is dead.
        let out = rewrite([XPathNode("exact", path: "p/"),
                           XPathNode("child", path: "p/q")], "p/", "NEW")
        XCTAssertEqual(out.map(\.path), ["NEW", "p/q"],
                       "exact match fires; the descendant arm is the part that no-ops")
    }

    /// A CLASS conformer. `TreeNode` has no `AnyObject` bound, so this is legal.
    private final class ClassNode: TreeNode {
        var id: String
        var children: [ClassNode]?
        init(_ id: String, _ children: [ClassNode]? = nil) {
            self.id = id
            self.children = children
        }
    }

    func test_C037_withACLASSConformer_mutateAndRemoveDISTURBTheInputForest() {
        // A LATENT DEFECT, pinned. `M2-A-11`, `M2-T-018` and property P12 all say
        // the input forest is never disturbed. For a class conformer, `var copy =
        // node` copies a REFERENCE, so writing `copy.children` writes through to
        // the caller's own node. P12 ran 20,000 cases and never saw this because
        // its generator only ever produced structs.
        //
        // Latent, not live: StructureItem and ResearchItem are both structs. But
        // the protocol permits a class and nothing — type, test or comment — warns.
        let child = ClassNode("kid")
        let root = ClassNode("root", [child])
        let forest = [root]

        XCTAssertEqual(forest[0].children?.map(\.id), ["kid"])
        _ = TreeWalk.remove(id: "kid", in: forest)
        XCTAssertEqual(forest[0].children?.map(\.id), [],
                       "remove wrote through to the caller's forest")

        let root2 = ClassNode("r2", [ClassNode("a")])
        let forest2 = [root2]
        _ = TreeWalk.mutate(id: "a", in: forest2) { n in ClassNode("RENAMED", n.children) }
        XCTAssertEqual(forest2[0].children?.map(\.id), ["RENAMED"],
                       "mutate wrote through too")
    }

    // MARK: - Depth (M2-C-034)

    func test_C034_theRecursiveWalkersSurviveADeeplyNestedChain() {
        // Every walker is unbounded recursion with no depth guard. This pins that a
        // 1,000-deep chain is fine. The failure THRESHOLD is stack-size dependent
        // and is deliberately recorded as non-deterministic rather than pinned.
        var node = XNode("leaf")
        for i in (0..<1_000).reversed() { node = XNode("n\(i)", [node]) }
        XCTAssertEqual(TreeWalk.collectIds(in: [node]).count, 1_001)
        XCTAssertEqual(TreeWalk.leaves(in: [node]).map(\.id), ["leaf"])
        XCTAssertNotNil(TreeWalk.find(id: "leaf", in: [node]))
    }
}
