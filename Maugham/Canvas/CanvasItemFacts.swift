import Foundation
import MaughamCore

/// What an item node SAYS it is (spec §8A.1): a title, a kind glyph, and the
/// picture to draw when there is one.
///
/// **Three facts and no fourth.** The renderer draws them and the inspector
/// names them, and neither is told anything it would have to switch on. A
/// caller that needs to *act* differently on a deleted reference — to withhold
/// an **Open in Research** button, say — asks `CanvasItemIndex`, which is the
/// thing that knows; it must not read the state back out of these strings.
///
/// **Pure, and handed its lookup rather than reaching for it** — `Promotion`
/// and `ArtifactIndex`'s shape, for their reason. A `ProjectStore` read from a
/// `body`, or from anything a `body` calls, is the failure `CanvasAuthorLine`
/// documents at length; here it would be worse, because this is resolved per
/// item node rather than per selection.
struct CanvasItemFacts: Equatable, Sendable {

    /// What the card is called. Never an id, in any arm — see `missingTitle`.
    let title: String

    /// An SF Symbol name. **A string because that is what `Image(systemName:)`
    /// takes**; the set it is drawn from is `CanvasItemKind.glyph`, and this
    /// type does not re-decide it.
    let glyph: String

    /// **PROJECT-RELATIVE**, which is what `CanvasThumbnails` takes (it is
    /// handed the project URL alongside). Absolute would key the thumbnail
    /// cache on a string that differs between Macs and break the moment the
    /// project moved — `CanvasItemReference.owned`'s doc comment spells out the
    /// same rule for the same reason.
    ///
    /// Nil for everything that is not a picture. A path here for a note or a
    /// PDF would queue a decode that can only fail, and `CanvasThumbnails`
    /// memoises failures — one permanent dead entry per note on the canvas.
    let thumbnailPath: String?

    // MARK: - The two titles that are not a manifest's

    /// **A referenced item that is not in the manifest: a sentence, not an id.**
    /// The writer deleted the note; `Item · res-3f2a` on a card is a code, and
    /// `PromotedArtifactSection.contributionArtifactMissing` — "This card's
    /// words went into something that is no longer in the project." — is the
    /// register this matches rather than inventing a second voice.
    ///
    /// **The subject is elided deliberately**, and the alternatives were
    /// weighed rather than skipped. This string is drawn as a ONE-LINE card
    /// label (`CanvasCardMetrics.itemLabelOnlyHeight` is one line at
    /// `itemLabelFontSize`) as well as read in the pane, so length is not free:
    /// "What this points at is no longer in the project." truncates on a
    /// default-width card to something less useful than nothing, and "This is
    /// no longer in the project." fits but says the wrong thing — the card is
    /// still there, and what it points at is not. Dropping the subject leaves
    /// the predicate the precedent already uses, on a card the writer is
    /// looking at, which supplies the subject the sentence does not.
    static let missingTitle = "No longer in the project."

    /// **An owned image has no manifest entry and never will, so its title is a
    /// fixed noun — and the reason is that the filename carries nothing.**
    ///
    /// `ProjectStore.ingestCanvasAsset` copies the file into `canvas_assets/`
    /// under a minted name (`ImagePasteHandler.destination`:
    /// `image-yyyyMMdd-HHmmss.<ext>`, deduped with a counter). The writer's own
    /// filename is discarded at ingest and never recorded anywhere, so
    /// "the filename" is not the writer's word for the picture — it is the
    /// clock reading at the moment they dropped it. A card reading
    /// `image-20260730-220430.png` is the storage answer to a question about
    /// content, which is the failure the 1C-d plan names for the *path* arriving
    /// through the filename instead.
    ///
    /// **What identifies one owned card from another is the picture**, which is
    /// drawn on it — so a shelf of cards all titled "Image" is not the ambiguity
    /// it looks like on paper. "Image" is also the noun this app already uses
    /// for the kind (`InspectorResearchPanel`), not a coinage.
    ///
    /// *Falsification:* if ingest is ever changed to preserve the source
    /// filename, this decision is void and the filename is the better title.
    static let ownedTitle = "Image"

    // MARK: - Resolving

    /// **One entry point for both provenances**, so no caller can pick the
    /// wrong one. The index is taken even by the arm that cannot use it: an
    /// owned image resolves against an empty index, which is the test that
    /// states "needs no manifest" most strongly.
    static func resolve(_ reference: CanvasItemReference,
                        in index: CanvasItemIndex) -> CanvasItemFacts {
        switch reference {
        case .owned(let path):
            return CanvasItemFacts(title: ownedTitle,
                                   glyph: CanvasItemKind.image.glyph,
                                   thumbnailPath: path)
        case .project(let id):
            guard let entry = index.entry(of: id) else {
                return CanvasItemFacts(title: missingTitle,
                                       glyph: CanvasItemKind.missingGlyph,
                                       thumbnailPath: nil)
            }
            return CanvasItemFacts(title: entry.title,
                                   glyph: entry.kind.glyph,
                                   thumbnailPath: entry.thumbnailPath)
        }
    }
}

/// What a referenced item IS, in the terms the canvas needs to draw one glyph.
///
/// **Not `ArtifactKind`, and not `ResearchItem.AssetKind`.** `ArtifactKind`
/// (`Promotion.swift`) is a *promotion-target* vocabulary — note / palette card
/// / craft intent — whose whole job is deciding whether a mark may be
/// overwritten, and it has no case for a photograph because a promotion never
/// produces one. `AssetKind` has the photograph and not the palette card, which
/// is not a `kind` in the manifest at all but a position in the tree
/// (`PaletteLookup.paletteCards`, which this file's own `over(research:)` calls
/// twenty lines down — the name here read `PaletteConvention` for one commit,
/// which is a *different* enum in the same file with no such member). This is
/// the union the canvas actually draws from, which is neither.
/// **`String`-backed since 1C-d Task 5's fix round**, so `CanvasItemIndex`'s
/// fingerprint can name a kind without `String(describing:)` reflection. The raw
/// values are never written to disk and never parsed — nothing decodes this — so
/// they are free to follow the case names.
enum CanvasItemKind: String, Equatable, Hashable, Sendable, CaseIterable {
    case researchNote
    case paletteCard
    case image
    case pdf
    case audio
    case link
    /// A research GROUP. It resolves rather than reading as deleted — it is in
    /// the project, and "no longer in the project" said over a folder the
    /// writer can see in the binder is a lie the canvas has no business telling.
    case group

    /// **A fifth spelling of the research glyph table, and recorded as such
    /// rather than pretended away.** `ResearchRow`, `LinkedResearchRow`,
    /// `ResearchLinkPickerSheet` and `InboxPane` each carry their own, and they
    /// already disagree with one another (audio is `speaker.wave.2` in one and
    /// `waveform` in another; a missing kind is `questionmark.circle` in one and
    /// `folder` in another) — so there is no single existing spelling to reuse,
    /// only a choice of which to copy. This one has two cases none of them has
    /// (a palette card, and a reference to nothing) and is read by a `Canvas`
    /// draw pass rather than by a row, so it is written here and the symbol
    /// names are taken from the closest existing surface: `paintpalette` is what
    /// every palette surface in the app already uses.
    ///
    /// Unifying the five is a real cleanup and it is not this task's; doing it
    /// here would put four view files in a canvas diff.
    var glyph: String {
        switch self {
        case .researchNote: return "doc.text"
        case .paletteCard:  return "paintpalette"
        case .image:        return "photo"
        case .pdf:          return "doc.richtext"
        case .audio:        return "waveform"
        case .link:         return "link"
        case .group:        return "folder"
        }
    }

    /// The glyph for a reference to something the writer deleted. **Not a case
    /// on this enum**: missing is the absence of an entry, and a case for it
    /// would be a value somebody could construct and store.
    static let missingGlyph = "questionmark.square.dashed"
}

/// Item id → what it is called, what it is, and where its picture lives, for
/// every research item in the project.
///
/// **`ArtifactIndex`'s shape and its reason, and deliberately not
/// `ArtifactIndex` itself.** That index answers a promotion's question — may
/// this mark be overwritten, and by what — and its `Entry` is a title plus an
/// `ArtifactKind`. This one needs a **path** and a photograph's kind, and
/// neither belongs on a type whose callers are deciding whether to rewrite an
/// artifact: a path on that `Entry` is an invitation to resolve a promotion
/// target by filename, which is exactly the legacy fallback
/// `PaletteLookup` keeps behind a role check. Two indexes over one manifest is
/// the cost, and it is one walk each at the same construction site.
///
/// **Built ONCE per manifest change and passed in.** The construction site is
/// `ProjectWindow`, beside `pieceChoices` and on the same terms its doc comment
/// sets out: that body reads `store.manifest` and so re-evaluates when the
/// manifest changes, and it does *not* read `model.scene`, so it is not on the
/// canvas's drag loop. Building it inside `CanvasView` instead — or resolving
/// per node in a draw closure — is tripwire 4: a per-row manifest walk that
/// went O(N²) on a binder click in 3d and produced visible pauses.
struct CanvasItemIndex: Equatable, Sendable {

    struct Entry: Equatable, Hashable, Sendable {
        let title: String
        let kind: CanvasItemKind
        /// Set only for a kind that HAS pixels — see `CanvasItemFacts`.
        let thumbnailPath: String?

        init(title: String, kind: CanvasItemKind, thumbnailPath: String? = nil) {
            self.title = title
            self.kind = kind
            self.thumbnailPath = thumbnailPath
        }
    }

    private let entriesByID: [String: Entry]

    /// **The manifest half of the cache key, and the part of this task most
    /// likely to be got subtly wrong.**
    ///
    /// The key a caller caches resolved facts against is
    /// `(CanvasModel.sceneRevision, index.fingerprint)` — an `Int` and a 16-char
    /// hex string, so comparing it costs nothing on a body that re-evaluates per
    /// frame. Both halves are load-bearing:
    ///
    /// - **`sceneRevision` alone is wrong.** The writer renames the research
    ///   note a card points at and nothing on the canvas moves, so the counter
    ///   does not budge and the card shows the old title for the rest of the
    ///   session.
    /// - **The fingerprint alone is wrong.** A new item node added to the scene
    ///   changes no manifest fact, and its facts would never be resolved.
    ///
    /// **Content-derived, and not a counter bumped on each rebuild.** The index
    /// is rebuilt on the window's body path, so a counter minted at build time
    /// would move on every pass and the cache would hold nothing — the whole
    /// mechanism would be dead with nothing red. Being content-derived also
    /// makes it *narrower* than a manifest-save counter: a change to something
    /// these facts do not read (a tag, a link, a caption) leaves it alone and
    /// the cache survives, which a counter on `ProjectStore` could not do.
    ///
    /// **Watch it, rather than the index itself.** `.onChange(of: index)`
    /// compiles and reads correctly and compares a whole dictionary — every
    /// entry, every title — on every body pass, which on this surface means every
    /// frame of every drag and coast. That is not tripwire 30 (this comment said
    /// it was, for one commit): tripwire 30 is specifically about keying
    /// scene-proportional work off `CanvasView.revision`, the per-frame REDRAW
    /// counter. The kinship is real and the rule is not — what is wrong with a
    /// per-frame dictionary comparison is its cost, not its key — so the fix is
    /// the same one either way: compare two scalars.
    ///
    /// **`StableHash.fnv1a64Hex`, not `hashValue`, and the reason is not that
    /// this value is persisted — it is that nothing here needed seeding.** It was
    /// `entriesByID.hashValue` for one commit, which is process-seeded (SE-0206),
    /// which meant the same manifest fingerprinted differently on every launch
    /// and the whole thing had to be caveated "in-memory only" — and it meant
    /// widening `TripwireGrepTests.test_noHashValueInPersistedIdConstruction`,
    /// load-bearing since the 2026-06-07 audit, to let it through. That is a
    /// permanent hole in a tripwire bought for a value that can simply use the
    /// thing the tripwire tells you to use. **Same O(n), same code path, one walk
    /// of the same entries** — and this fingerprint is now stable across
    /// launches, which costs nothing and closes a caveat.
    ///
    /// **Sorted by id before hashing, and that is not tidiness.** `Dictionary`
    /// iteration order is seeded per process, so hashing the entries in
    /// dictionary order would give one manifest a different fingerprint on every
    /// rebuild — the cache would hold nothing and `.onChange` would fire on every
    /// pass, with nothing red. `CanvasMembership.homeRegion` is the same fact
    /// costing a different bug, in a third id space.
    let fingerprint: String

    init(entriesByID: [String: Entry]) {
        self.entriesByID = entriesByID
        // The separators are control characters so no title, path or id can spell
        // one and make two different manifests hash alike.
        self.fingerprint = StableHash.fnv1a64Hex(
            entriesByID.sorted { $0.key < $1.key }
                .map { id, entry in
                    [id, entry.title, entry.kind.rawValue, entry.thumbnailPath ?? ""]
                        .joined(separator: "\u{1}")
                }
                .joined(separator: "\u{2}"))
    }

    /// No project behind it: every referenced item resolves to `missingTitle`, and
    /// an owned image resolves in full because it never needed a manifest.
    ///
    /// It is what a canvas hosted without a window has, which is a real state —
    /// see `CanvasItemPresentation.empty`.
    static let empty = CanvasItemIndex(entriesByID: [:])

    /// One walk of the manifest, and it collects **everything** — groups
    /// included, so an item node pointing at a group resolves rather than
    /// reading as deleted.
    static func over(research: [ResearchItem]) -> CanvasItemIndex {
        // `PaletteLookup` is the ONE definition of "which research items are
        // palette cards" (tripwire 19), exactly as `ArtifactIndex.over` reads
        // it — a local predicate here would be the next surface spelling it.
        let paletteCards = Set(PaletteLookup.paletteCards(in: research).map(\.id))
        return CanvasItemIndex(entriesByID: Dictionary(
            TreeWalk.collect(in: research, where: { _ in true }).map { item in
                let kind = kind(of: item, paletteCards: paletteCards)
                return (item.id, Entry(title: item.title, kind: kind,
                                       thumbnailPath: kind == .image ? item.path : nil))
            },
            uniquingKeysWith: { _, later in later }))
    }

    /// Position first, then the manifest's own `kind`. A palette card is an
    /// ordinary `.document` asset that happens to live under the palette group,
    /// so nothing on the item itself distinguishes it — which is the same fact
    /// that made a title-only `ArtifactIndex` resolve every mark for every
    /// target (`ArtifactIndex`'s doc comment).
    private static func kind(of item: ResearchItem,
                             paletteCards: Set<String>) -> CanvasItemKind {
        if paletteCards.contains(item.id) { return .paletteCard }
        if item.type == .group { return .group }
        switch item.kind {
        case .image:    return .image
        case .pdf:      return .pdf
        case .audio:    return .audio
        case .link:     return .link
        // `.document` and a nil kind alike. Nil is the legacy manifest's
        // spelling and `AssetKind`'s own forward-tolerance degrades an unknown
        // kind to `.document` (ADR 0015), so both land on the same noun the
        // manifest would give them today.
        case .document, .none: return .researchNote
        }
    }

    func entry(of itemID: String) -> Entry? { entriesByID[itemID] }
}
