import Foundation
import Combine

@MainActor
final class MarketsViewModel: ObservableObject {
    @Published private(set) var perps: [Market] = []
    @Published private(set) var spot: [SpotMarket] = []
    @Published private(set) var dexes: [PerpDex] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var errorMessage: String?
    @Published var searchText: String = ""
    @Published var sort: Sort = .volume
    @Published var filter: Filter = .all

    enum Sort: String, CaseIterable, Identifiable {
        case volume = "Volume"
        case change = "24h %"
        case name = "Name"
        var id: String { rawValue }
    }

    /// Market filter chips. "All" is every perp market; Crypto/TradFi/HIP-3
    /// are subsets. Spot is hidden for now — data plumbing is still here so
    /// it can come back without a VM rewrite.
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case crypto = "Crypto"
        case tradfi = "TradFi"
        case hip3 = "HIP-3"
        var id: String { rawValue }

        static var orderedCases: [Filter] { [.all, .crypto, .tradfi, .hip3] }
    }

    /// Unified row type for the Markets list. Hashable/Identifiable so the
    /// SwiftUI `List` can diff it directly.
    struct Row: Identifiable, Hashable {
        enum Kind: Hashable { case perp, spot }
        let id: String
        let kind: Kind
        let symbol: String          // coin / pair string used for detail nav
        let displayName: String
        let markPrice: Double?
        let dayVolumeUSD: Double?
        let dayChangePct: Double?
        let dex: String             // "" for core / spot, HIP-3 deployer name otherwise
    }

    private let api: HyperliquidAPI
    private let socket: HyperliquidSocket
    private var refreshTask: Task<Void, Never>?

    init(api: HyperliquidAPI, socket: HyperliquidSocket) {
        self.api = api
        self.socket = socket
    }

    var filtered: [Row] {
        let source: [Row]
        switch filter {
        case .all:
            source = perpRows
        case .crypto:
            source = perps.filter { $0.category == .crypto }.map(Self.row(from:))
        case .tradfi:
            source = perps.filter { $0.category == .tradfi }.map(Self.row(from:))
        case .hip3:
            source = perps.filter { $0.category == .hip3 }.map(Self.row(from:))
        }

        let searched: [Row]
        if searchText.isEmpty {
            searched = source
        } else {
            searched = source.filter {
                $0.symbol.localizedCaseInsensitiveContains(searchText)
                    || $0.displayName.localizedCaseInsensitiveContains(searchText)
            }
        }

        switch sort {
        case .volume:
            return searched.sorted { ($0.dayVolumeUSD ?? 0) > ($1.dayVolumeUSD ?? 0) }
        case .change:
            return searched.sorted { ($0.dayChangePct ?? 0) > ($1.dayChangePct ?? 0) }
        case .name:
            return searched.sorted { $0.displayName < $1.displayName }
        }
    }

    private var perpRows: [Row] { perps.map(Self.row(from:)) }
    private var spotRows: [Row] { spot.map(Self.row(from:)) }

    private static func row(from m: Market) -> Row {
        Row(
            id: "perp:\(m.id)",
            kind: .perp,
            symbol: m.name,
            displayName: m.name,
            markPrice: m.markPrice,
            dayVolumeUSD: m.dayVolumeUSD,
            dayChangePct: m.dayChangePct,
            dex: m.dex
        )
    }

    private static func row(from m: SpotMarket) -> Row {
        Row(
            id: "spot:\(m.symbol)",
            kind: .spot,
            symbol: m.symbol,
            displayName: m.displayName,
            markPrice: m.markPrice,
            dayVolumeUSD: m.dayVolumeUSD,
            dayChangePct: m.dayChangePct,
            dex: ""
        )
    }

    func load() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.refresh()
        }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        async let perpPair: (Universe, [AssetContext])? = try? api.metaAndAssetCtxs()
        async let spotPair: (SpotUniverse, [AssetContext])? = try? api.spotMetaAndAssetCtxs()
        async let dexList: [PerpDex]? = try? api.perpDexs()

        let (perpResult, spotResult, dexesResult) = await (perpPair, spotPair, dexList)

        var assembledPerps: [Market] = []
        if let (universe, contexts) = perpResult {
            assembledPerps = zip(universe.universe, contexts).map { Market(meta: $0, context: $1) }
            self.errorMessage = nil
        } else {
            self.errorMessage = "Failed to load perp markets"
        }

        if let dexes = dexesResult {
            self.dexes = dexes
            // Fetch HIP-3 deployer universes in parallel and fold them in.
            let hip3 = dexes.filter { !$0.isCore }
            let hip3Markets: [[Market]] = await withTaskGroup(of: [Market].self) { group in
                for dex in hip3 {
                    group.addTask { [api] in
                        guard let (uni, ctxs) = try? await api.metaAndAssetCtxs(dex: dex.name) else { return [] }
                        return zip(uni.universe, ctxs).map { Market(meta: $0, context: $1, dex: dex.name) }
                    }
                }
                var out: [[Market]] = []
                for await markets in group { out.append(markets) }
                return out
            }
            assembledPerps.append(contentsOf: hip3Markets.flatMap { $0 })
        }

        self.perps = assembledPerps

        if let (sUniverse, sContexts) = spotResult {
            self.spot = Self.buildSpotMarkets(universe: sUniverse, contexts: sContexts)
        }

        subscribeMidStream()
    }

    private static func buildSpotMarkets(universe: SpotUniverse, contexts: [AssetContext]) -> [SpotMarket] {
        zip(universe.universe, contexts).compactMap { pair, ctx in
            guard pair.tokens.count >= 2,
                  let base = universe.token(atIndex: pair.tokens[0]),
                  let quote = universe.token(atIndex: pair.tokens[1]) else { return nil }
            return SpotMarket(pair: pair, base: base, quote: quote, context: ctx)
        }
    }

    private func subscribeMidStream() {
        socket.on(channel: "allMids") { [weak self] data in
            guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let mids = dict["mids"] as? [String: String] else { return }
            Task { @MainActor in self?.scheduleMids(mids) }
        }
        socket.subscribeAllMids()
        if socket.state == .disconnected { socket.connect() }
    }

    /// Throttle allMids applies to 400ms. At native tick rates (~5-10/sec)
    /// we'd otherwise rebuild the entire 300-row perps array on each push;
    /// with throttling the list stays live enough to look real-time but
    /// stops re-layouting every 100ms, which is what made the Markets scroll
    /// hitch on older devices.
    private var pendingMids: [String: String]?
    private var midThrottleTask: Task<Void, Never>?

    private func scheduleMids(_ mids: [String: String]) {
        pendingMids = mids
        if midThrottleTask == nil {
            midThrottleTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let self, let latest = self.pendingMids else { return }
                self.applyMids(latest)
                self.pendingMids = nil
                self.midThrottleTask = nil
            }
        }
    }

    private func applyMids(_ mids: [String: String]) {
        self.perps = self.perps.map { market in
            guard let newMid = mids[market.name] else { return market }
            return Market(meta: market.meta, context: Self.ctx(market.context, newMid: newMid))
        }
        self.spot = self.spot.map { m in
            guard let newMid = mids[m.symbol] ?? mids["@\(m.pair.index)"] else { return m }
            return SpotMarket(pair: m.pair, base: m.base, quote: m.quote, context: Self.ctx(m.context, newMid: newMid))
        }
    }

    private static func ctx(_ old: AssetContext, newMid: String) -> AssetContext {
        AssetContext(
            funding: old.funding,
            openInterest: old.openInterest,
            prevDayPx: old.prevDayPx,
            dayNtlVlm: old.dayNtlVlm,
            premium: old.premium,
            oraclePx: old.oraclePx,
            markPx: newMid,
            midPx: newMid,
            impactPxs: old.impactPxs
        )
    }
}
