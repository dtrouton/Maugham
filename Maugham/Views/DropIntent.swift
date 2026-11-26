import Foundation
import CoreGraphics
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

        /// **The one reading of a point on a row** (shell p4 Task 10 fix
        /// round 1): thirds — the top third above, the bottom third below,
        /// the middle into — or, for a target with no "into" (a Collection
        /// piece row), halves. `y` from the row's top, in the same space as
        /// `height`, the row's REAL height: every drop closure and the hover
        /// read it, so they cannot disagree about where the pointer is.
        public static func of(y: CGFloat, height: CGFloat, halves: Bool = false) -> Position {
            let h = Swift.max(height, 1)
            if halves { return y < h / 2 ? .top : .bottom }
            if y < h / 3 { return .top }
            if y > h * 2 / 3 { return .bottom }
            return .middle
        }
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
