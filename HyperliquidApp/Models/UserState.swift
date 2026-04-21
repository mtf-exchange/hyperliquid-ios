import Foundation

struct AssetPosition: Codable, Hashable {
    let type: String
    let position: Position
}

struct Position: Codable, Hashable, Identifiable {
    let coin: String
    let szi: String
    let entryPx: String?
    let positionValue: String?
    let unrealizedPnl: String?
    let returnOnEquity: String?
    let leverage: Leverage?
    let liquidationPx: String?
    let marginUsed: String?
    let maxLeverage: Int?

    var id: String { coin }
    var size: Double { Double(szi) ?? 0 }
    var isLong: Bool { size > 0 }
    var entryPrice: Double? { entryPx.flatMap(Double.init) }
    var value: Double? { positionValue.flatMap(Double.init) }
    var unrealizedPnlValue: Double? { unrealizedPnl.flatMap(Double.init) }
    var roe: Double? { returnOnEquity.flatMap(Double.init) }
    var liquidationPrice: Double? { liquidationPx.flatMap(Double.init) }
}

struct Leverage: Codable, Hashable {
    let type: String
    let value: Int
    let rawUsd: String?
}

/// Hyperliquid sends these over REST as strings, but the `allDexsClearinghouseState`
/// WebSocket subscription sends them as raw JSON numbers. The custom decoder
/// accepts either so the model doesn't silently end up with 0s.
struct MarginSummary: Codable, Hashable {
    let accountValueDouble: Double
    let totalPositionValue: Double
    let totalRawUsdDouble: Double
    let totalMarginUsedDouble: Double

    static let empty = MarginSummary(
        accountValueDouble: 0, totalPositionValue: 0,
        totalRawUsdDouble: 0, totalMarginUsedDouble: 0
    )

    init(accountValueDouble: Double, totalPositionValue: Double, totalRawUsdDouble: Double, totalMarginUsedDouble: Double) {
        self.accountValueDouble = accountValueDouble
        self.totalPositionValue = totalPositionValue
        self.totalRawUsdDouble = totalRawUsdDouble
        self.totalMarginUsedDouble = totalMarginUsedDouble
    }

    enum CodingKeys: String, CodingKey {
        case accountValue, totalNtlPos, totalRawUsd, totalMarginUsed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.accountValueDouble = (try? decodeNumeric(c, key: .accountValue)) ?? 0
        self.totalPositionValue = (try? decodeNumeric(c, key: .totalNtlPos)) ?? 0
        self.totalRawUsdDouble = (try? decodeNumeric(c, key: .totalRawUsd)) ?? 0
        self.totalMarginUsedDouble = (try? decodeNumeric(c, key: .totalMarginUsed)) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(String(accountValueDouble), forKey: .accountValue)
        try c.encode(String(totalPositionValue), forKey: .totalNtlPos)
        try c.encode(String(totalRawUsdDouble), forKey: .totalRawUsd)
        try c.encode(String(totalMarginUsedDouble), forKey: .totalMarginUsed)
    }
}

/// Clearinghouse state for one venue. `allDexsClearinghouseState` delivers
/// one of these per dex name; the core Hyperliquid venue is keyed by `""`.
struct UserState: Decodable {
    var assetPositions: [AssetPosition] = []
    var marginSummary: MarginSummary = .empty
    var crossMarginSummary: MarginSummary = .empty
    var withdrawable: Double = 0
    var crossMaintenanceMarginUsed: Double = 0
    var time: Int64?

    var withdrawableDouble: Double { withdrawable }

    init(assetPositions: [AssetPosition] = [],
         marginSummary: MarginSummary = .empty,
         crossMarginSummary: MarginSummary = .empty,
         withdrawable: Double = 0,
         crossMaintenanceMarginUsed: Double = 0,
         time: Int64? = nil) {
        self.assetPositions = assetPositions
        self.marginSummary = marginSummary
        self.crossMarginSummary = crossMarginSummary
        self.withdrawable = withdrawable
        self.crossMaintenanceMarginUsed = crossMaintenanceMarginUsed
        self.time = time
    }

    enum CodingKeys: String, CodingKey {
        case assetPositions, marginSummary, crossMarginSummary
        case withdrawable, crossMaintenanceMarginUsed, time
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.assetPositions = (try? c.decode([AssetPosition].self, forKey: .assetPositions)) ?? []
        let direct = try? c.decode(MarginSummary.self, forKey: .marginSummary)
        let cross  = try? c.decode(MarginSummary.self, forKey: .crossMarginSummary)
        // Unified / HIP-3 payloads sometimes ship only `crossMarginSummary`.
        // Fall back so every caller that reads `marginSummary.accountValueDouble`
        // still gets a real number.
        self.marginSummary = direct ?? cross ?? .empty
        self.crossMarginSummary = cross ?? direct ?? .empty
        self.withdrawable = (try? decodeNumeric(c, key: .withdrawable)) ?? 0
        self.crossMaintenanceMarginUsed = (try? decodeNumeric(c, key: .crossMaintenanceMarginUsed)) ?? 0
        self.time = try? c.decode(Int64.self, forKey: .time)
    }
}

/// Accept both a JSON number and a decimal-string representation and return
/// the Double value. Hyperliquid's live stream shows both on different
/// channels / field positions; decoding generously keeps the model tolerant.
fileprivate func decodeNumeric<K: CodingKey>(_ c: KeyedDecodingContainer<K>, key: K) throws -> Double {
    if let d = try? c.decode(Double.self, forKey: key) { return d }
    if let s = try? c.decode(String.self, forKey: key), let v = Double(s) { return v }
    throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath + [key],
                                            debugDescription: "Expected number or numeric string"))
}

/// Payload wrapper for the `allDexsClearinghouseState` WebSocket push.
///
/// The Hyperliquid TypeScript docs say `clearinghouseStates` is
/// `Record<string, ClearinghouseState>`, but the live feed actually sends an
/// **array of `[dex, state]` tuples** plus a top-level `time`. We decode
/// both layouts here — dict-shape survives future docs alignment, and the
/// tuple-array shape is what real traffic looks like today.
///
/// Example current wire shape:
/// ```
/// {"user":"0x…",
///  "clearinghouseStates":[
///    ["", { "assetPositions":[…], "marginSummary":{…}, … }],
///    ["xyz", { … }]
///  ],
///  "time":1776748979417}
/// ```
struct WsAllDexsClearinghouseStateWire: Decodable {
    let user: String
    let clearinghouseStates: [String: UserState]
    let time: Int64?

    enum CodingKeys: String, CodingKey {
        case user, clearinghouseStates, time
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.user = (try? c.decode(String.self, forKey: .user)) ?? ""
        self.time = try? c.decode(Int64.self, forKey: .time)

        // Try dict first (matches the TS doc)…
        if let dict = try? c.decode([String: UserState].self, forKey: .clearinghouseStates) {
            self.clearinghouseStates = dict
            return
        }
        // …otherwise array-of-pairs, which is what the live feed sends.
        if var arr = try? c.nestedUnkeyedContainer(forKey: .clearinghouseStates) {
            var out: [String: UserState] = [:]
            while !arr.isAtEnd {
                var tuple = try arr.nestedUnkeyedContainer()
                let dex = (try? tuple.decode(String.self)) ?? ""
                let state = (try? tuple.decode(UserState.self)) ?? UserState()
                out[dex] = state
            }
            self.clearinghouseStates = out
            return
        }
        self.clearinghouseStates = [:]
    }
}

/// Spot balance as delivered by `spotClearinghouseState` (REST) and
/// `spotState` (WebSocket). Hyperliquid keeps these as decimal strings on
/// both channels, so a straight `Codable` struct is fine here.
struct SpotBalance: Codable, Hashable, Identifiable {
    let coin: String
    let token: Int?
    let hold: String
    let total: String
    let entryNtl: String?

    var id: String { coin }
    var totalDouble: Double { Double(total) ?? 0 }
    var holdDouble: Double { Double(hold) ?? 0 }
    var entryNotional: Double? { entryNtl.flatMap(Double.init) }
}

struct SpotClearinghouseState: Codable {
    let balances: [SpotBalance]
}

struct OpenOrder: Codable, Hashable, Identifiable {
    let coin: String
    let side: String
    let limitPx: String
    let sz: String
    let oid: Int64
    let timestamp: Int64
    let origSz: String?

    var id: Int64 { oid }
    var price: Double { Double(limitPx) ?? 0 }
    var size: Double { Double(sz) ?? 0 }
    var isBuy: Bool { side == "B" }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000) }
}
