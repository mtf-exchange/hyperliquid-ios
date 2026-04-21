import SwiftUI

/// Composite Trade screen.
/// - Perps/Spot toggle + symbol picker at the top
/// - Price + change + funding header
/// - Compact K-line (interval chips collapsed into a menu to save vertical space)
/// - Orderbook (left) + order form (right) packed tight
/// - Activity strip below: Positions / Open Orders / TWAP / Trade / Funding / History
struct TradeView: View {
    @ObservedObject var session: AppSession
    @StateObject private var marketsVM: MarketsViewModel
    @StateObject private var detailVM: MarketDetailViewModel
    @StateObject private var tradeVM: TradeViewModel
    @StateObject private var activityVM: TradeTabViewModel

    @State private var selectedCoin: String
    @State private var activeSection: TradeTabViewModel.Section = .positions
    @State private var activeBookPanel: BookPanel = .orderbook
    @State private var showSymbolPicker = false
    @State private var showChartDetail = false
    @State private var showInlineChart = false
    @State private var sizePercent: Double = 0
    @State private var cancelError: String?

    enum BookPanel: String, CaseIterable, Identifiable {
        case orderbook = "Orderbook"
        case depth = "Depth"
        case trades = "Trades"
        var id: String { rawValue }
    }

    private let api: HyperliquidAPI
    private let socket: HyperliquidSocket
    private let exchange: HyperliquidExchangeAPI

    init(session: AppSession, api: HyperliquidAPI, socket: HyperliquidSocket, exchange: HyperliquidExchangeAPI) {
        self.session = session
        self.api = api
        self.socket = socket
        self.exchange = exchange
        let initialCoin = session.tradeCoin
        _selectedCoin = State(initialValue: initialCoin)
        _marketsVM = StateObject(wrappedValue: MarketsViewModel(api: api, socket: socket))
        _detailVM = StateObject(wrappedValue: MarketDetailViewModel(coin: initialCoin, api: api, socket: socket))
        _tradeVM = StateObject(wrappedValue: TradeViewModel(coin: initialCoin, exchange: exchange, session: session))
        _activityVM = StateObject(wrappedValue: TradeTabViewModel(api: api, socket: socket))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    VStack(spacing: 6) {
                        headerRow
                        priceRow
                        if showInlineChart { chartBlock }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 4)

                    // Main trading region: orderbook on the LEFT (~40% width),
                    // order form on the RIGHT. Both use the full horizontal
                    // extent of the screen minus a minimal 4pt outer gutter.
                    HStack(alignment: .top, spacing: 6) {
                        bookPanelBlock
                            .frame(maxWidth: .infinity, alignment: .top)
                        orderFormColumn
                            .frame(maxWidth: .infinity, alignment: .top)
                    }
                    .padding(.horizontal, 4)

                    activityBlock
                        .padding(.horizontal, 8)
                }
                .padding(.bottom, 6)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .task {
                detailVM.start()
                marketsVM.load()
                await activityVM.refresh(address: session.walletAddress)
            }
            .onChange(of: detailVM.midPrice) { _, new in tradeVM.fillFromMid(new) }
            .onChange(of: session.walletAddress) { _, new in
                Task { await activityVM.refresh(address: new) }
            }
            .onChange(of: session.tradeCoin) { _, coin in
                switchCoin(to: coin)
            }
            .onDisappear { detailVM.stop() }
            .sheet(isPresented: $showSymbolPicker) {
                SymbolPicker(
                    perps: marketsVM.perps,
                    onPick: { coin in
                        switchCoin(to: coin)
                        showSymbolPicker = false
                    }
                )
                .presentationDetents([.medium, .large])
            }
            .navigationDestination(isPresented: $showChartDetail) {
                ChartDetailView(coin: selectedCoin, api: api, socket: socket)
                    .environmentObject(session)
            }
        }
    }

    // MARK: - Header (symbol picker + chart detail)

    private var headerRow: some View {
        HStack(spacing: 8) {
            Button {
                showSymbolPicker = true
            } label: {
                HStack(spacing: 4) {
                    CoinLogo(symbol: baseSymbol, size: 22)
                    Text(selectedCoin).font(.title3.bold())
                    Image(systemName: "chevron.down").font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showInlineChart.toggle() }
            } label: {
                Image(systemName: showInlineChart ? "chart.bar.xaxis" : "chart.bar.xaxis.ascending")
                    .font(.subheadline)
                    .foregroundStyle(showInlineChart ? Color.brandUp : Color.secondary)
                    .padding(6)
            }
            .buttonStyle(.plain)

            Button {
                showChartDetail = true
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 2)
    }

    private var baseSymbol: String {
        String(selectedCoin.split(separator: "/").first ?? Substring(selectedCoin))
    }

    // MARK: - Price row

    private var priceRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Formatters.price(detailVM.midPrice))
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.delta(dayChangePct))
                .contentTransition(.numericText())

            if let ch = dayChangePct {
                Text(Formatters.percent(ch))
                    .font(.caption.bold().monospacedDigit())
                    .foregroundStyle(Color.delta(ch))
            }
            Spacer(minLength: 4)

            if let ctx = detailVM.liveCtx {
                if let oi = ctx.openInterest {
                    stat("OI", Formatters.compactUSD(oi))
                }
                if let funding = ctx.funding {
                    stat("Fund", String(format: "%+.4f%%", funding * 100))
                        .foregroundStyle(Color.delta(funding))
                }
            }
        }
        .padding(.horizontal, 2)
    }

    private var dayChangePct: Double? {
        // Prefer the authoritative 24h reference price from the live context
        // feed. Fall back to chart-window change when the context hasn't
        // arrived yet (first few hundred ms of a fresh subscribe).
        if let ctx = detailVM.liveCtx,
           let prevStr = ctx.ctx.prevDayPx,
           let prev = Double(prevStr),
           prev > 0,
           let mark = detailVM.midPrice {
            return (mark - prev) / prev
        }
        if let c = detailVM.candles.last,
           let o = detailVM.candles.first,
           o.open > 0 {
            return Double(c.close - o.open) / Double(o.open)
        }
        return nil
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption2.monospacedDigit())
        }
    }

    // MARK: - Chart block

    private var chartBlock: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                ForEach(CandleInterval.allCases) { iv in
                    Button { detailVM.interval = iv } label: {
                        Text(iv.rawValue)
                            .font(.caption2.bold())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(detailVM.interval == iv ? Color.brandUp.opacity(0.2) : Color.clear, in: .capsule)
                            .foregroundStyle(detailVM.interval == iv ? Color.brandUp : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                HStack(spacing: 8) {
                    maLegend(7, .yellow)
                    maLegend(25, .purple)
                    maLegend(99, .pink)
                }
            }
            .padding(.horizontal, 2)

            KLineChartView(candles: detailVM.candles, height: 180)
                .frame(height: 180)
        }
    }

    private func maLegend(_ period: Int, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("MA\(period)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    // MARK: - Book / Depth / Trades panel

    /// Left-column panel hosting one of three views: classic top/bottom
    /// Orderbook, Depth chart, or Trades tape. Tab-strip on top. No outer
    /// material/background — the content is already tight and the tabs
    /// provide the only chrome.
    private var bookPanelBlock: some View {
        VStack(spacing: 0) {
            bookPanelTabs
            Group {
                switch activeBookPanel {
                case .orderbook: orderbookVertical
                case .depth:     depthPanel
                case .trades:    tradesPanel
                }
            }
        }
    }

    private var bookPanelTabs: some View {
        HStack(spacing: 16) {
            ForEach(BookPanel.allCases) { p in
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) { activeBookPanel = p }
                } label: {
                    VStack(spacing: 4) {
                        Text(p.rawValue)
                            .font(activeBookPanel == p ? .footnote.bold() : .footnote)
                            .foregroundStyle(activeBookPanel == p ? Color.primary : Color.secondary)
                        Rectangle()
                            .fill(activeBookPanel == p ? Color.primary : Color.clear)
                            .frame(height: 2)
                            .frame(maxWidth: 24)
                    }
                    .frame(minHeight: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
    }

    /// Classic vertical orderbook: asks stacked on top (best ask just above
    /// the current-price row), bids stacked below (best bid just below). A
    /// prominent centre row shows the last price + mid; the column is dense
    /// enough to fit ~10 levels each side in the narrow trade layout.
    private var orderbookVertical: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Price")
                Spacer()
                Text("Size")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.bottom, 2)

            if let book = detailVM.book {
                let ladder = DepthLadder(book: book, depth: 10)
                // `ladder.asks` is deepest-first so it already reads
                // top-to-bottom with best-ask last. Keep it.
                ForEach(ladder.asks, id: \.price) { entry in
                    orderbookRow(entry: entry, side: .ask, maxCum: ladder.maxCumulative)
                }
                centerPriceRow(book: book)
                ForEach(ladder.bids, id: \.price) { entry in
                    orderbookRow(entry: entry, side: .bid, maxCum: ladder.maxCumulative)
                }
            } else {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 260)
            }
        }
    }

    private enum BookSide { case bid, ask }

    private func orderbookRow(entry: DepthLadder.Entry, side: BookSide, maxCum: Double) -> some View {
        ZStack(alignment: .trailing) {
            GeometryReader { geo in
                let ratio = CGFloat(max(0.03, entry.cumulative / maxCum))
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Rectangle()
                        .fill((side == .bid ? Color.brandUp : Color.brandDown).opacity(0.18))
                        .frame(width: geo.size.width * ratio)
                }
            }
            HStack {
                Text(Formatters.price(entry.price))
                    .foregroundStyle(side == .bid ? Color.brandUp : Color.brandDown)
                Spacer()
                Text(Formatters.size(entry.size, decimals: detailVM.szDecimals))
                    .foregroundStyle(.primary)
            }
            .font(.system(size: 11, design: .monospaced))
            .padding(.horizontal, 4)
        }
        .frame(height: 18)
        .contentShape(Rectangle())
        .onTapGesture { tradeVM.priceText = String(entry.price) }
    }

    private func centerPriceRow(book: L2Book) -> some View {
        let bid = book.bids.first?.price ?? 0
        let ask = book.asks.first?.price ?? 0
        let mid = bid > 0 && ask > 0 ? (bid + ask) / 2 : 0
        let last = detailVM.candles.last.map { Double($0.close) }
        let color = Color.delta(detailVM.liveCtx?.ctx.prevDayPx.flatMap(Double.init).map { prev in
            ((last ?? mid) - prev) / prev
        })
        return VStack(alignment: .leading, spacing: 1) {
            Text(Formatters.price(last ?? (mid == 0 ? nil : mid)))
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .foregroundStyle(color)
            Text(Formatters.price(mid == 0 ? nil : mid))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .background(Color.gray.opacity(0.08))
    }

    // MARK: - Depth panel

    @ViewBuilder
    private var depthPanel: some View {
        if let book = detailVM.book {
            DepthChart(book: book)
                .frame(height: 200)
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: 200)
        }
    }

    // MARK: - Trades panel

    @ViewBuilder
    private var tradesPanel: some View {
        if vm_trades.isEmpty {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: 200)
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text("Price").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text("Size").font(.caption2).foregroundStyle(.secondary)
                    Spacer().frame(width: 72)
                    Text("Time").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8).padding(.bottom, 4)

                ForEach(vm_trades.prefix(40)) { trade in
                    HStack {
                        Text(Formatters.price(trade.price))
                            .foregroundStyle(trade.isBuy ? Color.brandUp : Color.brandDown)
                        Spacer()
                        Text(Formatters.size(trade.size, decimals: detailVM.szDecimals))
                            .foregroundStyle(.primary)
                        Spacer().frame(width: 14)
                        Text(trade.date, style: .time)
                            .foregroundStyle(.secondary)
                            .frame(width: 62, alignment: .trailing)
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                }
            }
        }
    }

    /// Alias to the VM's trades array — the `tradesPanel` builder uses this
    /// instead of `detailVM.trades` directly because `detailVM.trades` has a
    /// tricky emissions pattern that occasionally misbehaves under SwiftUI's
    /// diff engine when re-rendered in a ViewBuilder. Using a computed proxy
    /// keeps the capture snapshot stable.
    private var vm_trades: [Trade] { detailVM.trades }

    // MARK: - Order form

    private var orderFormColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            orderTypePicker

            switch tradeVM.orderMode {
            case .limit:
                stepperField("Price", text: $tradeVM.priceText, tick: priceTick, trailing: AnyView(bboButton))
                sizeStepperField
                sizeSlider
                tifPicker
            case .market:
                sizeStepperField
                sizeSlider
            case .tp, .sl:
                stepperField("Trigger", text: $tradeVM.triggerPriceText, tick: priceTick, trailing: nil)
                sizeStepperField
                sizeSlider
                Toggle("Trigger executes at market", isOn: $tradeVM.triggerIsMarket)
                    .toggleStyle(.switch).controlSize(.small).font(.caption)
                if !tradeVM.triggerIsMarket {
                    stepperField("Limit", text: $tradeVM.priceText, tick: priceTick, trailing: nil)
                }
            }

            HStack {
                Toggle(isOn: $tradeVM.reduceOnly) {
                    Text("Reduce only").font(.caption)
                }
                .toggleStyle(.switch).controlSize(.small)
                Spacer()
                if let n = tradeVM.notional {
                    Text("≈ \(Formatters.compactUSD(n))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 6) {
                submitButton(isLong: true)
                submitButton(isLong: false)
            }

            if session.agent == nil {
                Label("Enable trading in User tab", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
            }
            if let r = tradeVM.lastResult { Text(r).font(.caption2).foregroundStyle(Color.brandUp) }
            if let e = tradeVM.lastError  { Text(e).font(.caption2).foregroundStyle(Color.brandDown) }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
    }

    private var sizeStepperField: some View {
        stepperField(
            "Size (\(session.sizeUnit.label(coin: tradeVM.coin)))",
            text: $tradeVM.sizeText,
            tick: sizeTick,
            trailing: nil
        )
    }

    /// Quick-size row: slider + [25% 50% 75% MAX] buttons. Scales against
    /// `activityVM.state?.withdrawable` — if no account context yet, the
    /// slider hides.
    @ViewBuilder
    private var sizeSlider: some View {
        if let maxUsd = maxNotional, maxUsd > 0 {
            VStack(spacing: 6) {
                Slider(value: $sizePercent, in: 0...1, step: 0.01)
                    .tint(tradeVM.isBuy ? Color.brandUp : Color.brandDown)
                    .onChange(of: sizePercent) { _, v in applySizePercent(v) }

                HStack(spacing: 6) {
                    ForEach([0.25, 0.50, 0.75, 1.00], id: \.self) { pct in
                        Button {
                            sizePercent = pct
                            applySizePercent(pct)
                        } label: {
                            Text(pct == 1.0 ? "MAX" : "\(Int(pct * 100))%")
                                .font(.caption2.bold())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .background(
                                    sizePercent >= pct - 0.01 && sizePercent <= pct + 0.01
                                        ? Color.primary.opacity(0.12)
                                        : Color.gray.opacity(0.12),
                                    in: .rect(cornerRadius: 6, style: .continuous)
                                )
                                .foregroundStyle(Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var maxNotional: Double? {
        activityVM.state?.withdrawableDouble
    }

    private func applySizePercent(_ pct: Double) {
        guard let maxUsd = maxNotional, maxUsd > 0 else { return }
        let usdAmount = maxUsd * pct
        switch session.sizeUnit {
        case .usdc:
            tradeVM.sizeText = formatStepper(usdAmount)
        case .base:
            guard let price = detailVM.midPrice, price > 0 else { return }
            let base = usdAmount / price
            tradeVM.sizeText = formatStepper(base)
        }
    }

    /// Order-type picker styled as a horizontal segmented group of capsule
    /// buttons. Matches the rest of the app's tab-strip language — cleaner
    /// than iOS's default segmented control in a dark context.
    private var orderTypePicker: some View {
        HStack(spacing: 6) {
            ForEach(TradeViewModel.OrderMode.allCases) { mode in
                Button { tradeVM.orderMode = mode } label: {
                    Text(mode.rawValue)
                        .font(tradeVM.orderMode == mode ? .footnote.bold() : .footnote)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(tradeVM.orderMode == mode ? Color.primary.opacity(0.12) : Color.clear, in: .rect(cornerRadius: 7))
                        .foregroundStyle(tradeVM.orderMode == mode ? Color.primary : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.gray.opacity(0.1), in: .rect(cornerRadius: 8))
    }

    private var tifPicker: some View {
        HStack(spacing: 6) {
            ForEach([(OrderRequest.TimeInForce.gtc, "GTC"),
                     (.ioc, "IOC"),
                     (.alo, "Post")], id: \.1) { pair in
                Button { tradeVM.tif = pair.0 } label: {
                    Text(pair.1)
                        .font(.caption.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(tradeVM.tif == pair.0 ? Color.primary.opacity(0.12) : Color.clear, in: .rect(cornerRadius: 6))
                        .foregroundStyle(tradeVM.tif == pair.0 ? Color.primary : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.gray.opacity(0.08), in: .rect(cornerRadius: 7))
    }

    private var bboButton: AnyView {
        AnyView(
            Button { fillBBO() } label: {
                Text("BBO")
                    .font(.caption.bold())
                    .foregroundStyle(Color.brandUp)
            }
            .buttonStyle(.plain)
        )
    }

    /// Tick sizes derived from the current price so the ± buttons nudge in
    /// sensible increments for whatever asset is active. For a $75k BTC that
    /// means $1-step; for a $0.01 meme it's $0.0001.
    private var priceTick: Double {
        guard let p = detailVM.midPrice, p > 0 else { return 0.01 }
        let order = pow(10, floor(log10(p)))
        return max(0.00000001, order / 1000)
    }
    private var sizeTick: Double {
        switch session.sizeUnit {
        case .usdc:
            // $10 increments feel right for most liquid pairs; scales down
            // for tiny accounts via the slider.
            return 10
        case .base:
            return pow(10, -Double(detailVM.szDecimals))
        }
    }

    private func stepperField(_ label: String, text: Binding<String>, tick: Double, trailing: AnyView?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                trailing
            }
            HStack(spacing: 0) {
                stepperButton(systemImage: "minus") {
                    adjust(text: text, by: -tick)
                }
                TextField("0", text: text)
                    .multilineTextAlignment(.center)
                    .font(.system(.body, design: .monospaced))
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .keyboardType(.decimalPad)
                stepperButton(systemImage: "plus") {
                    adjust(text: text, by: tick)
                }
            }
            .background(Color.gray.opacity(0.12), in: .rect(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.05), lineWidth: 0.5)
            )
        }
    }

    private func stepperButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.footnote.bold())
                .frame(width: 36, height: 36)
                .foregroundStyle(Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func adjust(text: Binding<String>, by tick: Double) {
        let current = Double(text.wrappedValue) ?? 0
        let next = max(0, current + tick)
        text.wrappedValue = formatStepper(next)
    }

    private func formatStepper(_ v: Double) -> String {
        if v == 0 { return "" }
        // Mirror the dynamic precision used by the price formatter, but drop
        // trailing zeros so the text field looks tidy when the user keeps
        // tapping the stepper.
        let mag = Swift.abs(v)
        let digits: Int
        switch mag {
        case 10_000...:   digits = 1
        case 1_000...:    digits = 2
        case 100...:      digits = 3
        case 10...:       digits = 4
        case 1...:        digits = 5
        case 0.1...:      digits = 6
        case 0.01...:     digits = 7
        default:          digits = 8
        }
        return String(format: "%.\(digits)f", v)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }

    /// One big colored button per direction. Tapping Open Long submits a buy,
    /// Open Short submits a sell — the form's own isBuy gets flipped before
    /// the submit so the order goes out in the right direction.
    private func submitButton(isLong: Bool) -> some View {
        let color: Color = isLong ? .brandUp : .brandDown
        let title = isLong ? "Open Long" : "Open Short"
        return Button {
            tradeVM.isBuy = isLong
            Task { await tradeVM.submit(universe: detailVM.universe, markPrice: detailVM.midPrice) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isLong ? "arrow.up.right" : "arrow.down.right")
                    .font(.caption.bold())
                Text(title)
                    .font(.subheadline.bold())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .background(color)
        .foregroundStyle(Color.white)
        .clipShape(.rect(cornerRadius: 10))
        .disabled(!tradeVM.canSubmit)
        .opacity(tradeVM.canSubmit ? 1 : 0.6)
    }

    private func fillBBO() {
        guard let book = detailVM.book else { return }
        if tradeVM.isBuy, let bid = book.bids.first {
            tradeVM.priceText = String(bid.price)
        } else if !tradeVM.isBuy, let ask = book.asks.first {
            tradeVM.priceText = String(ask.price)
        }
    }

    // MARK: - Activity block

    private var activityBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    ForEach(TradeTabViewModel.Section.allCases) { s in
                        Button {
                            withAnimation(.easeInOut(duration: 0.12)) { activeSection = s }
                        } label: {
                            VStack(spacing: 4) {
                                Text(s.rawValue)
                                    .font(activeSection == s ? .subheadline.bold() : .subheadline)
                                    .foregroundStyle(activeSection == s ? Color.primary : Color.secondary)
                                Rectangle()
                                    .fill(activeSection == s ? Color.primary : Color.clear)
                                    .frame(height: 2)
                                    .frame(maxWidth: 28)
                            }
                            .frame(minHeight: 36)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }

            activityContent
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var activityContent: some View {
        switch activeSection {
        case .positions:
            if activityVM.positions.isEmpty {
                emptyRow("No open positions")
            } else {
                // Edge-to-edge: cancel the activityBlock's outer
                // horizontal padding (8) so each position row uses the
                // full screen width. Rows have their own 10pt padding.
                VStack(spacing: 0) {
                    ForEach(activityVM.positions) { pos in
                        PositionCard(
                            entry: pos,
                            markPrice: pos.position.coin == detailVM.coin ? detailVM.midPrice : nil,
                            onClose: { closePosition(pos) }
                        )
                    }
                }
                .padding(.horizontal, -8)
            }
        case .openOrders:
            if activityVM.openOrders.isEmpty {
                emptyRow("No open orders")
            } else {
                VStack(spacing: 4) {
                    ForEach(activityVM.openOrders) { entry in
                        HStack(spacing: 6) {
                            OpenOrderRow(order: entry.order)
                            if !entry.isCore {
                                Text(entry.dex.uppercased())
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.purple.opacity(0.2), in: .capsule)
                                    .foregroundStyle(.purple)
                            }
                            Button(role: .destructive) {
                                cancel(order: entry.order)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(Color.brandDown)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if let err = cancelError {
                        Text(err).font(.caption2).foregroundStyle(Color.brandDown)
                    }
                }
            }
        case .twap:
            if activityVM.twaps.isEmpty {
                emptyRow("No active or recent TWAPs")
            } else {
                ForEach(activityVM.twaps) { TwapRow(twap: $0) }
            }
        case .tradeHistory:
            if activityVM.fills.isEmpty {
                emptyRow("No fills")
            } else {
                ForEach(activityVM.fills.prefix(30)) { FillCard(fill: $0) }
            }
        case .fundingHistory:
            if activityVM.funding.isEmpty {
                emptyRow("No funding events")
            } else {
                ForEach(activityVM.funding.prefix(30)) { FundingRow(event: $0) }
            }
        case .orderHistory:
            if activityVM.fills.isEmpty {
                emptyRow("No order history")
            } else {
                ForEach(activityVM.fills.prefix(40)) { OrderHistoryRow(fill: $0) }
            }
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
    }

    // MARK: - Actions

    private func switchCoin(to coin: String) {
        guard coin != selectedCoin else { return }
        selectedCoin = coin
        session.tradeCoin = coin
        session.tradeIsSpot = false
        detailVM.switchTo(coin: coin)
        tradeVM.switchTo(coin: coin)
    }

    /// "Close position" — currently flips to the Trade tab's form with a
    /// reduce-only market order for the full size. The actual exchange
    /// call still goes through the TradeViewModel so cancel/position
    /// state stays consistent.
    private func closePosition(_ pos: TradeTabViewModel.DexedPosition) {
        // Switch the form to that coin, flip side, prime size, mark
        // reduce-only. The user still hits the action button — we don't
        // fire a market order automatically to avoid a footgun.
        if pos.position.coin != selectedCoin {
            switchCoin(to: pos.position.coin)
        }
        tradeVM.isBuy = !pos.position.isLong
        tradeVM.reduceOnly = true
        tradeVM.orderMode = .market
        let closeSize = Swift.abs(pos.position.size)
        switch session.sizeUnit {
        case .base:
            tradeVM.sizeText = Formatters.size(closeSize, decimals: detailVM.szDecimals)
        case .usdc:
            if let mark = detailVM.midPrice ?? pos.position.entryPrice {
                tradeVM.sizeText = Formatters.size(closeSize * mark, decimals: 2)
            }
        }
    }

    private func cancel(order: OpenOrder) {
        Task {
            guard session.agent != nil, let universe = detailVM.universe else {
                cancelError = "Universe not loaded yet"
                return
            }
            do {
                let agent = try await session.loadAgentKey(reason: "Cancel order")
                _ = try await exchange.cancel(
                    coin: order.coin,
                    oid: order.oid,
                    universe: universe,
                    agent: agent,
                    isMainnet: session.environment == .mainnet
                )
                cancelError = nil
            } catch {
                cancelError = error.localizedDescription
            }
        }
    }
}

// MARK: - Symbol picker sheet

private struct SymbolPicker: View {
    let perps: [Market]
    let onPick: (String) -> Void
    @State private var query: String = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredPerps) { m in
                    Button { onPick(m.name) } label: {
                        HStack {
                            CoinLogo(symbol: m.name, size: 24)
                            Text(m.name).bold()
                            if !m.dex.isEmpty {
                                Text(m.dex.uppercased())
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.purple.opacity(0.18), in: .capsule)
                                    .foregroundStyle(.purple)
                            }
                            Spacer()
                            Text(Formatters.price(m.markPrice)).monospaced()
                            DeltaPill(value: m.dayChangePct)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle("Select Market")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var filteredPerps: [Market] {
        let base = perps.sorted { ($0.dayVolumeUSD ?? 0) > ($1.dayVolumeUSD ?? 0) }
        if query.isEmpty { return base }
        return base.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

}

// MARK: - Activity row helpers

/// Dense, edge-to-edge position row. No side-margin, no rounded chrome —
/// the tab's own container already holds the section together, wasting
/// 20pt of a 390pt screen on card padding for every position is rude.
/// Layout per row:
///
///   BTC  Cross 10x              +$123.40 / +3.27%        [Close]
///   size 0.05 BTC ≈ $3,760
///   Entry 74,123   Mark 75,200  Liq 60,234  Margin $376
///
/// All numbers monospaced; PnL line uses brand green/red for both the
/// absolute and % components; a thin divider separates rows.
struct PositionCard: View {
    let entry: TradeTabViewModel.DexedPosition
    var position: Position { entry.position }

    /// Mark price surfaced from the Trade page — optional because in
    /// contexts where we don't have a live orderbook (e.g. Assets tab)
    /// we just fall back to position value / size.
    var markPrice: Double? = nil
    var onClose: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            topRow
            sizeRow
            statsRow
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 10)
        .background(
            Rectangle()
                .fill(Color.gray.opacity(0.04))
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5)
                }
        )
    }

    // MARK: Rows

    private var topRow: some View {
        HStack(spacing: 6) {
            sideBadge
            Text(position.coin).font(.subheadline.bold())
            if !entry.isCore {
                Text(entry.dex.uppercased())
                    .font(.caption2.bold())
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.purple.opacity(0.2), in: .capsule)
                    .foregroundStyle(.purple)
            }
            if let lev = position.leverage {
                Text(leverageLabel(lev))
                    .font(.caption2.bold())
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.gray.opacity(0.15), in: .capsule)
                    .foregroundStyle(.primary)
            }
            Spacer(minLength: 6)

            // PnL + ROI inline — bold monospaced, brand colour
            HStack(spacing: 4) {
                Text(Formatters.usd(position.unrealizedPnlValue))
                    .font(.footnote.bold().monospacedDigit())
                Text("/")
                    .font(.footnote).foregroundStyle(.secondary)
                Text(position.roe.map { Formatters.percent($0) } ?? "—")
                    .font(.footnote.bold().monospacedDigit())
            }
            .foregroundStyle(Color.delta(position.unrealizedPnlValue))

            if let onClose {
                Button(action: onClose) {
                    Text("Close")
                        .font(.caption.bold())
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.gray.opacity(0.2), in: .rect(cornerRadius: 5, style: .continuous))
                        .foregroundStyle(Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var sizeRow: some View {
        let absSize = Swift.abs(position.size)
        let notional: Double? = {
            if let v = position.value { return v }
            if let mark = markPrice { return absSize * mark }
            return nil
        }()
        return HStack(spacing: 8) {
            Text("Size")
                .font(.caption2).foregroundStyle(.secondary)
            Text(Formatters.size(absSize, decimals: 4))
                .font(.caption.monospacedDigit())
            Text(position.coin)
                .font(.caption2).foregroundStyle(.secondary)
            if let notional {
                Text("≈ \(Formatters.usd(notional))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var statsRow: some View {
        HStack(spacing: 10) {
            stat("Entry", Formatters.price(position.entryPrice))
            stat("Mark",  Formatters.price(markPrice))
            stat("Liq",   Formatters.price(position.liquidationPrice), color: .brandDown)
            stat("Margin", Formatters.usd(Double(position.marginUsed ?? "0")))
            Spacer(minLength: 0)
        }
    }

    private func stat(_ label: String, _ value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(color)
        }
    }

    private var sideBadge: some View {
        Text(position.isLong ? "LONG" : "SHORT")
            .font(.caption2.bold())
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(
                (position.isLong ? Color.brandUp : Color.brandDown),
                in: .rect(cornerRadius: 3, style: .continuous)
            )
            .foregroundStyle(Color.white)
    }

    private func leverageLabel(_ lev: Leverage) -> String {
        let type = lev.type == "cross" ? "Cross" : "Iso"
        return "\(type) \(lev.value)x"
    }
}

/// Detail-rich fill card for the Trade History tab. Mirrors `PositionCard`
/// but shows per-fill numbers: side, coin, direction, realized PnL, size,
/// price, fee, time.
struct FillCard: View {
    let fill: UserFill

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(fill.isBuy ? "BUY" : "SELL")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(
                        (fill.isBuy ? Color.brandUp : Color.brandDown),
                        in: .rect(cornerRadius: 4, style: .continuous)
                    )
                    .foregroundStyle(Color.white)
                Text(fill.coin).font(.subheadline.bold())
                if let dir = fill.dir {
                    Text(dir).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(fill.date, style: .relative)
                    .font(.caption2).foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 12) {
                statCell("PnL",
                         value: fill.pnl.map { Formatters.usd($0) } ?? "—",
                         color: Color.delta(fill.pnl))
                statCell("Size",
                         value: Formatters.size(fill.size, decimals: 4),
                         alignment: .center)
                statCell("Price",
                         value: Formatters.price(fill.price),
                         alignment: .trailing)
            }

            if (fill.feeValue ?? 0) != 0 {
                HStack {
                    Text("Fee \(Formatters.usd(fill.feeValue ?? 0))")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text("oid \(fill.oid)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 0.5)
        )
    }
}

private func statCell(_ label: String, value: String, color: Color = .primary, alignment: HorizontalAlignment = .leading) -> some View {
    VStack(alignment: alignment, spacing: 2) {
        Text(label)
            .font(.caption2)
            .foregroundStyle(.secondary)
        Text(value)
            .font(.footnote.monospacedDigit().bold())
            .foregroundStyle(color)
    }
    .frame(maxWidth: .infinity, alignment: alignment.frameAlignment)
}

private extension HorizontalAlignment {
    var frameAlignment: Alignment {
        switch self {
        case .leading:  return .leading
        case .trailing: return .trailing
        default:        return .center
        }
    }
}

private struct TwapRow: View {
    let twap: TwapState

    private var progress: Double {
        guard twap.size > 0 else { return 0 }
        return min(1, twap.executedSize / twap.size)
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(twap.coin).font(.subheadline).bold()
                    Text(twap.isBuy ? "BUY" : "SELL")
                        .font(.caption2).bold()
                        .foregroundStyle(twap.isBuy ? Color.brandUp : Color.brandDown)
                }
                Text("\(twap.minutes ?? 0)min · size \(Formatters.size(twap.size, decimals: 4))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 80)
                Text("\(Int(progress * 100))%")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct OrderHistoryRow: View {
    let fill: UserFill
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(fill.coin).font(.subheadline).bold()
                    Text(fill.isBuy ? "BUY" : "SELL")
                        .font(.caption2).bold()
                        .foregroundStyle(fill.isBuy ? Color.brandUp : Color.brandDown)
                    if let dir = fill.dir {
                        Text(dir).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text("oid \(fill.oid)").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Formatters.price(fill.price)) × \(Formatters.size(fill.size, decimals: 4))")
                    .font(.system(size: 11, design: .monospaced))
                Text(fill.date, style: .relative).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
