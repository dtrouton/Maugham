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
        "CLAUDE.md": 3_031,  // ratchet: actual size; the hard cap is 4,000 words (foundations plan 1) — raise only with a reason. +19: the Maugham/Models row names its two real guides (final fix wave); +92 at the foundations merge: tripwire rows 54–56 (plans 6/7's censuses), the type-keyed census line, AgentRoster in the Compiler row
        "docs/tripwires.md": 6_791,  // ratchet: actual size; +485 at the foundations merge: rows 54–56, the census-key paragraph, rows 17/24/39/46 name the OpLogStore split's homes
        "docs/testing/TROUBLESHOOTING.md": 4_406,  // ratchet: actual size; +28 over 4,378 for the line naming the old CLAUDE.md phrases comments still cite
        "docs/INDEX.md": 417,  // ratchet: actual size (Core and Publish guides and the recipes line added); +6: Stores line names the project session; +15: the docs/history line (plan 5)
        "Maugham/Canvas/AREA.md": 7_681,  // plan 5: re-templated (47,971 → this); the narrative is in docs/history/canvas.md
        "Maugham/OpLog/AREA.md": 7_759,  // plan 5: re-templated (30,412 → this); the narrative is in docs/history/oplog.md
        "Maugham/Views/AREA.md": 28_289,  // + residue from CLAUDE.md; PersonaMemory claim corrected, 2026-10-17; +572 at the foundations merge: the window family, CentreColumn/CentreRoute/RightColumn/PaletteWallState/PublishCentreModel rows, the session pointer
        "Maugham/Compiler/AREA.md": 23_782,  // + residue from CLAUDE.md, 2026-10-17; +396 at the foundations merge: main's additions since the plans branched and the AgentRoster paragraph
        "Maugham/Stores/AREA.md": 16_389,  // + residue from CLAUDE.md; ProjectStore size claim replaced by an ls, 2026-10-17; +275 at the foundations merge: main's additions since the plans branched and the Project sessions row
        "Maugham/MCP/AREA.md": 8_687,  // + residue from CLAUDE.md, 2026-10-17; +16: the bump-the-catalogue-heading step; +95: main's #44 refused-layout text, merged at the foundations integration
        "MaughamPhone/AREA.md": 5_007,
        "Maugham/Editor/AREA.md": 3_673,
        "Maugham/Updates/AREA.md": 4_089,  // +2,467: main's updater hardening (#67, #87), merged at the foundations integration
        "Maugham/Publish/AREA.md": 1_073,  // new: the Publish cell of CLAUDE.md's area table, 2026-10-17; +38: the pointer to Core's block-kind recipe; +96: the unproducible-format door (foundations plan 7)
        "Packages/MaughamCore/Sources/MaughamCore/AREA.md": 3_085,  // +28: Statement.Kind recipe gains the Persona.panes and one-writer-census steps; +206: the OpLogStore split's six files, DocumentFormat, ProjectType+Capabilities, the ProjectType recipe rewritten for capabilities
    ]

    /// Repo-relative path → the longest line it may hold, in characters.
    /// A single 15,000-character bullet cannot be skimmed or cited.
    static let lineCeilings: [String: Int] = [
        "CLAUDE.md": 515,  // ratchet: actual size; the hard cap is 1,000 characters (foundations plan 1) — raise only with a reason
        "Packages/MaughamCore/Sources/MaughamCore/AREA.md": 1_000,
    ]

    /// Docs whose backticked file names must name a file that exists.
    static let pathCheckedDocs: [String] = [
        "CLAUDE.md",
        "docs/INDEX.md",
        "docs/testing/TROUBLESHOOTING.md",
        "docs/tripwires.md",
        "Packages/MaughamCore/Sources/MaughamCore/AREA.md",
        "Maugham/Canvas/AREA.md",
        "Maugham/OpLog/AREA.md",
    ]

    /// Docs that must carry no milestone tag (a rule outlives the milestone
    /// that made it; the tag is history and belongs in git or an ADR).
    static let untaggedDocs: [String] = [
        "CLAUDE.md",
        "docs/INDEX.md",
        "Packages/MaughamCore/Sources/MaughamCore/AREA.md",
        "Maugham/Canvas/AREA.md",
        "Maugham/OpLog/AREA.md",
    ]

    /// Guides already in the template (Map / Rules / Recipes / Pointers).
    /// Plan 5 adds each area's guide here as it is re-templated.
    static let templatedGuides: [String] = [
        "Packages/MaughamCore/Sources/MaughamCore/AREA.md",
        "Maugham/Canvas/AREA.md",
        "Maugham/OpLog/AREA.md",
    ]

    /// Guides still over the hard cap, awaiting their re-template. Shrinks to
    /// empty by the end of plan 5; a member at or under the cap fails the
    /// census so the set cannot go stale.
    static let notYetTemplated: Set<String> = [
        "Maugham/Views/AREA.md",
        "Maugham/Compiler/AREA.md",
        "Maugham/Stores/AREA.md",
        "Maugham/MCP/AREA.md",
    ]

    static let areaGuideHardCap = 8_000

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

    /// Every `AREA.md` in the repo, found by walking from `repoRoot`. Skips
    /// hidden directories (`.git`, `.superpowers`, `.claude`, `.build`…),
    /// build products, and worktree copies.
    static func areaGuides(under root: URL) -> [String] {
        let skipped: Set<String> = ["DerivedData", "build", "node_modules", "worktrees", "Maugham.xcodeproj"]
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var found: [String] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                if name.hasPrefix(".") || skipped.contains(name) || name.hasPrefix("Maugham-") {
                    walker.skipDescendants()
                }
                continue
            }
            if name == "AREA.md" {
                found.append(String(url.path.dropFirst(root.path.count + 1)))
            }
        }
        return found.sorted()
    }

    /// The problem with a guide's headings, or nil when `## Map`, `## Rules`,
    /// `## Recipes`, `## Pointers` each appear as a heading line, in that order.
    static func templateProblem(in text: String) -> String? {
        let headings = text.components(separatedBy: "\n").filter { $0.hasPrefix("## ") }
        var from = headings.startIndex
        for want in ["## Map", "## Rules", "## Recipes", "## Pointers"] {
            guard let at = headings[from...].firstIndex(of: want) else {
                return headings.contains(want)
                    ? "\(want) is out of order" : "\(want) is missing"
            }
            from = headings.index(after: at)
        }
        return nil
    }

    /// `Task 4`, `P3a`, `P3c plan 2`, `plan 1`, `fix round`, `M4`, `M1A`, an ISO date.
    /// Text inside backtick spans is ignored: a dated file path is a pointer, not history.
    static func milestoneTags(in rawText: String) -> [String] {
        let text = rawText.replacingOccurrences(of: "`[^`]*`", with: " ", options: .regularExpression)
        let pattern = #"\bTask \d+\b|\bP\d[a-c]?\b|\bM\d[A-Z]?\b|\bplan \d+\b|\bfix round\b|\b20\d\d-\d\d-\d\d\b"#
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

    /// Every Core source file is on the Core map (D3). A new file that is
    /// missing fails here, so the map cannot rot into a partial list.
    func test_everyCoreSourceFileIsOnTheCoreMap() throws {
        let dir = Self.repoRoot.appendingPathComponent("Packages/MaughamCore/Sources/MaughamCore")
        let area = try Self.read("Packages/MaughamCore/Sources/MaughamCore/AREA.md")
        // Recursive: the map promises `Inbox/` (and any later subfolder) too.
        // Matched by file name, as the map spells it.
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil))
        var files: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            files.append(url.lastPathComponent)
        }
        files.sort()
        XCTAssertFalse(files.isEmpty, "the control: no Core files found means the scan reads nothing")
        let missing = files.filter { !area.contains("`\($0)`") }
        XCTAssertEqual(missing, [], "Core files missing from Packages/MaughamCore/Sources/MaughamCore/AREA.md's Map")
    }

    func test_untaggedDocsCarryNoMilestoneTag() throws {
        for path in Self.untaggedDocs {
            let tags = Self.milestoneTags(in: try Self.read(path))
            XCTAssertEqual(tags, [], "\(path) carries milestone tags (history belongs in git or an ADR): \(tags)")
        }
    }

    func test_everyAreaGuideFollowsTheTemplate() throws {
        for path in Self.templatedGuides {
            XCTAssertNil(Self.templateProblem(in: try Self.read(path)),
                "\(path) must have ## Map, ## Rules, ## Recipes, ## Pointers in that order")
        }
    }

    func test_noAreaGuideExceedsTheHardCap() throws {
        let guides = Self.areaGuides(under: Self.repoRoot)
        XCTAssertGreaterThanOrEqual(guides.count, 11, "the control: the walk found only \(guides)")
        for path in guides {
            let words = Self.wordCount(try Self.read(path))
            if Self.notYetTemplated.contains(path) {
                XCTAssertGreaterThan(words, Self.areaGuideHardCap,
                    "\(path) holds \(words) words, within the cap: remove it from notYetTemplated")
            } else {
                XCTAssertLessThanOrEqual(words, Self.areaGuideHardCap,
                    "\(path) holds \(words) words, over the \(Self.areaGuideHardCap)-word cap. "
                    + "Move narrative to docs/history/ and re-template it.")
            }
        }
        for path in Self.notYetTemplated {
            XCTAssertTrue(guides.contains(path), "notYetTemplated names \(path), which is not an AREA.md")
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

    /// AGENTS.md is CLAUDE.md under a generated header (scripts/gen-agents-md.sh);
    /// its budget is CLAUDE.md's. Returns the problem, or nil when it is current.
    static func agentsMdProblem(agents: String, claude: String) -> String? {
        let lines = agents.components(separatedBy: "\n")
        guard let first = lines.first, first.contains("GENERATED from CLAUDE.md") else {
            return "AGENTS.md is stale: run scripts/gen-agents-md.sh"
        }
        let body = lines.dropFirst(2).joined(separator: "\n")
        return body == claude ? nil : "AGENTS.md is stale: run scripts/gen-agents-md.sh"
    }

    func test_agentsMdIsCLAUDEmdWithItsGeneratedHeader() throws {
        let problem = Self.agentsMdProblem(agents: try Self.read("AGENTS.md"),
                                           claude: try Self.read("CLAUDE.md"))
        XCTAssertNil(problem)
    }

    func test_theAgentsMdGuardFiresOnAStaleBody() {
        let header = "<!-- GENERATED from CLAUDE.md by scripts/gen-agents-md.sh -->\n\n"
        XCTAssertNil(Self.agentsMdProblem(agents: header + "# Rules\nA\n", claude: "# Rules\nA\n"))
        XCTAssertNotNil(Self.agentsMdProblem(agents: header + "# Rules\nOLD\n", claude: "# Rules\nA\n"))
        XCTAssertNotNil(Self.agentsMdProblem(agents: "# Rules\nA\n", claude: "# Rules\nA\n"),
                        "a missing header is reported")
    }

    // MARK: - Planted controls (each helper fires, and lets clean text through)

    func test_theHelpersFireOnPlantedOffenders() {
        let good = "# X\n\n## Map\n\n## Rules\n\n## Recipes\n\n## Pointers\n"
        XCTAssertNil(Self.templateProblem(in: good))
        XCTAssertNotNil(Self.templateProblem(in: "## Rules\n## Map\n## Recipes\n## Pointers\n"),
                        "Rules before Map is reported")
        XCTAssertNotNil(Self.templateProblem(in: "## Map\n## Rules\n## Pointers\n"),
                        "a missing Recipes is reported")
        XCTAssertNotNil(Self.templateProblem(in: good.replacingOccurrences(of: "## Rules", with: "### Rules")),
                        "a ### heading is not a ## heading")
        XCTAssertEqual(Self.wordCount("one two\nthree\t four  "), 4)
        XCTAssertEqual(Self.longestLine("ab\nabcde\n"), 5)
        XCTAssertEqual(Self.milestoneTags(in: "Shipped in P3c plan 2, Task 4, fix round 1, on 2026-10-17."),
                       ["P3c", "plan 2", "Task 4", "fix round", "2026-10-17"])
        XCTAssertEqual(Self.milestoneTags(in: "See `docs/superpowers/notes/2026-10-17-foundations-audit.md` and `P3a`."), [],
                       "a backticked dated path is a pointer, not a tag")
        XCTAssertEqual(Self.milestoneTags(in: "See `a.md`, written 2026-10-17."), ["2026-10-17"])
        XCTAssertEqual(Self.milestoneTags(in: "Phase 3d was abandoned; tripwire 36 holds."), [],
                       "Phase 3d and tripwire numbers are not milestone tags")
        XCTAssertEqual(Self.milestoneTags(in: "Shipped in M4, reworked in M1A."), ["M4", "M1A"])
        XCTAssertEqual(Self.milestoneTags(in: "The MCP server follows ADR 0019."), [],
                       "MCP and ADR numbers are not milestone tags")
        let missing = Self.unresolvedPaths(
            in: "See `CLAUDE.md`, `Packages/MaughamCore/Package.swift`, `NoSuchFile.swift`, "
                + "`docs/nope.md` and the pattern `Foo*.swift`.",
            repoRoot: Self.repoRoot)
        XCTAssertEqual(missing, ["NoSuchFile.swift", "docs/nope.md"])
    }
}
