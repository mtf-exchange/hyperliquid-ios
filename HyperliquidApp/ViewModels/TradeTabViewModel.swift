import Foundation

/// Aggregates every "my activity" feed the Trade tab displays below the
/// orderbook: positions, open orders, TWAP schedules, trade fills, funding
/// payments, and order history. WS subscriptions keep the live-change rows
/// fresh; REST calls fill in snapshots that don't have a stream (TWAP state
/// history, ledger).
@MainActor
final class TradeTabViewModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case positions = "Positions"
        case openOrders = "Open Orders"
        case twap = "TWAP"
        case tradeHistory = "Trade History"
        case fundingHistory = "Funding"
        case orderHistory = "Order History"
        var id: String { rawValue }
    }

    @Published private(set) var positions: [DexedPosition] = []
    @Published private(set) var openOrders: [DexedOrder] = []
    @Published private(set) var fills: [UserFill] = []
    @Published private(set) var funding: [UserFunding] = []
    @Published private(set) var twaps: [TwapState] = []
    /// Core clearinghouse snapshot (withdrawable, margin summary). The Trade
    /// form reads this to compute the size slider's max notional.
    @Published private(set) var state: UserState?
    /// Per-dex clearinghouse snapshots from `allDexsClearinghouseState`.
    /// Keyed by dex name ("" for core / Hyperliquid canonical, otherwise the
    /// HIP-3 deployer name). Views iterate this to show HIP-3 positions.
    @Published private(set) var dexStates: [String: UserState] = [:]
    @Published private(set) var errorMessage: String?

    /// A position tagged with the dex it came from, so the Trade tab can
    /// show HIP-3 (xyz) positions alongside core Hyperliquid positions
    /// without losing the dex context on the row.
    struct DexedPosition: Identifiable, Hashable {
        let dex: String
        let position: Position
        var id: String { dex.isEmpty ? position.coin : "\(dex):\(position.coin)" }
        var isCore: Bool { dex.isEmpty }
    }

    /// An open order tagged with its originating dex — `allDexsOpenOrders`
    /// doesn't exist, so for HIP-3 deployers we subscribe per-dex and merge.
    struct DexedOrder: Identifiable, Hashable {
        let dex: String
        let order: OpenOrder
        var id: String { dex.isEmpty ? "core:\(order.oid)" : "\(dex):\(order.oid)" }
        var isCore: Bool { dex.isEmpty }
    }

    /// Addresses + dexes we've already subscribed to, so we don't
    /// resubscribe on every refresh.
    private var subscribedDexOrders: Set<String> = []

    private let api: HyperliquidAPI
    private let socket: HyperliquidSocket
    private var subscribedAddress: String?

    init(api: HyperliquidAPI, socket: HyperliquidSocket) {
        self.api = api
        self.socket = socket
    }

    func refresh(address: String?) async {
        guard let address, !address.isEmpty else {
            positions = []
            openOrders = []
            fills = []
            funding = []
            twaps = []
            dexStates = [:]
            errorMessage = nil
            return
        }
        // Non-WS data: TWAP snapshot and the HIP-3 deployer list (so we know
        // which dexes to subscribe orders for).
        async let twapList = try? api.twapStates(address: address)
        async let dexList  = try? api.perpDexs()
        self.twaps = (await twapList) ?? []
        let dexes = (await dexList) ?? []
        subscribeAll(for: address, dexes: dexes.filter { !$0.isCore }.map(\.name))
    }

    /// Map of (user, dex) → open orders on that dex. Keyed per dex because
    /// the `openOrders` channel echoes orders for ONE dex per push, and we
    /// want to keep core + every HIP-3 dex visible simultaneously.
    private var ordersPerDex: [String: [OpenOrder]] = [:]

    private func subscribeAll(for address: String, dexes: [String]) {
        // allDexsClearinghouseState delivers both core and HIP-3 states in
        // one push. Take core ("") into `state` + flatten all dexes into
        // `positions` tagged with their dex.
        socket.on(channel: "allDexsClearinghouseState") { [weak self] data in
            guard let payload = try? JSONDecoder().decode(WsAllDexsClearinghouseStateWire.self, from: data) else {
                if let s = String(data: data, encoding: .utf8) {
                    print("[ws] failed to decode allDexsClearinghouseState: \(s.prefix(400))")
                }
                return
            }
            // One line every push summarising what we parsed, so when the
            // UI is empty we can tell whether the wire had no data or the
            // pipeline dropped it.
            let summary = payload.clearinghouseStates.map { (dex, st) in
                "[\(dex.isEmpty ? "core" : dex): \(st.assetPositions.count)pos $\(Formatters.usd(st.marginSummary.accountValueDouble))]"
            }.joined(separator: " ")
            print("[ws] allDexsClearinghouseState dexes=\(payload.clearinghouseStates.count) \(summary)")

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.dexStates = payload.clearinghouseStates
                self.state = payload.clearinghouseStates[""]
                let sortedDexes = payload.clearinghouseStates.keys.sorted { a, b in
                    if a.isEmpty { return true }
                    if b.isEmpty { return false }
                    return a < b
                }
                var rows: [DexedPosition] = []
                for dex in sortedDexes {
                    guard let st = payload.clearinghouseStates[dex] else { continue }
                    rows.append(contentsOf: st.assetPositions.map {
                        DexedPosition(dex: dex, position: $0.position)
                    })
                }
                self.positions = rows
            }
        }

        // openOrders is per-dex. The payload carries a `dex` field — we
        // bucket orders by that key and flatten for display.
        socket.on(channel: "openOrders") { [weak self] data in
            guard let payload = try? JSONDecoder().decode(WsOpenOrders.self, from: data) else {
                if let s = String(data: data, encoding: .utf8) {
                    print("[ws] failed to decode openOrders: \(s.prefix(400))")
                }
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let dexKey = payload.dex ?? ""
                self.ordersPerDex[dexKey] = payload.orders
                // Flatten: core first, then HIP-3 alphabetical.
                let keys = self.ordersPerDex.keys.sorted { a, b in
                    if a.isEmpty { return true }
                    if b.isEmpty { return false }
                    return a < b
                }
                self.openOrders = keys.flatMap { k in
                    (self.ordersPerDex[k] ?? []).map { DexedOrder(dex: k, order: $0) }
                }
            }
        }

        socket.on(channel: "userFills") { [weak self] data in
            guard let payload = try? JSONDecoder().decode(WsUserFills.self, from: data) else { return }
            Task { @MainActor [weak self] in
                self?.merge(fills: payload.fills, replace: payload.isSnapshot ?? false)
            }
        }
        socket.on(channel: "userFundings") { [weak self] data in
            guard let payload = try? JSONDecoder().decode(WsUserFundings.self, from: data) else { return }
            Task { @MainActor [weak self] in
                self?.merge(funding: payload.fundings, replace: payload.isSnapshot ?? false)
            }
        }

        if subscribedAddress != address {
            socket.subscribeAllDexsClearinghouseState(user: address)
            socket.subscribeOpenOrders(user: address)     // core venue
            socket.subscribeUserFills(user: address)
            socket.subscribeUserFundings(user: address)
            subscribedAddress = address
            subscribedDexOrders = [""]
        }

        // Subscribe openOrders per HIP-3 dex we haven't attached yet.
        for dex in dexes {
            guard !subscribedDexOrders.contains(dex) else { continue }
            socket.subscribeOpenOrders(user: address, dex: dex)
            subscribedDexOrders.insert(dex)
        }

        if socket.state == .disconnected { socket.connect() }
    }

    private func merge(fills new: [UserFill], replace: Bool) {
        if replace { fills = new.sorted { $0.time > $1.time } }
        else {
            var seen = Set<Int64>()
            fills = (new + fills)
                .filter { seen.insert($0.tid).inserted }
                .sorted { $0.time > $1.time }
        }
    }

    private func merge(funding new: [UserFunding], replace: Bool) {
        if replace { funding = new.sorted { $0.time > $1.time } }
        else {
            var seen = Set<String>()
            funding = (new + funding)
                .filter { seen.insert($0.id).inserted }
                .sorted { $0.time > $1.time }
        }
    }

    private struct WsOpenOrders: Decodable {
        let user: String
        let dex: String?
        let orders: [OpenOrder]
    }
    private struct WsUserFills: Decodable {
        let user: String?
        let isSnapshot: Bool?
        let fills: [UserFill]
    }
    private struct WsUserFundings: Decodable {
        let user: String?
        let isSnapshot: Bool?
        let fundings: [UserFunding]
    }
}
