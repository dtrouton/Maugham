#!/usr/bin/env python3
"""Phase 14: add the `verdict` field to the ledger schema and record Denver's
first rulings.

The seam experiment surfaced this gap: the ledger records `warrant` (how well
evidenced a claim is) and had NO field for whether the behaviour is WANTED. A
shattered property was indistinguishable from a documented quirk, and the blind
implementer in Phase 10 reproduced a defect faithfully because nothing told it
otherwise. `verdict` is that missing field.
"""
import json

LEDGER = "register/01-claims-ledger.json"
d = json.load(open(LEDGER))
by_id = {c["claim_id"]: c for c in d["claims"]}

# ---------------------------------------------------------------- the rulings
RULINGS = {
    "RULING-1": {
        "statement": ("Maugham MUST NOT accept, through any of its own entry points, content it "
                      "cannot read back faithfully. The refusal must be visible at the point of "
                      "entry rather than discovered later."),
        "scope": "every entry point Maugham itself offers — the editor, MCP writes, canvas promotion, inbox promote",
        "ruled_by": "human", "date": "2026-08-01",
        "rationale": ("Product-level, from the constitution's 'the words are safe'. The writer must "
                      "never be able to create, from inside the app, content that will later be "
                      "eaten. Stated by Denver as: 'this is what makes it important there isn't a "
                      "foot gun and people can't enter things that will get eaten within Maugham'."),
    },
    "RULING-2": {
        "statement": ("A file on disk MAY contain content Maugham drops when reading it. That is "
                      "acceptable. The fidelity obligation is on the ENTRY POINTS, not on the file."),
        "scope": "the parse path, for files arriving from outside — hand-edits, imports, sync",
        "ruled_by": "human", "date": "2026-08-01",
        "rationale": ("Consistent with the existing hard invariant that external .md edits are not "
                      "honored and the model owns the file. Deliberately NOT symmetric with "
                      "RULING-1: strictness applies where a person can act, tolerance applies where "
                      "a file arrives."),
    },
}

# ------------------------------------------------- verdicts on existing claims
# verdict ∈ RATIFIED | DEFECT | ACCEPTED_LIMIT | UNRULED
VERDICTS = {
    # Governed by RULING-1: reachable from inside, so it is a footgun.
    "M1-C-043": ("DEFECT", ["RULING-1"],
                 "An invalid swatch is reachable from inside Maugham (MCP write, canvas promotion). "
                 "Under RULING-1 it must be refused at that entry point, not written and then "
                 "silently lost. Resolves ruling-sheet item R11."),
    "M1-C-044": ("DEFECT", ["RULING-1"],
                 "A newline in a title is reachable from inside; the remainder migrating into body "
                 "is exactly the silent eating RULING-1 forbids."),
    "M1-C-045": ("DEFECT", ["RULING-1"],
                 "A newline in a note truncates it. Same reasoning as M1-C-044."),
    "M1-C-046": ("DEFECT", ["RULING-1"],
                 "A remote URL in imagePaths is mangled by relativize. Reachable from inside via a "
                 "constructed model."),
    # Governed by RULING-2: these are parse-side tolerance of outside input.
    "M1-C-024": ("ACCEPTED_LIMIT", ["RULING-2"],
                 "A CRLF document is an external file. RULING-2 permits dropping what cannot be "
                 "read — BUT the scale here (every field lost, title swallows the document) makes "
                 "this worth revisiting on its own; recorded as an accepted limit only for the "
                 "purposes of this ruling pass. Ruling-sheet item R01 still stands."),
    "M1-C-038": ("ACCEPTED_LIMIT", ["RULING-2"],
                 "Unknown-heading-before-structure kept as body: parse-side tolerance of outside input."),
    "M1-C-039": ("ACCEPTED_LIMIT", ["RULING-2"],
                 "Unknown-heading-after-structure discarded: parse-side tolerance of outside input."),
    # Ratified: confirmed by a held property AND consistent with the rulings.
    "M1-T-041": ("RATIFIED", ["RULING-1"],
                 "The renderer never emitting a bare '- ' bullet IS RULING-1 applied at the render "
                 "boundary. P08 held over 20,000 cases."),
    "M1-T-042": ("RATIFIED", ["RULING-1"],
                 "Skipping an untagged-empty note is the canonical instance of RULING-1 in this "
                 "module: do not write what cannot be read back."),
}

for cid, (verdict, rulings, note) in VERDICTS.items():
    c = by_id[cid]
    c["verdict"] = verdict
    c["governed_by"] = rulings
    c["_verdict_note"] = note

for c in d["claims"]:
    c.setdefault("verdict", "UNRULED")
    c.setdefault("governed_by", [])

d["_meta"]["rulings"] = RULINGS
d["_meta"]["schema_note"] = (
    "`warrant` = how well evidenced a claim is. `verdict` = whether the behaviour is WANTED. "
    "They are independent: a HIGH-warrant claim can be a DEFECT (well-proven wrong behaviour), "
    "and a LOW-warrant claim can be RATIFIED. The Phase 10 regeneration reproduced a defect "
    "faithfully because this field did not exist."
)
d["_meta"]["phase"] = 14

import collections
counts = collections.Counter(c["verdict"] for c in d["claims"])
d["_meta"]["counts"]["verdicts"] = dict(counts)
json.dump(d, open(LEDGER, "w"), indent=2)
print("rulings recorded:", list(RULINGS))
print("verdicts:", dict(counts))
