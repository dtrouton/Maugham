# Your devices are you — design

*2026-09-27. Brainstormed with Denver after the v0.41.0/v0.41.1 People & Devices finds. Architectural: it changes who is admitted without a question, it touches both apps' entitlements, and it ships as a paired Mac and phone release.*

## Why

Denver writes alone, on one Mac and one iPhone. On v0.41.0 his book's People & Devices showed two "Denver Trouton" people:
- the second was his iPhone (code 0ECB);
- this Mac had asked about it once, with the same sheet it shows a stranger;
- he had typed his own name into it.

v0.41.1 groups records by name, which fixes the display. What remains is the experience he asked for:

1. **Never be asked about my own devices.** My Mac, my iPhone, and any second Mac on my Apple ID are just *me*.
2. **Good names without typing.** Person and device names come from the system, including for collaborators' devices.
3. **For a first-time collaborator, a hint as to who they are.**

## What this must not break

- **Admission stays a root's decision, recorded in the register.** Silent admission is a decision the root's Mac makes *on proof*, written through the same door as an asked one: `RegistryAdmission` (tripwire 41).
- **Device keys stay the Secure Enclave's** (tripwire 36). The person key never signs a line of manuscript; it signs only a claim about which device belongs to which person.
- **A book folder is writable by collaborators** on a read-write iCloud share. Nothing a file *says* is proof. The spoofability of a CloudKit user ID written into a file is why that approach was rejected.
- **The phone signs no person record, no event and no claim record** (MaughamPhone/AREA.md; tripwire 41's phone twin). It keeps writing only its own device record, which gains a field.
- **Behaviour-neutral where there is no person key.** No iCloud Keychain, a build that predates this, or a claim that fails to verify all lead to today's admission sheet.

## The model

### The person key

- A P256 signing key stored in **iCloud Keychain**: synchronizable, in one team-prefixed access group shared by the Mac and phone apps.
- The item also carries the person's **name**.
- The first Maugham to run on a device signed into an Apple ID looks for the item. If there is none, it creates one, and iCloud Keychain gives the same key to every device on that Apple ID.
- **Name seeding.**
  - The Mac seeds the name from the account's full name (`DocumentStore.thisWritersName`, `NSFullUserName()`, already the root label's source).
  - The phone creates the item only if none exists. iOS gives an app no owner name, so a phone-created item starts with an empty name.
  - A Mac that finds an item with an empty name writes its account name into it.
- **This is the ONE software private key in production.** Tripwire 36 gets a named allow-list entry with this rationale:
  - A device key must never leave its machine.
  - A person key must move across one person's devices, and iCloud Keychain is the only store that does that without the key ever touching the book folder.
  - It proves *which person*, never *which device*.

### The person claim

- When a device writes its own device record (the Mac's `RegistryPresence.ensureDeviceRecord`; the phone's `PhoneDeviceRecord.ensure`), it embeds a **claim**: "device `<fingerprint>` belongs to person key `<P public key>`, whose name is `<name>`".
- The claim is signed by P. Its canonical form follows `RegistryCanonical`'s rules (tripwire 42): one decider of what is signed.
- **When the phone makes it.** The phone writes its device record only on its first write in a book (an inbox capture or an annotation action), so its claim appears then, not merely on opening the book.
- **Bound to the device.** The claim names the device's own fingerprint, so a claim copied into another device's record does not verify for that record.
- **Compatible with older builds.** Older builds read the device record with the field unknown and keep it byte-faithfully.

### The decision (one pure function)

Given a newly seen device (its verified device record and optional claim) and the register, the root's Mac answers exactly one of:

| Claim | Answer |
|---|---|
| verifies, and P is this root's own person key | **own device**: admit silently under the root's label, whole-book author (the root's own standing) |
| verifies, and P is linked to an admitted person (e.g. Sam) | **known person**: admit silently under Sam's label with Sam's *current* permit (read from the timeline, tripwire 43) |
| verifies, and P is unknown | **ask**, with hints: the claimed person name and device name |
| missing, or does not verify | **ask**, as today, with iCloud's hint if available |

- It feeds `AdmissionDecision`. The silent answers go through `RegistryAdmission`, which records the link and admits.
- Each silent admission leaves a **dated History entry** (*"Sam's iPhone joined as Sam"*, *"Your iPhone joined as you"*), per History's two shapes (ruling C).
- Only a Mac holding the book's root record decides (ruling AA, F10). Every other Mac waits for the root's admission, as today.

### Linking a person key to an existing person

- A person record gains an optional **linked person key**, written only by the root's Mac through `RegistryAdmission`.
- **When it is written.**
  - When a device that is *already admitted* under a person record first shows a verifying claim, the root links that claim's P to that person record.
  - This is safe because the root already decided that device is that person.
  - From then on, the "known person" row applies to that person's new devices.
- **The root's own record** is linked to the root Mac's own P at its next open.
- **If P is already linked elsewhere.** A claim whose P is already linked to a *different* person is not linked again and not trusted for silent admission. The device is asked about, and the sheet says the key is already linked to someone else.

### Names

- **Person name.** Taken from the person key item's name. For an existing person record, the root's label stands; nothing is renamed silently.
- **Device name.**
  - The Mac uses its computer name, as today.
  - On the phone, when the system name is generic (iOS 16+ reports "iPhone" without Apple's user-assigned-device-name entitlement), Maugham builds *"<first name>'s <model>"* from the person name and the device model. No entitlement is needed.
  - Where a user-assigned name is available, it wins.
- **Sheet pre-fill.** For a device that must still be asked about, the admission sheet is pre-filled with the claimed person name and device name. Admission memory still offers a remembered label first.

### A first-time collaborator's hint

- **The claimed name.** The sheet shows the name the claim carries, marked as the device's own claim.
- **iCloud's saved-by name.** For a shared folder, iCloud exposes who last saved a file (the "most recent editor" name components, set by Apple's servers, not by the file's content). If the plan's first task confirms this works on real shares:
  - the sheet adds *"iCloud says this device's record was saved by <name>"*;
  - when the two names disagree, it says so plainly.
- **No email.** No API gives an app the Apple ID email.
- If the spike shows the metadata is unreliable or unavailable, that line is dropped and the claimed name stands alone.

### Revocation and failure

- **Revoking a device** is unchanged: per device, the root's act.
- **Forget this person key.** People & Devices gains this verb on a person. It unlinks P from that person record (a register write through `RegistryAdmission`) so new devices with P are asked about again. Already-admitted devices stay, and the writer revokes them individually if needed. This is the answer to a compromised Apple ID.
- **No iCloud Keychain / not signed in / keychain unavailable.** No claim is made, and the device gets today's sheet. Nothing blocks, and nothing is lost.
- **Two Apple IDs of one person.** These are two person keys, and today's sheet handles it (type the same name; v0.41.1 groups the records).

## Surfaces

- **People & Devices.**
  - A linked person shows *"Recognised on every device signed into this person's Apple ID"*, with **Forget this person key**.
  - Devices admitted silently read like any other.
- **The admission sheet.** Pre-filled names, and the hint lines described above.
- **History.** One dated entry per silent admission, and one per Forget.
- **The phone's Settings → This device.** Says whether this phone carries a person key (*"Recognised as Denver Trouton on your other devices"*) or not (*"iCloud Keychain is off, so each book will ask about this phone once"*).

## Signing, entitlements and release

- **Entitlements.** Both apps gain `keychain-access-groups` with one shared team-prefixed group.
- **Portal steps (Denver).** The Mac is a Developer ID app; the entitlement is expected to need an embedded provisioning profile. That is a one-time Apple Developer portal step by Denver, plus a `release.yml` change. The phone's App ID gains the same group.
- **The dry run is the integration test** (RELEASING.md): a throwaway signed Mac build and a throwaway phone TestFlight build prove the keychain group before the real tags.
- **Paired release** on the current schema. The device record's new field is additive, so there is no schema raise; older builds ignore it and ask as today.

## Testing

- `PersonKey` sits behind a keychain protocol. The gate uses an in-memory keychain, with no real keychain writes and no synchronizable items created on the developer's account.
- Pins, each in both directions, with disable experiments:
  - claim sign/verify;
  - a claim copied into another device's record fails;
  - a claim signed by another key fails;
  - the four decision rows;
  - linking only via an already-admitted device;
  - a P already linked elsewhere is not trusted;
  - Forget returns P's new devices to the sheet;
  - silent admission writes through `RegistryAdmission` only (tripwire 41's census);
  - tripwire 36's allow-list names `PersonKey` alone.
- Censuses: the person key is created and read in one file on each surface; the claim is verified in one function.
- **Smoke** on real hardware: Denver's Mac, his iPhone, and the second Apple ID as a collaborator.
  1. His phone joins his book silently.
  2. A collaborator's first device is asked about, with hints.
  3. Her second device joins silently as her.
  4. Forget, then her next device is asked again.
  5. iCloud Keychain off → the sheet.

## Order (for the plan)

1. **Spike (throwaway):**
   - Can a Developer ID Mac and the iOS app share a synchronizable keychain item, and what does signing need?
   - Does the "most recent editor" metadata work on a real shared folder?
2. Core: `PersonKey` (protocol + keychain), `PersonClaim`, the decision function, the linked-key field, censuses.
3. The Mac: the claim in `ensureDeviceRecord`, the root's silent admission and linking through `RegistryAdmission`, History lines, Forget.
4. The phone: the claim in `PhoneDeviceRecord.ensure`, the device-name rule, Settings' line.
5. Surfaces: sheet pre-fill and hints, People & Devices.
6. Entitlements, signing, and pipeline dry runs.
7. Smoke, then the paired release.

## Out of scope

- An email or any Apple ID detail beyond a name.
- Renaming a person label-wide (a separate small verb, if wanted).
- Recovering a person key after an Apple ID is lost. The answer is Forget plus per-device revoke.
- Any change to what a person may write: permits and the partition are untouched.
