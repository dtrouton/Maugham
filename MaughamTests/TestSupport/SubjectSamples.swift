import Foundation
import SwiftUI
@testable import Maugham
import MaughamCore

/// **One sample of every kind of thing a window's subject can name**, for the
/// routing suites that ask a decision over the whole product of its inputs.
///
/// `kind(of:)` is an exhaustive switch with no `default`, and
/// `CentreRouteTests.test_theSamplesCoverEveryKindOfSubject` asserts every kind it names has a sample — so a new
/// `BinderSubject` case fails to compile here, then fails the census until a
/// sample joins, and no routing loop can quietly skip it.
enum SubjectSamples {
    /// A document piece and a Part (a group holding it).
    static let pieceID = "pc01"
    static let partID = "pt01"
    static let researchID = "r-1"
    static let figureID = "f-1"

    /// A Part holding one piece, and a top-level piece beside it.
    static let structure: [StructureItem] = [
        StructureItem(id: partID, title: "Part One", type: .group, children: [
            StructureItem(id: pieceID, title: "Chapter One", type: .document,
                          path: "manuscript/chapter-one.md"),
        ]),
        StructureItem(id: "pc02", title: "Chapter Two", type: .document,
                      path: "manuscript/chapter-two.md"),
    ]

    /// One of each kind `open` can be.
    static let everyOpen: [BinderSubject] = [
        .project, .item(pieceID), .item(partID), .research(researchID),
        .figure(figureID), .inbox, .canvas, .palette, .edition(language: "es"),
    ]

    /// The window opened on `open`, its faces on the same thing.
    static func opened(_ open: BinderSubject) -> WindowSubject {
        WindowSubject(open: open, faces: open)
    }

    /// Every sample `open`, with the faces on it.
    static var everySubject: [WindowSubject] { everyOpen.map(opened) }

    /// The kind's name, exhaustively — a new case is a compile error here.
    static func kind(of subject: BinderSubject) -> String {
        switch subject {
        case .project: return "project"
        case .item(let id): return id == partID ? "part" : "piece"
        case .research: return "research"
        case .figure: return "figure"
        case .inbox: return "inbox"
        case .canvas: return "canvas"
        case .palette: return "palette"
        case .edition: return "edition"
        }
    }

    static let everyKind: Set<String> = [
        "project", "piece", "part", "research", "figure", "inbox", "canvas",
        "palette", "edition",
    ]
}

/// **A window's subject held outside the view**, so a mounted test can seed
/// it and watch what a real tree row writes into it. `binding` is what a tree
/// takes; `treeBinding` is the faces-or-beside view a non-tree surface (a
/// card, a chip, a pane) writes through production's `ClickRule.navigate`.
@Observable
@MainActor
final class WindowSubjectProbe {
    var subject: WindowSubject
    init(_ subject: WindowSubject = .book) { self.subject = subject }

    /// The window subject itself — what every tree takes.
    var binding: Binding<WindowSubject> {
        Binding(get: { self.subject }, set: { self.subject = $0 })
    }

    func treeBinding(store: ProjectStore) -> Binding<BinderSubject?> {
        Binding(
            get: { self.subject.lastClicked },
            set: { newValue in
                self.subject = ClickRule.navigate(
                    to: newValue, current: self.subject,
                    structure: store.manifest.structure, projectType: store.manifest.type)
            })
    }
}

extension WindowSubjectProbe {
    /// What a card, a chip or a navigation writes: production's
    /// `ClickRule.navigate`.
    func pick(_ clicked: BinderSubject, in store: ProjectStore) {
        subject = ClickRule.navigate(to: clicked, current: subject,
                                     structure: store.manifest.structure,
                                     projectType: store.manifest.type)
    }

    /// What a tree row's single click writes: `ClickRule.resolve(_, .click, …)`.
    func selectRow(_ clicked: BinderSubject, in store: ProjectStore) {
        subject = ClickRule.resolve(clicked, gesture: .click, current: subject,
                                    structure: store.manifest.structure,
                                    projectType: store.manifest.type)
    }
}

extension Binding where Value == WindowSubject {
    /// **A suite that holds only a `BinderSubject?`, seen as a window subject**
    /// — for the suites that mount `SubjectValidationModifier` over a legacy
    /// probe. Reads the probe's value as what is open (nil reads as the Book);
    /// a repair writes back what is open. The modifier writes only a subject
    /// that changed, so a nil probe the Book leaves alone stays nil.
    @MainActor
    static func bridging(_ legacy: Binding<BinderSubject?>) -> Binding<WindowSubject> {
        Binding(
            get: { legacy.wrappedValue.map(SubjectSamples.opened) ?? .book },
            set: { legacy.wrappedValue = $0.open })
    }
}

extension Binding where Value == WindowSubject {
    /// **A tree fixture that holds only a `BinderSubject?`**, seen as the
    /// window's subject — for the mounted tree suites whose subject is not the
    /// point (drops, folds, verbs). A research value reads as opened beside
    /// the Book, anything else as open; a write keeps the row the writer last
    /// clicked (`WindowSubject.lastClicked`).
    ///
    /// **`nil` — nothing chosen yet — reads as the canvas open**, so no row
    /// the suites drive starts out drawn selected: the tree draws the row last
    /// clicked, and a click on a row already selected writes nothing through a
    /// `List` (`BinderTreeSelection`'s doc). From there the first click on any
    /// row, the Book's included, is a write the probe sees.
    @MainActor
    static func tree(_ legacy: Binding<BinderSubject?>) -> Binding<WindowSubject> {
        Binding(
            get: {
                switch legacy.wrappedValue {
                case .research(let id):
                    return WindowSubject(open: .project, faces: .project,
                                         beside: .research(id))
                case let other:
                    return SubjectSamples.opened(other ?? .canvas)
                }
            },
            set: { legacy.wrappedValue = $0.lastClicked })
    }
}

extension ProjectWindow {
    /// **What a restored or swept subject opens on** — production's
    /// `validatedSubject` over a window opened on `subject` (nil is the Book),
    /// read as what is open. The legacy single-subject suites ask the repair
    /// through this.
    static func repairedOpen(_ subject: BinderSubject?, in structure: [StructureItem],
                             research: [ResearchItem], figures: [FigureRecord],
                             parked: Set<String>) -> BinderSubject {
        validatedSubject(subject.map(SubjectSamples.opened) ?? .book,
                         structure: structure, research: research, figures: figures,
                         parked: parked, editionLanguages: []).open
    }
}
