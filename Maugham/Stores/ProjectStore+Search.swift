import Foundation
import MaughamCore

// MARK: - Cross-document search

extension ProjectStore {

    /// Run a cross-document search. Cancels any in-flight search; debounces 300ms.
    /// Flushes pending research-note writes first so the research pass reads
    /// fresh bytes from disk. Manuscript freshness needs no flush: the engine
    /// reads an open doc's live `Document` state and a closed doc's op log
    /// directly (ADR 0018), never the `.md`. Results land on currentSearch
    /// (Observable) — unless a search that started later has landed first
    /// (`land`). The debounce is for typing; a Replace refreshes through
    /// `searchNow`.
    public func performSearch(
        query: String, options: SearchOptions
    ) async {
        searchTask?.cancel()
        latestSearchRequest = (query, options)

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
            self.searchGeneration += 1
            let generation = self.searchGeneration

            let engine = ProjectSearchEngine()
            let results = await engine.search(query: query, options: options, in: self)
            await self.searchWillLandForTesting?(query)

            if Task.isCancelled { return }

            self.land(results, generation: generation)
            self.searchInProgress = false
        }
        searchTask = task
    }

    /// **Search now, with no debounce**, and return once `currentSearch`
    /// holds results no older than this call: its own, or those of a search
    /// that started after it and landed first. A pending debounced search is
    /// left to run (it is newer typing). Flushes pending research-note writes
    /// first, as `performSearch` does.
    public func searchNow(query: String, options: SearchOptions) async {
        try? await documentStore?.flushPendingSave()
        searchGeneration += 1
        let generation = searchGeneration
        let results = await ProjectSearchEngine().search(query: query, options: options, in: self)
        await searchWillLandForTesting?(query)
        land(results, generation: generation)
    }

    /// Results land only when newer than the last that landed: a search that
    /// started before another one landed (or before `clearSearch`) is
    /// dropped, so older results never overwrite newer ones.
    private func land(_ results: SearchResults, generation: Int) {
        guard generation > landedSearchGeneration else { return }
        landedSearchGeneration = generation
        currentSearch = results
        recentlyLandedSearches.append(results)
        if recentlyLandedSearches.count > Self.landedSearchesKept {
            recentlyLandedSearches.removeFirst()
        }
    }

    /// How many landed results `listedMatch(for:)` can trace a click back
    /// to: a click queued behind more refreshes than this is refused.
    static let landedSearchesKept = 8

    public func clearSearch() {
        searchTask?.cancel()
        searchTask = nil
        // Nothing started before the close may land after it.
        landedSearchGeneration = searchGeneration
        latestSearchRequest = nil
        currentSearch = nil
        recentlyLandedSearches = []
        searchInProgress = false
    }

    // MARK: - Replace

    // The op log is the source of truth for manuscripts; the `.md` on disk is
    // derived. So a manuscript replacement must produce ops, not raw bytes.
    // We route manuscript replacements through the same `Document.setFullText`
    // path normal typing uses (open doc → live instance; closed doc →
    // `Document.load` → setFullText → persist via `close()`). Research notes
    // are NOT op-log-backed: they are written whole through the note door
    // (`writeReplacedResearchText`), after one flush per replace.
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
    // `SearchOptions`) and target by ORDINAL — the clicked match's index among
    // its document's matches in `currentSearch` (`ordinal(of:)`). A single
    // Replace refreshes `currentSearch` before it returns (`searchNow`) and
    // single Replaces run one at a time, so the results an ordinal is read
    // from are never older than the last Replace. A match whose id is not in
    // them (it came from results a Replace has since refreshed) means the
    // one current match with its path, range and line (`listedMatch(for:)`,
    // #147 R1) when its document shows the same occurrences now as in the
    // click's results — another document's match is still clickable after a
    // Replace, one in the document the Replace changed is not; with none, or
    // several, it is refused with
    // `ProjectStoreError.staleSearchMatch`, never re-aimed at a guessed
    // occurrence. So is a text that changed since the search under the
    // ordinal (`ClickedOccurrence.range`): a different count of occurrences,
    // or a different line at the ordinal. Every refusal refreshes the results.

    // MARK: - What this Mac may replace (P3c whole-branch fix wave, C1)

    /// **A manuscript replace this Mac may not make** — thrown by
    /// `replaceMatch` and collected by `replaceAll` (controller ruling AI). A
    /// replace writes a typing burst, and a burst's emission is deliberately
    /// not permit-guarded (the editor's membrane is in front of the keystroke),
    /// so the replace verbs ask before they reach `setFullText`: otherwise the
    /// text lands signed in the writer's name and every read sets it aside.
    public struct ManuscriptReplaceRefused: LocalizedError, Equatable {
        public let titles: [String]
        public var errorDescription: String? {
            ProjectStore.leftAloneSentence(titles) ?? "Nothing was replaced."
        }
    }

    /// What `replaceAll` did not do, by title: `leftAlone` — the manuscript
    /// documents this Mac may not write (ruling AI) and Research files
    /// Maugham may not change; `changedSinceRead` — the notes that changed
    /// between Replace All's read of them and the door's write (#147 R2).
    public struct ReplaceAllOutcome: Equatable, Sendable {
        public let leftAlone: [String]
        public let changedSinceRead: [String]

        public init(leftAlone: [String], changedSinceRead: [String] = []) {
            self.leftAlone = leftAlone
            self.changedSinceRead = changedSinceRead
        }

        /// What the writer is told, each list with its own reason; nil — nothing.
        public var notice: String? {
            let sentences = [ProjectStore.leftAloneSentence(leftAlone),
                             ProjectStore.changedSinceReadSentence(changedSinceRead)].compactMap { $0 }
            return sentences.isEmpty ? nil : sentences.joined(separator: " ")
        }
    }

    /// The one sentence naming the pieces a replace left alone.
    nonisolated static func leftAloneSentence(_ titles: [String]) -> String? {
        guard !titles.isEmpty else { return nil }
        return "Left as it was — this Mac may not change the text of "
            + titles.joined(separator: ", ") + "."
    }

    /// The one sentence naming the notes Replace All left because they
    /// changed while it ran (#147 R2).
    nonisolated static func changedSinceReadSentence(_ titles: [String]) -> String? {
        guard !titles.isEmpty else { return nil }
        let quoted = titles.map { "“\($0)”" }
        if quoted.count == 1 {
            return "Left as it was — \(quoted[0]) changed while Replace was running. Search again."
        }
        let named = quoted.count == 2 ? quoted.joined(separator: " and ") : quoted.joined(separator: ", ")
        return "Left as they were — \(named) changed while Replace was running. Search again."
    }

    /// Replace a single search match with the given replacement text.
    ///
    /// Manuscript matches route through the op log: the target occurrence is
    /// identified by its ordinal within the document (`ordinal(of:)`),
    /// re-found in display form, and replaced via `setFullText`. A research
    /// match is re-found by the same ordinal in the text just read
    /// (`replacingResearchMatches`) and written through `writeReplacedResearchText`.
    ///
    /// **Replaces run one at a time** (`takingTheReplaceTurn`, shared with
    /// Replace All), each waiting for the one before it and its refresh, and
    /// **each ends by refreshing `currentSearch`**
    /// (`searchNow`, no debounce): a second click — even on the same match,
    /// even while the first is in flight — is judged against fresh results.
    /// Its id is gone from them, so it means the fresh match with the same
    /// path, range and line (`listedMatch(for:)`) only in a document the
    /// first Replace left unchanged; in the one it changed there is none,
    /// and it throws
    /// `ProjectStoreError.staleSearchMatch` with nothing written.
    public func replaceMatch(
        _ match: SearchMatch, with replacement: String
    ) async throws {
        try await takingTheReplaceTurn {
            try await self.replaceOneMatch(match, with: replacement)
        }
    }

    /// **Every Replace takes its turn** — a single Replace or Replace All
    /// runs once the one issued before it has finished, refresh included,
    /// in the order issued. A Replace that throws still ends its turn, so
    /// the next one runs; its error goes to its own caller.
    private func takingTheReplaceTurn<T: Sendable>(
        _ body: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        let previous = replaceTail
        let mine = Task {
            await previous?.value
            return try await body()
        }
        replaceTail = Task { _ = await mine.result }
        return try await mine.value
    }

    /// **The results, refreshed after a Replace** (`searchNow`, no
    /// debounce): what the field asks for now (typing may have moved on),
    /// else the current results' own query; nothing once the overlay has
    /// closed.
    private func refreshAfterReplace() async {
        if let request = latestSearchRequest {
            await searchNow(query: request.query, options: request.options)
        } else if let current = currentSearch {
            await searchNow(query: current.query, options: current.options)
        }
    }

    /// One single Replace, once every earlier Replace has finished.
    private func replaceOneMatch(
        _ match: SearchMatch, with replacement: String
    ) async throws {
        // What the clicked match was found by — taken before any await.
        let query = currentSearch?.query ?? ""
        let options = currentSearch?.options ?? SearchOptions()
        let url: URL?
        let target: ResearchReplaceTarget?
        switch match.documentSource {
        case .manuscript:
            // With no live search there is nothing we can do safely.
            guard !query.isEmpty else {
                throw ProjectStoreError.fileSystemError(
                    "No active search query for replaceMatch")
            }
            url = nil
            target = nil
        case .research:
            // A path that escapes the project is refused as unsafe first (tripwire 58).
            url = try resolvedProjectPathToChange(match.documentPath)
            target = researchReplaceTarget(at: match.documentPath)
            guard target != nil else {
                throw ProjectStoreError.fileSystemError(
                    "“\(match.documentTitle)” is not a Research note Maugham can change.")
            }
        }
        // Which occurrence to hit, and what the search showed of it — taken
        // before any await.
        guard let clicked = clickedOccurrence(match) else {
            // The results the click came from are gone and nothing in the
            // current ones is its occurrence: show what the text holds now.
            await refreshAfterReplace()
            throw ProjectStoreError.staleSearchMatch
        }
        do {
            if let url, let target {
                // The editor's queued edits land first, so the bytes read below
                // are the newest and the write cannot be undone by a later save.
                try? await documentStore?.flushPendingSave()
                await settleResearchEdits(target)
                let (original, readHash) = try Self.readResearchText(at: url)
                // Re-found in the text just read, by its ordinal in the search —
                // never the search-time offsets, which an edit since may have moved.
                let updated = try Self.replacingResearchMatches(
                    in: original, query: query, options: options,
                    replacement: replacement, clicked: clicked)
                try await writeReplacedResearchText(updated, to: target, path: match.documentPath, url: url,
                                                    readHash: readHash)
            } else {
                try await replaceInManuscript(
                    path: match.documentPath, title: match.documentTitle,
                    query: query, options: options,
                    replacement: replacement, clicked: clicked)
            }
        } catch {
            // A refusal for text changed since the search (or a failed
            // write) still leaves the results showing what the text holds.
            await refreshAfterReplace()
            throw error
        }
        // The results are never older than this Replace.
        await refreshAfterReplace()
    }

    /// **The match in `currentSearch` a click means** (#147 R1): the one
    /// with its id; else — its results have been refreshed since, and match
    /// ids are minted fresh by every search (`SearchMatch.id`, a `UUID()`) —
    /// the one current match with the same path, range and line preview,
    /// **only when its document is unchanged since the click's results**:
    /// the results it came from (`recentlyLandedSearches`) are for the same
    /// query and options and list the very same occurrences in that document
    /// (`shownOccurrences`) as the current ones. A Replace (or any edit) in
    /// the document shows there — the occurrence it changed reads a
    /// different line, and a length change moves every later range — so a
    /// document a Replace changed has no fallback: an identical line at the
    /// old range is another occurrence (fix round 1). Not always: on a line
    /// longer than the ~120-character preview, a replacement that starts
    /// with the query can leave that occurrence's preview unchanged, so the
    /// change does not show there. Untouched, a range
    /// names one occurrence, so this never names another; none, or several,
    /// or results no longer remembered, is nil (a refusal). The
    /// clicked-occurrence check (`ClickedOccurrence.range`) still runs on
    /// whichever it names.
    private func listedMatch(for match: SearchMatch) -> SearchMatch? {
        guard let current = currentSearch else { return nil }
        if let same = current.matches.first(where: { $0.id == match.id }) { return same }
        guard let clickedFrom = recentlyLandedSearches.last(where: { results in
                  results.matches.contains { $0.id == match.id } }),
              clickedFrom.query == current.query, clickedFrom.options == current.options,
              Self.shownOccurrences(in: clickedFrom, at: match.documentPath)
                  == Self.shownOccurrences(in: current, at: match.documentPath)
        else { return nil }
        let candidates = current.matches.filter {
            $0.documentPath == match.documentPath
                && $0.charRangeInDocument == match.charRangeInDocument
                && $0.linePreview == match.linePreview
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// What `results` show of one document's occurrences, left to right,
    /// ids aside: equal for two searches of an unchanged document.
    private static func shownOccurrences(
        in results: SearchResults, at path: String
    ) -> [ShownOccurrence] {
        results.matches
            .filter { $0.documentPath == path }
            .map { ShownOccurrence(range: $0.charRangeInDocument, line: $0.linePreview,
                                   inLine: $0.matchRangeInLine) }
            .sorted { $0.range.location < $1.range.location }
    }

    private struct ShownOccurrence: Equatable {
        let range: NSRange
        let line: String
        let inLine: NSRange
    }

    /// **A clicked match's ordinal** — the index of the match it means
    /// (`listedMatch(for:)`) among its document's matches in
    /// `currentSearch`, left to right — for both arms; nil when it means
    /// none.
    private func ordinal(of match: SearchMatch) -> Int? {
        guard let listed = listedMatch(for: match) else { return nil }
        return (currentSearch?.matches ?? [])
            .filter { $0.documentPath == match.documentPath }
            .sorted { $0.charRangeInDocument.location < $1.charRangeInDocument.location }
            .firstIndex { $0.id == listed.id }
    }

    /// The clicked match as a single Replace will check it, from
    /// `currentSearch`; nil when it means no match there (`ordinal(of:)`).
    private func clickedOccurrence(_ match: SearchMatch) -> ClickedOccurrence? {
        guard let ordinal = ordinal(of: match) else { return nil }
        let count = (currentSearch?.matches ?? []).filter { $0.documentPath == match.documentPath }.count
        return ClickedOccurrence(match: match, ordinal: ordinal, count: count)
    }

    /// **The occurrence a single Replace was clicked on** — its ordinal
    /// among its document's matches in the results it came from, how many
    /// there were, and the match itself (the line the result showed).
    struct ClickedOccurrence {
        let match: SearchMatch
        let ordinal: Int
        let count: Int

        /// **The one rule both arms re-find by** (final fix wave): the
        /// clicked occurrence's range in `text`, the text about to be
        /// changed, or `.staleSearchMatch`. The checks run on `searched` —
        /// that text in the form the search reads it (a manuscript's display
        /// form, which is `text` itself; a note's `stripAnchors(text)`) — by
        /// the search engine's own matcher (`ProjectSearchEngine.matchesIn`):
        /// refused for a different number of occurrences (one added or
        /// removed since), or, at the ordinal, a different line
        /// (`linePreview`) or place in it (`matchRangeInLine`) — one added
        /// and another removed. An edit elsewhere that leaves the occurrences
        /// and the clicked line alone still replaces it.
        ///
        /// Where `searched` differs from `text` (a note's `\r\n` endings, its
        /// edge whitespace, an anchor-shaped line), the same matcher runs on
        /// `text` and the occurrence at the same ordinal is replaced — only
        /// when the count there is the expected one too. Equal counts keep
        /// the ordinals in step: the strip removes anchors, `\r` and the edge
        /// whitespace, none of which holds an ordinary occurrence; an
        /// anchor-shaped line holding the query changes the count, so that
        /// Replace is refused.
        @MainActor func range(
            in text: String, searched: String, query: String, options: SearchOptions
        ) throws -> NSRange {
            let found = occurrences(in: searched, query: query, options: options)
            guard found.count == count else { throw ProjectStoreError.staleSearchMatch }
            let now = found[ordinal]
            guard now.linePreview == match.linePreview,
                  now.matchRangeInLine == match.matchRangeInLine else {
                throw ProjectStoreError.staleSearchMatch
            }
            guard searched != text else { return now.charRangeInDocument }
            let inText = occurrences(in: text, query: query, options: options)
            guard inText.count == count else { throw ProjectStoreError.staleSearchMatch }
            return inText[ordinal].charRangeInDocument
        }

        @MainActor private func occurrences(
            in text: String, query: String, options: SearchOptions
        ) -> [SearchMatch] {
            ProjectSearchEngine.matchesIn(
                content: text, query: query, options: options,
                documentPath: match.documentPath, documentTitle: match.documentTitle,
                documentSource: match.documentSource)
        }
    }

    /// **A research file's text with its matches replaced, re-found in
    /// `stored`** — the text Replace has just read — never at the search's
    /// offsets, which an edit made since (or an earlier Replace) may have
    /// moved (#141 N2). `clicked` names the one occurrence a single Replace
    /// changes (`ClickedOccurrence.range`, which throws `.staleSearchMatch`
    /// when `stored` no longer holds what the search showed, and the caller
    /// writes nothing); nil replaces every match `stored` holds.
    ///
    /// The search read `MarkdownDisplayFilter.stripAnchors(stored)` — which
    /// joins `\r\n` lines with `\n` and trims the note's edge whitespace — so
    /// the checks run on that text, and the occurrence is replaced in
    /// `stored` (`ClickedOccurrence.range(in:searched:…)`).
    private static func replacingResearchMatches(
        in stored: String, query: String, options: SearchOptions,
        replacement: String, clicked: ClickedOccurrence?
    ) throws -> String {
        let ranges = try clicked.map {
            [try $0.range(in: stored, searched: MarkdownDisplayFilter.stripAnchors(stored),
                          query: query, options: options)]
        } ?? matchRanges(in: stored, query: query, options: options)
        // Right-to-left so earlier offsets aren't shifted by later edits.
        var ns = stored as NSString
        for range in ranges.reversed() {
            ns = ns.replacingCharacters(in: range, with: replacement) as NSString
        }
        return ns as String
    }

    /// How Replace may write the Research file at `path`.
    private enum ResearchReplaceTarget {
        /// A note or a palette card the door takes: written through it.
        case note(ResearchItem)
        /// A note or card with no `DocumentStore` (a load-only context), or a
        /// file inside a research root with no manifest item: the raw atomic
        /// write, keeping nothing.
        case raw
    }

    /// **What Replace may write at `path`, nil — nothing** (whole-branch C2):
    /// a manifest item there is written only when `ResearchTextRole` calls it
    /// a note or a palette card; a file no item names, only when the path is
    /// inside a research root (`ResearchTextRole.isInsideAResearchRoot`). A
    /// synced manifest's `.document` naming the manuscript or a `.maugham/`
    /// file is never written.
    private func researchReplaceTarget(at path: String) -> ResearchReplaceTarget? {
        guard let item = TreeWalk.first(in: manifest.research, where: { $0.path == path }) else {
            return ResearchTextRole.isInsideAResearchRoot(path, structure: manifest.structure) ? .raw : nil
        }
        guard ResearchNoteDoor.takes(item, structure: manifest.structure) else { return nil }
        return .note(item)
    }

    /// **A Research file's text as Replace reads it, with the hash of the
    /// bytes read** — the door's expectation for the write
    /// (`writeReplacedResearchText`'s `readHash`, #147 R2).
    private static func readResearchText(at url: URL) throws -> (text: String, bytesHash: String) {
        let bytes = try Data(contentsOf: url)  // adr-0018-ok: research-note read (manuscript replace routes through the op log)
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding, userInfo: [NSURLErrorKey: url])
        }
        return (text, ContentHash.of(bytes))
    }

    /// A research file's text after a replace. **A note goes through the note
    /// door** — what it held is kept as a version, and an editor open on it
    /// reloads — **as compare-and-swap** (#147 R2): the door is handed
    /// `readHash`, the hash of the bytes `text` was made from, and a note
    /// changed since writes nothing and throws `staleSearchMatch` (Replace All
    /// skips that note and names it in `changedSinceRead`). The door writing nothing for any
    /// other reason throws, as any other failure of this write does
    /// (`replaceAll` stops there, as it always has). A file
    /// no item names has no door and keeps the raw atomic write; so does a
    /// note in a store never given a `DocumentStore`. A note in a store that
    /// had one and lost it (teardown) throws rather than write raw (#141 N6).
    private func writeReplacedResearchText(_ text: String, to target: ResearchReplaceTarget,
                                           path: String, url: URL, readHash: String) async throws {
        if case .note(let note) = target {
            if let ds = documentStore {
                switch await ds.saveResearchNote(itemId: note.id, text: text,
                                                 expectingBytesHash: readHash, from: self) {
                case .saved: return
                case .changedSinceTheCallerRead: throw ProjectStoreError.staleSearchMatch
                case .notSaved: throw ProjectStoreError.fileSystemError("“\(note.title)” was not changed.")
                }
            }
            guard rawNoteWriteWithNoDoor() == .allowed else {
                throw ProjectStoreError.noteWriteRefusedAsTheProjectCloses
            }
        }
        try text.write(to: url, atomically: true, encoding: .utf8)  // raw-research-text: no-door fallback
    }

    /// An edit of the note typed since the replace's flush is saved before
    /// its file is read (`settleResearchNoteEdits`). Nothing for a file that
    /// is not a note.
    private func settleResearchEdits(_ target: ResearchReplaceTarget) async {
        guard case .note(let note) = target, let ds = documentStore else { return }
        await ds.settleResearchNoteEdits(itemId: note.id)
    }

    /// Replace all matches in the given results with `replacement`.
    ///
    /// Groups by document. Manuscript documents re-find every occurrence of the
    /// query in display form and replace them via the op log. A research file
    /// has every match re-found in the text just read replaced
    /// (`replacingResearchMatches`) and written through `writeReplacedResearchText`.
    ///
    /// **A manuscript document this Mac may not write is SKIPPED and named**
    /// (controller ruling AI), never replaced and never a part-way failure:
    /// the rest of the book is replaced, and the outcome lists what was left.
    /// A Research note changed between Replace All's read of it and the
    /// door's write is skipped too (#147 R2): nothing is written to it, and
    /// it is named in the outcome's `changedSinceRead`, with its own reason.
    ///
    /// **It takes its turn with the single Replaces** (`takingTheReplaceTurn`)
    /// **and ends by refreshing `currentSearch`** — on a throw too, since a
    /// Replace All that stops part-way may already have changed text — so a
    /// single Replace of a match found before it finds that match gone.
    @discardableResult
    public func replaceAll(
        in results: SearchResults, with replacement: String
    ) async throws -> ReplaceAllOutcome {
        try await takingTheReplaceTurn {
            let outcome: ReplaceAllOutcome
            do {
                outcome = try await self.replaceEveryMatch(in: results, with: replacement)
            } catch {
                await self.refreshAfterReplace()
                throw error
            }
            await self.refreshAfterReplace()
            return outcome
        }
    }

    /// Replace All's work, once every earlier Replace has finished.
    private func replaceEveryMatch(
        in results: SearchResults, with replacement: String
    ) async throws -> ReplaceAllOutcome {
        let grouped = Dictionary(grouping: results.matches, by: \.documentPath)
        var leftAlone: [String] = []
        var changedSinceRead: [String] = []
        // Once for the whole replace: the editor's queued note edits land
        // before any research file below is read.
        if results.matches.contains(where: { $0.documentSource == .research }) {
            try? await documentStore?.flushPendingSave()
        }
        for path in grouped.keys.sorted() {
            guard let matches = grouped[path],
                  let source = matches.first?.documentSource else { continue }
            switch source {
            case .manuscript:
                // Replace ALL occurrences (clicked: nil).
                do {
                    try await replaceInManuscript(
                        path: path, title: matches[0].documentTitle,
                        query: results.query, options: results.options,
                        replacement: replacement, clicked: nil)
                } catch let refused as ManuscriptReplaceRefused {
                    leftAlone.append(contentsOf: refused.titles)
                }

            case .research:
                // A path that escapes the project is refused as unsafe first (tripwire 58).
                let url = try resolvedProjectPathToChange(path)
                // Not Research text Maugham may change: left as it was, and named.
                guard let target = researchReplaceTarget(at: path) else {
                    leftAlone.append(matches[0].documentTitle)
                    continue
                }
                await settleResearchEdits(target)
                let (original, readHash) = try Self.readResearchText(at: url)
                // Every match the text just read holds, not the search-time list.
                let updated = try Self.replacingResearchMatches(
                    in: original, query: results.query, options: results.options,
                    replacement: replacement, clicked: nil)
                // Nothing left to replace (the query is gone since the
                // search): the file is skipped and nothing is written.
                guard updated != original else { continue }
                do {
                    try await writeReplacedResearchText(updated, to: target, path: path, url: url,
                                                        readHash: readHash)
                } catch ProjectStoreError.staleSearchMatch {
                    // Changed since the read just above (#147 R2): nothing
                    // was written; left as it was, and named for that.
                    changedSinceRead.append(matches[0].documentTitle)
                }
            }
        }
        return ReplaceAllOutcome(leftAlone: leftAlone, changedSinceRead: changedSinceRead)
    }

    /// Apply a query→replacement edit to a manuscript document through the op
    /// log. Holds the document through the door-checked route
    /// (`openManuscriptForWriting`); re-finds occurrences in `displayText`
    /// (display coordinates, respecting `options`); replaces either the
    /// clicked occurrence (`clicked`) or all of them (nil); commits
    /// via `setFullText`; persists + closes a transiently-loaded doc.
    private func replaceInManuscript(
        path: String,
        title: String,
        query: String,
        options: SearchOptions,
        replacement: String,
        clicked: ClickedOccurrence?
    ) async throws {
        let held = try await openManuscriptForWriting(
            path: path, title: title, session: "find-replace")

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
                to: held.doc, query: query, options: options,
                replacement: replacement, clicked: clicked)
        } catch {
            thrown = error
        }
        // Single close site — runs on success AND failure, awaited exactly once.
        await held.release()
        if let thrown { throw thrown }
    }

    /// A manuscript document held for writing by `openManuscriptForWriting`:
    /// the window's live `Document`, or one loaded for this write alone.
    struct WritableManuscript {
        let doc: Document
        let isTransient: Bool

        /// Close a document loaded for this write — which flushes its burst
        /// and autosave, so the `.md` holds the edit — exactly once, awaited.
        /// A live document is left to its window's schedulers.
        @MainActor func release() async {
            if isTransient { await doc.close() }
        }
    }

    /// **The door-checked manuscript route** — the one way a verb outside the
    /// editor holds a manuscript to write its text: Replace and Replace All,
    /// and a figure rename's relabel (`relabelFigure`).
    ///
    /// 1. **The door, before any load** (C1, ruling AI): the acting answer —
    ///    never the drawn one (controller ruling I) — so the root's yield is
    ///    honoured here as it is by the hidden per-match button.
    /// 2. The window's live `Document` if it has one open; else a transient
    ///    `Document.load`, signed as the writer (constraint 6): the ops it
    ///    lands are the writer's own edits, made in one sweep.
    /// 3. **And the Document's own stamp** — the answer the load made, and
    ///    the only one where no `DocumentStore` stands behind this store.
    ///
    /// Any refusal throws `ManuscriptReplaceRefused` naming `title`, with
    /// nothing loaded left open. The caller writes through `doc` and then
    /// `release()`s it.
    func openManuscriptForWriting(
        path: String, title: String, session: String
    ) async throws -> WritableManuscript {
        let refused = ManuscriptReplaceRefused(titles: [title])
        if let documentStore,
           !(await documentStore.settledPosture(forPath: path).allows(.writeText)) {
            throw refused
        }
        let docURL = try resolvedProjectPath(path)
        let held: WritableManuscript
        if let openDoc = documentStore?.document(for: path) {
            held = WritableManuscript(doc: openDoc, isTransient: false)
        } else {
            do {
                let doc = try await Document.load(
                    url: docURL,
                    actor: .author,
                    session: "\(session)-\(UUID().uuidString.prefix(8))",
                    presenter: documentStore?.presenter)
                held = WritableManuscript(doc: doc, isTransient: true)
            } catch DocumentLoadError.waitingForPiece {
                // A piece this device may not write whose history has not
                // arrived: left alone and named, not a part-way failure.
                throw refused
            }
        }
        guard held.doc.mayWriteItsText else {
            await held.release()
            throw refused
        }
        return held
    }

    // MARK: - A figure's line in the text, changed (report plan 6b Tasks 5 and 7)

    /// **What a figure rename changes in the text**: its line's label
    /// (`{#tbl:old}` → `{#tbl:new}`), that line's file name when it names the
    /// figure's file (`figures/old.csv` → `figures/new.csv`), and every
    /// cross-reference to the label (`@tbl:old`, `[@tbl:old]`).
    struct FigureLabelChange: Equatable {
        let old: ManuscriptLabel
        let newName: String
        let oldFile: String
        let newFile: String
    }

    /// **What a verb on a figure changes in the text**: a rename relabels it
    /// (ruling P-3); *Send to Research* removes its line, leaving every
    /// cross-reference to it (spec §4.2: they read "This table is in Research
    /// now"); *Move into Figures* points one line, in one piece, at the
    /// figure's file instead of its Research one (report plan 8b Task 1).
    enum FigureTextChange: Equatable {
        case relabel(FigureLabelChange)
        case removeLine(ManuscriptLabel)
        /// The figure line starting on line `lineIndex` (from 0) of `piece`'s
        /// text whose path is written `oldPath`: its path becomes `newPath`,
        /// its caption kept. Its label becomes `label` — set where it had
        /// none, replaced where it had another — or, nil, is kept (report
        /// plan 8b Task 9: the line of a figure moved in takes the record's
        /// name, so Send and Rename find it). Only that piece is held.
        case retargetLine(piece: String, lineIndex: Int, oldPath: String, newPath: String,
                          label: ManuscriptLabel? = nil)

        /// The one piece (structure item id) the change is made in, or nil
        /// for every manuscript whose text holds a site.
        var piece: String? {
            if case .retargetLine(let piece, _, _, _, _) = self { return piece }
            return nil
        }

        /// The verb's refusal naming `titles`: pieces this Mac may not write.
        func notWritable(_ titles: [String]) -> Error {
            switch self {
            case .relabel: return FigureRenameRefused(reason: .piecesNotWritable(titles))
            case .removeLine: return FigureSendRefused(reason: .piecesNotWritable(titles))
            case .retargetLine: return FigureLineRetargetRefused(reason: .pieceNotWritable(titles.first ?? ""))
            }
        }

        /// The verb's refusal naming `titles`: pieces whose text won't read.
        func unreadable(_ titles: [String]) -> Error {
            switch self {
            case .relabel: return FigureRenameRefused(reason: .unreadable(titles))
            case .removeLine: return FigureSendRefused(reason: .unreadable(titles))
            case .retargetLine: return FigureLineRetargetRefused(reason: .unreadable(titles.first ?? ""))
            }
        }

        /// The refusal when the one piece a change targets no longer holds
        /// its site (the line moved or changed); nil for a change made
        /// wherever its sites are.
        var siteMissing: Error? {
            if case .retargetLine = self { return FigureLineRetargetRefused(reason: .lineNotFound) }
            return nil
        }
    }

    /// **The manuscripts a figure verb changes, each held for writing**
    /// through `openManuscriptForWriting` — phase one of all or nothing.
    /// `write()` changes every one or none; `release()` lets them go.
    struct HeldFigureTextEdit {
        let change: FigureTextChange
        let manuscripts: [(title: String, manuscript: WritableManuscript)]

        /// What a written manuscript said before, so `unwrite` can put it back.
        typealias Written = [(doc: Document, before: String)]

        /// **Change every held manuscript, or none**, re-finding the sites in
        /// each one's CURRENT text. `setFullText` writes nothing where the
        /// document stopped being writable since it was held (a yield or a
        /// permit that landed meanwhile): then every manuscript already written
        /// is put back and the verb's refusal (`FigureTextChange.notWritable`)
        /// names the ones that refused. Synchronous: nothing can land between
        /// the documents.
        @MainActor func write() throws -> Written {
            var written: Written = []
            var refused: [String] = []
            var missing = false
            for (title, held) in manuscripts {
                // Closed or no longer writable since it was held: refused
                // before its text is read (a closed document's text is gone).
                guard !held.doc.isClosed, held.doc.mayWriteItsText else {
                    refused.append(title)
                    continue
                }
                let before = held.doc.displayText
                guard let text = ProjectStore.edited(before, change) else {
                    // A targeted change whose line is gone writes nothing.
                    if change.siteMissing != nil { missing = true }
                    continue
                }
                held.doc.setFullText(text)
                if held.doc.displayText != before {
                    written.append((held.doc, before))
                } else {
                    refused.append(title)
                }
            }
            guard refused.isEmpty else {
                Self.unwrite(written)
                throw change.notWritable(refused)
            }
            if missing, let error = change.siteMissing {
                Self.unwrite(written)
                throw error
            }
            return written
        }

        /// Put each written manuscript back as it was, last first.
        @MainActor static func unwrite(_ written: Written) {
            for each in written.reversed() { each.doc.setFullText(each.before) }
        }

        /// Release every held manuscript (closing one loaded for this verb,
        /// which persists whatever it holds).
        @MainActor func release() async {
            for each in manuscripts { await each.manuscript.release() }
        }
    }

    /// **Phase one of a figure verb's text change**: every manuscript whose
    /// text holds a site of `change` — for a rename the figure's line or a
    /// cross-reference to its label, for a send its line — is found (its live
    /// text where a window has it open, else derived from its op log — never
    /// the `.md`; one whose text cannot be derived refuses the verb, named,
    /// since its sites cannot be checked), and each is held through the
    /// door-checked route. **Any refusal releases them all and throws** the
    /// verb's refusal naming every piece that refused, so nothing is written
    /// anywhere. For a rename, only when the text holds the figure is a new
    /// name that is not a valid label name, or a label the text already
    /// defines, refused too.
    ///
    /// **A change targeting one piece** (`FigureTextChange.piece`: a
    /// retarget) reads and holds that piece alone — another piece's
    /// unreadable text does not refuse it — and refuses when the piece is not
    /// a prose manuscript or its text no longer holds the site
    /// (`siteMissing`).
    func holdManuscriptsForFigureText(_ change: FigureTextChange) async throws -> HeldFigureTextEdit {
        var newLabel: ManuscriptLabel?
        var newName = ""
        if case .relabel(let relabel) = change {
            newName = relabel.newName
            newLabel = ManuscriptLabel(reference: "\(relabel.old.kind.rawValue):\(relabel.newName)")
        }
        var candidates: [(title: String, path: String)] = []
        var labelTaken = false
        var unreadable: [String] = []
        let target = change.piece
        for item in Self.collectDocuments(in: manifest.structure) where target == nil || item.id == target {
            guard let path = item.path, !DocumentFormat.ofManuscript(path: path).isScreenplay else { continue }
            let text = Self.figureRelabelReadFailsForTesting.contains(item.id) ? nil
                : documentStore?.document(for: path)?.displayText
                    ?? (try? derivedCache.displayText(forDocId: item.id, in: url))
            guard let text else {
                // All or nothing: a piece whose sites cannot be checked
                // refuses the verb rather than be left unchanged.
                unreadable.append(item.title)
                continue
            }
            if case .relabel(let relabel) = change, let newLabel, relabel.old != newLabel,
               Self.definesLabel(text, newLabel) { labelTaken = true }
            if !Self.figureTextEdits(in: text, change).isEmpty {
                candidates.append((item.title, path))
            }
        }
        guard unreadable.isEmpty else { throw change.unreadable(unreadable) }
        guard !candidates.isEmpty else {
            if let missing = change.siteMissing { throw missing }
            return HeldFigureTextEdit(change: change, manuscripts: [])
        }
        if case .relabel = change {
            guard let newLabel else {
                throw FigureRenameRefused(reason: .notALabelName(newName))
            }
            guard !labelTaken else { throw FigureRenameRefused(reason: .labelTaken(newLabel.reference)) }
        }
        var held: [(title: String, manuscript: WritableManuscript)] = []
        var refused: [String] = []
        for candidate in candidates {
            do {
                held.append((candidate.title, try await openManuscriptForWriting(
                    path: candidate.path, title: candidate.title, session: "figure-text")))
            } catch is ManuscriptReplaceRefused {
                refused.append(candidate.title)
            } catch {
                await HeldFigureTextEdit(change: change, manuscripts: held).release()
                throw error
            }
        }
        guard refused.isEmpty else {
            await HeldFigureTextEdit(change: change, manuscripts: held).release()
            throw change.notWritable(refused)
        }
        return HeldFigureTextEdit(change: change, manuscripts: held)
    }

    /// Test seam: documents whose text `holdManuscriptsForFigureText`
    /// reads as underivable (an op log that will not read). Empty in
    /// production.
    static var figureRelabelReadFailsForTesting: Set<String> = []

    /// `text` relabelled by `change`, or nil when it holds nothing to change.
    nonisolated static func relabelled(_ text: String, _ change: FigureLabelChange) -> String? {
        edited(text, .relabel(change))
    }

    /// `text` with `change` made, or nil when it holds nothing to change.
    nonisolated static func edited(_ text: String, _ change: FigureTextChange) -> String? {
        let edits = figureTextEdits(in: text, change)
        guard !edits.isEmpty else { return nil }
        let ns = NSMutableString(string: text)
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            ns.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return ns as String
    }

    /// **Every site `change` rewrites in `text`**, as UTF-16 ranges: a
    /// relabel's (`figureRelabelEdits`), or each figure line a send removes
    /// (`figureLineRemovalEdits`).
    nonisolated static func figureTextEdits(
        in text: String, _ change: FigureTextChange
    ) -> [(range: NSRange, replacement: String)] {
        switch change {
        case .relabel(let relabel): return figureRelabelEdits(in: text, relabel)
        case .removeLine(let label): return figureLineRemovalEdits(in: text, label)
        case .retargetLine(_, let lineIndex, let oldPath, let newPath, let label):
            return figureLineRetargetEdits(in: text, lineIndex: lineIndex, oldPath: oldPath,
                                           newPath: newPath, label: label)
        }
    }

    /// **The path of the figure line starting on `lineIndex`, retargeted**:
    /// one edit, when a figure line (outside a code fence) starts there and
    /// its path is written exactly `oldPath`; none otherwise — a line that
    /// moved or was edited since it was found is not guessed at. With a
    /// `label` the line does not carry, the edit runs from the path to the
    /// line's end: the path, `)` and `{#label}`, in place of whatever label
    /// (and trailing space) it had — nothing else can follow a figure line's
    /// `)` (`ManuscriptBlocks`).
    nonisolated static func figureLineRetargetEdits(
        in text: String, lineIndex: Int, oldPath: String, newPath: String,
        label: ManuscriptLabel? = nil
    ) -> [(range: NSRange, replacement: String)] {
        let lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(lineIndex) else { return [] }
        for (block, range) in ManuscriptBlocks.parse(text) where range.lowerBound == lineIndex {
            guard case .figure(_, let path, let current) = block, path == oldPath else { return [] }
            let start = lines[..<lineIndex].reduce(0) { $0 + ($1 as NSString).length + 1 }
            let line = lines[lineIndex] as NSString
            let target = line.range(of: "](\(oldPath))", options: .backwards)
            guard target.location != NSNotFound else { return [] }
            let pathStart = start + target.location + 2
            guard let label, label != current else {
                return [(NSRange(location: pathStart, length: (oldPath as NSString).length), newPath)]
            }
            return [(NSRange(location: pathStart, length: line.length - target.location - 2),
                     "\(newPath)){#\(label.reference)}")]
        }
        return []
    }

    /// **The figure lines labelled `label`, removed** — each line with its
    /// line break, and with it one blank line beside it when the line stood
    /// alone between blank lines, so the paragraphs around it keep one blank
    /// line between them. Nothing inside a code fence is a site.
    nonisolated static func figureLineRemovalEdits(
        in text: String, _ label: ManuscriptLabel
    ) -> [(range: NSRange, replacement: String)] {
        let lines = text.components(separatedBy: "\n")
        var starts: [Int] = []
        var offset = 0
        for line in lines {
            starts.append(offset)
            offset += (line as NSString).length + 1
        }
        let length = (text as NSString).length
        func isBlank(_ i: Int) -> Bool {
            lines.indices.contains(i) && lines[i].trimmingCharacters(in: .whitespaces).isEmpty
        }
        var edits: [(range: NSRange, replacement: String)] = []
        for (block, range) in ManuscriptBlocks.parse(text) {
            guard case .figure(_, _, let l) = block, l == label else { continue }
            var first = range.lowerBound
            var last = range.upperBound - 1
            // A blank line on each side: take the one after (or, at the end
            // of the text, the one before) with the line.
            if isBlank(first - 1), isBlank(last + 1), last + 1 < lines.count - 1 {
                last += 1
            } else if isBlank(first - 1), last + 1 >= lines.count - 1 {
                first -= 1
            }
            let start = starts[first]
            let end = min(last + 1 < lines.count ? starts[last + 1] : length, length)
            edits.append((NSRange(location: start, length: end - start), ""))
        }
        return edits
    }

    /// **Every site a relabel rewrites in `text`**, as UTF-16 ranges: the
    /// figure line's label name and (when it names `oldFile`, in any case)
    /// its file name, and each cross-reference's name. Nothing inside a code
    /// fence or code span is a site.
    nonisolated static func figureRelabelEdits(
        in text: String, _ change: FigureLabelChange
    ) -> [(range: NSRange, replacement: String)] {
        let lines = text.components(separatedBy: "\n")
        var starts: [Int] = []
        var offset = 0
        for line in lines {
            starts.append(offset)
            offset += (line as NSString).length + 1
        }
        let old = change.old
        let nameLength = (old.name as NSString).length
        let prefixLength = (old.kind.rawValue as NSString).length + 1   // "tbl:"
        var edits: [(range: NSRange, replacement: String)] = []
        for (block, range) in ManuscriptBlocks.parse(text) {
            if case .other(.fence) = block { continue }
            if case .figure(_, let path, let label) = block, label == old {
                let index = range.lowerBound
                let line = lines[index] as NSString
                let labelBlock = line.range(of: "{#\(old.reference)}", options: .backwards)
                if labelBlock.location != NSNotFound {
                    edits.append((NSRange(location: starts[index] + labelBlock.location + 2 + prefixLength,
                                          length: nameLength), change.newName))
                    let file = (path as NSString).lastPathComponent
                    let target = line.range(of: "](\(path))", options: .backwards,
                                            range: NSRange(location: 0, length: labelBlock.location))
                    if file.lowercased() == change.oldFile.lowercased(), target.location != NSNotFound {
                        let fileLength = (file as NSString).length
                        let at = target.location + 2 + (path as NSString).length - fileLength
                        edits.append((NSRange(location: starts[index] + at, length: fileLength), change.newFile))
                    }
                }
            }
            let blockText = lines[range].joined(separator: "\n") as NSString
            for (marker, found) in ManuscriptInlineScanner.scan(blockText as String) {
                guard case .crossRef(let label) = marker, label == old else { continue }
                let at = blockText.range(of: "@\(old.reference)", options: [], range: found)
                guard at.location != NSNotFound else { continue }
                edits.append((NSRange(location: starts[range.lowerBound] + at.location + 1 + prefixLength,
                                      length: nameLength), change.newName))
            }
        }
        return edits
    }

    /// True when a heading, table caption or figure line in `text` defines
    /// `label` (outside a code fence).
    nonisolated static func definesLabel(_ text: String, _ label: ManuscriptLabel) -> Bool {
        ManuscriptBlocks.parse(text).contains { block, _ in
            switch block {
            case .heading(_, _, let l), .figure(_, _, let l): return l == label
            case .table(_, _, _, _, let l): return l == label
            default: return false
            }
        }
    }

    /// Pure-in-memory replacement step: re-find occurrences in the doc's CURRENT
    /// display form, replace the clicked one (or all), and commit via
    /// `setFullText`. The clicked one is found by `ClickedOccurrence.range`,
    /// which throws `.staleSearchMatch` — nothing committed — when the text
    /// no longer holds what the search showed. Persistence/teardown is the
    /// caller's responsibility (see `replaceInManuscript`).
    private func applyReplacement(
        to doc: Document,
        query: String,
        options: SearchOptions,
        replacement: String,
        clicked: ClickedOccurrence?
    ) throws {
        // Re-find occurrences in DISPLAY form (anchors stripped) — the form
        // the search read — so the ranges are valid coordinates for
        // `setFullText`.
        let display = doc.displayText
        let ranges = try clicked.map {
            [try $0.range(in: display, searched: display, query: query, options: options)]
        } ?? Self.matchRanges(in: display, query: query, options: options)

        // Apply right-to-left so earlier offsets aren't shifted by later edits.
        var ns = display as NSString
        for r in ranges.reversed() {
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
