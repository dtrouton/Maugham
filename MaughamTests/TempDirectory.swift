import Foundation
import XCTest

/// A temporary directory created on init, removed on `cleanup()`.
/// Use in XCTest by calling `addTeardownBlock` or storing as a property.
final class TempDirectory {
    let url: URL

    init(file: StaticString = #file, line: UInt = #line) {
        let base = FileManager.default.temporaryDirectory
        let name = "MaughamTests-\(UUID().uuidString)"
        self.url = base.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true)
        } catch {
            XCTFail("TempDirectory init failed: \(error)", file: file, line: line)
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }

    deinit { cleanup() }
}
