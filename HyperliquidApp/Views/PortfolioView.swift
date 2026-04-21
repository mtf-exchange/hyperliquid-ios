import SwiftUI

struct PortfolioView: View {
    @EnvironmentObject var session: AppSession
    @StateObject private var vm: PortfolioViewModel

    init(api: HyperliquidAPI, exchange: HyperliquidExchangeAPI, socket: HyperliquidSocket) {
        _vm = StateObject(wrappedValue: PortfolioViewModel(api: api, exchange: exchange, socket: socket))
    }

    var body: some View {
        NavigationStack {
            List {
                if let state = vm.state {
                    Section("Account") {
                        row("Equity", Formatters.usd(state.marginSummary.accountValueDouble))
                        row("Position Value", Formatters.usd(state.marginSummary.totalPositionValue))
                        row("Margin Used", Formatters.usd(state.marginSummary.totalMarginUsedDouble))
                        row("Withdrawable", Formatters.usd(state.withdrawableDouble))
                    }

                    if !state.assetPositions.isEmpty {
                        Section("Positions") {
                            ForEach(state.assetPositions, id: \.position.coin) { wrapper in
                                PositionRow(position: wrapper.position)
                            }
                        }
                    }
                }

                if !vm.openOrders.isEmpty {
                    Section("Open Orders") {
                        ForEach(vm.openOrders) { order in
                            OpenOrderRow(order: order)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        guard session.agent != nil else { return }
                                        Task {
                                            do {
                                                let agent = try await session.loadAgentKey(reason: "Cancel order")
                                                await vm.cancel(
                                                    order: order,
                                                    universe: vm.universe,
                                                    agent: agent,
                                                    isMainnet: session.environment == .mainnet
                                                )
                                            } catch {
                                                vm.surface(error: error)
                                            }
                                        }
                                    } label: {
                                        Label("Cancel", systemImage: "xmark")
                                    }
                                    .disabled(session.agent == nil)
                                }
                        }
                    }
                }

                if let msg = vm.errorMessage {
                    Section { Text(msg).foregroundStyle(.secondary) }
                }
            }
            .overlay {
                if vm.isLoading { ProgressView() }
            }
            .navigationTitle("Portfolio")
            .refreshable { await vm.refresh(address: session.walletAddress) }
            .task { await vm.refresh(address: session.walletAddress) }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(.body, design: .monospaced))
        }
    }
}

struct PositionRow: View {
    let position: Position

    var body: some View {
        HStack(spacing: 10) {
            CoinLogo(symbol: position.coin, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(position.coin).font(.headline)
                Text(position.isLong ? "LONG" : "SHORT")
                    .font(.caption2).bold()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(position.isLong ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
                    .foregroundStyle(position.isLong ? .green : .red)
                    .clipShape(.capsule)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Formatters.usd(position.value))
                    .font(.system(.body, design: .monospaced))
                if let pnl = position.unrealizedPnlValue {
                    Text(Formatters.usd(pnl))
                        .font(.caption)
                        .foregroundStyle(pnl >= 0 ? .green : .red)
                }
            }
        }
    }
}

struct OpenOrderRow: View {
    let order: OpenOrder

    var body: some View {
        HStack(spacing: 10) {
            CoinLogo(symbol: order.coin, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(order.coin).font(.headline)
                Text(order.isBuy ? "BUY" : "SELL")
                    .font(.caption2).bold()
                    .foregroundStyle(order.isBuy ? .green : .red)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Formatters.price(order.price)) × \(Formatters.size(order.size, decimals: 4))")
                    .font(.system(.caption, design: .monospaced))
                Text(order.date, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
