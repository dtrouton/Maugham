import XCTest

/// **The editor binding's shape, censused** (#114 F16): tripwires 3 and 6 were
/// held only by `EditorIntegrationHarnessTests`' behavioural tests, so a second
/// observable on `EditorHost`, or new work in the binding's setter, showed up
/// only as a flaky cursor test. These read `type:EditorHost` — every
/// `struct`/`extension EditorHost` under the production roots, whichever file
/// it lives in — over comment- and string-masked code.
extension TripwireGrepTests {

    /// **Every property-wrapped member `EditorHost` may declare** (tripwire 6),
    /// as `@<Wrapper> <name>`, each with why it is not a parallel copy of the
    /// text. Count the dictionary, not this comment. A new entry needs a reason
    /// that says what it holds and why nothing it owns feeds the text binding.
    static let editorHostWrappedMembers: [String: String] = [
        "@Bindable store": "the project, an input the window owns",
        "@Bindable documentStore": "the document registry, an input the window owns",
        "@Environment userPreferences": "theme and typography, read into the configuration",
        "@Environment undoManager": "the window's ⌘Z stack, passed to accept/revert",
        "@State document": "the bound Document; the binding reads its displayText and writes setFullText",
        "@State loadedItemId": "which item the bound Document is, for the husk guard",
        "@State priorLoadedPath": "which path the bound Document is, for the husk guard",
        "@State loads": "a plain generation box, never read by body",
        "@State referenceIndex": "a plain reference; its redraw goes one-way through control",
        "@State tableGrid": "a plain presenter; body never reads its session",
        "@State loadOutcome": "the one refusal/waiting slot, never text",
        "@State translatedSurfaceText": "the derived read-only translation surface, recomputed on events only",
        "@State window": "the hosting window, for the scope filter",
        "@State recoveryBannerModel": "unreadable file names and a poll, never text",
        "@State recoveryPaneModel": "the refusal ladder's cause, never text",
    ]

    /// **The `$` projections `EditorHost` may hand out**, each a binding into
    /// state that is never text. Count the dictionary, not this comment.
    static let editorHostProjections: [String: String] = [
        "$window": "WindowAccessor resolves the hosting window once; never text",
    ]

    /// **The only calls the text binding's setter may make** (tripwire 3), as
    /// the callee's last name. Each is O(edit) and synchronous: the guard's
    /// `Document.setFullText` writes `displayText` once, `recordEditorTextWrite`
    /// routes the project-level side effects (and is itself what
    /// `EditorBindingSideEffectsTests` pins), and `WritingModeFactory.mode` picks
    /// a mode from the path's extension. Heavy work belongs behind a debounce.
    static let editorBindingSetterCalls: Set<String> = ["setFullText", "recordEditorTextWrite", "mode"]

    /// Attributes that are not property wrappers: a `@ViewBuilder var` is a
    /// computed view, not state.
    private static let attributesThatWrapNothing: Set<String> = [
        "ViewBuilder", "MainActor", "available", "objc", "nonobjc", "discardableResult",
        "inlinable", "usableFromInline",
    ]

    private static let swiftKeywordsBeforeABrace: Set<String> = [
        "if", "else", "guard", "do", "for", "while", "repeat", "switch", "in", "catch", "defer", "return",
    ]

    /// What `EditorHost` declares, read from every declaration of it under
    /// `roots`: `bindings` is each place a `Binding` is made or named (a
    /// `Binding` token or a `$name` projection), `wrapped` each property-wrapped
    /// member as `@<Wrapper> <name>`, and `setterCalls` every callee in the
    /// `set:` closure of the `Binding(get:set:)`. Throws when nothing declares
    /// `EditorHost`, so the census cannot pass over nothing.
    static func editorHostCensus(roots: [String], base: URL) throws
        -> (bindings: [String], wrapped: [String], setterCalls: [String]) {
        let ranges = try SourceTree.declarationRanges(of: "EditorHost", under: roots, base: base)
        guard !ranges.isEmpty else {
            throw SourceTree.LookupError(description: "no declaration of EditorHost under \(roots)")
        }
        var code: [String] = []
        for (file, spans) in ranges.sorted(by: { $0.key < $1.key }) {
            let text = try SourceTree.read(file, base: base)
            let lines = String(decoding: try SourceTree.checkedMask(text, path: file), as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for span in spans { code += lines[(span.lowerBound - 1)...min(span.upperBound - 1, lines.count - 1)] }
        }
        let joined = code.joined(separator: "\n")
        func matches(_ pattern: String, in s: String, group: Int = 0) throws -> [String] {
            try NSRegularExpression(pattern: pattern)
                .matches(in: s, range: NSRange(s.startIndex..., in: s))
                .compactMap { Range($0.range(at: group), in: s).map { String(s[$0]) } }
        }
        let bindings = try matches(#"\bBinding\b|(?<![\w$])\$[A-Za-z_]\w*"#, in: joined)
        let wrapped = try NSRegularExpression(
            pattern: #"@(\w+)(?:\([^)]*\))?\s+(?:(?:private|fileprivate|internal|public|nonisolated|static|lazy|weak)(?:\(set\))?\s+)*(?:var|let)\s+([A-Za-z_]\w*)"#)
            .matches(in: joined, range: NSRange(joined.startIndex..., in: joined))
            .compactMap { m -> String? in
                guard let w = Range(m.range(at: 1), in: joined), let n = Range(m.range(at: 2), in: joined),
                      !attributesThatWrapNothing.contains(String(joined[w]))
                else { return nil }
                return "@\(joined[w]) \(joined[n])"
            }

        // The setter: the `{` after `set:` in a `Binding(`, to its matching `}`.
        var setterCalls: [String] = []
        let chars = Array(joined)
        for bindingOpen in try NSRegularExpression(pattern: #"\bBinding\s*\("#)
            .matches(in: joined, range: NSRange(joined.startIndex..., in: joined))
            .compactMap({ Range($0.range, in: joined) }) {
            let after = joined[bindingOpen.upperBound...]
            guard let set = after.range(of: #"\bset\s*:\s*\{"#, options: .regularExpression) else { continue }
            let open = joined.distance(from: joined.startIndex, to: set.upperBound) - 1
            var depth = 0
            var close = open
            for i in open..<chars.count {
                if chars[i] == "{" { depth += 1 }
                if chars[i] == "}" { depth -= 1; if depth == 0 { close = i; break } }
            }
            let body = String(chars[(open + 1)..<close])
            // A call is a name followed by `(` or by a trailing closure's `{`.
            setterCalls += try matches(#"\b([A-Za-z_]\w*)\s*[({]"#, in: body, group: 1)
                .filter { !swiftKeywordsBeforeABrace.contains($0) }
        }
        return (bindings, wrapped, setterCalls)
    }

    /// **`EditorHost` makes exactly one `Binding`, and every observable it
    /// declares is named** (tripwire 6). The one `Binding` is the text binding
    /// whose setter writes `displayText` once through `setFullText`
    /// (`EditorIntegrationHarnessTests` pins that behaviour); a second, or a
    /// `$projection` outside `editorHostProjections`, is a second path into the
    /// text. A wrapped member missing from `editorHostWrappedMembers` is a
    /// parallel observable until its reason is written down — the
    /// `$documentText` triad drove three cursor races.
    func test_editorHostDeclaresOneBindingAndNoUnlistedObservable() throws {
        let census = try Self.editorHostCensus(roots: SourceTree.productionRoots, base: SourceTree.repoRoot)
        XCTAssertEqual(census.bindings.sorted(), (["Binding"] + Self.editorHostProjections.keys).sorted(),
            "EditorHost makes exactly one Binding, the text binding, and only the listed `$` projections "
            + "(tripwire 6) — read docs/tripwires.md row 6")
        XCTAssertEqual(census.wrapped.sorted(), Self.editorHostWrappedMembers.keys.sorted(),
            "EditorHost's property-wrapped members differ from editorHostWrappedMembers (tripwire 6). "
            + "A new one is a parallel observable until its reason is written there; a removed one leaves its entry.")
    }

    /// **The text binding's setter calls only `editorBindingSetterCalls`**
    /// (tripwire 3): heavy work in a synchronous binding setter caused the
    /// trailing-space autosave, the async restore and the stale-text loop.
    /// Equality, not a subset, so a census that stopped finding the setter fails.
    func test_theEditorBindingSetterCallsOnlyTheAllowListedFunctions() throws {
        let census = try Self.editorHostCensus(roots: SourceTree.productionRoots, base: SourceTree.repoRoot)
        XCTAssertEqual(Set(census.setterCalls), Self.editorBindingSetterCalls,
            "EditorHost's Binding setter calls \(census.setterCalls) (tripwire 3) — read docs/tripwires.md row 3")
    }

    /// The census against a planted tree: a second `Binding`, a `$` projection,
    /// an unlisted `@State` in an extension in another file, and a setter that
    /// calls more than the list are each seen; a comment, a string, a
    /// `StatementEditorHost` and an `EditorHostLoadGeneration` are not.
    func test_theEditorHostCensusFiresOnPlantedOffenders() throws {
        let base = try SourceTree.plantedTree([
            "Maugham/Views/EditorHost.swift": """
            final class EditorHostLoadGeneration { @State var ignored = 0 }
            struct EditorHost: View {
                @Bindable var store: ProjectStore
                @State private var document: Document?
                // @State private var commented = 0
                let note = "Binding(get: {}, set: {})"
                var body: some View {
                    EditorSurface(
                        text: Binding(
                            get: { document?.displayText ?? "" },
                            set: { newText in
                                guard let doc = document else { return }
                                doc.setFullText(newText)
                                Task { await autosave(newText) }
                                restyle(newText)
                            }),
                        flag: $store.flag)
                }
            }
            """,
            "Maugham/Views/EditorHost+More.swift": """
            extension EditorHost {
                @State private var lastWrittenText: String = ""
                @ViewBuilder
                private var computed: some View { EmptyView() }
                var second: Binding<String> { .constant("") }
            }
            """,
            "Maugham/Views/StatementEditorHost.swift": """
            struct StatementEditorHost: View {
                @State private var text = ""
                var body: some View { TextField("", text: $text) }
            }
            """,
        ])
        let census = try Self.editorHostCensus(roots: ["Maugham"], base: base)
        XCTAssertEqual(census.bindings.sorted(), ["$store", "Binding", "Binding"],
            "Self-check: the text Binding, a `$` projection and a second `Binding` in another file's extension")
        XCTAssertEqual(census.wrapped.sorted(),
                       ["@Bindable store", "@State document", "@State lastWrittenText"],
            "Self-check: wrapped members from the struct and its extension, never a comment or another type")
        XCTAssertEqual(Set(census.setterCalls).subtracting(Self.editorBindingSetterCalls),
                       ["Task", "autosave", "restyle"],
            "Self-check: a trailing-closure call, a call inside it and a plain call are seen; `guard … else {` is not")
        XCTAssertThrowsError(try Self.editorHostCensus(
            roots: ["Maugham"], base: try SourceTree.plantedTree(["Maugham/Other.swift": "struct Other {}"])),
            "Self-check: no EditorHost must throw, not pass")
    }
}
