#!/usr/bin/env bash
# verify-mac-signing.sh — the release's loud check that the Mac app carries the
# Developer ID provisioning profile its keychain entitlement needs.
#
# WHY THIS EXISTS: the Release app is entitled to the person key's iCloud
# Keychain group (`keychain-access-groups`, Maugham/Maugham.entitlements). That
# entitlement is RESTRICTED: it holds only under an embedded provisioning
# profile that grants it. `codesign --verify --deep --strict` passes on an app
# signed with the group and NO profile (measured, plan 2 Task 5), so nothing in
# the ordinary signing gate notices a missing profile — and the app that ships
# then reads the keychain as unavailable (or is refused at launch). This script
# is the gate that does notice. release.yml runs it twice:
#
#   verify-mac-signing.sh profile <file.provisionprofile>
#       before the build: the MAC_PROVISIONING_PROFILE secret decodes to a
#       Developer ID profile for this team and bundle id, not expired, that
#       grants the keychain group.
#   verify-mac-signing.sh app <Maugham.app>
#       after signing: Contents/embedded.provisionprofile exists and passes the
#       same checks, and the app's own signature names the group and the
#       application identifier, and the signature verifies.
#   verify-mac-signing.sh resign-entitlements <Maugham.app> <out.plist>
#       before the outer re-sign: writes the entitlements to re-sign with —
#       Xcode's own set minus get-task-allow (see resign_entitlements). Needs
#       none of the environment below.
#
# Required environment (no defaults — the workflow states each one):
#   EXPECT_TEAM       e.g. FF3XH4ZJ45
#   EXPECT_BUNDLE_ID  e.g. com.maugham.Maugham
#   EXPECT_GROUP      e.g. FF3XH4ZJ45.com.maugham.person
# Optional (profile mode): MAC_PROFILE_PLIST — where to leave the decoded plist.
#
# Exit 0 = every check passed; anything else prints `::error::<why>` (a GitHub
# annotation; plain text locally) and exits 1. Exercised by
# scripts/tests/verify-mac-signing.test.sh.

set -euo pipefail

fail() { echo "::error::$*" >&2; exit 1; }

PB=/usr/libexec/PlistBuddy
pb() { "$PB" -c "Print $2" "$1" 2>/dev/null; }

# Every value of an array at a PlistBuddy keypath, one per line.
array_values() {
    local plist="$1" kp="$2" i=0 v
    while v="$(pb "$plist" "$kp:$i")"; do
        echo "$v"
        i=$((i + 1))
    done
}

# Does a profile's entitlement value (exact, or a trailing-`*` wildcard such as
# `FF3XH4ZJ45.*`) allow this concrete value?
allows() {
    local pattern="$1" value="$2"
    [[ "$pattern" == "$value" ]] && return 0
    [[ "$pattern" == *'*' && "$value" == "${pattern%\*}"* ]]
}

require_env() {
    : "${EXPECT_TEAM:?EXPECT_TEAM is required}"
    : "${EXPECT_BUNDLE_ID:?EXPECT_BUNDLE_ID is required}"
    : "${EXPECT_GROUP:?EXPECT_GROUP is required}"
    [[ "$EXPECT_GROUP" == "$EXPECT_TEAM."* ]] ||
        fail "keychain group $EXPECT_GROUP is not in team $EXPECT_TEAM's prefix"
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Decode a CMS-wrapped profile and check what it grants. $2 names it in errors.
check_profile() {
    local file="$1" label="$2" plist="$TMP/profile.plist"
    [[ -s "$file" ]] || fail "$label is missing or empty ($file)"
    security cms -D -i "$file" > "$plist" 2>/dev/null ||
        fail "$label is not a provisioning profile (security cms -D could not decode it)"

    local name team appid expiry now all_devices
    name="$(pb "$plist" ":Name" || true)"
    team="$(pb "$plist" ":TeamIdentifier:0" || true)"
    [[ "$team" == "$EXPECT_TEAM" ]] ||
        fail "$label '$name' belongs to team '$team', not $EXPECT_TEAM"

    appid="$(pb "$plist" ":Entitlements:com.apple.application-identifier" || true)"
    allows "$appid" "$EXPECT_TEAM.$EXPECT_BUNDLE_ID" ||
        fail "$label '$name' is for application identifier '$appid', not $EXPECT_TEAM.$EXPECT_BUNDLE_ID"

    # A Developer ID profile provisions every Mac. A development profile lists
    # its devices instead, and an app shipped under one runs only on those.
    all_devices="$(pb "$plist" ":ProvisionsAllDevices" || true)"
    [[ "$all_devices" == "true" ]] ||
        fail "$label '$name' is not a Developer ID profile (ProvisionsAllDevices is not true) — a development profile would limit the app to its listed Macs"

    expiry="$(plutil -extract ExpirationDate raw -o - "$plist" 2>/dev/null || true)"
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [[ -n "$expiry" && "$expiry" > "$now" ]] ||
        fail "$label '$name' has expired (ExpirationDate '$expiry')"

    local granted=0 g
    while IFS= read -r g; do
        if allows "$g" "$EXPECT_GROUP"; then granted=1; fi
    done < <(array_values "$plist" ":Entitlements:keychain-access-groups")
    [[ "$granted" == 1 ]] ||
        fail "$label '$name' does not grant keychain-access-groups $EXPECT_GROUP (enable Keychain Sharing on the App ID and regenerate the profile)"

    echo "ok: $label '$name' (team $team, $appid, expires $expiry) grants $EXPECT_GROUP"
}

check_app() {
    local app="$1"
    [[ -d "$app" ]] || fail "no app bundle at $app"
    check_profile "$app/Contents/embedded.provisionprofile" "the app's Contents/embedded.provisionprofile"

    local ents="$TMP/signed-entitlements.plist"
    codesign -d --entitlements - --xml "$app" > "$ents" 2>/dev/null ||
        fail "codesign could not read the entitlements of $app"
    [[ -s "$ents" ]] || fail "$app is signed with NO entitlements (expected keychain-access-groups $EXPECT_GROUP)"

    local found=0 g
    while IFS= read -r g; do
        if [[ "$g" == "$EXPECT_GROUP" ]]; then found=1; fi
    done < <(array_values "$ents" ":keychain-access-groups")
    [[ "$found" == 1 ]] ||
        fail "$app's signature does not name keychain-access-groups $EXPECT_GROUP"

    local appid team
    appid="$(pb "$ents" ":com.apple.application-identifier" || true)"
    [[ "$appid" == "$EXPECT_TEAM.$EXPECT_BUNDLE_ID" ]] ||
        fail "$app's signature carries application identifier '$appid', not $EXPECT_TEAM.$EXPECT_BUNDLE_ID — the profile cannot be matched to the app without it"
    team="$(pb "$ents" ":com.apple.developer.team-identifier" || true)"
    [[ "$team" == "$EXPECT_TEAM" ]] ||
        fail "$app's signature carries team identifier '$team', not $EXPECT_TEAM"

    # Notarization rejects a debuggable app; catch it here, before a 15-minute
    # submission says so.
    local gta
    gta="$(pb "$ents" ":com.apple.security.get-task-allow" || true)"
    [[ -z "$gta" || "$gta" == "false" ]] ||
        fail "$app's signature carries com.apple.security.get-task-allow ($gta) — notarization rejects a debuggable app"

    codesign --verify --deep --strict "$app" 2>"$TMP/verify.err" ||
        fail "codesign --verify failed for $app: $(tr '\n' ' ' < "$TMP/verify.err")"

    echo "ok: $app embeds its profile and is signed for $appid with $EXPECT_GROUP"
}

# The entitlements the release re-signs the outer app with: the set XCODE
# signed it with (the file PLUS the com.apple.application-identifier and team
# identifier it takes from the profile — without them the embedded profile
# cannot be matched to the app), read back BEFORE anything is re-signed, with
# com.apple.security.get-task-allow removed. Xcode's `build` action injects
# get-task-allow = true into every signature it makes, whatever the identity
# (only `archive` strips it), and notarization rejects a debuggable app — so a
# set carried across verbatim is one the `app` check below refuses. The key is
# stripped here rather than by CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO, because
# the base entitlements are what supply the application identifier.
resign_entitlements() {
    local app="$1" out="$2"
    # Any signed code, not only a bundle: the release passes the app; the fix
    # wave's rehearsal ran it on Xcode's own Release-built maugham-mcp.
    [[ -e "$app" ]] || fail "no signed code at $app"
    codesign -d --entitlements - --xml "$app" > "$out" 2>/dev/null ||
        fail "codesign could not read the entitlements of $app"
    [[ -s "$out" ]] || fail "$app is signed with NO entitlements"
    plutil -lint "$out" >/dev/null || fail "the entitlements read back from $app do not lint"
    # NOT `plutil -remove`: plutil reads the key as a dotted KEYPATH
    # (com → apple → security → …), finds nothing, and with `|| true` would
    # leave the key in place without a word (measured, Xcode 27.0). PlistBuddy
    # takes the key whole. Absent is fine; still present afterwards is not.
    "$PB" -c "Delete :com.apple.security.get-task-allow" "$out" >/dev/null 2>&1 || true
    if pb "$out" ":com.apple.security.get-task-allow" >/dev/null; then
        fail "could not remove com.apple.security.get-task-allow from $out"
    fi
    plutil -p "$out"
}

mode="${1:-}"
target="${2:-}"
[[ -n "$mode" && -n "$target" ]] ||
    fail "usage: $0 profile <file.provisionprofile> | app <Maugham.app> | resign-entitlements <Maugham.app> <out.plist>"
if [[ "$mode" == resign-entitlements ]]; then
    [[ -n "${3:-}" ]] || fail "usage: $0 resign-entitlements <Maugham.app> <out.plist>"
    resign_entitlements "$target" "$3"
    exit 0
fi
require_env
case "$mode" in
    profile)
        check_profile "$target" "MAC_PROVISIONING_PROFILE"
        # Optional: hand the decoded plist back so the caller need not decode again.
        if [[ -n "${MAC_PROFILE_PLIST:-}" ]]; then cp "$TMP/profile.plist" "$MAC_PROFILE_PLIST"; fi
        ;;
    app) check_app "$target" ;;
    *) fail "unknown mode '$mode' (expected profile, app or resign-entitlements)" ;;
esac
