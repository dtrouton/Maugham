#!/usr/bin/env bash
# Shared preflight: verify every SHA-pinned GitHub Action in the workflow files
# actually resolves to the git tag named in its trailing `# vX.Y.Z` comment.
#
# WHY THIS EXISTS (the fabricated-SHA guard, PR #1 history): pinning an action by
# commit SHA is the supply-chain-safe idiom, but a SHA is opaque. The reassuring
# `# v7.0.0` comment beside it is just a comment — nothing enforces that the SHA
# is the commit that tag points at. A careless copy-paste (or a malicious PR) can
# pin a SHA that has nothing to do with the tag in the comment, and code review
# can't catch it by eye. This preflight dereferences each tag via the GitHub API
# and asserts the pinned SHA matches, so a mismatch aborts the release cut.
#
# It ALSO fails the cut if a remote action is referenced by a mutable ref (a tag
# or branch instead of a 40-hex SHA) — an unpinned action is the very risk this
# guards against.
#
# Sourced by scripts/cut-release.sh and scripts/cut-phone-release.sh, and driven
# directly by scripts/tests/verify-action-pins.test.sh. All GitHub API access
# goes through "$GH_BIN" (default: gh) so the test can inject a stub.

GH_BIN="${GH_BIN:-gh}"

# Resolve a tag ref to the COMMIT sha it ultimately points at, following the
# annotated-tag indirection (a tag ref may point to a tag OBJECT, which in turn
# points to the commit). Action pins are always commit SHAs, so we compare
# against the final commit.
#   $1 = owner/repo   $2 = tag (e.g. v7.0.0)
# Echoes the resolved commit sha; returns non-zero on any gh failure.
resolve_tag_commit() {
    local repo="$1" tag="$2"
    local line obj_type obj_sha
    # One call returns "<type> <sha>": type is "commit" for a lightweight tag or
    # "tag" for an annotated tag (whose object.sha is the tag object, not a commit).
    line="$("$GH_BIN" api "repos/${repo}/git/ref/tags/${tag}" \
              --jq '.object.type + " " + .object.sha' 2>/dev/null)" || return 1
    obj_type="${line%% *}"
    obj_sha="${line#* }"
    if [[ "$obj_type" == "tag" ]]; then
        obj_sha="$("$GH_BIN" api "repos/${repo}/git/tags/${obj_sha}" \
                     --jq '.object.sha' 2>/dev/null)" || return 1
    fi
    [[ -n "$obj_sha" ]] || return 1
    printf '%s' "$obj_sha"
}

# Verify one pin.
#   $1 = owner/repo   $2 = pinned sha   $3 = tag
# Returns 0 on match, 1 on mismatch, 2 on resolve error. Diagnostics on stderr.
verify_action_pin() {
    local repo="$1" pinned="$2" tag="$3" resolved
    if ! resolved="$(resolve_tag_commit "$repo" "$tag")"; then
        printf '  ✗ %-40s could not resolve tag %s via gh\n' "$repo" "$tag" >&2
        return 2
    fi
    if [[ "$resolved" == "$pinned" ]]; then
        printf '  ✓ %-40s %s → %s\n' "$repo" "$tag" "$pinned"
        return 0
    fi
    printf '  ✗ %-40s pinned @%s but %s → %s\n' "$repo" "$pinned" "$tag" "$resolved" >&2
    return 1
}

# Scan workflow files and verify every remote-action pin.
#   $@ = files to scan (default: .github/workflows/*.yml)
# Returns 0 iff every pin matched and no unpinned/untagged remote action was
# found; otherwise 1. Deduplicates identical pins seen across files.
scan_and_verify_pins() {
    local files=( "$@" )
    if [[ ${#files[@]} -eq 0 ]]; then
        files=( .github/workflows/*.yml )
    fi

    local rc=0 seen=""
    local line path ref repo sha tag key

    # Every `uses:` referencing a remote action. Local (`./…`) and docker
    # (`docker://…`) refs are not SHA-pinnable and are skipped below.
    while IFS= read -r line; do
        # uses: <path>@<ref>  (optionally followed by  # <tag>)
        if [[ "$line" =~ uses:[[:space:]]*([^@[:space:]\"\']+)@([^[:space:]\"\']+)([[:space:]]*#[[:space:]]*([^[:space:]]+))? ]]; then
            path="${BASH_REMATCH[1]}"
            ref="${BASH_REMATCH[2]}"
            tag="${BASH_REMATCH[4]}"
        else
            continue
        fi

        # Skip local composite actions and docker refs — nothing to pin.
        [[ "$path" == ./* || "$path" == docker://* ]] && continue

        # owner/repo is the first two path segments (handles owner/repo/sub@sha).
        IFS='/' read -r _owner _repo _ <<< "$path"
        repo="${_owner}/${_repo}"

        if [[ ! "$ref" =~ ^[0-9a-f]{40}$ ]]; then
            printf '  ✗ %-40s ref %q is not a 40-hex commit SHA (unpinned action)\n' \
                "$repo" "$ref" >&2
            rc=1
            continue
        fi
        sha="$ref"

        if [[ -z "$tag" ]]; then
            printf '  ✗ %-40s @%s has no "# vTag" comment to verify against\n' \
                "$repo" "$sha" >&2
            rc=1
            continue
        fi

        key="${repo}@${sha}#${tag}"
        case " $seen " in
            *" $key "*) continue ;;  # already verified this exact pin
        esac
        seen="$seen $key"

        verify_action_pin "$repo" "$sha" "$tag" || rc=1
    done < <(grep -hE 'uses:[[:space:]]*[^[:space:]]+@' "${files[@]}" 2>/dev/null || true)

    return "$rc"
}
