import SwiftUI

/// Markets browser. Mirrors the Bitget / Binance layout: a horizontal category
/// strip at the top (All / Crypto / TradFi / HIP-3 / Spot), then a Hot /
/// Gainers / Losers / Volume sub-tab row, then a dense price list. Tapping a
/// row jumps to the Trade tab with that symbol loaded.
struct MarketsView: View {
    @EnvironmentObject var session: AppSession
    @StateObject private var vm: MarketsViewModel
    @State private var activeSort: SortTab = .volume

    enum SortTab: String, CaseIterable, Identifiable {
        case favorites = "Favorites"
        case hot = "Hot"
        case gainers = "Gainers"
        case losers = "Losers"
        case new = "New"
        case volume = "Volume"
        var id: String { rawValue }
    }

    init(api: HyperliquidAPI, socket: HyperliquidSocket) {
        _vm = StateObject(wrappedValue: MarketsViewModel(api: api, socket: socket))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                categoryStrip
                sortStrip
                columnHeader
                marketsList
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle("Markets")
            .overlay(alignment: .bottom) {
                if let msg = vm.errorMessage {
                    Text(msg)
                        .font(.footnote)
                        .padding(8)
                        .background(.red.opacity(0.15), in: .rect(cornerRadius: 8))
                        .padding()
                }
            }
            .task { vm.load() }
            .refreshable { await vm.refresh() }
        }
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search coin", text: $vm.searchText)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            if !vm.searchText.isEmpty {
                Button { vm.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color.gray.opacity(0.12), in: .rect(cornerRadius: 10))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Category tabs (All / Perps / Spot / Crypto / TradFi / HIP-3)

    private var categoryStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                ForEach(MarketsViewModel.Filter.orderedCases) { f in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { vm.filter = f }
                    } label: {
                        VStack(spacing: 4) {
                            Text(f.rawValue)
                                .font(vm.filter == f ? .subheadline.bold() : .subheadline)
                                .foregroundStyle(vm.filter == f ? Color.primary : Color.secondary)
                            Rectangle()
                                .fill(vm.filter == f ? Color.primary : Color.clear)
                                .frame(height: 2)
                                .frame(maxWidth: 18)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
        }
    }

    // MARK: - Sort row (Hot / Gainers / Losers / Volume)

    private var sortStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(SortTab.allCases) { s in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            activeSort = s
                            // Hot defaults to volume sort; others set sort explicitly
                            switch s {
                            case .gainers: vm.sort = .change
                            case .losers:  vm.sort = .change
                            case .volume:  vm.sort = .volume
                            case .favorites, .hot, .new: vm.sort = .volume
                            }
                        }
                    } label: {
                        Text(s.rawValue)
                            .font(activeSort == s ? .footnote.bold() : .footnote)
                            .foregroundStyle(activeSort == s ? Color.primary : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Column header

    private var columnHeader: some View {
        HStack {
            Text("Coin / Volume")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Text("Price")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
            Text("Change")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - List

    private var marketsList: some View {
        List {
            ForEach(sortedRows) { row in
                Button {
                    session.openTrade(coin: row.symbol, isSpot: row.kind == .spot)
                } label: {
                    MarketRow(row: row)
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            }
        }
        .listStyle(.plain)
    }

    private var sortedRows: [MarketsViewModel.Row] {
        let base = vm.filtered
        switch activeSort {
        case .favorites:
            // No favorites persistence yet — surface top 10 by volume as placeholder.
            return Array(base.prefix(20))
        case .hot, .volume:
            return base.sorted { ($0.dayVolumeUSD ?? 0) > ($1.dayVolumeUSD ?? 0) }
        case .gainers:
            return base.sorted { ($0.dayChangePct ?? 0) > ($1.dayChangePct ?? 0) }
        case .losers:
            return base.sorted { ($0.dayChangePct ?? -.greatestFiniteMagnitude) < ($1.dayChangePct ?? -.greatestFiniteMagnitude) }
        case .new:
            return base
        }
    }
}

/// Apple-Stocks-inspired row. Three clean columns:
///   left  — coin logo + ticker / volume
///   centre — price, right-aligned, monospaced
///   right — filled rounded change-pill, generous spacing from price
struct MarketRow: View {
    let row: MarketsViewModel.Row

    var body: some View {
        HStack(spacing: 14) {
            CoinLogo(symbol: row.displayName, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.displayName)
                        .font(.headline)
                    if !row.dex.isEmpty {
                        Text(row.dex.uppercased())
                            .font(.caption2).bold()
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.purple.opacity(0.18), in: .capsule)
                            .foregroundStyle(.purple)
                    }
                }
                Text(Formatters.compactUSD(row.dayVolumeUSD))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Text(Formatters.price(row.markPrice))
                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(minWidth: 84, alignment: .trailing)

            DeltaPill(value: row.dayChangePct)
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}


/// Apple-Stocks-style filled pill. Bold monospaced digits, white text, brand
/// green / red / neutral background with a continuous rounded shape. Used
/// across Home / Markets / the Trade symbol picker.
struct DeltaPill: View {
    let value: Double?

    var body: some View {
        let color = Color.delta(value)
        Text(Formatters.percent(value))
            .font(.footnote.bold().monospacedDigit())
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(color, in: .rect(cornerRadius: 6, style: .continuous))
    }
}
