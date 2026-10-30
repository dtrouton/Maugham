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

    /// What `replaceAll` did not do: the manuscript documents it left alone
    /// because this Mac may not write their text (ruling AI), by title.
    public struct ReplaceAllOutcome: Equatable {
        public let leftAlone: [String]
    }

    /// The one sentence naming the pieces a replace left alone.
    nonisolated static func leftAloneSentence(_ titles: [String]) -> String? {
        guard !titles.isEmpty else { return nil }
        return "Left as it was — this Mac may not change the text of "
            + titles.joined(separator: ", ") + "."
    }

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
                path: match.documentPath, title: match.documentTitle,
                query: query, options: options,
                replacement: replacement, occurrenceIndices: [ordinal])

        case .research:
            let url = try resolvedProjectPathToChange(match.documentPath)
            let original = try String(contentsOf: url, encoding: .utf8)  // adr-0018-ok: research-note read (manuscript replace routes through the op log)
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
    ///
    /// **A manuscript document this Mac may not write is SKIPPED and named**
    /// (controller ruling AI), never replaced and never a part-way failure:
    /// the rest of the book is replaced, and the outcome lists what was left.
    @discardableResult
    public func replaceAll(
        in results: SearchResults, with replacement: String
    ) async throws -> ReplaceAllOutcome {
        let grouped = Dictionary(grouping: results.matches, by: \.documentPath)
        var leftAlone: [String] = []
        for path in grouped.keys.sorted() {
            guard let matches = grouped[path],
                  let source = matches.first?.documentSource else { continue }
            switch source {
            case .manuscript:
                // Replace ALL occurrences (occurrenceIndices: nil).
                do {
                    try await replaceInManuscript(
                        path: path, title: matches[0].documentTitle,
                        query: results.query, options: results.options,
                        replacement: replacement, occurrenceIndices: nil)
                } catch let refused as ManuscriptReplaceRefused {
                    leftAlone.append(contentsOf: refused.titles)
                }

            case .research:
                let url = try resolvedProjectPathToChange(path)
                let original = try String(contentsOf: url, encoding: .utf8)  // adr-0018-ok: research-note read (manuscript replace routes through the op log)
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
        return ReplaceAllOutcome(leftAlone: leftAlone)
    }

    /// Apply a query→replacement edit to a manuscript document through the op
    /// log. Holds the document through the door-checked route
    /// (`openManuscriptForWriting`); re-finds occurrences in `displayText`
    /// (display coordinates, respecting `options`); replaces either the given
    /// ordinal occurrences (`occurrenceIndices`) or all of them (nil); commits
    /// via `setFullText`; persists + closes a transiently-loaded doc.
    private func replaceInManuscript(
        path: String,
        title: String,
        query: String,
        options: SearchOptions,
        replacement: String,
        occurrenceIndices: [Int]?
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
                replacement: replacement, occurrenceIndices: occurrenceIndices)
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
        /// its caption and label kept. Only that piece is held.
        case retargetLine(piece: String, lineIndex: Int, oldPath: String, newPath: String)

        /// The one piece (structure item id) the change is made in, or nil
        /// for every manuscript whose text holds a site.
        var piece: String? {
            if case .retargetLine(let piece, _, _, _) = self { return piece }
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
        case .retargetLine(_, let lineIndex, let oldPath, let newPath):
            return figureLineRetargetEdits(in: text, lineIndex: lineIndex, oldPath: oldPath, newPath: newPath)
        }
    }

    /// **The path of the figure line starting on `lineIndex`, retargeted**:
    /// one edit, when a figure line (outside a code fence) starts there and
    /// its path is written exactly `oldPath`; none otherwise — a line that
    /// moved or was edited since it was found is not guessed at.
    nonisolated static func figureLineRetargetEdits(
        in text: String, lineIndex: Int, oldPath: String, newPath: String
    ) -> [(range: NSRange, replacement: String)] {
        let lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(lineIndex) else { return [] }
        for (block, range) in ManuscriptBlocks.parse(text) where range.lowerBound == lineIndex {
            guard case .figure(_, let path, _) = block, path == oldPath else { return [] }
            let start = lines[..<lineIndex].reduce(0) { $0 + ($1 as NSString).length + 1 }
            let line = lines[lineIndex] as NSString
            let target = line.range(of: "](\(oldPath))", options: .backwards)
            guard target.location != NSNotFound else { return [] }
            return [(NSRange(location: start + target.location + 2, length: (oldPath as NSString).length), newPath)]
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
