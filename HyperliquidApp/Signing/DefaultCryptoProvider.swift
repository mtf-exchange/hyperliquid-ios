import Foundation
import CryptoSwift
import WalletConnectSign

/// `CryptoProvider` implementation Reown's stack expects at configure-time.
/// Reown uses this for EIP-191 signature verification when sessions / auth
/// requests round-trip; we plug in CryptoSwift for keccak256 and the raw
/// libsecp256k1 C API for secp256k1 public-key recovery.
final class DefaultCryptoProvider: CryptoProvider {
    func keccak256(_ data: Data) -> Data {
        Data(SHA3(variant: .keccak256).calculate(for: Array(data)))
    }

    /// `message` is the unhashed payload (e.g. EIP-191 prefixed bytes).
    /// We must keccak256 it ourselves before feeding it to ECDSA recover.
    /// Returns the **64-byte** uncompressed pubkey (no 0x04 prefix) — that's
    /// what Reown's verifier hashes to derive an Ethereum address.
    func recoverPubKey(signature: EthereumSignature, message: Data) throws -> Data {
        let digest = keccak256(message)
        let uncompressed = try Secp256k1Raw.recoverUncompressedPubkey(
            digest: digest,
            r: signature.r,
            s: signature.s,
            recoveryId: Int32(signature.v)
        )
        return uncompressed.first == 0x04 ? uncompressed.dropFirst() : uncompressed
    }
}
