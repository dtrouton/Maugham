import SwiftUI
import CoreGraphics
import ImageIO
import MaughamCore

/// **The small pictures on list rows** — a picture's row in the tree (a
/// canvas picture or a research image in a piece's fold, an image in the
/// Research section) and an image capture's row in the Inbox (owner,
/// 2026-11-20). One cache for both, one per process (`shared`).
///
/// - **The decode is the canvas's** (`CanvasThumbnails.decode`): ImageIO's
///   thumbnailer at a capped pixel size, EXIF orientation applied, the
///   decompression-bomb gate. A second decoder would be a second answer about
///   what a picture looks like.
/// - **Keyed on the file's path, modification date and size**, so a picture
///   replaced at the same path decodes afresh the next time its row asks; the
///   stale entry for that path is dropped when the new one lands. The canvas's
///   cache keys on the path alone, which suits a surface that never outlives a
///   file change; a row does.
/// - **Bounded in count** (`defaultEntryBudget`) and least-recently-used; with
///   every request capped at `maxPixelSize`, the count is the memory bound.
/// - **Nothing touches the disk on the main actor.** The stat that builds the
///   key and the decode both run detached; a row draws its glyph until the
///   picture arrives (`RowThumbnail`), in a fixed box, so nothing moves.
/// - A missing file is not cached (its row asks again when it next appears);
///   a file that will not decode is cached as nothing, so it is not retried
///   until it changes.
@MainActor
final class RowThumbnails {

    static let shared = RowThumbnails()

    /// How many thumbnails are held. At `maxPixelSize` a thumbnail is at most
    /// 64 KB, so the whole cache is at most 16 MB.
    nonisolated static let defaultEntryBudget = 256

    /// No request decodes larger than this, whatever a caller asks.
    nonisolated static let maxPixelSize = 128

    /// What a row's picture is: a relative path under a root, as the data
    /// names it — a research image or a canvas-owned picture under the
    /// project, an Inbox capture's asset under its kind's folder. Resolved
    /// through `SafeRelativePath` off the main actor (tripwire 58; the
    /// resolve reads symlinks), so a row never builds a path by hand.
    struct Source: Hashable {
        let path: String
        let root: URL

        /// The file on disk, or nil when the path would leave its root.
        /// Touches the disk.
        nonisolated func resolved() -> URL? {
            try? SafeRelativePath.resolve(path, under: root)
        }
    }

    /// One thumbnail's identity: the file, as it is now, at one size.
    struct Key: Hashable {
        let path: String
        let modified: Date?
        let size: Int?
        let pixels: Int
    }

    private struct Entry {
        let image: CGImage?
        var lastUsed: UInt64
    }

    private var entries: [Key: Entry] = [:]
    private var inFlight: [Key: Task<CGImage?, Never>] = [:]
    private var clock: UInt64 = 0
    private let entryBudget: Int

    /// Decode attempts, including the ones that produced nothing — what the
    /// tests count instead of timing anything.
    private(set) var decodeCount = 0

    var count: Int { entries.count }

    init(entryBudget: Int = RowThumbnails.defaultEntryBudget) {
        self.entryBudget = max(1, entryBudget)
    }

    /// The key for `url` at `points` on a 2× display, read from the file's
    /// attributes; nil when there is no file. Touches the disk: call it off
    /// the main actor.
    nonisolated static func key(for url: URL, points: CGFloat) -> Key? {
        // A URL caches what it read; a replaced file must be read afresh.
        var url = url
        url.removeAllCachedResourceValues()
        let values = try? url.resourceValues(forKeys: [
            .contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
        guard let values, values.isRegularFile == true else { return nil }
        return Key(path: url.standardizedFileURL.path,
                   modified: values.contentModificationDate,
                   size: values.fileSize,
                   pixels: pixels(for: points))
    }

    /// Points → the pixels decoded for them, capped.
    nonisolated static func pixels(for points: CGFloat) -> Int {
        min(maxPixelSize, Int((points * CanvasThumbnails.assumedPixelScale).rounded(.up)))
    }

    /// The thumbnail of `source` for a box `points` wide, or nil when there is
    /// no file or it is not a picture. Never decodes on the main actor.
    func thumbnail(for source: Source, points: CGFloat) async -> CGImage? {
        guard let found = await Task.detached(priority: .utility, operation: {
            () -> (URL, Key)? in
            guard let url = source.resolved(),
                  let key = Self.key(for: url, points: points) else { return nil }
            return (url, key)
        }).value else { return nil }
        let (url, key) = found
        if var entry = entries[key] {
            clock += 1
            entry.lastUsed = clock
            entries[key] = entry
            return entry.image
        }
        if let running = inFlight[key] { return await running.value }
        let pixels = key.pixels
        let task = Task.detached(priority: .utility) {
            CanvasThumbnails.decode(url, maxPixelSize: pixels)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        decodeCount += 1
        store(image, for: key)
        return image
    }

    private func store(_ image: CGImage?, for key: Key) {
        // The file at this path changed: what was decoded from it before is
        // a picture that is no longer there.
        for stale in entries.keys where stale.path == key.path && stale.pixels == key.pixels
            && stale != key {
            entries.removeValue(forKey: stale)
        }
        clock += 1
        entries[key] = Entry(image: image, lastUsed: clock)
        while entries.count > entryBudget,
              let oldest = entries.min(by: { $0.value.lastUsed < $1.value.lastUsed }) {
            entries.removeValue(forKey: oldest.key)
        }
    }
}

/// **A row's picture, or its glyph until there is one** — in a fixed
/// `side`-point box either way, so a thumbnail arriving moves nothing. The
/// picture is decorative: the row reads to VoiceOver exactly as it did with
/// the glyph (`accessibilityRepresentation`).
struct RowThumbnail: View {
    /// A tree row's box: about a small glyph's, so a picture row stays one
    /// line high and no taller than its neighbours.
    static let treeSide: CGFloat = 16
    /// An Inbox row's box: the height of its title and subtitle lines.
    static let inboxSide: CGFloat = 32

    /// Nil draws the glyph only (a row that is not a picture).
    let source: RowThumbnails.Source?
    let glyph: String
    let side: CGFloat
    var glyphScale: Image.Scale = .small

    @State private var image: CGImage?
    @State private var loadedFor: RowThumbnails.Source?

    var body: some View {
        ZStack {
            if let image, source != nil {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: max(2, side / 6)))
                    .accessibilityRepresentation { glyphView }
            } else {
                glyphView
            }
        }
        .frame(width: side, height: side)
        .task(id: source) {
            if loadedFor != source { image = nil }
            guard let source else { return }
            let found = await RowThumbnails.shared.thumbnail(for: source, points: side)
            guard !Task.isCancelled else { return }
            image = found
            loadedFor = source
        }
    }

    private var glyphView: some View {
        Image(systemName: glyph)
            .imageScale(glyphScale)
            .foregroundStyle(.secondary)
    }
}

private struct RowThumbnailRootKey: EnvironmentKey {
    static let defaultValue: URL? = nil
}

extension EnvironmentValues {
    /// The project a tree row's project-relative picture path is under; set
    /// on the tree's `List` by its hosts (`BinderView`, `CollectionPiecesPane`,
    /// `SceneNavigatorPane`).
    /// Nil draws no thumbnails.
    var rowThumbnailRoot: URL? {
        get { self[RowThumbnailRootKey.self] }
        set { self[RowThumbnailRootKey.self] = newValue }
    }
}
