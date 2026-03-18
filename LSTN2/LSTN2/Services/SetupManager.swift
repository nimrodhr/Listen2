import Foundation
import os.log

private let log = Logger(subsystem: "com.lstn2.app", category: "SetupManager")

@MainActor
final class SetupManager {
    let state: SetupState

    init(state: SetupState) {
        self.state = state
    }

    // MARK: - Quick Checks (for subsequent launches)

    /// Runs all prerequisite checks and returns an array of human-readable error descriptions.
    /// An empty array means everything is OK.
    func runQuickChecks() async -> [String] {
        var errors: [String] = []

        if !checkUvInstalled() {
            errors.append("uv not found at \(state.uvPath). Re-run the setup wizard from Settings to install it.")
        }

        if !(await checkPythonAvailable()) {
            errors.append("Python 3.11+ not available. Re-run the setup wizard from Settings.")
        }

        if !checkBackendDepsInstalled() {
            errors.append("Backend dependencies not installed (.venv missing). Re-run the setup wizard from Settings.")
        }

        if !checkAPIKey() {
            errors.append("OpenAI API key not configured. Go to Settings to enter your API key.")
        }

        return errors
    }

    /// Runs all checks and updates state. Returns true if everything is already set up.
    func runAllChecks() async -> Bool {
        // uv
        let uvOK = checkUvInstalled()
        state.envSubStatuses[.uv] = uvOK ? .completed : .pending

        // Python (only if uv is available)
        var pythonOK = false
        if uvOK {
            pythonOK = await checkPythonAvailable()
            state.envSubStatuses[.python] = pythonOK ? .completed : .pending
        }

        // Backend deps (only if uv is available)
        var depsOK = false
        if uvOK {
            depsOK = checkBackendDepsInstalled()
            state.envSubStatuses[.deps] = depsOK ? .completed : .pending
        }

        // Mark environment step overall
        if uvOK && pythonOK && depsOK {
            state.stepStatuses[.environment] = .completed
        }

        // API key
        let apiKeyOK = checkAPIKey()
        state.stepStatuses[.apiKey] = apiKeyOK ? .completed : .pending
        if apiKeyOK {
            state.apiKeyInput = loadExistingAPIKey()
        }

        // BlackHole
        let bhOK = checkBlackHoleInstalled()
        state.stepStatuses[.blackHole] = bhOK ? .completed : .pending
        state.blackHoleDetected = bhOK

        // Audio config is informational, always pending until wizard marks it
        state.stepStatuses[.audioConfig] = .pending

        state.advanceToFirstIncompleteStep()

        let allRequired = uvOK && pythonOK && depsOK && apiKeyOK
        return allRequired
    }

    // MARK: - Individual Checks

    func checkUvInstalled() -> Bool {
        FileManager.default.fileExists(atPath: state.uvPath)
    }

    func checkPythonAvailable() async -> Bool {
        guard checkUvInstalled() else { return false }
        let (exitCode, output) = await runProcess(
            executablePath: state.uvPath,
            arguments: ["python", "find", ">=3.11"],
            workingDirectory: nil
        )
        if exitCode == 0 {
            state.detectedPythonVersion = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return true
        }
        return false
    }

    func checkBackendDepsInstalled() -> Bool {
        let venvPath = "\(state.backendDirectory)/.venv"
        return FileManager.default.fileExists(atPath: venvPath)
    }

    func checkAPIKey() -> Bool {
        let key = loadExistingAPIKey()
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func loadExistingAPIKey() -> String {
        let settings = AppState.Settings.loadFromDisk()
        return settings.apiKey
    }

    func checkBlackHoleInstalled() -> Bool {
        // Primary: check driver file
        let driverPath = "/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver"
        if FileManager.default.fileExists(atPath: driverPath) {
            return true
        }
        // Fallback: check audio device names via AudioDeviceService
        let service = AudioDeviceService()
        let devices = service.loadDevices()
        return devices.systemOutputs.contains(where: {
            $0.localizedCaseInsensitiveContains("BlackHole")
        })
    }

    // MARK: - Installation Actions

    func installAll() async {
        state.installOutput = ""

        // Step 1: uv
        if state.envSubStatuses[.uv] != .completed {
            guard await installUv() else { return }
        }

        // Step 2: Python
        if state.envSubStatuses[.python] != .completed {
            guard await installPython() else { return }
        }

        // Step 3: Backend deps
        if state.envSubStatuses[.deps] != .completed {
            guard await installBackendDeps() else { return }
        }

        state.stepStatuses[.environment] = .completed
    }

    func installUv() async -> Bool {
        state.envSubStatuses[.uv] = .inProgress(detail: "Downloading uv...")
        state.stepStatuses[.environment] = .inProgress(detail: "Installing uv...")
        appendOutput("$ curl -LsSf https://astral.sh/uv/install.sh | sh\n")

        let (exitCode, output) = await runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", "curl -LsSf https://astral.sh/uv/install.sh | sh"],
            workingDirectory: NSHomeDirectory()
        )

        appendOutput(output)

        if exitCode == 0 && FileManager.default.fileExists(atPath: state.uvPath) {
            state.envSubStatuses[.uv] = .completed
            appendOutput("\n✓ uv installed successfully\n\n")
            log.info("uv installed successfully")
            return true
        } else {
            let errorMsg = "uv installation failed (exit code: \(exitCode))"
            state.envSubStatuses[.uv] = .failed(error: errorMsg)
            state.stepStatuses[.environment] = .failed(error: errorMsg)
            appendOutput("\n✗ \(errorMsg)\n")
            log.error("\(errorMsg)")
            return false
        }
    }

    func installPython() async -> Bool {
        state.envSubStatuses[.python] = .inProgress(detail: "Installing Python 3.13...")
        state.stepStatuses[.environment] = .inProgress(detail: "Installing Python...")
        appendOutput("$ uv python install 3.13\n")

        let (exitCode, output) = await runProcess(
            executablePath: state.uvPath,
            arguments: ["python", "install", "3.13"],
            workingDirectory: nil
        )

        appendOutput(output)

        if exitCode == 0 {
            state.envSubStatuses[.python] = .completed
            state.detectedPythonVersion = "3.13"
            appendOutput("\n✓ Python 3.13 installed\n\n")
            log.info("Python 3.13 installed")
            return true
        } else {
            let errorMsg = "Python installation failed (exit code: \(exitCode))"
            state.envSubStatuses[.python] = .failed(error: errorMsg)
            state.stepStatuses[.environment] = .failed(error: errorMsg)
            appendOutput("\n✗ \(errorMsg)\n")
            log.error("\(errorMsg)")
            return false
        }
    }

    func installBackendDeps() async -> Bool {
        state.envSubStatuses[.deps] = .inProgress(detail: "Running uv sync...")
        state.stepStatuses[.environment] = .inProgress(detail: "Installing dependencies...")
        appendOutput("$ cd \(state.backendDirectory) && uv sync\n")

        let (exitCode, output) = await runProcess(
            executablePath: state.uvPath,
            arguments: ["sync"],
            workingDirectory: state.backendDirectory
        )

        appendOutput(output)

        if exitCode == 0 {
            state.envSubStatuses[.deps] = .completed
            appendOutput("\n✓ Backend dependencies installed\n\n")
            log.info("Backend dependencies synced")
            return true
        } else {
            let errorMsg = "Dependency installation failed (exit code: \(exitCode))"
            state.envSubStatuses[.deps] = .failed(error: errorMsg)
            state.stepStatuses[.environment] = .failed(error: errorMsg)
            appendOutput("\n✗ \(errorMsg)\n")
            log.error("\(errorMsg)")
            return false
        }
    }

    func saveAPIKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            state.stepStatuses[.apiKey] = .failed(error: "API key cannot be empty")
            return false
        }

        guard trimmed.hasPrefix("sk-") else {
            state.stepStatuses[.apiKey] = .failed(error: "Invalid format — OpenAI keys start with sk-")
            return false
        }

        let listenDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".listen")
        let settingsPath = listenDir.appendingPathComponent("settings.json")

        do {
            try FileManager.default.createDirectory(at: listenDir, withIntermediateDirectories: true)

            var settings: [String: Any] = [:]
            if let data = try? Data(contentsOf: settingsPath),
               let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                settings = existing
            }

            var apiKeys = settings["api_keys"] as? [String: Any] ?? [:]
            apiKeys["openai"] = trimmed
            settings["api_keys"] = apiKeys

            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: settingsPath, options: .atomic)

            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: settingsPath.path
            )

            state.stepStatuses[.apiKey] = .completed
            state.apiKeyInput = trimmed
            log.info("API key saved to settings.json")
            return true
        } catch {
            let msg = "Failed to save API key: \(error.localizedDescription)"
            state.stepStatuses[.apiKey] = .failed(error: msg)
            log.error("\(msg)")
            return false
        }
    }

    // MARK: - Process Runner

    private func runProcess(
        executablePath: String,
        arguments: [String],
        workingDirectory: String?
    ) async -> (Int32, String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: executablePath)
                proc.arguments = arguments
                if let wd = workingDirectory {
                    proc.currentDirectoryURL = URL(fileURLWithPath: wd)
                }
                proc.environment = [
                    "HOME": NSHomeDirectory(),
                    "PATH": "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                ]

                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = pipe

                do {
                    try proc.run()
                    proc.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(returning: (proc.terminationStatus, output))
                } catch {
                    continuation.resume(returning: (-1, "Failed to run process: \(error.localizedDescription)"))
                }
            }
        }
    }

    private func appendOutput(_ text: String) {
        state.installOutput += text
    }
}
