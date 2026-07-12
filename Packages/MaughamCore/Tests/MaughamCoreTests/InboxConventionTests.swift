import XCTest
@testable import MaughamCore

/// `InboxConvention` is the SINGLE SOURCE OF TRUTH for the inbox asset
/// subdir names and the (kind, filename) → URL mapping (E5a — mirrors
/// `PaletteConvention`). These assertions are the cross-surface contract:
/// a PHONE-shaped path construction (join `inboxDir` + the kind's subdir,
/// then the asset filename — the shape `InboxCaptureWriter` uses) and a
/// MAC-shaped resolution (`assetURL(kind:filename:inboxDir:)` — the shape
/// `InboxStore.assetURL(for:)` uses) must land on the identical URL, because
/// both go through this one helper.
final class InboxConventionTests: XCTestCase {
    private let inboxDir = URL(fileURLWithPath: "/tmp/TestProject/.maugham/inbox")

    func test_assetSubdir_mapsKindToDirName() {
        XCTAssertEqual(InboxConvention.assetSubdir(for: .image), "images")
        XCTAssertEqual(InboxConvention.assetSubdir(for: .audio), "audio")
        XCTAssertNil(InboxConvention.assetSubdir(for: .text))
    }

    func test_phoneWriterShapedPath_and_macReaderShapedPath_agree_forImage() {
        let filename = "01ABCDEFGHJKMNPQ.jpg"
        // Phone-writer shape: the writer joins inboxDir + kind's subdir to get
        // a destination directory, then appends the freshly-minted asset name.
        let writerURL = inboxDir
            .appendingPathComponent(InboxConvention.imagesSubdir, isDirectory: true)
            .appendingPathComponent(filename)

        // Mac-reader shape: resolve straight from (kind, filename) via the
        // choke-point, the way InboxStore.assetURL(for:) does at promote time.
        let readerURL = InboxConvention.assetURL(kind: .image, filename: filename, inboxDir: inboxDir)

        XCTAssertEqual(readerURL, writerURL,
            "phone-writer-shaped and Mac-reader-shaped resolution must land on the same URL")
    }

    func test_phoneWriterShapedPath_and_macReaderShapedPath_agree_forAudio() {
        let filename = "01ABCDEFGHJKMNPQ.m4a"
        let writerURL = inboxDir
            .appendingPathComponent(InboxConvention.audioSubdir, isDirectory: true)
            .appendingPathComponent(filename)

        let readerURL = InboxConvention.assetURL(kind: .audio, filename: filename, inboxDir: inboxDir)

        XCTAssertEqual(readerURL, writerURL,
            "phone-writer-shaped and Mac-reader-shaped resolution must land on the same URL")
    }

    func test_assetURL_text_returnsNil() {
        XCTAssertNil(InboxConvention.assetURL(kind: .text, filename: "whatever", inboxDir: inboxDir))
    }

    func test_assetDir_text_returnsNil() {
        XCTAssertNil(InboxConvention.assetDir(for: .text, inboxDir: inboxDir))
    }
}
