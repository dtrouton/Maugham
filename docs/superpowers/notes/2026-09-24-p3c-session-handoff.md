# Signed op log P3 — session handoff into P3c (2026-09-24)

**Why this note exists.** The session that smoked P3b, fixed what the smoke found, re-smoked it and merged it is out of room. This is the door for the next one. It **replaces** `2026-09-23-p3c-session-handoff.md` (read that one only for its process notes, which still hold). It points at the records; it does not repeat them.

## State of the world

- **Local main is `05edad52`**, carrying signed-op-log P3a, P3b, and the P3b smoke + fix wave (`d3f88d4a`). It is **~166 commits ahead of origin**. Not pushed, not tagged.
- **Denver's ruling stands: P3 ships whole.** Nothing of P3 is pushed, tagged or released until P3c's closing smoke.
- **Gates on the fix wave's final head:** Mac full **9,080 passed / 0 failed / 10 skipped**; MaughamCore green; phone **274 / 0**.
- **P3b is smoked and re-smoked** (four Macs, 2026-09-23/24) — the first move the previous handoff asked for is DONE. The record: `docs/superpowers/notes/2026-09-23-p3b-smoke-finds.md`.
- The dev app on this Mac is built from `ed82aec2` (the fix wave's head); four dev instances may still be running (the root and `~/.maugham-{second,third,fourth}-mac`). Books `TestWorkspace/P3b Smoke` and `TestWorkspace/P3b Resmoke` are scratch.

## Read first, in this order

1. `docs/superpowers/notes/2026-09-23-p3b-smoke-finds.md` — F1–F10, **every ruling Denver made on 2026-09-23/24**, the re-smoke. **These rulings supersede older text** (see 2).
2. `docs/superpowers/notes/2026-09-17-signed-op-log-p3-handoff.md` from **"P3b OUTCOME"** to the end, then its last section **"P3b SMOKE OUTCOME"**, which lists what the smoke superseded (Theirs by position → by reason; Claim unprompted → explicit verb) and adds **F10 to P3c**. Together with the earlier *Carries into P3c* sections (P3a's, P3b's, the P2 carries C4/C5/C7/C10+C17/C12/C14) this is the list P3c is planned against.
3. `docs/superpowers/specs/2026-09-19-signed-op-log-p3-roles-scope-collaborator-design.md` — §8 (the membrane), §9 (inbox + phone), §10 (constitution, ADR, docs), §12 (testing incl. the closing smoke), §13 (shipping), and its dated amendments.
4. `docs/adr/0032-the-signed-op-log.md` — the P3a/P3b addenda, limits, and the smoke's additions (Theirs by reason, the Claim verb, mid-session declaration, registry arrival). `Maugham/OpLog/AREA.md`, `Maugham/Stores/AREA.md` (F7 adoption, Removed Elsewhere, let-go), `Maugham/Views/AREA.md`, CLAUDE.md tripwires 38–50.
5. The ledgers for the P3c whole-branch reviewer: `.superpowers/sdd/2026-09-20-signed-op-log-p3b/ledger.md` and P3a's beside it (git-ignored scratch). The smoke's rulings are in the finds note, not a ledger.

## What P3c is (re-derive against the BUILT code — rule 11; cap ~10 tasks — rule 12; probably two plans)

Spec §8, §9, §10, plus what P3a/P3b/the smoke handed forward. In outline — the handoff file above has the detail:

- **`Posture`** — one Core value from this device's own permit for the document shown (ask `Permit.allows` / `OpLogStore.localWritePermit`, never a rung — tripwires 44/47/49), and every surface gates on it (locked editor, no dispositions, no pass chips, read-only statements, no structural verbs, no round Run; the root's override on someone else's piece; ⌘S flashes and writes no op). A census with a planted offender. **This is also the answer to the smoke's "observed as designed" item**: a collaborator's own Mac silently dropping her out-of-scope or demoted lines — posture and the standing line must make that visible.
- **Component A retires** (`CollaborationRole`, `ShareIdentityMapper`, `ReviewPosturePolicy`, `ProjectWindow.resolvedRole`/`shareReader`/`effectivePosture`, the phone's `SharingRoleBanner`); `FileURLShareMetadataReader` survives for the admission sheet's §7.1 reviewer pre-fill.
- **Option A (I3)** — an author of some pieces may OPEN a new piece nobody has claimed; the load mints it; her own Mac applies her own lines under a standing line *Waiting for <root> to say this piece is yours*. Touches the P3a load seam — its own task and its own opus review. **Interacts with the smoke's by-reason Theirs**: re-derive against `PermitTimeline.judging`/`settled`, not the old positional cut.
- **F10 (Denver, 2026-09-24)** — raise the admission question when a stranger's DEVICE RECORD arrives (the `.registry` arrival arm, `DocumentStore.registryChanged`), not only from chapters open on the root. No log read.
- **Inbox attribution** (`InboxByline`: *from Sam*).
- **The phone**: apply `AnnotationOwnership`; `DeviceStanding` gains the permit; posture per piece in Annotations, capture always offered; role + pieces in Settings with a refresh watcher (C5); `ChainPolicy` sites from the table (C7). The phone signs no record and no event.
- **Carries from P3b** (listed in the P3 handoff's *Added to P3c from the build*) + **P2 carries** C4, C5, C7, C10+C17, C12, C14.
- **Constitution + guides** (§10): *AI is never the author* gains its storage-layer sentence; *roles guard the words, not the binder* stated as a limit; `docs/guide/people-and-devices.md` gains posture; the WF1 spec gains *Component A retired*.
- **Then the closing smoke and the release** — on the four-Mac rig below, plus a **second Apple ID** (WF1's participant-side iCloud review is still unverified); `scripts/census-load-bursts.sh` from this Mac against every Mac's folders; paired Mac + phone release on schema 9 (*a book made on this build starts at 9*); push main and the tag by name, never `--tags`. **Still open for the release task, ask Denver then:** should an OLD build refuse a book with events that has not narrowed anybody?

## The smoke rig (reuse it — it cut Denver's work to sheet presses)

- Macs: the dev app is the root; `./scripts/second-mac.sh [--reset] [--name third|fourth]` launches the others (each its own home, keys and MCP socket, sharing the dev TestWorkspace).
- Drive any Mac over its own socket: `MAUGHAM_MCP_SOCKET="<home>/Library/Application Support/Maugham Dev/mcp.sock" <DerivedData>/Debug/Maugham.app/Contents/MacOS/maugham-mcp`, JSON-RPC on stdin (initialize → notifications/initialized → tools/call). The root's home is `$HOME`. A 15-line wrapper is easy to rewrite; the previous session's lived in its scratchpad.
- Dev-only tools added by the smoke: `test_add_document`, `test_open_document`, `test_close_document` (`Maugham/MCP/Test/Tools/TestDocumentTools.swift`) beside `test_create_project` / `test_open_project` / `test_apply_edit` / `test_flush_autosave` / `test_dump_document` / `test_quit`.
- **Gotchas that cost time:** a stale second-Mac process survives `--reset` and keeps its socket (`lsof -p <pid> | grep mcp.sock`, kill it); the Mac sleeps under a long loop (`caffeinate -i`); the root only asks about strangers whose lines are in chapters OPEN there (F10, until P3c) and **Plan persona loads no chapter** — have Denver in Author (⌘2); a chapter the root's editor has open must not be closed through `test_close_document`.

## First moves for the next session

1. Read the list above. Do not re-derive P3a, P3b or the smoke.
2. `superpowers:writing-plans` for **P3c plan 1**, against the built code, ~10 tasks, first plan built before the second is written (rule 11). Verify every signature at file+line. Posture + Component A's retirement + F10 is a natural first plan; Option A and the phone the second.
3. Subagent-driven build on a new branch off main; opus implementers in **worktrees**, never two sharing a file; per-task opus review; **the most capable model (fable) for the whole-branch review**, with both ledgers, the finds note and a named seam list.
4. Closing smoke on the rig, then the release task (ask Denver the open release question then).

## Process notes that paid in the smoke wave (keep doing these)

- **The whole-branch review found the Critical again** — a husk re-bind the branch's own notices invited, which also existed on the LOCAL trash→restore route all along. Keep giving it the rulings, the ledgers and a seam list, and tell it to assume there is one.
- **My rulings as relayed were half-rules twice more** (F3's "only a Mac holding its own unattributed history" could never fire; Theirs "by position" gave one fault two outcomes). Implementers who were told *check the ruling, not just the code* caught both. Keep that line in every dispatch.
- **Re-read Denver's earlier answers before instructing.** I told an implementer to add a guard his case-2 ruling had already declined; the reviewer caught it.
- **Parallel branches cross silently** — a sync→async signature change in one branch broke a new test in the other with no merge conflict; only the integrated full gate saw it. Always run the full gate after integrating, before any review is called final.
- **Give every agent its own scratch paths** — two reviewers read another agent's `mac.log` from a shared scratchpad and a build hit "build.db is locked".
- Worktrees of this wave's agents and the merged fix branches (`claude/p3b-*`, `worktree-agent-*`) are this session's and merged; they are safe to remove if still present.
