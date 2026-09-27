# Person key spike — results (plan 1, Task 1, 2026-09-27)

The throwaway probe (`~/src/person-key-probe`, not in this repo) answered every question. **GO for plan 1 as written, including the iCloud saved-by hint in plan 2.**

## 1. Can the Mac and iOS apps share one synchronizable keychain item? YES

- **Setup.** Two targets, team `FF3XH4ZJ45`, each with `keychain-access-groups = $(AppIdentifierPrefix)com.dtrouton.personkeyprobe.shared`. The item is a generic password with `kSecAttrSynchronizable = true` and `kSecUseDataProtectionKeychain = true`.
- **Result.** Written on the Mac, read on Denver's iPhone after iCloud Keychain sync: *Found "Denver probe" — fingerprint b16942dea2bc0027*.

## 2. Developer ID? YES, with an embedded provisioning profile

- The Mac target would not build with automatic signing until an Apple account was signed into Xcode. Xcode then required a Mac App Development profile.
- Exported via Direct Distribution:
  - signed *Developer ID Application: Denver Trouton (FF3XH4ZJ45)*, notarized;
  - carries `Contents/embedded.provisionprofile`, *"Mac Team Direct Provisioning Profile: com.dtrouton.personkeyprobe.mac"*, whose entitlements grant `keychain-access-groups: FF3XH4ZJ45.*`.
- The exported app read the same item: *Found "Denver probe" — fingerprint b16942dea2bc0027*.
- **Consequence for plan 2.** Maugham's Mac release needs a Developer ID provisioning profile for its bundle id, embedded before `codesign` in `release.yml`. The profile is a CI secret, like the phone's `PROVISIONING_PROFILE`. The phone's App Store profile gains the same group.

## 3. Ad-hoc-signed Debug builds? NO keychain

- An ad-hoc-signed binary adding a synchronizable data-protection item fails with **`-34018 A required entitlement is not present`**.
- So the dev app and the test gate can never touch a real iCloud Keychain. They run with the in-memory `PersonKeyStore`, or with none, which gives no claim and today's sheet.
- **Decision for Task 6:** the Debug and test-host builds inject `InMemoryPersonKeyStore` only in tests. The dev app uses the keychain store, which reports *unavailable* (no claim). Real-keychain behaviour is proven only by the plan-2 signed dry run.

## 4. Does iCloud say who saved a file in a shared folder? YES

- On the owner's Mac, `URLResourceValues.ubiquitousSharedItemMostRecentEditorNameComponents` returns:
  - **nil** for every item the current user saved last (107 of 108 files in a real shared folder, "House Stuff");
  - **the other participant's name** for the one file she saved last (*"Quote 4 Gas and UFH.xls" → Rebecca Burgess*).
- Apple's servers set it, not the file's content. It is a name, not an email, and only the most recent editor.
- **Consequence for plan 2:** the admission sheet may add *"iCloud says this device's record was saved by <name>"*. When it is nil on the root's Mac, the root saved it themselves. The hint applies only where the root's Mac is a participant in a share.
