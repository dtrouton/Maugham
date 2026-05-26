import Foundation

/// Typed classification of a file URL relative to a project root. Replaces
/// the string-prefix cascade that `DocumentStore.presenterDidChangeSubitem`
/// used to dispatch external file-change events. Adding a new sidecar
/// owner becomes adding an enum case — the compiler then lists every
/// dispatch site that needs to handle it.
///
/// The canonical `.maugham/` subdir layout (see `Maugham/Stores/AREA.md`)
/// is encoded here as explicit cases. Subdirs that exist but don't yet
/// have presenter routing (`sessions`, `ui-state`, `conflicts`, `scratch`,
/// `trash`) parse to their own cases so a future owner-wiring is a
/// one-case edit rather than a free-string regex change.
internal enum MaughamSidecarPath: Equatable {

    /// Top-level manifest.
    case manifest

    /// `.maugham/ops/<docId>.jsonl` — the per-doc op log. Excludes the
    /// `.pending.jsonl` companion used by `PendingBuffer` (which is a
    /// crash-recovery artifact, not a routing target).
    case opLog(docId: String)

    /// `.maugham/checkpoints.jsonl` — project-scope checkpoint log.
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

    /// `.maugham/publications.jsonl` — append-only publication log.
    case publicationsLog

    /// `.maugham/publications/<id>.json` — per-publication snapshot blob.
    case publicationSnapshot(relativePath: String)

    /// A path under `.maugham/` that doesn't match any known subdir.
    /// Includes `.pending.jsonl` companions for `PendingBuffer`. Routing
    /// intent: ignore.
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

        if relativePath == "project.maugham.json" {
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
            && relativePath.hasSuffix(".jsonl")
            && !relativePath.hasSuffix(".pending.jsonl") {
            let filename = (relativePath as NSString).lastPathComponent
            let docId = (filename as NSString).deletingPathExtension
            return .opLog(docId: docId)
        }

        if relativePath == ".maugham/checkpoints.jsonl" {
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

        if relativePath == ".maugham/publications.jsonl" {
            return .publicationsLog
        }

        if relativePath.hasPrefix(".maugham/publications/") {
            return .publicationSnapshot(relativePath: relativePath)
        }

        return .unknownSidecar(relativePath: relativePath)
    }
}
