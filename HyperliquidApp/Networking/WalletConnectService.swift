import Foundation
import Combine
import ReownAppKit
import WalletConnectSign

/// Thin wrapper around ReownAppKit / WalletConnectSign:
/// - configures networking + AppKit on launch with the project id
/// - presents the wallet-picker modal
/// - exposes `signTypedData(...)` so the connected wallet signs EIP-712 payloads
///
/// Replace `Self.projectId` with a real id from https://cloud.reown.com.
@MainActor
final class WalletConnectService: ObservableObject {
    static let projectId = Bundle.main.object(forInfoDictionaryKey: "REOWN_PROJECT_ID") as? String ?? ""

    @Published private(set) var connectedAddress: String?
    @Published private(set) var chainId: String = "eip155:421614"
    @Published private(set) var lastError: String?

    private var bag = Set<AnyCancellable>()
    private var pendingSign: CheckedContinuation<String, Error>?

    static let shared = WalletConnectService()

    private init() {}

    func configure() {
        guard !Self.projectId.isEmpty else {
            self.lastError = "Missing REOWN_PROJECT_ID in Info.plist"
            return
        }
        Networking.configure(
            groupIdentifier: "group.exchange.mtf.hl",
            projectId: Self.projectId,
            socketFactory: URLSessionWebSocketFactory()
        )

        // Scheme-only redirects are interceptable by any app that registers the
        // same URL scheme. Configure an `applinks:` universal link by setting
        // the UNIVERSAL_LINK_HOST build setting (e.g. `links.hyperliquid.xyz`),
        // ensuring Associated Domains points at the same host, and serving the
        // matching `/.well-known/apple-app-site-association` file.
        let universal = (Bundle.main.object(forInfoDictionaryKey: "UNIVERSAL_LINK_HOST") as? String)
            .flatMap { host in host.isEmpty ? nil : URL(string: "https://\(host)/wc") }
        let redirect: AppMetadata.Redirect
        do {
            redirect = try AppMetadata.Redirect(native: "hyperliquid://", universal: universal?.absoluteString)
        } catch {
            self.lastError = "Invalid WalletConnect redirect: \(error.localizedDescription)"
            return
        }

        let metadata = AppMetadata(
            name: "Hyperliquid",
            description: "Native iOS client for Hyperliquid perps",
            url: "https://hyperliquid.xyz",
            icons: ["https://app.hyperliquid.xyz/favicon.ico"],
            redirect: redirect
        )

        AppKit.configure(
            projectId: Self.projectId,
            metadata: metadata,
            crypto: DefaultCryptoProvider(),
            authRequestParams: nil
        )

        subscribe()
    }

    func presentConnect() {
        AppKit.present()
    }

    /// Called from `onOpenURL` so WalletConnect can resume a session initiated
    /// by a wallet-side deep link. Reown AppKit 1.8.x exposes
    /// `AppKitClient.handleDeeplink(_:)`, which inspects the URL for a
    /// link-mode `wc_ev` envelope and forwards it to
    /// `SignClient.dispatchEnvelope(_:)`; it also routes Coinbase Wallet SDK
    /// responses when that path is configured. Any failure is surfaced via
    /// `lastError` so the UI can react.
    func handle(_ url: URL) {
        if AppKit.instance.handleDeeplink(url) {
            return
        }
        // Fallback: some wallets reply with a bare `wc_ev` envelope that isn't
        // routed through AppKit (e.g. when no modal is on screen). In that
        // case, hand it straight to the Sign client.
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           components.queryItems?.contains(where: { $0.name == "wc_ev" }) == true {
            do {
                try Sign.instance.dispatchEnvelope(url.absoluteString)
            } catch {
                self.lastError = error.localizedDescription
            }
        }
    }

    func disconnect() async {
        // Clear local state no matter what — if the server-side disconnect
        // throws (e.g. session already torn down) we still want the UI to
        // reflect "not connected" and downstream observers to react.
        defer { self.connectedAddress = nil }
        for session in Sign.instance.getSessions() {
            do { try await Sign.instance.disconnect(topic: session.topic) }
            catch { self.lastError = error.localizedDescription }
        }
    }

    /// Asks the connected wallet to sign an EIP-712 v4 typed-data JSON string.
    /// Returns the signature hex (0x-prefixed, 65 bytes).
    ///
    /// Transport chain picking: the wallet rejects requests sent on a chain
    /// its session didn't negotiate permissions for (that's the infamous
    /// "invalid permissions for call" error). The EIP-712 domain inside the
    /// signed payload is self-describing (Hyperliquid uses chainId 421614
    /// regardless of the wallet's actual chain), so we send the request on
    /// whatever chain the session *did* negotiate — preferring an Arbitrum
    /// variant when available, otherwise the first authorized chain.
    func signTypedData(_ typedJSON: String) async throws -> String {
        guard let session = Sign.instance.getSessions().first,
              let account = session.accounts.first else {
            throw WalletConnectError.notConnected
        }
        let chain = Self.preferredChain(for: session) ?? account.blockchain
        let params = AnyCodable([account.address, typedJSON])
        let request = try Request(
            topic: session.topic,
            method: "eth_signTypedData_v4",
            params: params,
            chainId: chain
        )
        try await Sign.instance.request(params: request)

        return try await withCheckedThrowingContinuation { cont in
            self.pendingSign = cont
        }
    }

    /// Pick the most Hyperliquid-friendly chain the negotiated session
    /// supports. Order of preference:
    ///   1. Arbitrum Sepolia (the chain Hyperliquid's EIP-712 domain names)
    ///   2. Arbitrum One (likely what real wallets actually hold)
    ///   3. Any Ethereum-namespace chain the session advertises
    private static func preferredChain(for session: Session) -> Blockchain? {
        var candidates: [Blockchain] = []
        for ns in session.namespaces.values {
            if let chains = ns.chains { candidates.append(contentsOf: chains) }
            candidates.append(contentsOf: ns.accounts.map(\.blockchain))
        }
        // de-duplicate while preserving order
        var seen = Set<String>()
        let unique = candidates.filter { seen.insert($0.absoluteString).inserted }

        if let arbSepolia = unique.first(where: { $0.absoluteString == "eip155:421614" }) {
            return arbSepolia
        }
        if let arbOne = unique.first(where: { $0.absoluteString == "eip155:42161" }) {
            return arbOne
        }
        if let anyEth = unique.first(where: { $0.namespace == "eip155" }) {
            return anyEth
        }
        return nil
    }

    // MARK: - Subscriptions

    private func subscribe() {
        // Reown 1.8 emits (session, responses?) tuples instead of a bare Session.
        Sign.instance.sessionSettlePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.connectedAddress = event.session.accounts.first?.address
            }
            .store(in: &bag)

        Sign.instance.sessionDeletePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.connectedAddress = nil }
            .store(in: &bag)

        Sign.instance.sessionResponsePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] response in
                guard let self, let cont = self.pendingSign else { return }
                self.pendingSign = nil
                switch response.result {
                case .response(let value):
                    if let hex = try? value.get(String.self) {
                        cont.resume(returning: hex)
                    } else {
                        cont.resume(throwing: WalletConnectError.badResponse)
                    }
                case .error(let err):
                    cont.resume(throwing: err)
                }
            }
            .store(in: &bag)
    }
}

enum WalletConnectError: Error, LocalizedError {
    case notConnected
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Wallet is not connected"
        case .badResponse: return "Unexpected response from wallet"
        }
    }
}
