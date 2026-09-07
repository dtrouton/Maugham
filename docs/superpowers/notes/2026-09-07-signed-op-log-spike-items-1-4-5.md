> Full report for items 1, 4 and 5 of the signed-op-log §7 spike, written by the researching subagent on 2026-09-07. Digest: `2026-09-07-signed-op-log-spike.md`. The probe sources and raw output files it names lived in the session scratchpad and are not kept; the commands, error texts and citations are reproduced inline.

# Signed op log — spike items 1, 4 and 5

Run 2026-09-07 against `docs/superpowers/specs/2026-09-05-signed-op-log-design.md` §7.
Items 2 (enclave availability) and 3 (cost) belong to another agent and are not covered here.

Every finding below carries one of three labels:

- **MEASURED** — a command was run on this Mac (or its iOS simulator) and the output is quoted verbatim.
- **DOCUMENTED** — Apple's own words, with the URL.
- **PROCEDURE-ONLY** — cannot be run from this session; written as steps for Denver.

Nothing under `/Users/denver/src/Maugham` was modified. All probe sources, binaries and
raw output live in `…/scratchpad/spike/probe/`.

---

## The one-sentence answer

A synchronizable Keychain item is an item in the **data-protection keychain**, the
data-protection keychain is gated on the app having an **App ID entitlement**, and on
macOS that entitlement is **restricted** — it must be authorized by an embedded
provisioning profile. Maugham today has an empty entitlements file, no team-scoped
entitlements and no profile, so every synchronizable call fails with `-34018`, and a
dev build that merely *claims* the entitlement is killed before `main`.

---

# Item 1 — Keychain sync on the non-sandboxed Mac

## 1(a) What an ad-hoc-signed, entitlement-less process gets — MEASURED

### The probe

`…/scratchpad/spike/probe/probe.swift`, built and run as a plain command-line tool:

```
swiftc -O probe.swift -o probe
./probe
```

Its signature is the same shape as a Maugham dev build (`CODE_SIGN_IDENTITY: "-"`):

```
$ codesign -dvvv --entitlements - ./probe
Identifier=probe
CodeDirectory v=20400 size=734 flags=0x20002(adhoc,linker-signed) hashes=20+0
Signature=adhoc
TeamIdentifier=not set
Internal requirements=none
```

No entitlements, no team identifier. Each case adds one generic-password item, reads it
back, deletes it, and re-queries to prove the delete took.

### Results, verbatim

| Case | Query shape | `SecItemAdd` | Message |
|---|---|---|---|
| A | file-based keychain, `synchronizable` absent (control) | `0` | `No error.` |
| B | file-based keychain + `kSecAttrSynchronizable: true` | `-34018` | `A required entitlement isn't present.` |
| C | `kSecUseDataProtectionKeychain: true`, no synchronizable | `-34018` | `A required entitlement isn't present.` |
| D | `kSecUseDataProtectionKeychain: true` + `synchronizable: true` | `-34018` | `A required entitlement isn't present.` |
| E | D + `kSecAttrAccessible: AfterFirstUnlock` | `-34018` | `A required entitlement isn't present.` |
| F | D + explicit `kSecAttrAccessGroup` | `-34018` | `A required entitlement isn't present.` |
| G | `SecKeyCreateRandomKey`, P256, permanent + synchronizable | fails | see below |

Case A verbatim, showing the control does work and cleans up:

```
=== A. file-based (legacy) keychain, synchronizable ABSENT (control)
  SecItemAdd: OSStatus=0 message="No error."
  SecItemCopyMatching: OSStatus=0 message="No error."
  attrs: synchronizable=<absent> accessible=<absent> accessGroup=<absent> data=maugham-spike-secret
  SecItemDelete (cleanup): OSStatus=0 message="No error."
  post-delete SecItemCopyMatching (expect -25300): OSStatus=-25300 message="The specified item could not be found in the keychain."
```

Case B verbatim — this is the spec's §4.1 shape:

```
=== B. file-based keychain + kSecAttrSynchronizable=true  [spec §4.1 shape]
  SecItemAdd: OSStatus=-34018 message="A required entitlement isn't present."
  SecItemCopyMatching: OSStatus=-25300 message="The specified item could not be found in the keychain."
  SecItemDelete (cleanup): OSStatus=-34018 message="A required entitlement isn't present."
  post-delete SecItemCopyMatching (expect -25300): OSStatus=-25300 message="The specified item could not be found in the keychain."
```

Case G verbatim (a stored `SecKey`, the other plausible way to hold a P256 person key):

```
  SecKeyCreateRandomKey FAILED: -34018 The operation couldn't be completed.
  (OSStatus error -34018 - failed to add key to keychain: <SecKeyRef curve type:
  kSecECCurveSecp256r1, algorithm id: 3, key type: ECPrivateKey, version: 4,
  block size: 256 bits, addr: 0xb2b438010>)
```

`-34018` is `errSecMissingEntitlement`.

### Cleanup — MEASURED

Case A was the only case that added anything. It deleted its own item and the probe
proved the delete with a follow-up query returning `-25300`. A separate sweep after the
run confirms nothing is left behind:

```
$ security find-generic-password -s com.maugham.spike.personkey
security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain.
$ security find-generic-password -s com.maugham.spike.ios
security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain.
$ security find-key -a com.maugham.spike.p256
security: SecItemCopyMatching: The specified item could not be found in the keychain.
```

**The developer's keychain is clean.** No spike item survives.

### A second measurement: a dev build cannot even *claim* the entitlement — MEASURED

This is the finding with the most consequence for the milestone, and it was not
anticipated by the spec. Re-signing the identical binary ad-hoc with a
`keychain-access-groups` entitlement does not produce a keychain error. It produces a
process that never starts.

```
$ codesign --force --sign - --entitlements ents2.plist probe-ent2
$ ./probe-ent2 > run3.txt 2>&1; echo "EXIT=$?"
EXIT=137
```

`137` is `128 + 9`, i.e. `SIGKILL`. To prove the kill lands before `main` rather than
inside a keychain call, a two-line program that writes to unbuffered stderr as its first
statement was signed the same two ways:

```
$ ./tiny              # ad-hoc, no entitlements
MAIN-REACHED
adhoc-noent exit=0
$ ./tiny-ent          # ad-hoc + keychain-access-groups
adhoc-kag exit=137
```

The entitled build prints nothing at all. It is killed at `exec`. The same happens with
`com.apple.application-identifier` added alongside.

**Consequence.** You cannot develop or test this feature in a locally-signed dev build.
Adding `keychain-access-groups` to `Maugham.entitlements` makes the app un-launchable on
the developer's machine, because `project.yml:21` and `:78` sign Debug/dev with
`CODE_SIGN_IDENTITY: "-"` and no provisioning profile. See the itemized list in 1(b) for
what this forces.

### Why the split between case A and cases B–F — DOCUMENTED

Case A works and everything else fails for one reason, and Apple states it directly.

> "On macOS, the advice in this post only applies if you're using the data protection
> keychain. If you're using the traditional file-based keychain, you should never see
> error -34018."
> — Quinn, Apple DTS, https://developer.apple.com/forums/thread/114456

> "To use the data protection keychain your app must be signed with an App ID. Without
> that, you get this errSecMissingEntitlement error."
> — same thread

And a synchronizable item *is* a data-protection-keychain item, by definition:

> "A keychain item created in macOS with this attribute behaves like an iOS keychain
> item. For example, you share the item between apps using Access Groups instead of
> Access Control Lists. To create a keychain item in macOS that behaves like an iOS
> keychain item without making it synchronizable, use kSecUseDataProtectionKeychain
> instead."
> — https://developer.apple.com/documentation/security/ksecattrsynchronizable

So `kSecAttrSynchronizable: true` and `kSecUseDataProtectionKeychain: true` fail for the
*same* reason, which is exactly what cases B and C measured. There is no configuration of
attributes that gets a synchronizable item without an App ID.

### Other constraints the spec's design must respect — DOCUMENTED

From https://developer.apple.com/documentation/security/ksecattrsynchronizable, all
verbatim:

- **Cryptographic keys do sync, but only on recent OSes.** "Starting in iOS 14, macOS 11,
  and watchOS 7, the keychain synchronizes passwords, certificates, and cryptographic
  keys. Earlier OS versions synchronize only passwords." Maugham's floor is macOS 26 and
  iOS 17, so this is satisfied — a P256 key can sync as a key, and does not have to be
  smuggled as a password blob.
- **Sharing requires an explicit access group.** "If a password is intended to be shared
  between multiple applications, the kSecAttrAccessGroup key must be specified, and each
  application using this password must have the keychain-access-groups enabled with a
  common access group specified." This is the Mac↔phone sentence; see 1(b).
- **Delete is global.** "Updating or deleting items using the kSecAttrSynchronizable key
  affects all copies of the item, not just the one on your local device." A bug that
  deletes the person key deletes it on every device the writer owns, which for this
  design means every device silently becomes a separate person. Worth a guard.
- **No `ThisDeviceOnly` accessibility.** "Items stored or obtained using the
  kSecAttrSynchronizable key may not also specify a kSecAttrAccessible value that is
  incompatible with syncing (namely, those whose names end with `ThisDeviceOnly`)."
- **No references, no persistent references.** "Items stored or obtained using the
  kSecAttrSynchronizable key cannot be specified by reference. Use only
  kSecReturnAttributes and/or kSecReturnData to retrieve results." And: "Do not use
  persistent references to synchronizable items."
  **This kills case G's shape.** A synchronizable P256 key cannot be handed back as a
  live `SecKeyRef`; the person key must be stored as raw key material
  (`P256.Signing.PrivateKey.rawRepresentation` in a generic-password item, or a key item
  retrieved with `kSecReturnData`) and re-imported by CryptoKit on each use.
- **Query keys are limited.** "When specifying a query that uses the
  kSecAttrSynchronizable key, search keys are limited to the item's class and attributes.
  The only search constant that may be used is kSecMatchLimit."
- **No `SecAccess` ACLs.** "Items stored or obtained using the kSecAttrSynchronizable key
  cannot specify SecAccess-based access control with kSecAttrAccess." Worth flagging to
  whoever answers spike item 2: the software-fallback ACL idea in §7.2 does **not** apply
  to the *person* key, only to a non-synchronizable software device key.

---

## 1(b) What a Developer-ID-signed, non-sandboxed app needs

### Can a Developer ID app carry `keychain-access-groups` at all? — DOCUMENTED

Yes, but only with an embedded provisioning profile, and the profile then becomes a
launch-time dependency with an expiry.

> "In contrast, *restricted entitlements* must be authorized by a provisioning profile.
> This is an important security feature on macOS. For example, the fact that the
> `keychain-access-groups` entitlement must be authorized by a profile means that other
> developers can't impersonate your app in order to steal its keychain items."
> — TN3125, https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles

TN3125 lists the *unrestricted* macOS entitlements — `com.apple.security.get-task-allow`,
`com.apple.security.application-groups`, the App Sandbox ones and the Hardened Runtime
ones. Everything else, including `keychain-access-groups` and
`com.apple.application-identifier`, is restricted.

> "macOS supports provisioning profiles for both App Store and Developer ID distribution.
> Some entitlements are not supported by Developer ID profiles."
> — TN3125

Keychain sharing is supported by Developer ID profiles. Apple's Developer ID page
describes the arrangement and its sharpest edge:

> "Gatekeeper will evaluate the validity of your Developer ID certificate when your
> application is installed and will evaluate the validity of your Developer ID
> provisioning profile at every app launch. As long as your Developer ID certificate was
> valid when you compiled your app, then users can download and run your app, even after
> the expiration date of the certificate. However, **if your Developer ID provisioning
> profile expires, the app will no longer launch.**"
> — https://developer.apple.com/support/developer-id/

> "Developer ID provisioning profiles generated after February 22, 2017, are valid for 18
> years from the creation date, regardless of the expiration date of your Developer ID
> certificate."
> — same page

18 years is comfortable, but note what changes: today a shipped Maugham keeps launching
forever. After this change, a shipped Maugham stops launching on a date, and the profile
becomes a release-critical secret alongside the signing identity.

The profile is embedded at `Contents/embedded.provisionprofile` inside the app bundle.

### Which entitlements, exactly — DOCUMENTED

Apple's access-group article is the authority on how the set is formed:

> "An app belongs to all groups named in a virtual array of strings formed by
> concatenating the following items in order: [the `keychain-access-groups` entitlement],
> [the `application-identifier` entitlement], [app groups]."
> — https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps

> "Xcode automatically adds the `application-identifier` entitlement (or the
> `com.apple.application-identifier` entitlement in macOS) to every app during code
> signing, formed as the team identifier (team ID) plus the bundle identifier (bundle ID)."
> — same article

> "Order matters. The system considers the first item in the list of access groups to be
> the app's default access group… If you don't specify any keychain access groups, then
> the app ID is the default."
> — same article

> "This form of keychain item sharing applies to all iOS keychain items, and to macOS
> keychain items when you query with the `kSecUseDataProtectionKeychain` key, set the
> item's `kSecAttrSynchronizable` attribute, or both."
> — same article

**So, for a person key that only ever needs to reach the writer's other Macs:**
`com.apple.application-identifier` alone is sufficient. The app's own App ID is its
default access group; no `keychain-access-groups` array is needed. This is the smaller
change, and it is what the spec's §4.1 actually requires if the phone is deferred.

**For the same item to appear on the iPhone:** a shared `keychain-access-groups` entry is
mandatory on both apps. The Apple sentence quoted above is unambiguous — "each
application using this password must have the keychain-access-groups enabled with a
common access group specified."

### Do the differing bundle ids matter? — DOCUMENTED, and the answer is yes-but-solvable

The Mac is `com.maugham.Maugham` (lowercase m, `project.yml:80`); the phone is
`com.Maugham.MaughamPhone` (capital M, `project.yml:199`, deliberate — the registered
App ID cannot be re-registered lowercase).

The consequence is precise. Each app's **default** access group is its own App ID:

| app | default access group |
|---|---|
| Mac | `<TeamID>.com.maugham.Maugham` |
| phone | `<TeamID>.com.Maugham.MaughamPhone` |

These differ, so an item written to either app's default group is invisible to the other,
whatever the sync state. **But a keychain access group name is not a bundle id.** It is
`<TeamID>.<anything-you-registered>`:

> "As with forming the app ID from the bundle ID, Xcode automatically prefixes keychain
> groups with your team ID. This ensures that your groups are specific to your
> development team."
> — same article

So both apps declare a third, shared, invented group — for example
`<TeamID>.com.maugham.shared` — in `keychain-access-groups`, and both write the person key
with `kSecAttrAccessGroup` set to it explicitly. The bundle-id case mismatch is then
irrelevant, because neither app relies on its default group. The one hard requirement is
that both apps are on the **same team**, which they are (both workflows derive `TEAM_ID`
from the same account).

The group must be registered against both App IDs in the developer account, and both
provisioning profiles must carry it.

### Itemized: what would have to change

**`Maugham/Maugham.entitlements`** — today an empty `<dict/>`. Add:

1. `com.apple.application-identifier` = `<TeamID>.com.maugham.Maugham`.
   Required for the data-protection keychain at all. Restricted; needs the profile.
2. `keychain-access-groups` = `[ <TeamID>.com.maugham.shared ]`, and only if the phone
   must see the same item. Restricted; needs the profile. Omit this entirely for a
   Mac-only P2.
3. Nothing else. No `com.apple.developer.icloud-*` entitlement is involved. iCloud
   Keychain is not the iCloud-container/CloudKit family; it rides the KeychainSync
   dataclass on the user's Apple Account, and the app opts in per item with
   `kSecAttrSynchronizable`, not with an entitlement.

**A new phone entitlements file** — `MaughamPhone` has **no** `.entitlements` file at all
today (verified: `MaughamPhone/*.entitlements` does not exist). Create one carrying the
same `keychain-access-groups` array. On iOS the App ID entitlement is added automatically
by the distribution profile, so only the shared group needs declaring.

**Apple Developer account (no repo change, but blocking)**

4. Register a Keychain Groups identifier for `<TeamID>.com.maugham.shared`.
5. Enable Keychain Sharing on the `com.maugham.Maugham` App ID and on the
   `com.Maugham.MaughamPhone` App ID, both carrying that group.
6. Create a **Developer ID Application provisioning profile** for `com.maugham.Maugham`.
   This is the item that does not exist today in any form.
7. Regenerate the phone's distribution provisioning profile so it carries the new group;
   the existing `PROVISIONING_PROFILE` secret becomes stale the moment the group is added.

**`project.yml`**

8. Set `DEVELOPMENT_TEAM` on the Maugham Mac target for Release. Today the team is only
   injected on the command line by `release.yml:186`; a profile-based build needs it in
   the project so `CODE_SIGN_ENTITLEMENTS` resolves `$(AppIdentifierPrefix)` and so local
   Release builds match CI.
9. Decide what the **dev/Debug variant** does — this is the blocking design question, not
   a mechanical edit. The measurement above proves an ad-hoc-signed build carrying either
   restricted entitlement is `SIGKILL`ed at `exec`. Three options, none free:
   - **(a)** Give Debug a real Developer ID identity plus the embedded profile. The
     bundle id is `com.maugham.Maugham.dev` (`project.yml:73`), so that needs its own App
     ID, its own group membership and its own profile. Every developer machine then needs
     the identity installed to launch the app at all.
   - **(b)** Compile the person key out of Debug behind `MAUGHAM_DEV_BUILD` and let the
     dev variant always take §4.1's fallback path (mints its own person key, looks like a
     separate person). Cheapest, and it exercises the fallback constantly, which is a
     virtue. The cost is that the sync path is never exercised except in a signed build,
     i.e. it becomes a dry-run-only feature — the shape
     `feedback_dry_run_is_integration_test` already warns about.
   - **(c)** Store the person key non-synchronizably in Debug (file-based keychain, case A
     above, which measured `OSStatus=0`) and synchronizably in Release. Same fallback
     behaviour as (b) but the storage code path is shared, so only the one attribute
     differs. This looks like the right answer, and it belongs behind `BuildVariant`
     (tripwire 13) rather than an `#if` scattered at call sites.

**`.github/workflows/release.yml`**

10. Add a step before the build that installs the Developer ID provisioning profile from
    a new repository secret, mirroring `phone-release.yml:101-120` — base64-decode,
    `security cms -D` to read its UUID, drop it in
    `~/Library/MobileDevice/Provisioning Profiles/<UUID>.mobileprovision`. A new secret,
    say `MAC_PROVISIONING_PROFILE`, joins `PROVISIONING_PROFILE`.
11. Copy the profile into the built bundle as
    `<App>/Contents/embedded.provisionprofile`, before the re-sign at line 261. Xcode does
    this itself for a profile-based signing style; the current build
    (`release.yml:183-186`) passes only `DEVELOPMENT_TEAM` and would not.
12. `release.yml:261` — `codesign … --entitlements Maugham/Maugham.entitlements "$APP"` —
    needs no textual change, but it now re-seals a bundle whose entitlements are
    restricted. If the embedded profile is missing or does not authorize the group, this
    line still **succeeds** and the failure appears only when a user launches the app.
    Add a verification step after it:
    `codesign -d --entitlements - "$APP"` to confirm the entitlements are present, and an
    actual launch-and-quit of the signed app in CI, because a `SIGKILL`-at-`exec` is
    exactly what neither `codesign --verify` nor notarization will catch.
13. Consider switching the Release build to `CODE_SIGN_STYLE: Manual` with
    `PROVISIONING_PROFILE_SPECIFIER`, as `phone-release.yml:163-164` already does, rather
    than hand-embedding the profile.

**`docs/RELEASING.md`**

14. Record the profile's 18-year expiry and that the app stops launching when it passes.

---

## 1(c) Propagation time and iCloud-Keychain-OFF behaviour

### What cannot be measured here — stated plainly

Neither is measurable in this session.

- **Propagation time** needs a second device signed into the same Apple Account, running a
  Developer-ID-signed build that carries a provisioning profile that does not yet exist.
  Three preconditions, none of which this session can create.
- **iCloud Keychain OFF** would mean turning off iCloud Keychain on the developer's own
  Mac. That evicts the machine from the sync circle and can require re-establishing trust
  from another device or the account's recovery flow. It is not a thing to do to
  somebody's working machine, and I did not do it.

### Read-only detection of iCloud Keychain state — MEASURED

There is a read-only way, and it works. The `KEYCHAIN_SYNC` dataclass appears in the
iCloud account plist:

```
$ defaults read MobileMeAccounts | grep -n -i keychain
202:                    Name = "KEYCHAIN_SYNC";
203:                    ServiceID = "com.apple.Dataclass.KeychainSync";
```

with its surrounding block:

```
{
    Enabled = 1;
    Name = "KEYCHAIN_SYNC";
    ServiceID = "com.apple.Dataclass.KeychainSync";
    authMechanism = token;
    escrowProxyUrl = "https://p113-escrowproxy.icloud.com:443";
}
```

**iCloud Keychain is ON for `dtrouton@gmail.com` on this Mac.** Which is useful: it means
Denver's own two-device test needs no setup on this side.

Two caveats before anyone reaches for this in production code. The plist lives in
`~/Library/Preferences/MobileMeAccounts.plist` and is private, undocumented and unstable
across releases. And `/usr/bin/security` offers nothing — `security help` has no `sync`,
`circle` or `cloud` subcommand at all (measured: the grep returns no matches). So this is
a **diagnostic aid for Denver's manual procedure, not an API for the app.**

### What the code must do instead — the design constraint

The app must never ask "is iCloud Keychain on?". It must ask "did the person key arrive?"
The two are different questions and only the second one is answerable, because iCloud
Keychain can be on and the item still not have arrived (lag), or on and never arrive (a
device not in the sync circle, a restored device mid-escrow).

This is exactly §4.1's fallback, and the measurement above sharpens what it must handle.
Three distinct outcomes, and the code needs all three:

1. **`SecItemAdd` returns `-34018`.** Not a sync problem — the build is not entitled. This
   is what a dev build does, permanently. Take the fallback immediately and silently:
   mint a local person key in the file-based keychain (measured working, `OSStatus=0`),
   record it as unsynced, carry on. **It must not crash and must not nag**, since it is
   the normal state of every dev build under option (b) or (c) above.
2. **`SecItemAdd` succeeds and a key is already present** from another device. Normal
   path. Certify this device against it.
3. **`SecItemAdd` succeeds and no key ever arrives.** Indistinguishable at any single
   moment from "it will arrive in a minute". The design must not have a timeout that
   decides this, because a wrong guess mints a second person key and permanently splits
   the writer's identity in two — recoverable only through the admission sheet's *this is
   also Sam*. The honest shape: mint the local key at once so writing is never blocked,
   mark it *not yet shared*, keep watching for an arriving key, and when one arrives that
   is older, adopt it and merge. Never delete a key on a timer — remember Apple's
   "deleting… affects all copies of the item".

A concrete detail for whoever writes P2: the arriving-key watch is not a poll of
`SecItemCopyMatching` on a timer. Register for the Darwin notification
`com.apple.security.keychainchanged` (and `…view-change`), which is what fires when
iCloud Keychain lands an item.

### PROCEDURE-ONLY — Denver's two-device keychain test

Preconditions: items 4–7 and 10–13 of 1(b) are done, and a signed build exists. This
cannot be run before then; there is no shortcut with a dev build.

*Setup*

1. On the Mac, confirm sync is on: System Settings → Apple Account → iCloud → Passwords
   & Keychain is on. Cross-check with `defaults read MobileMeAccounts | grep -A3
   KEYCHAIN_SYNC` and expect `Enabled = 1`.
2. Same check on the iPhone: Settings → Apple Account → iCloud → Passwords.
3. Confirm both devices show each other in Settings → Apple Account → Devices. A device
   not in the list is not in the sync circle and will never receive the item.

*Test 1 — Mac writes, second Mac reads (the §4.1 primary path)*

4. Launch the signed Maugham on Mac A with a fresh project. Note the timestamp.
5. In Settings → People & Devices, read the person fingerprint. Record it and the wall
   clock.
6. Launch the same signed build on Mac B. Watch the fingerprint.
7. **Expect**: Mac B shows the *same* person fingerprint and a *different* device
   fingerprint, and Mac B never shows an admission sheet. Record the elapsed time from
   step 5. Apple gives no SLA; seconds-to-a-few-minutes is typical, and a locked or
   sleeping device does not sync.
8. **If Mac B shows a different person fingerprint**, the fallback fired. That is a pass
   for robustness and a fail for sync. Check `codesign -d --entitlements - /Applications/Maugham.app`
   on both, and check that both machines are in the same sync circle.

*Test 2 — the phone (only if `keychain-access-groups` shipped)*

9. Install the TestFlight build. Open it, adopt the projects folder.
10. **Expect**: the phone's device list entry appears under the *same* person as the Macs.
11. **If the phone mints its own person**, the shared access group is wrong. Verify with
    `codesign -d --entitlements -` on the Mac app and by checking the phone's embedded
    profile carries the same `<TeamID>.com.maugham.shared`.

*Test 3 — iCloud Keychain off (the fallback)*

12. On Mac B **only**, turn off iCloud → Passwords & Keychain. Choose *Keep on this Mac*
    if offered.
13. Delete Mac B's Maugham container state so it starts cold.
14. Launch Maugham on Mac B.
15. **Expect**: no crash, no hang, no error dialog. Mac B mints its own person key, is
    listed as a separate person, and the admission sheet on Mac A offers *this is also
    Denver*. Writing must work throughout — the key is not on the critical path for
    typing.
16. **The failure to look for**: a spinner, a modal, or an editor that refuses input while
    something waits for a key. Any of those means the key was made a blocking dependency
    of writing, which violates constitution must #1.
17. Turn iCloud Keychain back on and confirm Mac B converges or, at minimum, that the two
    person keys are mergeable through the sheet.

---

# Item 4 — Registry propagation through iCloud Drive as a shared folder

**PROCEDURE-ONLY.** This needs a second Apple Account and cannot be run from this session.
It is the same blocker that has left WF1's participant side unverified since 2026-06-27.

## The standing debt this test also pays off

`memory/project_collaboration_wf1.md` records the open gate verbatim:

> **PARTICIPANT side UNVERIFIED — needs a friend/2nd-Apple-ID smoke**: confirm an invitee
> resolves `role=participant`, `by=<owner>` non-empty, `write=rw`, and is correctly locked
> to annotate-only.

`ShareIdentityMapper` / `FileURLShareMetadataReader` in MaughamCore already read
`.ubiquitousSharedItemCurrentUserRoleKey` and friends, and the **owner** side was verified
on a real share (`shared=yes role=owner write=rw`). Only the participant side is open.
Denver should run item 4 and the WF1 participant smoke in **one sitting on one share** —
they need the same two accounts, the same folder and the same invite, and the registry
records are written by exactly the participant whose role WF1 wants to observe.

## Is a one-record-per-file registry safe under tripwire 17? — reasoned, DOCUMENTED by ADR 0012

Yes, and for a stronger reason than the op log's.

Tripwire 17 forbids **a single shared JSONL file across devices via iCloud Drive**. ADR
0012 states the mechanism:

> "iCloud detects divergence (both devices have a 'newer than the last common version'
> file). The reconciler resolves by *whole-file replace*, not line-merge. The loser's copy
> lands as a conflict-named twin alongside the canonical file… `OpLogStore.load(docId:)`
> opens exactly one path. Twin files are invisible. The loser's ops are silently lost."

Every clause of that turns on **two writers appending to one path**. The registry has no
such path. `.maugham/people/<personFingerprint>.json` and
`.maugham/devices/<deviceFingerprint>.json` are one record per file, and the filename is a
**fingerprint of the key that writes it**, so two devices cannot target the same path
except by producing the same key — which is the collision the fingerprint exists to make
impossible. It is per-device partitioning taken to its limit: not one file per device per
document, but one file per device, full stop.

ADR 0012's own words about why partitioning works apply unchanged: "Two devices can never
target the same file path, so iCloud never has to reconcile divergent versions of the same
file. Conflict-twins are impossible by construction."

Three caveats, none of which reopen the tripwire:

- **A record is written once, not appended to.** If a person record is ever *updated* —
  `revokedAt`, `mergedInto` — the writer is the admitting author's device and only that
  device, so it is still single-writer per path. If two authors could ever revoke the same
  person, that path gains a second writer and the tripwire returns. §4.9's two roles make
  that impossible in this milestone; note it for the day a third role appears.
- **Twins are still possible from a restore**, not from concurrency — iCloud can produce a
  twin when a device comes back from backup. The loader should glob and tolerate a
  `<name> 2.json` rather than assume one path, exactly as `OpLogStore.opLogFileURLs` does.
- **Deletion is unprotected.** §4.2 already says so: "Signing protects authorship, never
  existence." That is what step 12 below tests.

## The procedure

*Setup — one share, both tests*

1. On Mac A (owner, `dtrouton@gmail.com`), put a throwaway project in iCloud Drive. Use
   Maugham's own **File → Share for Review…** so the share is created the way a writer
   would create it — that path is `ProjectShareEligibility` plus an `NSSharingServicePicker`
   and is itself worth exercising.
2. Choose **Collaborate**, permission **read & write**, and invite the second Apple
   Account. Do not choose "copy" — a copy produces no share metadata at all, which is the
   silent failure WF1's Component H exists to prevent.
3. On Mac B, signed into the second account, accept the invitation and let the folder
   download fully.

*WF1 debt, first, because it costs one screenshot*

4. Open the project in Maugham on Mac B. **Expect** the sharing pill to read
   `shared=yes role=participant by=<owner name> write=rw`, and the editor to be locked to
   annotate-only with no way to type manuscript text. Confirm ⌘⌥R flips the marks but
   never unlocks text — `ReviewPosturePolicy`'s `lockEditing` hard floor.
5. Record whether `.ubiquitousSharedItemCurrentUserRoleKey` resolves immediately on open
   or after a delay, and how long any `.unknown` window lasts. That window is the thing
   WF1's contingency was written against.

*Registry propagation*

6. On Mac B, note the device fingerprint in Project Settings → People & Devices, and the
   file that appeared: `.maugham/devices/<fingerprint>.json`. Confirm a request file was
   written beside it.
7. On Mac A, wait. **Expect** a pending-request row at the top of People & Devices, with
   the sheet's *Sam's MacBook wants to review…* wording, the proposed `ownName`, the role,
   and the short code. Record the elapsed time from step 6.
8. **The thing to observe**: does the row appear **without the writer touching anything**?
   That is the whole question. If the request only appears after Mac A's window is closed
   and reopened, the app is not observing the folder and the feature is broken in the way
   that matters most, because a writer will not know to look.
9. Admit. **Expect** a `people/<fingerprint>.json` on Mac A, propagating to Mac B, and
   Mac B's own pending ops flipping from pending to verified. Record that elapsed time
   too.

*The deletion test — §4.2's cache restore*

10. On Mac A, confirm the cache holds the registry it last verified.
11. On Mac B (the participant, who has write access to the share and therefore can delete),
    delete `.maugham/devices/<Mac A's fingerprint>.json` in Finder.
12. On Mac A, **expect** the deletion noticed **loudly** — not silently healed. §4.2 says
    "A record missing from the folder reads as *removed by someone*, loudly, and is
    restored from the cache." Both halves must happen: a visible notice *and* the file
    reappearing.
13. **Expect** the restored file to be byte-identical to the original, and its signature to
    still verify. Diff it against a copy taken at step 10.
14. **The failure to look for**: Mac A quietly re-creating the record with a fresh
    `madeAt`, or re-signing it. A restored record must be the *same* record, or the cache
    is a forgery mechanism rather than a backup.

## What the app must observe for the test to be decisive

The test above is only meaningful if the app is actually watching. Three mechanisms, and
which one is used changes what step 8 measures:

- **`NSFileCoordinator` + an `NSFilePresenter` on the directory.** ADR 0012 already names
  this requirement for the op log: "New per-device files appear at runtime (a phone's
  first write creates a file the Mac has never seen). The presenter must subscribe at
  **directory level** for `presenterDidChangeSubitem` to fire." The registry has exactly
  this shape — a brand-new file from a device never seen. A presenter scoped to known
  files will observe nothing, and step 8 will fail for that reason rather than a sync one.
- **`NSMetadataQuery`** with scope `NSMetadataQueryUbiquitousDataScope` is the mechanism
  that actually reports *remote* changes and download progress. A file presenter tells you
  about the local filesystem; the metadata query tells you a peer wrote something and
  whether it has arrived. For a shared folder, this is the one that matters, and the
  `NSMetadataUbiquitousItemIsDownloadingKey` / `…DownloadingStatusKey` values are what
  distinguish "no request exists" from "a request exists and has not arrived".
- **`.icloud` placeholder eviction.** A registry record that has been evicted is a
  zero-byte `.<name>.json.icloud` placeholder, and a naive `Data(contentsOf:)` on it reads
  nothing or throws. The phone already solved exactly this — `CoordinatedFileIO`'s
  `isLocallyReady` plus `ensureDownloaded` before every coordinated read (`MaughamPhone/AREA.md`
  tripwire 6). The Mac's registry loader needs the same gate, and tripwire 18's first rule
  applies verbatim: **do not assume a file is evicted**, since a local, non-ubiquitous file
  has a nil download status and is readable now. Assuming eviction is what broke phone
  browsing entirely on the 2026-05-30 smoke.

One more, worth deciding before P2 rather than discovering: **conflict twins**. Have the
loader glob `people/*.json` rather than construct one path per known fingerprint, so a
`<fingerprint> 2.json` from a restore is seen rather than ignored, and so an unknown
person's record is found at all.

---

# Item 5 — iOS

## What was measured — MEASURED, and it corrects an assumption

The brief expected `SecureEnclave.isAvailable` to be documented as `false` on the
simulator. On this machine it is **`true`**, and a key really is created.

A Swift probe was compiled for the simulator and run on a booted iPhone 17
(`xcrun simctl spawn`). It is a genuine iOS-simulator binary, not a Mac one:

```
$ vtool -show-build iosprobe
 platform IOSSIMULATOR
    minos 26.0
      sdk 26.5
```

Output, verbatim:

```
$ xcrun simctl spawn 525F69CA-EF85-4BF8-BE3C-0D408DBA07C3 .../iosprobe
SecureEnclave.isAvailable = true
plain: SecItemAdd OSStatus=-34018 "A required entitlement isn't present."
plain: SecItemCopyMatching OSStatus=-34018 "A required entitlement isn't present."
plain: SecItemDelete OSStatus=-34018 "A required entitlement isn't present."
sync: SecItemAdd OSStatus=-34018 "A required entitlement isn't present."
sync: SecItemCopyMatching OSStatus=-34018 "A required entitlement isn't present."
sync: SecItemDelete OSStatus=-34018 "A required entitlement isn't present."
SecureEnclave key: CREATED, dataRepresentation 143 bytes
```

Three things to read out of that, carefully, because two of them are easy to misread.

**One — the enclave is available on the Apple Silicon simulator, and it works.** Not just
the flag: `SecureEnclave.P256.Signing.PrivateKey()` returned a real key with a 143-byte
data representation. The simulator on Apple Silicon proxies to the host Mac's own Secure
Enclave. The widely-repeated "no SE in the simulator" is Intel-era advice. **This means
P1's device-key work is testable in the simulator**, which is worth a good deal — it was
budgeted as hardware-gated.

**Two — the `-34018` on every keychain call is an artefact of the harness, not a statement
about the app.** A bare binary spawned by `simctl` is not an app: it has no bundle and no
`application-identifier` entitlement. Note that even the *plain, non-synchronizable* add
failed, which is the tell — on iOS there is only the data-protection keychain, so
everything needs the App ID. Quinn, on the same point:

> "This requirement isn't a problem on iOS because all iOS apps have that entitlement
> (occasionally we see it cause problems on the iOS Simulator, when Xcode and the iOS
> Simulator's understanding of how things work gets out of whack…)"
> — https://developer.apple.com/forums/thread/107586

A real `MaughamPhone` build gets the entitlement from its profile and will not see this.
**Do not read this row as "keychain is broken in the simulator."**

**Three — you cannot fake the entitlement in the simulator either.** Signing the same
probe ad-hoc with `application-identifier` and `keychain-access-groups` produces a refusal
to launch, the simulator's analogue of the Mac's `SIGKILL`:

```
$ codesign --force --sign - --entitlements iosents.plist iosprobe-ent
$ xcrun simctl spawn <udid> .../iosprobe-ent
An error was encountered processing the command (domain=com.apple.CoreSimulator.LaunchdSimError, code=163):
Process spawn via launchd failed.
Underlying error (domain=SimXPCErrorDomain, code=163):
	Security policy issue
```

## What remains hardware- or account-gated on iOS — DOCUMENTED

**Synchronizable items do not sync in the simulator.** The simulator has no Apple Account
sync circle; `kSecAttrSynchronizable` can be set, and the item is stored, but nothing
carries it anywhere. Apple's position, from the search of the developer forums, is that
the simulator "does not try to faithfully replicate the security architecture of iOS; its
focus is on supporting, or not supporting, APIs". So the *API* works and the *sync* does
not. iCloud Keychain arrival on the phone is a device-only test. The relevant Apple pages:
https://developer.apple.com/documentation/security/ksecattrsynchronizable and
https://developer.apple.com/forums/thread/676891.

## What the phone's file-access model implies for reading `.maugham/devices/*.json`

The registry files sit in the same folder tree the phone already reads, so the rules that
already govern the op log govern the registry — and all three of tripwire 18's clauses
bite, in different places.

**Route every registry read through `ensureDownloaded` then `coordinatedRead`.** This is
`MaughamPhone/AREA.md` tripwire 6, and it is not optional: a device record written by a Mac
five minutes ago is, from the phone's point of view, exactly the evicted-placeholder case.
The registry loader must be a `CoordinatedFileIO` client, not a `Data(contentsOf:)` caller.
Since the registry is shared Mac↔phone, tripwire 19 applies with full force — **the loader
belongs in MaughamCore**, and the phone must not grow its own. The one thing that is
allowed to differ is the injected `UbiquitousFileSystem` seam.

**Do not assume a record is evicted** (tripwire 18.1). `isLocallyReady` treats
`.current`/`.downloaded` *or a nil-status file that exists* as readable now. The phone's own
device record — the one it just wrote — is local and non-ubiquitous at the moment of
writing, so a loader that calls `startDownloadingUbiquitousItem` unconditionally will throw
on the phone's own record. That is precisely the bug that "broke browsing entirely" on the
2026-05-30 smoke, and the registry gives it a fresh place to happen.

**`startAccessingSecurityScopedResource() == false` is not a denial** (tripwire 18.2). The
`.maugham/devices/` directory is reached through the same bookmarked projects root, and
`ProjectsRoot` adopts the folder regardless. A registry loader that treats the `false`
return as "no permission, show an error" will report a permissions failure on a folder it
can read perfectly well.

**The filename is a fingerprint — do not invent a stricter id predicate** (tripwire 18.3,
generalized). The op-log version of this cost the phone a shipped "No open annotations"
bug, because `hasPrefix("d_")` and a 26-char-ULID check each matched zero real files. The
registry's filenames are key fingerprints whose encoding is P1's choice — hex, base64url,
truncated or not. **Enumerate `devices/*.json` and take the basename; do not validate its
shape.** If the phone needs to know whether a fingerprint is its own, it should compare
against its own computed fingerprint, never against a pattern.

One further consequence, from §4.11: the phone reads its role off the registry to decide
its posture. That read is now on the phone's **launch** path and is subject to iCloud
download latency. The posture must have a safe default for the window in which the registry
has not arrived — and by WF1's precedent that default is the cautious one
(`ReviewPosturePolicy` locks `.unknown`), not the permissive one.

## PROCEDURE-ONLY — Denver's on-device iOS test

Preconditions: the phone's entitlements file exists, the shared keychain group is
registered, the phone profile is regenerated, and a TestFlight build is out. Per
`MaughamPhone/AREA.md`, cut a throwaway `phone-v0.0.x` tag — the dry run *is* the
integration test, and five on-device bugs have already escaped `xcodebuild test` this way.

1. Before installing, confirm on the phone: Settings → Apple Account → iCloud → Passwords
   is on, and the Macs appear under Devices.
2. Install the TestFlight build and adopt the projects folder through the document picker.
3. **Enclave** — in Settings, confirm the device row reads *enclave*, not *software*. The
   simulator already told us the API path works; this confirms the real hardware path and
   that the key is not silently falling back.
4. **Person key arrival** — confirm the phone's person fingerprint matches the Mac's, and
   that the Mac's device list gains an *added iPhone* line **silently**, with no admission
   sheet (§4.5: "The author's own devices follow the same rule; the author never sees a
   sheet for their own phone"). Record how long the person key took to arrive from a cold
   install.
5. **The negative case that matters most** — turn Airplane Mode on, delete and reinstall
   the app, then launch it offline. **Expect**: capture still works, the phone shows an
   unresolved-identity posture, and nothing blocks. Then turn networking on and confirm it
   converges without a second person key being minted.
6. **Registry read under eviction** — on the Mac, add a device record, then on the phone
   force-quit and relaunch cold so the record is fetched fresh. Confirm the phone shows it
   rather than reporting an error. This is the tripwire-6 path.
7. **Role posture** (P3, but observable early) — with the phone's person record set to
   `reviewer`, confirm the phone offers capture and offers no dispositions, and that a
   pending request shows as a line and never as a control (§4.11).
8. **The failure to look for throughout**: a *stricter id predicate*. If Settings shows an
   empty device list on the phone while the Mac shows three devices, and the files are
   present in the folder, the loader is filtering filenames by shape. That is tripwire
   18.3 returning, and it presents as emptiness rather than as an error.

---

## Appendix — artefacts

All under `…/scratchpad/spike/probe/`:

| file | what |
|---|---|
| `probe.swift` / `probe` | the macOS keychain probe, ad-hoc, no entitlements |
| `run1.txt` | its verbatim output (cases A–G) |
| `ents.plist` / `ents2.plist` | entitlement plists used for the SIGKILL measurement |
| `probe-ent`, `probe-ent2` | the same binary re-signed; both exit 137 |
| `tiny.swift` / `tiny`, `tiny-ent` | the two-line before-`main` proof |
| `iosprobe.swift` / `iosprobe` | the iOS-simulator probe |
| `iosrun.txt` | its verbatim output |
| `iosents.plist`, `iosprobe-ent` | the simulator's refusal-to-launch measurement |

The iPhone 17 simulator (`525F69CA-EF85-4BF8-BE3C-0D408DBA07C3`) was booted and left
booted; shut it down with `xcrun simctl shutdown 525F69CA-EF85-4BF8-BE3C-0D408DBA07C3` if
that matters. No keychain items survive the run.

## Sources

- [kSecAttrSynchronizable](https://developer.apple.com/documentation/security/ksecattrsynchronizable)
- [kSecUseDataProtectionKeychain](https://developer.apple.com/documentation/security/ksecusedataprotectionkeychain)
- [Sharing access to keychain items among a collection of apps](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps)
- [Keychain Access Groups Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/keychain-access-groups)
- [TN3125: Inside Code Signing: Provisioning Profiles](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)
- [Developer ID certificates and provisioning profiles](https://developer.apple.com/support/developer-id/)
- [Troubleshooting -34018 keychain errors (Quinn)](https://developer.apple.com/forums/thread/114456)
- [Can't generate keypair through SecureEnclave (Quinn, on the simulator)](https://developer.apple.com/forums/thread/107586)
- [Accessing iCloud keychain](https://developer.apple.com/forums/thread/676891)
- [errSecMissingEntitlement](https://developer.apple.com/documentation/security/errsecmissingentitlement)
