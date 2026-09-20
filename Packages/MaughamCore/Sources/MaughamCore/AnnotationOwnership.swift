import Foundation

/// Cooperative-identity ownership check for author self-service (edit /
/// withdraw your OWN annotation). WF1-local has no accounts: identity is the
/// reviewer's chosen display name (`UserPreferences.collaboratorDisplayName`)
/// matched against the annotation author stamped on its creation op.
///
/// Pure + nonisolated so it's directly unit-testable and callable from any
/// surface. An annotation is "own" iff it was authored by a human whose
/// display name equals the local reviewer's. Claude's annotations (or another
/// human collaborator's) are never editable/withdrawable here.
public enum AnnotationOwnership {
    public static func isOwn(_ annotation: Annotation, localName: String) -> Bool {
        guard let author = annotation.author else { return false }
        return author.sourceKind == .human && author.displayName == localName
    }

    // MARK: - Whose annotation it is (P3a Task 6, spec §2 and §4.2)

    /// **May the device that signed this amendment edit or withdraw this
    /// note?** — the one Core answer, never restated at a surface.
    ///
    /// The ladder's reviewer rung reads *edit/withdraw of their OWN
    /// annotations*, and that is a **same-person** rule rather than a per-file
    /// one (spec §4.2): every rung may sign an `annotationEdit` or an
    /// `annotationWithdraw`, so the per-line partition lets the kind through
    /// and this decides whose note it was allowed to be about. Two ways in:
    ///
    /// 1. **Author rights on this document.** Asked of `Permit.allows` with a
    ///    disposition-class write, so the ladder is never spelled a second
    ///    time — settling somebody's note and amending it are the same
    ///    authority, and the actor narrows it (an assistant-signed amendment
    ///    is the reviewer row on every device, the root's included).
    /// 2. **The same person.** Two devices, one writer: her phone may withdraw
    ///    what her Mac wrote. The join is the table's (`sameWriter`) and never
    ///    string equality of device ids — under labels-only a person is a
    ///    device's author key, so two of her machines are two fingerprints and
    ///    one label.
    ///
    /// **Not honoured loses no words.** The amending op stays in the log and
    /// the annotation simply stands as it was, so the conservative answer is
    /// cheap here in a way it never is for manuscript text — which is why the
    /// two unresolvable cases below are refusals rather than holds.
    ///
    /// **Four answers, and the two middle ones are what fix round 2 separated:**
    ///
    /// - The register **cannot place the signer's device, and the id is not
    ///   even shaped like one this app writes** — a pre-P1 hostname
    ///   (`denvers-macbook-pro`), a P1-era sentinel (`mcp`, `wiki-rename`), a
    ///   phone's `phone:<uuid>`: **honoured**. The permit partition does not
    ///   judge those lines either (no seal it can attribute covers them), and
    ///   P3 does not start refusing what P1 applied (decision B3). A load that
    ///   ignored them would resurrect every note the writer has ever deleted
    ///   the day the book's first permit event is written.
    /// - The register cannot place it and the id **is** production-shaped —
    ///   `<actor>-<hex…>`, a name only this app's writers produce, resolving to
    ///   no key this register knows: **not honoured in a book with permit
    ///   events, honoured in one without**. Such an id is *named-shaped but
    ///   unknown*, which is not P2's unattributable history: in practice it is
    ///   one of an admitted person's three NON-author actor keys, which only a
    ///   device record can name, arriving before that record does. In a book
    ///   with no events the answer is the one it has always been, because there
    ///   is no narrower permit for a refusal to be protecting (neutrality).
    /// - The register **names the key and awards it to nobody** — two verified
    ///   records claim it (`Registry.actorKeyOwners`' third clause): **not
    ///   honoured**. Here the register does have an opinion, and it is that
    ///   nobody holds this key; acting on it would let a dispute be settled by
    ///   whoever wrote last.
    /// - Otherwise the two rules above decide, and a CREATOR the register
    ///   cannot place (or awards to nobody) fails the same-person half — so an
    ///   amendment by somebody without author rights, of a note nobody can be
    ///   shown to have written, is not honoured.
    ///
    /// **Her `author` id is placeable from a person record alone** (fix round
    /// 2, `TrustTable.deviceKey(forDeviceId:)`), so the ordinary case — an
    /// admitted reviewer whose device record has not synced yet — is JUDGED
    /// rather than waved through. That window was the Important of this round:
    /// the partition judged her op lines correctly in it (it reaches her
    /// timeline through `person(forSealKey:)`'s self-fallback) while this
    /// function honoured her amendment of somebody else's note.
    ///
    /// **`signerPermit` is the caller's to resolve**, because only the caller
    /// knows which permit it means — and the production caller
    /// (`AnnotationAmendments.judged`) passes the permit **as of the amending
    /// line**, carried out of the partition that judged it. See that function
    /// for why today's permit is the wrong one and what it costs.
    ///
    /// **The unplaced arm is reached from here AND from
    /// `AnnotationAmendments.judged`**, which meets the same fork one step
    /// earlier because it needs the signer's key to resolve a permit at all.
    /// Two call sites, ONE rule (`unplaced(_:trust:)`) since fix round 2 — it
    /// used to be two spellings — and it is pinned from both:
    /// `AnnotationOwnershipTests` asks this function directly, and asks the
    /// deriver for the policy's.
    public static func mayAmend(
        signerDevice: String,
        creatorDevice: String,
        signerPermit: Permit,
        signerActor: DeviceActor?,
        in documentClass: DocumentClass,
        trust: TrustTable,
        insideTheUnsignedSnapshot: Bool = false
    ) -> Bool {
        guard let signer = trust.deviceKey(forDeviceId: signerDevice)
        else {
            return unplaced(
                signerDevice, trust: trust,
                insideTheUnsignedSnapshot: insideTheUnsignedSnapshot)
        }
        guard signer.isOwned else { return false }
        // Settling a note and amending one are the same authority, so the
        // question is put to the table in the vocabulary the table already has.
        if signerPermit.allows(
            .op(.claudeArchive), in: documentClass, actor: signerActor) == .yes {
            return true
        }
        guard let creator = trust.deviceKey(forDeviceId: creatorDevice),
              creator.isOwned else { return false }
        return trust.sameWriter(signer.key, creator.key)
    }

    /// **What an id this register cannot place at all means** — the one
    /// spelling, asked by `mayAmend` and by `AnnotationAmendments.judged`,
    /// which reaches the same fork one step earlier because it needs the
    /// signer's key to resolve a permit.
    ///
    /// See `mayAmend`'s second and third bullets for the reasoning. The short
    /// form: a name this app's own writers could not have produced is history
    /// nobody can attribute, and P1 applied it; a name they could have
    /// produced, resolving to nobody, in a book where somebody is NARROWED, is
    /// not the same thing and is not waved through.
    ///
    /// **Narrowing, not events** (final fix wave, W1 — the whole-branch
    /// review's Critical, and the sharpest of its three consequences).
    /// An UNSIGNED device — a VM, an Intel Mac with no Secure Enclave — is a
    /// first-class state in this format: it writes chained lines, seals
    /// nothing, and files no registry record, so the ids it signs are shaped
    /// exactly like this app's (`author-<16 hex>`) and resolve to nobody,
    /// forever. Under the old test, the day the writer admitted their phone on
    /// the signed Mac — a book-author admission that says nothing about
    /// anybody's permit — every `annotationEdit` and `annotationWithdraw` that
    /// unsigned Mac had ever written stopped being honoured: withdrawn notes
    /// came back and edits reverted, on every signed Mac, with nothing red
    /// anywhere. That is P3 refusing what P1 applied, which is the one thing
    /// this milestone promised not to do.
    ///
    /// Asked of the permits instead, the rule fires where it was meant to: in
    /// a book that has a reviewer, a scoped author, or a role word this build
    /// cannot read, an unattributable production-shaped id could be any of
    /// them and is not waved through.
    ///
    /// **And narrowing still does not reach BACK** (P3b Task 2, Denver's
    /// ruling of 2026-09-20). The W1 fix above narrowed *when* this rule
    /// fires; it left it reaching backwards *once it does*. The day the root
    /// makes anybody a reviewer, every withdrawal an enclave-less Mac had ever
    /// made stops being honoured — deleted notes come back, edits revert, on
    /// every signed Mac, with nothing red anywhere. That is the same defect
    /// the W1 fix was about, one condition along.
    ///
    /// So the photograph decides. A line at or before the first narrowing is
    /// **exactly what P1 made of it**, amendments included; a line after it is
    /// not waved through — and in practice is not here at all, because the
    /// unsigned door holds it and a held line never reaches the deriver. What
    /// remains after the snapshot, and is what this guard is now FOR, is an id
    /// this register cannot place arriving in a file it CAN: a signed device
    /// naming somebody else's fingerprint on its own line, which no photograph
    /// covers and which stays refused.
    ///
    /// `insideTheUnsignedSnapshot` is the amending line's own side, carried by
    /// op id out of the partition that judged it (`AmendmentPermits`). False
    /// is the answer for every caller that has no carrier and for every line
    /// no unsigned door judged, which is P3a's answer exactly.
    static func unplaced(
        _ deviceId: String, trust: TrustTable,
        insideTheUnsignedSnapshot: Bool = false
    ) -> Bool {
        guard DeviceIdentity.looksLikeADeviceId(deviceId) else { return true }
        if insideTheUnsignedSnapshot { return true }
        return !trust.hasNarrowingPermits
    }
}

/// **Which amendments a derivation honours** (P3a Task 6).
///
/// `AnnotationDeriver` is pure and has no project, no registry and no table;
/// the ownership rule needs all three. So it is handed in as one value with a
/// **neutral default** — `honourEverything`, which is exactly what the deriver
/// did before P3a and is what every caller with no table keeps doing (the
/// phone, `RewindImpact`, every test).
///
/// One value rather than a set of parameters for `PermitContext`'s reason: a
/// half-supplied policy is a check that silently decides nothing.
public struct AnnotationAmendments: Sendable {

    /// `(amendment, creation) -> honoured`.
    private let rule: @Sendable (Op, Op) -> Bool

    public init(honours rule: @escaping @Sendable (Op, Op) -> Bool) {
        self.rule = rule
    }

    /// Every edit and every withdrawal stands — the pre-P3a rule, and the one
    /// a caller with no register has any business applying.
    public static let honourEverything = AnnotationAmendments { _, _ in true }

    /// Whether this amendment op stands against the note its `creation` op made.
    public func honours(_ amendment: Op, creation: Op) -> Bool {
        rule(amendment, creation)
    }

    /// **The production policy**, built by a caller that already holds a
    /// verified table.
    ///
    /// `documentClass` is a CLOSURE and is asked at most once, and only where
    /// some signer's permit makes the answer turn on it — resolving one means
    /// decoding a manifest, and a permit that covers the whole book answers
    /// `.yes` in the hardest class there is. That is
    /// `OpLogStore.localWritePermit`'s own shape, for its own reason, and it
    /// is what keeps a book with no permit events paying nothing.
    ///
    /// **`permits` is the permit AS OF THE LINE**, carried out of the partition
    /// that judged it (`AmendmentPermits`) and keyed by the amending op's id.
    /// A permit is evaluated as of the line and never as of today — both ways
    /// of getting that wrong are silent, and this rule has two of them: by
    /// today's permit a demotion reaches back and un-does an author's honest
    /// edit of somebody else's note, and a promotion pardons a reviewer's
    /// withdrawal of one.
    ///
    /// **An op with no entry falls back to the signer's current permit**, which
    /// is what this did before the map existed and is right for exactly the
    /// cases that produce no entry: a book with no permit events (where every
    /// timeline is one entry, so current *is* as-of-the-line), and a line no
    /// partition judged — legacy history, an unsigned device, a book with no
    /// register. None of those has a past permit to be wrong about.
    ///
    /// **`insideTheUnsignedSnapshot` is the same carrier's second product**
    /// (P3b Task 2): the op ids of amendment lines the unsigned door found at
    /// or before the book's first narrowing. It reaches exactly one arm —
    /// `AnnotationOwnership.unplaced`, after that function has already decided
    /// it cannot place the signer — and empty is P3a's behaviour exactly.
    public static func judged(
        by trust: TrustTable,
        permits: [String: Permit] = [:],
        insideTheUnsignedSnapshot: Set<String> = [],
        class documentClass: @escaping @Sendable () -> DocumentClass
    ) -> AnnotationAmendments {
        let memo = PermitMemo<DocumentClass>()
        return AnnotationAmendments { amendment, creation in
            let inside = insideTheUnsignedSnapshot.contains(amendment.opId)
            guard let signer = trust.deviceKey(forDeviceId: amendment.device)
            else {
                return AnnotationOwnership.unplaced(
                    amendment.device, trust: trust,
                    insideTheUnsignedSnapshot: inside)
            }
            let permit = permits[amendment.opId]
                ?? trust.timeline(forSealKey: signer.key).current
            // The same skip the partition makes, and for the same reason: a
            // permit that can refuse nothing cannot refuse this either, so the
            // manifest is never read for it.
            if permit.allowsEverything(actor: signer.actor) { return true }
            return AnnotationOwnership.mayAmend(
                signerDevice: amendment.device,
                creatorDevice: creation.device,
                signerPermit: permit,
                signerActor: signer.actor,
                in: memo { documentClass() },
                trust: trust,
                insideTheUnsignedSnapshot: inside)
        }
    }
}
