#!/usr/bin/env bash
# Exercises scripts/verify-mac-signing.sh in both directions: an app that
# embeds a granting Developer ID profile and is signed with the group passes,
# and each way of losing that fails loudly.
#
# Fixtures are real: a throwaway .app ad-hoc signed with entitlements, and the
# Developer ID profile Xcode keeps for the person-key probe
# (com.dtrouton.personkeyprobe.mac, which grants FF3XH4ZJ45.*). Without that
# profile on this Mac the positive cases cannot be built, so the test SKIPS
# (exit 0 with a message) rather than pretending. Run from anywhere:
#   scripts/tests/verify-mac-signing.test.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../verify-mac-signing.sh"
PROFILES="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"

TEAM=FF3XH4ZJ45
PROBE_ID=com.dtrouton.personkeyprobe.mac
GROUP=FF3XH4ZJ45.com.maugham.person

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Find an installed profile by its Name.
find_profile() {
    local want="$1" f
    for f in "$PROFILES"/*.provisionprofile; do
        [[ -f "$f" ]] || continue
        security cms -D -i "$f" > "$WORK/find.plist" 2>/dev/null || continue
        if [[ "$(/usr/libexec/PlistBuddy -c 'Print :Name' "$WORK/find.plist" 2>/dev/null)" == "$want" ]]; then
            echo "$f"; return 0
        fi
    done
    return 1
}

DIRECT="$(find_profile "Mac Team Direct Provisioning Profile: $PROBE_ID")" || {
    echo "SKIP: the probe's Developer ID profile is not installed on this Mac"
    exit 0
}
DEVPROFILE="$(find_profile "Mac Team Provisioning Profile: *" || true)"

# make_app <name> <profile-or-empty> <entitlements-plist-or-empty>
make_app() {
    local app="$WORK/$1.app" profile="$2" ents="$3"
    mkdir -p "$app/Contents/MacOS"
    cp /usr/bin/true "$app/Contents/MacOS/Fixture"
    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$PROBE_ID</string>
<key>CFBundleExecutable</key><string>Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
    [[ -n "$profile" ]] && cp "$profile" "$app/Contents/embedded.provisionprofile"
    if [[ -n "$ents" ]]; then
        codesign --force --sign - --entitlements "$ents" "$app" 2>/dev/null
    else
        codesign --force --sign - "$app" 2>/dev/null
    fi
    echo "$app"
}

# write_ents <file> <app-id-or-empty> <group-or-empty>
write_ents() {
    local f="$1" appid="$2" group="$3"
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
        echo '<plist version="1.0"><dict>'
        [[ -n "$appid" ]] && echo "<key>com.apple.application-identifier</key><string>$appid</string>"
        echo "<key>com.apple.developer.team-identifier</key><string>$TEAM</string>"
        [[ -n "$group" ]] && echo "<key>keychain-access-groups</key><array><string>$group</string></array>"
        echo '</dict></plist>'
    } > "$f"
}

PASS=0; FAILN=0
# expect <pass|fail> <description> <expected-substring-on-fail> -- <env+args…>
expect() {
    local want="$1" desc="$2" needle="$3"; shift 4
    local out rc
    out="$(env "$@" "$SCRIPT" "${ARGS[@]}" 2>&1)"; rc=$?
    if [[ "$want" == pass && $rc -eq 0 ]] ||
       [[ "$want" == fail && $rc -ne 0 && "$out" == *"$needle"* ]]; then
        echo "PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "FAIL: $desc (rc=$rc)"; echo "$out" | sed 's/^/    /'; FAILN=$((FAILN + 1))
    fi
}

ENV_OK=("EXPECT_TEAM=$TEAM" "EXPECT_BUNDLE_ID=$PROBE_ID" "EXPECT_GROUP=$GROUP")

write_ents "$WORK/good.plist" "$TEAM.$PROBE_ID" "$GROUP"
write_ents "$WORK/nogroup.plist" "$TEAM.$PROBE_ID" ""
write_ents "$WORK/noappid.plist" "" "$GROUP"

GOOD="$(make_app good "$DIRECT" "$WORK/good.plist")"
NOPROFILE="$(make_app noprofile "" "$WORK/good.plist")"
NOGROUP="$(make_app nogroup "$DIRECT" "$WORK/nogroup.plist")"
NOAPPID="$(make_app noappid "$DIRECT" "$WORK/noappid.plist")"
NOENTS="$(make_app noents "$DIRECT" "")"

# --- profile mode
ARGS=(profile "$DIRECT")
expect pass "profile: the probe's Developer ID profile grants the group" "" -- "${ENV_OK[@]}"
expect fail "profile: another team is refused" "belongs to team" -- EXPECT_TEAM=ABCDE12345 EXPECT_BUNDLE_ID=$PROBE_ID EXPECT_GROUP=ABCDE12345.com.maugham.person
expect fail "profile: another bundle id is refused" "application identifier" -- EXPECT_TEAM=$TEAM EXPECT_BUNDLE_ID=com.maugham.Maugham EXPECT_GROUP=$GROUP
expect fail "profile: a group outside the team is refused" "not in team" -- EXPECT_TEAM=$TEAM EXPECT_BUNDLE_ID=$PROBE_ID EXPECT_GROUP=ABCDE12345.com.maugham.person
: > "$WORK/empty.provisionprofile"
ARGS=(profile "$WORK/empty.provisionprofile")
expect fail "profile: an empty secret is refused" "missing or empty" -- "${ENV_OK[@]}"
echo "not a profile" > "$WORK/junk.provisionprofile"
ARGS=(profile "$WORK/junk.provisionprofile")
expect fail "profile: bytes that are not a profile are refused" "not a provisioning profile" -- "${ENV_OK[@]}"
if [[ -n "$DEVPROFILE" ]]; then
    ARGS=(profile "$DEVPROFILE")
    expect fail "profile: a development profile is refused" "not a Developer ID profile" -- "${ENV_OK[@]}"
fi

# --- app mode
ARGS=(app "$GOOD")
expect pass "app: embedded profile + group + app id passes" "" -- "${ENV_OK[@]}"
ARGS=(app "$NOPROFILE")
expect fail "app: no embedded profile fails (codesign --verify alone would pass)" "embedded.provisionprofile is missing" -- "${ENV_OK[@]}"
ARGS=(app "$NOGROUP")
expect fail "app: a signature without the group fails" "does not name keychain-access-groups" -- "${ENV_OK[@]}"
ARGS=(app "$NOAPPID")
expect fail "app: a signature without the application identifier fails" "application identifier ''" -- "${ENV_OK[@]}"
ARGS=(app "$NOENTS")
expect fail "app: a signature with no entitlements fails" "NO entitlements" -- "${ENV_OK[@]}"
# A profile slipped in AFTER signing breaks the seal.
cp -R "$NOPROFILE" "$WORK/late.app"
cp "$DIRECT" "$WORK/late.app/Contents/embedded.provisionprofile"
ARGS=(app "$WORK/late.app")
expect fail "app: a profile added after signing breaks the seal" "codesign --verify failed" -- "${ENV_OK[@]}"

# The control that makes the passes mean something: codesign's own gate is
# satisfied by the app with no profile.
if codesign --verify --deep --strict "$NOPROFILE" 2>/dev/null; then
    echo "PASS: control — codesign --verify alone accepts the profile-less app"; PASS=$((PASS + 1))
else
    echo "FAIL: control — expected codesign --verify to accept the profile-less app"; FAILN=$((FAILN + 1))
fi

echo "---"
echo "$PASS passed, $FAILN failed"
[[ $FAILN -eq 0 ]]
