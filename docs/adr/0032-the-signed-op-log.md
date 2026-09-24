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

**Amended 2026-09-20 (P3a Task 11): the verdict settles a SPAN, sealed or not
— and the table above is about a span rather than about a seal.** Trust was
consulted at `case .seal` and nowhere else, so everything a signed foreign
device had written *since* its last seal — up to `chainSealInterval − 1` ops, or
its whole file before its first one — was `.unsealed`, not held back, and
applied, whatever the register said. A stranger's text entered the manuscript
unadmitted and a revoked device's post-revocation tail leaked; the permit
partition skipped those spans too, for want of a key to attribute them to. This
shipped in v0.39.0/v0.40.0 and was found by the 2026-09-20 audit (PR #65, F1 +
F2). Every P2 fixture sealed before it asserted, which is why nothing was red.

**The file's key**, asked once at end-of-walk, in three arms: the key of the
LAST seal in the file that parsed and chain-verified, *whatever its verdict* —
ADR 0012 gives a file one writer, so a stranger's seal names the file as surely
as this device's own; else — **or where that seal's key is one the register
cannot attribute to anybody** — the key the caller can name for the filename's
slug, matched against a verified record (a claim checked, never believed); else
**neither, and the span stays exactly as it was**. Arm 1 falls through rather
than winning outright because one seal under a throwaway key would otherwise buy
the unsealed remainder a gentler answer than the file's own name deserves; the
fall-through cannot widen, because an unattributable verdict only ever holds or
leaves alone, and arm 2 is consulted only when it answers a state at all. That third arm is decision
B3's door, held open deliberately: an unsigned device — a VM, CI's runner —
writes chained lines nothing seals and reports nothing wrong, and pre-signing
legacy history is in the same arm. Closing it is a P3b question.

What the span becomes is `TrustVerdict.settlingAnUnsealedSpan`, a sibling of
`settling` rather than a call into it, because two arms cannot be answered the
same way. `.mine`/`.admitted` leave the span `.unsealed` rather than calling it
verified — nothing has signed these bytes, and more sharply, **this device's own
unsealed tail must never be held or refused**: typing appends unsealed lines all
day, and the chained write's own `.mine`-only closure would otherwise refuse to
seal the very file it is appending to. `.retired` keeps rather than refuses,
because its answer turns on when a seal was made and there is no seal; the two
readings are *before it retired* and *at or after it*, and refusing would set
aside the last tail of every device that ever retired — words written while the
machine was still in use, since retiring seals no op log — under a sentence that
is false about them. Its SEALED post-retirement spans are refused exactly as
this addendum's predecessor refuses them. The residue is bounded: a retired
device that goes on writing keeps at most `chainSealInterval − 1` ops applied,
because the app seals after every burst and at every close.

This too is visible on a book that already exists, in the same direction P2b's
rotation amendment was: a stranger's unsealed tail that applied before the
upgrade is held afterwards. Nothing is deleted and admitting the device applies
all of it on the next read.

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
with the first Mac in an empty book writing the root — and re-signs it, before
the first line, when a key the lazy `LocalIdentities` minted after the open is
about to sign one (`declareActor`, P3b smoke find F6; without it a Mac's first
Claude write of a session was held on every other Mac until it relaunched). *Before
the line* is ordering on the writing Mac's disk only, so the receiving Mac also
re-judges when a record lands after its line: its presenter routes the registry
folders and re-reads what is open, and ignores an echo of its own writes. History says what is held
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

**A revocation reaches the OPEN chapter, and says which choice it was** (Denver's
re-smoke, 2026-09-19). Two things shipped wrong and both were about the same
asymmetry: every verb before revocation only ever ADDED. `handleExternalLogChange`'s
echo guard therefore asked *is anything new* and returned when there was not,
which is precisely what a narrowing of trust produces — so the record was
written, the `.lines` record filed, and the revoked device's paragraph stayed in
the live document until the project was closed and reopened. The guard now also
asks whether ops have LEFT; everything past it was already a rebuild from the
loaded ops, so nothing else had to change, and retirement and a registry Restore
arrive down the same path. And `QuarantineCause.afterRevocation` now carries
`keptNothing`, read off the revocation record's own missing mark: under *set
aside everything it wrote* a paragraph from last June is refused too, and filing
it as *written after this device's access was withdrawn* is false about the one
thing the record exists to say.

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

**Amended 2026-09-23, from the P3b smoke (find F3; Denver's ruling C): nobody is
asked.** The three conditions describe an invited collaborator's Mac exactly as
well as the writer's restored one — every Mac declares its own device record at
open, and a restored Mac holds a new key — so the open put *is this book yours?*
to the collaborator, and *Claim* would have made her a second root. No predicate
over the folder tells the two apart (a narrower one, *this Mac holds history of
its own nobody can attribute*, was considered and is unreachable in practice: a signing
Mac's lines are attributable through the device record it writes at open, and a
Mac that cannot sign cannot claim). So the claim is a VERB, not a question: *This Book Is Mine…* in People &
Devices, offered where the three conditions hold AND this Mac can sign, confirmed
on the same sheet (*Claim* / *Cancel*), performed by the same
`DocumentStore.claim(adopting:)`. The open presents nothing, and the claim sheet
is built in `ProjectSettingsSheet` alone (`ClaimDecisionTests`' census).

**Claiming is two writes and the order is the contract**: this device's own
self-signed root record FIRST, then the `ClaimRecord` naming the roots it
adopts. A claim written alone is malformed and adopts nobody. **A claim adopts
every root it found**, because the question is about the whole book and
answering it by halves is not something the writer was offered.

**Two roots leave mutual quarantine by adopting each other**, and it is the same
call made on each Mac. Afterwards each answers `.admitted` for the other's
devices, `adoptedRoots` holds the other on each side, and **`joinedRoot` is nil
on both** — a merge widens whose history a device verifies and moves nobody's
root. *Not mine* (since F3, the confirmation's *Cancel*) writes nothing and
leaves B3 exactly as it was.

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

## Addendum — the permit, enforced, 2026-09-20 (P3a)

P2 asked one question of a key: *is this somebody this book admits?* P3 asks
the next one — **admitted to write WHAT** — and answers it where lines are
read. No surface; a permit cannot yet be given to anybody from inside Maugham
(that is P3b), and the membrane and the phone are P3c's. What ships is the
mechanism, and it is **behaviour-neutral for every book that exists**: a book
with no permit events makes every admitted person an author of the whole book
from the start, which is exactly what P2 meant, and the whole P2 suite passes
untouched.

### The ladder, and the one table

Three rungs (spec §2): a **reviewer** may sign annotations, edits of their own
annotations, and inbox rows; an **author of some pieces** may sign everything
inside her pieces and takes the reviewer's row everywhere else; an **author of
the whole book** may sign everything, project statements included. `Permit` is
the value, `Permit.allows` the one table, and its switch over `OpKind` carries
no `default:` on purpose — a kind a later build adds fails to compile there
until somebody decides who may sign it. Which ops become words is **asked of
`Deriver.appliesToManuscript`** rather than restated: a second copy would
drift, and the drift would wave a prose-moving kind through on the reviewer
row.

**The fourth answer is the one that matters most.** A permit is parsed from
strings in a signed file, and a build meeting a `role`, a `scope`, an event
`kind` or an `OpKind` it does not recognise has met a LATER build's
vocabulary. It must not guess, and above all must not guess *reviewer*: an
unrecognised anything holds that person's lines PENDING and never sets them
aside. `Permit.unjudgeable` and `Allowed.cannotJudge` are how that reaches the
table. An older Mac must not quarantine what a newer one would apply.

**The actor rows are the constitution's sentence at the storage layer.** A
person's permit gates their devices; the actor gates each of that device's
four keys within it. `assistant` — anything through MCP — gets exactly the
reviewer's row, which is what *MCP never mutates manuscript text* becomes when
it is enforced by the reader rather than by the tool catalogue;
`translator` gets a row of its own (translation records and nothing else);
`maugham` signs only the rebalance; `author` keeps everything the person's own
rung allows. These bind in EVERY book, evented or not — they are not a permit
anybody was given, they are what each key is for.

### Events are the history, and the timeline is what the check reads

`PersonRecord.role` is a convenience: what somebody may write *today*. What
judges a LINE is the permit its signer held **when they wrote it**. A person
demoted on Tuesday wrote her chapters on Monday as an author; a check reading
the record's field would set every one of them aside, and the same mistake in
the other direction would pardon text the book had already refused. Both
failures are silent.

So the register gains a **fourth directory**, `.maugham/people/events`, one
signed record per event (a shared append-only file is tripwire 17), written by
`RegistryAdmission` alone and spelled — like the other three — only in
`RegistryWriter.directoryURL`. `PermitTimeline` turns a person's events into
an ordered run of `(permit, mark)` entries; `TrustTable` builds one per person
from `TrustResolution.verifiedRegistry`'s single read, and the permit travels
to the walk on the verdict. There is **no second table** (tripwire 39).

Two authority questions guard an event, and the second is about its subject
rather than its signer. `RegistryReader` lists an event malformed when its
signer is not a root entitled to make it
(`MalformedRecord.Reason.eventSignerHasNoAuthority`) — an event whose subject
has no person record yet counts only when `by` is a verified root, because the
write order is event-then-record and that window is real. And a root is an
author of the whole book unconditionally, so an event that would narrow one is
`Reason.eventDemotesARoot`: `Registry.chain(underRoot:)` includes the root
itself, so entitlement alone cannot catch the one file that would leave a book
with no author.

**What governs the lines before a person's first event depends on that
event's KIND**, and it is not a detail. An `admitted` or `silentlyAdmitted`
event's permit governs everything on both sides of its mark — nothing precedes
an admission, and a stranger's HELD manuscript text would otherwise fall to the
book-author default the moment she was let in as a reviewer. A
`roleChanged`, `scopeChanged` or `readmitted` event first means the person was
admitted under P2, so the opening stays book author: **a demotion must not
reach back**. An unrecognised kind first leaves the opening unjudgeable, so
those lines are held pending rather than guessed at. `revoked` and `retired`
are skipped when finding *first*, because neither installs a permit.
`PermitTimeline.opening(before:)` is the five arms; read them, not this
paragraph.

### A mark is chain positions, and two alternatives were rejected

An event needs to say *from when*. P2's mark is one opId per person
(`highestOpIdSeen`), and P3 does not use it, for two reasons found in design:

- **An opId is not evidence.** Its ULID timestamp is chosen by its own writer,
  so a demoted author could stamp new text with an old id and slip under the
  mark. A mark made of the subject's own claims is not a mark.
- **This device's own memory is worse.** Fix the first by marking against what
  THIS Mac had recorded, and a fresh Mac with no memory applies what the root's
  Mac refused. The divergence is silent and permanent, and it is exactly the
  class of bug the whole signed op log exists to remove.

A mark is therefore **positions in the shared bytes**, per STREAM of the
subject's — `<docId>.<slug>` and the translation and inbox streams alike: the
**digest of every whole segment** the root had read and judged, and the
`OpLogChain.lineHash` of the **last line** it had read and judged. Keyed by
stream rather than by filename, because a rotation moves the marked line out of
the tail and into a `.mzseg` without changing anything about the chain; ordered
by containment rather than by a segment index, because an index is part of a
filename and a filename is not evidence either. Every device computes the same
answer from the same bytes.

**SEEN, not applied** (corrected during the P3a build; spec §3.3 amended in
place). A mark does not bless lines — it selects which permit judges them.
Were it *the last line applied*, refused text sitting at the end of what the
root had read would fall after a promotion's mark and be applied under the new
permit, which is the pardon this milestone forbids; and a segment holding one
refused line, left out of the mark for that reason, would have its honestly
applied lines re-judged under a demotion's permit. *Seen* excludes only a torn
tail and what a broken chain quarantined. **A revocation is the one act whose
mark means APPLIED**, because *keep what this Mac had already applied* is about
the draft the writer has been reading — so the store answers two questions,
`OpLogStore.seenPositions` for permit events and `OpLogStore.appliedPositions`
for a revocation, and `DocumentStore.permitMark(forPerson:seen:)` chooses.

### The check is line by line, and it runs where the revocation cut runs

Spec §4.9's *quarantined whole* is superseded: a batch is not a unit of
authority. `PermitPartition` judges **each line**, before the parse — a line it
refuses must never reach the element decoder, and a line it holds must never
reach the document — and it runs immediately after `RevocationSplit`, which is
the only order in which both answers survive: a revocation is a verdict about a
whole KEY cut on a mark, a permit is about one line judged against the history
its signer had at that line.

A refusal is `QuarantineCause.notPermitted`, carrying the person, the rung, what
was refused and whether the line fell after a mark, so the sentence can say
which. A line the build cannot judge is **pending**, held with no `.lines`
record, because nothing is wrong with it.

**Annotation amendments are judged as of the line.** Editing or withdrawing a
note is on the reviewer's row, and *whose note* is a same-person rule rather
than a per-file one. Judged by the signer's CURRENT permit, a demotion would
revert an author's honest edit of a reviewer's note and a promotion would
pardon an ignored withdrawal — the two-sided failure again. So the partition
carries the governing permit out per amendment op (`AmendmentPermits`, empty
for every existing book) and `AnnotationOwnership` honours the amendment under
the permit that was in force at that line.

**Where the partition runs is a named list**, not a number in prose:
`OpLogStore.partitioningByPermit` (the op-log door, reached from the live tail,
a settled segment and the fallback walk), `OpLogStore.verificationForPositions`
(the mark sweep, which must judge a file exactly as the load does or the two
would cut it in different places), `TranslationStore.loadMerged`, and
`JSONLAppendStore.loadVerifiedStrict` for the inbox manifest and the annotation
log. `TripwireGrepTests.partitionCallSites` is the array.

### The load asks the question of itself

`Document.load` writes before it reads, so it has to know whether this device
may write this piece before its first line exists.
`OpLogStore.localWritePermit(as:documentClass:)` is the one function that
answers — this device's own timeline, narrowed by actor, against the stream's
class — and it never throws and never suspends. Where the answer is no, the
load mints nothing and refuses with `DocumentLoadError.waitingForPiece`,
because on such a device *no op log* means *its ops have not synced yet*
rather than *a new file whose `.md` is the seed*, and a bootstrap the partition
sets aside derives the document EMPTY.

**The Bootstrap invariant is amended to match**: `Bootstrap.run` must be called
from any new manuscript load path *that may write the piece*. The contract
surface is still `Document.load` and `BootstrapWiringTests` still enforces it.

**And everything the load path emits on its own account is the AUTHOR actor's,
whoever opened the file** — the bootstrap, the two pending-recovery folds, the
task anchors `rebuildTasksCache` splices back in and the `taskCreate` beside
each. None is the act of whoever opened the document, and every one is a kind
the table refuses to `assistant` and `translator`; they are the writer's own
words arriving through whichever door happened to be first.
`Document.authorEmissionDevice(loadedAs:)` is the redirect. Only what the
CALLER then writes stays the calling actor's, which is what tripwire 38 has
always been about: the actor names who is acting.

### Possession, and a contested key

A device record lists the fingerprints of its four actor keys — and **nothing
proves possession of a listed key**. The actors map is a claim inside a
signed record, and only the author slot is self-proving (the record is signed
by it). Under permits the join decides which permit judges a line, so guessing
is worse than asking:

- the **author** slot is proven and wins;
- a non-author key with exactly ONE claimant is that device's, whatever its
  standing;
- a non-author key **two or more device records claim is NOBODY's, forever** —
  whoever is revoked or retired later.

Standing plays no part, and that is the second draft of this rule rather than
the first. Awarding a disputed key to the only *standing* claimant let a
revoked owner's later lines read as the standing liar's — the same defect from
the other side. `Registry.actorKeyOwners` is the one resolution, and the three
sites that used to join first-wins by sorted fingerprint all ask it.

**The residual is named rather than papered over**: an admitted device can now
hold another person's NON-author actor lines pending indefinitely by listing
that key, and revocation no longer cures it. It costs availability and never
words (the lines stay in the log and apply the moment the dispute is resolved),
it never touches the author key, and the cure is a format change — per-actor
possession proofs in the device record — filed under the roadmap's *Signed
structure* item.

### A sweep that cannot read refuses; it never shortens

Four verbs compute a mark — admit, changePermit, revoke, retire — and a mark
that does not NAME a stream judges that stream wholly new. So a sweep that
comes back short is not a small inaccuracy: it turns a lost or evicted file
into a demotion that reaches back through every line of it, or a *keep what was
applied* revocation that sets aside words this Mac had already put in front of
the writer. Every one of the four therefore **refuses and writes nothing** — no
event, no record — when it cannot list an existing directory, cannot read a
present stream file, meets an old-style `.icloud` placeholder standing in for
one, or cannot name a stream this device REMEMBERS having read
(`ReadError.unlistableStreamDirectory`, `ReadError.streamMissingFromSweep`).
Retirement refuses with the others: its mark is what P3b's *N paragraphs
written while retired* is derived from, and an empty mark would call a whole
history post-retirement. The refusal is the existing `historyUnreadable`
sentence, which now names the ACT it is about — `RegistryAdmissionError.Act`,
four words for four verbs — because a writer who pressed *make Sam a reviewer*
should not be told a revocation was refused. The silent admission at project
open is the one exception and skips rather than blocking the open.

**Remembered foreign streams** are what make *absent* distinguishable from
*never existed* — and they are their own finding as well. `ForeignStreamWatch`
records, per stream, the head this device last saw and the digest of every
segment it took in whole, but **only once that stream has ANSWERED**: a file
that is present, readable and yields nothing this device can point at (a
zero-byte `.jsonl` that synced ahead of its contents) would otherwise be
demanded of every later sweep for ever. A stream that answered and has stopped
is the truncation case, reported and never refused — the surviving lines stay
applied, because they are exactly what a backup is for — and the finding CLEARS
when the bytes come back.

### Task 11 — an unsealed span answers to its file

Recorded above, as an amendment to §6 where the states are defined, because it
corrects §6 rather than extending it: trust was consulted at `case .seal` and
nowhere else, so a signed foreign device's writing since its last seal was
applied whatever the register said. It shipped in v0.39.0/v0.40.0 and was found
by the 2026-09-20 audit (PR #65, F1 + F2). **Release consequence**: on books
that already exist, a stranger's unsealed tail that used to apply now waits for
admission. Nothing is deleted, and admitting the device applies all of it on the
next read.

### What P3a does NOT do — the limits, stated

- **Roles guard the words, not the binder.** `OpKind` has no structural cases:
  create, rename, reorder and trash go through the unsigned manifest, and
  `__project__` carries tasks only. Storage cannot prove who shaped the binder,
  and P3 does not pretend otherwise — the membrane refuses structural verbs
  cooperatively and *Signed structure* is its own roadmap milestone.
- **The unsigned door is open, by P1's design, and P3a leaves it open.** A file
  with no attributable seal — an unsigned device's history (a VM, CI's runner),
  pre-signing legacy history, or a file nothing has ever sealed — is applied
  unjudged. Under permits that means a hostile client that never seals bypasses
  the check entirely. This contradicts what the P2 handoff told Denver
  (*"an unsigned device's lines can never pass a role check, so they sit
  pending"*): they are in fact applied. There is a further asymmetry inside it —
  the WRITE side narrows by actor even with no register (`LocalWritePermit`
  falls back to keyless, which is P1 exactly), while the READ side does not.
  The candidate close, for P3b's planning: the first permit event snapshots the
  book's unsigned files by digest, and unsigned lines outside that snapshot are
  PENDING in a book that has events. **Parked for Denver.** Until it is closed,
  enforcement is cooperative against a modified client — which is what ADR
  0032 has always claimed to be (provenance, not a lock) but is worth saying in
  the place where somebody will look for it.
  **CLOSED BY P3b (2026-09-20), by snapshot — Denver's ruling, option B.** The
  candidate above is what shipped: the first NARROWING event (not the first
  permit event — an admission changes nothing about who may write what) carries
  a mark over every stream this register can name no key for, and an
  unattributable line AFTER that photograph is PENDING. See the P3b addendum
  below for the rule in both directions, for what it still does not cover, and
  for what it costs.
- **A file's fast path rests on one key per file.** A stream whose every line
  is one kind, written by an actor the table allows that kind under a book
  author, is answered whole rather than line by line. That is sound because
  ADR 0012 gives a file one writer and the filename encodes the slug — but it
  is an assumption encoded in a filename, not a check, and only a device mixing
  its OWN keys into one file could slip past it.
- **Permits are per person RECORD, and P2b merges devices under one LABEL.** So
  a demoted Sam would keep writing from her phone's own record.
  `RegistryAdmission.records(sharingLabelWith:in:)` and
  `DocumentStore.changePermit(everyRecordOf:to:)` are the label-wide verb —
  each record its own mark and its own event, refused whole up front if any
  would be (`PermitChangePartlyApplied`), revoked siblings skipped — and it
  exists for P3b's pane to press. Nothing presses it in P3a. **P3b presses it**:
  People & Devices' *Change…* and *Re-admit* both go through it, and
  `TripwireGrepTests.test_noViewPressesTheSingleRecordPermitVerb` keeps the
  single-record verb out of every view, so a permit change cannot reach one of a
  writer's machines and miss the others.
- **A revocation's cut is positions only where the revocation HAS a mark.** A
  P2-era revocation carries `highestOpIdSeen` and no event, so `RevocationSplit`
  still reads the opId off the line for it. That is the residue of the audit's
  Low finding (*the revocation mark is taken off an unsigned `op.device`*):
  closed for every revocation this build writes, open for every one already on
  disk, and it stays open because rewriting a signed record to change what it
  means is not something a later build gets to do.
- **The load's own `typingBurst` emissions from released builds are not
  grandfathered.** `Permit.isALoadEmission` covers `bootstrap` and the anchor
  `taskCreate`, so a line those released builds signed with the loading actor
  is judged under the person's permit without the actor narrowing — permanently,
  because a time-boxed rule would be un-applied by the first reviewer P3b
  creates. The other three load emissions — both pending-recovery folds and the
  anchor splice — are `typingBurst`, and on every RELEASED build nothing on the
  line distinguishes them from a person typing (they wrote no
  `synthesisSource`; see the amendment below). Widening the rule to every `typingBurst` would say MCP may move the
  manuscript after all, so an assistant-signed ordinary burst stays refused. A
  disk census of every project this developer's Mac can reach (23 projects, 194
  tails, 5 `.mzseg` segments, 11,064 lines) found no such line; the exposure is
  a shape this format allows rather than one anybody has been observed to hold.
  The close, if one is ever wanted, is a `synthesisSource` on those three
  emissions, which only helps lines written AFTER it ships.
  **Amended by P3b Task 3 (2026-09-20), and the amendment does not move the
  rule.** Those three emissions now DO carry a `synthesisSource`
  (`.pendingRecovery`, `.anchorSplice`), written prospectively under handoff
  ruling 3, and `Permit.isALoadEmission` is still NOT widened to `typingBurst`
  — two reasons, either sufficient: the label only reaches lines written after
  it ships, so every released-build line the census is about is still
  unlabelled; and a field the assistant writes is a field the assistant can
  write, so a rule keyed on it would rest on the assistant's good manners. The
  label is provenance, read by `LoadBurstCensus` and History, and it reaches no
  table (`PermitPartition.writtenOp` decodes a KIND and nothing else). The
  census is kept rather than thrown away — `scripts/census-load-bursts.sh` over
  `LoadBurstCensus` — and is on the P3c release checklist for every Mac that
  has opened a book before the release. The two `SynthesisSource` cases are
  half of why `ProjectManifest.currentSchemaVersion` is 9.
- **A downgrade takes the foreign-stream memory with it, and the sweep guard
  goes quiet with it.** A Mac that has been down to an older build and back
  expects nothing of any stream until it has loaded each one again, so for that
  window a marking verb cannot tell an absent stream from one that never
  existed. Pre-P3a behaviour, arrived at honestly, healing per document on the
  next load — but a window.

### The cost of a narrowed book, measured (2026-09-20)

P3a's own measurement covered the ordinary book, which is what every existing
book becomes the day it ships, and left the NARROWED book unmeasured because no
P3a surface can create one. It is measured now, on one fixture, both shapes,
one machine, medians of 7:

| measure | admissions-only | one reviewer |
|---|---|---|
| annotations walk, 30 documents | 157.8 ms | 157.4 ms |
| aggregation walk, 30 documents | 153.3 ms | 163.8 ms |
| `Document.load`, 1,001 ops | 23.8 ms | 39.2 ms |
| `TranslationStore.loadMerged`, 40 records | 0.82 ms | 0.89 ms |

An **admissions-only** book — which is what P3a's own verbs produce, and what
the first admitted phone makes of every book — pays nothing: it takes every
exit, which is what `TrustTable.hasNarrowingPermits` restored. The moment one
person is a reviewer the book judges, and the cost lands on the document open:
**+15 ms, +65 %**, the per-line decode plus the class resolution over 1,001
ops. It is paid once per open rather than per keystroke, and it is the price of
the rung existing; P3b carries it as a known number rather than a surprise.

## Addendum — scope's lifecycle and the Mac's surfaces, 2026-09-20 (P3b)

P3a enforced the permit and gave it no way to be GIVEN or SEEN. P3b is that
half: the controls that install a rung, the surfaces that say what is held and
what is lost, and the four things the P3a build left open — the unsigned door,
the schema gate, a sweep that could refuse for ever, and a sheet offering keys
it must not.

Nothing here changes what a line MEANS. Every decision is still one pure
MaughamCore value with a thin surface reading it, there is still one trust
table (tripwire 39), one permission table (44) and one partition (45), and a
book that narrows nobody is P2/P3a exactly.

### The unsigned door closes by snapshot, in both directions

`UnsignedSnapshot`. The first NARROWING event carries a mark, in P3a's own
chain-position form, over every stream with no attributable key.

- **At or before the photograph: exactly P1.** Manuscript text stays applied,
  and an unsigned Mac's note edits and withdrawals stay honoured — this
  replaces `AnnotationOwnership.unplaced`'s backward reach, because *narrowing
  must not reach back* is the demotion rule and it does not stop being the rule
  when the party has no key.
- **After it: PENDING.** Held, never set aside (nothing is wrong with the
  line), never pardonable by an admission (there is no key to admit). Its one
  way in is §7.4's *Send to Inbox*, from History's held rows.

An un-narrowed or registerless book is untouched, and narrowing is STICKY
(`TrustTable.hasNarrowingPermits` reads every entry of every timeline), so
there is no un-narrowing direction. Where two roots have both narrowed, the
**earliest narrowing event by date** governs — never the newest, because a
later photograph would MOVE the cliff, and moving it forward applies lines that
had been held while moving it back withdraws lines that had been applied. `at`
is a signed field, so every device reads the same number out of the same bytes.

**S4(c) is answered by test, not by argument** (`UnsignedDoorTests
.test_twoRootsThatAdoptedEachOtherJudgeEveryLineTheSameWay`): two roots that
each narrowed somebody of their own, each from its own copy of the folder, and
then adopted each other, reach the same governing snapshot and apply and hold
exactly the same lines.

### The schema gate, and new books born at 9

The first narrowing raises `ProjectManifest.schemaVersion` to 9 BEFORE the
event is written (gate → event → record), so a v0.40 Mac cannot open a narrowed
book — which it would otherwise do by applying a reviewer's refused text and
re-asserting it under its own book-author key. The write door is **raise-only**
against what is on disk, inside the coordinated write, and a P3 build that
finds a narrowed book stamped lower HEALS it at open. A book MADE on this build
starts at 9, which is a release-notes line rather than a rule.

### A loss the writer has been shown stops being expected

`OpLogDeviceState.acknowledgeLoss`. A remembered stream that is legitimately
gone made `revoke`, `changePermit` and `admit` refuse for ever, naming history
that no longer exists. History now draws what this book is missing — a stream
found shorter than it was, or one the folder holds no file of at all — and
**Acknowledge** puts it down; every sweep, the snapshot's included, takes the
same escape through one function (`expectedStreams`).

### *Theirs* re-judges by reason, not by position (P3b smoke find F9, ruled 2026-09-23)

§4.5's answer — *the piece she started is hers* — first shipped as a
POSITIONAL cut: the event's mark was taken before her first held line, so
what followed was judged under the widened permit. The smoke found it doing
nothing (a stranger whose admission had already seen her line got the
admission's position carried forward over the cut), and the fix exposed that a
position can only say *everything after X is new*, which is not the rule the
writer meant. Denver ruled the rule instead: **a line of hers in the settled
piece that was refused ONLY because the piece was not in her permit is
re-judged under the granted permit wherever it sits** — before her held span,
after it, in a segment that arrives later — **and a line refused for any other
reason stays set aside wherever it sits**; a line held for a reason that is not
§4.5's (a kind this build cannot read) stays held.

So the answer is a FACT on the event, not a position: `PermitEvent.settled`
names the pieces, the mark is the ordinary seen mark, and `PermitTimeline`
reads every earlier entry of that person as having held those pieces
(`Entry.judging`, via `Permit.settling`, which widens an author-of-some-pieces
list and nothing else). `Entry.permit` stays what was installed, so History and
`current` are unchanged. The partition asks `judging` — one judgment, for the
load and every sweep. Because only the piece list moves, every other refusal
is answered by something the widening does not touch: the actor rows, a
reviewer's rung, `.cannotJudge`, and every VERDICT (revoked, retired, a broken
chain), which is decided before the partition runs. *Another person's line*
means a line another person SIGNED: her own accepts, rejects and archives of
other people's notes in the settled piece, refused only for scope, are her
acts and come in too (Denver, 2026-09-24). After a deliberate REMOVAL the
question is still put and the effect is the same, but every surface says she
kept writing in a piece that was taken from her (`PermitTimeline
.wasTakenFromThem`, ruled 2026-09-24). An entry after the answer
is not widened, and `settled` over a permit that does not author the piece
settles nothing. The ordinary mark takes the ordinary loss check, so an answer
over a stream missing a segment this Mac applied refuses, as every marking verb
does.

### What the surfaces are

The admission sheet installs a rung and never offers a non-author actor key or
a contested one; People & Devices changes a permit across every record of one
label, re-admits pre-filled with the permit held when revoked, re-signs a
record the reader refuses and writes this Mac's own record again; the editor
says which piece is waiting for whom; the Inspector and the outline say whose
piece is whose; and History carries the dated account — including, now, one
undated-or-dated adoption row per adoption, and one dated *unsigned* entry per
unsigned stream in a narrowed book.

### What P3b does NOT do — the limits, stated

- **The unsigned door closes by SNAPSHOT, which is not the same as closing.**
  A modified client that holds a book-author key can still write whatever that
  key may write; the photograph is about files nothing signs, not about a key
  being misused. Enforcement stays provenance rather than a lock, which is what
  this ADR has always claimed.
- **The legacy unsuffixed `<docId>.jsonl` is outside `expecting:`.** It carries
  no slug, so the foreign-stream memory has no key for it and a sweep cannot
  tell *gone* from *never was* about it. Stated in the sweep's own doc comment.
- **A Mac on no chain hears no narrowing at all.** No root of its own and
  adopted by nobody means the event population — filtered by signer to my root
  and the roots I have adopted — is empty, so the book reads as un-narrowed
  there and every unattributable line is applied. It errs the permissive way
  only, and such a Mac can write nothing this book will take; closing it means
  deciding what a Mac that belongs to nobody should be SHOWN, which is P3c's
  question. Pinned as
  `UnsignedDoorTests.test_aMacOnNoChainHearsNoNarrowingAtAll`.
- **Two admitting roots that have not adopted each other disagree about what is
  held** (`test_withoutAdoptionEachMacHearsOnlyItsOwnRootsNarrowing`). Each
  hears its own root's narrowing and drops the other's. That is what a claimant
  IS and Merge is the way out, but it is a real disagreement and it is on the
  record rather than a surprise.
- **A file named `author-<hex of a non-author key>` can take a held span's
  sheet.** The admission sheet gives an AUTHOR slug for a key precedence over
  every other, so that a folder-writer cannot deny an honest stranger her sheet
  by writing one filename beside her tail. **Accepted risk, stated** (Task 4's
  review): such a file can only contain lines that key really signed, honest
  Maugham signs only assistant-permitted kinds with that key, and once the
  device record syncs `Registry.actorKeyOwners` names it an actor key. The cost
  if it is wrong is that an actor key is admitted as a person and its replayed
  annotation-kind lines are judged on the author row, which allows them anyway.
- **An acknowledgement's scope grows, and it is device-local.** It is per
  STREAM and it outlives the act it was pressed for — nothing re-asks after the
  first verb — and two Macs can disagree about what the book is still waiting
  for. That is deliberate: it is a fact about what this writer has been shown,
  it changes no mark, and it moves only which Mac is able to write one. The
  admission sheet takes the escape with no clause of its own (the pane's
  *Re-admit*, which is P3b's surface for a revoked person, does carry it).
- **A settled question's held lines can outlive their answer.** *Theirs* brings
  in what was held under §4.5 in the piece it settles; a `.cannotJudge` hold in
  that piece is re-judged to the same answer (still held), and a held line in
  any OTHER piece stays where it was. The
  sentence then names People & Devices and there is no control beside it.
- **A too-new manifest arriving mid-session is decoded without the schema
  guard.** `handleManifestChanged` re-reads the file; the guard runs at open.
  Pre-existing, found by Task 3's re-review, carried to the roadmap.
- **Retirement is one-way.** There is no un-retire verb: a retired device's
  unsealed tail stays applied, its later SEALED lines are set aside, and their
  way back is §7.4's door rather than one press. Spec §7.3's third load
  question was withdrawn for it (Task 7's ruling; spec amended in `cb513541`).
- **A `chainBroke` record still offers §7.4's door.** The door is decided by
  what the record's archived LINES hold, never by the cause — which is right,
  and it is also where *the words come back* meets *this was not written by
  Maugham*. Such a record's captures are attributed to nobody
  (*this book cannot say who wrote it*).
- **Two doors sit on one pane with different leads.** History draws *Set
  aside…* over records and *Waiting…* over held spans. They are different facts
  and the words say so, but they are adjacent and orange.
- **`changePermitOutcome`'s `.alreadyAdmittedElsewhere` arm is unreachable from
  the pane** — a person under another root has no row there. It is the verb's
  own guard and correct; there is no test that can be written for it from the
  surface.
- ~~**Spec §7.1's share pre-fill is not built.** A read-only iCloud share does
  not suggest *reviewer* in the admission sheet; the default is the whole book,
  which is P2b's behaviour exactly. Carried to P3c, where Component A's
  retirement decides `FileURLShareMetadataReader`'s one surviving caller.~~
  **STRUCK by P3c plan 1 (ruling R1):** the pre-fill was dropped on merit, not
  deferred — the admitting root cannot read another participant's share
  permission, so there is nothing to pre-fill from. See the P3c addendum.
- **The kept release census does not walk hidden directories.** The P3c release
  checklist's wording has to say so (`scripts/census-load-bursts.sh`).

### The cost of a narrowed book, re-measured (P3b, 2026-09-23)

P3a's table above is a different fixture and its probe was never committed.
`MaughamTests/Performance/NarrowedBookCostTests.swift` is kept and env-gated,
so this is re-takeable: the same four measures, medians of 7, over a real
novel project with 300 bursts in the measured piece, on a quiet machine
(`pgrep -x xcodebuild`: nothing). Two runs agreed to within a tenth of a
millisecond; the first is shown.

| measure | admissions-only | one reviewer | + a 400-line unsigned stream |
|---|---|---|---|
| annotations walk | 9.05 ms | 9.73 ms | 17.25 ms |
| aggregation walk | 8.95 ms | 9.64 ms | 17.00 ms |
| `Document.load` | 10.38 ms | 13.47 ms | 24.20 ms |
| `TranslationStore.loadMerged` | 3.44 ms | 4.23 ms | 4.22 ms |

An admissions-only book still pays nothing. One reviewer costs about +3 ms on a
document open here; the unsigned stream the photograph is about is the bigger
half, at about +11 ms more, because every load walks and judges it. Taken
together the narrowed book stays inside **about one 16 ms frame** per document
open — the figure `Maugham/OpLog/AREA.md` gives, and the one P3a's larger
fixture reached from the other side.


## Addendum — the posture, Component A retired, and F10, 2026-09-24 (P3c plan 1)

P3a enforced the permit where lines are READ, and P3b gave it a way to be
given and seen. What neither did was make the permit-holder's own Mac honest
about it: a reviewer could still press Accept, and the next read set her own
act aside in silence. P3c is split into plans. This addendum covers plan 1: the Mac
half of spec §8 (the membrane widens to the table), the retirement of WF1's
Component A, and smoke find F10. Plan 2 covers Option A (starting a piece of
your own) and the phone.

Nothing here changes what a line MEANS. The table (tripwire 44), the partition
(45) and the one *may this actor write here* (46) are untouched. A book whose
device has no narrowing permit answers `Posture.author` everywhere, so it is
P3b exactly: every verb is offered. The pre-P3c suites passed unchanged apart from these declared
edits: the Component A suites that were deleted with it, the F10
premise narrowings (controller ruling Y), and mechanical edits that pass a newly
required posture argument (ruling S).

### One value, asked of the permit

`Posture` (MaughamCore) is built from a `LocalWritePermit`, which comes from the
one builder, `OpLogStore.localWritePermit`. It answers one question: *may a
surface offer this verb?*

- The verbs are the cases of `Posture.Verb`. Count the enum, not this
  paragraph.
- ONE `default:`-less switch maps each verb to the line it would write, and the
  permit's own `allows` answers.
- Pass state, structure and a round are not ops. Each is probed as *may you
  write this piece's text* (R3, R4).
- *Start a piece* is asked in the hardest class, so it is a whole-book
  author's act until plan 2.
- `reason` names why the words are not hers: `.reviewer`, `.notYourPiece`,
  `.yielding(to:)` or `.cannotJudge`. It reads the rung only to NAME the
  reason, never to decide a verb (tripwire 47).
- The permit is private, so a surface cannot ask it a second question.

Named values stand beside the built ones.

- **`Posture.author`** is P1's posture.
- **`Posture.settling`** is the door's *not yet* answer: the answer about a
  document it has never answered, in a book that has a register, before its
  off-main table lands. It offers the reviewer row alone, because a verb
  appearing a frame late is harmless and a verb appearing that must not is not.
  A book with no register never answers `settling`.

**The Mac asks through one door** (`DocumentStore+Posture.swift`, controller
rulings B and I). Which accessor a caller uses is the rule:

- **`posture(forDocId:as:)` is the DRAWING accessor.** It is a per-epoch cache
  and never resolves the registry on the main actor. After a trust change and
  before the refresh lands, it answers provisionally (this key's last answer,
  else the open document's stamp, else `settling`) and caches nothing.
- **`settledPosture(forDocId:as:)` is what every door that ACTS asks.** It waits
  out any refresh, re-warms if the folder moved under it, and never returns a
  provisional or `settling` answer.

**Fresh on every trust change.** `invalidateTrust` and manifest adoption bump
the epoch, and the refresh that follows warms the new answers into a STAGING
dictionary, then — **in one main-actor turn** (ruling AG; the whole-branch fix
wave's Minor 1) — publishes them to the drawing cache, re-stamps every open
`Document`'s `localWritePermit` from the same builder (the manuscript
registry's AND every open statement editor's, which is deliberately in no
`DocumentStore` registry — fix wave I1), and bumps the epoch that re-renders
the editor. Until that turn the new table is not published, so a redraw during
the warm's yields draws the last answer rather than the new one. The
Document's own writes, what a surface draws and the editor's lock therefore
flip together, and no turn sees one without the others
(`DocumentStorePostureTests.test_theRestampAndTheBumpAreOneTurn` samples every
turn, the stamp AND the drawn answer). Once the refresh lands, a demotion stops her writes and locks her
editor, a promotion restores both, and neither needs a reopen. The re-stamp
keeps the actor the stamp was made for, which is the author's, because the
load's own emissions are (tripwire 38; ruling J).

**The lock trails the change; it does not precede it** (ruling AG's stated
limit). Between a registry change landing in the folder and its refresh
completing — the presenter's debounce, the off-main resolve, the pre-warm —
surfaces draw the last answer they had (the drawing accessor's provisional
rule), and the open Document still answers under its old stamp. A burst typed
in that window under a permit just withdrawn is signed and then set aside in
her name, kept in History, not lost. `settling` fails closed only about a
document never answered; about one already answered, the last answer is what
is drawn until the refresh lands. Every verb's own door asks `settledPosture`,
which waits the refresh out.

`TripwireGrepTests.test_postureIsAskedOfThePermitInOnePlace` (CLAUDE.md tripwire
51) keeps every other file from asking a permit a question or building a
`Posture` of its own. It checks by file AND spelling, over `Maugham/` and
`MaughamPhone/`, with a planted-offender control.

### Every verb has a door and a surface

This heading claimed completeness for a list enumerated from the plan. The
whole-branch review found three manuscript writers outside the editor's
membrane that were on neither list — History's restore, project Replace /
Replace All, and the rename's wiki-link sweep — and the fix wave gave each a
door and a surface. **The population is now a grep, not a list**:
`TripwireGrepTests.test_everyManuscriptWriterOutsideTheEditorIsANamedSite`
counts every production call of `setFullText(`, `applyRestore(`,
`restoreToOp(`, `restoreToOpUndoable(`, `Restore.buildRestoreOp(` and the
replace verbs, by file, against a named array whose every entry says where its
posture is asked or why it need not be (count the array,
`manuscriptWriterCallSites`, never this paragraph). A burst's EMISSION is
deliberately not permit-guarded — the editor's membrane is in front of the
keystroke — so any other caller that reaches one must ask first.

The shape is the same everywhere. **The surface hides** a verb the posture
forbids — a greyed Accept reads as broken, so nothing is disabled. **The verb's
own door refuses it** if a stale press or a stale undo reaches it anyway. Both
ask the one door.

**The exceptions to hiding:**
- **The editor** stays selectable and copyable and refuses mutation. This is
  the P2 membrane's shape: `EditorEditPolicy` and `shouldChangeTextIn` alone,
  with `isEditable` untouched.
- **The File menu's piece items** are DISABLED (ruling X). A menu-bar item is
  greyed, not removed.

**The doors:**
- **Dispositions** refuse in `Document+Annotations` (`PostureRefusal`). An undo
  whose compensating op is refused is declined out loud (`UndoDecline
  .notPermitted`), never silently re-applied.
- **Task ops** refuse in `Document+Tasks` (`UndoDecline.taskNotPermitted`).
- **Statements** refuse at `RulingPerformer`'s rule/revoke/edit/restore and at
  `StatementProposalGate.adopt`.
- **A round** refuses in `CompilerOrchestrator.runRequested`. It starts nothing:
  no marker moves, no session, no pass memory, and `runState` stays idle.
- **⌘S's op** refuses in `CheckpointCapture`.
- **A translation** refuses in `TranslationWritePipeline`, and at the desk's
  Run. Both are judged as the TRANSLATOR actor.
- **The Collection's start-a-piece commands** refuse at `StartAPieceDoor`.
- **A History restore** refuses in `Document.requireRestorePermitted` — at the
  top of `restoreToOpUndoable` (before its undo-stack clear), of `restoreToOp`
  (before the burst flush) and of `applyRestore` (for the inline-task archive
  undo) — so nothing is flushed or appended. A registered ⌘Z/⇧⌘Z it refuses
  is said (`UndoDecline.restoreNotPermitted`). History draws *Rewind to before
  this…* and the rewind window draws *Restore here…* only where the document
  allows `.writeText`; *Snapshot here…* follows `.checkpoint` (R5).
- **A checkpoint revert** (*Revert here…*, `PartialRestorePicker`) asks the
  settled posture per document before it builds a restore; the picker lists
  only documents this Mac may write, offers *Whole project* only where every
  one may be, and names in the sheet what its door left alone.
- **Project Replace / Replace All** refuse in `ProjectStore.replaceInManuscript`
  — the settled posture before any load (so the root's yield holds), then the
  loaded Document's own stamp before `setFullText`. Replace All SKIPS and NAMES
  a refused document and replaces the rest (ruling AI); a single Replace on
  one throws `ManuscriptReplaceRefused`. Find draws the per-match Replace only
  for a match whose own document allows `.writeText`, and Replace All only
  where one match does; research notes keep their verbs.
- **The rename's wiki-link sweep** skips a piece or statement this Mac may not
  write (the settled posture, then the stamp) and the tree says which links
  were left (ruling AH); the rename itself is not refused.
- **Every statement write** passes `ProjectStore.mutateStatementText`, which
  refuses where the statement Document's stamp refuses its text
  (`StatementWriteRefused`) — behind the ruling and proposal doors, and the one
  door for promotion's appends and the picture ingest.

**Where the posture comes from for each kind of document.** A statement's
posture is its piece's (a piece statement) or the book's (a project statement).
A translation is judged as the translator. A queue row is judged by ITS OWN
document's posture, never the window's selection.

**The standing line** (`PostureStandingLine`) sits above the editor and says
why the words are not hers. It is keyed on `reason`, never on `isRestricted`
(ruling E), so an author of some pieces inside her own piece sees no line.
**Ruling K** adds a clause: *Some of what you wrote here is kept in History*,
counted exactly from the set-aside and held lines of this device's own files
(`OpLogProvenance.ownLinesKeptInHistory`).

**The root's cooperative yield** (spec §2/§8, R2, ruling H). Where this Mac
holds the book's root and `PieceWriters` names somebody else on a piece, the
author's posture on that piece yields: *This is Sam's piece*, with **Edit
Anyway**.

- It applies to that piece's statement and its translation as well.
- It never yields to this device's own person, and never to a whole-book
  co-author.
- A whole-book author who is not the root yields to nobody.
- The override is per window, per piece, for the session. It is not persisted
  and not synced.
- The acting doors honour the yield too (ruling T). The root presses Edit
  Anyway before ruling on or checkpointing Sam's piece, even though storage
  would take her lines.

### The plan's rulings, and the controller rulings that changed behaviour

**Plan rulings:**
- **R1.** Spec §7.1's share pre-fill is DROPPED on merit. The admitting root
  cannot read another participant's share permission, and a read-only
  participant cannot upload a device record to be asked about.
- **R2.** The root's override is per window, per piece, per session.
- **R3.** Pass state and structural verbs are probed as the piece's text. Start
  a piece is the book-author probe. Duplicate needs both (ruling W), because a
  copy is a new piece.
- **R4.** A round is gated. Author's check is anyone's, because it mints the
  reviewer row.
- **R5.** ⌘S on a piece this Mac may not write flashes and writes nothing: no op
  and no checkpoint entry. ⇧⌘S says why instead of opening its sheet.
  - **Ruling L:** ⌘S with the project row selected is unchanged.
  - **Ruling N:** a labelled ⇧⌘S that succeeds now flashes too.

**Controller rulings that moved behaviour beyond the plan:**
- **Ruling K**, the own-lines clause, described above.
- **Ruling O.** `author_collaborator_id` is decoded and never written. Claim
  M5-AN-012 is amended, and `test_theCollaboratorIdIsDecodedAndNeverWritten`
  guards it.
- **Ruling P.** A reviewer's reopen of her OWN withdrawn note is refused for
  now, loudly. `annotationReopen` is a disposition in the table, and moving
  own-note reopen onto the ownership path is a storage-table change that must
  move on the Mac and the phone together. It is plan 2's.
- **Ruling X,** the File menu, described above.
- **Rulings AA–AC,** F10, described below.

### Component A is retired

`CollaborationRole`, `ShareIdentityMapper`, `ReviewPosturePolicy`,
`ProjectWindow`'s role plumbing and the phone's `SharingRoleBanner` are
deleted. What remains of the share:

- **It is an indicator, not a role.** `ShareMetadata` survives, moved to a file
  of its own, and `SharingStatusPill` shows *Shared* or *Shared by <owner>*
  and claims no role.
- **A read-only iCloud share is an OS-level lock.** `ShareMetadata.canWrite ==
  false` still locks the editor and shows `ViewOnlyShareNotice`, as the
  mirror's second input beside the posture. Neither input ever unlocks what the
  other locks.

Behaviour changes that follow, by design:

- A participant on a read-WRITE share is no longer locked as a "reviewer". What
  she may write is her permit.
- An unresolved share no longer locks the window while it resolves.

### F10 — the question is asked when the stranger arrives

**Smoke find F10.** The admission sheet used to be raised by a stranger's held
LINES alone, so a collaborator whose device record had synced, but who had not
written yet, was invisible until her first words were already being held.
`AdmissionDecision.requests` now also asks about every verified, unretired
device record that `standing(ofHolder:)` calls a stranger to ask about. Such a
request carries *Nothing from it has reached this Mac yet.* A device that is
both held and newly recorded is one request, not two.

- **Ruling AA.** The question is asked ONLY on a Mac that holds the book's root
  — its own root record, the same test `admitRemembered` uses — on both paths.
  An admitted non-root Mac is never shown the sheet.
- **Ruling AB.** The inbox recount runs on a registry settle, never on a
  document open.
- **Rulings AB and AC.** A retired record is never a waiting stranger. The
  filename pre-check reads `retiredAt` from unmatched device files, unverified,
  which fails toward silence.

### The cost of the drawing door, measured and fixed (Task 10, ruling AD)

Task 2 promised O(1) in a view body *after the first question per document per
epoch*. Task 10 measured the first one, on a trust change with a queue of rows
each on its own document. The fixture is `MaughamTests/Performance
/PostureMissCostTests.swift`, kept and env-gated in `NarrowedBookCostTests`'
shape: the root's Mac with one person narrowed, medians of 7, no other
`xcodebuild` running.

**Before.** The first redraw after the refresh landed was all misses.

| rows | first redraw after the refresh |
|---|---|
| 10 | 8.6 ms |
| 50 | **42.0 ms** |
| 200 | 167 ms |

Each miss cost about 0.84 ms:

| what a miss did | cost |
|---|---|
| decode the manifest from disk for the document's class | 0.47 ms |
| folder signature, taken twice | about 0.11 ms each |
| is-there-a-register question, asked twice | about 0.06 ms each |

That breached tripwire 3 on every registry arrival for any queue showing about
twenty documents.

**The fix (rulings AD and AG):**
- **The class comes from the window's live manifest** where the store holds
  one, through `DocumentClass.resolve(docId:statements:)`, which is what the
  disk path computes over the statements it decodes. The builder is unchanged
  (tripwire 46), and manifest adoption already bumps the epoch.
- **The refresh warms every `(docId, actor)` the window has asked about**, off
  the table it just warmed, OVERWRITING whatever the cache held — a refresh no
  clearing bump preceded (one a drawing miss scheduled before the debounced
  invalidation) must not keep an answer off the table it replaces. It works in
  chunks that yield the main actor, and checks the folder's signature once per
  chunk rather than once per key.
- **The warm comes FIRST; the Documents' re-stamp and the epoch bump follow
  together in one turn** (ruling AG). The first version re-stamped before the
  warm, which put the warm's yields between a Document's stamp and the editor's
  mirror; the task's review caught it and the ordering test pins it.
- **Its epoch bump keeps the warmed cache.** The yields' second bump never
  clears it, because a permit does not depend on who is yielded to.
- **A folder that moves mid-warm abandons it** and falls back to the clearing
  bump, as before.
- **Pinned in the ordinary gate**, not only measured:
  `test_theRedrawAfterATrustChangeIsAllHitsAndEveryHitIsFresh` counts the
  builder's calls across the redraw (none) and compares every warmed answer
  with a fresh build; `test_aRefreshNoInvalidationPrecededStillReanswersACachedKey`
  pins the overwrite.

**After:**

| rows | first redraw after | provisional, during the refresh | a never-asked queue |
|---|---|---|---|
| 10 | 0.008 ms | — | — |
| 50 | **0.023 ms** | 2.95 ms | 18.2 ms |
| 200 | 0.083 ms | — | — |

The pre-existing `DocumentStorePostureTests` passed unchanged. A queue of documents this window
has never asked about still costs about 0.36 ms a row. That is the folder
signature and the register check, each taken once by the door and once again
inside the builder. The door's own check is what keeps a registry resolution
off the main actor, so it stays per miss; see the limits.

### What P3c plan 1 does NOT do — the limits, stated

- **The binder is cooperative.** *Roles guard the words, not the binder* (P3a's
  first limit) still holds. The tree hides structural verbs from a posture that
  forbids them, and nothing at storage refuses a reviewer's manifest write.
  Starting a piece is refused at its command's receiver as well, but that is the
  app's courtesy too; what storage guarantees is only that nobody whose permit
  does not name the new piece can write its text (the load refuses it).
- **A read-only iCloud share is an OS lock and no role.** It locks the editor on
  that Mac because the file system will not take the write. It says nothing
  about the person's permit, and no permit is inferred from it (R1).
- **Project-stream tasks are hidden in the pane but have no door.**
  `ProjectStore.createProjectPaneTask`/`archiveProjectTask` are unguarded. The
  reviewer's pane never draws them, and the read side sets aside a reviewer's
  `__project__` task op. A door there needs a permit on `ProjectStore`.
- **A reviewer cannot restore her own deleted note until plan 2** (ruling P).
  The refusal is loud rather than silent.
- **M5-AN-012's filing awaits a register ruling.** The claim is amended and
  pinned. Its filing stays NO_RULING_REACHES until Denver promotes spec §8's
  sentence to a RULING-n.
- **A late capture does not refresh an open F10 sheet.** A capture arriving
  after the sheet is up leaves it reading *Nothing from it has reached this Mac
  yet* until the next settle or load.
- **A corrupt `people/<fp>.json` hides a record-only stranger.** The pre-check
  skips the verified read and fails toward silence until the next verified
  read. A forged `retiredAt` on an unmatched device file does the same (ruling
  AC).
- **A never-asked document still costs a door check and a builder check on the
  main actor** (about 0.36 ms a row). Only the redraw after a trust change was
  made cheap; the drawing path's per-miss signature check stays (ruling AE),
  because memoising it could put a registry resolution on the main actor.
- **What the window has asked about is remembered for the session**
  (`PostureBook.asked`), including a document since deleted or renamed away,
  and every refresh re-warms all of it. It is bounded by the documents this
  window has shown, and a refresh's warm yields the main actor every chunk
  (about 3 ms of work each), so a long session on a large book pays a longer
  warm spread across turns, never a longer stall. Pruning keys whose document
  no longer resolves was not built: whether an id still names something is a
  class question with statement, translation and project-stream arms, and a
  wrong prune only costs a miss.
- **The lock trails a trust change** — see *Fresh on every trust change* above.
  The pre-warm widens that trailing window by its own duration (about 0.36 ms
  per asked key, spread across turns); what it no longer does is publish an
  answer ahead of the re-stamp.
- **A rename leaves links it may not rewrite** (ruling AH). A piece-author
  renaming her own chapter renames it, and the `[[old title]]` in pieces this
  Mac may not write is left — dangling on EVERY Mac until somebody who may
  write there fixes it. The tree says which pieces, once, at the rename.
- **An unreadable registry re-resolves on the main actor per settled miss.**
  `settledPosture` gives up re-warming after a bounded number of attempts and
  asks the builder directly, which resolves on the main actor — the price of a
  correct answer in a state that should not persist.
- **The dev build's `test_apply_edit` is ungated by design.** It is the smoke
  rig's typing surrogate and stands in for a keystroke; the census names it.
- **The phone draws none of this.** Its banner is gone with Component A, and its
  posture (dispositions per piece, `AnnotationOwnership`, ruling P's reopen
  change) is plan 2's.


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
- CLAUDE.md tripwires 35, 36, 37 and 38; and 51, the posture census (P3c).
