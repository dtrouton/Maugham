// MaughamTests/Editor/CommentOnSelectionTests.swift
import XCTest
import AppKit
import SwiftUI
import MaughamCore
@testable import Maugham

/// **Comment… on a selection without entering read-through** (shell p5 Task
/// 7, the owner's added row): Edit ▸ Comment… (⌘⇧K) and the text's
/// right-click Comment… / Suggest… open the composer read-through's
/// selection toolbar opens. Offered by the posture, never by read-through.
/// The right-click is never synthesised (tripwire 33): the builder
/// `MaughamTextView.menu(for:)` runs (`AnnotationOffer.compose`) is called
/// with the coordinator's own items, and the menu item's action is read.
@MainActor
final class CommentOnSelectionTests: XCTestCase {
    override class func setUp() { FontWarmup.ensure() }

    private var reviewer: Posture {
        Posture(LocalWritePermit(permit: .reviewer, actor: .author, documentClass: .piece("doc-a")))
    }

    // MARK: - The offer, pure

    func test_theOfferIsThePosturesAndNeverReadThroughs() {
        typealias Offer = AnnotationOffer
        XCTAssertEqual(Offer.kinds(posture: .author, isReadingTranslation: false,
                                   hasSelection: true, answersAnnotations: true), [.comment],
                       "a writer who may type comments; she changes her own words herself")
        XCTAssertEqual(Offer.kinds(posture: reviewer, isReadingTranslation: false,
                                   hasSelection: true, answersAnnotations: true), [.comment, .suggest],
                       "one who may not type proposes the change")
        XCTAssertEqual(Offer.kinds(posture: .author, isReadingTranslation: false,
                                   hasSelection: false, answersAnnotations: true), [], "no selection")
        XCTAssertEqual(Offer.kinds(posture: .author, isReadingTranslation: true,
                                   hasSelection: true, answersAnnotations: true), [],
                       "over a translation a note would anchor to source text the selection is not")
        XCTAssertEqual(Offer.kinds(posture: .author, isReadingTranslation: false,
                                   hasSelection: true, answersAnnotations: false), [],
                       "a surface that writes no notes (a research note, a statement)")
        XCTAssertEqual(Offer.kinds(posture: nil, isReadingTranslation: false,
                                   hasSelection: true, answersAnnotations: true), [], "no posture yet")
        XCTAssertEqual(Offer.kinds(posture: .settling, isReadingTranslation: false,
                                   hasSelection: true, answersAnnotations: true),
                       Posture.settling.allows(.annotate) ? [.comment, .suggest] : [],
                       "the settling posture answers as its table says")
        // The offer takes no read-through input at all.
        let signature = try? SourceTree.declaration(named: "static func kinds(posture: Posture?", under: "Maugham")
        XCTAssertNotNil(signature)
        XCTAssertFalse(signature?.contains("readThrough") ?? true, "offered by the posture, never by read-through")
    }

    func test_theEditMenuGateAsksThePostureAndTheVisibleManuscript() {
        let bare = CentreRoute.editor(altitude: nil, cover: nil)
        XCTAssertTrue(CommentMenuGate.offersComment(posture: .author, isReadingTranslation: false, route: bare))
        XCTAssertTrue(CommentMenuGate.offersComment(posture: reviewer, isReadingTranslation: false, route: bare))
        XCTAssertFalse(CommentMenuGate.offersComment(posture: nil, isReadingTranslation: false, route: bare))
        XCTAssertFalse(CommentMenuGate.offersComment(posture: .author, isReadingTranslation: true, route: bare))
        XCTAssertFalse(CommentMenuGate.offersComment(posture: .author, isReadingTranslation: false, route: nil),
                       "no manuscript in the centre")
    }

    // MARK: - The builder

    func test_theRightClickMenuIsComposedConvertFirstThenTheNotesThenAppKits() {
        func base() -> NSMenu {
            let menu = NSMenu()
            menu.addItem(withTitle: "Cut", action: nil, keyEquivalent: "")
            menu.addItem(withTitle: "Copy", action: nil, keyEquivalent: "")
            return menu
        }
        let convert = NSMenuItem(title: "Convert to Table Figure", action: nil, keyEquivalent: "")
        let comment = NSMenuItem(title: AnnotationOffer.commentTitle, action: nil, keyEquivalent: "")
        let suggest = NSMenuItem(title: AnnotationOffer.suggestTitle, action: nil, keyEquivalent: "")
        func titles(_ menu: NSMenu?) -> [String] {
            (menu?.items ?? []).map { $0.isSeparatorItem ? "|" : $0.title }
        }
        XCTAssertEqual(titles(AnnotationOffer.compose(base: base(), convert: nil, annotate: [])), ["Cut", "Copy"])
        XCTAssertEqual(titles(AnnotationOffer.compose(base: base(), convert: nil, annotate: [comment])),
                       ["Comment…", "|", "Cut", "Copy"])
        XCTAssertEqual(titles(AnnotationOffer.compose(base: base(), convert: convert,
                                                      annotate: [comment.copy() as! NSMenuItem,
                                                                 suggest])),
                       ["Convert to Table Figure", "|", "Comment…", "Suggest…", "|", "Cut", "Copy"])
        XCTAssertEqual(titles(AnnotationOffer.compose(base: nil, convert: nil,
                                                      annotate: [NSMenuItem(title: "Comment…", action: nil, keyEquivalent: "")])),
                       ["Comment…"], "no trailing separator over an empty menu")
        // The text view runs this builder, with the coordinator's own items.
        let surface = SourceScan.codeLines(of: (try? SourceTree.read("Maugham/Editor/EditorSurface.swift")) ?? "")
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        XCTAssertTrue(surface.contains(
            "return AnnotationOffer.compose( base: super.menu(for: event), convert: coordinator?.convertTableMenuItem(atCharacterIndex: index), annotate: coordinator?.annotationMenuItems() ?? [])"))
    }

    // MARK: - Mounted: the coordinator's items and the one receiver

    final class Box {
        var text: String
        var created: [(AnnotationKind, String)] = []
        init(_ text: String) { self.text = text }
    }

    private func mount(posture: Posture?, writesNotes: Bool = true) throws
        -> (box: Box, textView: NSTextView, coordinator: EditorCoordinator) {
        let box = Box("Arrival was quiet.\n\nThe second paragraph.")
        let binding = Binding(get: { box.text }, set: { box.text = $0 })
        var control = EditorControl()
        control.posture = posture
        var configuration = EditorSurfaceConfiguration(
            presentation: .init(theme: .light, typography: .defaults, mode: ProseMode(),
                                typewriterScroll: false, sentenceFocus: false,
                                paragraphFocus: false, showElementGutter: false),
            control: control)
        // The first paragraph's place, as `Document.paragraphRange(at:)` gives it.
        configuration.paragraphProviders.paragraphRangeAtLocation = { location in
            location < 18 ? (id: "aaaa", range: NSRange(location: 0, length: 18)) : nil
        }
        if writesNotes {
            configuration.reviewProviders.createAnnotationHandler = { kind, _, _, body, _ in
                box.created.append((kind, body))
            }
        }
        let window = TestWindow.mount(EditorSurface(text: binding, configuration: configuration),
                                      size: CGSize(width: 700, height: 500), as: KeyTestWindow.self)
        addTeardownBlock { @MainActor in
            window.reportsKey = false
            window.close()
        }
        let textView = try XCTUnwrap(Self.textView(in: window.contentView))
        let coordinator = try XCTUnwrap(textView.delegate as? EditorCoordinator)
        window.makeFirstResponder(textView)
        return (box, textView, coordinator)
    }

    private static func textView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let tv = view as? NSTextView { return tv }
        for sub in view.subviews { if let tv = textView(in: sub) { return tv } }
        return nil
    }

    func test_theCoordinatorsItemsFollowTheSelectionAndThePosture() throws {
        let m = try mount(posture: .author)
        m.coordinator.updateReviewCardVerbs(for: .author)
        XCTAssertEqual(m.coordinator.annotationMenuItems().map(\.title), [], "no selection, no item")
        m.textView.setSelectedRange(NSRange(location: 0, length: 7))
        let items = m.coordinator.annotationMenuItems()
        XCTAssertEqual(items.map(\.title), ["Comment…"])
        XCTAssertTrue(items.first?.target === m.coordinator)
        XCTAssertEqual(items.first?.action, #selector(EditorCoordinator.commentFromMenu(_:)))

        m.coordinator.updateReviewCardVerbs(for: reviewer)
        XCTAssertEqual(m.coordinator.annotationMenuItems().map(\.title), ["Comment…", "Suggest…"])

        let bare = try mount(posture: .author, writesNotes: false)
        bare.coordinator.updateReviewCardVerbs(for: .author)
        bare.textView.setSelectedRange(NSRange(location: 0, length: 7))
        XCTAssertEqual(bare.coordinator.annotationMenuItems().map(\.title), [],
                       "a surface that writes no notes offers none")
    }

    /// The three routes reach one receiver: the right-click item's action,
    /// Edit ▸ Comment…'s post (⌘⇧K is the walk's: `MenuBarCensusTests`), and
    /// both open the toolbar's composer on the selection — outside
    /// read-through, with the toolbar itself left hidden.
    func test_theMenuItemAndThePostOpenTheToolbarsComposerOutsideReadThrough() throws {
        let m = try mount(posture: .author)
        m.coordinator.updateReviewCardVerbs(for: .author)
        XCTAssertFalse(m.coordinator.isReviewMode, "premise: not in read-through")
        m.textView.setSelectedRange(NSRange(location: 0, length: 7))
        let parent = try XCTUnwrap(m.coordinator.selectionToolbar?.superview)
        func composers() -> [ReviewAnnotationComposerView] {
            parent.subviews.compactMap { $0 as? ReviewAnnotationComposerView }
        }
        XCTAssertEqual(composers().count, 0)
        let item = try XCTUnwrap(m.coordinator.annotationMenuItems().first)
        m.coordinator.commentFromMenu(item)
        XCTAssertEqual(composers().count, 1, "the right-click opened the composer")
        XCTAssertTrue(m.coordinator.selectionToolbar?.isHidden ?? false, "the floating toolbar stays read-through's")

        // Edit ▸ Comment…'s post, as the menu item sends it.
        MaughamEvent.post(.maughamCommentOnSelection, to: .keyWindow)
        XCTAssertEqual(composers().count, 1, "the post opened the same composer, replacing the first")

        // The menu bar's item posts what the coordinator hears.
        let app = SourceScan.codeLines(of: try SourceTree.read("Maugham/MaughamApp.swift"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        XCTAssertTrue(app.contains(
            #"Button(AnnotationOffer.commentTitle) { MaughamEvent.post(.maughamCommentOnSelection, to: .keyWindow) } .keyboardShortcut("k", modifiers: [.command, .shift]) .disabled(!enabled(mayComment == true))"#))
        let coordinator = SourceScan.codeLines(of: try SourceTree.read("Maugham/Editor/EditorCoordinator.swift"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        XCTAssertTrue(coordinator.contains(
            ".maughamCommentOnSelection, context: { [weak self] in self?.manuscriptCommandContext() } ) { [weak self] note in self?.commentOnSelection(AnnotationOffer.kind(of: note.userInfo) ?? .comment)"))
    }

    func test_withNoSelectionThePostOpensNothing() throws {
        let m = try mount(posture: .author)
        m.coordinator.updateReviewCardVerbs(for: .author)
        m.textView.setSelectedRange(NSRange(location: 3, length: 0))
        let parent = try XCTUnwrap(m.coordinator.selectionToolbar?.superview)
        m.coordinator.commentOnSelection(.comment)
        XCTAssertTrue(parent.subviews.allSatisfy { !($0 is ReviewAnnotationComposerView) },
                      "no selection: a beep, no composer")
        m.textView.setSelectedRange(NSRange(location: 0, length: 7))
        m.coordinator.commentOnSelection(.suggest)
        XCTAssertTrue(parent.subviews.allSatisfy { !($0 is ReviewAnnotationComposerView) },
                      "Suggest is not the author's offer: refused")
    }
}
