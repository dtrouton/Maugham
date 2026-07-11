import XCTest
import MaughamCore
@testable import Maugham

/// Tripwire-19 cross-surface safety net for palette promotion: a PHONE-shaped
/// inbox entry (the exact snake_case JSON bytes `InboxCaptureWriter` produces,
/// carrying `palette_subject`/`sense`) is seeded, promoted into a palette card
/// via the Mac `InboxStore.promoteToPaletteCard`, and the card is re-parsed from
/// disk through `ProjectStore.loadPaletteCards()` with the new note/image present.
/// The whole write→read loop crosses the phone-writer / Mac-reader boundary.
@MainActor
final class InboxPalettePromoteRoundTripTests: XCTestCase {

    private func openProject() async throws
        -> (URL, ProjectStore, InboxStore, DocumentStore) {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("palette-promote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let url = try await ProjectFactory.createNovelProject(named: "PalettePromote", in: parent)
        let store = try await ProjectStore.load(from: url)
        let ds = try await DocumentStore.open(url: url)
        store.documentStore = ds
        return (url, store, InboxStore(projectURL: url, deviceId: "mac"), ds)
    }

    /// Encode the entry with the phone writer's exact date strategy so the row is
    /// byte-compatible with what MaughamPhone lands on disk, then append it as a
    /// JSONL line — the same seed idiom as `InboxPromoteTests`.
    private func seedPhoneRow(_ url: URL, _ entry: InboxEntry) async throws {
        let file = url.appendingPathComponent(".maugham/inbox/inbox.phone.jsonl")
        let store = JSONLAppendStore<InboxEntry>(fileURL: file)
        try await store.append(entry)
        // Guard the cross-surface key contract: the phone writes snake_case
        // `palette_subject`/`sense`, and the Mac must decode them.
        let raw = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(raw.contains("\"palette_subject\""),
                      "phone-shaped row carries palette_subject")
        XCTAssertTrue(raw.contains("\"sense\""),
                      "phone-shaped row carries sense")
    }

    func test_phoneShapedTextEntry_promotesToCard_andReparsesFromDisk() async throws {
        let (url, store, inbox, ds) = try await openProject()
        let card = try await store.addPaletteCard(title: "The Flat", kind: .location)
        try await seedPhoneRow(url, InboxEntry(
            id: "rt-text", createdAt: Date(timeIntervalSince1970: 100),
            writtenAt: Date(timeIntervalSince1970: 100.001),
            deviceId: "phone", kind: .text,
            inlineText: "turpentine and cold ash",
            paletteSubject: "The Flat", sense: "smell"))
        await inbox.refresh()
        let entry = try XCTUnwrap(inbox.entries.first { $0.id == "rt-text" })

        _ = try await inbox.promoteToPaletteCard(entry, projectStore: store, cardId: card.id)

        // Re-parse the card FROM DISK (not the returned model): the note survives
        // the render→parse round trip.
        let reloaded = try XCTUnwrap(
            store.loadPaletteCards().first { $0.researchItemId == card.id })
        XCTAssertEqual(reloaded.notes.last?.sense, .smell)
        XCTAssertEqual(reloaded.notes.last?.text, "turpentine and cold ash")
        XCTAssertFalse(inbox.entries.contains { $0.id == "rt-text" })
        withExtendedLifetime(ds) {}
    }

    func test_phoneShapedImageEntry_promotesToCard_imageReparsesFromDisk() async throws {
        let (url, store, inbox, ds) = try await openProject()
        let card = try await store.addPaletteCard(title: "Marlowe", kind: .character)
        let imagesDir = url.appendingPathComponent(".maugham/inbox/images")
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        let asset = imagesDir.appendingPathComponent("rt-img.png")
        try Data("fake-image".utf8).write(to: asset)
        try await seedPhoneRow(url, InboxEntry(
            id: "rt-image", createdAt: Date(timeIntervalSince1970: 100),
            writtenAt: Date(timeIntervalSince1970: 100.001),
            deviceId: "phone", kind: .image, sourceFilename: "rt-img.png",
            paletteSubject: "Marlowe", sense: "sight"))
        await inbox.refresh()
        let entry = try XCTUnwrap(inbox.entries.first { $0.id == "rt-image" })

        _ = try await inbox.promoteToPaletteCard(entry, projectStore: store, cardId: card.id)

        let reloaded = try XCTUnwrap(
            store.loadPaletteCards().first { $0.researchItemId == card.id })
        let imagePath = try XCTUnwrap(reloaded.imagePaths.last)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent(imagePath).path),
            "promoted image is present on disk and re-parsed into the card")
        XCTAssertFalse(FileManager.default.fileExists(atPath: asset.path),
                       "inbox original removed")
        withExtendedLifetime(ds) {}
    }
}
