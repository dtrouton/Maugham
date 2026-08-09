#!/usr/bin/env python3
"""Phase 11: derive the SEAM brief from the BOUNDARY brief by ADDING one section.

The two arms must differ in exactly one way — the presence of relationship and
graph claims — or the experiment measures brief-writing rather than claim shape.
So Arm S is generated from Arm B mechanically: same task, same API surface, same
13 boundary claims, same 4 boundary intent clauses, plus §3b.
"""
import sys

B = open("register/11-seam-brief-BOUNDARY.md").read()

SEAM = """
## 3b. Seam claims — the relationship between the mover, the autosaves, and the filesystem

The claims above describe each API member in isolation. These describe the
**relationship between them**, which no single member's boundary can express.
Three parties participate in a move: the **mover**, the two **debounced autosave
timers**, and the **filesystem** (via `NSFileCoordinator` and the app's file
presenter).

| id | kind | claim |
|---|---|---|
| S-S-01 | RELATIONSHIP | A move and the two 750ms debounces are in a **race**. Both timers capture their target path at schedule time (S-B-05, S-B-08). A timer that fires *after* a move therefore writes to the path the file no longer occupies, **re-creating a file at the OLD path** — a phantom the manifest does not know about and the writer sees as a duplicate. |
| S-S-02 | ORDERING | Therefore, for every project-relative path affected by a move, both of the following MUST complete **before any filesystem call** in that move: (i) any open `Document` at that path is **closed and unregistered**; (ii) the store's research-note debounce is **flushed**. |
| S-S-03 | ORDERING | The flush is a single drain of the whole scheduler, not per-path — one call covers every pending research-note write, including notes under a moved folder. |
| S-S-04 | RELATIONSHIP | Closing is not sufficient on its own and unregistering is not sufficient on its own. Closing without unregistering leaves the registry pointing at a stale path; unregistering without closing leaves a live timer that still fires. |
| S-S-05 | RELATIONSHIP | A flush failure MUST NOT abort the move — the filesystem surgery still has to proceed — but MUST NOT be swallowed silently either; it is recorded so a lost last-edit before a move leaves a trace. |
| S-S-06 | GRAPH | Exactly **three** entry points in the whole application may move or delete a path the user might be editing. Every other caller routes through one of them. A fourth entry point is a defect, not an extension. |
| S-S-07 | GRAPH | The close-and-flush discipline of S-S-02 lives **inside** those entry points, never at their call sites, so that no caller can forget either half. This is the property that makes the rule unbypassable rather than merely documented. |
| S-S-08 | GRAPH | Raw `FileManager.moveItem` / `moveToTrash` / `String.write(to:)` on a user-editable path is forbidden outside the mover. Internal non-user paths — scratch/staging, duplicate-copy, anything under `.maugham/` — are deliberately NOT routed through the mover: they touch no path the user is editing, so the discipline does not apply to them. |

"""

if "## 3b." in B:
    sys.exit("Arm B already contains the seam section — refusing to double-add")

marker = "\n---\n\n## 4. Output"
if marker not in B:
    sys.exit("could not find the output section marker in Arm B")

S = B.replace("(ARM B: boundary claims)", "(ARM S: seam claims)")
S = S.replace("CandidateMoverB.swift", "CandidateMoverS.swift")
S = S.replace("NOTES-B.md", "NOTES-S.md")
S = S.replace(marker, "\n" + SEAM + "\n---\n\n## 4. Output")

open("register/11-seam-brief-SEAM.md", "w").write(S)

# Verify the arms differ ONLY by the added section + the three filename swaps.
import difflib
added = [l for l in difflib.unified_diff(B.splitlines(), S.splitlines(), lineterm="", n=0)
         if l.startswith("+") and not l.startswith("+++")]
removed = [l for l in difflib.unified_diff(B.splitlines(), S.splitlines(), lineterm="", n=0)
           if l.startswith("-") and not l.startswith("---")]
print(f"Arm S = Arm B + {len(added)} lines, - {len(removed)} lines")
print("removed lines (should be only the 3 renames):")
for l in removed:
    print("   ", l)
assert len(removed) == 3, "arms differ by more than the filename swaps"
print(f"\nboundary brief: {len(B.splitlines())} lines")
print(f"seam brief:     {len(S.splitlines())} lines")
