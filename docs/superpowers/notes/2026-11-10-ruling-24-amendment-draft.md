# RULING-24 amendment — a draft for Denver

Nothing here is in the register. `register/RULINGS.md` and `register/reconciliation/ruling-hashes.json`
are untouched; the rulings are yours, and hash-pinned. This is proposed wording for you to confirm or change.

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
