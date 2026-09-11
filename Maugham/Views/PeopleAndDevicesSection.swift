import SwiftUI
import MaughamCore

/// **Project Settings → People & Devices** (signed op log P2, spec §6).
///
/// A thin drawing of `PeopleAndDevicesModel`: every decision about what belongs
/// on screen — which row is a question, which root is this Mac, which claimant
/// has been answered — is made in that value and asserted with nothing mounted.
/// What is left here is layout and four verbs.
///
/// **Revoke and Retire are live as of P2b Task 7**; Merge is still drawn
/// disabled with a tooltip saying when it arrives. Drawn rather than hidden,
/// for P2a's Admit… reason: a control that appears later moves everything under
/// it, and a writer who has learned where Merge lives should find it in the
/// same place when it starts working. A live verb that this Mac may not perform
/// on a given row is disabled with the reason in its tooltip — never hidden,
/// for the same reason and one more: *why can I not revoke this* is a question
/// an absent button answers with silence.
///
/// **Forget this device** is live and touches no registry record — it clears
/// this Mac's own memory of a label.
///
/// A verb that REFUSES says so in `notice`, drawn under the header: the writer
/// pressed something and it did not happen, and a control that looks dead is
/// worse than a refusal (RULING-7).
struct PeopleAndDevicesSection: View {

    let model: PeopleAndDevicesModel
    /// The writer is asking to admit a device. The sheet belongs to the window,
    /// so this posts and the window asks.
    var admit: () -> Void = {}
    /// Clear this Mac's memory of a label for a device the folder no longer
    /// describes.
    var forget: (String) -> Void = { _ in }
    /// Stop applying what a device writes. The argument is the PERSON's
    /// fingerprint — under labels-only that is the device's author key, and it
    /// is the record the root re-signs.
    var revoke: (String) -> Void = { _ in }
    /// Say this Mac has stopped writing in this book. Offered on this Mac's own
    /// row alone: a device signs its own retirement.
    var retire: (String) -> Void = { _ in }
    /// What the last verb said when it refused, or nil.
    var notice: String?

    var body: some View {
        Section {
            if let refusal = model.refusal {
                // RULING-54: a registry present and unreadable says so in the
                // read's own words. Empty rows here would tell the writer that
                // nobody may write in this book — a trust decision nobody made.
                Label(refusal, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                thisMac
                if let notice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(model.pending) { request in
                    pendingRow(request)
                }
                ForEach(model.people) { person in
                    personRow(person)
                }
                ForEach(model.merged) { root in
                    plainRow(root, note: "merged",
                             caption: "Its history is part of this book's chain.")
                }
                ForEach(model.claimants) { root in
                    claimantRow(root)
                }
                ForEach(model.absent) { device in
                    absentRow(device)
                }
            }
        } header: {
            Text("People & Devices")
        } footer: {
            Text(PeopleAndDevicesModel.shareSentence)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - This Mac

    private var thisMac: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.standing)
            Text("This Mac\u{2019}s code is \(model.code).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Rows

    private func pendingRow(_ request: PeopleAndDevicesModel.PendingRequest) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(request.name)
                Text(request.sentence)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Admit\u{2026}", action: admit)
                .controlSize(.small)
                .help("Give this device a name and let its writing in")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func personRow(_ person: PeopleAndDevicesModel.Person) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(person.title)
                        if let mark = person.mark {
                            Text(mark)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(person.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Revoke") { revoke(person.fingerprint) }
                    .controlSize(.small)
                    .disabled(!person.canRevoke)
                    .help(person.whyNotRevocable ?? PeopleAndDevicesModel.revokeHelp)
                    // .help is hover-only; the WHY must reach VoiceOver too.
                    .accessibilityHint(Text(
                        person.whyNotRevocable ?? PeopleAndDevicesModel.revokeHelp))
            }
            if person.canRevoke {
                // Spec §5's own sentence, beside the button rather than in the
                // footer: what Revoke does, and the thing it does not do.
                Text(PeopleAndDevicesModel.revokeSentence)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(person.devices) { device in
                deviceRow(device)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func deviceRow(_ device: PeopleAndDevicesModel.Device) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.name)
                        .font(.callout)
                    if device.isThisMac {
                        Text("this Mac")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(device.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Retire") { retire(device.fingerprint) }
                .controlSize(.small)
                .disabled(!device.canRetire)
                .help(device.whyNotRetirable ?? PeopleAndDevicesModel.retireHelp)
                .accessibilityHint(Text(
                    device.whyNotRetirable ?? PeopleAndDevicesModel.retireHelp))
        }
        .padding(.leading, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func claimantRow(_ root: PeopleAndDevicesModel.Named) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(root.name) (\(root.code))")
                Text("Claims this book as its own. Nothing it writes is applied here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Merge: this is also me") {}
                .controlSize(.small)
                .disabled(true)
                .help(PeopleAndDevicesModel.mergeSoon)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func plainRow(
        _ root: PeopleAndDevicesModel.Named, note: String, caption: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("\(root.name) (\(root.code))")
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func absentRow(_ device: PeopleAndDevicesModel.Named) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(device.name) (\(device.code))")
                Text("This Mac remembers naming it, but nothing in this book describes it now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Forget this device") { forget(device.fingerprint) }
                .controlSize(.small)
                .help("Clear this Mac\u{2019}s memory of the name it gave")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
