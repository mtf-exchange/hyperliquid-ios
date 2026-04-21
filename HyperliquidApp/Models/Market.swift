import Foundation

struct AssetMeta: Codable, Hashable, Identifiable {
    let name: String
    let szDecimals: Int
    let maxLeverage: Int?

    var id: String { name }
}

struct Universe: Codable {
    let universe: [AssetMeta]
}

struct AssetContext: Codable, Hashable {
    let funding: String?
    let openInterest: String?
    let prevDayPx: String?
    let dayNtlVlm: String?
    let premium: String?
    let oraclePx: String?
    let markPx: String?
    let midPx: String?
    let impactPxs: [String]?
}

struct Market: Identifiable, Hashable {
    let meta: AssetMeta
    let context: AssetContext
    /// HIP-3 deployer name, or "" for Hyperliquid Core markets.
    let dex: String

    init(meta: AssetMeta, context: AssetContext, dex: String = "") {
        self.meta = meta
        self.context = context
        self.dex = dex
    }

    var id: String { dex.isEmpty ? meta.name : "\(dex):\(meta.name)" }
    var name: String { meta.name }
    var isHip3: Bool { !dex.isEmpty }

    var markPrice: Double? { context.markPx.flatMap(Double.init) }
    var midPrice: Double? { context.midPx.flatMap(Double.init) }
    var oraclePrice: Double? { context.oraclePx.flatMap(Double.init) }
    var prevDayPrice: Double? { context.prevDayPx.flatMap(Double.init) }
    var dayVolumeUSD: Double? { context.dayNtlVlm.flatMap(Double.init) }
    var openInterest: Double? { context.openInterest.flatMap(Double.init) }
    var funding: Double? { context.funding.flatMap(Double.init) }

    var dayChangePct: Double? {
        guard let mark = markPrice, let prev = prevDayPrice, prev > 0 else { return nil }
        return (mark - prev) / prev
    }

    /// Broad classification for the Markets filter chips. HIP-3 markets come
    /// from per-deployer `metaAndAssetCtxs(dex:)` pulls and are authoritatively
    /// tagged via `dex`. Everything on core leans on a curated ticker list to
    /// distinguish TradFi from Crypto.
    var category: MarketCategory {
        if isHip3 { return .hip3 }
        if MarketCategory.tradfiTickers.contains(name.uppercased()) { return .tradfi }
        return .crypto
    }
}

enum MarketCategory: String, CaseIterable, Identifiable {
    case crypto = "Crypto"
    case tradfi = "TradFi"
    case hip3   = "HIP-3"

    var id: String { rawValue }

    /// TradFi perps mirror equity/ETF/index prices. This list reflects listings
    /// live on Hyperliquid as of 2026-Q1; extend as new deployers land.
    static let tradfiTickers: Set<String> = [
        "SPX", "NDX", "DJI", "VIX",
        "AAPL", "MSFT", "NVDA", "GOOGL", "AMZN", "META", "TSLA",
        "COIN", "MSTR", "HOOD",
        "GLD", "SLV", "OIL",
        "EUR", "GBP", "JPY", "CNY"
    ]

    /// HIP-3 (permissionless perp listings) are flagged here until the
    /// perpDexs feed is wired up properly. Keep this conservative — anything
    /// uncertain stays in `crypto` bucket.
    static let hip3Tickers: Set<String> = []
}

// MARK: - Spot

struct SpotToken: Codable, Hashable {
    let name: String
    let szDecimals: Int
    let weiDecimals: Int
    let index: Int
    let tokenId: String?
}

struct SpotPair: Codable, Hashable {
    let tokens: [Int]
    let name: String
    let index: Int
    let isCanonical: Bool?
}

struct SpotUniverse: Codable {
    let universe: [SpotPair]
    let tokens: [SpotToken]

    func token(atIndex idx: Int) -> SpotToken? {
        tokens.first { $0.index == idx }
    }
}

struct SpotMarket: Identifiable, Hashable {
    let pair: SpotPair
    let base: SpotToken
    let quote: SpotToken
    let context: AssetContext

    var id: String { symbol }
    var symbol: String { pair.name }
    var displayName: String { "\(base.name)/\(quote.name)" }

    var markPrice: Double? { context.markPx.flatMap(Double.init) }
    var prevDayPrice: Double? { context.prevDayPx.flatMap(Double.init) }
    var dayVolumeUSD: Double? { context.dayNtlVlm.flatMap(Double.init) }

    var dayChangePct: Double? {
        guard let mark = markPrice, let prev = prevDayPrice, prev > 0 else { return nil }
        return (mark - prev) / prev
    }
}

// MARK: - HIP-3 deployers

struct PerpDex: Codable, Identifiable, Hashable {
    let name: String
    let full_name: String
    let deployer: String?
    let oracle_updater: String?

    var id: String { name }
    var isCore: Bool { name.isEmpty }
}
