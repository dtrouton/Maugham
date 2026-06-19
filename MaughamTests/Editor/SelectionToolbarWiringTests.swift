// MaughamTests/Editor/SelectionToolbarWiringTests.swift
import XCTest
import SwiftUI
import AppKit
@testable import Maugham

/// Regression net for the selection-toolbar `onAction` wiring.
///
/// `EditorCoordinator.attach(to:)` wires `selectionToolbar?.onAction`. That
/// optional-chain is a no-op if `selectionToolbar` is still nil at attach time,
/// which silently kills the entire Comment/Query/Suggest authoring flow in
/// production (clicking a toolbar button hits nothing). `EditorSurface.makeNSView`
/// must therefore assign the toolbar BEFORE calling `attach`.
///
/// `makeNSView` itself can't be driven from a unit test
/// (`NSViewRepresentable.Context` can't be synthesized), so this asserts the
/// coordinator-side half of the contract directly: a toolbar present at attach
/// time gets its `onAction` wired. The production ordering is additionally
/// backstopped by a `#if DEBUG assert` at the end of `makeNSView`.
@MainActor
final class SelectionToolbarWiringTests: XCTestCase {

    private func makeCoordinator() -> EditorCoordinator {
        final class TextBox { var value = "" }
        let box = TextBox()
        return EditorCoordinator(
            text: Binding(get: { box.value }, set: { box.value = $0 }),
            mode: ProseMode(),
            theme: .light, typography: .defaults,
            typewriterScroll: false,
            sentenceFocus: false, paragraphFocus: false)
    }

    func test_attach_wiresToolbarOnAction_whenToolbarAssignedFirst() {
        let coordinator = makeCoordinator()
        let toolbar = SelectionToolbarView(frame: .zero)

        // Mirror EditorSurface.makeNSView's ordering: toolbar assigned BEFORE attach.
        coordinator.selectionToolbar = toolbar

        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        tv.delegate = coordinator
        coordinator.attach(to: tv)

        XCTAssertNotNil(coordinator.selectionToolbar?.onAction,
            "attach must wire the selection toolbar's onAction when a toolbar is present")
    }
}
