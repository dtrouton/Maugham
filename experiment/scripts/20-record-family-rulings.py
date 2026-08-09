#!/usr/bin/env python3
"""Phase 20: record the family-level rulings and apply them to the sweep's
52 product decisions.

The Phase 19 finding was that 32 novel rulings collapse into 6 families. This
records the human verdicts on those families and shows what each one settles —
the claim that a family, once ruled, resolves its members mechanically.
"""
import json, glob, collections

LEDGER = "experiment/01-claims-ledger.json"
d = json.load(open(LEDGER))

FAMILY_RULINGS = {
 "RULING-3": {
   "family": "E — What is on disk stays legible to the writer",
   "verdict": "DECLINED",
   "statement": ("On-disk filename legibility is NOT a commitment. A title that produces no ASCII "
                 "slug yields `NN-untitled.md`, and that is accepted. Maugham does not transliterate, "
                 "and does not put non-Latin script in filenames."),
   "consequence": ("A writer working in Japanese, Russian, Greek or Hebrew has a project folder that "
                   "is opaque outside the app. This is now a known and accepted limitation rather "
                   "than an unexamined defect."),
   "ruled_by": "human", "date": "2026-08-01",
 },
 "RULING-4": {
   "family": "A — Nothing is lost without a trace, and loss is recoverable",
   "verdict": "RATIFIED_NARROWED",
   "statement": ("Words the writer authored are ALWAYS recoverable. Derived or transient material — a "
                 "failed transcription, a superseded render, a cache — may be dropped, but the drop "
                 "must be reported. Recovery is guaranteed only where the writer would look for it."),
   "consequence": ("Every case must be classified as authored or derived, and the line will be "
                   "argued. A trash-restore that fails with the words intact on disk is a defect "
                   "under this ruling; a discarded cache is not."),
   "ruled_by": "human", "date": "2026-08-01",
 },
 "RULING-5": {
   "family": "F — What Maugham does on the writer's behalf carries a higher duty",
   "verdict": "RATIFIED_STRICT",
   "statement": ("A suggestion whose quoted phrase can no longer be found in the writer's paragraph "
                 "MUST NOT be applied. It is refused, the writer is told why, and they may ask again. "
                 "Maugham never guesses where an AI-authored change belongs."),
   "consequence": ("A suggestion the writer still wants becomes unusable after any nearby edit — "
                   "accepted deliberately as the price of never mis-placing AI text. Directly "
                   "closes the verified mis-splice defect."),
   "ruled_by": "human", "date": "2026-08-01",
 },
 "RULING-6": {
   "family": "C — The writer's text is theirs; presentation is ours",
   "verdict": "RATIFIED",
   "statement": ("Stored text is never changed by a formatting convention. An EDITING surface renders "
                 "as-typed, because a caret indexes into the source and display substitution desyncs "
                 "it. A READING surface may present the form's conventions. EXPORT is a reading "
                 "surface that produces an artifact for someone else, so the convention is offered to "
                 "the writer as an option at publish time rather than chosen for them."),
   "consequence": ("The phone reader's uppercase is ratified, not accidental. The Mac editor's "
                   "as-typed rendering has a stated reason (the caret). Export gains an option it "
                   "does not have today."),
   "ruled_by": "human", "date": "2026-08-01",
   "provenance": ("Recovered from commit de1b69d7 + Maugham/Editor/AREA.md: display-time uppercase "
                  "was BUILT and REJECTED for cursor-positioning reasons; a dead ScreenplayLayoutManager "
                  "relic was deleted 2026-06-10. The split was considered, not cheap."),
 },
 "RULING-7": {
   "family": "B — A failure must be reported as what it is",
   "verdict": "RATIFIED_BY_DEFAULT",
   "statement": ("Maugham never misrepresents a failure. Unreadable is never presented as empty. A "
                 "refusal names its real cause. An empty replacement reads as a deletion. A capture "
                 "this build cannot handle says so rather than appearing broken."),
   "consequence": "No product trade-off; consistency work only.",
   "ruled_by": "proposed by machine, not objected to", "date": "2026-08-01",
 },
 "RULING-8": {
   "family": "D — One question, one answer, on every surface and every path",
   "verdict": "RATIFIED_BY_DEFAULT",
   "statement": ("Where the same product question is answered in more than one place, it has one "
                 "answer. A second surface or a second code path may not answer it differently."),
   "consequence": ("A meta-rule: cheap to state, expensive to enforce. It is what makes the 17 "
                   "INCONSISTENT findings defects rather than observations."),
   "ruled_by": "proposed by machine, not objected to", "date": "2026-08-01",
 },
}

# Which family each sweep decision belongs to, by ruling-text keyword.
FAM_KEYS = {
 "RULING-4": ["A capture made on one of","When two devices change the same","Whenever Maugham overwrites",
              "Refusing an unsafe destination","A promote must be undoable","The obligation to make a loss visible"],
 "RULING-7": ["A capture this build does not know","an empty replacement must be presented","must be shown as exactly that"],
 "RULING-6": ["Formatting conventions change how Maugham DRAWS","Capitalising a line must never change",
              "Once the writer has edited a transcript","Where the writer's own words and a stored suggestion conflict",
              "Maugham may render an element in capitals only","Where Maugham capitalises a line the writer typed"],
 "RULING-8": ["The numbers in filenames either follow","Joining two paragraphs must have one stated answer","A split is not a rename"],
 "RULING-3": ["A writer working in a non-Latin script","A manuscript or research file's name","Where a letter has a conventional ASCII",
              "A shortened filename ends on a whole word","Maugham must never give a new item a name"],
 "RULING-5": ["An edit Maugham makes on the writer's behalf","A transformation Maugham applies itself",
              "When a suggestion was made about a specific phrase","A suggestion that contradicts the grain",
              "A suggestion about a paragraph the writer has since deleted","Short paragraphs are identified by their own text",
              "Promoting a voice capture must carry","A capture that failed to transcribe","A symlink a writer has placed",
              "Text a writer has marked as verbatim"],
}

resolved = collections.defaultdict(list)
unresolved = []
inconsistent = []
for f in sorted(glob.glob("experiment/sweep/*.json")):
    j = json.load(open(f))
    for x in j["product_decisions"]:
        if x["classification"] == "INCONSISTENT":
            inconsistent.append((j["module"], x["question"]))
            continue
        if x["classification"] != "NOVEL":
            continue
        r = x.get("proposed_ruling") or ""
        hit = next((rid for rid, keys in FAM_KEYS.items() if any(k in r for k in keys)), None)
        (resolved[hit].append((j["module"], r)) if hit else unresolved.append((j["module"], r)))

d["_meta"]["rulings"].update(FAMILY_RULINGS)
d["_meta"]["phase"] = 20
d["_meta"]["family_ruling_application"] = {
    "novel_decisions_swept": sum(len(v) for v in resolved.values()) + len(unresolved),
    "settled_by_a_family_ruling": sum(len(v) for v in resolved.values()),
    "unsettled": len(unresolved),
    "inconsistencies_now_defects_under_RULING_8": len(inconsistent),
    "per_ruling": {k: len(v) for k, v in sorted(resolved.items())},
}
json.dump(d, open(LEDGER, "w"), indent=2)

print("RULINGS NOW ON RECORD:", len(d["_meta"]["rulings"]))
for rid, r in sorted(d["_meta"]["rulings"].items()):
    print(f"  {rid}  {r.get('verdict','—'):22} {r.get('family','(original)')[:52]}")
print()
tot = sum(len(v) for v in resolved.values())
print(f"novel decisions settled by a family ruling : {tot}/{tot+len(unresolved)}")
for rid, v in sorted(resolved.items()):
    print(f"    {rid}: {len(v)}")
print(f"unsettled: {len(unresolved)}")
print(f"inconsistencies now DEFECTS under RULING-8: {len(inconsistent)}")
