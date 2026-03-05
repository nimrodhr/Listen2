import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ActivityLogView: View {
    let entries: [AppState.ActivityEntry]

    @State private var exportMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Page title with export button
            HStack {
                Label("Activity Log", systemImage: "list.bullet.rectangle")
                    .font(.headline)
                    .foregroundStyle(.primary)

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
            .padding(.top, 10)
            .padding(.bottom, 6)

            if entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(entries) { entry in
                            ActivityRow(entry: entry)
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
            let level = entry.level.rawValue.replacingOccurrences(of: "\"", with: "\"\"")
            let category = entry.category.replacingOccurrences(of: "\"", with: "\"\"")
            let msg = entry.message.replacingOccurrences(of: "\"", with: "\"\"")
            csv += "\"\(ts)\",\"\(level)\",\"\(category)\",\"\(msg)\"\n"
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
        HStack(alignment: .top, spacing: 8) {
            // Level indicator bar
            RoundedRectangle(cornerRadius: 1)
                .fill(levelColor)
                .frame(width: 2, height: 14)
                .padding(.top, 2)

            // Timestamp
            Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .leading)

            // Category tag
            categoryTag

            // Message
            Text(entry.message)
                .font(.caption)
                .foregroundStyle(.primary.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(rowBackground)
        )
    }

    private var categoryTag: some View {
        Text(entry.category.uppercased())
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(categoryColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(categoryColor.opacity(0.12))
            )
    }

    private var categoryColor: Color {
        switch entry.category.lowercased() {
        case "frontend":    .blue
        case "backend":     .purple
        case "recording":   .red
        case "transcription", "transcript": .green
        case "intelligence", "question":    .orange
        case "knowledge", "kb":             .teal
        case "audio":       .indigo
        case "settings":    .gray
        default:            .secondary
        }
    }

    private var levelColor: Color {
        switch entry.level {
        case .info:    .blue.opacity(0.5)
        case .warning: .orange
        case .error:   .red
        }
    }

    private var rowBackground: Color {
        switch entry.level {
        case .error:   .red.opacity(0.06)
        case .warning: .orange.opacity(0.04)
        case .info:    .clear
        }
    }
}
