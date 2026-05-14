import SwiftUI

struct ProjectSearchView: View {
    @Bindable var store: ProjectStore
    @Binding var isActive: Bool

    @State private var query: String = ""
    @State private var replacement: String = ""
    @State private var options: SearchOptions = SearchOptions()
    @State private var showReplace: Bool = false
    @State private var pendingError: String?
    @State private var showingReplaceAllConfirm: Bool = false
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear {
            DispatchQueue.main.async { queryFocused = true }
        }
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
            Text("\(store.currentSearch?.matchCount ?? 0) matches will be replaced.")
        }
        .alert("Search error",
               isPresented: Binding(
                get: { pendingError != nil },
                set: { if !$0 { pendingError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(pendingError ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Find in Project")
                    .font(.headline)
                Spacer()
                Button {
                    isActive = false
                    store.clearSearch()
                    NotificationCenter.default.post(
                        name: .maughamCloseFind, object: nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close find")
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
                    Button("Replace All") {
                        showingReplaceAllConfirm = true
                    }
                    .disabled((store.currentSearch?.matchCount ?? 0) == 0)
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
    private var content: some View {
        if store.searchInProgress {
            VStack { ProgressView().padding() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let r = store.currentSearch, !r.matches.isEmpty {
            resultsList(r)
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

    private func resultsList(_ results: SearchResults) -> some View {
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
                            matchRow(for: match)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func matchRow(for match: SearchMatch) -> some View {
        Button {
            NotificationCenter.default.post(
                name: .maughamFindMatchSelected,
                object: nil,
                userInfo: ["match": match])
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
                if showReplace {
                    Button {
                        Task { await runReplaceMatch(match) }
                    } label: {
                        Image(systemName: "arrow.right.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Replace this match")
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

    private func scheduleSearch() {
        Task {
            await store.performSearch(query: query, options: options)
        }
    }

    private func runReplaceMatch(_ match: SearchMatch) async {
        do {
            try await store.replaceMatch(match, with: replacement)
            await store.performSearch(query: query, options: options)
        } catch {
            pendingError = error.localizedDescription
        }
    }

    private func runReplaceAll() async {
        guard let r = store.currentSearch else { return }
        do {
            try await store.replaceAll(in: r, with: replacement)
            await store.performSearch(query: query, options: options)
        } catch {
            pendingError = error.localizedDescription
        }
    }
}
