import SwiftUI
import AppKit
import MaughamCore

/// **A canvas region pulled up beside the centre** (owner, 2026-11-20: "if I
/// add a region I get the region as super group which can be opened then in
/// right panel"). Its cards read down the column in the canvas's visual
/// order: a scrap's whole words, an owned picture scaled to the column, a
/// research or palette card (a table included) as its title row, which pulls
/// that item up instead.
///
/// **One ordering.** The members are `PinnedReferences.readingOrder(ofRegion:in:)`,
/// the shelf's own, so the fold's region row and this view never disagree
/// about the order. A region the writer promoted to a note shows that note
/// first, as its title row (the region became it, the shelf's §2.3), then
/// its cards — and the fold's region row holds the same (review M2,
/// `PinnedReferences.pinned`'s `promotedRegionsListTheirCards`).
///
/// **Read-only, as a pulled-up card is** (`PulledUp.isEditableBeside`): a
/// scrap's words live in the canvas's shared text storage, and a second
/// editor on them is the tripwires 26–28 risk. Open in Centre opens the
/// canvas and selects the region.
///
/// **A leaf, so the column reads no canvas.** It reads the scene in a `.task`
/// keyed on the canvas's STRUCTURAL revision (never the per-frame counter,
/// tripwire 30), Claude's closed-canvas writes (the fold's signal,
/// `CanvasCardsRevision`) and the manifest's stamp, and follows a scrap being typed on
/// the attached canvas through `CanvasModel.scraps`, as a pulled-up scrap does
/// (`PulledUpView.liveCard`).
struct PulledUpRegionView: View {
    let store: ProjectStore
    let model: CanvasModel
    let regionId: String
    let openInCentre: () -> Void
    let close: () -> Void
    /// A title row's click: that item is pulled up in the region's place.
    let pullUp: (PulledUp) -> Void
    /// The window's count of Claude's writes into a closed canvas: with the
    /// scene revision, the fold's own refresh signal (`CanvasCardsRevision`).
    var closedCanvasWrites: Int = 0
    /// The header's Back (`PulledUpHistory`); nil hides it.
    var back: (() -> Void)? = nil
    var backTitle: String = ""

    @State private var read: Read?
    /// Owned pictures, decoded off the main actor in the `.task`, never in
    /// `body`, at no more than the column's size (`pictureCapPoints`).
    @State private var images: [String: NSImage] = [:]

    // MARK: - The decisions, pure

    /// One card of the region, as the column draws it.
    enum Member: Equatable, Identifiable {
        case scrap(nodeId: String, text: String)
        case picture(path: String)
        /// A research item or palette card: a title row. `resolves` is false
        /// for a card whose item left the project; its row is not a control.
        case item(id: String, title: String, glyph: String, resolves: Bool)

        var id: String {
            switch self {
            case .scrap(let nodeId, _): return "scrap:\(nodeId)"
            case .picture(let path): return "picture:\(path)"
            case .item(let id, _, _, _): return "item:\(id)"
            }
        }

        /// What its click pulls up; nil for a scrap, a picture and a gone item.
        var pulledUp: PulledUp? {
            guard case .item(let id, _, _, true) = self else { return nil }
            return .research(id)
        }
    }

    enum Read: Equatable {
        case region(title: String, members: [Member])
        /// No longer on the canvas.
        case missing
    }

    /// The region against a scene. Pure.
    static func read(_ regionId: String, scene: CanvasScene,
                     scraps: [CanvasNodeID: String], items: CanvasItemIndex) -> Read {
        guard let region = scene.region(CanvasRegionID(regionId)) else { return .missing }
        var members: [Member] = []
        var seen = Set<String>()
        func item(_ id: String) {
            guard seen.insert(id).inserted else { return }
            let facts = CanvasItemFacts.resolve(.project(id: id), in: items)
            members.append(.item(id: id, title: facts.title, glyph: facts.glyph,
                                 resolves: items.entry(of: id) != nil))
        }
        if let promoted = region.promotedItemID, items.entry(of: promoted) != nil {
            item(promoted)
        }
        for id in PinnedReferences.readingOrder(ofRegion: region.id, in: scene) {
            guard let node = scene.node(id) else { continue }
            switch node.kind {
            case .scrap:
                members.append(.scrap(nodeId: id.raw, text: scraps[id] ?? ""))
            case .item(.owned(let path)):
                members.append(.picture(path: path))
            case .item(.project(let referenceID)):
                item(referenceID)
            }
        }
        return .region(title: Promotion.regionTitle(region), members: members)
    }

    /// **The scrap the writer is typing on the canvas, as they type it**: an
    /// attached canvas folds every keystroke into `scraps` (tripwire 28),
    /// observably, so the words beside read it there.
    @MainActor
    static func live(_ read: Read?, model: CanvasModel) -> Read? {
        guard model.isAttached, case .region(let title, let members)? = read else { return read }
        return .region(title: title, members: members.map { member in
            guard case .scrap(let nodeId, _) = member,
                  let text = model.scraps[CanvasNodeID(nodeId)] else { return member }
            return .scrap(nodeId: nodeId, text: text)
        })
    }

    /// The header's title: the region's, else the kind's own word.
    static func title(of read: Read?) -> String {
        guard case .region(let title, _)? = read else { return PulledUpView.canvasRegionTitle }
        return title
    }

    static let missingRegionLine = "This region is no longer on the canvas."
    static let emptyRegionLine = "This region holds no cards."

    // MARK: - The view

    private struct ReadKey: Equatable {
        let regionId: String
        let canvas: CanvasCardsRevision
        let manifestModified: Date
    }

    var body: some View {
        let shown = Self.live(read, model: model)
        VStack(spacing: 0) {
            BesideHeader(title: Self.title(of: shown), openInCentre: openInCentre, close: close,
                         back: back, backTitle: backTitle)
            Divider()
            content(shown)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: ReadKey(regionId: regionId,
                          canvas: CanvasCardsRevision(sceneRevision: model.sceneRevision,
                                                      closedCanvasWrites: closedCanvasWrites),
                          manifestModified: store.manifest.modified)) {
            let scene = CanvasClaudeWrite.readScene(store: store, projectRoot: store.url)
            let next = Self.read(regionId, scene: scene.scene, scraps: scene.scraps,
                                 items: CanvasItemIndex.over(research: store.manifest.research))
            read = next
            await loadImages(for: next)
        }
    }

    @ViewBuilder
    private func content(_ shown: Read?) -> some View {
        switch shown {
        case nil:
            Color.clear
        case .missing?:
            VStack(spacing: 0) {
                ContentUnavailableView {
                    Label(Self.missingRegionLine, systemImage: CanvasItemKind.missingGlyph)
                } actions: {
                    Button(BesideHeader.closeLabel, action: close)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        case .region(_, let members)?:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if members.isEmpty { quiet(Self.emptyRegionLine) }
                    ForEach(members) { member in
                        memberView(member)
                    }
                    quiet(PulledUpView.readOnlyCardLine)
                }
                .padding(16)
            }
        }
    }

    @ViewBuilder
    private func memberView(_ member: Member) -> some View {
        switch member {
        case .scrap(_, let text):
            if text.isEmpty {
                quiet(CanvasAccessibility.emptyScrapValue)
            } else {
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .picture(let path):
            if let image = images[path] {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(CanvasItemFacts.ownedTitle)
            } else {
                Label(CanvasItemFacts.ownedTitle, systemImage: CanvasItemKind.image.glyph)
                    .foregroundStyle(.secondary)
            }
        case .item(_, let title, let glyph, _):
            if let pulled = member.pulledUp {
                // A plain button (tripwire 9's shape): the item is pulled up.
                Button { pullUp(pulled) } label: {
                    itemLabel(title: title, glyph: glyph)
                }
                .buttonStyle(.plain)
                .help("Pull up \(title)")
            } else {
                itemLabel(title: title, glyph: glyph)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func itemLabel(title: String, glyph: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: glyph)
                .imageScale(.small)
                .foregroundStyle(.secondary)
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func quiet(_ line: String) -> some View {
        Text(line)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The widest a picture here is drawn, in points — wider than the right
    /// column is ever dragged — and so the most it is decoded to.
    static let pictureCapPoints: CGFloat = 800

    /// Decodes the region's owned pictures not already held, OFF the main
    /// actor through the canvas's one decoder (`CanvasThumbnails.decode`, its
    /// decompression-bomb gate included) at the column's size, as
    /// `RowThumbnails` does (review M8); drops the ones the region no longer
    /// holds.
    private func loadImages(for read: Read) async {
        guard case .region(_, let members) = read else { images = [:]; return }
        let paths = Set(members.compactMap { member -> String? in
            if case .picture(let path) = member { return path }
            return nil
        })
        var next = images.filter { paths.contains($0.key) }
        let wanted: [(path: String, url: URL)] = paths.filter { next[$0] == nil }.compactMap { path in
            (try? SafeRelativePath.resolve(path, under: store.url)).map { (path, $0) }
        }
        if !wanted.isEmpty {
            let pixels = Int((Self.pictureCapPoints * CanvasThumbnails.assumedPixelScale).rounded(.up))
            let decoded = await Task.detached(priority: .utility) {
                wanted.compactMap { item -> (String, CGImage)? in
                    CanvasThumbnails.decode(item.url, maxPixelSize: pixels).map { (item.path, $0) }
                }
            }.value
            guard !Task.isCancelled else { return }
            for (path, image) in decoded {
                next[path] = NSImage(cgImage: image, size: .zero)
            }
        }
        if next.keys != images.keys { images = next }
    }
}
