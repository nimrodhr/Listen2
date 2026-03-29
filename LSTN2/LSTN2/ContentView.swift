import AVFoundation
import SwiftUI

struct ContentView: View {
    enum Panel: String {
        case live
        case knowledgeBase
        case settings
        case activity
    }

    @State private var activePanel: Panel = .live
    @State private var systemAudioStreamTask: Task<Void, Never>?

    let state: AppState
    let webSocketClient: WebSocketClient
    let eventRouter: EventRouter
    let systemAudioCapture: SystemAudioCapture
    let micAudioCapture: MicAudioCapture
    var onRerunWizard: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            // Error banner at the very top
            if let error = state.errorMessage {
                ErrorBannerView(message: error) {
                    state.errorMessage = nil
                    state.logFrontendEvent("error_banner.dismiss")
                }
            }

            // Main header with recording control and panel icons
            headerBar
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            // Content area
            Group {
                switch activePanel {
                case .live:
                    LiveWorkspaceView(state: state)
                case .knowledgeBase:
                    KnowledgeBaseView(state: state, webSocketClient: webSocketClient)
                case .settings:
                    SettingsView(
                        settings: .init(
                            get: { state.settings },
                            set: { state.settings = $0 }
                        ),
                        micDevices: state.availableMicDevices,
                        connectionStatus: state.connectionStatus,
                        onSave: { saved in
                            let oldKey = state.settings.apiKey
                            state.settings = saved
                            let apiKeyChanged = oldKey != saved.apiKey
                            state.logFrontendEvent(
                                "settings.saved",
                                detail: apiKeyChanged ? "api_key updated" : "api_key unchanged"
                            )

                            // Sync settings to backend
                            syncSettingsToBackend()

                            // Auto-reconnect when API key changes
                            if apiKeyChanged && !saved.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                connectIfNeeded(reason: "api_key_changed")
                            }
                        },
                        onConnect: {
                            connectIfNeeded(reason: "settings.reconnect")
                        },
                        onRerunWizard: onRerunWizard
                    )
                case .activity:
                    ActivityLogView(entries: state.activity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Minimal status footer
            statusFooter
        }
        .background(Color(NSColor.windowBackgroundColor))
        .frame(minWidth: 340, idealWidth: 370, maxWidth: 420, minHeight: 700, idealHeight: 800)
        .onAppear {
            state.isWindowVisible = true
            state.logFrontendEvent("app.view.appeared")

            webSocketClient.onTextMessage = { text in
                Task { @MainActor in
                    eventRouter.route(text: text)
                }
            }

            webSocketClient.onConnectionChanged = { isConnected in
                Task { @MainActor in
                    state.connectionStatus = isConnected ? .connected : .disconnected
                    state.logFrontendEvent("websocket.connection_changed", detail: isConnected ? "connected" : "disconnected")

                    if isConnected {
                        // Fetch device list and sync settings on connect
                        try? await webSocketClient.send(ClientCommand(command: .getAudioDevices, payload: nil))
                        try? await webSocketClient.send(ClientCommand(command: .updateSettings, payload: state.settingsPayload()))
                    } else {
                        // Reset recording state when connection drops — the backend
                        // recording is gone so the frontend must not stay stuck.
                        if state.isRecording {
                            state.setRecording(false)
                            state.logFrontendEvent("recording.reset_on_disconnect", level: .warning)
                        }
                        // Reset KB loading spinner so it doesn't stay stuck
                        state.kbIsLoading = false
                    }
                }
            }

            webSocketClient.onLifecycleEvent = { detail in
                Task { @MainActor in
                    state.logFrontendEvent("websocket.lifecycle", detail: detail)
                }
            }

            refreshAudioDevices()
            if state.backendReady {
                connectIfNeeded(reason: "view_appeared")
            }
        }
        .onChange(of: state.backendReady) { _, ready in
            if ready {
                connectIfNeeded(reason: "backend_ready")
            }
        }
        .onChange(of: activePanel) { _, newValue in
            state.logFrontendEvent("panel.changed", detail: newValue.rawValue)
            if newValue == .settings {
                refreshAudioDevices()
            }
            if newValue == .knowledgeBase {
                state.kbIsLoading = true
                Task {
                    try? await webSocketClient.send(ClientCommand(command: .getKBStatus, payload: nil))
                }
            }
        }
        .onDisappear {
            state.isWindowVisible = false
            state.logFrontendEvent("app.view.disappeared")
            // Nil out WebSocket callbacks to avoid retaining stale closures
            webSocketClient.onTextMessage = nil
            webSocketClient.onConnectionChanged = nil
            webSocketClient.onLifecycleEvent = nil
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            // Connection indicator
            connectionBadge

            Spacer()

            // Panel toggle icons
            panelIcon("books.vertical", panel: .knowledgeBase, help: "Knowledge Base")
            panelIcon("gearshape", panel: .settings, help: "Settings")
            panelIcon("list.bullet.rectangle", panel: .activity, help: "Activity Log")

            // Primary action: record button
            recordButton
        }
    }

    private func panelIcon(_ systemName: String, panel: Panel, help: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                activePanel = activePanel == panel ? .live : panel
            }
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .foregroundStyle(activePanel == panel ? Color.accentColor : Color.secondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(activePanel == panel ? Color.accentColor.opacity(0.12) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var connectionBadge: some View {
        Button {
            if state.connectionStatus != .connected {
                connectIfNeeded(reason: "reconnect_button")
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 7, height: 7)

                Text(connectionLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
        }
        .buttonStyle(.plain)
        .help(state.connectionStatus != .connected ? "Click to reconnect" : "Connected to backend")
    }

    private var connectionColor: Color {
        switch state.connectionStatus {
        case .disconnected: .red.opacity(0.7)
        case .connecting: .orange
        case .connected: .green
        }
    }

    private var connectionLabel: String {
        switch state.connectionStatus {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting..."
        case .connected: "Connected"
        }
    }

    private var recordButton: some View {
        Button {
            // --- Stopping: always allowed, even if disconnected ---
            if state.isRecording {
                state.logFrontendEvent("recording.stop.requested")
                systemAudioStreamTask?.cancel()
                systemAudioStreamTask = nil
                micAudioCapture.stopCapture()
                systemAudioCapture.stopCapture()
                if state.connectionStatus == .connected {
                    Task {
                        do {
                            try await webSocketClient.send(ClientCommand(command: .stopRecording, payload: nil))
                        } catch {
                            state.logFrontendEvent("recording.stop.send_failed", detail: error.localizedDescription, level: .error)
                        }
                    }
                }
                // Always reset the frontend state so the user is never stuck,
                // even if the backend stop command fails or connection is lost.
                state.setRecording(false)
                return
            }

            // --- Starting: requires API key + backend connection ---
            if state.settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                state.errorMessage = "API key is required. Go to Settings and enter your OpenAI API key before recording."
                state.logFrontendEvent("recording.blocked", detail: "no api key", level: .warning)
                return
            }

            if state.connectionStatus != .connected {
                state.errorMessage = "Not connected to backend. Check that the backend server is running."
                state.logFrontendEvent("recording.blocked", detail: "not connected", level: .warning)
                return
            }

            state.logFrontendEvent("recording.start.requested")

            // Check system audio permission with non-blocking preflight BEFORE async work.
            // CGRequestScreenCaptureAccess() is synchronous and blocks the thread, which
            // stalls the WebSocket receive loop and causes the backend connection to drop.
            let hasSystemAudioPermission = systemAudioCapture.hasPermission()
            if !hasSystemAudioPermission {
                // Trigger the permission request on a background thread so it doesn't
                // block the main thread / WebSocket receive loop.
                Task.detached { [systemAudioCapture] in
                    _ = await systemAudioCapture.requestPermission()
                }
                state.errorMessage = "System audio permission required. Grant permission in System Settings > Privacy & Security > Screen & System Audio Recording, then restart the app."
                state.logFrontendEvent("recording.system_audio.permission_needed", level: .warning)
                return
            }

            // Validate mic device before entering async context
            guard let micID = state.settings.micDeviceID else {
                state.errorMessage = "No microphone selected. Go to Settings and choose a microphone device."
                state.logFrontendEvent("recording.blocked", detail: "no mic device", level: .warning)
                return
            }

            // Show immediate visual feedback — will be confirmed or reverted
            // once the backend responds with recordingState.
            withAnimation(.easeInOut(duration: 0.2)) {
                activePanel = .live
                state.setRecording(true)
            }

            Task {
                // Request microphone permission (needed for backend's sounddevice capture)
                // AVCaptureDevice.requestAccess is truly async and won't block.
                let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
                if !micGranted {
                    state.setRecording(false)
                    state.errorMessage = "Microphone access denied. Grant permission in System Settings > Privacy & Security > Microphone."
                    state.logFrontendEvent("recording.mic.permission_denied", level: .error)
                    return
                }

                // Set up audio streaming callbacks BEFORE starting capture.
                // Each binary frame is prefixed with a 1-byte tag so the backend
                // can route mic vs system audio to separate transcription sessions.
                let ws = webSocketClient
                systemAudioCapture.onAudioChunk = { chunk in
                    var tagged = Data([AudioFrameTag.system.rawValue])
                    tagged.append(chunk)
                    Task { try? await ws.sendBinary(tagged) }
                }
                micAudioCapture.onAudioChunk = { chunk in
                    var tagged = Data([AudioFrameTag.mic.rawValue])
                    tagged.append(chunk)
                    Task { try? await ws.sendBinary(tagged) }
                }

                // Start system audio capture via Core Audio Taps
                do {
                    try systemAudioCapture.startCapture()
                } catch {
                    state.setRecording(false)
                    state.errorMessage = "Failed to capture system audio: \(error.localizedDescription)"
                    state.logFrontendEvent("recording.system_audio.failed", detail: error.localizedDescription, level: .error)
                    return
                }

                // Start mic audio capture via AVAudioEngine (runs in-process,
                // so it inherits the app's microphone TCC permission).
                do {
                    try micAudioCapture.startCapture()
                } catch {
                    // Non-fatal: system audio still works without mic
                    state.logFrontendEvent("recording.mic_capture.failed", detail: error.localizedDescription, level: .warning)
                }

                // Send start_recording command with validated mic device
                let command = ClientCommand(command: .startRecording, payload: ["mic_device_id": micID])
                do {
                    try await webSocketClient.send(command)
                } catch {
                    // Revert optimistic state — backend never got the command
                    systemAudioCapture.stopCapture()
                    state.setRecording(false)
                    state.errorMessage = "Failed to send recording command: \(error.localizedDescription)"
                    state.logFrontendEvent("recording.request.failed", detail: error.localizedDescription, level: .error)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: state.isRecording ? "stop.fill" : "record.circle")
                    .font(.system(size: 12, weight: .bold))
                Text(state.isRecording ? "Stop" : "Record")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(state.isRecording ? Color.red : Color.accentColor)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Footer

    private var statusFooter: some View {
        HStack(spacing: 8) {
            if state.isRecording, let startDate = state.startDate {
                RecordingTimer(startDate: startDate)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.red)
            }

            Spacer()

            if activePanel == .settings {
                Button {
                    refreshAudioDevices()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption2)
                        Text("Refresh Devices")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else if activePanel == .knowledgeBase {
                Button {
                    state.kbIsLoading = true
                    Task {
                        try? await webSocketClient.send(ClientCommand(command: .getKBStatus, payload: nil))
                    }
                    state.logFrontendEvent("kb.status.refresh.requested")
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption2)
                        Text("Refresh KB Status")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else if activePanel == .live {
                HStack(spacing: 12) {
                    if !state.transcript.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "text.quote")
                                .font(.system(size: 9))
                            Text("\(state.transcript.count)")
                                .font(.caption.monospacedDigit())
                        }
                        .foregroundStyle(.tertiary)
                        .help("\(state.transcript.count) transcript entries")
                    }

                    if !state.questions.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "questionmark.bubble")
                                .font(.system(size: 9))
                            Text("\(state.questions.count)")
                                .font(.caption.monospacedDigit())
                        }
                        .foregroundStyle(.tertiary)
                        .help("\(state.questions.count) questions detected")
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(NSColor.separatorColor).opacity(0.15))
    }

    // MARK: - Actions

    private func connectIfNeeded(reason: String) {
        guard state.connectionStatus != .connected && state.connectionStatus != .connecting else {
            state.logFrontendEvent("connect.skipped", detail: "already \(state.connectionStatus)")
            return
        }

        state.connectionStatus = .connecting

        guard let url = URL(string: "ws://127.0.0.1:8765") else {
            state.errorMessage = "Invalid backend WebSocket URL"
            state.connectionStatus = .disconnected
            state.logFrontendEvent("connect.failed", detail: "invalid websocket url", level: .error)
            return
        }

        webSocketClient.connect(url: url, authToken: state.wsToken)
        state.logFrontendEvent("connect.requested", detail: "\(reason) -> \(url.absoluteString)")
    }

    private func refreshAudioDevices() {
        guard state.connectionStatus == .connected else { return }
        Task {
            try? await webSocketClient.send(ClientCommand(command: .getAudioDevices, payload: nil))
        }
        state.logFrontendEvent("audio_devices.refresh.requested")
    }

    private func syncSettingsToBackend() {
        guard state.connectionStatus == .connected else { return }
        Task {
            try? await webSocketClient.send(ClientCommand(command: .updateSettings, payload: state.settingsPayload()))
        }
        state.logFrontendEvent("settings.synced_to_backend")
    }
}

// MARK: - Recording Timer

private struct RecordingTimer: View {
    let startDate: Date

    @State private var elapsed: TimeInterval = 0

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.red)
                .frame(width: 6, height: 6)
            Text(formatted)
        }
        .task {
            elapsed = Date().timeIntervalSince(startDate)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                elapsed = Date().timeIntervalSince(startDate)
            }
        }
    }

    private var formatted: String {
        let total = Int(elapsed)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Live Workspace

private struct LiveWorkspaceView: View {
    let state: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Page title
            HStack {
                Label("Live", systemImage: "waveform")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)

            VSplitView {
                TranscriptView(
                    entries: state.transcript,
                    hiddenCount: state.hiddenTranscriptCount
                ) {
                    state.clearTranscript()
                    state.logFrontendEvent("transcript.cleared")
                }
                .frame(minHeight: 180)

            QuestionListView(questions: state.questions) { id in
                state.dismissQuestion(id: id)
                state.logFrontendEvent("question.dismissed", detail: id.uuidString)
            } onClear: {
                state.clearQuestions()
                state.logFrontendEvent("questions.cleared")
            }
                .frame(minHeight: 140)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

#Preview {
    let state = AppState()
    let client = WebSocketClient()
    ContentView(state: state, webSocketClient: client, eventRouter: EventRouter(state: state), systemAudioCapture: SystemAudioCapture(), micAudioCapture: MicAudioCapture(), onRerunWizard: nil)
}
