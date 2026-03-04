import Foundation

@MainActor
final class EventRouter {
    private let state: AppState

    init(state: AppState) {
        self.state = state
    }

    func route(text: String) {
        guard let data = text.data(using: .utf8), let envelope = EventEnvelope(jsonData: data) else {
            state.logBackendEvent("malformed_event", detail: text, level: .warning)
            return
        }

        state.logBackendEvent(envelope.event.rawValue)

        switch envelope.event {
        case .connected:
            state.connectionStatus = .connected
            state.logBackendEvent("connected", detail: "Backend session established")

        case .recordingState:
            let active = envelope.payload["is_recording"] as? Bool ?? false
            state.setRecording(active)
            state.logBackendEvent("recording_state", detail: active ? "recording=true" : "recording=false")

        case .transcriptDelta, .transcriptCompleted:
            let speaker = (envelope.payload["speaker"] as? String) == "me" ? AppState.Speaker.me : AppState.Speaker.them
            let text = envelope.payload["text"] as? String ?? ""
            let elapsed = envelope.payload["elapsed"] as? TimeInterval ?? 0
            let isFinal = envelope.event == .transcriptCompleted
            state.appendTranscript(speaker: speaker, text: text, elapsed: elapsed, isFinal: isFinal)

        case .questionDetected:
            let text = envelope.payload["question"] as? String ?? "Question"
            let elapsed = envelope.payload["elapsed"] as? TimeInterval ?? 0
            let categoryRaw = envelope.payload["category"] as? String ?? AppState.QuestionCategory.clarification.rawValue
            let category = AppState.QuestionCategory(rawValue: categoryRaw) ?? .clarification
            state.appendQuestion(.init(question: text, elapsed: elapsed, category: category, state: .loading))

        case .questionAnswered:
            let answer = envelope.payload["answer"] as? String ?? "Answer received"
            let preview = String(answer.prefix(80))
            state.logBackendEvent("question.answered", detail: preview)

        case .questionNoAnswer:
            let reason = envelope.payload["reason"] as? String ?? "No answer found"
            state.logBackendEvent("question.no_answer", detail: reason, level: .warning)

        case .error:
            let message = envelope.payload["message"] as? String ?? "Unknown backend error"
            state.errorMessage = message
            state.logBackendEvent("error", detail: message, level: .error)

        case .kbIngestionProgress:
            let fileName = envelope.payload["file_name"] as? String ?? "Unknown"
            let progress = envelope.payload["progress"] as? Double ?? 0.0
            state.updateIngestionProgress(fileName: fileName, progress: progress)
            state.logBackendEvent("kb.ingestion_progress", detail: "\(fileName): \(Int(progress * 100))%")

        case .kbStatus:
            let totalDocs = envelope.payload["total_documents"] as? Int ?? 0
            let totalChunks = envelope.payload["total_chunks"] as? Int ?? 0
            let health = envelope.payload["index_health"] as? String ?? "unknown"
            let embedding = envelope.payload["embedding_model"] as? String ?? ""
            let dbType = envelope.payload["vector_db_type"] as? String ?? ""

            var sources: [AppState.KBSource] = []
            if let rawSources = envelope.payload["sources"] as? [[String: Any]] {
                for raw in rawSources {
                    let id = raw["id"] as? String ?? UUID().uuidString
                    let name = raw["file_name"] as? String ?? "Unknown"
                    let chunks = raw["chunk_count"] as? Int ?? 0
                    sources.append(AppState.KBSource(id: id, fileName: name, chunkCount: chunks))
                }
            }

            state.updateKBStatus(
                sources: sources,
                totalDocuments: totalDocs,
                totalChunks: totalChunks,
                indexHealth: health,
                embeddingModel: embedding,
                vectorDBType: dbType
            )
            state.logBackendEvent("kb.status", detail: "docs=\(totalDocs), chunks=\(totalChunks), health=\(health)")

        case .kbQueryResults:
            state.logBackendEvent("kb.query_results")

        default:
            break
        }
    }
}
