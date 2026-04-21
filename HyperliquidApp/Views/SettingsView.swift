import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var session: AppSession
    @EnvironmentObject var wallet: WalletConnectService

    @State private var manualAddress: String = ""
    @State private var enabling: Bool = false
    @State private var enableError: String?
    @State private var showDisableConfirm = false
    @State private var showTransfer = false

    var body: some View {
        NavigationStack {
            Form {
                walletSection
                tradingSection
                networkSection
                connectionSection
                aboutSection
            }
            .navigationTitle("Settings")
            .onAppear { manualAddress = session.walletAddress ?? "" }
            .alert("Disable trading?", isPresented: $showDisableConfirm) {
                Button("Disable", role: .destructive) { session.forgetAgent() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Your agent key will be deleted. You'll need to sign another approveAgent transaction to re-enable.")
            }
            .sheet(isPresented: $showTransfer) {
                TransferView(session: session)
            }
        }
    }

    // MARK: - Sections

    private var walletSection: some View {
        Section("Wallet") {
            if let addr = wallet.connectedAddress ?? session.walletAddress {
                LabeledContent("Address", value: addr.shortAddress)
                    .font(.system(.body, design: .monospaced))
                Button("Disconnect") {
                    Task { await wallet.disconnect() }
                }
                .foregroundStyle(.red)
            } else {
                Button {
                    wallet.presentConnect()
                } label: {
                    Label("Connect Wallet", systemImage: "wallet.pass")
                }

                DisclosureGroup("Or enter address manually (read-only)") {
                    TextField("0x…", text: $manualAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    Button("Save") {
                        session.walletAddress = manualAddress.isEmpty ? nil : manualAddress
                    }
                }
            }
        }
    }

    private var tradingSection: some View {
        Section("Trading") {
            Button {
                showTransfer = true
            } label: {
                Label("Transfer funds", systemImage: "arrow.left.arrow.right")
            }
            .disabled(wallet.connectedAddress == nil)

            if let agent = session.agent {
                LabeledContent("Agent", value: agent.address.shortAddress)
                    .font(.system(.body, design: .monospaced))
                LabeledContent("Age") {
                    Text("\(agent.daysOld)d")
                        .foregroundStyle(agent.needsRotation ? .orange : .secondary)
                }
                Text("Trading enabled — orders are signed locally by your agent key.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if agent.needsRotation {
                    Label("Agent is \(agent.daysOld) days old. Rotate it for safety.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    Button {
                        Task { await rotateAgent() }
                    } label: {
                        if enabling { ProgressView() } else { Label("Rotate agent", systemImage: "arrow.triangle.2.circlepath") }
                    }
                    .disabled(enabling)
                }
                Button("Disable trading", role: .destructive) {
                    showDisableConfirm = true
                }
            } else if wallet.connectedAddress != nil {
                Button {
                    Task { await enableTrading() }
                } label: {
                    if enabling { ProgressView() } else { Label("Enable trading", systemImage: "key.fill") }
                }
                .disabled(enabling)
                Text("Signs an `approveAgent` action with your wallet and stores a local agent key for order signing.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let err = enableError {
                    Text(err).font(.footnote).foregroundStyle(.red)
                }
            } else {
                Text("Connect a wallet to enable trading.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var networkSection: some View {
        Section("Network") {
            Picker("Environment", selection: $session.environment) {
                ForEach(HyperliquidEnvironment.allCases) { env in
                    Text(env.displayName).tag(env)
                }
            }
        }
    }

    private var connectionSection: some View {
        Section("Connection") {
            HStack {
                Text("WebSocket")
                Spacer()
                Text(socketStatus).foregroundStyle(socketColor)
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Data", value: session.environment.restURL.host ?? "")
            LabeledContent("Version", value: Bundle.main.shortVersion)
        }
    }

    // MARK: - Actions

    private func enableTrading() async {
        enabling = true
        enableError = nil
        defer { enabling = false }
        do {
            let info = try await session.makeEnabler().enable()
            session.setAgent(info)
        } catch {
            enableError = error.localizedDescription
        }
    }

    /// Rotate: drop the existing agent key, then re-run approveAgent to mint a
    /// fresh one. The old agent remains valid on-chain until its next approval
    /// expiry; users should also un-approve it from the Hyperliquid web UI.
    private func rotateAgent() async {
        enabling = true
        enableError = nil
        defer { enabling = false }
        session.forgetAgent()
        do {
            let info = try await session.makeEnabler().enable()
            session.setAgent(info)
        } catch {
            enableError = error.localizedDescription
        }
    }

    // MARK: - Derived

    private var socketStatus: String {
        switch session.socket.state {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .disconnected: return "Disconnected"
        }
    }

    private var socketColor: Color {
        switch session.socket.state {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .secondary
        }
    }
}

extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }
}

private extension String {
    var shortAddress: String {
        guard count >= 10 else { return self }
        return "\(prefix(6))…\(suffix(4))"
    }
}
