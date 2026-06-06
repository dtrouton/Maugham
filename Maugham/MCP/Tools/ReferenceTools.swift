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
                let abs = entry.url.appendingPathComponent(path)
                text = (try? String(contentsOf: abs, encoding: .utf8)) ?? ""
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
        public let kind: String   // "wiki" or "linked_research"
    }
    public static let method = "find_references"
    public static let description =
        "Find back-references to a document or research item. The `target` " +
        "can be an id (returned by get_outline / list_research) or a title " +
        "(case-insensitive match). Returns [[wiki link]] matches in manuscript " +
        "text + research-link backrefs."
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

        // Wiki-link references: gather candidate titles. If target resolved to an
        // id, look up its title(s); else use the literal target string as a title.
        let titles = Self.titlesToScan(target: params.target, resolvedId: resolvedId, store: store)
        if !titles.isEmpty {
            for doc in TreeWalk.collect(in: store.manifest.structure, where: { $0.type == .document }) {
                guard let path = doc.path else { continue }
                let abs = entry.url.appendingPathComponent(path)
                guard let text = try? String(contentsOf: abs, encoding: .utf8) else { continue }
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
