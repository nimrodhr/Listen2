import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ActivityLogView: View {
    let entries: [AppState.ActivityEntry]

    @State private var exportMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with export button
            HStack {
                Spacer()

                if let exportMessage {
                    Text(exportMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }

                Button {
                    exportToCSV()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.caption2)
                        Text("Export CSV")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(entries.isEmpty)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)

            if entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            ActivityRow(entry: entry)
                            if entry.id != entries.last?.id {
                                Divider()
                                    .padding(.leading, 24)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 24))
                .foregroundStyle(.quaternary)
            Text("No activity yet")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func exportToCSV() {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var csv = "timestamp,level,category,message\n"
        for entry in entries.reversed() {
            let ts = dateFormatter.string(from: entry.timestamp)
            let msg = entry.message
                .replacingOccurrences(of: "\"", with: "\"\"")
            csv += "\(ts),\(entry.level.rawValue),\(entry.category),\"\(msg)\"\n"
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "lstn2-activity-\(Date().formatted(.dateTime.year().month().day())).csv"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            withAnimation { exportMessage = "Exported \(entries.count) entries" }
            Task {
                try? await Task.sleep(for: .seconds(3))
                withAnimation { exportMessage = nil }
            }
        } catch {
            withAnimation { exportMessage = "Export failed" }
            Task {
                try? await Task.sleep(for: .seconds(3))
                withAnimation { exportMessage = nil }
            }
        }
    }
}

private struct ActivityRow: View {
    let entry: AppState.ActivityEntry

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(levelColor)
                .frame(width: 6, height: 6)

            Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)

            Text(entry.category)
                .font(.caption)
                .foregroundStyle(.tertiary)

            Text("·")
                .foregroundStyle(.quaternary)

            Text(entry.message)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
    }

    private var levelColor: Color {
        switch entry.level {
        case .info: .blue.opacity(0.6)
        case .warning: .orange
        case .error: .red
        }
    }
}
