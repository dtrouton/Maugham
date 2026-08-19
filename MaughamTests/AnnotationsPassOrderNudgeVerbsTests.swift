import XCTest
import SwiftUI
import AppKit
@testable import Maugham
import MaughamCore

/// **The pass-order nudge gains its verbs** (2026-08-19).
///
/// Denver's smoke: the queue's advisory nudge — "Structural still open on
/// this piece" — named a problem with no verb attached. Closing the earlier
/// pass meant leaving the queue for the Inspector's ladder or the board's
/// chip context menu. `PassOrderNudgeRow` (`AnnotationsPane.swift`) now draws
/// two small trailing buttons, Mark done and Skip, that write the NAMED
/// earlier pass's state through `AnnotationsPane.onSetPassState` — the same
/// closure-threading shape `onSetActivePass` already uses, landing at the
/// same `ProjectWindow` call site that writes the board's chip verb.
///
/// This suite drives the real button — `accessibilityPerformPress`, the
/// established delivery path for a mounted `.bordered` button in this pane
/// family (`ReviewRoundCockpitTests`) — through the real `AnnotationsPane`,
/// wired exactly as `ProjectWindow` wires it, and checks the write lands in
/// the manifest and the nudge leaves the screen.
@MainActor
final class AnnotationsPassOrderNudgeVerbsTests: XCTestCase {

    private var windows: [NSWindow] = []
    private var roots: [URL] = []

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    // MARK: - Fixture

    private struct Harness {
        let store: ProjectStore
        let documentStore: DocumentStore
        let document: Document
        let pieceId: String
    }

    /// A real project on disk with one chapter open — presets' four passes,
    /// the piece being worked through Line while Structural is untouched.
    private func makeHarness() async throws -> Harness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PassOrderNudgeVerbs-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)

        let url = try await ProjectFactory.createNovelProject(named: "P", in: root)
        let store = try await ProjectStore.load(from: url)
        let documentStore = try await DocumentStore.open(url: url)
        store.documentStore = documentStore

        let item = try XCTUnwrap(store.manifest.structure.first)
        let document = try await Document.load(
            url: url.appendingPathComponent(item.path ?? ""),
            device: "test-mac", session: "s", presenter: nil)
        documentStore.register(document: document, for: item.path ?? "")

        documentStore.updateUIState {
            $0.activePassMemory.record(piece: item.id, passId: "line")
        }

        return Harness(store: store, documentStore: documentStore,
                       document: document, pieceId: item.id)
    }

    private func passStates(_ fx: Harness) -> [String: PassState]? {
        fx.store.manifest.structure.first { $0.id == fx.pieceId }?.passStates
    }

    // MARK: - Mounting, wired exactly as `ProjectWindow` wires it

    /// `onSetPassState` here is `ProjectWindow`'s own closure, byte for byte
    /// (the `Task { try? await store.setPassState(...) }` at its
    /// `DetailPaneToggle(...)` call site) — so a pass with this wiring but no
    /// production caller would still go undetected. It doesn't: this is the
    /// production wiring, mounted directly.
    private func mountPane(_ fx: Harness) -> NSWindow {
        let view = AnnotationsPane(
            document: fx.document,
            store: fx.store,
            documentStore: fx.documentStore,
            scope: .constant(.document),
            onTravel: { _ in },
            orchestrator: nil,
            diagnostics: nil,
            onSetActivePass: { _, _ in },
            onSetPassState: { pieceId, passId, state in
                Task { try? await fx.store.setPassState(id: pieceId, passId: passId, state) }
            })
            .environment(UserPreferences(
                defaults: UserDefaults(suiteName: "PassOrderNudgeVerbs-\(UUID())")!))

        let frame = CGRect(x: 0, y: 0, width: 320, height: 700)
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        pump()
        return window
    }

    // MARK: - Accessibility (mirrors `ReviewRoundCockpitTests`' readers)

    private func axAttribute(_ element: AnyObject, _ attribute: String) -> Any? {
        guard let object = element as? NSObject,
              object.responds(to: NSSelectorFromString(attribute)) else { return nil }
        return object.value(forKey: attribute)
    }

    private func axElements(under root: AnyObject, depth: Int = 0) -> [AnyObject] {
        guard depth < 40 else { return [] }
        let children = axAttribute(root, "accessibilityChildren") as? [AnyObject] ?? []
        return [root] + children.flatMap { axElements(under: $0, depth: depth + 1) }
    }

    private func axTree(in window: NSWindow) throws -> [AnyObject] {
        var role: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(getpid()), kAXRoleAttribute as CFString, &role)
        guard error == .success, role != nil else {
            throw XCTSkip(
                "no assistive client could be attached to this process, so SwiftUI "
                + "never built the tree this test reads")
        }
        return axElements(under: try XCTUnwrap(window.contentView))
    }

    private func button(labelled label: String, in window: NSWindow) throws -> NSObject {
        var lastAll: [AnyObject] = []
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            lastAll = try axTree(in: window)
                .filter { (axAttribute($0, "accessibilityRole") as? String) == "AXButton" }
            if let match = lastAll.first(
                where: { (axAttribute($0, "accessibilityLabel") as? String) == label }
            ) as? NSObject {
                return match
            }
            pump(0.05)
        }
        return try XCTUnwrap(
            lastAll.first { (axAttribute($0, "accessibilityLabel") as? String) == label }
                as? NSObject,
            "no button labelled \u{201C}\(label)\u{201D} reached the hosted view. "
            + "Buttons found: "
            + "\(lastAll.map { axAttribute($0, "accessibilityLabel") as? String ?? "nil" })")
    }

    private func findButton(labelled label: String, in window: NSWindow) -> NSObject? {
        guard let tree = try? axTree(in: window) else { return nil }
        return tree
            .filter { (axAttribute($0, "accessibilityRole") as? String) == "AXButton" }
            .first { (axAttribute($0, "accessibilityLabel") as? String) == label } as? NSObject
    }

    private func caption(in window: NSWindow, contains text: String) -> Bool {
        guard let tree = try? axTree(in: window) else { return false }
        return tree.contains { element in
            let value = (axAttribute(element, "accessibilityValue") as? String)
                ?? (axAttribute(element, "accessibilityLabel") as? String) ?? ""
            return value.contains(text)
        }
    }

    // MARK: - The nudge is present with its two verbs

    func test_theNudgeDrawsMarkDoneAndSkipBesideTheCaption() async throws {
        let fx = try await makeHarness()
        let window = mountPane(fx)

        XCTAssertTrue(caption(in: window, contains: "Structural still open on this piece"),
                      "premise: the nudge must be showing before its buttons are")
        _ = try button(labelled: "Mark done", in: window)
        _ = try button(labelled: "Skip", in: window)
    }

    // MARK: - Mark done, driven for real

    /// **The end-to-end pin.** The real pane, the real row, a press through
    /// `accessibilityPerformPress`, and the assertions this task is about:
    /// the manifest carries `.done` for the NAMED earlier pass, and the nudge
    /// itself is gone — `PassOrderAdvice.openEarlierPass` no longer finds an
    /// unfinished pass before Line once Structural is `.done`.
    func test_pressingMarkDoneWritesTheNamedPassAndTheNudgeDisappears() async throws {
        let fx = try await makeHarness()
        let window = mountPane(fx)
        XCTAssertNil(passStates(fx)?["structural"], "premise: untouched")

        let markDone = try button(labelled: "Mark done", in: window)
        _ = markDone.perform(NSSelectorFromString("accessibilityPerformPress"))

        await pumpUntil(deadline: 5) { self.passStates(fx)?["structural"] == .done }
        XCTAssertEqual(passStates(fx)?["structural"], .done,
                       "the button's write must reach the manifest through "
                       + "the same store verb the board's chip and the "
                       + "Inspector's ladder use")

        await pumpUntil(deadline: 5) {
            self.findButton(labelled: "Mark done", in: window) == nil
        }
        XCTAssertNil(findButton(labelled: "Mark done", in: window),
                     "the nudge must be gone once its own verb has closed "
                     + "the pass it named")
        XCTAssertFalse(caption(in: window, contains: "Structural still open"),
                       "the caption must leave with its buttons")
    }

    // MARK: - Skip, driven for real

    func test_pressingSkipWritesTheNamedPassAndTheNudgeDisappears() async throws {
        let fx = try await makeHarness()
        let window = mountPane(fx)

        let skip = try button(labelled: "Skip", in: window)
        _ = skip.perform(NSSelectorFromString("accessibilityPerformPress"))

        await pumpUntil(deadline: 5) { self.passStates(fx)?["structural"] == .skipped }
        XCTAssertEqual(passStates(fx)?["structural"], .skipped,
                       "Skip is a decision, not an omission — a writer who "
                       + "rules a piece needs no earlier pass has answered "
                       + "the question the nudge asked")

        await pumpUntil(deadline: 5) {
            self.findButton(labelled: "Skip", in: window) == nil
        }
        XCTAssertNil(findButton(labelled: "Skip", in: window))
    }

    // MARK: - The nudge stays quiet once there is nothing to advise about

    /// The pure half of the same claim, with no window: `PassOrderAdvice`
    /// already excludes `.done`/`.skipped`, which is WHY the mounted tests
    /// above see the row disappear. Restated here as the truth table Denver's
    /// spec asked for, beside the verbs that drive it.
    func test_theAdviceTruthTable_markingDoneOrSkippedRemovesIt() {
        let passes = ReviewPass.presets
        XCTAssertEqual(
            PassOrderAdvice.openEarlierPass(
                activePassId: "line", passes: passes, passStates: nil)?.id,
            "structural", "premise: untouched is open")
        XCTAssertNil(
            PassOrderAdvice.openEarlierPass(
                activePassId: "line", passes: passes,
                passStates: ["structural": .done]),
            "Mark done's write removes the advice")
        XCTAssertNil(
            PassOrderAdvice.openEarlierPass(
                activePassId: "line", passes: passes,
                passStates: ["structural": .skipped]),
            "Skip's write removes the advice too")
    }
}
