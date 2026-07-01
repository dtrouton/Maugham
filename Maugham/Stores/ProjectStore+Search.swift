import Foundation
import MaughamCore

// MARK: - Cross-document search

extension ProjectStore {

    /// Run a cross-document search. Cancels any in-flight search; debounces 300ms.
    /// Flushes pending research-note writes first so the research pass reads
    /// fresh bytes from disk. Manuscript freshness needs no flush: the engine
    /// reads an open doc's live `Document` state and a closed doc's op log
    /// directly (ADR 0018), never the `.md`. Results land on currentSearch
    /// (Observable).
    public func performSearch(
        query: String, options: SearchOptions
    ) async {
        searchTask?.cancel()

        let task = Task { [weak self] in
            // Debounce
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            guard let self else { return }

            // Pre-search flush so research notes on disk reflect pending edits
            // (manuscripts read live/op-log, not disk — see doc comment).
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
    // `lineNumber` are DISPLAY-form coordinates — `ProjectSearchEngine` strips
    // the `<!-- ¶id -->` / `<!--t-XXXXXX-->` anchors via MarkdownDisplayFilter
    // before matching, so a match never lands inside an invisible anchor. BUT
    // those coordinates are a SNAPSHOT taken at search time: by the time a
    // replace runs, the live `doc.displayText` may have diverged (autosave
    // landed an external edit, or an earlier replace in this same loop already
    // shifted offsets). So we don't trust the snapshotted range — we RE-FIND
    // occurrences in the CURRENT `doc.displayText` (respecting the recorded
    // `SearchOptions`) and target by ORDINAL. The ordinal is stable across any
    // content change that doesn't add or remove query occurrences, which is the
    // common case for a replace pass; if occurrences did change, the
    // stale-match guard (re-find count < requested index) throws so the caller
    // re-runs the search.

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
            // in the current search results (left-to-right by display-form
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

        // Apply the edit, then close a transiently-loaded doc on EVERY exit
        // path (normal completion AND throw), exactly once, AWAITED. close()
        // flushes the pending burst + autosave, so the `.md` reflects the edit
        // before the instance is torn down — the caller (which re-runs the
        // search right after) depends on that persistence being durable, so a
        // fire-and-forget close won't do. An open doc is left to its live
        // schedulers (its editor binding already reflects the new displayText).
        //
        // We capture any thrown error and close after the do/catch (rather than
        // using `defer`, whose body can't `await`): that keeps the close a
        // single AWAITED site reached on both success and failure. A duplicated
        // fire-and-forget that the throw path skipped or doubled could leave two
        // transient Documents racing the same autosave scheduler on a rapid
        // re-search+replace of the same doc.
        var thrown: Error?
        do {
            try applyReplacement(
                to: doc, query: query, options: options,
                replacement: replacement, occurrenceIndices: occurrenceIndices)
        } catch {
            thrown = error
        }
        // Single close site — runs on success AND failure, awaited exactly once.
        if isTransient { await doc.close() }
        if let thrown { throw thrown }
    }

    /// Pure-in-memory replacement step: re-find occurrences in the doc's CURRENT
    /// display form, replace the requested ordinals (or all), and commit via
    /// `setFullText`. Throws the stale-match guard. Persistence/teardown is the
    /// caller's responsibility (see `replaceInManuscript`).
    private func applyReplacement(
        to doc: Document,
        query: String,
        options: SearchOptions,
        replacement: String,
        occurrenceIndices: [Int]?
    ) throws {
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
