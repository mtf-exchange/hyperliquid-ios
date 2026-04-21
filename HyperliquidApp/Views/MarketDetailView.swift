import SwiftUI

struct MarketDetailView: View {
    @EnvironmentObject var session: AppSession
    @StateObject private var vm: MarketDetailViewModel
    @StateObject private var trade: TradeViewModel

    init(coin: String, api: HyperliquidAPI, socket: HyperliquidSocket, exchange: HyperliquidExchangeAPI, session: AppSession) {
        _vm = StateObject(wrappedValue: MarketDetailViewModel(
            coin: coin, api: api, socket: socket
        ))
        _trade = StateObject(wrappedValue: TradeViewModel(
            coin: coin, exchange: exchange, session: session
        ))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerCard
                candleChart
                tradePanel
                orderBookView
                tradeTape
            }
            .padding()
        }
        .navigationTitle(vm.coin)
        .navigationBarTitleDisplayMode(.inline)
        .task { vm.start() }
        .onDisappear { vm.stop() }
        .onChange(of: vm.midPrice) { _, new in trade.fillFromMid(new) }
    }

    // MARK: - Sections

    private var headerCard: some View {
        HStack(alignment: .lastTextBaseline, spacing: 12) {
            CoinLogo(symbol: vm.coin, size: 44)
            VStack(alignment: .leading) {
                Text(Formatters.price(vm.midPrice))
                    .font(.system(.largeTitle, design: .monospaced))
                    .bold()
                if let c = vm.candles.last, let o = vm.candles.first, o.open > 0 {
                    let change = Double(c.close - o.open) / Double(o.open)
                    Text(Formatters.percent(change))
                        .foregroundStyle(change >= 0 ? .green : .red)
                }
            }
            Spacer()
        }
    }

    private var candleChart: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(CandleInterval.allCases) { iv in
                    Button {
                        vm.interval = iv
                    } label: {
                        Text(iv.rawValue)
                            .font(.caption2.bold())
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(vm.interval == iv ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.1), in: .capsule)
                            .foregroundStyle(vm.interval == iv ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            KLineChartView(candles: vm.candles, height: 260)
                .frame(height: 260)
        }
    }

    private var tradePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Order Mode", selection: $trade.orderMode) {
                ForEach(TradeViewModel.OrderMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 0) {
                sideButton(title: "Buy / Long", active: trade.isBuy, color: .green) { trade.isBuy = true }
                sideButton(title: "Sell / Short", active: !trade.isBuy, color: .red) { trade.isBuy = false }
            }
            .clipShape(.rect(cornerRadius: 8))

            switch trade.orderMode {
            case .limit:
                HStack {
                    VStack(alignment: .leading) {
                        Text("Price").font(.caption).foregroundStyle(.secondary)
                        TextField("0", text: $trade.priceText)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                    VStack(alignment: .leading) {
                        Text("Size (\(trade.coin))").font(.caption).foregroundStyle(.secondary)
                        TextField("0", text: $trade.sizeText)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                }
            case .market:
                VStack(alignment: .leading) {
                    Text("Size (\(trade.coin))").font(.caption).foregroundStyle(.secondary)
                    TextField("0", text: $trade.sizeText)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
            case .tp, .sl:
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Trigger Price").font(.caption).foregroundStyle(.secondary)
                            TextField("0", text: $trade.triggerPriceText)
                                .keyboardType(.decimalPad)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                        }
                        VStack(alignment: .leading) {
                            Text("Size (\(trade.coin))").font(.caption).foregroundStyle(.secondary)
                            TextField("0", text: $trade.sizeText)
                                .keyboardType(.decimalPad)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                    Picker("Execution", selection: $trade.triggerIsMarket) {
                        Text("Market").tag(true)
                        Text("Limit").tag(false)
                    }
                    .pickerStyle(.segmented)
                    if !trade.triggerIsMarket {
                        VStack(alignment: .leading) {
                            Text("Limit Price").font(.caption).foregroundStyle(.secondary)
                            TextField("0", text: $trade.priceText)
                                .keyboardType(.decimalPad)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                }
            }

            if trade.orderMode == .limit {
                HStack {
                    Picker("TIF", selection: $trade.tif) {
                        Text("GTC").tag(OrderRequest.TimeInForce.gtc)
                        Text("IOC").tag(OrderRequest.TimeInForce.ioc)
                        Text("Post").tag(OrderRequest.TimeInForce.alo)
                    }
                    .pickerStyle(.segmented)
                    Toggle("Reduce Only", isOn: $trade.reduceOnly)
                        .labelsHidden()
                        .tint(.accentColor)
                    Text("Reduce Only").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Spacer()
                    Toggle("Reduce Only", isOn: $trade.reduceOnly)
                        .labelsHidden()
                        .tint(.accentColor)
                    Text("Reduce Only").font(.caption).foregroundStyle(.secondary)
                }
            }

            if let notional = trade.notional {
                Text("Notional ≈ \(Formatters.usd(notional))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if session.agent == nil {
                Text("Enable Trading in Settings first.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Button {
                Task { await trade.submit(universe: vm.universe, markPrice: vm.midPrice) }
            } label: {
                HStack {
                    if trade.submitting { ProgressView() }
                    Text(submitLabel).bold()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .background(trade.isBuy ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
            .foregroundStyle(trade.isBuy ? .green : .red)
            .clipShape(.rect(cornerRadius: 8))
            .disabled(!trade.canSubmit)

            if let r = trade.lastResult { Text(r).font(.caption).foregroundStyle(.green) }
            if let e = trade.lastError  { Text(e).font(.caption).foregroundStyle(.red) }

            DisclosureGroup("Leverage") {
                HStack {
                    TextField("e.g. 5", text: $trade.leverageText)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                    Button("Apply") {
                        Task { await trade.setLeverage(universe: vm.universe) }
                    }
                    .disabled(session.agent == nil)
                }
            }
        }
        .padding()
        .background(Color.gray.opacity(0.08), in: .rect(cornerRadius: 12))
    }

    private var submitLabel: String {
        let side = trade.isBuy ? "Buy" : "Sell"
        switch trade.orderMode {
        case .limit:  return "Place \(side)"
        case .market: return "Place Market \(side)"
        case .tp:     return "Place TP \(side)"
        case .sl:     return "Place SL \(side)"
        }
    }

    private func sideButton(title: String, active: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .bold()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .background(active ? color.opacity(0.25) : Color.gray.opacity(0.1))
        .foregroundStyle(active ? color : .secondary)
    }

    private var orderBookView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Order Book").font(.headline)
            if let book = vm.book {
                HStack(alignment: .top, spacing: 12) {
                    bookSide(levels: book.bids.prefix(10), color: .green, alignment: .leading)
                    bookSide(levels: book.asks.prefix(10), color: .red, alignment: .trailing)
                }
            } else {
                ProgressView()
            }
        }
    }

    private func bookSide<S: Sequence>(levels: S, color: Color, alignment: HorizontalAlignment) -> some View where S.Element == L2Level {
        VStack(alignment: alignment, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                HStack {
                    if alignment == .trailing { Spacer() }
                    Text(Formatters.price(level.price))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(color)
                    Text(Formatters.size(level.size, decimals: vm.szDecimals))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if alignment == .leading { Spacer() }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var tradeTape: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Trades").font(.headline)
            ForEach(vm.trades.prefix(20)) { trade in
                HStack {
                    Text(Formatters.price(trade.price))
                        .foregroundStyle(trade.isBuy ? .green : .red)
                    Text(Formatters.size(trade.size, decimals: vm.szDecimals))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(trade.date, style: .time)
                        .foregroundStyle(.secondary)
                }
                .font(.system(.caption, design: .monospaced))
            }
        }
    }
}
