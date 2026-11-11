# RULING-24 amendment — a draft for Denver

**ACCEPTED 2026-11-11.** Denver accepted the proposed wording below, extended it to palette cards (his
answer to P2), and added: "we might need to be clear we accept a lower SLO on note history compared to
manuscript". The amendment is in the register (`register/01-claims-ledger.json` → `_meta.rulings`,
`amended` on RULING-24 and RULING-56; `RULINGS.md` regenerated and `ruling-hashes.json` re-pinned with
`23-generate-rulings.py --amend RULING-24,RULING-56`). Every filing citing RULING-24 was re-read; the
six that quoted the old RESEARCH line now quote the new one (all still COMPLIES), and M6-PR-037 was
rewritten for P1. The final wording and the four answers are at the end of this note; the rest is the
draft as it was put to him.

## RULING-24 as it stands

> DELETING STATE IS NOT DELETING HISTORY. Protection is tiered:
>   THE WORK — the prose, the screenplay, the thing being created — is protected AT ALL COSTS and is version-controlled: every change to it is retained.
>   RESEARCH is recoverable but not versioned.
>   INGESTED OR DERIVED material — a voice note already promoted as text, a cache, a render — is not protected; losing it costs nothing but annoyance.
> The boundary is PRACTICAL ECONOMICS: images, voice notes and PDFs are large, and versioning everything would be expensive.

RULING-24's own basis anticipates this: "in future we might version control parts of research too".
RULING-56 (2026-10-30) already records the direction, and its last sentence is now out of date:
"Research tables are versioned in the code (report plan 9d, claim M5-AN-067); Research notes are not yet,
and RULING-24 still describes them."

## What you ruled on 2026-11-10

- Research notes get what Research tables have: earlier versions, restorable from the inspector.
- Files — pictures, PDFs, audio — stay covered by backups, not by versions (the economic boundary).
- The assistant's writes to a note are kept and marked, as its writes to a table are.

All of it is built on branch `claude/typing-loop-and-note-versions` (claims M5-AN-070, 071, 072; `M1-C-055`'s second half closed).

## Proposed wording

RULING-24, the RESEARCH line and the boundary line:

> RESEARCH TEXT — a table, a note — is versioned: its writes, the writer's and the assistant's, keep earlier versions the writer can restore (RULING-56). Research FILES — pictures, voice notes, PDFs — are recoverable but not versioned.
> The boundary is PRACTICAL ECONOMICS: images, voice notes and PDFs are large, and versioning everything would be expensive; text is cheap.

RULING-56, its last sentence, replaced by:

> Research tables and Research notes are versioned in the code (claims M5-AN-067, M5-AN-070 to M5-AN-072); the files named above are not.

If you accept, the register's ruling source is `register/01-claims-ledger.json` → `_meta.rulings`; the
generator `register/scripts/23-generate-rulings.py` rebuilds `RULINGS.md`, and `ruling-hashes.json` is re-pinned. Filing
`M6-PR-037` (COMPLIES under RULING-24's "not versioned") would then be re-read against the new wording; the Rewrite
still keeps its Trash entry, so it still complies.

## Questions still open (the plan's "Pending Denver" table), with what is built

| | Question | As built (the default) |
|---|---|---|
| P1 | A canvas Rewrite keeps the replaced text as a Trash "previous version" (M6-PR-037). Replace it with a version, or keep both? | Both. A Rewrite leaves a Trash entry and a version. |
| P2 | Do palette cards get versions? | No. A card is refused by the note door and shows no Versions. |
| P3 | When the earlier version cannot be kept, is the save stopped (as tables) or made anyway with a notice? | INTERIM, not as the plan's default: a timed autosave is not made and the writer is told once; a save at a note switch, close, ⌘S or a move is made anyway, with a notice that the earlier version could not be kept. So an edit is never dropped at close. The guide says only "if Maugham can't keep the earlier version, it tells you". |
| P4 | Record the 2026-11-10 ruling as an amendment to RULING-24 (and RULING-56's last sentence)? | This draft; nothing committed to the register. |

## The final wording (in the register since 2026-11-11)

RULING-24, the RESEARCH line (now two lines) and the boundary line:

> RESEARCH TEXT — a table, a note, a palette card — is versioned: its writes, the writer's and the assistant's, keep earlier versions the writer can restore (RULING-56). Research FILES — pictures, voice notes, PDFs — are recoverable but not versioned.
> Research history is held to a LOWER STANDARD than the work's, knowingly: the work keeps every change; research text keeps one version per editing run and a bounded number of them per item on each device, older ones are dropped, and a save may land without its earlier version when that version cannot be kept (the writer is told).
> The boundary is PRACTICAL ECONOMICS: images, voice notes and PDFs are large, and versioning everything would be expensive; text is cheap.

RULING-56, its last sentence:

> Research tables, notes and palette cards are versioned in the code (claims M5-AN-067, M5-AN-070 to M5-AN-072); the files named above are not.

## Denver's four answers (2026-11-11)

| | Answer | Built |
|---|---|---|
| P1 | "Drop the trash entry IF we guarantee a version is created." | A canvas Rewrite of a note or card lands only through the note door, after the text it replaces is kept as a version; if the version can't be kept the Rewrite is refused and the file untouched; with no window store it refuses. No Trash entry; old `priorVersion` entries still restore. M6-PR-037 rewritten. |
| P2 | "Version." | Palette cards keep versions as notes do: every card writer goes through the door; the card editor's own saves keep one per editing run; the card editor re-reads on the reload signal; a card's inspector lists Versions with Restore. `update_note` still refuses a card. |
| P3 | As built. | No change (a timed autosave waits; a save at a note switch, close, ⌘S or a move lands with a notice). |
| P4 | The wording above, plus the lower-standard sentence. | In the register. |
