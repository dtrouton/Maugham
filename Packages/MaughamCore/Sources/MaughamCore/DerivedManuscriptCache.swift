import Foundation

/// Per-project in-memory cache fronting `DerivedManuscript` for CLOSED
/// documents (the ADR 0018 read path). Generalises the Tasks pane's
/// op-log-mtime cache (`ProjectStore+Tasks.swift`) to the derived manuscript
/// state so the hot closed-doc readers — cross-document search, project-open
/// word counts, the wiki-rename pre-check, and the link/reference tools — pay
/// the JSONL-decode cost once per (doc, op-log-file-set) rather than once per
/// call.
///
/// The cached value is the derived STATE (`paragraphs` + `sequence`); each
/// adopter materialises or strips from it on demand, so a single derive serves
/// both the anchored form (compile / wiki tokens) and the display form
/// (search / scene parsing). Materialize + stripAnchors are cheap relative to
/// the log decode, so they are NOT cached.
///
/// Validity token: the sorted `(path, mtime, size)` of the doc's op-log file
/// set (`OpLogStore.opLogFileURLs`). Any append, seal, or cross-device sync
/// changes a file's size and/or mtime, so the token invalidates exactly the
/// docs whose files changed — per-doc, not project-wide.
///
/// Open docs never route through here: their live `Document` is fresher than
/// the op log (which lags an actively-edited doc by the burst window). Adopters
/// take the live `Document` when the doc is open and only fall through to this
/// cache for closed docs.
///
/// Not thread-safe by design: instantiate one per project and touch it only
/// from the main actor (every adopter is `@MainActor`). Kept Foundation-only
/// so it lives in MaughamCore alongside the primitives it composes.
public final class DerivedManuscriptCache {

    /// Op-log file-set fingerprint. Two tokens compare equal iff the doc's
    /// op-log files, their sizes, and their mtimes all match.
    public struct Token: Equatable {
        struct Entry: Equatable {
            let path: String
            let mtime: TimeInterval
            let size: Int
        }
        let entries: [Entry]
    }

    private struct Line {
        let token: Token
        let state: Deriver.DerivedState
    }

    private var lines: [String: Line] = [:]

    /// Number of times a derive actually ran (a cache miss). Test-visible so
    /// perf guards assert cache hits by counting derives instead of timing
    /// wall-clock (which would flake in CI).
    public private(set) var deriveCount: Int = 0

    public init() {}

    /// Derived `paragraphs` + `sequence` for a CLOSED doc — cached when the
    /// op-log file set is unchanged since the last derive, else derived fresh
    /// (via `DerivedManuscript.derivedState`) and stored.
    public func state(forDocId docId: String, in projectURL: URL) -> Deriver.DerivedState {
        let token = Self.token(forDocId: docId, in: projectURL)
        if let line = lines[docId], line.token == token {
            return line.state
        }
        let state = DerivedManuscript.derivedState(forDocId: docId, in: projectURL)
        deriveCount &+= 1
        lines[docId] = Line(token: token, state: state)
        return state
    }

    /// Anchored (materialised) text for a CLOSED doc — the `<!-- ¶id -->`
    /// form the compile + wiki-token readers want. See `DerivedManuscript.materialize`.
    public func materialize(forDocId docId: String, in projectURL: URL) -> String {
        let s = state(forDocId: docId, in: projectURL)
        return Materializer.materialize(paragraphs: s.paragraphs, sequence: s.sequence)
    }

    /// Display (anchor-stripped) form for a CLOSED doc — what search and the
    /// Fountain scene parser want, matching an open doc's `displayText`.
    public func displayText(forDocId docId: String, in projectURL: URL) -> String {
        MarkdownDisplayFilter.stripAnchors(materialize(forDocId: docId, in: projectURL))
    }

    /// Drop a single doc's cached line. The mtime/size token already
    /// self-invalidates on disk changes; this is for callers that mutate a
    /// closed doc's log and want a guaranteed re-derive without racing mtime
    /// resolution.
    public func invalidate(docId: String) {
        lines[docId] = nil
    }

    /// Drop the entire cache.
    public func invalidateAll() {
        lines.removeAll()
    }

    static func token(forDocId docId: String, in projectURL: URL) -> Token {
        let fm = FileManager.default
        let entries = OpLogStore.opLogFileURLs(forDocId: docId, in: projectURL)
            .map { url -> Token.Entry in
                let attrs = try? fm.attributesOfItem(atPath: url.path)
                let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                let size = (attrs?[.size] as? Int) ?? 0
                return Token.Entry(path: url.path, mtime: mtime, size: size)
            }
            .sorted { $0.path < $1.path }
        return Token(entries: entries)
    }
}
