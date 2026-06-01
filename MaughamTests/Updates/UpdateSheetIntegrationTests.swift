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
            UpdateSheet.title(for: .readyToInstall(
                bundleURL: URL(fileURLWithPath: "/tmp/Maugham.app"),
                version: "0.2.0",
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

@MainActor
final class UpdateMenuCommandTests: XCTestCase {
    func test_menuTitle_idle()        { XCTAssertEqual(UpdateMenuCommand.menuTitle(for: .idle), "Check for Updates…") }
    func test_menuTitle_checking()    { XCTAssertEqual(UpdateMenuCommand.menuTitle(for: .checking), "Checking for Updates…") }
    func test_menuTitle_downloading() {
        XCTAssertEqual(
            UpdateMenuCommand.menuTitle(for: .downloading(version: "0.2.0", progress: 0.5)),
            "Downloading Update…")
    }
    func test_menuTitle_ready() {
        XCTAssertEqual(
            UpdateMenuCommand.menuTitle(for: .readyToInstall(
                bundleURL: URL(fileURLWithPath: "/tmp/Maugham.app"),
                version: "0.2.0",
                releaseNotes: "")),
            "Install Update…")
    }
    func test_menuTitle_error() {
        XCTAssertEqual(UpdateMenuCommand.menuTitle(for: .error("x")), "Check for Updates…")
    }
    func test_menuTitle_upToDate() {
        XCTAssertEqual(UpdateMenuCommand.menuTitle(for: .upToDate(currentVersion: "0.1.0")),
                       "Check for Updates…")
    }
}
