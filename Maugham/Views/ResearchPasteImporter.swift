import AppKit
import Foundation
import MaughamCore

/// **⌘V into research** (shell-finish stage-2b Task 4).
///
/// The decision table below is `ResearchView`'s, moved rather than rewritten:
/// a pasted URL becomes a research link, a pasted image becomes an asset, and
/// pasted text becomes a note — all in shared research. Stage 2b deletes that
/// pane, and this is the capability arriving at the binder tree before its old
/// home goes; both surfaces call this one implementation in the meantime, so
/// there is no window in which the two can disagree about what a paste means.
///
/// **The order of the arms is load-bearing and is why this is a move.** A
/// dragged-or-copied URL from a browser also answers `canLoadObject(NSImage)`
/// on some pasteboards, and plain text arrives beside almost everything — so
/// URL is asked first and text last. Re-deriving that order from the type list
/// is exactly how a paste of a link becomes a screenshot of one.
@MainActor
struct ResearchPasteImporter {
    let store: ProjectStore
    /// Where a failure goes — the host's own error channel, so a paste that
    /// fails reaches the same alert every other verb's failure does rather
    /// than a second one of its own.
    let reportError: (String) -> Void

    /// The pasteboard types this importer asks for. Named here rather than at
    /// the two mount sites, so the list and the table below cannot drift apart.
    static let acceptedTypeIdentifiers = ["public.image", "public.text", "public.url"]

    func paste(_ items: [NSItemProvider]) async {
        for provider in items {
            if provider.hasItemConformingToTypeIdentifier("public.url") {
                if let item = try? await provider
                    .loadItem(forTypeIdentifier: "public.url"),
                   let url = Self.url(from: item) {
                    await addLink(
                        title: url.host ?? url.absoluteString,
                        url: url.absoluteString)
                    continue
                }
            }
            if provider.canLoadObject(ofClass: NSImage.self) {
                _ = await importImage(provider: provider)
                continue
            }
            if provider.hasItemConformingToTypeIdentifier("public.text") {
                if let textObject = try? await provider
                    .loadItem(forTypeIdentifier: "public.text"),
                   let text = (textObject as? Data)
                       .flatMap({ String(data: $0, encoding: .utf8) })
                       ?? (textObject as? String) {
                    await importText(text)
                }
            }
        }
    }

    /// **The one line of this table that is not a straight move, and it is a
    /// defect the move found.**
    ///
    /// `ResearchView` cast the loaded item to `URL` and nothing else. An
    /// `NSItemProvider` hands `loadItem` the pasteboard's **bytes** — measured,
    /// not deduced: a provider carrying `https://example.com` answers with
    /// `Data`, and the cast to `URL` returns nil — so the URL arm fell through
    /// to the image arm, then to the text arm, matched neither, and the paste
    /// did nothing at all. Silent, with no error and nothing in the log: the
    /// exact shape the publishing-namespace finding says to fail loudly on.
    ///
    /// `DropClassification.fileURL(from:)` had already met this and handles
    /// both forms; this is that treatment, not a new idea. Nothing that worked
    /// before stops working — the `URL` case is untouched and first.
    private static func url(from item: NSSecureCoding) -> URL? {
        switch item {
        case let url as URL: return url
        case let data as Data: return URL(dataRepresentation: data, relativeTo: nil)
        default: return nil
        }
    }

    private func addLink(title: String, url: String) async {
        do {
            _ = try await store.addResearchLink(
                parentId: nil, title: title, url: url)
        } catch {
            reportError(error.localizedDescription)
        }
    }

    private func importImage(provider: NSItemProvider) async -> ResearchItem? {
        return await withCheckedContinuation { (cont: CheckedContinuation<ResearchItem?, Never>) in
            _ = provider.loadObject(ofClass: NSImage.self) { obj, _ in
                guard let img = obj as? NSImage,
                      let data = img.tiffRepresentation,
                      let bmp = NSBitmapImageRep(data: data),
                      let pngData = bmp.representation(using: .png, properties: [:]) else {
                    cont.resume(returning: nil); return
                }
                let tmpURL = Self.temporaryFile(extension: "png")
                do {
                    try pngData.write(to: tmpURL)
                    Task { @MainActor in
                        do {
                            let asset = try await store.addResearchAsset(
                                parentId: nil, fromURL: tmpURL)
                            cont.resume(returning: asset)
                        } catch {
                            reportError(error.localizedDescription)
                            cont.resume(returning: nil)
                        }
                    }
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private func importText(_ text: String) async {
        let tmpURL = Self.temporaryFile(extension: "md")
        do {
            try text.write(to: tmpURL, atomically: true, encoding: .utf8)
            _ = try await store.addResearchAsset(parentId: nil, fromURL: tmpURL)
        } catch {
            reportError(error.localizedDescription)
        }
    }

    /// A temp file named for the moment it was pasted — the name the import
    /// then titles the item by, which is why it is a timestamp and not
    /// `UUID()`: a writer scanning their research can tell when a stray paste
    /// arrived.
    /// `nonisolated` because one of its two callers is `loadObject`'s
    /// completion, which AppKit runs off the main actor — the whole struct is
    /// `@MainActor`, so without this the call is an actor hop the compiler
    /// warns about and Swift 6 rejects. It touches nothing isolated.
    nonisolated private static func temporaryFile(extension ext: String) -> URL {
        let iso = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("pasted-\(iso).\(ext)")
    }
}

/// **Whether a ⌘V in the binder column belongs to research at all** (stage-2b
/// Task 4).
///
/// `ResearchView` never had to ask: it was a pane holding nothing but
/// research, so a paste that reached it was research's by construction. The
/// tree is one `List` carrying the manuscript as well, and a paste with a
/// chapter selected is not a research note the writer asked for — it is a
/// surprise the old pane could not have produced.
///
/// **The plan's second condition — "or the Research section has focus" — has
/// no signal of its own in a one-`List` tree**, and inventing one would be a
/// second answer beside the selection, free to disagree with it. What stands
/// in for it is `.project`: the window is about the whole project, no row of
/// the manuscript is chosen, and shared research is where a pasted thing
/// belongs. That also keeps the case a fresh project opens on — an empty
/// Research section shows an untagged placeholder that can never be the
/// subject, so gating on `.research` alone would refuse the writer's very
/// first paste.
enum TreePasteRouting {
    static func acceptsPaste(subject: BinderSubject?) -> Bool {
        switch subject {
        case .research, .project: return true
        case .item, .none: return false
        }
    }
}
