import Foundation
import CryptoSwift

/// Mirrors Python SDK's `action_hash`:
///
///     data = msgpack.packb(action)
///     data += nonce.to_bytes(8, "big")
///     data += b"\x00" if vault_address is None else (b"\x01" + vault_bytes)
///     if expires_after is not None:
///         data += b"\x00" + expires_after.to_bytes(8, "big")
///     return keccak(data)
enum ActionHasher {
    static func hash(
        action: MsgPackValue,
        vaultAddress: String?,
        nonce: UInt64,
        expiresAfter: UInt64? = nil
    ) throws -> Data {
        var buf = MsgPack.pack(action)
        buf.append(contentsOf: withUnsafeBytes(of: nonce.bigEndian, Array.init))

        if let vault = vaultAddress {
            guard let addr = Data(hexString: vault) else { throw SigningError.invalidAddress(vault) }
            buf.append(0x01)
            buf.append(addr)
        } else {
            buf.append(0x00)
        }

        if let expires = expiresAfter {
            buf.append(0x00)
            buf.append(contentsOf: withUnsafeBytes(of: expires.bigEndian, Array.init))
        }

        return Data(SHA3(variant: .keccak256).calculate(for: Array(buf)))
    }
}

enum SigningError: Error, LocalizedError {
    case invalidAddress(String)
    case unknownCoin(String)

    var errorDescription: String? {
        switch self {
        case .invalidAddress(let s): return "Invalid hex address: \(s)"
        case .unknownCoin(let c):    return "Unknown coin: \(c)"
        }
    }
}
