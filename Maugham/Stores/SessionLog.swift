import Foundation

/// A single completed writing session — a contiguous activity period
/// bracketed by 30 minutes of typing inactivity at either end (or app
/// launch / quit).
public struct SessionEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let startedAt: Date
    public let endedAt: Date
    public let wordsNet: Int
    public let deviceId: String?

    public init(
        id: String,
        startedAt: Date,
        endedAt: Date,
        wordsNet: Int,
        deviceId: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.wordsNet = wordsNet
        self.deviceId = deviceId
    }
}

/// Append-only log of session events for a project. Stored at
/// `<project>/.maugham/sessions.json`. Conflict-merge by event id —
/// append-only logs compose safely under iCloud divergence.
public struct SessionLog: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var events: [SessionEvent]

    public static let empty = SessionLog(schemaVersion: currentSchemaVersion, events: [])

    public init(schemaVersion: Int = SessionLog.currentSchemaVersion,
                events: [SessionEvent]) {
        self.schemaVersion = schemaVersion
        self.events = events
    }

    /// Union by event id. Both logs share an identifier scheme so duplicate
    /// ids represent the same write — keep the local copy in that case.
    public static func merged(_ a: SessionLog, _ b: SessionLog) -> SessionLog {
        var byId: [String: SessionEvent] = [:]
        for e in a.events { byId[e.id] = e }
        for e in b.events where byId[e.id] == nil { byId[e.id] = e }
        let sorted = byId.values.sorted(by: { $0.startedAt < $1.startedAt })
        return SessionLog(
            schemaVersion: max(a.schemaVersion, b.schemaVersion),
            events: sorted)
    }

    /// Total wordsNet of events whose `startedAt` falls in today
    /// (caller's local timezone by default).
    public func wordsToday(
        timeZone: TimeZone = .current,
        now: Date = Date()
    ) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let startOfToday = cal.startOfDay(for: now)
        guard let endOfToday = cal.date(
            byAdding: .day, value: 1, to: startOfToday) else { return 0 }
        return events
            .filter { $0.startedAt >= startOfToday && $0.startedAt < endOfToday }
            .reduce(0) { $0 + $1.wordsNet }
    }

    /// Map of midnight-local-of-day → sum of wordsNet for sessions
    /// starting on that day, for days within `range` (inclusive).
    public func wordsByDay(
        in range: ClosedRange<Date>,
        timeZone: TimeZone = .current
    ) -> [Date: Int] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        var result: [Date: Int] = [:]
        for event in events {
            let startOfDay = cal.startOfDay(for: event.startedAt)
            guard startOfDay >= cal.startOfDay(for: range.lowerBound),
                  startOfDay <= cal.startOfDay(for: range.upperBound) else {
                continue
            }
            result[startOfDay, default: 0] += event.wordsNet
        }
        return result
    }

    /// Most recent `limit` events sorted descending by startedAt.
    public func eventsRecent(limit: Int) -> [SessionEvent] {
        return Array(events
            .sorted(by: { $0.startedAt > $1.startedAt })
            .prefix(limit))
    }
}
