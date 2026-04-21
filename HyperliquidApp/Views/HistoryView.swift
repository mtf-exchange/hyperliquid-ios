import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var session: AppSession
    @StateObject private var vm: HistoryViewModel
    @State private var tab: Tab = .fills

    enum Tab: String, CaseIterable, Identifiable {
        case fills = "Fills"
        case funding = "Funding"
        var id: String { rawValue }
    }

    init(api: HyperliquidAPI, socket: HyperliquidSocket) {
        _vm = StateObject(wrappedValue: HistoryViewModel(api: api, socket: socket))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("History", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)

                List {
                    if let msg = vm.errorMessage {
                        Section { Text(msg).foregroundStyle(.secondary) }
                    }

                    switch tab {
                    case .fills:
                        if vm.fills.isEmpty, vm.errorMessage == nil, !vm.isLoading {
                            Section { Text("No fills in history.").foregroundStyle(.secondary) }
                        } else {
                            Section("Fills") {
                                ForEach(vm.fills) { FillRow(fill: $0) }
                            }
                        }
                    case .funding:
                        if vm.funding.isEmpty, vm.errorMessage == nil, !vm.isLoading {
                            Section { Text("No funding in the last 30 days.").foregroundStyle(.secondary) }
                        } else {
                            Section("Funding") {
                                ForEach(vm.funding) { FundingRow(event: $0) }
                            }
                        }
                    }
                }
                .overlay {
                    if vm.isLoading { ProgressView() }
                }
            }
            .navigationTitle("History")
            .refreshable { await vm.refresh(address: session.walletAddress) }
            .task { await vm.refresh(address: session.walletAddress) }
        }
    }
}

struct FillRow: View {
    let fill: UserFill

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CoinLogo(symbol: fill.coin, size: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(fill.coin).font(.headline)
                HStack(spacing: 6) {
                    Text(fill.isBuy ? "BUY" : "SELL")
                        .font(.caption2).bold()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(fill.isBuy ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
                        .foregroundStyle(fill.isBuy ? .green : .red)
                        .clipShape(.capsule)
                    if let dir = fill.dir {
                        Text(dir)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Formatters.price(fill.price)) × \(Formatters.size(fill.size, decimals: 4))")
                    .font(.system(.caption, design: .monospaced))
                if let pnl = fill.pnl, pnl != 0 {
                    Text(Formatters.usd(pnl))
                        .font(.caption)
                        .foregroundStyle(pnl >= 0 ? .green : .red)
                }
                if let fee = fill.feeValue, fee != 0 {
                    Text("fee \(Formatters.usd(fee))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(fill.date, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct FundingRow: View {
    let event: UserFunding

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CoinLogo(symbol: event.delta.coin, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.delta.coin).font(.headline)
                Text(Formatters.percent(event.delta.rate))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospaced()
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Formatters.usd(event.delta.usdcValue))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(event.delta.usdcValue >= 0 ? .green : .red)
                Text(event.date, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
