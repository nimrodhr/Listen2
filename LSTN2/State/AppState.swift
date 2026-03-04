import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    enum ConnectionStatus: String {
        case disconnected
        case connecting
        case connected
    }

    enum Speaker: String, Codable {
        case me
        case them
    }

    enum QuestionCategory: String, Codable {
        case factual
        case opinion
        case clarification
        case actionItem = "action_item"
    }

    struct TranscriptEntry: Identifiable, Hashable {
        let id: UUID
        let speaker: Speaker
        var text: String
        let elapsed: TimeInterval
        var isFinal: Bool

        init(id: UUID = UUID(), speaker: Speaker, text: String, elapsed: TimeInterval, isFinal: Bool) {
            self.id = id
            self.speaker = speaker
            self.text = text
            self.elapsed = elapsed
            self.isFinal = isFinal
        }
    }

    struct SourceBadge: Identifiable, Hashable {
        let id: UUID
        let fileName: String
        let page: Int?
        let preview: String

        init(id: UUID = UUID(), fileName: String, page: Int?, preview: String) {
            self.id = id
            self.fileName = fileName
            self.page = page
            self.preview = preview
        }
    }

    struct QuestionCard: Identifiable, Hashable {
        enum State: Hashable {
            case loading
            case answered(String)
            case noAnswer(String)
        }

        let id: UUID
        let question: String
        let elapsed: TimeInterval
        let category: QuestionCategory
        var state: State
        var sources: [SourceBadge]

        init(
            id: UUID = UUID(),
            question: String,
            elapsed: TimeInterval,
            category: QuestionCategory,
            state: State,
            sources: [SourceBadge] = []
        ) {
            self.id = id
            self.question = question
            self.elapsed = elapsed
            self.category = category
            self.state = state
            self.sources = sources
        }
    }

    struct ActivityEntry: Identifiable, Hashable {
        enum Level: String, Hashable {
            case info
            case warning
            case error
        }

        let id: UUID
        let timestamp: Date
        let category: String
        let level: Level
        let message: String

        init(id: UUID = UUID(), timestamp: Date = Date(), category: String, level: Level, message: String) {
            self.id = id
            self.timestamp = timestamp
            self.category = category
            self.level = level
            self.message = message
        }
    }

    // MARK: - Knowledge Base

    struct KBSource: Identifiable, Hashable {
        let id: String
        let fileName: String
        let addedAt: Date
        let chunkCount: Int

        init(id: String, fileName: String, addedAt: Date = Date(), chunkCount: Int = 0) {
            self.id = id
            self.fileName = fileName
            self.addedAt = addedAt
            self.chunkCount = chunkCount
        }
    }

    struct KBStatus: Hashable {
        var totalDocuments: Int = 0
        var totalChunks: Int = 0
        var indexHealth: String = "unknown"
        var embeddingModel: String = ""
        var vectorDBType: String = ""
        var lastUpdated: Date? = nil
    }

    struct Settings: Hashable {
        var apiKey: String = ""
        var micDevice: String = "Default Microphone"
        var systemDevice: String = "BlackHole 2ch"
        var transcriptionModel: String = "gpt-4o-transcribe"
        var qaModel: String = "gpt-4o-mini"
    }

    var connectionStatus: ConnectionStatus = .disconnected
    var isRecording = false
    var startDate: Date?

    var transcript: [TranscriptEntry] = []
    var hiddenTranscriptCount = 0

    var questions: [QuestionCard] = []
    var activity: [ActivityEntry] = []

    var settings = Settings()
    var availableMicDevices: [String] = []
    var availableSystemDevices: [String] = []
    var isWindowVisible = true

    var errorMessage: String?
    var showAudioSetupWizard = false

    var kbSources: [KBSource] = []
    var kbStatus: KBStatus = KBStatus()
    var kbIngestionProgress: Double? = nil
    var kbIngestionFileName: String? = nil
    var kbIsLoading: Bool = false

    func setRecording(_ value: Bool) {
        isRecording = value
        if value {
            startDate = Date()
        }
    }

    func appendTranscript(speaker: Speaker, text: String, elapsed: TimeInterval, isFinal: Bool) {
        let newEntry = TranscriptEntry(speaker: speaker, text: text, elapsed: elapsed, isFinal: isFinal)
        transcript.append(newEntry)

        if transcript.count > 200 {
            let overflow = transcript.count - 200
            transcript.removeFirst(overflow)
            hiddenTranscriptCount += overflow
        }
    }

    func clearTranscript() {
        transcript.removeAll()
        hiddenTranscriptCount = 0
    }

    func appendQuestion(_ card: QuestionCard) {
        questions.insert(card, at: 0)
    }

    func updateQuestion(id: UUID, state: QuestionCard.State, sources: [SourceBadge] = []) {
        guard let index = questions.firstIndex(where: { $0.id == id }) else { return }
        questions[index].state = state
        questions[index].sources = sources
    }

    func dismissQuestion(id: UUID) {
        questions.removeAll(where: { $0.id == id })
    }

    func appendActivity(category: String, level: ActivityEntry.Level, message: String) {
        activity.insert(ActivityEntry(category: category, level: level, message: message), at: 0)
        if activity.count > 500 {
            activity.removeLast(activity.count - 500)
        }
    }

    func logFrontendEvent(_ event: String, detail: String? = nil, level: ActivityEntry.Level = .info) {
        let message = detail.map { "\(event): \($0)" } ?? event
        appendActivity(category: "frontend", level: level, message: message)
    }

    func logBackendEvent(_ event: String, detail: String? = nil, level: ActivityEntry.Level = .info) {
        let message = detail.map { "\(event): \($0)" } ?? event
        appendActivity(category: "backend", level: level, message: message)
    }

    func updateAvailableDevices(mics: [String], system: [String]) {
        availableMicDevices = mics
        availableSystemDevices = system

        if let firstMic = mics.first, !mics.contains(settings.micDevice) {
            settings.micDevice = firstMic
        }

        if let firstSystem = system.first, !system.contains(settings.systemDevice) {
            settings.systemDevice = firstSystem
        }
    }

    // MARK: - Knowledge Base Methods

    func updateKBStatus(
        sources: [KBSource],
        totalDocuments: Int,
        totalChunks: Int,
        indexHealth: String,
        embeddingModel: String,
        vectorDBType: String
    ) {
        kbSources = sources
        kbStatus.totalDocuments = totalDocuments
        kbStatus.totalChunks = totalChunks
        kbStatus.indexHealth = indexHealth
        kbStatus.embeddingModel = embeddingModel
        kbStatus.vectorDBType = vectorDBType
        kbStatus.lastUpdated = Date()
        kbIsLoading = false
    }

    func updateIngestionProgress(fileName: String, progress: Double) {
        kbIngestionFileName = fileName
        kbIngestionProgress = progress
        if progress >= 1.0 {
            kbIngestionProgress = nil
            kbIngestionFileName = nil
        }
    }

    func removeKBSource(id: String) {
        kbSources.removeAll(where: { $0.id == id })
        kbStatus.totalDocuments = kbSources.count
    }

    func clearKB() {
        kbSources.removeAll()
        kbStatus = KBStatus()
    }
}
