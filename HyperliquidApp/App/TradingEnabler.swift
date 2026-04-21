import Foundation

/// End-to-end "Enable Trading" flow:
///   1. generate a fresh secp256k1 agent key
///   2. build the approveAgent action + EIP-712 typed data
///   3. ask the connected wallet (WalletConnect) to sign it
///   4. POST `{ action, nonce, signature }` to /exchange
///   5. persist the agent key in the Keychain
@MainActor
final class TradingEnabler {
    private let wallet: WalletConnectService
    private let exchange: HyperliquidExchangeAPI
    private let environment: HyperliquidEnvironment

    init(wallet: WalletConnectService, exchange: HyperliquidExchangeAPI, environment: HyperliquidEnvironment) {
        self.wallet = wallet
        self.exchange = exchange
        self.environment = environment
    }

    func enable(agentName: String = "HL iOS") async throws -> AgentInfo {
        let agent = try AgentKey.generate()
        let nonce = Int64(Date().timeIntervalSince1970 * 1000)
        let (action, typedJSON) = try ApproveAgent.build(
            agentAddress: agent.address,
            agentName: agentName,
            isMainnet: environment == .mainnet,
            nonceMs: nonce
        )

        let rawSigHex = try await wallet.signTypedData(typedJSON)
        guard let sig = HyperliquidExchangeAPI.Signature.fromConcatenatedHex(rawSigHex) else {
            throw EnableTradingError.badSignature
        }

        _ = try await exchange.post(action: action, signature: sig, nonce: nonce)
        return try AgentKeychain.save(agent)
    }
}

enum EnableTradingError: Error, LocalizedError {
    case badSignature
    var errorDescription: String? {
        switch self {
        case .badSignature: return "Wallet returned an unexpected signature format"
        }
    }
}
