import SwiftUI
import MaughamCore

/// The research inspector's Citation section's working copy: what the writer
/// has typed, before and after a commit. Pure, so its conversions are pinned
/// without a mounted view (`InspectorCitationDraftTests`). It applies no rule
/// of its own: `citation()` hands the door everything, and the door
/// (`ProjectStore.updateCitation`) decides.
struct CitationDraft: Equatable {
    var key = ""
    var authors: [String] = []
    var sourceTitle = ""
    var publisher = ""
    var year: Int?
    /// As the date picker holds it: a moment on the picked day in the
    /// writer's own zone. Stored as that day's UTC midnight (`storedDay`).
    var accessed: Date?
    var pages = ""

    init() {}

    init(_ info: CitationInfo?, calendar: Calendar = .current) {
        guard let info else { return }
        key = info.key
        authors = info.authors
        sourceTitle = info.sourceTitle ?? ""
        publisher = info.publisher ?? ""
        year = info.year
        accessed = info.accessed.map { Self.pickedDay(fromStored: $0, calendar: calendar) }
        pages = info.pages ?? ""
    }

    /// The whole set, as the door takes it. A blank text field is an absent
    /// field; a blank key reaches the door blank, which removes the citation
    /// when nothing else is set and is refused when anything is.
    func citation(calendar: Calendar = .current) -> CitationInfo {
        func present(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        return CitationInfo(
            key: key.trimmingCharacters(in: .whitespacesAndNewlines),
            authors: authors, sourceTitle: present(sourceTitle), publisher: present(publisher),
            year: year,
            accessed: accessed.map { Self.storedDay(fromPicked: $0, calendar: calendar) },
            pages: present(pages))
    }

    private static let utc: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    /// The picked day (in the writer's zone) as UTC midnight of the same
    /// calendar day: `CitationStyle` prints the accessed day in UTC, so a
    /// local midnight east of Greenwich would otherwise print the day before.
    static func storedDay(fromPicked picked: Date, calendar: Calendar) -> Date {
        let ymd = calendar.dateComponents([.year, .month, .day], from: picked)
        return utc.date(from: ymd) ?? picked
    }

    /// The stored UTC day as local midnight of the same calendar day, for the picker.
    static func pickedDay(fromStored stored: Date, calendar: Calendar) -> Date {
        let ymd = utc.dateComponents([.year, .month, .day], from: stored)
        return calendar.date(from: ymd) ?? stored
    }

    /// "2026", never "2,026".
    static var yearFormat: IntegerFormatStyle<Int> { .number.grouping(.never) }

    /// The draft after the stored citation changed from `old` to `new` (a
    /// commit landing, or Claude's `update_research_citation`), without
    /// wiping what the writer is typing (whole-branch review M8). Field by
    /// field: one the writer has edited away from what was stored keeps the
    /// draft; one they have not follows the store. So a commit of one field
    /// that lands while the writer types in the next keeps their typing, and
    /// an external change still shows wherever the writer has not typed.
    ///
    /// "Edited away" is judged after the door's own trim
    /// (`ProjectStore.nonBlank`, blank authors dropped): a field committed as
    /// " Hachette " is stored as "Hachette" and is not dirty, so a later
    /// change from Claude still shows there.
    func merging(storedFrom old: CitationInfo?, to new: CitationInfo?,
                 calendar: Calendar = .current) -> CitationDraft {
        let was = CitationDraft(old, calendar: calendar)
        let now = CitationDraft(new, calendar: calendar)
        func pick<T: Equatable>(_ field: KeyPath<CitationDraft, T>) -> T {
            self[keyPath: field] != was[keyPath: field] ? self[keyPath: field] : now[keyPath: field]
        }
        func pick(_ field: KeyPath<CitationDraft, String>) -> String {
            let trimmed = { (s: String) in ProjectStore.nonBlank(s) ?? "" }
            return trimmed(self[keyPath: field]) != trimmed(was[keyPath: field])
                ? self[keyPath: field] : now[keyPath: field]
        }
        func pickAuthors() -> [String] {
            let cleaned = { (a: [String]) in a.compactMap(ProjectStore.nonBlank) }
            return cleaned(authors) != cleaned(was.authors) ? authors : now.authors
        }
        var merged = CitationDraft()
        merged.key = pick(\.key)
        merged.authors = pickAuthors()
        merged.sourceTitle = pick(\.sourceTitle)
        merged.publisher = pick(\.publisher)
        merged.year = pick(\.year)
        merged.accessed = pick(\.accessed)
        merged.pages = pick(\.pages)
        return merged
    }

    /// What the section says under a refused commit.
    static func refusal(_ error: Error) -> String {
        if let refusal = error as? CitationEditError { return refusal.localizedDescription }
        return "Couldn’t save the citation: \(error.localizedDescription)"
    }
}

/// The research inspector's "Citation" section (report foundations plan 3a,
/// R-3a-7): key with Suggest, authors, source title, publisher, year, accessed
/// and pages. Each field commits the whole draft through
/// `ProjectStore.updateCitation`, the door `update_research_citation` also
/// takes; a refused commit shows its reason under the fields and keeps the
/// draft, so the writer can fix it rather than retype it.
struct InspectorCitationSection: View {
    @Bindable var store: ProjectStore
    let item: ResearchItem

    @State private var draft = CitationDraft()
    @State private var refusal: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Citation")
                .font(.callout)
                .foregroundStyle(.secondary)
            LabeledContent("Key") {
                HStack(spacing: 6) {
                    TextField("e.g. smith2026", text: $draft.key, onCommit: commit)
                        .textFieldStyle(.plain)
                        .help("Renaming a key doesn't update [@key] citations already in the manuscript.")
                    Button("Suggest", action: suggest)
                        .buttonStyle(.link)
                        .help("Fill in a key from the first author's surname and the year")
                }
            }
            LabeledContent("Authors") {
                InspectorTagsField(
                    tags: $draft.authors, suggestions: [], onCommit: commit,
                    placeholder: "Add author…", splitsOnCommas: false)
            }
            LabeledContent("Source title") {
                TextField("", text: $draft.sourceTitle, onCommit: commit)
                    .textFieldStyle(.plain)
            }
            LabeledContent("Publisher") {
                TextField("", text: $draft.publisher, onCommit: commit)
                    .textFieldStyle(.plain)
            }
            LabeledContent("Year") {
                TextField("", value: yearBinding, format: CitationDraft.yearFormat)
                    .textFieldStyle(.plain)
            }
            LabeledContent("Accessed") {
                accessedControl
            }
            LabeledContent("Pages") {
                TextField("", text: $draft.pages, onCommit: commit)
                    .textFieldStyle(.plain)
            }
            if let refusal {
                Text(refusal)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: item.id) { seed() }
        // A commit from here, or `update_research_citation` from Claude, lands
        // in the manifest; the section shows what was stored — except in a
        // field the writer is editing (`CitationDraft.merging`).
        .onChange(of: item.citation) { old, new in
            draft = draft.merging(storedFrom: old, to: new)
        }
    }

    @ViewBuilder private var accessedControl: some View {
        if draft.accessed != nil {
            HStack(spacing: 6) {
                DatePicker("", selection: accessedBinding, displayedComponents: .date)
                    .labelsHidden()
                Button {
                    draft.accessed = nil
                    commit()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Clear the accessed date")
                .accessibilityLabel("Clear accessed date")
            }
        } else {
            Button("Add date") {
                draft.accessed = Calendar.current.startOfDay(for: Date())
                commit()
            }
            .buttonStyle(.link)
        }
    }

    /// Set only when the field commits, so seeding the draft never writes.
    private var yearBinding: Binding<Int?> {
        Binding(get: { draft.year }, set: { draft.year = $0; commit() })
    }

    private var accessedBinding: Binding<Date> {
        Binding(get: { draft.accessed ?? Date() }, set: { draft.accessed = $0; commit() })
    }

    private func seed() {
        draft = CitationDraft(item.citation)
        refusal = nil
    }

    private func commit() {
        let id = item.id
        let citation = draft.citation()
        Task {
            do {
                try await store.updateCitation(researchId: id, citation)
                refusal = nil
            } catch {
                refusal = CitationDraft.refusal(error)
            }
        }
    }

    private func suggest() {
        let id = item.id
        let typed = draft
        Task {
            draft.key = await store.suggestedCitationKey(
                for: id, authors: typed.authors, year: typed.year, sourceTitle: typed.sourceTitle)
            commit()
        }
    }
}
