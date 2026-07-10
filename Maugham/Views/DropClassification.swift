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
/// image well and the three Research zones). Browser image drags carry rendered
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
                if let url = await loadFileURL(provider: provider) { urls.append(url) }
            case .image:
                if let url = await loadImageAsTempFile(provider: provider) { urls.append(url) }
            case .ignore:
                continue
            }
        }
        return urls
    }

    private static func loadFileURL(provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            _ = provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
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

    private static func loadImageAsTempFile(provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            _ = provider.loadObject(ofClass: NSImage.self) { obj, _ in
                guard let img = obj as? NSImage,
                      let data = img.tiffRepresentation,
                      let bmp = NSBitmapImageRep(data: data),
                      let pngData = bmp.representation(using: .png, properties: [:]) else {
                    cont.resume(returning: nil); return
                }
                let iso = ISO8601DateFormatter().string(from: Date())
                    .replacingOccurrences(of: ":", with: "-")
                let tmpURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("dropped-\(iso).png")
                do {
                    try pngData.write(to: tmpURL)
                    cont.resume(returning: tmpURL)
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
    }
}
