import SwiftUI
import MaughamCore

/// Read-only reader for one sensory-palette card (Task 6). Mirrors
/// `DocumentReaderView.load()` exactly — download gate + progress, then
/// `ensureDownloaded` → `coordinatedRead` → decode — before parsing the card
/// with `PaletteCardParser`. Renders title + kind, a swatch strip, sense-grouped
/// notes, freeform body prose, and images.
///
/// Text renders first; images fault in progressively in a `.task` and are
/// eviction-tolerant — a failed image shows a placeholder, never an error screen
/// (the card's words must survive an evicted asset). Standalone-constructible.
struct PaletteCardView: View {
    let project: BrowsedProject
    let item: ResearchItem
    let downloads: DownloadCoordinator
    var io: CoordinatedFileIO = .live
    let recents: RecentsTracker

    private enum LoadState {
        case downloading(Double?)
        case loading
        case card(PaletteCard)
        case failed(String)
    }

    @State private var state: LoadState = .downloading(nil)
    /// Progressive image cache, keyed by project-relative path. A path present as
    /// a key with a nil value is one that failed to load (→ placeholder).
    @State private var images: [String: UIImage?] = [:]
    @State private var loadAttempt: Int = 0

    var body: some View {
        content
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
            .task(id: loadAttempt) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case let .downloading(progress):
            downloadGate(progress: progress)
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .card(card):
            cardView(card)
        case let .failed(message):
            failureView(message)
        }
    }

    // MARK: - States

    /// Full-screen download gate — never a blank canvas while bytes fault in.
    private func downloadGate(progress: Double?) -> some View {
        VStack(spacing: 20) {
            if let progress {
                ProgressView(value: progress) { Text("Downloading \(item.title)…") }
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 280)
            } else {
                ProgressView { Text("Downloading \(item.title)…") }
            }
            Button("Cancel", role: .cancel) {
                Task {
                    await downloads.cancel(cardURL)
                    state = .failed("Download cancelled.")
                }
            }
        }
        .padding()
        // Tripwire 15: empty/centered states pin to fill the pane.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failureView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn’t open \(item.title)", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Retry") { loadAttempt += 1 }
        }
        // Tripwire 15: ContentUnavailableView must fill its container.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Card render

    private func cardView(_ card: PaletteCard) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label(card.kind.rawValue.capitalized,
                      systemImage: ReadIcons.paletteKindSymbol(card.kind))
                    .font(.subheadline).foregroundStyle(.secondary)

                imageStrip(card)
                swatchStrip(card)
                notesView(card)

                if !card.body.isEmpty {
                    Divider()
                    ForEach(Array(MarkdownBlocks.parse(card.body).enumerated()), id: \.offset) { _, block in
                        bodyBlock(block)
                    }
                }
            }
            .textSelection(.enabled)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Images fault in after the card parses; re-keys per card so a Retry
        // re-runs. Text is already on screen — this only fills the placeholders.
        .task(id: card.researchItemId) { await loadImages(card) }
    }

    @ViewBuilder
    private func imageStrip(_ card: PaletteCard) -> some View {
        if !card.imagePaths.isEmpty {
            VStack(spacing: 12) {
                ForEach(card.imagePaths, id: \.self) { path in
                    imageCell(path)
                }
            }
        }
    }

    @ViewBuilder
    private func imageCell(_ path: String) -> some View {
        // A path present as a key with a nil value has been TRIED and failed →
        // placeholder. Absent key → still loading. Non-nil → the image.
        if let entry = images[path] {
            if let image = entry {
                Image(uiImage: image)
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                imagePlaceholder(systemImage: "photo.badge.exclamationmark",
                                 caption: "Image unavailable")
            }
        } else {
            imagePlaceholder(systemImage: "photo", caption: nil, showsSpinner: true)
        }
    }

    private func imagePlaceholder(
        systemImage: String, caption: String?, showsSpinner: Bool = false
    ) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(.secondarySystemBackground))
            .frame(height: 120)
            .overlay {
                VStack(spacing: 6) {
                    if showsSpinner {
                        ProgressView()
                    } else {
                        Image(systemName: systemImage).font(.title2)
                    }
                    if let caption {
                        Text(caption).font(.caption)
                    }
                }
                .foregroundStyle(.secondary)
            }
    }

    @ViewBuilder
    private func swatchStrip(_ card: PaletteCard) -> some View {
        if !card.swatches.isEmpty {
            HStack(spacing: 6) {
                ForEach(card.swatches, id: \.self) { hex in
                    if let rgb = PaletteCard.color(fromHex: hex) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(red: rgb.r, green: rgb.g, blue: rgb.b))
                            .frame(width: 28, height: 28)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(.separator)))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func notesView(_ card: PaletteCard) -> some View {
        ForEach(Array(PaletteLoading.groupedNotes(card.notes).enumerated()), id: \.offset) { _, group in
            VStack(alignment: .leading, spacing: 4) {
                Label(group.sense?.rawValue.capitalized ?? "Notes",
                      systemImage: group.sense.map(ReadIcons.senseSymbol) ?? "ellipsis")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(group.notes.enumerated()), id: \.offset) { _, note in
                    Text(note.text).font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Minimal body-prose renderer. The card body is freeform prose before the
    /// first `##`, so paragraphs dominate; headings/lists/dividers are handled
    /// for completeness. (The full block vocabulary lives in `DocumentReaderView`
    /// for whole documents; a card body doesn't warrant the recursive machinery.)
    @ViewBuilder
    private func bodyBlock(_ block: MarkdownBlocks.Block) -> some View {
        switch block {
        case let .heading(_, text):
            Text(text).font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .paragraph(md):
            Text(Self.inlineEmphasis(md)).font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .list(ordered, items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ordered ? "\(index + 1)." : "•")
                        Text(Self.inlineEmphasis(item))
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .divider:
            Text("* * *").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        case .code, .table, .quote:
            // Uncommon inside a card body; render the raw text plainly rather
            // than duplicate DocumentReaderView's full renderer.
            EmptyView()
        }
    }

    private static func inlineEmphasis(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
    }

    // MARK: - Load pipeline

    private var cardURL: URL {
        project.url.appendingPathComponent(item.path ?? "")
    }

    /// Directory of the card file, project-relative — the base for resolving the
    /// card's image paths. Mirrors the Mac's `loadPaletteCards` derivation.
    private var cardDirectory: String {
        ((item.path ?? "") as NSString).deletingLastPathComponent
    }

    @MainActor
    private func load() async {
        // Opening a card keeps the project warm for the cold-launch prefetch
        // budget, exactly as the document reader does.
        recents.recordOpen(project.id)

        guard let path = item.path, !path.isEmpty else {
            state = .failed("This card has no file.")
            return
        }

        state = .downloading(nil)
        images = [:]

        let progressObservation = Task { @MainActor in
            for await downloadState in await downloads.observe(cardURL) {
                if case let .downloading(p) = downloadState {
                    if case .downloading = state { state = .downloading(p) }
                }
            }
        }
        defer { progressObservation.cancel() }

        do {
            try await downloads.ensureDownloaded(cardURL)
        } catch is CancellationError {
            if case .failed = state { return }
            state = .failed("Download cancelled.")
            return
        } catch {
            state = .failed(describe(error))
            return
        }

        state = .loading

        let markdown: String
        do {
            let data = try io.coordinatedRead(at: cardURL)
            markdown = String(decoding: data, as: UTF8.self)
        } catch {
            state = .failed(describe(error))
            return
        }

        state = .card(PaletteCardParser.parse(
            markdown: markdown, itemId: item.id, fallbackTitle: item.title,
            cardDirectory: cardDirectory))
    }

    /// Progressively fault in each image. Failures (evicted, missing, undecodable)
    /// record a nil entry so the cell shows a placeholder — never an error screen.
    private func loadImages(_ card: PaletteCard) async {
        for path in card.imagePaths {
            let url = project.url.appendingPathComponent(path)
            let image = try? await PhoneImageLoader.load(url, downloads: downloads, io: io)
            await MainActor.run { images[path] = .some(image) }
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}
