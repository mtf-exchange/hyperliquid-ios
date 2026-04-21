import Foundation

/// POSTs signed actions to Hyperliquid's `/exchange` endpoint.
/// Accepts a signature as (r, s, v) hex components produced either by the user's
/// wallet (for user-signed actions like `approveAgent`, `usdSend`, `withdraw3`)
/// or by the local agent key (for L1 actions like `order`, `cancel`).
final class HyperliquidExchangeAPI {
    let api: HyperliquidAPI

    init(api: HyperliquidAPI) {
        self.api = api
    }

    // MARK: - L1 action helpers

    /// Place a single order. Returns the parsed /exchange response.
    @discardableResult
    func placeOrder(
        _ request: OrderRequest,
        universe: Universe,
        agent: AgentKey,
        isMainnet: Bool,
        vaultAddress: String? = nil
    ) async throws -> [String: Any] {
        let resolver = OrderAction.AssetResolver(universe: universe)
        let (json, wire) = try OrderAction.placeOrder(request, resolver: resolver)
        return try await signAndPost(json: json, wire: wire, agent: agent, isMainnet: isMainnet, vaultAddress: vaultAddress)
    }

    @discardableResult
    func cancel(
        coin: String,
        oid: Int64,
        universe: Universe,
        agent: AgentKey,
        isMainnet: Bool,
        vaultAddress: String? = nil
    ) async throws -> [String: Any] {
        let resolver = OrderAction.AssetResolver(universe: universe)
        let asset = try resolver.id(of: coin)
        let (json, wire) = OrderAction.cancel(asset: asset, oid: oid)
        return try await signAndPost(json: json, wire: wire, agent: agent, isMainnet: isMainnet, vaultAddress: vaultAddress)
    }

    @discardableResult
    func updateLeverage(
        coin: String,
        isCross: Bool,
        leverage: Int,
        universe: Universe,
        agent: AgentKey,
        isMainnet: Bool
    ) async throws -> [String: Any] {
        let resolver = OrderAction.AssetResolver(universe: universe)
        let asset = try resolver.id(of: coin)
        let (json, wire) = OrderAction.updateLeverage(asset: asset, isCross: isCross, leverage: leverage)
        return try await signAndPost(json: json, wire: wire, agent: agent, isMainnet: isMainnet, vaultAddress: nil)
    }

    // MARK: - User-signed transfer actions
    //
    // These rebuild the exact action dict that was signed by the wallet
    // (so the server sees the same bytes the user approved), parse the
    // concatenated 65-byte hex signature into (r,s,v), and POST /exchange.

    @discardableResult
    func submitWithdraw(
        destination: String,
        amount: String,
        isMainnet: Bool,
        signatureHex: String,
        timeMs: Int64
    ) async throws -> [String: Any] {
        let (action, _) = try Withdraw.build(
            destination: destination,
            amount: amount,
            isMainnet: isMainnet,
            timeMs: timeMs
        )
        guard let sig = Signature.fromConcatenatedHex(signatureHex) else {
            throw EnableTradingError.badSignature
        }
        return try await post(action: action, signature: sig, nonce: timeMs, vaultAddress: nil)
    }

    @discardableResult
    func submitUsdSend(
        destination: String,
        amount: String,
        isMainnet: Bool,
        signatureHex: String,
        timeMs: Int64
    ) async throws -> [String: Any] {
        let (action, _) = try UsdSend.build(
            destination: destination,
            amount: amount,
            isMainnet: isMainnet,
            timeMs: timeMs
        )
        guard let sig = Signature.fromConcatenatedHex(signatureHex) else {
            throw EnableTradingError.badSignature
        }
        return try await post(action: action, signature: sig, nonce: timeMs, vaultAddress: nil)
    }

    @discardableResult
    func submitUsdClassTransfer(
        amount: String,
        toPerp: Bool,
        isMainnet: Bool,
        signatureHex: String,
        nonceMs: Int64
    ) async throws -> [String: Any] {
        let (action, _) = try UsdClassTransfer.build(
            amount: amount,
            toPerp: toPerp,
            isMainnet: isMainnet,
            nonceMs: nonceMs
        )
        guard let sig = Signature.fromConcatenatedHex(signatureHex) else {
            throw EnableTradingError.badSignature
        }
        return try await post(action: action, signature: sig, nonce: nonceMs, vaultAddress: nil)
    }

    private func signAndPost(
        json: [String: Any],
        wire: MsgPackValue,
        agent: AgentKey,
        isMainnet: Bool,
        vaultAddress: String?
    ) async throws -> [String: Any] {
        let nonce = UInt64(Date().timeIntervalSince1970 * 1000)
        let signature = try L1Signer.sign(
            action: wire,
            agent: agent,
            isMainnet: isMainnet,
            nonce: nonce,
            vaultAddress: vaultAddress
        )
        return try await post(action: json, signature: signature, nonce: Int64(nonce), vaultAddress: vaultAddress)
    }

    struct Signature {
        let r: String   // 0x-prefixed 32 bytes
        let s: String   // 0x-prefixed 32 bytes
        let v: Int      // 27 / 28 (or 0 / 1 depending on wallet)

        static func fromConcatenatedHex(_ hex: String) -> Signature? {
            var h = hex
            if h.hasPrefix("0x") { h.removeFirst(2) }
            guard h.count == 130 else { return nil }   // 65 bytes
            let r = "0x" + h.prefix(64)
            let s = "0x" + h.dropFirst(64).prefix(64)
            let vHex = String(h.suffix(2))
            guard var v = Int(vHex, radix: 16) else { return nil }
            if v < 27 { v += 27 }                       // normalize to {27,28}
            return Signature(r: r, s: s, v: v)
        }
    }

    struct ExchangeResponse: Decodable {
        let status: String
        let response: AnyDecodable?
    }

    struct AnyDecodable: Decodable { }  // drop body — callers that need it switch to JSONSerialization

    /// Generic POST /exchange. `action` is the action dict exactly as sent on the wire.
    @discardableResult
    func post(action: [String: Any], signature: Signature, nonce: Int64, vaultAddress: String? = nil) async throws -> [String: Any] {
        var body: [String: Any] = [
            "action": action,
            "nonce": nonce,
            "signature": [
                "r": signature.r,
                "s": signature.s,
                "v": signature.v
            ]
        ]
        if let vault = vaultAddress { body["vaultAddress"] = vault }

        var req = URLRequest(url: api.environment.restURL.appendingPathComponent("exchange"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            throw HyperliquidAPIError.http((response as? HTTPURLResponse)?.statusCode ?? -1, bodyStr)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HyperliquidAPIError.invalidResponse
        }
        if (json["status"] as? String) == "err" {
            throw HyperliquidAPIError.exchange(Self.describeExchangeError(json["response"]))
        }
        // Per-order statuses surface errors inside a successful HTTP response.
        if let inner = json["response"] as? [String: Any],
           let innerData = inner["data"] as? [String: Any],
           let statuses = innerData["statuses"] as? [Any] {
            let errors = statuses.compactMap { ($0 as? [String: Any])?["error"] as? String }
            if !errors.isEmpty, errors.count == statuses.count {
                throw HyperliquidAPIError.exchange(errors.joined(separator: "; "))
            }
        }
        return json
    }

    /// Hyperliquid returns `response` as either a string or a nested object.
    /// Extract a single readable line no matter which shape it takes.
    private static func describeExchangeError(_ raw: Any?) -> String {
        if let s = raw as? String { return s }
        if let dict = raw as? [String: Any] {
            if let msg = dict["error"] as? String { return msg }
            if let data = try? JSONSerialization.data(withJSONObject: dict),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
        }
        return "unknown error"
    }
}
