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

        XCTAssertEqual(slugsInIndex, slugsOnDisk,
            "index.json and docs/guide/*.md disagree: index-only=\(slugsInIndex.subtracting(slugsOnDisk)) file-only=\(slugsOnDisk.subtracting(slugsInIndex))")
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
