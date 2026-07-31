import AppKit
import Foundation
import UniformTypeIdentifiers

/// How to handle one dropped `NSItemProvider`. A file URL wins over rendered
/// image data — a Finder drag carries both, and the on-disk file preserves the
/// original name/extension. Browser drags carry no file URL but do carry a
/// rendered bitmap, so they fall to `.image`. Everything else (e.g. a
/// remote-URL-only drag with no image payload) is `.ignore` — we never fetch
/// over the network.
enum DropAction: Equatable { case fileURL, image, ignore }

/// Shared drop classification + loading for every external-drop zone (the palette
/// image well, the three Research zones and — as of 1C-d Task 11 — the planning
/// canvas, which is the fifth adopter and adds no classification logic of its
/// own; it routes the two answers to the two halves of
/// `ProjectStore.ingestCanvasAsset`). Browser image drags carry rendered
/// bitmap data rather than a file URL, so `.dropDestination(for: URL.self)` silently
/// rejects them (CoreTransferable error 0); routing through `[.fileURL, .image]`
/// providers and this classifier is what makes them land. The canonical fix landed
/// for the palette well in d55891c; this is that treatment made reusable.
enum DropClassification {
    nonisolated static func action(hasFileURL: Bool, canLoadImage: Bool) -> DropAction {
        if hasFileURL { return .fileURL }
        if canLoadImage { return .image }
        return .ignore
    }

    /// Turn dropped providers into importable file URLs: real file URLs from Finder
    /// drags pass through untouched (name/extension preserved); browser image drags
    /// are rendered to a temp PNG so they flow through the same file-import path;
    /// remote-URL-only providers are dropped (we never download). Every Research zone
    /// funnels through this so images and files import to the same target uniformly.
    static func fileURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            switch action(
                hasFileURL: provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                canLoadImage: provider.canLoadObject(ofClass: NSImage.self)) {
            case .fileURL:
                if let url = await fileURL(from: provider) { urls.append(url) }
            case .image:
                if let url = await loadImageAsTempFile(provider: provider) { urls.append(url) }
            case .ignore:
                continue
            }
        }
        return urls
    }

    /// The file URL a Finder drag carries, or nil. Handed out beside
    /// `fileURLs(from:)` so a zone that does **not** want everything funnelled
    /// through a temp file — the canvas, whose ingestion pair takes a URL on one
    /// side and an `NSImage` on the other — can take the two halves apart without
    /// writing its own loader.
    static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                switch item {
                case let url as URL where url.isFileURL:
                    cont.resume(returning: url)
                case let data as Data:
                    let url = URL(dataRepresentation: data, relativeTo: nil)
                    cont.resume(returning: url?.isFileURL == true ? url : nil)
                default:
                    cont.resume(returning: nil)
                }
            }
        }
    }

    /// The rendered bitmap a browser drag carries, or nil.
    ///
    /// **The one loader, rather than a fourth hand-rolled
    /// `loadObject(ofClass: NSImage.self)`.** Three existed when the canvas needed
    /// one (here, `ResearchView`, `PaletteCardEditor`), and the canvas's browser
    /// branch hands the image straight to `ProjectStore.ingestCanvasAsset(image:)`
    /// rather than to a temp file, so it needs the image and not the URL below.
    static func image(from provider: NSItemProvider) async -> NSImage? {
        await withCheckedContinuation { (cont: CheckedContinuation<NSImage?, Never>) in
            _ = provider.loadObject(ofClass: NSImage.self) { obj, _ in
                cont.resume(returning: obj as? NSImage)
            }
        }
    }

    private static func loadImageAsTempFile(provider: NSItemProvider) async -> URL? {
        guard let img = await image(from: provider),
              let data = img.tiffRepresentation,
              let bmp = NSBitmapImageRep(data: data),
              let pngData = bmp.representation(using: .png, properties: [:]) else {
            return nil
        }
        let iso = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropped-\(iso).png")
        do {
            try pngData.write(to: tmpURL)
            return tmpURL
        } catch {
            return nil
        }
    }
}
