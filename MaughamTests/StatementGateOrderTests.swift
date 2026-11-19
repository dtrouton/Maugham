import XCTest
import AppKit
import SwiftUI
import Observation
import MaughamCore
@testable import Maugham

/// Which of two hosts the probe window shows. Swapping it in one update tears
/// one `StatementEditorHost` down and mounts the next on the same statement:
/// Done-then-Edit, faces A→B→A, the centre's cover closing.
@Observable
@MainActor
final class StatementHostSwapProbe {
    var which = 1
    init() {}
}

@MainActor
private struct SwappingHostsView: View {
    let store: ProjectStore
    let documentStore: DocumentStore
    let scope: Statement.Scope
    let probe: StatementHostSwapProbe

    var body: some View {
        StatementEditorHost(store: store, documentStore: documentStore,
                            kind: .intent, scope: scope, posture: .author)
            .id(probe.which)
    }
}

/// **One `Document` per statement path, across a host's close** (shell plan 3
/// Task 4 fix, I1). A host lets go of its statement under the open gate
/// (`ProjectStore.closeStatementDocument`), and a load waits for a statement
/// another host still holds — open or closing — rather than opening a second
/// `Document` beside it. Mounted measurements of the order; nothing is pressed.
@MainActor
final class StatementGateOrderTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        FontWarmup.ensure()
    }

    private var fixtures: [StatementMountFixture] = []

    override func tearDown() async throws {
        for fixture in fixtures { fixture.tearDown() }
        fixtures.removeAll()
        try await super.tearDown()
    }

    private func fixture(_ name: String) async throws -> (StatementMountFixture, Statement) {
        let f = try await StatementMountFixture.novel(named: name)
        fixtures.append(f)
        let statement = try await f.store.createStatement(kind: .intent, scope: .document(f.documentItemId))
        try await f.store.mutateStatementText(of: statement, session: "gate-test") { _ in "Chapter one turns." }
        return (f, statement)
    }

    /// A second load requested while the first host closes observes that
    /// `Document` fully closed before it loads.
    func test_aLoadDuringAHostsCloseWaitsForTheCloseToReturn() async throws {
        let (f, statement) = try await fixture("GateCloseThenLoad")
        let probe = StatementHostSwapProbe()
        let window = f.hostView(AnyView(SwappingHostsView(
            store: f.store, documentStore: f.documentStore,
            scope: .document(f.documentItemId), probe: probe)))
        await pumpUntil(deadline: 5) { f.store.openStatementDocument(id: statement.id) != nil }
        let first = try XCTUnwrap(f.store.openStatementDocument(id: statement.id), "premise: host 1 bound")
        // A burst still pending, so host 1's close has a write to flush — the
        // suspension a second load could slip into.
        await pumpUntil(deadline: 5) { f.firstTextView(in: window) != nil }
        await f.type(" More words.", into: try f.textView(in: window))
        XCTAssertTrue(first.displayText.contains("More words."), "premise: the typing reached host 1")

        var events: [StatementGateEvent] = []
        f.store.onStatementGateEvent = { events.append($0) }
        defer { f.store.onStatementGateEvent = nil }
        probe.which = 2
        await pumpUntil(deadline: 5) {
            guard let now = f.store.openStatementDocument(id: statement.id) else { return false }
            return now !== first
        }

        let second = try XCTUnwrap(f.store.openStatementDocument(id: statement.id))
        XCTAssertFalse(second === first, "host 2 bound a Document of its own")
        XCTAssertTrue(first.isClosed)
        let id = statement.id
        let closed = try XCTUnwrap(events.firstIndex(of: .closed(id)), "host 1's close ran under the gate: \(events)")
        let loading = try XCTUnwrap(events.lastIndex(of: .loading(id)), "host 2 loaded: \(events)")
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: .closing(id))), closed)
        XCTAssertLessThan(closed, loading,
                          "host 2's Document.load began before host 1's close returned — two Documents on one path: \(events)")
        await pumpUntil(deadline: 5) { f.allTextViews(in: window).count == 1 }
        XCTAssertEqual(f.allTextViews(in: window).count, 1, "host 2's editor mounted")
    }

    /// A load of a statement another host holds open waits with the
    /// placeholder up — no editor, no second `Document` — and binds the
    /// moment that host lets go. It is never left without an editor.
    func test_aWaitingLoadBindsOnceTheOtherHostLetsGo() async throws {
        let (f, statement) = try await fixture("GateWaitThenBind")
        let other = try await Document.load(
            url: f.store.resolvedProjectPath(statement.path), actor: .author,
            session: "other-host", presenter: nil)
        f.store.noteStatementDocumentOpened(other, id: statement.id)

        let window = f.hostView(AnyView(StatementEditorHost(
            store: f.store, documentStore: f.documentStore,
            kind: .intent, scope: .document(f.documentItemId), posture: .author)))
        await waitOut(0.5)
        XCTAssertTrue(f.allTextViews(in: window).isEmpty, "the load waits; no editor over a second Document")
        XCTAssertTrue(f.store.openStatementDocument(id: statement.id) === other)

        await f.store.closeStatementDocument(other, id: statement.id)
        XCTAssertTrue(other.isClosed)
        await pumpUntil(deadline: 5) {
            !f.allTextViews(in: window).isEmpty && f.store.openStatementDocument(id: statement.id) != nil
        }
        XCTAssertEqual(f.allTextViews(in: window).count, 1, "the waiting load bound once the other let go")
        let bound = try XCTUnwrap(f.store.openStatementDocument(id: statement.id))
        XCTAssertFalse(bound === other)
    }
}
