import Foundation
import SwiftUI

/// Drives the TransferView. Builds the right user-signed action, asks the
/// connected wallet to sign it via WalletConnect, then submits it to
/// /exchange. The same timestamp-ms is used as both the action's time/nonce
/// field (inside the typed-data payload the wallet sees) and the outer POST
/// body's `nonce`, so the server's signature check lines up.
@MainActor
final class TransferViewModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case withdraw
        case usdSend
        case toPerp
        case toSpot

        var id: String { rawValue }

        var title: String {
            switch self {
            case .withdraw: return "Withdraw"
            case .usdSend: return "Send USDC"
            case .toPerp: return "Spot → Perp"
            case .toSpot: return "Perp → Spot"
            }
        }

        var needsDestination: Bool {
            self == .withdraw || self == .usdSend
        }
    }

    @Published var mode: Mode = .toPerp
    @Published var destination: String = ""
    @Published var amount: String = ""
    @Published private(set) var submitting: Bool = false
    @Published private(set) var result: String?
    @Published private(set) var errorMessage: String?

    private unowned let session: AppSession

    init(session: AppSession) {
        self.session = session
    }

    var canSubmit: Bool {
        guard !submitting else { return false }
        guard !amount.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard session.walletConnect.connectedAddress != nil else { return false }
        if mode.needsDestination {
            let d = destination.trimmingCharacters(in: .whitespaces)
            guard d.hasPrefix("0x"), d.count >= 42 else { return false }
        }
        return true
    }

    func submit() async {
        guard session.walletConnect.connectedAddress != nil else {
            errorMessage = "Connect a wallet first"
            return
        }
        let trimmedAmount = amount.trimmingCharacters(in: .whitespaces)
        guard !trimmedAmount.isEmpty else {
            errorMessage = "Enter an amount"
            return
        }

        submitting = true
        errorMessage = nil
        result = nil
        defer { submitting = false }

        let isMainnet = session.environment == .mainnet
        let nonce = Int64(Date().timeIntervalSince1970 * 1000)
        let dest = destination.trimmingCharacters(in: .whitespaces)

        do {
            let typedJSON: String
            switch mode {
            case .withdraw:
                (_, typedJSON) = try Withdraw.build(
                    destination: dest,
                    amount: trimmedAmount,
                    isMainnet: isMainnet,
                    timeMs: nonce
                )
            case .usdSend:
                (_, typedJSON) = try UsdSend.build(
                    destination: dest,
                    amount: trimmedAmount,
                    isMainnet: isMainnet,
                    timeMs: nonce
                )
            case .toPerp, .toSpot:
                (_, typedJSON) = try UsdClassTransfer.build(
                    amount: trimmedAmount,
                    toPerp: mode == .toPerp,
                    isMainnet: isMainnet,
                    nonceMs: nonce
                )
            }

            let sigHex = try await session.walletConnect.signTypedData(typedJSON)

            let response: [String: Any]
            switch mode {
            case .withdraw:
                response = try await session.exchange.submitWithdraw(
                    destination: dest,
                    amount: trimmedAmount,
                    isMainnet: isMainnet,
                    signatureHex: sigHex,
                    timeMs: nonce
                )
            case .usdSend:
                response = try await session.exchange.submitUsdSend(
                    destination: dest,
                    amount: trimmedAmount,
                    isMainnet: isMainnet,
                    signatureHex: sigHex,
                    timeMs: nonce
                )
            case .toPerp, .toSpot:
                response = try await session.exchange.submitUsdClassTransfer(
                    amount: trimmedAmount,
                    toPerp: mode == .toPerp,
                    isMainnet: isMainnet,
                    signatureHex: sigHex,
                    nonceMs: nonce
                )
            }

            result = summarize(response)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func summarize(_ response: [String: Any]) -> String {
        if let status = response["status"] as? String, status == "ok" {
            return "OK"
        }
        return "Unexpected response"
    }
}
