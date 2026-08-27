import AppKit
import SwiftUI
import XCTest
@testable import Maugham

/// `TestWindow` is the bundle's one window fixture; these pin the two facts
/// every other mounted suite now inherits from it — the window is live for
/// SwiftUI and invisible to the developer — and the activation gate.
@MainActor
final class TestWindowTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        super.tearDown()
    }

    func test_aMadeWindowIsLiveForSwiftUIAndInvisibleToTheDeveloper() async {
        let window = TestWindow.make(contentRect: CGRect(x: 0, y: 0, width: 200, height: 120))
        windows.append(window)

        // Live: on a screen and ordered in — the premises SwiftUI layout,
        // `onAppear` and `TimelineView` read. `occlusionState` is deliberately
        // NOT asserted: it is a fact about the machine, not the fixture — a
        // full-screen app or an opaque window covering this display occludes
        // every window on it, alpha or not. Measured 2026-08-27: two gates read
        // `.visible` here and a third did not, with every mounted suite
        // (TimelineView-driven canvas included) green in all three.
        XCTAssertTrue(window.isVisible)
        XCTAssertNotNil(window.screen)

        // Invisible: drawn at alpha 0, deaf to the real mouse, out of Mission
        // Control and the Window menu, no appearance animation.
        XCTAssertEqual(window.alphaValue, 0)
        XCTAssertTrue(window.ignoresMouseEvents)
        XCTAssertTrue(window.collectionBehavior.contains(.transient))
        XCTAssertTrue(window.collectionBehavior.contains(.ignoresCycle))
        XCTAssertTrue(window.isExcludedFromWindowsMenu)
        XCTAssertEqual(window.animationBehavior, .none)
    }

    func test_mountLaysTheViewOutAtTheAskedSizeAndFiresOnAppear() async {
        final class Probe { var appeared = false }
        let probe = Probe()
        let window = TestWindow.mount(
            Text("hello").onAppear { probe.appeared = true },
            size: CGSize(width: 320, height: 240))
        windows.append(window)

        let deadline = Date().addingTimeInterval(2)
        while !probe.appeared, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(probe.appeared, "onAppear never fired — the hidden window is not live")
        XCTAssertEqual(window.contentView?.frame.size, CGSize(width: 320, height: 240))
        XCTAssertEqual(window.alphaValue, 0)
    }

    /// The default class swallows the no-responder beep — a keystroke sent at
    /// nothing, which the suites do on purpose, must not be audible.
    func test_theDefaultWindowIsSilent() {
        let window = TestWindow.make(contentRect: CGRect(x: 0, y: 0, width: 50, height: 50))
        windows.append(window)
        XCTAssertTrue(type(of: window) == SilentTestWindow.self,
                      "the fixture's default window class must be SilentTestWindow")
        let mounted = TestWindow.mount(Text("hi"), size: CGSize(width: 50, height: 50))
        windows.append(mounted)
        XCTAssertTrue(type(of: mounted) == SilentTestWindow.self)
    }

    /// A sheet is its own child window at full alpha, whatever its parent's.
    /// `TestHost`'s sweep conceals it as it begins — the first hidden gate
    /// floated `DesignGateTests`' "Finalize this design" dialog over the
    /// developer's desktop.
    func test_aSheetOnAMadeWindowIsConcealedToo() async {
        let parent = TestWindow.make(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200))
        windows.append(parent)
        let sheet = TestWindow.make(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100),
                                    present: .unshown)
        // Undo the fixture's own conceal so only the sweep can hide it.
        sheet.alphaValue = 1
        parent.beginSheet(sheet, completionHandler: { _ in })
        let hidden = await RunLoopPump.until(deadline: 2) { sheet.alphaValue == 0 }
        XCTAssertTrue(hidden, "the sweep must conceal a sheet as it begins")
        XCTAssertTrue(parent.attachedSheet === sheet, "premise: the sheet did attach")
        parent.endSheet(sheet)
    }

    /// An alert panel is a window the fixture never built — `NSAlert` makes
    /// its own — so only the sweep can hide it.
    func test_anAlertPanelTheFixtureNeverBuiltIsConcealed() async {
        let parent = TestWindow.make(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200))
        windows.append(parent)
        let alert = NSAlert()
        alert.messageText = "Finalize this design?"
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: parent, completionHandler: { _ in })
        let hidden = await RunLoopPump.until(deadline: 2) {
            parent.attachedSheet.map { $0.alphaValue == 0 } ?? false
        }
        XCTAssertTrue(hidden, "the sweep must conceal an alert panel it did not build")
        if let panel = parent.attachedSheet { parent.endSheet(panel) }
    }

    func test_theSubclassAskedForIsTheOneBuilt() {
        let window = TestWindow.make(SilentTestWindow.self,
                                     contentRect: CGRect(x: 0, y: 0, width: 50, height: 50))
        windows.append(window)
        XCTAssertTrue(type(of: window) == SilentTestWindow.self)
        XCTAssertEqual(window.alphaValue, 0)
    }

    /// The host is `.accessory` — `TestHost` switched it at launch — so no
    /// Dock tile and no ⌘-tab entry for any of the worker processes.
    func test_theHostIsAnAccessoryApp() {
        XCTAssertTrue(TestHost.isActive, "TestHost must recognise an XCTest host")
        XCTAssertEqual(NSApplication.shared.activationPolicy(), .accessory)
    }

    /// Without `MAUGHAM_ALLOW_ACTIVATION=1`, `activate` never takes the
    /// keyboard: an inactive host stays inactive and the call says so. With it
    /// (CI), the call asks and reports what it got.
    func test_activationIsRefusedUnlessTheRunOptsIn() async {
        let window = TestWindow.make(contentRect: CGRect(x: 0, y: 0, width: 50, height: 50))
        windows.append(window)
        let wasActive = NSApplication.shared.isActive
        let result = await TestWindow.activate(window, deadline: 0.2)
        if TestWindow.activationAllowed {
            XCTAssertEqual(result, NSApplication.shared.isActive)
        } else {
            XCTAssertEqual(result, wasActive,
                "activate must not change the host's active state without opt-in")
            if !wasActive {
                XCTAssertFalse(NSApplication.shared.isActive)
            }
        }
    }
}
