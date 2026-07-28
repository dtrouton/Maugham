import Foundation
import MaughamCore

/// What is being promoted.
enum PromotionSource: Equatable, Hashable {
    case scrap(CanvasNodeID)
    case region(CanvasRegionID)
    case line(CanvasLineID)
}

/// What it becomes. **This list IS spec §6's table** and must not grow without
/// amending the spec — every entry is a new durable artifact the writer can
/// create, and the whole design rests on that set being small and predictable.
enum PromotionTarget: String, Equatable, Hashable, CaseIterable, Identifiable {
    case researchNote
    case paletteCard
    case intentStatement
    case pieceBinding
    case wikiLink

    var id: String { rawValue }

    var writerFacingName: String {
        switch self {
        case .researchNote: return "Research note"
        case .paletteCard: return "Palette card"
        case .intentStatement: return "Craft intent"
        case .pieceBinding: return "Piece binding"
        case .wikiLink: return "Wiki-link"
        }
    }
}

/// New artifact, or rewrite the one this source produced last time.
///
/// **Neither is a default, and that is the ruling** (spec §6.1, 2026-07-28).
/// "Always update" eats edits the writer made in `research/`; "always new"
/// leaves `The falls at night 2`, `… 3` and two orphans nobody asked for. The
/// choice is one sentence of preview, which is what §6.1 already requires of
/// everything else here.
enum PromotionMode: Equatable, Hashable, Identifiable {
    case new
    case update(itemID: String, title: String)

    var id: String {
        switch self {
        case .new: return "new"
        case .update(let itemID, _): return "update:\(itemID)"
        }
    }
}

/// What promoting will throw away. Promotion is ALLOWED to be lossy and that is
/// a feature (§6.1) — the spatial work was thinking; it earned its keep by
/// producing the artifact. Scapple → Scrivener keeps notes and drops
/// connections, deliberately. The writer is told which, in the preview.
enum PromotionDiscard: Equatable, Hashable {
    case lines
    case layout
}

/// An offer to link an already-promoted member to the artifact being produced.
/// An OFFER — see `PromotionPlan.linksAccepted`.
struct PromotionLinkOffer: Equatable, Hashable, Identifiable {
    let node: CanvasNodeID
    /// The member's own artifact. Only promoted members can be offered: a link
    /// into a scrap has nowhere to be written.
    let itemID: String
    let title: String
    var id: CanvasNodeID { node }
}

/// The one durable write a line promotion makes.
struct WikiLinkWrite: Equatable {
    let intoNode: CanvasNodeID
    let intoItemID: String
    /// `[[Artifact title]] — the line's name`. The link names the ARTIFACT and
    /// never the card's first line: `[[X]]` resolves against the manifest, and a
    /// scrap is not in it.
    let linkText: String

    /// A blank line before, a newline after — so appending twice never runs two
    /// links together, and a note that did not end in a newline still parses.
    var appendedText: String { "\n\n" + linkText + "\n" }
}

/// Item id → title, for every research item in the project.
///
/// **This exists because the sidecar cannot validate a mark and never could.**
/// `CanvasNode.promotedItemID` is written by a promotion and read much later; a
/// writer who deletes the note leaves an id that resolves to nothing. Passing an
/// index rather than a `ProjectStore` keeps this whole file pure and testable,
/// and means the manifest is walked ONCE, when the sheet opens, rather than per
/// query.
struct ArtifactIndex: Equatable {
    private let titlesByID: [String: String]

    init(titlesByID: [String: String]) { self.titlesByID = titlesByID }

    static func over(research: [ResearchItem]) -> ArtifactIndex {
        ArtifactIndex(titlesByID: Dictionary(
            TreeWalk.collect(in: research, where: { _ in true }).map { ($0.id, $0.title) },
            uniquingKeysWith: { _, later in later }))
    }

    func title(of itemID: String) -> String? { titlesByID[itemID] }
}

/// Everything `Promotion.plan` needs. A struct rather than eight parameters,
/// because the sheet builds one and holds it, editing its fields as the writer
/// works.
struct PromotionRequest {
    let source: PromotionSource
    let target: PromotionTarget
    var mode: PromotionMode = .new
    var scraps: [CanvasNodeID: String]
    var piece: RegionInspector.PieceChoice?
    var paletteKind: PaletteCard.Kind = .other
    var artifacts: ArtifactIndex
    /// The destination artifact's body as read from disk when the target was
    /// chosen, for the wiki-link duplicate check. `nil` when not applicable or
    /// not read. **A snapshot** — the performer checks again against the live
    /// file, because this one can be stale by the time the writer commits.
    var destinationBody: String?

    init(source: PromotionSource,
         target: PromotionTarget,
         mode: PromotionMode = .new,
         scraps: [CanvasNodeID: String],
         piece: RegionInspector.PieceChoice? = nil,
         paletteKind: PaletteCard.Kind = .other,
         artifacts: ArtifactIndex,
         destinationBody: String? = nil) {
        self.source = source
        self.target = target
        self.mode = mode
        self.scraps = scraps
        self.piece = piece
        self.paletteKind = paletteKind
        self.artifacts = artifacts
        self.destinationBody = destinationBody
    }
}

/// The preview. The writer sees what will be produced, and where, before
/// committing — Scrivener's Commit is the model: a named command with a stated
/// rule and a predictable outcome (§6.1).
///
/// Building a plan NEVER mutates anything. That is what makes the preview
/// honest, and `test_planningNeverMutatesTheScene` pins it.
struct PromotionPlan: Equatable {
    let source: PromotionSource
    let producedKind: PromotionTarget
    /// The writer may edit this in the sheet before committing.
    var title: String
    let body: String
    /// Human-readable, shown verbatim: "research/", "the palette wall",
    /// "the note “The falls at night.”".
    let destinationDescription: String
    let discards: Set<PromotionDiscard>

    /// §6.1's "may suggest, must never impose". Promoting a region may *offer*
    /// to link its already-promoted members to the artifact it produced. That
    /// sits inside Shipman & Marshall's licence precisely BECAUSE the writer
    /// sees it and can decline it cheaply.
    let offeredLinks: [PromotionLinkOffer]

    /// Defaults to FALSE, always. The same inference applied silently is
    /// forbidden: membership is n-ary and vague, wiki-links are binary and
    /// specific, and a silent conversion manufactures precision the writer never
    /// claimed — into a layer with backlinks and rename propagation, where it is
    /// expensive to undo.
    var linksAccepted = false

    let wikiLinkWrite: WikiLinkWrite?
    let pieceID: String?
    let mode: PromotionMode
    let paletteKind: PaletteCard.Kind

    /// True when the link this plan would write is already in the destination.
    /// The sheet says so and refuses; the performer refuses too, against the
    /// live file.
    let linkAlreadyPresent: Bool
}

enum Promotion {

    /// The targets whose artifact is a single rewritable document. The craft
    /// intent is deliberately absent: it ACCUMULATES — one doc per scope — so an
    /// "update" would mean replacing the writer's whole intent statement.
    static let updatableTargets: Set<PromotionTarget> = [.researchNote, .paletteCard]

    // MARK: - §6's table

    static func targets(for source: PromotionSource,
                        in scene: CanvasScene,
                        artifacts: ArtifactIndex) -> [PromotionTarget] {
        switch source {
        case .scrap(let id):
            // Only scraps promote. An item already exists as itself; promoting
            // it would duplicate it, and two editable copies of one note is
            // exactly what §4.3 rejects.
            guard case .scrap = scene.node(id)?.kind else { return [] }
            return [.researchNote, .paletteCard, .intentStatement]

        case .region(let id):
            guard scene.region(id) != nil else { return [] }
            return [.paletteCard, .pieceBinding]

        case .line(let id):
            guard let line = scene.line(id),
                  resolvedArtifact(of: line.from, in: scene, artifacts: artifacts) != nil,
                  resolvedArtifact(of: line.to, in: scene, artifacts: artifacts) != nil
            else { return [] }
            return [.wikiLink]
        }
    }

    /// Why a source offers nothing, in words a writer can act on. Only lines
    /// have an interesting answer; everything else returns nil and the sheet
    /// simply shows the targets.
    static func blockedReason(for source: PromotionSource,
                              in scene: CanvasScene,
                              artifacts: ArtifactIndex) -> String? {
        guard case .line(let id) = source, let line = scene.line(id),
              targets(for: source, in: scene, artifacts: artifacts).isEmpty else { return nil }
        guard isScrap(line.from, in: scene) && isScrap(line.to, in: scene) else {
            return "A line becomes a wiki-link only between two cards of text."
        }
        // The precedence rule, taught at the moment it costs something: the
        // durable layer is reached by promoting the things first.
        return "Promote both cards first. A wiki-link has to point at something "
            + "that exists outside the canvas — a canvas line is scratch."
    }

    // MARK: - Update or New

    /// The artifact this source produced last time, when it still exists AND the
    /// target is one that can be rewritten.
    static func existingArtifact(for source: PromotionSource,
                                 target: PromotionTarget,
                                 in scene: CanvasScene,
                                 artifacts: ArtifactIndex) -> PromotionMode? {
        guard updatableTargets.contains(target) else { return nil }
        let markedID: String?
        switch source {
        case .scrap(let id): markedID = scene.node(id)?.promotedItemID
        case .region(let id): markedID = scene.region(id)?.promotedItemID
        case .line: markedID = nil
        }
        guard let markedID, let title = artifacts.title(of: markedID) else { return nil }
        return .update(itemID: markedID, title: title)
    }

    /// `.new` first, always — so a sheet that renders these in order cannot make
    /// "rewrite the writer's note" the thing sitting under the cursor.
    static func modes(for target: PromotionTarget, existing: PromotionMode?) -> [PromotionMode] {
        guard let existing, updatableTargets.contains(target) else { return [.new] }
        return [.new, existing]
    }

    // MARK: - The plan

    static func plan(_ request: PromotionRequest, in scene: CanvasScene) -> PromotionPlan? {
        guard targets(for: request.source, in: scene, artifacts: request.artifacts)
                .contains(request.target) else { return nil }

        switch request.source {
        case .scrap(let id):
            let body = text(of: id, in: request.scraps)
            guard !body.isEmpty else { return nil }
            return PromotionPlan(
                source: request.source, producedKind: request.target,
                title: title(from: body), body: body,
                destinationDescription: destination(request),
                discards: [], offeredLinks: [], wikiLinkWrite: nil, pieceID: nil,
                mode: request.mode, paletteKind: request.paletteKind,
                linkAlreadyPresent: false)

        case .region(let id):
            guard let region = scene.region(id) else { return nil }
            if request.target == .pieceBinding {
                guard let piece = request.piece else { return nil }
                return PromotionPlan(
                    source: request.source, producedKind: request.target,
                    title: regionTitle(region), body: "",
                    destinationDescription: destination(request),
                    // Binding drops nothing: the region stays exactly as it is.
                    discards: [], offeredLinks: [], wikiLinkWrite: nil,
                    pieceID: piece.id, mode: .new, paletteKind: request.paletteKind,
                    linkAlreadyPresent: false)
            }
            let members = readingOrder(region.homeMembers, in: scene)
            let bodies = members.compactMap { nodeID -> (CanvasNodeID, String)? in
                let t = text(of: nodeID, in: request.scraps)
                return t.isEmpty ? nil : (nodeID, t)
            }
            return PromotionPlan(
                source: request.source, producedKind: request.target,
                title: regionTitle(region),
                body: bodies.map(\.1).joined(separator: "\n\n"),
                destinationDescription: destination(request),
                // The spatial work is not carried across, and the writer is told.
                discards: [.lines, .layout],
                offeredLinks: bodies.compactMap { nodeID, _ in
                    guard let itemID = resolvedArtifact(of: nodeID, in: scene,
                                                        artifacts: request.artifacts),
                          let title = request.artifacts.title(of: itemID) else { return nil }
                    return PromotionLinkOffer(node: nodeID, itemID: itemID, title: title)
                },
                wikiLinkWrite: nil, pieceID: nil, mode: request.mode,
                paletteKind: request.paletteKind, linkAlreadyPresent: false)

        case .line(let id):
            guard let line = scene.line(id),
                  let fromItem = resolvedArtifact(of: line.from, in: scene,
                                                  artifacts: request.artifacts),
                  let toItem = resolvedArtifact(of: line.to, in: scene,
                                                artifacts: request.artifacts),
                  let fromTitle = request.artifacts.title(of: fromItem),
                  let toTitle = request.artifacts.title(of: toItem) else { return nil }
            let write = WikiLinkWrite(intoNode: line.from, intoItemID: fromItem,
                                      linkText: linkText(to: toTitle, label: line.label))
            return PromotionPlan(
                source: request.source, producedKind: request.target,
                title: fromTitle, body: write.linkText,
                destinationDescription: "the note “\(fromTitle)”",
                discards: [], offeredLinks: [], wikiLinkWrite: write, pieceID: nil,
                mode: .new, paletteKind: request.paletteKind,
                linkAlreadyPresent: request.destinationBody?.contains(write.linkText) ?? false)
        }
    }

    // MARK: - Pieces

    static func title(from body: String) -> String {
        body.split(separator: "\n", omittingEmptySubsequences: true).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    /// `[[Title]]`, plus the line's own name when it has one. An em dash rather
    /// than a colon, matching the guide's prose voice.
    static func linkText(to title: String, label: String?) -> String {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return "[[\(title)]]" }
        return "[[\(title)]] — \(trimmed)"
    }

    private static func isScrap(_ id: CanvasNodeID, in scene: CanvasScene) -> Bool {
        if case .scrap = scene.node(id)?.kind { return true }
        return false
    }

    /// The node's artifact, when it is a scrap, HAS a mark, and that mark still
    /// names something in the project. All three conditions matter — the third
    /// is the dangling mark, and it is the only one the scene cannot see.
    private static func resolvedArtifact(of id: CanvasNodeID,
                                         in scene: CanvasScene,
                                         artifacts: ArtifactIndex) -> String? {
        guard let node = scene.node(id), case .scrap = node.kind,
              let itemID = node.promotedItemID,
              artifacts.title(of: itemID) != nil else { return nil }
        return itemID
    }

    private static func text(of id: CanvasNodeID, in scraps: [CanvasNodeID: String]) -> String {
        (scraps[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Regions are created unlabelled and named in the inspector, so this is the
    /// common case for the first minute of a region's life. An untitled palette
    /// card is unfindable on the wall.
    private static func regionTitle(_ region: CanvasRegion) -> String {
        let trimmed = region.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? CanvasRegion.untitledLabel : trimmed
    }

    /// Top to bottom, then left to right, then by id.
    ///
    /// **Spatial and not id order**, because the writer arranged these cards and
    /// the joined text should read the way the region reads. The id tiebreak is
    /// not decoration: two cards at the same origin would otherwise let a `Set`'s
    /// iteration order decide, and that differs between runs of the same binary.
    private static func readingOrder(_ ids: Set<CanvasNodeID>,
                                     in scene: CanvasScene) -> [CanvasNodeID] {
        ids.compactMap { scene.node($0) }
            .sorted { a, b in
                if a.origin.y != b.origin.y { return a.origin.y < b.origin.y }
                if a.origin.x != b.origin.x { return a.origin.x < b.origin.x }
                return a.id.raw < b.id.raw
            }
            .map(\.id)
    }

    private static func destination(_ request: PromotionRequest) -> String {
        if case .update(_, let title) = request.mode,
           updatableTargets.contains(request.target) {
            return "the existing “\(title)”"
        }
        switch request.target {
        case .researchNote: return "research/"
        case .paletteCard: return "the palette wall"
        case .intentStatement: return "the project's craft intent"
        case .pieceBinding: return "the piece “\(request.piece?.title ?? "")”"
        case .wikiLink: return ""   // replaced per-plan above
        }
    }
}
