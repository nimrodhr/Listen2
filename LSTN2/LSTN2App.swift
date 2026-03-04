import SwiftUI
import AppKit

@main
struct LSTN2App: App {
    @State private var state = AppState()
    @State private var webSocketClient = WebSocketClient()
    private let pythonManager = PythonManager()

    var body: some Scene {
        Window("LSTN2", id: "main") {
            ContentView(
                state: state,
                webSocketClient: webSocketClient,
                eventRouter: EventRouter(state: state)
            )
            .onAppear {
                launchBackendIfNeeded()
            }
        }
        .defaultSize(width: 370, height: 800)
        .windowResizability(.contentSize)

        MenuBarExtra {
            Button(state.isWindowVisible ? "Hide Window" : "Show Window") {
                if state.isWindowVisible {
                    hideMainWindow()
                    state.logFrontendEvent("menubar.hide_window")
                } else {
                    showMainWindow()
                    state.logFrontendEvent("menubar.show_window")
                }
            }

            Divider()

            Button(state.isRecording ? "Stop Recording" : "Start Recording") {
                state.logFrontendEvent(state.isRecording ? "menubar.recording.stop" : "menubar.recording.start")
                Task {
                    let command: ClientCommand = state.isRecording
                        ? .init(command: .stopRecording, payload: nil)
                        : .init(command: .startRecording, payload: nil)
                    do {
                        try await webSocketClient.send(command)
                    } catch {
                        state.logFrontendEvent("menubar.recording.failed", detail: error.localizedDescription, level: .error)
                    }
                }
            }

            Button("Connect Backend") {
                connectBackend()
            }

            Divider()

            Button("Quit") {
                state.logFrontendEvent("menubar.quit")
                pythonManager.stopBackend()
                NSApplication.shared.terminate(nil)
            }
        } label: {
            Text("LSTN2")
                .font(.system(size: 7, weight: .semibold, design: .default))
        }
    }

    private func launchBackendIfNeeded() {
        do {
            try pythonManager.startBackend()
            state.logFrontendEvent("backend.launched")

            // Give the server a moment to start, then connect
            Task {
                try? await Task.sleep(for: .seconds(2))
                await MainActor.run {
                    connectBackend()
                }
            }
        } catch {
            state.logFrontendEvent("backend.launch.failed", detail: error.localizedDescription, level: .error)
            state.errorMessage = "Failed to start backend: \(error.localizedDescription)"
        }
    }

    private func showMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let window = NSApplication.shared.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
        state.isWindowVisible = true
    }

    private func hideMainWindow() {
        NSApplication.shared.windows.forEach { $0.orderOut(nil) }
        state.isWindowVisible = false
    }

    private func connectBackend() {
        guard state.connectionStatus != .connected else {
            state.logFrontendEvent("menubar.connect.skipped", detail: "already connected")
            return
        }

        guard let url = URL(string: "ws://127.0.0.1:8765") else {
            state.logFrontendEvent("menubar.connect.failed", detail: "invalid websocket url", level: .error)
            return
        }

        state.connectionStatus = .connecting
        webSocketClient.connect(url: url, apiKey: state.settings.apiKey)
        state.logFrontendEvent("menubar.connect.requested", detail: url.absoluteString)
    }
}
