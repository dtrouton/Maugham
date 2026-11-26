import XCTest
import MaughamCore
@testable import Maugham

/// **A trust change reaches an open statement too** (shell p3 final wave,
/// I4). A statement is in no `DocumentStore` registry, so the loops an
/// admission, a revocation, *Theirs* and a registry arrival run — forget the
/// table, re-read the text — went over the manuscripts alone: an open intent
/// kept the old verdict and the old words until it was reopened, and the next
/// keystroke in a paragraph whose admitted text it did not show wrote over it.
///
/// One spelling of "every open `Document`", `DocumentStore.everyOpenDocument()`
/// (the union the posture refresh already re-stamped), and a census holding
/// every trust loop to it.
@MainActor
final class TrustReReadsStatementsTests: XCTestCase {

    func test_everyOpenDocumentIncludesAnOpenStatement() async throws {
        let f = try await StatementMountFixture.novel(named: "trust-statements")
        addTeardownBlock { await f.closeAndTearDown() }
        let statement = try await f.store.createStatement(
            kind: .intent, scope: .document(f.documentItemId))
        let live = try await Document.load(
            url: try f.store.resolvedProjectPath(statement.path), actor: .author,
            session: "s", presenter: f.documentStore.presenter)
        f.store.noteStatementDocumentOpened(live, id: statement.id)
        addTeardownBlock { await f.store.closeStatementDocument(live, id: statement.id) }

        XCTAssertFalse(f.documentStore.allOpenDocuments().contains { $0 === live },
                       "premise: a statement is in no manuscript registry")
        XCTAssertTrue(f.documentStore.everyOpenDocument().contains { $0 === live },
                      "the trust loops' union names it")
    }

    /// Every loop in the store that forgets a trust table or re-reads after a
    /// trust change iterates `everyOpenDocument()`.
    func test_everyTrustLoopIteratesTheUnion() throws {
        let stores = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Maugham/Stores")
        var loops: [String: Int] = [:]
        for file in ["DocumentStore.swift", "DocumentStore+Registry.swift", "DocumentStore+Posture.swift"] {
            let lines = try String(contentsOf: stores.appendingPathComponent(file), encoding: .utf8)
                .components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("for document in ") else { continue }
                let body = lines[i...min(lines.count - 1, i + 2)].joined()
                guard body.contains("reReadAfterExternalChange(document)")
                        || body.contains("opStore.invalidateTrust()")
                        || body.contains("document.stamp(") else { continue }
                XCTAssertTrue(trimmed.contains("everyOpenDocument()"),
                              "\(file):\(i + 1) runs a trust loop over manuscripts alone: \(trimmed)")
                loops[file, default: 0] += 1
            }
        }
        XCTAssertEqual(loops["DocumentStore.swift"], 3,
                       "admit's re-read, invalidateTrust's forget, a registry arrival's re-read")
        XCTAssertEqual(loops["DocumentStore+Registry.swift"], 1, "the verbs' settle")
        XCTAssertEqual(loops["DocumentStore+Posture.swift"], 1, "the posture refresh's re-stamp")
    }
}
