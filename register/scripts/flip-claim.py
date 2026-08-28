#!/usr/bin/env python3
"""The register's one flip tool — replaces the per-fix scripts (25-*, 26-*,
kept as history of the first two loops).

The fix-loop lifecycle it serves:
  1. The FIX lands with a pinned production test, in its own commit.
  2. Claim edits (statement/reachability/new claims) are made in the module's
     claims JSON by hand or by the caller — they are judgment, not mechanics.
  3. THIS TOOL flips the filing, stamps fix provenance, and recomputes the
     summary. The summary is never hand-adjusted.
  4. On a REBASE, commit hashes in filings dangle — re-point with `repoint`.

Usage:
  flip-claim.py flip --module Rewind --claim M4-RW-019 --commit <sha> \
      --ruling RULING-25 --clause "<exact clause>" --why "<why in scope>" \
      --authorised-by "<ruling/disposition + who + date>" \
      --pinned-by "<test>" [--note "..."]
  flip-claim.py recompute --module Rewind          # summary only
  flip-claim.py repoint --module Rewind --old <sha> --new <sha>
"""
import argparse
import json
import re
import sys

BASE = "register/reconciliation"
HASH_RE = re.compile(r"\b[0-9a-f]{7,40}\b")


def find_cited_hash(raw, old):
    """Find a hash cited in `raw` that repoint's `--old` refers to.

    Filings store hashes at whatever length was on hand when the claim was
    filed — 8-char abbreviations are the norm, but a full 40-char sha is
    valid too. A post-rebase `--old` is usually a full sha, so matching it
    verbatim (or its first 10 chars) against an 8-char citation always
    misses. Compare on the SHORTER of the two lengths instead (minimum 7,
    below which a hex prefix is not a trustworthy hash reference either
    way) — this matches a full sha against an 8-char citation and an
    8-char --old against a full-length citation.
    """
    candidates = sorted(set(HASH_RE.findall(raw)))
    matches = []
    for cited in candidates:
        n = min(len(cited), len(old))
        if n < 7:
            continue
        if cited[:n] == old[:n]:
            matches.append(cited)
    if len(matches) > 1:
        sys.exit(f"{old[:10]} matches {len(matches)} distinct citations "
                  f"({', '.join(matches)}) — disambiguate with a longer --old")
    return matches[0] if matches else None


def load(module):
    claims = json.load(open(f"{BASE}/{module}.claims.json"))
    filings = json.load(open(f"{BASE}/{module}.filings.json"))
    return claims, filings


def save(module, claims, filings):
    for name, data in (("claims", claims), ("filings", filings)):
        with open(f"{BASE}/{module}.{name}.json", "w") as fh:
            json.dump(data, fh, indent=1, ensure_ascii=False)
            fh.write("\n")


def recompute_summary(filings):
    rows = [f for f in filings if "claim_id" in f]
    holder = next((f for f in filings if "_summary" in f), None)
    if holder is None:
        holder = {"_summary": {}}
        filings.append(holder)
    summary = holder["_summary"]
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
        "coverage": f"{round(100 * reached / len(rows))}%" if rows else "0%",
        "by_ruling": {k: sorted(v) for k, v in sorted(by_ruling.items())},
    })
    return summary


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)

    f = sub.add_parser("flip")
    f.add_argument("--module", required=True)
    f.add_argument("--claim", required=True)
    f.add_argument("--commit", required=True)
    f.add_argument("--ruling", required=True)
    f.add_argument("--clause", required=True)
    f.add_argument("--why", required=True)
    f.add_argument("--authorised-by", required=True)
    f.add_argument("--pinned-by", required=True)
    f.add_argument("--note", default=None)
    f.add_argument("--date", required=True, help="YYYY-MM-DD of the fix")

    r = sub.add_parser("recompute")
    r.add_argument("--module", required=True)

    rp = sub.add_parser("repoint")
    rp.add_argument("--module", required=True)
    rp.add_argument("--old", required=True)
    rp.add_argument("--new", required=True)

    a = p.parse_args()
    claims, filings = load(a.module)

    if a.cmd == "flip":
        filing = next((x for x in filings if x.get("claim_id") == a.claim), None)
        if filing is None:
            sys.exit(f"no filing for {a.claim} in {a.module}")
        if filing["outcome"] != "VIOLATES":
            sys.exit(f"{a.claim} is {filing['outcome']}, not VIOLATES — nothing to flip")
        filing.update({
            "outcome": "COMPLIES",
            "ruling": a.ruling,
            "clause_that_reaches_it": a.clause,
            "why_in_scope": a.why,
            "fix": {"commit": a.commit, "date": a.date,
                    "authorised_by": a.authorised_by,
                    "pinned_by": a.pinned_by,
                    **({"note": a.note} if a.note else {})},
        })
        s = recompute_summary(filings)
        save(a.module, claims, filings)
        print(f"flipped {a.claim} → COMPLIES under {a.ruling}; "
              f"{s['reached']} reached, {s['complies']}/{s['violates']} over {s['total']}")

    elif a.cmd == "recompute":
        s = recompute_summary(filings)
        save(a.module, claims, filings)
        print(f"{a.module}: {s['reached']} reached, "
              f"{s['complies']} complies / {s['violates']} violates over {s['total']}")

    elif a.cmd == "repoint":
        raw = json.dumps(filings, ensure_ascii=False)
        match = find_cited_hash(raw, a.old)
        if match is None:
            sys.exit(f"{a.old[:10]} not cited in {a.module} filings")
        replacement = a.new[:len(match)]
        raw = raw.replace(match, replacement)
        filings = json.loads(raw)
        save(a.module, claims, filings)
        print(f"re-pointed {match} → {replacement} in {a.module} filings")


if __name__ == "__main__":
    main()
