import SwiftUI
import UniformTypeIdentifiers

struct KnowledgeBaseView: View {
    let state: AppState
    let webSocketClient: WebSocketClient

    @State private var showFlushConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            // Page title
            HStack {
                Label("Knowledge Base", systemImage: "books.vertical")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)

            ScrollView {
                VStack(spacing: 0) {
                    statusSection
                    vectorDBSection
                    ingestSection
                    sourcesSection
                    dangerSection
                }
            }
        }
        .onAppear {
            requestKBStatus()
        }
        .alert("Flush Knowledge Base?", isPresented: $showFlushConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Flush All Data", role: .destructive) {
                flushKB()
            }
        } message: {
            Text("This will permanently remove all documents and vectors from the knowledge base. This action cannot be undone.")
        }
    }

    // MARK: - Status Section

    private var statusSection: some View {
        KBSection("Status") {
            if state.kbIsLoading {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading KB status...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                KBRow("Documents") {
                    Text("\(state.kbStatus.totalDocuments)")
                        .font(.callout.monospacedDigit())
                }
                Divider().padding(.leading, 112)
                KBRow("Chunks") {
                    Text("\(state.kbStatus.totalChunks)")
                        .font(.callout.monospacedDigit())
                }
                Divider().padding(.leading, 112)
                KBRow("Health") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(healthColor)
                            .frame(width: 7, height: 7)
                        Text(state.kbStatus.indexHealth.capitalized)
                            .font(.callout)
                    }
                }
                if let lastUpdated = state.kbStatus.lastUpdated {
                    Divider().padding(.leading, 112)
                    KBRow("Updated") {
                        Text(lastUpdated.formatted(date: .abbreviated, time: .shortened))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var healthColor: Color {
        switch state.kbStatus.indexHealth {
        case "healthy": .green
        case "degraded": .orange
        case "empty": .gray
        default: .gray.opacity(0.5)
        }
    }

    // MARK: - Vector DB Section

    private var vectorDBSection: some View {
        KBSection("Vector Database") {
            KBRow("DB Type") {
                Text(state.kbStatus.vectorDBType.isEmpty ? "N/A" : state.kbStatus.vectorDBType)
                    .font(.callout)
            }
            Divider().padding(.leading, 112)
            KBRow("Embedding") {
                Text(state.kbStatus.embeddingModel.isEmpty ? "N/A" : state.kbStatus.embeddingModel)
                    .font(.callout)
            }
        }
    }

    // MARK: - Ingest Section

    private var ingestSection: some View {
        KBSection("Ingest Documents") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Add documents to the knowledge base for context-aware Q&A during meetings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    pickAndIngestFiles()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.badge.plus")
                        Text("Choose Files...")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(state.connectionStatus != .connected)

                if let progress = state.kbIngestionProgress,
                   let fileName = state.kbIngestionFileName {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Ingesting: \(fileName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ProgressView(value: progress, total: 1.0)
                            .progressViewStyle(.linear)
                        Text("\(Int(progress * 100))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Sources Section

    private var sourcesSection: some View {
        KBSection("Sources (\(state.kbSources.count))") {
            if state.kbSources.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 20))
                        .foregroundStyle(.quaternary)
                    Text("No sources in knowledge base")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                ForEach(state.kbSources) { source in
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.fileName)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("\(source.chunkCount) chunks")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }

                        Spacer()

                        Button {
                            removeSource(id: source.id)
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                                .foregroundStyle(.red.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                        .help("Remove this source")
                    }
                    .padding(.vertical, 4)

                    if source.id != state.kbSources.last?.id {
                        Divider().padding(.leading, 28)
                    }
                }
            }
        }
    }

    // MARK: - Danger Section

    private var dangerSection: some View {
        KBSection("Danger Zone") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Flush Knowledge Base")
                        .font(.callout.weight(.medium))
                    Text("Remove all documents and reset the vector index.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Flush All") {
                    showFlushConfirmation = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .disabled(state.connectionStatus != .connected || state.kbSources.isEmpty)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Actions

    private func requestKBStatus() {
        guard state.connectionStatus == .connected else { return }
        state.kbIsLoading = true
        Task {
            do {
                try await webSocketClient.send(ClientCommand(command: .getKBStatus, payload: nil))
                state.logFrontendEvent("kb.status.requested")
            } catch {
                state.kbIsLoading = false
                state.logFrontendEvent("kb.status.request.failed", detail: error.localizedDescription, level: .error)
            }
        }
    }

    private func pickAndIngestFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            .pdf,
            .plainText,
            UTType(filenameExtension: "md") ?? .plainText,
            UTType("org.openxmlformats.wordprocessingml.document") ?? .data
        ]
        panel.message = "Select documents to add to the knowledge base"

        guard panel.runModal() == .OK else { return }

        let paths = panel.urls.map { $0.path }
        state.logFrontendEvent("kb.ingest.files_selected", detail: "\(paths.count) files")

        for path in paths {
            Task {
                do {
                    try await webSocketClient.send(
                        ClientCommand(command: .ingestKB, payload: ["file_path": path])
                    )
                    state.logFrontendEvent("kb.ingest.sent", detail: path)
                } catch {
                    state.logFrontendEvent("kb.ingest.failed", detail: error.localizedDescription, level: .error)
                    state.errorMessage = "Failed to ingest file: \(error.localizedDescription)"
                }
            }
        }
    }

    private func removeSource(id: String) {
        Task {
            do {
                try await webSocketClient.send(
                    ClientCommand(command: .removeKBSource, payload: ["source_path": id])
                )
                state.removeKBSource(id: id)
                state.logFrontendEvent("kb.source.removed", detail: id)
            } catch {
                state.logFrontendEvent("kb.source.remove.failed", detail: error.localizedDescription, level: .error)
                state.errorMessage = "Failed to remove source: \(error.localizedDescription)"
            }
        }
    }

    private func flushKB() {
        Task {
            do {
                try await webSocketClient.send(
                    ClientCommand(command: .flushKB, payload: nil)
                )
                state.clearKB()
                state.logFrontendEvent("kb.flushed")
            } catch {
                state.logFrontendEvent("kb.flush.failed", detail: error.localizedDescription, level: .error)
                state.errorMessage = "Failed to flush knowledge base: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - KB Layout Components

private struct KBSection<Content: View>: View {
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

private struct KBRow<Content: View>: View {
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
                .frame(width: 96, alignment: .trailing)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
    }
}
