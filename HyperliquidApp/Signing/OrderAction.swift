import Foundation

/// Strongly-typed order inputs the trader sees, converted to wire form
/// (`OrderWire`) for both JSON posting and msgpack hashing.
struct OrderRequest {
    var coin: String
    var isBuy: Bool
    var size: Double
    var limitPrice: Double
    var reduceOnly: Bool = false
    var tif: TimeInForce = .gtc
    var trigger: Trigger? = nil
    var cloid: String? = nil   // 16-byte 0x-hex client order id

    enum TimeInForce: String { case gtc = "Gtc", ioc = "Ioc", alo = "Alo" }

    struct Trigger {
        var triggerPrice: Double
        var isMarket: Bool
        var kind: Kind
        enum Kind: String { case tp, sl }
    }
}

enum OrderAction {
    /// Resolves coin symbols to Hyperliquid asset ids using a universe snapshot.
    struct AssetResolver {
        let universe: [String: Int]
        init(universe: Universe) {
            var m: [String: Int] = [:]
            for (i, meta) in universe.universe.enumerated() { m[meta.name] = i }
            self.universe = m
        }
        func id(of coin: String) throws -> Int {
            guard let i = universe[coin] else { throw SigningError.unknownCoin(coin) }
            return i
        }
    }

    // MARK: - Action builders (returns BOTH JSON-ready & msgpack-ready forms)

    /// Returns the action in two forms:
    ///   - `json`: `[String: Any]` ready for `/exchange` POST body.
    ///   - `wire`: `MsgPackValue` used by `ActionHasher.hash` for the L1 digest.
    static func placeOrder(_ request: OrderRequest, resolver: AssetResolver, grouping: String = "na")
        throws -> (json: [String: Any], wire: MsgPackValue)
    {
        let asset = try resolver.id(of: request.coin)
        let p = Self.floatToWire(request.limitPrice)
        let s = Self.floatToWire(request.size)

        let orderType: MsgPackValue
        let orderTypeJSON: [String: Any]
        if let t = request.trigger {
            let trig: [(String, MsgPackValue)] = [
                ("isMarket", .bool(t.isMarket)),
                ("triggerPx", .string(Self.floatToWire(t.triggerPrice))),
                ("tpsl", .string(t.kind.rawValue))
            ]
            orderType = .map([("trigger", .map(trig))])
            orderTypeJSON = ["trigger": [
                "isMarket": t.isMarket,
                "triggerPx": Self.floatToWire(t.triggerPrice),
                "tpsl": t.kind.rawValue
            ]]
        } else {
            orderType = .map([("limit", .map([("tif", .string(request.tif.rawValue))]))])
            orderTypeJSON = ["limit": ["tif": request.tif.rawValue]]
        }

        // Wire pairs MUST stay in this order (matches Python OrderWire TypedDict).
        var wirePairs: [(String, MsgPackValue)] = [
            ("a", .int(Int64(asset))),
            ("b", .bool(request.isBuy)),
            ("p", .string(p)),
            ("s", .string(s)),
            ("r", .bool(request.reduceOnly)),
            ("t", orderType)
        ]
        var jsonOrder: [String: Any] = [
            "a": asset, "b": request.isBuy, "p": p, "s": s, "r": request.reduceOnly, "t": orderTypeJSON
        ]
        if let cloid = request.cloid {
            wirePairs.append(("c", .string(cloid)))
            jsonOrder["c"] = cloid
        }

        let action: MsgPackValue = .map([
            ("type",     .string("order")),
            ("orders",   .array([.map(wirePairs)])),
            ("grouping", .string(grouping))
        ])
        let json: [String: Any] = [
            "type": "order",
            "orders": [jsonOrder],
            "grouping": grouping
        ]
        return (json, action)
    }

    static func cancel(asset: Int, oid: Int64) -> (json: [String: Any], wire: MsgPackValue) {
        let wire: MsgPackValue = .map([
            ("type",    .string("cancel")),
            ("cancels", .array([.map([("a", .int(Int64(asset))), ("o", .int(oid))])]))
        ])
        let json: [String: Any] = [
            "type": "cancel",
            "cancels": [["a": asset, "o": oid]]
        ]
        return (json, wire)
    }

    static func updateLeverage(asset: Int, isCross: Bool, leverage: Int) -> (json: [String: Any], wire: MsgPackValue) {
        let wire: MsgPackValue = .map([
            ("type",     .string("updateLeverage")),
            ("asset",    .int(Int64(asset))),
            ("isCross",  .bool(isCross)),
            ("leverage", .int(Int64(leverage)))
        ])
        let json: [String: Any] = [
            "type": "updateLeverage",
            "asset": asset,
            "isCross": isCross,
            "leverage": leverage
        ]
        return (json, wire)
    }

    static func updateIsolatedMargin(asset: Int, isBuy: Bool, ntliUsdMicros: Int64) -> (json: [String: Any], wire: MsgPackValue) {
        // ntli is integer USD * 1e6, per Python `float_to_usd_int`.
        let wire: MsgPackValue = .map([
            ("type",  .string("updateIsolatedMargin")),
            ("asset", .int(Int64(asset))),
            ("isBuy", .bool(isBuy)),
            ("ntli",  .int(ntliUsdMicros))
        ])
        let json: [String: Any] = [
            "type": "updateIsolatedMargin",
            "asset": asset,
            "isBuy": isBuy,
            "ntli": ntliUsdMicros
        ]
        return (json, wire)
    }

    // MARK: -

    /// Matches Python `float_to_wire`: round to 8 decimals, strip trailing zeros.
    /// Throws-equivalent would be a precondition on lossy rounding; the wallet
    /// side already clamps to `szDecimals` so callers should pre-round.
    static func floatToWire(_ x: Double) -> String {
        var s = String(format: "%.8f", x)
        // drop trailing zeros / dot
        while s.contains(".") && s.last == "0" { s.removeLast() }
        if s.last == "." { s.removeLast() }
        if s == "-0" { s = "0" }
        return s
    }
}
