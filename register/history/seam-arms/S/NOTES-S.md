# NOTES-S — implementing `CandidateMover.move(from:to:in:)` from the ARM S brief

## (a) Ambiguities in the specification, and what I chose

**a1. "Every project-relative path affected by a move" (S-S-02) is not enumerable with the given API.**
This is the largest ambiguity and it interacts with a2. S-S-03 explicitly contemplates "notes under a
moved folder", which means the spec anticipates that a move can affect paths *other than* `oldPath`.
But the `DocumentStore` surface offers no way to enumerate them: `document(for:)` is exact-match,
`allOpenDocuments()` returns `[Document]`, and `Document` has "no knowledge of its own
project-relative path" (S-B-08 scope note / `docId` doc comment). So there is no `Document -> path`
direction, and therefore **no way to close the documents open beneath a moved folder**. I implemented
exact-path quiescing only (source and destination) and am flagging the folder case as unimplementable
from this brief. If the real store has a `registeredPaths` accessor, or `document(for:)` has a prefix
variant, or `Document` exposes a URL, the correct implementation is different from mine.

**a2. Is this function ever asked to move a folder at all?**
The prose says "moves a **user-editable file** (a manuscript `.md`/`.fountain`, or a research note)",
and `coordinatedMove`'s doc comment says "a file **or folder**", and S-S-03 mentions notes under a
moved folder. I chose to treat the parameter as possibly-a-file-only (per the prose) while noting
that if folders are in scope the implementation is incomplete per a1. I did **not** add a
`isDirectory` probe, both because a bare `FileManager` probe is a read rather than a mutation
(S-B-15 constrains mutation) and because I have nothing useful to do with the answer given a1.

**a3. Whether the destination path needs quiescing at all.**
S-S-02 says "every project-relative path affected by a move". A move affects two paths. A `Document`
open at `newPath` captured the destination URL at load time (S-B-08) and would autosave its stale
text over the freshly-moved bytes. I chose to close and unregister at `newPath` as well. The spec
never says this explicitly, and every sentence of S-S-01 is phrased in terms of the *old* path
("re-creating a file at the OLD path"), so a strict reading of S-S-01 covers only the source. I went
with the broader reading of S-S-02. **If the intended behaviour is source-only, my implementation
closes a document the user still has open, which is a visible behavioural difference, not a
no-op.**

**a4. Ordering between "close and unregister" and "flush".**
S-S-02 requires both before any filesystem call but does not order them relative to each other. I
close first, then flush, on the reasoning that if closing a `Document` causes anything to land in the
store's scheduler, the subsequent flush drains it; the reverse order would leave that write pending.
I have no evidence `Document.close()` touches the store's scheduler — S-B-09 says only "cancels the
document's timers and flushes any pending state" — so this is a guess in the safe direction.

**a5. "Recorded" in S-S-05 is not defined.**
"MUST NOT be swallowed silently either; it is recorded so a lost last-edit before a move leaves a
trace." No logging facility, error-collection sink, error type, or diagnostics surface is in the
brief's API list. I used `os.Logger` with a made-up subsystem string. This will compile but is almost
certainly not how the real app records anything, and the subsystem/category are invented. If the real
codebase has a shared logger, an error-accumulator, or a user-visible alert channel, the correct
implementation uses that.

**a6. Whether a flush failure should surface to the caller after the move succeeds.**
S-S-05 says it must not abort the move. It does not say whether it should be rethrown *after* the
move, returned, or only logged. Rethrowing after a successful move would tell the caller "the move
failed" when it did not, which seems worse, so I only log. A design that returned a
`MoveOutcome`/diagnostic value would satisfy the claim better, but the signature is fixed by the
brief and returns `Void`.

**a7. `Document.close()` is `async` and non-throwing, so a failed final flush inside it is
invisible here.** S-B-09 says it "flushes any pending state before returning" with no failure mode. If
the document's own final write fails, S-S-05's "leave a trace" spirit is violated and I cannot detect
it. I did nothing about this.

**a8. Whether the moved document should be reopened/re-registered at the new path.**
The spec is silent. `Document` exposes no reload/reopen and `DocumentStore` exposes no load, so I
cannot reopen it even if it were wanted — I can only `register(document:for:)` the *same* `Document`
object at the new path, which would be wrong: S-B-08 says the document writes to "the URL it was
loaded from, which it captured at load time", so re-registering the closed old object under the new
path would map the new path to an object still pointed at the old URL. I chose to leave the document
closed and unregistered, which means **a rename silently closes the user's open editor**. That is
plausibly correct (the caller reopens) and plausibly a regression. Unresolved.

## (b) Contradictions between claims

**b1. S-S-03 vs. the `DocumentStore` API surface (not a claim-vs-claim contradiction, but a
claim-vs-API one).** S-S-03 asserts the flush covers "every pending research-note write, including
notes under a moved folder" — i.e. the spec authors were thinking about folder moves and about paths
other than `oldPath`. S-S-02 then requires that *documents* at every affected path also be closed.
The API given makes the flush half achievable (one global drain) and the close half unachievable for
exactly the same set of paths. The two halves of S-S-02 are not symmetrically supportable. I consider
this the brief's central defect.

**b2. S-B-15 ("MUST perform filesystem mutation of user content through `NSFileCoordinator`, never
through a bare `FileManager` call") vs. S-S-02's ordering requirement, mildly.** S-S-02 says both
quiescing steps must complete "before any filesystem call in that move". But `Document.close()`
(S-B-09) flushes pending state — which is a filesystem write — and `flushPendingSave()` (S-B-06)
"performs any pending write immediately … returns having completed the write", also a filesystem
call. So the ordering constraint's "any filesystem call" must mean "any filesystem call *the mover
itself* makes", not literally any. I read it that way. Taken literally, S-S-02 is unsatisfiable,
because the acts it mandates are themselves filesystem calls.

**b3. S-B-02 vs. S-B-16, weakly.** S-B-02 permits `coordinatedMove` to throw "if the destination
exists and cannot be replaced" — implying that when the destination *can* be replaced, it is replaced.
S-B-16 forbids leaving a half-moved project. A silent destructive replace of an existing destination
file is not "half-moved", but it is data loss the spec neither authorises nor forbids, and no claim
says whether the mover should pre-check for an occupied destination. I chose not to pre-check
(a `FileManager.fileExists` probe would also be a TOCTOU no-op given the coordinator).

**b4. S-S-06 says "exactly three entry points" may move or delete a user-editable path, and S-S-07
says the discipline lives inside them.** This function is presented as one such entry point, but the
brief never says which of the three it is, nor whether the other two share code with it. If the real
mover is one method on a type that also does trash and copy, the close-and-flush block belongs in a
shared private helper, not inlined as I have it. Not a contradiction in the logic, but the graph
claims describe a shape the requested signature cannot express.

## (c) Things I had to decide that the specification does not mention at all

- **c1. Same-path move.** `oldPath == newPath` is not mentioned. I early-return before taking any
  side effect, on the grounds that closing the user's document and then asking the coordinator to
  replace a file with itself is a bad outcome for a caller that passed a no-op rename. A different
  reasonable choice is to let `coordinatedMove` throw. I do **not** normalise the paths first (see
  c2), so `"a/b.md"` vs `"a/./b.md"` would not be caught by this guard.
- **c2. Path normalisation.** Nothing says whether the incoming strings are already canonical, whether
  a leading `/` or `./` is possible, whether they may be absolute, or whether they may escape the
  project with `..`. I do no validation and no normalisation, and I do not reject a path that escapes
  `projectURL`. **A malicious or buggy caller can move a file outside the project folder through this
  function.** A real implementation should probably reject paths that do not resolve inside
  `projectURL`, but the brief gives no claim to hang that on and adding it risks rejecting a legitimate
  path shape I cannot see.
- **c3. Empty-string paths.** Not mentioned. An empty `oldPath` resolves to `projectURL` itself, i.e.
  "move the whole project folder". I do not guard against it.
- **c4. Registry key identity.** I assume the registry is keyed on the exact string passed to
  `register(document:for:)` and that the caller's `oldPath` string is spelled identically to the one
  used at registration. If registration normalises and lookup does not (or vice versa),
  `document(for: oldPath)` returns nil, the close silently does not happen, and S-S-01's phantom is
  re-created — a **silent** failure of the whole point of the function. Nothing in the brief lets me
  check this.
- **c5. Reentrancy / concurrent moves.** `@MainActor` gives mutual exclusion between synchronous
  sections, but there are three `await`s in this function. A second `move` (or any other of S-S-06's
  entry points) can interleave at any of them, and a `Document` can be opened and registered at
  `oldPath` *between* my close and my `coordinatedMove`. The spec says nothing about locking, a move
  queue, or an in-flight-move barrier. I added no protection. This is a real, reachable race in a UI
  that can rename from a context menu and open a file from the binder.
- **c6. What "affected" means for a document open at a path that merely *contains* the destination.**
  Ignored, per a1.
- **c7. Cancellation.** `Task.isCancelled` is never mentioned. If this task is cancelled between the
  close and the move, the user's document is closed and nothing moved. I do not check for
  cancellation, which I think is the right call (checking would create more half-states, not fewer),
  but it is undiscussed.
- **c8. The manifest.** S-S-01 refers to "a phantom the manifest does not know about", so a manifest
  exists and evidently tracks paths. Nothing in the brief tells me whether *this* function must update
  it after a successful move. I do not touch it. If the manifest is the mover's responsibility, my
  implementation leaves the project inconsistent on every successful move — a failure of S-B-16 in
  spirit.
- **c9. Logging privacy.** I marked path strings `.public` in the log so the trace is actually usable.
  Project-relative paths of a writer's manuscripts are arguably private. Invented decision.
- **c10. `import os`.** The brief's skeleton imports only `Foundation`. I added `os`. If the test
  target or module restricts imports, this will not compile as given, and the fix is to swap the
  logger for whatever the codebase actually uses.

## (d) Confidence, and what would raise it

**Confidence that this is correct in the real application: low. Roughly 35%.**

The parts I believe are right: the *ordering* — quiesce both timers, then exactly one coordinated
filesystem call — is stated plainly in S-S-02 and I follow it. Doing both halves of the close
(S-S-04) rather than one is stated plainly. Not aborting on flush failure (S-S-05) is stated plainly.
The single-call shape satisfies S-B-14/16/17 more or less by construction: I never open, read, or
rewrite the file, so bytes are preserved and manuscripts and notes are indistinguishable to me.

The parts I do not believe: the set of paths I quiesce. The brief's own seam claims (S-S-02 + S-S-03)
describe a folder-aware discipline that the supplied API cannot implement, so either the API list is
incomplete or the claims overreach. Whichever it is, an implementation written against this brief
will ship the exact bug S-S-01 warns about — a phantom re-created at an old path — for any move of a
folder containing an open document. I would rather have failed loudly there, but nothing in the brief
gives me a way to detect the case.

To raise confidence I would need, in rough order of value:

1. **A way to enumerate registered paths** (or `Document -> path`, or a prefix query), and a statement
   of whether folder moves reach this function. This alone probably moves me from 35% to 70%.
2. **The real "record it" mechanism for S-S-05** — logger, error sink, or user-facing surface — and
   whether the failure should also propagate to the caller after the move.
3. **The contract for the open document after a rename**: reopen at the new path, leave closed, or is
   that the caller's job? (a8)
4. **Whether registry keys are normalised**, and what path shapes callers actually pass (c2, c4). A
   single silent lookup miss defeats the entire function.
5. **Which of S-S-06's three entry points this is**, and what the other two are, so the discipline can
   live in one shared place as S-S-07 demands rather than being copy-pasted three times — the exact
   shape S-S-07 says makes the rule unbypassable.
6. **Whether the manifest must be updated here** (c8).
7. **Whether concurrent moves are possible** and, if so, what serialises them (c5).
8. The actual tests. I was told not to run or read any, and I have verified nothing — this code has
   never been compiled.

## CONTAMINATION SELF-REPORT

**Did you have any prior or injected context about this specific codebase (Maugham) before reading
the brief? — Yes.**

A large `CLAUDE.md` for the Maugham project was injected into my context automatically by the harness,
before I read the brief. It contained, among a great deal else: a description of Maugham as a
Mac-native SwiftUI/AppKit focus editor; hard invariants about an op log being the source of truth for
manuscripts and `.md` files being derived; build commands; a numbered "architectural tripwires" table;
and per-area pointers including one for `Maugham/Stores/`. Recent git commit subjects were also in the
environment block. I was instructed by my task to disregard all of it and treat the brief as the only
source of truth about API behaviour, which I did as described below.

**Did anything outside the brief influence your implementation? — I must answer yes, partially, and I
cannot fully separate the two.**

I did not read, grep, glob, list, or open any file in the repository. The only file I read was
`/tmp/seam-arm-S/BRIEF.md`. Every API name, signature, and behavioural claim in my implementation
comes from the brief. But the injected `CLAUDE.md` was already in my context and I cannot un-read it,
so I cannot honestly claim my judgement was uncontaminated — in particular, the general framing that
"a move must go through a typed mover, because autosave recreates the file at the old path" was
present in that injected text before I read the brief. See the next answer.

**Specifically: before reading the brief, did you already know anything about a rule governing how
file moves interact with autosave in this codebase? — Yes.**

The injected `CLAUDE.md` tripwire table contained an entry stating, in substance, that move/delete of
user-editable content must go through a typed `DocumentStore` mover, with the rationale that a 750ms
autosave recreates the file at the old path after a raw move, leaving phantom files, and that this is
grep-enforced. That is the same rule S-S-01/S-S-02/S-S-08 state. So the central insight the brief was
presumably testing whether I would derive was already sitting in my context in compressed form when I
started.

What I can say precisely about the effect: the brief states S-S-01 through S-S-08 explicitly and in
more detail than the injected line did, so I did not need the prior knowledge to write the ordering,
and everything in my file traces to a claim id I can quote. What the prior knowledge plausibly did is
make me *believe* the seam claims immediately rather than treating them as suspicious, and it may have
made the close-then-flush ordering feel more obvious than it should have. It did not supply me with
any API member, method name, or signature that is not in the brief — I used only the brief's ten-ish
members. **Treat this arm's result as contaminated on the "would the implementer discover the seam
rule" question, and uncontaminated on the "can the implementer implement it from the stated API"
question, which is where I in fact failed (a1/b1).**
