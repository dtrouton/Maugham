import XCTest
@testable import Maugham

final class MaughamSidecarPathTests: XCTestCase {
    let projectURL = URL(fileURLWithPath: "/tmp/test-project")

    func testClassifies_publishTemplate() {
        let url = projectURL.appendingPathComponent(".maugham/publish/template.tex")
        XCTAssertEqual(
            MaughamSidecarPath.classify(url: url, projectURL: projectURL),
            .publishTemplate(relativePath: ".maugham/publish/template.tex")
        )
    }

    func testClassifies_publishStyles() {
        let url = projectURL.appendingPathComponent(".maugham/publish/styles.css")
        XCTAssertEqual(
            MaughamSidecarPath.classify(url: url, projectURL: projectURL),
            .publishStyles(relativePath: ".maugham/publish/styles.css")
        )
    }

    func testClassifies_publishConfig() {
        let url = projectURL.appendingPathComponent(".maugham/publish/config.json")
        XCTAssertEqual(
            MaughamSidecarPath.classify(url: url, projectURL: projectURL),
            .publishConfig
        )
    }

    func testClassifies_publishPartial_preamble() {
        let url = projectURL.appendingPathComponent(".maugham/publish/preamble.tex")
        XCTAssertEqual(
            MaughamSidecarPath.classify(url: url, projectURL: projectURL),
            .publishTemplate(relativePath: ".maugham/publish/preamble.tex")
        )
    }

    func testClassifies_publishCover() {
        let url = projectURL.appendingPathComponent(".maugham/publish/cover.jpg")
        XCTAssertEqual(
            MaughamSidecarPath.classify(url: url, projectURL: projectURL),
            .publishAsset(relativePath: ".maugham/publish/cover.jpg")
        )
    }

    func testClassifies_publishFont() {
        let url = projectURL.appendingPathComponent(".maugham/publish/fonts/EBGaramond-Regular.otf")
        XCTAssertEqual(
            MaughamSidecarPath.classify(url: url, projectURL: projectURL),
            .publishAsset(relativePath: ".maugham/publish/fonts/EBGaramond-Regular.otf")
        )
    }

    func testClassifies_publishBuild_isTransient() {
        let url = projectURL.appendingPathComponent(".maugham/publish/build/body.tex")
        XCTAssertEqual(
            MaughamSidecarPath.classify(url: url, projectURL: projectURL),
            .publishBuild(relativePath: ".maugham/publish/build/body.tex")
        )
    }

    func testClassifies_publicationsLog() {
        let url = projectURL.appendingPathComponent(".maugham/publications.jsonl")
        XCTAssertEqual(
            MaughamSidecarPath.classify(url: url, projectURL: projectURL),
            .publicationsLog
        )
    }

    func testClassifies_publicationSnapshot() {
        let url = projectURL.appendingPathComponent(".maugham/publications/snap-abc123.json")
        XCTAssertEqual(
            MaughamSidecarPath.classify(url: url, projectURL: projectURL),
            .publicationSnapshot(relativePath: ".maugham/publications/snap-abc123.json")
        )
    }

    func testPublishStoreRoundTrip_doesNotPolluteUnknownSidecar() async throws {
        let store = await PublicationStore(projectURL: projectURL)
        try await store.append(Publication(
            publicationID: "pub_x", version: "0.1", label: nil,
            format: .pdf, outputPath: "Exports/x.pdf",
            snapshotID: "snap_x", checkpointID: "chk", republishedFrom: nil,
            compiledAt: Date(), maughamVersion: "0",
            tectonicVersion: "0.15.0"))

        let url = projectURL.appendingPathComponent(".maugham/publications.jsonl")
        XCTAssertEqual(
            MaughamSidecarPath.classify(url: url, projectURL: projectURL),
            .publicationsLog
        )
    }

    func testSnapshotFile_classifiesAsPublicationSnapshot() async throws {
        let store = PublicationSnapshotStore(projectURL: projectURL)
        let snap = PublicationSnapshot(
            snapshotID: "snap-cls",
            createdAt: Date(),
            publishFiles: [],
            config: PublishConfig(metadata: .init(title: "X", author: "Y")),
            maughamVersion: "0", tectonicVersion: "0.15.0")
        try await store.save(snap)

        let url = projectURL.appendingPathComponent(".maugham/publications/snap-cls.json")
        XCTAssertEqual(
            MaughamSidecarPath.classify(url: url, projectURL: projectURL),
            .publicationSnapshot(relativePath: ".maugham/publications/snap-cls.json")
        )
    }
}
