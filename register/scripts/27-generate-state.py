#!/usr/bin/env python3
"""Regenerate START-HERE.md's state-of-play block from the reconciliation
JSONs. The block between the BEGIN/END markers is GENERATED — hand-edits to it
are overwritten, which is the point: the table drifted twice on 2026-08-08 and
was hand-fixed twice, and a state table that can drift is a state table that
lies. Narrative stays hand-written outside the markers.

Run after any flip/recompute:  python3 register/scripts/27-generate-state.py
"""
import json
import sys

START = "<!-- BEGIN GENERATED STATE (register/scripts/27-generate-state.py) -->"
END = "<!-- END GENERATED STATE -->"
DOC = "register/START-HERE.md"

# MaughamCore modules live in the ledger and are frozen history; app-layer
# modules live in per-module files and move with every fix loop.
CORE_ROWS = [
    ("`MaughamCore.TreeWalk`", 61, "0%", "—", "`07-summary.md`"),
    ("`MaughamCore.PaletteCardParser`", 47, "34%", "16 reached", "`07-summary.md`"),
    ("`MaughamCore.PaletteCardModel`", 40, "40%", "16 reached", "`07-summary.md`"),
]
APP_MODULES = [
    ("Trash", "`Stores/TrashStore` + `ProjectStore+Trash`", "`22-trash-reconciliation.md`"),
    ("Rewind", "`OpLog/Document+Rewind` (+`RewindUndo`, `Deriver+Rewind`)", "`24-rewind-reconciliation.md`"),
    ("Annotations", "`OpLog/Document+Annotations` (+`AnnotationDeriver`, `AnnotationInverse`)", "`28-annotations-reconciliation.md`"),
    ("Promotion", "`Canvas/Promotion*` (the falsification module)", "`29-promotion-falsification.md`"),
    ("Publications", "`Publish/Republisher` (+`CompileOrchestrator`)", "—"),
    ("Inbox", "`Stores/InboxStore` (+`InboxTranscriptionWorker`, the promote siblings)", "—"),
    ("OpLog", "`OpLogStore` read paths + `Document.load`'s refusal (the spine's first slice)", "—"),
]
CORE_RECONCILED, CORE_TOTAL = 148, 169


def app_row(module, label, report):
    filings = json.load(open(f"register/reconciliation/{module}.filings.json"))
    s = next(f for f in filings if "_summary" in f)["_summary"]
    return ((label, s["total"], s["coverage"],
             f"{s['complies']} / {s['violates']}", report),
            s["total"], s["complies"], s["violates"])


rows = list(CORE_ROWS)
app_total = app_complies = app_violates = 0
for module, label, report in APP_MODULES:
    row, total, complies, violates = app_row(module, label, report)
    rows.append(row)
    app_total += total
    app_complies += complies
    app_violates += violates

lines = [
    START,
    "",
    "| Module | Claims | Coverage | Complies / Violates | Report |",
    "|---|---|---|---|---|",
]
lines += [f"| {m} | {c} | {cov} | {cv} | {rep} |" for m, c, cov, cv, rep in rows]
lines += [
    "",
    f"The three MaughamCore rows are the {CORE_RECONCILED} reconciled claims out of the ledger's "
    f"{CORE_TOTAL}; the app-layer rows are {app_total} further claims in their own files. "
    f"**{CORE_TOTAL + app_total} claims in the experiment, "
    f"{CORE_RECONCILED + app_total} reconciled.** "
    f"The app layer stands at **{app_complies} complies / {app_violates} violates** "
    f"(MaughamCore's pure modules ran 31:1 — the inversion result).",
    "",
    "App-layer claims are pinned by the PERMANENT suites in `MaughamTests/Claims/` — every full "
    "suite run and CI `mac-tests` re-verifies them; MaughamCore claims run as "
    "`register/ExperimentTests` (CI job `behavioural-claims`). Exception: the OpLog row's pins "
    "live where their subjects do — `MaughamTests/OpLog/` and the MaughamCore package tests "
    "(`core-tests`/`behavioural-claims`) — not under `Claims/`.",
    "",
    END,
]
block = "\n".join(lines)

text = open(DOC).read()
if START in text:
    pre, rest = text.split(START, 1)
    _, post = rest.split(END, 1)
    out = pre + block + post
else:
    sys.exit(f"markers not found in {DOC} — add them once around the state block")
open(DOC, "w").write(out)
print(f"regenerated state block: {CORE_TOTAL + app_total} claims, "
      f"app layer {app_complies}:{app_violates}")
