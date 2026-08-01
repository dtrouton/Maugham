import Foundation
import MaughamCore

/// `list_scenes(project_id)` — screenplay-only. Parses on demand.
public enum ListScenesTool: MCPTool {
    public struct Params: Codable { public let project_id: String }
    public struct Scene: Codable, Equatable {
        public let id: String
        public let heading: String
        public let page_start: Double
        public let page_length: Double
        public let document_id: String
    }
    public static let method = "list_scenes"
    public static let description =
        "Return scenes parsed from a Fountain screenplay. Empty array for non-screenplay projects."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"}},"required":["project_id"]}"#

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(params.project_id, in: registry)
        let store = entry.store
        guard store.manifest.type == .screenplay else {
            return try JSONEncoder().encode([Scene]())
        }

        // Walk all .document items in manifest order, maintaining a script-global
        // line counter so page_start positions are cumulative across documents.
        // Compound (documentId, lineLocation) into each scene's id so the id is
        // actually unique across the script.
        struct Heading {
            let documentId: String
            let line: FountainLine
            let pageStart: Double
        }
        let linesPerPage = 55.0
        var headings: [Heading] = []
        var cumulativeLines = 0
        for item in TreeWalk.collect(in: store.manifest.structure, where: { $0.type == .document }) {
            guard let path = item.path else { continue }
            let text: String
            if let ds = store.documentStore, let doc = ds.document(for: path) {
                text = doc.displayText
            } else {
                // Closed doc: display form through the per-project cache (F5);
                // strip anchors so the Fountain parser sees clean text, matching
                // the open-doc displayText form.
                text = store.derivedCache.displayText(forDocId: item.id, in: entry.url)
            }
            let script = FountainTokenizer().parse(text)
            for line in script.lines {
                if line.element == .sceneHeading {
                    headings.append(Heading(
                        documentId: item.id,
                        line: line,
                        pageStart: Double(cumulativeLines) / linesPerPage))
                }
                cumulativeLines += Self.lineCount(for: line)
            }
        }
        let scriptEnd = Double(cumulativeLines) / linesPerPage

        var scenes: [Scene] = []
        for (idx, h) in headings.enumerated() {
            let end = (idx + 1 < headings.count) ? headings[idx + 1].pageStart : scriptEnd
            let length = max(0, end - h.pageStart)
            // Strip redundant "scene-" prefix from document id when building the
            // composite scene id (old projects may have stored ids like "scene-f8c9644e").
            let normalizedDocId = h.documentId.hasPrefix("scene-")
                ? String(h.documentId.dropFirst("scene-".count))
                : h.documentId
            scenes.append(Scene(
                id: "scene-\(normalizedDocId)-\(h.line.range.location)",
                heading: h.line.content,
                page_start: h.pageStart,
                page_length: length,
                document_id: h.documentId))
        }
        return try JSONEncoder().encode(scenes)
    }

    /// Mirror of FountainScript's private lineCount(for:). Replicated here because
    /// the original is `private static` — keep in sync if the script's wrap math
    /// changes. Documented in spec carry-forwards.
    private static func lineCount(for line: FountainLine) -> Int {
        let charsPerActionLine = 60
        let charsPerDialogueLine = 35
        let charsPerParenthetical = 20
        let sceneHeadingExtraBlankLines = 1
        switch line.element {
        case .action:
            let len = line.content.count
            guard len > 0 else { return 0 }
            return max((len + charsPerActionLine - 1) / charsPerActionLine, 1)
        case .dialogue:
            let len = line.content.count
            return max((len + charsPerDialogueLine - 1) / charsPerDialogueLine, 1)
        case .parenthetical:
            let len = line.content.count
            return max((len + charsPerParenthetical - 1) / charsPerParenthetical, 1)
        case .sceneHeading:
            return 1 + sceneHeadingExtraBlankLines
        case .character, .transition, .centered, .lyric:
            return 1
        case .section, .synopsis, .boneyard, .note, .pageBreak, .titlePage:
            return 0
        }
    }
}

/// `find_references(project_id, target)` — wiki links + linked_research backreferences.
public enum FindReferencesTool: MCPTool {
    public struct Params: Codable {
        public let project_id: String
        public let target: String
    }
    public struct Reference: Codable, Equatable {
        public let from_id: String
        public let from_title: String
        public let kind: String   // "wiki", "linked_research", or "piece_research"
    }
    public static let method = "find_references"
    public static let description =
        "Find back-references to a document or research item. The `target` " +
        "can be an id (returned by get_outline / list_research) or a title " +
        "(case-insensitive match). Returns [[wiki link]] matches in manuscript " +
        "text, research note bodies (a link written into a research note, " +
        "e.g. by canvas promotion, is included) AND statements (craft intent, " +
        "visual language) + research-link backrefs. " +
        "Piece-owned research returns its owning piece as a piece_research " +
        "backref. When a piece both links to and owns the same research " +
        "item, the explicit link masks the containment backref " +
        "(deduplicated by from_id)."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"target":{"type":"string"}},"required":["project_id","target"]}"#

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(params.project_id, in: registry)
        let store = entry.store

        // Resolve target to a canonical id (document or research).
        // Try id-match first, then title-match.
        let resolvedId: String? = Self.resolveTargetId(params.target, store: store)

        var refs: [Reference] = []
        var seenFromIds = Set<String>()

        // Linked-research backref scan needs an id.
        if let rid = resolvedId {
            for chapter in TreeWalk.collect(in: store.manifest.structure, where: { $0.type == .document }) {
                if store.linkedResearchIds(forDocumentId: chapter.id).contains(rid) {
                    if seenFromIds.insert(chapter.id).inserted {
                        refs.append(Reference(
                            from_id: chapter.id,
                            from_title: chapter.title,
                            kind: "linked_research"))
                    }
                }
            }
        }

        // Containment backref — a collection loose piece owning the target
        // research item by path prefix is a reference too (spec 2026-07-07).
        if let rid = resolvedId {
            for piece in store.manifest.structure where piece.pieceKind == .loose {
                if store.derivedResearchItems(forDocumentId: piece.id)
                    .contains(where: { $0.id == rid }),
                   seenFromIds.insert(piece.id).inserted {
                    refs.append(Reference(
                        from_id: piece.id,
                        from_title: piece.title,
                        kind: "piece_research"))
                }
            }
        }

        // Wiki-link references: gather candidate titles. If target resolved to an
        // id, look up its title(s); else use the literal target string as a title.
        let titles = Self.titlesToScan(target: params.target, resolvedId: resolvedId, store: store)
        if !titles.isEmpty {
            for doc in TreeWalk.collect(in: store.manifest.structure, where: { $0.type == .document }) {
                // ADR 0018: an OPEN doc's live `Document` is freshest (the op
                // log lags an actively-edited doc by the burst window, 30s/90s);
                // closed docs derive from the op log. Never read the `.md`.
                let text: String
                if let ds = store.documentStore, let path = doc.path,
                   let live = ds.document(for: path) {
                    text = live.materialize()
                } else {
                    text = store.derivedCache.materialize(forDocId: doc.id, in: entry.url)
                }
                guard !text.isEmpty else { continue }
                for title in titles where text.contains("[[\(title)]]") {
                    if seenFromIds.insert(doc.id).inserted {
                        refs.append(Reference(
                            from_id: doc.id,
                            from_title: doc.title,
                            kind: "wiki"))
                    }
                    break
                }
            }

            // The same widening `list_all_links` takes, and for the same
            // reason: a promoted line's link lives in a research note, and this
            // is the tool a writer asks "what points at this".
            for item in TreeWalk.collect(in: store.manifest.research,
                                         where: { $0.kind == .document }) {
                guard item.id != resolvedId,          // not a reference to itself
                      let path = item.path,
                      let text = try? String(contentsOf: entry.url.appendingPathComponent(path), encoding: .utf8),  // adr-0018-ok: research note, not manuscript
                      !text.isEmpty else { continue }
                for title in titles where text.contains("[[\(title)]]") {
                    if seenFromIds.insert(item.id).inserted {
                        refs.append(Reference(from_id: item.id, from_title: item.title,
                                              kind: "wiki"))
                    }
                    break
                }
            }

            // And the same widening again for statements, because M1A moved the
            // writer's intent into one. A link that lived in a craft-intent
            // research note WAS found here; adoption carries the body across
            // verbatim, so without this loop the migration silently costs the
            // answer to "what points at this".
            //
            // ADR 0018: `statementText(of:)` derives — a statement is a
            // `Document` and its `.md` is output.
            let documentTitles = Dictionary(
                TreeWalk.collect(in: store.manifest.structure, where: { _ in true })
                    .map { ($0.id, $0.title) },
                uniquingKeysWith: { _, later in later })
            for statement in store.manifest.statements {
                guard statement.id != resolvedId else { continue }
                let text = store.statementText(of: statement)
                guard !text.isEmpty else { continue }
                for title in titles where text.contains("[[\(title)]]") {
                    if seenFromIds.insert(statement.id).inserted {
                        refs.append(Reference(
                            from_id: statement.id,
                            from_title: ArtifactIndex.statementTitle(
                                statement, documentTitle: { documentTitles[$0] }),
                            kind: "wiki"))
                    }
                    break
                }
            }
        }

        return try JSONEncoder().encode(refs)
    }

    /// Resolve `target` to a canonical id: first by id match (structure or
    /// research), then by case-insensitive title match, then by exact path match.
    @MainActor
    private static func resolveTargetId(_ target: String, store: ProjectStore) -> String? {
        let docs = TreeWalk.collect(in: store.manifest.structure, where: { $0.type == .document })
        // Exact id in manuscript structure?
        if docs.contains(where: { $0.id == target }) {
            return target
        }
        // Exact id in research tree?
        if TreeWalk.find(id: target, in: store.manifest.research) != nil {
            return target
        }
        // Case-insensitive title match in manuscript structure?
        if let m = docs
            .first(where: { $0.title.compare(target, options: .caseInsensitive) == .orderedSame }) {
            return m.id
        }
        // Case-insensitive title match in research tree?
        if let r = TreeWalk.first(in: store.manifest.research, where: {
            $0.title.compare(target, options: .caseInsensitive) == .orderedSame
        }) {
            return r.id
        }
        // Exact path match (manuscript)?
        if let m = docs
            .first(where: { $0.path == target }) {
            return m.id
        }
        // Exact path match (research)?
        if let r = TreeWalk.first(in: store.manifest.research, where: { $0.path == target }) {
            return r.id
        }
        return nil
    }

    @MainActor
    private static func titlesToScan(
        target: String, resolvedId: String?, store: ProjectStore
    ) -> [String] {
        var titles: [String] = []
        if let id = resolvedId {
            for doc in TreeWalk.collect(in: store.manifest.structure, where: { $0.type == .document })
                where doc.id == id {
                titles.append(doc.title)
            }
            for item in store.resolveResearchLinks([id]) {
                titles.append(item.title)
            }
        } else {
            // Unresolved id — still scan for [[target]] literally; user may have
            // a wiki link to something that hasn't been created yet.
            titles.append(target)
        }
        return titles
    }

}

/// `get_session_stats(project_id, days?)` — session log aggregates.
public enum GetSessionStatsTool: MCPTool {
    public struct Params: Codable {
        public let project_id: String
        public let days: Int?    // default 30
    }
    public struct DayStat: Codable, Equatable {
        public let date: String   // yyyy-MM-dd
        public let words: Int
        public let minutes: Int
    }
    public struct SessionStats: Codable, Equatable {
        public let daily: [DayStat]
        public let total_words: Int
        public let total_minutes: Int
    }
    public static let method = "get_session_stats"
    public static let description =
        "Aggregate writing session stats over a window (default 30 days): per-day words + minutes, totals."
    public static let inputSchemaJSON =
        #"{"type":"object","properties":{"project_id":{"type":"string"},"days":{"type":"integer"}},"required":["project_id"]}"#

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        let params = try decodeParams(Params.self, from: paramsJSON)
        let entry = try resolveProject(params.project_id, in: registry)
        let daysWindow = max(1, params.days ?? 30)
        let log = (try? await entry.store.documentStore?.loadSessionLog()) ?? .empty
        let now = Date()
        let cutoff = Calendar.current.date(byAdding: .day, value: -daysWindow, to: now)
            ?? Date.distantPast

        // Aggregate per-day. Group SessionEvents by startOfDay(startedAt).
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = .current

        var perDay: [Date: (Int, Int)] = [:]   // (words, seconds)
        var totalWords = 0
        var totalSeconds = 0
        for event in log.events where event.startedAt >= cutoff {
            let day = cal.startOfDay(for: event.startedAt)
            let secs = Int(event.endedAt.timeIntervalSince(event.startedAt))
            let secsClamped = max(0, secs)
            let (w, s) = perDay[day] ?? (0, 0)
            perDay[day] = (w + event.wordsNet, s + secsClamped)
            totalWords += event.wordsNet
            totalSeconds += secsClamped
        }
        let sortedDays = perDay.keys.sorted()
        let daily = sortedDays.map { day in
            let (w, s) = perDay[day]!
            return DayStat(
                date: fmt.string(from: day),
                words: w,
                minutes: s / 60)
        }
        let stats = SessionStats(
            daily: daily,
            total_words: totalWords,
            total_minutes: totalSeconds / 60)
        return try JSONEncoder().encode(stats)
    }
}
