#!/usr/bin/env python3
"""Phase 2: append CHARACTERIZATION claims to the ledger."""
import json, collections

LEDGER = "experiment/01-claims-ledger.json"

# (claim_id, scope, kind, statement, test_ref, extra)
# extra: dict merged into the claim (e.g. evidence overrides, _note)
M2 = [
 ("M2-C-001","TreeWalk.find","POSTCONDITION","find on an empty forest returns nil rather than trapping","test_C001_to_C008_everyWalkerToleratesAnEmptyForest",{}),
 ("M2-C-002","TreeWalk.contains","POSTCONDITION","contains on an empty forest is false","test_C001_to_C008_everyWalkerToleratesAnEmptyForest",{}),
 ("M2-C-003","TreeWalk.collectIds","POSTCONDITION","collectIds on an empty forest returns an empty array","test_C001_to_C008_everyWalkerToleratesAnEmptyForest",{}),
 ("M2-C-004","TreeWalk.leaves","POSTCONDITION","leaves on an empty forest returns an empty array","test_C001_to_C008_everyWalkerToleratesAnEmptyForest",{}),
 ("M2-C-005","TreeWalk.collect","POSTCONDITION","collect on an empty forest returns an empty array without invoking the predicate","test_C001_to_C008_everyWalkerToleratesAnEmptyForest",{}),
 ("M2-C-006","TreeWalk.first","POSTCONDITION","first on an empty forest returns nil without invoking the predicate","test_C001_to_C008_everyWalkerToleratesAnEmptyForest",{}),
 ("M2-C-007","TreeWalk.mutate","POSTCONDITION","mutate on an empty forest returns an empty forest","test_C001_to_C008_everyWalkerToleratesAnEmptyForest",{}),
 ("M2-C-008","TreeWalk.remove","POSTCONDITION","remove on an empty forest returns an empty forest","test_C001_to_C008_everyWalkerToleratesAnEmptyForest",{}),
 ("M2-C-009","TreeWalk.idsByPath","POSTCONDITION","idsByPath on an empty forest returns an empty map","test_C009_idsByPathOnAnEmptyForestIsAnEmptyMap",{}),
 ("M2-C-010","TreeWalk.find","POSTCONDITION","when several nodes share an id, find returns the first in pre-order (shallowest, then leftmost)","test_C010_findReturnsTheFirstMatchInPreOrder_theShallowestLeftmost",{}),
 ("M2-C-011","TreeWalk.collectIds","POSTCONDITION","collectIds emits duplicate ids once per occurrence; it does not deduplicate","test_C011_collectIdsEmitsDuplicateIdsWithoutDeduplication",{}),
 ("M2-C-012","TreeWalk.mutate","POSTCONDITION","mutate applies the body to EVERY node whose id matches, not just the first","test_C012_mutateAppliesToEVERYNodeMatchingTheId_notJustTheFirst",{}),
 ("M2-C-013","TreeWalk.remove","POSTCONDITION","remove drops EVERY node whose id matches; with duplicated root ids the forest can empty entirely","test_C013_removeDropsEVERYNodeMatchingTheId_hereEmptyingTheForest",{}),
 ("M2-C-014","TreeWalk.contains","POSTCONDITION","contains is true when any duplicate matches","test_C014_containsIsTrueWhenAnyDuplicateMatches",{}),
 ("M2-C-015","TreeWalk.mutate","INVARIANT","children are transformed before the parent's body closure runs, so the body observes already-rewritten children","test_C015_childrenAreTransformedBeforeTheParentsBodyRuns",{"_cross_ref":"confirms M2-T-019, which was MEDIUM/INCIDENTAL"}),
 ("M2-C-016","TreeWalk.mutate","POSTCONDITION","mutate with an absent id is the identity and never invokes the body closure","test_C016_mutateWithAnAbsentIdIsTheIdentityAndNeverRunsTheBody",{}),
 ("M2-C-017","TreeWalk.remove","POSTCONDITION","remove with an absent id is the identity","test_C017_removeWithAnAbsentIdIsTheIdentity",{}),
 ("M2-C-018","TreeWalk.collect","INVARIANT","collect descends into a node that FAILS the predicate; a filtered-out parent does not prune its matching children","test_C018_collectDescendsThroughANodeThatFAILSThePredicate",{"_cross_ref":"confirms M2-T-015, which was MEDIUM/INCIDENTAL and the most load-bearing untested property in M2"}),
 ("M2-C-019","TreeWalk.collect","POSTCONDITION","a collected node carries its ENTIRE original subtree, including descendants that failed the predicate","test_C019_aCollectedNodeCarriesItsWHOLESubtree_notAFilteredOne",{}),
 ("M2-C-020","TreeWalk.first","INVARIANT","first is depth-first, not breadth-first: a deep match under an earlier sibling beats a shallow match at a later one","test_C020_firstIsDepthFirstNotBreadthFirst",{}),
 ("M2-C-021","TreeWalk.collect","INVARIANT","collect with an always-true predicate agrees with collectIds even in the presence of duplicate ids","test_C021_collectWithAnAlwaysTruePredicateAgreesWithCollectIdsOnDuplicates",{}),
 ("M2-C-022","TreeWalk.leaves","POSTCONDITION","a chain terminating in an empty children array yields exactly that terminal node as the single leaf","test_C022_aChainTerminatingInAnEmptyChildrenArrayYieldsThatNodeAsTheOnlyLeaf",{}),
 ("M2-C-023","TreeWalk.leaves","POSTCONDITION","leaves preserves pre-order across sibling subtrees","test_C023_leavesPreservesPreOrderAcrossSiblingSubtrees",{}),
 ("M2-C-024","TreeWalk.rewritePaths","POSTCONDITION","an empty oldPrefix rewrites ONLY empty paths, not every path","test_C024_anEmptyOldPrefixRewritesONLYEmptyPaths_notEveryPath",{}),
 ("M2-C-025","TreeWalk.rewritePaths","POSTCONDITION","oldPrefix == newPrefix is the identity","test_C025_oldPrefixEqualToNewPrefixIsTheIdentity",{}),
 ("M2-C-026","TreeWalk.rewritePaths","INVARIANT","a node with a nil path is never assigned one","test_C026_aNilPathIsNeverAssignedOne",{}),
 ("M2-C-027","TreeWalk.rewritePaths","POSTCONDITION","a trailing slash on oldPrefix silently makes the whole rewrite a no-op, with no diagnostic","test_C027_aTrailingSlashOnOldPrefixSilentlyMakesTheRewriteANoOp",{"_defect_candidate":True}),
 ("M2-C-028","TreeWalk.rewritePaths","POSTCONDITION","the walk descends into the children of a node whose own path did not match","test_C028_theWalkDescendsIntoChildrenOfANodeWhosePathDidNotMatch",{}),
 ("M2-C-029","TreeWalk.rewritePaths","POSTCONDITION","an empty newPrefix produces paths with a leading slash (e.g. 'p/q' -> '/q')","test_C029_anEmptyNewPrefixProducesAPathWithALeadingSlash",{"_defect_candidate":True}),
 ("M2-C-030","TreeWalk.rewritePaths","POSTCONDITION","the exact-match node and its descendants are both rewritten in a single pass","test_C030_bothTheExactNodeAndItsDescendantsAreRewrittenInOnePass",{}),
 ("M2-C-031","TreeWalk.idsByPath","POSTCONDITION","when two nodes share a path, the LAST visited in pre-order wins","test_C031_duplicatePathsResolveToTheLASTNodeVisitedInPreOrder",{}),
 ("M2-C-032","TreeWalk.idsByPath","POSTCONDITION","when a parent and child share a path, the CHILD wins","test_C032_whenAParentAndChildSharePathTheCHILDWins",{}),
 ("M2-C-033","TreeWalk.idsByPath","POSTCONDITION","an empty-string path is a valid key, distinct from an absent (nil) path","test_C033_anEmptyStringPathIsAValidKey_notTreatedAsAbsent",{}),
 ("M2-C-034","TreeWalk","POSTCONDITION","every walker is unbounded recursion with no depth guard, and survives a 1,000-deep chain","test_C034_theRecursiveWalkersSurviveADeeplyNestedChain",{}),
 ("M2-C-035","TreeWalk.idsByPath","POSTCONDITION","the ITERATION ORDER of the returned Dictionary is not stable across processes (Swift seeds its hasher per process); any caller that iterates rather than subscripts gets a run-varying order","NOT_PINNED",{"nd":True}),
 ("M2-C-036","TreeWalk","PRECONDITION","the recursion depth at which the walkers overflow the stack is environment-dependent (thread stack size, optimisation level) and has no guard in the code","NOT_PINNED",{"nd":True}),
]

M1 = [
 ("M1-C-001","PaletteCard.color(fromHex:)","PRECONDITION","hex bodies of any length other than 3 or 6 characters are rejected","test_C001_lengthsOtherThanThreeOrSixHexDigitsAreRejected",{}),
 ("M1-C-002","PaletteCard.color(fromHex:)","PRECONDITION","surrounding or interior whitespace is not tolerated and yields nil","test_C002_surroundingOrInteriorWhitespaceIsNotTolerated",{}),
 ("M1-C-003","PaletteCard.color(fromHex:)","POSTCONDITION","a leading '+' is ACCEPTED as a hex-body character: '#+FFFFF' passes the six-character check and parses as 0x0FFFFF","test_C003_aLeadingPlusSignIsACCEPTEDAsPartOfTheHexBody",{"_defect_candidate":True}),
 ("M1-C-004","PaletteCard.color(fromHex:)","PRECONDITION","a leading '-' is rejected","test_C004_aLeadingMinusSignIsRejected",{}),
 ("M1-C-005","PaletteCard.color(fromHex:)","PRECONDITION","non-ASCII digit forms (fullwidth, Arabic-Indic) are rejected","test_C005_nonASCIIDigitFormsAreRejected",{}),
 ("M1-C-006","PaletteCard.color(fromHex:)","PRECONDITION","the empty string is rejected","test_C006_theEmptyStringIsRejected",{}),
 ("M1-C-007","PaletteCard.color(fromHex:)","POSTCONDITION","the 3-digit form expands by digit doubling and agrees exactly with the equivalent 6-digit form, case-insensitively","test_C007_theThreeDigitFormExpandsByDigitDoublingAndIsCaseInsensitive",{}),
 ("M1-C-008","PaletteCardParser.parse","POSTCONDITION","an empty document yields a fully defaulted card: fallback title, .other, empty everything","test_C008_anEmptyDocumentYieldsAFullyDefaultedCard",{}),
 ("M1-C-009","PaletteCardParser.parse","POSTCONDITION","a whitespace-only document becomes BODY, because the structural-framing test is raw.isEmpty rather than a blankness test","test_C009_aWhitespaceOnlyDocumentBecomesBODY_notAnEmptyCard",{}),
 ("M1-C-010","PaletteCardParser.parse","POSTCONDITION","a '# ' line with no title text is not a title (the trimmed probe collapses it to '#') and is kept as body","test_C010_aHashLineWithNoTitleTextIsNOTATitleAndFallsIntoBody",{}),
 ("M1-C-011","PaletteCardParser.parse","POSTCONDITION","a SECOND '# ' heading is kept as body text rather than discarded","test_C011_aSecondTitleHeadingIsKeptAsBODYRatherThanDiscarded",{}),
 ("M1-C-012","PaletteCardParser.parse","PRECONDITION","a '#' with no following space is not a title","test_C012_aHashWithNoFollowingSpaceIsNotATitle",{}),
 ("M1-C-013","PaletteCardParser.parse","POSTCONDITION","an H3 ('### ') heading is neither a title nor a section and falls into body","test_C013_anH3HeadingIsNeitherTitleNorSectionAndBecomesBody",{}),
 ("M1-C-014","PaletteCardParser.parse","POSTCONDITION","section heading matching is case-insensitive","test_C014_sectionHeadingMatchingIsCaseInsensitive",{}),
 ("M1-C-015","PaletteCardParser.parse","POSTCONDITION","extra spaces inside and after a section heading are tolerated","test_C015_extraSpacesInsideASectionHeadingAreTolerated",{}),
 ("M1-C-016","PaletteCardParser.parse","POSTCONDITION","an INDENTED section heading still opens that section, because structure detection runs on the trimmed probe","test_C016_anINDENTEDSectionHeadingStillOpensThatSection",{}),
 ("M1-C-017","PaletteCardParser.parse","PRECONDITION","a heading with no space after the hashes is not a section","test_C017_aHeadingWithNoSpaceAfterTheHashesIsNotASection",{}),
 ("M1-C-018","PaletteCardParser.parse","POSTCONDITION","a repeated section heading appends to the same collection rather than resetting it","test_C018_aRepeATEDSectionHeadingAppendsToTheSameCollection",{}),
 ("M1-C-019","PaletteCardParser.parse","POSTCONDITION","sections may appear in any order","test_C019_sectionsMayAppearInAnyOrder",{}),
 ("M1-C-020","PaletteCardParser.parse","POSTCONDITION","the kind key tolerates a missing space after the colon and any casing of the key itself","test_C020_theKindKeyToleratesAMissingSpaceAndAnyKeyCasing",{}),
 ("M1-C-021","PaletteCardParser.parse","POSTCONDITION","an EMPTY kind value consumes the one-shot capture: kind becomes .other and a later well-formed kind: line is demoted to body","test_C021_anEmptyKindValueCONSUMEStheOneShotCapture",{"_defect_candidate":True}),
 ("M1-C-022","PaletteCardParser.parse","POSTCONDITION","a kind: line appearing after a section heading is discarded entirely — neither captured as kind nor kept as body","test_C022_aKindLineAfterASectionHeadingIsDiscardedEntirely",{}),
 ("M1-C-023","PaletteCardParser.parse","POSTCONDITION","a blank line the writer typed between pre-kind prose and the kind: line is silently eaten, but a whitespace-bearing line in the same position survives","test_C023_aBlankLineBetweenPreKindProseAndTheKindLineIsSILENTLYEATEN",{"_defect_candidate":True}),
 ("M1-C-024","PaletteCardParser.parse","POSTCONDITION","a CRLF document parses as ONE line — Swift treats \\r\\n as a single Character so split(separator:'\\n') never fires — and the title swallows the whole file while kind, swatches, senses and images are all lost","test_C024_aCRLFDocumentParsesAsONELine_losingEveryField",{"_defect_candidate":True}),
 ("M1-C-025","PaletteCardParser.parse","POSTCONDITION","swatches are neither deduplicated nor case-normalised by the parser","test_C025_swatchesAreNeitherDeduplicatedNorCaseNormalisedByTheParser",{}),
 ("M1-C-026","PaletteCardParser.parse","POSTCONDITION","a 3-digit swatch survives parsing unexpanded; expansion happens only inside color(fromHex:)","test_C026_theThreeDigitSwatchFormSurvivesParsingUnexpanded",{}),
 ("M1-C-027","PaletteCardParser.parse","POSTCONDITION","an unrecognised sense prefix keeps the WHOLE item text, colon included","test_C027_anUnrecognisedSensePrefixKeepsTheWHOLEItemTextIncludingTheColon",{}),
 ("M1-C-028","PaletteCardParser.parse","POSTCONDITION","an item beginning with a colon is untagged and keeps the colon","test_C028_anItemBeginningWithAColonIsUntaggedAndKeepsTheColon",{}),
 ("M1-C-029","PaletteCardParser.parse","POSTCONDITION","whitespace around the sense token is tolerated","test_C029_whitespaceAroundTheSenseTokenIsTolerated",{}),
 ("M1-C-030","PaletteCardParser.parse","POSTCONDITION","a bare '-' or '- ' item is dropped from every section","test_C030_aBareDashItemIsDroppedFromEverySection",{}),
 ("M1-C-031","PaletteCardParser.parse","POSTCONDITION","dash-item images are NOT deduplicated against each other","test_C031_dashItemImagesAreNOTDeduplicatedAgainstEachOther",{}),
 ("M1-C-032","PaletteCardParser.parse","POSTCONDITION","an inline image IS deduplicated against an already-collected dash item, giving the two intake routes different dedup rules","test_C032_anINLINEImageIsDeduplicatedAgainstAnAlreadyCollectedDashItem",{}),
 ("M1-C-033","PaletteCardParser.parse","POSTCONDITION","an absolute path passes through resolution unchanged","test_C033_anAbsolutePathPassesThroughResolutionUnchanged",{}),
 ("M1-C-034","PaletteCardParser.parse","POSTCONDITION","a remote-URL dash item is skipped entirely","test_C034_aRemoteURLDashItemIsSkippedEntirely",{}),
 ("M1-C-035","PaletteCardParser.parse","POSTCONDITION","climbing above the project root is clamped rather than rejected: '../../../../x.png' resolves to 'x.png'","test_C035_climbingAboveTheProjectRootIsCLAMPEDRatherThanRejected",{}),
 ("M1-C-036","PaletteCardParser.parse","POSTCONDITION","'.' and '..' segments are collapsed in place during resolution","test_C036_dotAndDotDotSegmentsAreCollapsedInPlace",{}),
 ("M1-C-037","PaletteCardParser.parse","POSTCONDITION","an empty cardDirectory leaves relative paths bare","test_C037_anEmptyCardDirectoryLeavesRelativePathsBare",{}),
 ("M1-C-038","PaletteCardParser.parse","POSTCONDITION","an unknown heading BEFORE any real section is kept as body, heading line included, along with the prose under it","test_C038_anUnknownHeadingBEFOREAnyRealSectionIsKeptAsBodyIncludingItsProse",{}),
 ("M1-C-039","PaletteCardParser.parse","POSTCONDITION","an unknown heading AFTER real structure discards itself and everything under it up to the next heading","test_C039_anUnknownHeadingAFTERRealStructureDiscardsItselfAndItsContent",{}),
 ("M1-C-040","PaletteCardRenderer.render","POSTCONDITION","the canonical render of an empty card is a fixed byte string with two blank lines between empty sections","test_C040_theCanonicalRenderOfAnEmptyCardHasAFixedByteShape",{}),
 ("M1-C-041","PaletteCardParser.template","POSTCONDITION","template and render disagree on blank lines between empty sections, so a freshly created card's file changes bytes on its first save; both forms re-parse identically, which is why nothing catches it","test_C041_templateAndRenderDisagreeOnBlankLinesBetweenEmptySections",{"_defect_candidate":True}),
 ("M1-C-042","PaletteCard.Sense","INVARIANT","Sense declaration order is [sight, sound, smell, touch, taste] and Kind is [location, character, motif, other]","test_C042_declarationOrderOfKindAndSenseIsPinned",{"_cross_ref":"pins M1-T-048 directly, which existing tests only asserted through a derived grouping"}),
 ("M1-C-043","PaletteCard","POSTCONDITION","a swatch that is not valid hex IS written to the file (uppercased) and is silently lost on the way back in — the round-trip law does not hold for it","test_C043_aSwatchThatIsNotValidHexIsSILENTLYLOSTOnRoundTrip",{"_defect_candidate":True}),
 ("M1-C-044","PaletteCard","POSTCONDITION","a newline in the title migrates the remainder into body on round-trip","test_C044_aNewlineInTheTitleMIGRATESTheRemainderIntoBody",{"_defect_candidate":True}),
 ("M1-C-045","PaletteCard","POSTCONDITION","a newline in a note truncates it at the newline on round-trip; the remainder is lost","test_C045_aNewlineInANoteTRUNCATESItAtTheNewline",{"_defect_candidate":True}),
 ("M1-C-046","PaletteCard","POSTCONDITION","a remote URL in imagePaths is mangled by relativize (the scheme's '//' collapses) and reads back as a single-slash relative path","test_C046_aRemoteURLInImagePathsIsMANGLEDByRelativizeThenReadBackWrong",{"_defect_candidate":True}),
 ("M1-C-047","PaletteCard","INVARIANT","a body spelling a KNOWN section heading loses that body on the first pass (claimed by section detection, any inline image harvested) and is stable from the second pass on","test_C047_aBodySpellingAKnownSectionHeadingLosesItsBodyOnTheFIRSTPassThenConverges",{"_cross_ref":"the residual the module's own doc comment documents"}),
 ("M1-C-048","PaletteCardRenderer.relativize","POSTCONDITION","a path EQUAL to the directory climbs out and comes back in ('research/palette' from 'research/palette' -> '../palette')","test_C048_aPathEQUALToTheDirectoryClimbsOutAndComesBackIn",{}),
 ("M1-C-049","PaletteCardRenderer.relativize","POSTCONDITION","an empty path produces a bare climb ('../../')","test_C049_anEmptyPathProducesABareClimb",{}),
 ("M1-C-050","PaletteCardRenderer.relativize","POSTCONDITION","an empty directory yields the './' form","test_C050_anEmptyDirectoryYieldsADotSlashForm",{}),
 ("M1-C-051","PaletteCardRenderer.relativize","POSTCONDITION","one '../' is emitted per uncommon directory component","test_C051_oneClimbIsEmittedPerUNCOMMONDirectoryComponent",{}),
 ("M1-C-052","PaletteCardRenderer.relativize","INVARIANT","a sibling directory sharing a textual prefix ('research/paletteX') is not confused for the directory itself","test_C052_aSiblingDirectoryWithACOMMONPREFIXIsNotConfusedForTheDirectory",{}),
]

RD = {  # reverse deps by scope, carried forward from Phase 1
 "TreeWalk.find":42, "TreeWalk.collect":36, "TreeWalk.first":8, "TreeWalk.contains":6,
 "TreeWalk.rewritePaths":3, "TreeWalk.mutate":3, "TreeWalk.collectIds":3,
 "TreeWalk.remove":2, "TreeWalk.leaves":2, "TreeWalk.idsByPath":3, "TreeWalk":105,
 "PaletteCardParser.parse":2, "PaletteCardParser.template":1,
 "PaletteCardRenderer.render":1, "PaletteCardRenderer.relativize":1,
 "PaletteCard.color(fromHex:)":8, "PaletteCard.Sense":5, "PaletteCard":3,
}
TRANS = {
 "PaletteCardParser.parse":11, "PaletteCardParser.template":4,
 "PaletteCardRenderer.render":6, "PaletteCardRenderer.relativize":6,
 "PaletteCard.color(fromHex:)":8, "PaletteCard.Sense":12, "PaletteCard":11,
}

FILE = {"M1":"PaletteCardCharacterization", "M2":"TreeWalkCharacterization"}

def build(rows):
    out = []
    for cid, scope, kind, stmt, ref, extra in rows:
        mod = cid[:2]
        nd = extra.pop("nd", False)
        claim = {
            "claim_id": cid, "scope": scope, "kind": kind, "statement": stmt,
            "source": {"type": "CHARACTERIZATION",
                       "ref": "NOT_PINNED (non-deterministic)" if nd else f"{FILE[mod]}.{ref}"},
            "warrant": "LOW", "intent": "UNKNOWN",
            "reverse_deps": {"direct": RD.get(scope, 0),
                             "transitive": TRANS.get(scope, RD.get(scope, 0))},
            "evidence": {"non_deterministic": True} if nd else {"property_test": None},
        }
        claim.update(extra)
        out.append(claim)
    return out

d = json.load(open(LEDGER))
d["claims"].extend(build(M2))
d["claims"].extend(build(M1))
c = d["claims"]
d["_meta"]["phase"] = 2
d["_meta"]["counts"] = {
    "M1_total": sum(1 for x in c if x["claim_id"].startswith("M1")),
    "M2_total": sum(1 for x in c if x["claim_id"].startswith("M2")),
    "existing_test": sum(1 for x in c if x["source"]["type"] == "EXISTING_TEST"),
    "characterization": sum(1 for x in c if x["source"]["type"] == "CHARACTERIZATION"),
    "characterization_pinned": sum(1 for x in c if x["source"]["type"] == "CHARACTERIZATION"
                                   and not x["evidence"].get("non_deterministic")),
    "characterization_not_pinned": sum(1 for x in c if x["evidence"].get("non_deterministic")),
    "defect_candidates": sum(1 for x in c if x.get("_defect_candidate")),
    "total": len(c),
}
json.dump(d, open(LEDGER, "w"), indent=2)

ids = [x["claim_id"] for x in c]
assert len(ids) == len(set(ids)), "duplicate claim ids: " + str([i for i in ids if ids.count(i) > 1])
print(json.dumps(d["_meta"]["counts"], indent=2))
print("scopes:", len(collections.Counter(x["scope"] for x in c)))
