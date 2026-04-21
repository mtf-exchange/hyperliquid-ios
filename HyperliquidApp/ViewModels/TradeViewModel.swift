import Foundation
import SwiftUI

@MainActor
final class TradeViewModel: ObservableObject {
    enum OrderMode: String, CaseIterable, Identifiable {
        case limit = "Limit"
        case market = "Market"
        case tp = "TP"
        case sl = "SL"
        var id: String { rawValue }
    }

    @Published var isBuy: Bool = true
    @Published var priceText: String = ""
    @Published var sizeText: String = ""
    @Published var tif: OrderRequest.TimeInForce = .gtc
    @Published var reduceOnly: Bool = false
    @Published var leverageText: String = ""

    @Published var orderMode: OrderMode = .limit
    @Published var triggerPriceText: String = ""
    @Published var triggerIsMarket: Bool = true
    @Published var markPrice: Double?

    @Published private(set) var submitting: Bool = false
    @Published private(set) var lastResult: String?
    @Published private(set) var lastError: String?

    @Published private(set) var coin: String
    private let exchange: HyperliquidExchangeAPI
    private unowned let session: AppSession

    init(coin: String, exchange: HyperliquidExchangeAPI, session: AppSession) {
        self.coin = coin
        self.exchange = exchange
        self.session = session
    }

    /// Surface an error from an outside caller (e.g. the Trade view's Submit
    /// button when spot is selected).
    func surface(error: String?) {
        self.lastError = error
        if error != nil { self.lastResult = nil }
    }

    func switchTo(coin newCoin: String) {
        guard newCoin != coin else { return }
        self.coin = newCoin
        self.priceText = ""
        self.sizeText = ""
        self.triggerPriceText = ""
        self.markPrice = nil
        self.lastError = nil
        self.lastResult = nil
    }

    func fillFromMid(_ mid: Double?) {
        markPrice = mid
        guard priceText.isEmpty, let mid else { return }
        priceText = String(format: "%g", mid)
    }

    var canSubmit: Bool {
        guard !submitting, session.agent != nil else { return false }
        guard (Double(sizeText) ?? 0) > 0 else { return false }
        switch orderMode {
        case .limit:
            return (Double(priceText) ?? 0) > 0
        case .market:
            return (markPrice ?? 0) > 0
        case .tp, .sl:
            guard (Double(triggerPriceText) ?? 0) > 0 else { return false }
            if !triggerIsMarket {
                return (Double(priceText) ?? 0) > 0
            }
            return true
        }
    }

    /// Reference price used to convert between USDC notional and base-coin
    /// units. Picks the most authoritative available price: the limit price
    /// when in limit mode, the trigger in TP/SL, otherwise the live mark.
    private var referencePrice: Double? {
        switch orderMode {
        case .limit: return Double(priceText)
        case .market: return markPrice
        case .tp, .sl: return Double(triggerPriceText)
        }
    }

    /// Notional value of the order, always expressed in USDC. Handles both
    /// size-unit modes — in USDC mode `sizeText` *is* the notional; in base
    /// mode we multiply by the reference price.
    var notional: Double? {
        guard let s = Double(sizeText) else { return nil }
        switch session.sizeUnit {
        case .usdc: return s
        case .base:
            guard let p = referencePrice else { return nil }
            return s * p
        }
    }

    /// Size in base-coin units, accounting for the user's preferred input
    /// mode. Returns nil if sizeText parses empty or the conversion can't be
    /// done (USDC mode without a reference price).
    private func resolveBaseSize() -> Double? {
        guard let s = Double(sizeText), s > 0 else { return nil }
        switch session.sizeUnit {
        case .base: return s
        case .usdc:
            guard let p = referencePrice, p > 0 else { return nil }
            return s / p
        }
    }

    func submit(universe: Universe?, markPrice: Double? = nil) async {
        guard session.agent != nil, let universe else {
            lastError = "Trading not enabled"
            return
        }
        guard let size = resolveBaseSize() else {
            lastError = session.sizeUnit == .usdc
                ? "Enter a USDC amount and a price"
                : "Invalid size"
            return
        }

        let req: OrderRequest
        switch orderMode {
        case .limit:
            guard let price = Double(priceText), price > 0 else {
                lastError = "Invalid price"
                return
            }
            req = OrderRequest(
                coin: coin,
                isBuy: isBuy,
                size: size,
                limitPrice: price,
                reduceOnly: reduceOnly,
                tif: tif
            )
        case .market:
            let mark = markPrice ?? self.markPrice
            guard let mark, mark > 0 else {
                lastError = "Missing mark price for market order"
                return
            }
            let slipped = isBuy ? mark * 1.05 : mark * 0.95
            req = OrderRequest(
                coin: coin,
                isBuy: isBuy,
                size: size,
                limitPrice: slipped,
                reduceOnly: reduceOnly,
                tif: .ioc
            )
        case .tp, .sl:
            guard let triggerPrice = Double(triggerPriceText), triggerPrice > 0 else {
                lastError = "Invalid trigger price"
                return
            }
            let limitPrice: Double
            if triggerIsMarket {
                // Limit fallback unused when isMarket=true; use trigger price as placeholder.
                limitPrice = triggerPrice
            } else {
                guard let p = Double(priceText), p > 0 else {
                    lastError = "Invalid limit price"
                    return
                }
                limitPrice = p
            }
            let trigger = OrderRequest.Trigger(
                triggerPrice: triggerPrice,
                isMarket: triggerIsMarket,
                kind: orderMode == .tp ? .tp : .sl
            )
            req = OrderRequest(
                coin: coin,
                isBuy: isBuy,
                size: size,
                limitPrice: limitPrice,
                reduceOnly: reduceOnly,
                tif: .gtc,
                trigger: trigger
            )
        }

        submitting = true
        lastError = nil
        lastResult = nil
        defer { submitting = false }
        do {
            let agent = try await session.loadAgentKey(reason: "Sign Hyperliquid order")
            let response = try await exchange.placeOrder(
                req,
                universe: universe,
                agent: agent,
                isMainnet: session.environment == .mainnet
            )
            lastResult = summarize(response)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setLeverage(universe: Universe?) async {
        guard session.agent != nil, let universe else {
            lastError = "Trading not enabled"
            return
        }
        guard let lev = Int(leverageText), lev > 0 else {
            lastError = "Invalid leverage"
            return
        }
        do {
            let agent = try await session.loadAgentKey(reason: "Update leverage")
            _ = try await exchange.updateLeverage(
                coin: coin,
                isCross: true,
                leverage: lev,
                universe: universe,
                agent: agent,
                isMainnet: session.environment == .mainnet
            )
            lastResult = "Leverage → \(lev)x"
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func summarize(_ response: [String: Any]) -> String {
        if let status = response["status"] as? String, status == "ok" {
            if let inner = response["response"] as? [String: Any],
               let data = inner["data"] as? [String: Any],
               let statuses = data["statuses"] as? [Any],
               let first = statuses.first {
                if let filled = (first as? [String: Any])?["filled"] as? [String: Any] {
                    let totalSz = filled["totalSz"] as? String ?? "?"
                    let avgPx = filled["avgPx"] as? String ?? "?"
                    return "Filled \(totalSz) @ \(avgPx)"
                }
                if let resting = (first as? [String: Any])?["resting"] as? [String: Any] {
                    let oid = resting["oid"] as? Int ?? 0
                    return "Resting oid=\(oid)"
                }
            }
            return "OK"
        }
        return "Unexpected response"
    }
}
