import Foundation
import MaughamCore

/// A surface that can resolve a wiki-link title to a document id.
/// ProjectStore conforms in T8; the protocol exists so the editor
/// layer can render wiki links without taking a hard dependency on
/// the full project store API.
///
/// Marked `@MainActor` because both the sole conformer (ProjectStore)
/// and the consumers (EditorCoordinator, ProseMode) are main-actor
/// isolated. Without the annotation, Swift 6 strict concurrency flags
/// the conformance as a data race risk.
@MainActor
public protocol WikiLinkProject: AnyObject {
    /// Returns the StructureItem id of the first manuscript document
    /// whose title matches `title` (case-insensitive, trimmed). Nil if
    /// no match.
    func resolveDocumentId(forTitle title: String) -> String?
}
