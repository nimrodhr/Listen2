import SwiftUI

struct APIKeyStepView: View {
    let state: SetupState
    let manager: SetupManager

    @State private var showKey = false
    @State private var showInfo = false
    @FocusState private var isKeyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("OpenAI API Key", systemImage: "key")
                    .font(.headline)

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showInfo.toggle()
                    }
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(showInfo ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help("Why is this needed?")
            }

            Text("LSTN2 uses OpenAI for real-time transcription and AI-powered question detection. You need an API key from your OpenAI account.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if showInfo {
                VStack(alignment: .leading, spacing: 8) {
                    infoRow(
                        "What it's used for",
                        "Your API key authenticates requests to OpenAI's services: real-time speech-to-text transcription, question detection from conversation, and AI-generated answers from your knowledge base."
                    )
                    infoRow(
                        "Where it's stored",
                        "Locally at ~/.listen/settings.json with file permissions 600 (only your user can read it). The key never leaves your machine except when sent directly to OpenAI's API over HTTPS."
                    )
                    infoRow(
                        "Cost",
                        "OpenAI charges per usage. Transcription uses the Realtime API; Q&A uses GPT-4o-mini by default. You control spending via your OpenAI account dashboard."
                    )
                }
                .padding(10)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if state.stepStatuses[.apiKey] == .completed {
                Label("API key saved", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            }

            if case .failed(let error) = state.stepStatuses[.apiKey] {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            // Key input
            HStack(spacing: 8) {
                if showKey {
                    TextField("sk-...", text: Binding(
                        get: { state.apiKeyInput },
                        set: { state.apiKeyInput = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .focused($isKeyFocused)
                } else {
                    SecureField("Paste your OpenAI API key", text: Binding(
                        get: { state.apiKeyInput },
                        set: { state.apiKeyInput = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .focused($isKeyFocused)
                }

                Button(showKey ? "Hide" : "Show") {
                    showKey.toggle()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }

            HStack(spacing: 12) {
                Button("Save API Key") {
                    isKeyFocused = false
                    _ = manager.saveAPIKey(state.apiKeyInput)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(state.apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Link("Get an API key", destination: URL(string: "https://platform.openai.com/api-keys")!)
                    .font(.callout)
            }
        }
    }

    private func infoRow(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
