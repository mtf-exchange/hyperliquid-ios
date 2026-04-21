import Foundation

enum HyperliquidEnvironment: String, CaseIterable, Identifiable {
    case mainnet
    case testnet

    var id: String { rawValue }

    var restURL: URL {
        switch self {
        case .mainnet: return URL(string: "https://api.hyperliquid.xyz")!
        case .testnet: return URL(string: "https://api.hyperliquid-testnet.xyz")!
        }
    }

    var socketURL: URL {
        switch self {
        case .mainnet: return URL(string: "wss://api.hyperliquid.xyz/ws")!
        case .testnet: return URL(string: "wss://api.hyperliquid-testnet.xyz/ws")!
        }
    }

    var displayName: String {
        switch self {
        case .mainnet: return "Mainnet"
        case .testnet: return "Testnet"
        }
    }
}
