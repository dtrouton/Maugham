#!/usr/bin/env python3
"""Close the M4-RW-002 loop: the first defect fixed under the reconciliation
register. Usage: python3 experiment/scripts/25-flip-m4-rw-002.py <fix-commit-sha>

The lifecycle this encodes (the pattern for every future fix):
  1. The FIX lands with a pinned production test, in its own commit.
  2. The CLAIM whose pinned behaviour changed is updated (here: M4-RW-002's
     reachability — the derive boundary itself did not change); a claim whose
     pinned test now describes the new behaviour gets its statement updated too.
  3. A NEW claim pins the new behaviour if the old claims did not cover it
     (here: M4-RW-032, the predecessor composition).
  4. The FILING flips VIOLATES -> COMPLIES, citing the fix commit, the ruling
     disposition that authorised the fix, and the pinned test.
  5. The _summary counts are recomputed, never hand-adjusted.
"""
import json
import sys

if len(sys.argv) != 2:
    sys.exit("usage: 25-flip-m4-rw-002.py <fix-commit-sha>")
FIX = sys.argv[1]

CLAIMS = "experiment/reconciliation/Rewind.claims.json"
FILINGS = "experiment/reconciliation/Rewind.filings.json"

claims = json.load(open(CLAIMS))
filings = json.load(open(FILINGS))

# -- 2. the reachability that made the old composition a live defect is gone --
c002 = next(c for c in claims if c["claim_id"] == "M4-RW-002")
assert "predecessor" not in c002["reachability"], "already flipped"
c002["reachability"] = (
    "LIVE — RewindWindow scrub positions; since the M4-RW-002 fix (" + FIX[:10] + ", 2026-08-08) "
    "HistoryPane's 'Rewind to before this…' posts the PREDECESSOR op, so the inclusive boundary "
    "composes with the label instead of contradicting it")

# -- 3. the new behaviour, pinned by a permanent production test ------------
assert not any(c["claim_id"] == "M4-RW-032" for c in claims)
claims.append({
    "claim_id": "M4-RW-032",
    "scope": "HistoryPane.predecessorIndex + the 'Rewind to before this…' deep-link",
    "kind": "POSTCONDITION",
    "statement": ("'Rewind to before this…' resolves to the row op's immediate predecessor in the "
                  "opId-ordered log, so the opened cursor derives state EXCLUDING the selected op's "
                  "effect; the first op (no predecessor) offers no deep-link"),
    "source": {
        "type": "CHARACTERIZATION",
        "ref": ("MaughamTests/Views/HistoryPaneRewindTargetTests"
                ".test_rewindBeforeThis_excludesTheTargetOpsOwnEffect — a PERMANENT production "
                "test, not an experiment copy: the fix's own regression net")
    },
    "warrant": "HIGH",
    "intent": "INTENTIONAL — ruled (RULING-22 disposition, Denver 2026-08-08)",
    "reachability": "LIVE — every History row with a manuscript-mutating op and a predecessor",
    "evidence": {"property_test": None},
    "out_of_module_note": ("Lives in Maugham/Views, not the three rewind files — added here because "
                           "it is the composition claim that makes M4-RW-002's flipped filing honest")
})

# -- 4. flip the filing -----------------------------------------------------
f002 = next(f for f in filings if f.get("claim_id") == "M4-RW-002")
assert f002["outcome"] == "VIOLATES"
f002["outcome"] = "COMPLIES"
f002["why_in_scope"] = (
    "RULING-22's 'controls do what they say' reaches the pair — the HistoryPane label and this "
    "inclusive boundary. As of the fix the pair AGREES: the label promises 'before this' and the "
    "deep-link posts the predecessor op, so the inclusive derive lands exactly where the label "
    "says. The boundary itself was never the defect (M4-RW-005: the method matches its doc); the "
    "composition was, and the composition is now pinned by M4-RW-032.")
f002["fix"] = {
    "commit": FIX,
    "date": "2026-08-08",
    "authorised_by": "RULING-22 disposition_M4_RW_002_RULED — Denver: fix the behaviour, not the label",
    "pinned_by": "MaughamTests/Views/HistoryPaneRewindTargetTests (production, runs in the Mac suite)",
    "note": "first defect taken through the claim→fix→re-verify loop"}

filings.insert(-1, {
    "claim_id": "M4-RW-032",
    "outcome": "COMPLIES",
    "ruling": "RULING-22",
    "clause_that_reaches_it": "Controls are unambiguous and DO WHAT THEY SAY.",
    "why_in_scope": ("The control's label names a state ('before this') and the writer forms their "
                     "expectation from it; the deep-link now opens the rewind at exactly that "
                     "state. Same clause that convicted the old composition."),
    "intent_expressed_when": "contemporaneous — the writer clicked a button naming the moment they wanted",
    "call_path": ("HistoryPane row → 'Rewind to before this…' → predecessorIndex → .maughamOpenRewind "
                  "with the predecessor's opId → RewindModifier .atOp → RewindWindow → restoreToOp"),
    "violation_or_enhancement": "neither"})

# -- 5. recompute the summary, never hand-adjust ----------------------------
rows = [f for f in filings if "claim_id" in f]
summary = next(f for f in filings if "_summary" in f)["_summary"]
by_ruling = {}
for f in rows:
    if f["outcome"] in ("COMPLIES", "VIOLATES"):
        by_ruling.setdefault(f["ruling"], []).append(f["claim_id"])
reached = sum(1 for f in rows if f["outcome"] in ("COMPLIES", "VIOLATES"))
complies = sum(1 for f in rows if f["outcome"] == "COMPLIES")
violates = sum(1 for f in rows if f["outcome"] == "VIOLATES")
summary.update({
    "reached": reached, "complies": complies, "violates": violates,
    "no_ruling": sum(1 for f in rows if f["outcome"] == "NO_RULING_REACHES"),
    "total": len(rows),
    "coverage": f"{round(100 * reached / len(rows))}%",
    "by_ruling": {k: sorted(v) for k, v in sorted(by_ruling.items())},
    "distinct_defects": ("6 violations over 5 distinct defects — M4-RW-003 and M4-RW-008 are two "
                         "pinned faces of one silent no-op and are counted once in the register; "
                         "M4-RW-002 fixed 2026-08-08 (" + FIX[:10] + ") and flipped to COMPLIES"),
})

json.dump(claims, open(CLAIMS, "w"), indent=1, ensure_ascii=False)
json.dump(filings, open(FILINGS, "w"), indent=1, ensure_ascii=False)
print(f"flipped M4-RW-002, added M4-RW-032; summary: {reached} reached, "
      f"{complies} complies / {violates} violates over {len(rows)} claims")
