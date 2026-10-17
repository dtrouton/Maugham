import XCTest

/// **The docs' budgets** (foundations audit 2026-10-17, D1/D5). CLAUDE.md is
/// loaded into every session and every subagent; an AREA.md must be read
/// before its directory is edited. Both grew without limit because nothing
/// measured them. These ceilings RATCHET: a task that cuts a doc lowers its
/// number in the same commit, and no number is ever raised without a reason
/// written beside it.
final class DocBudgetTests: XCTestCase {

    /// Repo-relative path → the most words it may hold.
    static let wordCeilings: [String: Int] = [
        "CLAUDE.md": 14_468,
        "docs/tripwires.md": 6_400,
        "docs/testing/TROUBLESHOOTING.md": 4_400,
        "docs/INDEX.md": 600,
        "Maugham/Canvas/AREA.md": 48_005,
        "Maugham/OpLog/AREA.md": 29_586,
        "Maugham/Views/AREA.md": 27_098,
        "Maugham/Compiler/AREA.md": 23_303,
        "Maugham/Stores/AREA.md": 16_059,
        "Maugham/MCP/AREA.md": 8_490,
        "MaughamPhone/AREA.md": 5_007,
        "Maugham/Editor/AREA.md": 3_673,
        "Maugham/Updates/AREA.md": 1_622,
    ]

    /// Repo-relative path → the longest line it may hold, in characters.
    /// A single 15,000-character bullet cannot be skimmed or cited.
    static let lineCeilings: [String: Int] = [
        "CLAUDE.md": 21_416,
    ]

    /// Docs whose backticked file names must name a file that exists.
    static let pathCheckedDocs: [String] = [
        "docs/INDEX.md",
        "docs/testing/TROUBLESHOOTING.md",
        "docs/tripwires.md",
    ]

    /// Docs that must carry no milestone tag (a rule outlives the milestone
    /// that made it; the tag is history and belongs in git or an ADR).
    static let untaggedDocs: [String] = [
        "docs/INDEX.md",
    ]

    // MARK: - Helpers (pure; the planted controls below exercise them)

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamCoreTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // MaughamCore/
            .deletingLastPathComponent()   // Packages/
            .deletingLastPathComponent()   // repo root
    }

    static func read(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    static func longestLine(_ text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(\.count).max() ?? 0
    }

    /// `Task 4`, `P3a`, `P3c plan 2`, `plan 1`, `fix round`, an ISO date.
    /// Text inside backtick spans is ignored: a dated file path is a pointer, not history.
    static func milestoneTags(in rawText: String) -> [String] {
        let text = rawText.replacingOccurrences(of: "`[^`]*`", with: " ", options: .regularExpression)
        let pattern = #"\bTask \d+\b|\bP\d[a-c]?\b|\bplan \d+\b|\bfix round\b|\b20\d\d-\d\d-\d\d\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    /// Every `` `…something.ext` `` (swift, md, yml, sh, json) that names no
    /// file. With a `/`, the token is repo-relative and must exist exactly; a
    /// bare name must exist somewhere under the searched roots. Tokens with
    /// `*`, `<` or a space are patterns, not files, and are skipped.
    static func unresolvedPaths(in text: String, repoRoot: URL) -> [String] {
        let pattern = #"`([A-Za-z0-9_+./-]+\.(?:swift|md|yml|sh|json))`"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let names = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
        let fm = FileManager.default
        var basenames: Set<String>?
        func allBasenames() -> Set<String> {
            if let basenames { return basenames }
            var found: Set<String> = []
            for root in ["Maugham", "MaughamPhone", "Packages", "MaughamTests",
                         "MaughamPhoneTests", "docs", "scripts", "register", ".github"] {
                let url = repoRoot.appendingPathComponent(root)
                guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: nil)
                else { continue }
                for case let file as URL in walker { found.insert(file.lastPathComponent) }
            }
            for top in (try? fm.contentsOfDirectory(atPath: repoRoot.path)) ?? [] {
                found.insert(top)
            }
            basenames = found
            return found
        }
        var missing: [String] = []
        for name in Set(names).sorted() {
            if name.contains("/") {
                let trimmed = name.hasPrefix("./") ? String(name.dropFirst(2)) : name
                if !fm.fileExists(atPath: repoRoot.appendingPathComponent(trimmed).path) {
                    missing.append(name)
                }
            } else if !allBasenames().contains(name) {
                missing.append(name)
            }
        }
        return missing
    }

    // MARK: - The censuses

    func test_everyBudgetedDocIsWithinItsWordCeiling() throws {
        for (path, ceiling) in Self.wordCeilings.sorted(by: { $0.key < $1.key }) {
            let words = Self.wordCount(try Self.read(path))
            XCTAssertLessThanOrEqual(words, ceiling,
                "\(path) holds \(words) words, over its ceiling of \(ceiling). "
                + "Move detail into the AREA.md, ADR or note it belongs in; "
                + "do not raise the ceiling without a reason beside it.")
        }
    }

    func test_noBudgetedDocHasAnOverlongLine() throws {
        for (path, ceiling) in Self.lineCeilings.sorted(by: { $0.key < $1.key }) {
            let longest = Self.longestLine(try Self.read(path))
            XCTAssertLessThanOrEqual(longest, ceiling,
                "\(path) has a \(longest)-character line, over \(ceiling). Split it.")
        }
    }

    func test_everyBacktickedFileInACheckedDocExists() throws {
        for path in Self.pathCheckedDocs {
            let missing = Self.unresolvedPaths(in: try Self.read(path), repoRoot: Self.repoRoot)
            XCTAssertEqual(missing, [], "\(path) names files that do not exist: \(missing)")
        }
    }

    func test_untaggedDocsCarryNoMilestoneTag() throws {
        for path in Self.untaggedDocs {
            let tags = Self.milestoneTags(in: try Self.read(path))
            XCTAssertEqual(tags, [], "\(path) carries milestone tags (history belongs in git or an ADR): \(tags)")
        }
    }

    func test_theCeilingsNameRealDocs() {
        for path in Set(Self.wordCeilings.keys).union(Self.lineCeilings.keys)
            .union(Self.pathCheckedDocs).union(Self.untaggedDocs) {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: Self.repoRoot.appendingPathComponent(path).path),
                "a budget names \(path), which does not exist: the census would read nothing")
        }
    }

    // MARK: - Planted controls (each helper fires, and lets clean text through)

    func test_theHelpersFireOnPlantedOffenders() {
        XCTAssertEqual(Self.wordCount("one two\nthree\t four  "), 4)
        XCTAssertEqual(Self.longestLine("ab\nabcde\n"), 5)
        XCTAssertEqual(Self.milestoneTags(in: "Shipped in P3c plan 2, Task 4, fix round 1, on 2026-10-17."),
                       ["P3c", "plan 2", "Task 4", "fix round", "2026-10-17"])
        XCTAssertEqual(Self.milestoneTags(in: "See `docs/superpowers/notes/2026-10-17-foundations-audit.md` and `P3a`."), [],
                       "a backticked dated path is a pointer, not a tag")
        XCTAssertEqual(Self.milestoneTags(in: "See `a.md`, written 2026-10-17."), ["2026-10-17"])
        XCTAssertEqual(Self.milestoneTags(in: "Phase 3d was abandoned; tripwire 36 holds."), [],
                       "Phase 3d and tripwire numbers are not milestone tags")
        let missing = Self.unresolvedPaths(
            in: "See `CLAUDE.md`, `Packages/MaughamCore/Package.swift`, `NoSuchFile.swift`, "
                + "`docs/nope.md` and the pattern `Foo*.swift`.",
            repoRoot: Self.repoRoot)
        XCTAssertEqual(missing, ["NoSuchFile.swift", "docs/nope.md"])
    }
}
