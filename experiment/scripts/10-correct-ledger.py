#!/usr/bin/env python3
"""Phase 10: correct the two false claims the blind implementer found, and add
the three claims the regeneration produced. Records HOW each was found."""
import json

LEDGER = "experiment/01-claims-ledger.json"
d = json.load(open(LEDGER))
by_id = {c["claim_id"]: c for c in d["claims"]}

# --- corrections ------------------------------------------------------------
c = by_id["M2-C-024"]
c["_superseded_statement"] = c["statement"]
c["statement"] = ("an empty oldPrefix rewrites every ABSOLUTE path (the descendant arm reads "
                  "\"\" + \"/\") and every empty path, but not relative paths")
c["warrant"] = "CORRECTED"
c["source"]["ref"] = "TreeWalkCharacterization.test_C024a_anEmptyOldPrefixALSORewritesEveryABSOLUTEPath"
c["_correction"] = {
    "found_by": "PHASE_10_REGENERATION — blind implementer reading the ledger against itself",
    "found_by_execution": False,
    "note": ("The original statement said 'rewrites ONLY empty paths'. My Phase 2 probe used the "
             "paths \"x/y\" and \"\" — neither absolute — so the characterization test confirmed my "
             "own wording instead of testing it. A closed loop: claim written from a probe, then "
             "checked with the same probe."),
}

c = by_id["M2-C-027"]
c["_superseded_statement"] = c["statement"]
c["statement"] = ("a trailing slash on oldPrefix kills only the DESCENDANT arm of the rewrite; a path "
                  "exactly equal to oldPrefix still matches the exact-match arm and is rewritten")
c["warrant"] = "CORRECTED"
c["source"]["ref"] = "TreeWalkCharacterization.test_C027a_aTrailingSlashStillRewritesAPathEqualToThePrefixItself"
c["_correction"] = {
    "found_by": "PHASE_10_REGENERATION — blind implementer reading the ledger against itself",
    "found_by_execution": False,
    "note": ("The original statement said the trailing slash made the WHOLE rewrite a no-op. My probe "
             "used path \"p/q\" and never path \"p/\". The implementer also offered a diagnosis I had "
             "not reached: the claim may be a stale observation of the pre-unification store-local "
             "code, which per M2-B-05 had no exact-match arm at all."),
}

# --- new claim from the regeneration ---------------------------------------
d["claims"].append({
    "claim_id": "M2-C-037",
    "scope": "TreeWalk.mutate / TreeWalk.remove",
    "kind": "PRECONDITION",
    "statement": ("TreeNode has no AnyObject bound, so a CLASS may conform — and for a class conformer "
                  "mutate and remove write through to the caller's forest, silently violating M2-A-11, "
                  "M2-T-018 and property P12. Latent only because StructureItem and ResearchItem are structs"),
    "source": {"type": "CHARACTERIZATION",
               "ref": "TreeWalkCharacterization.test_C037_withACLASSConformer_mutateAndRemoveDISTURBTheInputForest"},
    "warrant": "LOW", "intent": "UNKNOWN",
    "reverse_deps": {"direct": 5, "transitive": 105},
    "evidence": {"property_test": None},
    "_defect_candidate": True,
    "_found_by": {
        "phase": 10, "method": "blind implementer reasoning about type constraints vs claims",
        "found_by_execution": False,
        "note": ("P12 ran 20,000 cases and could not find this: its generator only ever produced "
                 "struct conformers. The hazard is in the TYPE SYSTEM, not the value space, so no "
                 "amount of value-space sampling reaches it."),
    },
})

# --- metrics ---------------------------------------------------------------
claims = d["claims"]
d["_meta"]["phase"] = 10
d["_meta"]["regeneration"] = {
    "module": "M2 MaughamCore.TreeNode / TreeWalk",
    "brief": "experiment/08-regeneration-brief.md",
    "brief_contents": {"claims": 63, "intent_clauses": 26, "public_signatures": True,
                       "implementation": False, "doc_comments": False, "tests": False,
                       "commit_messages": False},
    "results": {
        "compiled": True,
        "maughamcore_package": {"tests": 453, "failures": 0},
        "mac_scheme":  {"tests": 3856, "failures": 3, "control_failures": 3, "regressions": 0},
        "phone_scheme": {"tests": 221, "failures": 0, "regressions": 0},
        "behavioural_diff_vs_original": "none — identical function for function, comments stripped",
        "implementation_diff": ("regenerated threads an inout accumulator where the original "
                                "concatenates arrays per recursion level: strictly fewer allocations"),
    },
    "defects_found_by_regeneration": ["M2-C-024 (false claim)", "M2-C-027 (false claim)",
                                      "M2-C-037 (latent defect in production code)"],
    "defects_found_by_execution_that_regeneration_missed": ["M1-C-024 CRLF", "M1-C-003 hex '+'",
                                                            "M2-C-027 trailing-slash behaviour (P13)"],
    "contradictions_the_implementer_found_in_the_artifact": 8,
    "predictions_scored": {"correct": 3, "wrong": 4, "see": "experiment/09-regeneration-predictions.md"},
}
d["_meta"]["counts"]["total"] = len(claims)
d["_meta"]["counts"]["corrected_by_regeneration"] = 2

json.dump(d, open(LEDGER, "w"), indent=2)
print(f"ledger now {len(claims)} claims; 2 corrected, 1 added")
print("corrected:", [c["claim_id"] for c in claims if c["warrant"] == "CORRECTED"])
