import Foundation
import MaughamCore

/// Classifies a drag-and-drop gesture in the binder into a structural action.
public enum DropIntent: Equatable, Sendable {
    case insertAbove(targetId: String)
    case insertBelow(targetId: String)
    case insertChild(parentId: String)
}

extension DropIntent {
    /// Vertical position of the drop within a row's height.
    public enum Position: Equatable, Sendable {
        case top, middle, bottom
    }

    /// Classify a drop. Documents can't have children, so a middle drop on
    /// a document becomes "below".
    public static func classify(
        position: Position, target: StructureItem
    ) -> DropIntent {
        switch position {
        case .top:
            return .insertAbove(targetId: target.id)
        case .bottom:
            return .insertBelow(targetId: target.id)
        case .middle:
            return target.type == .group
                ? .insertChild(parentId: target.id)
                : .insertBelow(targetId: target.id)
        }
    }
}
