# The signed op log — the §7 spike, answered (2026-09-07)

Spec: `docs/superpowers/specs/2026-09-05-signed-op-log-design.md`. Its §7 lists five
items that gate P1. This note is the digest; the two full reports, with every command,
verbatim error text and the raw numbers, are beside it:

- `2026-09-07-signed-op-log-spike-items-2-3.md` — enclave, fallback ACL, cost (measured)
- `2026-09-07-signed-op-log-spike-items-1-4-5.md` — keychain sync, registry propagation, iOS (measured where a single Mac allows; procedures where it does not)

Machine: Apple M4, macOS 26.6.2, Xcode 26.6. Every measurement was made from ad-hoc-signed
`swiftc -O` binaries, i.e. the shape of a dev build. Nothing under the repo was modified;
the probe sources lived in the session scratchpad and are not kept — the reports carry the
commands.

Each item below is labelled **MEASURED**, **DOCUMENTED** (Apple's own pages, cited in the
full report) or **PROCEDURE** (needs a second device or account; steps written for Denver).

## The verdict in five lines

1. **Keychain sync** — MEASURED: a synchronizable item is refused outright by any build
   Maugham ships today (`-34018`, "A required entitlement isn't present"), and a dev build
   that merely *claims* the entitlement is `SIGKILL`ed before `main`. The entitlement is
   restricted; it needs a Developer ID provisioning profile, which does not exist yet.
2. **Enclave** — MEASURED: available and working from an entitlement-less binary. The
   §4.1 device key is buildable today with no signing work, provided P1 persists the
   key's `dataRepresentation` itself and never makes it a keychain item.
3. **Cost** — MEASURED: at today's real append grain (one op per line) a 50k-op verify on
   open costs ~3.9 s, 39× the budget. Batching appends cannot reach a safe grain because
   there is no natural batch. **Segment-level caching moves into P1**; a sealed segment
   verifies in 11 ms and the unsealed tail fits.
4. **Registry propagation** — PROCEDURE: needs the second Apple ID that has left WF1's
   participant side unverified since June. A one-record-per-file registry is safe under
   tripwire 17 by construction.
5. **iOS** — MEASURED where it could be: the Secure Enclave is available *in the Apple
   Silicon simulator* and mints a real key, so P1's device-key work is testable there.
   Sync and admission stay device-only.

## Item 1 — Keychain sync on the non-sandboxed Mac

**MEASURED.** From an ad-hoc-signed binary with an empty entitlements file:

| call | result |
|---|---|
| `SecItemAdd`, plain file-based login keychain | `OSStatus=0` — works (item added, read, deleted, absence verified) |
| `SecItemAdd` with `kSecAttrSynchronizable: true` | `-34018` "A required entitlement isn't present." |
| `SecItemAdd` with `kSecUseDataProtectionKeychain: true` | `-34018`, same text |
| permanent synchronizable `SecKey` | `-34018`, same text |
| the same binary re-signed ad-hoc **with** `keychain-access-groups` claimed | **exit 137 (`SIGKILL`) at `exec`, before `main`** — proven with a program whose first statement writes to stderr and prints nothing |

The one-sentence reason: a synchronizable item lives in the data-protection keychain, the
data-protection keychain is gated on an App ID entitlement, and on macOS that entitlement
is *restricted* — it must be authorized by an embedded provisioning profile (TN3125).

**DOCUMENTED.** What a Developer-ID-signed, non-sandboxed Maugham needs:

- `com.apple.application-identifier` = `<TeamID>.com.maugham.Maugham` — sufficient for
  Mac↔Mac sync on its own.
- `keychain-access-groups` = `[<TeamID>.com.maugham.shared]` on **both** apps, only if the
  phone must see the same item. The differing bundle ids (`com.maugham.Maugham` vs
  `com.Maugham.MaughamPhone`) break only the *default* groups; an invented shared group
  sidesteps them. `MaughamPhone` has no entitlements file at all today; it needs one.
- No `com.apple.developer.icloud-*` entitlement is involved. iCloud Keychain is opted into
  per item with `kSecAttrSynchronizable`, not by entitlement.
- Developer ID apps **can** carry `keychain-access-groups`, but only with an embedded
  Developer ID provisioning profile (`Contents/embedded.provisionprofile`). Gatekeeper
  evaluates that profile at **every launch**; profiles are valid 18 years; **when it
  expires the app stops launching.** Today a shipped Maugham launches forever. This is a
  new release-critical secret with a date on it.

**The itemized change list** (full report §1(b), fourteen items) — the ones that decide
something rather than edit something:

- The Apple Developer account needs a Keychain Groups identifier, Keychain Sharing on
  both App IDs, a Developer ID Application profile for the Mac (does not exist), and a
  regenerated phone distribution profile (the existing `PROVISIONING_PROFILE` secret goes
  stale the moment the group is added).
- `release.yml` needs a profile-install step (mirror `phone-release.yml`'s), the profile
  copied into the bundle before the re-sign at its `codesign … --entitlements` line, and a
  **launch-and-quit of the signed app in CI**, because a `SIGKILL`-at-`exec` is invisible to
  both `codesign --verify` and notarization.
- **The dev variant is a design decision, not an edit.** An ad-hoc Debug build cannot
  carry the entitlement. Three options: (a) give Debug a real identity plus its own
  profile for `com.maugham.Maugham.dev`; (b) compile the person key out of Debug; **(c)
  store the person key non-synchronizably in Debug and synchronizably in Release, one
  attribute behind `BuildVariant`** (tripwire 13). The report recommends (c). Either way the
  sync path becomes a dry-run-only feature (`feedback_dry_run_is_integration_test`).

**MEASURED, diagnostic only.** iCloud Keychain is ON for this Mac's account
(`defaults read MobileMeAccounts` shows `KEYCHAIN_SYNC … Enabled = 1`). That plist is
private and unstable; `/usr/bin/security` has no sync subcommand. It is a manual-test aid,
never an API for the app.

**The design constraint this sharpens (for P2).** The app must never ask "is iCloud
Keychain on?"; it must ask "did the person key arrive?" — and handle three outcomes:
`-34018` (not entitled: take the fallback silently, no nag, the permanent state of a dev
build); success with a key already present (certify against it); success with no key
arriving (indistinguishable from lag at any instant — **no timeout may decide it**, since a
wrong guess mints a second person key and splits the writer's identity; mint the local
key at once so writing never blocks, mark it *not yet shared*, watch
`com.apple.security.keychainchanged`, and when an older key arrives adopt and merge; never
delete a key on a timer, since deleting a synchronizable item deletes every copy).

**PROCEDURE** (report §1(c)): the two-device keychain test — Mac writes, Mac B reads
(expect the same person fingerprint and a different device fingerprint, no sheet); the
phone under the shared group; and iCloud Keychain OFF on Mac B (expect no crash, no
modal, writing never blocked, a separate person mergeable through *this is also Denver*).
Precondition: a signed build with the profile. There is no dev-build shortcut.

## Item 2 — Enclave availability and the software fallback's ACL

**MEASURED.** `SecureEnclave.isAvailable == true`. From an entitlement-less ad-hoc binary:

| probe | result |
|---|---|
| `SecureEnclave.P256.Signing.PrivateKey()` — create, sign, verify | works |
| `dataRepresentation` (284 B) persisted to a file, reloaded in a later process, re-signed | same public key, verifies |
| `PrivateKey(accessControl:)` with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` + `.privateKeyUsage` | works, no prompt |
| `SecKeyCreateRandomKey` + `kSecAttrTokenIDSecureEnclave` + `kSecAttrIsPermanent` (file or data-protection keychain) | `-34018` — the key is minted in the SEP; *storing it as a keychain item* is what fails |

So the device key needs no entitlement at all: P1 keeps the opaque blob under `.maugham/`
or Application Support (it is useless off this Mac's SEP) and never makes the enclave key
a keychain item.

**MEASURED — the fallback provides no confidentiality.** A software P256 key stored in
the login keychain was read in full, silently, with no dialog and no password, by: a
different ad-hoc binary; `/usr/bin/security find-generic-password -w`; and a foreign
reader against an item written by a **Developer-ID-signed** writer (the shipped app's
shape). Each reader appended itself to the item's partition list on the way through. An
explicit self-only `SecAccess` and the `requirePassphase` prompt selector changed nothing.
Attribute-only queries succeed for any process with no ACL check at all. The keychain that
would enforce this (data protection) is unreachable until item 1's entitlement work is
done.

**Consequence for the spec.** §4.4's central scenario — an agent with a shell appends an
op and cannot sign it — is **true on an enclave Mac and false on a fallback Mac**, where
the same agent can read the key and sign convincingly. The §4.1 fallback must be described
as a *provenance* key, not a *secret* one, and the record that a device is on the software
fallback (§4.1 already says "recorded as such") is load-bearing rather than cosmetic.

**Not measured.** No Intel hardware here. That the fallback runs and stores is established;
that its ACL is porous carries to Intel unchanged (a property of the login keychain, not
the CPU). Whether `SecureEnclave.isAvailable` returns false cleanly on a T2-less Mac rather
than throwing is untested.

## Item 3 — Cost

**A correction to §4.3 first.** The spec says "`PendingBuffer`'s flush is already the
append unit." It is not. `OpLogStore.append(_ op:)` takes one `Op` and
`JSONLAppendStore.append` writes **one line per call**; every production caller passes a
single op. `PendingBuffer.flushToDisk` is an atomic whole-file write of the pending buffer
to `.maugham/pending/`, deliberately off the op-log glob, and never touches `.maugham/ops/`.
**The real append unit is one op — batch size 1.** And `BurstScheduler` closes a burst
every 30–90 s, so 50k ops is ~800+ hours in one document and per-op signing cost at write
time is irrelevant; the whole question is verify-on-load.

**MEASURED**, 50,000 generated lines shaped on a real Playlist op log (op kinds at the
observed frequencies, 719 B mean line, 35.9 MB), release build, medians of repeated runs:

| operation | cost |
|---|---|
| baseline cold load (read + split + `JSONDecoder` per line, production date strategy) | 1.86–2.01 s |
| hash chain, SHA-256 per line chained on `prev`, all 50k | 31.6 ms (0.63 µs/line) |
| one Secure Enclave P256 signature | 4.49 ms |
| one software P256 signature | 83.5 µs |
| one verify (CPU; identical for both key types, confirmed) | ~78 µs |
| sealed-segment verify: SHA-256 over 35.9 MB + one verify | **11.0 ms** |

Added cost to a cold open = chain + one verify per batch:

| ops per signature | verifies | added | under 100 ms? |
|---|---|---|---|
| **1 (today's grain)** | 50,000 | **3.94 s** | no — 39× over |
| 10 | 5,000 | 419 ms | no |
| 50 | 1,000 | 109 ms | no |
| 58 | 863 | 99–103 ms | on the noise floor |
| 100 | 500 | 70 ms | yes |
| 200 | 250 | 51 ms | yes |

**Verdict: the budget is not met by batching, so segment-level caching moves into P1** —
the outcome §7 named. The chain alone is a third of the budget; the first grain with real
margin is ~100 ops per signature, and the write path has no natural batch of that size.
The seal shape is the answer: a verified segment is cached by content hash (§4.3 already
says so) and never re-verified, so a warm open pays nothing for sealed history and only the
unsealed tail carries per-op verification — at the 512 KB seal threshold a tail is at most
~700 ops, ~55 ms at batch 1, which fits. Two figures to carry into the plan: enclave
signing is **54× slower** than software P256 (harmless once per burst, rules out signing in
any loop), and verification is pure CPU so an enclave-signed log verifies no slower.

**Not asked, but load-bearing.** Of the ~1.9 s baseline, **~1.09 s is
`JSONLAppendStore`'s custom `ISO8601DateFormatter` date strategy** (production strategy
1736 ms; built-in `.iso8601` 650 ms; date not decoded 267 ms). If the 100 ms budget ever
proves tight, the headroom is there, not in the crypto.

## Item 4 — Registry propagation through an iCloud shared folder

**PROCEDURE.** Needs a second Apple Account; the same blocker that has left WF1's
participant-side iCloud review unverified since 2026-06-27, and the procedure pays that
debt first (report Item 4: share via **File → Share for Review…**, *Collaborate*, read &
write; on Mac B expect `role=participant`, editor locked to annotate-only; then the request
file, the pending row appearing **without the writer touching anything**, admission, and
the deletion test — Mac B deletes `.maugham/devices/<Mac A>.json`; Mac A must notice
**loudly** *and* restore a **byte-identical** record whose signature still verifies, never
a fresh re-signed one).

**DOCUMENTED — a one-record-per-file registry is safe under tripwire 17.** Every clause of
ADR 0012's failure turns on two writers appending to one path. The registry's filename is
the fingerprint of the key that writes it, so two devices cannot target one path except by
colliding keys — per-device partitioning taken to its limit. Three caveats, none reopening
the tripwire: an *update* (`revokedAt`, `mergedInto`) is still single-writer while §4.9 has
two roles, and gains a second writer the day a third role can revoke; twins are still
possible from a **restore**, so the loader globs `people/*.json` and tolerates `<name> 2.json`
as `OpLogStore.opLogFileURLs` does; deletion is unprotected, which is what the cache test is
for.

**What the app must observe for the test to be decisive:** a directory-level
`NSFilePresenter` (ADR 0012's own requirement, since a new device's record is a file never
seen), an `NSMetadataQuery` on the ubiquitous scope (the only thing that reports *remote*
arrival and download status), and the `.icloud` placeholder gate the phone already has
(`CoordinatedFileIO.isLocallyReady` + `ensureDownloaded`), applied with tripwire 18's first
rule: a local, non-ubiquitous file has a nil download status and is readable now.

## Item 5 — iOS

**MEASURED, and it corrects an assumption.** A genuine iOS-simulator binary
(`platform IOSSIMULATOR`) spawned on a booted iPhone 17 simulator:

```
SecureEnclave.isAvailable = true
SecureEnclave key: CREATED, dataRepresentation 143 bytes
```

The Apple Silicon simulator proxies to the host's SEP; "no enclave in the simulator" is
Intel-era advice. **P1's device-key work is testable in the simulator.** Every keychain
call from that bare binary returned `-34018` — an artefact of a bundle-less process on a
platform where only the data-protection keychain exists, not a statement about the app; a
real `MaughamPhone` build has the App ID from its profile. And the entitlement cannot be
faked there either: an ad-hoc probe claiming it is refused by launchd (`Security policy
issue`), the simulator's analogue of the Mac's `SIGKILL`.

**DOCUMENTED.** Synchronizable items are stored but never carried anywhere in the
simulator — there is no sync circle. Person-key arrival on the phone is a device-only test.

**What the phone's file model implies.** Reading `.maugham/devices/*.json` beside the op
log goes through the same coordinated, eviction-gated reads as everything else, and the
failure to watch for is a *stricter id predicate*: an empty device list on the phone while
the Mac shows three and the files are present means the loader is filtering filenames by
shape — tripwire 18.3 returning as emptiness rather than error.

**PROCEDURE** (report Item 5): a throwaway `phone-v0.0.x` TestFlight build; confirm the
device row reads *enclave*; the person fingerprint matches the Mac's and the Mac's device
list gains an *added iPhone* line silently; the offline reinstall (Airplane Mode: capture
still works, unresolved-identity posture, converges later without a second person key);
a cold relaunch fetching a fresh record; and the reviewer posture once P3 exists.

## What this changes for P1, before it is planned

- **Segment-level signatures and the content-hash verify cache are P1 work, not P2's**
  (§8's P1 already lists seal signatures; the cache joins them). The tail verifies per op.
- **The device key persists its own blob.** No keychain item, no entitlement, no
  provisioning profile in P1 at all. `DeviceSlug` from the key fingerprint (§4.8) follows
  with no signing work.
- **§4.3's append-unit premise is wrong**; the plan must not restate it. If a batch grain is
  wanted later, it is a new write-path decision, not a property the code has.
- **The software fallback is provenance, not secrecy**, and the spec's §4.4 scenario needs
  that qualifier. The "recorded as such" flag on a fallback device is load-bearing.
- **P2 inherits a gate of its own**: the Developer ID provisioning profile, the shared
  keychain group, the dev-variant decision (recommend option (c) behind `BuildVariant`),
  the launch-and-quit CI step, and the 18-year expiry recorded in `docs/RELEASING.md`.
  None of it can be smoked in a dev build; a signed dry-run build is the integration test.
- **Two tests can run today that were budgeted as hardware-gated**: the enclave path in the
  iOS simulator, and the software-fallback storage path on this Mac.
- **Still owed to Denver, and only Denver can run them**: item 1's two-device sync test,
  item 4's shared-folder test (which also closes WF1's participant-side debt), and item 5's
  on-device run. All three procedures are written in the full reports.
