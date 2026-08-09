#!/usr/bin/env python3
"""Phase 5: compute the agreement map, silence ratios, contradiction rate and
the ratchet-safety table from the ledger."""
import json, collections

d = json.load(open("experiment/01-claims-ledger.json"))
claims = d["claims"]
by_id = {c["claim_id"]: c for c in claims}

def mod(c): return c["claim_id"][:2]
def held(c):
    pt = c["evidence"].get("property_test")
    if pt is None: return None
    if isinstance(pt, list): return all(p["held"] for p in pt)
    return pt["held"]

# ---------------------------------------------------------------- regions
# C: an EXISTING_TEST claim with INDEPENDENT observational confirmation —
#    a held property, or an explicit characterization cross-reference.
xrefd = set()
for c in claims:
    if c.get("_cross_ref") and "M" in c.get("_cross_ref", ""):
        for tok in c["_cross_ref"].replace(",", " ").split():
            t = tok.strip(".,;")
            if t in by_id: xrefd.add(t)

C, D, uncorroborated = [], [], []
for c in claims:
    if c["source"]["type"] == "EXISTING_TEST":
        if held(c) is True or c["claim_id"] in xrefd: C.append(c)
        elif held(c) is False: pass          # contradicted, counted separately
        else: uncorroborated.append(c)
    else:
        # characterization with no covering existing test = the silent surface
        if not c.get("_cross_ref"): D.append(c)

contradicted = [c for c in claims if c["warrant"] == "CONTRADICTED"]
nd = [c for c in claims if c["evidence"].get("non_deterministic")]

# ---------------------------------------------------------------- intent clauses
# (clause, module, arm, verdict, supporting observed claims / why not)
CLAUSES = [
 ("M1-A-01","M1","A","SUPPORTED","M1-T-032 + P01 (20k)"),
 ("M1-A-02","M1","A","SUPPORTED","M1-C-047 + P02 (20k)"),
 ("M1-A-03","M1","A","SUPPORTED","M1-T-036, M1-C-039"),
 ("M1-A-04","M1","A","SUPPORTED_NARROWED","M1-T-022..026 + P05; narrowed by M1-C-023"),
 ("M1-A-05","M1","A","SUPPORTED","M1-T-017"),
 ("M1-A-06","M1","A","SUPPORTED_HALF","M1-T-019, M1-C-034 on parse; M1-C-046 shows render violates it"),
 ("M1-A-07","M1","A","SUPPORTED","M1-T-039 + P04 (20k)"),
 ("M1-A-08","M1","A","SUPPORTED","M1-T-010, M1-T-012"),
 ("M1-A-09","M1","A","SUPPORTED","M1-T-041/042 + P08 (20k)"),
 ("M1-A-10","M1","A","SUPPORTED","M1-T-044"),
 ("M1-A-11","M1","A","SUPPORTED_HOLED","M1-T-004 + P06 held; P03 shattered the validator's language"),
 ("M1-A-12","M1","A","SUPPORTED","M1-T-034/036, M1-C-040"),
 ("M1-A-13","M1","A","SUPPORTED","M1-C-038, M1-C-039"),
 ("M1-A-14","M1","A","SUPPORTED","M1-T-007/045/046 + P07 (20k)"),
 ("M1-A-15","M1","A","REGION_A_ARCHITECTURAL","no behavioural signature; verifiable by grep, not by test"),
 ("M1-A-16","M1","A","SUPPORTED","M1-T-047"),
 ("M1-A-17","M1","A","REGION_A_ARCHITECTURAL","cross-surface placement; verifiable by build graph"),
 ("M1-A-18","M1","A","SUPPORTED","M1-C-016"),
 ("M1-A-19","M1","A","SUPPORTED","M1-T-002/009, M1-C-010"),
 ("M1-A-20","M1","A","REGION_A_HALLUCINATION","FALSIFIED by M1-C-043: an invalid swatch IS written to the file"),
 ("M1-A-21","M1","A","SUPPORTED","all 52 M1 characterization tests; parse is non-throwing and total"),
 ("M1-A-22","M1","A","SUPPORTED","M1-T-001"),
 ("M1-B-01","M1","B","SUPPORTED","M1-T-037"),
 ("M1-B-02","M1","B","SUPPORTED","M1-T-040"),
 ("M1-B-03","M1","B","SUPPORTED","M1-T-013"),
 ("M1-B-04","M1","B","SUPPORTED","M1-T-048, M1-C-042"),
 ("M1-B-05","M1","B","REGION_A_PROVENANCE","historical cause; not falsifiable by present behaviour"),
 ("M1-B-06","M1","B","SUPPORTED","M1-T-022..026 + P05"),
 ("M1-B-07","M1","B","SUPPORTED","M1-C-041 is exactly the defect this granularity choice hides"),
 ("M2-A-01","M2","A","REGION_A_ARCHITECTURAL","no behavioural signature; verifiable by grep"),
 ("M2-A-02","M2","A","REGION_A_ARCHITECTURAL","cross-surface contract; verifiable by build graph"),
 ("M2-A-03","M2","A","SUPPORTED","M2-T-005/012 + P11, P15 (40k)"),
 ("M2-A-04","M2","A","SUPPORTED","M2-T-009, M2-C-022"),
 ("M2-A-05","M2","A","REGION_A_DESIGN_DIRECTIVE","a 'do not move this decision' rule; no behavioural signature"),
 ("M2-A-06","M2","A","SUPPORTED_HOLED","M2-T-023..026 held on the stated rule; P13 shattered the semantic rule"),
 ("M2-A-07","M2","A","SUPPORTED","M2-T-025"),
 ("M2-A-08","M2","A","SUPPORTED","M2-C-026"),
 ("M2-A-09","M2","A","SUPPORTED","M2-T-027"),
 ("M2-A-10","M2","A","SUPPORTED","M2-C-031/032"),
 ("M2-A-11","M2","A","SUPPORTED","M2-T-018 + P12 (20k)"),
 ("M2-A-12","M2","A","SUPPORTED","M2-C-015"),
 ("M2-A-13","M2","A","REGION_A_ARCHITECTURAL","API-shape rule; enforced by the compiler, not by behaviour"),
 ("M2-A-14","M2","A","REGION_A_ARCHITECTURAL","API-completeness rule; no behavioural signature"),
 ("M2-A-15","M2","A","REGION_A_ARCHITECTURAL","type-level; enforced by the compiler"),
 ("M2-A-16","M2","A","REGION_A_HALLUCINATION","FALSIFIED as a requirement by P14 (20k): every walker contract holds without it"),
 ("M2-A-17","M2","A","SUPPORTED","M2-C-001..009"),
 ("M2-A-18","M2","A","SUPPORTED","M2-C-018 + P10 (20k)"),
 ("M2-A-19","M2","A","REGION_A_OUT_OF_SCOPE","a claim about ProjectStore, not about TreeWalk; unfalsifiable from here"),
 ("M2-A-20","M2","A","REGION_A_HALLUCINATION","a style preference dressed as intent; not falsifiable by any behaviour"),
 ("M2-B-01","M2","B","REGION_A_ARCHITECTURAL","a fact about the TEST SUITE's dependency shape; verifiable by census"),
 ("M2-B-02","M2","B","REGION_A_PROVENANCE","historical derivation; not falsifiable by present behaviour"),
 ("M2-B-03","M2","B","SUPPORTED","M2-T-012 + P15 (20k)"),
 ("M2-B-04","M2","B","SUPPORTED","M2-T-014 + P11 (20k)"),
 ("M2-B-05","M2","B","SUPPORTED","M2-T-024"),
 ("M2-B-06","M2","B","SUPPORTED","M2-C-012"),
]

regionA = [c for c in CLAUSES if c[3].startswith("REGION_A")]

# ---------------------------------------------------------------- metrics
out = {"per_module": {}}
for m in ("M1", "M2"):
    mc  = [c for c in claims if mod(c) == m]
    mD  = [c for c in D if mod(c) == m]
    mC  = [c for c in C if mod(c) == m]
    mcl = [c for c in CLAUSES if c[1] == m]
    out["per_module"][m] = {
        "claims_total": len(mc),
        "existing_test": sum(1 for c in mc if c["source"]["type"] == "EXISTING_TEST"),
        "characterization": sum(1 for c in mc if c["source"]["type"] == "CHARACTERIZATION"),
        "region_C": len(mC),
        "region_D": len(mD),
        "silence_ratio_D_over_all_observed": round(len(mD) / len(mc), 3),
        "silence_ratio_D_over_characterization":
            round(len(mD) / max(1, sum(1 for c in mc if c["source"]["type"] == "CHARACTERIZATION")), 3),
        "intent_clauses": len(mcl),
        "region_A": sum(1 for c in mcl if c[3].startswith("REGION_A")),
        "contradicted": sum(1 for c in mc if c["warrant"] == "CONTRADICTED"),
    }

out["totals"] = {
    "claims": len(claims),
    "region_C": len(C),
    "region_D": len(D),
    "uncorroborated_existing_test_claims": len(uncorroborated),
    "non_deterministic": len(nd),
    "silence_ratio_overall": round(len(D) / len(claims), 3),
    "intent_clauses": len(CLAUSES),
    "region_A": len(regionA),
    "region_A_breakdown": dict(collections.Counter(c[3] for c in regionA)),
    "claims_hammered": sum(1 for c in claims if c["evidence"].get("property_test")),
    "claims_contradicted": len(contradicted),
    "contradiction_rate_of_hammered":
        round(len(contradicted) / sum(1 for c in claims if c["evidence"].get("property_test")), 3),
    "clause_contradiction_rate": round(2 / len(CLAUSES), 3),
}

# ---------------------------------------------------------------- ratchet safety
ranked = sorted(claims, key=lambda c: (-c.get("reverse_deps", {}).get("direct", 0), c["claim_id"]))
top = []
for c in ranked[:10]:
    h = held(c)
    top.append({
        "claim_id": c["claim_id"], "scope": c["scope"],
        "reverse_deps": c["reverse_deps"]["direct"],
        "source": c["source"]["type"], "warrant": c["warrant"],
        "hammered": h is not None, "held": h,
        "statement": c["statement"],
        "FLAG": ("SHATTERED" if h is False else ("UNHAMMERED" if h is None else "")),
    })
out["ratchet_top10"] = top
out["ratchet_flagged"] = [t["claim_id"] for t in top if t["FLAG"]]

d["_meta"]["phase"] = 5
d["_meta"]["agreement_map"] = out
d["_meta"]["intent_clause_verdicts"] = [
    {"clause": c[0], "module": c[1], "arm": c[2], "verdict": c[3], "evidence": c[4]} for c in CLAUSES]
json.dump(d, open("experiment/01-claims-ledger.json", "w"), indent=2)
print(json.dumps(out, indent=2))
