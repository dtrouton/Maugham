import Foundation
import MaughamCore

/// **The one thing the writer pulled up beside the centre** (shell plan 3):
/// the right column's third position. It generalises what `beside` held in
/// plans 1–2 (a research item opened beside) to everything the tree, the fold
/// and the Book's Brief can pull up. It stays until closed, across subject
/// changes (`WindowSubject.beside`'s rules are unchanged; its type widened).
///
/// **The encoding is `BinderSubject`'s for the two cases they share**
/// (`{"kind":"research","id":"r1"}`, `{"kind":"figure","id":"f1"}`), so a
/// subject persisted by plans 1–2 reads back as the same thing beside. Every
/// case is `kind` plus its value under `id` (`path` for a picture). An
/// unknown kind throws; `WindowSubject` reads that as nothing beside
/// (tripwire 11).
public enum PulledUp: Hashable, Codable, Sendable {
    /// A research item: a note, a table, a PDF, a palette card.
    case research(String)
    case figure(String)
    /// A scrap typed onto the canvas. Its words live in the canvas's shared
    /// text storage.
    case canvasScrap(nodeId: String)
    /// A picture the canvas owns (`canvas_assets/`), by project-relative path.
    case canvasPhoto(path: String)
    /// The Book's statements that are not its intent.
    case lessons, firstReader, visualLanguage
    /// A piece's history.
    case history(docId: String)

    private enum CodingKeys: String, CodingKey { case kind, id, path }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .research(let id):
            try c.encode("research", forKey: .kind); try c.encode(id, forKey: .id)
        case .figure(let id):
            try c.encode("figure", forKey: .kind); try c.encode(id, forKey: .id)
        case .canvasScrap(let nodeId):
            try c.encode("canvasScrap", forKey: .kind); try c.encode(nodeId, forKey: .id)
        case .canvasPhoto(let path):
            try c.encode("canvasPhoto", forKey: .kind); try c.encode(path, forKey: .path)
        case .lessons: try c.encode("lessons", forKey: .kind)
        case .firstReader: try c.encode("firstReader", forKey: .kind)
        case .visualLanguage: try c.encode("visualLanguage", forKey: .kind)
        case .history(let docId):
            try c.encode("history", forKey: .kind); try c.encode(docId, forKey: .id)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "research": self = .research(try c.decode(String.self, forKey: .id))
        case "figure": self = .figure(try c.decode(String.self, forKey: .id))
        case "canvasScrap": self = .canvasScrap(nodeId: try c.decode(String.self, forKey: .id))
        case "canvasPhoto": self = .canvasPhoto(path: try c.decode(String.self, forKey: .path))
        case "lessons": self = .lessons
        case "firstReader": self = .firstReader
        case "visualLanguage": self = .visualLanguage
        case "history": self = .history(docId: try c.decode(String.self, forKey: .id))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "unknown pulled-up kind \(other)")
        }
    }

    /// What a tree row pulls up: a research item or a figure; nil for every
    /// other row (a piece, a Part, the Book, the Canvas…, which open).
    public init?(treeSubject: BinderSubject) {
        switch treeSubject {
        case .research(let id): self = .research(id)
        case .figure(let id): self = .figure(id)
        case .project, .item, .inbox, .canvas, .palette, .edition: return nil
        }
    }

    /// The tree row this is, when it is one — what the tree draws selected or
    /// outlined, and what the canvas lights. nil for a canvas card, a
    /// statement or History: none is a tree row.
    public var treeSubject: BinderSubject? {
        switch self {
        case .research(let id): return .research(id)
        case .figure(let id): return .figure(id)
        case .canvasScrap, .canvasPhoto, .lessons, .firstReader, .visualLanguage, .history:
            return nil
        }
    }

    public var researchID: String? {
        if case .research(let id) = self { return id }
        return nil
    }

    public var figureID: String? {
        if case .figure(let id) = self { return id }
        return nil
    }

    /// **Whether it is edited where it is pulled up** — the one answer
    /// (owner, 2026-11-16 / 2026-11-18). A research note, a palette card, a
    /// table and a figure are edited beside, under Lock as in the centre. A
    /// canvas card is READ-ONLY beside, with Open in Centre: its words live in
    /// the canvas's shared text storage, and a second editor on them is the
    /// tripwires 26–28 risk (open question 4: either answer is this one line).
    /// A statement is its own `StatementEditorHost`, asked of its posture.
    /// History is a record, never edited.
    var isEditableBeside: Bool {
        switch self {
        case .research, .figure, .lessons, .firstReader, .visualLanguage: return true
        case .canvasScrap, .canvasPhoto, .history: return false
        }
    }

    /// Whether the window's Lock covers it — exactly the items it covers in
    /// the centre (`WindowLock`: research, a palette card, a table, a figure).
    var lockApplies: Bool {
        switch self {
        case .research, .figure: return true
        case .canvasScrap, .canvasPhoto, .lessons, .firstReader, .visualLanguage, .history:
            return false
        }
    }

    /// The statement this is, for its posture and its one editor; nil for
    /// everything that is not a statement.
    var statement: (kind: Statement.Kind, scope: Statement.Scope)? {
        switch self {
        case .lessons: return (.lessons, .project)
        case .firstReader: return (.firstReader, .project)
        case .visualLanguage: return (.visualLanguage, .project)
        case .research, .figure, .canvasScrap, .canvasPhoto, .history: return nil
        }
    }

    /// What Open in Centre draws as the centre's cover (`CentreItem`), for a
    /// statement and History; nil for what the centre opens as a subject.
    var centreItem: CentreItem? {
        if let statement { return .statement(kind: statement.kind, scope: statement.scope) }
        if case .history(let docId) = self { return .history(docId: docId) }
        return nil
    }
}

/// **A statement or a piece's History opened in the centre** (shell plan 3):
/// drawn as a cover over the editor route (`CentreCover.centreItem`), where a
/// publish cover wins while it stands. Not a subject: the subject opens the
/// piece (or the Book) the item belongs to (`ProjectWindow.openingInCentre`),
/// and the item clears on any later change of what is open
/// (`centreItemAfterOpenChange`).
enum CentreItem: Equatable {
    case statement(kind: Statement.Kind, scope: Statement.Scope)
    case history(docId: String)
}
