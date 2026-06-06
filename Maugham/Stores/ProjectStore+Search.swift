import Foundation
import MaughamCore

// MARK: - Cross-document search

extension ProjectStore {

    /// Run a cross-document search. Cancels any in-flight search; debounces 300ms.
    /// Flushes pending writes for the active document first so the search reads
    /// the freshest content from disk. Results land on currentSearch (Observable).
    public func performSearch(
        query: String, options: SearchOptions
    ) async {
        searchTask?.cancel()

        let task = Task { [weak self] in
            // Debounce
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            guard let self else { return }

            // Pre-search flush so disk reflects active-doc edits
            try? await self.documentStore?.flushPendingSave()
            if Task.isCancelled { return }

            self.searchInProgress = true

            let engine = ProjectSearchEngine()
            let results = await engine.search(query: query, options: options, in: self)

            if Task.isCancelled { return }

            self.currentSearch = results
            self.searchInProgress = false
        }
        searchTask = task
    }

    public func clearSearch() {
        searchTask?.cancel()
        searchTask = nil
        currentSearch = nil
        searchInProgress = false
    }

    // MARK: - Replace

    // The op log is the source of truth for manuscripts; the `.md` on disk is
    // derived. So a manuscript replacement must produce ops, not raw bytes.
    // We route manuscript replacements through the same `Document.setFullText`
    // path normal typing uses (open doc → live instance; closed doc →
    // `Document.load` → setFullText → persist via `close()`). Research notes
    // are NOT op-log-backed (plain files persisted via DocumentStore), so they
    // keep the raw atomic write.
    //
    // Coordinate-space subtlety: `SearchMatch.charRangeInDocument` /
    // `lineNumber` are in STORED form (the `.md` WITH `<!-- ¶id -->` anchors,
    // which is what `ProjectSearchEngine` reads). `setFullText` consumes the
    // DISPLAY form (anchors stripped). We must NOT splice a stored-form range
    // into display text. Instead we RE-FIND occurrences in `doc.displayText`
    // (respecting the recorded `SearchOptions`) and operate on those — the
    // ordinal position of an occurrence within a document is preserved between
    // stored and display form (anchors aren't query text), so the Nth match in
    // stored form is the Nth match in display form.

    /// Replace a single search match with the given replacement text.
    ///
    /// Manuscript matches route through the op log: the target occurrence is
    /// identified by its ordinal within the document (from `currentSearch`),
    /// re-found in display form, and replaced via `setFullText`. Research
    /// matches splice into the stored bytes and write atomically.
    public func replaceMatch(
        _ match: SearchMatch, with replacement: String
    ) async throws {
        switch match.documentSource {
        case .manuscript:
            // Determine the ordinal of this match among same-document matches
            // in the current search results (left-to-right by stored-form
            // location). This identifies WHICH display-form occurrence to hit.
            let options = currentSearch?.options ?? SearchOptions()
            let query = currentSearch?.query ?? ""
            let sameDoc = (currentSearch?.matches ?? [])
                .filter { $0.documentPath == match.documentPath }
                .sorted { $0.charRangeInDocument.location
                    < $1.charRangeInDocument.location }
            let ordinal = sameDoc.firstIndex(where: { $0.id == match.id })
                ?? sameDoc.filter {
                    $0.charRangeInDocument.location
                        < match.charRangeInDocument.location
                }.count
            // Recover the query from the search; if it's empty (no live
            // search), fall back to nothing we can do safely → out of bounds.
            guard !query.isEmpty else {
                throw ProjectStoreError.fileSystemError(
                    "No active search query for replaceMatch")
            }
            try await replaceInManuscript(
                path: match.documentPath, query: query, options: options,
                replacement: replacement, occurrenceIndices: [ordinal])

        case .research:
            let url = self.url.appendingPathComponent(match.documentPath)
            let original = try String(contentsOf: url, encoding: .utf8)
            let ns = original as NSString
            guard match.charRangeInDocument.location
                    + match.charRangeInDocument.length <= ns.length else {
                // Stale match (file changed since search). Caller re-runs search.
                throw ProjectStoreError.fileSystemError("Match range out of bounds")
            }
            let updated = ns.replacingCharacters(
                in: match.charRangeInDocument, with: replacement) as String
            try updated.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Replace all matches in the given results with `replacement`.
    ///
    /// Groups by document. Manuscript documents re-find every occurrence of the
    /// query in display form and replace them via the op log. Research notes
    /// splice their stored-form ranges right-to-left and write atomically.
    public func replaceAll(
        in results: SearchResults, with replacement: String
    ) async throws {
        let grouped = Dictionary(grouping: results.matches, by: \.documentPath)
        for (path, matches) in grouped {
            guard let source = matches.first?.documentSource else { continue }
            switch source {
            case .manuscript:
                // Replace ALL occurrences (occurrenceIndices: nil).
                try await replaceInManuscript(
                    path: path, query: results.query, options: results.options,
                    replacement: replacement, occurrenceIndices: nil)

            case .research:
                let url = self.url.appendingPathComponent(path)
                let original = try String(contentsOf: url, encoding: .utf8)
                var ns = original as NSString
                // Right-to-left so earlier offsets aren't shifted by later edits.
                let ordered = matches.sorted {
                    $0.charRangeInDocument.location
                        > $1.charRangeInDocument.location
                }
                for match in ordered {
                    guard match.charRangeInDocument.location
                            + match.charRangeInDocument.length <= ns.length
                    else { continue }
                    ns = ns.replacingCharacters(
                        in: match.charRangeInDocument,
                        with: replacement) as NSString
                }
                try (ns as String).write(
                    to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Apply a query→replacement edit to a manuscript document through the op
    /// log. Obtains the live `Document` from the registry if open, else
    /// transient-loads it; re-finds occurrences in `displayText` (display
    /// coordinates, respecting `options`); replaces either the given ordinal
    /// occurrences (`occurrenceIndices`) or all of them (nil); commits via
    /// `setFullText`; persists + closes a transiently-loaded doc.
    private func replaceInManuscript(
        path: String,
        query: String,
        options: SearchOptions,
        replacement: String,
        occurrenceIndices: [Int]?
    ) async throws {
        // Obtain the Document — open one from the registry, else transient-load.
        let docURL = self.url.appendingPathComponent(path)
        let openDoc = documentStore?.document(for: path)
        let doc: Document
        let isTransient: Bool
        if let openDoc {
            doc = openDoc
            isTransient = false
        } else {
            doc = try await Document.load(
                url: docURL,
                device: "find-replace",
                session: "find-replace-\(UUID().uuidString.prefix(8))",
                presenter: documentStore?.presenter)
            isTransient = true
        }

        // Re-find occurrences in DISPLAY form (anchors stripped) so the ranges
        // are valid coordinates for `setFullText`.
        let display = doc.displayText
        let ranges = Self.matchRanges(
            in: display, query: query, options: options)

        // Stale-match guard: if the live display form has fewer occurrences
        // than the search expected to address, the file changed since the
        // search. For a single-ordinal replace that targets a missing index,
        // surface so the caller re-runs the search.
        if let indices = occurrenceIndices {
            for idx in indices where idx >= ranges.count {
                if isTransient { Task { await doc.close() } }
                throw ProjectStoreError.fileSystemError(
                    "Match range out of bounds")
            }
        }

        // Determine which occurrences to replace.
        let targetIndices: [Int]
        if let indices = occurrenceIndices {
            targetIndices = indices
        } else {
            targetIndices = Array(ranges.indices)
        }

        // Apply right-to-left so earlier offsets aren't shifted by later edits.
        var ns = display as NSString
        for idx in targetIndices.sorted(by: >) {
            guard idx < ranges.count else { continue }
            let r = ranges[idx]
            guard r.location + r.length <= ns.length else { continue }
            ns = ns.replacingCharacters(in: r, with: replacement) as NSString
        }
        let newText = ns as String

        // Commit through the same path normal typing uses.
        doc.setFullText(newText)

        // For a transiently-loaded doc, force persistence (burst → autosave),
        // then close it. close() flushes both. An open doc is left to its
        // live burst/autosave schedulers (and its editor binding already
        // reflects the new displayText).
        if isTransient {
            await doc.close()
        }
    }

    /// Find all occurrence ranges of `query` in `text` according to `options`.
    /// Operates on the whole string (display form); used to map a search hit
    /// into display coordinates for op-log-routed replacement. Mirrors the
    /// per-line matching logic in `ProjectSearchEngine.findRanges` but spans
    /// the full document (a query never matches across a newline here either —
    /// neither whole-word regex nor literal contains crosses `\n` for the
    /// single-line queries Find supports).
    static func matchRanges(
        in text: String, query: String, options: SearchOptions
    ) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let ns = text as NSString
        var ranges: [NSRange] = []

        if options.wholeWord {
            let escaped = NSRegularExpression.escapedPattern(for: query)
            let pattern = "\\b\(escaped)\\b"
            let regexOptions: NSRegularExpression.Options =
                options.caseSensitive ? [] : [.caseInsensitive]
            guard let regex = try? NSRegularExpression(
                pattern: pattern, options: regexOptions) else { return [] }
            let full = NSRange(location: 0, length: ns.length)
            regex.enumerateMatches(in: text, options: [], range: full) { m, _, _ in
                if let r = m?.range { ranges.append(r) }
            }
        } else {
            let compareOptions: NSString.CompareOptions =
                options.caseSensitive ? [] : [.caseInsensitive]
            var start = 0
            while start < ns.length {
                let remaining = NSRange(
                    location: start, length: ns.length - start)
                let r = ns.range(
                    of: query, options: compareOptions, range: remaining)
                if r.location == NSNotFound { break }
                ranges.append(r)
                start = r.location + max(r.length, 1)
            }
        }
        return ranges
    }
}
