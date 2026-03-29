import SwiftUI

struct AudioConfigStepView: View {
    let state: SetupState

    @State private var showInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Audio Device Configuration", systemImage: "mic")
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
                .help("Why configure audio devices?")
            }

            Text("After setup completes, select your microphone in **Settings**.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if showInfo {
                VStack(alignment: .leading, spacing: 8) {
                    infoRow(
                        "Microphone",
                        "LSTN2 uses your selected microphone to capture what you say. Choose the right device in Settings after the backend starts."
                    )
                    infoRow(
                        "System audio",
                        "System audio (what others say in calls) is captured automatically using native macOS APIs. You may be prompted to grant audio capture permission on first recording."
                    )
                }
                .padding(10)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            VStack(alignment: .leading, spacing: 10) {
                configItem(
                    icon: "mic.fill",
                    title: "Microphone",
                    description: "Select the microphone that captures your voice in Settings."
                )

                configItem(
                    icon: "speaker.wave.2.fill",
                    title: "System Audio",
                    description: "Captured automatically via native macOS audio APIs. No extra setup needed."
                )
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text("Click **Finish** to complete setup. You can configure your microphone in the Settings tab.")
                .font(.callout)
                .foregroundStyle(.primary)
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

    private func configItem(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
