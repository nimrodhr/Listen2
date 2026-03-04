import SwiftUI

struct TranscriptView: View {
    let entries: [AppState.TranscriptEntry]
    let hiddenCount: Int
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header
            HStack {
                Label("Transcript", systemImage: "text.quote")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                if !entries.isEmpty {
                    Button {
                        onClear()
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear transcript")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if entries.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        if hiddenCount > 0 {
                            Text("\(hiddenCount) older entries trimmed")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 8)
                        }

                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(entries) { entry in
                                TranscriptRow(entry: entry)
                                    .id(entry.id)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .onChange(of: entries.last?.id) { _, newID in
                        if let newID {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(newID, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 24))
                .foregroundStyle(.quaternary)
            Text("No transcript yet")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text("Start recording to see live transcription")
                .font(.caption2)
                .foregroundStyle(.quaternary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct TranscriptRow: View {
    let entry: AppState.TranscriptEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(timestamp)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 36, alignment: .trailing)

            speakerIndicator

            Text(entry.text.isEmpty ? "..." : entry.text)
                .font(.callout)
                .foregroundStyle(entry.isFinal ? .primary : .secondary)
                .opacity(entry.isFinal ? 1 : 0.7)
        }
        .padding(.vertical, 3)
    }

    private var speakerIndicator: some View {
        Text(entry.speaker == .me ? "You" : "Them")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(entry.speaker == .me ? Color.accentColor : .secondary)
            .frame(width: 32)
    }

    private var timestamp: String {
        let m = Int(entry.elapsed) / 60
        let s = Int(entry.elapsed) % 60
        return String(format: "%d:%02d", m, s)
    }
}
