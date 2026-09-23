// Maugham/Views/NewPieceModifier.swift
import SwiftUI
import AppKit
import MaughamCore
import os

private let newPieceLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.Maugham",
    category: "NewPiece")

/// **The window's half of §4.5's question** (signed op log P3b Task 7).
///
/// `AdmissionModifier`'s sibling, in its shape and for its reasons: one sheet
/// per question, sequentially, drawn off a queue a pure model derives
/// (`LoadQuestions.newPieces`), with everything the writer reads decided there
/// and nothing derived here.
///
/// **The one difference from admission, and it is the point of the task**: an
/// admission *Not now* is window state that lapses at the next open, because
/// the book will go on holding a stranger's lines and the writer should be
/// asked again. This *Not now* is remembered on the DEVICE
/// (`OpLogDeviceState.declinePiece`), because the person is already in the book
/// and her words are not going anywhere: asking again at every open would be a
/// dialog over the draft every morning about a decision the writer has already
/// declined to make. It waits in People & Devices instead.
struct NewPieceModifier: ViewModifier {
    let projectURL: URL
    let documentStore: DocumentStore?
    /// The open project, for the pieces' titles. Optional because a window
    /// whose load has not finished has none, and a question drawn then names
    /// the piece by its placeholder rather than not being asked.
    let projectStore: ProjectStore?
    @Binding var window: NSWindow?

    @State private var queue: [LoadQuestions.NewPiece] = []
    /// The one the sheet is drawing, held apart from the queue's head for
    /// `AdmissionModifier`'s reason: a `sheet(item:)` whose item changes from
    /// one value straight to another never shows the second.
    @State private var presented: LoadQuestions.NewPiece?
    @State private var shown: LoadQuestions.NewPiece?
    @State private var refusal: String?
    @State private var isAnswering = false

    func body(content: Content) -> some View {
        content
            .sheet(item: $presented, onDismiss: advance) { question in
                NewPieceSheet(
                    question: question,
                    refusal: refusal,
                    isAnswering: isAnswering,
                    onTheirs: { theirs(question) },
                    onNotNow: { notNow(question) })
            }
            // **A new store is a new book AND the first one this view sees**
            // (fix round 1, C2). `.task(id: projectURL)` runs while
            // `documentStore` is still nil on a window's first pass, so the
            // early return there was the whole of this modifier's behaviour at
            // an open: the store arrives afterwards and nothing asked again.
            // So this both scorches what the last book left and re-derives for
            // the one that has just arrived.
            .onChange(of: documentStore.map(ObjectIdentifier.init)) { _, _ in
                queue = []
                presented = nil
                shown = nil
                refusal = nil
                Task { await recompute() }
            }
            .task(id: projectURL) { await recompute() }
            // A load is how this window finds out somebody is waiting, and a
            // piece nobody has claimed arrives the same way a stranger does —
            // through the same event, because it is the same fact (held lines
            // that were not there before). Re-deriving on it costs one pure
            // pass over counts already in hand plus one registry read.
            .onProjectEvent(.maughamAdmissionRequested, url: projectURL, window: window) { _ in
                Task { await recompute() }
            }
            .onProjectEvent(.maughamAdmissionSettled, url: projectURL, window: window) { _ in
                Task { await recompute() }
            }
    }

    private func advance() {
        // **Escape means *Not now*, and it is REMEMBERED** — the same answer
        // the button gives, because a question the writer closed is a question
        // they declined to answer and putting it straight back up is the one
        // behaviour a dismissal must not have.
        if let finished = shown,
           queue.contains(where: { $0.id == finished.id }) {
            documentStore?.notNowAboutPiece(
                person: finished.person, docId: finished.docId)
            queue.removeAll { $0.id == finished.id }
        }
        refusal = nil
        shown = queue.first
        presented = shown
    }

    private func presentHeadIfIdle() {
        guard presented == nil, let head = queue.first else { return }
        shown = head
        presented = head
    }

    // MARK: - What is being asked

    /// Re-derive the queue: the counts this window already has, the registry
    /// as it stands, the manifest's titles, and this device's memory of what
    /// it has already asked.
    ///
    /// The registry read is disk work and a signature check per record, so it
    /// is detached (`TrustResolution`'s own rule); everything else is in hand.
    /// A registry that will not read costs the writer the question and never
    /// the window — named in the log so it is not a silence.
    @MainActor
    private func recompute() async {
        guard let documentStore else { return }
        let held = documentStore.heldLines()
        guard !held.startedAPiece.isEmpty else {
            queue = []
            takeDownAVanishedSheet()
            return
        }
        let url = projectURL
        let identities = Document.loadIdentities
        let cache = Document.loadRegistryCache
        let resolved = await Task.detached(priority: .userInitiated) {
            () -> (registry: Registry, me: String?)? in
            do {
                let verified = try TrustResolution.resolveVerified(
                    projectURL: url, identities: identities, cache: cache)
                return (verified.registry, verified.table.myRoot)
            } catch {
                newPieceLog.error(
                    "a piece question could not read \(url.lastPathComponent, privacy: .public)'s registry: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }.value
        guard let resolved, let me = resolved.me else { return }
        var titles: [String: String] = [:]
        for piece in PermitControl.pieces(
            in: projectStore?.manifest.structure ?? []) {
            titles[piece.id] = piece.title
        }
        queue = LoadQuestions.newPieces(
            held: held, registry: resolved.registry, titles: titles,
            declined: documentStore.closedPieceQuestions(), me: me)
        takeDownAVanishedSheet()
        presentHeadIfIdle()
    }

    /// Close a sheet whose question has been answered elsewhere — a second
    /// window on this book, or the writer settling it in People & Devices
    /// while this stood. `AdmissionModifier`'s rule, for its reason: pressing
    /// a stale sheet would write a permit over one somebody has already
    /// chosen.
    private func takeDownAVanishedSheet() {
        guard let shown, !queue.contains(where: { $0.id == shown.id })
        else { return }
        presented = nil
    }

    // MARK: - Answering

    /// **Not now writes nothing to the book.** It records, on this Mac alone,
    /// that the question has been asked — and the question goes on waiting.
    private func notNow(_ question: LoadQuestions.NewPiece) {
        documentStore?.notNowAboutPiece(
            person: question.person, docId: question.docId)
        queue.removeAll { $0.id == question.id }
        presented = nil
    }

    /// **Theirs**: add the piece to their scope, and let what is waiting in.
    ///
    /// The store verb decides everything about the permit — what is in force
    /// now, whether this Mac may change it, every record of theirs, the
    /// book's photograph, the schema gate. This knows none of it. A refusal
    /// keeps the sheet up carrying its own sentence, because a dialog that
    /// closes on a write that did not happen is the silence RULING-7 forbids.
    private func theirs(_ question: LoadQuestions.NewPiece) {
        guard let documentStore, !isAnswering else { return }
        isAnswering = true
        refusal = nil
        Task { @MainActor in
            defer { isAnswering = false }
            do {
                _ = try await documentStore.pieceIsTheirs(
                    person: question.person, docId: question.docId)
                queue.removeAll { $0.id == question.id }
                presented = nil
            } catch {
                refusal = AdmissionDecision.refusal(error)
                newPieceLog.error(
                    "saying \(question.docId, privacy: .public) is \(DeviceCode.short(question.person), privacy: .public)'s refused: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// **The question itself** — two answers and no third (spec §4.5).
///
/// It draws a `LoadQuestions.NewPiece` and derives nothing: what it asks, what
/// each answer costs and what neither of them does are all decided in the pure
/// model, so the whole of what the writer reads is pinned without a window.
struct NewPieceSheet: View {
    let question: LoadQuestions.NewPiece
    let refusal: String?
    let isAnswering: Bool
    let onTheirs: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(question.question)
                .font(.headline)
                .accessibilityIdentifier("new-piece-question")
            Text(question.consequence)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(question.notNowConsequence)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let refusal {
                Text(refusal)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("new-piece-refusal")
            }
            HStack {
                Spacer()
                Button(question.notNowTitle, action: onNotNow)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("new-piece-not-now")
                Button(question.theirsTitle, action: onTheirs)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isAnswering)
                    .accessibilityIdentifier("new-piece-theirs")
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
