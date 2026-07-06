import SwiftUI
import MaughamCore

/// Download-gated reader for one manuscript file. Renders `.md` as Markdown and
/// `.fountain` with semantic screenplay styling (E.2). It funnels every read
/// through the shipped substrate: `DownloadCoordinator.ensureDownloaded` faults
/// an evicted iCloud-Drive file in (an evicted file reads as empty bytes with NO
/// error, so reading before download would silently render blank), then
/// `CoordinatedFileIO.coordinatedRead` reads the now-local bytes under
/// NSFileCoordinator.
///
/// This view is constructible standalone (E.3/E.4 wire it into the binder + tab
/// later); it does not touch the app's TabView.
struct DocumentReaderView: View {
    let docURL: URL
    let title: String
    let projectId: ProjectId
    let downloads: DownloadCoordinator
    var io: CoordinatedFileIO = .live
    let recents: RecentsTracker

    /// Reader lifecycle. `Double?` progress is nil while indeterminate (we know
    /// a download is running but have no fraction yet).
    private enum LoadState {
        case downloading(Double?)
        case loading
        case markdown([MarkdownBlocks.Block])
        case fountain(FountainScript)
        /// Unsupported file type rendered as plain text (friendlier than failing).
        case plain(String)
        case failed(String)
    }

    @State private var state: LoadState = .downloading(nil)
    @State private var searchQuery: String = ""
    /// Bumped to force `.task(id:)` to re-run on Retry.
    @State private var loadAttempt: Int = 0

    var body: some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            // Search is scoped to the Fountain path in v1 (whole-line highlight);
            // Markdown in-doc search is a follow-up — applying highlight to an
            // AttributedString is fiddly and out of scope here.
            .searchable(text: $searchQuery, prompt: Text("Find in document"))
            .task(id: loadAttempt) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case let .downloading(progress):
            downloadGate(progress: progress)
        case .loading:
            loadingView
        case let .markdown(blocks):
            markdownView(blocks)
        case let .fountain(script):
            FountainSemanticRenderer(script: script, searchQuery: searchQuery)
        case let .plain(text):
            plainView(text)
        case let .failed(message):
            failureView(message)
        }
    }

    // MARK: - States

    /// Full-screen download gate — never a blank canvas while bytes fault in.
    private func downloadGate(progress: Double?) -> some View {
        VStack(spacing: 20) {
            if let progress {
                ProgressView(value: progress) {
                    Text("Downloading \(title)…")
                }
                .progressViewStyle(.linear)
                .frame(maxWidth: 280)
            } else {
                ProgressView {
                    Text("Downloading \(title)…")
                }
            }
            Button("Cancel", role: .cancel) {
                Task {
                    await downloads.cancel(docURL)
                    state = .failed("Download cancelled.")
                }
            }
        }
        .padding()
        // Tripwire 15: empty/centered states pin to fill the pane.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingView: some View {
        ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func markdownView(_ blocks: [MarkdownBlocks.Block]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    Self.blockView(block)
                }
            }
            .textSelection(.enabled)
            .padding(20)
        }
    }

    @ViewBuilder
    private static func blockView(_ block: MarkdownBlocks.Block) -> some View {
        switch block {
        case let .heading(level, text):
            Text(text)
                .font(headingFont(level)).bold()
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .paragraph(md):
            Text(inlineEmphasis(md))
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .list(ordered, items):
            listView(ordered: ordered, items: items)
        case let .code(text):
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        case let .table(header, rows):
            tableView(header: header, rows: rows)
        case let .quote(inner):
            quoteView(inner)
        case .divider:
            Text("* * *")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private static func listView(ordered: Bool, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ordered ? "\(index + 1)." : "•")
                    Text(inlineEmphasis(item))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func tableView(header: [String], rows: [[String]]) -> some View {
        let hasHeaderText = header.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 6) {
            if hasHeaderText {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(inlineEmphasis(cell)).fontWeight(.semibold)
                    }
                }
                Divider()
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(inlineEmphasis(cell))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // `AnyView`-erased: `blockView` and `quoteView` are mutually recursive
    // (a quote can contain a quote), and opaque `some View` return types
    // can't be inferred through a recursive cycle.
    private static func quoteView(_ inner: [MarkdownBlocks.Block]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(Color(.separator))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(inner.enumerated()), id: \.offset) { _, block in
                    AnyView(blockView(block))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title
        case 2: return .title2
        case 3: return .title3
        default: return .headline
        }
    }

    /// Inline emphasis (`*italic*`, `**bold**`, links) for one paragraph, without
    /// block re-interpretation — `inlineOnlyPreservingWhitespace` keeps the
    /// paragraph's text intact. Falls back to plain text on a parse failure.
    private static func inlineEmphasis(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
    }

    private func plainView(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
    }

    private func failureView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn’t open \(title)", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Retry") { loadAttempt += 1 }
        }
        // Tripwire 15: ContentUnavailableView must fill its container.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Load pipeline

    @MainActor
    private func load() async {
        // The writer opened this doc to read it — keep recents warm so the
        // cold-launch prefetch budget favours it next time.
        recents.recordOpen(projectId)

        state = .downloading(nil)

        // Observe live download progress while we await completion. The stream
        // replays current state immediately and finishes at a terminal state;
        // it's cancelled automatically when this `.task` is torn down.
        let progressObservation = Task { @MainActor in
            for await downloadState in await downloads.observe(docURL) {
                if case let .downloading(p) = downloadState {
                    if case .downloading = state { state = .downloading(p) }
                }
            }
        }
        defer { progressObservation.cancel() }

        do {
            try await downloads.ensureDownloaded(docURL)
        } catch is CancellationError {
            // Cancel button (or task teardown) stopped the download. Keep a
            // readable message and don't clobber one the Cancel handler set —
            // the two run in either order on the main actor.
            if case .failed = state { return }
            state = .failed("Download cancelled.")
            return
        } catch {
            state = .failed(describe(error))
            return
        }

        state = .loading

        let text: String
        do {
            let data = try io.coordinatedRead(at: docURL)
            text = String(decoding: data, as: UTF8.self)
        } catch {
            state = .failed(describe(error))
            return
        }

        // Branch on extension. Parse Fountain exactly ONCE here and cache the
        // script in @State (tripwire 4); the renderer never re-parses.
        switch BinderRouting.kind(of: docURL) {
        case .markdown:
            // Shared display strip (paragraph + task anchors) — the same
            // MarkdownDisplayFilter the Mac editor's RenderFilter uses, so the
            // two surfaces never drift and the phone strips task anchors too.
            // Split into block elements so paragraph breaks + headings survive
            // (AttributedString(markdown:) alone collapses blocks into one run).
            // Inline emphasis is applied per-paragraph in the renderer.
            state = .markdown(MarkdownBlocks.parse(MarkdownDisplayFilter.stripAnchors(text)))
        case .fountain:
            state = .fountain(Self.parseFountain(text))
        case .other:
            // Render raw text plain — friendlier than a hard failure.
            state = .plain(text)
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    // MARK: - Fountain parse seam

    /// Strip the manuscript display anchors BEFORE parsing Fountain, then parse
    /// once. The Fountain path must strip the same `<!-- ¶id -->` paragraph +
    /// `<!--t-XXXXXX-->` task anchors the markdown path does — via the shared
    /// `MarkdownDisplayFilter` (single source of truth, CLAUDE.md). Skipping the
    /// strip shipped two bugs in the first TestFlight build: the anchor lines
    /// rendered as `.action` body text ("paragraph markers"), and a leading
    /// anchor line made `FountainTokenizer.parseTitlePage` miss the title page
    /// (its first-line `Key:` probe saw the anchor, not the title). `stripAnchors`
    /// removes each anchor line and the single blank that followed it, so the
    /// blank lines *between* elements survive — exactly what Fountain's
    /// blank-line-sensitive classification needs.
    ///
    /// Pure + static so it's unit-testable without the async I/O pipeline.
    static func parseFountain(_ text: String) -> FountainScript {
        FountainTokenizer().parse(MarkdownDisplayFilter.stripAnchors(text))
    }
}
