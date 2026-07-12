#!/usr/bin/env bash
# Unit test for scripts/lib/verify-action-pins.sh.
#
# Runs fully offline: GitHub API access is stubbed by pointing GH_BIN at a fake
# `gh` that returns canned responses for a fixed fixture set. Exercises the
# lightweight-tag path, the annotated-tag indirection path, a SHA↔tag mismatch,
# a gh/resolve failure, and the whole-file scanner (good pin, mismatched pin,
# and an unpinned `@vX` ref).
#
# Usage: bash scripts/tests/verify-action-pins.test.sh   (exit 0 = all passed)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

# 40-hex fixture SHAs.
COMMIT_A="$(printf 'a%.0s' {1..40})"   # lightweight tag v1.0.0 -> this commit
TAG_OBJ="$(printf 'b%.0s' {1..40})"    # annotated tag v2.0.0 -> this tag object
COMMIT_B="$(printf 'c%.0s' {1..40})"   # ...which -> this commit
WRONG="$(printf 'd%.0s' {1..40})"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- Stub gh -----------------------------------------------------------------
# The lib calls:
#   gh api repos/<r>/git/ref/tags/<tag> --jq '.object.type + " " + .object.sha'
#   gh api repos/<r>/git/tags/<objsha>  --jq '.object.sha'
# The stub keys on the api path and emits the already-jq'd string the lib expects.
cat > "$WORK/gh" <<STUB
#!/usr/bin/env bash
[[ "\$1" == "api" ]] || { echo "unexpected: gh \$*" >&2; exit 99; }
case "\$2" in
  repos/good/repo/git/ref/tags/v1.0.0) echo "commit $COMMIT_A" ;;
  repos/good/repo/git/ref/tags/v2.0.0) echo "tag $TAG_OBJ" ;;
  repos/good/repo/git/tags/$TAG_OBJ)   echo "$COMMIT_B" ;;
  *) exit 1 ;;   # unknown ref / network failure
esac
STUB
chmod +x "$WORK/gh"
export GH_BIN="$WORK/gh"

# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/lib/verify-action-pins.sh"

PASS=0
FAIL=0
check() { # $1=label $2=expected $3=actual
    if [[ "$2" == "$3" ]]; then
        PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"
    else
        FAIL=$((FAIL + 1)); printf 'FAIL %s (expected %q, got %q)\n' "$1" "$2" "$3"
    fi
}

# resolve_tag_commit: lightweight tag.
got="$(resolve_tag_commit good/repo v1.0.0)"; rc=$?
check "resolve lightweight -> commit" "$COMMIT_A" "$got"
check "resolve lightweight rc"        "0"         "$rc"

# resolve_tag_commit: annotated tag indirection.
got="$(resolve_tag_commit good/repo v2.0.0)"
check "resolve annotated  -> commit" "$COMMIT_B" "$got"

# resolve_tag_commit: gh failure.
resolve_tag_commit good/repo v9.9.9 >/dev/null 2>&1; rc=$?
check "resolve failure rc nonzero" "1" "$rc"

# verify_action_pin: match / mismatch / annotated-match / resolve error.
verify_action_pin good/repo "$COMMIT_A" v1.0.0 >/dev/null 2>&1
check "verify match rc"          "0" "$?"
verify_action_pin good/repo "$WRONG" v1.0.0 >/dev/null 2>&1
check "verify mismatch rc"       "1" "$?"
verify_action_pin good/repo "$COMMIT_B" v2.0.0 >/dev/null 2>&1
check "verify annotated match"   "0" "$?"
verify_action_pin good/repo "$COMMIT_A" v9.9.9 >/dev/null 2>&1
check "verify resolve-error rc"  "2" "$?"

# scan_and_verify_pins: a clean workflow file.
cat > "$WORK/good.yml" <<YAML
jobs:
  x:
    steps:
      - uses: good/repo@$COMMIT_A # v1.0.0
      - uses: good/repo@$COMMIT_B # v2.0.0
      - uses: ./local-action
YAML
scan_and_verify_pins "$WORK/good.yml" >/dev/null 2>&1
check "scan clean file rc" "0" "$?"

# scan_and_verify_pins: mismatched pin fails.
cat > "$WORK/bad.yml" <<YAML
jobs:
  x:
    steps:
      - uses: good/repo@$WRONG # v1.0.0
YAML
scan_and_verify_pins "$WORK/bad.yml" >/dev/null 2>&1
check "scan mismatch rc" "1" "$?"

# scan_and_verify_pins: unpinned (@vX) ref fails.
cat > "$WORK/unpinned.yml" <<YAML
jobs:
  x:
    steps:
      - uses: good/repo@v1.0.0
YAML
scan_and_verify_pins "$WORK/unpinned.yml" >/dev/null 2>&1
check "scan unpinned rc" "1" "$?"

echo "-----"
echo "passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
