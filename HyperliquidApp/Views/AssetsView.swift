import SwiftUI

/// "User" tab — wallet, account model, balances (core + every HIP-3
/// deployer the address has funds on), positions, trading toggles,
/// preferences, network, about. Disconnect is prominent and actually
/// clears wallet + agent state.
struct AssetsView: View {
    @EnvironmentObject var session: AppSession
    @EnvironmentObject var wallet: WalletConnectService
    @StateObject private var vm: AssetsViewModel

    @State private var showDisableConfirm = false
    @State private var showDisconnectConfirm = false
    @State private var enabling = false
    @State private var enableError: String?
    @State private var manualAddress: String = ""

    init(api: HyperliquidAPI, socket: HyperliquidSocket) {
        _vm = StateObject(wrappedValue: AssetsViewModel(api: api, socket: socket))
    }

    var body: some View {
        NavigationStack {
            List {
                accountModeSection
                walletSection
                tradingSection
                equitySection

                if !vm.spotBalances.isEmpty {
                    spotSection
                }

                hip3Section

                preferencesSection
                networkSection
                aboutSection

                if let msg = vm.errorMessage {
                    Section { Text(msg).foregroundStyle(.red) }
                }
            }
            .overlay {
                if vm.isLoading && vm.perpState == nil {
                    ProgressView()
                }
            }
            .navigationTitle("User")
            .onAppear { manualAddress = session.walletAddress ?? "" }
            .refreshable { await vm.refresh(address: session.walletAddress) }
            .task { await vm.refresh(address: session.walletAddress) }
            .onChange(of: session.walletAddress) { _, new in
                Task { await vm.refresh(address: new) }
            }
            .alert("Disable trading?", isPresented: $showDisableConfirm) {
                Button("Disable", role: .destructive) { session.forgetAgent() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Deletes the local agent key. Re-enable by approving a new one.")
            }
            .alert("Disconnect wallet?", isPresented: $showDisconnectConfirm) {
                Button("Disconnect", role: .destructive) {
                    Task {
                        await wallet.disconnect()
                        session.walletAddress = nil
                        session.forgetAgent()
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Ends the WalletConnect session and clears the cached address and agent key.")
            }
        }
    }

    // MARK: - Account model

    private var accountModeSection: some View {
        Section {
            Picker("Model", selection: $session.accountMode) {
                ForEach(AccountMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(session.accountMode.subtitle)
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Label("Account model", systemImage: "circle.grid.2x2.fill")
                .font(.caption.bold()).foregroundStyle(.secondary)
        }
    }

    // MARK: - Wallet

    private var walletSection: some View {
        Section {
            if let addr = wallet.connectedAddress ?? session.walletAddress {
                LabeledContent("Address") {
                    Text(Formatters.truncatedAddress(addr))
                        .font(.system(.footnote, design: .monospaced))
                }
                Button(role: .destructive) {
                    showDisconnectConfirm = true
                } label: {
                    Label("Disconnect", systemImage: "rectangle.portrait.and.arrow.right")
                }
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
        } header: {
            Label("Wallet", systemImage: "creditcard.fill")
                .font(.caption.bold()).foregroundStyle(.secondary)
        }
    }

    // MARK: - Trading enable / rotate / disable

    private var tradingSection: some View {
        Section {
            if let agent = session.agent {
                LabeledContent("Agent") {
                    Text(Formatters.truncatedAddress(agent.address))
                        .font(.system(.footnote, design: .monospaced))
                }
                LabeledContent("Age") {
                    Text("\(agent.daysOld)d")
                        .foregroundStyle(agent.needsRotation ? .orange : .secondary)
                }
                if agent.needsRotation {
                    Label("Agent is \(agent.daysOld) days old — rotate it.", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.orange)
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
                if let err = enableError {
                    Text(err).font(.footnote).foregroundStyle(.red)
                }
            } else {
                Text("Connect a wallet to enable trading.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Label("Trading", systemImage: "bolt.fill")
                .font(.caption.bold()).foregroundStyle(.secondary)
        }
    }

    // MARK: - Equity summary

    private var equitySection: some View {
        Section {
            if let core = vm.perpState {
                summaryRow("Perp equity",  Formatters.usd(core.marginSummary.accountValueDouble))
                summaryRow("Withdrawable", Formatters.usd(core.withdrawableDouble))
                summaryRow("Margin used",  Formatters.usd(core.marginSummary.totalMarginUsedDouble))
                if !core.assetPositions.isEmpty {
                    DisclosureGroup("Positions (\(core.assetPositions.count))") {
                        ForEach(core.assetPositions, id: \.position.coin) { wrapper in
                            PositionRow(position: wrapper.position)
                        }
                    }
                }
            } else {
                Text("No perp activity yet.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Label("Core — Hyperliquid", systemImage: "h.circle.fill")
                .font(.caption.bold()).foregroundStyle(.secondary)
        }
    }

    // MARK: - Spot

    private var spotSection: some View {
        Section {
            ForEach(vm.spotBalances) { b in
                HStack {
                    CoinLogo(symbol: b.coin, size: 26)
                    Text(b.coin).font(.subheadline.bold())
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(Formatters.size(b.totalDouble, decimals: 6))
                            .font(.system(.footnote, design: .monospaced))
                        if let entry = Double(b.entryNtl ?? "0"), entry > 0 {
                            Text("≈ \(Formatters.usd(entry))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Label("Spot", systemImage: "circle.dotted")
                .font(.caption.bold()).foregroundStyle(.secondary)
        } footer: {
            if session.accountMode == .unified {
                Text("Unified account — this spot pool is also the collateral backing your perp positions.")
                    .font(.caption2)
            }
        }
    }

    // MARK: - HIP-3 deployers

    /// One sub-section per named dex from `allDexsClearinghouseState`.
    /// Surfaces balance, margin used, and any open positions on that
    /// deployer. Empty if the address has zero exposure to HIP-3.
    ///
    /// Per Hyperliquid docs: *"unified account and portfolio margin shows
    /// all balances and holds in the spot clearinghouse state. Individual
    /// perp dex user states are not meaningful."* So we drop the per-dex
    /// balance/margin lines in those modes and show **positions only** —
    /// which are still real — with a disclaimer.
    @ViewBuilder
    private var hip3Section: some View {
        let named = vm.dexStates.filter { !$0.key.isEmpty }
        let registry: [String: PerpDex] = Dictionary(uniqueKeysWithValues: vm.dexes.map { ($0.name, $0) })
        let balancesMeaningful = session.accountMode.perDexBalancesMeaningful

        if named.isEmpty {
            Section {
                Text("No HIP-3 deployer activity for this address. When you fund a permissionless perp venue (xyz and friends), it'll appear here.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: {
                Label("HIP-3 dexes", systemImage: "square.stack.3d.up")
                    .font(.caption.bold()).foregroundStyle(.secondary)
            }
        } else {
            ForEach(named.keys.sorted(), id: \.self) { dexName in
                Section {
                    if let state = named[dexName] {
                        if balancesMeaningful {
                            summaryRow("Equity",       Formatters.usd(state.marginSummary.accountValueDouble))
                            summaryRow("Withdrawable", Formatters.usd(state.withdrawableDouble))
                            summaryRow("Margin used",  Formatters.usd(state.marginSummary.totalMarginUsedDouble))
                        }
                        if !state.assetPositions.isEmpty {
                            ForEach(state.assetPositions, id: \.position.coin) { wrapper in
                                PositionRow(position: wrapper.position)
                            }
                        } else {
                            Text("No open positions.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    HStack {
                        Image(systemName: "square.stack.3d.up.fill")
                            .foregroundStyle(.purple)
                        Text(registry[dexName]?.displayName ?? dexName)
                            .font(.caption.bold())
                        Spacer()
                        Text(dexName.uppercased())
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.purple.opacity(0.2), in: .capsule)
                            .foregroundStyle(.purple)
                    }
                } footer: {
                    if let deployer = registry[dexName]?.deployer, !deployer.isEmpty {
                        Text("Deployer \(Formatters.truncatedAddress(deployer))")
                            .font(.caption2)
                            .monospaced()
                    }
                }
            }
        }
    }

    // MARK: - Preferences

    private var preferencesSection: some View {
        Section {
            Picker("Size entered as", selection: $session.sizeUnit) {
                Text("USDC").tag(SizeUnit.usdc)
                Text("Base coin").tag(SizeUnit.base)
            }
            .pickerStyle(.menu)
            Text(session.sizeUnit == .usdc
                 ? "Order size is typed in USDC — the app divides by the active price."
                 : "Order size is typed in the base coin directly (e.g. 0.05 for BTC).")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Label("Preferences", systemImage: "slider.horizontal.3")
                .font(.caption.bold()).foregroundStyle(.secondary)
        }
    }

    // MARK: - Network / About

    private var networkSection: some View {
        Section {
            Picker("Environment", selection: $session.environment) {
                ForEach(HyperliquidEnvironment.allCases) { env in
                    Text(env.displayName).tag(env)
                }
            }
            HStack {
                Text("WebSocket")
                Spacer()
                Text(socketStatus).foregroundStyle(socketColor)
            }
        } header: {
            Label("Network", systemImage: "network")
                .font(.caption.bold()).foregroundStyle(.secondary)
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Host", value: session.environment.restURL.host ?? "")
            LabeledContent("Version", value: Bundle.main.shortVersion)
        } header: {
            Label("About", systemImage: "info.circle")
                .font(.caption.bold()).foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(.body, design: .monospaced))
        }
    }

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
}
