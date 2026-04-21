import Foundation
import WalletConnectRelay

/// `WebSocketFactory` implementation Reown's `Networking.configure` requires.
/// The Reown example app uses Starscream; we avoid adding that dep by
/// backing our socket with Apple's `URLSessionWebSocketTask`.
final class URLSessionWebSocketFactory: WebSocketFactory {
    func create(with url: URL) -> WebSocketConnecting {
        URLSessionWebSocket(url: url)
    }
}

/// Minimal adapter from Reown's `WebSocketConnecting` protocol to
/// `URLSessionWebSocketTask`. Reown sets callbacks and pushes strings; we
/// translate those onto the URLSession task.
final class URLSessionWebSocket: NSObject, WebSocketConnecting, URLSessionWebSocketDelegate {
    var request: URLRequest
    var isConnected: Bool = false
    var onConnect: (() -> Void)?
    var onDisconnect: ((Error?) -> Void)?
    var onText: ((String) -> Void)?

    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private let delegateQueue = OperationQueue()

    init(url: URL) {
        self.request = URLRequest(url: url)
        let config = URLSessionConfiguration.default
        let queue = OperationQueue()
        queue.qualityOfService = .utility
        self.delegateQueue.qualityOfService = .utility
        self.session = URLSession(configuration: config, delegate: nil, delegateQueue: queue)
        super.init()
    }

    func connect() {
        let newSession = URLSession(configuration: .default, delegate: self, delegateQueue: delegateQueue)
        task = newSession.webSocketTask(with: request)
        task?.resume()
        listen()
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        if isConnected {
            isConnected = false
            onDisconnect?(nil)
        }
    }

    func write(string: String, completion: (() -> Void)?) {
        task?.send(.string(string)) { error in
            if let error, let onDisconnect = self.onDisconnect {
                onDisconnect(error)
            }
            completion?()
        }
    }

    private func listen() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.isConnected = false
                self.onDisconnect?(error)
            case .success(let msg):
                switch msg {
                case .string(let str): self.onText?(str)
                case .data(let d): if let s = String(data: d, encoding: .utf8) { self.onText?(s) }
                @unknown default: break
                }
                self.listen()
            }
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        isConnected = true
        onConnect?()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        isConnected = false
        onDisconnect?(nil)
    }
}
