import XCTest
import SwiftUI
@testable import Maugham

@MainActor
final class UpdateSheetIntegrationTests: XCTestCase {
    func test_titleForIdle() {
        XCTAssertEqual(UpdateSheet.title(for: .idle), "Check for Updates")
    }

    func test_titleForChecking() {
        XCTAssertEqual(UpdateSheet.title(for: .checking), "Checking for Updates…")
    }

    func test_titleForDownloading() {
        XCTAssertEqual(
            UpdateSheet.title(for: .downloading(version: "0.2.0", progress: 0.5)),
            "Downloading Maugham 0.2.0…")
    }

    func test_titleForReady() {
        XCTAssertEqual(
            UpdateSheet.title(for: .ready(
                version: "0.2.0",
                dmgURL: URL(fileURLWithPath: "/x"),
                releaseNotes: "notes")),
            "Maugham 0.2.0 is Ready to Install")
    }

    func test_titleForError() {
        XCTAssertEqual(
            UpdateSheet.title(for: .error("boom")),
            "Couldn't Check for Updates")
    }

    func test_titleForUpToDate() {
        XCTAssertEqual(
            UpdateSheet.title(for: .upToDate(currentVersion: "0.1.0")),
            "Maugham 0.1.0 is Up to Date")
    }
}
