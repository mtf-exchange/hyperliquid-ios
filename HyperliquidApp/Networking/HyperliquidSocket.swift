import Foundation
import Combine

/// WebSocket client for Hyperliquid's public feed. Supports every channel the
/// UI cares about: allMids, l2Book, trades, candle, userFills, userFundings,
/// orderUpdates, openOrders, clearinghouseState, activeAssetCtx, bbo, webData2,
/// and the newer all-dex aggregated streams (`allDexsClearinghouseState`,
/// `allDexsAssetCtxs`).
///
/// Key behaviours:
///
/// - **Ref-counted subscriptions.** Multiple viewmodels can call
///   `subscribeAllMids()` independently; only the first call actually hits the
///   wire, and the server sees a single subscription until everybody unsubs.
///   This eliminates the "Already subscribed" server error spam we were seeing
///   when Home/Markets/Trade each owned a MarketsViewModel.
///
/// - **Multi-handler.** `on(channel:handler:)` returns a token; register as
///   many handlers per channel as you want, each gets called when data
///   arrives. Drop a handler with `off(channel:token:)`.
///
/// - **Auto-reconnect.** Exponential backoff on close/receive/send failure,
///   and a 90s watchdog timer that recycles the connection if the server goes
///   silent. On reopen the client replays every live subscription.
final class HyperliquidSocket: NSObject, ObservableObject {
    enum State { case disconnected, connecting, connected }

    @Published private(set) var state: State = .disconnected

    private var task: URLSessionWebSocketTask?
    private var session: URLSession!
    private var environment: HyperliquidEnvironment
    private var pingTimer: Timer?
    private var lastPongAt: Date = Date()
    private var watchdogTimer: Timer?
    private var reconnectAttempts: Int = 0
    private var reconnectWork: DispatchWorkItem?
    private var isIntentionalDisconnect: Bool = false

    /// Canonical-key → subscription payload. Used to replay subs on reconnect.
    private var activeSubscriptions: [String: [String: Any]] = [:]
    /// Canonical-key → refcount. Subscribe hits the wire only on 0→1,
    /// unsubscribe only on 1→0.
    private var subscriptionCounts: [String: Int] = [:]
    /// Channel → set of handlers keyed by token. A channel may have any
    /// number of concurrent subscribers.
    private var handlers: [String: [UUID: (Data) -> Void]] = [:]

    /// Last payload seen per channel. Replayed synchronously to any
    /// handler that registers *after* the first server emit so a late
    /// subscriber doesn't wait a full tick (Hyperliquid tick-drives
    /// `allDexsClearinghouseState` even when the account doesn't change,
    /// but there's still a few-second gap between ticks and we'd rather
    /// hand the UI the most recent snapshot the moment it asks).
    private var lastPayloads: [String: Data] = [:]

    init(environment: HyperliquidEnvironment) {
        self.environment = environment
        super.init()
        self.session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    }

    func update(environment: HyperliquidEnvironment) {
        guard environment != self.environment else { return }
        self.environment = environment
        teardownConnection(intentional: true)
        connect()
    }

    func connect() {
        guard state != .connected else { return }
        reconnectWork?.cancel()
        reconnectWork = nil
        isIntentionalDisconnect = false
        state = .connecting
        task = session.webSocketTask(with: environment.socketURL)
        task?.resume()
        listen()
        schedulePing()
        startWatchdog()
    }

    func disconnect() {
        teardownConnection(intentional: true)
        activeSubscriptions.removeAll()
        subscriptionCounts.removeAll()
        handlers.removeAll()
    }

    private func teardownConnection(intentional: Bool) {
        isIntentionalDisconnect = intentional
        pingTimer?.invalidate(); pingTimer = nil
        watchdogTimer?.invalidate(); watchdogTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .disconnected
    }

    // MARK: - Handlers

    /// Register a handler for a channel. Returns a token the caller should
    /// hold onto and pass to `off(channel:token:)` when the observer goes
    /// away. The return value is `@discardableResult` so legacy call sites
    /// that don't need fine-grained removal still compile.
    @discardableResult
    func on(channel: String, handler: @escaping (Data) -> Void) -> UUID {
        let token = UUID()
        handlers[channel, default: [:]][token] = handler
        // Replay the last payload so late subscribers don't have to wait
        // for the next server emit. Hyperliquid's low-volume channels
        // (clearinghouseState, allDexs*) only push on account change —
        // can be minutes between pushes.
        if let cached = lastPayloads[channel] {
            handler(cached)
        }
        return token
    }

    func off(channel: String, token: UUID) {
        handlers[channel]?.removeValue(forKey: token)
    }

    // MARK: - Subscriptions

    func subscribe(_ subscription: [String: Any]) {
        let key = Self.key(for: subscription)
        let prev = subscriptionCounts[key] ?? 0
        subscriptionCounts[key] = prev + 1
        if prev == 0 {
            activeSubscriptions[key] = subscription
            print("[ws] subscribe \(key) [fresh]")
            send(["method": "subscribe", "subscription": subscription])
        } else {
            print("[ws] subscribe \(key) [refcount=\(prev + 1), replaying cached]")
        }
    }

    func unsubscribe(_ subscription: [String: Any]) {
        let key = Self.key(for: subscription)
        guard let count = subscriptionCounts[key], count > 0 else { return }
        if count == 1 {
            subscriptionCounts.removeValue(forKey: key)
            activeSubscriptions.removeValue(forKey: key)
            send(["method": "unsubscribe", "subscription": subscription])
        } else {
            subscriptionCounts[key] = count - 1
        }
    }

    func subscribeAllMids() { subscribe(["type": "allMids"]) }
    func subscribeL2Book(coin: String) { subscribe(["type": "l2Book", "coin": coin]) }
    func subscribeTrades(coin: String) { subscribe(["type": "trades", "coin": coin]) }
    func subscribeOrderUpdates(user address: String) { subscribe(["type": "orderUpdates", "user": address]) }
    func subscribeOpenOrders(user address: String, dex: String = "") { subscribe(["type": "openOrders", "user": address, "dex": dex]) }
    // Per-dex `clearinghouseState` is superseded by `allDexsClearinghouseState`
    // (one subscription covers core + every HIP-3 dex). Deliberately removed
    // the helper so nobody accidentally reintroduces the pre-HIP-3 flow.
    func subscribeUserFills(user address: String, aggregateByTime: Bool = false) { subscribe(["type": "userFills", "user": address, "aggregateByTime": aggregateByTime]) }
    func subscribeUserFundings(user address: String) { subscribe(["type": "userFundings", "user": address]) }
    func subscribeActiveAssetCtx(coin: String) { subscribe(["type": "activeAssetCtx", "coin": coin]) }
    func subscribeBbo(coin: String) { subscribe(["type": "bbo", "coin": coin]) }
    func subscribeCandle(coin: String, interval: String) { subscribe(["type": "candle", "coin": coin, "interval": interval]) }

    // MARK: - HIP-3 / all-dex aggregated feeds

    /// Unified per-address clearinghouse state across the core venue and
    /// every HIP-3 deployer. One subscription replaces N per-dex
    /// `clearinghouseState` subs.
    func subscribeAllDexsClearinghouseState(user address: String) {
        subscribe(["type": "allDexsClearinghouseState", "user": address])
    }

    /// Unified per-asset contexts (mark/mid/funding/OI) across every dex.
    /// Push shape: `{ ctxs: { "<dex>": [PerpsAssetCtx] } }` keyed by dex name
    /// (core is the empty string).
    func subscribeAllDexsAssetCtxs() {
        subscribe(["type": "allDexsAssetCtxs"])
    }

    /// Live spot balances for a user. `isPortfolioMargin` toggles how the
    /// server attributes held balances in unified-margin accounts — leave it
    /// `false` unless you explicitly need the portfolio-margin view.
    /// Push shape: `{ user: string, spotState: { balances: [...] } }`.
    func subscribeSpotState(user address: String, isPortfolioMargin: Bool = false) {
        subscribe([
            "type": "spotState",
            "user": address,
            "isPortfolioMargin": isPortfolioMargin
        ])
    }

    // MARK: - Wire

    private func send(_ payload: [String: Any]) {
        guard let task,
              JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else { return }
        task.send(.string(str)) { [weak self] error in
            if let error {
                print("[socket] send error: \(error)")
                self?.scheduleReconnectIfNeeded(reason: "send")
            }
        }
    }

    private func listen() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                print("[socket] receive error: \(error)")
                self.scheduleReconnectIfNeeded(reason: "receive-failure")
            case .success(let message):
                switch message {
                case .string(let text):
                    if let data = text.data(using: .utf8) { self.dispatch(data: data) }
                case .data(let data):
                    self.dispatch(data: data)
                @unknown default: break
                }
                self.listen()
            }
        }
    }

    private func dispatch(data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else {
            if let s = String(data: data, encoding: .utf8) {
                print("[ws] non-dict frame: \(s.prefix(200))")
            }
            return
        }
        guard let channel = json["channel"] as? String else {
            print("[ws] frame missing channel: \(json.keys.sorted().joined(separator: ","))")
            return
        }
        switch channel {
        case "pong":
            lastPongAt = Date()
            return
        case "subscriptionResponse":
            if let sub = json["data"] as? [String: Any] {
                print("[ws] sub ack: \(sub)")
            }
            return
        case "error":
            if let msg = json["data"] as? String { print("[ws] server error: \(msg)") }
            return
        default:
            break
        }
        lastPongAt = Date()
        guard let payload = json["data"],
              JSONSerialization.isValidJSONObject(payload),
              let payloadData = try? JSONSerialization.data(withJSONObject: payload) else {
            print("[ws] \(channel): payload not a valid JSON object, skipped")
            return
        }
        lastPayloads[channel] = payloadData
        let hs = handlers[channel]
        print("[ws] recv channel=\(channel) bytes=\(payloadData.count) handlers=\(hs?.count ?? 0)")
        if let hs { for handler in hs.values { handler(payloadData) } }
    }

    // MARK: - Reconnect + heartbeat

    private func schedulePing() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.send(["method": "ping"])
        }
    }

    private func startWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.state == .connected, Date().timeIntervalSince(self.lastPongAt) > 90 {
                print("[socket] watchdog: no traffic for 90s, reconnecting")
                self.scheduleReconnectIfNeeded(reason: "watchdog")
            }
        }
    }

    private func scheduleReconnectIfNeeded(reason: String) {
        guard !isIntentionalDisconnect else { return }
        pingTimer?.invalidate(); pingTimer = nil
        watchdogTimer?.invalidate(); watchdogTimer = nil
        task?.cancel(with: .abnormalClosure, reason: nil)
        task = nil
        Task { @MainActor in self.state = .disconnected }

        reconnectWork?.cancel()
        reconnectAttempts += 1
        let delay = Self.backoff(attempt: reconnectAttempts)
        print("[socket] reconnect in \(delay)s (attempt \(reconnectAttempts), reason \(reason))")
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isIntentionalDisconnect else { return }
            self.reopen()
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func reopen() {
        state = .connecting
        task = session.webSocketTask(with: environment.socketURL)
        task?.resume()
        listen()
        schedulePing()
        startWatchdog()
    }

    private static func backoff(attempt: Int) -> TimeInterval {
        let capped = min(attempt, 7)
        let base = pow(2.0, Double(capped - 1))
        let capped60 = min(base, 60)
        let jitter = Double.random(in: 0.75...1.25)
        return max(1, capped60 * jitter)
    }

    private static func key(for subscription: [String: Any]) -> String {
        let ordered = subscription.keys.sorted().map { "\($0)=\(subscription[$0] ?? "")" }
        return ordered.joined(separator: "&")
    }
}

extension HyperliquidSocket: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        Task { @MainActor in
            self.state = .connected
            self.reconnectAttempts = 0
            self.lastPongAt = Date()
            print("[ws] open → replaying \(self.activeSubscriptions.count) subs")
            for sub in self.activeSubscriptions.values {
                self.send(["method": "subscribe", "subscription": sub])
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        Task { @MainActor in
            if !self.isIntentionalDisconnect {
                self.scheduleReconnectIfNeeded(reason: "close-\(closeCode.rawValue)")
            } else {
                self.state = .disconnected
            }
        }
    }
}
