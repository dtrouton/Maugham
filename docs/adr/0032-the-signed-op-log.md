# ADR 0032 — The signed op log: provenance for every op, the device before the person

**Date:** 2026-09-07 · **Status:** Accepted (P1 built; P2 and P3 unwritten) · **Milestone:** signed-op-log-p1-integrity-and-the-device (branch `claude/signed-op-log-p1-2026-09-07`)

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
reports nothing wrong. `deviceId` is the 16-hex prefix of the fingerprint,
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
somewhere else, however well it chains.

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
  the container;
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
- **Verification costs a rounding error against parsing — and the plan's
  100 ms-at-50k budget was not met as a headline number.** The first measurement
  of a 50,000-line cold open added about 450 ms end to end, against a stated
  budget of 100 ms; the hex fix took the chain's own work down to 55-83 ms on
  that fixture, after which the end-to-end delta sits inside the parse's own
  noise. What is claimed here is what was measured, never that the budget was
  met: the tail walk and its signature checks are tens of milliseconds against
  seconds of `JSONDecoder`, and that fixture's tail is eight times the size
  `segmentSealThreshold` lets a real one reach. **Whether the budget should be
  restated against a realistic per-document op count is Denver's decision, not
  the implementer's, and it is open** (the handoff's Decisions owed). Two things
  keep the cost where it is: `Hex` is table-driven (the obvious
  `String(format: "%02x")` spelling cost 107 ms of a 109 ms `lineHash` total on
  that fixture), and the settled-segment branch counts lines rather than
  splitting them. See `Maugham/OpLog/AREA.md`.
- **The project stream is signed but never rotated, and its tail has no
  ceiling.** `__project__` seals like any other stream now that `ProjectStore`
  holds one `OpLogStore` for its lifetime, but `sealTailIfNeeded` still refuses
  it, so the file grows without limit and the chained append's verify cost grows
  with it. That is a pre-existing growth with a new cost attached, and it is
  recorded rather than fixed.
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
- CLAUDE.md tripwires 35, 36 and 37.
