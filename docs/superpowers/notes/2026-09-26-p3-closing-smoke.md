# Signed op log P3 — the closing smoke (checklist, 2026-09-26)

The checklist for P3 plan 3's **Task 10**
(`docs/superpowers/plans/2026-09-26-signed-op-log-p3-plan3-carries-smoke-release.md`),
run by the controller with Denver before the paired release. It covers P3a–P3c
whole plus plan 3's carries. Record each find under **Finds** as it happens.
**Every find gets a regression pin and a fix on a branch, and the re-smoke
passes, before release.**

## The rig

Four Macs on this machine, plus the second Apple ID for the iCloud share.

```sh
# Build the Maugham scheme (Debug) in THIS checkout first; the rig finds this
# tree's DerivedData by its recorded workspace path, never the newest folder.
./scripts/second-mac.sh --reset                  # B — its own home, ~/.maugham-second-mac
./scripts/second-mac.sh --reset --name third     # C — ~/.maugham-third-mac
./scripts/second-mac.sh --reset --name fourth    # D — ~/.maugham-fourth-mac
# A is the dev app itself (the root). Drop --reset to keep an identity between runs.
```

- **Cast** (as in the P3b smoke): **A** = the dev app, the root, Denver. **B** =
  Sam. **C** = Ren. **D** = Kit. Use a fresh book under `TestWorkspace/` (every
  home symlinks the dev `TestWorkspace`, so `test_open_project` opens it by name
  on every Mac).
- **Driving B, C and D over MCP:** point the built bridge at each home's socket,
  e.g. `MAUGHAM_MCP_SOCKET="$HOME/.maugham-second-mac/Library/Application Support/Maugham Dev/mcp.sock" <DerivedData>/Build/Products/Debug/Maugham.app/Contents/MacOS/maugham-mcp`
  (`scripts/maugham-test-mcp.sh` is the same bridge for A's socket). The dev-only
  tools `test_add_document`, `test_open_document`, `test_close_document` and
  `test_apply_edit` (the typing surrogate) are the rig's hands. Denver presses
  A's sheets and panes.
- **A gate while the dev app is open used to delete its MCP socket.** It no
  longer does (2026-09-06), but relaunch the dev app after any gate from an
  older build.
- **The iPhone:** a reviewer's phone on the same book (Settings → This device
  shows its code and role line).

## Checklist

### Option A, end to end
- [ ] Sam starts a piece on B. Her second Mac waits (*Waiting for this piece to
      arrive.*), then applies her words.
- [ ] The root (A) waits (*Waiting for this piece to arrive from Sam.*), then
      asks *Sam started "…" — is it theirs?* **Theirs** brings her words in on
      every Mac, and her waiting line goes with no reopen.
- [ ] A **Duplicate of a group** mints each copy's opening on the Mac that made
      it (note how long a large group takes; the main-actor mint is a stated
      limit).
- [ ] **Ruling U:** the root presses *Not now*, opens the piece, and sees *Sam
      started this piece — it isn't settled whose it is yet.* The editor takes
      no typing. **Edit Anyway**, then type: her words are set aside on BOTH
      Macs and kept in History.
- [ ] **Task 4 — the yield lifts on the re-read:** with the root yielding,
      another book author (Kit, admitted as a whole-book author) writes in the
      piece. The root's open window stops yielding when his text arrives, with
      no reopen and no trust change.

### Permissions
- [ ] **A co-author** (whole book) writes anywhere, and every Mac applies it.
- [ ] **An author of some pieces** is refused outside hers (the standing line
      says so; the verbs are hidden).
- [ ] **A reviewer:** restores her own deleted note on the Mac, and the phone
      shows it restored. Restore of somebody else's note is not offered.
- [ ] **A demotion while she is typing** (`test_apply_edit` every few seconds,
      then Change… → Reviewer): lines after the demotion are set aside, lines
      before it applied; her editor locks at the refresh.

### The phone
- [ ] A reviewer's phone offers no Accept, Reject, Archive or Reopen, and still
      captures to the Inbox.
- [ ] Settings' role line changes after **Change…** on the Mac (on foreground or
      pull).

### Held lines and their doors
- [ ] **Both Send to Inbox doors** — a set-aside record's, and a held span's —
      bring the paragraphs into the Inbox, and a second press offers nothing
      left.
- [ ] **A truncated file:** cut one of Sam's streams by some lines. History's
      loss drawer says her history is shorter; **Acknowledge** puts it down, and
      a marking verb (Change…) then works.
- [ ] **A later narrowing on a book with an enclave-less Mac** (Ruling Q): the
      second narrowing carries the first's photograph forward, and the unsigned
      Mac's post-photograph lines stay held, not more and not fewer.

### Plan 3's carries
- [ ] **Task 3:** a stranger writes only in a CLOSED chapter. The root opens the
      book with no chapter open; the admission sheet appears and counts those
      lines (the count may rise once, seconds after open), and it does not ask
      twice. People & Devices lists the stranger as pending.
- [ ] **Task 4:** after the admission, the derived `.md` ON DISK holds the
      admitted text (open it in a text editor), for an open chapter at once and
      for a closed one at its next open.
- [ ] **Task 8:** a stranded piece. Sam (admitted by A) starts a piece on B, then
      B stops (quit it; do not revoke). On A, Sam's row in People & Devices says
      *1 piece is waiting for this Mac. If it is gone for good, revoke it and
      they will open.* Revoke Sam; the piece opens on A.

### Outside the rig
- [ ] **WF1:** participant-side iCloud review on the second Apple ID. It has
      been unverified since WF1.
- [ ] **The load-burst census**, from this Mac against each Mac's folders:
      `scripts/census-load-bursts.sh ~/Documents "$HOME/Library/Application Support/Maugham Dev/TestWorkspace"`
      (the rig's four Macs share that TestWorkspace), plus every other Mac's
      folders reached over a file-sharing mount or as a copy. It does
      not walk hidden directories, so name a project folder inside one
      directly. Give Denver the output; a hit is a per-line manual recovery.

## Finds

- **R1 (rig, not product) — B, C and D do not see changes live.** Their homes reach the book through a symlinked `TestWorkspace`, and their open windows did not pick up A's or each other's pieces, op-log files or manifest writes until relaunched (C and D kept a three-chapter outline after B added four pieces; B's open Sams Third kept Sam's words after the root wrote there, and showed the root's text on reopen). A, on the real path, saw everything live. Worked around by relaunching. A real Mac on iCloud has no symlink; the rig could open by the resolved path.
- **F1 — the load question says "Sam started \"Chapter 1\"" for a piece the ROOT started.** Chapter 1 was made with the book on A (`startedBy` = A), never opened there, so it had no op log. Sam (author of Two only) wrote in it. A asked *Sam started "Chapter 1" — is it theirs?* The wording is false (the manifest names A as the starter), and whether it should be a question at all is open: her line is outside her scope in a piece whose recorded starter is this Mac.

  **DENVER RULED (2026-09-26): refuse, don't ask.** A piece whose manifest records a starter that is not her is outside her scope: her line is set aside like any out-of-scope line (History, Send to Inbox). The §4.5 question is asked only for a piece SHE started, or a legacy piece with no recorded starter.
- **O1 — a demoted writer who keeps typing costs one conflict backup per arrival** on the holding Mac (Probe: 20, the cap). **DENVER RULED: keep it** — bounded, and it is evidence.
- Not run this round (Denver, 2026-09-26): the phone items, WF1's second Apple ID, the held-span Send to Inbox door (F1 blocked it), Ruling Q (no enclave-less Mac in the rig), a reviewer's restore on C's window. Left to their tests.

## Passed so far

- Task 3: the admission sheet counted Kit's two paragraphs in the closed chapter Three ("2 paragraphs waiting in \"Three\"") and did not ask twice.
- Option A: Theirs brought Sam's words in (Sams Piece, and Sams Second by accident).
- Ruling U: Not now → the yield line and a locked editor; Edit Anyway + typing set Sam's words aside, in History (Sams Third); on B they were set aside on reopen (R1).
- The Critical's fix, live: Sam typed five times while A held Sams Second open — no new conflict backups, the `.md` held her words.
- Task 4: the root's yield on Sams Fourth lifted, without a reopen, when Kit's text arrived.
- Sam's scope: her line in Two (hers) applied on A.
- Send to Inbox from a set-aside record (Sams Third): brought her paragraph in; a second look offered nothing.
- A demotion while Kit typed (Probe): lines after 36 stopped on A, earlier ones stayed.
- A truncated stream (Sam's Two, 8 → 4 lines): History's loss drawer; Change… refused before Acknowledge and worked after.
- Task 8: Sams Stranded (ops removed) waited on A; Sam's row said *1 piece is waiting for this Mac…*; after Revoke it opened.
- Duplicate of a group on A: fast; the copies opened.
- The load-burst census on this Mac: 32 projects, 226 files, nothing unreadable, no load bursts under a non-author actor.
