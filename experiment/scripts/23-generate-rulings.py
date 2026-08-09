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
enf = d["_meta"].get("enforcement", {})
if enf:
    L_ += ["## The enforcement gradient — how each ruling is held", ""]
    L_ += ["prose → test → tripwire → type → model. A prose-only ruling with LIVE reach is a",
           "promotion candidate. (Source: `_meta.enforcement`; metadata, outside the ruling hashes.)", ""]
    for k in sorted([k for k in enf if k.startswith("RULING")], key=lambda x: int(x.split("-")[1])):
        e = enf[k]
        L_.append(f"- **{k}** `{e['mechanism']}` — {e['note']}")
    L_.append("")

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

# Reference check: every ruling/principle id cited by the process docs must
# exist in the ledger. The id-level cousin of the phantom-clause failure —
# RECONCILE.md discipline 5 cited a RULING-8 clause nobody had written, and
# nothing caught it until a reconciliation run spent a filing on it.
import re
dangling = []
for doc in ("experiment/RECONCILE.md", "experiment/reconciliation/PROTOCOL.md"):
    try:
        body = open(doc).read()
    except FileNotFoundError:
        continue
    for ref in set(re.findall(r"(?:RULING|PRINCIPLE)-\d+", body)):
        if ref not in R:
            dangling.append(f"{doc} cites {ref}")
if dangling:
    sys.exit(f"FAILED: {len(dangling)} dangling ruling references: {dangling}")

# Amendment detection: a ruling's TEXT changing invalidates the judgments made
# against the old text, and nothing else in the system notices. R8 gained its
# sameness clause on 2026-08-08 and every earlier filing citing R8 had weighed
# an escape clause that did not exist. So: ruling-text hashes are recorded;
# a change fails this script, listing every filing that cites the amended
# ruling, until re-run with --amend RULING-n — which updates the baseline and
# prints the citing filings as the re-check queue.
import glob
import hashlib
HASHES = "experiment/reconciliation/ruling-hashes.json"
amend_ok = set()
for i, arg in enumerate(sys.argv):
    if arg == "--amend" and i + 1 < len(sys.argv):
        amend_ok.update(sys.argv[i + 1].split(","))

current = {k: hashlib.sha256(
    json.dumps(r, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
    for k, r in R.items()}

def citing_filings(ruling):
    hits = []
    for path in sorted(glob.glob("experiment/reconciliation/*.filings.json")):
        for f in json.load(open(path)):
            if isinstance(f, dict) and f.get("ruling") == ruling:
                hits.append(f"{path.split('/')[-1]}:{f['claim_id']}")
    return hits

try:
    baseline = json.load(open(HASHES))
except FileNotFoundError:
    baseline = None

if baseline is None:
    with open(HASHES, "w") as fh:
        json.dump(current, fh, indent=1, sort_keys=True)
        fh.write("\n")
    print(f"baseline ruling hashes written to {HASHES}")
else:
    changed = [k for k in current
               if k in baseline and baseline[k] != current[k]]
    unacknowledged = [k for k in changed if k not in amend_ok]
    if unacknowledged:
        for k in unacknowledged:
            cites = citing_filings(k)
            print(f"AMENDED without acknowledgment: {k} — "
                  f"{len(cites)} filing(s) cite it: {cites}")
        sys.exit("FAILED: ruling text changed. Re-run with "
                 f"--amend {','.join(unacknowledged)} and re-check the filings above.")
    if changed:
        for k in changed:
            cites = citing_filings(k)
            print(f"AMENDED (acknowledged): {k} — re-check queue "
                  f"({len(cites)} filings): {cites}")
    with open(HASHES, "w") as fh:
        json.dump(current, fh, indent=1, sort_keys=True)
        fh.write("\n")

print(f"wrote {OUT}: {len([k for k in R if k.startswith('RULING')])} rulings, "
      f"{len([k for k in R if k.startswith('PRINCIPLE')])} principles, "
      f"{len(txt.splitlines())} lines")
print("verification: every entry present, no string clause dropped, no dangling doc references")
