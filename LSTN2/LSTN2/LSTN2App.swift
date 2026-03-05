import SwiftUI
import AppKit
import os.log

private let log = Logger(subsystem: "com.lstn2.app", category: "AppLifecycle")

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
                if state.isRecording {
                    state.logFrontendEvent("menubar.recording.stop")
                    if state.connectionStatus == .connected {
                        Task {
                            do {
                                try await webSocketClient.send(ClientCommand(command: .stopRecording, payload: nil))
                            } catch {
                                state.logFrontendEvent("menubar.recording.stop.failed", detail: error.localizedDescription, level: .error)
                            }
                        }
                    }
                    state.setRecording(false)
                } else {
                    // Validate API key and connection before starting
                    guard !state.settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        state.errorMessage = "API key is required. Go to Settings and enter your OpenAI API key before recording."
                        state.logFrontendEvent("menubar.recording.blocked", detail: "no api key", level: .warning)
                        return
                    }
                    guard state.connectionStatus == .connected else {
                        state.errorMessage = "Not connected to backend. Check that the backend server is running."
                        state.logFrontendEvent("menubar.recording.blocked", detail: "not connected", level: .warning)
                        return
                    }

                    state.logFrontendEvent("menubar.recording.start")
                    Task {
                        do {
                            try await webSocketClient.send(ClientCommand(command: .startRecording, payload: nil))
                        } catch {
                            state.logFrontendEvent("menubar.recording.failed", detail: error.localizedDescription, level: .error)
                        }
                    }
                }
            }

            Divider()

            Button("Quit") {
                log.info("User quit requested")
                state.logFrontendEvent("menubar.quit")
                DispatchQueue.global(qos: .userInitiated).async {
                    pythonManager.stopBackend()
                    DispatchQueue.main.async {
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
        } label: {
            Text("LSTN2")
                .font(.system(size: 7, weight: .semibold, design: .default))
        }
    }

    private func launchBackendIfNeeded() {
        do {
            try pythonManager.startBackend()
            log.info("Backend process launched successfully")
            state.logFrontendEvent("backend.launched")
            // Connection is handled by ContentView.onAppear → connectIfNeeded().
            // The WebSocketClient auto-reconnect will keep retrying until the
            // backend is ready, so no delayed connect call is needed here.
        } catch {
            log.error("Backend launch failed: \(error.localizedDescription)")
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

}
