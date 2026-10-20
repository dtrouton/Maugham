import Foundation
import MaughamCore

/// Why the citation door refused an edit. The words are the writer's: the
/// inspector shows `localizedDescription` inline, and `update_research_citation`
/// returns it as its invalid-argument message.
public enum CitationEditError: Error, Equatable, LocalizedError {
    /// Not `CitationKey.isValid`: letters, digits, `-` and `_`, starting with a
    /// letter or digit.
    case invalidKey
    /// Another live research item, or one in the Trash, holds this key.
    case duplicateKey(String)
    /// The key was cleared while other details are still set (R-3a-7).
    case needsAKey

    public var errorDescription: String? {
        switch self {
        case .invalidKey:
            return "A key uses only letters, digits, - and _, and starts with a letter or digit"
        case .duplicateKey(let key):
            return "Another source already uses the key \u{201C}\(key)\u{201D} (a source in the Trash counts too)"
        case .needsAKey:
            return "A citation needs a key"
        }
    }
}

/// **The one door a research item's citation details are written through**
/// (report foundations plan 3a, R-3a-7). The research inspector's Citation
/// section and the `update_research_citation` MCP tool both call
/// `updateCitation(researchId:_:)`; neither restates a rule.
///
/// - Fields are trimmed; a blank optional becomes nil and blank authors drop.
/// - Nothing left at all (`nil`, or every field blank) removes the citation.
/// - A blank key with any other detail set is refused (`needsAKey`).
/// - A key must be `CitationKey.isValid` and free against every OTHER live
///   item's key plus every key held in the Trash (a restore would bring it
///   back). An item keeping its own key is not a new claim, so it passes.
///
/// Piece-scoped research (a Collection piece's `pieces/<x>/research/`) lives in
/// `manifest.research` like shared research, so the one tree walk finds it and
/// its keys share the one namespace a book's `[@key]` resolves in.
extension ProjectStore {

    public func updateCitation(researchId: String, _ citation: CitationInfo?) async throws {
        beginStructuralVerb(); defer { endStructuralVerb() }
        guard findResearchItem(id: researchId, in: manifest.research) != nil else {
            throw ProjectStoreError.structureMissing
        }
        let trashed = await trashedResearchCitationKeys()
        // Everything from here to the write is ONE main-actor turn, with no
        // await (whole-branch review M7): the item, its own key and the live
        // keys are read after the trash scan, so a commit that interleaved
        // across that await — the inspector's and Claude's, or two quick
        // inspector commits — is seen, and two items never take one key.
        guard let item = findResearchItem(id: researchId, in: manifest.research) else {
            throw ProjectStoreError.structureMissing
        }
        let cleaned = try Self.validatedCitation(
            citation, ownKey: item.citation?.key,
            taken: liveCitationKeys(byOtherThan: researchId).union(trashed))
        mutateResearchItem(id: researchId) { $0.citation = cleaned }
        manifest.modified = Date()
        try await saveManifest()
    }

    public func suggestedCitationKey(for researchId: String) async -> String {
        let item = findResearchItem(id: researchId, in: manifest.research)
        return await suggestedCitationKey(
            for: researchId, authors: item?.citation?.authors ?? [],
            year: item?.citation?.year, sourceTitle: item?.citation?.sourceTitle)
    }

    /// `CitationKey.suggest` over values the caller has not saved yet (the
    /// inspector's drafts), free against the same set the door checks. With no
    /// source title the item's own title stands in, as `rekeyingCitations` does.
    func suggestedCitationKey(
        for researchId: String, authors: [String], year: Int?, sourceTitle: String?
    ) async -> String {
        let title = sourceTitle.flatMap(Self.nonBlank)
            ?? findResearchItem(id: researchId, in: manifest.research)?.title ?? ""
        return CitationKey.suggest(
            authors: authors, year: year, title: title,
            existing: await citationKeysTaken(byOtherThan: researchId))
    }

    /// Every live key except `researchId`'s own, plus every trashed key. The
    /// item's descendants still count: only its own key is its to keep.
    func citationKeysTaken(byOtherThan researchId: String) async -> Set<String> {
        let trashed = await trashedResearchCitationKeys()
        return liveCitationKeys(byOtherThan: researchId).union(trashed)
    }

    /// Every live key except `researchId`'s own: synchronous, so the door
    /// reads it in the same turn as its write.
    func liveCitationKeys(byOtherThan researchId: String) -> Set<String> {
        var live = Set<String>()
        func walk(_ items: [ResearchItem]) {
            for item in items {
                if item.id != researchId, let key = item.citation?.key { live.insert(key) }
                walk(item.children ?? [])
            }
        }
        walk(manifest.research)
        return live
    }

    /// The door's rules as a pure function: the cleaned citation to store
    /// (nil removes it), or the refusal.
    nonisolated static func validatedCitation(
        _ citation: CitationInfo?, ownKey: String?, taken: Set<String>
    ) throws -> CitationInfo? {
        guard let citation else { return nil }
        var cleaned = citation
        cleaned.key = citation.key.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned.authors = citation.authors.compactMap(nonBlank)
        cleaned.sourceTitle = citation.sourceTitle.flatMap(nonBlank)
        cleaned.publisher = citation.publisher.flatMap(nonBlank)
        cleaned.pages = citation.pages.flatMap(nonBlank)

        let hasOtherDetails = !cleaned.authors.isEmpty || cleaned.sourceTitle != nil
            || cleaned.publisher != nil || cleaned.year != nil
            || cleaned.accessed != nil || cleaned.pages != nil
        if cleaned.key.isEmpty {
            if hasOtherDetails { throw CitationEditError.needsAKey }
            return nil
        }
        guard CitationKey.isValid(cleaned.key) else { throw CitationEditError.invalidKey }
        if cleaned.key != ownKey, taken.contains(cleaned.key) {
            throw CitationEditError.duplicateKey(cleaned.key)
        }
        return cleaned
    }

    nonisolated static func nonBlank(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
