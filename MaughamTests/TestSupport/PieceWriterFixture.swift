import XCTest
import AppKit
import SwiftUI
@testable import MaughamCore
@testable import Maugham

/// **A real book on disk with a scoped author in it** — the fixture the
/// surfaces that say whose piece is whose need (To resolve's head, the
/// Outline's column) and nothing else had (P3b Task 9).
///
/// Every earlier surface in this milestone could be pinned as a value, because
/// each one is a pure model over a registry a test could hand it. These two
/// cannot be: the row and the column read a `PieceWriters` the VIEW resolved,
/// off a folder, in a `.task` — so the only honest question to ask of them is
/// whether the thing is drawn over a book that really is narrowed.
///
/// **It injects all four of `Document`'s process-wide seams and clears them.**
/// An admission writes this Mac's own memory of what it has verified and what
/// it calls the devices it has let in; a suite that admitted a throwaway key
/// without injecting those would leave the writer's real memory holding a
/// label for a key that will never exist again.
@MainActor
enum PieceWriterFixture {

    struct Book {
        let url: URL
        let store: ProjectStore
        let documentStore: DocumentStore
        /// Every document id in the book, in binder order.
        let pieceIDs: [String]
    }

    /// A project nobody has ever been admitted to — every book written before
    /// P3, and every book with one writer in it.
    static func oneAuthor(named name: String, in directory: URL) async throws -> Book {
        try await open(named: name, in: directory)
    }

    /// The same project, with one other person in it whose permit names
    /// `scopedTo` and nothing else. Driven through the production verbs, so
    /// the record, the event and the manifest's schema gate all move the way
    /// they move for a writer.
    static func narrowed(
        named name: String, in directory: URL, scopedTo pieces: (Book) -> [String],
        label: String = "Sam"
    ) async throws -> Book {
        let book = try await open(named: name, in: directory)
        let sam = DeviceIdentity.softwareForTesting()
        _ = try await book.documentStore.admit(
            device: sam.fingerprint, label: label,
            ownName: "\(label)\u{2019}s Mac")
        _ = try await book.documentStore.changePermit(
            everyRecordOf: sam.fingerprint,
            to: .author(.pieces(Set(pieces(book)))))
        return book
    }

    private static func open(named name: String, in directory: URL) async throws -> Book {
        Document.localIdentitiesForTesting =
            .forTesting(author: .softwareForTesting())
        let url = try await ProjectFactory.createNovelProject(
            named: "\(name)-\(UUID().uuidString.prefix(6))", in: directory)
        Document.deviceStateForTesting = OpLogDeviceState(
            fileURL: url.appendingPathComponent("op-log-state.json"))
        Document.registryCacheForTesting = RegistryCache(
            fileURL: url.appendingPathComponent("registry-cache.json"),
            identity: "test")
        Document.admissionMemoryForTesting = AdmissionMemory(
            fileURL: url.appendingPathComponent("admission-memory.json"),
            identity: "test")
        let store = try await ProjectStore.load(from: url)
        await store.wordCountPopulationTask?.value
        let documentStore = try await DocumentStore.open(url: url)
        store.documentStore = documentStore
        return Book(
            url: url, store: store, documentStore: documentStore,
            pieceIDs: TreeWalk.collect(
                in: store.manifest.structure, where: { $0.type == .document })
                .map(\.id))
    }

    /// Clear the four seams. Every caller `defer`s it.
    static func reset() {
        Document.localIdentitiesForTesting = nil
        Document.deviceStateForTesting = nil
        Document.registryCacheForTesting = nil
        Document.admissionMemoryForTesting = nil
    }
}
