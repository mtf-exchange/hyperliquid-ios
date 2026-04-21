import Foundation

enum HyperliquidAPIError: Error, LocalizedError {
    case invalidResponse
    case http(Int, String?)
    case exchange(String)
    case decode(Error)
    case encode(Error)
    case missingWallet

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response"
        case .http(let code, let body): return "HTTP \(code): \(body ?? "")"
        case .exchange(let msg): return msg
        case .decode(let err): return "Decode failed: \(err.localizedDescription)"
        case .encode(let err): return "Encode failed: \(err.localizedDescription)"
        case .missingWallet: return "Wallet address not set"
        }
    }
}

final class HyperliquidAPI {
    private let session: URLSession
    private(set) var environment: HyperliquidEnvironment

    init(environment: HyperliquidEnvironment, session: URLSession = .shared) {
        self.environment = environment
        self.session = session
    }

    func update(environment: HyperliquidEnvironment) {
        self.environment = environment
    }

    // MARK: - Public endpoints

    func meta() async throws -> Universe {
        try await info(["type": "meta"])
    }

    /// Returns [Universe, [AssetContext]] — Hyperliquid's `metaAndAssetCtxs`.
    func metaAndAssetCtxs() async throws -> (Universe, [AssetContext]) {
        let data = try await infoRaw(["type": "metaAndAssetCtxs"])
        guard let array = try JSONSerialization.jsonObject(with: data) as? [Any],
              array.count >= 2,
              let universeJSON = try? JSONSerialization.data(withJSONObject: array[0]),
              let ctxJSON = try? JSONSerialization.data(withJSONObject: array[1]) else {
            throw HyperliquidAPIError.invalidResponse
        }
        let universe = try JSONDecoder().decode(Universe.self, from: universeJSON)
        let contexts = try JSONDecoder().decode([AssetContext].self, from: ctxJSON)
        return (universe, contexts)
    }

    func allMids() async throws -> [String: String] {
        try await info(["type": "allMids"])
    }

    func l2Book(coin: String) async throws -> L2Book {
        try await info(["type": "l2Book", "coin": coin])
    }

    func recentTrades(coin: String) async throws -> [Trade] {
        try await info(["type": "recentTrades", "coin": coin])
    }

    func candles(coin: String, interval: CandleInterval, startMs: Int64, endMs: Int64) async throws -> [Candle] {
        let payload: [String: Any] = [
            "type": "candleSnapshot",
            "req": [
                "coin": coin,
                "interval": interval.rawValue,
                "startTime": startMs,
                "endTime": endMs
            ]
        ]
        return try await info(payload)
    }

    // MARK: - Spot metadata

    func spotMeta() async throws -> SpotUniverse {
        try await info(["type": "spotMeta"])
    }

    /// Returns [SpotUniverse, [AssetContext]] — Hyperliquid's `spotMetaAndAssetCtxs`.
    func spotMetaAndAssetCtxs() async throws -> (SpotUniverse, [AssetContext]) {
        let data = try await infoRaw(["type": "spotMetaAndAssetCtxs"])
        guard let array = try JSONSerialization.jsonObject(with: data) as? [Any],
              array.count >= 2,
              let uniJSON = try? JSONSerialization.data(withJSONObject: array[0]),
              let ctxJSON = try? JSONSerialization.data(withJSONObject: array[1]) else {
            throw HyperliquidAPIError.invalidResponse
        }
        let universe = try JSONDecoder().decode(SpotUniverse.self, from: uniJSON)
        let contexts = try JSONDecoder().decode([AssetContext].self, from: ctxJSON)
        return (universe, contexts)
    }

    // MARK: - User endpoints

    // `userState` / per-dex `userState` REST helpers are removed — Hyperliquid
    // pushes a snapshot on the `allDexsClearinghouseState` WS channel at
    // connect time and tick-drives updates after that, so a REST round-trip
    // would only ever return staler data than what's already in memory.

    func openOrders(address: String) async throws -> [OpenOrder] {
        try await info(["type": "openOrders", "user": address])
    }

    func userFills(address: String) async throws -> [UserFill] {
        try await info(["type": "userFills", "user": address])
    }

    func userFunding(address: String, startMs: Int64, endMs: Int64) async throws -> [UserFunding] {
        try await info([
            "type": "userFunding",
            "user": address,
            "startTime": startMs,
            "endTime": endMs
        ])
    }

    // Spot balances now come exclusively via the `spotState` WS channel —
    // the one-shot REST equivalent has been dropped so there's a single
    // source of truth for spot holdings.

    /// `/info {"type":"userAbstraction"}` returns a bare JSON string like
    /// `"default"` / `"unified"` / `"portfolioMargin"`. Wraps the raw body
    /// so `AppSession` can map it to the `AccountMode` enum and cache.
    func userAbstraction(address: String) async throws -> String {
        let data = try await infoRaw(["type": "userAbstraction", "user": address])
        // Top-level fragment (bare string) — JSONSerialization needs
        // .fragmentsAllowed to accept it.
        if let raw = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String {
            return raw
        }
        // Fallback: some relay hosts wrap it in an object — look for a
        // common "type" or "mode" key.
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let s = obj["type"] as? String { return s }
            if let s = obj["mode"] as? String { return s }
        }
        throw HyperliquidAPIError.invalidResponse
    }

func twapStates(address: String) async throws -> [TwapState] {
        // Returns `[[twapId, state]]` — flatten to the state objects.
        let data = try await infoRaw(["type": "twapHistory", "user": address])
        guard let outer = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        var states: [TwapState] = []
        for row in outer {
            guard let pair = row as? [Any], pair.count >= 2,
                  let stateJSON = try? JSONSerialization.data(withJSONObject: pair[1]),
                  let s = try? JSONDecoder().decode(TwapState.self, from: stateJSON) else { continue }
            states.append(s)
        }
        return states
    }

    func nonFundingLedger(address: String, startMs: Int64, endMs: Int64) async throws -> [NonFundingLedgerEvent] {
        try await info([
            "type": "userNonFundingLedgerUpdates",
            "user": address,
            "startTime": startMs,
            "endTime": endMs
        ])
    }

    // MARK: - HIP-3 / custom DEXs

    /// Hyperliquid's `perpDexs` payload is `[nil, {...}, {...}, …]`. The first
    /// null represents the canonical non-named venue; subsequent objects
    /// describe HIP-3 deployers. We strip nulls and decode the rest, then
    /// prepend a synthetic "core" entry so the UI can treat the list
    /// uniformly.
    func perpDexs() async throws -> [PerpDex] {
        let data = try await infoRaw(["type": "perpDexs"])
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [Any?] else { return [] }
        var out: [PerpDex] = [PerpDex(name: "", full_name: "Hyperliquid Core", deployer: nil, oracle_updater: nil)]
        for entry in arr {
            guard let dict = entry as? [String: Any],
                  let json = try? JSONSerialization.data(withJSONObject: dict),
                  let dex = try? JSONDecoder().decode(PerpDex.self, from: json) else { continue }
            if dex.isCore { continue }  // avoid doubling the core entry
            out.append(dex)
        }
        return out
    }

    /// Dex-scoped perp meta (HIP-3 deployers can ship their own universe).
    /// Returns (Universe, contexts) for the named dex — pass `""` for core.
    func metaAndAssetCtxs(dex: String) async throws -> (Universe, [AssetContext]) {
        let data = try await infoRaw(["type": "metaAndAssetCtxs", "dex": dex])
        guard let array = try JSONSerialization.jsonObject(with: data) as? [Any],
              array.count >= 2,
              let universeJSON = try? JSONSerialization.data(withJSONObject: array[0]),
              let ctxJSON = try? JSONSerialization.data(withJSONObject: array[1]) else {
            throw HyperliquidAPIError.invalidResponse
        }
        let universe = try JSONDecoder().decode(Universe.self, from: universeJSON)
        let contexts = try JSONDecoder().decode([AssetContext].self, from: ctxJSON)
        return (universe, contexts)
    }

    // MARK: - Core request

    private func info<T: Decodable>(_ payload: [String: Any]) async throws -> T {
        let data = try await infoRaw(payload)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw HyperliquidAPIError.decode(error)
        }
    }

    private func infoRaw(_ payload: [String: Any]) async throws -> Data {
        var request = URLRequest(url: environment.restURL.appendingPathComponent("info"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            throw HyperliquidAPIError.encode(error)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HyperliquidAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw HyperliquidAPIError.http(http.statusCode, String(data: data, encoding: .utf8))
        }
        return data
    }
}
