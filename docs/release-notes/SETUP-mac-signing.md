# Mac Signing & Notarization — One-Time Setup

The release workflow (`.github/workflows/release.yml`) signs the Mac app with a
**Developer ID Application** certificate and notarizes it with an App Store Connect
API key, and embeds a **Developer ID provisioning profile** that grants the app its
keychain entitlement. The ASC key is the **same one the phone pipeline already uses**;
the certificate and the profile are the Mac's own. This is the one-time setup to do
before cutting the first signed release.

## 1. Create the Developer ID Application certificate

This is **not** the iOS "Apple Distribution" cert the phone uses — that type cannot
notarize Mac apps. You need a separate **Developer ID Application** certificate.

- Apple Developer portal → **Certificates, Identifiers & Profiles** → Certificates →
  **+** → **Developer ID Application**.
- Follow the CSR flow: Keychain Access → Certificate Assistant → **Request a
  Certificate from a Certificate Authority** → save to disk.
- Upload the CSR, download the resulting `.cer`, and open it — it imports into your
  login keychain alongside its private key.

## 2. Export as .p12 and base64-encode

- Keychain Access → find **"Developer ID Application: <your name> (TEAMID)"** →
  right-click → **Export** → save as `.p12` (set a password you'll remember).
- Base64-encode it for the GitHub secret:

      base64 -i DeveloperID.p12 | pbcopy

## 3. Add GitHub secrets

Repo → **Settings → Secrets and variables → Actions → New repository secret**:

| Secret | Value |
|---|---|
| `DEVELOPER_ID_CERT` | the base64 string from step 2 (now on your clipboard) |
| `DEVELOPER_ID_CERT_PASSWORD` | the `.p12` password from step 2 |

**Reused (already set for the phone pipeline — do NOT recreate):**
`APP_STORE_CONNECT_API_KEY`, `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`.
notarytool authenticates with these.

The workflow derives the Team ID at runtime from the imported certificate
(`security find-identity`), so there is no Team-ID secret to set.

## 4. Provisioning profile

The Release app is entitled to the person key's iCloud Keychain group,
`FF3XH4ZJ45.com.maugham.person` (`keychain-access-groups` in
`Maugham/Maugham.entitlements`). That entitlement is **restricted**: it holds only
under an embedded provisioning profile that grants it, and without one the signed
build fails (*"Maugham" requires a provisioning profile*). The release workflow
refuses to run without the profile rather than ship an app that silently reads the
keychain as unavailable.

**In the portal** (Certificates, Identifiers & Profiles):

1. **Identifiers** → find or register the explicit App ID **`com.maugham.Maugham`**
   (platform macOS). Register one only if it is missing — **+** → App IDs → App →
   macOS, description `Maugham`, Bundle ID *Explicit* `com.maugham.Maugham`.
2. On that App ID's **Capabilities**, make sure **Keychain Sharing** is enabled if
   the portal lists it (on some accounts the keychain group rides on the App ID
   prefix and there is no switch — either way the downloaded profile must grant
   `FF3XH4ZJ45.*` or the exact group; the workflow checks this). Save.
3. **Profiles** → **+** → under *Distribution*, **Developer ID** → App ID
   `com.maugham.Maugham` → the **Developer ID Application** certificate from §1 →
   name it (e.g. `Maugham Developer ID`) → Generate → Download. The file ends in
   `.provisionprofile`.

**Check it before storing it** (from the directory you downloaded it to):

    security cms -D -i Maugham_Developer_ID.provisionprofile > /tmp/mac-profile.plist
    /usr/libexec/PlistBuddy -c 'Print :Entitlements' /tmp/mac-profile.plist
    /usr/libexec/PlistBuddy -c 'Print :ProvisionsAllDevices' /tmp/mac-profile.plist
    EXPECT_TEAM=FF3XH4ZJ45 EXPECT_BUNDLE_ID=com.maugham.Maugham \
      EXPECT_GROUP=FF3XH4ZJ45.com.maugham.person \
      scripts/verify-mac-signing.sh profile Maugham_Developer_ID.provisionprofile

The entitlements must show `com.apple.application-identifier =
FF3XH4ZJ45.com.maugham.Maugham` and `keychain-access-groups` containing `FF3XH4ZJ45.*`
(or the exact group); `ProvisionsAllDevices` must be `true` (a *development* profile
lists devices instead, and would limit the app to those Macs). The last command is
the check the workflow itself runs, and must print `ok:`.

**Store it** as a repository secret (Settings → Secrets and variables → Actions):

    base64 -i Maugham_Developer_ID.provisionprofile | pbcopy

| Secret | Value |
|---|---|
| `MAC_PROVISIONING_PROFILE` | the base64 string now on your clipboard |

**Renewal.** A Developer ID profile expires with (at most) its certificate; the
workflow refuses an expired one by name. Regenerating the certificate means
regenerating this profile against it and replacing the secret — the build needs no
other change, because the workflow reads the profile's name from the secret.

## 5. Dry run (the integration test)

Per the dry-run-is-the-integration-test rule, prove the signing/notarization/install
path on a **throwaway** tag before a real release — cert/profile/API-key/upload and
Apple's bundle validation can only be checked by pushing a real signed build.

**The dry-run band: patch number ≥ 90** (e.g. `v0.5.90`, `v0.5.91`). The release
workflow marks any build whose patch component is ≥ 90 as a **prerelease**, so the
stable channel's `/releases/latest` poll (which excludes prereleases) never surfaces
a throwaway to installed users. This safety is structural — decided in CI from the
version, not a manual post-publish flip. Real releases use normal patch numbers
(`0`, `1`, `2`, …) and publish as stable. (A 0.x line will never legitimately reach
90 patches, so the band can't collide with a real release.)

    cp docs/release-notes/_template.md docs/release-notes/v0.5.90.md   # minimal notes
    git add docs/release-notes/v0.5.90.md
    git commit -m "chore: dry-run notes v0.5.90 (throwaway)"
    git tag -a v0.5.90 -m "Dry-run throwaway 0.5.90"
    git push origin v0.5.90          # cut from the feature branch; the workflow
                                     # fires on any v* tag regardless of branch

Watch the run (`gh run watch`). The build must: install the profile (the log
names it), sign without error, pass *Verify the app carries its provisioning profile* (the log prints the app's
entitlements, then `ok:` lines naming the profile and the group), **notarytool
accept** the hardened-runtime build (this is where a missing WhisperKit entitlement
would surface — read `xcrun notarytool log <id>` if it rejects), staple, and pass the
`spctl`/`codesign` gate. The published release will be a **prerelease** (hidden from
stable auto-update). Then on a real Mac, download the `.dmg` from the GitHub Release
and confirm it launches with **no right-click → Open**.

Delete the throwaway tag + release afterward:

    gh release delete v0.5.90 --yes
    git push --delete origin v0.5.90
    git tag -d v0.5.90

Build numbers are `git rev-list --count HEAD` (the tagged commit's count — see the
workflow's *Extract version* step), not `github.run_number`. The updater compares
`CFBundleShortVersionString` alone, so a throwaway's build number never gets in a
later real release's way. The full dry-run checklist is Task 14 of
`docs/superpowers/plans/2026-06-01-mac-auto-update.md`.

## Switching to lowercase later (optional)

Unlike the phone (whose App ID is locked to a capital "M"), the Mac app has no App
Store Connect record — it's distributed outside the store — so the bundle id
`com.maugham.Maugham` and the Developer ID cert are independent. Nothing here is
case-locked the way the phone bundle id is.
