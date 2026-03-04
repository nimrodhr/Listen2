import SwiftUI

struct SettingsView: View {
    @Binding var settings: AppState.Settings
    let micDevices: [AppState.AudioDevice]
    let systemDevices: [AppState.AudioDevice]
    let connectionStatus: AppState.ConnectionStatus
    let onSave: (AppState.Settings) -> Void
    let onConnect: () -> Void

    @State private var draft: AppState.Settings
    @State private var showAPIKey = false
    @FocusState private var isAPIKeyFocused: Bool

    init(
        settings: Binding<AppState.Settings>,
        micDevices: [AppState.AudioDevice],
        systemDevices: [AppState.AudioDevice],
        connectionStatus: AppState.ConnectionStatus,
        onSave: @escaping (AppState.Settings) -> Void,
        onConnect: @escaping () -> Void
    ) {
        _settings = settings
        _draft = State(initialValue: settings.wrappedValue)
        self.micDevices = micDevices
        self.systemDevices = systemDevices
        self.connectionStatus = connectionStatus
        self.onSave = onSave
        self.onConnect = onConnect
    }

    var body: some View {
        VStack(spacing: 0) {
            // Page title
            HStack {
                Label("Settings", systemImage: "gearshape")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)

            ScrollView {
                VStack(spacing: 0) {
                    openAISection
                    audioSection
                    backendSection
                }
            }

            saveBar
        }
        .animation(.easeInOut(duration: 0.2), value: hasChanges)
        .onChange(of: settings) { _, newValue in
            draft = newValue
        }
        .onChange(of: micDevices) { _, newValue in
            guard !newValue.isEmpty else { return }
            if let currentID = draft.micDeviceID, !newValue.contains(where: { $0.id == currentID }) {
                draft.micDeviceID = newValue.first?.id
            } else if draft.micDeviceID == nil {
                draft.micDeviceID = newValue.first?.id
            }
        }
        .onChange(of: systemDevices) { _, newValue in
            guard !newValue.isEmpty else { return }
            if let currentID = draft.systemDeviceID, !newValue.contains(where: { $0.id == currentID }) {
                draft.systemDeviceID = newValue.first?.id
            } else if draft.systemDeviceID == nil {
                draft.systemDeviceID = newValue.first?.id
            }
        }
    }

    // MARK: - OpenAI Section

    private var openAISection: some View {
        SettingsSection("OpenAI") {
            apiKeyRow
            Divider()
            transcriptionRow
            Divider()
            qaModelRow
        }
    }

    private var apiKeyRow: some View {
        SettingsRow("API Key") {
            if showAPIKey {
                apiKeyPeekView
            } else {
                apiKeyEditView
            }
        }
    }

    private var apiKeyPeekView: some View {
        HStack(spacing: 8) {
            if draft.apiKey.isEmpty {
                Text("Not set")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(maskedAPIKey)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button("Hide") { showAPIKey = false }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(Color.accentColor)
        }
        .frame(height: 22)
    }

    private var apiKeyEditView: some View {
        HStack(spacing: 8) {
            SecureField("Enter your OpenAI API key", text: $draft.apiKey)
                .textFieldStyle(.roundedBorder)
                .focused($isAPIKeyFocused)

            Button("Peek") { showAPIKey = true }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .disabled(draft.apiKey.isEmpty)
        }
        .frame(height: 22)
    }

    private var transcriptionRow: some View {
        SettingsRow("Transcription") {
            Picker("", selection: $draft.transcriptionModel) {
                Text("gpt-4o-transcribe").tag("gpt-4o-transcribe")
                Text("gpt-4o-mini-transcribe").tag("gpt-4o-mini-transcribe")
            }
            .labelsHidden()
        }
    }

    private var qaModelRow: some View {
        SettingsRow("Q&A Model") {
            Picker("", selection: $draft.qaModel) {
                Text("gpt-4o-mini").tag("gpt-4o-mini")
                Text("gpt-4o").tag("gpt-4o")
            }
            .labelsHidden()
        }
    }

    // MARK: - Audio Section

    private var audioSection: some View {
        SettingsSection("Audio Devices") {
            micRow
            Divider()
            loopbackRow
        }
    }

    private var micRow: some View {
        SettingsRow("Microphone") {
            Picker("", selection: $draft.micDeviceID) {
                if micDevices.isEmpty {
                    Text("No input devices").tag(nil as Int?)
                } else {
                    ForEach(micDevices) { device in
                        Text(device.name).tag(device.id as Int?)
                    }
                }
            }
            .labelsHidden()
        }
    }

    private var loopbackRow: some View {
        SettingsRow("Loopback") {
            Picker("", selection: $draft.systemDeviceID) {
                if systemDevices.isEmpty {
                    Text("No output devices").tag(nil as Int?)
                } else {
                    ForEach(systemDevices) { device in
                        Text(device.name).tag(device.id as Int?)
                    }
                }
            }
            .labelsHidden()
        }
    }

    // MARK: - Backend Section

    private var backendSection: some View {
        SettingsSection("Backend") {
            SettingsRow("Connection") {
                HStack(spacing: 8) {
                    Circle()
                        .fill(backendStatusColor)
                        .frame(width: 7, height: 7)

                    Text(backendStatusLabel)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    if connectionStatus != .connected {
                        Button("Reconnect") { onConnect() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private var backendStatusColor: Color {
        switch connectionStatus {
        case .disconnected: .red.opacity(0.7)
        case .connecting: .orange
        case .connected: .green
        }
    }

    private var backendStatusLabel: String {
        switch connectionStatus {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        }
    }

    // MARK: - Save Bar

    @ViewBuilder
    private var saveBar: some View {
        if hasChanges {
            HStack {
                Text("Unsaved changes")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Revert") { draft = settings }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button("Save") {
                    isAPIKeyFocused = false
                    settings = draft
                    onSave(draft)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var hasChanges: Bool {
        draft != settings
    }

    private var maskedAPIKey: String {
        let key = draft.apiKey
        guard key.count > 6 else {
            return String(repeating: "•", count: key.count)
        }
        let masked = String(repeating: "•", count: key.count - 6)
        let suffix = String(key.suffix(6))
        return masked + suffix
    }
}

// MARK: - Settings Layout Components

private struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.caption.weight(.medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 6)

            VStack(spacing: 0) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)

            Divider()
        }
    }
}

private struct SettingsRow<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.primary)

            Spacer()

            content
        }
        .padding(.vertical, 6)
    }
}
