import Foundation
import Combine

@MainActor
final class MarketDetailViewModel: ObservableObject {
    @Published private(set) var book: L2Book?
    @Published private(set) var trades: [Trade] = []
    @Published private(set) var candles: [Candle] = []
    @Published private(set) var universe: Universe?
    @Published private(set) var szDecimals: Int = 4
    @Published private(set) var liveCtx: ActiveAssetCtx?
    @Published private(set) var errorMessage: String?
    @Published var interval: CandleInterval = .m15 {
        didSet {
            socket.unsubscribe(["type": "candle", "coin": coin, "interval": oldValue.rawValue])
            Task { await loadCandles() }
            socket.subscribeCandle(coin: coin, interval: interval.rawValue)
        }
    }

    @Published private(set) var coin: String
    private let api: HyperliquidAPI
    private let socket: HyperliquidSocket

    init(coin: String, api: HyperliquidAPI, socket: HyperliquidSocket) {
        self.coin = coin
        self.api = api
        self.socket = socket
    }

    /// Swap in a new symbol without tearing down the VM — unsubscribe the
    /// current feeds, rewrite the coin, then resubscribe.
    func switchTo(coin newCoin: String) {
        guard newCoin != coin else { return }
        stop()
        self.coin = newCoin
        self.book = nil
        self.trades = []
        self.candles = []
        self.liveCtx = nil
        self.szDecimals = 4
        start()
    }

    var midPrice: Double? {
        if let m = liveCtx?.markPrice { return m }
        if let bid = book?.bids.first?.price { return bid }
        if let last = candles.last { return Double(last.close) }
        return nil
    }

    func start() {
        // meta & candle history have no WS equivalent
        Task { await loadMeta() }
        Task { await loadCandles() }
        // l2Book / trades / activeAssetCtx all push a snapshot on subscribe → no REST needed
        subscribeLive()
    }

    private func loadMeta() async {
        do {
            let uni = try await api.meta()
            self.universe = uni
            if let meta = uni.universe.first(where: { $0.name == coin }) {
                self.szDecimals = meta.szDecimals
            }
        } catch { self.errorMessage = error.localizedDescription }
    }

    func stop() {
        socket.unsubscribe(["type": "l2Book", "coin": coin])
        socket.unsubscribe(["type": "trades", "coin": coin])
        socket.unsubscribe(["type": "activeAssetCtx", "coin": coin])
        socket.unsubscribe(["type": "candle", "coin": coin, "interval": interval.rawValue])
    }

    private func loadCandles() async {
        let end = Int64(Date().timeIntervalSince1970 * 1000)
        let start = end - Int64(interval.seconds * 500 * 1000)
        do { self.candles = try await api.candles(coin: coin, interval: interval, startMs: start, endMs: end) }
        catch { self.errorMessage = error.localizedDescription }
    }

    private func subscribeLive() {
        socket.on(channel: "l2Book") { [weak self] data in
            guard let book = try? JSONDecoder().decode(L2Book.self, from: data) else { return }
            Task { @MainActor [weak self] in
                guard let self, book.coin == self.coin else { return }
                self.book = book
            }
        }
        socket.on(channel: "trades") { [weak self] data in
            guard let trades = try? JSONDecoder().decode([Trade].self, from: data) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let merged = (trades + self.trades).prefix(100)
                self.trades = Array(merged)
            }
        }
        socket.on(channel: "activeAssetCtx") { [weak self] data in
            guard let ctx = try? JSONDecoder().decode(ActiveAssetCtx.self, from: data) else { return }
            Task { @MainActor [weak self] in
                guard let self, ctx.coin == self.coin else { return }
                self.liveCtx = ctx
            }
        }
        socket.on(channel: "candle") { [weak self] data in
            // WS pushes a single in-progress candle each tick.
            let dec = JSONDecoder()
            let one = try? dec.decode(Candle.self, from: data)
            let many = (one == nil) ? (try? dec.decode([Candle].self, from: data)) : nil
            let updates = one.map { [$0] } ?? many ?? []
            guard !updates.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                for c in updates where c.s == self.coin && c.i == self.interval.rawValue {
                    if let idx = self.candles.firstIndex(where: { $0.t == c.t }) {
                        self.candles[idx] = c
                    } else {
                        self.candles.append(c)
                    }
                }
            }
        }
        socket.subscribeL2Book(coin: coin)
        socket.subscribeTrades(coin: coin)
        socket.subscribeActiveAssetCtx(coin: coin)
        socket.subscribeCandle(coin: coin, interval: interval.rawValue)
        if socket.state == .disconnected { socket.connect() }
    }
}

/// Wire payload for the `activeAssetCtx` subscription. The server sends a
/// coin-keyed envelope whose `ctx` matches the REST `AssetContext` shape.
struct ActiveAssetCtx: Decodable {
    let coin: String
    let ctx: AssetContext

    var markPrice: Double? { ctx.markPx.flatMap(Double.init) }
    var midPrice: Double? { ctx.midPx.flatMap(Double.init) }
    var funding: Double? { ctx.funding.flatMap(Double.init) }
    var openInterest: Double? { ctx.openInterest.flatMap(Double.init) }
}
