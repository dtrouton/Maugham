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

(none yet)
