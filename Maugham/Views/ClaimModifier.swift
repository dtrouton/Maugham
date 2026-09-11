// Maugham/Views/ClaimModifier.swift
import SwiftUI
import AppKit
import MaughamCore
import os

private let claimLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.maugham.Maugham",
    category: "Claim")

/// **The window's half of the claim** (signed op log P2b Task 8, spec §5).
///
/// A `ViewModifier` of its own rather than a second sheet inside
/// `AdmissionModifier`, for two reasons. The questions are mutually exclusive
/// — admission is asked only by a Mac that HAS a chain
/// (`AdmissionDecision.requests` answers nothing without a root), and this is
/// asked only by one that has none — so they never compete for the screen, and
/// a single modifier presenting two `sheet(item:)`s would be the identity swap
/// that shape exists to avoid. And they are different subjects: one is about a
/// device, this is about the whole book.
///
/// **Asked once per project per launch** (`ClaimPromptMemory`). Claim, *Not
/// mine* and Escape all count as answered: a question about a whole book that
/// comes back while the writer is working is the dialog nobody can get rid of.
/// The next launch asks again, which is what *until the next open* means
/// everywhere else in this milestone.
struct ClaimModifier: ViewModifier {
    let projectURL: URL
    let projectTitle: String
    let documentStore: DocumentStore?
    @Binding var window: NSWindow?

    @State private var offer: ClaimOffer?
    @State private var refusal: String?
    @State private var isClaiming: Bool = false

    func body(content: Content) -> some View {
        content
            .sheet(item: $offer) { offer in
                ClaimSheet(
                    offer: offer,
                    projectTitle: projectTitle,
                    refusal: refusal,
                    isClaiming: isClaiming,
                    onClaim: { claim(offer) },
                    onNotMine: { notMine() })
            }
            .task(id: projectURL) { await ask() }
            // **Asked once the store that would perform it exists.** A project
            // open mints the `DocumentStore` asynchronously, and `.task` fires
            // before it lands — a sheet put up in that window would carry a
            // Claim that silently did nothing, which is the one behaviour a
            // dialog must not have. The memory is only consulted once a
            // question has actually been decided, so nothing is spent waiting.
            .onChange(of: documentStore.map(ObjectIdentifier.init)) { _, _ in
                Task { await ask() }
            }
    }

    // MARK: - Whether to ask

    /// Read the registry as this device, and put the question if
    /// `ClaimDecision` says there is one — and if this launch has not already
    /// put it.
    ///
    /// The registry read is a directory walk plus a P256 verification per
    /// record, so it goes to a detached task (`TrustResolution`'s own rule).
    /// The memory is consulted LAST, after the decision, so a project that
    /// resolves to no offer is not marked as asked: the writer opening a book
    /// whose registry arrives through iCloud a minute later is asked when it
    /// does.
    @MainActor
    private func ask() async {
        guard documentStore != nil, offer == nil else { return }
        let url = projectURL
        let identities = Document.loadIdentities
        let cache = Document.loadRegistryCache
        let decided = await Task.detached(priority: .userInitiated) { () -> ClaimOffer? in
            // A registry that will not read costs the writer the question and
            // never the window: they can still write, and the book still reads
            // as B3's unsigned history. Named in the log so it is not a
            // silence (RULING-54's display half).
            do {
                let resolved = try TrustResolution.resolveVerified(
                    projectURL: url, identities: identities, cache: cache)
                return ClaimDecision.offer(
                    registry: resolved.registry, table: resolved.table,
                    canWriteRegistry: ClaimDecision.canWriteRegistry(in: url))
            } catch {
                claimLog.error(
                    "the claim could not read \(url.lastPathComponent, privacy: .public)'s registry: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }.value

        guard let decided, ClaimPromptMemory.shared.shouldAsk(about: url) else { return }
        refusal = nil
        offer = decided
    }

    // MARK: - Answering

    /// Nothing at all, which is the whole of *Not mine* (decision B3). The
    /// memory already holds this project, so the question does not come back
    /// this launch.
    private func notMine() {
        offer = nil
    }

    /// Write this Mac's own root record and the claim that adopts what it
    /// found, then let the adopted history in.
    ///
    /// A refusal keeps the sheet up carrying its own sentence — the one thing a
    /// dialog must never do is close on a write that did not happen — and the
    /// sentence is `AdmissionDecision`'s, which is the one vocabulary a
    /// `RegistryAdmissionError` becomes words in.
    private func claim(_ offer: ClaimOffer) {
        guard let documentStore, !isClaiming else { return }
        isClaiming = true
        refusal = nil
        Task { @MainActor in
            defer { isClaiming = false }
            do {
                _ = try await documentStore.claim(adopting: offer.roots)
                self.offer = nil
            } catch {
                refusal = AdmissionDecision.refusal(error)
                claimLog.error(
                    "claiming \(projectURL.lastPathComponent, privacy: .public) refused: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
