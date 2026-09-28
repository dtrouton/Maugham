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
#
# Required environment (no defaults — the workflow states each one):
#   EXPECT_TEAM       e.g. FF3XH4ZJ45
#   EXPECT_BUNDLE_ID  e.g. com.maugham.Maugham
#   EXPECT_GROUP      e.g. FF3XH4ZJ45.com.maugham.person
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

    codesign --verify --deep --strict "$app" 2>"$TMP/verify.err" ||
        fail "codesign --verify failed for $app: $(tr '\n' ' ' < "$TMP/verify.err")"

    echo "ok: $app embeds its profile and is signed for $appid with $EXPECT_GROUP"
}

mode="${1:-}"
target="${2:-}"
[[ -n "$mode" && -n "$target" ]] || fail "usage: $0 profile <file.provisionprofile> | app <Maugham.app>"
require_env
case "$mode" in
    profile) check_profile "$target" "MAC_PROVISIONING_PROFILE" ;;
    app) check_app "$target" ;;
    *) fail "unknown mode '$mode' (expected profile or app)" ;;
esac
