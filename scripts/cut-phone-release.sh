#!/usr/bin/env bash
# Pre-flight checks for cutting a MaughamPhone (iOS) TestFlight release.
#
# Usage:
#   ./scripts/cut-phone-release.sh 0.X.Y                    # full pre-flight + tag
#   ./scripts/cut-phone-release.sh 0.X.Y --skip-tests       # skip the test run
#   ./scripts/cut-phone-release.sh 0.X.Y --skip-pin-check   # skip action-pin check (offline)
#
# Creates the tag locally on success and prints the push command.
#
# Mirror of scripts/cut-release.sh (the Mac pipeline). The phone uses a separate
# tag namespace (phone-v*) so the two release workflows never collide. Version is
# tag-derived: project.yml keeps the "0.0.0-dev" / "1" placeholders and CI rewrites
# both at build time (CFBundleShortVersionString from the tag, CFBundleVersion from
# `git rev-list --count HEAD`). Do NOT bump them in project.yml.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/verify-action-pins.sh
source "$SCRIPT_DIR/lib/verify-action-pins.sh"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <version> [--skip-tests] [--skip-pin-check]"
    exit 1
fi

VERSION=""
SKIP_TESTS=0
SKIP_PIN_CHECK=0
for arg in "$@"; do
    case "$arg" in
        --skip-tests)     SKIP_TESTS=1 ;;
        --skip-pin-check) SKIP_PIN_CHECK=1 ;;
        -*) echo "ERROR: unknown flag: $arg"; exit 1 ;;
        *)
            if [[ -z "$VERSION" ]]; then
                VERSION="$arg"
            else
                echo "ERROR: unexpected argument: $arg"; exit 1
            fi ;;
    esac
done

# Validate version shape.
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: version must be X.Y.Z (got: ${VERSION:-<none>})"
    exit 1
fi

NOTES="docs/release-notes/phone/v${VERSION}.md"

# 1. Release notes must exist.
if [[ ! -f "$NOTES" ]]; then
    echo "ERROR: release notes missing at $NOTES"
    echo "       (cp docs/release-notes/phone/_template.md $NOTES, then edit it)"
    exit 1
fi

# 2. Must be on main.
BRANCH=$(git symbolic-ref --short HEAD)
if [[ "$BRANCH" != "main" ]]; then
    echo "ERROR: not on main (current branch: $BRANCH)"
    exit 1
fi

# 3. Working tree clean.
if [[ -n "$(git status --porcelain)" ]]; then
    echo "ERROR: working tree dirty"
    git status --short
    exit 1
fi

# 4. Tag must not already exist.
if git rev-parse "phone-v${VERSION}" >/dev/null 2>&1; then
    echo "ERROR: tag phone-v${VERSION} already exists"
    exit 1
fi

# 5. GitHub Action pins resolve to the tags in their `# vX` comments (shared with
#    the Mac cut; the check scans all of .github/workflows/*.yml). See
#    scripts/lib/verify-action-pins.sh. --skip-pin-check bypasses for offline cuts.
if [[ "$SKIP_PIN_CHECK" -eq 0 ]]; then
    echo "Verifying GitHub Action pins (SHA ↔ tag)…"
    # No args on purpose: the lib defaults to scanning .github/workflows/*.yml.
    # shellcheck disable=SC2119
    if ! scan_and_verify_pins; then
        echo "ERROR: action pin verification failed (see above)."
        echo "       Fix the pin in .github/workflows/, or pass --skip-pin-check"
        echo "       for an offline cut (only if you trust the pins already)."
        exit 1
    fi
    echo "Action pins verified."
else
    echo "Skipping action-pin verification (--skip-pin-check)."
fi

# 6. Tests pass (phone test target on the simulator; signing disabled).
if [[ "$SKIP_TESTS" -eq 0 ]]; then
    echo "Running phone tests…"
    ./gen.sh
    xcodebuild -project Maugham.xcodeproj -scheme MaughamPhone \
        -destination 'platform=iOS Simulator,name=iPhone 17' \
        test CODE_SIGNING_ALLOWED=NO \
        2>&1 | tail -20
    echo "Tests passed."
fi

# 7. Create tag (annotated).
git tag -a "phone-v${VERSION}" -m "MaughamPhone ${VERSION}"

cat <<EOF

Tag phone-v${VERSION} created locally. To trigger the release workflow:

    git push origin phone-v${VERSION}

EOF
