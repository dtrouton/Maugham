#!/usr/bin/env bash
# Pre-flight checks for cutting a stable Maugham release.
#
# Usage:
#   ./scripts/cut-release.sh 0.X.Y                    # full pre-flight + tag
#   ./scripts/cut-release.sh 0.X.Y --skip-tests       # skip the test run
#   ./scripts/cut-release.sh 0.X.Y --skip-pin-check   # skip the action-pin check (offline cuts)
#   ./scripts/cut-release.sh 0.X.Y --skip-ci-check    # skip the green-CI check (offline cuts; release.yml still asks)
#
# Creates the tag locally on success and prints the push command.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/verify-action-pins.sh
source "$SCRIPT_DIR/lib/verify-action-pins.sh"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <version> [--skip-tests] [--skip-pin-check] [--skip-ci-check]"
    exit 1
fi

VERSION=""
SKIP_TESTS=0
SKIP_PIN_CHECK=0
SKIP_CI_CHECK=0
for arg in "$@"; do
    case "$arg" in
        --skip-tests)     SKIP_TESTS=1 ;;
        --skip-pin-check) SKIP_PIN_CHECK=1 ;;
        --skip-ci-check)  SKIP_CI_CHECK=1 ;;
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

NOTES="docs/release-notes/v${VERSION}.md"

# 1. Release notes must exist.
if [[ ! -f "$NOTES" ]]; then
    echo "ERROR: release notes missing at $NOTES"
    echo "       (cp docs/release-notes/_template.md $NOTES, then edit it)"
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
if git rev-parse "v${VERSION}" >/dev/null 2>&1; then
    echo "ERROR: tag v${VERSION} already exists"
    exit 1
fi

# 5. GitHub Action pins resolve to the tags in their `# vX` comments.
#    The fabricated-SHA guard (PR #1 history): a pinned SHA is only trustworthy
#    if it is the commit its comment claims. Aborts the cut on any mismatch or
#    unpinned action. Needs network + gh auth; --skip-pin-check bypasses it for
#    offline cuts.
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

# 6. CI is green for this exact commit. release.yml runs no tests of its own:
#    it refuses a stable tag whose commit has no SUCCESSFUL `CI` run, so a tag
#    cut before CI finishes (or on a commit whose run a newer push cancelled)
#    fails there after the push. Asking here fails it before the tag exists.
#    A dry-run tag (patch >= 90) only warns, as release.yml does.
if [[ "$SKIP_CI_CHECK" -eq 0 ]]; then
    SHA="$(git rev-parse HEAD)"
    REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
    GREEN="$(gh api "repos/${REPO}/actions/workflows/ci.yml/runs?head_sha=${SHA}&status=success&per_page=1" --jq '.total_count')"
    if [[ "$GREEN" -ge 1 ]]; then
        echo "CI is green for ${SHA}."
    elif [[ "${VERSION##*.}" -ge 90 ]]; then
        echo "WARNING: no successful CI run for ${SHA} (dry-run tag, continuing)."
    else
        echo "ERROR: no successful CI run for ${SHA}."
        echo "       Push this commit to main and wait for CI to finish green on it."
        echo "       (--skip-ci-check bypasses this here; release.yml will still refuse.)"
        exit 1
    fi
else
    echo "Skipping the green-CI check (--skip-ci-check)."
fi

# 7. Tests pass.
if [[ "$SKIP_TESTS" -eq 0 ]]; then
    echo "Running tests…"
    ./gen.sh
    xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO \
        2>&1 | tail -20
    echo "Tests passed."
fi

# 8. Create tag (annotated).
git tag -a "v${VERSION}" -m "Maugham ${VERSION}"

cat <<EOF

Tag v${VERSION} created locally. To trigger the release workflow:

    git push origin v${VERSION}

EOF
