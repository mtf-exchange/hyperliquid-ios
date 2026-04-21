import Foundation

@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var state: UserState?
    @Published private(set) var spot: SpotClearinghouseState?
    @Published private(set) var topMarkets: [Market] = []
    @Published private(set) var dayPnl: Double = 0
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var errorMessage: String?

    private let api: HyperliquidAPI
    private let socket: HyperliquidSocket
    private var subscribedAddress: String?

    /// The account model the headline balance should be computed under.
    /// Callers set this from `AppSession.accountMode` — the VM doesn't hold
    /// a session reference, so stay in sync by reassigning on change.
    @Published var accountMode: AccountMode = .standard

    init(api: HyperliquidAPI, socket: HyperliquidSocket) {
        self.api = api
        self.socket = socket
    }

    /// Spot total = USDC balance + every non-USDC token valued at its
    /// entry-notional. Mirrors what Hyperliquid's own UI shows.
    private var spotTotal: Double {
        spot?.balances.reduce(0) { acc, b in
            let entryValue = Double(b.entryNtl ?? "0") ?? 0
            return acc + (b.coin == "USDC" ? b.totalDouble : entryValue)
        } ?? 0
    }

    private var perpTotal: Double {
        state?.marginSummary.accountValueDouble ?? 0
    }

    /// Headline balance. Source of truth branches on account mode per
    /// Hyperliquid's docs: *"unified account and portfolio margin shows all
    /// balances and holds in the spot clearinghouse state. Individual perp
    /// dex user states are not meaningful."*
    ///
    /// - Standard: perp + spot (separate pools).
    /// - Unified / Portfolio margin: spot only + unrealized PnL floating
    ///   from the open positions (the collateral pool IS spot; perp-state
    ///   accountValue double-counts it).
    var totalEquity: Double {
        if accountMode.balancesLiveInSpotState {
            return spotTotal + unrealizedPnl
        }
        return perpTotal + spotTotal
    }

    var unrealizedPnl: Double {
        state?.assetPositions.reduce(0) { $0 + ($1.position.unrealizedPnlValue ?? 0) } ?? 0
    }

    func refresh(address: String?) async {
        guard let address, !address.isEmpty else {
            state = nil
            spot = nil
            topMarkets = []
            dayPnl = 0
            errorMessage = nil
            return
        }

        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        async let marketsTask: Void = loadTopMarkets()
        async let pnlTask:     Void = loadDayPnl(address: address)
        _ = await (marketsTask, pnlTask)

        subscribeAll(for: address)
    }

    private func loadTopMarkets() async {
        do {
            let (universe, contexts) = try await api.metaAndAssetCtxs()
            let all = zip(universe.universe, contexts).map { Market(meta: $0, context: $1) }
            self.topMarkets = all
                .sorted { ($0.dayVolumeUSD ?? 0) > ($1.dayVolumeUSD ?? 0) }
                .prefix(6)
                .map { $0 }
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    private func loadDayPnl(address: String) async {
        do {
            let fills = try await api.userFills(address: address)
            let cutoff = Int64((Date().timeIntervalSince1970 - 86_400) * 1000)
            dayPnl = fills
                .filter { $0.time >= cutoff }
                .reduce(0) { $0 + ($1.pnl ?? 0) - ($1.feeValue ?? 0) }
        } catch {
            // Non-critical — leave dayPnl as 0.
        }
    }

    // MARK: - Live WS subscriptions

    private func subscribeAll(for address: String) {
        // allDexsClearinghouseState replaces the per-dex clearinghouseState.
        // We pick the core ("") slot for the perp state — HIP-3 deployer
        // balances don't roll into "total equity" on Home (they're surfaced
        // in the User tab alongside each dex).
        socket.on(channel: "allDexsClearinghouseState") { [weak self] data in
            guard let payload = try? JSONDecoder().decode(WsAllDexsClearinghouseStateWire.self, from: data) else {
                if let s = String(data: data, encoding: .utf8) {
                    print("[ws] failed to decode allDexsClearinghouseState: \(s.prefix(400))")
                }
                return
            }
            Task { @MainActor [weak self] in
                self?.state = payload.clearinghouseStates[""]
            }
        }
        socket.on(channel: "spotState") { [weak self] data in
            guard let payload = try? JSONDecoder().decode(WsSpotState.self, from: data) else { return }
            Task { @MainActor [weak self] in
                self?.spot = payload.spotState
            }
        }

        if subscribedAddress != address {
            socket.subscribeAllDexsClearinghouseState(user: address)
            socket.subscribeSpotState(user: address)
            subscribedAddress = address
        }
        if socket.state == .disconnected { socket.connect() }
    }

    private struct WsSpotState: Decodable {
        let user: String
        let spotState: SpotClearinghouseState
    }
}
