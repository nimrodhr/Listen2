import SwiftUI

struct BlackHoleStepView: View {
    let state: SetupState
    let manager: SetupManager

    @State private var showInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("BlackHole Audio Driver", systemImage: "speaker.wave.2")
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
                .help("What is BlackHole?")
            }

            if showInfo {
                VStack(alignment: .leading, spacing: 8) {
                    infoRow(
                        "What it is",
                        "BlackHole is a free, open-source virtual audio driver for macOS by Existential Audio. It creates a virtual audio device that routes audio between applications."
                    )
                    infoRow(
                        "Why LSTN2 needs it",
                        "To transcribe what others say in a call, LSTN2 needs to capture system audio output. macOS doesn't allow this natively. BlackHole acts as a loopback — it takes audio going to your speakers and makes it available as an input that LSTN2 can record."
                    )
                    infoRow(
                        "What it installs",
                        "A macOS audio driver (kernel extension) at /Library/Audio/Plug-Ins/HAL/. It adds a virtual audio device called \"BlackHole 2ch\" to your system. It uses zero CPU when not in use."
                    )
                    infoRow(
                        "Is it safe?",
                        "BlackHole is widely used by audio professionals and developers. It's open-source (github.com/ExistentialAudio/BlackHole), code-signed, and notarized by Apple."
                    )
                }
                .padding(10)
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if state.blackHoleDetected {
                Label("BlackHole 2ch is installed", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)

                Text("BlackHole lets LSTN2 capture system audio — what others are saying in a call. You're all set.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("BlackHole 2ch is a free virtual audio driver that lets LSTN2 capture system audio (e.g., what others say in a meeting). It requires a quick manual installation.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Installation Steps:")
                        .font(.callout.weight(.medium))

                    instructionRow(1, "Download and install BlackHole 2ch from the link below")
                    instructionRow(2, "Open Audio MIDI Setup (in /Applications/Utilities)")
                    instructionRow(3, "Click \"+\" at bottom-left \u{2192} Create Multi-Output Device")
                    instructionRow(4, "Check both your speakers/headphones AND BlackHole 2ch")
                    instructionRow(5, "Set the Multi-Output Device as your system output")
                }

                HStack(spacing: 12) {
                    Link(destination: URL(string: "https://existential.audio/blackhole/")!) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.right.square")
                            Text("Download BlackHole 2ch")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)

                    Button("Open Audio MIDI Setup") {
                        NSWorkspace.shared.open(
                            URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app")
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button("Re-check") {
                    state.blackHoleDetected = manager.checkBlackHoleInstalled()
                    state.stepStatuses[.blackHole] = state.blackHoleDetected ? .completed : .pending
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text("You can skip this step and set it up later. BlackHole is only needed to capture system audio — microphone-only recording works without it.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
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

    private func instructionRow(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
                .font(.callout.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)
            Text(text)
                .font(.callout)
        }
    }
}
