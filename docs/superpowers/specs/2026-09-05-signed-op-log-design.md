# The signed op log — provenance for every op, people as keys, devices as certificates

**Date:** 2026-09-05 · **Status:** approved in discussion, plans unwritten; a spike gates P1
**Session:** "compiler / author / review split" (second brainstorm of the session)

*Brainstormed with Denver 2026-09-05, from his question "protecting the oplog
from interference outside Maugham — signing or encrypting?" Denver's answers of
record are inlined at each decision. Subsumes WF1's Component A (identity and
role) and hardens its Component B (the membrane) from cooperative to enforced;
WF1's other components stand. Closes the maintainability audit's item 10 (the
live tail's unframed appends). Touches ADR 0012 and ADR 0016 without amending
either's decision.*

## 1. The problem

"Interference outside Maugham" is three adversaries wearing one word:

1. **Accident** — a torn append, a sync layer's half-write, a tool that
   rewrites line endings. Sealed segments already carry a SHA-256 (ADR 0016,
   `OpLogSegment`); the live tail carries nothing, which is audit item 10's
   residue and a ≤512 KB window per device file.
2. **A person with the disk** — reads or alters files. At that point they can
   replace the app binary, so nothing the app does is protection; FileVault
   handles reading and nothing at the application layer handles a compromised
   machine.
3. **A program with a shell on the writer's own Mac** — appends to
   `.maugham/ops/*.jsonl` directly. This one is real and new. Claude Desktop
   cannot write manuscript text because `MCPToolCatalog` has no tool for it;
   Claude Code pointed at the project folder, or any agent with filesystem
   access, writes an insert op and the log honours it without a mark. The
   bootstrap skill teaches the layout. The constitution's identity must-not —
   *AI is never the author* — is enforced by the absence of a tool in one
   channel, and the storage under it is an open door.

Only the third is both real and the application's to address, and it is an
**authenticity** gap, not a secrecy gap. Encryption answers none of the three:
the manuscript is plain text on disk by constitutional must, so an encrypted
op log beside a plaintext `.md` hides nothing; losing the key loses history;
git diffs become noise; the phone needs the key; iCloud's merge of two
devices' files gets harder. Every cost, no benefit.

A fourth fact, found while reading: **the Mac's device id is its hostname**
(`MacDeviceID.current`). Two Macs with the same name, or a restored Mac that
kept its name, already collide on ADR 0012's one-writer-per-file rule and
ADR 0016's never-seal-another-device's-file rule. Signing gives the device an
identity that cannot collide; §4.8 uses it.

## 2. The frames

- **Provenance, not a lock.** A lock locks the author out on the day their
  laptop dies. Provenance makes every byte of history answer to a named
  device and a named person, and makes the one thing you cannot do *quietly*
  be the thing you should never do quietly. Every decision below is tested
  against this.
- **The trust root is the folder the author owns.** iCloud Drive sharing
  decides who can *read* and who can *write files*; Maugham decides which
  *ops* are the manuscript's. Hard revocation is unsharing the folder; the
  registry's revocation is bookkeeping. Denver: *"if I have ownership of the
  iCloud folder then that's a good argument for your approach."*
- **A ceremony people skip is a ceremony the design must not depend on**
  (Norman). Codes are shown, never demanded; a person's second device is
  admitted silently with an audit line; the sheet appears only when a
  stranger asks.
- **The identity-key / device-key split** (iMessage, Signal, Keybase): a
  person is a key that travels with them; a device is a key that never
  leaves its enclave; the person certifies the device.

## 3. Decisions of record (Denver, 2026-09-05)

- **Sign, do not encrypt.** Reading is the folder's business.
- **One key per device, roles per project.** The registry holds the roles, so
  the same phone is author in one book and reviewer in another with one key.
- **A person is a key** (synced through iCloud Keychain), **a device is a
  certificate** that person signs. Admission is of persons; a person's further
  devices are admitted silently, each with an audit line. Denver: *"yes audit
  is fine."*
- **Labels are the author's.** The name in every byline is the name the
  author gave the person at admission; the person's own display name is the
  default the sheet proposes, and where the two differ the audit line and the
  Settings pane show `<label> (<their own name>)`. Denver: *"some convention
  like <MYNAME> (<icloud-identity>) if they are different."*
- **Restore is a loud claim, not a locked door.** With no trusted key left
  (iCloud Keychain off, Apple ID gone) the writer claims the book and adopts
  its history in one sheet; every surviving device sees it.
- **A reviewer may capture into the author's inbox.** The inbox is already
  *someone proposes, the author disposes*; a reviewer's photo or voice note
  lands there with their name on it. Denver: *"a suggested image or whatever
  landing in the inbox."*
- **The phone's palette aim goes.** Since the canvas takes the inbox as a drop
  source, a capture's destination is decided at promotion on the Mac. Denver:
  *"with the canvas now this is pointless anyway."*
- **Verification never refuses to open a book.** Unverifiable ops are
  quarantined visibly, never applied, never lost. *The words are safe* (must
  #1) outranks everything here.

## 4. The model

### 4.1 Keys

| key | where | made when | signs |
|---|---|---|---|
| **person key** | software P256, Keychain item marked synchronizable; iCloud Keychain carries it to every device on the same Apple ID | first launch on the first device; re-used everywhere it arrives | device certificates; admission records the person makes as author |
| **device key** | Secure Enclave P256 (CryptoKit `SecureEnclave.P256.Signing`); a Keychain software key on an Intel Mac without T2, recorded as such | first launch on each device | every append batch the device writes; segment seals; self-revocation |

A device certificate is `{devicePublicKey, personPublicKey, name, madeAt}`
signed by the person key. It is made on the device, silently, the first time
the app runs with both keys present. Its security is the Apple ID's, which is
already the folder's and the share's trust root; this adds nothing a
compromised Apple ID could not already reach.

**Fallback without iCloud Keychain**: each device mints its own person key
and looks like a separate person. The admission sheet's *this is also Sam*
merges two person keys under one label (§4.5). Person keys are the normal
path; labels are the fallback; both are the author's act.

### 4.2 The registry

`.maugham/people/<personFingerprint>.json` and
`.maugham/devices/<deviceFingerprint>.json`, one record each, every record
signed:

- **person record** — `{personPublicKey, label, ownName, role, admittedAt,
  admittedBy: personFingerprint, revokedAt?, mergedInto?}`, signed by the
  admitting author's person key. The creating device's person is the **root**,
  self-signed, `role: author`.
- **device record** — the device certificate (§4.1) plus `{revokedAt?,
  revokedBy?}`; a device may sign its own revocation.
- **claim record** (§4.7) — a new root adopting an old chain.

A device trusts the chain it belongs to: the root its own person was admitted
under, transitively. A second root in the same folder is *another claimant*
and its ops are quarantined as such, never merged.

**The cache.** Each device keeps the registry it last verified in its own
local state. A record missing from the folder reads as *removed by someone*,
loudly, and is restored from the cache — safe because records are signed. A
participant with write access to the share can delete files; they cannot
forge them. Signing protects authorship, never existence; existence is the
folder's and the backup's.

### 4.3 What is signed, and at what grain

- **Every append batch.** `PendingBuffer`'s flush is already the append unit.
  Each batch's lines carry a `sig` field on the LAST line covering the
  batch's ops in order plus the previous line's hash — a **hash chain** on the
  tail, so truncation and torn appends are detected without a key, and a
  batch is one signature rather than one per op. (Verification of a 50k-op
  log is then hundreds of verifies, not tens of thousands; the spike measures
  it.)
- **Every sealed segment.** At seal, one signature over the segment's
  existing SHA-256 (ADR 0016), stored beside the digest. A verified segment is
  cached as verified by content hash; it is never re-verified per load.
- **Every inbox manifest row** — the same batch signature on
  `inbox.<slug>.jsonl`, because a reviewer's capture is a proposal and its
  authorship is the whole point (§4.10).
- **Registry records** (§4.2).

The op JSON is otherwise byte-identical; `sig` and `prev` are two additive
keys on a line (tripwire 11: legacy lines carry neither and load as
*unsigned* — see §4.4 — never as broken).

### 4.4 Verification: three states, and what each does

On every load and on every sync merge (`OpLogStore.loadSyncMerged`), each
batch resolves to one of:

| state | meaning | what happens |
|---|---|---|
| **verified** | signature checks against a device certified by a person admitted in this device's chain, with a role that permits every op kind in the batch (§4.9) | applied |
| **pending** | signature checks against a device whose person is **not yet admitted** — a request exists or can be made | held; the author sees *N notes from Sam's Mac, not admitted yet*; admission applies them retroactively |
| **quarantined** | no signature; a bad signature; a chain break; a role the batch's op kinds exceed; a second root | set aside in `OpLogQuarantine`'s existing home, never applied, never deleted; a line in History says what, from where, and why |

**Legacy** — a file or a tail written before this milestone has no `sig` and
no `prev`. It is *unsigned history*: applied, marked in History once as
*written before this book was signed*, and never re-signed (the words are the
writer's; a signature over them would claim a device that did not sign them).
The first signed batch's `prev` hashes the last legacy line, so the chain
starts where the history does.

**On the writer's own Mac, the case this milestone exists for**: an agent
with a shell appends an insert op. It has no device key, so no signature;
the batch is quarantined on the next load and History says *3 changes were
written to chapter 4 by something that is not Maugham; kept in backup, not
applied.* The `.md` is re-materialised without them, the same fate an outside
`.md` edit already gets (2026-06-09's ruling).

### 4.5 Admission

- **A stranger's device** (person key unknown to this chain) writes a
  request beside its own files: `{personPublicKey, ownName, requestedRole}`.
  The author's Mac shows a sheet: *Sam's MacBook wants to review Playlist* —
  a label field (proposed: `ownName`; a picker of known people for *this is
  also…*), the role, and a short code both devices show. The code is
  **shown, never demanded**. Admit writes the person record; every pending
  batch from that person becomes verified.
- **A known person's new device** (certificate signed by an admitted person
  key) is admitted silently. One line in Settings' device list and in
  History: *Sam added iPhone (Sam Ortiz's iPhone) on 5 Sep* — the
  `<label> (<own name>)` convention, shown only where the two differ.
- **The author's own devices** follow the same rule; the author never sees a
  sheet for their own phone.
- A request that names an existing label is never honoured as that label; the
  author supplies the name, so nobody can request admission *as* Sam or *as*
  Claude.

### 4.6 Revocation

- **A device retires itself** (self-signed; a key can only remove its own
  future authority). A person retires their own devices the same way.
- **The author revokes a person** — every device of theirs at once — or one
  device. The record carries `revokedAt` and the highest `opId` the author's
  device had seen from it; later-arriving batches with *earlier* ULIDs are
  quarantined as backdated, which iCloud lag can also cause, so the notice
  says *may be late sync or may be backdated* and offers Apply.
- **This is soft by construction.** A revoked device with folder access can
  still write files. Hard revocation is removing the participant from the
  iCloud share, which the author owns. Settings says so in one sentence next
  to Revoke.

### 4.7 The claim, and adoption

A device with **no trusted chain** — every device that could admit it is gone
and its person key did not arrive (iCloud Keychain off, Apple ID lost) — is
offered one sheet: *This book's history was written by devices this Mac
doesn't know (MacBook Pro, iPhone). Is it yours?* **Claim** makes this
person a new root and signs an **adoption** of the old chain, so the whole
history stays verified and attributed. It has no cryptographic authority and
must not pretend to: the authority is possession of the folder, which is what
the writer has today. What it must be is **loud**: a History line, a
Settings row, and on any surviving device of the old chain a notice that *a
new Mac claimed this book on 5 Sep*.

With iCloud Keychain on, the common restore never reaches this: the person
key arrives, a new device certificate is made, and the Mac is trusted (§4.5).

### 4.8 The device slug is the device key

`DeviceSlug.make(from:)` takes the hostname today. It takes the device key's
fingerprint from P1 on: a new key is a new device and a new file **by
construction**, a restored Mac writes to a new file and reads its old one as
history, and two Macs named alike never collide. `DeviceSlug` keeps its
private init and its filename-only life (tripwire 24); only what `make` is
handed changes. Legacy slugs stay for legacy files. `MacDeviceID` is deleted;
the phone's equivalent follows the same rule through MaughamCore (tripwire 19).

### 4.9 Roles

Two roles in this milestone, on the person record:

| role | may sign | may not sign |
|---|---|---|
| **author** | everything | — |
| **reviewer** | annotation creation ops (comment, query, suggestion), inbox manifest rows | manuscript text ops, structure ops, dispositions (accept/reject/stet/triage), pass states, statements, registry records other than self-revocation |

The role check is per op kind inside a batch: a reviewer's batch carrying a
manuscript op is quarantined whole, and History says *Sam's Mac wrote 2
changes to the manuscript, which a reviewer can't; kept in backup.* WF1's
membrane (Component B) stays in the UI as the cooperative half; this is the
enforced half it explicitly deferred.

**The author lock and the baton** (roadmap; WF2) are this record: an
admission with `role: author` signed by the current author, downgrading the
previous author's role in the same act. Not built here; the record shape
anticipates it and nothing here forecloses it.

### 4.10 The inbox

- **Reviewer captures land in the author's inbox**, signed by the reviewer's
  device and attributed through the registry — the row says *from Sam*. The
  author promotes or discards as today. Storage is the folder's (a
  participant's audio counts against the owner's quota; iCloud's rule, not
  ours).
- **The palette aim is removed**: `PaletteAimPicker`, the `aim:` parameter on
  the three capture sheets, and the writer's `paletteSubject` stamp. The field
  is still decoded (tolerated) and never written. The Mac's promotion path is
  untouched and keeps every destination.
- Attribution needs no new field: `deviceId` is already on every row, and the
  registry resolves it.

### 4.11 The phone

Every iPhone has an enclave; the phone mints its device key and, with the
person key arriving through iCloud Keychain, certifies itself. It **reads its
own role off the registry** through MaughamCore and renders in that posture:
a reviewer's phone offers no dispositions (they would be quarantined anyway)
and does offer capture. The phone shows pending requests as a line, never a
control; admission is a Mac act in this milestone.

### 4.12 What Claude sees

Nothing new is written by MCP. `list_annotations`' `author` already carries
the name the registry resolves. A `list_people` read tool is a later widening
if a use appears; not here.

## 5. Surfaces (every new data type gets one)

- **Project Settings → People & Devices**: one row per person (label, own
  name when different, role, admitted date, Revoke), their devices nested
  (name, kind, enclave or software, added, Retire), pending requests at the
  top, the root marked, claims listed. The one sentence about hard revocation
  being the share's.
- **The admission sheet** (§4.5), only for strangers.
- **History** carries the audit lines: admissions, silent device additions,
  revocations, claims, quarantines, and the one *written before this book was
  signed* line for legacy history.
- **The quarantine notice**: a History line plus, for a manuscript-affecting
  quarantine, a one-time banner in the editor's status footer register — not a
  modal.
- **Phone**: Settings shows this device's person, label and role per project;
  the Annotations tab's posture follows the role.

Nothing goes in the tree, the footer or a badge. Constitution must #2.

## 6. Constitution and ADR accounting

- **AI is never the author** gains its storage-layer enforcement: *no op
  enters a manuscript's history unless Maugham minted it on a device the
  writer admitted.* Falsification: an op that verifies and was not minted by
  Maugham on an admitted device. Text pasted into Maugham's editor is the
  writer's act and is signed as such — the claim authenticates the channel,
  never the human, and says so.
- **The words are safe**: verification never refuses a load; quarantine keeps
  bytes; legacy history is applied.
- **Plain text on disk**: untouched; two added keys on a JSONL line.
- **Nothing pushed**: sheets only for strangers; lines, not badges.
- **Teams** (constitution's stated absence): this is the identity layer WF1
  needs and does not replace WF1's surfaces.
- An ADR (0032) records provenance-not-lock, the person/device split, the
  slug-from-key rule, and the three verification states; ADR 0012 and 0016
  gain a one-line pointer each.

## 7. The spike (gates P1)

1. **Keychain sync on the non-sandboxed Mac.** `Maugham.entitlements` is
   empty. A synchronizable Keychain item needs a keychain-access-group
   entitlement on a Developer-ID-signed build; confirm it syncs Mac↔iPhone
   for this app, how long propagation takes, and what happens with iCloud
   Keychain off (the §4.1 fallback must be reachable, not a crash).
2. **Enclave availability**: `SecureEnclave.isAvailable` on the dev Mac and a
   T2-less Intel Mac; the software fallback's Keychain ACL keeps the key from
   a shell process.
3. **Cost**: sign per batch and verify a 50k-op log on load; the budget is
   under 100 ms added to a cold open at that scale, else segment-level caching
   moves earlier in P1.
4. **Registry propagation** through iCloud Drive as a shared folder: a
   participant's request file reaching the owner, and record deletion by a
   participant surfacing as the cache restore (§4.2).
5. **iOS**: the same items on the phone through the document-picker access
   the phone already uses (tripwire 18's three rules).

Record the answers in `docs/superpowers/notes/` before P1 is planned.

## 8. Sequencing — three plans (rule 11; each built before the next is written)

- **P1 — integrity and the device.** The tail hash chain and batch
  signatures with the device's enclave key; segment signatures at seal; the
  verify-on-load shape with **verified / quarantined** only (no registry yet:
  own-device batches verify, foreign devices' batches are applied as *unsigned
  history* with the History line, so nothing regresses); `DeviceSlug` from
  the key fingerprint and `MacDeviceID` deleted; inbox rows signed; the
  palette aim removed. Closes audit item 10.
- **P2 — people and admission.** The person key and iCloud Keychain sync;
  device certificates; the registry with signed records and the cache; the
  three states in full (pending arrives here); the admission sheet, labels
  and the `<label> (<own name>)` convention; silent device admission with
  audit lines; revocation; the claim and adoption; People & Devices in
  Project Settings; the History lines.
- **P3 — roles and the collaborator.** `author`/`reviewer` on the person
  record; the per-op-kind role check; the reviewer's inbox capture with
  attribution; the phone reading its role and taking its posture; WF1's
  Component A retired in favour of the registry (iCloud share keys as the
  request's default only); the guides and the constitution's amendment.

## 9. Out of scope

- Encryption of anything.
- The baton and co-authoring (WF2) — the record shape anticipates it.
- Any server, and any attestation that needs one (App Attest, DeviceCheck).
- Admission from the phone.
- A code that must be compared; the code is shown.
- Re-signing legacy history.
- Any MCP write; a `list_people` read is a later widening.
