import Foundation
import Combine

@MainActor
final class AppSession: ObservableObject {
    @Published var walletAddress: String? {
        didSet { UserDefaults.standard.set(walletAddress, forKey: Self.walletKey) }
    }

    @Published var environment: HyperliquidEnvironment {
        didSet {
            UserDefaults.standard.set(environment.rawValue, forKey: Self.envKey)
            api.update(environment: environment)
            socket.update(environment: environment)
        }
    }

    /// Hyperliquid offers two account models: classic (separate spot + perp
    /// balances per address) and unified (a single cross-margined pool). We
    /// persist the user's choice here and every balance/order screen reads
    /// this so it can show the right split / aggregate. Detection from the
    /// wire is TODO — today this is a user preference, not a server fact.
    @Published var accountMode: AccountMode {
        didSet { UserDefaults.standard.set(accountMode.rawValue, forKey: Self.accountModeKey) }
    }

    /// Non-sensitive agent metadata (address + createdAt) used for UI state and
    /// "is trading enabled?" checks. The sensitive private key lives in the
    /// Keychain behind a `.userPresence` access-control object and is only
    /// fetched on-demand via `loadAgentKey(reason:)`.
    @Published private(set) var agent: AgentInfo?

    /// Currently-selected tab in RootView. Published so deep-link-style jumps
    /// (e.g. tapping a market in Home/Markets) can programmatically bring
    /// the Trade tab forward.
    @Published var selectedTab: MainTab = .home

    /// Symbol the Trade tab is showing. Set this + flip `selectedTab` to
    /// `.trade` to route a market tap from any screen into the trade form.
    @Published var tradeCoin: String = "BTC"
    @Published var tradeIsSpot: Bool = false

    /// How size is entered in the Trade form — USDC notional (default, most
    /// traders think in dollars) or base-coin units. Stored per device.
    @Published var sizeUnit: SizeUnit {
        didSet { UserDefaults.standard.set(sizeUnit.rawValue, forKey: Self.sizeUnitKey) }
    }

    let api: HyperliquidAPI
    let exchange: HyperliquidExchangeAPI
    let socket: HyperliquidSocket
    let walletConnect: WalletConnectService

    private var bag = Set<AnyCancellable>()
    private static let walletKey = "wallet.address"
    private static let envKey = "hyperliquid.env"
    private static let accountModeKey = "account.mode"
    private static let sizeUnitKey = "trade.sizeUnit"

    init() {
        let storedEnv = UserDefaults.standard.string(forKey: Self.envKey)
            .flatMap(HyperliquidEnvironment.init(rawValue:)) ?? .mainnet
        self.environment = storedEnv
        self.walletAddress = UserDefaults.standard.string(forKey: Self.walletKey)
        self.accountMode = UserDefaults.standard.string(forKey: Self.accountModeKey)
            .flatMap(AccountMode.init(rawValue:)) ?? .default
        self.sizeUnit = UserDefaults.standard.string(forKey: Self.sizeUnitKey)
            .flatMap(SizeUnit.init(rawValue:)) ?? .usdc

        let api = HyperliquidAPI(environment: storedEnv)
        self.api = api
        self.exchange = HyperliquidExchangeAPI(api: api)
        self.socket = HyperliquidSocket(environment: storedEnv)
        self.walletConnect = .shared

        self.agent = AgentKeychain.info()

        walletConnect.$connectedAddress
            .dropFirst()   // ignore the initial nil emitted by @Published
            .receive(on: DispatchQueue.main)
            .sink { [weak self] addr in
                guard let self else { return }
                if let addr {
                    self.walletAddress = addr
                    Task { await self.refreshAccountMode() }
                } else {
                    // The main wallet went away (disconnect button, session
                    // expiry, wallet-side kick). The cached agent was approved
                    // on behalf of that wallet, so it's no longer signable
                    // anything meaningful — clear both.
                    self.walletAddress = nil
                    self.forgetAgent()
                }
            }
            .store(in: &bag)

        // Kick off mode detection for a pre-existing stored address so the
        // first render already has the right AccountMode.
        if walletAddress != nil {
            Task { await self.refreshAccountMode() }
        }
    }

    func makeEnabler() -> TradingEnabler {
        TradingEnabler(wallet: walletConnect, exchange: exchange, environment: environment)
    }

    func forgetAgent() {
        AgentKeychain.delete()
        agent = nil
    }

    func setAgent(_ info: AgentInfo) { agent = info }

    /// Biometric-gated fetch of the sensitive AgentKey. Runs the blocking
    /// Keychain call off the main actor so the UI doesn't hitch while iOS
    /// presents the FaceID / passcode sheet.
    func loadAgentKey(reason: String) async throws -> AgentKey {
        try await Task.detached(priority: .userInitiated) {
            try AgentKeychain.loadKey(reason: reason)
        }.value
    }

    // MARK: - Account-mode auto-detection
    //
    // Hyperliquid exposes the user's current abstraction mode on the REST
    // `userAbstraction` info endpoint. No push channel, so we fetch once
    // per address and cache the answer keyed by address+env — address
    // rarely changes; the answer almost never does.

    private static let abstractionCacheKey = "account.mode.cache.v1"
    private static let abstractionCacheTTL: TimeInterval = 6 * 3600   // 6h

    /// Fetch the account-abstraction mode for the current wallet and
    /// update `accountMode` accordingly.
    ///
    /// Stale-while-revalidate: if a cached value exists, apply it
    /// immediately (UI gets a decision this tick) and always kick off a
    /// background fetch to refresh the cache. On a cache miss we still do
    /// the fetch but with no prior value, so the first render may briefly
    /// show the previous session's mode.
    func refreshAccountMode() async {
        guard let address = walletAddress, !address.isEmpty else { return }
        let cacheKey = "\(environment.rawValue):\(address.lowercased())"

        var cacheFresh = false
        if let cached = Self.readAbstractionCache()[cacheKey],
           let mode = AccountMode(rawValue: cached.mode) {
            self.accountMode = mode
            cacheFresh = Date().timeIntervalSince1970 - cached.cachedAt < Self.abstractionCacheTTL
        }

        // Always refresh the cache in the background — cheap REST call,
        // and it catches the case where the user changed modes on the web
        // between app launches. Only the cache-miss path awaits; the
        // cache-fresh path returns so the caller isn't blocked.
        if cacheFresh {
            Task.detached { [weak self] in
                await self?.fetchAndStoreMode(address: address, cacheKey: cacheKey)
            }
            return
        }

        await fetchAndStoreMode(address: address, cacheKey: cacheKey)
    }

    private func fetchAndStoreMode(address: String, cacheKey: String) async {
        do {
            let raw = try await api.userAbstraction(address: address)
            let mode = AccountMode.from(wire: raw)
            // Only reassign if the mode actually changed; avoids bouncing
            // the UI when the cache was already correct.
            if self.accountMode != mode {
                self.accountMode = mode
            }
            var cache = Self.readAbstractionCache()
            cache[cacheKey] = AbstractionCacheEntry(
                mode: mode.rawValue,
                cachedAt: Date().timeIntervalSince1970
            )
            Self.writeAbstractionCache(cache)
        } catch {
            // Swallow — we already have a cached or user-picked value.
        }
    }

    private struct AbstractionCacheEntry: Codable {
        let mode: String
        let cachedAt: TimeInterval
    }

    private static func readAbstractionCache() -> [String: AbstractionCacheEntry] {
        guard let data = UserDefaults.standard.data(forKey: abstractionCacheKey),
              let dict = try? JSONDecoder().decode([String: AbstractionCacheEntry].self, from: data) else {
            return [:]
        }
        return dict
    }

    private static func writeAbstractionCache(_ dict: [String: AbstractionCacheEntry]) {
        guard let data = try? JSONEncoder().encode(dict) else { return }
        UserDefaults.standard.set(data, forKey: abstractionCacheKey)
    }
}

/// Which top-level tab is active. Used for both the tab bar itself and for
/// programmatic routing (e.g. Home's market-movers list jumping to Trade).
enum MainTab: Int, Hashable, CaseIterable {
    case home = 0
    case markets = 1
    case trade = 2
    case assets = 3
}

/// Helper for jumping into the Trade tab at a specific symbol. Call this
/// from any view to route the user forward.
extension AppSession {
    func openTrade(coin: String, isSpot: Bool = false) {
        self.tradeCoin = coin
        self.tradeIsSpot = isSpot
        self.selectedTab = .trade
    }
}

/// Unit the Trade form uses when the user types a size — USDC notional (the
/// natural mental model for most derivative traders: "buy $100 of BTC") or
/// base-coin units ("buy 0.001 BTC"). Persisted across launches.
enum SizeUnit: String, CaseIterable, Identifiable {
    case usdc
    case base

    var id: String { rawValue }
    func label(coin: String) -> String {
        switch self {
        case .usdc: return "USDC"
        case .base: return coin
        }
    }
}

/// Hyperliquid's account-abstraction modes. Per the official docs:
///   • **Standard** — classic mode, separate spot and perp balances; the
///     one recommended for market makers / high-volume traders, and the
///     one builder-code addresses must use to collect fees.
///   • **Unified account** — the app.hyperliquid.xyz default; single
///     cross-margin pool. The doc is explicit: *"unified account and
///     portfolio margin shows all balances and holds in the spot
///     clearinghouse state. Individual perp dex user states are not
///     meaningful."*
///   • **Portfolio margin** — unified + automatic borrow against
///     eligible collateral, pre-alpha, $5M-volume gated.
///
/// The API doesn't expose a field that tells us which mode an address is
/// in, so we keep this as a user-picked preference on the device.
/// Balance / HIP-3 code branches on:
///   `.standard` → sum perp + spot; per-dex HIP-3 states are meaningful.
///   `.unified` / `.portfolioMargin` → use spot state only;
///   per-dex state is ignored (docs say it's "not meaningful").
enum AccountMode: String, CaseIterable, Identifiable {
    case standard
    case unified
    case portfolioMargin

    /// Backwards-compat alias — earlier builds wrote `.default` into
    /// UserDefaults.
    static var `default`: AccountMode { .standard }

    /// Parse the raw string the `userAbstraction` info endpoint returns.
    /// Hyperliquid uses `"default"` / `"unified"` / `"portfolioMargin"`;
    /// be generous on casing and alternative spellings.
    static func from(wire raw: String) -> AccountMode {
        switch raw.lowercased() {
        case "default", "standard":
            return .standard
        case "unified", "unifiedaccount", "unified_account":
            return .unified
        case "portfoliomargin", "portfolio_margin", "portfolio":
            return .portfolioMargin
        default:
            return .standard
        }
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard:        return "Standard"
        case .unified:         return "Unified"
        case .portfolioMargin: return "Portfolio margin"
        }
    }

    var subtitle: String {
        switch self {
        case .standard:
            return "Separate spot and perp balances. Per-dex (HIP-3) states are meaningful."
        case .unified:
            return "Single cross-margin pool. All balances surface in spot state; individual perp-dex states are not meaningful (per Hyperliquid docs)."
        case .portfolioMargin:
            return "Unified pool plus automatic borrow against eligible collateral. Pre-alpha, $5M-volume gated. Uses the same spot-state balance surface as unified."
        }
    }

    /// True when the mode routes balances through spotState rather than
    /// perp clearinghouseState. Everything we compute for Home / User
    /// balance branches on this.
    var balancesLiveInSpotState: Bool {
        switch self {
        case .standard: return false
        case .unified, .portfolioMargin: return true
        }
    }

    /// True when per-dex (HIP-3) clearinghouseState entries should be
    /// surfaced as real balances. The docs explicitly say these aren't
    /// meaningful under unified/portfolio modes.
    var perDexBalancesMeaningful: Bool { !balancesLiveInSpotState }
}
