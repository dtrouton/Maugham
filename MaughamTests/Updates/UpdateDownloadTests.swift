// MaughamTests/Updates/UpdateDownloadTests.swift
import XCTest
@testable import Maugham

/// The download's decisions are pure and tested here without a network: which
/// errors earn the one retry, where the cap falls, and which extension a file
/// gets. The real delegate path is exercised against a `file://` URL under
/// `TestTemp.root` — a download task reads one like any other, so the move
/// into place and the cap's refusal run through production code offline.
final class UpdateDownloadTests: XCTestCase {

    // MARK: - The retry classifier

    func test_theFourDroppedConnectionErrorsAreTransient() {
        for code in [URLError.Code.networkConnectionLost, .timedOut, .cannotConnectToHost, .notConnectedToInternet] {
            XCTAssertTrue(UpdateDownload.isTransient(URLError(code)), "\(code) should earn the retry")
        }
    }

    func test_everythingElseFailsAtOnce() {
        for code in [URLError.Code.cancelled, .badServerResponse, .secureConnectionFailed,
                     .cannotFindHost, .fileDoesNotExist, .badURL] {
            XCTAssertFalse(UpdateDownload.isTransient(URLError(code)), "\(code) must not be retried")
        }
        XCTAssertFalse(UpdateDownload.isTransient(
            UpdateDownloadError.tooLarge(bytes: 10, limit: 5)), "a refused size is never retried")
        XCTAssertFalse(UpdateDownload.isTransient(UpdateDownloadError.badStatus(404)))
        struct Other: Error {}
        XCTAssertFalse(UpdateDownload.isTransient(Other()))
    }

    func test_theRetryIsExactlyOne() {
        XCTAssertEqual(UpdateDownload.maxAttempts, 2)
    }

    // MARK: - The cap

    func test_theStandardCapIs512MB() {
        XCTAssertEqual(UpdateLimits.standard.maxDownloadBytes, 512 * 1024 * 1024)
    }

    func test_theCapRefusesOnlyWhatIsOverIt() {
        let limits = UpdateLimits(maxDownloadBytes: 1000)
        XCTAssertFalse(UpdateDownload.exceedsCap(receivedBytes: 1000, expectedBytes: 1000, limits: limits),
                       "exactly the cap is allowed")
        XCTAssertTrue(UpdateDownload.exceedsCap(receivedBytes: 1001, expectedBytes: -1, limits: limits),
                      "received bytes past the cap refuse even when the size was never declared")
        XCTAssertTrue(UpdateDownload.exceedsCap(receivedBytes: 0, expectedBytes: 1001, limits: limits),
                      "a declared size past the cap refuses before a byte arrives")
        XCTAssertFalse(UpdateDownload.exceedsCap(receivedBytes: 500, expectedBytes: -1, limits: limits),
                       "an unknown size is never a refusal on its own")
    }

    // MARK: - The extension comes from the asset's name

    func test_theExtensionIsTheAssetNamesNeverTheURLs() {
        XCTAssertEqual(UpdateDownload.fileExtension(forAssetNamed: "Maugham-0.42.0.zip"), "zip")
        XCTAssertEqual(UpdateDownload.fileExtension(forAssetNamed: "Maugham-0.42.0.dmg"), "dmg")
        XCTAssertEqual(UpdateDownload.fileExtension(forAssetNamed: "Maugham-0.42.0.DMG"), "dmg")
        XCTAssertEqual(UpdateDownload.fileExtension(forAssetNamed: "Maugham-0.42.0.sh"), "zip",
                       "only the two kinds the updater handles are ever produced")
    }

    // MARK: - The real delegate path, offline

    private func source(bytes: Int) throws -> URL {
        let url = TestTemp.root.appendingPathComponent("source.zip")
        try Data((0..<bytes).map { UInt8($0 % 251) }).write(to: url)
        return url
    }

    func test_aCompleteDownloadLandsAtTheDestination() async throws {
        let src = try source(bytes: 200_000)
        let dest = TestTemp.root.appendingPathComponent("Maugham-9.9.9.zip.download")
        try await UpdateDownload.download(from: src, to: dest) { _ in }
        XCTAssertEqual(try Data(contentsOf: dest), try Data(contentsOf: src))
    }

    func test_aDownloadOverTheCapLeavesNothingBehind() async throws {
        let src = try source(bytes: 200_000)
        let dest = TestTemp.root.appendingPathComponent("Maugham-9.9.9.zip.download")
        do {
            try await UpdateDownload.download(
                from: src, to: dest, limits: UpdateLimits(maxDownloadBytes: 1000)) { _ in }
            XCTFail("a download past the cap must throw")
        } catch let error as UpdateDownloadError {
            guard case .tooLarge(_, let limit) = error else {
                return XCTFail("expected .tooLarge, got \(error)")
            }
            XCTAssertEqual(limit, 1000)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path),
                       "a refused download leaves no file a later check could reuse")
    }
}
