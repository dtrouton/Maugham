import Foundation

/// Cooperative-identity ownership check for author self-service (edit /
/// withdraw your OWN annotation). WF1-local has no accounts: identity is the
/// reviewer's chosen display name (`UserPreferences.collaboratorDisplayName`)
/// matched against the annotation author stamped on its creation op.
///
/// Pure + nonisolated so it's directly unit-testable and callable from any
/// surface. An annotation is "own" iff it was authored by a human whose
/// display name equals the local reviewer's. Claude's annotations (or another
/// human collaborator's) are never editable/withdrawable here.
public enum AnnotationOwnership {
    public static func isOwn(_ annotation: Annotation, localName: String) -> Bool {
        guard let author = annotation.author else { return false }
        return author.sourceKind == .human && author.displayName == localName
    }
}
