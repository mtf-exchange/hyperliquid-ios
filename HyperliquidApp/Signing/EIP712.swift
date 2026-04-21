import Foundation

/// Builds Hyperliquid's user-signed EIP-712 typed-data payloads. Hyperliquid uses
/// `HyperliquidSignTransaction` as the EIP-712 domain for user-signed actions
/// (approveAgent, usdSend, withdraw3, …). Domain chainId comes from the
/// action's `signatureChainId` hex field. The SDK default is `0x66eee`.
///
/// Source of truth: hyperliquid-python-sdk/hyperliquid/utils/signing.py
enum Eip712 {
    static let defaultSignatureChainId = "0x66eee"   // 421614 (Arbitrum Sepolia)

    struct Field {
        let name: String
        let type: String
    }

    /// Returns a JSON-encoded string ready to pass as the `eth_signTypedData_v4` param.
    static func userSignedPayloadJSON(
        primaryType: String,
        fields: [Field],
        action: [String: Any]
    ) throws -> String {
        guard let chainHex = action["signatureChainId"] as? String,
              let chainId = Int(chainHex.replacingOccurrences(of: "0x", with: ""), radix: 16) else {
            throw EIP712Error.missingSignatureChainId
        }

        let domain: [String: Any] = [
            "name": "HyperliquidSignTransaction",
            "version": "1",
            "chainId": chainId,
            "verifyingContract": "0x0000000000000000000000000000000000000000"
        ]

        let eip712DomainFields: [[String: String]] = [
            ["name": "name", "type": "string"],
            ["name": "version", "type": "string"],
            ["name": "chainId", "type": "uint256"],
            ["name": "verifyingContract", "type": "address"]
        ]

        let primaryFields = fields.map { ["name": $0.name, "type": $0.type] }

        let types: [String: Any] = [
            "EIP712Domain": eip712DomainFields,
            primaryType: primaryFields
        ]

        let payload: [String: Any] = [
            "domain": domain,
            "types": types,
            "primaryType": primaryType,
            "message": action
        ]

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let str = String(data: data, encoding: .utf8) else {
            throw EIP712Error.encodingFailed
        }
        return str
    }
}

enum EIP712Error: Error {
    case missingSignatureChainId
    case encodingFailed
}
