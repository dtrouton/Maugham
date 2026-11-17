# Hardening 2026-11-17 — issues #145–#149

**Status:** agreed with Denver in conversation, 2026-11-17 ("yep" to the table of fix/leave and to leaving the MCP characterisation out).
**Source:** GitHub issues #145, #146, #147, #148, #149 (each carries the reviewer's finding and fix-shape; read the issue for the detail).
**Ships as:** Maugham 0.48.0 (Mac only).

## What is fixed

| Id | Issue | Behaviour after the fix |
|---|---|---|
| F1 | #149 M1 | `set_publish_config` with a `patch` that is not a JSON object (scalar, `null`, array) is refused with `MCPError.invalidArgument("patch must be a JSON object (RFC 7396 merge patch); a scalar, null, or array is not a valid patch")`. The server keeps running. A `null` INSIDE the object still deletes that key. |
| F2 | #149 M2 | `list_publish_files` on a `.maugham/publish/` that exists and cannot be read refuses with a named `publish_dir_unreadable` error. An absent folder still reads as an empty tree (RULING-7: unreadable is never presented as empty). |
| F3 | #145 | Every piece verb that moves a folder which can hold Research (`movePiece`, `renamePiece`, the piece trash and its restore, and any other `relocateUserContent` caller the census finds) runs its mover calls inside `ProjectStore.withResearchItemsInFlight` over the Research ids under each moved piece. A note save that lands meanwhile takes the door's existing "being moved" route (conflict copy + notice, M5-AN-082), never a fresh file at the old path. |
| F4 | #146 (first half) | A closing document clears its pending recovery file only when the file still holds the bytes that instance last wrote (compare-and-clear). A reopened document's recovery file survives the old instance's late close. |
| F5 | #147 R1 | A Replace click whose match id is gone (the results were refreshed) falls back to the match with the same path, range and line preview and proceeds through the existing clicked-occurrence check. A refusal (`staleSearchMatch`) refreshes the results. |
| F6 | #147 R2 | Replace in a Research note hands the door the hash of the bytes Replace read. If the file changed in between, nothing is written and Replace throws `staleSearchMatch`. |
| F7 | #148 D1 | When `add_note`, the MCP inbox promotion, or a kept letter fails to save the body of the note it just created, the empty note is removed again (row and file) before the error is thrown. A retried inbox promotion makes one note. |
| F8 | #148 D2 | A failed asset-ref rewrite after a note move or rename is reported to the writer through the same outcome the link sweep uses for `linksLeftIn`, naming the note. It is still logged. |
| F9 | #148 D4 (part) | `addResearchTextNote` derives a new note's folder from the parent group's actual folder on disk, not its title slug. A test saves a real note through the door and then destroys it (N7's production path). M3-TR-066 gets its filing; M3-TR-068's missing-group arm gets a pin. |

## What is left, on purpose

- **#146 second half (the burst variant):** RULING-64 (2026-11-17) kept the stale-`.md` rule as built; widening was put and not chosen.
- **#147 R3:** the three limits of the clicked-occurrence check stay documented limits.
- **#148 D3:** a new card's blank-template mark stays in memory only.
- **#148 D4, rest:** the raw-write census's blind spots, the Core disable experiment, and the twin wait loops stay as filed.
- **#149 M3:** re-running the MCP tool-surface characterisation is its own job; a new issue carries it, and `origin/worktree-mcp-tools-claims` is deleted once F1/F2 are on main.

## Rules that bind every task

- Register rule (CLAUDE.md): fix, pinned production test, claim updated, filing flipped, in the same task. Read the module's claims and filings first.
- Rulings in reach: RULING-7 (unreadable is not empty), RULING-52 (a failure after a change says what it did), RULING-60/62/63, RULING-64. No new ruling is needed; anything that looks like a product decision is recorded in the claim as the coordinator's call.
- Tripwire 14 (typed mover), 58 (`SafeRelativePath`), and the raw-research-text marker census must stay green.
