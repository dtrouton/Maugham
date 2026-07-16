import SwiftUI
import MaughamCore
import AppKit
import UniformTypeIdentifiers

struct ResearchView: View {
    @Bindable var store: ProjectStore
    @Binding var selectedResearchId: String?

    @State private var renamingItemId: String?
    @State private var pendingRenameId: String?
    @State private var pendingError: String?
    @State private var showingAddLinkSheet: Bool = false
    @State private var addLinkParentId: String?

    var body: some View {
        List(selection: $selectedResearchId) {
            ForEach(store.manifest.research) { item in
                ResearchTreeNode(
                    item: item,
                    renamingItemId: $renamingItemId,
                    findParentId: { findParentId(of: $0) },
                    actions: treeActions)
            }
        }
        .listStyle(.sidebar)
        .contextMenu {
            Button("New Note") {
                Task { await addResearchNote(parentId: nil) }
            }
            Button("New Group") {
                Task { await addGroup(parentId: nil) }
            }
            Button("Add File…") {
                Task { await runAddFile(parentId: nil) }
            }
            Button("Add Link…") {
                addLinkParentId = nil
                showingAddLinkSheet = true
            }
        }
        .sheet(isPresented: $showingAddLinkSheet) {
            AddResearchLinkSheet(
                onAdd: { title, url in
                    Task { await addLink(parentId: addLinkParentId, title: title, url: url) }
                    showingAddLinkSheet = false
                },
                onCancel: { showingAddLinkSheet = false })
        }
        .alert(pendingError ?? "",
               isPresented: Binding(
                get: { pendingError != nil },
                set: { if !$0 { pendingError = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            Task { await importExternal(providers, toParentId: nil) }
            return true
        }
        .onPasteCommand(of: ["public.image", "public.text", "public.url"]) { items in
            Task { await handlePaste(items: items) }
        }
        .onChange(of: store.manifest.research) { _, _ in
            tryCommitPendingRename()
        }
        .onChange(of: pendingRenameId) { _, _ in
            tryCommitPendingRename()
        }
    }

    private func tryCommitPendingRename() {
        guard let id = pendingRenameId,
              TreeWalk.contains(id: id, in: store.manifest.research) else { return }
        renamingItemId = id
        pendingRenameId = nil
    }

    private var treeActions: ResearchTreeActions {
        ResearchTreeActions(
            rename: { id, newTitle in Task { await rename(id: id, to: newTitle) } },
            internalDrop: { draggedId, position, target in
                Task { await handleInternalDrop(
                    draggedId: draggedId, position: position, target: target) }
            },
            externalDrop: { providers, position, target in
                let parent = position == .middle && target.type == .group
                    ? target.id
                    : findParentId(of: target.id)
                Task { await importExternal(providers, toParentId: parent) }
            },
            newNote: { parentId in Task { await addResearchNote(parentId: parentId) } },
            newGroup: { parentId in Task { await addGroup(parentId: parentId) } },
            addFile: { parentId in Task { await runAddFile(parentId: parentId) } },
            addLink: { parentId in
                addLinkParentId = parentId
                showingAddLinkSheet = true
            },
            duplicate: { id in Task { await duplicate(id: id) } },
            delete: { id in Task { await delete(id: id) } })
    }

    private func handleInternalDrop(
        draggedId: String, position: DropIntent.Position, target: ResearchItem
    ) async {
        guard draggedId != target.id else { return }
        let toParentId: String?
        let destIndex: Int
        switch position {
        case .top:
            toParentId = findParentId(of: target.id)
            destIndex = currentIndex(of: target.id, in: toParentId)
        case .bottom:
            toParentId = findParentId(of: target.id)
            destIndex = currentIndex(of: target.id, in: toParentId) + 1
        case .middle where target.type == .group:
            toParentId = target.id
            destIndex = 0
        case .middle:
            toParentId = findParentId(of: target.id)
            destIndex = currentIndex(of: target.id, in: toParentId) + 1
        }
        do {
            try await store.moveResearchItem(
                id: draggedId, toParentId: toParentId, atIndex: destIndex)
        } catch ProjectStoreError.cycle {
            pendingError = "Can't move a group into one of its own descendants."
        } catch {
            pendingError = error.localizedDescription
        }
    }

    private func addGroup(parentId: String?) async {
        do {
            let g = try await store.addResearchItem(
                parentId: parentId, title: "Untitled Group", kind: nil)
            selectedResearchId = g.id
            pendingRenameId = g.id  // applied via .onChange when new row appears
        } catch {
            pendingError = error.localizedDescription
        }
    }

    private func addResearchNote(parentId: String?) async {
        do {
            let note = try await store.addResearchTextNote(parentId: parentId, title: "Untitled Note")
            selectedResearchId = note.id
            pendingRenameId = note.id  // applied via .onChange when new row appears
        } catch {
            pendingError = error.localizedDescription
        }
    }

    private func addLink(parentId: String?, title: String, url: String) async {
        do {
            let l = try await store.addResearchLink(
                parentId: parentId, title: title, url: url)
            selectedResearchId = l.id
        } catch {
            pendingError = error.localizedDescription
        }
    }

    private func runAddFile(parentId: String?) async {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        await runImport(panel.urls, toParentId: parentId)
    }

    private func runImport(_ urls: [URL], toParentId: String?) async {
        do {
            _ = try await store.importResearchFiles(urls, toParentId: toParentId)
        } catch {
            pendingError = error.localizedDescription
        }
    }

    /// Import a drop of raw providers (Finder files and/or browser image bitmaps)
    /// into `toParentId`. Browser drags carry rendered image data rather than a file
    /// URL, so `DropClassification` renders those to a temp PNG and everything imports
    /// through the same target-respecting path. See `DropClassification`.
    private func importExternal(_ providers: [NSItemProvider], toParentId: String?) async {
        let urls = await DropClassification.fileURLs(from: providers)
        guard !urls.isEmpty else { return }
        await runImport(urls, toParentId: toParentId)
    }

    private func rename(id: String, to newTitle: String) async {
        do {
            try await store.updateResearchItem(id: id, title: newTitle)
        } catch {
            pendingError = error.localizedDescription
        }
    }

    private func duplicate(id: String) async {
        do {
            let copy = try await store.duplicateResearchItem(id: id)
            renamingItemId = copy.id
            selectedResearchId = copy.id
        } catch {
            pendingError = error.localizedDescription
        }
    }

    private func delete(id: String) async {
        do {
            try await store.deleteResearchItem(id: id)
        } catch {
            pendingError = error.localizedDescription
        }
    }

    // MARK: - Paste handling

    private func handlePaste(items: [NSItemProvider]) async {
        for provider in items {
            if provider.hasItemConformingToTypeIdentifier("public.url") {
                if let urlObject = try? await provider
                    .loadItem(forTypeIdentifier: "public.url"),
                   let urlData = urlObject as? URL {
                    await addLink(
                        parentId: nil,
                        title: urlData.host ?? urlData.absoluteString,
                        url: urlData.absoluteString)
                    continue
                }
            }
            if provider.canLoadObject(ofClass: NSImage.self) {
                _ = await loadAndImportImage(provider: provider)
                continue
            }
            if provider.hasItemConformingToTypeIdentifier("public.text") {
                if let textObject = try? await provider
                    .loadItem(forTypeIdentifier: "public.text"),
                   let text = (textObject as? Data)
                       .flatMap({ String(data: $0, encoding: .utf8) })
                       ?? (textObject as? String) {
                    await pasteText(text)
                }
            }
        }
    }

    private func loadAndImportImage(provider: NSItemProvider) async -> ResearchItem? {
        return await withCheckedContinuation { (cont: CheckedContinuation<ResearchItem?, Never>) in
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
                    .appendingPathComponent("pasted-\(iso).png")
                do {
                    try pngData.write(to: tmpURL)
                    Task { @MainActor in
                        do {
                            let asset = try await store.addResearchAsset(
                                parentId: nil, fromURL: tmpURL)
                            cont.resume(returning: asset)
                        } catch {
                            pendingError = error.localizedDescription
                            cont.resume(returning: nil)
                        }
                    }
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private func pasteText(_ text: String) async {
        let iso = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pasted-\(iso).md")
        do {
            try text.write(to: tmpURL, atomically: true, encoding: .utf8)
            _ = try await store.addResearchAsset(parentId: nil, fromURL: tmpURL)
        } catch {
            pendingError = error.localizedDescription
        }
    }

    // MARK: - Tree helpers

    private func findParentId(of childId: String) -> String? {
        findParentIdHelper(of: childId, in: store.manifest.research, parent: nil)
    }

    private func findParentIdHelper(
        of childId: String, in items: [ResearchItem], parent: String?
    ) -> String? {
        for item in items {
            if item.id == childId { return parent }
            if let children = item.children,
               let nested = findParentIdHelper(
                    of: childId, in: children, parent: item.id) {
                return nested
            }
        }
        return nil
    }

    private func currentIndex(of id: String, in parentId: String?) -> Int {
        let siblings: [ResearchItem]
        if let parentId,
           let parent = TreeWalk.find(id: parentId, in: store.manifest.research) {
            siblings = parent.children ?? []
        } else {
            siblings = store.manifest.research
        }
        return siblings.firstIndex(where: { $0.id == id }) ?? 0
    }
}
