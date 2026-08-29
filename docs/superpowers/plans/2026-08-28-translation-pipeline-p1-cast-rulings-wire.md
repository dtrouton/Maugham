# Translation Pipeline P1 — Cast, Rulings, and the Wire — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every language edition two more named people (a blind reader and a collator) as data, teach the rulings stratum the directive and glossary shapes, and define the three report contracts the pipeline's legs answer with — all pure, all tested without a subprocess or a window.

**Architecture:** Additive cases on `ProductionRole.Role` (no schema bump — `.unknown` already round-trips), lazy mints on `ProjectStore` mirroring `translatorRole(for:)`, computed shapes on `Ruling` over its existing `text` (render/round-trip untouched), a shared `ReportJSON` helper extracted from the three duplicated parsers, two new report parsers (`ReaderReport`, `CollatorReport`) and a `.fix`-mode widening of `TranslatorReport` validated against the note ids a leg was briefed with. Nothing here spawns a process, touches a window, or writes a manuscript.

**Tech Stack:** Swift 6, XCTest, MaughamCore (SPM, Apple frameworks only), the Mac app target.

**Spec:** `docs/superpowers/specs/2026-08-28-translation-pipeline-design.md` — §1 (cast), §3/§3.1 (directives, glossary), §4 (the wire). This plan is the first of five; §13 is amended to match.

## Global Constraints

- **Run the right tests.** MaughamCore changes: `swift test --parallel --package-path Packages/MaughamCore` (~6s). App changes: `./scripts/test.sh` (~65s). Both before every commit that touches both targets. `./scripts/test.sh full` before merge.
- **Paragraph ids in tests are 4 chars from `[0-9a-hjkmnp-tv-z]`** (tripwire 8) — use `k7mq`, `a1b2`, `c3d4`, `x9y2`. Never `iloU`.
- **Never read `name`/`brief` at a call site** — `effectiveName`/`effectiveBrief` are the ONE spelling of resolution (`ProductionRole`'s own rule).
- **Read paths never mint.** A surface that only displays a person looks them up via the manifest and falls back to the preset name (`Maugham/Stores/AREA.md`, `ProjectStore+ProductionRoles.swift`'s header). Only a *run* may call a `*Role(for:)` mint.
- **No new `AnnotationKind`, no manifest schema bump, no migration** (spec constitution check; tripwire 11).
- **`RulingsSection.parseItem` splits on the RIGHTMOST em-dash** — a directive's or glossary line's own text must never contain `—`; composers replace it (Task 3).
- **All-or-nothing at parse** for every report (`TranslatorReport`'s doctrine): a malformed item fails the whole report; empty `text` refused; an absent list key reads as `[]`.
- Test naming: MaughamCore suites use prose-sentence names `test_aReaderWithNoNameOfItsOwnTakesThePresetForItsLanguage`; report suites use `test_<subject>_<expectation>`. Match the file you are in.
- Commit after each task with the message given. `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` on every commit.

---

### Task 1: Reader and collator on `ProductionRole`

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/ProductionRole.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/ProductionRoleTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `ProductionRole.Role.reader(language:)`, `.collator(language:)` (raw `"reader:<tag>"`, `"collator:<tag>"`); `ProductionRole.defaultReaderName(language:) -> String?`, `defaultCollatorName(language:) -> String?`; `effectiveName`/`effectiveBrief` resolving for both (brief never nil for either).

- [ ] **Step 1: Write the failing tests** — append to `ProductionRoleTests` under a new `// MARK: - Reader and collator (translation pipeline P1)`:

```swift
    // MARK: - Reader and collator (translation pipeline P1)

    func test_aReaderRoleCarriesItsLanguageAfterTheColon() throws {
        let role = try JSONDecoder().decode(ProductionRole.Role.self, from: Data("\"reader:es\"".utf8))
        XCTAssertEqual(role, .reader(language: "es"))
        XCTAssertEqual(role.rawValue, "reader:es")
    }

    func test_aCollatorRoleCarriesItsLanguageAfterTheColon() throws {
        let role = try JSONDecoder().decode(ProductionRole.Role.self, from: Data("\"collator:pt-br\"".utf8))
        XCTAssertEqual(role, .collator(language: "pt-br"))
        XCTAssertEqual(role.rawValue, "collator:pt-br")
    }

    func test_aReaderOrCollatorWithAnEmptyLanguageDecodesAsUnknownAndStaysLossless() throws {
        for raw in ["reader:", "collator:"] {
            let role = try JSONDecoder().decode(ProductionRole.Role.self, from: Data("\"\(raw)\"".utf8))
            XCTAssertEqual(role, .unknown(raw), raw)
            let re = try JSONEncoder().encode(role)
            XCTAssertEqual(String(decoding: re, as: UTF8.self), "\"\(raw)\"")
        }
    }

    func test_thePresetReadersAndCollatorsAreTheEightTheSpecFixes() {
        XCTAssertEqual(ProductionRole.defaultReaderName(language: "es"), "Ocampo")
        XCTAssertEqual(ProductionRole.defaultReaderName(language: "fr"), "Colette")
        XCTAssertEqual(ProductionRole.defaultReaderName(language: "de"), "Bachmann")
        XCTAssertEqual(ProductionRole.defaultReaderName(language: "ja"), "Enchi")
        XCTAssertEqual(ProductionRole.defaultCollatorName(language: "es"), "Borges")
        XCTAssertEqual(ProductionRole.defaultCollatorName(language: "fr"), "Yourcenar")
        XCTAssertEqual(ProductionRole.defaultCollatorName(language: "de"), "Schlegel")
        XCTAssertEqual(ProductionRole.defaultCollatorName(language: "ja"), "Futabatei")
        XCTAssertNil(ProductionRole.defaultReaderName(language: "sr"))
        XCTAssertNil(ProductionRole.defaultCollatorName(language: "sr"))
        XCTAssertEqual(ProductionRole.defaultReaderName(language: "ES"), "Ocampo", "case-insensitive on the tag")
    }

    func test_aReaderWithNoNameOfItsOwnTakesThePresetForItsLanguage() {
        XCTAssertEqual(ProductionRole(id: "r", role: .reader(language: "fr")).effectiveName, "Colette")
        XCTAssertEqual(ProductionRole(id: "c", role: .collator(language: "de")).effectiveName, "Schlegel")
    }

    func test_anUnlistedUnnamedReaderFallsBackToTheUppercasedTag() {
        XCTAssertEqual(ProductionRole(id: "r", role: .reader(language: "sr")).effectiveName, "SR")
        XCTAssertEqual(ProductionRole(id: "c", role: .collator(language: "sr")).effectiveName, "SR")
    }

    func test_anOwnNameWinsForAReaderAndACollator() {
        XCTAssertEqual(ProductionRole(id: "r", role: .reader(language: "es"), name: "Pizarnik").effectiveName, "Pizarnik")
        XCTAssertEqual(ProductionRole(id: "c", role: .collator(language: "es"), name: "Bioy").effectiveName, "Bioy")
    }

    func test_aReaderAndACollatorAlwaysHaveADoctrine() throws {
        let reader = try XCTUnwrap(ProductionRole(id: "r", role: .reader(language: "es")).effectiveBrief)
        XCTAssertTrue(reader.contains("will not see"), "the reader's brief states its blindness")
        XCTAssertTrue(reader.contains("Do not rewrite"))
        XCTAssertTrue(reader.contains("author's language"), "notes are written to the author")
        let collator = try XCTUnwrap(ProductionRole(id: "c", role: .collator(language: "es")).effectiveBrief)
        XCTAssertTrue(collator.contains("side by side"))
        XCTAssertTrue(collator.contains("drifted"))
        XCTAssertTrue(collator.contains("glossary"))
        XCTAssertNotEqual(reader, collator)
    }

    func test_anOwnBriefWinsForAReader() {
        let role = ProductionRole(id: "r", role: .reader(language: "es"), brief: "Only flag register.")
        XCTAssertEqual(role.effectiveBrief, "Only flag register.")
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --parallel --package-path Packages/MaughamCore --filter ProductionRoleTests 2>&1 | tail -20`
Expected: compile errors — `reader`, `collator`, `defaultReaderName` do not exist.

- [ ] **Step 3: Implement.** In `ProductionRole.Role`, add the two cases and prefixes, and widen `rawValue`/`init(from:)`:

```swift
        case translator(language: String)
        case reader(language: String)
        case collator(language: String)
        case designer
        case unknown(String)

        private static let designerRaw = "designer"
        private static let translatorPrefix = "translator:"
        private static let readerPrefix = "reader:"
        private static let collatorPrefix = "collator:"

        public var rawValue: String {
            switch self {
            case .designer: return Self.designerRaw
            case .translator(let language): return Self.translatorPrefix + language
            case .reader(let language): return Self.readerPrefix + language
            case .collator(let language): return Self.collatorPrefix + language
            case .unknown(let raw): return raw
            }
        }

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            if raw == Self.designerRaw {
                self = .designer
            } else if let tag = Self.tag(of: raw, after: Self.translatorPrefix) {
                self = .translator(language: tag)
            } else if let tag = Self.tag(of: raw, after: Self.readerPrefix) {
                self = .reader(language: tag)
            } else if let tag = Self.tag(of: raw, after: Self.collatorPrefix) {
                self = .collator(language: tag)
            } else {
                self = .unknown(raw)
            }
        }

        /// The language tag after `prefix`, or nil when `raw` does not start
        /// with it **or the tag is empty** — an empty tag is the `.unknown`
        /// case, the type doc's rule, for all three language roles alike.
        private static func tag(of raw: String, after prefix: String) -> String? {
            guard raw.hasPrefix(prefix) else { return nil }
            let tag = String(raw.dropFirst(prefix.count))
            return tag.isEmpty ? nil : tag
        }
```

Widen `effectiveName`:

```swift
        case .translator(let language):
            return Self.presetOrTag(Self.defaultTranslatorName(language: language), language)
        case .reader(let language):
            return Self.presetOrTag(Self.defaultReaderName(language: language), language)
        case .collator(let language):
            return Self.presetOrTag(Self.defaultCollatorName(language: language), language)
```

with the helper beside `unnamedFallback`:

```swift
    /// The preset name, else the uppercased tag, else the never-empty fallback.
    private static func presetOrTag(_ preset: String?, _ language: String) -> String {
        if let preset { return preset }
        let tag = language.uppercased()
        return tag.isEmpty ? unnamedFallback : tag
    }
```

Widen `effectiveBrief` (update its doc comment: the reader and collator have preset doctrines; the translator still has none):

```swift
        switch role {
        case .designer: return Self.designerBrief
        case .reader: return Self.readerBrief
        case .collator: return Self.collatorBrief
        case .translator, .unknown: return nil
        }
```

Add the presets under `// MARK: - The presets`:

```swift
    /// Real readers of each language — the spec fixes this table (§1).
    public static func defaultReaderName(language: String) -> String? {
        presetReaderNames[language.lowercased()]
    }

    /// Writers who translated — the spec fixes this table (§1).
    public static func defaultCollatorName(language: String) -> String? {
        presetCollatorNames[language.lowercased()]
    }

    private static let presetReaderNames: [String: String] = [
        "es": "Ocampo", "fr": "Colette", "de": "Bachmann", "ja": "Enchi",
    ]

    private static let presetCollatorNames: [String: String] = [
        "es": "Borges", "fr": "Yourcenar", "de": "Schlegel", "ja": "Futabatei",
    ]

    /// The blind reader's doctrine (spec §1). It never names the language: the
    /// briefing's role frame does, so one doctrine serves every edition.
    private static let readerBrief = """
    You are reading a book written in the language of this edition. You have \
    not seen, and will not see, any other version of it. Say where it does not \
    sound like a book written in this language — a phrase no native writer \
    would reach for, register that wobbles, rhythm that limps, a name or idiom \
    transcribed rather than rendered. Judge against the edition brief's stated \
    register and its rulings, not a universal norm; a feature the brief declares \
    deliberate is not a fault. Write your notes and your report in the author's \
    language, which the briefing names. Do not rewrite. Do not guess what an \
    original might have said.
    """

    /// The collator's doctrine (spec §1).
    private static let collatorBrief = """
    You hold the original and the translation side by side. Say where the \
    translation departs from what the original says, and for each departure \
    whether it still says the same thing or has drifted — and render, \
    literally, into the author's language, what the translation now says \
    there, so the author can judge it. Deliberate repetition, sentence \
    architecture and the author's plainness are meaning: a synonym for a \
    repeated word is a departure. A directive on a paragraph is the standard \
    for that paragraph. Read the whole document against the glossary: a name \
    or term rendered two ways is a departure even when each paragraph is fine \
    alone. The translator's idiom is not your concern unless meaning moved.
    """
```

Update the type's header doc (first paragraph) to say "a translator into one language, that edition's blind reader and collator, or the book's designer".

- [ ] **Step 4: Run the Core suite**

Run: `swift test --parallel --package-path Packages/MaughamCore 2>&1 | tail -5`
Expected: all pass, including the existing `test_effectiveNameIsNeverEmptyForAnyRole` (extend its loop to cover `.reader(language: "")` and `.collator(language: "")` if it enumerates cases by hand — read it first).

- [ ] **Step 5: Build the app** (a `switch role.role` anywhere in `Maugham/` without a `default` will now fail):

Run: `xcodebuild -project Maugham.xcodeproj -scheme Maugham build CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "error:|BUILD" | head`
Expected: `BUILD SUCCEEDED`. If a switch fails, add the two arms there mirroring what `.translator` does in that switch and note the file in the commit message.

- [ ] **Step 6: Commit**

```bash
git add Packages/MaughamCore/Sources/MaughamCore/ProductionRole.swift Packages/MaughamCore/Tests/MaughamCoreTests/ProductionRoleTests.swift
git commit -m "feat(core): a reader and a collator per language on ProductionRole, with presets and doctrine

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Lookups and lazy mints for the two new people

**Files:**
- Modify: `Packages/MaughamCore/Sources/MaughamCore/ProjectManifest.swift` (beside `storedTranslator(for:)`, ~line 225)
- Modify: `Maugham/Stores/ProjectStore+ProductionRoles.swift`
- Modify: `Maugham/Publish/EditionStatus.swift` (beside `translatorName(for:in:)`, ~line 430)
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/ProductionRoleTests.swift`, `MaughamTests/ProductionRoleStoreTests.swift`

**Interfaces:**
- Consumes: Task 1's cases and presets.
- Produces: `ProjectManifest.storedReader(for:) -> ProductionRole?`, `storedCollator(for:) -> ProductionRole?`; `ProjectStore.readerRole(for:) async throws -> ProductionRole`, `collatorRole(for:) async throws -> ProductionRole` (lazy mints, run-only); `EditionStatus.readerName(for:in:) -> String?`, `collatorName(for:in:) -> String?` (read-only).

- [ ] **Step 1: Failing Core test** — append to `ProductionRoleTests`:

```swift
    func test_theManifestFindsAStoredReaderAndCollatorCaseInsensitively() throws {
        let json = manifestJSON(schemaVersion: 8, productionRolesJSON: """
            [{"id":"r1","role":"reader:es","name":"Pizarnik"},
             {"id":"c1","role":"collator:es"},
             {"id":"t1","role":"translator:es"}]
            """)
        let manifest = try ProjectManifest.makeDecoder().decode(ProjectManifest.self, from: json)
        XCTAssertEqual(manifest.storedReader(for: "ES")?.id, "r1")
        XCTAssertEqual(manifest.storedCollator(for: "es")?.id, "c1")
        XCTAssertEqual(manifest.storedTranslator(for: "es")?.id, "t1", "unchanged")
        XCTAssertNil(manifest.storedReader(for: "fr"))
    }
```

(If the fixture file decodes manifests through a different helper than `ProjectManifest.makeDecoder()`, use whatever `test_twoProductionRolesRoundTripByteStable` in the same file uses.)

- [ ] **Step 2: Failing app tests** — append to `ProductionRoleStoreTests` (it already has `loadedNovel(named:)`):

```swift
    // MARK: - Reader and collator (translation pipeline P1)

    func test_mintingAReaderTwiceReturnsTheSameRole() async throws {
        let (_, store) = try await loadedNovel(named: "Reader")
        let first = try await store.readerRole(for: "es")
        let second = try await store.readerRole(for: "ES")
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.role, .reader(language: "es"))
        XCTAssertEqual(first.effectiveName, "Ocampo")
        XCTAssertEqual(store.manifest.productionRoles.filter { $0.role == .reader(language: "es") }.count, 1)
    }

    func test_aReaderAndACollatorAreDistinctPeopleForOneLanguage() async throws {
        let (_, store) = try await loadedNovel(named: "Cast")
        let translator = try await store.translatorRole(for: "fr")
        let reader = try await store.readerRole(for: "fr")
        let collator = try await store.collatorRole(for: "fr")
        XCTAssertEqual(Set([translator.id, reader.id, collator.id]).count, 3)
        XCTAssertEqual([translator, reader, collator].map(\.effectiveName), ["Baudelaire", "Colette", "Yourcenar"])
    }

    func test_anInvalidTagRefusesToMintAReaderOrACollator() async throws {
        let (url, store) = try await loadedNovel(named: "BadTag")
        let before = try manifestState(of: url)
        await XCTAssertThrowsErrorAsync(try await store.readerRole(for: "not a tag"))
        await XCTAssertThrowsErrorAsync(try await store.collatorRole(for: "not a tag"))
        XCTAssertEqual(try manifestState(of: url), before, "a refused mint writes nothing")
    }
```

If `XCTAssertThrowsErrorAsync` does not exist in the test target, add this private helper at the bottom of the file:

```swift
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath, line: UInt = #line
) async {
    do { _ = try await expression(); XCTFail("expected a throw", file: file, line: line) } catch {}
}
```

- [ ] **Step 3: Run both to verify they fail**

Run: `swift test --parallel --package-path Packages/MaughamCore --filter ProductionRoleTests 2>&1 | tail -5` and `./scripts/test.sh 2>&1 | grep -E "ProductionRoleStoreTests|error:" | head`
Expected: compile errors on `storedReader`, `readerRole`.

- [ ] **Step 4: Implement the manifest lookups** — replace `storedTranslator(for:)`'s body with a shared helper and add the two siblings:

```swift
    public func storedTranslator(for language: String) -> ProductionRole? {
        storedLanguageRole(for: language) { if case .translator(let t) = $0 { return t }; return nil }
    }

    /// The STORED reader for a language tag — `storedTranslator`'s rule, for
    /// the blind reader (translation pipeline P1).
    public func storedReader(for language: String) -> ProductionRole? {
        storedLanguageRole(for: language) { if case .reader(let t) = $0 { return t }; return nil }
    }

    /// The STORED collator for a language tag — `storedTranslator`'s rule.
    public func storedCollator(for language: String) -> ProductionRole? {
        storedLanguageRole(for: language) { if case .collator(let t) = $0 { return t }; return nil }
    }

    /// The one spelling of the case-insensitive tag match, for every role that
    /// carries a language.
    private func storedLanguageRole(
        for language: String, tag: (ProductionRole.Role) -> String?
    ) -> ProductionRole? {
        productionRoles.first { role in
            guard let stored = tag(role.role) else { return false }
            return stored.caseInsensitiveCompare(language) == .orderedSame
        }
    }
```

- [ ] **Step 5: Implement the store mints** — in `ProjectStore+ProductionRoles.swift`, replace `translatorRole(for:)`'s body with a call to a shared private mint and add the two siblings under a new `// MARK: - Readers and collators`:

```swift
    func translatorRole(for language: String) async throws -> ProductionRole {
        try await mintedLanguageRole(
            for: language, stored: manifest.storedTranslator(for:),
            role: { .translator(language: $0) },
            presetName: ProductionRole.defaultTranslatorName(language:))
    }

    // MARK: - Readers and collators

    /// The blind reader for a language, minted on first ask — `translatorRole`'s
    /// contract exactly, including the rule that only a RUN may call it.
    func readerRole(for language: String) async throws -> ProductionRole {
        try await mintedLanguageRole(
            for: language, stored: manifest.storedReader(for:),
            role: { .reader(language: $0) },
            presetName: ProductionRole.defaultReaderName(language:))
    }

    /// The collator for a language, minted on first ask — same contract.
    func collatorRole(for language: String) async throws -> ProductionRole {
        try await mintedLanguageRole(
            for: language, stored: manifest.storedCollator(for:),
            role: { .collator(language: $0) },
            presetName: ProductionRole.defaultCollatorName(language:))
    }

    /// The find-or-mint every language role shares. Order is load-bearing and
    /// unchanged from the translator's: empty-tag guard, then the stored lookup
    /// (an already-stored invalid tag is still returned), then the validity
    /// gate over what is about to be MINTED.
    private func mintedLanguageRole(
        for language: String,
        stored: (String) -> ProductionRole?,
        role: (String) -> ProductionRole.Role,
        presetName: (String) -> String?
    ) async throws -> ProductionRole {
        let tag = language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { throw ProjectStoreError.productionRoleLanguageEmpty }
        if let existing = stored(tag) { return existing }
        guard TranslationRecord.isValidLanguageTag(tag.lowercased()) else {
            throw ProjectStoreError.languageTagInvalid(language)
        }
        let minted = ProductionRole(id: Self.newId(prefix: "role"), role: role(tag), name: presetName(tag))
        try await commitProductionRoles(manifest.productionRoles + [minted])
        return minted
    }
```

Update the file's header comment: "the project's named translators, readers and collators, and its designer".

- [ ] **Step 6: Implement the read-only names** — in `EditionStatus.swift` beside `translatorName(for:in:)`:

```swift
    /// The reader's name for a language — `translatorName`'s rule: the stored
    /// role's `effectiveName`, else the preset, else nil (nobody yet). Read-only.
    nonisolated static func readerName(for language: String, in manifest: ProjectManifest) -> String? {
        if let stored = manifest.storedReader(for: language) { return stored.effectiveName }
        return ProductionRole.defaultReaderName(language: language)
    }

    nonisolated static func collatorName(for language: String, in manifest: ProjectManifest) -> String? {
        if let stored = manifest.storedCollator(for: language) { return stored.effectiveName }
        return ProductionRole.defaultCollatorName(language: language)
    }
```

Add to `ProductionRoleStoreTests`:

```swift
    func test_theReadOnlyNamesNeverMint() async throws {
        let (url, store) = try await loadedNovel(named: "ReadOnly")
        let before = try manifestState(of: url)
        XCTAssertEqual(EditionStatus.readerName(for: "es", in: store.manifest), "Ocampo")
        XCTAssertEqual(EditionStatus.collatorName(for: "ja", in: store.manifest), "Futabatei")
        XCTAssertNil(EditionStatus.readerName(for: "sr", in: store.manifest))
        XCTAssertEqual(try manifestState(of: url), before)
    }
```

- [ ] **Step 7: Run both suites**

Run: `swift test --parallel --package-path Packages/MaughamCore 2>&1 | tail -3 && ./scripts/test.sh 2>&1 | tail -5`
Expected: all green; the existing translator store tests (`test_mintingATranslatorTwiceReturnsTheSameRole`, `test_aFailedSaveLeavesNoPhantomTranslatorBehind`, …) still pass through the shared mint.

- [ ] **Step 8: Commit**

```bash
git add Packages/MaughamCore/Sources/MaughamCore/ProjectManifest.swift Packages/MaughamCore/Tests/MaughamCoreTests/ProductionRoleTests.swift Maugham/Stores/ProjectStore+ProductionRoles.swift Maugham/Publish/EditionStatus.swift MaughamTests/ProductionRoleStoreTests.swift
git commit -m "feat(stores): find-or-mint a reader and a collator per language through the translator's one shared mint

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Directive and glossary shapes on `Ruling`

**Files:**
- Create: `Packages/MaughamCore/Sources/MaughamCore/RulingShapes.swift`
- Test: `Packages/MaughamCore/Tests/MaughamCoreTests/RulingShapesTests.swift`

**Interfaces:**
- Consumes: `Ruling.text`, `RulingsSection.appending/parse`, `ParagraphID`'s alphabet.
- Produces:
  - `Ruling.directive: (paragraphId: String, text: String)?`, `Ruling.paragraphId: String?`
  - `Ruling.glossary: (term: String, rendering: String, note: String?)?`
  - `Ruling.directiveText(paragraphId: String, _ text: String) -> String` (composer, `"¶k7mq: text"`)
  - `Ruling.glossaryText(term: String, rendering: String, note: String?) -> String` (composer, `"«term» → «rendering» (note)"`)
  - `Ruling.Provenance.translatorsNote = "translator's note"`, `.glossary = "glossary"`

- [ ] **Step 1: Failing tests** — new file:

```swift
import XCTest
@testable import MaughamCore

/// A directive is a ruling anchored to a paragraph; a glossary entry is a
/// ruling of a recognised shape (translation pipeline spec §3, §3.1). Both are
/// COMPUTED over `Ruling.text`, so the stratum's parser, renderer and
/// round-trip are untouched — a bare hand-written line still parses as it did.
final class RulingShapesTests: XCTestCase {

    private func ruling(_ text: String) -> Ruling {
        Ruling(id: "x", text: text, ruledOn: nil, provenance: nil)
    }

    // MARK: - Directive

    func test_aDirectiveLineParsesItsAnchorAndItsInstruction() {
        let r = ruling("¶k7mq: keep the three \"and\"s")
        XCTAssertEqual(r.directive?.paragraphId, "k7mq")
        XCTAssertEqual(r.directive?.text, "keep the three \"and\"s")
        XCTAssertEqual(r.paragraphId, "k7mq")
    }

    func test_aBareRulingHasNoDirective() {
        XCTAssertNil(ruling("Kelly never lies").directive)
        XCTAssertNil(ruling("Kelly never lies").paragraphId)
    }

    func test_anAnchorOutsideTheIdAlphabetIsNotADirective() {
        XCTAssertNil(ruling("¶iloU: nope").directive, "i l o u are outside ParagraphID's alphabet")
        XCTAssertNil(ruling("¶k7m: too short").directive)
        XCTAssertNil(ruling("¶k7mq:").directive, "an anchor with no instruction is not a directive")
    }

    func test_theDirectiveComposerRoundTripsThroughTheStratum() {
        let line = Ruling.directiveText(paragraphId: "k7mq", "one sentence, not two")
        let md = RulingsSection.appending(line, provenance: Ruling.Provenance.translatorsNote,
                                          on: Date(timeIntervalSince1970: 0), to: "Essay.")
        let parsed = RulingsSection.parse(md).rulings
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].directive?.paragraphId, "k7mq")
        XCTAssertEqual(parsed[0].directive?.text, "one sentence, not two")
        XCTAssertEqual(parsed[0].provenance, "translator's note")
    }

    func test_theDirectiveComposerNeverEmitsAnEmDash() {
        let line = Ruling.directiveText(paragraphId: "k7mq", "plain — not elevated")
        XCTAssertFalse(line.contains("—"), "the stratum splits on the rightmost em-dash")
        let md = RulingsSection.appending(line, provenance: Ruling.Provenance.translatorsNote,
                                          on: Date(timeIntervalSince1970: 0), to: "")
        XCTAssertEqual(RulingsSection.parse(md).rulings.first?.directive?.text, "plain - not elevated")
    }

    // MARK: - Glossary

    func test_aGlossaryLineParsesTermRenderingAndNote() {
        let r = ruling("«October» → «Octubre» (the month, never a name)")
        XCTAssertEqual(r.glossary?.term, "October")
        XCTAssertEqual(r.glossary?.rendering, "Octubre")
        XCTAssertEqual(r.glossary?.note, "the month, never a name")
    }

    func test_aGlossaryLineWithoutANoteParses() {
        let r = ruling("«Kelly» → «Kelly»")
        XCTAssertEqual(r.glossary?.term, "Kelly")
        XCTAssertEqual(r.glossary?.rendering, "Kelly")
        XCTAssertNil(r.glossary?.note)
    }

    func test_aBareRulingIsNotAGlossaryEntry() {
        XCTAssertNil(ruling("Render every month name in Spanish").glossary)
        XCTAssertNil(ruling("«unclosed → «x»").glossary)
    }

    func test_theGlossaryComposerRoundTripsThroughTheStratum() {
        let line = Ruling.glossaryText(term: "October", rendering: "Octubre", note: "the month — never a name")
        XCTAssertFalse(line.contains("—"))
        let md = RulingsSection.appending(line, provenance: Ruling.Provenance.glossary,
                                          on: Date(timeIntervalSince1970: 0), to: "Essay.")
        let parsed = RulingsSection.parse(md).rulings
        XCTAssertEqual(parsed.first?.glossary?.term, "October")
        XCTAssertEqual(parsed.first?.glossary?.rendering, "Octubre")
        XCTAssertEqual(parsed.first?.glossary?.note, "the month - never a name")
        XCTAssertEqual(parsed.first?.provenance, "glossary")
    }

    func test_aDirectiveIsNotAGlossaryEntryAndViceVersa() {
        XCTAssertNil(ruling("¶k7mq: keep it").glossary)
        XCTAssertNil(ruling("«a» → «b»").directive)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --parallel --package-path Packages/MaughamCore --filter RulingShapesTests 2>&1 | tail -5`
Expected: compile errors — `directive`, `glossary`, `directiveText`, `Provenance` undefined.

- [ ] **Step 3: Implement** — new file `RulingShapes.swift`:

```swift
import Foundation

/// The two recognised shapes a ruling's text can take (translation pipeline
/// spec §3, §3.1) — a **directive** anchored to a paragraph, and a **glossary
/// entry**. Both are computed over `text`; nothing here changes what
/// `RulingsSection` parses, renders or round-trips, which is what lets a
/// pre-pipeline build read the same file as ordinary rulings.
///
/// **No em-dash may appear in a composed line.** `RulingsSection.parseItem`
/// splits on the rightmost `—` to find the `ruled <date>, <provenance>`
/// suffix, so an em-dash inside a directive's instruction or a glossary note
/// would be read as the suffix. The composers replace it with a hyphen.
public extension Ruling {

    enum Provenance {
        public static let translatorsNote = "translator's note"
        public static let glossary = "glossary"
    }

    // MARK: - Directive

    /// `¶k7mq: keep the three "and"s` → `("k7mq", "keep the three \"and\"s")`.
    /// The anchor must be a 4-char id in `ParagraphID`'s alphabet followed by a
    /// colon and a non-empty instruction; anything else is an ordinary ruling.
    var directive: (paragraphId: String, text: String)? {
        guard let match = Self.directivePattern.firstMatch(
            in: text, range: NSRange(text.startIndex..., in: text)),
              let idRange = Range(match.range(at: 1), in: text),
              let bodyRange = Range(match.range(at: 2), in: text)
        else { return nil }
        let body = text[bodyRange].trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }
        return (String(text[idRange]), body)
    }

    /// The paragraph a directive is about; nil for every other ruling.
    var paragraphId: String? { directive?.paragraphId }

    /// The line text for a directive on `paragraphId`.
    static func directiveText(paragraphId: String, _ instruction: String) -> String {
        "¶\(paragraphId): \(dashSafe(instruction))"
    }

    // MARK: - Glossary

    /// `«October» → «Octubre» (the month, never a name)` →
    /// `("October", "Octubre", "the month, never a name")`; the note is optional.
    var glossary: (term: String, rendering: String, note: String?)? {
        guard let match = Self.glossaryPattern.firstMatch(
            in: text, range: NSRange(text.startIndex..., in: text)),
              let termRange = Range(match.range(at: 1), in: text),
              let renderingRange = Range(match.range(at: 2), in: text)
        else { return nil }
        let note = Range(match.range(at: 3), in: text).map {
            text[$0].trimmingCharacters(in: .whitespaces)
        }
        return (String(text[termRange]), String(text[renderingRange]),
                (note?.isEmpty ?? true) ? nil : note)
    }

    /// The line text for a glossary entry.
    static func glossaryText(term: String, rendering: String, note: String?) -> String {
        var line = "«\(dashSafe(term))» → «\(dashSafe(rendering))»"
        if let note, !note.trimmingCharacters(in: .whitespaces).isEmpty {
            line += " (\(dashSafe(note)))"
        }
        return line
    }

    // MARK: - Patterns

    /// The alphabet is `ParagraphID`'s: no i, l, o, u.
    private static let directivePattern = try! NSRegularExpression(
        pattern: "^¶([0-9abcdefghjkmnpqrstvwxyz]{4}):(.*)$")

    private static let glossaryPattern = try! NSRegularExpression(
        pattern: "^«([^«»]+)»\\s*→\\s*«([^«»]+)»(?:\\s*\\((.*)\\))?$")

    private static func dashSafe(_ s: String) -> String {
        s.replacingOccurrences(of: "—", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

- [ ] **Step 4: Run the Core suite**

Run: `swift test --parallel --package-path Packages/MaughamCore 2>&1 | tail -3`
Expected: all green, `RulingsSectionTests` untouched and passing.

- [ ] **Step 5: Commit**

```bash
git add Packages/MaughamCore/Sources/MaughamCore/RulingShapes.swift Packages/MaughamCore/Tests/MaughamCoreTests/RulingShapesTests.swift
git commit -m "feat(core): a ruling can be a paragraph-anchored directive or a glossary entry, computed over its text

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: `ReportJSON` — one copy of the report parsers' shared helpers

**Files:**
- Create: `Maugham/Compiler/ReportJSON.swift`
- Modify: `Maugham/Compiler/TranslatorReport.swift` (delete its private `parseList`, `nonEmptyString`, `reportObject`, `objectSpans`; call `ReportJSON`)
- Modify: `Maugham/Compiler/DesignerReport.swift` (delete its private `nonEmptyString`, `reportObject`, `objectSpans`; call `ReportJSON`)
- Test: `MaughamTests/ReportJSONTests.swift`; existing `TranslatorReportTests`, `DesignerReportTests` are the safety net.

**Interfaces:**
- Produces:
  - `ReportJSON.nonEmptyString(_ value: Any?) -> String?` (trims)
  - `ReportJSON.objectSpans(in text: String) -> [String]`
  - `ReportJSON.lastObject(in raw: String, shapedBy keys: [String]) -> [String: Any]?` — the LAST brace-balanced top-level object carrying any of `keys`
  - `ReportJSON.parseList<T>(_ container: [String: Any], key: String, parseItem: ([String: Any]) -> T?) -> [T]?` — absent key → `[]`; wrong shape or any failing item → `nil`
  - `ReportJSON.enumValue<E: RawRepresentable>(_ value: Any?, as: E.Type) -> E? where E.RawValue == String`

- [ ] **Step 1: Failing tests** — new file:

```swift
import XCTest
@testable import Maugham

/// The helpers every report parser shares — extracted when the fourth copy
/// (the reader's report) would have been the fourth copy. The three existing
/// parsers' suites are the behavioural pin; these are the helper's own.
final class ReportJSONTests: XCTestCase {

    func test_lastObject_takesTheLastSpanCarryingAShapeKey() throws {
        let raw = """
            Thinking: {"notes":[{"x":1}]} ... and finally:
            ```json
            {"notes":[],"overall":{"text":"fine"}}
            ```
            """
        let object = try XCTUnwrap(ReportJSON.lastObject(in: raw, shapedBy: ["notes", "overall"]))
        XCTAssertNotNil(object["overall"])
    }

    func test_lastObject_ignoresSpansWithoutAShapeKey() {
        XCTAssertNil(ReportJSON.lastObject(in: "{\"other\":1}", shapedBy: ["notes"]))
    }

    func test_parseList_absentKeyIsEmpty_wrongShapeIsNil_badItemIsNil() {
        let ok: [Int]? = ReportJSON.parseList([:], key: "k") { _ in 1 }
        XCTAssertEqual(ok, [])
        let wrong: [Int]? = ReportJSON.parseList(["k": "no"], key: "k") { _ in 1 }
        XCTAssertNil(wrong)
        let bad: [Int]? = ReportJSON.parseList(["k": [["a": 1], ["b": 2]]], key: "k") { $0["a"] as? Int }
        XCTAssertNil(bad, "one failing item fails the list")
    }

    func test_nonEmptyString_trimsAndRefusesBlank() {
        XCTAssertEqual(ReportJSON.nonEmptyString("  hi \n"), "hi")
        XCTAssertNil(ReportJSON.nonEmptyString("   "))
        XCTAssertNil(ReportJSON.nonEmptyString(3))
    }

    private enum Colour: String { case red, blue }

    func test_enumValue_readsAKnownRawAndRefusesTheRest() {
        XCTAssertEqual(ReportJSON.enumValue("red", as: Colour.self), .red)
        XCTAssertNil(ReportJSON.enumValue("green", as: Colour.self))
        XCTAssertNil(ReportJSON.enumValue(1, as: Colour.self))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `./scripts/test.sh 2>&1 | grep -E "ReportJSONTests|error:" | head`
Expected: compile error — `ReportJSON` undefined.

- [ ] **Step 3: Implement** — `Maugham/Compiler/ReportJSON.swift`, moving the bodies verbatim from `TranslatorReport` (they are the canonical copies; `objectSpans` and `nonEmptyString` are byte-identical across the three files):

```swift
import Foundation

/// The helpers every report parser shares: finding the answer object in a
/// turn's text, reading a list all-or-nothing, and reading a string that has
/// something in it. `DiagnosticIngest`, `TranslatorReport` and
/// `DesignerReport` each carried a private copy "owing the others no
/// dependency"; a neutral helper is not a dependency on another contract, and
/// the fourth copy is where the duplication stopped earning its keep.
enum ReportJSON {

    /// A `String` value with something in it, TRIMMED — whitespace around a
    /// model's answer is an artifact of how it wrote its JSON, not of the prose.
    static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A closed wire enum's value, or nil for anything not in the enum.
    static func enumValue<E: RawRepresentable>(_ value: Any?, as: E.Type) -> E?
    where E.RawValue == String {
        guard let raw = nonEmptyString(value) else { return nil }
        return E(rawValue: raw)
    }

    /// A key that is absent reads as an empty list; a key present with the
    /// wrong shape, or any one element `parseItem` refuses, fails the list.
    static func parseList<T>(
        _ container: [String: Any], key: String, parseItem: ([String: Any]) -> T?
    ) -> [T]? {
        guard let value = container[key] else { return [] }
        guard let raw = value as? [Any] else { return nil }
        var results: [T] = []
        results.reserveCapacity(raw.count)
        for element in raw {
            guard let item = element as? [String: Any], let parsed = parseItem(item) else {
                return nil
            }
            results.append(parsed)
        }
        return results
    }

    /// The LAST complete top-level JSON object in `raw` carrying any of `keys`
    /// — a model that reasons in prose puts worked examples earlier and the
    /// real answer last (`TranslatorReport`'s reasoning, unchanged).
    static func lastObject(in raw: String, shapedBy keys: [String]) -> [String: Any]? {
        for span in objectSpans(in: raw).reversed() {
            guard let data = span.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any],
                  keys.contains(where: { dictionary[$0] != nil })
            else { continue }
            return dictionary
        }
        return nil
    }

    /// Every top-level `{...}` span in `text`, brace-balanced and string-aware.
    static func objectSpans(in text: String) -> [String] {
        // — paste TranslatorReport.objectSpans' body here verbatim —
    }
}
```

Then in `TranslatorReport`: delete `parseList`, `nonEmptyString`, `reportObject`, `objectSpans`; replace `reportObject(in: raw)` with `ReportJSON.lastObject(in: raw, shapedBy: [WireField.entries, WireField.queries])`, `parseList(` with `ReportJSON.parseList(`, `nonEmptyString(` with `ReportJSON.nonEmptyString(`. In `DesignerReport`: same three deletions; `reportObject` → `ReportJSON.lastObject(in: raw, shapedBy: [WireField.spec, WireField.files])`. Leave `DiagnosticIngest` alone (it is the compiler's, sectioned, and out of this plan's scope) but update the three "duplicated here rather than shared" doc comments to point at `ReportJSON`.

- [ ] **Step 4: Run the app suite**

Run: `./scripts/test.sh 2>&1 | tail -5`
Expected: green — `TranslatorReportTests` (23) and `DesignerReportTests` unchanged and passing.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Compiler/ReportJSON.swift Maugham/Compiler/TranslatorReport.swift Maugham/Compiler/DesignerReport.swift MaughamTests/ReportJSONTests.swift
git commit -m "refactor(compiler): ReportJSON — one copy of the span finder, list reader and non-empty string the report parsers shared

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: `ReaderReport`

**Files:**
- Create: `Maugham/Compiler/ReaderReport.swift`
- Test: `MaughamTests/ReaderReportTests.swift`

**Interfaces:**
- Consumes: `ReportJSON`.
- Produces:

```swift
struct ReaderReport: Equatable {
    enum Verdict: String, CaseIterable { case readsAsNative = "reads_as_native", readsAsTranslated = "reads_as_translated", mixed }
    enum NoteKind: String, CaseIterable { case unidiomatic, register, rhythm, grammar, inconsistency }
    enum Severity: String, CaseIterable { case minor, major }
    struct Overall: Equatable { let verdict: Verdict; let text: String }
    struct Note: Equatable { let paragraphId: String; let kind: NoteKind; let severity: Severity; let text: String }
    let overall: Overall
    let notes: [Note]
    enum WireField { overall, verdict, text, notes, paragraphId = "paragraph_id", kind, severity }
    static let schemaDescription: String
    static func parse(_ raw: String, briefedParagraphIds: Set<String>) -> ReaderReport?
}
```

- [ ] **Step 1: Failing tests** — new file:

```swift
import XCTest
@testable import Maugham

/// The blind reader's answer (translation pipeline spec §4): one object, an
/// `overall` verdict against the brief's texture line, and notes that can only
/// ever be about fluency. All-or-nothing, `TranslatorReport`'s doctrine.
final class ReaderReportTests: XCTestCase {

    private let briefed: Set<String> = ["k7mq", "a1b2"]

    func test_roundTrip_overallAndNotes() throws {
        let raw = """
            {"overall":{"verdict":"mixed","text":"Reads well until the dialogue."},
             "notes":[{"paragraph_id":"k7mq","kind":"register","severity":"major","text":"Too formal for a bar."}]}
            """
        let report = try XCTUnwrap(ReaderReport.parse(raw, briefedParagraphIds: briefed))
        XCTAssertEqual(report.overall.verdict, .mixed)
        XCTAssertEqual(report.overall.text, "Reads well until the dialogue.")
        XCTAssertEqual(report.notes, [.init(paragraphId: "k7mq", kind: .register, severity: .major, text: "Too formal for a bar.")])
    }

    func test_zeroNotesIsAValidReport() throws {
        let raw = #"{"overall":{"verdict":"reads_as_native","text":"Clean."},"notes":[]}"#
        let report = try XCTUnwrap(ReaderReport.parse(raw, briefedParagraphIds: briefed))
        XCTAssertTrue(report.notes.isEmpty)
        let absent = #"{"overall":{"verdict":"reads_as_native","text":"Clean."}}"#
        XCTAssertEqual(ReaderReport.parse(absent, briefedParagraphIds: briefed)?.notes, [])
    }

    func test_overallIsRequired() {
        XCTAssertNil(ReaderReport.parse(#"{"notes":[]}"#, briefedParagraphIds: briefed))
        XCTAssertNil(ReaderReport.parse(#"{"overall":{"verdict":"mixed","text":""},"notes":[]}"#, briefedParagraphIds: briefed), "empty text refused")
        XCTAssertNil(ReaderReport.parse(#"{"overall":{"verdict":"great","text":"x"},"notes":[]}"#, briefedParagraphIds: briefed), "closed verdict enum")
    }

    func test_aNoteOutsideTheBriefedSetFailsTheReport() {
        let raw = #"{"overall":{"verdict":"mixed","text":"x"},"notes":[{"paragraph_id":"zzzz","kind":"rhythm","severity":"minor","text":"limps"}]}"#
        XCTAssertNil(ReaderReport.parse(raw, briefedParagraphIds: briefed))
    }

    func test_kindAndSeverityAreClosedEnums() {
        let badKind = #"{"overall":{"verdict":"mixed","text":"x"},"notes":[{"paragraph_id":"k7mq","kind":"mistranslation","severity":"minor","text":"y"}]}"#
        XCTAssertNil(ReaderReport.parse(badKind, briefedParagraphIds: briefed), "a reader cannot file an accuracy kind")
        let badSeverity = #"{"overall":{"verdict":"mixed","text":"x"},"notes":[{"paragraph_id":"k7mq","kind":"rhythm","severity":"critical","text":"y"}]}"#
        XCTAssertNil(ReaderReport.parse(badSeverity, briefedParagraphIds: briefed))
    }

    func test_aNoteWithEmptyTextFailsTheReport() {
        let raw = #"{"overall":{"verdict":"mixed","text":"x"},"notes":[{"paragraph_id":"k7mq","kind":"rhythm","severity":"minor","text":"  "}]}"#
        XCTAssertNil(ReaderReport.parse(raw, briefedParagraphIds: briefed))
    }

    func test_proseWrappedFence_takesTheLastCompleteBlock() throws {
        let raw = """
            Here is a draft {"overall":{"verdict":"mixed","text":"draft"}} and the answer:
            ```json
            {"overall":{"verdict":"reads_as_translated","text":"final"},"notes":[]}
            ```
            """
        XCTAssertEqual(try XCTUnwrap(ReaderReport.parse(raw, briefedParagraphIds: briefed)).overall.text, "final")
    }

    func test_wireFieldNamesAppearInTheSchemaDescription() {
        for name in ["overall", "verdict", "text", "notes", "paragraph_id", "kind", "severity",
                     "reads_as_native", "reads_as_translated", "mixed",
                     "unidiomatic", "register", "rhythm", "grammar", "inconsistency", "minor", "major"] {
            XCTAssertTrue(ReaderReport.schemaDescription.contains(name), name)
        }
        XCTAssertTrue(ReaderReport.schemaDescription.contains("Do not rewrite"))
    }
}
```

- [ ] **Step 2: Run to verify failure** — `./scripts/test.sh 2>&1 | grep -E "ReaderReportTests|error:" | head` → compile error.

- [ ] **Step 3: Implement** — `Maugham/Compiler/ReaderReport.swift`:

```swift
import Foundation

/// What one blind read returns (translation pipeline spec §4): an `overall`
/// reader's report with a verdict against the brief's TEXTURE line, and notes
/// that can only be about fluency — the kinds are closed to the reader's remit.
/// A note names a paragraph the reader was briefed with, or the report fails.
struct ReaderReport: Equatable {

    enum Verdict: String, CaseIterable {
        case readsAsNative = "reads_as_native"
        case readsAsTranslated = "reads_as_translated"
        case mixed
    }

    enum NoteKind: String, CaseIterable {
        case unidiomatic, register, rhythm, grammar, inconsistency
    }

    enum Severity: String, CaseIterable { case minor, major }

    struct Overall: Equatable {
        let verdict: Verdict
        let text: String
    }

    struct Note: Equatable {
        let paragraphId: String
        let kind: NoteKind
        let severity: Severity
        let text: String
    }

    let overall: Overall
    let notes: [Note]

    enum WireField {
        static let overall = "overall"
        static let verdict = "verdict"
        static let text = "text"
        static let notes = "notes"
        static let paragraphId = "paragraph_id"
        static let kind = "kind"
        static let severity = "severity"
    }

    static let schemaDescription: String = """
        Respond with exactly one fenced JSON object — no prose before, inside, \
        or after it:
        {"overall":{"verdict":"reads_as_native"|"reads_as_translated"|"mixed",\
        "text":<a short reader's report, to the author>},\
        "notes":[{"paragraph_id":<id>,"kind":"unidiomatic"|"register"|"rhythm"|\
        "grammar"|"inconsistency","severity":"minor"|"major","text":<the note>}]}
        "overall" is required: the verdict is against the edition brief's stated \
        texture, and its "text" is a paragraph written to the author in the \
        author's language. Each note names one paragraph you were shown, gives \
        one kind and one severity from the lists above, and says in the \
        author's language what does not sound like this language there. Do not \
        rewrite; do not suggest a rendering; do not guess what an original said. \
        Zero notes is a complete, valid answer. Any note about a paragraph you \
        were not shown, any empty "text", or any kind or severity outside the \
        lists makes the whole report unusable.
        """

    static func parse(_ raw: String, briefedParagraphIds: Set<String>) -> ReaderReport? {
        guard let object = ReportJSON.lastObject(in: raw, shapedBy: [WireField.overall, WireField.notes]),
              let overallObject = object[WireField.overall] as? [String: Any],
              let verdict = ReportJSON.enumValue(overallObject[WireField.verdict], as: Verdict.self),
              let overallText = ReportJSON.nonEmptyString(overallObject[WireField.text]),
              let notes = ReportJSON.parseList(object, key: WireField.notes, parseItem: {
                  parseNote($0, briefed: briefedParagraphIds)
              })
        else { return nil }
        return ReaderReport(overall: Overall(verdict: verdict, text: overallText), notes: notes)
    }

    private static func parseNote(_ item: [String: Any], briefed: Set<String>) -> Note? {
        guard let paragraphId = ReportJSON.nonEmptyString(item[WireField.paragraphId]),
              briefed.contains(paragraphId),
              let kind = ReportJSON.enumValue(item[WireField.kind], as: NoteKind.self),
              let severity = ReportJSON.enumValue(item[WireField.severity], as: Severity.self),
              let text = ReportJSON.nonEmptyString(item[WireField.text])
        else { return nil }
        return Note(paragraphId: paragraphId, kind: kind, severity: severity, text: text)
    }
}
```

- [ ] **Step 4: Run** — `./scripts/test.sh 2>&1 | tail -5` → green.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Compiler/ReaderReport.swift MaughamTests/ReaderReportTests.swift
git commit -m "feat(compiler): ReaderReport — the blind reader's verdict and fluency-only notes, all-or-nothing

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: `CollatorReport`

**Files:**
- Create: `Maugham/Compiler/CollatorReport.swift`
- Test: `MaughamTests/CollatorReportTests.swift`

**Interfaces:**
- Consumes: `ReportJSON`.
- Produces:

```swift
struct CollatorReport: Equatable {
    enum Verdict: String, CaseIterable { case holds, drifted }
    enum Kind: String, CaseIterable { case mistranslation, omission, addition, untranslated, inconsistency, rendering }
    struct Departure: Equatable { let paragraphId: String; let verdict: Verdict; let kind: Kind; let note: String; let gloss: String }
    let overall: String
    let departures: [Departure]
    var drifted: [Departure]   // the fix leg's input
    enum WireField { overall, text, departures, paragraphId = "paragraph_id", verdict, kind, note, gloss }
    static let schemaDescription: String
    static func parse(_ raw: String, briefedParagraphIds: Set<String>) -> CollatorReport?
}
```

- [ ] **Step 1: Failing tests** — new file:

```swift
import XCTest
@testable import Maugham

/// The collator's answer (translation pipeline spec §4): how the two texts
/// hold together, and every departure with a verdict, a kind and — required —
/// a gloss back into the author's language, so the author can rule on it.
final class CollatorReportTests: XCTestCase {

    private let briefed: Set<String> = ["k7mq", "a1b2"]

    func test_roundTrip_overallAndDepartures() throws {
        let raw = """
            {"overall":{"text":"Faithful, one drift in the argument."},
             "departures":[
               {"paragraph_id":"k7mq","verdict":"holds","kind":"rendering","note":"The pun is re-made on 'luz'.","gloss":"The light went out, and so did she."},
               {"paragraph_id":"a1b2","verdict":"drifted","kind":"omission","note":"Second clause dropped.","gloss":"He waited."}]}
            """
        let report = try XCTUnwrap(CollatorReport.parse(raw, briefedParagraphIds: briefed))
        XCTAssertEqual(report.overall, "Faithful, one drift in the argument.")
        XCTAssertEqual(report.departures.count, 2)
        XCTAssertEqual(report.departures[0].verdict, .holds)
        XCTAssertEqual(report.departures[0].kind, .rendering)
        XCTAssertEqual(report.departures[1].gloss, "He waited.")
        XCTAssertEqual(report.drifted.map(\.paragraphId), ["a1b2"])
    }

    func test_zeroDeparturesIsAValidReport() throws {
        let report = try XCTUnwrap(CollatorReport.parse(#"{"overall":{"text":"Clean."}}"#, briefedParagraphIds: briefed))
        XCTAssertTrue(report.departures.isEmpty)
    }

    func test_overallIsRequiredAndNonEmpty() {
        XCTAssertNil(CollatorReport.parse(#"{"departures":[]}"#, briefedParagraphIds: briefed))
        XCTAssertNil(CollatorReport.parse(#"{"overall":{"text":" "},"departures":[]}"#, briefedParagraphIds: briefed))
    }

    func test_glossIsRequiredOnEveryDeparture() {
        let raw = #"{"overall":{"text":"x"},"departures":[{"paragraph_id":"k7mq","verdict":"drifted","kind":"addition","note":"n"}]}"#
        XCTAssertNil(CollatorReport.parse(raw, briefedParagraphIds: briefed))
        let blank = #"{"overall":{"text":"x"},"departures":[{"paragraph_id":"k7mq","verdict":"drifted","kind":"addition","note":"n","gloss":""}]}"#
        XCTAssertNil(CollatorReport.parse(blank, briefedParagraphIds: briefed))
    }

    func test_aDepartureOutsideTheBriefedSetFailsTheReport() {
        let raw = #"{"overall":{"text":"x"},"departures":[{"paragraph_id":"zzzz","verdict":"holds","kind":"rendering","note":"n","gloss":"g"}]}"#
        XCTAssertNil(CollatorReport.parse(raw, briefedParagraphIds: briefed))
    }

    func test_verdictAndKindAreClosedEnums() {
        let badVerdict = #"{"overall":{"text":"x"},"departures":[{"paragraph_id":"k7mq","verdict":"maybe","kind":"rendering","note":"n","gloss":"g"}]}"#
        XCTAssertNil(CollatorReport.parse(badVerdict, briefedParagraphIds: briefed))
        let badKind = #"{"overall":{"text":"x"},"departures":[{"paragraph_id":"k7mq","verdict":"holds","kind":"rhythm","note":"n","gloss":"g"}]}"#
        XCTAssertNil(CollatorReport.parse(badKind, briefedParagraphIds: briefed), "a collator cannot file a fluency kind")
    }

    func test_wireFieldNamesAppearInTheSchemaDescription() {
        for name in ["overall", "text", "departures", "paragraph_id", "verdict", "kind", "note", "gloss",
                     "holds", "drifted", "mistranslation", "omission", "addition", "untranslated",
                     "inconsistency", "rendering"] {
            XCTAssertTrue(CollatorReport.schemaDescription.contains(name), name)
        }
    }
}
```

- [ ] **Step 2: Run to verify failure** — compile error on `CollatorReport`.

- [ ] **Step 3: Implement** — `Maugham/Compiler/CollatorReport.swift`:

```swift
import Foundation

/// What one collation returns (translation pipeline spec §4): an `overall`
/// paragraph on how the two texts hold together, and every departure with a
/// verdict (`holds` — still says what the source says; `drifted` — meaning
/// moved), an accuracy kind, a note, and a **gloss**: the literal back-rendering
/// of what the translation now says there, in the author's language. The gloss
/// is required, because it is the only thing on this report an author who
/// cannot read the language can rule on.
struct CollatorReport: Equatable {

    enum Verdict: String, CaseIterable { case holds, drifted }

    enum Kind: String, CaseIterable {
        case mistranslation, omission, addition, untranslated, inconsistency, rendering
    }

    struct Departure: Equatable {
        let paragraphId: String
        let verdict: Verdict
        let kind: Kind
        let note: String
        let gloss: String
    }

    let overall: String
    let departures: [Departure]

    /// The fix leg's input: only what moved meaning. `holds` departures are
    /// information for the author, never work for the translator.
    var drifted: [Departure] { departures.filter { $0.verdict == .drifted } }

    enum WireField {
        static let overall = "overall"
        static let text = "text"
        static let departures = "departures"
        static let paragraphId = "paragraph_id"
        static let verdict = "verdict"
        static let kind = "kind"
        static let note = "note"
        static let gloss = "gloss"
    }

    static let schemaDescription: String = """
        Respond with exactly one fenced JSON object — no prose before, inside, \
        or after it:
        {"overall":{"text":<how the translation holds together with the original, to the author>},\
        "departures":[{"paragraph_id":<id>,"verdict":"holds"|"drifted",\
        "kind":"mistranslation"|"omission"|"addition"|"untranslated"|"inconsistency"|"rendering",\
        "note":<why this is a departure>,"gloss":<a literal rendering, into the author's language, of what the translation now says here>}]}
        "overall" is required and written to the author in the author's language. \
        A departure is any place the translation does not say what the original \
        says: "holds" when it still means the same thing (a pun re-made, a \
        sentence split — kind "rendering"), "drifted" when meaning moved. A name \
        or term rendered two ways across the document is kind "inconsistency". \
        Every departure carries a "gloss" — never empty — so the author can judge \
        it without reading the language. Zero departures is a complete, valid \
        answer. Any departure about a paragraph you were not shown, any empty \
        field, or any verdict or kind outside the lists makes the whole report \
        unusable.
        """

    static func parse(_ raw: String, briefedParagraphIds: Set<String>) -> CollatorReport? {
        guard let object = ReportJSON.lastObject(in: raw, shapedBy: [WireField.overall, WireField.departures]),
              let overallObject = object[WireField.overall] as? [String: Any],
              let overall = ReportJSON.nonEmptyString(overallObject[WireField.text]),
              let departures = ReportJSON.parseList(object, key: WireField.departures, parseItem: {
                  parseDeparture($0, briefed: briefedParagraphIds)
              })
        else { return nil }
        return CollatorReport(overall: overall, departures: departures)
    }

    private static func parseDeparture(_ item: [String: Any], briefed: Set<String>) -> Departure? {
        guard let paragraphId = ReportJSON.nonEmptyString(item[WireField.paragraphId]),
              briefed.contains(paragraphId),
              let verdict = ReportJSON.enumValue(item[WireField.verdict], as: Verdict.self),
              let kind = ReportJSON.enumValue(item[WireField.kind], as: Kind.self),
              let note = ReportJSON.nonEmptyString(item[WireField.note]),
              let gloss = ReportJSON.nonEmptyString(item[WireField.gloss])
        else { return nil }
        return Departure(paragraphId: paragraphId, verdict: verdict, kind: kind, note: note, gloss: gloss)
    }
}
```

- [ ] **Step 4: Run** — `./scripts/test.sh 2>&1 | tail -5` → green.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Compiler/CollatorReport.swift MaughamTests/CollatorReportTests.swift
git commit -m "feat(compiler): CollatorReport — departures with a verdict, an accuracy kind and a required gloss

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: `TranslatorReport` in fix mode — addressed, declined, summary, glossary proposals

**Files:**
- Modify: `Maugham/Compiler/TranslatorReport.swift`
- Test: `MaughamTests/TranslatorReportTests.swift`

**Interfaces:**
- Consumes: `ReportJSON`.
- Produces:

```swift
extension TranslatorReport {
    struct Declined: Equatable { let noteId: String; let reason: String }
    struct GlossaryProposal: Equatable { let term: String; let rendering: String; let reason: String }
    enum Mode: Equatable {
        case translate
        /// The note ids this leg was briefed with; every one must be addressed or declined.
        case fix(briefedNoteIds: Set<String>)
    }
    let addressed: [String]
    let declined: [Declined]
    let summary: String?
    let glossaryProposals: [GlossaryProposal]
    static func parse(_ raw: String, mode: Mode = .translate) -> TranslatorReport?
    static let fixSchemaDescription: String   // the extra paragraph a fix leg's briefing appends
}
```

`WireField` gains `addressed`, `declined`, `noteId = "note_id"`, `reason`, `summary`, `glossaryProposals = "glossary_proposals"`, `term`, `rendering`. The existing memberwise use `TranslatorReport(entries:queries:)` keeps working through an explicit init with defaults.

- [ ] **Step 1: Failing tests** — append to `TranslatorReportTests` under `// MARK: - Fix mode (translation pipeline P1)`:

```swift
    // MARK: - Fix mode (translation pipeline P1)

    private let briefedNotes: Set<String> = ["n1", "n2", "n3"]

    func test_fixMode_roundTrip_addressedDeclinedSummaryAndGlossary() throws {
        let raw = """
            {"entries":[{"paragraph_id":"k7mq","text":"Nueva versión."}],
             "queries":[],
             "addressed":["n1","n2"],
             "declined":[{"note_id":"n3","reason":"The fragment is the author's."}],
             "summary":"Two repaired; one stands.",
             "glossary_proposals":[{"term":"October","rendering":"Octubre","reason":"the month"}]}
            """
        let report = try XCTUnwrap(TranslatorReport.parse(raw, mode: .fix(briefedNoteIds: briefedNotes)))
        XCTAssertEqual(report.addressed, ["n1", "n2"])
        XCTAssertEqual(report.declined, [.init(noteId: "n3", reason: "The fragment is the author's.")])
        XCTAssertEqual(report.summary, "Two repaired; one stands.")
        XCTAssertEqual(report.glossaryProposals, [.init(term: "October", rendering: "Octubre", reason: "the month")])
    }

    func test_fixMode_everyBriefedNoteMustAppearExactlyOnce() {
        let missing = #"{"entries":[],"addressed":["n1"],"declined":[{"note_id":"n2","reason":"r"}]}"#
        XCTAssertNil(TranslatorReport.parse(missing, mode: .fix(briefedNoteIds: briefedNotes)), "n3 unaccounted for — silence is refused")
        let twice = #"{"entries":[],"addressed":["n1","n2","n3"],"declined":[{"note_id":"n3","reason":"r"}]}"#
        XCTAssertNil(TranslatorReport.parse(twice, mode: .fix(briefedNoteIds: briefedNotes)))
        let duplicate = #"{"entries":[],"addressed":["n1","n1","n2","n3"]}"#
        XCTAssertNil(TranslatorReport.parse(duplicate, mode: .fix(briefedNoteIds: briefedNotes)))
        let unknown = #"{"entries":[],"addressed":["n1","n2","n3","n9"]}"#
        XCTAssertNil(TranslatorReport.parse(unknown, mode: .fix(briefedNoteIds: briefedNotes)), "an id from another pass fails the report")
    }

    func test_fixMode_withNoBriefedNotesAcceptsEmptyLists() throws {
        let raw = #"{"entries":[],"summary":"Nothing to fix."}"#
        let report = try XCTUnwrap(TranslatorReport.parse(raw, mode: .fix(briefedNoteIds: [])))
        XCTAssertEqual(report.summary, "Nothing to fix.")
        XCTAssertTrue(report.addressed.isEmpty)
    }

    func test_fixMode_aDeclineNeedsAReasonAndAProposalNeedsAllThreeFields() {
        let noReason = #"{"entries":[],"addressed":["n1","n2"],"declined":[{"note_id":"n3"}]}"#
        XCTAssertNil(TranslatorReport.parse(noReason, mode: .fix(briefedNoteIds: briefedNotes)))
        let badProposal = #"{"entries":[],"addressed":["n1","n2","n3"],"glossary_proposals":[{"term":"x","rendering":"y"}]}"#
        XCTAssertNil(TranslatorReport.parse(badProposal, mode: .fix(briefedNoteIds: briefedNotes)))
    }

    func test_translateMode_ignoresTheFixFieldsAndReadsThemEmpty() throws {
        let raw = #"{"entries":[],"queries":[],"addressed":["n1"],"summary":"x","glossary_proposals":[{"term":"a","rendering":"b","reason":"c"}]}"#
        let report = try XCTUnwrap(TranslatorReport.parse(raw))
        XCTAssertTrue(report.addressed.isEmpty)
        XCTAssertNil(report.summary)
        XCTAssertTrue(report.glossaryProposals.isEmpty)
    }

    func test_fixSchemaDescriptionNamesEveryFixField() {
        for name in ["addressed", "declined", "note_id", "reason", "summary", "glossary_proposals", "term", "rendering"] {
            XCTAssertTrue(TranslatorReport.fixSchemaDescription.contains(name), name)
        }
        XCTAssertTrue(TranslatorReport.fixSchemaDescription.contains("exactly one of"))
        XCTAssertFalse(TranslatorReport.schemaDescription.contains("addressed"), "the translate contract is unchanged")
    }
```

- [ ] **Step 2: Run to verify failure** — compile errors on `Mode`, `addressed`.

- [ ] **Step 3: Implement.** In `TranslatorReport`:

```swift
    struct Declined: Equatable {
        let noteId: String
        let reason: String
    }

    struct GlossaryProposal: Equatable {
        let term: String
        let rendering: String
        let reason: String
    }

    /// Which leg is reading. `.fix` carries the note ids the leg was briefed
    /// with, and the parser holds the report to them: every one in exactly one
    /// of `addressed`/`declined`, none from anywhere else. Silence on a note
    /// fails the report (spec §4) — an unaddressed note would otherwise land in
    /// the author's queue with no verdict from anybody.
    enum Mode: Equatable {
        case translate
        case fix(briefedNoteIds: Set<String>)
    }

    let entries: [Entry]
    let queries: [Query]
    let addressed: [String]
    let declined: [Declined]
    let summary: String?
    let glossaryProposals: [GlossaryProposal]

    init(entries: [Entry], queries: [Query], addressed: [String] = [],
         declined: [Declined] = [], summary: String? = nil,
         glossaryProposals: [GlossaryProposal] = []) {
        self.entries = entries
        self.queries = queries
        self.addressed = addressed
        self.declined = declined
        self.summary = summary
        self.glossaryProposals = glossaryProposals
    }
```

`WireField` additions:

```swift
        static let addressed = "addressed"
        static let declined = "declined"
        static let noteId = "note_id"
        static let reason = "reason"
        static let summary = "summary"
        static let glossaryProposals = "glossary_proposals"
        static let term = "term"
        static let rendering = "rendering"
```

The fix-leg contract paragraph:

```swift
    /// Appended to `schemaDescription` by a fix leg's briefing (spec §2).
    static let fixSchemaDescription: String = """
        This is a repair of the noted paragraphs, not a polish: an entry for a \
        paragraph you were not asked to fix makes the report unusable. The \
        object also carries "addressed": [note_id, …] for every note you \
        rewrote in response to, and "declined": [{"note_id":<id>,"reason":<why \
        the translation stands>}] for every note you stand against. Every note \
        you were given must appear in exactly one of the two — never neither, \
        never both. "summary" is a short paragraph, in the author's language, \
        saying what this round settled. "glossary_proposals": [{"term":<in the \
        source language>,"rendering":<in this edition's language>,"reason":<why>}] \
        names terms the edition should fix a rendering for.
        """
```

`parse`:

```swift
    static func parse(_ raw: String, mode: Mode = .translate) -> TranslatorReport? {
        guard let object = ReportJSON.lastObject(in: raw, shapedBy: [WireField.entries, WireField.queries,
                                                                      WireField.addressed, WireField.summary]),
              let entries = ReportJSON.parseList(object, key: WireField.entries, parseItem: parseEntry),
              let queries = ReportJSON.parseList(object, key: WireField.queries, parseItem: parseQuery)
        else { return nil }

        guard case .fix(let briefed) = mode else {
            return TranslatorReport(entries: entries, queries: queries)
        }
        guard let addressed = parseIdList(object, key: WireField.addressed),
              let declined = ReportJSON.parseList(object, key: WireField.declined, parseItem: parseDeclined),
              let proposals = ReportJSON.parseList(object, key: WireField.glossaryProposals,
                                                   parseItem: parseGlossaryProposal),
              accounts(for: briefed, addressed: addressed, declined: declined)
        else { return nil }
        let summary = ReportJSON.nonEmptyString(object[WireField.summary])
        return TranslatorReport(entries: entries, queries: queries, addressed: addressed,
                                declined: declined, summary: summary, glossaryProposals: proposals)
    }

    /// Every briefed id in exactly one list; nothing in either list that was
    /// not briefed; no id twice.
    private static func accounts(for briefed: Set<String>, addressed: [String], declined: [Declined]) -> Bool {
        let all = addressed + declined.map(\.noteId)
        guard Set(all).count == all.count else { return false }
        return Set(all) == briefed
    }

    private static func parseIdList(_ object: [String: Any], key: String) -> [String]? {
        guard let value = object[key] else { return [] }
        guard let raw = value as? [Any] else { return nil }
        var ids: [String] = []
        for element in raw {
            guard let id = ReportJSON.nonEmptyString(element) else { return nil }
            ids.append(id)
        }
        return ids
    }

    private static func parseDeclined(_ item: [String: Any]) -> Declined? {
        guard let noteId = ReportJSON.nonEmptyString(item[WireField.noteId]),
              let reason = ReportJSON.nonEmptyString(item[WireField.reason]) else { return nil }
        return Declined(noteId: noteId, reason: reason)
    }

    private static func parseGlossaryProposal(_ item: [String: Any]) -> GlossaryProposal? {
        guard let term = ReportJSON.nonEmptyString(item[WireField.term]),
              let rendering = ReportJSON.nonEmptyString(item[WireField.rendering]),
              let reason = ReportJSON.nonEmptyString(item[WireField.reason]) else { return nil }
        return GlossaryProposal(term: term, rendering: rendering, reason: reason)
    }
```

Update the type's header doc: "two arrays" becomes "two arrays in translate mode, and in a fix leg the four fields `Mode` describes". `TranslatorOrchestrator.finish`'s existing `TranslatorReport.parse(text)` compiles unchanged through the default.

- [ ] **Step 4: Run** — `./scripts/test.sh 2>&1 | tail -5` → green, including every pre-existing `TranslatorReportTests` case and `TranslatorOrchestratorTests`.

- [ ] **Step 5: Commit**

```bash
git add Maugham/Compiler/TranslatorReport.swift MaughamTests/TranslatorReportTests.swift
git commit -m "feat(compiler): TranslatorReport in fix mode — every briefed note addressed or declined, a summary, glossary proposals

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Whole-plan gate

- [ ] `swift test --parallel --package-path Packages/MaughamCore` green.
- [ ] `./scripts/test.sh full` green (no skips).
- [ ] `grep -rn "objectSpans" Maugham/Compiler` shows exactly two definitions: `ReportJSON` and `DiagnosticIngest`.
- [ ] Whole-branch review (CLAUDE.md default workflow #9) before merge.

## What this plan deliberately leaves to Plan 2

Briefings (`ReaderBriefing`, `CollatorBriefing`, `TranslatorBriefing.mode` and the *directed* work-list), the sealed `ClaudeCLISession` confinement and `ColdCall`, the cast sheet's three fields, and **Translator's note…** in the editor. Plan 2 is written against this plan's built code.
