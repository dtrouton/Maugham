# Mac Signing & Notarization — One-Time Setup

The release workflow (`.github/workflows/release.yml`) signs the Mac app with a
**Developer ID Application** certificate and notarizes it with an App Store Connect
API key. The ASC key is the **same one the phone pipeline already uses** — only the
certificate is new. This is the one-time setup to do before cutting the first signed
release.

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

## 4. Dry run (the integration test)

Per the dry-run-is-the-integration-test rule, prove the signing/notarization/install
path on a **throwaway** tag before a real release — cert/profile/API-key/upload and
Apple's bundle validation can only be checked by pushing a real signed build:

    cp docs/release-notes/_template.md docs/release-notes/v0.4.91.md   # minimal notes
    git add docs/release-notes/v0.4.91.md
    git commit -m "chore: dry-run notes v0.4.91"
    ./scripts/cut-release.sh 0.4.91
    git push origin v0.4.91

Watch the run (`gh run watch`). The build must: sign without error, **notarytool
accept** the hardened-runtime build (this is where a missing WhisperKit entitlement
would surface — read `xcrun notarytool log <id>` if it rejects), staple, and pass the
`spctl`/`codesign` gate. Then on a real Mac, download the `.dmg` from the GitHub
Release and confirm it launches with **no right-click → Open**.

Delete the throwaway tag + release afterward:

    gh release delete v0.4.91 --yes
    git push --delete origin v0.4.91
    git tag -d v0.4.91

Build numbers are `github.run_number`, so throwaway tags never collide with later
real releases. The full dry-run checklist is Task 14 of
`docs/superpowers/plans/2026-06-01-mac-auto-update.md`.

## Switching to lowercase later (optional)

Unlike the phone (whose App ID is locked to a capital "M"), the Mac app has no App
Store Connect record — it's distributed outside the store — so the bundle id
`com.maugham.Maugham` and the Developer ID cert are independent. Nothing here is
case-locked the way the phone bundle id is.
