import XCTest
@testable import Maugham

final class GuideDocsDriftTests: XCTestCase {
    /// Repo root = two levels up from MaughamTests/GuideDocsDriftTests.swift
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MaughamTests/
            .deletingLastPathComponent()   // repo root
    }

    func test_indexMatchesFilesExactly() throws {
        let guideDir = repoRoot.appendingPathComponent("docs/guide")
        let index = try HelpTopicIndex(directory: guideDir)
        let slugsInIndex = Set(index.topics.map(\.slug))

        let mdFiles = try FileManager.default
            .contentsOfDirectory(at: guideDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
            .map { $0.deletingPathExtension().lastPathComponent }
        let slugsOnDisk = Set(mdFiles)

        XCTAssertFalse(slugsInIndex.isEmpty, "index.json lists no topics — the census would be vacuous")
        let drift = Self.indexDrift(slugsInIndex: slugsInIndex, slugsOnDisk: slugsOnDisk)
        XCTAssertEqual(drift, IndexDrift(indexOnly: [], fileOnly: []),
            "index.json and docs/guide/*.md disagree: index-only=\(drift.indexOnly) file-only=\(drift.fileOnly)")
    }

    // MARK: - The index census, as a function a planted offender can reach

    struct IndexDrift: Equatable {
        /// Listed in index.json with no `.md` beside it — Help shows a topic that cannot open.
        var indexOnly: Set<String>
        /// A `.md` the index never lists — written, bundled, and unreachable from Help.
        var fileOnly: Set<String>
    }

    static func indexDrift(slugsInIndex: Set<String>, slugsOnDisk: Set<String>) -> IndexDrift {
        IndexDrift(indexOnly: slugsInIndex.subtracting(slugsOnDisk),
                   fileOnly: slugsOnDisk.subtracting(slugsInIndex))
    }

    /// Self-check: the census reports BOTH directions — a file the index forgot,
    /// and an index entry with no file — and reports nothing when they agree.
    func test_theIndexCensusFiresOnPlantedOffenders() {
        let drift = Self.indexDrift(
            slugsInIndex: ["getting-started", "reference", "no-such-topic"],
            slugsOnDisk: ["getting-started", "reference", "unindexed-topic"])
        XCTAssertEqual(drift.indexOnly, ["no-such-topic"],
                       "an index entry with no file must be reported")
        XCTAssertEqual(drift.fileOnly, ["unindexed-topic"],
                       "a guide file the index never lists must be reported")
        XCTAssertEqual(Self.indexDrift(slugsInIndex: ["a", "b"], slugsOnDisk: ["b", "a"]),
                       IndexDrift(indexOnly: [], fileOnly: []),
                       "a census that agrees must report nothing, or the guard is a wall")
    }

    // MARK: - Every relative link and anchor in the guide resolves (#56 E1)

    /// GitHub's heading anchor: strip inline markup, lowercase, drop every
    /// character that is not a letter, digit, mark, `_`, `-` or space, then
    /// spaces → hyphens. So `The History pane (⌘⌥H)` → `the-history-pane-h`
    /// and `Review Mode — reading your own draft cold` →
    /// `review-mode--reading-your-own-draft-cold` (the em dash goes, both
    /// spaces stay).
    static func githubSlug(_ heading: String) -> String {
        var text = heading
        // [label](url) → label
        if let link = try? NSRegularExpression(pattern: #"\[([^\]]*)\]\([^)]*\)"#) {
            text = link.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
        }
        text = text.replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "*", with: "")
            .lowercased()
        var out = ""
        for scalar in text.unicodeScalars {
            let props = scalar.properties
            if scalar == " " {
                out.append("-")
            } else if scalar == "-" || scalar == "_"
                        || props.isAlphabetic
                        || props.numericType != nil
                        || props.generalCategory == .nonspacingMark
                        || props.generalCategory == .spacingMark {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// The text with fenced code blocks removed (their lines blanked, so line
    /// structure survives). Nothing inside a fence is a heading or a link.
    static func withoutFences(_ markdown: String) -> [String] {
        var inFence = false
        return markdown.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                return ""
            }
            return inFence ? "" : line
        }
    }

    /// Every anchor a document's headings produce, with GitHub's `-1`, `-2`
    /// suffixes on a repeated heading.
    static func headingAnchors(in markdown: String) -> Set<String> {
        var seen: [String: Int] = [:]
        var anchors: Set<String> = []
        for line in withoutFences(markdown) {
            guard let match = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) else { continue }
            var heading = String(line[match.upperBound...])
            if let closing = heading.range(of: #"\s+#+\s*$"#, options: .regularExpression) {
                heading.removeSubrange(closing)
            }
            let base = githubSlug(heading.trimmingCharacters(in: .whitespaces))
            let count = seen[base, default: 0]
            seen[base] = count + 1
            anchors.insert(count == 0 ? base : "\(base)-\(count)")
        }
        return anchors
    }

    /// Every relative link target (`other.md`, `other.md#anchor`, `#anchor`)
    /// outside fences and code spans. Absolute URLs (`scheme:`) are skipped.
    static func relativeLinkTargets(in markdown: String) -> [String] {
        guard let codeSpan = try? NSRegularExpression(pattern: #"(`+).+?\1"#),
              let link = try? NSRegularExpression(
                pattern: #"!?\[[^\]]*\]\(<?([^)\s>]+)>?(?:\s+"[^"]*")?\)"#)
        else { return [] }
        var targets: [String] = []
        for rawLine in withoutFences(markdown) {
            let line = codeSpan.stringByReplacingMatches(
                in: rawLine, range: NSRange(rawLine.startIndex..., in: rawLine), withTemplate: "")
            let ns = line as NSString
            for match in link.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let target = ns.substring(with: match.range(at: 1))
                if target.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*:"#, options: .regularExpression) != nil {
                    continue
                }
                targets.append(target)
            }
        }
        return targets
    }

    /// The links in `markdown` (a file in `directory`) that do not resolve: a
    /// target file that does not exist, or an anchor no heading in the target
    /// produces. `read` returns a file's text, or nil when it does not exist.
    static func brokenLinks(in markdown: String,
                            directory: URL,
                            read: (URL) -> String?) -> [String] {
        relativeLinkTargets(in: markdown).filter { target in
            let parts = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            let path = String(parts[0]).removingPercentEncoding ?? String(parts[0])
            let anchor = parts.count > 1 ? String(parts[1]) : nil
            let text: String?
            if path.isEmpty {
                text = markdown
            } else {
                text = read(directory.appendingPathComponent(path).standardizedFileURL)
            }
            guard let text else { return true }
            guard let anchor, !anchor.isEmpty else { return false }
            guard path.isEmpty || path.hasSuffix(".md") else { return false }
            return !headingAnchors(in: text).contains(anchor.lowercased())
        }
    }

    private static func readIfPresent(_ url: URL) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func test_everyRelativeLinkAndAnchorInTheGuideResolves() throws {
        let guideDir = repoRoot.appendingPathComponent("docs/guide")
        let files = try FileManager.default
            .contentsOfDirectory(at: guideDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(files.isEmpty, "no docs/guide/*.md found — the check would be vacuous")

        var linkCount = 0
        var anchoredCount = 0
        var broken: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let targets = Self.relativeLinkTargets(in: text)
            linkCount += targets.count
            anchoredCount += targets.filter { $0.contains("#") }.count
            broken += Self.brokenLinks(in: text, directory: guideDir, read: Self.readIfPresent)
                .map { "\(file.lastPathComponent) → \($0)" }
        }
        // Anti-vacuity: the guide carries well over a hundred relative links
        // (2026-10-18), most with anchors. A parser that stopped matching would
        // otherwise pass this test by finding nothing to check.
        XCTAssertGreaterThanOrEqual(linkCount, 60,
            "found only \(linkCount) relative links in docs/guide — has the link parser stopped matching?")
        XCTAssertGreaterThanOrEqual(anchoredCount, 30,
            "found only \(anchoredCount) anchored links in docs/guide — has the anchor parser stopped matching?")
        XCTAssertTrue(broken.isEmpty,
            "docs/guide has link(s) that resolve to no file or no heading: \(broken)")
    }

    /// Self-check: a broken file link and a broken anchor are both reported
    /// against the REAL guide, a real anchor is not, and a link inside a code
    /// span is not a link at all.
    func test_theLinkCheckFiresOnPlantedOffenders() {
        let guideDir = repoRoot.appendingPathComponent("docs/guide")
        let planted = """
        # Planted
        ## A heading here
        ## A heading here
        See [x](reference.md#no-such-heading) and [y](no-such-topic.md).
        But [z](getting-started.md#who-wrote-your-history) is real, and so are
        [self](#a-heading-here), [again](#a-heading-here-1) and
        [the pane](backups-and-history.md#the-history-pane-h).
        Not a link: `[w](nowhere.md)`. Nor [web](https://example.com/x.md).
        [bad self](#a-heading-here-2)
        ```
        [fenced](also-nowhere.md)
        ```
        """
        XCTAssertEqual(
            Self.brokenLinks(in: planted, directory: guideDir, read: Self.readIfPresent),
            ["reference.md#no-such-heading", "no-such-topic.md", "#a-heading-here-2"])
    }

    func test_githubSlugMatchesGitHubsRule() {
        XCTAssertEqual(Self.githubSlug("The History pane (⌘⌥H)"), "the-history-pane-h")
        XCTAssertEqual(Self.githubSlug("Review Mode — reading your own draft cold"),
                       "review-mode--reading-your-own-draft-cold")
        XCTAssertEqual(Self.githubSlug("Claude's `add_suggested_change` tool — two grains"),
                       "claudes-add_suggested_change-tool--two-grains")
        XCTAssertEqual(Self.githubSlug("What I've Learned mode (⌘⌥G)"), "what-ive-learned-mode-g")
    }

    func test_everyTopicMarkdownIsReadableAndNonEmpty() throws {
        let index = try HelpTopicIndex(directory: repoRoot.appendingPathComponent("docs/guide"))
        for topic in index.topics {
            let md = try index.markdown(for: topic.slug)
            XCTAssertFalse(md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "\(topic.slug).md is empty")
        }
    }

    func test_projectYamlBundlesTheGuide() throws {
        let yml = try String(contentsOf: repoRoot.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(yml.contains("path: docs/guide"),
            "project.yml must bundle docs/guide as a resource folder, or the in-app Help window ships empty")
    }
}
