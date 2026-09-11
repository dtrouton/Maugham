import SwiftUI
import MaughamCore

/// **Project Settings → People & Devices** (signed op log P2, spec §6).
///
/// A thin drawing of `PeopleAndDevicesModel`: every decision about what belongs
/// on screen — which row is a question, which root is this Mac, which claimant
/// has been answered — is made in that value and asserted with nothing mounted.
/// What is left here is layout and four verbs.
///
/// **Three of the four verbs are drawn disabled** (Revoke, Retire, Merge), with
/// a tooltip saying when they arrive. Drawn rather than hidden, for P2a's
/// Admit… reason: a control that appears later moves everything under it, and a
/// writer who has learned where Revoke lives should find it in the same place
/// when it starts working. **Forget this device** is live — it clears this
/// Mac's own memory of a label and touches no registry record.
struct PeopleAndDevicesSection: View {

    let model: PeopleAndDevicesModel
    /// The writer is asking to admit a device. The sheet belongs to the window,
    /// so this posts and the window asks.
    var admit: () -> Void = {}
    /// Clear this Mac's memory of a label for a device the folder no longer
    /// describes.
    var forget: (String) -> Void = { _ in }

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
                Button("Revoke") {}
                    .controlSize(.small)
                    .disabled(true)
                    .help(PeopleAndDevicesModel.revokeSoon)
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
            Button("Retire") {}
                .controlSize(.small)
                .disabled(true)
                .help(PeopleAndDevicesModel.retireSoon)
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
