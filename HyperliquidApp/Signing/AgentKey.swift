import Foundation
import Security
import LocalAuthentication
import CryptoSwift

/// A locally-generated secp256k1 keypair that signs Hyperliquid L1 actions
/// (order / cancel / leverage) on behalf of the user, once the main wallet has
/// approved it via an `approveAgent` action. The 32-byte private scalar lives in
/// the Keychain behind `kSecAttrAccessControl` with `.userPresence` so every
/// signing session is gated on FaceID / TouchID / device passcode.
struct AgentKey {
    let privateKey: Data     // 32 bytes
    let publicKey: Data      // 65 bytes (uncompressed, 0x04-prefixed)
    let address: String      // 0x… 40-hex, EIP-55 checksum

    // MARK: - Generation / derivation

    static func generate() throws -> AgentKey {
        let priv = Secp256k1Raw.randomPrivateKey()
        return try fromPrivateKey(priv)
    }

    static func fromPrivateKey(_ priv: Data) throws -> AgentKey {
        let pub = try Secp256k1Raw.derivePubkey(privateKey: priv)
        guard pub.count == 65, pub.first == 0x04 else {
            throw AgentKeyError.invalidPublicKey
        }
        let address = Self.address(fromUncompressedPublicKey: pub)
        return AgentKey(privateKey: priv, publicKey: pub, address: address)
    }

    static func address(fromUncompressedPublicKey pub: Data) -> String {
        // Drop 0x04 prefix, keccak256, take last 20 bytes.
        let payload = pub.dropFirst()
        let hash = Data(SHA3(variant: .keccak256).calculate(for: Array(payload)))
        let addr = hash.suffix(20)
        return "0x" + checksum(hex: addr.hexString)
    }

    // EIP-55 checksum.
    static func checksum(hex: String) -> String {
        let lower = hex.lowercased()
        let hash = Data(SHA3(variant: .keccak256).calculate(for: Array(lower.utf8))).hexString
        var out = ""
        for (i, c) in lower.enumerated() {
            if c.isLetter {
                let hashChar = hash[hash.index(hash.startIndex, offsetBy: i)]
                out.append(Int(String(hashChar), radix: 16)! >= 8 ? Character(c.uppercased()) : c)
            } else {
                out.append(c)
            }
        }
        return out
    }

    // MARK: - Signing raw 32-byte digests (for L1 actions)

    /// Recoverable ECDSA over a 32-byte pre-hashed digest. Returns (r, s, v) with
    /// `v ∈ {27, 28}` — the convention Hyperliquid's `/exchange` expects.
    func sign(digest: Data) throws -> (r: Data, s: Data, v: UInt8) {
        guard digest.count == 32 else { throw AgentKeyError.invalidDigest }
        let sig = try Secp256k1Raw.signRecoverable(digest: digest, privateKey: privateKey)
        return (sig.r, sig.s, UInt8(27 + Int(sig.recoveryId)))
    }
}

/// Non-sensitive agent metadata — safe to cache in UserDefaults and show in UI
/// without prompting biometry. Used to answer "is trading enabled?" and
/// "how old is the agent?" cheaply.
struct AgentInfo: Codable, Equatable {
    let address: String
    let createdAt: Date

    /// How many days the approval is considered fresh. Past this, Settings nudges
    /// the user to re-run `approveAgent` and generate a new local key.
    static let rotationDays: Int = 60

    var age: TimeInterval { Date().timeIntervalSince(createdAt) }
    var daysOld: Int { Int(age / 86_400) }
    var needsRotation: Bool { daysOld >= Self.rotationDays }
}

enum AgentKeyError: Error, LocalizedError {
    case invalidPublicKey
    case invalidDigest
    case keychainSave(OSStatus)
    case keychainRead(OSStatus)
    case accessControl

    var errorDescription: String? {
        switch self {
        case .invalidPublicKey:      return "Derived public key is malformed"
        case .invalidDigest:         return "Digest must be 32 bytes"
        case .keychainSave(let s):   return "Keychain save failed (\(s))"
        case .keychainRead(let s):
            if s == errSecUserCanceled { return "Authentication canceled" }
            if s == errSecAuthFailed   { return "Authentication failed" }
            return "Keychain read failed (\(s))"
        case .accessControl:         return "Failed to build Keychain access control"
        }
    }
}

// MARK: - Keychain persistence

enum AgentKeychain {
    static let service = "exchange.mtf.hl.agent"
    static let account = "default"

    private static let infoKey = "agent.info.v2"

    /// Writes the agent's private scalar into the Keychain behind a
    /// `.userPresence` access-control object, and mirrors the public metadata
    /// (address + createdAt) into UserDefaults for cheap UI reads.
    @discardableResult
    static func save(_ key: AgentKey) throws -> AgentInfo {
        let access = try makeAccessControl()

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(baseQuery as CFDictionary)

        var add: [String: Any] = baseQuery
        add[kSecValueData as String] = key.privateKey  // raw 32 bytes — no JSON / hex wrapper
        add[kSecAttrAccessControl as String] = access
        // `kSecAttrAccessible` is implicit in the access-control object.
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw AgentKeyError.keychainSave(status) }

        let info = AgentInfo(address: key.address, createdAt: Date())
        let data = try JSONEncoder().encode(info)
        UserDefaults.standard.set(data, forKey: infoKey)
        return info
    }

    /// Non-sensitive read — no biometry prompt. Returns nil if no agent is stored.
    static func info() -> AgentInfo? {
        guard let data = UserDefaults.standard.data(forKey: infoKey),
              let info = try? JSONDecoder().decode(AgentInfo.self, from: data) else {
            return nil
        }
        return info
    }

    /// Prompts biometry (or device passcode as fallback) and returns the full
    /// AgentKey. `reuseSeconds` controls iOS's biometric reuse window — within
    /// the window, repeated Keychain hits won't re-prompt. The OS caps this at
    /// `LATouchIDAuthenticationMaximumAllowableReuseDuration` (5 min).
    static func loadKey(reason: String, reuseSeconds: TimeInterval = 300) throws -> AgentKey {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = reuseSeconds

        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
            kSecUseOperationPrompt as String: reason
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        guard status == errSecSuccess, let priv = item as? Data else {
            throw AgentKeyError.keychainRead(status)
        }
        return try AgentKey.fromPrivateKey(priv)
    }

    static func delete() {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(q as CFDictionary)
        UserDefaults.standard.removeObject(forKey: infoKey)
    }

    private static func makeAccessControl() throws -> SecAccessControl {
        var err: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            [.userPresence],
            &err
        ) else {
            throw AgentKeyError.accessControl
        }
        return access
    }
}

// MARK: - Hex helpers

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    init?(hexString raw: String) {
        var hex = raw
        if hex.hasPrefix("0x") { hex.removeFirst(2) }
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let b = UInt8(hex[idx..<next], radix: 16) else { return nil }
            data.append(b)
            idx = next
        }
        self = data
    }
}
