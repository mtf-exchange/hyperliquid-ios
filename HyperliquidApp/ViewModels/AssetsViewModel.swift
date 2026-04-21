import Foundation

/// Drives the Assets tab. Holds whatever the dex-split view needs:
///   - `perpState` — clearinghouseState (positions, margin summary)
///   - `spotState` — spot balances
///   - `twaps`     — so the Assets screen can surface an at-a-glance indicator
///                   when an address has in-flight TWAPs
///
/// Everything live comes over the WS; a one-shot REST kick gets TWAPs which
/// have no subscription channel.
@MainActor
final class AssetsViewModel: ObservableObject {
    @Published private(set) var perpState: UserState?
    @Published private(set) var spotState: SpotClearinghouseState?
    @Published private(set) var twaps: [TwapState] = []
    @Published private(set) var dexes: [PerpDex] = []
    /// Per-dex clearinghouseState fetched when the user opens the Assets tab.
    /// Keyed by dex name ("" = core, anything else = HIP-3 deployer).
    @Published private(set) var dexStates: [String: UserState] = [:]
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading: Bool = false

    private let api: HyperliquidAPI
    private let socket: HyperliquidSocket
    private var subscribedAddress: String?

    init(api: HyperliquidAPI, socket: HyperliquidSocket) {
        self.api = api
        self.socket = socket
    }

    var perpAccountValue: Double { perpState?.marginSummary.accountValueDouble ?? 0 }
    var perpMarginUsed: Double { perpState?.marginSummary.totalMarginUsedDouble ?? 0 }
    var perpWithdrawable: Double { perpState?.withdrawableDouble ?? 0 }

    var usdcSpotBalance: Double {
        spotState?.balances.first(where: { $0.coin == "USDC" })?.totalDouble ?? 0
    }
    var spotBalances: [SpotBalance] { spotState?.balances ?? [] }

    var perpPositions: [Position] {
        perpState?.assetPositions.map(\.position) ?? []
    }

    func refresh(address: String?) async {
        guard let address, !address.isEmpty else {
            perpState = nil
            spotState = nil
            twaps = []
            errorMessage = "Connect a wallet to view balances."
            return
        }
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        // Only REST-fetch the bits that don't have a live channel: TWAP
        // history and the static dex list (for pretty names / deployer addrs).
        // Perp + spot state arrive via allDexsClearinghouseState + spotState
        // subscriptions inside subscribeAll.
        async let twapTask = try? api.twapStates(address: address)
        async let dexesTask = try? api.perpDexs()

        self.twaps = (await twapTask) ?? []
        self.dexes = (await dexesTask) ?? []

        subscribeAll(for: address)
    }

    private func subscribeAll(for address: String) {
        // allDexsClearinghouseState supersedes the per-dex clearinghouseState
        // channel — one push delivers core and every HIP-3 venue's state.
        socket.on(channel: "allDexsClearinghouseState") { [weak self] data in
            guard let payload = try? JSONDecoder().decode(WsAllDexsClearinghouseStateWire.self, from: data) else {
                if let s = String(data: data, encoding: .utf8) {
                    print("[ws] failed to decode allDexsClearinghouseState: \(s.prefix(400))")
                }
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.perpState = payload.clearinghouseStates[""]    // core venue
                self.dexStates = payload.clearinghouseStates.filter { !$0.key.isEmpty }
            }
        }
        socket.on(channel: "spotState") { [weak self] data in
            guard let payload = try? JSONDecoder().decode(WsSpotState.self, from: data) else { return }
            Task { @MainActor [weak self] in self?.spotState = payload.spotState }
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
