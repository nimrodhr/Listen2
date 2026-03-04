import Foundation

final class WebSocketClient {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?

    var onTextMessage: ((String) -> Void)?
    var onConnectionChanged: ((Bool) -> Void)?
    var onLifecycleEvent: ((String) -> Void)?

    func connect(url: URL, apiKey: String?) {
        onLifecycleEvent?("connect.requested \(url.absoluteString)")
        disconnect()

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
        onLifecycleEvent?("connect.handshake_started")

        // Verify the connection is actually alive with a ping
        webSocketTask.sendPing { [weak self] error in
            guard let self else { return }
            if let error {
                self.onLifecycleEvent?("connect.ping_failed \(error.localizedDescription)")
                self.onConnectionChanged?(false)
            } else {
                self.onLifecycleEvent?("connect.opened")
                self.onConnectionChanged?(true)
            }
        }

        receiveLoop()
    }

    func disconnect() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        onConnectionChanged?(false)
        onLifecycleEvent?("connect.closed")
    }

    func send(_ command: ClientCommand) async throws {
        guard let task else {
            onLifecycleEvent?("send.failed not_connected")
            throw URLError(.notConnectedToInternet)
        }

        let data = try command.toJSON()
        guard let text = String(data: data, encoding: .utf8) else {
            throw URLError(.badURL)
        }
        onLifecycleEvent?("send.command \(command.command.rawValue)")
        try await task.send(.string(text))
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case let .success(message):
                switch message {
                case let .string(text):
                    self.onTextMessage?(text)
                    self.onLifecycleEvent?("receive.string")
                case let .data(data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.onTextMessage?(text)
                    }
                    self.onLifecycleEvent?("receive.data")
                @unknown default:
                    break
                }
                self.receiveLoop()

            case let .failure(error):
                self.onConnectionChanged?(false)
                self.onLifecycleEvent?("receive.failed \(error.localizedDescription)")
            }
        }
    }
}
