#!/usr/bin/env python3
"""Phase 6: order the ruling queue by (reverse-dependency count x uncertainty)."""
import json

# uncertainty weights — stated so the ordering is arguable rather than asserted
W = {
    "SHATTERED":      1.00,  # a property found a counterexample
    "CONTRADICTED":   0.90,  # claim disagrees with an observation
    "HALLUCINATION":  0.90,  # intent clause with no support, or falsified
    "PINNED_DEFECT":  0.80,  # characterization pinned behaviour I believe is wrong
    "UNPINNABLE":     0.75,  # recorded, deliberately not pinned
    "LOW_UNHAMMERED": 0.60,  # warrant LOW, intent UNKNOWN, no property
    "OVER_EXTRACTED": 0.55,  # my claim is stronger than its source test
    "OVER_SPECIFIC":  0.45,  # true but brittle pin
    "MEDIUM":         0.40,  # asserted in a test name only, or bundled
    "ARCHITECTURAL":  0.35,  # real intent, unreachable by behavioural test
    "HELD_HIGH":      0.10,  # property held at 20k; ratify-and-move-on
}

# (id, subject, deps, uncertainty-key, recommendation, one-line why)
ITEMS = [
 ("R01","M1-C-024 / P09 — a CRLF card loses every field",11,"SHATTERED","LATENT_DEFECT",
  "Swift's \\r\\n grapheme cluster defeats split(separator:\"\\n\"); a Windows-touched card parses as one line and kind/swatches/senses/images all come back empty."),
 ("R02","M2-C-027 + M2-C-029 / P13 — rewritePaths has two unguarded string preconditions",105,"SHATTERED","LATENT_DEFECT",
  "A trailing '/' on oldPrefix silently rewrites NOTHING; an empty newPrefix silently produces leading-slash (absolute-looking) paths. Bare String parameters, three call sites that happen to be well-behaved, and no diagnostic in either direction."),
 ("R03","M1-C-003 / P03 — color(fromHex:) accepts '#+FFFFF'",8,"SHATTERED","LATENT_DEFECT",
  "UInt32(_:radix:) accepts a leading '+' and the length check counts it; this is the SOLE gate on which swatches enter the model."),
 ("R04","The eleven undocumented preconditions behind 'editor-reachable'",11,"PINNED_DEFECT","NEEDS-DISCUSSION",
  "M1-A-01's escape hatch carries eleven conditions that appear in no comment, no test and no type; either document them or make PaletteCard.init validating."),
 ("R05","M2-C-019 — a collected node carries its ENTIRE unfiltered subtree",36,"LOW_UNHAMMERED","RATIFY",
  "36 call sites depend on it, it is almost certainly intended, and nobody has ever written it down."),
 ("R06","M2-C-018 / P10 — collect descends through a failing parent",36,"HELD_HIGH","RATIFY",
  "The single most load-bearing property of the second-most-called walker; held over 20,000 forests."),
 ("R07","M2-C-010 / P14 — find returns the FIRST pre-order match among duplicates",42,"HELD_HIGH","RATIFY",
  "42 call sites; held over 20,000 forests with deliberately duplicated ids."),
 ("R08","M2-C-012 + M2-C-013 — mutate and remove apply to EVERY match",3,"LOW_UNHAMMERED","NEEDS-DISCUSSION",
  "With a duplicated root id, remove empties the forest; tripwire 23 records that a mint collision has already happened once in this codebase."),
 ("R09","M2-C-036 — the walkers' stack-overflow depth is unguarded and environment-dependent",105,"UNPINNABLE","NEEDS-DISCUSSION",
  "The ratchet's #2 pick and one of only two claims with no test at all; does a depth guard belong here, or is unbounded depth a real invariant of the binder?"),
 ("R10","M2-C-034 — 'unbounded recursion with no depth guard' as a pinned claim",105,"OVER_SPECIFIC","INCIDENTAL-KILLABLE",
  "A description of an ABSENCE. Ratified, it forbids ever adding a depth guard — which R09 may conclude is wanted."),
 ("R11","M1-C-043 — an invalid swatch is written to the file, then silently lost",3,"PINNED_DEFECT","NEEDS-DISCUSSION",
  "Asymmetric with the untagged-empty-note case (M1-T-042), which the renderer DOES skip; the file is written either way."),
 ("R12","M1-C-046 — a remote URL in imagePaths is mangled by relativize",6,"PINNED_DEFECT","LATENT_DEFECT",
  "The parser is careful never to ADMIT a remote URL (M1-A-06); the renderer will happily emit one and collapse its scheme's '//'."),
 ("R13","M1-C-044 + M1-C-045 — a newline in title or note silently loses data",6,"PINNED_DEFECT","NEEDS-DISCUSSION",
  "Title's remainder migrates into body; a note truncates at the newline. Same root question as R04: validate at init, or document as unreachable."),
 ("R14","M2-A-16 — 'node ids MUST be unique within a forest'",105,"HALLUCINATION","INCIDENTAL-KILLABLE",
  "Falsified as a requirement by P14; replace with the true clause — TreeWalk is deliberately agnostic to id uniqueness."),
 ("R15","M1-C-021 — an empty 'kind:' value consumes the one-shot capture",11,"PINNED_DEFECT","LATENT_DEFECT",
  "The one-shot rule exists to stop body prose corrupting kind (M1-T-039); here it fires on a line carrying no information."),
 ("R16","M1-C-023 — a writer-typed blank line before 'kind:' is silently eaten",11,"PINNED_DEFECT","NEEDS-DISCUSSION",
  "Narrows M1-A-04, a rule four dedicated tests are devoted to; a blank-LOOKING line with a space in it survives, which is the tell."),
 ("R17","M2-T-023 + M2-T-024 — the rewrite claims as I extracted them",3,"CONTRADICTED","NEEDS-DISCUSSION",
  "True only for separator-free prefixes; neither my claim nor the doc comment carries the qualifier. Fix the code (R02) or add the precondition."),
 ("R18","M1-T-030 — 'a string with non-hex digits returns nil'",8,"OVER_EXTRACTED","INCIDENTAL-KILLABLE",
  "My extraction generalised a single assertion about '#GGGGGG' into a false universal; rewrite the claim to match the test, and let R03 carry the defect."),
 ("R19","M1-C-041 — template and render disagree on bytes",4,"PINNED_DEFECT","NEEDS-DISCUSSION",
  "A new card changes bytes on its first save with no edit; harmless until any content-hash, sync or git-facing feature exists."),
 ("R20","M1-A-20 — 'MUST NOT admit an invalid swatch into a rendered file'",1,"HALLUCINATION","INCIDENTAL-KILLABLE",
  "Falsified by M1-C-043; I flagged it LOW and predicted its death in Phase 3. Kill the clause; R11 carries the real question."),
 ("R21","M2-C-035 — idsByPath's ITERATION order is not stable across processes",3,"UNPINNABLE","NEEDS-DISCUSSION",
  "The doc comment resolves the INSERTION contest and is silent on iteration; a caller that iterates rather than subscripts has a run-varying order."),
 ("R22","M1-C-016 — an INDENTED '## Swatches' still opens a section",11,"LOW_UNHAMMERED","NEEDS-DISCUSSION",
  "Indentation is the natural thing a writer tries after hitting the documented heading-in-body residual, and it does not work."),
 ("R23","M2-B-01 — TreeWalk is the TEST SUITE's oracle, not only production's",105,"ARCHITECTURAL","RATIFY",
  "12 of 13 test files use it as a fixture helper; a regression here makes assertions across Store/Canvas/Inbox/MCP report on a lie."),
 ("R24","M1-C-040 + M1-C-042 — an exact render byte-string and an enum declaration order",5,"OVER_SPECIFIC","NEEDS-DISCUSSION",
  "M1-C-042 should probably RATIFY (M1-B-04: the phone depends on the order); M1-C-040 is the brittle-pin specimen. Split them."),
 ("R25","M2-A-20 — 'MUST stay allocation-simple and recursive'",105,"HALLUCINATION","INCIDENTAL-KILLABLE",
  "A style preference I dressed as an intent clause, included in Phase 3 as a deliberate specimen. It behaved as advertised."),
]

rows = sorted(ITEMS, key=lambda i: -(i[2] * W[i[3]]))
print(f"{'rank':<5}{'id':<5}{'score':>7}  {'deps':>4} {'uncert':<16}{'recommendation':<22}subject")
for n, (rid, subj, deps, key, rec, why) in enumerate(rows, 1):
    print(f"{n:<5}{rid:<5}{deps*W[key]:>7.1f}  {deps:>4} {key:<16}{rec:<22}{subj}")

json.dump([{"rank": n, "id": r[0], "subject": r[1], "deps": r[2], "uncertainty": r[3],
            "score": round(r[2]*W[r[3]], 2), "recommendation": r[4], "why": r[5]}
           for n, r in enumerate(rows, 1)],
          open("register/06-ruling-queue.json", "w"), indent=2)
