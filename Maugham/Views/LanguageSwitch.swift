import SwiftUI
import MaughamCore

/// **The toolbar's language switch** (shell p4 Task 8): which language the
/// open piece is read in — Source, then each language it has a translation
/// in — and whether the source is drawn under each paragraph. Three routes
/// choose a language, and all three post the one choice event
/// (`.maughamChooseReadingLanguage`), which the window answers by keeping the
/// writer's place (`ReadingLanguageModifier`): this control, View ▸ Read In,
/// and ⌃⌘L (Read In Next Language).
enum LanguageSwitch {

    /// What the switch offers: the piece's languages in order, the one read
    /// in now (nil: Source), and the source-under setting.
    struct Offer: Equatable {
        let languages: [String]
        let current: String?
        let showsSourceUnder: Bool
    }

    /// **Where the switch shows**: a manuscript piece open in the centre that
    /// has at least one translation — or is read in a language now, so the
    /// way back to Source never hides. Hidden (nil) everywhere else: the
    /// Book, an edition, research, the canvas.
    static func offer(subject: WindowSubject, structure: [StructureItem], languages: [String],
                      current: String?, showsSourceUnder: Bool) -> Offer? {
        guard case .item(let id) = subject.open,
              TreeWalk.find(id: id, in: structure)?.type == .document else { return nil }
        var listed = languages
        if let current, !listed.contains(where: { $0.caseInsensitiveCompare(current) == .orderedSame }) {
            listed.append(current)
        }
        guard !listed.isEmpty else { return nil }
        return Offer(languages: listed, current: current, showsSourceUnder: showsSourceUnder)
    }

    /// The switch's title, and each choice's: the language's name, or Source.
    static func title(of language: String?) -> String {
        language.map(LanguageName.title) ?? sourceTitle
    }

    static let sourceTitle = "Source"
    static let symbol = "character.book.closed"
    static let help = "Read this piece in Source or in one of its translations"
    static let readInMenuTitle = "Read In"
    static let nextMenuTitle = "Read In Next Language"
    /// ⌃⌘L — Source, then each language, then Source again.
    static let nextKey: KeyEquivalent = "l"
    static let sourceUnderTitle = "Show Source Under Translation"

    /// The choice event's payload: the language, or nothing for Source.
    static func payload(for language: String?) -> [String: Any] {
        language.map { [TranslationReveal.languageKey: $0] } ?? [:]
    }

    /// Every route's one act.
    static func choose(_ language: String?) {
        MaughamEvent.post(.maughamChooseReadingLanguage, to: .keyWindow,
                          payload: payload(for: language))
    }

    static func toggleSourceUnder() {
        MaughamEvent.post(.maughamToggleSourceUnder, to: .keyWindow)
    }
}

/// The switch in the toolbar: a menu titled with what you are reading.
struct LanguageSwitchControl: View {
    let offer: LanguageSwitch.Offer

    var body: some View {
        Menu {
            Picker(LanguageSwitch.readInMenuTitle, selection: Binding(
                get: { offer.current },
                set: { LanguageSwitch.choose($0) })) {
                Text(LanguageSwitch.sourceTitle).tag(String?.none)
                ForEach(offer.languages, id: \.self) { language in
                    Text(LanguageSwitch.title(of: language)).tag(String?.some(language))
                }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle(LanguageSwitch.sourceUnderTitle, isOn: Binding(
                get: { offer.showsSourceUnder },
                set: { _ in LanguageSwitch.toggleSourceUnder() }))
        } label: {
            Label(LanguageSwitch.title(of: offer.current), systemImage: LanguageSwitch.symbol)
                .labelStyle(.titleAndIcon)
        }
        .fixedSize()
        .help(LanguageSwitch.help)
        .accessibilityLabel("Reading in \(LanguageSwitch.title(of: offer.current))")
    }
}

// MARK: - The View menu

struct FocusedReadingOfferKey: FocusedValueKey { typealias Value = LanguageSwitch.Offer }
extension FocusedValues {
    /// The key window's language switch, for View ▸ Read In and ⌃⌘L.
    var readingOffer: LanguageSwitch.Offer? {
        get { self[FocusedReadingOfferKey.self] }
        set { self[FocusedReadingOfferKey.self] = newValue }
    }
}

/// View ▸ Read In ▸ Source / each language, Read In Next Language (⌃⌘L) and
/// Show Source Under Translation. Disabled (the menu bar's convention) where
/// the switch is hidden, so the key stays discoverable.
struct FocusedReadingItems: View {
    @FocusedValue(\.readingOffer) private var offer

    var body: some View {
        Menu(LanguageSwitch.readInMenuTitle) {
            Toggle(LanguageSwitch.sourceTitle, isOn: Binding(
                get: { offer != nil && offer?.current == nil },
                set: { _ in LanguageSwitch.choose(nil) }))
            ForEach(offer?.languages ?? [], id: \.self) { language in
                Toggle(LanguageSwitch.title(of: language), isOn: Binding(
                    get: { offer?.current == language },
                    set: { _ in LanguageSwitch.choose(language) }))
            }
        }
        .disabled(offer == nil)
        Button(LanguageSwitch.nextMenuTitle) {
            guard let offer else { return }
            LanguageSwitch.choose(ReadingLanguage.next(after: offer.current, in: offer.languages))
        }
        .keyboardShortcut(LanguageSwitch.nextKey, modifiers: [.command, .control])
        .disabled(offer == nil)
        Toggle(LanguageSwitch.sourceUnderTitle, isOn: Binding(
            get: { offer?.showsSourceUnder ?? true },
            set: { _ in LanguageSwitch.toggleSourceUnder() }))
        .disabled(offer == nil)
    }
}

// MARK: - The line over a translation

/// **The quiet line over a piece read in a language** (shell p4 Task 8): what
/// you are reading, that it is read-only and what to do instead, how much of
/// it is out of date or not yet translated, and the one press back to Source.
/// Not a mode's capsule: plain secondary text over the editor, the toolbar's
/// switch being what names the language — and the line is what still says so
/// when focus mode hides the toolbar.
struct ReadingLanguageLine: View {
    let language: String
    let entries: [TranslationBadgeLayout.Entry]

    struct Counts: Equatable {
        let stale: Int
        let missing: Int
    }

    static func counts(_ entries: [TranslationBadgeLayout.Entry]) -> Counts {
        Counts(stale: entries.lazy.filter { $0.status == .stale }.count,
               missing: entries.lazy.filter { $0.status == .missing }.count)
    }

    static func lead(_ language: String) -> String {
        "\(LanguageName.title(language)) translation \u{00b7} read-only"
    }

    /// Stale and missing, in the writer's words; nil with neither.
    static func countsLine(_ counts: Counts) -> String? {
        var parts: [String] = []
        if counts.stale > 0 {
            parts.append(counts.stale == 1 ? "1 paragraph out of date" : "\(counts.stale) paragraphs out of date")
        }
        if counts.missing > 0 {
            parts.append(counts.missing == 1 ? "1 not translated yet" : "\(counts.missing) not translated yet")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00b7} ")
    }

    static func instead(_ language: String) -> String {
        "To change it, write in Source \u{2014} the next \(LanguageName.title(language)) round carries it over."
    }

    static let backTitle = "Read Source"

    static func accessibilityText(language: String, counts: Counts) -> String {
        [lead(language), countsLine(counts), instead(language)].compactMap { $0 }.joined(separator: ". ")
    }

    var body: some View {
        let counts = Self.counts(entries)
        HStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                text([Self.lead(language), Self.countsLine(counts), Self.instead(language)])
                text([Self.lead(language), Self.countsLine(counts)])
                text([Self.lead(language)])
                text([LanguageName.title(language)])
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.accessibilityText(language: language, counts: counts))
            Spacer(minLength: 0)
            Button(Self.backTitle) { LanguageSwitch.choose(nil) }
                .buttonStyle(.link)
                .font(.callout)
                .fixedSize()
                .help("Show the source and write (\u{2303}\u{2318}L cycles the languages)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .help(Self.instead(language)
              + " Amber dots mark paragraphs whose source changed after they were translated; "
              + "hollow ones, paragraphs not translated yet, shown in their source.")
    }

    private func text(_ parts: [String?]) -> some View {
        Text(parts.compactMap { $0 }.joined(separator: " \u{00b7} "))
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
    }
}
