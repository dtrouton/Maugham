import AppKit
import ApplicationServices
import XCTest

/// **Reading a mounted SwiftUI surface the way a writer's keyboard and
/// VoiceOver read it** — the accessibility-tree helpers every mounted suite
/// needs, in one place.
///
/// **Why the tree rather than a click.** A synthetic `mouseDown` needs this
/// test host to be the ACTIVE app: with the screen locked, or another app
/// refusing to yield activation, AppKit drops the event before any view sees it
/// (CLAUDE.md's synthetic-click premise). `accessibilityPerformPress` is the
/// action the click ultimately performs and needs none of that, so an overnight
/// gate does not go red for a reason that has nothing to do with the code.
///
/// **Why suites skip rather than fail when no client can attach.** SwiftUI
/// builds no accessibility tree at all unless an assistive client is attached
/// to the process. A tree that was never built is not evidence about the view,
/// so ``requireAssistiveClient()`` throws `XCTSkip` — by name, with the
/// `AXError` in the message — and every reader here goes through it.
///
/// **A protocol extension rather than an extension on `XCTestCase`**, for
/// `RunLoopPumping`'s reason and it is not a style preference: members added to
/// a *class* in an extension are treated as overridable, so a suite that still
/// declares its own `collect(_:in:into:)` would fail to build with "overriding
/// declaration requires an 'override' keyword". Coming in through a protocol
/// makes a local declaration plain shadowing instead, which is legal and wins
/// for its own type — so the suites that keep a deliberately different copy
/// (`ReviewRoundCockpitTests`' longer `pump`, the canvas suites' own timings)
/// never see this file.
///
/// The waits live next door in ``RunLoopPumping``: prefer its `pumpUntil`,
/// which turns the runloop AND yields the main actor. A poll that only spins
/// `RunLoop.run(until:)` holds the main actor for its whole deadline, so an
/// `await`ed job under test — a promotion's `Task`, a round's briefing gather —
/// cannot be scheduled until after the assertion has already failed.
protocol AXReading {}

extension XCTestCase: AXReading {}

@MainActor
extension AXReading {

    // MARK: - The premise

    /// Throw `XCTSkip` unless an assistive client is attached to this process.
    ///
    /// Every reader below calls it, so a suite that cannot see a tree skips by
    /// name in one place rather than asserting against an empty one.
    func requireAssistiveClient() throws {
        var role: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(getpid()), kAXRoleAttribute as CFString, &role)
        guard error == .success, role != nil else {
            throw XCTSkip(
                "no assistive client could be attached to this process "
                + "(AXUIElementCopyAttributeValue -> \(error.rawValue)), so "
                + "SwiftUI never builds the tree this test reads")
        }
    }

    // MARK: - Walking the tree

    /// One accessibility attribute, by KVC — `nil` when the element does not
    /// carry it.
    func axAttribute(_ element: AnyObject, _ attribute: String) -> Any? {
        guard let object = element as? NSObject,
              object.responds(to: NSSelectorFromString(attribute)) else { return nil }
        return object.value(forKey: attribute)
    }

    /// `root` and every descendant of it, depth-first. The depth cap is a guard
    /// against a cyclic tree, not a limit any real surface reaches.
    func axElements(under root: AnyObject, depth: Int = 0) -> [AnyObject] {
        guard depth < 40 else { return [] }
        let children = axAttribute(root, "accessibilityChildren") as? [AnyObject] ?? []
        return [root] + children.flatMap { axElements(under: $0, depth: depth + 1) }
    }

    /// Every element the mounted window publishes.
    func axElements(in window: NSWindow) throws -> [AnyObject] {
        try requireAssistiveClient()
        return axElements(under: try XCTUnwrap(window.contentView))
    }

    // MARK: - Reading it

    /// Every button carrying `label`, in tree order — which for a `VStack` of
    /// rows is the order a writer reads them down the column.
    func axButtons(labelled label: String, in window: NSWindow) throws -> [AnyObject] {
        try axElements(in: window)
            .filter { (axAttribute($0, "accessibilityRole") as? String) == "AXButton" }
            .filter { (axAttribute($0, "accessibilityLabel") as? String) == label }
    }

    /// Every button label on the surface — what a failed lookup prints, so the
    /// message says what WAS there rather than only what was not.
    func axButtonLabels(in window: NSWindow) throws -> [String] {
        try axElements(in: window)
            .filter { (axAttribute($0, "accessibilityRole") as? String) == "AXButton" }
            .compactMap { axAttribute($0, "accessibilityLabel") as? String }
    }

    /// Every string the surface publishes — a static text's value, plus any
    /// label an element carries.
    func axTexts(in window: NSWindow) throws -> [String] {
        try axElements(in: window).flatMap { element -> [String] in
            [axAttribute(element, "accessibilityValue") as? String,
             axAttribute(element, "accessibilityLabel") as? String]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
        }
    }

    /// Whether an element reports itself pressable.
    ///
    /// **Neither shortcut works on its own** (measured 2026-08-17, macOS 26.6,
    /// `ReviewRoundCockpitTests`): SwiftUI's hosted `AccessibilityNode` does NOT
    /// respond to `accessibilityEnabled` — only to the KVC getter
    /// `isAccessibilityEnabled` — and the value it hands back is an
    /// `__NSCFNumber`, which `as? Bool` fails on because only `__NSCFBoolean`
    /// bridges. A reader that did one of the two answers `nil` for a button that
    /// is plainly disabled, which reads exactly like "neither enabled nor
    /// disabled". So: the responds-to check on one spelling, the number read on
    /// the other, and the plain `Bool` as the fallback for an element (an
    /// `NSButton`'s own node) that really does carry one.
    func axEnabled(_ element: AnyObject) -> Bool? {
        guard let object = element as? NSObject,
              object.responds(to: NSSelectorFromString("isAccessibilityEnabled"))
        else { return nil }
        if let number = object.value(forKey: "accessibilityEnabled") as? NSNumber {
            return number.boolValue
        }
        return object.value(forKey: "isAccessibilityEnabled") as? Bool
    }

    // MARK: - Menu-like controls

    /// The menu-like control carrying `identifier`, or `nil` where the surface
    /// published none.
    func axMenuControl(_ identifier: String,
                       in window: NSWindow) throws -> AXMenuControl? {
        try axElements(in: window)
            .first { (axAttribute($0, "accessibilityIdentifier") as? String) == identifier }
            .map { element in
                AXMenuControl(
                    role: axAttribute(element, "accessibilityRole") as? String,
                    reading: axReading(element),
                    isEnabled: axEnabled(element))
            }
    }

    /// Every identifier the surface published, for a failed lookup's message —
    /// so a miss says what WAS there rather than only what was not.
    func axIdentifiers(in window: NSWindow) throws -> [String] {
        try axElements(in: window)
            .compactMap { axAttribute($0, "accessibilityIdentifier") as? String }
            .filter { !$0.isEmpty }
    }

    /// An element's text: `accessibilityValue`, else `accessibilityTitle`.
    ///
    /// Both are read as a plain `String` AND through `NSAttributedString`,
    /// because a `SwiftUIPopupButtonCell` hands back an
    /// `NSConcreteMutableAttributedString` where a SwiftUI `AccessibilityNode`
    /// hands back a `String`, and a reader that did one of the two is silently
    /// blind to whichever control it did not have in mind.
    func axReading(_ element: AnyObject) -> String? {
        for key in ["accessibilityValue", "accessibilityTitle"] {
            guard let raw = axAttribute(element, key) else { continue }
            if let text = raw as? String, !text.isEmpty { return text }
            if let text = (raw as? NSAttributedString)?.string, !text.isEmpty { return text }
        }
        return nil
    }

    // MARK: - Acting on it

    /// Press an element through the tree — the action a click ultimately
    /// performs, and the one that does not need this process to be frontmost.
    func press(_ element: AnyObject) {
        _ = (element as? NSObject)?.perform(
            NSSelectorFromString("accessibilityPerformPress"))
    }

    // MARK: - The view hierarchy underneath

    /// Every view of `type` in the window, depth-first.
    func collect<T: NSView>(_ type: T.Type, in window: NSWindow) -> [T] {
        guard let root = window.contentView else { return [] }
        var found: [T] = []
        collect(type, in: root, into: &found)
        return found
    }

    func collect<T: NSView>(_ type: T.Type, in view: NSView, into out: inout [T]) {
        if let hit = view as? T { out.append(hit) }
        for sub in view.subviews { collect(type, in: sub, into: &out) }
    }
}

// MARK: - What a menu-like control publishes

/// **The one way a mounted `Picker` or `Menu` is read** (macOS 27 shell
/// slice, Task 4).
///
/// On macOS 27 a SwiftUI `Picker(.menu)` mounts **no AppKit control at
/// all** — the whole view-hierarchy trace is a `KeyViewProxy` and a
/// `_FocusRingView` — so every `NSPopUpButton` census over an inspector
/// answers `[]`, which is what took six `InspectorPassLadderTests` down
/// with it. It is in the accessibility tree, as a SwiftUI
/// `AccessibilityNode` with role `AXPopUpButton` whose `accessibilityValue`
/// is the selected item's title. A `Menu(.borderlessButton)` IS still a
/// real `SwiftUIPopupButton`, but its explicit `.accessibilityLabel`
/// arrives as an EMPTY `accessibilityLabel` beside an `NSAttributedString`
/// `accessibilityTitle` — the one attribute ``axTexts(in:)`` does not read,
/// in the one type it cannot cast, which is the whole of
/// `AdmissionSheetTests`' red.
///
/// **So the difference between the two controls is which attribute holds
/// their text, and that is this helper's business rather than each suite's.**
/// `reading` takes `accessibilityValue` first and falls back to
/// `accessibilityTitle`, bridged through `NSAttributedString` where it is
/// one. A suite asks for a control by identifier and gets back what it may
/// honestly assert: that it is there, what it currently reads, and whether
/// it is enabled.
///
/// **Nothing here presses.** The ladder's node publishes an EMPTY
/// `accessibilityActionNames`, no children and no `NSMenu`, so the mounted
/// delivery path `InspectorPassLadderTests` used to drive does not exist on
/// 27 in any form — a write is pinned at the host that performs it, never
/// through the control. Measured 2026-09-19; the whole spike is
/// `docs/superpowers/notes/2026-09-19-split-view-tie-break-spike.md`'s
/// *The accessibility tree on 27*.
///
/// **It reaches nothing inside a `List(.sidebar)`**: `NSOutlineRow` answers
/// `[]` to this KVC walk, so a tree row's control has no accessibility hook
/// of any kind — identifier included — and the `_FocusRingView` census
/// stays that furniture's only instrument (`SectionChevronTests`).
struct AXMenuControl {
    /// `AXPopUpButton` for a `Picker`, `AXMenuButton` for a `Menu`.
    let role: String?
    /// What the control says right now — its value, else its title.
    let reading: String?
    /// `nil` only where the element carries no enabled-ness at all.
    let isEnabled: Bool?
}
