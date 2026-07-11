import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MaughamCore

/// Visual editor for one palette card — replaces raw-markdown editing. Every
/// control mutates a single local `draft: PaletteCard?`; a single debounced task
/// persists it through `store.updatePaletteCard` (the model owns the file). We do
/// NOT wholesale re-seed from `store.manifest.modified` while mounted — our own
/// save bumps it and a full re-seed would clobber in-flight typing (tripwires
/// 3/6). The draft is re-seeded only when `cardId` changes; after each save the
/// fresh `imagePaths` flow back (the assets folder may have moved).
///
/// The one exception is the title. Because we seed once per `cardId`, an external
/// rename (via the research tree — same id, new title/path) leaves the draft's
/// title stale, and a naive save would treat that stale title as a rename intent
/// and revert the file to the old slug (finding E2). Two guards prevent this: the
/// persist path treats the draft title as intent only when it diverged from a
/// `baselineTitle` captured at seed (`reconciledTitle`), so the store's current
/// title wins otherwise; and a narrow title-only `.onChange` on the store item's
/// title re-syncs the field when the user has no in-editor title edit pending.
struct PaletteCardEditor: View {
    let store: ProjectStore
    let cardId: String

    @State private var draft: PaletteCard?
    /// The title the draft was last in sync with the store at (seed / last
    /// persist). `persist` treats the draft title as a *rename intent* only when
    /// it has diverged from this baseline — see `reconciledTitle` (finding E2).
    @State private var baselineTitle: String?
    @State private var thumbnails: [String: NSImage] = [:]
    @State private var saveTask: Task<Void, Never>?
    @State private var saveGeneration = 0
    @State private var newSwatchColor: Color = .gray
    @State private var newNoteText = ""
    @State private var isDropTargeted = false

    // MARK: - Tested surface (pure hex helpers)

    /// Clamp components to `0...1` and format uppercase `#RRGGBB`.
    nonisolated static func hexString(r: Double, g: Double, b: Double) -> String {
        func channel(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channel(r), channel(g), channel(b))
    }

    /// sRGB-convert an `NSColor` to `#RRGGBB`; nil if the colorspace conversion fails.
    nonisolated static func hexString(from nsColor: NSColor) -> String? {
        guard let c = nsColor.usingColorSpace(.sRGB) else { return nil }
        return hexString(
            r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent))
    }

    // MARK: - Body

    var body: some View {
        Group {
            if draft != nil {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        titleSection
                        kindSection
                        swatchesSection
                        imagesSection
                        notesSection
                        bodySection
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView(
                    "Card unavailable",
                    systemImage: "paintpalette",
                    description: Text("This palette card could not be loaded."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: cardId) { seed() }
        .task(id: draft?.imagePaths) { loadThumbnails() }
        .onChange(of: store.paletteCardItems().first(where: { $0.id == cardId })?.title) {
            _, newTitle in
            // An external rename (research tree) changed the card's title beneath
            // the mounted editor. Adopt it into the field ONLY when the user has no
            // in-editor title edit pending (draft title still equals the last
            // synced baseline) — this narrow title-only sync can't clobber body
            // typing (we touch only the title) or a rename the user is typing.
            guard let newTitle, draft != nil, draft?.title == baselineTitle else { return }
            mutate { $0.with(title: newTitle) }
            baselineTitle = newTitle
        }
    }

    // MARK: - Sections

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Title").font(.caption).foregroundStyle(.secondary)
            TextField("Untitled", text: titleBinding)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
        }
    }

    private var kindSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Kind").font(.caption).foregroundStyle(.secondary)
            Picker("Kind", selection: kindBinding) {
                ForEach(PaletteCard.Kind.allCases, id: \.self) { kind in
                    Label(kind.rawValue.capitalized,
                          systemImage: PaletteCardTile.kindSymbol(for: kind))
                        .tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    @ViewBuilder
    private var swatchesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Swatches").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if let swatches = draft?.swatches {
                    ForEach(Array(swatches.enumerated()), id: \.offset) { index, hex in
                        swatchChip(hex: hex, index: index)
                    }
                }
                ColorPicker("", selection: $newSwatchColor, supportsOpacity: false)
                    .labelsHidden()
                    .onChange(of: newSwatchColor) { _, color in
                        if let hex = Self.hexString(from: NSColor(color)) { appendSwatch(hex) }
                    }
                Button {
                    NSColorSampler().show { picked in
                        guard let picked, let hex = Self.hexString(from: picked) else { return }
                        appendSwatch(hex)
                    }
                } label: {
                    Image(systemName: "eyedropper")
                }
                .buttonStyle(.plain)
                .help("Sample a colour from the screen")
                Spacer()
            }
        }
    }

    private func swatchChip(hex: String, index: Int) -> some View {
        let rgb = PaletteCard.color(fromHex: hex)
        return RoundedRectangle(cornerRadius: 4)
            .fill(rgb.map { Color(red: $0.r, green: $0.g, blue: $0.b) } ?? .clear)
            .frame(width: 28, height: 28)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
            .overlay(alignment: .topTrailing) {
                Button { removeSwatch(at: index) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .offset(x: 5, y: -5)
            }
            .help(hex)
    }

    @ViewBuilder
    private var imagesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Images").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { pasteFromClipboard() } label: {
                    Label("Paste", systemImage: "doc.on.clipboard").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Paste an image from the clipboard")
            }
            let paths = draft?.imagePaths ?? []
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                ForEach(Array(paths.enumerated()), id: \.offset) { _, path in
                    imageThumbnail(path: path)
                }
            }
            dropZone
        }
    }

    private func imageThumbnail(path: String) -> some View {
        ZStack(alignment: .topTrailing) {
            if let image = thumbnails[path] {
                Image(nsImage: image)
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(height: 90).frame(maxWidth: .infinity).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                    .frame(height: 90)
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }
            Button { removeImage(path: path) } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .padding(4)
        }
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
            .foregroundStyle(isDropTargeted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.separator))
            .frame(height: 44)
            .overlay(
                Label("Drop or paste images here", systemImage: "square.and.arrow.down")
                    .font(.caption).foregroundStyle(.secondary))
            // `.focusable()` lets a click on the well take key focus so `⌘V`
            // routes here — without it `.onPasteCommand` never fires (the well
            // otherwise never becomes first responder). The explicit Paste button
            // above is the focus-independent path.
            .focusable()
            .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
                return true
            }
            .onPasteCommand(of: [.image]) { providers in
                importPasted(providers)
            }
    }

    @ViewBuilder
    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sensory notes").font(.caption).foregroundStyle(.secondary)
            if let notes = draft?.notes {
                ForEach(Array(notes.enumerated()), id: \.offset) { index, note in
                    HStack(spacing: 8) {
                        Image(systemName: note.sense.map(PalettePane.senseSymbol(for:)) ?? "ellipsis")
                            .foregroundStyle(.secondary).frame(width: 18)
                        Text(note.text)
                        Spacer()
                        Button { removeNote(at: index) } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            TextField("Add a sensory note…", text: $newNoteText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { addNote(sense: nil) }
            HStack(spacing: 6) {
                ForEach(PaletteCard.Sense.allCases, id: \.self) { sense in
                    Button { addNote(sense: sense) } label: {
                        Label(sense.rawValue.capitalized,
                              systemImage: PalettePane.senseSymbol(for: sense))
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
                Button { addNote(sense: nil) } label: {
                    Label("Untagged", systemImage: "ellipsis").font(.caption)
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.secondary)
        }
    }

    private var bodySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Notes").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: bodyBinding)
                .frame(minHeight: 120)
                .font(.body)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            Text("Anything else about this subject…")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Bindings

    private var titleBinding: Binding<String> {
        Binding(
            get: { draft?.title ?? "" },
            set: { newValue in mutate { $0.with(title: newValue) }; scheduleSave() })
    }

    private var kindBinding: Binding<PaletteCard.Kind> {
        Binding(
            get: { draft?.kind ?? .other },
            set: { newValue in mutate { $0.with(kind: newValue) }; scheduleSave() })
    }

    private var bodyBinding: Binding<String> {
        Binding(
            get: { draft?.body ?? "" },
            set: { newValue in mutate { $0.with(body: newValue) }; scheduleSave() })
    }

    // MARK: - Mutation helpers

    /// Apply `transform` to the draft (no-op if unseeded), then persist on a debounce.
    private func mutate(_ transform: (PaletteCard) -> PaletteCard) {
        guard let current = draft else { return }
        draft = transform(current)
    }

    private func appendSwatch(_ hex: String) {
        guard PaletteCard.color(fromHex: hex) != nil else { return }
        mutate { $0.with(swatches: $0.swatches + [hex]) }
        scheduleSave()
    }

    private func removeSwatch(at index: Int) {
        mutate { card in
            var next = card.swatches
            guard next.indices.contains(index) else { return card }
            next.remove(at: index)
            return card.with(swatches: next)
        }
        scheduleSave()
    }

    private func removeImage(path: String) {
        mutate { $0.with(imagePaths: $0.imagePaths.filter { $0 != path }) }
        scheduleSave()
    }

    private func addNote(sense: PaletteCard.Sense?) {
        let text = newNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        mutate { $0.with(notes: $0.notes + [PaletteCard.SensoryNote(sense: sense, text: text)]) }
        newNoteText = ""
        scheduleSave()
    }

    private func removeNote(at index: Int) {
        mutate { card in
            var next = card.notes
            guard next.indices.contains(index) else { return card }
            next.remove(at: index)
            return card.with(notes: next)
        }
        scheduleSave()
    }

    // MARK: - Image import (drop / paste)

    /// Handle a drop of one or more providers. Finder drags carry a file URL
    /// (path/extension preserved); browser drags carry only rendered image data;
    /// remote-URL-only drags carry neither and are ignored (we never download).
    private func handleDrop(_ providers: [NSItemProvider]) {
        Task {
            for provider in providers {
                switch DropClassification.action(
                    hasFileURL: provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                    canLoadImage: provider.canLoadObject(ofClass: NSImage.self)) {
                case .fileURL:
                    if let url = await loadFileURL(provider: provider),
                       let updated = try? await store.addImage(toPaletteCard: cardId, fileURL: url) {
                        mergeImagePaths(from: updated)
                    }
                case .image:
                    if let image = await loadImage(provider: provider),
                       let updated = try? await store.addImage(toPaletteCard: cardId, image: image) {
                        mergeImagePaths(from: updated)
                    }
                case .ignore:
                    continue
                }
            }
        }
    }

    /// Paste an image directly off the general pasteboard — the focus-independent
    /// path (a click never has to land in the well first).
    private func pasteFromClipboard() {
        guard let image = NSImage(pasteboard: .general) else { return }
        Task {
            if let updated = try? await store.addImage(toPaletteCard: cardId, image: image) {
                mergeImagePaths(from: updated)
            }
        }
    }

    private func loadFileURL(provider: NSItemProvider) async -> URL? {
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

    private func importPasted(_ providers: [NSItemProvider]) {
        Task {
            for provider in providers where provider.canLoadObject(ofClass: NSImage.self) {
                guard let image = await loadImage(provider: provider) else { continue }
                if let updated = try? await store.addImage(toPaletteCard: cardId, image: image) {
                    mergeImagePaths(from: updated)
                }
            }
        }
    }

    private func loadImage(provider: NSItemProvider) async -> NSImage? {
        await withCheckedContinuation { (cont: CheckedContinuation<NSImage?, Never>) in
            _ = provider.loadObject(ofClass: NSImage.self) { obj, _ in
                cont.resume(returning: obj as? NSImage)
            }
        }
    }

    /// Merge ONLY the store's imagePaths into the draft (the user may have unsaved
    /// text edits in flight — don't wholesale replace), then re-persist so the
    /// pending typing-save can't clobber the freshly added image.
    private func mergeImagePaths(from updated: PaletteCard) {
        mutate { $0.with(imagePaths: updated.imagePaths) }
        scheduleSave()
    }

    // MARK: - Seed / persist / thumbnails

    private func seed() {
        let card = store.loadPaletteCards().first { $0.researchItemId == cardId }
        draft = card
        baselineTitle = card?.title
    }

    private func loadThumbnails() {
        guard let paths = draft?.imagePaths else { thumbnails = [:]; return }
        var loaded: [String: NSImage] = [:]
        for p in paths where thumbnails[p] == nil {
            if let img = NSImage(contentsOf: store.url.appendingPathComponent(p)) { loaded[p] = img }
        }
        // Keep already-loaded thumbnails; drop any whose path is gone.
        thumbnails = paths.reduce(into: [String: NSImage]()) { acc, p in
            acc[p] = loaded[p] ?? thumbnails[p]
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveGeneration += 1
        let generation = saveGeneration
        guard let snapshot = draft else { return }
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
            await persist(snapshot, generation: generation)
        }
    }

    private func persist(_ card: PaletteCard, generation: Int) async {
        guard let newBaseline = await Self.persistDraft(
            card, baselineTitle: baselineTitle, in: store) else { return }
        baselineTitle = newBaseline
        // Re-pull imagePaths from the persisted store state on EVERY successful save,
        // not just title-changing ones: a rename remaps the sibling `_assets/` folder
        // and only the store knows the post-rename paths. Pulling them back each time
        // stops a rename that raced a mid-await keystroke from leaving stale pre-rename
        // paths in the draft that a later save would write back after the folder moved.
        // The generation guard keeps this from clobbering text typed since this save was
        // queued — we touch ONLY imagePaths, and only when this is still the latest save
        // (a superseded save's successor re-pulls when it settles).
        guard generation == saveGeneration else { return }
        if let fresh = store.loadPaletteCards().first(where: { $0.researchItemId == cardId }) {
            // Pull the fresh title too: when this save adopted an external rename
            // (draft title stale), the field must show the store's title, not the
            // seed. Guarded by the generation check above so we never overwrite a
            // title the user is actively typing (each keystroke advances it).
            mutate { $0.with(title: fresh.title, imagePaths: fresh.imagePaths) }
        }
    }

    // MARK: - Persist core (testable — no @State, no UI)

    /// The title the outgoing card should carry on persist. The draft title is an
    /// *intent*, not a value (finding E2): the editor seeds once on `cardId` and
    /// never re-seeds while mounted, so an external rename (via the research tree)
    /// leaves the draft's title stale. Honour the draft title only when the user
    /// actually changed it in-editor (`draftTitle != baselineTitle`), falling back
    /// to the on-disk title when the field was cleared (keep the slug valid);
    /// otherwise the store's CURRENT title wins, so an external rename survives a
    /// body/swatch/note save instead of being silently reverted to the stale seed.
    nonisolated static func reconciledTitle(
        draftTitle: String, baselineTitle: String?, onDiskTitle: String?
    ) -> String {
        let userRenamedInEditor = draftTitle != baselineTitle
        if userRenamedInEditor {
            if draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let onDiskTitle {
                return onDiskTitle
            }
            return draftTitle
        }
        return onDiskTitle ?? draftTitle
    }

    /// Reconcile `draft`'s title against the store's current title and persist.
    /// Returns the title now in sync with the store (the caller's new baseline),
    /// or nil if the write failed. The testable core of the debounced save.
    @MainActor
    static func persistDraft(
        _ draft: PaletteCard, baselineTitle: String?, in store: ProjectStore
    ) async -> String? {
        let onDiskTitle = store.paletteCardItems()
            .first { $0.id == draft.researchItemId }?.title
        let title = reconciledTitle(
            draftTitle: draft.title, baselineTitle: baselineTitle, onDiskTitle: onDiskTitle)
        do { try await store.updatePaletteCard(draft.with(title: title)) }
        catch { return nil }
        return title
    }
}

private extension PaletteCard {
    /// Copy with selected fields replaced (the model is immutable `let`s).
    func with(
        title: String? = nil, kind: Kind? = nil, swatches: [String]? = nil,
        notes: [SensoryNote]? = nil, imagePaths: [String]? = nil, body: String? = nil
    ) -> PaletteCard {
        PaletteCard(
            researchItemId: researchItemId,
            title: title ?? self.title,
            kind: kind ?? self.kind,
            swatches: swatches ?? self.swatches,
            notes: notes ?? self.notes,
            imagePaths: imagePaths ?? self.imagePaths,
            body: body ?? self.body)
    }
}
