import Foundation
import os.log

private let log = Logger(subsystem: "com.lstn2.app", category: "WebSocket")

final class WebSocketClient: @unchecked Sendable {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private let lock = NSLock()
    private var _task: URLSessionWebSocketTask?
    private var _session: URLSession?
    private var _lastURL: URL?
    private var _lastAPIKey: String?
    private var _intentionalDisconnect = false
    private var _reconnectWork: DispatchWorkItem?
    private var _reconnectAttempt = 0
    private var _isConnected = false
    /// Monotonically increasing ID so stale callbacks are ignored.
    private var _connectionID: UInt64 = 0

    private let maxReconnectDelay: TimeInterval = 30
    private let baseReconnectDelay: TimeInterval = 1

    var onTextMessage: ((String) -> Void)?
    var onConnectionChanged: ((Bool) -> Void)?
    var onLifecycleEvent: ((String) -> Void)?

    private var task: URLSessionWebSocketTask? {
        get { lock.withLock { _task } }
        set { lock.withLock { _task = newValue } }
    }

    private var session: URLSession? {
        get { lock.withLock { _session } }
        set { lock.withLock { _session = newValue } }
    }

    func connect(url: URL, apiKey: String?) {
        log.info("Connect requested: \(url.absoluteString)")
        onLifecycleEvent?("connect.requested \(url.absoluteString)")
        let connID: UInt64 = lock.withLock {
            _intentionalDisconnect = false
            _lastURL = url
            _lastAPIKey = apiKey
            _reconnectAttempt = 0
            _reconnectWork?.cancel()
            _reconnectWork = nil
            _connectionID += 1
            return _connectionID
        }
        performConnect(url: url, apiKey: apiKey, connID: connID)
    }

    func disconnect() {
        log.info("Intentional disconnect")
        lock.withLock {
            _intentionalDisconnect = true
            _reconnectWork?.cancel()
            _reconnectWork = nil
            _isConnected = false
        }
        let currentTask = self.task
        let currentSession = self.session
        self.task = nil
        self.session = nil
        currentTask?.cancel(with: .normalClosure, reason: nil)
        currentSession?.invalidateAndCancel()
        DispatchQueue.main.async {
            self.onConnectionChanged?(false)
            self.onLifecycleEvent?("connect.closed")
        }
    }

    func send(_ command: ClientCommand) async throws {
        guard let task else {
            log.warning("Send failed: not connected (command=\(command.command.rawValue))")
            onLifecycleEvent?("send.failed not_connected")
            throw URLError(.notConnectedToInternet)
        }

        let data = try command.toJSON()
        guard let text = String(data: data, encoding: .utf8) else {
            throw URLError(.badURL)
        }
        log.debug("Sending command: \(command.command.rawValue)")
        onLifecycleEvent?("send.command \(command.command.rawValue)")
        try await task.send(.string(text))
    }

    // MARK: - Private

    private func performConnect(url: URL, apiKey: String?, connID: UInt64) {
        // Bail out if a newer connect() call has superseded this one.
        let isCurrent: Bool = lock.withLock { _connectionID == connID }
        guard isCurrent else { return }

        // Clean up any existing connection without triggering reconnect.
        let currentTask = self.task
        let currentSession = self.session
        self.task = nil
        self.session = nil
        currentTask?.cancel(with: .normalClosure, reason: nil)
        currentSession?.invalidateAndCancel()

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 0

        let socketSession = URLSession(configuration: configuration)
        self.session = socketSession

        var request = URLRequest(url: url)
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let webSocketTask = socketSession.webSocketTask(with: request)
        self.task = webSocketTask
        webSocketTask.resume()
        onLifecycleEvent?("connect.handshake_started connID=\(connID)")

        // Verify the connection is actually alive with a ping.
        webSocketTask.sendPing { [weak self] error in
            guard let self else { return }
            // Ignore if a newer connection has been started.
            let stillCurrent: Bool = self.lock.withLock { self._connectionID == connID }
            guard stillCurrent else { return }

            DispatchQueue.main.async {
                if let error {
                    log.error("Connection ping failed: \(error.localizedDescription)")
                    self.onLifecycleEvent?("connect.ping_failed \(error.localizedDescription)")
                    self.onConnectionChanged?(false)
                    self.scheduleReconnect(connID: connID)
                } else {
                    log.info("WebSocket connected (connID=\(connID))")
                    self.onLifecycleEvent?("connect.opened connID=\(connID)")
                    self.lock.withLock {
                        self._reconnectAttempt = 0
                        self._isConnected = true
                    }
                    self.onConnectionChanged?(true)
                }
            }
        }

        receiveLoop(connID: connID)
    }

    private func receiveLoop(connID: UInt64) {
        task?.receive { [weak self] result in
            guard let self else { return }
            // Ignore if a newer connection has been started.
            let stillCurrent: Bool = self.lock.withLock { self._connectionID == connID }
            guard stillCurrent else { return }

            switch result {
            case let .success(message):
                DispatchQueue.main.async {
                    switch message {
                    case let .string(text):
                        self.onTextMessage?(text)
                    case let .data(data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.onTextMessage?(text)
                        }
                    @unknown default:
                        break
                    }
                }
                self.receiveLoop(connID: connID)

            case let .failure(error):
                DispatchQueue.main.async {
                    let wasConnected: Bool = self.lock.withLock {
                        let was = self._isConnected
                        self._isConnected = false
                        return was
                    }
                    if wasConnected {
                        log.error("WebSocket receive failed: \(error.localizedDescription)")
                        self.onConnectionChanged?(false)
                    }
                    self.onLifecycleEvent?("receive.failed \(error.localizedDescription)")
                    self.scheduleReconnect(connID: connID)
                }
            }
        }
    }

    private func scheduleReconnect(connID: UInt64) {
        let shouldReconnect: Bool = lock.withLock {
            // Only reconnect if this is still the active connection generation
            // and we haven't been intentionally disconnected.
            guard !_intentionalDisconnect, _lastURL != nil, _connectionID == connID else {
                return false
            }
            return true
        }
        guard shouldReconnect else { return }

        let (url, apiKey, attempt): (URL, String?, Int) = lock.withLock {
            let a = _reconnectAttempt
            _reconnectAttempt += 1
            return (_lastURL!, _lastAPIKey, a)
        }

        let delay = min(baseReconnectDelay * pow(2.0, Double(attempt)), maxReconnectDelay)
        log.info("Scheduling reconnect: delay=\(String(format: "%.1f", delay))s attempt=\(attempt + 1)")
        onLifecycleEvent?("reconnect.scheduled delay=\(String(format: "%.1f", delay))s attempt=\(attempt + 1)")

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Re-check before reconnecting — a new connect() call may have superseded.
            let stillCurrent: Bool = self.lock.withLock { self._connectionID == connID }
            guard stillCurrent else { return }
            self.onLifecycleEvent?("reconnect.attempting attempt=\(attempt + 1)")
            self.performConnect(url: url, apiKey: apiKey, connID: connID)
        }
        lock.withLock {
            _reconnectWork?.cancel()
            _reconnectWork = work
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
