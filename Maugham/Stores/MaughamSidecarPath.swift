import Foundation
import MaughamCore

/// Typed classification of a file URL relative to a project root. Replaces
/// the string-prefix cascade that `DocumentStore.presenterDidChangeSubitem`
/// used to dispatch external file-change events. Adding a new sidecar
/// owner becomes adding an enum case — the compiler then lists every
/// dispatch site that needs to handle it.
///
/// The canonical `.maugham/` subdir layout (see `Maugham/Stores/AREA.md`)
/// is encoded here as explicit cases. Subdirs that exist but don't yet
/// have presenter routing (`sessions`, `ui-state`, `conflicts`, `scratch`,
/// `pending`, `trash`) parse to their own cases so a future owner-wiring is a
/// one-case edit rather than a free-string regex change.
internal enum MaughamSidecarPath: Equatable {

    /// Top-level manifest.
    case manifest

    /// `.maugham/ops/<docId>.jsonl` — the per-doc op log. `PendingBuffer`'s
    /// crash-recovery companion lives under `.maugham/pending/` (see `.pending`),
    /// not here, so it can't be matched by the op-log glob.
    case opLog(docId: String)

    /// `.maugham/checkpoints.jsonl` (legacy) or `.maugham/checkpoints.<slug>.jsonl`
    /// — the project-scope checkpoint log, partitioned per device (FM-1).
    case checkpoints

    /// `.maugham/sessions/*` — owned by `SessionLog`. No presenter routing
    /// today; reified so future owners can add a dispatch case without
    /// re-touching the parser.
    case sessionLog(relativePath: String)

    /// `.maugham/ui-state.json` (file, not a subdir) or any nested ui-state
    /// artifact. No presenter routing today.
    case uiState(relativePath: String)

    /// `.maugham/conflicts/*` — written by Document on conflict, not
    /// observed back from disk.
    case conflictBackup(relativePath: String)

    /// `.maugham/scratch/*` — transient writes that are safe to ignore.
    case scratch(relativePath: String)

    /// `.maugham/pending/<docId>.<slug>.pending.jsonl` — `PendingBuffer`'s
    /// device-partitioned crash-recovery buffer. Derived/ephemeral (real edits
    /// already hit the op log at each burst boundary); relocated out of
    /// `.maugham/ops/` so it can't match the op-log glob. Routing intent:
    /// ignore (a device reads only its OWN pending file, on its own reopen —
    /// never reactively from a presenter callback).
    case pending(relativePath: String)

    /// `.maugham/trash/*` — owned by `TrashStore`. No presenter routing today.
    case trash(relativePath: String)

    /// `.maugham/publish/template.tex` + all `.tex` partials. The Claude-authored
    /// LaTeX template artifact.
    case publishTemplate(relativePath: String)

    /// `.maugham/publish/styles.css` + any css partials. The EPUB stylesheet.
    case publishStyles(relativePath: String)

    /// `.maugham/publish/config.json`. Structured, schema-validated, MCP-mutable.
    case publishConfig

    /// `.maugham/publish/cover.{jpg,png}`, `fonts/*`, or any other non-tex/non-css
    /// non-config file under the publish dir. Binary or unknown content.
    case publishAsset(relativePath: String)

    /// `.maugham/publish/build/*` — transient body emission + tectonic aux files.
    /// Routing intent: ignore (write-only by the compile pipeline).
    case publishBuild(relativePath: String)

    /// `.maugham/publications.jsonl` (legacy) or `.maugham/publications.<slug>.jsonl`
    /// — the append-only publication log, partitioned per device (FM-1).
    case publicationsLog

    /// `.maugham/publications/<id>.json` — per-publication snapshot blob.
    case publicationSnapshot(relativePath: String)

    /// `.maugham/inbox/*` — the capture inbox synced from MaughamPhone.
    /// `kind` distinguishes the manifest stream (`inbox.<slug>.jsonl`) from the
    /// kind-scoped asset subdirs (`text/`, `images/`, `audio/`). Routing intent:
    /// trigger `InboxStore` refresh and audio transcription worker via direct calls
    /// in `DocumentStore` (ADR 0021). See ADR 0013-adjacent inbox design (spec §3.2–3.3).
    case inbox(kind: InboxFileKind, relativePath: String)

    /// A path under `.maugham/` that doesn't match any known subdir.
    /// Routing intent: ignore.
    case unknownSidecar(relativePath: String)

    /// A path under the project but outside both the manifest and the
    /// `.maugham/` tree, and not registered as a manuscript. E.g., a
    /// research note the user added directly with Finder. Routing intent:
    /// ignore (research notes are loaded on demand, not via presenter).
    case otherProjectFile(relativePath: String)

    /// The URL doesn't live under `projectURL` at all. Routing intent:
    /// no-op.
    case outsideProject

    /// Classify `url` against `projectURL`. Both URLs are standardized
    /// before comparison so that `/tmp/foo` and `/private/tmp/foo` match
    /// on macOS (where `/tmp` is a symlink).
    static func classify(url: URL, projectURL: URL) -> MaughamSidecarPath {
        let project = projectURL.standardizedFileURL.path
        let changed = url.standardizedFileURL.path
        guard changed.hasPrefix(project + "/") else {
            return .outsideProject
        }
        let relativePath = String(changed.dropFirst(project.count + 1))

        if relativePath == ProjectManifest.fileName {
            return .manifest
        }

        if relativePath.hasPrefix(".maugham/") {
            return classifySidecar(relativePath: relativePath)
        }

        return .otherProjectFile(relativePath: relativePath)
    }

    /// Split a `.maugham/...` relative path into its typed case. Kept private
    /// so the only entry point is `classify(url:projectURL:)`.
    private static func classifySidecar(
        relativePath: String
    ) -> MaughamSidecarPath {
        let opsPrefix = ".maugham/ops/"
        if relativePath.hasPrefix(opsPrefix)
            && !relativePath.hasSuffix(".pending.jsonl")
            && (relativePath.hasSuffix(".jsonl") || relativePath.hasSuffix(".mzseg")) {
            // Per-device partitioning (ADR 0012): a file is either the legacy
            // `<docId>.jsonl`, the per-device `<docId>.<deviceSlug>.jsonl`, or a
            // sealed segment `<docId>.<deviceSlug>.seg<NNNN>.mzseg` (ADR 0016).
            // The docId (a `d_`+ULID, or `__project__`) never contains a dot, so
            // it is the component before the FIRST dot — `deletingPathExtension`
            // would strip only the extension, folding the device slug into the
            // docId and misrouting the op-log change notification. A sealed
            // segment delivers as an op-log change (re-derive); the deriver
            // collapses the now-redundant ops to a no-op (T11).
            let filename = (relativePath as NSString).lastPathComponent
            let docId = filename.prefix { $0 != "." }
            return .opLog(docId: String(docId))
        }

        // Legacy `.maugham/checkpoints.jsonl` or per-device
        // `.maugham/checkpoints.<deviceSlug>.jsonl` (FM-1). The template is
        // `PartitionedJSONLFile`'s; restating it here is the reach-around the
        // op-log filename tripwire exists to prevent.
        if PartitionedJSONLFile.matches(
            relativePath: relativePath, stemPath: CheckpointStore.stemPath) {
            return .checkpoints
        }

        if relativePath.hasPrefix(".maugham/sessions/") {
            return .sessionLog(relativePath: relativePath)
        }

        if relativePath == ".maugham/ui-state.json"
            || relativePath.hasPrefix(".maugham/ui-state/") {
            return .uiState(relativePath: relativePath)
        }

        if relativePath.hasPrefix(".maugham/conflicts/") {
            return .conflictBackup(relativePath: relativePath)
        }

        if relativePath.hasPrefix(".maugham/scratch/") {
            return .scratch(relativePath: relativePath)
        }

        if relativePath.hasPrefix(".maugham/pending/") {
            return .pending(relativePath: relativePath)
        }

        if relativePath.hasPrefix(".maugham/trash/") {
            return .trash(relativePath: relativePath)
        }

        if relativePath.hasPrefix(".maugham/publish/build/") {
            return .publishBuild(relativePath: relativePath)
        }

        if relativePath.hasPrefix(".maugham/publish/") {
            if relativePath == ".maugham/publish/config.json" {
                return .publishConfig
            }
            if relativePath.hasSuffix(".tex") {
                return .publishTemplate(relativePath: relativePath)
            }
            if relativePath.hasSuffix(".css") {
                return .publishStyles(relativePath: relativePath)
            }
            return .publishAsset(relativePath: relativePath)
        }

        // Legacy `.maugham/publications.jsonl` or per-device
        // `.maugham/publications.<deviceSlug>.jsonl` (FM-1). Checked before the
        // `.maugham/publications/` snapshot prefix below; the two cannot
        // collide, since a partitioned name has `.maugham` as its directory.
        if PartitionedJSONLFile.matches(
            relativePath: relativePath, stemPath: PublicationStore.stemPath) {
            return .publicationsLog
        }

        if relativePath.hasPrefix(".maugham/publications/") {
            return .publicationSnapshot(relativePath: relativePath)
        }

        if relativePath.hasPrefix(".maugham/inbox/") {
            let tail = String(relativePath.dropFirst(".maugham/inbox/".count))
            if tail.hasPrefix("text/") {
                return .inbox(kind: .text, relativePath: relativePath)
            }
            if tail.hasPrefix("images/") {
                return .inbox(kind: .image, relativePath: relativePath)
            }
            if tail.hasPrefix("audio/") {
                return .inbox(kind: .audio, relativePath: relativePath)
            }
            // `inbox.jsonl` (legacy) or `inbox.<deviceSlug>.jsonl` (per-device).
            if tail.hasPrefix("inbox.") && tail.hasSuffix(".jsonl") {
                return .inbox(kind: .manifest, relativePath: relativePath)
            }
            return .unknownSidecar(relativePath: relativePath)
        }

        return .unknownSidecar(relativePath: relativePath)
    }
}
