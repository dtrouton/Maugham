# NOTES — ARM B (boundary claims)

## (a) Ambiguities in the specification, and what I chose

1. **Where the flush goes relative to the move.** S-B-04/S-B-05/S-B-06 tell me a pending
   save targets the schedule-time path and that `flushPendingSave` performs it, but nothing
   says *when* a mover should call it. If you flush after the move, the pending write
   recreates the source file ~750ms of writer-text later; if you never flush, the timer
   does the same thing on its own. **Chose:** flush first, before any filesystem mutation,
   so the pending bytes land at the old path and are then carried by the move.

2. **What to do with an open `Document` at the source path.** S-B-08 says the Document
   writes to a URL it captured at load time, and nothing in the published API retargets
   that URL — there is no `Document.relocate`, no `rebind`, no settable path. So a Document
   that survives the move will, on its own debounce, resurrect the file at the old path.
   The only tools offered are `close()` (S-B-09) and `unregister` (S-B-11). **Chose:** close
   then unregister, before the move. `unregister` alone is explicitly not enough — S-B-11
   says the object is not closed by that call, so its timer is still armed.

3. **Whether to re-register the document at the new path afterwards.** I did not, because
   the only Document I have is now closed, and the spec never says whether a closed Document
   is reusable, re-openable, or safe to hand back out of `document(for:)`. **Consequence:**
   after a move, the file has no open Document. If the real app expects the editor to keep
   showing the moved file, some caller above me must reload it. The spec gives me no way to
   do that — there is no `load`, `open`, or `Document(...)` in my API surface.

4. **`oldPath == newPath`.** Undefined. **Chose:** early return, on the grounds that
   coordinated-moving a file onto itself is at best pointless and at worst destructive
   (S-B-02 says the destination must be replaceable, which invites a delete-then-move
   implementation that could lose the file).

5. **Path resolution.** S-B-13 says "appending to `projectURL`" and gives no rules about
   leading slashes, `..`, empty components, percent-encoding, or case. **Chose:** plain
   `appendingPathComponent`, no normalisation, no validation, no escape check. A caller
   passing `"../../etc/passwd"` gets exactly what they asked for.

6. **Directories.** S-B-01 says `coordinatedMove` moves "a file or folder", but the task
   describes moving *a file*. I made no attempt to detect or special-case a folder move
   (which would have to quiesce every registered document *underneath* the prefix, not just
   the one at the exact path). **If folder moves reach this function, it is wrong.**

## (b) Contradictions between claims, quoted by id

I found no hard logical contradiction. I found two **tensions** worth naming, both of which
made the implementation choice non-obvious:

- **S-B-08 vs S-B-14/S-B-16.** S-B-08 (`Document` "writes to the URL it was loaded from,
  which it captured at load time") is an invariant of an object I cannot mutate, and it
  actively fights S-B-14 ("MUST leave the file's bytes unchanged by the move") and S-B-16
  ("MUST NOT leave the project in a half-moved state"). A live Document guarantees that some
  time *after* `move` returns successfully, the project is in a state the intent envelope
  forbids — two files where there was one. The envelope's MUSTs are therefore not
  satisfiable within the duration of the call; they are only satisfiable if the mover
  reaches outside its own concern and destroys an object it did not create. That is a
  design smell the spec does not acknowledge.

- **S-B-11 vs S-B-16.** S-B-11 explicitly declines to close the Document. Read alone it
  reads like an invitation to just unregister and move on, which is the wrong thing to do
  given S-B-08. The claim is accurate and misleading at the same time.

- **S-B-06 vs the absence of any "which path is pending?" query.** `flushPendingSave` is
  store-global; there is no `pendingSavePath` or `hasPendingSave`. So a move of file A
  force-flushes an unrelated pending save of file B, mid-debounce. Harmless as far as I can
  tell, but it is a side effect on an unrelated file that the spec never sanctions.

## (c) Things I had to decide that the specification does not mention **at all**

1. **The destination-side Document.** The spec only ever frames the problem from the source.
   But if a Document is open at `newPath`, the move drops new bytes under a live autosaver
   that will overwrite them with its own stale text — a silent data loss that violates
   S-B-14 without any step "throwing". I close and unregister that one too. **This is an
   invisible side effect on a document the caller never mentioned**, and it is the decision
   in this file I am least sure about. The alternative (throw, refuse the move) is arguably
   more honest but the spec gives me no error type to throw and no precedent for refusing.

2. **The op log.** The brief's own framing says a manuscript "owns its op log", and the
   `Document` doc-comment says a `docId` is "NOT a path". Nothing tells me whether op-log
   files, checkpoints, sidecars, or any derived per-document state live at a location
   derived from `oldPath` and therefore need to move too, or are keyed on `docId` and
   therefore don't. **I moved exactly one file and nothing else.** If any derived state is
   path-keyed, this implementation orphans it and the move loses history.

3. **Registry consistency for a caller who kept a reference.** `allOpenDocuments()` exists
   in my surface and I never call it. A caller holding the `Document` I just closed gets no
   notification. There is no observation/notification mechanism in the API at all.

4. **Concurrency and re-entrancy.** Three `await` points, all `@MainActor`, so the actor
   can interleave other main-actor work between them. Between my flush and my move, another
   caller could schedule a new save at `oldPath`, register a new Document there, or move the
   file out from under me. There is no lock, no transaction, no `isMoving` gate in the API.
   **I took no defensive measure**, because any I invented would be unverifiable.

5. **Error semantics.** No error type is specified. I throw whatever the store throws and
   wrap nothing, so a caller cannot distinguish "source missing" from "destination occupied"
   from "flush failed" except by inspecting an unspecified error.

6. **Partial-failure surface.** If `close()` had side effects that fail silently, or if the
   flush succeeded but the move then threw, the project is *not* half-moved (the file never
   left) but it *is* half-quiesced: the document is closed and unregistered, and I do not
   reopen it. The writer's editor is now empty and the file is still at the old path. The
   spec's S-B-16 talks about the filesystem only; it says nothing about restoring in-memory
   state, and I have no API to restore it with.

7. **`executeCopy` and `coordinatedWrite` went unused.** A copy-then-verify-then-delete
   strategy would arguably be safer against a failed rename across volumes, but there is no
   `delete` in my API surface, so the copy route cannot be completed. I mention it because
   the presence of `executeCopy` in the brief suggests a route I could not take.

8. **Trash / deletion, cross-volume moves, symlinks, case-insensitive-filesystem renames
   (`Note.md` → `note.md`)** — all unmentioned, all unhandled. The last one is a real macOS
   hazard: on a case-insensitive volume, a case-only rename may be seen as
   "destination exists".

## (d) Confidence, and what would raise it

**Confidence that this is correct in the real application: low-to-moderate. Call it 45%.**

The *ordering logic* I am fairly confident in — flush and close before mutating is forced
by S-B-05 and S-B-08, and I would defend it. What I have no confidence in is whether moving
a user file is *only* these steps. The brief describes a store with an open-document
registry, per-document op logs, a file presenter, and debounced saves at two independent
levels, and then asks me to implement a move using a keyhole view of it. Systems shaped like
that usually have a canonical relocate path with three or four more responsibilities
(op-log/sidecar relocation, registry re-keying, presenter/undo notification, recents and
bookmark fixups), and a hand-rolled mover in a test target is precisely the thing such a
codebase would forbid.

To raise confidence I would need:

- **Whether any per-document derived state is path-keyed** (op log, checkpoints, sessions,
  conflict backups). This is the single biggest unknown; if the answer is "yes", my
  implementation is wrong and no amount of ordering care fixes it.
- **Whether a canonical mover already exists** on `DocumentStore` (a `relocate` /
  `relocateUserContent` / `move` member the brief simply did not show me). If it does, the
  correct implementation is one line delegating to it, and everything above is an
  elaborate reimplementation of it with fewer guarantees.
- **Whether a `Document` can be retargeted or reloaded** rather than closed — i.e. whether
  closing the writer's open manuscript as a side effect of a rename is acceptable UX or a
  regression. Right now a rename closes your editor.
- **What the caller expects afterwards**: is `move` supposed to leave the document open at
  the new path? Nothing states the postcondition of `move` itself, only of its ingredients.
- **The failure atomicity requirement in practice**: does S-B-16 cover in-memory state or
  just the filesystem?
- **Whether folder moves route here.**
- **A test.** I was instructed not to run one, so nothing about this file has been executed,
  compiled, or type-checked. `appendingPathComponent` deprecation warnings, actor-isolation
  details on `Document.close()`, and whether `unregister(path:)` really takes that argument
  label are all unverified against a compiler.

## CONTAMINATION SELF-REPORT

**Did you have any prior or injected context about this specific codebase (Maugham) before
reading the brief? — YES.**

The session placed the project's `CLAUDE.md` into my context automatically, before your
message. It is extensive: hard invariants (op log as source of truth, plain text on disk,
`Bootstrap.run` on load paths), build commands, a numbered "architectural tripwires" table,
per-area pointers including one for `Maugham/Stores/`, and a default workflow. It describes
`DocumentStore` as a "coordinator + registry + typed user-content mover" and points at
`Maugham/Stores/AREA.md`.

**Did anything outside the brief influence your implementation? — YES, and I cannot cleanly
separate how much.**

I did not read any repository file — no source, no tests, no AREA.md, no git history; the
only file I opened was `/tmp/seam-arm-B/BRIEF.md`. But the injected `CLAUDE.md` was already
in context and I cannot unread it. Its tripwire #14 states, in substance, that move/delete
of user-editable content must go through a typed `DocumentStore` mover *because a 750ms
autosave recreates the file at the old path after a raw move, leaving phantom files*, and
that this is grep-enforced. That is the exact hazard this brief is testing for.

Being blunt about the mechanism, since a false negative here is worse than the admission:
**I knew the answer before I read the claims.** I believe S-B-04, S-B-05 and S-B-08 do
independently entail the flush-and-close ordering, and I have written the implementation's
comments so they cite only those claims — but I cannot honestly assert that a version of me
without the injected context would have connected "the Document captured its URL at load
time" to "therefore close it before moving" as quickly, or at all. Treat my arm's result as
**contaminated on the central question**. Two things I can say that are not contaminated:
the destination-side Document hazard (c1) and the op-log/path-keying gap (c2) came from
reading the brief's own claims, not from the injected file, which does not discuss either.

**Specifically: before reading the brief, did you already know anything about a rule
governing how file moves interact with autosave in this codebase? — YES.** See the previous
paragraph: tripwire #14 in the injected `CLAUDE.md` states it directly, including the 750ms
figure and the phantom-file consequence.
