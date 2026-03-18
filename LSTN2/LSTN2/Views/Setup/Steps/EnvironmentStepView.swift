import SwiftUI

struct EnvironmentStepView: View {
    let state: SetupState
    let manager: SetupManager

    @State private var isInstalling = false
    @State private var expandedInfo: SetupState.EnvironmentSubStep?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Environment Setup", systemImage: "terminal")
                .font(.headline)

            // Sub-step checklist
            VStack(alignment: .leading, spacing: 0) {
                subStepRow(.uv, subtitle: "uv package manager") {
                    infoText("uv is a fast Python package manager by Astral. It manages Python versions and project dependencies. Installed to ~/.local/bin/uv (your home directory). Open-source: github.com/astral-sh/uv")
                }

                Divider().padding(.leading, 28)

                subStepRow(.python, subtitle: "Python 3.13 runtime") {
                    infoText("Python is the programming language LSTN2's backend is written in. Version 3.13 is installed and managed by uv — it does not affect any existing Python installation on your system.")
                }

                Divider().padding(.leading, 28)

                subStepRow(.deps, subtitle: "Backend libraries") {
                    depsInfoPanel
                }

                Divider().padding(.leading, 28)

                subStepRow(.blackHole, subtitle: "Virtual audio loopback") {
                    blackHoleInfoPanel
                }
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Install All button
            if !state.isEnvironmentComplete && !isInstalling {
                Button("Install All") {
                    isInstalling = true
                    Task {
                        await manager.installAll()
                        isInstalling = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }

            // Individual retry buttons for failed sub-steps
            if !isInstalling {
                failedRetryButtons
            }

            // Terminal output
            if !state.installOutput.isEmpty {
                terminalOutput
            }

            if state.isEnvironmentComplete {
                Label("Environment is ready", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            }

            if state.blackHoleNeedsReboot {
                Label("BlackHole installed — restart your Mac to activate the audio driver", systemImage: "arrow.clockwise.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if !manager.checkBrewInstalled() && state.envSubStatuses[.blackHole] != .completed {
                VStack(alignment: .leading, spacing: 4) {
                    Text("BlackHole requires Homebrew for automatic installation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Link("Install Homebrew", destination: URL(string: "https://brew.sh")!)
                            .font(.caption)
                        Text("or")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Link("Download BlackHole manually", destination: URL(string: "https://existential.audio/blackhole/")!)
                            .font(.caption)
                    }
                }
            }
        }
    }

    // MARK: - Deps Info Panel

    private var depsInfoPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            infoText("All libraries are installed inside the project's .venv folder — nothing is installed globally on your system. These are well-established, widely-used packages:")

            VStack(alignment: .leading, spacing: 6) {
                depRow(
                    name: "openai",
                    purpose: "Official OpenAI SDK — sends audio to the Realtime API for transcription and calls GPT models.",
                    trust: "By OpenAI. 25M+ monthly downloads."
                )
                depRow(
                    name: "sounddevice",
                    purpose: "Captures audio from your microphone and system loopback device.",
                    trust: "PortAudio bindings. 4M+ monthly downloads."
                )
                depRow(
                    name: "chromadb",
                    purpose: "Local vector database for the knowledge base. Stores document embeddings on disk at ~/.listen/chromadb/.",
                    trust: "By Chroma. 3M+ monthly downloads. No cloud — runs entirely locally."
                )
                depRow(
                    name: "websockets",
                    purpose: "WebSocket server for communication between this app and the Python backend.",
                    trust: "Standard Python WS library. 20M+ monthly downloads."
                )
                depRow(
                    name: "pydantic",
                    purpose: "Configuration validation and settings management.",
                    trust: "Industry standard. 200M+ monthly downloads."
                )
                depRow(
                    name: "numpy + soxr",
                    purpose: "Audio signal processing and resampling.",
                    trust: "numpy: foundational scientific computing library. 300M+ monthly downloads."
                )
                depRow(
                    name: "pypdf + docx2txt",
                    purpose: "Parse PDF and Word documents for the knowledge base.",
                    trust: "pypdf: 30M+ monthly downloads. Pure Python, no native code."
                )
                depRow(
                    name: "tiktoken",
                    purpose: "Token counting for OpenAI models — ensures prompts stay within limits.",
                    trust: "By OpenAI. 40M+ monthly downloads."
                )
                depRow(
                    name: "rank-bm25",
                    purpose: "Keyword search for the knowledge base's hybrid retrieval.",
                    trust: "Lightweight BM25 implementation. Pure Python."
                )
            }

            infoText("All packages are pinned to specific versions in the project's lock file, ensuring reproducible installs. Source code for every dependency is publicly auditable on PyPI and GitHub.")
        }
    }

    private var blackHoleInfoPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            infoText("BlackHole is a free, open-source virtual audio driver for macOS by Existential Audio. It creates a virtual audio device that routes audio between applications.")
            infoText("LSTN2 needs it to capture system audio output (what others say in a call). macOS doesn't allow this natively — BlackHole acts as a loopback device.")
            infoText("It installs a macOS audio driver at /Library/Audio/Plug-Ins/HAL/. Uses zero CPU when not in use. Code-signed and notarized by Apple.")
            if !manager.checkBrewInstalled() {
                infoText("Automatic installation requires Homebrew. You can install Homebrew from brew.sh, or download BlackHole manually from existential.audio/blackhole.")
            }
            infoText("BlackHole is optional — microphone-only recording works without it. A restart may be required after installation to activate the audio driver.")
        }
    }

    private func depRow(name: String, purpose: String, trust: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.caption.weight(.semibold).monospaced())
            Text(purpose)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(trust)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func infoText(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Sub-step Row

    private func subStepRow<InfoContent: View>(_ subStep: SetupState.EnvironmentSubStep, subtitle: String, @ViewBuilder info: () -> InfoContent) -> some View {
        let infoContent = info()
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                subStepIcon(subStep)
                    .frame(width: 16, height: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(subStep.title)
                        .font(.callout.weight(.medium))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        expandedInfo = expandedInfo == subStep ? nil : subStep
                    }
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(expandedInfo == subStep ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 8)

            if expandedInfo == subStep {
                infoContent
                    .padding(.leading, 24)
                    .padding(.trailing, 4)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private func subStepIcon(_ subStep: SetupState.EnvironmentSubStep) -> some View {
        let status = state.envSubStatuses[subStep] ?? .pending
        if subStep == .blackHole && state.blackHoleNeedsReboot && status == .completed {
            Image(systemName: "arrow.clockwise.circle.fill")
                .foregroundStyle(.orange)
        } else {
            switch status {
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            case .inProgress, .checking:
                ProgressView()
                    .controlSize(.mini)
            case .pending:
                Image(systemName: "circle")
                    .foregroundStyle(.gray.opacity(0.4))
            case .skipped:
                Image(systemName: "minus.circle")
                    .foregroundStyle(.gray)
            }
        }
    }

    @ViewBuilder
    private var failedRetryButtons: some View {
        let failedSubs = SetupState.EnvironmentSubStep.allCases.filter {
            if case .failed = state.envSubStatuses[$0] { return true }
            return false
        }

        if !failedSubs.isEmpty {
            HStack(spacing: 8) {
                ForEach(failedSubs, id: \.rawValue) { sub in
                    Button("Retry \(sub.title)") {
                        isInstalling = true
                        Task {
                            switch sub {
                            case .uv: _ = await manager.installUv()
                            case .python: _ = await manager.installPython()
                            case .deps: _ = await manager.installBackendDeps()
                            case .blackHole: _ = await manager.installBlackHole()
                            }
                            if state.isEnvironmentComplete {
                                state.stepStatuses[.environment] = .completed
                            }
                            isInstalling = false
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private var terminalOutput: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(state.installOutput)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .id("output-bottom")
            }
            .frame(maxHeight: 180)
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.2)))
            .onChange(of: state.installOutput) {
                proxy.scrollTo("output-bottom", anchor: .bottom)
            }
        }
    }
}
