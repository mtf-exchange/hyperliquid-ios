import SwiftUI

/// Modal that routes a user-signed transfer action through the connected
/// wallet. Covers withdrawals (on-chain), USDC sends (L1), and spot/perp
/// class transfers. The viewmodel does the signing + POST dance; this view
/// only wires the form fields.
struct TransferView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm: TransferViewModel

    init(session: AppSession) {
        _vm = StateObject(wrappedValue: TransferViewModel(session: session))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $vm.mode) {
                        ForEach(TransferViewModel.Mode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Details") {
                    if vm.mode.needsDestination {
                        TextField("0x… destination", text: $vm.destination)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.body, design: .monospaced))
                    }
                    TextField("Amount (USDC)", text: $vm.amount)
                        .keyboardType(.decimalPad)
                }

                Section {
                    Button {
                        Task { await vm.submit() }
                    } label: {
                        HStack {
                            if vm.submitting {
                                ProgressView()
                            }
                            Text(submitLabel)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!vm.canSubmit)
                }

                if let result = vm.result {
                    Section {
                        Label(result, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                if let err = vm.errorMessage {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }

                Section {
                    Text(footerHint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Transfer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private var submitLabel: String {
        switch vm.mode {
        case .withdraw: return "Withdraw"
        case .usdSend: return "Send"
        case .toPerp: return "Move to Perp"
        case .toSpot: return "Move to Spot"
        }
    }

    private var footerHint: String {
        switch vm.mode {
        case .withdraw:
            return "Sends USDC on-chain to the destination EVM address. Signed by your connected wallet."
        case .usdSend:
            return "Transfers USDC on Hyperliquid to another user by address."
        case .toPerp:
            return "Moves USDC from your spot account into the perp account."
        case .toSpot:
            return "Moves USDC from your perp account into the spot account."
        }
    }
}
