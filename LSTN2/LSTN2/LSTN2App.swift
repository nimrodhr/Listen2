import SwiftUI
import AppKit
import os.log

private let log = Logger(subsystem: "com.lstn2.app", category: "AppLifecycle")

@main
struct LSTN2App: App {
    @State private var state = AppState()
    @State private var webSocketClient = WebSocketClient()
    @State private var setupState = SetupState()
    @State private var systemAudioCapture = SystemAudioCapture()
    @State private var showWizard = !SetupState.hasCompletedSetup
    @State private var isCheckingSetup = !SetupState.hasCompletedSetup
    @State private var wizardRunID = UUID()
    /// When true, the wizard was opened from Settings and should always be shown
    /// even if all checks pass (so the user can review current status).
    @State private var wizardFromSettings = false
    private let pythonManager = PythonManager()

    var body: some Scene {
        Window("LSTN2", id: "main") {
            Group {
                if showWizard {
                    if isCheckingSetup {
                        ProgressView("Checking setup...")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .id(wizardRunID)
                            .task {
                                let manager = SetupManager(state: setupState)
                                let allGood = await manager.runAllChecks()
                                if allGood && !wizardFromSettings {
                                    // Auto-dismiss only on initial launch, not when
                                    // the user explicitly re-opened the wizard.
                                    SetupState.markSetupComplete()
                                    showWizard = false
                                }
                                isCheckingSetup = false
                            }
                    } else {
                        SetupWizardView(
                            setupState: setupState,
                            setupManager: SetupManager(state: setupState),
                            onComplete: {
                                wizardFromSettings = false
                                state.settings = AppState.Settings.loadFromDisk()
                                showWizard = false
                                Task { await launchBackendAndConnect() }
                            }
                        )
                        .onAppear {
                            resizeWindowForWizard()
                        }
                    }
                } else {
                    ContentView(
                        state: state,
                        webSocketClient: webSocketClient,
                        eventRouter: EventRouter(state: state),
                        systemAudioCapture: systemAudioCapture,
                        onRerunWizard: {
                            setupState.reset()
                            wizardRunID = UUID()
                            wizardFromSettings = true
                            isCheckingSetup = true
                            showWizard = true
                        }
                    )
                    .task {
                        await launchBackendAndConnect()
                    }
                    .task {
                        // On subsequent launches, run quick checks and show error if something is missing
                        let manager = SetupManager(state: setupState)
                        let errors = await manager.runQuickChecks()
                        if let firstError = errors.first {
                            state.errorMessage = firstError
                        }
                    }
                }
            }
        }
        .defaultSize(width: 370, height: 800)
        .windowResizability(.contentMinSize)

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
                    systemAudioCapture.stopCapture()
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
                        // Request permission and set up audio streaming
                        let permitted = await systemAudioCapture.requestPermission()
                        let ws = webSocketClient
                        systemAudioCapture.onAudioChunk = { chunk in
                            Task { try? await ws.sendBinary(chunk) }
                        }
                        if permitted {
                            do {
                                try systemAudioCapture.startCapture()
                            } catch {
                                state.logFrontendEvent("menubar.recording.system_audio.failed", detail: error.localizedDescription, level: .error)
                            }
                        }
                        // Send start command
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

    private func launchBackendAndConnect() async {
        do {
            try pythonManager.startBackend()
            log.info("Backend process launched successfully")
            state.logFrontendEvent("backend.launched")
        } catch {
            log.error("Backend launch failed: \(error.localizedDescription)")
            state.logFrontendEvent("backend.launch.failed", detail: error.localizedDescription, level: .error)
            state.errorMessage = "Failed to start backend: \(error.localizedDescription)"
            return
        }

        // Wait for the backend to start accepting connections before
        // the WebSocket client connects, avoiding the noisy error-57 race.
        let ready = await pythonManager.waitUntilReady()
        if ready {
            log.info("Backend port is open, signalling ready to connect")
            state.logFrontendEvent("backend.ready")
        } else {
            log.warning("Backend did not become ready within timeout — WebSocket will retry")
            state.logFrontendEvent("backend.ready.timeout", level: .warning)
        }

        // Read the per-session WebSocket auth token generated by the backend
        let tokenPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".listen/ws_token")
        if let tokenData = try? Data(contentsOf: tokenPath),
           let token = String(data: tokenData, encoding: .utf8)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            state.wsToken = token
            log.info("WebSocket auth token loaded")
            state.logFrontendEvent("ws_token.loaded")
        } else {
            log.warning("Failed to read WebSocket auth token")
            state.logFrontendEvent("ws_token.missing", level: .warning)
        }

        state.backendReady = true
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

    private func resizeWindowForWizard() {
        guard let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue.contains("main") ?? false }) ?? NSApplication.shared.windows.first else { return }
        let wizardSize = NSSize(width: 370, height: 640)
        let currentFrame = window.frame
        // Keep the window centered at its current horizontal position, adjust height from top
        let newOrigin = NSPoint(
            x: currentFrame.origin.x,
            y: currentFrame.origin.y + currentFrame.height - wizardSize.height
        )
        window.setFrame(NSRect(origin: newOrigin, size: wizardSize), display: true, animate: true)
    }

}
