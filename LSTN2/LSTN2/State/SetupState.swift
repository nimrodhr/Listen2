import Foundation
import Observation
import os.log

private let log = Logger(subsystem: "com.lstn2.app", category: "SetupState")

@MainActor
@Observable
final class SetupState {

    // MARK: - Step Definition

    enum Step: Int, CaseIterable, Comparable {
        case environment = 0   // uv + Python + deps + BlackHole (combined)
        case apiKey
        case audioConfig

        static func < (lhs: Step, rhs: Step) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var title: String {
            switch self {
            case .environment: "Environment"
            case .apiKey: "API Key"
            case .audioConfig: "Audio"
            }
        }

        var systemImage: String {
            switch self {
            case .environment: "terminal"
            case .apiKey: "key"
            case .audioConfig: "mic"
            }
        }
    }

    // MARK: - Sub-step for environment

    enum EnvironmentSubStep: Int, CaseIterable {
        case uv = 0
        case python
        case deps
        case blackHole

        var title: String {
            switch self {
            case .uv: "Package Manager (uv)"
            case .python: "Python Runtime"
            case .deps: "Backend Dependencies"
            case .blackHole: "BlackHole Audio Driver"
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

    /// True when required environment sub-steps are done (uv, python, deps).
    /// BlackHole is optional — mic-only recording works without it.
    var isEnvironmentComplete: Bool {
        let required: [EnvironmentSubStep] = [.uv, .python, .deps]
        return required.allSatisfy { sub in
            envSubStatuses[sub] == .completed
        }
    }

    // Step-specific data
    var apiKeyInput: String = ""
    var uvPath: String = "\(NSHomeDirectory())/.local/bin/uv"
    var backendDirectory: String = SetupState.resolveBackendDirectory()
    var installOutput: String = ""
    var detectedPythonVersion: String?

    // BlackHole
    /// True when driver file is installed but audio device not yet visible (reboot needed)
    var blackHoleNeedsReboot: Bool = false

    // MARK: - Persistence

    static let setupCompleteKey = "com.lstn2.setupComplete"
    static let setupVersionKey = "com.lstn2.setupVersion"
    static let currentSetupVersion = 2

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

    // MARK: - Backend Directory Resolution

    /// Resolves the backend directory by searching known locations.
    /// Priority: LSTN2_BACKEND_DIR env var → source tree (via #filePath) → ~/Documents/LSTN2/backend
    static func resolveBackendDirectory(_ sourceFile: String = #filePath) -> String {
        // 1. Environment variable override
        if let envDir = ProcessInfo.processInfo.environment["LSTN2_BACKEND_DIR"],
           FileManager.default.fileExists(atPath: envDir) {
            return envDir
        }

        // 2. Derive from compile-time source file path
        //    sourceFile is e.g. /Users/mark.s/Projects/Listen2/LSTN2/LSTN2/State/SetupState.swift
        //    We need to walk up to the repo root and append "backend"
        let sourceURL = URL(fileURLWithPath: sourceFile)
        var dir = sourceURL.deletingLastPathComponent() // State/
        // Walk up until we find a sibling "backend" directory
        for _ in 0..<10 {
            dir = dir.deletingLastPathComponent()
            let candidate = dir.appendingPathComponent("backend").path
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }

        // 3. Fallback to conventional location
        return "\(NSHomeDirectory())/Documents/LSTN2/backend"
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
        backendDirectory = SetupState.resolveBackendDirectory()
        installOutput = ""
        detectedPythonVersion = nil
        blackHoleNeedsReboot = false
    }
}
