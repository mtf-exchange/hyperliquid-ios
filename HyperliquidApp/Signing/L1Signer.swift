import Foundation
import CryptoSwift

/// Signs Hyperliquid L1 actions (order/cancel/leverage/…) with the local
/// agent key. The EIP-712 payload is:
///
///     domain  = { name: "Exchange", version: "1",
///                 chainId: 1337, verifyingContract: 0x0…0 }
///     types   = { Agent: [source:string, connectionId:bytes32] }
///     message = { source: "a" if mainnet else "b",
///                 connectionId: action_hash }
///
/// We compute the 0x1901-prefixed digest ourselves (since we're not round-tripping
/// through a wallet) and feed it to `AgentKey.sign`.
enum L1Signer {
    static func sign(
        action: MsgPackValue,
        agent: AgentKey,
        isMainnet: Bool,
        nonce: UInt64,
        vaultAddress: String? = nil,
        expiresAfter: UInt64? = nil
    ) throws -> HyperliquidExchangeAPI.Signature {
        let connectionId = try ActionHasher.hash(
            action: action,
            vaultAddress: vaultAddress,
            nonce: nonce,
            expiresAfter: expiresAfter
        )
        let source = isMainnet ? "a" : "b"
        let digest = try eip712Digest(source: source, connectionId: connectionId)
        let (r, s, v) = try agent.sign(digest: digest)
        return HyperliquidExchangeAPI.Signature(
            r: "0x" + r.hexString,
            s: "0x" + s.hexString,
            v: Int(v)
        )
    }

    // MARK: - EIP-712 hashing (manual, so no wallet roundtrip)

    private static let domainTypehash: Data = {
        let type = "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        return keccak(Data(type.utf8))
    }()

    private static let agentTypehash: Data = {
        let type = "Agent(string source,bytes32 connectionId)"
        return keccak(Data(type.utf8))
    }()

    private static let domainSeparator: Data = {
        let nameHash = keccak(Data("Exchange".utf8))
        let versionHash = keccak(Data("1".utf8))
        var buf = Data()
        buf.append(domainTypehash)
        buf.append(nameHash)
        buf.append(versionHash)
        buf.append(uint256(1337))
        buf.append(address("0x0000000000000000000000000000000000000000"))
        return keccak(buf)
    }()

    private static func eip712Digest(source: String, connectionId: Data) throws -> Data {
        precondition(connectionId.count == 32)
        let sourceHash = keccak(Data(source.utf8))
        var structBuf = Data()
        structBuf.append(agentTypehash)
        structBuf.append(sourceHash)
        structBuf.append(connectionId)
        let structHash = keccak(structBuf)

        var buf = Data([0x19, 0x01])
        buf.append(domainSeparator)
        buf.append(structHash)
        return keccak(buf)
    }

    // MARK: - Encoding helpers

    private static func keccak(_ data: Data) -> Data {
        Data(SHA3(variant: .keccak256).calculate(for: Array(data)))
    }

    private static func uint256(_ v: UInt64) -> Data {
        var d = Data(count: 32)
        let be = withUnsafeBytes(of: v.bigEndian, Array.init)
        d.replaceSubrange(24..<32, with: be)
        return d
    }

    private static func address(_ hex: String) -> Data {
        var d = Data(count: 32)
        if let bytes = Data(hexString: hex), bytes.count == 20 {
            d.replaceSubrange(12..<32, with: bytes)
        }
        return d
    }
}
