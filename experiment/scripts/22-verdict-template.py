#!/usr/bin/env python3
"""Phase 45: make the checks STRUCTURAL rather than a matter of my discipline.

A verdict cannot be filed without answering five questions. Each corresponds to a
failure mode this session actually produced:

  ruling + clause_that_reaches_it   PRINCIPLE-3  scope, not symptom
  why_in_scope                      PRINCIPLE-3  forced to argue it in writing
  intent_expressed_when             method finding: intent has duration
  reachability.call_path            PRINCIPLE-4  traced, not intuited
  violation_or_enhancement          PRINCIPLE-2  a wish is not a defect

The validator REJECTS an incomplete verdict. Re-filing the existing ones through
it is the point: it should catch errors, not rubber-stamp them.
"""
import json, sys, collections

L = "experiment/01-claims-ledger.json"
d = json.load(open(L))
by = {c["claim_id"]: c for c in d["claims"]}
R = d["_meta"]["rulings"]

REQUIRED = ["ruling", "clause_that_reaches_it", "why_in_scope",
            "intent_expressed_when", "call_path", "violation_or_enhancement"]

# Re-filed honestly. Where the template forces a change, `_template_caught` says so.
FILINGS = {
 "M1-C-053": {
   "ruling": "RULING-1",
   "clause_that_reaches_it": "MUST NOT accept, at Maugham's own ENTRY POINTS, content it cannot read back faithfully",
   "why_in_scope": ("PaletteCardEditor.addNote IS an entry point and it accepts an untagged note whose "
     "text begins with a sense name — content the format cannot read back faithfully."),
   "intent_expressed_when": "contemporaneous — the writer clicks the explicit 'Untagged' button, then types",
   "call_path": "palette card editor -> type note text -> press 'Untagged' -> addNote(sense: nil)",
   "violation_or_enhancement": "violation",
   "_template_caught": ("Was filed under RULING-11 (bookkeeping alters intent). Writing the clause out "
     "exposed the mismatch: a sense prefix is VISIBLE in the file, not invisible bookkeeping, and R11's "
     "stated scope is 'anchors, structural framing'. The mechanism is an entry point accepting "
     "un-round-trippable content, which is RULING-1 exactly. My earlier 'correction' from R1 to R11 was "
     "itself the error."),
 },
 "M1-C-023": {
   "ruling": "RULING-11",
   "clause_that_reaches_it": "Maugham's own invisible bookkeeping (anchors, STRUCTURAL FRAMING) must never alter the writer's intent",
   "why_in_scope": "the renderer's single structural blank-line pad is literally structural framing, and it eats a blank line the writer typed",
   "intent_expressed_when": "contemporaneous — the writer types the blank line",
   "call_path": "palette card editor -> body TextEditor -> type a blank line before `kind:` -> save -> reparse",
   "violation_or_enhancement": "violation",
 },
 "M1-C-054": {
   "ruling": "RULING-11",
   "clause_that_reaches_it": "must never alter the writer's intent — not what they see, not what is stored, not what Claude is served",
   "why_in_scope": "paragraph and task anchors are the canonical invisible bookkeeping; stripping them alters prose that quotes those shapes",
   "intent_expressed_when": "contemporaneous — the writer types the code block",
   "call_path": "manuscript containing `<!-- ¶abcd -->` in prose -> DerivedManuscriptCache/search/translation -> stripAnchors",
   "violation_or_enhancement": "violation",
 },
 "M1-C-055": {
   "ruling": "RULING-7 + RULING-4",
   "clause_that_reaches_it": "R7: 'unreadable is never presented as empty'; R4: 'authored words are always recoverable' (against MAUGHAM'S OWN ACTIONS, per R23's scope clause)",
   "why_in_scope": ("R7: the research note editor is plainly writer-facing. R4: the loss is caused by "
     "Maugham's own swallow-then-overwrite, not by the writer's deliberate act, so R23's carve-out does "
     "not apply."),
   "intent_expressed_when": "contemporaneous — the writer opens a note expecting its contents and types",
   "call_path": "research pane -> open a note not decodable as UTF-8 -> loadDocument sets \"\" -> one keystroke -> binding setter -> scheduleFileSave -> performFileSave atomic replace",
   "violation_or_enhancement": "violation",
 },
 "M1-C-056": {
   "ruling": "RULING-22",
   "clause_that_reaches_it": "controls are unambiguous and DO WHAT THEY SAY",
   "why_in_scope": "the control is labelled 'Rewind to before this…' and derives with prefix(through:), which is inclusive — it lands after",
   "intent_expressed_when": "contemporaneous — the writer clicks the control expecting its stated behaviour",
   "call_path": "History pane -> any op row -> 'Rewind to before this…' -> confirm -> Deriver.derive(ops:upTo:.atOp)",
   "violation_or_enhancement": "violation",
 },
 "M1-C-057": {
   "ruling": "RULING-4",
   "clause_that_reaches_it": "words the writer authored are always recoverable — against accidents and against Maugham's own actions",
   "why_in_scope": ("the loss is caused by Maugham's own mover failing to close a document it could not "
     "name; the writer's delete intent covers the GROUP, not the unsaved edit inside it"),
   "intent_expressed_when": ("delete intent is contemporaneous and covers the group. It does NOT cover "
     "the open document's unsaved edit — that is the distinction the defect turns on"),
   "call_path": "binder -> open a document inside a group -> type -> select the GROUP -> Delete -> deleteStructureItem passes item.path only -> closeFlushAndUnregister exact-match misses the child",
   "violation_or_enhancement": "violation",
   "_template_caught": ("Was filed under RULING-4 + RULING-20. RULING-20 ('honour intent, default safe') "
     "is a ROOT and was doing no work here — R4 alone reaches it. Dropped, per the root-only discipline: "
     "a root listed beside a sub that already reaches the case is decoration."),
 },
}

rejected = []
for cid, f in FILINGS.items():
    missing = [k for k in REQUIRED if not f.get(k)]
    if missing:
        rejected.append((cid, missing)); continue
    c = by[cid]
    c["verdict_filing"] = f
    c["governed_by"] = [r.strip() for r in f["ruling"].split("+")]

if rejected:
    sys.exit(f"REJECTED incomplete filings: {rejected}")

caught = {k: v["_template_caught"] for k, v in FILINGS.items() if "_template_caught" in v}
d["_meta"]["verdict_template"] = {
 "required_fields": REQUIRED,
 "rationale": {
   "ruling + clause_that_reaches_it": "PRINCIPLE-3 — scope, not symptom",
   "why_in_scope": "PRINCIPLE-3 — forces the argument to be written, which is where it fails",
   "intent_expressed_when": "method finding: intent has duration; I evaluated it at the instant",
   "call_path": "PRINCIPLE-4 — reachability traced, not intuited",
   "violation_or_enhancement": "PRINCIPLE-2 — a wish is not a defect",
 },
 "refiled": len(FILINGS), "caught_on_refile": len(caught), "catches": caught,
}
d["_meta"]["phase"] = 45
json.dump(d, open(L, "w"), indent=2)
print(f"re-filed {len(FILINGS)} verdicts through the template")
print(f"caught {len(caught)} errors on re-file:\n")
for k, v in caught.items():
    print(f"  {k}: {v[:200]}\n")
