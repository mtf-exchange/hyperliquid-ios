import SwiftUI

/// Home screen with an Apple-flavoured liquid-glass look:
///   - Hero balance card on ultraThinMaterial with a subtle diagonal gradient
///     highlight and a continuous rounded corner
///   - Quick-ticker cards on thinMaterial so the tab bar's vibrancy bleeds
///     through
///   - Movers list tapping into Trade
///   - Search field in a material-backed capsule at the top
struct HomeView: View {
    @EnvironmentObject var session: AppSession
    @StateObject private var vm: HomeViewModel
    @State private var hideBalance: Bool = false
    @State private var moverTab: MoverTab = .hot
    @State private var showDeposit = false
    @State private var searchQuery: String = ""
    @FocusState private var searchFocused: Bool

    enum MoverTab: String, CaseIterable, Identifiable {
        case favorites = "Favorites"
        case hot = "Hot"
        case gainers = "Gainers"
        case losers = "Losers"
        case volume = "Volume"
        var id: String { rawValue }
    }

    init(api: HyperliquidAPI, socket: HyperliquidSocket) {
        _vm = StateObject(wrappedValue: HomeViewModel(api: api, socket: socket))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    searchBar
                    if searchFocused && !searchQuery.isEmpty {
                        searchResults
                    } else {
                        balanceCard
                        quickTickers
                        promoBanner
                        moversSection
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 16)
            }
            .background(homeBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .task {
                vm.accountMode = session.accountMode
                await vm.refresh(address: session.walletAddress)
            }
            .refreshable { await vm.refresh(address: session.walletAddress) }
            .onChange(of: session.walletAddress) { _, new in
                Task { await vm.refresh(address: new) }
            }
            .onChange(of: session.accountMode) { _, new in
                vm.accountMode = new
            }
            .sheet(isPresented: $showDeposit) {
                DepositSheet(address: session.walletAddress ?? "")
            }
        }
    }

    // MARK: - Ambient background

    /// Large soft-gradient wash behind the whole scroll content. Lets the
    /// liquid-glass cards pick up colour without any individual layer
    /// shouting. Anchored top-left so the warmest tone sits under the
    /// balance hero.
    private var homeBackground: some View {
        ZStack {
            Color(.systemBackground)
            LinearGradient(
                colors: [Color.brandUp.opacity(0.18), .clear, Color.purple.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
    }

    // MARK: - Search

    /// Real in-place search. Types flow straight through to the market list,
    /// which filters below. Tapping a suggestion routes into Trade. No
    /// decorative user/bell icons — they didn't do anything.
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("Search coin (BTC, ETH, SOL…)", text: $searchQuery)
                .font(.subheadline)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit { commitSearch() }
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                    searchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.thinMaterial, in: .capsule)
        .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 0.5))
    }

    private var searchResults: some View {
        let needle = searchQuery.trimmingCharacters(in: .whitespaces).uppercased()
        let hits = vm.topMarkets.filter { $0.name.uppercased().hasPrefix(needle) || $0.name.uppercased().contains(needle) }
        return VStack(alignment: .leading, spacing: 0) {
            if hits.isEmpty {
                Text("No market matches \"\(searchQuery)\". Try a ticker like BTC.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                ForEach(hits.prefix(12)) { m in
                    Button {
                        searchFocused = false
                        searchQuery = ""
                        session.openTrade(coin: m.name)
                    } label: {
                        HStack(spacing: 10) {
                            CoinLogo(symbol: m.name, size: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(m.name).font(.subheadline.bold())
                                Text(Formatters.compactUSD(m.dayVolumeUSD))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(Formatters.price(m.markPrice))
                                .font(.system(.subheadline, design: .monospaced))
                            DeltaPill(value: m.dayChangePct)
                                .frame(width: 70)
                        }
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    if m.id != hits.prefix(12).last?.id {
                        Divider().opacity(0.3)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
    }

    private func commitSearch() {
        let needle = searchQuery.trimmingCharacters(in: .whitespaces).uppercased()
        if let hit = vm.topMarkets.first(where: { $0.name.uppercased() == needle }) {
            searchFocused = false
            searchQuery = ""
            session.openTrade(coin: hit.name)
        }
    }

    // MARK: - Balance card

    private var balanceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Total asset value")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button { hideBalance.toggle() } label: {
                    Image(systemName: hideBalance ? "eye.slash" : "eye")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Spacer()
                Text(session.accountMode.title.uppercased())
                    .font(.caption2.bold())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: .capsule)
                    .overlay(Capsule().stroke(Color.brandUp.opacity(0.3), lineWidth: 0.5))
                    .foregroundStyle(Color.brandUp)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(hideBalance ? "∗∗∗∗.∗∗" : Formatters.usd(vm.totalEquity))
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("USD")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button {
                    showDeposit = true
                } label: {
                    Text("Add funds")
                        .font(.footnote.bold())
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Color.primary, in: .capsule)
                        .foregroundStyle(Color(.systemBackground))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 14) {
                pnlTile("Unrealized", vm.unrealizedPnl)
                pnlTile("24h P&L", vm.dayPnl)
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.brandUp.opacity(0.22), Color.brandUp.opacity(0.02)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .blendMode(.plusLighter)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.25), Color.white.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        )
        .shadow(color: Color.brandUp.opacity(0.12), radius: 18, x: 0, y: 8)
    }

    private func pnlTile(_ label: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(hideBalance ? "∗∗∗" : Formatters.usd(value))
                .font(.footnote.bold().monospacedDigit())
                .foregroundStyle(Color.delta(value))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: .rect(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 0.5)
        )
    }

    // MARK: - 2x2 quick tickers (glass cards)

    private var quickTickers: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(topTickers) { m in
                Button {
                    session.openTrade(coin: m.name)
                } label: {
                    quickTickerCard(m)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var topTickers: [Market] {
        Array(vm.topMarkets.sorted { ($0.dayVolumeUSD ?? 0) > ($1.dayVolumeUSD ?? 0) }.prefix(4))
    }

    private func quickTickerCard(_ m: Market) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                CoinLogo(symbol: m.name, size: 22)
                Text(m.name).font(.subheadline.bold())
                Spacer()
                Text("Perp")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(Formatters.price(m.markPrice))
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Color.delta(m.dayChangePct))
            if let ch = m.dayChangePct {
                Text(Formatters.percent(ch))
                    .font(.caption.bold())
                    .foregroundStyle(Color.delta(ch))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
    }

    // MARK: - Promo banner

    private var promoBanner: some View {
        Button {
            session.selectedTab = .markets
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.title3)
                    .foregroundStyle(Color.yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text("HIP-3 deployers live")
                        .font(.footnote.bold())
                    Text("Browse permissionless perp venues — Markets → HIP-3.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(14)
            .background(.thinMaterial, in: .rect(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.yellow.opacity(0.3), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Movers

    private var moversSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    ForEach(MoverTab.allCases) { t in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { moverTab = t }
                        } label: {
                            VStack(spacing: 4) {
                                Text(t.rawValue)
                                    .font(moverTab == t ? .subheadline.bold() : .subheadline)
                                    .foregroundStyle(moverTab == t ? Color.primary : Color.secondary)
                                Rectangle()
                                    .fill(moverTab == t ? Color.primary : Color.clear)
                                    .frame(height: 2)
                                    .frame(maxWidth: 22)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }

            HStack {
                Text("Coin / Volume")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("Price")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(width: 84, alignment: .trailing)
                Spacer().frame(width: 12)
                Text("24h%")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(width: 76, alignment: .trailing)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)

            VStack(spacing: 0) {
                ForEach(moversList) { market in
                    Button { session.openTrade(coin: market.name) } label: {
                        HomeMoverRow(market: market)
                    }
                    .buttonStyle(.plain)
                    if market.id != moversList.last?.id {
                        Divider().opacity(0.3)
                    }
                }
            }
            .padding(.horizontal, 6)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.05), lineWidth: 0.5)
            )
        }
    }

    private var moversList: [Market] {
        let base = vm.topMarkets
        switch moverTab {
        case .favorites:
            return Array(base.prefix(10))
        case .hot, .volume:
            return base.sorted { ($0.dayVolumeUSD ?? 0) > ($1.dayVolumeUSD ?? 0) }.prefix(10).map { $0 }
        case .gainers:
            return base.sorted { ($0.dayChangePct ?? 0) > ($1.dayChangePct ?? 0) }.prefix(10).map { $0 }
        case .losers:
            return base.sorted {
                ($0.dayChangePct ?? -.greatestFiniteMagnitude) < ($1.dayChangePct ?? -.greatestFiniteMagnitude)
            }.prefix(10).map { $0 }
        }
    }
}

private struct HomeMoverRow: View {
    let market: Market

    var body: some View {
        HStack(spacing: 12) {
            CoinLogo(symbol: market.name, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(market.name)
                    .font(.subheadline.bold())
                Text(Formatters.compactUSD(market.dayVolumeUSD))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Text(Formatters.price(market.markPrice))
                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                .monospacedDigit()
                .frame(width: 84, alignment: .trailing)
            Spacer().frame(width: 12)
            DeltaPill(value: market.dayChangePct)
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

// MARK: - Deposit sheet

struct DepositSheet: View {
    @Environment(\.dismiss) private var dismiss
    let address: String
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "arrow.down.to.line.compact.square.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.brandUp)
                    .padding(.top, 24)

                Text("Deposit USDC")
                    .font(.title2).bold()

                Text("Send USDC on Arbitrum to your wallet below, then bridge into Hyperliquid from the official bridge UI. The iOS app doesn't custody funds directly.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                if !address.isEmpty {
                    VStack(spacing: 6) {
                        Text("Your address")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Text(address)
                                .font(.system(.footnote, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button {
                                UIPasteboard.general.string = address
                                copied = true
                                Task {
                                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                                    copied = false
                                }
                            } label: {
                                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            }
                        }
                        .padding(10)
                        .background(.thinMaterial, in: .rect(cornerRadius: 10, style: .continuous))
                    }
                    .padding(.horizontal)
                } else {
                    Label("Connect a wallet first", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }

                if let url = URL(string: "https://app.hyperliquid.xyz/trade") {
                    Link(destination: url) {
                        Label("Open Hyperliquid Bridge", systemImage: "arrow.up.right.square")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.brandUp)
                    .padding(.horizontal)
                }

                Spacer()
            }
            .padding(.vertical)
            .navigationTitle("Deposit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
