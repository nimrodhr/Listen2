import Foundation

enum CommandName: String, Codable {
    case startRecording = "start_recording"
    case stopRecording = "stop_recording"
    case updateSettings = "update_settings"
    case getAudioDevices = "get_audio_devices"
    case checkAudioSetup = "check_audio_setup"
    case ingestKB = "ingest_kb"
    case removeKBSource = "remove_kb_source"
    case getKBStatus = "get_kb_status"
    case queryKB = "query_kb"
    case flushKB = "flush_kb"
    case ping
    case getActivityLog = "get_activity_log"
    case getTranscriptSessions = "get_transcript_sessions"
    case getTranscriptSession = "get_transcript_session"
}

struct ClientCommand {
    let command: CommandName
    let payload: [String: String]?

    /// Serializes to the format the Python backend expects:
    /// `{"type": "command.<name>", ...payload_fields}`
    func toJSON() throws -> Data {
        var dict: [String: String] = ["type": "command.\(command.rawValue)"]
        if let payload {
            for (key, value) in payload {
                dict[key] = value
            }
        }
        return try JSONSerialization.data(withJSONObject: dict)
    }
}

enum EventName: String {
    case connected
    case pong
    case recordingState = "recording_state"
    case transcriptDelta = "transcript.delta"
    case transcriptCompleted = "transcript.completed"
    case questionDetected = "question.detected"
    case questionAnswered = "question.answered"
    case questionNoAnswer = "question.no_answer"
    case audioDevices = "audio_devices"
    case audioSetupStatus = "audio_setup_status"
    case kbIngestionProgress = "kb.ingestion_progress"
    case kbStatus = "kb.status"
    case kbQueryResults = "kb.query_results"
    case settingsUpdated = "settings_updated"
    case error
    case activityLog = "activity_log"
    case activityLogEntry = "activity_log.entry"
    case transcriptSessions = "transcript.sessions"
    case transcriptSessionData = "transcript.session_data"
}

struct EventEnvelope {
    let event: EventName
    let payload: [String: Any]

    init?(jsonData: Data) {
        guard
            let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
            let typeString = object["type"] as? String,
            typeString.hasPrefix("event.")
        else {
            return nil
        }

        // Strip "event." prefix to get the EventName raw value
        let eventRaw = String(typeString.dropFirst("event.".count))
        guard let event = EventName(rawValue: eventRaw) else {
            return nil
        }

        self.event = event
        // The payload is the entire object minus the "type" key
        var payload = object
        payload.removeValue(forKey: "type")
        self.payload = payload
    }
}
