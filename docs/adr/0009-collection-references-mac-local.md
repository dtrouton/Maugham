# 0009 — Collection project references are Mac-local; iCloud cross-Mac resolution is best-effort

**Status:** Accepted
**Date:** 2026-05-16

## Context

The [Mixed-Content Collection milestone](../superpowers/specs/2026-05-16-mixed-content-collection-design.md) introduces project references — a Collection can point at another Maugham project elsewhere on disk via a `pieces/<NN>-<slug>/.maugham-link.json` file. Each link stores three things that identify the target:

```json
{
  "title": "The Long One",
  "path": "/Users/denver/Documents/The Long One",
  "bookmark": "<base64 security-scoped bookmark data>",
  "linkedAt": "..."
}
```

The `bookmark` is `NSURL.bookmarkData(options: .withSecurityScope, ...)`. This survives the target project being moved on the same Mac, works under macOS sandbox restrictions, and is the right primitive for "I picked this folder once and want to access it later."

But security-scoped bookmarks are **Mac-local**. A Collection containing references that gets synced via iCloud to another Mac (or just restored from a backup) lands with bookmarks that don't resolve on the second machine. The bookmark encodes information about the *issuing* Mac's filesystem state — bookmark IDs, sandbox containers, the user's home — none of which are portable.

The alternative would be relative paths via iCloud-relative URLs (e.g., `~/Library/Mobile Documents/com~apple~CloudDocs/...`). That's doable but adds complexity: we'd need to detect iCloud-relative paths, normalize them across Macs, and gracefully handle when the target moves outside iCloud.

## Decision

Accept the Mac-local limitation. Use `path` as a best-effort cross-Mac fallback. When both bookmark and path fail, mark the reference unresolved and offer the user a Re-link affordance.

Resolution order on click:
1. Resolve the security-scoped bookmark. If it succeeds, open the target URL.
2. If the bookmark fails, try `URL(fileURLWithPath: linkedProjectPath)`. If a project exists there, silently refresh the bookmark from the resolved URL and open the target.
3. If both fail, mark the reference unresolved. The Inspector shows ⚠ Unresolved with a Re-link… button (NSOpenPanel) and a Remove button. The reference folder stays on disk until the user decides.

## Consequences

- **Same-Mac, target moved**: bookmark survives; resolves transparently.
- **Same-Mac, target deleted**: bookmark fails, path fails → unresolved → user re-links or removes.
- **Cross-Mac via iCloud, target at same iCloud-relative absolute path**: bookmark fails, path succeeds → silent re-bookmark on this Mac, transparent to the user.
- **Cross-Mac via iCloud, target at a different absolute path** (different user home, or different storage layout): bookmark fails, path fails → unresolved → user re-links.
- **The writer's iCloud-on-one-Mac primary workflow is fine.** The "I copied my project folder to a colleague's Mac" workflow needs re-linking.
- **No code is wasted if we later want true cross-Mac portability**: the natural next step is to detect iCloud-relative paths at link time and store them as a third field alongside `path`, falling through bookmark → iCloud-relative → absolute path. The existing structure accommodates this without manifest changes.

## What we explicitly didn't do

- **Did not build iCloud-relative path normalization** for this milestone. The complexity (detecting cross-Mac iCloud roots, handling targets that leave iCloud, handling targets that move within iCloud) is more than the immediate value justifies. The re-link affordance is a simple manual cure for the edge case.
- **Did not warn users at link-time** that the reference won't be cross-Mac portable. The Re-link UI is reactive; surfacing it as a proactive caveat in the link sheet would be noise for the primary single-Mac workflow.

## References

- [Mixed-Content Collection design spec](../superpowers/specs/2026-05-16-mixed-content-collection-design.md) — § Project references / § Cross-Mac caveat
- [ADR 0003](0003-mcp-live-only-unix-socket.md) — separately, MCP also doesn't see closed referenced projects, by design
- Apple docs: [Locating Files Using Bookmarks](https://developer.apple.com/documentation/foundation/nsurl#1663785) — primary source for security-scoped bookmark semantics
