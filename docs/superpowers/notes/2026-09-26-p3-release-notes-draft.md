# P3 release notes — DRAFT (signed op log P3: roles, scope, the collaborator)

Drafted 2026-09-26 by P3 plan 3's Task 9, from the release-note sections of
`2026-09-17-signed-op-log-p3-handoff.md` (P3a, P3b, P3c plans 1 and 2) plus plan
3's own. **Task 10 (the release) copies these into
`docs/release-notes/v0.X.Y.md` and `docs/release-notes/phone/v0.Y.Z.md`**, fills
the version numbers and dates, and adds anything the closing smoke's fix wave
changes. The expected pair is Maugham **0.41.0** with MaughamPhone **0.14.0**
(the last pair was 0.39.0 / 0.13.0, and 0.40.0 was Mac-only). Confirm that
against the tags at cut time.

This is a **paired release**: the Mac and the phone ship together, on
schema 9.

---

## Mac — `docs/release-notes/v0.X.Y.md`

```markdown
# Maugham 0.X.Y

_Released YYYY-MM-DD_

Roles. Everybody you admit to a book can now be given a permission of their
own: an **author of the whole book**, an **author of some pieces** (the pieces
you name), or a **reviewer** who leaves notes and writes no prose. You set it
when you admit them, and change it later from **People & Devices** with
**Change…**. Every Mac and iPhone on the book honours it: a line somebody wasn't
allowed to write is held rather than applied, and nothing is ever deleted.
(ADR 0032's P3 addenda; spec
`2026-09-19-signed-op-log-p3-roles-scope-collaborator-design.md`. Pairs with
MaughamPhone 0.Y.Z. **Update every Mac and iPhone on a shared book together.**)

## What's new

- **Permissions per person.** The admission panel asks what the newcomer may
  write, and People & Devices can change it (Change…, Re-admit). What somebody
  wrote is judged by the permission they held when they wrote it, so a later
  demotion never reaches back into chapters they wrote as an author.
- **A reviewer's Mac offers only what the book will take.** Verbs a permission
  doesn't allow are hidden, and refused if reached some other way. ⌘S still
  flashes there. The File menu's New Prose Story, New Screenplay and Link
  Existing Project are greyed for anybody who is not an author of the whole
  book.
- **An author of some pieces can start a piece of their own** and write in it
  straight away. The book's author is asked whether it's theirs (*Sam started
  "The Orchard" — is it theirs?*). Until then the book author's Mac keeps out
  of the piece, with **Edit Anyway** beside it.
- **A reviewer can restore a note they deleted themselves**, on the Mac and on
  the iPhone.
- **A participant on a read-WRITE iCloud share is no longer locked as a
  "reviewer".** What she may write is her permission. A read-only share still
  locks the editor, because the file system won't take the write.
- **History shows what is waiting and why** — a machine you haven't admitted, a
  permission that doesn't cover the line, or a Mac nothing in the book signs
  for — and offers **Send to Inbox** for held paragraphs, so the words can
  always come back.
- **A book that is missing part of a device's history says so**, in History,
  and **Acknowledge** puts it down.
- **People & Devices says what unblocks a stranded piece.** If a Mac that
  started pieces is gone (lost, wiped, restored as a new machine) without being
  revoked, its pieces wait on every other Mac. The Mac that admitted it now
  says *N pieces are waiting for this Mac. If it is gone for good, revoke it
  and they will open.*
- **The admission panel counts every chapter**, including ones you don't have
  open. They are read just after the project opens, so the number can rise
  once, a few seconds in. It can also appear before a newcomer has written
  anything, and only on the Mac that holds the book.
- **A successful labelled checkpoint (⇧⌘S) now flashes**, like ⌘S.

## Fixes

- **The `.md` beside each chapter now follows sync and permission changes.**
  It used to lag until you next typed in that chapter. After another Mac's
  changes arrive, or after an admission, a revocation or a change of
  permission, the `.md` on disk is rewritten to match the draft. A chapter that
  is holding lines back does not rewrite its `.md` on its own account; it waits
  until they are let in, or until you type.
- **Two Macs that see a chapter differently no longer trade its `.md` without
  end.** When one Mac holds lines another has let in, each renders the `.md`
  differently. With the chapter open on both, they used to overwrite each
  other's `.md` for as long as it stayed open, saving a backup each time. Now
  each Mac gives up after a couple of rewrites and leaves the other's `.md` in
  place until you type there again. Your words are never at risk either way:
  the draft lives in the history, and the `.md` is only a copy of it.
- **Unsealed writing from a device this book doesn't know now waits for
  admission** like the rest of its history. Before, everything such a device
  had written since its last seal was applied. Nothing is lost: admitting the
  device applies all of it on the next read.
- A Restore beaten by another Mac's clock now says *Another device deleted
  this note after you restored it. Restore it again to keep it.* rather than
  *not permitted* — where restoring it again would work. Where the later
  Delete is one you may not undo, the ordinary sentence stands and Restore is
  not offered.
- Rewind's preview of a closed chapter now matches what opening it would show.

## Known issues

- **A book made on this version starts at schema 9, and the first narrowing
  raises an existing one.** Older versions of Maugham can't open a narrowed
  book — which is the point.
- **Update every Mac on a shared book.** An older Mac can still open a book
  that nobody has narrowed yet. If it already has the book open when you
  narrow somebody, it keeps writing as before until you close the book on that
  Mac, and an older Mac rewriting the book's structure forgets which Mac
  started each piece. Updating every Mac and iPhone together avoids both.
- Permissions guard the *words*, not the binder. Adding, renaming, moving and
  trashing documents aren't signed; a Mac that doesn't allow them only hides
  them.
- A Mac with no Secure Enclave, or one nobody has admitted, is not told when a
  book is narrowed. What it writes afterwards waits on every other Mac.
```

---

## Phone — `docs/release-notes/phone/v0.Y.Z.md`

```markdown
# MaughamPhone 0.Y.Z

_Released YYYY-MM-DD_

The iPhone now follows each book's permissions. Pairs with Maugham 0.X.Y —
**update the Mac and the phone together.**

## What's new

- **The phone offers only what your permission allows.** A reviewer's phone
  offers no Accept, Reject, Archive or Reopen. Capturing to the Inbox works on
  every permission.
- **Settings → This device says what this phone may write in each book**, in
  the Mac's own words, and updates when the Mac changes it.
- **A reviewer can restore a note they deleted themselves**, and a restore
  made on the Mac shows here.
- In a piece somebody else started that the book's author hasn't settled yet,
  a book author's phone keeps its hands off: *settle it from your Mac.*

## Fixes

- A note's buttons now redraw from the phone's fresh answer even when a write
  fails, so a button the book would refuse is no longer left showing.

## Known issues

- A book made on this version starts at schema 9. Older versions of the phone
  can't open a narrowed book.
```

---

## Before the cut (from the handoff and `docs/RELEASING.md`)

- Run `scripts/census-load-bursts.sh` from this Mac against every Mac's
  folders; it does not walk hidden directories, so name any project folder
  inside one directly.
- Stash the three untracked agent-config entries (`git stash -u`), or the cut
  refuses a dirty tree.
- Push main, then each tag **by name**. Never `--tags`.
