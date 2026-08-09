#!/usr/bin/env python3
"""Close the M4-RW-019 loop — the second defect fixed under the register, and
the first fixed by a NEW ruling (RULING-25, Denver 2026-08-08) rather than a
disposition on an existing one.
Usage: python3 register/scripts/26-flip-m4-rw-019.py <fix-commit-sha>

Same lifecycle as 25-flip-m4-rw-002.py: fix + pinned production test in its
own commit -> update the claim whose pinned behaviour changed (here the claim
STATEMENT itself changes — the old statement pinned the asymmetry, which no
longer exists; its characterisation test copy was rewritten and re-verified)
-> add claims for behaviour the fix newly guarantees -> flip the filing citing
commit + ruling -> recompute _summary, never hand-adjust.
"""
import json
import sys

if len(sys.argv) != 2:
    sys.exit("usage: 26-flip-m4-rw-019.py <fix-commit-sha>")
FIX = sys.argv[1]

CLAIMS = "register/reconciliation/Rewind.claims.json"
FILINGS = "register/reconciliation/Rewind.filings.json"
claims = json.load(open(CLAIMS))
filings = json.load(open(FILINGS))

# -- the claim whose pinned behaviour changed ------------------------------
c019 = next(c for c in claims if c["claim_id"] == "M4-RW-019")
assert "leaves a sweep-archived ANNOTATION archived" in c019["statement"], "already flipped"
c019["statement"] = (
    "rewinding FORWARD past the moment a paragraph was created brings the paragraph, the pane task "
    "AND the sweep-archived annotation back: the restore appends a `.rewind`-stamped "
    "`.annotationReopen` for every annotation whose latest lifecycle op is a rewind-stamped archive "
    "from an open status and whose anchor paragraph exists in the target state (RULING-25)")
c019["kind"] = "INVARIANT"
c019["intent"] = "INTENTIONAL — ruled (RULING-25, Denver 2026-08-08)"
c019["source"]["ref"] = (
    "RewindCharacterization.test_forwardRewind_returnsTextTasks_andReopensWhatTheSweepArchived "
    "(copy, re-verified in place 2026-08-08) + production twin "
    "MaughamTests/Integration/RewindTravelReopenTests.test_forwardRewind_reopensTheCommentTheRewindArchived")
c019["fix_history"] = (
    "Pinned the ASYMMETRY (comment stayed archived, permanently and silently) until fixed at "
    + FIX[:10] + ", 2026-08-08, under RULING-25")

# -- behaviour the fix newly guarantees ------------------------------------
for cid in ("M4-RW-033", "M4-RW-034"):
    assert not any(c["claim_id"] == cid for c in claims)
claims += [{
    "claim_id": "M4-RW-033",
    "scope": "Document.restoreToOp — the return journey's scope guard",
    "kind": "INVARIANT",
    "statement": ("an annotation the WRITER archived (no synthesisSource on the archive op) stays "
                  "archived across a full backward-and-forward travel; only Maugham's own "
                  "rewind-stamped archives reopen"),
    "source": {"type": "CHARACTERIZATION",
               "ref": "MaughamTests/Integration/RewindTravelReopenTests.test_writersOwnArchive_staysArchivedAcrossTravel"},
    "warrant": "HIGH",
    "intent": "INTENTIONAL — RULING-25's scope clause verbatim",
    "reachability": "LIVE",
    "evidence": {"property_test": None},
}, {
    "claim_id": "M4-RW-034",
    "scope": "Document.restoreToOpUndoable × the return journey",
    "kind": "POSTCONDITION",
    "statement": ("undoing a forward travel re-archives what the travel reopened — via the "
                  "compensating restore's own step-7 sweep, no bespoke undo work; redo re-runs the "
                  "forward restore and reopens again. The return journey is gated to `.rewind` "
                  "restores so the `.undoRewind` compensating restore never double-acts"),
    "source": {"type": "CHARACTERIZATION",
               "ref": "MaughamTests/Integration/RewindTravelReopenTests.test_undoOfTheForwardRewind_reArchivesWhatItReopened"},
    "warrant": "HIGH",
    "intent": "INTENTIONAL",
    "reachability": "LIVE — ⌘Z after a forward Restore",
    "evidence": {"property_test": None},
}]

# -- flip the filing, file the new claims ----------------------------------
f019 = next(f for f in filings if f.get("claim_id") == "M4-RW-019")
assert f019["outcome"] == "VIOLATES"
f019.update({
    "outcome": "COMPLIES",
    "ruling": "RULING-25",
    "clause_that_reaches_it": ("Anything Maugham closes on the writer's behalf when they travel "
                               "through their history is reopened when they travel back."),
    "why_in_scope": ("The sweep's archive is Maugham closing an annotation on its own initiative "
                     "during history travel — RULING-25's stated scope verbatim. The old filing "
                     "convicted under RULING-8 (the task answered yes, the comment answered no); "
                     "R25 is now the more specific ruling and the behaviour matches it. The "
                     "accepted-then-archived case deliberately does NOT reopen (its pre-archive "
                     "status was not open; its honest forward status would be .accepted) — recorded "
                     "as a residual, unruled."),
    "fix": {
        "commit": FIX,
        "date": "2026-08-08",
        "authorised_by": "RULING-25 — Denver 2026-08-08, GAP-R1 ruled as symmetric travel",
        "pinned_by": ("MaughamTests/Integration/RewindTravelReopenTests (production) + the "
                      "rewritten characterisation copy"),
        "note": "second defect through the claim→fix→re-verify loop; first fixed by a new ruling"},
})
summary_idx = next(i for i, f in enumerate(filings) if "_summary" in f)
filings[summary_idx:summary_idx] = [{
    "claim_id": "M4-RW-033",
    "outcome": "COMPLIES",
    "ruling": "RULING-25",
    "clause_that_reaches_it": ("The writer's own archive/resolve actions are their intent "
                               "(RULING-23's shape) and are untouched by this ruling."),
    "why_in_scope": ("The scope clause names this case: a writer-made archive is intent to honour, "
                     "not damage to repair. The discriminator is the archive op's synthesisSource — "
                     "nil for the writer, .rewind for the sweep."),
    "intent_expressed_when": "earlier — the writer archived it before travelling",
    "call_path": "annotations pane → Archive → travel back and forward through the rewind modal",
    "violation_or_enhancement": "neither",
}, {
    "claim_id": "M4-RW-034",
    "outcome": "COMPLIES",
    "ruling": "RULING-25",
    "clause_that_reaches_it": ("Anything Maugham closes on the writer's behalf when they travel "
                               "through their history is reopened when they travel back."),
    "why_in_scope": ("Undo of a forward travel IS a backward travel — the clause applies in both "
                     "directions, and the sweep re-closing what the forward leg reopened is the "
                     "same symmetry run in reverse."),
    "intent_expressed_when": "contemporaneous — ⌘Z immediately after the Restore",
    "call_path": "rewind modal → Restore (forward) → ⌘Z",
    "violation_or_enhancement": "neither",
}]

# -- recompute, never hand-adjust ------------------------------------------
rows = [f for f in filings if "claim_id" in f]
summary = next(f for f in filings if "_summary" in f)["_summary"]
by_ruling = {}
for f in rows:
    if f["outcome"] in ("COMPLIES", "VIOLATES"):
        by_ruling.setdefault(f["ruling"], []).append(f["claim_id"])
reached = sum(1 for f in rows if f["outcome"] in ("COMPLIES", "VIOLATES"))
summary.update({
    "reached": reached,
    "complies": sum(1 for f in rows if f["outcome"] == "COMPLIES"),
    "violates": sum(1 for f in rows if f["outcome"] == "VIOLATES"),
    "no_ruling": sum(1 for f in rows if f["outcome"] == "NO_RULING_REACHES"),
    "total": len(rows),
    "coverage": f"{round(100 * reached / len(rows))}%",
    "by_ruling": {k: sorted(v) for k, v in sorted(by_ruling.items())},
    "distinct_defects": ("5 violations over 4 distinct defects — M4-RW-003 and M4-RW-008 are two "
                         "pinned faces of one silent no-op, counted once. Fixed and flipped: "
                         "M4-RW-002 (2026-08-08), M4-RW-019 (" + FIX[:10] + ", 2026-08-08)"),
})

json.dump(claims, open(CLAIMS, "w"), indent=1, ensure_ascii=False)
json.dump(filings, open(FILINGS, "w"), indent=1, ensure_ascii=False)
print(f"flipped M4-RW-019 to COMPLIES under RULING-25, added M4-RW-033/034; "
      f"summary: {reached} reached, {summary['complies']} complies / "
      f"{summary['violates']} violates over {len(rows)} claims")
