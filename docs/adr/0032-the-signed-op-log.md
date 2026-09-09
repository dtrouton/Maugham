# ADR 0032 — The signed op log: provenance for every op, the device before the person

**Date:** 2026-09-07 · **Amended 2026-09-08** (Addendum: actors) · **Status:** Accepted (P1 and P1b built; P2 and P3 unwritten) · **Milestone:** signed-op-log-p1-integrity-and-the-device (branch `claude/signed-op-log-p1-2026-09-07`), then signed-op-log-p1b-actors (branch `claude/signed-op-log-p1b-actors-2026-09-08`)

## Context

"Interference outside Maugham" is three adversaries wearing one word: an
accident (a torn append, a sync layer's half-write), a tool (an agent with a
shell appending an insert op into `.maugham/ops/`), and a person (a
collaborator writing ops they are not entitled to write). Sealed segments have
carried a SHA-256 since [ADR 0016](0016-op-log-growth-without-compaction.md);
the **live tail carried nothing**, which the 2026-06-09 maintainability audit
recorded as its item 10. Nothing in the log said who wrote a line, and nothing
could tell a line Maugham wrote from a line something else appended after it.

That matters here more than it would in most applications, because the op log
is the manuscript ([ADR 0018](0018-manuscript-reads-derive-from-oplog.md)): the
`.md` on disk is derived, an outside edit to it is discarded, and a line
appended to the log by anything else is applied as the writer's own words on
the next load. The constitution's *the words are safe* is what is at stake, and
it cuts both ways — a manuscript that refuses to open because a signature did
not check is the same failure as one that silently applies a stranger's line.

The spec (`docs/superpowers/specs/2026-09-05-signed-op-log-design.md`) settles
the shape with Denver: **sign, do not encrypt** (reading is the folder's
business); **a person is a key, a device is a certificate** that person signs;
**verification never refuses to open a book**. Its §7 spike, run 2026-09-07,
measured the two facts the design hangs on and corrected two of its premises:
a Secure Enclave key mints, persists and reloads from a binary carrying **no
entitlement**, while a synchronizable keychain item needs a Developer ID
provisioning profile and an entitled dev build is `SIGKILL`ed at exec; and the
append unit is **one op per line** rather than a `PendingBuffer` flush, so
per-op signing is 3.9 s over 50k ops against a 100 ms budget and the signature
had to be decoupled from the append.

Denver's ruling of 2026-09-07 followed: **P2 ships labels only.** A key synced
through the Apple ID would let a compromised Apple ID *sign as the author*,
where today it can only write files that land in quarantine visibly; the
provisioning pipeline adds a launch dependency with an expiry neither
`codesign` nor notarization can check; and the dev variant cannot carry the
entitlement, so the maintainer would never exercise the sync path. No keychain
item, no entitlement, no provisioning profile anywhere in P1 or P2.

## Decision

**Provenance, not a lock.** The op log records who wrote each line and refuses
to apply what it cannot account for; it never withholds a manuscript. Hard
revocation stays the iCloud share's.

### 1. The wire format: a chained line, and a seal line of its own kind

An op line is the existing `.sortedKeys` JSON object with one additive key
inserted **as the first key** — `{"prev":"<64 hex>",` then the rest of the
object. The position is fixed, so the bytes are deterministic and the hash is
over the bytes as written. `prev` is therefore **never a field on `Op` or
`InboxEntry`**: it is a wire key `OpLogChain.chainedLine` inserts textually, so
an op re-appended into another file can never carry a stale one, and every
existing `Codable` decoder ignores it — an older reader decodes a chained line
unchanged.

A **seal line** is a line of its own kind, one top-level key, recognised by the
prefix `{"seal":`:

```
{"seal":{"at":"…","head":"<64 hex>","key":"<fingerprint>","pub":"<base64 x963>","sig":"<base64 raw>"}}
```

It carries a signature over the chain head at the moment it was written **plus
the public key that verifies it**, so it is self-contained: P2 adds a *trust*
decision without touching the format. The line hash is SHA-256 over the line's
bytes without the trailing newline, because the newline is the file's separator
and not the line's content. `OpLogChain.genesis` — the hash of no bytes at all —
is the `prev` of the first line a device writes into an empty file, and is
accepted only where nothing precedes it; without it the first line would be
indistinguishable from a pre-milestone line and no seal could ever settle it.

A line with no `prev` is **legacy**, and legacy is a prefix and never a suffix:
one arriving after the chain has begun breaks it. No migration, no schema bump —
nothing here rewrites an op, and the manifest schema contract scopes bumps to
`OpKind` cases.

### 2. The device's identity is its key's fingerprint

`DeviceIdentity` (MaughamCore) mints a `SecureEnclave.P256.Signing.PrivateKey`
and persists its `dataRepresentation` — an enclave-wrapped blob useless on any
other machine — as **a plain file the app owns**, under
`~/Library/Application Support/<BuildVariant.current.supportFolderName>/device/`.
No keychain item, no `kSecAttrIsPermanent`, no entitlement, nothing an installer
or a profile can revoke. Its protection is the enclave, not the filesystem.

**Unsigned is a first-class state, not a failure.** Where there is no enclave —
a VM, CI's runner — the device persists 32 random bytes instead, takes its
fingerprint from their SHA-256, writes chained lines that nothing seals, and
reports nothing wrong. `deviceId` is `<actor>-<16-hex prefix of the
fingerprint>` (P1b: a device holds one key per `DeviceActor` — `author`,
`assistant`, `translator`, `maugham` — each its own blob under the same
`device/` folder, and `LocalIdentities` is all four in one value),
`fingerprint` the full 64, and `slug` is `DeviceSlug.make(from: deviceId)` —
`DeviceSlug` keeps its private init and its filename-only life (tripwire 24);
only what `make` is handed changed. `MacDeviceID` and `PhoneDeviceID` are
deleted. A blob that will not load on this enclave (a restored Mac) is renamed
aside rather than removed, and the token path is taken: a new key is a new
device anyway, and the old file is history.

**This device's existing files become another device's files.** The hostname
slug on the Mac and the `phone:<uuid>` slug on the phone name a device whose
key this build cannot produce, so those files read as unsigned history, are
never appended to, and are never sealed.

### 3. The device remembers the head it wrote

The chain catches a line that names the wrong `prev`. It does not catch a line
that names the **right** one: an agent that reads the file, hashes the last
line and appends a correctly-chained op is indistinguishable from Maugham by
the chain rules alone. `OpLogDeviceState` is the extra fact only this device
has — the head it last wrote into each file, keyed
`<SHA-256 of the project root path>/<filename>`, persisted beside the key
material in `op-log-state.json`. Anything after that head arrived from
somewhere else, however well it chains. Each entry also records the project
ROOT beside its head, because the key hashes that path and cannot be read
backwards, and an entry whose recorded root no longer has a `.maugham` child is
pruned at load while one with no recorded root is kept until its next `remember`
records one (2026-09-09, the P1 handoff's decision #3). What was NOT done there
is coalescing the persists: the head is remembered before the batch is written,
and deferring that write would turn a crash into a set-aside of the writer's own
words rather than the adopt case. It is already one persist per batch, not one
per line.

Two orderings are load-bearing. The head is **remembered before the line is
written**: a crash between them leaves a remembered head no line hashes to,
which the load treats as the adopt case, where the other order would leave the
device's own last op sitting after the head it remembers and quarantine it as a
stranger's. And the whole append — read the tail, verify, set aside, rewrite,
chain, remember, write — happens **inside one coordinated write**, never a
nested coordination.

**The adopt rule** covers that crash window, and *only* it. A remembered head
absent from the file is adopted when the walk never broke, every seal in the
file is ours, and the file's own head is the one this device remembered *last
time* (`previousHead`) — which is exactly what remembering a head before writing
the line that hashes to it leaves behind. Adopting a broken or foreign-sealed
file's head would bless exactly what the remembered head exists to catch.
Keying on the project *path* means a project that moves forgets its heads
entirely, which is the safe direction: nothing is adopted and nothing is
quarantined, and the writer's own history is never held back because they
dragged a folder.

**What is caught, and what is not.** An agent that APPENDS is caught: however
correctly it chains, its line arrives after the head this device remembers. An
agent that TRUNCATES the file back to a seal line and appends its own
correctly-chained lines used to be caught by nothing — no break, our own seals,
and a head we had simply never seen, which the load adopted and remembered, so
the next append chained onto the forgery. That is now the *converse* of the
adopt rule: when the file's head is not the crash window's, every line after the
last seal this device **trusts** is quarantined ("the history's chain is
broken"), the prefix up to and including that seal applies, and the state is not
updated. The read, the chained write and the verified read all take that
decision from one function (`OpLogChain.resolveAbsentHead`), because a load that
held lines back while the next append chained onto them would strand the
writer's own new ops behind a permanent break.

On an **unsigned** device the rule catches nobody, deliberately. "Every seal
trusted" is vacuous with zero seals, so there is nothing to fall back to, and
quarantining a whole unsigned file over a missing head would cost the writer
their manuscript to catch nobody. Such a file is left exactly as the walk found
it: its tail is unsigned history by definition, which is what an unsigned device
writes. The honest close for both halves is P2's registry plus a rule that an
adopted head must be at or descended from the last trusted seal.

**The state file belongs to one identity.** `op-log-state.json` carries the
fingerprint of the device that wrote it, and opening it under any other one
starts empty and rewrites the file. The heads are keyed by project path and
filename with the device nowhere in the key, and Application Support is what
Migration Assistant copies — while the enclave blob it copies will not load, so
the new Mac gets a new identity and would otherwise keep every remembered head
for the old slug's files, and quarantine its still-running twin's live ops as a
stranger's. There is no migration: a state file predating the field reads as a
mismatch, which is the empty case.

**A torn last line is a crash, not a forgery.** A line whose bytes do not close
as a JSON object, and which nothing follows, is classified `tornTail`: excluded
from the walk, never a break, never quarantined, the running head unmoved, and
the bytes handed to the element decoder, which reports them in
`diagnostics.skipped` exactly as a torn line was reported before the chain
existed. Only the *last* line may be torn — an incomplete line with something
after it means the write finished, so the damage is not a tear.

### 4. Seals are decoupled from appends

A seal is one signature over a run of lines, not one per line. `OpLogStore.sealChain(docId:)`
is the one verb, and enclave signing (~4.5 ms) never runs in a loop:

- every `OpLogStore.chainSealInterval` (100) appends, from `OpLogStore.append`;
- after every burst that appended, from `Document.flushBurstNow`;
- at `Document.close()`, and over every doc this Mac has written at project
  open, from `DocumentStore` — in both cases **before `sealTailIfNeeded`**, so
  a rotated `.mzseg` ends on a seal line and its whole span is verified inside
  the container. That open sweep also takes the project stream, which rotates at
  the same threshold as every other tail and has no other boundary to rotate at
  (2026-09-09);
- after **every** append on the phone (`AnnotationWriter`) and for every inbox
  capture on both surfaces, because those are rare lifecycle acts rather than a
  keystroke stream.

All of them are best-effort: `sealChain` answers false without throwing on a
device with no key and on a file with nothing new, and a genuine failure is
logged. Sealing is maintenance; it must never cost the writer the burst that
has already landed.

### 5. A segment's signature is a sidecar

Minting a `.mzseg` also writes `<name>.mzseg.sig`, a `SegmentSignature` over
the 32 digest bytes the container already carries. **Beside rather than
inside**: a `.mzseg` is immutable bytes whose checksum is part of its own
header, and a segment that can be rewritten is not sealed — so this is
additive over the MZS1 container and **no reader of it changes**. **Over the
digest**: the segment already commits to every one of its bytes through that
SHA-256, so signing those 32 bytes signs the whole segment, and verification is
a single P256 check however long the history is. Losing the sidecar costs what
losing any derived file costs — the segment reads as unsigned history, which is
honest.

**The sidecar contributes no content to `BackupSignature`, and the plan's
seam-9 premise that it "is a content file: it contributes a hash" is wrong.**
`BackupSignature` routes anything under `.maugham/ops/` into its op-ids branch,
so a `.sig` (and, pre-existing, a `.mzseg`) decodes to zero ops and contributes
a constant line: re-signing a segment produces an identical backup signature.
The half of that seam that mattered does hold and is pinned — a **seal line
changes no signature**, because seal lines fail `decode(Op.self)` and are
skipped, so a burst's seal does not mint a new backup generation.

A verified digest is remembered in `OpLogDeviceState` and never re-verified, so
a warm open pays nothing for sealed history and only the unsealed tail is
walked.

**A signed segment settles its lines as *verified*, legacy ones included, and
that is correct rather than laundering.** A tail that began as pre-P1 lines and
was later rotated is a run of bytes this device's key has signed the digest of
— the claim a seal makes is *these exact bytes are mine*, and it is true of a
legacy line inside a segment as much as a chained one. The consequence to know
is that the notice is not stable over a document's life: "part of this
document's history was written before this book was signed" stops appearing once
that legacy tail has been rotated into a signed segment. Nothing was rewritten;
the sentence became false.

### 6. Three states, of which P1 builds two

The spec's verification states are **verified**, **pending** and
**quarantined**, with legacy as *unsigned history* beside them. P1 has no
registry, so **pending cannot exist**: there is nobody to be un-admitted yet.
What P1 builds is verified and quarantined, with everything else applied as
unsigned history — a device verifies its **own** key and nothing else, so a
foreign seal that holds together perfectly is still history rather than this
device's word. `OpLogChain.Line.State` is the enum that spells the classes the
walk actually assigns; read its cases, not a list here.

Quarantine is a classification plus a record, never a refusal. A quarantined
line is never applied and never deleted: a copy goes to
`.maugham/conflicts/quarantined-ops/` as a `.lines` record beside the existing
file quarantines, content-deduped so the same foreign line found on ten
consecutive opens is one record. It is the one new refusal in the tree — a
`.lines` record **never returns** (`ReturnOutcome.setAsideByProvenance`), because
there is no file waiting to come back; the bytes are forensics. Its reason is
derived from the break rather than passed in, so no caller can file the same
event under different words: *written by something that is not Maugham* for a
line after the remembered head or an unchained line after the chain began, and
*the history's chain is broken* for everything else.

### 7. What the writer is told

Two sentences in the History pane, both pure statics, neither with a control
beside it, because neither is something the writer can act on:
`HistoryPane.unsignedHistoryNotice(provenance:)` says that part of this
document's history was written before the book was signed and/or that N changes
from another device are applied as unsigned history — **one sentence carrying
both** when both hold, per the pane's coalescing rule — and
`HistoryPane.setAsideLinesNotice(lineCount:)` says that N changes were written
by something that is not Maugham and are kept in backup, not applied.
`unsealed` lines are deliberately never mentioned: the live tail is always
partly unsealed, so naming it would be a permanent notice about nothing.
Nothing appears in the tree, the footer or a badge.

### 8. What P2 adds without a format change

Device certificates, the registry, admission with the author's labels,
revocation, the claim-and-adopt on a keyless restore, and the People & Devices
pane. None of it changes the wire format: a seal already carries the key that
verifies it, so P2 supplies the `trusted` closure `OpLogChain.verify` already
takes and *pending* becomes reachable. P3 adds roles and the per-op-kind check.

## Addendum — actors, 2026-09-08 (P1b)

**A device is four writers, and each holds a key of its own.** P1 gave the
device one enclave key, which said *this Mac* and stopped there. Four different
things write into one project's op logs — the writer typing, Claude answering
through MCP, the translation pipeline filing a round, and the app rebalancing
task priorities on nobody's instruction — and P1 recorded which was which
nowhere at all. Worse, four `Document.load` call sites passed a **role as a
device string** (`"wiki-rename"`, `"find-replace"`, `"mcp"` twice, and
`TaskDeriver`'s `"rebalance"`), and a string names no key, so C1's rule took
the plain unchained path for every one of them: everything Claude wrote through
MCP and both automations of the writer's hand were lines nothing on the device
could vouch for. That was the P1 handoff's decision #7, and Denver ruled it:
*"lets use the terminology 'assistant' for anything through the mcp …
translations get a special role of 'translator' … optimisations should be
signed as Maugham itself … search and replace is an automation of the writer."*

`DeviceActor` (MaughamCore) is the closed enum that follows — `author`,
`assistant`, `translator`, `maugham` — and `LocalIdentities` holds all four
identities in one value, subscripted exhaustively so a fifth case is a compile
error rather than a silently missing key. Each actor mints and persists its own
enclave blob under the same `device/` folder (the author keeps
`device-key.blob`/`device-token`; the others take a `.<actor>` suffix), takes
its own device id `<actor>-<16 hex>`, and therefore its own per-doc file. (In
the FILENAME the hex run is shorter for `assistant` and `translator`, whose
names do not leave sixteen hex digits inside `DeviceSlug.make`'s 24-character
prefix cap; the id itself is untrimmed.)

**Four KEYS rather than four labels, and what that does and does not buy.** A
label is a claim made *inside* the line, so anything able to write a line is
able to write the label; a key is who sealed the span, and only the enclave
that holds it can produce that signature. The honest limit: all four actors run
inside one Maugham process, so this does **not** protect against Maugham
mislabelling its own writes — nothing stops the app from loading a document as
`.author` and letting MCP write through it. That is not hypothetical: Denver's
smoke of this slice caught `add_comment` on an OPEN chapter signing Claude's
note as the writer, and the fix is a rule rather than a load — an annotation
CREATION whose author's `sourceKind` is not `.human` carries the assistant's id
whichever `Document` it arrived through, while the writer's own notes and every
disposition of Claude's stay the writer's. What protects that is the
compile-time argument: `Document.load(url:actor:session:presenter:)` is the
production door, the `device: String` overload is `internal`, and
`TripwireGrepTests.test_noDeviceStringAtAProductionDocumentLoad` (with a planted
offender) keeps a literal out. What the four keys buy is provenance of the
**channel**: a line in `<doc>.assistant-…jsonl` sealed by the assistant's key
came through MCP, and no line elsewhere can claim to have.

**What search-and-replace is.** It is the author's, not the app's. A
project-wide replace is a machine performing what the writer decided, in the
words the writer chose — an automation of their hand, and the same is true of a
wiki-link rename. The distinction is not *did a human type each character* but
*whose decision is in the op*, and by that rule only the priority rebalance
belongs to `maugham`: nobody asked for it and nobody would notice it.

**The rebalance marker moved from `device` to `session`.**
`TaskDeriver.rebalanceSentinel` is still the string `"rebalance"`, but it is now
the SESSION marker alone; the ops carry `DeviceActor.maugham`'s real device id,
so they chain and seal like everything else, and every reader that recognised a
rebalance by its device string recognises it by session. No `SynthesisSource`
case, so no schema bump.

**Translations are chained under two actors' files, and the existing merge is
what makes that safe.** `TranslationStore` writes through the chained
`JSONLAppendStore<TranslationRecord>` under the `translator` (the pipeline and
`write_translation`) or the `author` (the Translation Review pane's own edits,
because a purge is the writer's decision and filing it under the translator's
key would put it in the wrong hand). Two actors therefore write two files for
one `(docId, language)` — which is exactly what `loadMerged` has always done
across device files, opId-ordered and deduped, so nothing new was needed. The
chain is per file, so neither actor's rewrite can touch the other's lines
(ADR 0012's single-writer premise, now per actor rather than per device).

**Every local actor's oversized tail rotates.** `sealChain(docId:)` walks all
four actors and seals each file that exists and holds unsealed lines — the ones
that wrote nothing cost no enclave operation, since `appendSeal` returns before
it asks for a signature. Rotation follows the same rule as of this addendum:
`Document.close()` and `DocumentStore`'s open-time sweep call
`sealTailIfNeeded` once per local identity rather than for the author alone, so
a long MCP session's assistant tail becomes a `.mzseg` segment at the same
512 KB threshold the writer's does. This supersedes the first spelling of §5 in
this ADR's area guide, which said rotation was the author's tail alone. The
scope rules that survive this addendum, and now matter more: rotation is never
the legacy unsuffixed file, and **never another device's** — the loop is over
this device's own identities, so a document loaded under a device string that
names no local actor rotates nothing. `__project__` was a third such exclusion
when this addendum was written and is one no longer: since 2026-09-09 it rotates
at the same 512 KB, at the open sweep alone, which names it by hand and takes it
last (the Consequences say why). The sidecar carries the key of the
actor whose slug the segment is named for, and a slug naming no local actor
gets no signature at all.

**Which files a seal touches is decided by a counter, and which tails a close
rotates is decided by the Document's own actor** (the whole-branch review's I1
and I3, same day). `appendSeal` cannot discover that a file has nothing unsealed
without a coordinated write acquisition, a whole-file read and a full verify, so
`sealChain(docId:)` consults the store's in-memory `linesSinceSeal` counters and
touches only files it has appended to since their last seal — one signature per
burst, not four. The project-open sweep has no counters, being a fresh store, so
it asks `sealChain(docId:actor:)` for the AUTHOR's tail alone, which is P1's
shape; another actor's crash-window leftover is sealed by that actor's own next
write. And because rotation DELETES the tail it seals, a Document rotates only
the actor it was loaded as — an MCP call is a Document loaded as the assistant,
and a fan-out there would delete the file the writer's open Document is
appending to. The sweep stays the one place all four rotate, and is safe there
because it runs before the first `Document.load`.

**Signing and trusting stopped having the same answer.** A line is signed by
one actor; `ChainPolicy.trustedFingerprints` and every `trusted:` closure on the
read side are **all four**, because the assistant's seal over the assistant's
own file is this device's own word. A narrower set would file the writer's own
MCP history as another device's unsigned history, and History's *"changes from
another device"* would start counting Claude on this Mac. `OpLogStore` has no
single `identity` property any more: it holds `identities`, and a reader wanting
"the device" has to say which of the four it means.

**A key exists once a WRITER has named its actor** (amended by the whole-branch
review's C1, same day). `LocalIdentities` is lazy, and the split is by who is
asking. `subscript(actor:)` and the four named properties MINT — naming an actor
is the writer's act (`Document.load(actor:)`, the translation writers,
`TaskDeriver`'s Maugham id), and a key about to sign something is worth minting.
`all`, `fingerprints`, `existingActors` and `identity(forDeviceId:)` ENUMERATE,
over exactly the actors whose blob or token is already on disk — so a read path
trusts the keys this device has ever written with, and constructing
`LocalIdentities.current` costs nothing at all.

There is deliberately no writer's lookup that mints from an id's actor prefix. A
device id is DERIVED from its key, so an op can only carry `maugham-…` because
something named `.maugham` and minted it; a prefix-minting lookup would close
nothing and would mint this device's own author key on another Mac's author op.

**The phone is the `author` and mints that one key** — and under the lazy rule it
needs no code of its own to be. Its captures and its accept/reject are the
writer's acts, so its writers name `.author`; the three actors nothing on it ever
names are never minted, whatever it constructs. The guard is a measurement rather
than a spelling census, because the thing that broke it was a DEFAULT argument
(`OpLogStore(projectURL:)`, three phone sites) that no grep can see:
`PhoneOneKeyTests` runs the real annotation read path and then asks the phone's
own device folder what is in it.

**No format change.** `prev`, the seal line, `.lines` records and
`op-log-state.json` are exactly P1's; the state file belongs to the DEVICE and
takes the author's fingerprint as its identity, because a device that re-keys
re-keys all four. P2's registry admits a person, a device **and an actor**.

## Consequences

- **A device is its key, so a device that loses its key is a new device.** It
  writes a new file and reads its old one as history. That is the intended
  behaviour (spec §4.8) and it is what makes two Macs sharing a name unable to
  collide on a file — tripwire 17's record of what such a collision costs is
  the reason. The edge worth naming: a crash-recovery `pending` file
  partitioned under the OLD slug is not read after this upgrade. An updater
  relaunch follows a clean quit, which clears it.
- **Every op log and inbox manifest gains a `prev` per line and a seal line at
  its own cadence.** The added key is `"prev":"` plus 64 hex plus its quote and
  comma, and a seal line is one short object; the files stay plain JSONL and
  stay readable by eye.
- **A reader written before this milestone still works.** `prev` is ignored by
  every `Codable` decoder, and a seal line is filtered in
  `JSONLAppendStore.parse` — the one parser every reader shares (tails,
  decompressed segments, the inbox) — so no reader can hand a seal to an
  element decoder and then report the file as damaged.
- **Verification costs a rounding error against parsing, and the budget — as
  Denver restated it on 2026-09-09 — is met.** The budget is no longer an
  end-to-end subtraction, which cannot be measured on this box: it is the
  chain's own cost, read directly by the fixture, in two figures. The walk over
  a realistic tail (≤ 512 KB, some 600 lines) is to stay under **20 ms**, and
  the walk over the fixture's 8×-oversized 6,250-line tail under **100 ms**.
  Measured on a quiet machine at `4543b1a4`, best of three runs each, the
  50,000-line fixture (42 MB, seven signed segments plus that tail):

  | quantity | before | after |
  |---|---|---|
  | cold verified load (empty state) | 5934.2 ms | 514.6 ms |
  | warm verified load (state warm) | 5918.7 ms | 503.1 ms |
  | control (parse only, no verify) | 5832.0 ms | 421.5 ms |
  | chain walk over the live tail | 48.9 ms | 33.9 ms |
  | seven sidecar reads + signature checks | 1.7 ms | 0.8 ms |

  Against those numbers the oversized-tail figure holds as **measured** —
  33.9 ms against 100 ms — and the realistic-tail figure holds as **derived**:
  the fixture only ever walks its own tail, and a real one is a tenth of it, so
  the ≈ 3.4 ms quoted is the measured walk divided by ten, not a measurement of
  its own. The three end-to-end columns fell by about 91% because the DATE parse
  changed (`ISO8601Fast`, a hand parser for the two shapes this app writes, the
  formatter still behind it), not because verification got cheaper; the load was
  parsing and still is. What keeps the cost where it is, and must not be undone:
  `Hex` is table-driven (the obvious `String(format: "%02x")` spelling cost
  107 ms of a 109 ms `lineHash` total on that fixture), the settled-segment
  branch counts lines rather than splitting them, `prev(ofLine:)` reads the
  fixed `{"prev":"<64 hex>"` prefix by bytes, no date decode allocates a
  formatter, and the head persist is not coalesced (§3's crash window). Full
  tables in `docs/superpowers/notes/2026-09-09-perf-step-measurements.md`; the
  whole must-not-undo list with its reasons — count it there, not here — in
  `Maugham/OpLog/AREA.md`'s "Where the time goes".
- **The project stream is signed AND rotated, at the same 512 KB as every other
  tail** (Denver, 2026-09-09; one constant, `OpLogStore.segmentSealThreshold`,
  not two). `__project__` seals like any other stream now that `ProjectStore`
  holds one `OpLogStore` for its lifetime, and `sealTailIfNeeded` no longer
  refuses it. The open sweep in `DocumentStore.open` is its ONE boundary,
  because a document rotates at close and the project stream has no close; the
  sweep names it by hand and takes it last, since the manuscript-id reader
  `docIds(inOpsDirectoryFilenames:)` excludes it by contract. The residue: a
  session appending more than 512 KB of task ops (some 2,500 of them) carries
  the excess until the next open, which is accepted rather than fixed.
- **A check is not a load.** `ProjectIntegrity.check` classifies with no key and
  no remembered head, so its reading of a file is strictly weaker than the
  load's — it cannot see an after-remembered-head break at all — and it
  therefore records nothing. A check reports; the load records.
- **Checkpoints are not chained.** The spec names op log, inbox and registry as
  the chained streams, and `CheckpointStore` is deliberately not among them: it
  is a cold path written by ⌘S alone, already partitioned per device, and
  nothing derives a manuscript from it. Chaining it would buy an integrity
  guarantee over data that is not the words.
- **A device with no enclave is fully functional and fully unsigned.** CI's
  runner is such a machine, which is why every test asserting *verified*
  injects the test-only software signer in `DeviceIdentity+Testing.swift` and
  exactly one test per target touches the real enclave, skipping by
  **measurement** (`SecureEnclave.isAvailable`) rather than by platform guess.
  The Apple Silicon iOS simulator has one, so the phone's enclave test runs.
- **The writer cannot undo a `.lines` record.** There is no verb, and that is
  the decision: the bytes were not written by Maugham, the manuscript
  re-materialises without them exactly as an outside `.md` edit is discarded
  (2026-06-09's ruling), and the archive is there to be read.
- **P1 verifies only its own key, so a two-device writer sees their own phone's
  history described as unsigned.** The sentence is honest and the ops are
  applied; P2's registry is what turns most of it into *verified*.

## Enforcement / verification

- `TripwireGrepTests.test_noSoftwarePrivateKeyInProduction` — no production
  file under `Maugham/`, `MaughamPhone/` or `Packages/MaughamCore/Sources/`
  constructs a software `P256.Signing.PrivateKey(` (or a `Curve25519` key);
  `DeviceIdentity+Testing.swift` is the one allow-list entry, by name. A
  planted-offender companion proves the predicate fires and lets the sanctioned
  enclave spelling and a comment through.
- `TripwireGrepTests.test_noHostnameIdentity` and
  `test_noHandBuiltDeviceIdOutsideDeviceIdentity` — no production file derives
  an identity from `.hostName` or hand-builds a `"phone:` / `"unknown-host"`
  string, on either target or in MaughamCore — both Mac censuses scan
  `Maugham/`, `MaughamPhone/` and `Packages/MaughamCore/Sources`.
  `TripwirePhoneGrepTest.test_noHandBuiltDeviceIdOutsideDeviceIdentity` is the
  phone's own twin, folding both patterns into one test over `MaughamPhone/`.
  Each has a planted-offender self-check.
- `TripwirePhoneGrepTest.test_noPaletteAimWriterOnThePhone` — the aim picker's
  removal is invisible without it: a re-added `paletteSubject:` argument would
  compile and pass everything.
- `OpLogChainTests` — the verifier's classification, including a property test
  that a whole chain verifies and any flipped byte quarantines from there on,
  and the forged-seal, wrong-head and remembered-head cases.
- `ChainedAppendTests`, `OpLogVerifiedLoadTests`, `InboxChainTests`,
  `SegmentSealTriggerTests`, `HistoryPaneProvenanceNoticeTests`,
  `DeviceIdentityTests`, `PhoneDeviceIdentityTests` — the append order, the
  cross-reader agreement between `loadFileDiagnosed` and `loadSyncMerged`, the
  inbox's chained rows, the seal-before-rotate ordering, the two History
  sentences, and the identity itself on both platforms.
- `OpLogChainCostTests` — pins structurally that a remembered segment's lines
  are not walked at all (a counting seam on the verifier is the only way to see
  it, since the ops come out the same either way), and prints the book-scale
  numbers behind an env gate.

## Related

- `docs/superpowers/specs/2026-09-05-signed-op-log-design.md` — §3 (the
  decisions of record and the 2026-09-07 labels-only ruling), §4.1 (keys), §4.3
  (what is signed and at what grain), §4.4 (the states), §4.8 (the slug is the
  key), §4.10 (the inbox and the palette aim), §8 (the three plans; P1 is its
  first bullet, exactly).
- `docs/superpowers/notes/2026-09-07-signed-op-log-spike.md` — the enclave,
  keychain-sync, cost and propagation measurements this ADR budgets against.
- [ADR 0012](0012-per-device-jsonl-partitioning.md) — the chain is per file and
  the append rewrite is safe *because of* single-writer-per-(device, file);
  the slug's source changed, its contract did not.
- [ADR 0016](0016-op-log-growth-without-compaction.md) — the segment signature
  is a sidecar precisely so the sealed container stays immutable and unchanged.
- [ADR 0018](0018-manuscript-reads-derive-from-oplog.md) /
  [ADR 0019](0019-clean-md-on-disk.md) — why a line appended by something else
  would otherwise become the writer's words.
- `Maugham/OpLog/AREA.md` ("Chained and sealed", "Sealed segments"),
  `Maugham/Stores/AREA.md` (the inbox manifest; the `.maugham/` layout),
  `MaughamPhone/AREA.md` (the phone's writers and the aim's removal).
- CLAUDE.md tripwires 35, 36, 37 and 38.
