import SwiftUI
import MaughamCore

/// **"Link Research…" returns** (shell-finish stage-3b Task 9).
///
/// Its only host was `LinkedResearchPane`, deleted along with the segment
/// strip in stage 2b — and stage 3a's fix wave then deleted this sheet too,
/// since a sheet with no host is dead code. That left the tree DRAG as the
/// only in-app route to `ProjectStore.linkResearch`/`unlinkResearch`, a
/// modality narrowing for a writer working by keyboard or VoiceOver. Denver
/// delegated the decision to stage 3b; this task's answer is a document row's
/// context menu (`BinderView.linkResearchVerb`) plus this sheet, restored.
///
/// It is the original UI shape verbatim
/// (`git show 4dfcab8f~1:Maugham/Views/ResearchLinkPickerSheet.swift`) with
/// two changes:
///
/// **No `try?`.** The deleted sheet swallowed `linkResearch`/`unlinkResearch`
/// failures outright — a toggle that silently did nothing on a store error,
/// which is exactly the silent-no-op class CLAUDE.md's publishing-namespace
/// finding says to fail loudly on. `perform` is `BinderTreeVerbs.perform`'s
/// own shape, handed in rather than closed over (this view owns no
/// `BinderTreeSectionsState` of its own): a throw lands in
/// `state.pendingError` and the shared alert every other tree verb already
/// uses, so a link failure reads the same as a rename failure.
///
/// **It mounts from `BinderTreeSectionsPresentations`, never from a row.** A
/// sheet attached to a row inside a lazy `List` is presented from a view the
/// list may unmount — `BinderTreeSections`' own reason for splitting rows
/// from presentations. The row's whole job is to set
/// `state.linkPickerDocumentId`.
struct ResearchLinkPickerSheet: View {
    @Bindable var store: ProjectStore
    let documentId: String
    /// `BinderTreeVerbs.perform`, handed in — see the type doc for why no
    /// `try?` survives here. Not `private`: `ResearchLinkPickerTests` drives
    /// `toggleLink` directly, since a `.switch` `Toggle` inside a `.sheet` is
    /// not something a headless test can flip through AppKit the way a real
    /// click would.
    let perform: (@escaping () async throws -> Void) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("Search research…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(8)
                List {
                    ForEach(filteredItems()) { item in
                        row(for: item)
                    }
                }
                .listStyle(.sidebar)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .navigationTitle("Link Research")
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    private func row(for item: ResearchItem) -> some View {
        HStack {
            Image(systemName: Self.iconName(for: item))
                .foregroundStyle(.secondary)
            Text(item.title)
            Spacer()
            Toggle("", isOn: Binding(
                get: { isLinked(item.id) },
                set: { newValue in toggleLink(item.id, link: newValue) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    static func iconName(for item: ResearchItem) -> String {
        switch item.kind {
        case .document: return "doc.text"
        case .image:    return "photo"
        case .pdf:      return "doc.richtext"
        case .audio:    return "waveform"
        case .link:     return "link"
        case .none:     return "folder"
        }
    }

    private func isLinked(_ id: String) -> Bool {
        store.linkedResearchIds(forDocumentId: documentId).contains(id)
    }

    /// Not `private` — see the type doc's `perform` comment.
    func toggleLink(_ id: String, link: Bool) {
        perform {
            if link {
                try await store.linkResearch(researchId: id, toDocumentId: documentId)
            } else {
                try await store.unlinkResearch(researchId: id, fromDocumentId: documentId)
            }
        }
    }

    private func filteredItems() -> [ResearchItem] {
        Self.filter(store.linkableResearchItems(forDocumentId: documentId), query: query)
    }

    /// The search field's rule, pulled out pure so a test can drive it
    /// without typing into a `TextField` inside a mounted sheet. Case-
    /// insensitive substring match on the title — the original's rule,
    /// unchanged.
    static func filter(_ items: [ResearchItem], query: String) -> [ResearchItem] {
        if query.isEmpty { return items }
        let lower = query.lowercased()
        return items.filter { $0.title.lowercased().contains(lower) }
    }
}
