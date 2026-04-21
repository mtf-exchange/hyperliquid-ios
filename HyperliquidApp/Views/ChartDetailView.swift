import SwiftUI

/// Full-page chart / analysis screen pushed from the Trade tab's chart icon.
/// Layout: header → price stats → interval chips → MA legend → K-line → the
/// three inline panels (Orderbook / Depth / Trades) → Trade CTA. Unlike the
/// earlier draft that copied the Bitget "Chart / Data / Square / About /
/// Copy / Bot" top strip wholesale, this version keeps only what a derivative
/// trader actually uses on this screen.
struct ChartDetailView: View {
    @EnvironmentObject var session: AppSession
    @Environment(\.dismiss) private var dismiss

    @StateObject private var vm: MarketDetailViewModel
    @State private var activePanel: Panel = .orderbook

    private let coin: String

    enum Panel: String, CaseIterable, Identifiable {
        case orderbook = "Orderbook"
        case depth = "Depth"
        case trades = "Trades"
        var id: String { rawValue }
    }

    init(coin: String, api: HyperliquidAPI, socket: HyperliquidSocket) {
        self.coin = coin
        _vm = StateObject(wrappedValue: MarketDetailViewModel(coin: coin, api: api, socket: socket))
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().opacity(0.3)
            ScrollView {
                VStack(spacing: 10) {
                    priceStatsRow
                    intervalRow
                    maLegend
                    KLineChartView(candles: vm.candles, height: 300)
                        .frame(height: 300)
                    panelTabs
                    panelContent
                    Color.clear.frame(height: 80)   // room for bottom CTA
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
            }
            bottomBar
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task { vm.start() }
        .onDisappear { vm.stop() }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.title3)
                    .foregroundStyle(Color.primary)
            }
            Text(coin)
                .font(.title3.bold())
            Text("Perpetual")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            headerIcon("star")
            headerIcon("ellipsis")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func headerIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
    }

    // MARK: - Price stats

    private var priceStatsRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Last price")
                    .font(.caption).foregroundStyle(.secondary)
                Text(Formatters.price(vm.midPrice))
                    .font(.system(size: 26, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.delta(changePct))
                    .contentTransition(.numericText())
                if let ch = changePct {
                    Text(Formatters.percent(ch))
                        .font(.caption.bold())
                        .foregroundStyle(Color.delta(ch))
                }
                Text("Mark price \(Formatters.price(vm.liveCtx?.markPrice))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                statLine("24h high", Formatters.price(dayHigh))
                statLine("24h low",  Formatters.price(dayLow))
                statLine("24h Vol (\(coin))", Formatters.compact(dayVolumeCoin))
                statLine("24h Turnover",       Formatters.compactUSD(dayTurnover))
            }
        }
    }

    private func statLine(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.monospacedDigit())
        }
    }

    private var changePct: Double? {
        if let prevStr = vm.liveCtx?.ctx.prevDayPx,
           let prev = Double(prevStr),
           prev > 0,
           let mark = vm.midPrice {
            return (mark - prev) / prev
        }
        if let c = vm.candles.last, let o = vm.candles.first, o.open > 0 {
            return Double(c.close - o.open) / Double(o.open)
        }
        return nil
    }

    private var dayHigh: Double? { vm.candles.suffix(96).map { Double($0.high) }.max() }
    private var dayLow: Double?  { vm.candles.suffix(96).map { Double($0.low)  }.min() }
    private var dayVolumeCoin: Double? {
        let v = vm.candles.suffix(96).reduce(0.0) { $0 + Double($1.volume) }
        return v > 0 ? v : nil
    }
    private var dayTurnover: Double? {
        let mark = vm.midPrice ?? 0
        guard let vol = dayVolumeCoin else { return nil }
        return vol * mark
    }

    // MARK: - Interval row

    private var intervalRow: some View {
        HStack(spacing: 10) {
            ForEach(CandleInterval.allCases) { iv in
                Button { vm.interval = iv } label: {
                    Text(iv.rawValue)
                        .font(vm.interval == iv ? .subheadline.bold() : .subheadline)
                        .foregroundStyle(vm.interval == iv ? Color.primary : Color.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    // MARK: - MA legend

    private var maLegend: some View {
        HStack(spacing: 14) {
            legendItem("MA(7)", color: .yellow, value: ma(period: 7))
            legendItem("MA(25)", color: .purple, value: ma(period: 25))
            legendItem("MA(99)", color: .pink, value: ma(period: 99))
            Spacer()
        }
    }

    private func legendItem(_ label: String, color: Color, value: Double?) -> some View {
        Text("\(label): \(Formatters.price(value))")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(color)
    }

    private func ma(period: Int) -> Double? {
        guard vm.candles.count >= period else { return nil }
        let slice = vm.candles.suffix(period)
        return slice.reduce(0.0) { $0 + Double($1.close) } / Double(period)
    }

    // MARK: - Panel tabs (Orderbook / Depth / Trades)

    private var panelTabs: some View {
        HStack(spacing: 18) {
            ForEach(Panel.allCases) { p in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { activePanel = p }
                } label: {
                    VStack(spacing: 4) {
                        Text(p.rawValue)
                            .font(activePanel == p ? .subheadline.bold() : .subheadline)
                            .foregroundStyle(activePanel == p ? Color.primary : Color.secondary)
                        Rectangle()
                            .fill(activePanel == p ? Color.primary : Color.clear)
                            .frame(height: 2)
                            .frame(maxWidth: 40)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var panelContent: some View {
        switch activePanel {
        case .orderbook: orderbookPanel
        case .depth:     depthPanel
        case .trades:    tradesPanel
        }
    }

    // MARK: - Orderbook panel

    private var orderbookPanel: some View {
        VStack(spacing: 3) {
            HStack {
                Text("Price (USD)").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("Size (\(coin))").font(.caption2).foregroundStyle(.secondary)
                Spacer().frame(width: 80)
                Text("Total").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            if let book = vm.book {
                let ladder = DepthLadder(book: book, depth: 12)
                orderbookHalf(levels: ladder.asks, side: .ask, maxCum: ladder.maxCumulative)
                spreadRow(book: book)
                orderbookHalf(levels: ladder.bids, side: .bid, maxCum: ladder.maxCumulative)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .padding(8)
        .background(Color.gray.opacity(0.04), in: .rect(cornerRadius: 8))
    }

    private enum BookSide { case bid, ask }

    private func orderbookHalf(levels: [DepthLadder.Entry], side: BookSide, maxCum: Double) -> some View {
        VStack(spacing: 1) {
            ForEach(levels, id: \.price) { entry in
                ZStack(alignment: .trailing) {
                    GeometryReader { geo in
                        let ratio = CGFloat(max(0.05, entry.cumulative / maxCum))
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            Rectangle()
                                .fill((side == .bid ? Color.brandUp : Color.brandDown).opacity(0.14))
                                .frame(width: geo.size.width * ratio)
                        }
                    }
                    HStack(spacing: 0) {
                        Text(Formatters.price(entry.price))
                            .foregroundStyle(side == .bid ? Color.brandUp : Color.brandDown)
                        Spacer()
                        Text(Formatters.size(entry.size, decimals: vm.szDecimals))
                            .foregroundStyle(.primary)
                        Spacer().frame(width: 14)
                        Text(Formatters.compact(entry.cumulative))
                            .foregroundStyle(.secondary)
                            .frame(width: 66, alignment: .trailing)
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 4)
                }
                .frame(height: 18)
            }
        }
    }

    private func spreadRow(book: L2Book) -> some View {
        let bid = book.bids.first?.price ?? 0
        let ask = book.asks.first?.price ?? 0
        let mid = bid > 0 && ask > 0 ? (bid + ask) / 2 : 0
        let bps = mid > 0 ? (ask - bid) / mid * 10_000 : 0
        return HStack {
            Text(Formatters.price(mid == 0 ? nil : mid))
                .font(.system(size: 13, weight: .bold, design: .monospaced))
            Spacer()
            Text(String(format: "Spread %.1fbp", bps))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(Color.gray.opacity(0.1), in: .rect(cornerRadius: 6))
    }

    // MARK: - Depth panel

    private var depthPanel: some View {
        Group {
            if let book = vm.book {
                DepthChart(book: book)
                    .frame(height: 200)
                    .padding(8)
                    .background(Color.gray.opacity(0.04), in: .rect(cornerRadius: 8))
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            }
        }
    }

    // MARK: - Trades panel

    private var tradesPanel: some View {
        VStack(spacing: 2) {
            HStack {
                Text("Price").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("Size").font(.caption2).foregroundStyle(.secondary)
                Spacer().frame(width: 80)
                Text("Time").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            if vm.trades.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ForEach(vm.trades.prefix(40)) { trade in
                    HStack {
                        Text(Formatters.price(trade.price))
                            .foregroundStyle(trade.isBuy ? Color.brandUp : Color.brandDown)
                        Spacer()
                        Text(Formatters.size(trade.size, decimals: vm.szDecimals))
                            .foregroundStyle(.primary)
                        Spacer().frame(width: 14)
                        Text(trade.date, style: .time)
                            .foregroundStyle(.secondary)
                            .frame(width: 66, alignment: .trailing)
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 4)
                    .frame(height: 18)
                }
            }
        }
        .padding(8)
        .background(Color.gray.opacity(0.04), in: .rect(cornerRadius: 8))
    }

    // MARK: - Bottom CTA

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button {
                session.tradeCoin = coin
                dismiss()
            } label: {
                Text("Trade")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.primary, in: .rect(cornerRadius: 10))
                    .foregroundStyle(Color(.systemBackground))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
        .overlay(alignment: .top) { Divider().opacity(0.3) }
    }
}

// MARK: - Depth chart

/// Symmetric area chart of cumulative bid / ask depth around the mid price.
/// Bid side is teal/green on the left, ask side is pink/red on the right.
/// Price labels underneath; simple y-axis gridline at the top.
/// Used by both ChartDetailView and TradeView's Depth panel.
struct DepthChart: View {
    let book: L2Book

    var body: some View {
        Canvas { context, size in
            let bids = Array(book.bids.prefix(40))
            let asks = Array(book.asks.prefix(40))
            guard !bids.isEmpty, !asks.isEmpty else { return }

            let mid = (bids[0].price + asks[0].price) / 2
            let halfW = size.width / 2
            let maxCumulative: Double = {
                let bidCum = bids.reduce(0.0) { $0 + $1.size }
                let askCum = asks.reduce(0.0) { $0 + $1.size }
                return max(bidCum, askCum, 1)
            }()

            let priceSpan: Double = {
                let lowest  = bids.last?.price  ?? mid
                let highest = asks.last?.price  ?? mid
                return max(mid - lowest, highest - mid)
            }()
            guard priceSpan > 0 else { return }

            // Build cumulative curves
            func cumulativePoints(levels: [L2Level], fromMid: Bool, priceToX: (Double) -> CGFloat) -> [CGPoint] {
                var running = 0.0
                var pts: [CGPoint] = []
                pts.append(CGPoint(x: halfW, y: size.height))   // start at baseline from center
                for level in levels {
                    running += level.size
                    let x = priceToX(level.price)
                    let y = size.height - CGFloat(running / maxCumulative) * size.height
                    pts.append(CGPoint(x: x, y: y))
                }
                if let lastX = pts.last?.x {
                    pts.append(CGPoint(x: lastX, y: size.height))   // close to baseline
                }
                return pts
            }

            let bidPoints = cumulativePoints(levels: bids, fromMid: true) { price in
                halfW - CGFloat((mid - price) / priceSpan) * halfW
            }
            let askPoints = cumulativePoints(levels: asks, fromMid: true) { price in
                halfW + CGFloat((price - mid) / priceSpan) * halfW
            }

            // Fill bids
            var bidPath = Path()
            bidPath.addLines(bidPoints)
            bidPath.closeSubpath()
            context.fill(bidPath, with: .color(.brandUp.opacity(0.35)))
            context.stroke(bidPath, with: .color(.brandUp), lineWidth: 1)

            // Fill asks
            var askPath = Path()
            askPath.addLines(askPoints)
            askPath.closeSubpath()
            context.fill(askPath, with: .color(.brandDown.opacity(0.35)))
            context.stroke(askPath, with: .color(.brandDown), lineWidth: 1)

            // Mid-price dashed vertical
            var midLine = Path()
            midLine.move(to: CGPoint(x: halfW, y: 0))
            midLine.addLine(to: CGPoint(x: halfW, y: size.height))
            context.stroke(midLine, with: .color(.white.opacity(0.2)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))

            // Labels
            context.draw(
                Text(Formatters.price(mid))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.primary),
                at: CGPoint(x: halfW, y: 10),
                anchor: .center
            )
            context.draw(
                Text(Formatters.price(bids.last?.price))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color.brandUp),
                at: CGPoint(x: 2, y: size.height - 10),
                anchor: .leading
            )
            context.draw(
                Text(Formatters.price(asks.last?.price))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color.brandDown),
                at: CGPoint(x: size.width - 2, y: size.height - 10),
                anchor: .trailing
            )
        }
    }
}
