import Foundation

/// Hyperliquid "Enable Trading" = submit an `approveAgent` user-signed action.
/// The main wallet (connected via WalletConnect) signs EIP-712 typed data
/// registering the agent address on-chain; subsequent L1 actions (orders,
/// cancels) are then signed locally by the agent's secp256k1 key without
/// popping the wallet.
enum ApproveAgent {
    /// Builds the action dict **and** the typed-data JSON for wallet signing.
    /// `agentName` is free-form; pass nil for an unnamed agent.
    static func build(
        agentAddress: String,
        agentName: String?,
        isMainnet: Bool,
        nonceMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) throws -> (action: [String: Any], typedDataJSON: String) {

        var action: [String: Any] = [
            "type": "approveAgent",
            "signatureChainId": Eip712.defaultSignatureChainId,
            "hyperliquidChain": isMainnet ? "Mainnet" : "Testnet",
            "agentAddress": agentAddress.lowercased(),
            "nonce": nonceMs
        ]
        if let name = agentName, !name.isEmpty {
            action["agentName"] = name
        } else {
            action["agentName"] = ""
        }

        let fields: [Eip712.Field] = [
            .init(name: "hyperliquidChain", type: "string"),
            .init(name: "agentAddress", type: "address"),
            .init(name: "agentName", type: "string"),
            .init(name: "nonce", type: "uint64")
        ]

        let typedJSON = try Eip712.userSignedPayloadJSON(
            primaryType: "HyperliquidTransaction:ApproveAgent",
            fields: fields,
            action: action
        )
        return (action, typedJSON)
    }
}
