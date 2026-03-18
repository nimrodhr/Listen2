import Foundation
import Observation
import os.log

private let log = Logger(subsystem: "com.lstn2.app", category: "SetupState")

@MainActor
@Observable
final class SetupState {

    // MARK: - Step Definition

    enum Step: Int, CaseIterable, Comparable {
        case environment = 0   // uv + Python + deps (combined)
        case apiKey
        case blackHole
        case audioConfig

        static func < (lhs: Step, rhs: Step) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var title: String {
            switch self {
            case .environment: "Environment"
            case .apiKey: "API Key"
            case .blackHole: "BlackHole"
            case .audioConfig: "Audio"
            }
        }

        var systemImage: String {
            switch self {
            case .environment: "terminal"
            case .apiKey: "key"
            case .blackHole: "speaker.wave.2"
            case .audioConfig: "mic"
            }
        }
    }

    // MARK: - Sub-step for environment

    enum EnvironmentSubStep: Int, CaseIterable {
        case uv = 0
        case python
        case deps

        var title: String {
            switch self {
            case .uv: "Package Manager (uv)"
            case .python: "Python Runtime"
            case .deps: "Backend Dependencies"
            }
        }
    }

    // MARK: - Step Status

    enum StepStatus: Equatable {
        case pending
        case checking
        case inProgress(detail: String)
        case completed
        case failed(error: String)
        case skipped
    }

    // MARK: - Properties

    var currentStep: Step = .environment
    var stepStatuses: [Step: StepStatus] = {
        var dict: [Step: StepStatus] = [:]
        for step in Step.allCases {
            dict[step] = .pending
        }
        return dict
    }()

    /// Sub-step statuses for the environment step
    var envSubStatuses: [EnvironmentSubStep: StepStatus] = {
        var dict: [EnvironmentSubStep: StepStatus] = [:]
        for sub in EnvironmentSubStep.allCases {
            dict[sub] = .pending
        }
        return dict
    }()

    /// True when required steps are done (environment + API key).
    var isSetupComplete: Bool {
        let requiredSteps: [Step] = [.environment, .apiKey]
        return requiredSteps.allSatisfy { step in
            stepStatuses[step] == .completed || stepStatuses[step] == .skipped
        }
    }

    /// True when environment sub-step is fully done.
    var isEnvironmentComplete: Bool {
        EnvironmentSubStep.allCases.allSatisfy { sub in
            envSubStatuses[sub] == .completed
        }
    }

    // Step-specific data
    var apiKeyInput: String = ""
    var uvPath: String = "\(NSHomeDirectory())/.local/bin/uv"
    var backendDirectory: String = "\(NSHomeDirectory())/Documents/LSTN2/backend"
    var installOutput: String = ""
    var detectedPythonVersion: String?

    // BlackHole
    var blackHoleDetected: Bool = false

    // MARK: - Persistence

    static let setupCompleteKey = "com.lstn2.setupComplete"
    static let setupVersionKey = "com.lstn2.setupVersion"
    static let currentSetupVersion = 1

    static var hasCompletedSetup: Bool {
        let version = UserDefaults.standard.integer(forKey: setupVersionKey)
        return UserDefaults.standard.bool(forKey: setupCompleteKey) && version >= currentSetupVersion
    }

    static func markSetupComplete() {
        UserDefaults.standard.set(true, forKey: setupCompleteKey)
        UserDefaults.standard.set(currentSetupVersion, forKey: setupVersionKey)
        log.info("Setup marked as complete (version \(currentSetupVersion))")
    }

    static func resetSetupState() {
        UserDefaults.standard.set(false, forKey: setupCompleteKey)
        log.info("Setup state reset — wizard will show on next relevant trigger")
    }

    // MARK: - Helpers

    func advanceToFirstIncompleteStep() {
        for step in Step.allCases {
            if stepStatuses[step] != .completed && stepStatuses[step] != .skipped {
                currentStep = step
                return
            }
        }
    }

    /// Resets all mutable state back to defaults so the wizard can be re-run
    /// without replacing the object (which would invalidate SwiftUI observation).
    func reset() {
        currentStep = .environment
        for step in Step.allCases {
            stepStatuses[step] = .pending
        }
        for sub in EnvironmentSubStep.allCases {
            envSubStatuses[sub] = .pending
        }
        apiKeyInput = ""
        installOutput = ""
        detectedPythonVersion = nil
        blackHoleDetected = false
    }
}
