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
        case markdown(AttributedString)
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
        case let .markdown(attributed):
            markdownView(attributed)
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

    private func markdownView(_ attributed: AttributedString) -> some View {
        ScrollView {
            Text(attributed)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
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
            let stripped = ParagraphAnchorStripper.strip(text)
            // Full markdown so headings/lists/emphasis render. Fall back to the
            // stripped plain text if the markdown parse throws (malformed input).
            if let attributed = try? AttributedString(
                markdown: stripped,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .full,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            ) {
                state = .markdown(attributed)
            } else {
                state = .markdown(AttributedString(stripped))
            }
        case .fountain:
            let script = FountainTokenizer().parse(text)
            state = .fountain(script)
        case .other:
            // Render raw text plain — friendlier than a hard failure.
            state = .plain(text)
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}
