import Foundation
import MaughamCore

/// What `adoptExternalManifest` did with a manifest another device wrote.
/// `DocumentStore.handleManifestChanged` reads it to decide what to archive,
/// which open Documents to let go of, and how far to move the session's
/// baseline.
struct ManifestAdoption {
    /// The manifest this window held until now.
    let previous: ProjectManifest
    /// The manifest it holds now.
    let adopted: ProjectManifest
    /// Whether `previous` said anything `adopted` does not — i.e. whether
    /// there is a loser to archive at all.
    let replacedSomething: Bool
    /// `previous` carried a change of this window's own that never reached
    /// disk (a verb whose save threw). It is archived like any other loser;
    /// this only lets the log say so.
    let overUnsavedChange: Bool
    /// How far the project's word total moved because pieces came or went.
    /// Those words are someone else's, so the session subtracts them
    /// (Denver's ruling, 2026-09-23).
    let wordCountDelta: Int

    /// A document whose path this adoption changed: renamed or moved by
    /// another device.
    struct Moved: Equatable { let id: String; let oldPath: String; let newPath: String }
    /// A document this adoption removed: trashed by another device.
    struct Removed: Equatable { let id: String; let oldPath: String; let title: String }

    /// Documents whose path changed: renamed or moved elsewhere.
    let moved: [Moved]
    /// Documents that left the structure: trashed elsewhere.
    let removed: [Removed]
}

extension ProjectStore {

    /// **Take on a manifest another device wrote** (F7, 2026-09-23).
    ///
    /// The manifest is one object rewritten whole, so without this a window
    /// kept the copy it read at open for its whole life: a chapter another Mac
    /// added never appeared, and this Mac's next structural save wrote the
    /// stale copy over it. The master spec's rule is last-writer-wins with the
    /// loser kept in `.maugham/conflicts/`; this is the half that makes the
    /// incoming manifest the winner when it IS the later writer.
    ///
    /// **Never called during a structural verb.** Several verbs copy part of
    /// the structure, await file surgery and write the copy back afterwards
    /// (`moveStructureItem`, `tidyFilenames`, `movePiece`), so an adoption that
    /// landed during the wait would be undone and the incoming manifest lost
    /// with nothing archived. `DocumentStore` holds a manifest that arrives
    /// while `structuralVerbDepth > 0` and decides at `structuralVerbsSettled`
    /// who wrote last.
    ///
    /// Outside a verb there is no copy in flight, so the incoming manifest is
    /// always adopted. If this window holds a change that never reached disk (a
    /// verb whose save threw), the change is archived as the loser, so nothing
    /// is lost and the window does not stay out of step for ever.
    ///
    /// `schemaVersion` never falls here: it only rises within a session
    /// (`writeManifest`'s raise-only door, the narrowing gate), and an incoming
    /// lower number is the heal's to answer.
    ///
    /// Its one caller, `DocumentStore.handleManifestChanged`, has already
    /// refused a manifest from a later build (`decodeGuardingSchema`); a new
    /// caller must do the same, because nothing here checks the number.
    func adoptExternalManifest(_ incoming: ProjectManifest) -> ManifestAdoption {
        let previous = manifest
        let overUnsavedChange = !Self.sameIgnoringSchema(previous, settledManifest)
        var adopted = incoming
        adopted.schemaVersion = max(incoming.schemaVersion, previous.schemaVersion)
        manifest = adopted
        settledManifest = adopted
        let delta = refreshWordCounts(from: previous.structure, to: adopted.structure)
        return ManifestAdoption(
            previous: previous, adopted: adopted,
            replacedSomething: !Self.sameIgnoringSchema(previous, adopted),
            overUnsavedChange: overUnsavedChange,
            wordCountDelta: delta,
            moved: Self.moved(from: previous.structure, to: adopted.structure),
            removed: Self.removed(from: previous.structure, to: adopted.structure))
    }

    private static func moved(
        from old: [StructureItem], to new: [StructureItem]
    ) -> [ManifestAdoption.Moved] {
        let now = Dictionary(
            collectDocuments(in: new).compactMap { item in item.path.map { (item.id, $0) } },
            uniquingKeysWith: { first, _ in first })
        return collectDocuments(in: old).compactMap { item in
            guard let oldPath = item.path, let newPath = now[item.id],
                  newPath != oldPath else { return nil }
            return .init(id: item.id, oldPath: oldPath, newPath: newPath)
        }
    }

    private static func removed(
        from old: [StructureItem], to new: [StructureItem]
    ) -> [ManifestAdoption.Removed] {
        let now = Set(collectDocuments(in: new).map(\.id))
        return collectDocuments(in: old).compactMap { item in
            guard let oldPath = item.path, !now.contains(item.id) else { return nil }
            return .init(id: item.id, oldPath: oldPath, title: item.title)
        }
    }

    /// Enter a structural verb (F7 fix round, I1). Call it on the verb's first
    /// line, paired with `defer { endStructuralVerb() }`, before the verb reads
    /// anything from the manifest that it will write back.
    func beginStructuralVerb() {
        structuralVerbDepth += 1
    }

    /// Leave a structural verb. On the way out of the outermost one, the
    /// document store settles any manifest it held while the verb ran.
    func endStructuralVerb() {
        structuralVerbDepth -= 1
        if structuralVerbDepth == 0 {
            documentStore?.structuralVerbsSettled()
        }
    }

    /// **Every piece shows its true count** (Denver, 2026-09-23). A piece that
    /// arrived is counted from its op log; a piece that left is dropped from
    /// the cache. A piece that only moved keeps its id, so its count stays.
    /// Returns how far the project total moved.
    private func refreshWordCounts(
        from old: [StructureItem], to new: [StructureItem]
    ) -> Int {
        let before = projectWordCount
        let oldIds = Set(Self.collectDocuments(in: old).map(\.id))
        let newDocs = Self.collectDocuments(in: new)
        let newIds = Set(newDocs.map(\.id))
        for id in oldIds.subtracting(newIds) {
            forgetWordCount(forDocumentId: id)
        }
        for item in newDocs where !oldIds.contains(item.id) {
            if let count = derivedWordCount(of: item) {
                recordWordCount(forDocumentId: item.id, wordCount: count)
            }
        }
        return projectWordCount - before
    }

    private static func sameIgnoringSchema(
        _ a: ProjectManifest, _ b: ProjectManifest
    ) -> Bool {
        var a = a
        a.schemaVersion = b.schemaVersion
        return a == b
    }
}
