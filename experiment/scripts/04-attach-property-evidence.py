#!/usr/bin/env python3
"""Phase 4: attach property-test evidence to the ledger.

Numbers transcribed from the PROP lines emitted by
  swift test --package-path experiment/ExperimentTests --filter PropertyHammering
"""
import json

LEDGER = "experiment/01-claims-ledger.json"

# name -> (cases_run, held, counterexample, claims it bears on, intent clauses)
PROPS = {
 "P01": (20000, True, None,
         ["M1-T-032", "M1-T-033", "M1-T-018", "M1-T-020", "M1-T-037", "M1-T-038", "M1-T-040"],
         ["M1-A-01"], "parse(render(card)) == card over editor-reachable models"),
 "P02": (20000, True, None, ["M1-C-047"], ["M1-A-02", "M1-A-03"],
         "render/parse reaches a fixed point after one pass, over pathological models"),
 "P03": (69, False, '"#+2DDAf" is accepted; canonical shape is "#+" + any 5 hex digits',
         ["M1-C-003", "M1-T-030"], ["M1-A-11"],
         "color(fromHex:) accepts exactly #([0-9a-fA-F]{3}|[0-9a-fA-F]{6})"),
 "P04": (20000, True, None, ["M1-T-039"], ["M1-A-07"],
         "no body content corrupts kind, over pathological models"),
 "P05": (20000, True, None, ["M1-T-022", "M1-T-023", "M1-T-024", "M1-T-025", "M1-T-026"],
         ["M1-A-04"], "body bytes survive the round trip exactly"),
 "P06": (20000, True, None, ["M1-T-004"], ["M1-A-11"],
         "swatch retention is exactly the valid subsequence, order preserved"),
 "P07": (20000, True, None, ["M1-T-007", "M1-T-045", "M1-T-046"], ["M1-A-14"],
         "relativize is the exact inverse of resolve for project-relative paths"),
 "P08": (20000, True, None, ["M1-T-041", "M1-T-042"], ["M1-A-09"],
         "render never emits a bare '- ' bullet, for any note list"),
 "P09": (1, False,
         'LF "\\n- x.jpg" parses body "- x.jpg"; the same doc with CRLF parses body "\\r\\n- x.jpg". '
         'Illustrative: "# T\\r\\nkind: location" loses its kind entirely',
         ["M1-C-024"], [], "parsing is agnostic to LF vs CRLF line endings"),
 "P10": (20000, True, None, ["M2-C-018", "M2-T-015"], ["M2-A-18"],
         "collect(where: p) == collect(where: true).filter(p)"),
 "P11": (20000, True, None, ["M2-T-005", "M2-T-014", "M2-C-023", "M2-T-008"], ["M2-A-03"],
         "collectIds / collect(true) / leaves agree with an independent explicit-stack pre-order oracle"),
 "P12": (20000, True, None, ["M2-T-018"], ["M2-A-11"],
         "mutate and remove never disturb the input forest"),
 "P13": (90, False,
         'forest [XPathNode(path: "research")], oldPrefix "research/", newPrefix "NEW" '
         '-> path unchanged; the semantic rule says it denotes the node itself',
         ["M2-T-023", "M2-T-024", "M2-C-027"], ["M2-A-06"],
         "rewritePaths matches the SEMANTIC self-or-descendant rule, not a transcription of the code"),
 "P14": (20000, True, None, ["M2-C-010", "M2-C-012", "M2-C-013", "M2-T-001"], ["M2-A-16"],
         "every walker contract holds on forests WITH duplicate ids"),
 "P15": (20000, True, None, ["M2-C-020", "M2-T-012"], ["M2-A-03"],
         "first(where:) == collect(where:).first"),
}

d = json.load(open(LEDGER))
by_id = {c["claim_id"]: c for c in d["claims"]}
missing = []

for name, (cases, held, cex, claims, clauses, statement) in PROPS.items():
    for cid in claims:
        c = by_id.get(cid)
        if c is None:
            missing.append(cid); continue
        block = {
            "property": name,
            "test": f"PropertyHammering.test_{name}_*",
            "statement": statement,
            "cases_run": cases,
            "held": held,
            "counterexample": cex,
            "bears_on_intent_clauses": clauses,
        }
        # A claim can be hammered by more than one property.
        existing = c["evidence"].get("property_test")
        if existing is None:
            c["evidence"]["property_test"] = block
        elif isinstance(existing, list):
            existing.append(block)
        else:
            c["evidence"]["property_test"] = [existing, block]
        # A shattered property downgrades warrant unless the claim IS the pinned defect.
        if not held and c["source"]["type"] == "EXISTING_TEST":
            c["warrant"] = "CONTRADICTED"

assert not missing, f"unknown claim ids: {missing}"

c = d["claims"]
hammered = [x for x in c if x["evidence"].get("property_test")]
d["_meta"]["phase"] = 4
d["_meta"]["property_hammering"] = {
    "properties_written": len(PROPS),
    "properties_held": sum(1 for v in PROPS.values() if v[1]),
    "properties_shattered": sum(1 for v in PROPS.values() if not v[1]),
    "total_cases_run": sum(v[0] for v in PROPS.values()),
    "claims_with_property_evidence": len(hammered),
    "claims_contradicted": sum(1 for x in c if x["warrant"] == "CONTRADICTED"),
}
json.dump(d, open(LEDGER, "w"), indent=2)
print(json.dumps(d["_meta"]["property_hammering"], indent=2))
print("contradicted:", [x["claim_id"] for x in c if x["warrant"] == "CONTRADICTED"])
