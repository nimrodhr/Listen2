import Foundation
import os.log

private let log = Logger(subsystem: "com.lstn2.app", category: "EventRouter")

@MainActor
final class EventRouter {
    private let state: AppState

    /// Non-Latin script regex for frontend-side English filtering (safety net).
    /// Mirrors `is_likely_english()` in backend/src/listen/utils/text_filters.py.
    private static let nonLatinPattern: NSRegularExpression = {
        // Cyrillic, Hebrew, Arabic, Devanagari, Thai, Hiragana, Katakana, CJK, Korean
        let pattern = "[\\u0400-\\u052F\\u0590-\\u05FF\\u0600-\\u06FF\\u0900-\\u097F\\u0E00-\\u0E7F\\u3040-\\u309F\\u30A0-\\u30FF\\u4E00-\\u9FFF\\uAC00-\\uD7AF]"
        return try! NSRegularExpression(pattern: pattern)
    }()

    private static func isLikelyEnglish(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        return nonLatinPattern.firstMatch(in: trimmed, range: range) == nil
    }

    init(state: AppState) {
        self.state = state
    }

    func route(text: String) {
        guard let data = text.data(using: .utf8), let envelope = EventEnvelope(jsonData: data) else {
            log.warning("Malformed event received: \(text.prefix(200))")
            state.logBackendEvent("malformed_event", detail: text, level: .warning)
            return
        }

        // Only log non-noisy events; transcript deltas/completions are too frequent.
        if envelope.event != .pong
            && envelope.event != .transcriptDelta
            && envelope.event != .transcriptCompleted
            && envelope.event != .transcriptCorrected {
            state.logBackendEvent(envelope.event.rawValue)
        }

        switch envelope.event {
        case .connected:
            state.connectionStatus = .connected
            state.logBackendEvent("connected", detail: "Backend session established")

        case .recordingState:
            let active = envelope.payload["is_recording"] as? Bool ?? false
            state.setRecording(active)
            state.logBackendEvent("recording_state", detail: active ? "recording=true" : "recording=false")

        case .transcriptDelta:
            let speaker = (envelope.payload["speaker"] as? String) == "me" ? AppState.Speaker.me : AppState.Speaker.them
            let text = envelope.payload["delta_text"] as? String ?? ""
            // Frontend safety net: filter non-English text
            guard Self.isLikelyEnglish(text) else {
                log.info("Filtered non-English delta on frontend: \(text.prefix(60))")
                return
            }
            let rawTimestamp = envelope.payload["timestamp"] as? TimeInterval ?? 0
            let elapsed = computeElapsed(rawTimestamp)
            let turnId = envelope.payload["turn_id"] as? String
            state.appendTranscript(speaker: speaker, text: text, elapsed: elapsed, isFinal: false, turnId: turnId)

        case .transcriptCompleted:
            let speaker = (envelope.payload["speaker"] as? String) == "me" ? AppState.Speaker.me : AppState.Speaker.them
            let text = envelope.payload["final_text"] as? String ?? ""
            // Frontend safety net: filter non-English text
            guard Self.isLikelyEnglish(text) else {
                log.info("Filtered non-English transcript on frontend: \(text.prefix(60))")
                // Remove any partial delta entry for this turn
                if let turnId = envelope.payload["turn_id"] as? String {
                    state.removeTranscriptByTurnId(turnId)
                }
                return
            }
            let rawTimestamp = envelope.payload["timestamp"] as? TimeInterval ?? 0
            let elapsed = computeElapsed(rawTimestamp)
            let turnId = envelope.payload["turn_id"] as? String
            state.appendTranscript(speaker: speaker, text: text, elapsed: elapsed, isFinal: true, turnId: turnId)

        case .questionDetected:
            let questionId = envelope.payload["question_id"] as? String
            let text = envelope.payload["question_text"] as? String ?? "Question"
            let categoryRaw = envelope.payload["category"] as? String ?? AppState.QuestionCategory.clarification.rawValue
            let category = AppState.QuestionCategory(rawValue: categoryRaw) ?? .clarification
            let rawTimestamp = envelope.payload["timestamp"] as? TimeInterval ?? Date().timeIntervalSince1970
            let elapsed = computeElapsed(rawTimestamp)
            state.appendQuestion(.init(backendQuestionId: questionId, question: text, elapsed: elapsed, category: category, state: .loading))

        case .questionAnswered:
            let questionId = envelope.payload["question_id"] as? String ?? ""
            let answer = envelope.payload["answer_text"] as? String ?? "Answer received"
            var sources: [AppState.SourceBadge] = []
            if let rawSources = envelope.payload["sources"] as? [[String: Any]] {
                for raw in rawSources {
                    let fileName = raw["file_name"] as? String ?? "Unknown"
                    let page = raw["page"] as? Int
                    let preview = raw["chunk_preview"] as? String ?? ""
                    sources.append(AppState.SourceBadge(fileName: fileName, page: page, preview: preview))
                }
            }
            state.updateQuestion(backendId: questionId, state: .answered(answer), sources: sources)
            let preview = String(answer.prefix(80))
            state.logBackendEvent("question.answered", detail: preview)

        case .questionNoAnswer:
            let questionId = envelope.payload["question_id"] as? String ?? ""
            let reason = envelope.payload["reason"] as? String ?? "No answer found"
            state.updateQuestion(backendId: questionId, state: .noAnswer(reason))
            state.logBackendEvent("question.no_answer", detail: reason, level: .warning)

        case .error:
            let message = envelope.payload["message"] as? String ?? "Unknown backend error"
            let component = envelope.payload["component"] as? String ?? "unknown"
            let errorCode = envelope.payload["error_code"] as? String ?? "UNKNOWN"
            log.error("Backend error [\(component)] \(errorCode): \(message)")
            state.errorMessage = message
            state.logBackendEvent("error", detail: message, level: .error)

        case .kbIngestionProgress:
            let fileName = envelope.payload["file"] as? String ?? envelope.payload["file_name"] as? String ?? "Unknown"
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
                    let id = raw["source_path"] as? String ?? raw["id"] as? String ?? UUID().uuidString
                    let name = raw["file_name"] as? String ?? "Unknown"
                    let chunks = raw["chunks"] as? Int ?? raw["chunk_count"] as? Int ?? 0
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

        case .audioDevices:
            var mics: [AppState.AudioDevice] = []
            var outputs: [AppState.AudioDevice] = []

            if let rawInputs = envelope.payload["input_devices"] as? [[String: Any]] {
                for raw in rawInputs {
                    guard let id = raw["id"] as? Int, let name = raw["name"] as? String else { continue }
                    let isBH = raw["is_blackhole"] as? Bool ?? false
                    mics.append(AppState.AudioDevice(id: id, name: name, isBlackHole: isBH))
                }
            }

            if let rawOutputs = envelope.payload["output_devices"] as? [[String: Any]] {
                for raw in rawOutputs {
                    guard let id = raw["id"] as? Int, let name = raw["name"] as? String else { continue }
                    outputs.append(AppState.AudioDevice(id: id, name: name))
                }
            }

            state.updateAvailableDevices(mics: mics, system: outputs)
            state.logBackendEvent("audio_devices", detail: "mics=\(mics.count), outputs=\(outputs.count)")

        case .settingsUpdated:
            state.logBackendEvent("settings_updated")

        case .pong:
            break  // heartbeat — no activity log noise

        case .transcriptCorrected:
            let turnId = envelope.payload["turn_id"] as? String ?? ""
            let correctedText = envelope.payload["corrected_text"] as? String ?? ""
            if !turnId.isEmpty && !correctedText.isEmpty {
                state.updateTranscriptText(turnId: turnId, text: correctedText)
            }

        case .audioSetupStatus, .activityLog, .activityLogEntry,
             .transcriptSessions, .transcriptSessionData:
            state.logBackendEvent(envelope.event.rawValue)
        }
    }

    /// Convert a Unix timestamp from the backend into seconds elapsed since recording started.
    private func computeElapsed(_ unixTimestamp: TimeInterval) -> TimeInterval {
        guard let start = state.startDate else {
            // startDate not yet set (event arrived before recordingState);
            // return 0 as a safe fallback
            return 0
        }
        let elapsed = unixTimestamp - start.timeIntervalSince1970
        return max(elapsed, 0)
    }
}
