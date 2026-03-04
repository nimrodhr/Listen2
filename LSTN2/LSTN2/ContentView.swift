import SwiftUI

struct ContentView: View {
    enum Panel: String {
        case live
        case knowledgeBase
        case settings
        case activity
    }

    @State private var activePanel: Panel = .live

    let state: AppState
    let webSocketClient: WebSocketClient
    let eventRouter: EventRouter

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
                        systemDevices: state.availableSystemDevices,
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
                        }
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
        .sheet(isPresented: Binding(
            get: { state.showAudioSetupWizard },
            set: { state.showAudioSetupWizard = $0 }
        )) {
            AudioSetupView()
        }
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
                    }
                }
            }

            webSocketClient.onLifecycleEvent = { detail in
                Task { @MainActor in
                    state.logFrontendEvent("websocket.lifecycle", detail: detail)
                }
            }

            refreshAudioDevices()
            connectIfNeeded(reason: "view_appeared")
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
        .onChange(of: state.showAudioSetupWizard) { _, isPresented in
            state.logFrontendEvent("audio_setup.sheet", detail: isPresented ? "presented" : "dismissed")
        }
        .onDisappear {
            state.isWindowVisible = false
            state.logFrontendEvent("app.view.disappeared")
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
                if state.connectionStatus == .connected {
                    Task {
                        do {
                            try await webSocketClient.send(ClientCommand(command: .stopRecording, payload: nil))
                        } catch {
                            state.logFrontendEvent("recording.stop.send_failed", detail: error.localizedDescription, level: .error)
                        }
                    }
                }
                // Always reset the frontend state so the user is never stuck
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
            Task {
                var payload: [String: Any] = [:]
                if let micID = state.settings.micDeviceID {
                    payload["mic_device_id"] = micID
                }
                if let sysID = state.settings.systemDeviceID {
                    payload["system_device_id"] = sysID
                }
                let command = ClientCommand(command: .startRecording, payload: payload.isEmpty ? nil : payload)
                do {
                    try await webSocketClient.send(command)
                } catch {
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

        webSocketClient.connect(url: url, apiKey: state.settings.apiKey)
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
    return ContentView(state: state, webSocketClient: client, eventRouter: EventRouter(state: state))
}
