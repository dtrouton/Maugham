import Foundation

/// `list_scenes(project_id)` — screenplay-only. Parses on demand.
public enum ListScenesTool {
    public struct Params: Codable { public let project_id: String }
    public struct Scene: Codable, Equatable {
        public let id: String
        public let heading: String
        public let page_start: Double
        public let page_length: Double
        public let document_id: String
    }
    public static let method = "list_scenes"

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        guard let data = paramsJSON,
              let params = try? JSONDecoder().decode(Params.self, from: data) else {
            throw MCPError.invalidArgument("project_id required")
        }
        guard let entry = registry.lookup(id: params.project_id) else {
            throw MCPError.projectNotOpen
        }
        let store = entry.store
        guard store.manifest.type == .screenplay else {
            return try JSONEncoder().encode([Scene]())
        }

        var scenes: [Scene] = []
        for item in Self.allDocuments(in: store.manifest.structure) {
            guard let path = item.path else { continue }
            // Live in-memory text if open, else disk.
            let text: String
            if let ds = store.documentStore, ds.openDocumentPath == path {
                text = ds.currentDocumentText
            } else {
                let abs = entry.url.appendingPathComponent(path)
                text = (try? String(contentsOf: abs, encoding: .utf8)) ?? ""
            }
            let script = FountainTokenizer().parse(text)
            scenes.append(contentsOf: Self.scenesIn(script: script, documentId: item.id))
        }
        return try JSONEncoder().encode(scenes)
    }

    /// Walk manifest.structure recursively, flattening to .document items.
    private static func allDocuments(in items: [StructureItem]) -> [StructureItem] {
        var out: [StructureItem] = []
        for item in items {
            if item.type == .document { out.append(item) }
            if let kids = item.children { out.append(contentsOf: allDocuments(in: kids)) }
        }
        return out
    }

    /// Given a parsed script, emit Scene entries with fractional page positions.
    /// page_start is `linesBeforeScene / linesPerPage` (so the first scene starts
    /// at 0.0, not 1.0). page_length is the next scene's start minus this one's
    /// (or end-of-script minus this one for the last).
    private static func scenesIn(
        script: FountainScript, documentId: String
    ) -> [Scene] {
        let linesPerPage = 55.0
        struct Heading {
            let line: FountainLine
            let pageStart: Double
        }
        var headings: [Heading] = []
        var totalLines = 0
        for line in script.lines {
            if line.element == .sceneHeading {
                headings.append(Heading(
                    line: line,
                    pageStart: Double(totalLines) / linesPerPage))
            }
            totalLines += Self.lineCount(for: line)
        }
        let scriptEnd = Double(totalLines) / linesPerPage

        var scenes: [Scene] = []
        for (idx, h) in headings.enumerated() {
            let end = (idx + 1 < headings.count) ? headings[idx + 1].pageStart : scriptEnd
            let length = max(0, end - h.pageStart)
            scenes.append(Scene(
                id: "scene-\(h.line.range.location)",
                heading: h.line.content,
                page_start: h.pageStart,
                page_length: length,
                document_id: documentId))
        }
        return scenes
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
public enum FindReferencesTool {
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

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        guard let data = paramsJSON,
              let params = try? JSONDecoder().decode(Params.self, from: data) else {
            throw MCPError.invalidArgument("project_id and target required")
        }
        guard let entry = registry.lookup(id: params.project_id) else {
            throw MCPError.projectNotOpen
        }
        let store = entry.store

        // Resolve target to a canonical id (document or research).
        // Try id-match first, then title-match.
        let resolvedId: String? = Self.resolveTargetId(params.target, store: store)

        var refs: [Reference] = []
        var seenFromIds = Set<String>()

        // Linked-research backref scan needs an id.
        if let rid = resolvedId {
            for chapter in Self.flatDocs(store.manifest.structure) {
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
            for doc in Self.flatDocs(store.manifest.structure) {
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
    /// research), then by case-insensitive title match.
    @MainActor
    private static func resolveTargetId(_ target: String, store: ProjectStore) -> String? {
        // Exact id in manuscript structure?
        if flatDocs(store.manifest.structure).contains(where: { $0.id == target }) {
            return target
        }
        // Exact id in research tree?
        if findResearchById(id: target, in: store.manifest.research) != nil {
            return target
        }
        // Case-insensitive title match in manuscript structure?
        if let m = flatDocs(store.manifest.structure)
            .first(where: { $0.title.compare(target, options: .caseInsensitive) == .orderedSame }) {
            return m.id
        }
        // Case-insensitive title match in research tree?
        if let r = findResearchByTitle(title: target, in: store.manifest.research) {
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
            for doc in flatDocs(store.manifest.structure) where doc.id == id {
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

    @MainActor
    private static func flatDocs(_ items: [StructureItem]) -> [StructureItem] {
        var out: [StructureItem] = []
        for item in items {
            if item.type == .document { out.append(item) }
            if let kids = item.children { out.append(contentsOf: flatDocs(kids)) }
        }
        return out
    }

    private static func findResearchById(id: String, in items: [ResearchItem]) -> ResearchItem? {
        for item in items {
            if item.id == id { return item }
            if let kids = item.children, let n = findResearchById(id: id, in: kids) { return n }
        }
        return nil
    }

    private static func findResearchByTitle(title: String, in items: [ResearchItem]) -> ResearchItem? {
        for item in items {
            if item.title.compare(title, options: .caseInsensitive) == .orderedSame { return item }
            if let kids = item.children, let n = findResearchByTitle(title: title, in: kids) { return n }
        }
        return nil
    }
}

/// `get_session_stats(project_id, days?)` — session log aggregates.
public enum GetSessionStatsTool {
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

    @MainActor
    public static func handle(paramsJSON: Data?, registry: ProjectRegistry) async throws -> Data {
        guard let data = paramsJSON,
              let params = try? JSONDecoder().decode(Params.self, from: data) else {
            throw MCPError.invalidArgument("project_id required")
        }
        guard let entry = registry.lookup(id: params.project_id) else {
            throw MCPError.projectNotOpen
        }
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
