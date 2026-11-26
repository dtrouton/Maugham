import XCTest
@testable import Maugham

/// **The personas are gone, and no production source may name one** (shell
/// p1 Task 6). The window's subject decides what it shows; there is no mode
/// to switch into, so a type, a parameter, a stored key or a comment that
/// says "persona" describes something that does not exist.
///
/// Greps every production Swift file under `Maugham/` and
/// `Packages/MaughamCore/Sources` — comments included, because a comment that
/// explains a rule by a persona sends the next reader looking for one — for
/// `Persona`/`persona` and anything spelled from it (`personas`,
/// `personaKey`, `PersonaModifier`). The words *personal* and *impersonate*
/// are not the word and are not matched.
///
/// The words Plan, Author, Review and Publish are NOT censused: they survive
/// as `ReviewPass`, "Publish" the feature, `AuthorReader` and the `author`
/// actor key, none of which is a persona.
final class NoPersonaCensusTests: XCTestCase {
    /// The production roots this census reads.
    static let roots = ["Maugham", "Packages/MaughamCore/Sources"]

    /// Files allowed to name a persona. Empty, and meant to stay so.
    static let allowList: Set<String> = []

    /// `persona`, either case of its first letter, as a word or the stem of an
    /// identifier — but not `personal…` or `impersonat…`.
    static let pattern = try! NSRegularExpression(
        pattern: #"[Pp]ersona(?!l|t)"#)

    static func namesAPersona(_ line: String) -> Bool {
        pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    func test_noProductionSourceNamesAPersona() throws {
        let offenders = try Self.offenders()
        XCTAssertEqual(offenders, [],
                       "production source still names a persona:\n"
                       + offenders.joined(separator: "\n"))
    }

    /// The census itself: every Swift file under `roots`, read from `base`,
    /// each offending line as `path:line: text`. The planted control below
    /// runs this same function over a planted tree.
    static func offenders(base: URL = SourceTree.repoRoot) throws -> [String] {
        var offenders: [String] = []
        for root in roots {
            for path in try SourceTree.swiftFiles(under: root, base: base)
            where !allowList.contains(path) {
                let text = try SourceTree.read(path, base: base)
                for (index, line) in text.components(separatedBy: "\n").enumerated()
                where namesAPersona(line) {
                    offenders.append("\(path):\(index + 1): "
                                     + line.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        return offenders.sorted()
    }

    /// **The planted control, end to end**: a tree with an offender under
    /// each root, a doc-comment offender, and a clean file. The walk must
    /// reach both roots and report exactly the offending lines — so a green
    /// census above is a walk that ran, not only a regex that matches.
    func test_theCensusWalkCatchesPlantedFilesUnderBothRoots() throws {
        let base = try SourceTree.plantedTree([
            "Maugham/Views/RogueBar.swift": """
            struct RogueBar {
                let persona: Int
            }
            """,
            "Maugham/Models/Clean.swift": "/// A deeply personalised PDF.\nenum Clean {}\n",
            "Packages/MaughamCore/Sources/MaughamCore/Rogue.swift": """
            /// Plan's Persona decides.
            enum Rogue {}
            """,
        ])
        XCTAssertEqual(try Self.offenders(base: base), [
            "Maugham/Views/RogueBar.swift:2: let persona: Int",
            "Packages/MaughamCore/Sources/MaughamCore/Rogue.swift:1: /// Plan's Persona decides.",
        ])
    }

    /// The census reads real files: it found Swift under both roots.
    func test_theCensusReadsRealSource() throws {
        for root in Self.roots {
            XCTAssertFalse(try SourceTree.swiftFiles(under: root).isEmpty,
                           "\(root) yielded no Swift files — the census is blind")
        }
    }

    /// The planted offenders: each spelling the census exists for must be caught,
    /// and the words that merely contain the letters must not.
    func test_thePatternCatchesEverySpellingAndNoInnocentWord() {
        for planted in ["@State private var persona: Persona = .default",
                        "/// Plan's persona centres the canvas.",
                        "static let personaKey = \"persona\"",
                        ".modifier(PersonaModifier(persona: $persona))",
                        "// every persona's tree", "the Personas are lenses"] {
            XCTAssertTrue(Self.namesAPersona(planted), "the census missed: \(planted)")
        }
        for innocent in ["a deeply personalised PDF", "personal skills directory",
                         "never impersonate a real person", "Personal"] {
            XCTAssertFalse(Self.namesAPersona(innocent), "the census flagged: \(innocent)")
        }
    }
}
