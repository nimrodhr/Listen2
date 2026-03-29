import SwiftUI
import UniformTypeIdentifiers

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
                    // Export transcript to CSV
                    Button {
                        exportTranscriptCSV()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Export transcript to CSV")

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
                    .onChange(of: entries.last?.text) { _, _ in
                        if let lastID = entries.last?.id {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(lastID, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
    }

    // MARK: - CSV Export

    private func formatElapsed(_ elapsed: TimeInterval) -> String {
        let total = Int(elapsed)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    private func exportTranscriptCSV() {
        let header = "Timestamp,Speaker,Text"
        let rows = entries.filter { $0.isFinal }.map { entry -> String in
            let timestamp = formatElapsed(entry.elapsed)
            let speaker = entry.speaker == .me ? "You" : "Them"
            let text = csvEscape(entry.text)
            return "\(timestamp),\(speaker),\(text)"
        }
        let csv = ([header] + rows).joined(separator: "\n")

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        let timestamp = formatter.string(from: Date())

        let panel = NSSavePanel()
        panel.title = "Export Transcript"
        panel.nameFieldStringValue = "transcript_\(timestamp).csv"
        panel.allowedContentTypes = [UTType.commaSeparatedText]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try csv.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Export Failed"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }

    private func csvEscape(_ value: String) -> String {
        let needsQuoting = value.contains(",") || value.contains("\"") || value.contains("\n")
        if needsQuoting {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
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

// MARK: - Transcript Row

private struct TranscriptRow: View {
    let entry: AppState.TranscriptEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(timestamp)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .trailing)

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
        let total = Int(entry.elapsed)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
