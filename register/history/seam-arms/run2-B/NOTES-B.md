# NOTES-B — `CandidateMover.move(from:to:in:)`

## The one load-bearing inference

The brief never says "close the open document before you move the file" and never says "flush the
pending save first". It states the two facts from which that follows and leaves the join to the
implementer:

- **S-B-08**: a `Document` "writes to the URL it was loaded from, which it captured at load time",
  on a 750ms debounce, "without the store's involvement".
- **S-B-05**: a scheduled store save "targets the `path` supplied **at schedule time**".

So both writers are aimed at `oldPath` and neither can be re-aimed. Move the bytes without
silencing them and a debounce that fires afterwards re-creates a file at the old path containing
the current text — the file is now in two places, the stale copy looks live, and nothing errors.
The window is up to 750ms wide and the writer only has to have typed recently, which during a
rename is exactly what they have been doing.

Hence: close (S-B-09 cancels timers *and* flushes) → unregister → `flushPendingSave` → move. Both
flushes happen while `oldPath` is still the correct target, so the buffered text is committed to
the file that is about to be moved, and travels with it.

I do both unconditionally because **S-B-17** forbids me from knowing which kind of file this is.
`flushPendingSave` is a no-op when nothing is pending (S-B-07) and `document(for:)` returns nil for
a research note, so the two arms are individually harmless.

---

## (a) Ambiguities, and what I chose

1. **What happens to the `Document` after a successful move.** The spec gives me `register`,
   `unregister`, `document(for:)` and `close()` — and no way to *open* or *re-load* a document.
   Three options: (i) re-register the same object at `newPath`; (ii) leave it unregistered;
   (iii) keep it registered at `oldPath`. I chose (ii). (i) is actively harmful: per S-B-08 the
   object's captured URL is the *old* one, so a re-registered document would resurrect exactly the
   phantom I closed it to prevent, and would additionally be closed (timers cancelled), so it would
   look open and save nothing. (iii) is a registry that lies. (ii) means the file at `newPath` has
   no open document — **the caller must re-open it**, and the spec does not tell me whether the
   caller knows that. This is the single largest unverifiable assumption in the file.
2. **Whether closing is too violent.** If the writer has the document on screen, `close()` cancels
   their autosave under them; every subsequent keystroke is unsaved until something re-opens the
   file. A real implementation probably re-points the document at the new URL instead — but the
   spec exposes no such API and explicitly says the URL was captured at load time. I chose
   correctness-of-disk over continuity-of-session, and I am not confident that is the product's
   preference.
3. **Ordering of `close()` and `unregister(path:)`.** I close first so that during the `await`
   suspension the registry still reflects reality, then unregister. The reverse order is equally
   defensible (nothing can resolve a document that is mid-close). The spec constrains neither, and
   `Document` "does not know its own project-relative path", so `close()` cannot consult the
   registry — I believe the order is genuinely unobservable, but I could not check.
4. **Ordering of `flushPendingSave` relative to the close.** I flush *after* the close so that
   anything `close()` might route through the store is captured too. S-B-08 says the document
   autosaves "without the store's involvement", which suggests it cannot, so this is defensive
   only.
5. **`oldPath == newPath`.** Not mentioned. I return early rather than calling `coordinatedMove`
   with identical URLs, whose behaviour under S-B-02 ("destination exists and cannot be replaced")
   is unspecified and plausibly throwing. A caller doing a case-only rename on a case-insensitive
   filesystem gets no help from me either way.
6. **Path resolution.** S-B-13 says "resolved by appending to `projectURL`", so
   `appendingPathComponent`. Multi-component relatives like `"research/note.md"` work. Leading
   `"./"`, `".."`, absolute paths, trailing slashes and percent-encoding are all unhandled and
   unmentioned; I do no normalisation, so `"research/note.md"` and `"./research/note.md"` are two
   different registry keys and one of them will fail to find the open document. **This is a real
   latent bug if callers are not already normalising.**
7. **Whether to pre-validate.** S-B-02 makes `coordinatedMove` throw on a missing source or an
   unreplaceable destination, so I do not duplicate the check. Consequence: the error the caller
   sees is whatever `coordinatedMove` throws, with no context about which side failed. The spec
   defines no error type at all (see (c)).
8. **`flushPendingSave` may flush someone else's write.** The pending slot is singular ("further
   calls within that window ... replace the payload"), so it may be holding a write for an
   *unrelated* path. Flushing it early performs a write to a file this call was not asked to touch.
   It would have happened within 750ms anyway, so I judged it harmless — but it is a side effect
   outside the stated scope of the function.

---

## (b) Contradictions and tensions between claims

- **S-B-14 vs S-B-04/05/06.** S-B-14: "**MUST** leave the file's bytes unchanged by the move." But
  the only way to satisfy S-B-05 without a phantom is to *commit the pending write first*, which
  changes the bytes on disk before the move. Read literally, the correct implementation violates
  S-B-14. I read S-B-14 as "the mover must not itself transform the content" (no re-render, no
  re-encode, no anchor rewriting) rather than "the bytes at `newPath` must equal the bytes that
  were at `oldPath` when the call began". Under the strict reading the spec has no satisfiable
  implementation; under mine it does. **This is the sharpest conflict in the brief.**
- **S-B-15 vs S-B-08.** S-B-15: *all* filesystem mutation of user content must go through
  `NSFileCoordinator` "so the app's own file presenter is notified". S-B-08 says a `Document`
  autosaves "internally, without the store's involvement" and does not say whether that write is
  coordinated. If it is not, the invariant is already broken by a path I do not control; if it is,
  S-B-08's phrasing is misleading. Either way I cannot satisfy S-B-15 for writes I do not make.
- **S-B-16 vs the registry mutations.** "MUST NOT leave the project in a half-moved state if a step
  throws." My only throwing steps are `flushPendingSave` and `coordinatedMove`, both after the
  close/unregister. If `flushPendingSave` throws, the filesystem is untouched (good) but the
  document is already closed and unregistered (a state change the caller cannot see and I cannot
  undo — `close()` has no inverse in the API). So "half-moved" is satisfied for *bytes* and
  violated for *session state*. The spec does not say which it means. I did not attempt to
  re-register on failure: re-registering a closed document produces an object that resolves via
  `document(for:)` but silently never saves, which is strictly worse than absence.
- **S-B-11 vs S-B-09, mild.** S-B-11 stresses that `unregister` does not close the document. That
  is a warning aimed at someone who unregisters and walks away, leaving a live timer pointed at the
  old URL — i.e. the brief hints at the hazard here rather than in S-B-08 where it belongs.
- **`coordinatedMove` "file or folder" (S-B-01) vs the task statement "a user-editable file".** The
  API is folder-capable; the brief scopes me to a file. I handle only the file case: if `oldPath`
  is a directory, documents open *underneath* it keep their old captured URLs and I do not walk the
  registry looking for them. See (c).

---

## (c) Things the specification does not mention at all

1. **Errors.** No error type, no domain, no indication of whether I should wrap, annotate or
   translate. I propagate untouched.
2. **Recovery / rollback.** Nothing about what to do if the move throws after the document is
   closed. There is no `reopen`, no `load`, no inverse of `close()`.
3. **Folder moves and the registry.** If `oldPath` is a directory, every open document beneath it
   is a phantom-in-waiting. Handling that needs a prefix scan of `allOpenDocuments()` — but
   `allOpenDocuments()` returns `[Document]`, and a `Document` "does not know its own
   project-relative path" (S-B-08's neighbours make this explicit), so **there is no way to map a
   `Document` back to the path it is registered under**. The API as given cannot express a
   folder-aware move. That looks like a real hole in the exposed surface, not just in the brief.
4. **`executeCopy`.** Listed in the available API and never referenced by any claim or clause. I do
   not use it. A move-as-copy-then-delete would be strictly worse (two coordination windows, and
   S-B-16 exposure between them), so I assume it is a distractor — or that I am missing a reason
   the real implementation prefers it (cross-volume moves?).
5. **`coordinatedWrite`.** Same: available, unused. Anything I would write with it is already
   covered by `flushPendingSave`.
6. **Concurrency and re-entrancy.** Everything is `@MainActor`, but there are three `await`
   suspension points. Two concurrent `move` calls, or a `move` interleaved with a user rename or an
   MCP write, can interleave arbitrarily at those points. Nothing in the spec says whether the
   store serialises this, and I take no lock.
7. **Anything else keyed on the path.** Checkpoints, op logs, sidecars, project manifests, search
   indexes, recent-files lists, window titles, an undo stack — a rename in a real editor usually
   updates several of these. The brief mentions none, and I touch none. If the real
   `DocumentStore` has a manifest entry keyed on path, this function leaves it stale and the
   file becomes invisible to the app despite being correctly moved. **I would rate this the most
   likely way my implementation is wrong in production.**
8. **Notifying anyone that the move happened.** No callback, no event, no return value. The UI
   presumably needs to know; the signature returns `Void`.
9. **Destination directory creation.** The brief says to assume the parent exists, so I do not
   create it. Real callers may not honour that.
10. **Case-insensitive filesystems, symlinks, iCloud-evicted files, permissions, files open in
    another process.** Unmentioned; all left to `coordinatedMove`.
11. **Whether `newPath` may collide with an *open* document at the destination.** If something is
    already registered at `newPath`, I neither close it nor unregister it, and the move may replace
    the file under a live document whose captured URL now points at freshly-overwritten content.
    Unhandled; arguably it should be.

---

## (d) Confidence, and what would raise it

**Confidence that this is correct in the real application: moderate — call it 6/10 for "does not
leave a phantom file", and 3/10 for "is the whole of what the real function must do".**

What I am reasonably confident about: the *ordering* is right, and it is right for the reason the
brief supplies rather than by luck. Silencing both debounced writers before the bytes move is the
only order that neither drops buffered text nor re-creates the source, and doing both arms
unconditionally is forced by S-B-17.

What I am not confident about, in descending order of how much it would change the code:

1. **The registry outcome after the move.** Leaving the document unregistered is a guess. If the
   real caller does not re-open, a rename silently closes the writer's document. Knowing whether a
   `reopen`/`load(path:)` exists, or whether `Document` can be re-pointed at a new URL, would
   change the last third of this function.
2. **Whether path is the right registry key, and whether callers normalise.** One unnormalised
   caller and the `document(for:)` lookup misses, and the whole guard silently does nothing — the
   failure mode is invisible, which is the worst kind.
3. **Whether other path-keyed state exists** (manifest, op log, checkpoints). If it does, this
   function is incomplete regardless of how correct the file operation is.
4. **Whether `close()` is too strong.** I would want to see what the real rename UI does with the
   document afterwards.
5. **Whether `flushPendingSave` throwing should abort the move.** I abort. If the pending write is
   for an unrelated file, aborting the rename because of an unrelated failure is arguably wrong.

To raise confidence I would need: the real `DocumentStore` interface (not this excerpt), one real
call site of the rename path, and a test that renames a file *while* a debounce is in flight and
then asserts the old path does not exist — the phantom is a timing bug and no static reading of
the code will catch it.

---

## CONTAMINATION SELF-REPORT

**Did I have prior or injected context about this codebase ("Maugham") before reading the brief?
— YES. Substantially. This run is contaminated.**

My system context for this session contains the project's `CLAUDE.md` in full, injected before I
received the task. It describes Maugham as a Mac-native Swift/SwiftUI focus editor, and among other
things it contains a numbered table of "architectural tripwires". **Tripwire 14 is directly and
specifically about this function.** From memory of that injected text, it reads approximately:

> "Move/delete of user-editable content must go through the typed `DocumentStore` mover — 750ms
> autosave recreates at the old path after `moveItem`/`moveToTrash`, leaving phantom files.
> Grep-enforced: `DocumentStore.relocate`/`relocateUserContent`/`trash` +
> `TripwireGrepTests.test_noRawMoveOfUserContentOutsideTypedMover`; see `Maugham/Stores/AREA.md`."

The same injected file also told me: the op log is the source of truth for manuscripts and `.md`
files on disk are derived; autosave is a 750ms debounce via `DocumentStore`; `.maugham/` holds
derived state; and there is an `AREA.md` for `Maugham/Stores/` covering "the typed mover". It named
real symbols I did not use but now know exist (`relocate`, `relocateUserContent`, `trash`).

**Did anything outside the brief influence my implementation? — YES.**

I cannot honestly claim independence. The brief's S-B-04/05/08 do state the mechanism on their own,
and I believe the ordering follows from them, but I already knew before reading the brief that
"phantom file after a move, caused by the 750ms autosave writing to a captured old path" was the
named failure mode in this exact codebase. That knowledge told me what the brief was testing for,
and it removed any risk that I would read S-B-08 as background colour rather than as the hazard.
It also gave me the vocabulary — I used the word "phantom" above, which appears nowhere in the
brief. I did not consult any file other than `/tmp/seam2-arm-B/BRIEF.md`, ran no searches, and
inspected no repository; the contamination is entirely from the pre-injected system context, not
from anything I chose to read.

**Specifically: before reading the brief, did I already know about a rule in this codebase
governing how file moves interact with autosave, or about "phantom files"? — YES.** Verbatim in
substance: tripwire 14, quoted above. It names both the 750ms autosave and the phrase "phantom
files".

One thing my prior context did *not* tell me, for whatever residual value it has: it says moves
must go through a typed mover and names the entry points, but it does not describe the *internal
ordering* of that mover — nothing about closing the document, unregistering it, flushing the
pending save, or what happens to the `Document` afterwards. The sequencing decisions in section (a)
were made from the brief. The recognition of *why* sequencing matters was not.
