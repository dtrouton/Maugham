import Foundation

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

    /// Replace a single search match with the given replacement text.
    /// Loads the file, splices the replacement into the match's char range,
    /// saves via atomic write.
    public func replaceMatch(
        _ match: SearchMatch, with replacement: String
    ) async throws {
        let url = self.url.appendingPathComponent(match.documentPath)
        let original = try String(contentsOf: url, encoding: .utf8)
        let ns = original as NSString
        guard match.charRangeInDocument.location + match.charRangeInDocument.length
                <= ns.length else {
            // Stale match (file changed since search). Caller should re-run search.
            throw ProjectStoreError.fileSystemError("Match range out of bounds")
        }
        let updated = ns.replacingCharacters(
            in: match.charRangeInDocument, with: replacement) as String
        try updated.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Replace all matches in the given results with `replacement`.
    /// Groups by document; applies replacements right-to-left within each
    /// document so earlier offsets aren't shifted by later edits.
    public func replaceAll(
        in results: SearchResults, with replacement: String
    ) async throws {
        let grouped = Dictionary(grouping: results.matches, by: \.documentPath)
        for (path, matches) in grouped {
            let url = self.url.appendingPathComponent(path)
            let original = try String(contentsOf: url, encoding: .utf8)
            var ns = original as NSString
            // Right-to-left order
            let ordered = matches.sorted {
                $0.charRangeInDocument.location > $1.charRangeInDocument.location
            }
            for match in ordered {
                // Guard against out-of-bounds in case content changed
                guard match.charRangeInDocument.location + match.charRangeInDocument.length
                        <= ns.length else { continue }
                ns = ns.replacingCharacters(
                    in: match.charRangeInDocument, with: replacement) as NSString
            }
            try (ns as String).write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
