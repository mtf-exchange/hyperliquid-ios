import Foundation

@MainActor
final class PortfolioViewModel: ObservableObject {
    @Published private(set) var state: UserState?
    @Published private(set) var openOrders: [OpenOrder] = []
    @Published private(set) var universe: Universe?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var errorMessage: String?

    private let api: HyperliquidAPI
    private let exchange: HyperliquidExchangeAPI
    private let socket: HyperliquidSocket

    private var subscribedAddress: String?

    init(api: HyperliquidAPI, exchange: HyperliquidExchangeAPI, socket: HyperliquidSocket) {
        self.api = api
        self.exchange = exchange
        self.socket = socket
    }

    func refresh(address: String?) async {
        guard let address, !address.isEmpty else {
            state = nil
            openOrders = []
            errorMessage = "Add a wallet address in Settings to view your portfolio."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            // Universe has no WS equivalent; everything else (positions, orders)
            // arrives via subscriptions below — first push is a snapshot.
            self.universe = try await api.meta()
            self.errorMessage = nil
            subscribeAll(for: address)
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    func surface(error: Error) {
        self.errorMessage = error.localizedDescription
    }

    func cancel(order: OpenOrder, universe: Universe?, agent: AgentKey, isMainnet: Bool) async {
        guard let universe else {
            self.errorMessage = "Universe not loaded; cannot cancel order."
            return
        }
        do {
            _ = try await exchange.cancel(
                coin: order.coin,
                oid: order.oid,
                universe: universe,
                agent: agent,
                isMainnet: isMainnet
            )
            // Optimistic removal; WS will confirm.
            openOrders.removeAll { $0.oid == order.oid }
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    // MARK: - Live open-order updates

    /// Wire-level shape of an `orderUpdates` payload element.
    private struct WsOrderUpdate: Decodable {
        struct Inner: Decodable {
            let coin: String
            let side: String
            let limitPx: String
            let sz: String
            let oid: Int64
            let timestamp: Int64
            let origSz: String?
        }
        let order: Inner
        let status: String
        let statusTimestamp: Int64?
    }

    private func subscribeAll(for address: String) {
        // orderUpdates: per-order open/filled/canceled deltas
        socket.on(channel: "orderUpdates") { [weak self] data in
            guard let updates = try? JSONDecoder().decode([WsOrderUpdate].self, from: data) else { return }
            Task { @MainActor [weak self] in self?.apply(updates: updates) }
        }
        // openOrders: full snapshot of resting orders on subscribe + on changes
        socket.on(channel: "openOrders") { [weak self] data in
            guard let payload = try? JSONDecoder().decode(WsOpenOrders.self, from: data) else { return }
            Task { @MainActor [weak self] in self?.openOrders = payload.orders }
        }
        // allDexsClearinghouseState: unified per-dex state, keyed by dex name.
        // We take the core ("") slot for the legacy Portfolio screen; HIP-3
        // dex balances are surfaced separately in Assets.
        socket.on(channel: "allDexsClearinghouseState") { [weak self] data in
            guard let payload = try? JSONDecoder().decode(WsAllDexsClearinghouseStateWire.self, from: data) else { return }
            Task { @MainActor [weak self] in
                self?.state = payload.clearinghouseStates[""]
            }
        }

        if subscribedAddress != address {
            socket.subscribeOrderUpdates(user: address)
            socket.subscribeOpenOrders(user: address)
            socket.subscribeAllDexsClearinghouseState(user: address)
            subscribedAddress = address
        }
        if socket.state == .disconnected { socket.connect() }
    }

    private struct WsOpenOrders: Decodable {
        let dex: String?
        let user: String
        let orders: [OpenOrder]
    }


    private func apply(updates: [WsOrderUpdate]) {
        for u in updates {
            let inner = u.order
            switch u.status {
            case "open":
                let mapped = OpenOrder(
                    coin: inner.coin,
                    side: inner.side,
                    limitPx: inner.limitPx,
                    sz: inner.sz,
                    oid: inner.oid,
                    timestamp: inner.timestamp,
                    origSz: inner.origSz
                )
                if let idx = openOrders.firstIndex(where: { $0.oid == mapped.oid }) {
                    openOrders[idx] = mapped
                } else {
                    openOrders.append(mapped)
                }
            case "filled", "canceled", "rejected", "marginCanceled":
                openOrders.removeAll { $0.oid == inner.oid }
            default:
                break
            }
        }
    }
}
