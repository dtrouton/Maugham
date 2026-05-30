# MaughamPhone TestFlight — one-time setup

The `phone-release.yml` workflow signs, archives, and uploads MaughamPhone to
TestFlight on every `phone-v0.X.Y` tag. **The workflow is committed; the Apple
credentials are not.** This file is the one-time setup the *account owner* must do
before the first cut. None of it can be automated from inside the repo.

Mirror of the Mac pipeline (`scripts/cut-release.sh` + `.github/workflows/release.yml`),
adapted for iOS: TestFlight instead of a `.dmg`, real Distribution signing instead
of ad-hoc, and a monotonic build number.

---

## 0. Prerequisites

- **Apple Developer Program** membership (the paid one — required for TestFlight).
- The stable bundle id is **`com.maugham.MaughamPhone`** (the dev variant
  `com.maugham.MaughamPhone.dev` is for Xcode-run builds only — never released).

## 1. Register the bundle id

Developer portal → **Certificates, Identifiers & Profiles → Identifiers → +** →
App IDs → App → description "MaughamPhone", bundle id **explicit**
`com.maugham.MaughamPhone`. No special capabilities are needed (the app uses
iCloud Drive via the document picker / security-scoped bookmarks, not an iCloud
*container* entitlement, so you do **not** need to enable the iCloud capability here).

## 2. Create the App Store Connect app record

App Store Connect → **Apps → +** → New App:
- Platform: iOS
- Name: **Maugham** (or "MaughamPhone" — the public TestFlight name)
- Primary language, SKU (any unique string, e.g. `maugham-phone`), bundle id
  `com.maugham.MaughamPhone`.

This record must exist before the first upload or App Store Connect rejects the build.

## 3. Distribution certificate → `APPLE_DISTRIBUTION_CERT`

Create an **Apple Distribution** certificate (Xcode → Settings → Accounts → Manage
Certificates → + → Apple Distribution, or via the portal). Export it from Keychain
Access as a **`.p12`** with a password, then base64-encode:

```sh
base64 -i AppleDistribution.p12 | pbcopy   # → paste into the secret
```

- Secret `APPLE_DISTRIBUTION_CERT` = that base64 string.
- Secret `APPLE_DISTRIBUTION_CERT_PASSWORD` = the `.p12` password.

## 4. App Store provisioning profile → `PROVISIONING_PROFILE`

Portal → **Profiles → + → App Store Connect (Distribution)** → app id
`com.maugham.MaughamPhone` → the Distribution cert from step 3 → download the
**`.mobileprovision`**, then:

```sh
base64 -i MaughamPhone_AppStore.mobileprovision | pbcopy
```

- Secret `PROVISIONING_PROFILE` = that base64 string.

The workflow reads the profile's **Name** and **TeamID** out of this file at runtime
(via `security cms -D`), so you do **not** need a separate team-id secret, and the
ExportOptions.plist is generated on the fly — nothing account-specific is committed.

## 5. App Store Connect API key → 3 secrets

App Store Connect → **Users and Access → Integrations → App Store Connect API →
Team Keys → +**. Give it the **App Manager** role (enough to upload builds).
Download the **`.p8`** — **you can only download it once.** Note the **Key ID**
and the team **Issuer ID** shown on that page.

```sh
base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy
```

- Secret `APP_STORE_CONNECT_API_KEY` = the base64 `.p8`.
- Secret `APP_STORE_CONNECT_KEY_ID` = the Key ID (e.g. `XXXXXXXXXX`).
- Secret `APP_STORE_CONNECT_ISSUER_ID` = the Issuer ID (a UUID).

This single key both uploads the build (`-exportArchive destination=upload`) and
satisfies any provisioning lookup (`-allowProvisioningUpdates`).

## 6. Add the six secrets to GitHub

Repo → **Settings → Secrets and variables → Actions → New repository secret**:

| Secret | From |
|---|---|
| `APPLE_DISTRIBUTION_CERT` | step 3 (base64 `.p12`) |
| `APPLE_DISTRIBUTION_CERT_PASSWORD` | step 3 |
| `PROVISIONING_PROFILE` | step 4 (base64 `.mobileprovision`) |
| `APP_STORE_CONNECT_API_KEY` | step 5 (base64 `.p8`) |
| `APP_STORE_CONNECT_KEY_ID` | step 5 |
| `APP_STORE_CONNECT_ISSUER_ID` | step 5 |

---

## What you do NOT need for the first (internal) cut

The §9 "Beta App Information minimum" question, resolved:

- **Internal testing only** (≤100 testers who are members of your team in App Store
  Connect) **skips Beta App Review** — the build is usable ~15 min after upload, with
  no review delay and no "Test Information" requirements.
- **No App Privacy nutrition label** is required to test via TestFlight (it's an App
  Store *submission* gate, not a TestFlight gate).
- **No Privacy Policy URL, no Beta App Description, no demo account** are required for
  internal testing. They become mandatory only when you add **external** testers
  (which also triggers a 1–2 day Beta App Review on the first build of each version).
- **Export compliance** is pre-answered: the Info.plist carries
  `ITSAppUsesNonExemptEncryption = false` (set via `project.yml`; the app uses only
  standard HTTPS / iCloud / LocalAuthentication, all exempt), so uploads don't stall
  on the encryption question. If you ever add non-exempt crypto, revisit this.

The privacy *usage strings* (mic, speech, camera, photo library, Face ID) are already
in `project.yml` → the generated `Info.plist`; a missing usage string is the one thing
that *will* reject a TestFlight build, and they're present.

---

## Cutting a release

1. Write notes at `docs/release-notes/phone/v0.X.Y.md`
   (`cp docs/release-notes/phone/_template.md docs/release-notes/phone/v0.X.Y.md`).
2. Commit on `main`.
3. `./scripts/cut-phone-release.sh 0.X.Y` — verifies notes exist, tree clean, on
   `main`, runs the phone test target, creates the `phone-v0.X.Y` tag.
4. `git push origin phone-v0.X.Y` → the workflow runs.
5. ~10–15 min later the build is in App Store Connect → TestFlight → Ready to Test.

**Version is tag-derived** (same rule as the Mac): `project.yml` keeps
`CFBundleShortVersionString: "0.0.0-dev"` and `CFBundleVersion: "1"`; CI rewrites the
version from the tag and the build number from `git rev-list --count HEAD` (monotonic,
never resets — Apple rejects any build number ≤ a prior upload). Don't bump them in
`project.yml`.

## Dry run before the first real cut

Push **`phone-v0.0.1-dev`**… actually no — the trigger pattern is
`phone-v[0-9]+.[0-9]+.[0-9]+`, which a `-dev` suffix would *not* match. For a true
end-to-end rehearsal, push a real-shaped throwaway tag like **`phone-v0.0.1`** (with a
matching `docs/release-notes/phone/v0.0.1.md`), watch the workflow upload to
TestFlight, then **delete the tag, the GitHub release, and the TestFlight build**
before cutting `phone-v0.1.0`. (Build numbers are commit-count-monotonic, so the real
cut will still have a higher build number than the rehearsal — no collision.)

## If the upload step fails

The signed `.ipa` is uploaded as a workflow artifact (`MaughamPhone-<version>-ipa`),
so you can retry the upload manually from Transporter without re-archiving. See spec
§5.5 for the full failure matrix.
