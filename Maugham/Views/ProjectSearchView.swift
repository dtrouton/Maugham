import SwiftUI
import MaughamCore

/// Find in Project — **an overlay of the tree** since shell-finish stage 2b.
///
/// It no longer owns a flag of its own. `ProjectWindow.treeFindActive` is the
/// one piece of state that says the overlay is up, and this view's only way
/// down is `close()`: a post of `.maughamCloseFind`, which that window's handler
/// answers by clearing the flag and the search results together. The ✕ and
/// Escape are therefore not two routes out of one state — they are one call,
/// twice.
struct ProjectSearchView: View {
    @Bindable var store: ProjectStore

    @State private var query: String = ""
    @State private var replacement: String = ""
    @State private var options: SearchOptions = SearchOptions()
    @State private var showReplace: Bool = false
    @State private var pendingError: String?
    /// What a Replace All left alone (ruling AI) — a notice, not an error.
    @State private var leftAloneNotice: String?
    @State private var showingReplaceAllConfirm: Bool = false
    @FocusState private var queryFocused: Bool

    var body: some View {
        // What this Mac may replace, asked ONCE per document per body pass
        // (Task 9) and handed to every consumer below — never per match row.
        let gate = replaceGate
        return VStack(spacing: 0) {
            header(gate)
            Divider()
            content(gate)
        }
        .onAppear {
            DispatchQueue.main.async { queryFocused = true }
        }
        // **Escape's route out, and it is deliberately view-local.**
        //
        // Not `WindowEscapeArbiter`/`CanvasEscapeMonitor`: that mechanism's
        // third refusal passes Escape straight through whenever a text
        // responder is editing (`CanvasEscapeMonitor.isEditingText`), and the
        // query field is editing for essentially the whole life of this
        // overlay — the field autofocuses on appear. Not an app-wide menu key
        // equivalent either; that alternative is argued down at
        // `CanvasEscapeMonitor.swift`'s "rejected alternative" note, because it
        // would take Escape from every sheet and field editor in the app.
        //
        // `.onExitCommand` rides the responder chain's `cancelOperation:`,
        // which is where a focused field's Escape already goes.
        // `TreeFindOverlayTests` drives a real Escape key event at a real
        // focused field and pins how many presses it takes.
        .onExitCommand { Self.close() }
        .onChange(of: query) { _, _ in scheduleSearch() }
        .onChange(of: options) { _, _ in scheduleSearch() }
        .confirmationDialog(
            "Replace all matches?",
            isPresented: $showingReplaceAllConfirm
        ) {
            Button("Replace All", role: .destructive) {
                Task { await runReplaceAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.replaceAllMessage(
                store.currentSearch.map {
                    Self.replaceability($0, mayReplace: gate.mayReplace, inReadThrough: gate.isInReadThrough)
                }))
        }
        .alert("Search error",
               isPresented: Binding(
                get: { pendingError != nil },
                set: { if !$0 { pendingError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(pendingError ?? "")
        }
        .alert("Some pieces were left as they were",
               isPresented: Binding(
                get: { leftAloneNotice != nil },
                set: { if !$0 { leftAloneNotice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(leftAloneNotice ?? "")
        }
    }

    private func header(_ gate: ReplaceGate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Find in Project")
                    .font(.headline)
                Spacer()
                Button {
                    Self.close()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(Self.closeHelp)
                .accessibilityLabel(Self.closeHelp)
            }
            HStack {
                TextField("Find in project", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($queryFocused)
            }
            Toggle("Replace\u{2026}", isOn: $showReplace)
                .toggleStyle(.switch)
                .controlSize(.small)
            if showReplace {
                HStack {
                    TextField("Replace with", text: $replacement)
                        .textFieldStyle(.roundedBorder)
                    // Drawn only where at least one match is this Mac's to
                    // replace (C1, ruling AI): a reviewer whose results are all
                    // manuscript sees none; research notes keep their verbs.
                    if Self.offersReplaceAll(
                        store.currentSearch.map {
                            Self.replaceability($0, mayReplace: gate.mayReplace,
                                                inReadThrough: gate.isInReadThrough)
                        }) {
                        Button("Replace All") {
                            showingReplaceAllConfirm = true
                        }
                    }
                }
            }
            HStack(spacing: 16) {
                Toggle("Aa", isOn: Binding(
                    get: { options.caseSensitive },
                    set: { options.caseSensitive = $0 }))
                    .toggleStyle(.button)
                    .help("Case sensitive")
                Toggle("W", isOn: Binding(
                    get: { options.wholeWord },
                    set: { options.wholeWord = $0 }))
                    .toggleStyle(.button)
                    .help("Whole word")
                Spacer()
                if let r = store.currentSearch {
                    Text("\(r.matchCount) in \(r.documentCount) docs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
    }

    @ViewBuilder
    private func content(_ gate: ReplaceGate) -> some View {
        if store.searchInProgress {
            VStack { ProgressView().padding() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let r = store.currentSearch, !r.matches.isEmpty {
            resultsList(r, gate: gate)
        } else if !query.isEmpty {
            VStack {
                Text("No matches")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack {
                Text("Type to search across manuscript and research")
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func resultsList(_ results: SearchResults, gate: ReplaceGate) -> some View {
        let grouped = Dictionary(grouping: results.matches, by: \.documentPath)
        let sortedKeys = grouped.keys.sorted { (a, b) in
            let aIsManuscript = a.hasPrefix("manuscript/")
            let bIsManuscript = b.hasPrefix("manuscript/")
            if aIsManuscript != bIsManuscript { return aIsManuscript }
            return a < b
        }
        return List {
            ForEach(sortedKeys, id: \.self) { path in
                if let matches = grouped[path], !matches.isEmpty {
                    Section(header: Text(
                        "\(matches[0].documentTitle) \u{2014} \(matches.count) match\(matches.count == 1 ? "" : "es")"
                    )) {
                        ForEach(matches) { match in
                            matchRow(for: match, gate: gate)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func matchRow(for match: SearchMatch, gate: ReplaceGate) -> some View {
        Button {
            MaughamEvent.post(
                .maughamFindMatchSelected, to: .keyWindow,
                payload: ["match": match])
        } label: {
            HStack(spacing: 8) {
                Text("\(match.lineNumber)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .frame(width: 30, alignment: .trailing)
                Text(highlightedPreview(for: match))
                    .font(.callout)
                    .lineLimit(2)
                Spacer(minLength: 4)
                if showReplace, gate.mayReplace(match) {
                    Button {
                        Task { await runReplaceMatch(match) }
                    } label: {
                        Image(systemName: "arrow.right.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Replace this match")
                } else if showReplace, gate.isInReadThrough(match) {
                    // Said before the press, never alerted after it.
                    Image(systemName: "arrow.right.circle")
                        .foregroundStyle(.tertiary)
                        .help(Self.readThroughRowHelp)
                        .accessibilityLabel(Self.readThroughRowHelp)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func highlightedPreview(for match: SearchMatch) -> AttributedString {
        var attr = AttributedString(match.linePreview)
        let nsPreview = match.linePreview as NSString
        let r = match.matchRangeInLine
        guard r.location >= 0,
              r.location + r.length <= nsPreview.length else { return attr }
        if let strRange = Range(r, in: match.linePreview),
           let attrRange = Range(strRange, in: attr) {
            attr[attrRange].backgroundColor = .yellow.opacity(0.4)
        }
        return attr
    }

    /// The overlay's one way down, called by the ✕ and by Escape.
    ///
    /// It posts rather than writing a binding because the flag it clears is the
    /// WINDOW's (`ProjectWindow.treeFindActive`) and the results it clears are
    /// the STORE's, and one handler owning both is what keeps the two from
    /// drifting: `ProjectWindow.applyCloseFind` is the whole of it, and this
    /// post is what reaches it. Key-window scope (ADR 0021) — the ✕ was clicked
    /// in the key window, and a key event by definition arrived in one.
    static func close() {
        MaughamEvent.post(.maughamCloseFind, to: .keyWindow)
    }

    /// One spelling for the ✕'s tooltip and its accessibility label, so the
    /// test that presses it and the writer who hovers it name the same button.
    static let closeHelp = "Close find"

    private func scheduleSearch() {
        Task {
            await store.performSearch(query: query, options: options)
        }
    }

    private func runReplaceMatch(_ match: SearchMatch) async {
        do {
            // The store refreshes the results itself before it returns.
            try await store.replaceMatch(match, with: replacement)
        } catch {
            pendingError = error.localizedDescription
        }
    }

    private func runReplaceAll() async {
        guard let r = store.currentSearch else { return }
        do {
            // The store refreshes the results itself before it returns.
            let outcome = try await store.replaceAll(in: r, with: replacement)
            // What was left is SAID (ruling AI), never a silent partial pass.
            leftAloneNotice = outcome.notice
        } catch {
            pendingError = error.localizedDescription
        }
    }

    // MARK: - What this Mac may replace (P3c whole-branch fix wave, C1)

    /// The gate over the current results, asked of the window's drawing door.
    private var replaceGate: ReplaceGate {
        let documentStore = store.documentStore
        // One gate and one path→id map per pass, never one per document.
        let readThrough = store.readThroughGate()
        let pieceIds = Self.manuscriptPieceIds(store, gate: readThrough)
        return ReplaceGate(
            store.currentSearch,
            posture: { documentStore?.posture(forPath: $0) },
            inReadThrough: { path, source in
                switch source {
                case .manuscript: return pieceIds[path].map { readThrough.refusal(.piece($0)) != nil } ?? false
                case .research: return store.researchReadThroughRefusal(atPath: path, gate: readThrough) != nil
                }
            })
    }

    /// **Each manuscript path's piece id, mapped once per pass** — and only
    /// while some piece is in read-through (`gate`), so the common case walks
    /// nothing: the manuscript arm asks the captured gate by id, never a tree
    /// walk per document.
    static func manuscriptPieceIds(_ store: ProjectStore, gate: ReadThroughGate) -> [String: String] {
        guard !gate.pieces.isEmpty else { return [:] }
        var ids: [String: String] = [:]
        func walk(_ items: [StructureItem]) {
            for item in items {
                if let path = item.path { ids[path] = item.id }
                walk(item.children ?? [])
            }
        }
        walk(store.manifest.structure)
        return ids
    }

    /// Why a match in a piece in read-through offers no Replace.
    static let readThroughRowHelp = "In read-through \u{2014} Resume Writing to replace here."

    /// **What this Mac may replace, one posture question per DOCUMENT** (P3c
    /// plan 2 Task 9) — built once per body pass over a result set, so a
    /// chapter with a hundred matches asks its posture once rather than once
    /// per row per pass. A research match asks nothing (roles guard the words,
    /// not the binder); a manuscript match answers its OWN document's posture
    /// — the queue's per-row shape, so an author of some pieces replaces in
    /// hers. No door behind the host (`posture` answering nil) fails CLOSED.
    struct ReplaceGate {
        private let manuscriptPaths: [String: Bool]
        /// The paths whose piece is in read-through on this Mac — a piece, or
        /// a note in its own folder: left as they were, and said so before
        /// the press.
        private let readThroughPaths: Set<String>

        /// `inReadThrough` is asked once per document, manuscript or research
        /// (a note in a piece's own folder follows the piece).
        init(_ results: SearchResults?, posture: (String) -> Posture?,
             inReadThrough: (_ path: String, _ source: SearchDocumentSource) -> Bool) {
            var answers: [String: Bool] = [:]
            var reading: Set<String> = []
            var asked: Set<String> = []
            for match in results?.matches ?? [] where asked.insert(match.documentPath).inserted {
                if match.documentSource == .manuscript {
                    answers[match.documentPath] = ProjectSearchView.mayReplace(
                        match, posture: posture(match.documentPath))
                }
                if inReadThrough(match.documentPath, match.documentSource) {
                    reading.insert(match.documentPath)
                }
            }
            manuscriptPaths = answers
            readThroughPaths = reading
        }

        /// Only manuscript paths are ever answered, so a research match falls
        /// to its own rule and anything else unanswered fails CLOSED. A piece
        /// in read-through takes no Replace.
        func mayReplace(_ match: SearchMatch) -> Bool {
            !isInReadThrough(match)
                && (manuscriptPaths[match.documentPath] ?? (match.documentSource == .research))
        }

        /// The match is in a piece in read-through, or in its folder.
        func isInReadThrough(_ match: SearchMatch) -> Bool {
            readThroughPaths.contains(match.documentPath)
        }
    }

    static func mayReplace(_ match: SearchMatch, posture: Posture?) -> Bool {
        switch match.documentSource {
        case .research: return true
        case .manuscript: return posture?.allows(.writeText) ?? false
        }
    }

    /// How a result set divides: the matches this Mac may replace, and the
    /// titles of the manuscript documents it would leave alone.
    struct Replaceability: Equatable {
        let replaceable: Int
        let leftAlone: [String]
        /// Pieces in read-through, left as they were (named apart).
        var inReadThrough: [String] = []
    }

    static func replaceability(
        _ results: SearchResults, mayReplace: (SearchMatch) -> Bool,
        inReadThrough: (SearchMatch) -> Bool
    ) -> Replaceability {
        var replaceable = 0
        var leftAlone: [String] = []
        var reading: [String] = []
        for match in results.matches {
            if inReadThrough(match) {
                if !reading.contains(match.documentTitle) { reading.append(match.documentTitle) }
            } else if mayReplace(match) {
                replaceable += 1
            } else if !leftAlone.contains(match.documentTitle) {
                leftAlone.append(match.documentTitle)
            }
        }
        return Replaceability(replaceable: replaceable, leftAlone: leftAlone, inReadThrough: reading)
    }

    static func offersReplaceAll(_ split: Replaceability?) -> Bool {
        (split?.replaceable ?? 0) > 0
    }

    /// The confirm's message: how many will be replaced, and — before the
    /// press, not after — which pieces will be left alone.
    static func replaceAllMessage(_ split: Replaceability?) -> String {
        let count = split?.replaceable ?? 0
        let head = "\(count) match\(count == 1 ? "" : "es") will be replaced."
        guard let split else { return head }
        return ([head, ProjectStore.leftAloneSentence(split.leftAlone),
                 ProjectStore.readThroughSentence(split.inReadThrough)] as [String?])
            .compactMap { $0 }.joined(separator: " ")
    }
}
