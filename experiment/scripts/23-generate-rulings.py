#!/usr/bin/env python3
"""Generate experiment/RULINGS.md from the ledger. THE LEDGER IS THE SOURCE OF TRUTH.

Run this after ANY change to `_meta.rulings`. It has already drifted twice:
  - the first extraction emitted only family/statement/basis for ROOT rulings, silently
    dropping RULING-19's corollary — the clause that REVERSES that ruling;
  - RULING-24 was added to the ledger and never re-derived here at all.

Both were caught by a downstream reader noticing the file did not contain something it
needed. Neither was caught here. So: emit EVERY string field, for EVERY ruling, and let
the file be verbose rather than lossy. Verification at the bottom fails loudly.
"""
import json, sys

L = "experiment/01-claims-ledger.json"
OUT = "experiment/RULINGS.md"
d = json.load(open(L))
R = d["_meta"]["rulings"]

ROOTS = [k for k in R if R[k].get("family", "").startswith("ROOT")] + ["RULING-9", "RULING-19"]
ROOTS = sorted(set(ROOTS), key=lambda x: int(x.split("-")[1]))
SKIP = {"family", "statement", "verdict", "ruled_by", "date", "kind"}

def num(k): return int(k.split("-")[1])

def block(k):
    r = R[k]
    out = [f"### {k} — {r.get('family','')}  `{r.get('verdict','—')}`", "", f"> {r['statement']}", ""]
    for f, v in r.items():
        if f in SKIP or not v:
            continue
        if isinstance(v, str):
            out.append(f"*{f.replace('_',' ')}:* {v}")
        elif isinstance(v, list):
            out.append(f"*{f.replace('_',' ')}:*")
            out += [f"  - {x}" for x in v]
        elif isinstance(v, dict):
            out.append(f"*{f.replace('_',' ')}:*")
            out += [f"  - **{kk}** — {vv}" for kk, vv in v.items()]
        out.append("")
    return out

L_ = ["# Maugham — the ruling set", "",
 "**GENERATED from `experiment/01-claims-ledger.json` (`_meta.rulings`). Do not hand-edit.**",
 "Regenerate with `python3 experiment/scripts/23-generate-rulings.py` after any ruling change.",
 "", f"{len([k for k in R if k.startswith('RULING')])} rulings, "
 f"{len([k for k in R if k.startswith('PRINCIPLE')])} principles.", "",
 "Every ruling carries its **BASIS** — the reason it was made. The basis is load-bearing:",
 "applying a ruling to a new case means re-checking the basis, not pattern-matching the",
 "conclusion. Four rulings here were originally filed with a correct verdict and a wrong basis,",
 "and two rested on a belief about the code that did not hold.", "",
 "## Roots — general. A root cited beside a sub that already reaches the case is decoration.", ""]
for k in ROOTS:
    L_ += block(k)
L_ += ["## Sub-rulings — prefer these. Name the MOST SPECIFIC that reaches a case.", ""]
for k in sorted([k for k in R if k.startswith("RULING") and k not in ROOTS], key=num):
    L_ += block(k)
L_ += ["## Principles — how to judge, not what to decide", ""]
for k in sorted([k for k in R if k.startswith("PRINCIPLE")], key=num):
    L_ += [f"### {k}", "", f"> {R[k]['statement']}", ""]
    for f, v in R[k].items():
        if f not in ("statement", "kind") and isinstance(v, str) and v:
            L_.append(f"*{f.replace('_',' ')}:* {v}")
    L_.append("")

open(OUT, "w").write("\n".join(L_))

# verification — fail loudly rather than drift again
txt = open(OUT).read()
missing = [k for k in R if f"### {k}" not in txt]
if missing:
    sys.exit(f"FAILED: {len(missing)} entries missing from {OUT}: {missing}")
lost = []
for k, r in R.items():
    for f, v in r.items():
        if f in SKIP or not isinstance(v, str) or not v:
            continue
        if v[:60] not in txt:
            lost.append(f"{k}.{f}")
if lost:
    sys.exit(f"FAILED: {len(lost)} string clauses dropped: {lost[:8]}")
print(f"wrote {OUT}: {len([k for k in R if k.startswith('RULING')])} rulings, "
      f"{len([k for k in R if k.startswith('PRINCIPLE')])} principles, "
      f"{len(txt.splitlines())} lines")
print("verification: every entry present, no string clause dropped")
