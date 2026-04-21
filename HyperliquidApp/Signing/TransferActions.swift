import Foundation

/// Builders for Hyperliquid user-signed transfer actions:
///  - `withdraw3`       (on-chain USDC withdrawal to an EVM address)
///  - `usdSend`         (L1 USDC transfer to another Hyperliquid user)
///  - `usdClassTransfer` (move USDC between spot and perp accounts)
///
/// Mirrors `ApproveAgent.build(...)` — each returns `(action, typedDataJSON)`.
/// The caller hands `typedDataJSON` to the wallet via `eth_signTypedData_v4`,
/// then POSTs `{action, signature, nonce}` to `/exchange`.
enum Withdraw {
    static func build(
        destination: String,
        amount: String,
        isMainnet: Bool,
        timeMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) throws -> (action: [String: Any], typedDataJSON: String) {

        let action: [String: Any] = [
            "type": "withdraw3",
            "signatureChainId": Eip712.defaultSignatureChainId,
            "hyperliquidChain": isMainnet ? "Mainnet" : "Testnet",
            "destination": destination.lowercased(),
            "amount": amount,
            "time": timeMs
        ]

        let fields: [Eip712.Field] = [
            .init(name: "hyperliquidChain", type: "string"),
            .init(name: "destination", type: "string"),
            .init(name: "amount", type: "string"),
            .init(name: "time", type: "uint64")
        ]

        let typedJSON = try Eip712.userSignedPayloadJSON(
            primaryType: "HyperliquidTransaction:Withdraw",
            fields: fields,
            action: action
        )
        return (action, typedJSON)
    }
}

enum UsdSend {
    static func build(
        destination: String,
        amount: String,
        isMainnet: Bool,
        timeMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) throws -> (action: [String: Any], typedDataJSON: String) {

        let action: [String: Any] = [
            "type": "usdSend",
            "signatureChainId": Eip712.defaultSignatureChainId,
            "hyperliquidChain": isMainnet ? "Mainnet" : "Testnet",
            "destination": destination.lowercased(),
            "amount": amount,
            "time": timeMs
        ]

        let fields: [Eip712.Field] = [
            .init(name: "hyperliquidChain", type: "string"),
            .init(name: "destination", type: "string"),
            .init(name: "amount", type: "string"),
            .init(name: "time", type: "uint64")
        ]

        let typedJSON = try Eip712.userSignedPayloadJSON(
            primaryType: "HyperliquidTransaction:UsdSend",
            fields: fields,
            action: action
        )
        return (action, typedJSON)
    }
}

enum UsdClassTransfer {
    static func build(
        amount: String,
        toPerp: Bool,
        isMainnet: Bool,
        nonceMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) throws -> (action: [String: Any], typedDataJSON: String) {

        let action: [String: Any] = [
            "type": "usdClassTransfer",
            "signatureChainId": Eip712.defaultSignatureChainId,
            "hyperliquidChain": isMainnet ? "Mainnet" : "Testnet",
            "amount": amount,
            "toPerp": toPerp,
            "nonce": nonceMs
        ]

        let fields: [Eip712.Field] = [
            .init(name: "hyperliquidChain", type: "string"),
            .init(name: "amount", type: "string"),
            .init(name: "toPerp", type: "bool"),
            .init(name: "nonce", type: "uint64")
        ]

        let typedJSON = try Eip712.userSignedPayloadJSON(
            primaryType: "HyperliquidTransaction:UsdClassTransfer",
            fields: fields,
            action: action
        )
        return (action, typedJSON)
    }
}
