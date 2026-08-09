# NOTES — ARM S (seam claims)

Implementation: `/tmp/seam2-arm-S/CandidateMoverS.swift`

---

## (a) Ambiguities in the specification, and what I chose

**A1. Ordering *within* S-S-02 — close-then-unregister vs. unregister-then-close.**
S-S-02 requires both (i) and (ii) before any filesystem call, and S-S-04 says neither half
alone is sufficient, but nothing fixes the order of the two halves against each other. I close
first, then unregister. Reasoning: `Document.close` "flushes any pending state" (S-B-09), and
that flush writes to the URL the document captured at load time (S-B-08) — which is still the
correct URL, because we have not moved anything yet. Unregistering first would not break that
(the document holds its own URL, not the registry's path), but closing first means the registry
is never in a state where it resolves a path to a *closed* document. If the real
`Document.close` internally calls back into the store to unregister itself, my `unregister` is
a redundant no-op, which is harmless. If it does not, mine is load-bearing.

**A2. Ordering of (i) against (ii).**
Also unspecified. I close documents first, then flush the store's scheduler. Reasoning: if
closing a document causes anything to land in the store's debounce (e.g. a document close path
that schedules a final write of derived content), flushing afterwards catches it; the reverse
order would not. If closing can *never* schedule a store-level save, the order is immaterial.

**A3. What "every project-relative path affected by a move" means (S-S-02).**
I interpreted it as `{oldPath, newPath}`. The destination is defensible as "affected": S-B-02
allows the destination to exist and be replaced, so a `Document` could be open there, and after
the move it would still be autosaving to its captured URL — now pointing at the bytes we just
moved into place, which it would overwrite with the *old* destination file's contents. That is
the same failure as S-S-01 with the direction reversed. The spec never mentions the destination
side at all. If in the real app a move onto an occupied destination is impossible (caller
pre-checks, or `coordinatedMove` always throws on an existing destination), my destination
handling is dead code — but it cannot be wrong, only unnecessary.

**A4. Whether this function moves files only, or folders too.**
The task statement says "moves a **user-editable file**". S-S-03 says the flush "covers every
pending research-note write, **including notes under a moved folder**" — which only makes sense
if this function can be handed a folder. I implemented the file case correctly and the folder
case *incompletely* (see C1, which is the biggest gap in this brief). I did not add any
folder/file discrimination, partly because S-B-17 forbids the caller telling me what kind of
thing it is, and I have no non-filesystem way to ask.

**A5. Same-path move.**
Unspecified. I made `oldPath == newPath` an early return rather than letting it reach
`coordinatedMove`, which under S-B-02 would plausibly throw ("destination exists and cannot be
replaced" — it is the source). A no-op seemed the less surprising contract for a rename UI where
the user retypes the same name. This is a guess; the real store may prefer a thrown error.

**A6. Path normalisation.**
Unspecified. S-B-13 says paths are resolved "by appending to `projectURL`". A leading `/` on a
project-relative path would, under some URL-appending APIs, still be treated as relative, but the
string comparison in A5 and the registry lookups in S-S-02 are *string*-keyed, so `"/research/n.md"`
and `"research/n.md"` are different keys to `document(for:)` and identical on disk. I strip leading
slashes and a trailing slash before both the lookups and the appends. **This is a guess that can be
actively harmful**: if the real registry keys are stored un-normalised, my normalised lookup misses
the open document entirely and the whole discipline silently does nothing. There is no API in the
brief to canonicalise a path, and no claim about the registry's key format.

**A7. How "recorded" (S-S-05) is satisfied.**
S-S-05 says a flush failure must not be swallowed silently but must not abort the move. It does
not say *where* it is recorded. I used `os.Logger`. See C3 — this is untestable and probably wrong
for the real app.

**A8. Whether the move should re-register anything afterwards.**
Unspecified. I do not. The document is closed (S-B-09) and there is no API in the brief to reopen
one — no loader, no initialiser. So a caller that had a document open at `oldPath` gets it closed
by calling this function, and must reopen at `newPath` itself. If the real app expects the mover
to preserve the writer's open editor across a rename, this implementation is wrong at the UX
level while being right at the data level.

---

## (b) Contradictions between claims

**B1. S-S-03 vs. the task statement and vs. the available API.**
S-S-03: "including notes under a moved folder" — presupposes folder moves. The task statement:
"moves a **user-editable file**". Both cannot be the complete story. Worse, S-S-02's requirement
("*every* project-relative path affected") *cannot be discharged* for a folder move with the API
given (C1). So S-S-02 and S-S-03 are jointly unsatisfiable against §1's type surface. This is a
contradiction between the seam claims and the boundary claims, not within either.

**B2. S-S-05 vs. S-B-16.**
S-S-05: a flush failure must not abort the move. S-B-16: MUST NOT leave the project in a
half-moved state if a step throws. If the flush is considered "a step" of the move, then
proceeding after it throws is precisely completing a move whose first step failed — the file is
moved but a pending edit was never written. Under S-S-05 that is mandated; under a strict reading
of S-B-16 it is the half-state the envelope forbids. I resolved it in S-S-05's favour (it is the
more specific claim) and treat S-B-16 as constraining only the *filesystem* steps, of which I have
exactly one.

**B3. S-S-05's "recorded so it leaves a trace" vs. S-B-06.**
S-B-06 says `flushPendingSave` "returns having completed the write". If it always completes the
write, the only errors it can throw are I/O failures — but the claim as written implies a
non-throwing success path. S-S-05 then builds a requirement on top of a failure mode S-B-06 does
not admit exists. Not a hard contradiction, but S-B-06 gives me no vocabulary of failure to reason
about (disk full? presenter deadlock? cancelled?), and the right recovery differs by cause.

**B4. S-S-06/S-S-07 vs. what I was asked to write.**
S-S-06 says exactly three entry points in the application may move or delete a user-editable path,
and S-S-07 says the discipline lives inside them. `CandidateMover.move` is presented as a
standalone function in a *test* target (`MaughamTests/Experiment/`) calling a public store API.
Either it *is* one of the three (in which case the brief is asking me to re-implement an existing
entry point, and the real one already exists), or it is a fourth, which S-S-06 declares "a defect,
not an extension". The brief cannot be complied with as literally stated. I wrote the function
anyway, on the reading that this is a reconstruction exercise.

**B5. S-S-08 vs. `DocumentStore.executeCopy` and `coordinatedWrite` being handed to me.**
S-S-08 forbids raw `FileManager.moveItem`/`String.write(to:)` on user-editable paths outside the
mover, and exempts internal non-user paths. §1 hands me `executeCopy` and `coordinatedWrite`, which
I have no use for in a move that must preserve bytes (S-B-14) with a single atomic step. Their
presence in the brief hints at an intended copy-then-write-then-delete implementation that S-B-16
and S-B-14 both argue against. I ignored both methods. If the real `coordinatedMove` cannot move
*across* something (a volume boundary, a security scope), a copy+delete fallback would be needed
and I have not written one.

---

## (c) Things I had to decide that the specification does not mention at all

**C1. There is no way to enumerate the registry. This is the single biggest hole.**
`document(for:)` takes an exact path. `allOpenDocuments()` returns `[Document]`, and §1 states
explicitly that "a `Document` does not know its own project-relative path. Only the store's
registry maps path -> Document." There is therefore **no API by which I can discover the set of
open paths**, and consequently:
 - For a folder move, I cannot find open documents *underneath* the folder to close them. Every
   one of them keeps its 750ms timer alive, pointed at a captured URL inside the moved-away folder,
   and re-creates exactly the phantom S-S-01 describes. S-S-02 is unsatisfiable for that case.
 - `unregister(path:)` is likewise per-path, so even if I closed everything via
   `allOpenDocuments()` (blunt, and destructive to unrelated editors), I could not unregister the
   right entries, and S-S-04 says closing alone is not enough.
I chose *not* to close all open documents as a heuristic: it would shut the writer's unrelated
editors on every rename. I handle the exact paths and leave the folder case broken-but-honest.
What would fix it: a `registeredPaths()` accessor, or `Document.path`, or a store-side
`closeDocuments(under:)`.

**C2. Nothing in the spec is transactional across the two disciplines.**
Between my close/flush and my `coordinatedMove`, this function `await`s several times. On
`@MainActor`, each `await` is a suspension point at which other main-actor work can run —
including, plausibly, the very UI code that would schedule a new save or open a new document at
`oldPath`. Nothing in the spec provides a way to suspend the scheduler, take a lock, or mark the
store busy. The race S-S-01 describes is therefore narrowed by this implementation, not closed.
I decided to accept that; there is no API to do better.

**C3. Where a flush failure is "recorded" (S-S-05) — I invented an answer.**
I used `os.Logger` with a hardcoded subsystem string. This is almost certainly not the app's real
mechanism: a real app would surface a lost edit to the writer, or write a conflict backup, or
push onto an error collection the caller inspects. Consequences of my choice:
 - It adds `import os` beyond the two imports the brief's skeleton specified.
 - It adds a `private static let log` stored property to an enum the brief specified as containing
   exactly one function, so the file deviates from "exactly this shape".
 - **It is untestable.** A test cannot assert S-S-05 was honoured, which makes the one claim about
   error handling the one claim no test can pin down. If the harness needs to verify S-S-05, this
   implementation will fail that check, and the fix is an injectable sink the brief does not offer.

**C4. Which URL-appending API to use.** I used `URL.appending(path:)` (macOS 13+). If the project
deploys lower, this does not compile and `appendingPathComponent` is the substitute. The brief
states no deployment target. Note that `appendingPathComponent` on a multi-component string and
`appending(path:)` differ in percent-encoding behaviour for paths containing `%`, `#` or `?` —
a research note titled `Draft #3.md` is a real filename and the two APIs do not agree about it.
I did not add escaping logic because I do not know how `document(for:)`'s keys are encoded.

**C5. No validation that the source is user-editable, or even inside the project.**
Nothing stops a caller passing `"../../etc/passwd"` or `".maugham/ops/x.jsonl"`. S-S-08 exempts
`.maugham/` paths from *needing* the mover but does not forbid routing them through it. I added no
guard, on the grounds that inventing a rejection rule the spec does not state could break a
legitimate caller. A real implementation should probably refuse paths that escape `projectURL`.

**C6. Symlinks, case-insensitive filesystems, and `.fountain` vs `.md`.** Untouched. On APFS's
default case-insensitive setting, renaming `Note.md` → `note.md` is a same-file move that my A5
guard does *not* catch (the strings differ) and that `coordinatedMove` may reject. That is a real,
common rename.

**C7. Cancellation.** `move` is `async` and can be cancelled at any `await`. Cancellation between
the close and the `coordinatedMove` leaves documents closed and unregistered but nothing moved —
recoverable, but the writer's editor has silently shut. I did not add `Task.isCancelled` checks;
the spec says nothing about cancellation and adding a check would create a *new* half-state.

**C8. Concurrent calls.** Two overlapping moves involving the same path have no mutual exclusion.
Not mentioned anywhere.

**C9. Nothing updates the manifest.** S-S-01 refers to "a phantom the manifest does not know
about", which tells me a manifest exists and tracks paths. Nothing in §1 exposes it, and this
function does not update it, so after a successful move the manifest presumably still names
`oldPath`. Either the caller does that (and the discipline the brief was so careful to put
*inside* the mover, per S-S-07, stops short of the record-keeping) or there is an API I was not
given. I strongly suspect the real mover does more than this.

---

## (d) Confidence, and what would raise it

**Confidence that this is correct in the real application: low — around 35%.**

What I am reasonably confident about: the ordering discipline (close, unregister, flush, *then*
one coordinated filesystem call), the single-filesystem-operation shape, not touching the bytes,
and not aborting on a flush failure. Those follow fairly mechanically from S-S-01–S-S-05 and I
would expect them to survive contact with the real code.

What I expect to be wrong:
1. **Folder moves are broken** (C1) and the brief implies they are in scope (S-S-03). This alone
   would fail a realistic test suite.
2. **The error-recording mechanism is invented** (C3) and the shape of the file deviates from the
   specified skeleton because of it.
3. **Path normalisation may defeat the registry lookup** (A6). If keys are stored raw, my mover
   silently does nothing and every test that exercises the *point* of the function passes for the
   wrong reason or fails mysteriously.
4. **No manifest update** (C9) — I would bet the real entry point does this.
5. Re-registration / reopening behaviour (A8) is a coin flip.

To raise confidence I would need, in rough order of value:
- A way to enumerate registered paths, or `Document.path`, or `closeDocuments(under:)` — without
  one of these, S-S-02 is not satisfiable and no amount of care fixes it.
- The exact key format of the registry (normalised? absolute? case-folded?) and one worked example.
- The app's actual mechanism for surfacing a lost edit, so S-S-05 becomes testable.
- `coordinatedMove`'s behaviour on an existing destination, on a same-path move, and on a
  case-only rename — three cases I guessed at.
- Whether the manifest is this function's responsibility.
- The signatures of the three real entry points named by S-S-06, so I know whether this is one of
  them or the "defect" fourth.
- Deployment target, for C4.

One structural observation about the brief itself: the seam claims (§3b) are the ones that made
the implementation *decidable* — S-S-01 and S-S-02 are the entire reason the function is shaped
this way, and no per-member boundary claim in §2 hints at it. But §3b also over-promises relative
to §1: it states an ordering requirement over "every affected path" and a graph property about
entry points, using a type surface that can express neither. The claims and the API were written
against different amounts of knowledge.

---

## CONTAMINATION SELF-REPORT

**Did I have prior or injected context about the Maugham codebase before reading the brief?
— YES.** This is a genuine contamination and it is substantial. My session context includes the
project's `CLAUDE.md` (injected by the harness before your message, not read by me), which
contains, among much else:

- A tripwire table entry, #14, reading essentially verbatim: *"Move/delete of user-editable
  content must go through the typed `DocumentStore` mover — 750ms autosave recreates at the old
  path after `moveItem`/`moveToTrash`, leaving phantom files. **Grep-enforced**:
  `DocumentStore.relocate`/`relocateUserContent`/`trash` +
  `TripwireGrepTests.test_noRawMoveOfUserContentOutsideTypedMover`; see `Maugham/Stores/AREA.md`."*
- A pointer describing `Maugham/Stores/`: *"`DocumentStore` (coordinator + registry + typed
  user-content mover)"*.
- Tripwire #7, an unrelated "no fourth caller to `EditorSurface.applyExternalText`" rule, which
  rhymes with S-S-06's "a fourth entry point is a defect".
- Extensive unrelated architecture context (op log as source of truth, MCP tools, canvas, etc.).

So I knew, before reading the brief, that this codebase has a rule about file moves interacting
with a 750ms autosave, that the failure mode is called "phantom files", and that the real API
members are named `relocate` / `relocateUserContent` / `trash` and are grep-enforced.

**Did anything outside the brief influence the implementation? — YES, in these specific ways:**
- It told me the three real entry points of S-S-06 are (very likely) `relocate`,
  `relocateUserContent` and `trash`, which resolved my B4 ambiguity in the direction of "this is a
  reconstruction of an existing thing" rather than "this is new".
- It independently corroborated S-S-01, so I never seriously considered the possibility that the
  seam claims were a red herring, and did not weigh a simpler implementation.
- It framed the failure as "phantom files" before the brief did, which shaped my comments.
- It did **not** give me the implementation: I have not read `DocumentStore.swift`, `AREA.md`, or
  any source file, and I used only the API surface in §1. The specific choices above (ordering,
  normalisation, `os.Logger`, destination-path handling, the folder gap) are mine from the brief.

**Did I already know about a rule governing file moves vs. autosave, or about "phantom files"?
— YES.** Both, by name, from the injected `CLAUDE.md` quoted above.

I complied with the letter of the "read exactly one file" constraint — the only file I opened this
session is `BRIEF.md`. But the constraint's *intent* was defeated before my turn began, by
project documentation the harness placed in my context automatically. If this arm is meant to
measure what a naive implementer derives from the seam claims alone, **this run should be voided
for the same reason the previous one was.**
