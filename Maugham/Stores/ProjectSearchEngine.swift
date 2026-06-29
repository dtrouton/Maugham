import Foundation
import MaughamCore

/// Walks all manuscript + research-note documents and returns matches for
/// a query. Pure value type — no observable state, callers own caching.
@MainActor
public struct ProjectSearchEngine {
    public init() {}

    /// Run a search against the given project store. Reads files from disk
    /// (callers should flush pending writes first via DocumentStore).
    /// Yields between documents so cancellation can interrupt.
    public func search(
        query: String,
        options: SearchOptions,
        in store: ProjectStore
    ) async -> SearchResults {
        guard !query.isEmpty else {
            return SearchResults(query: query, options: options, matches: [])
        }

        var allMatches: [SearchMatch] = []

        // Manuscript pass
        let manuscriptDocs = Self.flattenManuscriptDocs(store.manifest.structure)
        for (item, fullPath) in manuscriptDocs {
            await Task.yield()
            if Task.isCancelled { break }
            // ADR 0018: manuscript content is derived from the op log, never
            // read from the `.md` on disk (which is a derived, potentially
            // stale artifact). DerivedManuscript.materialize returns the
            // anchored form (<!-- ¶id --> lines) — identical to what autosave
            // writes — so the strip below produces the same display form the
            // editor and iOS reader see. Returns "" when the doc has no ops
            // (new doc before first keystroke); matchesIn on "" yields nothing.
            let stored = DerivedManuscript.materialize(forDocId: item.id, in: store.url)
            // Search the DISPLAY form, not the raw anchored bytes. The
            // materialised `.md` carries op-log join anchors (`<!-- ¶id -->`
            // lines + inline `<!--t-XXXXXX-->` task anchors) whose 4/6-char
            // ids overlap the ordinary-text alphabet — so searching raw bytes
            // can surface matches *inside* an invisible anchor (e.g. "ab"
            // inside `<!-- ¶ab12 -->`). That match has no display-form
            // counterpart, which (a) shows the user a hit they can't see and
            // (b) makes click-to-jump + Find-Replace ordinals wrong against
            // the editor (which is display form). Strip via the shared
            // MarkdownDisplayFilter — the single source of truth the editor's
            // RenderFilter.stripComments and the iOS reader both use — so
            // every coordinate this engine emits (charRangeInDocument /
            // lineNumber / matchRangeInLine) is in display form.
            let content = MarkdownDisplayFilter.stripAnchors(stored)
            let matches = Self.matchesIn(
                content: content,
                query: query,
                options: options,
                documentPath: fullPath,
                documentTitle: item.title,
                documentSource: .manuscript)
            allMatches.append(contentsOf: matches)
        }

        // Research pass
        let researchDocs = Self.flattenResearchDocs(store.manifest.research)
        for (item, fullPath) in researchDocs {
            await Task.yield()
            if Task.isCancelled { break }
            let url = store.url.appendingPathComponent(fullPath)
            guard let stored = try? String(contentsOf: url, encoding: .utf8) else { continue } // adr-0018-ok: research-note read, not manuscript
            // Research notes carry no ¶ anchors, so stripAnchors is a no-op on
            // their content (it only removes own-line `<!-- ¶id -->` and inline
            // task anchors). Route through it anyway for uniformity, so both
            // passes emit display-form coordinates by the same code path.
            let content = MarkdownDisplayFilter.stripAnchors(stored)
            let matches = Self.matchesIn(
                content: content,
                query: query,
                options: options,
                documentPath: fullPath,
                documentTitle: item.title,
                documentSource: .research)
            allMatches.append(contentsOf: matches)
        }

        return SearchResults(query: query, options: options, matches: allMatches)
    }

    /// Recursively flatten structure tree, returning (item, path) pairs for
    /// .document-type items only. Group items are walked but not emitted.
    private static func flattenManuscriptDocs(
        _ items: [StructureItem]
    ) -> [(item: StructureItem, path: String)] {
        var out: [(item: StructureItem, path: String)] = []
        for item in items {
            switch item.type {
            case .document:
                if let path = item.path {
                    out.append((item, path))
                }
            case .group:
                if let children = item.children {
                    out.append(contentsOf: flattenManuscriptDocs(children))
                }
            }
        }
        return out
    }

    /// Flatten research tree, returning (item, path) pairs for .document-kind
    /// items whose path ends with .md.
    private static func flattenResearchDocs(
        _ items: [ResearchItem]
    ) -> [(item: ResearchItem, path: String)] {
        var out: [(item: ResearchItem, path: String)] = []
        for item in items {
            if item.type == .asset,
               item.kind == .document,
               let path = item.path,
               path.hasSuffix(".md") {
                out.append((item, path))
            }
            if let children = item.children {
                out.append(contentsOf: flattenResearchDocs(children))
            }
        }
        return out
    }

    /// Find all matches of `query` in `content` according to `options`.
    /// Returns matches in document order.
    private static func matchesIn(
        content: String,
        query: String,
        options: SearchOptions,
        documentPath: String,
        documentTitle: String,
        documentSource: SearchDocumentSource
    ) -> [SearchMatch] {
        var matches: [SearchMatch] = []
        let lines = content.components(separatedBy: "\n")

        var lineStartOffset = 0
        for (i, line) in lines.enumerated() {
            let lineNumber = i + 1
            let nsLine = line as NSString

            let lineRanges = findRanges(in: nsLine, query: query, options: options)
            for r in lineRanges {
                let docRange = NSRange(
                    location: lineStartOffset + r.location,
                    length: r.length)
                let preview = Self.truncatePreview(line: line, around: r)
                matches.append(SearchMatch(
                    documentPath: documentPath,
                    documentTitle: documentTitle,
                    documentSource: documentSource,
                    lineNumber: lineNumber,
                    charRangeInDocument: docRange,
                    linePreview: preview.text,
                    matchRangeInLine: preview.range))
            }

            lineStartOffset += nsLine.length + 1  // +1 for the newline
        }
        return matches
    }

    /// Find all match ranges in a single line.
    private static func findRanges(
        in line: NSString,
        query: String,
        options: SearchOptions
    ) -> [NSRange] {
        var ranges: [NSRange] = []

        if options.wholeWord {
            let escaped = NSRegularExpression.escapedPattern(for: query)
            let pattern = "\\b\(escaped)\\b"
            let regexOptions: NSRegularExpression.Options =
                options.caseSensitive ? [] : [.caseInsensitive]
            guard let regex = try? NSRegularExpression(
                pattern: pattern, options: regexOptions) else { return [] }
            let fullRange = NSRange(location: 0, length: line.length)
            regex.enumerateMatches(in: line as String, options: [], range: fullRange) { match, _, _ in
                if let r = match?.range { ranges.append(r) }
            }
        } else {
            let searchOptions: NSString.CompareOptions =
                options.caseSensitive ? [] : [.caseInsensitive]
            var startLocation = 0
            while startLocation < line.length {
                let remaining = NSRange(
                    location: startLocation,
                    length: line.length - startLocation)
                let r = line.range(
                    of: query, options: searchOptions, range: remaining)
                if r.location == NSNotFound { break }
                ranges.append(r)
                startLocation = r.location + max(r.length, 1)
            }
        }

        return ranges
    }

    /// Truncate long lines to ~120 chars centered on the match, with ellipsis
    /// markers. Re-computes the match range against the truncated string.
    private static func truncatePreview(
        line: String, around range: NSRange
    ) -> (text: String, range: NSRange) {
        let maxLength = 120
        let nsLine = line as NSString
        if nsLine.length <= maxLength {
            return (line, range)
        }

        let halfWindow = (maxLength - range.length) / 2
        let leftStart = max(0, range.location - halfWindow)
        let rightEnd = min(nsLine.length, range.location + range.length + halfWindow)
        let prefix = leftStart > 0 ? "…" : ""
        let suffix = rightEnd < nsLine.length ? "…" : ""

        let segment = nsLine.substring(with: NSRange(
            location: leftStart, length: rightEnd - leftStart))
        let truncated = "\(prefix)\(segment)\(suffix)"
        let newMatchStart = (prefix as NSString).length + (range.location - leftStart)
        let newRange = NSRange(location: newMatchStart, length: range.length)
        return (truncated, newRange)
    }
}
