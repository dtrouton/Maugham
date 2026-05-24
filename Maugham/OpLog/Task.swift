import Foundation

public enum TaskKind: String, Codable, Sendable, Equatable {
    case inlineMarkdown   = "inline_markdown"
    case fountainBoneyard = "fountain_boneyard"
    case paneCreated      = "pane_created"
}

public enum TaskStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case open
    case done
    case archived
}

public struct TaskAnchor: Codable, Sendable, Equatable {
    public let docId: String
    public let paragraphId: String?

    public init(docId: String, paragraphId: String?) {
        self.docId = docId
        self.paragraphId = paragraphId
    }
}

/// A single task item (inline checkbox, Fountain boneyard, or pane-created).
/// Named `WriterTask` to avoid shadowing Swift's built-in `_Concurrency.Task`.
public struct WriterTask: Identifiable, Sendable, Equatable {
    public let id: String
    public let kind: TaskKind
    public let anchor: TaskAnchor?
    public let body: String
    public let status: TaskStatus
    public let priority: Double
    public let parentTaskId: String?
    public let createdAt: Date
    public let createdBySession: String?

    public init(
        id: String, kind: TaskKind, anchor: TaskAnchor?, body: String,
        status: TaskStatus, priority: Double, parentTaskId: String?,
        createdAt: Date, createdBySession: String?
    ) {
        self.id = id
        self.kind = kind
        self.anchor = anchor
        self.body = body
        self.status = status
        self.priority = priority
        self.parentTaskId = parentTaskId
        self.createdAt = createdAt
        self.createdBySession = createdBySession
    }
}

public struct TaskFilter: Sendable, Equatable {
    public enum Scope: Sendable, Equatable {
        case document(docId: String)
        case project
    }
    public var scope: Scope
    public var statuses: Set<TaskStatus>

    public init(scope: Scope, statuses: Set<TaskStatus> = [.open]) {
        self.scope = scope
        self.statuses = statuses
    }
}
