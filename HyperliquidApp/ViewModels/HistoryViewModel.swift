import Foundation

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published private(set) var fills: [UserFill] = []
    @Published private(set) var funding: [UserFunding] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var errorMessage: String?

    private let api: HyperliquidAPI
    private let socket: HyperliquidSocket

    private var subscribedAddress: String?

    init(api: HyperliquidAPI, socket: HyperliquidSocket) {
        self.api = api
        self.socket = socket
    }

    func refresh(address: String?) async {
        guard let address, !address.isEmpty else {
            fills = []
            funding = []
            errorMessage = "Enter a wallet address in Settings."
            return
        }
        // The WS subscriptions push a snapshot first, then stream — no REST needed.
        // We still expose `isLoading` so the UI can show a spinner until that
        // snapshot arrives.
        isLoading = true
        errorMessage = nil
        subscribeAll(for: address)
    }

    // MARK: - Live subscriptions

    private func subscribeAll(for address: String) {
        socket.on(channel: "userFills") { [weak self] data in
            guard let payload = try? JSONDecoder().decode(WsUserFills.self, from: data) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.merge(fills: payload.fills, replace: payload.isSnapshot ?? false)
                self.isLoading = false
            }
        }
        socket.on(channel: "userFundings") { [weak self] data in
            guard let payload = try? JSONDecoder().decode(WsUserFundings.self, from: data) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.merge(funding: payload.fundings, replace: payload.isSnapshot ?? false)
            }
        }

        if subscribedAddress != address {
            socket.subscribeUserFills(user: address)
            socket.subscribeUserFundings(user: address)
            subscribedAddress = address
        }
        if socket.state == .disconnected { socket.connect() }
    }

    private func merge(fills new: [UserFill], replace: Bool) {
        if replace {
            fills = new.sorted { $0.time > $1.time }
        } else {
            var combined = new + fills
            // dedupe by tid (newest wins)
            var seen = Set<Int64>()
            combined = combined.filter { seen.insert($0.tid).inserted }
            fills = combined.sorted { $0.time > $1.time }
        }
    }

    private func merge(funding new: [UserFunding], replace: Bool) {
        if replace {
            funding = new.sorted { $0.time > $1.time }
        } else {
            var combined = new + funding
            var seen = Set<String>()
            combined = combined.filter { seen.insert($0.id).inserted }
            funding = combined.sorted { $0.time > $1.time }
        }
    }

    private struct WsUserFills: Decodable {
        let user: String?
        let isSnapshot: Bool?
        let fills: [UserFill]
    }

    private struct WsUserFundings: Decodable {
        let user: String?
        let isSnapshot: Bool?
        let fundings: [UserFunding]
    }
}
