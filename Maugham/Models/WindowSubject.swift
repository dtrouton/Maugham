import Foundation
import MaughamCore

/// What the window is about: what the centre shows, what the right column is
/// about, and the reference material opened beside (shell p1).
public struct WindowSubject: Equatable, Codable, Sendable {
    /// What the centre shows.
    public var open: BinderSubject
    /// What the right column is about. Writing it makes the faces the part
    /// clicked last (`lastClicked`).
    public var faces: BinderSubject {
        didSet { besideIsLatest = false }
    }
    /// Reference material opened beside. Writing something here makes it the
    /// part clicked last; putting it away hands that back to the faces.
    public var beside: BinderSubject? {
        didSet { besideIsLatest = beside != nil }
    }
    /// **Which of `faces` and `beside` was written last** (shell p1 final fix,
    /// I1). `beside` persists across clicks, so "what is beside, else the
    /// faces" cannot say which the writer clicked last: a piece clicked after
    /// a research note moves the faces while the note stays beside. Kept by
    /// the two `didSet`s above, so every writer of a part records it.
    public private(set) var besideIsLatest: Bool

    /// `besideIsLatest` defaults to "beside was written after the faces"
    /// whenever something is beside — a subject built whole names its parts
    /// in that order.
    public init(open: BinderSubject, faces: BinderSubject, beside: BinderSubject? = nil,
                besideIsLatest: Bool? = nil) {
        self.open = open
        self.faces = faces
        self.beside = beside
        self.besideIsLatest = beside != nil && (besideIsLatest ?? true)
    }

    public static let book = WindowSubject(open: .project, faces: .project, beside: nil)

    /// The row the writer last clicked: what is opened beside when it was
    /// written after the faces, else what the faces are on. The tree draws it
    /// outlined when it is not what is open; the canvas lights it.
    public var lastClicked: BinderSubject {
        if besideIsLatest, let beside { return beside }
        return faces
    }

    private enum CodingKeys: String, CodingKey { case open, faces, beside, besideIsLatest }

    /// A subject written before the order was recorded has none: it decodes
    /// as built whole (beside latest when there is one).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(open: try c.decode(BinderSubject.self, forKey: .open),
                  faces: try c.decode(BinderSubject.self, forKey: .faces),
                  beside: try c.decodeIfPresent(BinderSubject.self, forKey: .beside),
                  besideIsLatest: try c.decodeIfPresent(Bool.self, forKey: .besideIsLatest))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(open, forKey: .open)
        try c.encode(faces, forKey: .faces)
        try c.encodeIfPresent(beside, forKey: .beside)
        try c.encode(besideIsLatest, forKey: .besideIsLatest)
    }

    /// Any part naming something that no longer exists becomes the Book (open,
    /// faces) or nil (beside).
    public func validated(structure: [StructureItem], researchIDs: Set<String>,
                          figureIDs: Set<String>,
                          editionLanguages: Set<String>) -> WindowSubject {
        func lives(_ s: BinderSubject) -> Bool {
            switch s {
            case .project, .inbox, .canvas, .palette: return true
            case .item(let id): return TreeWalk.contains(id: id, in: structure)
            case .research(let id): return researchIDs.contains(id)
            case .figure(let id): return figureIDs.contains(id)
            case .edition(let language): return editionLanguages.contains(language)
            }
        }
        return WindowSubject(
            open: lives(open) ? open : .project,
            faces: lives(faces) ? faces : .project,
            beside: beside.flatMap { lives($0) ? $0 : nil },
            besideIsLatest: besideIsLatest)
    }
}
