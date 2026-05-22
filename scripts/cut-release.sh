#!/usr/bin/env bash
# Pre-flight checks for cutting a stable Maugham release.
#
# Usage:
#   ./scripts/cut-release.sh 0.X.Y                 # full pre-flight + tag
#   ./scripts/cut-release.sh 0.X.Y --skip-tests    # skip the test run
#
# Creates the tag locally on success and prints the push command.
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <version> [--skip-tests]"
    exit 1
fi

VERSION="$1"
SKIP_TESTS="${2:-}"

# Validate version shape.
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: version must be X.Y.Z (got: $VERSION)"
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

# 5. Tests pass.
if [[ "$SKIP_TESTS" != "--skip-tests" ]]; then
    echo "Running tests…"
    ./gen.sh
    xcodebuild -project Maugham.xcodeproj -scheme Maugham test CODE_SIGNING_ALLOWED=NO \
        2>&1 | tail -20
    echo "Tests passed."
fi

# 6. Create tag (annotated).
git tag -a "v${VERSION}" -m "Maugham ${VERSION}"

cat <<EOF

Tag v${VERSION} created locally. To trigger the release workflow:

    git push origin v${VERSION}

EOF
