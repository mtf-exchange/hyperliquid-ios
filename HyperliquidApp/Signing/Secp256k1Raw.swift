import Foundation
import Security
import libsecp256k1

/// Thin wrapper around the C secp256k1 context + recoverable signing /
/// recovery API. We use this instead of P256K's Swift wrappers because
/// their recoverable signing/recovery APIs take `Digest`-constrained
/// generics, and `CryptoKit.Digest` is hostile to external conformance
/// in Swift 6 (overload resolution ambiguity with CryptoSwift's `Digest`).
/// The C API takes raw bytes and Just Works.
enum Secp256k1Raw {
    private static let context: OpaquePointer = {
        // SECP256K1_CONTEXT_NONE: modern contexts are self-randomized on creation,
        // but upstream still recommends an explicit randomize call so the sign
        // routines blind scalars against side-channel leakage.
        let ctx = secp256k1_context_create(UInt32(SECP256K1_CONTEXT_NONE))!
        var seed = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, 32, &seed) == errSecSuccess {
            _ = seed.withUnsafeBufferPointer {
                secp256k1_context_randomize(ctx, $0.baseAddress!)
            }
        }
        return ctx
    }()

    enum Err: Error, LocalizedError {
        case parseFailed
        case signFailed
        case recoverFailed
        case serializeFailed
        case invalidInput(String)

        var errorDescription: String? {
            switch self {
            case .parseFailed: return "secp256k1 parse failed"
            case .signFailed: return "secp256k1 sign failed"
            case .recoverFailed: return "secp256k1 recover failed"
            case .serializeFailed: return "secp256k1 serialize failed"
            case .invalidInput(let s): return "secp256k1 invalid input: \(s)"
            }
        }
    }

    /// Sign `digest` (32 bytes already hashed) with `privateKey` (32 bytes).
    /// Returns (r:32, s:32, recoveryId: 0..3).
    static func signRecoverable(digest: Data, privateKey: Data) throws -> (r: Data, s: Data, recoveryId: Int32) {
        guard digest.count == 32 else { throw Err.invalidInput("digest must be 32 bytes") }
        guard privateKey.count == 32 else { throw Err.invalidInput("privateKey must be 32 bytes") }

        var sig = secp256k1_ecdsa_recoverable_signature()
        let signed = digest.withUnsafeBytes { d -> Int32 in
            privateKey.withUnsafeBytes { k in
                secp256k1_ecdsa_sign_recoverable(
                    context,
                    &sig,
                    d.bindMemory(to: UInt8.self).baseAddress!,
                    k.bindMemory(to: UInt8.self).baseAddress!,
                    nil, nil
                )
            }
        }
        guard signed == 1 else { throw Err.signFailed }

        var compact = [UInt8](repeating: 0, count: 64)
        var recid: Int32 = 0
        let serialized = secp256k1_ecdsa_recoverable_signature_serialize_compact(
            context, &compact, &recid, &sig
        )
        guard serialized == 1 else { throw Err.serializeFailed }

        let r = Data(compact.prefix(32))
        let s = Data(compact.suffix(32))
        return (r, s, recid)
    }

    /// Recover the 65-byte uncompressed public key (0x04-prefixed) from a
    /// pre-hashed digest + compact signature + recovery id.
    static func recoverUncompressedPubkey(digest: Data, r: [UInt8], s: [UInt8], recoveryId: Int32) throws -> Data {
        guard digest.count == 32 else { throw Err.invalidInput("digest must be 32 bytes") }
        guard r.count == 32, s.count == 32 else { throw Err.invalidInput("r/s must be 32 bytes") }

        var sig = secp256k1_ecdsa_recoverable_signature()
        let compactRS = r + s
        let parsed = compactRS.withUnsafeBufferPointer { buf in
            secp256k1_ecdsa_recoverable_signature_parse_compact(
                context, &sig, buf.baseAddress!, recoveryId
            )
        }
        guard parsed == 1 else { throw Err.parseFailed }

        var pub = secp256k1_pubkey()
        let recovered = digest.withUnsafeBytes { d -> Int32 in
            secp256k1_ecdsa_recover(
                context, &pub, &sig,
                d.bindMemory(to: UInt8.self).baseAddress!
            )
        }
        guard recovered == 1 else { throw Err.recoverFailed }

        var outBytes = [UInt8](repeating: 0, count: 65)
        var outLen = 65
        secp256k1_ec_pubkey_serialize(
            context, &outBytes, &outLen, &pub, UInt32(SECP256K1_EC_UNCOMPRESSED)
        )
        return Data(outBytes)
    }

    /// Derive the 65-byte uncompressed public key (0x04-prefixed) from a
    /// 32-byte private key.
    static func derivePubkey(privateKey: Data) throws -> Data {
        guard privateKey.count == 32 else { throw Err.invalidInput("privateKey must be 32 bytes") }
        var pub = secp256k1_pubkey()
        let ok = privateKey.withUnsafeBytes { k -> Int32 in
            secp256k1_ec_pubkey_create(
                context, &pub,
                k.bindMemory(to: UInt8.self).baseAddress!
            )
        }
        guard ok == 1 else { throw Err.signFailed }

        var outBytes = [UInt8](repeating: 0, count: 65)
        var outLen = 65
        secp256k1_ec_pubkey_serialize(
            context, &outBytes, &outLen, &pub, UInt32(SECP256K1_EC_UNCOMPRESSED)
        )
        return Data(outBytes)
    }

    /// Generate a cryptographically-random 32-byte secret scalar validated
    /// by `secp256k1_ec_seckey_verify`. Retries until libsecp256k1 accepts.
    static func randomPrivateKey() -> Data {
        while true {
            var bytes = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
            let ok = bytes.withUnsafeBufferPointer {
                secp256k1_ec_seckey_verify(context, $0.baseAddress!)
            }
            if ok == 1 { return Data(bytes) }
        }
    }
}
