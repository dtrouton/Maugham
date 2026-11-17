import Foundation
import MaughamCore

/// What the window is about: what the centre shows, what the right column is
/// about, and the reference material opened beside (shell p1).
public struct WindowSubject: Equatable, Codable, Sendable {
    /// What the centre shows.
    public var open: BinderSubject
    /// What the right column is about.
    public var faces: BinderSubject
    /// Reference material opened beside.
    public var beside: BinderSubject?

    public init(open: BinderSubject, faces: BinderSubject, beside: BinderSubject? = nil) {
        self.open = open
        self.faces = faces
        self.beside = beside
    }

    public static let book = WindowSubject(open: .project, faces: .project, beside: nil)

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
            beside: beside.flatMap { lives($0) ? $0 : nil })
    }
}
