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

### 6. The verification states, and which of them P1 builds

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

**Amended 2026-09-10 (P2a): pending exists, and the rule between the
verification states is a verdict.** With a registry there is somebody to be
un-admitted, so `Line.State` gained `pending(device:)` and the walk takes a
`TrustVerdict` rather than a Bool. The mapping lives in exactly one switch,
`TrustVerdict.settling(sealKey:)`, so a new verdict is a compile error and
never a silent *unsigned history*:

| verdict | state | applied? | `.lines` record? |
|---|---|---|---|
| `.mine`, `.admitted(person:)` | verified | yes | — |
| `.stranger(device:)` | **pending** | **no** | **no** |
| `.revoked(person:_)` | quarantined | no | yes, *written after this device's access was withdrawn* |
| `.otherRoot(root:)` | quarantined | no | yes, *written under another claimant's copy of this book* |
| `.noChain` | unsigned history | yes | — |

The rule between them: **verified is applied, quarantined is refused and
recorded, pending is neither.** A held span is not wrong — the device that wrote
it may be admitted five minutes from now — so it earns no `.lines` record and no
quarantine sentence, and admitting the device applies everything it held on the
next read. The two new quarantine sentences are derived in the walk from
`OpLogChain.QuarantineCause`, like every other one, so no caller can file the
same event under different words.

**Decision B3, restated: no registry means P1's behaviour, exactly.** A device
with no chain resolves `myRoot` to `nil`, every foreign key answers `.noChain`,
and those lines are APPLIED as unsigned history. That is not a fallback bolted
on for compatibility — it is what `TrustResolution.keyless(mine:)` computes, and
it is why the whole P1 test body passes unchanged with pending in the tree.
A book nobody has joined never holds a word back.

**And a refused span does not break the chain.** A verdict is about whose word a
span is, not about whether the bytes follow from each other, so the walk carries
on and a later span from an admitted key still applies. Held-back lines are
therefore no longer necessarily a suffix on the READ path; `applied` filters by
state and never by position. The chained WRITE is unchanged and judges by
`.mine` alone (ADR 0012 gives the file one writer, which is what licenses its
truncating rewrite), so it cannot produce one.

**Amended 2026-09-11 (P2b): a device's ROTATED history is judged by the same
table as its tail, and that is a P1 behaviour change.** `OpLogStore.classifySegment`
had one arm P2a never revisited. When a sealed `.mzseg` segment's own container
signature does not settle — an unsettled segment — the reader falls back to
walking the lines inside it, and that fallback walk was **keyless**
(`trusted: { _ in false }`), so every inner seal answered `.noChain` and the
whole span applied as unsigned history. The consequence was that rotation, which
is maintenance a device performs on its own files, silently admitted the device
that performed it: a stranger's live `.jsonl` was held, and the same stranger's
`.mzseg` was applied unread. The fallback now passes the same
`TrustVerdict` closure `classifyTail` does, so a stranger's rotated history is
held exactly as its tail is. With no table in hand the keyless walk stands,
which is P1 exactly.

This is a visible change to a book that already exists. A writer upgrading a
project in which a second device had rotated will see history that was applied
before the upgrade read as **pending** afterwards — nothing is deleted, nothing
is quarantined, and admitting that device applies all of it on the next read.
Held-line counts are also a truer number for the same reason: a seal line is
held with the span it closes but is counted in no *N notes waiting* sentence,
because a seal is neither a note nor a capture (`OpLogChain.pendingByDevice`
counts op lines only; the line tallies still count the seal, and the two answer
different questions).

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

**Amended 2026-09-10 (P2a).** The prediction held — the wire format is
byte-unchanged — with one correction: `OpLogChain.verify` no longer takes a
`trusted` closure but a `trust` one, answering a `TrustVerdict` rather than a
Bool, because a Bool could not express *held*. The Bool overload survives as a
keyless shorthand and is P1's behaviour exactly.

**What P2a built.** The registry, as signed records under three directories:
`DeviceRecord`, `PersonRecord` and `ClaimRecord`
(`RegistryRecord.swift`/`RegistryCanonical.swift`), written by
`RegistryWriter` alone — which refuses an identity that is not the one the
record names, and refuses a device with no key, both before creating anything —
and read by `RegistryReader`, which verifies the filename, the presence of a
signature, the signature itself over the canonical bytes, the signer the record's
shape expects, and a device record's claim on its own author actor. Read
`MalformedRecord.Reason` for the whole list. People are read in two passes so that a person admitted
by a key that is nobody's root here is malformed rather than admitted. Malformed
records are listed and never read; a record that is present and unreadable
throws (`ReadError.unreadableFile(kind: .registry)`) rather than quietly
un-admitting somebody. `RegistryCache` is this device's own byte-faithful memory
of the last verified registry, restoring — loudly — a record that was deleted or
tampered with, and a registry deleted wholesale with it. `TrustTable`/
`TrustResolution` answer the verdicts (count `TrustVerdict`'s cases, not a
sentence); `RegistryPresence` writes this
device's record at `DocumentStore.open` (and, on the phone, at the first write),
with the first Mac in an empty book writing the root. History says what is held
and whose chain this Mac joined.

**The root order, and the rule that a device never switches chains** — the one
place P2a settled something §3's spec left open. `myRoot` resolves as: the root
already joined (write-once); else this device's **own** self-signed root record;
else a foreign root whose chain names one of this device's keys; else `nil`. The
second arm outranks the third because a self-signed root record for my key is
the one statement in the registry that nobody but this device could have
written, while an admission naming me is somebody's assertion. And a device that
holds its own root record **never joins another**: a foreign root that names it
is recorded as a claimant and its spans read `.otherRoot`. Otherwise any Mac
that can write the folder writes itself a root plus an admission of you and
takes over a book you created.

**What P2b built, 2026-09-11.** The prediction was admission, revocation, the
claim, People & Devices and the phone joining a chain. All five shipped, and
the rest of this section is what they turned out to be. The hole P2a carried
into P2b — a person record is keyed by its own fingerprint, so a verified root
can overwrite another root's self-signed record with an admission naming itself
— is closed by the **same-authority rule** below rather than by the claim path,
because the fix belongs where the record changes hands and not where a re-root
is asked for; the claim is the writer's way BACK, not the guard.

**P2 ships whole: the first tag that carries P2a carries P2b.** P2a alone is a
build in which a Mac that has rooted itself holds every phone op as pending with
no way to admit it — `ensureRootIfEmpty` writes this Mac a root at the first
open of every existing project, which closes B3's escape hatch for all of them,
and the phone's P1b-signed spans then classify `.stranger` → `.pending` → held.
Every phone annotation leaves the Annotations pane, every phone capture leaves
the Inbox, and History says *N notes are waiting for admission* beside a button
drawn disabled. Nothing is lost — no `.lines` record is written, no file is
rewritten, and admission re-reads — but for the length of such a build the
writer's own phone history is invisible with no recourse. That is a stronger
reason than the compatibility one the plan gives (that the phone learns to read
records in P2a), and it binds the release on the Mac's side alone. The Mac and
the phone still ship as a pair for the ordinary reason: the phone reads the
records the Mac writes.

**One thing had to be fixed before the first tag that carries P2a: the canonical
digest was lossy. Fixed in P2b Task 1, 2026-09-10.** A record's signature was
verified over a *re-encode of the decoded record*, and `JSONDecoder` drops
unknown keys — so a record written by a later build carrying one extra field
decoded, re-encoded without it, and failed to verify. It was unreachable at the
time (nothing in P2a writes an unknown field), but the moment a release ships
that writes records the canonicalization is frozen: changing it afterwards
invalidates every record already on disk, and P2b adds claims while P3 adds
roles. P2a being unreleased, the change simply invalidates the records P2a's dev
builds wrote (tripwire 11: delete and recreate).

**The canonical form, now frozen.** `RegistryCanonical.canonicalBytes(ofJSON:)`
is the one spelling and it takes BYTES: parse the JSON object, remove the `"sig"`
member by name, re-serialize with `JSONSerialization` under `.sortedKeys` and
`.withoutEscapingSlashes`. The digest is SHA-256 over those bytes, hex-encoded.
The writer encodes the record once and canonicalizes that; the reader
canonicalizes the FILE it just read — so a member this build has no property for
is part of what was signed on both sides, and an honest record from a later
build still verifies. Sorted keys because a dictionary's insertion order is not
a fact about the record (`actors` is one). Slashes unescaped because JSON permits
both spellings of `/` and a device name may hold one, so a canonicalization that
did not decide would give two devices two digests for one record. Dates are
already ISO strings in the JSON, so nothing on this path reformats one.

**A record changes hands only under the same key** (the same-authority rule,
`RegistryCache.reconcile`). The destructive half of the old shape was already
closed — `reconcile` restores only an ABSENT file, so a record it cannot verify
is reported and left exactly as it is rather than overwritten. What was still
open is the opposite direction: a person record's expected signer is the root it
NAMES, so a second root can write a perfectly valid admission of somebody this
device already verified, and the folder's copy simply won. The second Mac to
open a book could take over the first one's self-signed root record and the whole
chain hanging off it. So a folder record for a remembered fingerprint signed by a
key other than the one that signed the remembered copy is listed
`malformed(.signerChanged(expected:found:))`, the remembered record stands, and
the folder's file is left where it is. Where the refused record is the one about
THIS device, the displacing key is recorded as a claimant — B1's list is fed by
the refusal rather than silenced by it.

## Addendum — admission, the claim and the two shapes, 2026-09-11 (P2b)

P2a built the registry and the verdicts. P2b builds the acts: the writer says
who a device is, and can say so later that it may stop. Nothing below changes
the wire format, and nothing below refuses to open a manuscript.

### The records, and what a signature covers

Three shapes, unchanged from P2a: `DeviceRecord` (a machine declaring its own
name, kind and actor keys, signed by itself), `PersonRecord` (a root saying a
fingerprint is somebody, with the writer's own label, signed by that root — and,
for a root, signed by itself) and `ClaimRecord` (a root saying whose chains it
has adopted, signed by that root). Read `RegistryRecord.swift`, not a list here.

**The digest is lossless, and it is frozen.**
`RegistryCanonical.canonicalBytes(ofJSON:)` takes the FILE's bytes: parse the
JSON object, remove the `"sig"` member **by name**, re-serialize with
`.sortedKeys` and `.withoutEscapingSlashes`; the digest is hex SHA-256 over
those bytes. The writer canonicalizes what it is about to write and the reader
canonicalizes what it just read, so a member this build has no property for is
part of what was signed on both sides and an honest record from a later build
still verifies. This was the release blocker, and it was fixed first for that
reason: once a shipped build writes records, changing the canonicalization
invalidates every record on disk. Re-signing goes through the same door —
`RegistryCanonical.resigned(fileBytes:editing:signing:)`, which edits the FILE's
object rather than this build's decoded copy, so a revocation or a retirement
written by an older build does not quietly drop a newer build's field. The
one caveat worth recording: `JSONSerialization` normalizes numbers, and every
field of every record today is a string, an array of strings, a dictionary of
strings or an ISO date string — whoever adds the first numeric field inherits
that question.

**A record changes hands only under the same key** (the same-authority rule,
above). Its effect on B1 is the non-obvious half: refusing the displacing copy
would also hide the claim it represents, so the displacing key is recorded as a
claimant — heard *because* the record was refused.

**`MalformedRecord.Reason.signerChanged(expected:found:)`** is what that refusal
is listed as, beside P2a's reasons. Count the enum, not this sentence.

### The cache, and what it remembers

`RegistryCache` is this device's byte-faithful memory of the last verified
registry. P2b adds three things to it:

- **A dated restore list.** `reconcile` writes what it actually put back into
  `Project.restores`, bounded at `RegistryCache.restoreLimit` (50) per project,
  oldest dropped first. A restoration leaves no trace in the folder afterwards
  — the file is back and looks exactly as it did — so this list is the only
  thing that can say it happened, or when; dating it at read time would stamp a
  week-old deletion with the moment a pane was opened. Two surfaces read the one
  list: History's `.recordRestored` events and People & Devices' *put back
  9 Sep* row mark. A record deleted twice is two events and one row mark,
  because a timeline is what happened and a row is what holds.
- **`joinedRoot` is write-once, and now carries `joinedAt`.** The stamp is
  written in the same arm as the root and never moves; a claimant arriving moves
  neither. A memory written before this field loads with its join intact and a
  nil date, which is why every sentence about a join has a dateless form.
- **It is lazy about the enclave.** The identity behind the cache is this
  device's author fingerprint, and asking for it MINTS a key if there is not
  one. Most projects have no registry, so the file is read on the first real
  question and the identity is resolved only where the answer turns on it — a
  project with no registry and no cache file resolves none at all.

### The trust table

The verdicts are `.mine`, `.admitted(person:)`, `.stranger(device:)`,
`.revoked(person:highestOpIdSeen:)`, `.retired(device:retiredAt:)`,
`.otherRoot(root:)` and `.noChain` — count `TrustVerdict`'s cases, not this
sentence, which is why it gives no number. (It gave one until P2b's final wave,
and that number had been wrong since Task 7 added `.retired` directly beneath
it.) The mapping from verdict to line state lives in one switch,
`TrustVerdict.settling(sealKey:sealedAt:)`, so a new verdict is a compile error
and never a silent *unsigned history*.

**The root order is unchanged**, and the arms are numbered because the code
cites them by number (`TrustTable`'s own comments say *arm 3 of `myRoot`*):
(1) the root already joined, write-once; (2) else this device's own self-signed
root record; (3) else a foreign root whose chain names one of this device's
keys; (4) else `nil`. **A device that
holds its own root record never joins another** — a foreign root naming it is a
claimant, and its spans read `.otherRoot`.

**Adoption widens what a device verifies and moves nobody's root.**
`TrustTable.adoptedRoots` is every other root whose chain my root has adopted,
transitively, and `myChain` is the union of my root's chain with each adopted
root's. A root I adopted is mine. Adoption is **symmetric and not reciprocal**:
each Mac adopts the other by its own act, and until the other one does, this
device is still a claimant over there. A claim is a ROOT's act — a claim whose
`newRoot` is not a verified root here is listed malformed and adopts nobody,
which is why the claim path writes the root record first.

### Admission

**One device, one sheet.** A stranger's first held line raises a window sheet
(not app-modal — spec §4.1's "non-modal to the project window" means exactly
that), asking the writer who this machine is. The sheet says the device's own
name, its four-character code and what is waiting; the writer types a **label**,
and the label is the AUTHOR'S — a person is what the writer calls a machine, not
what the machine calls itself. A typed label matching one already in the book
merges under that label's existing spelling rather than minting a second person
by the same name. Escape is *Not now*, and the dismissal lasts until the next
open; History's own **Admit…** outranks it, because that is the writer asking.

**`AdmissionMemory` is device-local and has no project key.** What the writer
decided a machine is called is a fact about their decision, not about a folder,
so it is remembered once and applies everywhere. The label's own `labelledAt`
moves only when the label actually changes.

**Silent admission at open.** After the first sheet for a device, every later
project this Mac opens admits that device automatically, under the remembered
label and the device's own current name (decision B2). It runs only where this
device is a root, reads the folder once however many devices it admits, and
skips a device already admitted under another root — a silent open must not
fail over somebody else's admission and must not take it over.

**A malformed-only registry is not an empty book** — no root is written beside a
tampered one — and **a record that is present and unreadable refuses** rather
than being treated as absent (RULING-54). Admission would otherwise launder a
permissions error or a half-downloaded iCloud file into a new decision.

**The three acts of an admission, in order**: write the signed person record off
the main actor and **throw** any refusal (a sheet that closed on a write that
did not happen is a silence); invalidate trust everywhere at once — every open
document's store and the capture stream's own resolution, because an admission
that reached some readers and not others is a book where one key is trusted in
the editor and a stranger in the Inbox; then re-read every open document, so
what was held reaches the draft in front of the writer rather than at the next
open.

**Pending is op lines only.** Every sentence built on this number puts a noun
after it, and a seal is neither a note nor a capture.

### The two shapes History draws (Denver's ruling C)

**A banner is a fact that holds now; a dated entry is something that happened.**
P2a had only the first shape, so a person admitted in June and revoked in
September read exactly like a person who was never here.

The banners are the pending count with its Admit…, *This Mac is on <label>'s
chain* (re-worded from P2a's *joined*, which is an event), and the retired-Mac
notice. The entries are `TrustEvents.derive(registry:cache:mine:for:)` in
MaughamCore — pure over a verified registry and a loaded cache, no clock and no
folder read, which is what makes every arm assertable as a value and safe to
call from a surface — drawn under one **Project** heading at the top of the
pane and never interleaved into the document timeline, because trust is the
book's and the rows below are one document's.

`TrustEvent.Kind`'s cases are the kinds; count them there. What is worth
recording here is what each is derived FROM, since none of them is stored: an
admission from a person record's `admittedAt`, a revocation from `revokedAt`, a
retirement from a device record's `retiredAt`, a claim and its adoptions from a
claim record, the join from this device's own cache, a claimant from the cache's
claimant list, and `.recordRestored` from the cache's dated restore list. A
root's self-signed record is deliberately not drawn as an admission: *Denver
admitted by Denver* at the foot of every book is an event in which nothing
happened. Newest first, undated last. **No sentence carries a date** — the row
draws one when there is one, and two kinds are honestly undated (a claimant, and
a join from a memory written before the stamp existed).

**The derivation is over records, so clearing a field takes its event with it.**
Re-admitting a revoked person clears `revokedAt`, and the revoked entry goes
with it — revoked-then-re-admitted reads as one admission rather than two dated
events. Accepted for P2b; a durable event log is P3's.

### Revocation, retirement, and the way back

**Revocation is the root's.** Only the root that admitted somebody may revoke
them, a root is claimed over rather than revoked, and a second revocation would
move the line the first drew. The record gains `revokedAt`, `revokedBy` and
`highestOpIdSeen` — the mark of what this Mac had already applied — and both
verbs confirm first, with the consequence in the alert rather than the verb.

**A revoked span is refused whole and filed in two halves.** The walk sees seals
and chains, never opIds, so it refuses the span under one cause and
`classifyTail`, which has the parse in hand, splits it against the mark: above
it is *written after this device's access was withdrawn*, at or below it is *may
be late sync, or may be backdated*, and a seal line goes with the strict half
unless nothing else is there. **Nothing is applied either way** — the split is
about the words the writer is owed, not about the refusal. The mark is computed
from OPEN documents only, so a chapter nobody has opened can hold ops above it.

**There is no Apply on the late-sync half, and its absence is deliberate.** A
`.lines` record has no return path at all (`attemptReturn` refuses one on its
first guard) and nothing for one to return TO — the ops are still in the live
per-device log, which is what the verdict is refusing. What refuses them is the
verdict, which quarantines the whole span at every load regardless of opId. So
an Apply built on the existing path would be a control that looked like it did
something and did nothing. Making it real needs a durable **per-span exception**
threaded through the trust table — new persisted state and a new trust input —
and that is **a P3 decision for Denver**, not a switch.

#### Amendment, 2026-09-18 — what a revocation costs is the writer's choice

The two paragraphs above describe what shipped in P2b and are superseded by
Denver's ruling on the P2 smoke's find 5. They are kept because the reasoning
behind the Apply still stands and P3 inherits it.

**What was wrong.** A revocation stripped everything that device had ever
written, including the paragraphs that were in the manuscript before the writer
revoked anybody. The smoke made it plain: Mac B's only op WAS the revocation's
own `highestOpIdSeen`, and it left the chapter with the rest. The split existed
but decided only which of two *sentences* a refused line was filed under. The
spec said only spans *arriving later* were held; the code held all of them.

**What ships now.** The cut is made BEFORE the parse, in both the live-tail and
the rotated-segment paths: `RevocationSplit.partition` answers which lines this
Mac had already applied and `OpLogChain.readmitting` re-settles them, so an op
at or below the mark stays in the book and one above it is set aside as before.
A seal travels with the op immediately before it in file order; a line with no
op before it stays refused. `Verification.head` does not move — it is what the
next chained append builds on and a re-admitted line is not a suffix.

**Why nothing is newly trusted.** The mark is this device's own record of how
far it had got with that device, not that device's word about itself. A line at
or below it is one this Mac had ALREADY APPLIED while they were admitted, so
keeping it is not the revocation believing a revoked key — it is the revocation
declining to reach backwards into work the writer has read, redrafted and, in
Denver's case, published. What the device wrote after the door closed is refused
exactly as it was. The claim this makes is about THIS device's past reads; it
gives a revoked key no standing anywhere else.

**And the old behaviour is a choice, not a casualty** (`RevocationScope`). *Set
aside everything it wrote* records no mark, which is how a reader has always
been told that nothing of theirs was ever already here, so the whole history
leaves the book until they are re-admitted. It is offered as a second
destructive button on the same alert, with its own sentence, because the two
costs differ and one shared message would have the writer choosing between two
things they were told the same thing about. History tells the two apart from the
record itself — a mark present or absent — so nothing new is stored to say it.

**The mark had to become honest for any of this to be safe.** It was computed
over the documents a window had OPEN, which is nil for a writer revoking from
Project Settings with nothing open — the ordinary way to reach the button — and
nil means keep nothing. It is now taken over every op-log file in the project
(plus the open documents from memory), read-only, once, behind the confirmation
the writer is already looking at.

**A revocation refuses rather than guess, and it always records which button
was pressed** (find-5 review). The mark used to be a single optional, so *this
book applies nothing of theirs* and *a file would not read* both came back nil —
and nil is the wire spelling of *set aside everything it wrote*. A read hiccup
therefore turned the writer's gentle press into the harsh choice and History
narrated it as one. Now the sweep answers three things. A mark is a mark. Where
this book applies nothing of theirs the gentle press records
`RevocationScope.nothingAppliedMark`, the lowest ULID: it keeps exactly nothing,
which is the truth, while leaving the record able to say which button was
pressed. Where a file or the registry will not read, the revocation REFUSES —
`RegistryAdmissionError.historyUnreadable`, nothing written, the file named —
because a mark that came back short silently widens what a revocation takes
back, and the shortest of all is indistinguishable from the other button. A nil
mark remains the one spelling of *set aside everything it wrote*.

**Dev records written before this carry nil for both meanings.** They are not
migrated: tripwire 11 — delete the dev registries and recreate, as P2b's own
release note already requires.

**Why a line was refused is a fact about the LINE.** `Verification.quarantineCause`
is one cause for a whole file and it is the FIRST one the walk met, so a splice
after a revoked seal wore the revocation's name; the cut, judging by op id, put
forged text back into a manuscript on the strength of a number the forger chose
(`highestOpIdSeen` is written into a signed record every device reads).
`OpLogChain.Line.refusal` now travels with the line and is what the cut asks; a
line refused for a chain fault, a truncation, another claimant's root or a
retirement is no candidate whatever its op id. A set-aside record is filed under
the reason its own lines carry, so a splice is reported as a splice rather than
as the writer's other Mac having written after the door closed.

**The late-sync distinction is deferred, not deleted.** `revocationLate` and its
sentence are gone from the code, because the lines they described are applied
and a cause with no producer is a rule waiting to be made load-bearing wrongly.
Telling *already applied here* from *an old id arriving late* still cannot be
done with what this device stores: `highestOpIdSeen` is a scalar, and below it
the two are indistinguishable. `OpLogDeviceState`'s remembered head WOULD decide
it unforgeably, but it is kept only for files this device has written and this
device never appends to a foreign device's file. Making it decidable needs a
head remembered per FOREIGN file — device-local state, not a new record kind,
through the additive `remember(head:for:)` that already exists — and it only
helps if recorded BEFORE a revocation. That, with the per-span Apply above,
is **P3's**.

**Re-admission by the root is the inverse of revocation.** Admitting a revoked
person under my root clears `revokedAt`/`revokedBy`/`highestOpIdSeen` and
preserves the original `admittedAt`, because any admission written by the
admitting root IS that root saying the device may write. People & Devices draws
**Re-admit** where the revoked row would otherwise carry a dead Revoke.

**Retirement is the device's own word about itself**, signed by its own key, and
true whether or not anybody admitted it. Peers quarantine what it seals at or
after that moment, by date, so a span sealed before it stays verified. **A
retired Mac still applies its own later writes locally** — `.mine` outranks
retirement, and a table that answered otherwise would have the chained write's
truncating rewrite set aside the file this device wrote — so the machine is
TOLD: a standing banner in History and a mark on its own row in People &
Devices, in one set of words shared with the phone. **There is no un-retire.** A
device that retired can only come back as a new key.

### The claim — a keyless Mac, and the two-roots exit

**A Mac holding a book it has no key in is asked one question, once per project
per launch**: *is this book yours?* It is asked only where all three conditions
hold — this device has joined nobody and is nobody's root, the book HAS a root,
and this Mac can actually write the registry folder. The last is a probe and not
a promise, which is why the claim still throws and the sheet still carries a
refusal; what it buys is not asking a question this Mac could not act on.

**Claiming is two writes and the order is the contract**: this device's own
self-signed root record FIRST, then the `ClaimRecord` naming the roots it
adopts. A claim written alone is malformed and adopts nobody. **A claim adopts
every root it found**, because the question is about the whole book and
answering it by halves is not something the writer was offered.

**Two roots leave mutual quarantine by adopting each other**, and it is the same
call made on each Mac. Afterwards each answers `.admitted` for the other's
devices, `adoptedRoots` holds the other on each side, and **`joinedRoot` is nil
on both** — a merge widens whose history a device verifies and moves nobody's
root. *Not mine* writes nothing and leaves B3 exactly as it was.

**A Mac already on somebody else's chain cannot merge.** It has no root record
of its own to sign a claim with, and a non-root signs no claim any reader takes,
so the verb refuses.

**`claimedAt` does not move when a later root is adopted**, so History dates a
later adoption on the day the book was claimed. The alternative moves the
*claimed this book* event instead, which is worse.

**Amended 2026-09-18, from the P2 smoke: a second root is a claimant whether or
not it has said anything about this device.** The rule above is stated as
displacement — a foreign root that names one of my keys, or a `signerChanged`
listing over a record of mine — and both halves require the other Mac to have
mentioned me. The two-roots exit does not arrive that way. A Mac that claims the
book writes its own root record and a `ClaimRecord` adopting mine, and a claim
is signed by that root ABOUT that root: it names none of my keys and displaces
none of my records. So the Mac being merged WITH listed nothing of the Mac doing
the merging, offered no Merge, and the exit could only ever be walked from one
side — and two Macs that each rooted an empty book and have claimed nothing were
the same silence with no claim record in it. The rule is now: **a verified
self-signed root that is not one of this device's keys, is not the root it is
on, and that it has not adopted is a claimant** — listed, with Merge offered.
Its converse is the half that keeps adoption the writer's own act: **a root this
device HAS adopted is merged and never listed, reciprocated or not**, because
`adoptedRoots` deliberately does not widen on somebody else's claim (B1) and the
writer's own claim is their answer to the question the list exists to ask. It is
decided in one place beside the other two rules, never in a view, and it moves
no `TrustVerdict`: a foreign root's keys still answer `.otherRoot` and are still
refused. A device on NO chain lists nobody — its surface for a book full of
somebody else's history is the claim sheet above, and recording a root it has
not joined yet would leave that root warning for good after it admitted this
device.

### What the phone does

The phone reads and never writes a registry record, and it holds no root: a
phone that could sign a person record could admit itself. Settings gains a
**This device** section — this phone's four-character code, whose whole job is
to be compared with the code on the Mac's sheet, then one line per book it has
been in, in `DeviceStanding`'s words, which are the same words the Mac's People
& Devices draws about itself. No control: admission is a Mac act in this
milestone. A retired phone is told so in the same sentence the Mac uses about
itself, with its own noun. The per-write memo is the phone's one optimisation —
declaring itself is idempotent but not free, so the facts it declared are
remembered per project, in process, and a declaration that threw is never
remembered.

### What P3 still owes

Roles and the per-op-kind check; the per-span Apply exception ruled on above; a
durable trust event log, so a revocation survives a re-admission as a dated
fact; and more of this drawn on the phone than one line per book.

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
one actor; every read judges by **all four**, because the assistant's seal over
the assistant's own file is this device's own word. (P2a retired the value that
used to say so: `ChainPolicy.trustedFingerprints` is gone and `ChainPolicy.trust`
is a `(String) -> TrustVerdict` in its place, with the four local keys as the
`.mine` arm of `TrustTable` — a set could only answer *mine* or *nobody*, and
admission put four more answers between them.) A narrower set would file the writer's own
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
- `TripwireGrepTests.test_theRegistrysWritersAreThreeFiles` — every production
  caller of `RegistryWriter.write` / `writeUnchecked` / `restore` / `resign` is
  in `RegistryPresence.swift`, `RegistryAdmission.swift` or
  `RegistryCache.swift`. The authority rules are not inside `write` — who may
  revoke is `RegistryAdmission`'s, a device signing its own record is
  `RegistryPresence`'s — so a fourth caller reaches the signature without
  reaching the rule. `TripwirePhoneGrepTest.test_thePhoneWritesNoRegistryRecord`
  is the phone's twin and allow-lists nobody at all, with planted offenders on
  both sides.
- `RegistryCanonicalCensusTests` — two censuses over
  `Packages/MaughamCore/Sources`, `Maugham/` and `MaughamPhone/`. The first:
  no registry/trust source may name `JSONEncoder(`, `JSONSerialization` or
  `SHA256`, allow-listed by file **plus spelling** (`RegistryCanonical.swift`
  all three; `RegistryCache.swift` and `AdmissionMemory.swift` the encoder
  alone, for their own persisted stores, and still caught reaching for a hash).
  The second, and the stronger: the set of production files naming `digestHex(`
  is exactly the writer, the reader and `RegistryCanonical` itself. Its known
  limit, stated so nobody has to rediscover it: a new file that hand-rolls
  `JSONSerialization` plus `SHA256` without calling `digestHex` escapes both,
  which is what the first census's spelling ban is there to catch.
- `RegistryAdmissionTests`, `RegistryCacheTests`, `TrustTableTests`,
  `TrustEventsTests`, `PendingLoadTests`, `OpLogQuarantineTests`,
  `AdmissionDecisionTests`, `AdmissionSheetTests`, `ClaimDecisionTests`,
  `PeopleAndDevicesModelTests`, `DocumentStoreAdmissionTests`,
  `InboxPendingTests`, `DeviceStandingTests` — admission and its refusals, the
  same-authority rule, the verdicts and the retirement date, the derived
  events, a stranger's held tail and held segment, the revocation split, the
  sheet's copy and its queue, the claim and the two-roots exit end to end, the
  section's rows and which verbs this Mac may press, and the phone's standing.
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
- `docs/superpowers/specs/2026-09-09-signed-op-log-p2-people-and-admission-design.md`
  — P2's own spec: §2 the records and the memory, §3 naming and presence, §4
  admission and the sheet, §5 revocation, retirement and the claim, §6 the
  surfaces.
- `docs/guide/people-and-devices.md` — the same thing in the writer's words.
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
